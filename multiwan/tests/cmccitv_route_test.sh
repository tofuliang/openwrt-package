#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
export STATE_DIR="$tmpdir/state"
export MULTIWAN_LOCK_DIR="$tmpdir/lock"
export CMCC_STATUS="$tmpdir/status.json"
export IP_CALLS="$tmpdir/ip.calls"
export PATH="$tmpdir/bin:$PATH"
mkdir -p "$STATE_DIR" "$MULTIWAN_LOCK_DIR" "$tmpdir/bin"

cat > "$tmpdir/bin/ubus" <<'EOF'
#!/bin/sh
[ "$*" = 'call network.interface.cmccitv status' ] || exit 64
cat "$CMCC_STATUS"
EOF
cat > "$tmpdir/bin/jsonfilter" <<'EOF'
#!/usr/bin/env python3
import json
import sys

status = json.load(sys.stdin)
field = sys.argv[2]
if field == '@.up':
    print(str(status['up']).lower())
elif field == '@.l3_device':
    print(status.get('l3_device', ''))
elif field == '@.inactive.route[@.target="0.0.0.0"&&@.mask=0].nexthop':
    default = [r for r in status.get('inactive', {}).get('route', [])
               if r.get('target') == '0.0.0.0' and r.get('mask') == 0]
    if default:
        print(default[0].get('nexthop', ''))
        raise SystemExit(0)
    raise SystemExit(1)
else:
    raise SystemExit(f'unexpected jsonfilter selector: {field}')
EOF
cat > "$tmpdir/bin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$IP_CALLS"
[ "$*" != 'link show eth2.48' ] || [ "${CMCC_DEVICE_UP:-1}" = 1 ] || exit 1
case "$*" in
    'route replace default via '*' table 500') [ "${CMCC_FAIL_DEFAULT:-0}" = 0 ] ;;
esac
EOF
cat > "$tmpdir/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmpdir/bin/ubus" "$tmpdir/bin/jsonfilter" "$tmpdir/bin/ip" "$tmpdir/bin/flock"

# shellcheck source=../lib/multiwan_common.sh
. "$repo_root/lib/multiwan_common.sh"
STATE_DIR="$tmpdir/state"
log() { :; }

up_status() {
    cat > "$CMCC_STATUS" <<'EOF'
{"up":true,"proto":"dhcp","l3_device":"eth2.48","ipv4-address":[{"address":"10.98.184.164","mask":20}],"route":[],"inactive":{"route":[{"target":"0.0.0.0","mask":0,"nexthop":"10.98.176.1","source":"10.98.184.164/32"}]}}
EOF
}
down_status() { printf '%s\n' '{"up":false,"route":[],"inactive":{"route":[]}}' > "$CMCC_STATUS"; }
assert_calls() {
    diff -u "$1" "$IP_CALLS"
    : > "$IP_CALLS"
}
cat > "$tmpdir/up.expected" <<'EOF'
link show eth2.48
route replace 239.10.0.0/24 dev eth2.48
route replace 239.11.0.0/24 dev eth2.48
route replace 239.20.0.0/24 dev eth2.48
route replace 239.21.0.0/24 dev eth2.48
route replace default via 10.98.176.1 dev eth2.48 table 500
EOF
cat > "$tmpdir/down.expected" <<'EOF'
route replace unreachable default table 500
route replace unreachable 239.10.0.0/24
route replace unreachable 239.11.0.0/24
route replace unreachable 239.20.0.0/24
route replace unreachable 239.21.0.0/24
EOF

: > "$IP_CALLS"
up_status
sync_cmccitv_route
assert_calls "$tmpdir/up.expected"
down_status
sync_cmccitv_route
assert_calls "$tmpdir/down.expected"

# A new up lease must survive a delayed ifdown event: the handler reads ubus
# while holding the same table lock, not the old event's ACTION.
awk -v common="$repo_root/lib/multiwan_common.sh" '
    /^\. \/lib\/multiwan_common\.sh$/ {
        printf ". \"%s\"\nSTATE_DIR=\"%s\"\nlog() { :; }\n", common, ENVIRON["STATE_DIR"]
        next
    }
    { print }
' "$repo_root/etc/hotplug.d/iface/99-multiwan" > "$tmpdir/hotplug.sh"
up_status
(INTERFACE=cmccitv; ACTION=ifdown; . "$tmpdir/hotplug.sh")
assert_calls "$tmpdir/up.expected"
# A delayed ifup worker must not bring back a lease already down.
down_status
(INTERFACE=cmccitv; ACTION=ifup; sleep() { :; }; . "$tmpdir/hotplug.sh"; wait)
assert_calls "$tmpdir/down.expected"
# ifupdate (lease/prefix refresh) must re-read ubus under the same lock.
up_status
(INTERFACE=cmccitv; ACTION=ifupdate; . "$tmpdir/hotplug.sh")
assert_calls "$tmpdir/up.expected"

# An up interface with no advertised DHCP nexthop must not fall back to ARP.
cat > "$CMCC_STATUS" <<'EOF'
{"up":true,"l3_device":"eth2.48","inactive":{"route":[{"target":"0.0.0.0","mask":0}]}}
EOF
sync_cmccitv_route
# Missing gateway short-circuits even the device check.
assert_calls "$tmpdir/down.expected"

# The gateway must come from the 0.0.0.0/0 inactive route even when a
# non-default inactive route precedes it in the netifd array.
cat > "$CMCC_STATUS" <<'EOF'
{"up":true,"l3_device":"eth2.48","inactive":{"route":[{"target":"10.98.0.0/16","mask":16,"nexthop":"10.98.255.1"},{"target":"0.0.0.0","mask":0,"nexthop":"10.98.176.1"}]}}
EOF
sync_cmccitv_route
assert_calls "$tmpdir/up.expected"

# Route installation failure also falls closed (including scoped multicast).
up_status
CMCC_FAIL_DEFAULT=1 sync_cmccitv_route
{ cat "$tmpdir/up.expected"; cat "$tmpdir/down.expected"; } > "$tmpdir/failed.expected"
assert_calls "$tmpdir/failed.expected"

clear_cmccitv_routes
cat > "$tmpdir/clear.expected" <<'EOF'
route replace unreachable default table 500
route replace unreachable 239.10.0.0/24
route replace unreachable 239.11.0.0/24
route replace unreachable 239.20.0.0/24
route replace unreachable 239.21.0.0/24
EOF
assert_calls "$tmpdir/clear.expected"
# Even if an ifup worker started before stop, it must do nothing after stop.
rmdir "$STATE_DIR"
sync_cmccitv_route
[ ! -s "$IP_CALLS" ]
printf '%s\n' 'CMCC IPTV DHCP gateway, scoped IGMP routes, hotplug races and fail-closed teardown'
