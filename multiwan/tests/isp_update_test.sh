#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

export PATH="$tmpdir/bin:$PATH"
export MULTIWAN_CACHE_ROOT="$tmpdir/cache"
export MULTIWAN_LOCK_DIR="$tmpdir/lock"
export NFT_CALLS="$tmpdir/nft.calls"
mkdir -p "$tmpdir/bin" "$tmpdir/cache/versions/old" "$tmpdir/lock"

cat > "$tmpdir/bin/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NFT_CALLS"
if [ "$1" = '-c' ]; then input="$3"; else input="$2"; fi
cat "$input" >> "$NFT_CALLS"
printf '%s\n' '-- end nft transaction --' >> "$NFT_CALLS"
[ "${NFT_FAIL_APPLY:-0}" = 1 ] && [ "$1" = '-f' ] && exit 1
exit 0
EOF
cat > "$tmpdir/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmpdir/bin/nft" "$tmpdir/bin/flock"

printf '%s\n' old > "$tmpdir/cache/current"
printf '%s\n' 1.1.1.0/24 > "$tmpdir/cache/versions/old/mobile.cidr"
printf '%s\n' 2.2.2.0/24 > "$tmpdir/cache/versions/old/telecom.cidr"
printf '%s\n' 3.3.3.0/24 > "$tmpdir/cache/versions/old/china.cidr"

"$repo_root/usr/sbin/multiwan-isp-update" apply
[ "$(grep -c '^flush set inet multiwan cloudflare_destinations$' "$NFT_CALLS" || true)" -eq 0 ]
mapfile -t calls < <(grep -E '^-c -f |^-f ' "$NFT_CALLS")
[ "${calls[0]}" = "-c -f ${calls[1]#-f }" ]
grep -q '^flush set inet multiwan mobile_destinations$' "$NFT_CALLS"
grep -q '^flush set inet multiwan telecom_destinations$' "$NFT_CALLS"
grep -q '^flush set inet multiwan china_destinations$' "$NFT_CALLS"
[ "$(grep -c '6_destinations$' "$NFT_CALLS" || true)" -eq 0 ]

printf '%s\n' 4.4.4.0/24 > "$tmpdir/cache/versions/old/cloudflare.cidr"
: > "$NFT_CALLS"
"$repo_root/usr/sbin/multiwan-isp-update" apply
[ "$(grep -c '^flush set inet multiwan cloudflare_destinations$' "$NFT_CALLS")" -eq 2 ]
grep -q '^add element inet multiwan cloudflare_destinations { 4.4.4.0/24 }$' "$NFT_CALLS"

cat > "$tmpdir/bin/uclient-fetch" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmpdir/bin/uclient-fetch"
: > "$NFT_CALLS"
if "$repo_root/usr/sbin/multiwan-isp-update" update; then
    echo 'update unexpectedly succeeded after download failure' >&2
    exit 1
fi
[ "$(cat "$tmpdir/cache/current")" = old ]
[ ! -s "$NFT_CALLS" ]

first="$tmpdir/first"
mkdir -p "$first/bin" "$first/fixtures" "$first/lock"
cp "$tmpdir/bin/nft" "$first/bin/nft"
cp "$tmpdir/bin/flock" "$first/bin/flock"
for name in mobile telecom; do for n in $(seq 1 100); do printf '10.0.%d.0/24\n' "$n"; done > "$first/fixtures/$name"; done
for name in mobile6 telecom6; do for n in $(seq 1 20); do printf '2400:%x::/32\n' "$n"; done > "$first/fixtures/$name"; done
for n in $(seq 1 200); do printf '2409:%x::/32\n' "$n"; done > "$first/fixtures/china6"
for n in $(seq 1 6); do printf '2606:4700:%x::/48\n' "$n"; done > "$first/fixtures/cloudflare6"
for n in $(seq 1 1000); do printf '11.%d.0.0/16\n' "$((n % 256))"; done > "$first/fixtures/china"
for n in $(seq 1 10); do printf '12.%d.0.0/16\n' "$n"; done > "$first/fixtures/cloudflare"
cat > "$first/bin/uclient-fetch" <<'EOF'
#!/bin/sh
case "$4" in
  *cmcc_ipv6*) source=mobile6 ;;
  *chinatelecom_ipv6*) source=telecom6 ;;
  *all_cn_ipv6*) source=china6 ;;
  *ips-v6*) source=cloudflare6 ;;
  *cmcc_cidr*) source=mobile ;;
  *chinatelecom_cidr*) source=telecom ;;
  *chnroute*) source=china ;;
  *ips-v4*) source=cloudflare ;;
  *) exit 64 ;;
esac
cp "$FIXTURES/$source" "$3"
EOF
chmod +x "$first/bin/uclient-fetch"
if PATH="$first/bin:$PATH" FIXTURES="$first/fixtures" MULTIWAN_CACHE_ROOT="$first/cache" MULTIWAN_LOCK_DIR="$first/lock" NFT_CALLS="$first/nft.calls" NFT_FAIL_APPLY=1 "$repo_root/usr/sbin/multiwan-isp-update" update; then
    echo 'initial update unexpectedly succeeded after nft failure' >&2
    exit 1
fi
[ ! -e "$first/cache/current" ]

old="$tmpdir/old-failure"
mkdir -p "$old/cache/versions/old" "$old/cache/versions/stale" "$old/lock"
printf '%s\n' old > "$old/cache/current"
for name in mobile telecom china cloudflare; do cp "$first/fixtures/$name" "$old/cache/versions/old/$name.cidr"; done
cp "$first/fixtures/mobile" "$old/cache/versions/stale/mobile.cidr"
: > "$old/nft.calls"
if PATH="$first/bin:$PATH" FIXTURES="$first/fixtures" MULTIWAN_CACHE_ROOT="$old/cache" MULTIWAN_LOCK_DIR="$old/lock" NFT_CALLS="$old/nft.calls" NFT_FAIL_APPLY=1 "$repo_root/usr/sbin/multiwan-isp-update" update; then
    echo 'update unexpectedly succeeded with an existing cache after nft failure' >&2
    exit 1
fi
[ "$(cat "$old/cache/current")" = old ]
[ -d "$old/cache/versions/old" ]
[ "$(find "$old/cache/versions" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 ]

: > "$old/nft.calls"
PATH="$first/bin:$PATH" FIXTURES="$first/fixtures" MULTIWAN_CACHE_ROOT="$old/cache" MULTIWAN_LOCK_DIR="$old/lock" NFT_CALLS="$old/nft.calls" "$repo_root/usr/sbin/multiwan-isp-update" update
new_version=$(cat "$old/cache/current")
[ "$new_version" != old ]
for f in mobile6 telecom6 china6 cloudflare6; do [ -s "$old/cache/versions/$new_version/$f.cidr" ]; done
grep -q '^flush set inet multiwan mobile6_destinations$' "$old/nft.calls"
grep -q '^flush set inet multiwan cloudflare6_destinations$' "$old/nft.calls"
[ -d "$old/cache/versions/$new_version" ]
[ ! -d "$old/cache/versions/old" ]
[ ! -d "$old/cache/versions/stale" ]
[ "$(find "$old/cache/versions" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]

printf '%s\n' 'isp updater keeps only the current CIDR version and removes the first failed update pointer'
