#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

export STATE_DIR="$tmpdir/state"
export PATH="$tmpdir/bin:$PATH"
mkdir -p "$STATE_DIR" "$tmpdir/bin"

cat > "$tmpdir/bin/nft" <<'EOF'
#!/bin/sh
[ "$1" = "-f" ] && [ "$2" = "-" ] || exit 64
cat >> "$NFT_CALLS"
EOF
chmod +x "$tmpdir/bin/nft"
export NFT_CALLS="$tmpdir/nft.calls"

# shellcheck source=../lib/multiwan_common.sh
. "$repo_root/lib/multiwan_common.sh"
log() { :; }

pcc2_wan_vwan='meta mark set jhash ip saddr . ip daddr . meta l4proto . th sport . th dport mod 2 map { 0 : 0x00010000, 1 : 0x00020000 } goto save_mark'
pcc3='meta mark set jhash ip saddr . ip daddr . meta l4proto . th sport . th dport mod 3 map { 0 : 0x00010000, 1 : 0x00020000, 2 : 0x00040000 } goto save_mark'
pcc2_wan_cmcc='meta mark set jhash ip saddr . ip daddr . meta l4proto . th sport . th dport mod 2 map { 0 : 0x00010000, 1 : 0x00040000 } goto save_mark'
pcc2_vwan_cmcc='meta mark set jhash ip saddr . ip daddr . meta l4proto . th sport . th dport mod 2 map { 0 : 0x00020000, 1 : 0x00040000 } goto save_mark'
pcc2_wan_vwan_v6='meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 2 map { 0 : 0x00010000, 1 : 0x00020000 } goto save_mark'
pcc3_v6='meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 3 map { 0 : 0x00010000, 1 : 0x00020000, 2 : 0x00040000 } goto save_mark'
pcc2_wan_cmcc_v6='meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 2 map { 0 : 0x00010000, 1 : 0x00040000 } goto save_mark'
pcc2_vwan_cmcc_v6='meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 2 map { 0 : 0x00020000, 1 : 0x00040000 } goto save_mark'
t6_wan_vwan="$pcc2_wan_vwan_v6"
t6_wan=vwan=''
t6_wan6='meta mark set 0x00010000 goto save_mark'
t6_vwan6='meta mark set 0x00020000 goto save_mark'
t6_cmcc6='meta mark set 0x00040000 goto save_mark'
c6_3="$pcc3_v6"
c6_wan_cmcc="$pcc2_wan_cmcc_v6"
c6_vwan_cmcc="$pcc2_vwan_cmcc_v6"
wan='meta mark set 0x00010000 goto save_mark'
vwan='meta mark set 0x00020000 goto save_mark'
cmcc='meta mark set 0x00040000 goto save_mark'

assert_policy() {
    local state=$1 mobile=$2 telecom=$3 china=$4 international=$5 mobile6=$6 international6=$7 telecom6=$8 china6=$9
    local expected="$tmpdir/$state.expected"

    : > "$NFT_CALLS"
    apply_destination_policy "$state"
    cat > "$expected" <<EOF
flush chain inet multiwan route_mobile
add rule inet multiwan route_mobile $mobile
flush chain inet multiwan route_mobile6
add rule inet multiwan route_mobile6 $mobile6
flush chain inet multiwan route_telecom6
add rule inet multiwan route_telecom6 $telecom6
flush chain inet multiwan route_china6
add rule inet multiwan route_china6 $china6
flush chain inet multiwan route_telecom
add rule inet multiwan route_telecom $telecom
flush chain inet multiwan route_china
add rule inet multiwan route_china $china
flush chain inet multiwan route_international
add rule inet multiwan route_international $international
flush chain inet multiwan route_international6
add rule inet multiwan route_international6 $international6
EOF
    diff -u "$expected" "$NFT_CALLS"
}

assert_policy balanced "$cmcc" "$pcc2_wan_vwan" "$pcc3" "$pcc3" "$cmcc" "$pcc3_v6" "$t6_wan_vwan" "$c6_3"
assert_policy ct_only "$pcc2_wan_vwan" "$pcc2_wan_vwan" "$pcc2_wan_vwan" "$pcc2_wan_vwan" "$pcc2_wan_vwan_v6" "$pcc2_wan_vwan_v6" "$t6_wan_vwan" "$t6_wan_vwan"
assert_policy wan_cmcc "$cmcc" "$wan" "$pcc2_wan_cmcc" "$pcc2_wan_cmcc" "$cmcc" "$pcc2_wan_cmcc_v6" "$t6_wan6" "$c6_wan_cmcc"
assert_policy vwan_cmcc "$cmcc" "$vwan" "$pcc2_vwan_cmcc" "$pcc2_vwan_cmcc" "$cmcc" "$pcc2_vwan_cmcc_v6" "$t6_vwan6" "$c6_vwan_cmcc"
assert_policy wan_only "$wan" "$wan" "$wan" "$wan" "$t6_wan6" "$t6_wan6" "$t6_wan6" "$t6_wan6"
assert_policy vwan_only "$vwan" "$vwan" "$vwan" "$vwan" "$t6_vwan6" "$t6_vwan6" "$t6_vwan6" "$t6_vwan6"
assert_policy cmcc_only "$cmcc" "$cmcc" "$cmcc" "$cmcc" "$t6_cmcc6" "$t6_cmcc6" "$t6_cmcc6" "$t6_cmcc6"

printf '%s\n' 'destination policies hash international, telecom and china traffic for IPv4 and router IPv6'
