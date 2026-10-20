#include "proxy.h"
int is_scheme(const char *s) { return !strncasecmp(s, "http://", 7) || !strncasecmp(s, "https://", 8); }
int parse_url(const char *url, ParsedUrl *u) {
    if (!url || !u) return -1;
    memset(u, 0, sizeof(*u));
    const char *scheme_end = strstr(url, "://");
    if (!scheme_end) return -1;
    size_t scheme_len = (size_t)(scheme_end - url);
    if (scheme_len >= sizeof(u->scheme)) return -1;
    memcpy(u->scheme, url, scheme_len);
    u->scheme[scheme_len] = 0;
    if (strcasecmp(u->scheme, "http") && strcasecmp(u->scheme, "https")) return -1;
    const char *authority = scheme_end + 3;
    const char *authority_end = strpbrk(authority, "/?#");
    if (!authority_end) authority_end = authority + strlen(authority);
    if (authority == authority_end || memchr(authority, '@', (size_t)(authority_end - authority))) return -1;
    const char *colon = memchr(authority, ':', (size_t)(authority_end - authority));
    size_t host_len = colon ? (size_t)(colon - authority) : (size_t)(authority_end - authority);
    if (host_len == 0 || host_len >= sizeof(u->host)) return -1;
    memcpy(u->host, authority, host_len);
    u->host[host_len] = 0;
    u->port = !strcasecmp(u->scheme, "https") ? 443 : 80;
    if (colon) {
        char *end = NULL;
        long port = strtol(colon + 1, &end, 10);
        if (end != authority_end || port < 1 || port > 65535) return -1;
        u->port = (int)port;
    }
    if (*authority_end != '/') {
        snprintf(u->path, sizeof(u->path), "/");
    } else {
        const char *path_end = strpbrk(authority_end, "?#");
        size_t path_len = path_end ? (size_t)(path_end - authority_end) : strlen(authority_end);
        if (path_len == 0 || path_len >= sizeof(u->path)) return -1;
        memcpy(u->path, authority_end, path_len);
        u->path[path_len] = 0;
    }
    return 0;
}
static int allowed_345_host(const char *host) {
    size_t n = strlen(host); const char *a = "345iptv.com", *b = "iptv345.com";
    return !strcasecmp(host, a) || (n > strlen(a) && n > strlen(a) + 1 && !strcasecmp(host + n - strlen(a), a) && host[n - strlen(a) - 1] == '.') ||
           !strcasecmp(host, b) || (n > strlen(b) && n > strlen(b) + 1 && !strcasecmp(host + n - strlen(b), b) && host[n - strlen(b) - 1] == '.');
}
static int hex_value(char c) { if (c >= '0' && c <= '9') return c - '0'; if (c >= 'a' && c <= 'f') return c - 'a' + 10; if (c >= 'A' && c <= 'F') return c - 'A' + 10; return -1; }
int url_decode(const char *in, char *out, size_t cap) { size_t j = 0; for (size_t i = 0; in[i]; i++) { unsigned char c = (unsigned char)in[i]; if (c == '%') { int a = hex_value(in[i+1]), b = hex_value(in[i+2]); if (a < 0 || b < 0) return -1; c = (unsigned char)((a << 4) | b); i += 2; } else if (c == '+') c = ' '; if (j + 1 >= cap) return -1; out[j++] = (char)c; } out[j] = 0; return 0; }
static void reverse_copy(const char *in, char *out, size_t cap) { size_t n = strlen(in); if (n >= cap) n = cap - 1; for (size_t i = 0; i < n; i++) out[i] = in[n - 1 - i]; out[n] = 0; }
int b64_decode(const char *data, const char *alphabet, unsigned char *out, size_t cap, size_t *out_len) { size_t n = strlen(data); if (n % 4) return -1; size_t w = 0; char pad = alphabet[64] ? alphabet[64] : '='; for (size_t i = 0; i < n; i += 4) { int v[4]; for (int k = 0; k < 4; k++) { char c = data[i+k]; if (c == pad) v[k] = 64; else { const char *q = strchr(alphabet, c); if (!q || q - alphabet >= 64) return -1; v[k] = (int)(q - alphabet); } } if (v[0] >= 64 || v[1] >= 64 || w + 3 > cap) return -1; out[w++] = (unsigned char)((v[0] << 2) | (v[1] >> 4)); if (v[2] < 64) { out[w++] = (unsigned char)((v[1] << 4) | (v[2] >> 2)); if (v[3] < 64) out[w++] = (unsigned char)((v[2] << 6) | v[3]); } else if (v[3] < 64) return -1; } *out_len = w; return 0; }
char *trim(char *s) { while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n') s++; char *e = s + strlen(s); while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\r' || e[-1] == '\n')) *--e = 0; return s; }
int safe_input_url(const char *url) { ParsedUrl u; if (strpbrk(url, "\r\n\t<>|;'\"") != NULL) return 0; return parse_url(url, &u) == 0 && (u.port == 80 || u.port == 443) && allowed_345_host(u.host); }
int safe_media_url(const char *url, int initial) { ParsedUrl u; if (parse_url(url, &u) != 0) return 0; if (initial) return !strcasecmp(u.host, "p.iptv200.com"); return strchr(u.host, '.') != NULL && strcasecmp(u.host, "localhost") && strcasecmp(u.host, "metadata.google.internal") && strstr(u.host, ".local") == NULL && strstr(u.host, ".internal") == NULL; }
static Variable *find_var(Variable *vars, size_t n, const char *name) { for (size_t i = 0; i < n; i++) if (vars[i].set && vars[i].value && !strcmp(vars[i].name, name)) return &vars[i]; return NULL; }
static Variable *ensure_var(Variable *vars, size_t *n, const char *name) { Variable *v = find_var(vars, *n, name); if (v) return v; if (*n >= proxy_config.max_variables || strlen(name) >= sizeof(vars[0].name)) return NULL; v = &vars[(*n)++]; memset(v, 0, sizeof(*v)); snprintf(v->name, sizeof(v->name), "%s", name); return v; }
static void free_variables(Variable *vars, size_t n) { if (!vars) return; for (size_t i = 0; i < n; i++) free(vars[i].value); free(vars); }
static const char *skip_ws(const char *p) { while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++; return p; }
static int parse_js_string(const char **pp, char *out, size_t cap) {
    const char *p = skip_ws(*pp); if (*p != '"' && *p != '\'') return -1; char q = *p++; size_t n = 0;
    while (*p && *p != q) { char c = *p++; if (c == '\\' && *p) { c = *p++; if (c == 'n') c = '\n'; else if (c == 'r') c = '\r'; else if (c == 't') c = '\t'; } if (n + 1 >= cap) return -1; out[n++] = c; } if (*p != q) return -1; out[n] = 0; *pp = p + 1; return 0;
}
static int parse_expr(const char **pp, Variable *vars, size_t n, char *out, size_t cap, int depth);
static int parse_term(const char **pp, Variable *vars, size_t n, char *out, size_t cap, int depth) {
    if (depth > 16) return -1; const char *p = skip_ws(*pp); size_t used = 0;
    if (*p == '"' || *p == '\'') { if (parse_js_string(&p, out, cap) != 0) return -1; }
    else if (*p == '(') { p++; if (parse_expr(&p, vars, n, out, cap, depth + 1) != 0) return -1; p = skip_ws(p); if (*p != ')') return -1; p++; }
    else { char name[96]; size_t k = 0; if (!(isalpha((unsigned char)*p) || *p == '_' || *p == '$')) return -1; while (isalnum((unsigned char)*p) || *p == '_' || *p == '$') { if (k + 1 >= sizeof(name)) return -1; name[k++] = *p++; } name[k] = 0; Variable *v = find_var(vars, n, name); if (!v || !v->value || snprintf(out, cap, "%s", v->value) >= (int)cap) return -1; }
    p = skip_ws(p);
    if (!strncmp(p, ".split(\"\").reverse().join(\"\")", 29) || !strncmp(p, ".split('\').reverse().join('\')", 27)) { size_t m = strlen(out); for (size_t i = 0; i < m / 2; i++) { char c = out[i]; out[i] = out[m-1-i]; out[m-1-i] = c; } p += p[7] == '"' ? 29 : 27; }
    (void)used; *pp = p; return 0;
}
static int parse_expr(const char **pp, Variable *vars, size_t n, char *out, size_t cap, int depth) {
    char *part = malloc(cap); if (!part) return -1;
    if (parse_term(pp, vars, n, out, cap, depth) != 0) { free(part); return -1; }
    const char *p = skip_ws(*pp);
    while (*p == '+') { p++; if (parse_term(&p, vars, n, part, cap, depth) != 0) { free(part); return -1; } size_t a = strlen(out), b = strlen(part); if (a > cap - b - 1) { free(part); return -1; } memcpy(out+a, part, b+1); p = skip_ws(p); }
    free(part); *pp = p; return 0;
}
static void collect_variables(const char *html, Variable *vars, size_t *n) {
    const char *p = html; for (int pass = 0; pass < 64; pass++) { int changed = 0; p = html;
        while ((p = strchr(p, '=')) != NULL) { if (p > html && (p[-1] == '=' || p[1] == '=' || p[-1] == '!' || p[-1] == '<' || p[-1] == '>')) { p++; continue; }
            const char *q = p; while (q > html && (q[-1] == ' ' || q[-1] == '\t')) q--; while (q > html && (isalnum((unsigned char)q[-1]) || q[-1] == '_' || q[-1] == '$')) q--; if (q == p) { p++; continue; } char name[96]; size_t len = (size_t)(p - q); if (len >= sizeof(name)) { p++; continue; } memcpy(name, q, len); name[len] = 0; Variable *v = ensure_var(vars, n, name); if (!v) { p++; continue; }
            const char *e = p + 1; char *value = calloc(proxy_config.max_variable_value_bytes, 1); if (!value) { p++; continue; } if (parse_expr(&e, vars, *n, value, proxy_config.max_variable_value_bytes, 0) == 0) { size_t value_len = strlen(value); if (!v->set || !v->value || strcmp(v->value, value)) { char *copy = malloc(value_len + 1); if (copy) { memcpy(copy, value, value_len + 1); free(v->value); v->value = copy; v->set = 1; changed = 1; } } } free(value);
            p++;
        }
        if (!changed) break;
    }
}
static void normalize_decoder_key(DecoderConfig *cfg) {
    size_t key_len = strlen(cfg->key), suffix_len = strlen(cfg->suffix);
    if (suffix_len && key_len > suffix_len && !strcmp(cfg->key + key_len - suffix_len, cfg->suffix)) cfg->key[key_len - suffix_len] = 0;
}

static int resolve_name(const char *html, const char *name, char *out, size_t cap, int depth) { if (depth > 16) return -1; const char *p = html; size_t nl = strlen(name); while ((p = strstr(p, name)) != NULL) { if ((p > html && (isalnum((unsigned char)p[-1]) || p[-1] == '_' || p[-1] == '$')) || isalnum((unsigned char)p[nl])) { p += nl; continue; } const char *q = p + nl; while (*q == ' ' || *q == '\t') q++; if (*q != '=') { p += nl; continue; } q++; char value[4096] = ""; size_t used = 0; int ok = 1; while (*q && *q != ';' && *q != '\n') { while (*q == ' ' || *q == '\t') q++; if (*q == '+') q++; while (*q == ' ' || *q == '\t') q++; char part[4096]; if (*q == '"' || *q == '\'') { if (parse_js_string(&q, part, sizeof(part)) != 0) { ok = 0; break; } q = skip_ws(q); if (!strncmp(q, ".split(\"\").reverse().join(\"\")", 29)) { size_t m = strlen(part); for (size_t i = 0; i < m / 2; i++) { char c = part[i]; part[i] = part[m - 1 - i]; part[m - 1 - i] = c; } q += 29; } } else { char ref[96]; size_t r = 0; while ((isalnum((unsigned char)*q) || *q == '_' || *q == '$') && r + 1 < sizeof(ref)) ref[r++] = *q++; ref[r] = 0; if (!*ref || resolve_name(html, ref, part, sizeof(part), depth + 1) != 0) { ok = 0; break; } } size_t m = strlen(part); if (used + m + 1 >= sizeof(value)) { ok = 0; break; } memcpy(value + used, part, m); used += m; value[used] = 0; q = skip_ws(q); if (*q != '+') break; } if (ok && used) { snprintf(out, cap, "%s", value); return 0; } p += nl; } return -1; }
void parse_config(const char *html, DecoderConfig *cfg) {
    memset(cfg, 0, sizeof(*cfg)); snprintf(cfg->alphabet, sizeof(cfg->alphabet), "%s", STANDARD_ALPHABET); snprintf(cfg->suffix, sizeof(cfg->suffix), "%s", DEFAULT_KEY_SUFFIX); snprintf(cfg->token, sizeof(cfg->token), "%s", DEFAULT_TOKEN);
    Variable *vars = calloc(proxy_config.max_variables, sizeof(*vars)); size_t n = 0; if (!vars) return; collect_variables(html, vars, &n);
    const char *p = html; while (p) { const char *qmatch = strstr(p, "key = key"); const char *compact = strstr(p, "key=key"); if (!qmatch || (compact && compact < qmatch)) qmatch = compact; if (!qmatch) break; const char *q = strchr(qmatch, '"'); if (!q) q = strchr(qmatch, '\''); if (q) { char quote = *q++; const char *e = strchr(q, quote); if (e && (size_t)(e-q) < sizeof(cfg->suffix)) { memcpy(cfg->suffix, q, (size_t)(e-q)); cfg->suffix[e-q] = 0; } } p = qmatch + 8; }
    char key_param[96] = ""; char fn[96] = ""; p = html; while ((p = strstr(p, "function ")) != NULL) { const char *q = p + 9; q = skip_ws(q); size_t k = 0; while ((isalnum((unsigned char)*q) || *q == '_' || *q == '$') && k + 1 < sizeof(fn)) fn[k++] = *q++; fn[k] = 0; const char *open = strchr(q, '('), *close = open ? strchr(open, ')') : NULL; if (open && close) { const char *comma = strchr(open, ','); if (comma && comma < close) { const char *r = skip_ws(comma + 1); k = 0; while ((isalnum((unsigned char)*r) || *r == '_' || *r == '$') && k + 1 < sizeof(key_param)) key_param[k++] = *r++; key_param[k] = 0; if (strstr(p, "key = key") || strstr(p, "key=key")) break; } } p += 9; }
    if (!*cfg->key) { const char *scan = html; while ((scan = strstr(scan, ".split(\"\").reverse().join(\"\")")) != NULL) { const char *stmt = scan; while (stmt > html && *stmt != ';' && stmt[-1] != '{') stmt--; while (*stmt == ' ' || *stmt == '\t') stmt++; char v1[96] = ""; size_t z = 0; const char *nm = stmt; while ((isalnum((unsigned char)*nm) || *nm == '_' || *nm == '$') && z + 1 < sizeof(v1)) v1[z++] = *nm++; v1[z] = 0; const char *call = strchr(scan, ';'); if (call) { const char *eq2 = call + 1; while (*eq2 == ' ' || *eq2 == '\t') eq2++; char v2[96] = ""; char fn2[96] = ""; char arg2[96] = ""; char kv[96] = ""; z = 0; while ((isalnum((unsigned char)*eq2) || *eq2 == '_' || *eq2 == '$') && z + 1 < sizeof(v2)) v2[z++] = *eq2++; v2[z] = 0; while (*eq2 == ' ') eq2++; if (*eq2 == '=') { eq2++; while (*eq2 == ' ') eq2++; z = 0; while ((isalnum((unsigned char)*eq2) || *eq2 == '_' || *eq2 == '$') && z + 1 < sizeof(fn2)) fn2[z++] = *eq2++; fn2[z] = 0; if (*eq2 == '(') { eq2++; while (*eq2 == ' ') eq2++; z = 0; while ((isalnum((unsigned char)*eq2) || *eq2 == '_' || *eq2 == '$') && z + 1 < sizeof(arg2)) arg2[z++] = *eq2++; arg2[z] = 0; while (*eq2 == ' ') eq2++; if (*eq2 == ',' && !strcmp(v1, arg2)) { eq2++; while (*eq2 == ' ') eq2++; z = 0; while ((isalnum((unsigned char)*eq2) || *eq2 == '_' || *eq2 == '$') && z + 1 < sizeof(kv)) kv[z++] = *eq2++; kv[z] = 0; if (*kv && !strcmp(v1, v2)) { Variable *v = find_var(vars, n, kv); if (v && strlen(v->value) >= 16) { snprintf(cfg->key, sizeof(cfg->key), "%s", v->value); break; } } } } } } scan += 10; } }
    if (!*cfg->key) { const char *scan = html; while ((scan = strstr(scan, "function ")) != NULL) { const char *name = skip_ws(scan + 9); char fn3[96]; size_t fk = 0; while ((isalnum((unsigned char)*name) || *name == '_' || *name == '$') && fk + 1 < sizeof(fn3)) fn3[fk++] = *name++; fn3[fk] = 0; const char *body = strchr(name, '{'); const char *end = body ? strchr(body, '}') : NULL; if (body && end && (strstr(body, "key = key") || strstr(body, "key=key"))) { char needle[128]; snprintf(needle, sizeof(needle), "%s(", fn3); const char *call = html; while ((call = strstr(call, needle)) != NULL) { const char *a = call + strlen(needle); while (*a == ' ' || *a == '\t') a++; const char *close = strchr(a, ')'); const char *comma = strchr(a, ','); if (comma && close && comma < close) { const char *b = skip_ws(comma + 1); char arg[96]; size_t ak = 0; while ((isalnum((unsigned char)*b) || *b == '_' || *b == '$') && ak + 1 < sizeof(arg)) arg[ak++] = *b++; arg[ak] = 0; Variable *v = find_var(vars, n, arg); if (v && v->set && strlen(v->value) >= 16) { snprintf(cfg->key, sizeof(cfg->key), "%s", v->value); break; } } call += strlen(needle); } } if (*cfg->key) break; scan += 9; } }
    normalize_decoder_key(cfg);
    if (!*cfg->key) { for (size_t i = 0; i < n; i++) if (vars[i].set && strlen(vars[i].value) >= 16 && strspn(vars[i].value, "0123456789abcdefABCDEF") == strlen(vars[i].value)) { snprintf(cfg->key, sizeof(cfg->key), "%s", vars[i].value); break; } }
    p = html; while ((p = strstr(p, "replace(\"token=\"+")) != NULL) { const char *a = strchr(p, '+'); const char *b = strstr(a ? a + 1 : p, "token=\"+"); if (a && b) { a++; b = strchr(b, '+'); if (!b) break; b++; char n1[96], n2[96]; size_t x = 0; while ((isalnum((unsigned char)*a) || *a == '_' || *a == '$') && x + 1 < sizeof(n1)) n1[x++] = *a++; n1[x] = 0; x = 0; while ((isalnum((unsigned char)*b) || *b == '_' || *b == '$') && x + 1 < sizeof(n2)) n2[x++] = *b++; n2[x] = 0; Variable *v1 = find_var(vars, n, n1), *v2 = find_var(vars, n, n2); if (v1) snprintf(cfg->token, sizeof(cfg->token), "%s", v1->value); if (v2) snprintf(cfg->replacement, sizeof(cfg->replacement), "%s", v2->value); if (*cfg->replacement) break; } p += 16; }
    if (!*cfg->replacement) { const char *r = strstr(html, "replace(\"token=\""); if (r) { const char *a = strchr(r, '+'); const char *comma = strchr(r, ','); if (a && comma && a < comma) { a++; char name[96]; size_t x = 0; while ((isalnum((unsigned char)*a) || *a == '_' || *a == '$') && x + 1 < sizeof(name)) name[x++] = *a++; name[x] = 0; if (*name) resolve_name(html, name, cfg->token, sizeof(cfg->token), 0); const char *b = strchr(comma, '+'); if (b) { b++; x = 0; while ((isalnum((unsigned char)*b) || *b == '_' || *b == '$') && x + 1 < sizeof(name)) name[x++] = *b++; name[x] = 0; if (*name) resolve_name(html, name, cfg->replacement, sizeof(cfg->replacement), 0); } } } }
    p = html; while ((p = strstr(p, "keyStr")) != NULL) { const char *q = strchr(p, '='); if (q) { char v[128]; q++; if (parse_js_string(&q, v, sizeof(v)) == 0 && strlen(v) >= 64) snprintf(cfg->alphabet, sizeof(cfg->alphabet), "%s", v); } p++; }
    free_variables(vars, n);
}
int decode_line(const char *encoded, const DecoderConfig *cfg, char *out, size_t cap) {
    if (!encoded || !cfg || !out || cap == 0 || !cfg->key[0]) return -1;
    size_t encoded_len = strlen(encoded);
    if (encoded_len == 0 || encoded_len > MAX_ENCODED_LINE_BYTES || (encoded_len % 4) != 0) return -1;
    size_t decoded_cap = encoded_len / 4 * 3 + 3;
    char *reversed = malloc(encoded_len + 1);
    unsigned char *first = malloc(decoded_cap);
    unsigned char *second = malloc(decoded_cap);
    if (!reversed || !first || !second) { free(reversed); free(first); free(second); return -1; }
    size_t n1 = 0, n2 = 0;
    reverse_copy(encoded, reversed, encoded_len + 1);
    if (b64_decode(reversed, cfg->alphabet, first, decoded_cap, &n1) != 0) goto fail;
    char key[768];
    snprintf(key, sizeof(key), "%s%s", cfg->key, cfg->suffix);
    size_t key_len = strlen(key);
    if (!key_len || n1 > encoded_len) goto fail;
    for (size_t i = 0; i < n1; i++) first[i] ^= (unsigned char)key[i % key_len];
    memcpy(reversed, first, n1);
    reversed[n1] = 0;
    if (b64_decode(reversed, cfg->alphabet, second, decoded_cap, &n2) != 0 || n2 + 1 > cap) goto fail;
    memcpy(out, second, n2);
    out[n2] = 0;
    char marker[1024];
    snprintf(marker, sizeof(marker), "token=%s", cfg->token);
    char replacement[8192];
    snprintf(replacement, sizeof(replacement), "token=%s", cfg->replacement);
    char *m = strstr(out, marker);
    if (m) {
        size_t marker_len = strlen(marker), replacement_len = strlen(replacement), tail = strlen(m + marker_len);
        if ((size_t)(m - out) + replacement_len + tail + 1 >= cap) goto fail;
        memmove(m + replacement_len, m + marker_len, tail + 1);
        memcpy(m, replacement, replacement_len);
    }
    m = strstr(out, cfg->key);
    if (m) memmove(m, m + strlen(cfg->key), strlen(m + strlen(cfg->key)) + 1);
    if (!safe_media_url(out, 1)) goto fail;
    ParsedUrl u;
    if (parse_url(out, &u) != 0) goto fail;
    if (!strcasecmp(u.host, "p.iptv200.com") && !strcmp(u.path, "/play.php") && !strstr(out, "type="))
        strncat(out, strstr(out, "?") ? "&type=.flv" : "?type=.flv", cap - strlen(out) - 1);
    free(reversed); free(first); free(second);
    return 0;
fail:
    free(reversed); free(first); free(second);
    return -1;
}

int choose_media(const char *html, const char *page, const DecoderConfig *cfg, char *media, size_t cap) {
    char *encoded = malloc(MAX_ENCODED_LINE_BYTES);
    if (!encoded) return -1;
    int result = -1;
    for (size_t i = 0; i < 8; i++) {
        if (extract_option_at(html, i, encoded, MAX_ENCODED_LINE_BYTES) != 0) break;
        if (decode_line(encoded, cfg, media, cap) == 0) { result = 0; break; }
    }
    free(encoded);
    (void)page;
    return result;
}
int extract_option_at(const char *html, size_t wanted, char *out, size_t cap) { const char *p = html; size_t index = 0; while ((p = strstr(p, "value=")) != NULL) { p += 6; if (*p != '"' && *p != '\'') continue; char q = *p++; const char *e = strchr(p, q); if (!e) return -1; if (index++ == wanted) { size_t n = (size_t)(e - p); if (n >= cap) return -1; memcpy(out, p, n); out[n] = 0; return 0; } p = e + 1; } return -1; }
