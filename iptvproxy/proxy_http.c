#include "proxy.h"
static int append_header(struct curl_slist **list, const char *value) { struct curl_slist *next = curl_slist_append(*list, value); if (!next) { curl_slist_free_all(*list); *list = NULL; return -1; } *list = next; return 0; }
static int buffer_reserve(Buffer *b, size_t extra) {
    if (extra > b->limit || b->len > b->limit - extra) return -1;
    size_t need = b->len + extra + 1;
    if (need <= b->cap) return 0;
    size_t cap = b->cap ? b->cap : 4096;
    while (cap < need) { if (cap > b->limit / 2) { cap = b->limit + 1; break; } cap *= 2; }
    char *p = realloc(b->data, cap);
    if (!p) return -1;
    b->data = p; b->cap = cap; return 0;
}
static size_t write_body(char *ptr, size_t size, size_t nmemb, void *opaque) {
    Buffer *b = opaque; size_t n = size * nmemb;
    if (buffer_reserve(b, n) != 0) return 0;
    memcpy(b->data + b->len, ptr, n); b->len += n; b->data[b->len] = 0; return n;
}
static size_t read_headers(char *ptr, size_t size, size_t nmemb, void *opaque) {
    HttpResponse *r = opaque; size_t n = size * nmemb;
    if (n >= 9 && !strncasecmp(ptr, "Location:", 9)) {
        const char *p = ptr + 9; while (*p == ' ' || *p == '\t') p++;
        size_t m = strcspn(p, "\r\n"); if (m >= sizeof(r->location)) m = sizeof(r->location) - 1;
        memcpy(r->location, p, m); r->location[m] = 0;
    }
    return n;
}
int curl_fetch(const char *url, const char *method, const char *referer, const char *origin, size_t limit, int redirect_mode, HttpResponse *out) {
    if (!out) return -1;
    memset(out, 0, sizeof(*out)); out->body.limit = limit;
    LOGD("http start method=%s url=%s limit=%zu redirect_mode=%d", method, url, limit, redirect_mode);
    char current[MAX_URL];
    snprintf(current, sizeof(current), "%s", url);
    for (int redirect = 0; redirect <= 5; redirect++) {
        CURL *c = curl_easy_init(); if (!c) return -1;
        memset(out, 0, sizeof(*out)); out->body.limit = limit;
        struct curl_slist *headers = NULL;
        if (append_header(&headers, "Cookie: iptvad=1") != 0) { curl_easy_cleanup(c); buffer_free(&out->body); return -1; }
        if (referer && *referer) { char h[MAX_HEADER]; snprintf(h, sizeof(h), "Referer: %s", referer); if (append_header(&headers, h) != 0) { curl_easy_cleanup(c); buffer_free(&out->body); return -1; } }
        if (origin && *origin) { char h[MAX_HEADER]; snprintf(h, sizeof(h), "Origin: %s", origin); if (append_header(&headers, h) != 0) { curl_easy_cleanup(c); buffer_free(&out->body); return -1; } }
        if (append_header(&headers, "Accept-Encoding: identity") != 0) { curl_easy_cleanup(c); buffer_free(&out->body); return -1; }
        curl_easy_setopt(c, CURLOPT_URL, current);
        const char *px = getenv("IPTVPROXY_PROXY"); if (px && *px) { curl_easy_setopt(c, CURLOPT_PROXY, px); curl_easy_setopt(c, CURLOPT_PROXYTYPE, CURLPROXY_HTTP); }
        curl_easy_setopt(c, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
        curl_easy_setopt(c, CURLOPT_USERAGENT, USER_AGENT);
        curl_easy_setopt(c, CURLOPT_HTTPHEADER, headers);
        curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 0L);
        curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 10L);
        curl_easy_setopt(c, CURLOPT_TIMEOUT, redirect_mode == 1 && limit == MAX_PLAYLIST_BYTES ? 0L : 30L); curl_easy_setopt(c, CURLOPT_LOW_SPEED_LIMIT, 1L); curl_easy_setopt(c, CURLOPT_LOW_SPEED_TIME, 20L);
        curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, read_headers);
        curl_easy_setopt(c, CURLOPT_HEADERDATA, out);
        if (!strcasecmp(method, "HEAD")) { curl_easy_setopt(c, CURLOPT_NOBODY, 1L); }
        else { curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, write_body); curl_easy_setopt(c, CURLOPT_WRITEDATA, &out->body); }
        CURLcode rc = curl_easy_perform(c);
        long status = 0; curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status); out->status = (int)status;
        LOGD("http response method=%s status=%ld curl=%s bytes=%zu location=%s", method, status, curl_easy_strerror(rc), out->body.len, out->location[0] ? out->location : "<none>");
        const char *ct = NULL; curl_easy_getinfo(c, CURLINFO_CONTENT_TYPE, &ct);
        if (ct) snprintf(out->content_type, sizeof(out->content_type), "%s", ct);
        curl_slist_free_all(headers); curl_easy_cleanup(c);
        if (rc != CURLE_OK && !(rc == CURLE_WRITE_ERROR && (limit == 1 || limit == MAX_PLAYLIST_BYTES) && out->status >= 200 && out->status < 400)) { LOGW("http failed method=%s status=%d curl=%s", method, out->status, curl_easy_strerror(rc)); buffer_free(&out->body); return -1; }
        if (out->status < 300 || out->status >= 400 || !out->location[0]) { snprintf(out->location, sizeof(out->location), "%s", current); return 0; }
        char next[MAX_URL];
        if (redirect == 5 || join_url(current, out->location, next, sizeof(next)) != 0) { buffer_free(&out->body); return -1; }
        LOGD("http redirect %d from=%s to=%s", redirect + 1, current, next);
        if ((redirect_mode == 0 && !safe_input_url(next)) || (redirect_mode == 1 && !safe_media_url(next, 0))) { buffer_free(&out->body); return -1; }
        snprintf(current, sizeof(current), "%s", next);
        buffer_free(&out->body);
    }
    return -1;
}

int fetch_session_media(Session *s, const char *method, const char *referer, const char *origin, HttpResponse *out) {
    if (curl_fetch(s->media_url, method, referer, origin, MAX_PLAYLIST_BYTES, 1, out) == 0 && out->status < 400) return 0;
    buffer_free(&out->body);
    HttpResponse page = {0};
    if (curl_fetch(s->page_url, "GET", NULL, NULL, MAX_PAGE_BYTES, 0, &page) != 0 || page.status < 200 || page.status >= 300) {
        buffer_free(&page.body);
        return -1;
    }
    DecoderConfig cfg;
    parse_config(page.body.data ? page.body.data : "", &cfg);
    char *encoded = malloc(MAX_ENCODED_LINE_BYTES);
    char *candidate = malloc(MAX_URL);
    char (*tried)[MAX_URL] = calloc(8, sizeof(*tried));
    if (!encoded || !candidate || !tried) {
        free(encoded); free(candidate); free(tried);
        buffer_free(&page.body);
        return -1;
    }
    size_t tried_n = 0;
    snprintf(tried[tried_n++], MAX_URL, "%s", s->media_url);
    for (size_t i = 0; i < 8; i++) {
        if (extract_option_at(page.body.data ? page.body.data : "", i, encoded, MAX_ENCODED_LINE_BYTES) != 0) break;
        if (decode_line(encoded, &cfg, candidate, MAX_URL) != 0) continue;
        int seen = 0;
        for (size_t j = 0; j < tried_n; j++) if (!strcmp(tried[j], candidate)) { seen = 1; break; }
        if (seen) continue;
        if (tried_n < 8) snprintf(tried[tried_n++], MAX_URL, "%s", candidate);
        if (curl_fetch(candidate, method, referer, origin, MAX_PLAYLIST_BYTES, 1, out) == 0 && out->status < 400) {
            snprintf(s->media_url, sizeof(s->media_url), "%s", out->location[0] ? out->location : candidate);
            free(encoded); free(candidate); free(tried);
            buffer_free(&page.body);
            return 0;
        }
        buffer_free(&out->body);
    }
    free(encoded); free(candidate); free(tried);
    buffer_free(&page.body);
    return -1;
}
static int refresh_stream_media(Session *s) {
    HttpResponse page = {0};
    if (curl_fetch(s->page_url, "GET", NULL, NULL, MAX_PAGE_BYTES, 0, &page) != 0 || page.status < 200 || page.status >= 300) {
        LOGW("stream media refresh page failed status=%d", page.status);
        buffer_free(&page.body);
        return -1;
    }
    DecoderConfig cfg;
    parse_config(page.body.data ? page.body.data : "", &cfg);
    char *encoded = malloc(MAX_ENCODED_LINE_BYTES);
    char candidate[MAX_URL];
    if (!encoded) { buffer_free(&page.body); return -1; }
    int result = -1;
    for (size_t i = 0; i < 8; i++) {
        if (extract_option_at(page.body.data ? page.body.data : "", i, encoded, MAX_ENCODED_LINE_BYTES) != 0) break;
        if (decode_line(encoded, &cfg, candidate, sizeof(candidate)) != 0 || !strcmp(candidate, s->media_url) || strstr(candidate, ".m3u8")) continue;
        snprintf(s->media_url, sizeof(s->media_url), "%s", candidate);
        LOGI("stream media refreshed url=%s", s->media_url);
        result = 0;
        break;
    }
    free(encoded);
    buffer_free(&page.body);
    if (result != 0) LOGW("stream media refresh found no alternate candidate");
    return result;
}
typedef struct { int fd; CURL *curl; long status; int discard; int sent; int client_closed; size_t bytes; char content_type[128]; char location[MAX_URL]; } StreamContext;
static int send_all_checked(int fd, const void *buf, size_t len) { const char *p = buf; while (len) { ssize_t n = send(fd, p, len, MSG_NOSIGNAL); if (n <= 0) return -1; p += n; len -= (size_t)n; } return 0; }
static void stream_send_headers(StreamContext *ctx) { if (ctx->sent || ctx->discard) return; const char *text = ctx->status == 206 ? "Partial Content" : "OK"; char h[512]; int n = snprintf(h, sizeof(h), "HTTP/1.1 %ld %s\r\nContent-Type: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n", ctx->status >= 200 ? ctx->status : 200, text, ctx->content_type[0] ? ctx->content_type : "application/octet-stream"); if (send_all_checked(ctx->fd, h, (size_t)n) == 0) { ctx->sent = 1; LOGI("stream opened status=%ld content_type=%s", ctx->status, ctx->content_type[0] ? ctx->content_type : "application/octet-stream"); } }
static size_t stream_headers(char *ptr, size_t size, size_t nmemb, void *opaque) { StreamContext *ctx = opaque; size_t n = size * nmemb; curl_easy_getinfo(ctx->curl, CURLINFO_RESPONSE_CODE, &ctx->status); if (n >= 9 && !strncasecmp(ptr, "Location:", 9)) { const char *p = ptr + 9; while (*p == ' ' || *p == '\t') p++; size_t m = strcspn(p, "\r\n"); if (m >= sizeof(ctx->location)) m = sizeof(ctx->location) - 1; memcpy(ctx->location, p, m); ctx->location[m] = 0; } if (n >= 13 && !strncasecmp(ptr, "Content-Type:", 13)) { const char *p = ptr + 13; while (*p == ' ' || *p == '\t') p++; size_t m = strcspn(p, "\r\n"); if (m >= sizeof(ctx->content_type)) m = sizeof(ctx->content_type) - 1; memcpy(ctx->content_type, p, m); ctx->content_type[m] = 0; } ctx->discard = ctx->status >= 300 || ctx->status < 200; return n; }
static size_t stream_body(char *ptr, size_t size, size_t nmemb, void *opaque) { StreamContext *ctx = opaque; size_t n = size * nmemb; if (ctx->discard) return n; if (!ctx->sent) stream_send_headers(ctx); if (!ctx->sent) return 0; if (send_all_checked(ctx->fd, ptr, n) != 0) { ctx->client_closed = 1; LOGD("stream client closed bytes=%zu", ctx->bytes); return 0; } ctx->bytes += n; return n; }
static int stream_fetch(int fd, const char *url, const char *referer, const char *origin, int header_sent) {
    char current[MAX_URL]; snprintf(current, sizeof(current), "%s", url);
    int failures = 0, redirects = 0;
    for (;;) {
        CURL *c = curl_easy_init(); if (!c) { LOGE("stream curl init failed url=%s", current); return header_sent ? 1 : -1; }
        struct curl_slist *headers = NULL;
        if (append_header(&headers, "Cookie: iptvad=1") != 0) { curl_easy_cleanup(c); return header_sent ? 1 : -1; }
        if (referer && *referer) { char h[MAX_HEADER]; snprintf(h, sizeof(h), "Referer: %s", referer); if (append_header(&headers, h) != 0) { curl_easy_cleanup(c); return header_sent ? 1 : -1; } }
        if (origin && *origin) { char h[MAX_HEADER]; snprintf(h, sizeof(h), "Origin: %s", origin); if (append_header(&headers, h) != 0) { curl_easy_cleanup(c); return header_sent ? 1 : -1; } }
        if (append_header(&headers, "Accept-Encoding: identity") != 0) { curl_easy_cleanup(c); return header_sent ? 1 : -1; }
        StreamContext ctx = { .fd = fd, .curl = c, .sent = header_sent };
        curl_easy_setopt(c, CURLOPT_URL, current); const char *px = getenv("IPTVPROXY_PROXY"); if (px && *px) { curl_easy_setopt(c, CURLOPT_PROXY, px); curl_easy_setopt(c, CURLOPT_PROXYTYPE, CURLPROXY_HTTP); }
        curl_easy_setopt(c, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1); curl_easy_setopt(c, CURLOPT_USERAGENT, USER_AGENT); curl_easy_setopt(c, CURLOPT_HTTPHEADER, headers); curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 0L); curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 10L); curl_easy_setopt(c, CURLOPT_TIMEOUT, 0L); curl_easy_setopt(c, CURLOPT_LOW_SPEED_LIMIT, 1L); curl_easy_setopt(c, CURLOPT_LOW_SPEED_TIME, 20L); curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L); curl_easy_setopt(c, CURLOPT_TCP_KEEPALIVE, 1L); curl_easy_setopt(c, CURLOPT_TCP_KEEPIDLE, 10L); curl_easy_setopt(c, CURLOPT_TCP_KEEPINTVL, 5L); curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, stream_headers); curl_easy_setopt(c, CURLOPT_HEADERDATA, &ctx); curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, stream_body); curl_easy_setopt(c, CURLOPT_WRITEDATA, &ctx);
        CURLcode rc = curl_easy_perform(c); curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &ctx.status); curl_slist_free_all(headers); curl_easy_cleanup(c);
        if (ctx.client_closed) return 0;
        if (ctx.status >= 300 && ctx.status < 400 && ctx.location[0]) { char next[MAX_URL]; if (++redirects > 5 || join_url(current, ctx.location, next, sizeof(next)) != 0 || !safe_media_url(next, 0)) { LOGE("stream redirect rejected status=%ld location=%s", ctx.status, ctx.location); return header_sent ? 1 : -1; } LOGD("stream redirect from=%s to=%s", current, next); snprintf(current, sizeof(current), "%s", next); continue; }
        if (ctx.status >= 200 && ctx.status < 300 && ctx.sent) { header_sent = 1; if (ctx.bytes > 0) failures = 0; failures++; LOGW("upstream disconnected url=%s status=%ld curl=%s bytes=%zu failure=%d", current, ctx.status, curl_easy_strerror(rc), ctx.bytes, failures); if (failures >= 2) return 1; sleep(1); continue; }
        if (header_sent) { failures++; LOGW("upstream unavailable after stream started url=%s status=%ld curl=%s failure=%d", current, ctx.status, curl_easy_strerror(rc), failures); if (failures >= 2) return 1; sleep(1); continue; }
        LOGW("stream upstream failed url=%s status=%ld curl=%s", current, ctx.status, curl_easy_strerror(rc)); return -1;
    }
}
int stream_session_media(int fd, Session *s, const char *referer, const char *origin) { int header_sent = 0; for (int refresh = 0; refresh < 8; refresh++) { int result = stream_fetch(fd, s->media_url, referer, origin, header_sent); if (result == 0) return 0; if (result > 0) { header_sent = 1; LOGW("refreshing stream media after upstream disconnect attempt=%d", refresh + 1); } if (refresh_stream_media(s) == 0) continue; if (!header_sent) return -1; sleep(1); } LOGE("stream media refresh limit reached"); return header_sent ? 0 : -1; }
