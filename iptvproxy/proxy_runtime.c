#include "proxy.h"

ProxyConfig proxy_config = {
    .session_capacity = PROXY_MAX_SESSIONS,
    .hls_target_capacity = PROXY_MAX_HLS_TARGETS,
    .max_variables = PROXY_MAX_VARIABLES,
    .max_variable_value_bytes = PROXY_MAX_VARIABLE_VALUE_BYTES,
    .page_limit = PROXY_MAX_PAGE_BYTES,
    .playlist_limit = PROXY_MAX_PLAYLIST_BYTES,
};
Session *sessions;
HlsTarget *hls_targets;
unsigned long token_counter = 1;
volatile sig_atomic_t stopping = 0;
char public_base[1024];
LogLevel log_level = LOG_INFO;

const char *log_level_name(LogLevel level) {
    static const char *names[] = {"ERROR", "WARN", "INFO", "DEBUG", "TRACE"};
    return level <= LOG_TRACE ? names[level] : "UNKNOWN";
}

int parse_log_level(const char *text, LogLevel *out) {
    if (!strcasecmp(text, "error")) *out = LOG_ERROR;
    else if (!strcasecmp(text, "warn") || !strcasecmp(text, "warning")) *out = LOG_WARN;
    else if (!strcasecmp(text, "info")) *out = LOG_INFO;
    else if (!strcasecmp(text, "debug")) *out = LOG_DEBUG;
    else if (!strcasecmp(text, "trace")) *out = LOG_TRACE;
    else return -1;
    return 0;
}

void log_emit(LogLevel level, const char *function, const char *format, ...) {
    if (level > log_level) return;
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    struct tm tm_now;
    localtime_r(&now.tv_sec, &tm_now);
    fprintf(stderr, "%04d-%02d-%02dT%02d:%02d:%02d.%03ld [%s] %s: ",
            tm_now.tm_year + 1900, tm_now.tm_mon + 1, tm_now.tm_mday,
            tm_now.tm_hour, tm_now.tm_min, tm_now.tm_sec,
            now.tv_nsec / 1000000L, log_level_name(level), function);
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
    fputc('\n', stderr);
}

void on_signal(int sig) { (void)sig; stopping = 1; }

void proxy_configure_profile(void) {
    proxy_config = (ProxyConfig){
        .session_capacity = PROXY_MAX_SESSIONS,
        .hls_target_capacity = PROXY_MAX_HLS_TARGETS,
        .max_variables = PROXY_MAX_VARIABLES,
        .max_variable_value_bytes = PROXY_MAX_VARIABLE_VALUE_BYTES,
        .page_limit = PROXY_MAX_PAGE_BYTES,
        .playlist_limit = PROXY_MAX_PLAYLIST_BYTES,
    };
}

int proxy_init_storage(void) {
    sessions = calloc(proxy_config.session_capacity, sizeof(*sessions));
    hls_targets = calloc(proxy_config.hls_target_capacity, sizeof(*hls_targets));
    if (!sessions || !hls_targets) {
        LOGE("storage allocation failed sessions=%zu hls_targets=%zu", proxy_config.session_capacity, proxy_config.hls_target_capacity);
        proxy_free_storage();
        return -1;
    }
    return 0;
}

void proxy_free_storage(void) {
    free(sessions);
    free(hls_targets);
    sessions = NULL;
    hls_targets = NULL;
}

void buffer_free(Buffer *b) { free(b->data); memset(b, 0, sizeof(*b)); }
