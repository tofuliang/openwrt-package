# 批量解码 AdGuard 查询日志：输入 "域名|base64应答"，输出 "域名|IP"（A/AAAA）
# 单进程完成 base64 解码 + DNS 报文解析（压缩指针、RR 头 10 字节）
BEGIN {
    B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for (i = 1; i <= 64; i++) VAL[substr(B64, i, 1)] = i - 1
    for (i = 0; i < 256; i++) ORD[sprintf("%c", i)] = i
}
function b64dec(s,   i, ch, v, acc, n, out) {
    acc = 0; n = 0; out = ""
    gsub(/=+$/, "", s)
    for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (!(ch in VAL)) continue
        acc = acc * 64 + VAL[ch]
        if (++n == 4) {
            out = out sprintf("%c%c%c", int(acc / 65536) % 256, int(acc / 256) % 256, acc % 256)
            acc = 0; n = 0
        }
    }
    if (n == 3) {
        acc *= 4
        out = out sprintf("%c%c", int(acc / 65536) % 256, int(acc / 256) % 256)
    } else if (n == 2) {
        acc *= 16
        out = out sprintf("%c", int(acc / 65536) % 256)
    }
    return out
}
function rdname(m, p,   len, ptr, resume, s, guard) {
    s = ""; resume = -1; guard = 0
    while (p >= 1 && p <= Mlen && guard++ < 128) {
        len = ORD[substr(m, p, 1)]
        if (len == 0) { p++; break }
        if (int(len / 64) == 3) {
            ptr = (len - 192) * 256 + ORD[substr(m, p + 1, 1)]
            if (resume < 0) resume = p + 2
            p = ptr + 1
            continue
        }
        s = s substr(m, p + 1, len) "."
        p += len + 1
    }
    POS = (resume >= 0) ? resume : p
    return s
}
function b(m, p) { return ORD[substr(m, p, 1)] }
{
    sep = index($0, "|")
    if (sep == 0) next
    dom = substr($0, 1, sep - 1)
    m = b64dec(substr($0, sep + 1))
    Mlen = length(m)
    if (Mlen < 12) next
    qd = b(m, 5) * 256 + b(m, 6)
    an = b(m, 7) * 256 + b(m, 8)
    p = 13
    for (i = 1; i <= qd; i++) { rdname(m, p); p = POS + 4 }
    for (i = 1; i <= an; i++) {
        rdname(m, p); p = POS
        t = b(m, p) * 256 + b(m, p + 1)
        rdlen = b(m, p + 8) * 256 + b(m, p + 9)
        rdp = p + 10
        if (t == 1 && rdlen == 4) {
            printf "%s|%d.%d.%d.%d\n", dom, b(m, rdp), b(m, rdp+1), b(m, rdp+2), b(m, rdp+3)
        } else if (t == 28 && rdlen == 16) {
            s = ""
            for (k = 0; k < 8; k++) s = s sprintf("%x:", b(m, rdp + 2*k) * 256 + b(m, rdp + 2*k + 1))
            printf "%s|%s\n", dom, substr(s, 1, length(s) - 1)
        }
        p = rdp + rdlen
        if (p > Mlen + 1) break
    }
}
