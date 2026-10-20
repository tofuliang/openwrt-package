#ifndef IPTVPROXY_PROXY_H
#define IPTVPROXY_PROXY_H

#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <ctype.h>
#include <curl/curl.h>
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_PORT 3450
#define PROXY_MAX_SESSIONS 64u
#define PROXY_MAX_HLS_TARGETS 256u
#define PROXY_MAX_VARIABLES 96u
#define PROXY_MAX_VARIABLE_VALUE_BYTES (16u * 1024u)
#define PROXY_MAX_PAGE_BYTES (2u * 1024u * 1024u)
#define PROXY_MAX_PLAYLIST_BYTES (1u * 1024u * 1024u)
#define MAX_REQUEST 16384
#define MAX_URL 8192
#define MAX_HEADER 4096
#define MAX_ENCODED_LINE_BYTES (256u * 1024u)
#define USER_AGENT "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36"
#define STANDARD_ALPHABET "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
#define DEFAULT_KEY_SUFFIX "e2beebd2e606c2f3"
#define DEFAULT_TOKEN "d4b152364bee806338d52eb1017d2039"
#define DEFAULT_PORT_TEXT "3450"

typedef struct { char *data; size_t len, cap, limit; } Buffer;
typedef struct { int status; char content_type[128]; char location[MAX_URL]; Buffer body; } HttpResponse;
typedef struct { char scheme[8], host[256], path[MAX_URL]; int port; } ParsedUrl;
typedef struct { char name[96]; char *value; int set; } Variable;
typedef struct { char key[512], token[512], replacement[4096], suffix[256], alphabet[128]; } DecoderConfig;
typedef struct { int active; char token[64]; char media_url[MAX_URL]; char page_url[MAX_URL]; time_t expires; } Session;
typedef struct { int active; char token[64], session[64], url[MAX_URL]; time_t expires; } HlsTarget;
typedef enum { LOG_ERROR = 0, LOG_WARN = 1, LOG_INFO = 2, LOG_DEBUG = 3, LOG_TRACE = 4 } LogLevel;

typedef struct {
    size_t session_capacity;
    size_t hls_target_capacity;
    size_t max_variables;
    size_t max_variable_value_bytes;
    size_t page_limit;
    size_t playlist_limit;
} ProxyConfig;

extern ProxyConfig proxy_config;
extern Session *sessions;
extern HlsTarget *hls_targets;
extern unsigned long token_counter;
extern volatile sig_atomic_t stopping;
extern char public_base[1024];
extern LogLevel log_level;
#define MAX_PAGE_BYTES (proxy_config.page_limit)
#define MAX_PLAYLIST_BYTES (proxy_config.playlist_limit)

#define LOGE(...) log_emit(LOG_ERROR, __func__, __VA_ARGS__)
#define LOGW(...) log_emit(LOG_WARN, __func__, __VA_ARGS__)
#define LOGI(...) log_emit(LOG_INFO, __func__, __VA_ARGS__)
#define LOGD(...) log_emit(LOG_DEBUG, __func__, __VA_ARGS__)
#define LOGT(...) log_emit(LOG_TRACE, __func__, __VA_ARGS__)

void log_emit(LogLevel level, const char *function, const char *format, ...);
const char *log_level_name(LogLevel level);
int parse_log_level(const char *text, LogLevel *out);
void on_signal(int sig);
void proxy_configure_profile(void);
int proxy_init_storage(void);
void proxy_free_storage(void);

void buffer_free(Buffer *b);
int is_scheme(const char *s);
int b64_decode(const char *data, const char *alphabet, unsigned char *out, size_t cap, size_t *out_len);
char *trim(char *s);
int safe_input_url(const char *url);
int safe_media_url(const char *url, int initial);
int parse_url(const char *url, ParsedUrl *u);
int join_url(const char *base, const char *ref, char *out, size_t cap);
int url_decode(const char *in, char *out, size_t cap);
void parse_config(const char *html, DecoderConfig *cfg);
int decode_line(const char *encoded, const DecoderConfig *cfg, char *out, size_t cap);
int extract_option_at(const char *html, size_t wanted, char *out, size_t cap);
int choose_media(const char *html, const char *page, const DecoderConfig *cfg, char *media, size_t cap);
int curl_fetch(const char *url, const char *method, const char *referer, const char *origin, size_t limit, int redirect_mode, HttpResponse *out);
int fetch_session_media(Session *s, const char *method, const char *referer, const char *origin, HttpResponse *out);
int stream_session_media(int fd, Session *s, const char *referer, const char *origin);
void handle_client(int fd);
int self_test(void);

#endif
