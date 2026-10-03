#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

export PATH="$tmpdir/bin:$PATH"
export MULTIWAN_LOCK_DIR="$tmpdir/lock"
mkdir -p "$MULTIWAN_LOCK_DIR" "$tmpdir/bin"

# nft 桩：list table 失败（模拟开机时表尚未加载），其余记录调用
cat > "$tmpdir/bin/nft" <<'EOF'
#!/bin/sh
if [ "$1" = "list" ]; then
    exit 1
fi
printf '%s\n' "$*" >> "$NFT_CALLS"
[ "$1" = "-f" ] && cat "${3:-/dev/null}"
exit 0
EOF
# flock / ip / conntrack 桩
for cmd in flock conntrack ip; do
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$tmpdir/bin/$cmd"
done
chmod +x "$tmpdir/bin/nft" "$tmpdir/bin/flock" "$tmpdir/bin/conntrack" "$tmpdir/bin/ip"
export NFT_CALLS="$tmpdir/nft.calls"
: > "$NFT_CALLS"

# shellcheck source=../lib/multiwan_common.sh
. "$repo_root/lib/multiwan_common.sh"
# 库内写死了 STATE_DIR，测试在其后覆盖
STATE_DIR="$tmpdir/state"
mkdir -p "$STATE_DIR"
log() { printf '%s\n' "$*" >> "$tmpdir/log"; }

printf '%s\n' up > "$STATE_DIR/wan_status"
printf '%s\n' up > "$STATE_DIR/vwan1_status"
printf '%s\n' up > "$STATE_DIR/vwan2_status"

# 1. 策略表未加载：推迟而不是报错，且不写任何策略链
update_global_routing hotplug
[ ! -s "$NFT_CALLS" ]
[ ! -e "$STATE_DIR/routing_state" ]
grep -q 'not loaded yet; deferring policy update' "$tmpdir/log"

# 1b. 表未加载：本机 IPv6 网段刷新直接跳过，不产生 nft 写入
: > "$NFT_CALLS"
update_localnetwork6
[ ! -s "$NFT_CALLS" ]

# 2. PPPoE 源地址暂不可得：重试到成功后返回 0
attempt_file="$tmpdir/attempts"
: > "$attempt_file"
update_special_udp_source() {
    echo x >> "$attempt_file"
    [ "$(wc -l < "$attempt_file")" -ge 3 ]
}
refresh_special_udp_sources
[ "$(wc -l < "$attempt_file")" -ge 3 ]

# 3. 一直不可得：重试次数用尽后返回非零（调用方只告警，不放弃启动）
: > "$attempt_file"
update_special_udp_source() { echo x >> "$attempt_file"; return 1; }
if refresh_special_udp_sources; then
    echo 'refresh_special_udp_sources unexpectedly succeeded' >&2
    exit 1
fi
[ "$(wc -l < "$attempt_file")" -eq 5 ]

printf '%s\n' 'startup defers policy until the table exists and survives undialed PPPoE'
