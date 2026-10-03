#!/bin/sh
# 统计 AdGuardHome 查询日志中「最近 N 小时」全部 A 应答 IP 的多 WAN 归属（不抽样）。
#
# 用法: adguard-window-attrib.sh [窗口起点UTC前缀] [排除的客户端IP]
#   缺省窗口起点 = 当前时间 - 24 小时；缺省排除客户端 = 192.168.20.22
#   ADGUARD_QUERYLOG  查询日志路径（默认 /usr/share/adguardhome/data/querylog.json）
#   DNSDEC            解码器路径（默认同目录 dnsdec-all.awk）
#
# 归属判定：策略按 cloudflare → mobile → telecom → china → international 顺序匹配，
# 因此多集合命中时按该顺序落到 route_mobile / route_telecom / route_china / route_international。
set -eu

WINDOW=${1:-}
EXCLUDE=${2:-192.168.20.22}
QL=${ADGUARD_QUERYLOG:-/usr/share/adguardhome/data/querylog.json}
DNSDEC=${DNSDEC:-$(dirname "$0")/dnsdec-all.awk}
NFT_TABLE=multiwan

[ -r "$QL" ] || { echo "无法读取查询日志: $QL" >&2; exit 1; }
[ -r "$DNSDEC" ] || { echo "缺少解码器: $DNSDEC" >&2; exit 1; }

if [ -z "$WINDOW" ]; then
    WINDOW=$(date -u -d "@$(( $(date -u +%s) - 86400 ))" +%Y-%m-%dT%H 2>/dev/null) || {
        echo "无法自动计算窗口起点，请显式传入（如 2026-09-10T07）" >&2; exit 1; }
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/adguard-window.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

START=$(grep -n "\"T\":\"$WINDOW" "$QL" | head -1 | cut -d: -f1); [ -n "$START" ] || START=1
printf '窗口起点 %s（第 %s 行 / 共 %s 行）\n' "$WINDOW" "$START" "$(wc -l < "$QL")"

tail -n +"$START" "$QL" | grep '"QT":"A"' | grep -E '"Answer":"[A-Za-z0-9+/=]{40,}' > "$WORK/cand"
if [ -n "$EXCLUDE" ]; then
    grep -v "\"IP\":\"$EXCLUDE\"" "$WORK/cand" > "$WORK/cand2" || true
    mv "$WORK/cand2" "$WORK/cand"
fi
RECORDS=$(wc -l < "$WORK/cand")
printf '窗口内 A 应答记录: %s（已排除 %s）\n' "$RECORDS" "${EXCLUDE:-无}"

# 单进程解码：域名|base64 → 域名|IP
sed 's/.*"QH":"//; s/".*"Answer":"/|/; s/".*//' "$WORK/cand" | awk -f "$DNSDEC" > "$WORK/pairs"
ANSWERS=$(wc -l < "$WORK/pairs")
printf '解出应答 IP: %s\n' "$ANSWERS"

# nft 区间集合：导出为 起IP-止IP / CIDR / 单IP 三种形式之一
for s in mobile telecom china cloudflare; do
    nft list set inet "$NFT_TABLE" "${s}_destinations" 2>/dev/null \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(-[0-9]{1,3}(\.[0-9]{1,3}){3}|/[0-9]{1,2})?' \
        | sort -u > "$WORK/set_$s.txt"
done

cut -d'|' -f2 "$WORK/pairs" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u > "$WORK/iplist.txt"
awk -F. '{ print $0 "|" $1*16777216 + $2*65536 + $3*256 + $4 }' "$WORK/iplist.txt" \
    | sort -t'|' -k2 -n > "$WORK/ip.sorted"

for s in mobile telecom china cloudflare; do
    awk '
      function num(x,   a) { split(x, a, "."); return a[1]*16777216 + a[2]*65536 + a[3]*256 + a[4] }
      {
        if (index($0, "-") > 0) { split($0, r, "-"); printf "%d|%d\n", num(r[1]), num(r[2]) }
        else if (index($0, "/") > 0) { split($0, c, "/"); st = num(c[1]); printf "%d|%d\n", st, st + 2^(32-c[2]) - 1 }
        else { v = num($0); printf "%d|%d\n", v, v }
      }' "$WORK/set_$s.txt" | sort -t'|' -k1 -n > "$WORK/range_$s.txt"
    awk -F'|' '
      NR == FNR { st[++n] = $1; en[n] = $2; next }
      BEGIN { best = -1 }
      { ip = $2; while (idx < n && st[idx+1] <= ip) { idx++; if (en[idx] > best) best = en[idx] }
        printf "%s|%d\n", $1, (ip <= best ? 1 : 0) }' "$WORK/range_$s.txt" "$WORK/ip.sorted" > "$WORK/hit_$s.txt"
done

# 逐集合累加命中位（mobile,tel,china,cloudflare）
acc="$WORK/hit_mobile.txt"
for s in telecom china cloudflare; do
    awk -F'|' 'NR == FNR { f[$1] = $2; next } { print $1 "|" f[$1] $2 }' "$acc" "$WORK/hit_$s.txt" > "$WORK/acc_$s"
    acc="$WORK/acc_$s"
done
awk -F'|' '{ c = ""; if (substr($2,1,1) == "1") c = c "m"; if (substr($2,2,1) == "1") c = c "t"
             if (substr($2,3,1) == "1") c = c "c"; if (substr($2,4,1) == "1") c = c "f"
             if (c == "") c = "-"; print $1 "|" c }' "$acc" > "$WORK/ipcls.txt"

V6=$(cut -d'|' -f2 "$WORK/pairs" | grep -c ':' || true)
printf '其中 IPv6 应答: %s（本工具只分类 IPv4）\n\n' "${V6:-0}"

echo "== 集合命中明细（按应答 IP 计）=="
awk -F'|' 'NR == FNR { c[$1] = $2; next } { n[c[$2]]++; t++ } END { for (k in n) printf "%s %d %d\n", k, n[k], t }' \
    "$WORK/ipcls.txt" "$WORK/pairs" | sort -k2 -rn \
    | awk '{ printf "  %-4s %6d (%.1f%%)\n", $1, $2, $2*100/$3 }'

echo
echo "== 汇总到出口 =="
awk -F'|' 'NR == FNR { c[$1] = $2; next }
  { k = c[$2]
    if (index(k, "f") || index(k, "m")) b = "vwan2"
    else if (index(k, "t")) b = "wan+vwan1"
    else b = "三线哈希"
    n[b]++; t++ }
  END { for (k in n) printf "%s %d %d\n", k, n[k], t }' "$WORK/ipcls.txt" "$WORK/pairs" \
  | sort -k2 -rn | awk '{ printf "  %-12s %6d (%.1f%%)\n", $1, $2, $2*100/$3 }'
echo "  vwan2 = route_mobile/route_mobile6；wan+vwan1 = route_telecom/route_telecom6；三线哈希 = route_china/route_international"

echo
echo "== 各归属域名样例（按查询次数）=="
awk -F'|' 'NR == FNR { c[$1] = $2; next } { print c[$2] "|" $1 }' "$WORK/ipcls.txt" "$WORK/pairs" | sort | uniq -c | sort -rn > "$WORK/cd"
for cls in tc mtc mc cf f c t -; do
    printf "  [%-3s] " "$cls"
    awk -v C="$cls" '{ split($2, a, "|"); if (a[1] == C) print a[2] }' "$WORK/cd" | head -6 | tr '\n' ' '
    echo
done
echo
echo "== 查询量 top10 域名 → 归属 =="
awk -F'|' 'NR == FNR { c[$1] = $2; next } { print $1 "|" c[$2] }' "$WORK/ipcls.txt" "$WORK/pairs" | sort | uniq -c | sort -rn | head -10 \
  | awk '{ split($2, a, "|"); printf "  %-42s %s\n", a[1], a[2] }'
