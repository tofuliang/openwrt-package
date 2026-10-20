#include "proxy.h"

static void usage(const char *program) {
    fprintf(stderr, "usage: %s [--self-test] [--log-level LEVEL]\n"
                    "levels: error, warn, info, debug, trace\n", program);
}
static pthread_mutex_t workers_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t workers_done = PTHREAD_COND_INITIALIZER;
static size_t active_workers;

static void *client_worker(void *arg) {
    int fd = *(int *)arg;
    free(arg);
    struct timeval send_timeout = {10, 0};
    if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send_timeout, sizeof(send_timeout)) < 0) LOGW("setsockopt SO_SNDTIMEO failed: %s", strerror(errno));
    LOGD("client worker started fd=%d", fd);
    handle_client(fd);
    close(fd);
    pthread_mutex_lock(&workers_lock);
    active_workers--;
    pthread_cond_signal(&workers_done);
    pthread_mutex_unlock(&workers_lock);
    LOGD("client worker stopped fd=%d", fd);
    return NULL;
}

static void wait_for_workers(void) {
    pthread_mutex_lock(&workers_lock);
    while (active_workers != 0) pthread_cond_wait(&workers_done, &workers_lock);
    pthread_mutex_unlock(&workers_lock);
}

int main(int argc, char **argv) {
    const char *env_level = getenv("IPTVPROXY_LOG_LEVEL");
    if (env_level && *env_level && parse_log_level(env_level, &log_level) != 0) {
        fprintf(stderr, "invalid IPTVPROXY_LOG_LEVEL: %s\n", env_level);
        return 2;
    }
    int run_self_test = 0;
    proxy_configure_profile();
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--self-test")) { run_self_test = 1; continue; }
        const char *value = NULL;
        if (!strcmp(argv[i], "--log-level") || !strcmp(argv[i], "-l")) {
            if (++i >= argc) { usage(argv[0]); return 2; }
            value = argv[i];
        } else if (!strncmp(argv[i], "--log-level=", 12)) {
            value = argv[i] + 12;
        } else {
            usage(argv[0]);
            return 2;
        }
        if (parse_log_level(value, &log_level) != 0) {
            fprintf(stderr, "invalid log level: %s\n", value);
            usage(argv[0]);
            return 2;
        }
    }
    if (run_self_test) return self_test();
    if (proxy_init_storage() != 0) return 2;

    const char *bind_addr = getenv("IPTVPROXY_BIND");
    if (!bind_addr || !*bind_addr) bind_addr = "0.0.0.0:" DEFAULT_PORT_TEXT;
    const char *slash = strrchr(bind_addr, ':');
    if (!slash) { LOGE("bind must be host:port"); proxy_free_storage(); return 2; }
    char host[256];
    size_t hl = (size_t)(slash - bind_addr);
    if (hl >= sizeof(host)) { LOGE("bind host is too long"); proxy_free_storage(); return 2; }
    memcpy(host, bind_addr, hl); host[hl] = 0;
    int port = atoi(slash + 1);
    if (port < 1 || port > 65535) { LOGE("invalid bind port: %s", slash + 1); proxy_free_storage(); return 2; }
    snprintf(public_base, sizeof(public_base), "%s", getenv("IPTVPROXY_URL") ? getenv("IPTVPROXY_URL") : "");
    LOGI("starting bind=%s profile=%s log_level=%s sessions=%zu hls_targets=%zu variable_bytes=%zu page_limit=%zu playlist_limit=%zu public_base=%s",
         bind_addr, "low-memory", log_level_name(log_level), proxy_config.session_capacity,
         proxy_config.hls_target_capacity, proxy_config.max_variable_value_bytes,
         proxy_config.page_limit, proxy_config.playlist_limit,
         public_base[0] ? public_base : "<none>");

    curl_global_init(CURL_GLOBAL_DEFAULT);
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal); signal(SIGPIPE, SIG_IGN);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { LOGE("socket failed: %s", strerror(errno)); curl_global_cleanup(); proxy_free_storage(); return 2; }
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) < 0) LOGW("setsockopt SO_REUSEADDR failed: %s", strerror(errno));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr)); addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = !strcmp(host, "localhost") || !strcmp(host, "127.0.0.1") ? htonl(0x7f000001u) : htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, SOMAXCONN) < 0) {
        LOGE("bind/listen failed on %s: %s", bind_addr, strerror(errno)); close(fd); curl_global_cleanup(); proxy_free_storage(); return 2;
    }
    LOGI("listening on %s backlog=%d", bind_addr, SOMAXCONN);
    while (!stopping) {
        fd_set read_set; FD_ZERO(&read_set); FD_SET(fd, &read_set);
        int ready = select(fd + 1, &read_set, NULL, NULL, NULL);
        if (ready < 0) { if (errno == EINTR) continue; LOGE("select failed: %s", strerror(errno)); break; }
        if (ready == 0) continue;
        int c = accept(fd, NULL, NULL);
        if (c < 0) { if (errno == EINTR) continue; LOGW("accept failed: %s", strerror(errno)); continue; }
        int *client_fd = malloc(sizeof(*client_fd));
        if (!client_fd) { LOGW("client fd allocation failed"); close(c); continue; }
        *client_fd = c;
        pthread_mutex_lock(&workers_lock); active_workers++; pthread_mutex_unlock(&workers_lock);
        pthread_t worker;
        int thread_rc = pthread_create(&worker, NULL, client_worker, client_fd);
        if (thread_rc != 0) {
            pthread_mutex_lock(&workers_lock); active_workers--; pthread_cond_signal(&workers_done); pthread_mutex_unlock(&workers_lock);
            LOGW("pthread_create failed: %s", strerror(thread_rc)); free(client_fd); close(c); continue;
        }
        pthread_detach(worker);
        pthread_mutex_lock(&workers_lock); size_t worker_count = active_workers; pthread_mutex_unlock(&workers_lock);
        LOGD("accepted client fd=%d active_workers=%zu", c, worker_count);
    }
    LOGI("stopping"); close(fd); wait_for_workers(); curl_global_cleanup(); proxy_free_storage(); return 0;
}
