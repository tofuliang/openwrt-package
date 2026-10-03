#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

export STATE_DIR="$tmpdir/state"
export MULTIWAN_LOCK_DIR="$tmpdir/lock"
export PATH="$tmpdir/bin:$PATH"
mkdir -p "$STATE_DIR" "$tmpdir/bin"

cat > "$tmpdir/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmpdir/bin/flock"

# shellcheck source=../lib/multiwan_common.sh
. "$repo_root/lib/multiwan_common.sh"

log() { :; }
sleep() { :; }
ubus() { printf '%s\n' '{}'; }
jsonfilter() {
    case "$*" in
        *'@.up'*) printf '%s\n' true ;;
        *'@.l3_device'*) printf '%s\n' pppoe-iptv ;;
        *'ptpaddress'*) printf '%s\n' 10.152.176.1 ;;
    esac
}
ip() {
    printf '%s\n' "$*" >> "$tmpdir/ip.calls"
    return 0
}

setup_route iptv 300

grep -Fx 'route replace default via 10.152.176.1 dev pppoe-iptv table 300' "$tmpdir/ip.calls"
printf '%s\n' 'setup_route installs IPTV policy-table default route'
