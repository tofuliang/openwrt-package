#!/usr/bin/env bash
# Exercise the actual multiwan nft hooks with packets, without touching the host ruleset.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
for command in ip nft python3; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'SKIP: %s is required for the nft namespace test\n' "$command"
        exit 0
    fi
done

router="mwrouter$$"
sender="mwsender$$"
cleanup() {
    ip netns del "$sender" >/dev/null 2>&1 || :
    ip netns del "$router" >/dev/null 2>&1 || :
}
trap cleanup EXIT
if ! ip netns add "$router" 2>/dev/null; then
    printf 'SKIP: network namespaces are unavailable\n'
    exit 0
fi
if ! ip netns add "$sender" 2>/dev/null; then
    printf 'SKIP: network namespaces are unavailable\n'
    exit 0
fi

ip -n "$router" link set lo up
ip -n "$sender" link set lo up
for spec in 'WG0 wgpeer 198.51.100.1 198.51.100.2' \
            'apifox appeer 198.51.101.1 198.51.101.2' \
            'lan0 lanpeer 198.51.102.1 198.51.102.2'; do
    read -r iface peer gateway client <<< "$spec"
    ip -n "$router" link add "$iface" type veth peer name "$peer"
    ip -n "$router" link set "$peer" netns "$sender"
    ip -n "$router" addr add "$gateway/24" dev "$iface"
    ip -n "$sender" addr add "$client/24" dev "$peer"
    ip -n "$router" link set "$iface" up
    ip -n "$sender" link set "$peer" up
done
ip -n "$sender" addr add 192.168.1.153/32 dev wgpeer
ip netns exec "$router" nft -f "$repo_root/etc/multiwan/multiwan.nft"

# Reset the OUTPUT mark on looped-back packets to prove prerouting itself
# classifies them; ordinary forwarded packets are left untouched.
ip netns exec "$router" nft -f - <<'EOF'
table inet cmcc_probe {
    counter cmcc { }
    counter legacy { }
    counter forced { }
    counter untouched { }
    chain clear_loopback {
        type filter hook prerouting priority dstnat + 4; policy accept;
        iifname "lo" meta mark set 0
    }
    chain observe {
        type filter hook prerouting priority dstnat + 6; policy accept;
        ip daddr != { 183.235.16.92, 183.235.162.80, 183.235.162.81, 10.10.10.10 } return
        meta mark 0x00050000 counter name cmcc
        meta mark 0x00030000 counter name legacy
        meta mark 0x00010000 counter name forced
        meta mark 0 counter name untouched
    }
}
EOF

count() {
    ip netns exec "$router" nft -j list counter inet cmcc_probe "$1" |
        python3 -c 'import json,sys; print(next(item["counter"]["packets"] for item in json.load(sys.stdin)["nftables"] if "counter" in item))'
}

# One TCP SYN traverses prerouting even if the router has no route to the
# public destination; no live catalog/replay endpoint is contacted.
send_syn() {
    local ns=$1 destination=$2 port=$3 source=${4:-}
    ip netns exec "$ns" python3 -c '
import socket, sys
sock = socket.socket()
sock.settimeout(0.05)
if sys.argv[3]:
    sock.bind((sys.argv[3], 0))
try:
    sock.connect((sys.argv[1], int(sys.argv[2])))
except OSError:
    pass
finally:
    sock.close()
' "$destination" "$port" "$source"
}

expect_packet() {
    local expected=$1 ns=$2 destination=$3 port=$4 source=${5:-} mark before after
    local -A previous=()
    for mark in cmcc legacy forced untouched; do previous[$mark]=$(count "$mark"); done
    send_syn "$ns" "$destination" "$port" "$source"
    for mark in cmcc legacy forced untouched; do
        before=${previous[$mark]}
        after=$(count "$mark")
        if [[ "$mark" = "$expected" ]]; then
            (( after == before + 1 )) || { printf 'FAIL: %s expected %s mark (%s -> %s)\n' "$destination:$port" "$mark" "$before" "$after" >&2; exit 1; }
        else
            (( after == before )) || { printf 'FAIL: %s unexpectedly got %s mark\n' "$destination:$port" "$mark" >&2; exit 1; }
        fi
    done
}

ip -n "$sender" route replace default via 198.51.100.1 dev wgpeer
expect_packet cmcc "$sender" 183.235.16.92 8081
expect_packet cmcc "$sender" 183.235.16.92 8082
expect_packet cmcc "$sender" 183.235.162.80 6610

# A single set owns service tuples: adding a host/port works immediately,
# while cross-pairing a listed IP with another service's port must not match.
expect_packet untouched "$sender" 183.235.16.92 6610
expect_packet untouched "$sender" 183.235.162.80 8082
ip netns exec "$router" nft add element inet multiwan cmcc_iptv_services '{ 183.235.162.81 . 6610 }'
expect_packet cmcc "$sender" 183.235.162.81 6610
ip netns exec "$router" nft delete element inet multiwan cmcc_iptv_services '{ 183.235.162.81 . 6610 }'
ip -n "$sender" route replace default via 198.51.101.1 dev appeer
expect_packet cmcc "$sender" 183.235.16.92 8081
expect_packet cmcc "$sender" 183.235.162.80 6610

# @iptv still routes non-CMCC ports and the Telecom TVBOX to table 300.
ip netns exec "$router" nft add element inet multiwan iptv '{ 183.235.16.92 }'
expect_packet legacy "$sender" 183.235.16.92 8083
ip -n "$sender" route replace default via 198.51.100.1 dev wgpeer
expect_packet legacy "$sender" 183.235.16.92 8081 192.168.1.153
expect_packet cmcc "$sender" 183.235.16.92 8081

# Explicit destination policy takes precedence over both CMCC and @iptv.
ip netns exec "$router" nft add element inet multiwan force_wan '{ 183.235.16.92 }'
expect_packet forced "$sender" 183.235.16.92 8082
ip netns exec "$router" nft delete element inet multiwan force_wan '{ 183.235.16.92 }'

ip -n "$sender" route replace default via 198.51.102.1 dev lanpeer
expect_packet cmcc "$sender" 183.235.162.80 6610

# Local destinations retain their exclusion even if explicitly forced.
ip netns exec "$router" nft add element inet multiwan force_wan '{ 10.10.10.10 }'
expect_packet untouched "$sender" 10.10.10.10 8081

# A locally emitted loopback packet is cleared before the prerouting hook.
ip -n "$router" route add 183.235.162.80/32 dev lo
expect_packet cmcc "$router" 183.235.162.80 6610
printf 'CMCC nft forwarding classification and policy precedence passed\n'
