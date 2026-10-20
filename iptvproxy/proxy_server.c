#include "proxy.h"
int safe_input_url(const char *url);
int safe_media_url(const char *url, int initial);
int join_url(const char *base, const char *ref, char *out, size_t cap);

static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static void make_token(char *out, size_t cap, const char prefix) { snprintf(out, cap, "%c%016lx%08lx", prefix, (unsigned long)time(NULL), token_counter++); }
static Session *find_session_unlocked(const char *token) { time_t now = time(NULL); for (size_t i = 0; i < proxy_config.session_capacity; i++) if (sessions[i].active && sessions[i].expires > now && !strcmp(sessions[i].token, token)) return &sessions[i]; return NULL; }
static int copy_session(const char *token, Session *out) { int found = 0; pthread_mutex_lock(&state_lock); Session *s = find_session_unlocked(token); if (s) { *out = *s; found = 1; } pthread_mutex_unlock(&state_lock); return found ? 0 : -1; }
static void update_session_media(const Session *snapshot) { pthread_mutex_lock(&state_lock); Session *s = find_session_unlocked(snapshot->token); if (s) snprintf(s->media_url, sizeof(s->media_url), "%s", snapshot->media_url); pthread_mutex_unlock(&state_lock); }
static int create_session(const char *page, const char *media, Session *out) { int created = 0; pthread_mutex_lock(&state_lock); for (size_t i = 0; i < proxy_config.session_capacity; i++) if (!sessions[i].active || sessions[i].expires <= time(NULL)) { Session *s = &sessions[i]; memset(s, 0, sizeof(*s)); s->active = 1; make_token(s->token, sizeof(s->token), 's'); snprintf(s->page_url, sizeof(s->page_url), "%s", page); snprintf(s->media_url, sizeof(s->media_url), "%s", media); s->expires = time(NULL) + 30; *out = *s; created = 1; break; } pthread_mutex_unlock(&state_lock); return created ? 0 : -1; }
static int create_hls_target(const char *session, const char *url, HlsTarget *out) { int created = 0; pthread_mutex_lock(&state_lock); for (size_t i = 0; i < proxy_config.hls_target_capacity; i++) if (!hls_targets[i].active || hls_targets[i].expires <= time(NULL)) { HlsTarget *t = &hls_targets[i]; memset(t, 0, sizeof(*t)); t->active = 1; make_token(t->token, sizeof(t->token), 'h'); snprintf(t->session, sizeof(t->session), "%s", session); snprintf(t->url, sizeof(t->url), "%s", url); t->expires = time(NULL) + 30; *out = *t; created = 1; break; } pthread_mutex_unlock(&state_lock); return created ? 0 : -1; }
static int copy_hls_target_session(const char *token, HlsTarget *target, Session *session) { int found = 0; pthread_mutex_lock(&state_lock); time_t now = time(NULL); for (size_t i = 0; i < proxy_config.hls_target_capacity; i++) if (hls_targets[i].active && hls_targets[i].expires > now && !strcmp(hls_targets[i].token, token)) { Session *s = find_session_unlocked(hls_targets[i].session); if (s) { *target = hls_targets[i]; *session = *s; found = 1; } break; } pthread_mutex_unlock(&state_lock); return found ? 0 : -1; }
int join_url(const char *base, const char *ref, char *out, size_t cap) {
    if (!base || !ref || !out || cap == 0) return -1;
    if (is_scheme(ref)) return snprintf(out, cap, "%s", ref) >= (int)cap ? -1 : 0;
    ParsedUrl b;
    if (parse_url(base, &b) != 0) return -1;
    char authority[320];
    int default_port = !strcasecmp(b.scheme, "https") ? 443 : 80;
    int authority_len = b.port == default_port
        ? snprintf(authority, sizeof(authority), "%s://%s", b.scheme, b.host)
        : snprintf(authority, sizeof(authority), "%s://%s:%d", b.scheme, b.host, b.port);
    if (authority_len < 0 || (size_t)authority_len >= sizeof(authority)) return -1;
    if (ref[0] == '/' && ref[1] == '/') return snprintf(out, cap, "%s:%s", b.scheme, ref) >= (int)cap ? -1 : 0;
    if (ref[0] == '/') return snprintf(out, cap, "%s%s", authority, ref) >= (int)cap ? -1 : 0;
    if (ref[0] == '?' || ref[0] == '#') return snprintf(out, cap, "%s%s%s", authority, b.path, ref) >= (int)cap ? -1 : 0;
    char root[MAX_URL];
    int root_len = snprintf(root, sizeof(root), "%s%s", authority, b.path);
    if (root_len < 0 || (size_t)root_len >= sizeof(root)) return -1;
    char *slash = strrchr(root, '/');
    if (!slash) return -1;
    slash[1] = 0;
    return snprintf(out, cap, "%s%s", root, ref) >= (int)cap ? -1 : 0;
}
static void public_path(const char *path, char *out, size_t cap) { if (public_base[0]) { snprintf(out, cap, "%s%s%s", public_base, public_base[strlen(public_base)-1] == '/' ? "" : "/", path[0] == '/' ? path + 1 : path); } else snprintf(out, cap, "%s", path); }
static int rewrite_playlist(const char *body, size_t len, const char *base, const char *session, char *out, size_t cap) {
    size_t used = 0; const char *p = body, *end = body + len;
    while (p < end) { const char *nl = memchr(p, '\n', (size_t)(end-p)); if (!nl) nl = end; size_t line_len = (size_t)(nl-p); char line[8192]; if (line_len >= sizeof(line)) return -1; memcpy(line, p, line_len); line[line_len] = 0; char *trimmed = trim(line); int is_uri = *trimmed && *trimmed != '#'; char *uri_start = NULL, *uri_end = NULL;
        if (!is_uri) { char *u = strstr(line, "URI=\""); if (u) { uri_start = u + 5; uri_end = strchr(uri_start, '\"'); } }
        else { uri_start = trimmed; uri_end = trimmed + strlen(trimmed); }
        if (uri_start && uri_end && uri_end > uri_start) { char ref[4096]; size_t rn = (size_t)(uri_end-uri_start); if (rn >= sizeof(ref)) return -1; memcpy(ref, uri_start, rn); ref[rn] = 0; char absolute[MAX_URL]; if (join_url(base, ref, absolute, sizeof(absolute)) != 0 || !safe_media_url(absolute, 0)) return -1; HlsTarget target; if (create_hls_target(session, absolute, &target) != 0) return -1; char proxy[1100], replacement[1300]; snprintf(proxy, sizeof(proxy), "/hls/%s", target.token); public_path(proxy, replacement, sizeof(replacement)); char rebuilt[8192]; size_t pre = (size_t)(uri_start - line), post = strlen(uri_end); if (pre + strlen(replacement) + post + 1 >= sizeof(rebuilt)) return -1; memcpy(rebuilt, line, pre); strcpy(rebuilt + pre, replacement); memcpy(rebuilt + pre + strlen(replacement), uri_end, post + 1); snprintf(line, sizeof(line), "%s", rebuilt); }
        if (used + strlen(line) + 2 >= cap) return -1; memcpy(out + used, line, strlen(line)); used += strlen(line); out[used++] = '\n'; p = nl < end ? nl + 1 : end;
    }
    out[used] = 0; return 0;
}
 static void send_all(int fd, const void *buf, size_t len) { const char *p = buf; while (len) { ssize_t n = send(fd, p, len, 0); if (n <= 0) return; p += n; len -= (size_t)n; } }
static void send_response(int fd, const char *method, int status, const char *type, const char *extra, const void *body, size_t len) { const char *text = status == 200 ? "OK" : status == 206 ? "Partial Content" : status == 302 ? "Found" : status == 400 ? "Bad Request" : status == 404 ? "Not Found" : status == 405 ? "Method Not Allowed" : status == 502 ? "Bad Gateway" : "Service Unavailable"; char h[2048]; int n = snprintf(h, sizeof(h), "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n%s\r\n", status, text, type ? type : "text/plain", len, extra ? extra : ""); send_all(fd, h, (size_t)n); if (strcasecmp(method, "HEAD")) send_all(fd, body, len); }
static int parse_request(int fd, char *method, size_t mcap, char *target, size_t tcap, char *headers, size_t hcap) { char buf[MAX_REQUEST]; ssize_t n = recv(fd, buf, sizeof(buf)-1, 0); if (n <= 0) return -1; buf[n] = 0; char *line_end = strstr(buf, "\r\n"); if (!line_end) return -1; *line_end = 0; if (sscanf(buf, "%15s %8191s", method, target) != 2) return -1; char *hs = line_end + 2; char *hend = strstr(hs, "\r\n\r\n"); if (!hend) hend = hs + strlen(hs); size_t len = (size_t)(hend - hs); if (len >= hcap) len = hcap - 1; memcpy(headers, hs, len); headers[len] = 0; (void)mcap; (void)tcap; return 0; }
void handle_client(int fd) {
    char method[16], target[MAX_URL], headers[MAX_REQUEST]; if (parse_request(fd, method, sizeof(method), target, sizeof(target), headers, sizeof(headers)) != 0) { send_response(fd, "GET", 400, NULL, NULL, "bad request\n", 12); return; }
    LOGT("request fd=%d method=%s target=%s", fd, method, target);
    if (strcasecmp(method, "GET") && strcasecmp(method, "HEAD") && strcasecmp(method, "OPTIONS")) { send_response(fd, method, 405, NULL, NULL, "method not allowed\n", 20); return; }
    if (!strcmp(method, "OPTIONS")) { send_response(fd, method, 204, "text/plain", NULL, "", 0); return; }
    if (!strncmp(target, "/healthz", 8)) { send_response(fd, method, 200, "text/plain", NULL, "ok\n", 3); return; }
    char *q = strchr(target, '?'); char path[MAX_URL]; if (q) { *q++ = 0; snprintf(path, sizeof(path), "%s", target); } else { snprintf(path, sizeof(path), "%s", target); q = ""; }
    if (!strcmp(path, "/345iptv")) {
        const char *s = strstr(q, "s="); if (!s) { send_response(fd, method, 400, NULL, NULL, "missing s\n", 10); return; } s += 2; char page[MAX_URL]; if (url_decode(s, page, sizeof(page)) != 0 || !safe_input_url(page)) { send_response(fd, method, 400, NULL, NULL, "invalid page URL\n", 18); return; }
        HttpResponse html; if (curl_fetch(page, "GET", NULL, NULL, MAX_PAGE_BYTES, 0, &html) != 0 || html.status < 200 || html.status >= 300) { buffer_free(&html.body); send_response(fd, method, 502, NULL, NULL, "page fetch failed\n", 19); return; }
        char media[MAX_URL]; DecoderConfig cfg; parse_config(html.body.data ? html.body.data : "", &cfg); int ok = choose_media(html.body.data ? html.body.data : "", page, &cfg, media, sizeof(media)) == 0; buffer_free(&html.body); if (!ok) { send_response(fd, method, 502, NULL, NULL, "page decode failed\n", 20); return; }
        Session session;
        if (create_session(page, media, &session) != 0) { send_response(fd, method, 503, NULL, NULL, "session capacity\n", 18); return; }
        LOGI("session created token=%s media=%s", session.token, media);
        char loc[1200], pth[1100]; snprintf(pth, sizeof(pth), "/stream/%s", session.token); public_path(pth, loc, sizeof(loc)); char extra[1400]; snprintf(extra, sizeof(extra), "Location: %s\r\n", loc); send_response(fd, method, 302, "text/plain", extra, "", 0); return;
    }
    if (!strncmp(path, "/stream/", 8)) {
        Session session;
        if (copy_session(path + 8, &session) != 0) { send_response(fd, method, 404, NULL, NULL, "not found\n", 10); return; }
        LOGD("stream request token=%s media=%s method=%s", session.token, session.media_url, method);
        char referer[MAX_URL]; snprintf(referer, sizeof(referer), "%s", session.page_url); ParsedUrl pu; parse_url(session.page_url, &pu); char origin[512]; snprintf(origin, sizeof(origin), "%s://%s", pu.scheme, pu.host);
        if (!strcasecmp(method, "GET") && !strstr(session.media_url, ".m3u8")) {
            int stream_rc = stream_session_media(fd, &session, referer, origin); update_session_media(&session);
            if (stream_rc == 0) return;
            send_response(fd, method, 502, NULL, NULL, "upstream failed\n", 17); return;
        }
        HttpResponse upstream;
        if (fetch_session_media(&session, method, referer, origin, &upstream) != 0) { update_session_media(&session); send_response(fd, method, 502, NULL, NULL, "upstream failed\n", 17); return; }
        if (upstream.location[0]) snprintf(session.media_url, sizeof(session.media_url), "%s", upstream.location);
        int playlist = strstr(upstream.content_type, "mpegurl") || strstr(upstream.content_type, "m3u8") || strstr(session.media_url, ".m3u8");
        if (playlist && strcasecmp(method, "HEAD")) {
            char *rewritten = malloc(MAX_PLAYLIST_BYTES + 1);
            if (!rewritten) { update_session_media(&session); buffer_free(&upstream.body); send_response(fd, method, 503, NULL, NULL, "playlist memory unavailable\n", 28); return; }
            if (rewrite_playlist(upstream.body.data ? upstream.body.data : "", upstream.body.len, session.media_url, session.token, rewritten, MAX_PLAYLIST_BYTES + 1) != 0) { update_session_media(&session); free(rewritten); buffer_free(&upstream.body); send_response(fd, method, 502, NULL, NULL, "playlist rejected\n", 19); return; }
            update_session_media(&session); buffer_free(&upstream.body); send_response(fd, method, upstream.status ? upstream.status : 200, "application/vnd.apple.mpegurl", NULL, rewritten, strlen(rewritten)); free(rewritten); return;
        }
        update_session_media(&session); send_response(fd, method, upstream.status ? upstream.status : 502, upstream.content_type[0] ? upstream.content_type : "application/octet-stream", NULL, upstream.body.data ? upstream.body.data : "", upstream.body.len); buffer_free(&upstream.body); return;
    }
    if (!strncmp(path, "/hls/", 5)) {
        HlsTarget target; Session session;
        if (copy_hls_target_session(path + 5, &target, &session) != 0) { send_response(fd, method, 404, NULL, NULL, "not found\n", 10); return; }
        char origin[512]; ParsedUrl pu; parse_url(session.page_url, &pu); snprintf(origin, sizeof(origin), "%s://%s", pu.scheme, pu.host); HttpResponse upstream;
        if (curl_fetch(target.url, method, session.page_url, origin, MAX_PLAYLIST_BYTES, 1, &upstream) != 0) { send_response(fd, method, 502, NULL, NULL, "upstream failed\n", 17); return; }
        int playlist = strstr(upstream.content_type, "mpegurl") || strstr(upstream.content_type, "m3u8") || strstr(target.url, ".m3u8");
        if (playlist && strcasecmp(method, "HEAD")) {
            char *rewritten = malloc(MAX_PLAYLIST_BYTES + 1);
            if (!rewritten) { buffer_free(&upstream.body); send_response(fd, method, 503, NULL, NULL, "playlist memory unavailable\n", 28); return; }
            if (rewrite_playlist(upstream.body.data ? upstream.body.data : "", upstream.body.len, target.url, session.token, rewritten, MAX_PLAYLIST_BYTES + 1) != 0) { free(rewritten); buffer_free(&upstream.body); send_response(fd, method, 502, NULL, NULL, "playlist rejected\n", 19); return; }
            buffer_free(&upstream.body); send_response(fd, method, upstream.status ? upstream.status : 200, "application/vnd.apple.mpegurl", NULL, rewritten, strlen(rewritten)); free(rewritten); return;
        }
        send_response(fd, method, upstream.status ? upstream.status : 502, upstream.content_type[0] ? upstream.content_type : "application/octet-stream", NULL, upstream.body.data ? upstream.body.data : "", upstream.body.len); buffer_free(&upstream.body); return;
    }
    send_response(fd, method, 404, NULL, NULL, "not found\n", 10);
}
int self_test(void) {
    unsigned char out[32]; size_t n = 0; if (b64_decode("SGVsbG8=", STANDARD_ALPHABET, out, sizeof(out), &n) != 0 || n != 5 || memcmp(out, "Hello", 5)) return 1;
    if (!safe_input_url("https://m.345iptv.com/?act=play") || safe_input_url("https://345iptv.com.evil.example/")) return 2;
    const char *html = "var uhzoe=\"\";var srpjk=\"10\"+\"4\"+\"909d1\"+\"5\"+\"2f0\"+\"e8fc\".split(\"\").reverse().join(\"\")+\"4c\".split(\"\").reverse().join(\"\")+\"19d\".split(\"\").reverse().join(\"\")+\"6c\".split(\"\").reverse().join(\"\")+\"aabf2\".split(\"\").reverse().join(\"\")+\"86\".split(\"\").reverse().join(\"\")+\"e6\".split(\"\").reverse().join(\"\");uhzoe=srpjk;var hckat=\"replacement\";function lbmwh(str,key){key=key+\"b7f48074af034275\";}function avflx(v){v=v.replace(\"token=\"+xitbm,\"token=\"+hckat);}";
    DecoderConfig c;
    parse_config(html, &c);
    if (!c.key[0] || strcmp(c.suffix, "b7f48074af034275")) return 3;
    DecoderConfig sample = {0};
    snprintf(sample.key, sizeof(sample.key), "%s", "104909d152f0cf8ec4d91c62fbaa686e");
    snprintf(sample.suffix, sizeof(sample.suffix), "%s", "b7f48074af034275");
    snprintf(sample.token, sizeof(sample.token), "%s", "3bd83085cd0be3ce6ff5f93567a4a2c2");
    snprintf(sample.replacement, sizeof(sample.replacement), "%s", "Mq1%2FEvLIi%2FZWMGNMKRG2GkBb104909d152f0cf8ec4d91c62fbaa686e");
    snprintf(sample.alphabet, sizeof(sample.alphabet), "%s", STANDARD_ALPHABET);
    const char *encoded = "=QQW15CX5hQKIZldvFkP6R1VFQ3aFVGX+pUfLwCXlRWYH8zYs8RXSxGU48APAMWUoNUMZpjEpRlOBEgd4t0A9pGU6RWYAFGAVVkYVFzQfd3WB1wb7YBdLoXFYB1PHd3J8BUP8dgEUtwLH91S5dQKxNVCmhHU";
    char decoded[MAX_URL];
    int decode_rc = decode_line(encoded, &sample, decoded, sizeof(decoded));
    if (decode_rc != 0 || strcmp(decoded, "https://p.iptv200.com/play.php?token=Mq1%2FEvLIi%2FZWMGNMKRG2GkBb&tid=gt&id=1&p=0&type=.flv")) {
        fprintf(stderr, "decoder regression failed rc=%d output=%s\n", decode_rc, decoded);
        return 4;
    }
    ParsedUrl parsed;
    char joined[MAX_URL];
    if (parse_url("https://t42.iptv200.com:8443/live/nowxw.flv?sign=x", &parsed) != 0 || parsed.port != 8443 || strcmp(parsed.path, "/live/nowxw.flv")) return 5;
    if (join_url("https://t42.iptv200.com:8443/live/nowxw.flv?sign=x", "chunk.flv", joined, sizeof(joined)) != 0 || strcmp(joined, "https://t42.iptv200.com:8443/live/chunk.flv")) return 6;
    printf("self-test: base64, URL policy, decoder config and line passed (key=%s)\n", c.key);
    return 0;
}
