#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

export PATH="$tmpdir/bin:$PATH"
export IP_CALLS="$tmpdir/ip.calls"
export NFT_ACTIVE_ELEMENTS="$tmpdir/nft.active-elements"
mkdir -p "$tmpdir/bin" "$tmpdir/state"
: > "$IP_CALLS"
: > "$NFT_ACTIVE_ELEMENTS"

# Source the production init script with only its absolute dependencies replaced.
: > "$tmpdir/network.stub"
awk -v network="$tmpdir/network.stub" -v common="$repo_root/lib/multiwan_common.sh" '
    /\/lib\/functions\/network\.sh/ {
        printf ". \"%s\"\n", network
        next
    }
    /\/lib\/multiwan_common\.sh/ {
        printf ". \"%s\"\n", common
        next
    }
    { print }
' "$repo_root/etc/init.d/multiwan" > "$tmpdir/multiwan-init.sh"
# shellcheck source=/dev/null
. "$tmpdir/multiwan-init.sh"
STATE_DIR="$tmpdir/state"
MULTIWAN_LOCK_DIR="$tmpdir/lock"
NFT_FILE="$tmpdir/new-rules.nft"
NFT_RESTART_MARKER="$tmpdir/restart-special.pending"
RESTART_SPECIAL_DIR="$tmpdir/restart-special"
mkdir -p "$STATE_DIR" "$MULTIWAN_LOCK_DIR"
printf '%s\n' 'table inet multiwan {}' > "$NFT_FILE"

log() { :; }
setup_route() { :; }
update_special_udp_source() { return 0; }
update_global_routing() { return 0; }
config_load() { :; }
config_foreach() { :; }

# Keep the production policy-rule construction in this smoke test. The rule
# generation must continue to use the high mark bits and mask.
ip() {
    printf '%s\n' "$*" >> "$IP_CALLS"
}
expected_rules="$tmpdir/expected.rules"
cat > "$expected_rules" <<EOF
rule add priority 2001 from all fwmark 0x00010000/0x000f0000 lookup 100
rule add priority 2002 from all fwmark 0x00020000/0x000f0000 lookup 200
rule add priority 2003 from all fwmark 0x00030000/0x000f0000 lookup 300
rule add priority 2004 from all fwmark 0x00040000/0x000f0000 lookup 400
-6 rule add priority 2001 from all fwmark 0x00010000/0x000f0000 lookup 100
-6 rule add priority 2002 from all fwmark 0x00020000/0x000f0000 lookup 200
-6 rule add priority 2003 from all fwmark 0x00030000/0x000f0000 lookup 300
-6 rule add priority 2004 from all fwmark 0x00040000/0x000f0000 lookup 400
EOF
setup_ip_rules
awk '$0 ~ /(^| )rule add /' "$IP_CALLS" > "$tmpdir/current.rules"
diff -u "$expected_rules" "$tmpdir/current.rules"

cat > "$tmpdir/bin/nft" <<'EOF'
#!/bin/sh
if [ "$1" = list ] && [ "$2" = table ]; then
    [ "${NFT_TABLE_PRESENT:-0}" = 1 ] || exit 1
    exit 0
fi
if [ "$1" = list ] && [ "$2" = set ]; then
    [ "${NFT_SET_FAIL:-0}" = 1 ] && exit 1
    [ "$5" = special_udp_wan_51820 ] && cat "$NFT_SET_DUMP"
    exit 0
fi
if [ "$1" = add ] && [ "$2" = element ]; then
    printf '%s %s %s\n' "$5" "$7" "$9" >> "$NFT_ACTIVE_ELEMENTS"
    exit 0
fi
if [ "$1" = -c ] || [ "$1" = -f ]; then
    exit 0
fi
exit 0
EOF
cat > "$tmpdir/bin/sysctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmpdir/bin/nft" "$tmpdir/bin/sysctl"
NFT_SET_DUMP="$tmpdir/nft-set.dump"
export NFT_FILE STATE_DIR NFT_SET_DUMP
cat > "$NFT_SET_DUMP" <<'EOF'
table inet multiwan {
    set special_udp_wan_51820 {
        elements = { 198.51.100.10 . 51820 }
    }
}
EOF

# A failed nft snapshot must not leave a marker or partial restart directory.
rm -rf "$STATE_DIR" "$RESTART_SPECIAL_DIR"
rm -f "$NFT_RESTART_MARKER"
export NFT_TABLE_PRESENT=1 NFT_SET_FAIL=1
stop_service
[ ! -e "$NFT_RESTART_MARKER" ]
[ ! -d "$RESTART_SPECIAL_DIR" ]

# stop/start are separate processes in production, so verify the on-disk
# marker and snapshot carry the dynamic endpoint mapping across the restart.
rm -rf "$STATE_DIR" "$RESTART_SPECIAL_DIR"
rm -f "$NFT_RESTART_MARKER" "$NFT_ACTIVE_ELEMENTS"
: > "$NFT_ACTIVE_ELEMENTS"
export NFT_TABLE_PRESENT=1 NFT_SET_FAIL=0
stop_service
[ -e "$NFT_RESTART_MARKER" ]
[ -s "$RESTART_SPECIAL_DIR/special_udp_wan_51820.elements" ]
grep -qF '198.51.100.10 . 51820' "$RESTART_SPECIAL_DIR/special_udp_wan_51820.elements"

export NFT_TABLE_PRESENT=0
start_service
grep -qF 'special_udp_wan_51820 198.51.100.10 51820' "$NFT_ACTIVE_ELEMENTS"
[ ! -e "$NFT_RESTART_MARKER" ]
[ ! -d "$RESTART_SPECIAL_DIR" ]

printf '%s\n' 'restart snapshot preserves dynamic WireGuard endpoint mappings and high-bit IPv4/IPv6 policy rules'