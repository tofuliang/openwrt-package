#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"
export IP_CALLS="$tmpdir/ip.calls"
export PATH="$tmpdir/bin:$PATH"

cat > "$tmpdir/bin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$IP_CALLS"
EOF
cat > "$tmpdir/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmpdir/bin/ip" "$tmpdir/bin/logger"

hook="$repo_root/etc/hotplug.d/iface/98-iptv-mcast"
: > "$IP_CALLS"
# PPPoE lifecycle events must not change IPoE multicast routes or table 300.
INTERFACE=iptv ACTION=ifup sh "$hook"
INTERFACE=iptv ACTION=ifdown sh "$hook"
INTERFACE=iptvipoe ACTION=ifup sh "$hook"
INTERFACE=iptvipoe ACTION=ifdown sh "$hook"
INTERFACE=iptvipoe ACTION=ifupdate sh "$hook"

cat > "$tmpdir/expected" <<'EOF'
route replace 239.77.0.0/24 dev iptv_ipoe
route replace 239.77.1.0/24 dev iptv_ipoe
route replace 239.253.43.0/24 dev iptv_ipoe
route replace 239.0.10.0/24 dev iptv_ipoe
route del 239.77.0.0/24 dev iptv_ipoe
route del 239.77.1.0/24 dev iptv_ipoe
route del 239.253.43.0/24 dev iptv_ipoe
route del 239.0.10.0/24 dev iptv_ipoe
EOF
diff -u "$tmpdir/expected" "$IP_CALLS"

# Same configured device must be used when deleting after the interface goes down.
: > "$IP_CALLS"
INTERFACE=iptvipoe ACTION=ifup IPTV_MCAST_IFACE=other_ipoe \
    IPTV_MCAST_NETS=239.77.0.0/24 sh "$hook"
INTERFACE=iptvipoe ACTION=ifdown IPTV_MCAST_IFACE=other_ipoe \
    IPTV_MCAST_NETS=239.77.0.0/24 sh "$hook"
cat > "$tmpdir/expected" <<'EOF'
route replace 239.77.0.0/24 dev other_ipoe
route del 239.77.0.0/24 dev other_ipoe
EOF
diff -u "$tmpdir/expected" "$IP_CALLS"
printf '%s\n' 'IPTV multicast routes follow IPoE only; PPPoE unicast is untouched'
