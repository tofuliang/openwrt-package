#!/bin/sh
set -eu
bin=${1:?binary required}
port=${IPTVPROXY_SMOKE_PORT:-3457}
IPTVPROXY_BIND="127.0.0.1:${port}" "$bin" >/tmp/iptvproxy-smoke.out 2>/tmp/iptvproxy-smoke.err &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f /tmp/iptvproxy-smoke.out /tmp/iptvproxy-smoke.err /tmp/iptvproxy-smoke-health' EXIT
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS "http://127.0.0.1:${port}/healthz" | grep -qx 'ok'; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ]
code=$(curl -sS -o /tmp/iptvproxy-smoke-health -w '%{http_code}' "http://127.0.0.1:${port}/healthz")
[ "$code" = 200 ]
[ "$(cat /tmp/iptvproxy-smoke-health)" = ok ]
echo "smoke: /healthz HTTP ${code} body=ok"
