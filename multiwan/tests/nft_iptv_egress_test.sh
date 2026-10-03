#!/usr/bin/env bash
# 断言 @iptv 目的地在 prerouting_hook / output_hook 中都能打上 0x00030000，
# 且位置不被"跳过无需处理的流量"规则抢先 —— 修复 WG0/apifox 转发流量与
# 路由器自身流量拿不到 IPTV 标记、落回 main 表默认出口的问题。
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
nft_file="$repo_root/etc/multiwan/multiwan.nft"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -f "$nft_file" ] || fail "缺少 $nft_file"

# 输出指定 chain 的链体（去掉 chain 声明行与 4 空格缩进的收尾大括号）
chain_body() {
    awk -v name="$1" '
        $0 ~ "chain " name " \\{" { inside = 1; next }
        inside && /^    }/ { exit }
        inside { print }
    ' "$nft_file"
}

# 匹配首个固定串的行号（链体内 1 起），无匹配输出空
line_of() {
    printf '%s\n' "$2" | grep -nF -- "$1" | head -n 1 | cut -d: -f1 || true
}

# 所有匹配固定串的行号，可按 < 或 > 过滤
lines_of() {
    printf '%s\n' "$2" | grep -nF -- "$1" | cut -d: -f1 || true
}

first_below() { printf '%s\n' "$1" | awk -v s="$2" '$1 < s' | head -n 1; }
first_above() { printf '%s\n' "$1" | awk -v s="$2" '$1 > s' | head -n 1; }

skip_vpn='iifname { "lo", "apifox", "WG0" } counter return'
lan_iptv='ip daddr @iptv counter meta mark set 0x00030000 goto save_mark'

# --- prerouting_hook：WG0/apifox 转发流量也要命中 IPTV ---
pre=$(chain_body prerouting_hook)
[ -n "$pre" ] || fail "prerouting_hook 链体为空"

pre_skip=$(line_of "$skip_vpn" "$pre")
[ -n "$pre_skip" ] || fail "prerouting_hook 缺少接口跳过规则：$skip_vpn"

pre_early=$(first_below "$(lines_of '@iptv' "$pre")" "$pre_skip")
[ -n "$pre_early" ] || fail "prerouting_hook 中 @iptv 规则全部排在接口跳过规则之后，WG0/apifox 流量拿不到 0x00030000"

pre_early_rule=$(printf '%s\n' "$pre" | sed -n "${pre_early}p")
case $pre_early_rule in
    *'iifname { "lo", "apifox", "WG0" }'*'meta mark set 0x00030000 goto save_mark'*) ;;
    *) fail "prerouting_hook 提前的 @iptv 规则未限定接口或未设 0x00030000：$pre_early_rule" ;;
esac

# LAN 既有路径（跳过规则之后的无条件 @iptv）必须保留，避免改动 br-lan 行为
pre_lan=$(first_above "$(lines_of "$lan_iptv" "$pre")" "$pre_skip")
[ -n "$pre_lan" ] || fail "prerouting_hook 丢失了接口跳过规则之后的无条件 @iptv 规则"

# --- output_hook：路由器自身流量也要命中 IPTV ---
out=$(chain_body output_hook)
[ -n "$out" ] || fail "output_hook 链体为空"

out_iptv=$(line_of "$lan_iptv" "$out")
[ -n "$out_iptv" ] || fail "output_hook 缺少 @iptv 打标规则"

out_icmp=$(line_of 'meta l4proto icmp counter return' "$out")
if [ -n "$out_icmp" ]; then
    [ "$out_iptv" -lt "$out_icmp" ] || fail "@iptv 规则必须排在 ICMP 例外之前"
fi

out_skip=$(line_of 'oifname { "lo", "apifox", "WG0" } counter return' "$out")
if [ -n "$out_skip" ]; then
    [ "$out_iptv" -lt "$out_skip" ] || fail "@iptv 规则必须排在 oifname 跳过规则之前"
fi

out_force=$(line_of 'ip daddr @force_wan counter meta mark set 0x00010000 goto save_mark' "$out")
if [ -n "$out_force" ]; then
    [ "$out_force" -lt "$out_iptv" ] || fail "强制出口规则必须保持在 @iptv 之前（force 优先级最高）"
fi

printf '%s\n' 'IPTV egress marked in prerouting_hook (before interface skip) and output_hook (before ICMP skip)'
