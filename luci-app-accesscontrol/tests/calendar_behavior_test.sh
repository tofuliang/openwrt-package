#!/bin/sh
# Run with BusyBox ash/flock, ucode with fs, GNU timeout, and tzdata. All state and fixtures are
# private; no UCI, procd, host firewall, or network is changed. The nft boundary
# below models transactional chain replacement and consumes generated epoch
# predicates. A separate privileged smoke test should load batches into nft.

if [ "${ACCESSCONTROL_TEST_ASH:-0}" != 1 ]; then
	command -v busybox >/dev/null 2>&1 || { echo 'BusyBox is required' >&2; exit 1; }
	exec env ACCESSCONTROL_TEST_ASH=1 busybox ash "$0" "$@"
fi
set -u
for executable in ucode timeout cmp; do
	command -v "$executable" >/dev/null 2>&1 || { echo "$executable is required" >&2; exit 1; }
done
busybox flock --help >/dev/null 2>&1 || { echo 'BusyBox flock is required' >&2; exit 1; }
timeout --version >/dev/null 2>&1 || { echo 'GNU coreutils timeout is required' >&2; exit 1; }

package=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
sandbox=$(mktemp -d) || exit 1
trap 'rm -rf "$sandbox"' EXIT INT TERM
mkdir -p "$sandbox/cache" "$sandbox/firewall" "$sandbox/fixtures"
ACCESSCONTROL_CALENDAR_LIB="$package/root/usr/libexec/accesscontrol-calendar.sh"
ACCESSCONTROL_CALENDAR_CACHE="$sandbox/cache"
ACCESSCONTROL_CALENDAR_STATE="$sandbox/state"
ACCESSCONTROL_CALENDAR_STATUS="$sandbox/status"
ACCESSCONTROL_FIREWALL_INCLUDE="$sandbox/include/firewall"
ACCESSCONTROL_CALENDAR_RETRY_INTERVAL=3600
. "$package/root/etc/init.d/accesscontrol"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_equal() { [ "$1" = "$2" ] || fail "$3 (got $1, expected $2)"; }
assert_file_equal() { cmp -s "$1" "$2" || fail "$3"; }
debug_log() { :; }
calendar_log() { printf '%s\n' "$*" >> "$sandbox/messages"; }

# Freeze only the current civil date. All explicit local/UTC conversions still
# use BusyBox date and the real timezone database.
FROZEN_TODAY=2026-03-08
export TZ=Asia/Shanghai
date() {
	if [ "$#" = 1 ] && [ "$1" = '+%Y-%m-%d' ]; then
		printf '%s\n' "$FROZEN_TODAY"
	else
		busybox date "$@"
	fi
}

config_load() { :; }
config_get() {
	local destination="$1" section="$2" option="$3" default="${4:-}" value
	value=$(ucode -e '
		import { readfile } from "fs";
		let config = json(readfile(ARGV[0]));
		let section = null;
		if (ARGV[1] == "global")
			section = config.global;
		else
			for (let i = 0; i < length(config.rules); i++)
				if (config.rules[i].id == ARGV[1]) section = config.rules[i];
		let value = section == null ? "" : section[ARGV[2]];
		if (value === null || value === false) value = ARGV[3];
		printf("%s\n", value);
	' "$sandbox/config.json" "$section" "$option" "$default") || fail 'fixture configuration parsing'
	eval "$destination=\$value"
}
config_foreach() {
	local callback="$1" section
	for section in $(ucode -e '
		import { readfile } from "fs";
		let config = json(readfile(ARGV[0]));
		for (let i = 0; i < length(config.rules); i++) printf("%s\n", config.rules[i].id);
	' "$sandbox/config.json"); do "$callback" "$section"; done
}
uci_validate_section() { config_get enabled global enabled 0; }
procd_open_instance() { printf '%s\n' "$1" >> "$sandbox/workers"; }
procd_set_param() { printf '%s\n' "$*" >> "$sandbox/worker.parameters"; }
procd_close_instance() { :; }

# This isolated stateful backend applies a batch only after accepting its whole
# contents. It preserves ordinary-chain state and can inject an atomic failure.
NFT_FAIL_BATCH=0
NFT_FAIL_ON_BATCH=0
NFT_BATCH_CALLS=0
nft() {
	local operation="$1" chain line stage
	printf '%s\n' "$*" >> "$sandbox/nft.commands"
	if [ "$operation" = '-f' ]; then
		NFT_BATCH_CALLS=$((NFT_BATCH_CALLS + 1))
		printf '%s\n' "$NFT_BATCH_CALLS" >> "$sandbox/batch.attempts"
		[ "$NFT_FAIL_BATCH" = 0 ] && [ "$NFT_BATCH_CALLS" != "$NFT_FAIL_ON_BATCH" ] || return 1
		stage=$(mktemp "$sandbox/firewall/transaction.XXXXXX") || return 1
		while IFS= read -r line; do
			case "$line" in
				'flush chain inet fw4 accesscontrol_calendar') : ;;
				'add rule inet fw4 accesscontrol_calendar '*) printf '%s\n' "$line" >> "$stage" ;;
				*) rm -f "$stage"; fail 'calendar batch touched a chain outside its ownership' ;;
			esac
		done < "$2"
		mv "$stage" "$sandbox/firewall/accesscontrol_calendar"
		return 0
	fi
	[ "$operation" != '-a' ] || { shift; operation="$1"; }
	case "$operation $2" in
		'list table') return 0 ;;
		'list chain')
			chain="$5"
			[ -f "$sandbox/firewall/$chain" ] || return 1
			cat "$sandbox/firewall/$chain"
			;;
		'add chain') : > "$sandbox/firewall/$5" ;;
		'flush chain') : > "$sandbox/firewall/$5" ;;
		'delete chain') rm -f "$sandbox/firewall/$5" ;;
		'add rule'|'insert rule')
			chain="$5"
			if [ "$chain" = forward ]; then
				printf 'counter jump accesscontrol comment "AccessControl Forward" # handle 1\n' >> "$sandbox/firewall/forward"
			else
				printf '%s\n' "$*" >> "$sandbox/firewall/$chain"
			fi
			;;
		'delete rule') : > "$sandbox/firewall/forward" ;;
		*) fail "unhandled isolated nft command: $*" ;;
	esac
}
: > "$sandbox/firewall/forward"

cat > "$sandbox/config.json" <<'EOF'
{"global":{"enabled":"1"},"rules":[
 {"id":"holiday","enabled":"1","respect_holidays":"1","macaddr":"00:11:22:33:44:55","start_time":"22:00","end_time":"06:00","monday":"1","tuesday":"0","wednesday":"0","thursday":"0","friday":"0","saturday":"0","sunday":"0"},
 {"id":"ordinary","enabled":"1","respect_holidays":"0","macaddr":"00:11:22:33:44:66","start_time":"07:00","end_time":"07:30","monday":"1","tuesday":"0","wednesday":"0","thursday":"0","friday":"0","saturday":"0","sunday":"0"}
]}
EOF
cp "$sandbox/config.json" "$sandbox/original-config.json"
cat > "$sandbox/fixtures/2018.json" <<'EOF'
{"year":2018,"days":[{"date":"2018-01-01","isOffDay":true},{"date":"2018-12-29","isOffDay":true}]}
EOF
# Contract fragment from NateScarlet/holiday-cn's 2019.json: the 2019 New Year
# announcement includes the make-up Saturday and two days off in December 2018.
cat > "$sandbox/fixtures/2019.json" <<'EOF'
{"year":2019,"days":[
 {"date":"2018-12-29","isOffDay":false},{"date":"2018-12-30","isOffDay":true},{"date":"2018-12-31","isOffDay":true},
 {"date":"2019-01-01","isOffDay":true},{"date":"2019-02-02","isOffDay":false}
]}
EOF
cat > "$sandbox/fixtures/2025.json" <<'EOF'
{"year":2025,"days":[{"date":"2025-01-01","isOffDay":true}]}
EOF
cat > "$sandbox/fixtures/2026.json" <<'EOF'
{"year":2026,"days":[
 {"date":"2026-01-01","isOffDay":true},{"date":"2026-01-02","isOffDay":true},{"date":"2026-01-03","isOffDay":true},{"date":"2026-01-04","isOffDay":false},
 {"date":"2026-02-14","isOffDay":false},{"date":"2026-02-15","isOffDay":true},{"date":"2026-02-16","isOffDay":true},{"date":"2026-02-17","isOffDay":true},{"date":"2026-02-18","isOffDay":true},{"date":"2026-02-19","isOffDay":true},{"date":"2026-02-20","isOffDay":true},{"date":"2026-02-21","isOffDay":true},{"date":"2026-02-22","isOffDay":true},{"date":"2026-02-23","isOffDay":true},{"date":"2026-02-28","isOffDay":false},
 {"date":"2026-12-31","isOffDay":false}
]}
EOF
cat > "$sandbox/fixtures/2027.json" <<'EOF'
{"year":2027,"days":[
 {"date":"2026-12-31","isOffDay":true},{"date":"2027-01-01","isOffDay":true},{"date":"2027-01-02","isOffDay":true},{"date":"2027-01-03","isOffDay":true}
]}
EOF

replace_config() {
	ucode -e '
		import { readfile } from "fs";
		let config = json(readfile(ARGV[0]));
		'"$1"'
		printf("%.J\n", config);
	' "$sandbox/config.json" > "$sandbox/new-config.json" || fail 'editing fixture configuration'
	mv "$sandbox/new-config.json" "$sandbox/config.json"
}
DOWNLOAD_INVALID=0
DOWNLOAD_NEXT=0
DOWNLOAD_FAIL_CURRENT=0
calendar_download() {
	printf '%s\n' "$1" >> "$sandbox/downloads"
	if [ "$DOWNLOAD_INVALID" = 1 ]; then
		printf '{"year":%s,"days":[{"date":"%s-02-30","isOffDay":true}]}\n' "$1" "$1" > "$2"
	elif [ "$1" = 2026 ] && [ "$DOWNLOAD_FAIL_CURRENT" = 1 ]; then
		return 1
	elif [ "$1" = 2027 ] && [ "$DOWNLOAD_NEXT" = 0 ]; then
		return 1
	else
		cp "$sandbox/fixtures/$1.json" "$2"
	fi
}
calendar_validate_file "$sandbox/fixtures/2019.json" 2019 "$sandbox/2019.days" || fail 'NateScarlet prior-December dates rejected'


# No cache must visibly fall back, then replace only the calendar child chain
# after a real validation/download path has made the year available.
start_service || fail 'initial mixed service start'
assert_equal "$(cat "$ACCESSCONTROL_CALENDAR_STATUS")" unavailable 'missing cache status'
[ ! -f "$sandbox/downloads" ] || fail 'firewall start performed a download'
[ -s "$sandbox/firewall/accesscontrol_calendar" ] || fail 'weekday fallback missing'
assert_equal "$(wc -l < "$sandbox/workers" | tr -d ' ')" 1 'calendar worker declaration'
cp "$sandbox/firewall/accesscontrol" "$sandbox/ordinary.saved" || fail 'saving ordinary chain before refresh'
token=$(cat "$ACCESSCONTROL_CALENDAR_STATE/active")
calendar_fetch_due "$token" "$FROZEN_TODAY" || fail 'current-year fixture fetch'
calendar_refresh "$token" || fail 'switching to validated cached calendar'
assert_equal "$(cat "$ACCESSCONTROL_CALENDAR_STATUS")" ready 'cache transition status'
assert_file_equal "$sandbox/firewall/accesscontrol" "$sandbox/ordinary.saved" 'mixed refresh changed ordinary rules'
assert_equal "$(wc -l < "$sandbox/downloads" | tr -d ' ')" 2 'current and unpublished next-year attempts'
if calendar_fetch_due "$token" "$FROZEN_TODAY"; then fail 'same-day data was fetched twice'; fi
assert_equal "$(wc -l < "$sandbox/downloads" | tr -d ' ')" 2 'same-day request suppression'

# Consume the generated epoch predicates, rather than searching source code or
# merely asserting that a forwarding helper was called.
blocked() {
	local epoch line rule_mac start end
	epoch=$(date -d "$1" +%s) || fail "parsing probe time $1"
	while IFS= read -r line; do
		set -- $line
		[ "$#" -ge 16 ] || continue
		rule_mac="$8"
		[ "$rule_mac" = 00:11:22:33:44:55 ] || continue
		shift 11; start="$1"; shift 4; end="$1"
		[ "$epoch" -ge "$start" ] && [ "$epoch" -lt "$end" ] && return 0
	done < "$sandbox/firewall/accesscontrol_calendar"
	return 1
}
expect_blocked() { blocked "$1" || fail "expected restriction at $1 ($TZ)"; }
expect_open() { if blocked "$1"; then fail "expected release at $1 ($TZ)"; fi; }
build_for() {
	local work
	FROZEN_TODAY="$1"
	replace_config "config.rules[0].start_time=\"$2\"; config.rules[0].end_time=\"$3\";"
	work=$(mktemp -d "$sandbox/build.XXXXXX") || fail 'private batch workspace'
	calendar_build_batch "$FROZEN_TODAY" "$work" || fail 'calendar batch generation'
	nft -f "$work/batch" || fail 'isolated transaction'
	rm -rf "$work"
}
cp "$sandbox/fixtures/2018.json" "$sandbox/cache/2018.json"
cp "$sandbox/fixtures/2019.json" "$sandbox/cache/2019.json"
build_for 2018-12-29 08:00 09:00
assert_equal "$CALENDAR_BUILD_STATUS" ready '2019 announcement fragment was unavailable'
expect_blocked '2018-12-29 08:00:00' # next-year make-up entry overrides the older table
build_for 2018-12-30 08:00 09:00
expect_open '2018-12-30 08:00:00'
expect_open '2018-12-31 08:00:00'
build_for 2018-12-28 22:00 06:00
expect_blocked '2018-12-28 22:00:00' # ending on the make-up Saturday
build_for 2018-12-29 22:00 06:00
expect_open '2018-12-29 22:00:00' # ending on the announced day off


cp "$sandbox/fixtures/2025.json" "$sandbox/cache/2025.json"
build_for 2026-03-06 22:00 06:00
expect_open '2026-03-06 22:00:00'
expect_open '2026-03-07 02:00:00'
build_for 2026-03-07 22:00 06:00
expect_open '2026-03-08 06:00:00'
expect_blocked '2026-03-08 22:00:00' # Sunday was prelaid while still Saturday.
build_for 2026-03-08 22:00 06:00
expect_open '2026-03-08 21:59:59'
expect_blocked '2026-03-08 22:00:00'
expect_blocked '2026-03-09 06:00:59'
expect_open '2026-03-09 06:01:00'
expect_blocked '2026-03-09 22:00:00' # Monday night follows Tuesday despite its stored flag being 0.

build_for 2026-02-14 22:00 06:00
expect_blocked '2026-02-14 05:00:00' # Make-up Saturday, ending on Feb 14.
expect_open '2026-02-14 22:00:00' # Night before the holiday starts.
expect_open '2026-02-15 05:00:00'
build_for 2026-02-23 22:00 06:00
expect_open '2026-02-23 05:00:00'
expect_blocked '2026-02-23 22:00:00' # Final holiday night precedes a workday.
build_for 2026-02-27 22:00 06:00
expect_blocked '2026-02-27 22:00:00' # Make-up Saturday overrides a normal weekend.
expect_blocked '2026-02-28 06:00:59'

build_for 2025-12-31 22:00 06:00
expect_open '2025-12-31 22:00:00'
expect_open '2026-01-01 05:00:00'
build_for 2026-01-03 22:00 06:00
expect_blocked '2026-01-03 22:00:00' # Make-up Sunday Jan 4.
rm -f "$sandbox/cache/2025.json"
build_for 2026-01-01 08:00 09:00
assert_equal "$CALENDAR_BUILD_STATUS" ready 'expired prior-year non-crossing interval forced fallback'


# Minute precision and a single-digit hour. 23:59 includes its final second,
# not the next midnight.
build_for 2026-03-09 6:00 6:00
expect_open '2026-03-09 05:59:59'
expect_blocked '2026-03-09 06:00:00'
expect_blocked '2026-03-09 06:00:59'
expect_open '2026-03-09 06:01:00'
build_for 2026-03-06 23:50 23:59
expect_open '2026-03-06 23:59:59'

# Periods starting at or after 18:00 belong to the day they wake up on: the
# night before a holiday stays open and the last holiday night is restricted.
# Earlier periods still follow the date on which they begin.
build_for 2026-02-14 21:30 22:00
expect_open '2026-02-14 21:30:00'
expect_open '2026-02-14 22:00:59'
build_for 2026-02-23 21:30 22:00
expect_open '2026-02-23 21:29:59'
expect_blocked '2026-02-23 21:30:00'
expect_blocked '2026-02-23 22:00:59'
expect_open '2026-02-23 22:01:00'
build_for 2026-02-23 17:00 18:30
expect_open '2026-02-23 17:00:00'
expect_open '2026-02-23 17:59:59'
expect_blocked '2026-02-23 18:00:00' # the final holiday night precedes a workday
expect_blocked '2026-02-23 18:30:59'
build_for 2026-02-14 17:00 18:30
expect_blocked '2026-02-14 17:59:59' # make-up workday, before the boundary
expect_open '2026-02-14 18:00:00' # the night before the holiday
# The boundary minute itself already belongs to the night, whether a period ends
# there or consists of it alone.
build_for 2026-02-14 17:00 18:00
expect_blocked '2026-02-14 17:59:59'
expect_open '2026-02-14 18:00:00'
build_for 2026-02-23 18:00 18:00
expect_blocked '2026-02-23 18:00:00'
expect_open '2026-02-23 18:01:00'
build_for 2026-02-24 17:00 18:30
expect_blocked '2026-02-24 17:00:00'
expect_blocked '2026-02-24 18:30:59'
expect_open '2026-02-24 18:31:00'
# A period long enough to reach the night of the following day carries a third
# interval, decided by the day after that night.
build_for 2026-02-22 23:00 22:00
expect_open '2026-02-23 10:00:00'
expect_blocked '2026-02-23 18:00:00'
expect_open '2026-02-23 22:01:00'
expect_blocked '2026-02-23 23:00:00'
expect_blocked '2026-02-24 17:59:59'
expect_blocked '2026-02-24 18:00:00'
expect_open '2026-02-24 22:01:00'

export TZ=Asia/Kolkata
build_for 2026-03-08 22:00 06:00
expect_open '2026-03-08 21:59:59'
expect_blocked '2026-03-08 22:00:00'
expect_blocked '2026-03-09 06:00:59'
expect_open '2026-03-09 06:01:00'
# Force the DST-transition Sunday to a make-up workday to exercise a seven-hour
# overnight interval rather than assuming all local days contain 86400 seconds.
ucode -e '
	import { readfile } from "fs";
	let data = json(readfile(ARGV[0]));
	push(data.days, { date: "2026-03-08", isOffDay: false });
	printf("%.J\n", data);
' "$sandbox/fixtures/2026.json" > "$sandbox/cache/2026.json" || fail 'editing DST fixture'
export TZ=America/New_York
build_for 2026-03-07 22:00 06:00
expect_blocked '2026-03-07 22:00:00'
expect_blocked '2026-03-08 06:00:59'
expect_open '2026-03-08 06:01:00'
build_for 2026-03-07 17:00 18:30
expect_open '2026-03-07 17:59:59' # ordinary Saturday before the boundary
expect_blocked '2026-03-07 18:00:00' # the forced make-up Sunday follows
assert_equal "$(calendar_adjacent_date 2026-03-08 -1)" 2026-03-07 'civil day before DST change'
assert_equal "$(calendar_adjacent_date 2026-03-08 1)" 2026-03-09 'civil day after DST change'
cp "$sandbox/fixtures/2026.json" "$sandbox/cache/2026.json"
export TZ=Asia/Shanghai

# December requires both announcement-year tables, even when a daytime period
# never reaches January: the next file may override a December make-up day.
build_for 2026-12-30 22:00 06:00
assert_equal "$CALENDAR_BUILD_STATUS" unavailable 'unknown next-year overnight window'
build_for 2026-12-30 08:00 09:00
assert_equal "$CALENDAR_BUILD_STATUS" unavailable 'missing December override table'
# An evening period reaches into January through its deciding day, so December
# needs the announcement-year table here as well.
build_for 2026-12-31 21:30 22:00
assert_equal "$CALENDAR_BUILD_STATUS" unavailable 'unknown next-year evening window'
cp "$sandbox/cache/2026.json" "$sandbox/calendar.saved.json" || fail 'saving valid cache before failed fetch'
DOWNLOAD_INVALID=1
FROZEN_TODAY=2026-12-31
ACCESSCONTROL_CALENDAR_NOW_EPOCH=1000
if calendar_fetch_due "$token" "$FROZEN_TODAY"; then fail 'invalid data was committed'; fi
assert_file_equal "$sandbox/cache/2026.json" "$sandbox/calendar.saved.json" 'invalid fetch overwrote valid cache'
[ ! -f "$sandbox/cache/2027.json" ] || fail 'unpublished year was cached as known'
requests_after_failure=$(wc -l < "$sandbox/downloads")
ACCESSCONTROL_CALENDAR_NOW_EPOCH=1001
if calendar_fetch_due "$token" "$FROZEN_TODAY"; then fail 'same-hour failed fetch unexpectedly succeeded'; fi
assert_equal "$(wc -l < "$sandbox/downloads")" "$requests_after_failure" 'failed fetch retried before backoff'
ACCESSCONTROL_CALENDAR_NOW_EPOCH=4601
if calendar_fetch_due "$token" "$FROZEN_TODAY"; then fail 'invalid retry unexpectedly succeeded'; fi
assert_equal "$(wc -l < "$sandbox/downloads" | tr -d ' ')" "$((requests_after_failure + 1))" 'retry redownloaded an already valid year'
unset ACCESSCONTROL_CALENDAR_NOW_EPOCH
build_for 2026-12-31 22:00 06:00
assert_equal "$CALENDAR_BUILD_STATUS" unavailable 'cross-year fallback status'
cp "$sandbox/fixtures/2027.json" "$sandbox/cache/2027.json"
build_for 2026-12-31 22:00 06:00
assert_equal "$CALENDAR_BUILD_STATUS" ready 'cross-year validated window'
expect_open '2026-12-31 22:00:00'
expect_open '2027-01-01 05:00:00'
build_for 2026-12-31 08:00 09:00
assert_equal "$CALENDAR_BUILD_STATUS" ready 'December override window status'
expect_open '2026-12-31 08:00:00' # next year's prior-December entry marks it off
build_for 2026-12-31 21:30 22:00
assert_equal "$CALENDAR_BUILD_STATUS" ready 'December evening window status'
expect_open '2026-12-31 21:30:00' # the night before the January holiday


# Exercise structure, boolean, duplicate, real-date and year validation against
# JSON inputs. A source file may carry only its year plus the preceding December.
for invalid in \
	'{"year":2025,"days":[{"date":"2025-01-01","isOffDay":true}]}' \
	'{"year":"2026","days":[{"date":"2026-01-01","isOffDay":true}]}' \
	'{"year":2026,"days":[{"date":"2025-11-30","isOffDay":true}]}' \
	'{"year":2026,"days":[{"date":"2027-01-01","isOffDay":true}]}' \
	'{"year":2026,"days":[{"date":"2024-12-31","isOffDay":true}]}' \
	'{"year":2026,"days":[{"date":"2026-1-01","isOffDay":true}]}' \
	'{"year":2026,"days":[]}' \
	'{"year":2026,"days":[{"date":"2026-02-30","isOffDay":true}]}' \
	'{"year":2026,"days":[{"date":"2026-01-01","isOffDay":"false"}]}' \
	'{"year":2026,"days":[{"date":"2026-01-01","isOffDay":true}]} {"year":2026,"days":[{"date":"2026-01-02","isOffDay":true}]}' \
	'{"year":2026,"days":[{"date":"2026-01-01","isOffDay":true}]} junk' \
	'{"year":2026,"days":[{"date":"2026-01-01","isOffDay":true},{"date":"2026-01-01","isOffDay":false}]}'
do
	printf '%s\n' "$invalid" > "$sandbox/candidate.json"
	if calendar_validate_file "$sandbox/candidate.json" 2026 "$sandbox/candidate.days"; then fail 'invalid JSON calendar accepted'; fi
done

# The numeric year may use an equivalent JSON double, as with the old parser.
printf '%s\n' '{"year":2026.0,"days":[{"date":"2026-01-01","isOffDay":true}]}' > "$sandbox/candidate.json"
calendar_validate_file "$sandbox/candidate.json" 2026 "$sandbox/candidate.days" || fail 'equivalent numeric year rejected'

# Raw TSV must never turn a single JSON date into multiple valid rows. A valid
# first entry also proves the whole structure is checked before any TSV output.
printf '%s\n' '{"year":2026,"days":[{"date":"2026-01-01","isOffDay":true},{"date":"2026-01-02\t1\n2026-01-03","isOffDay":false}]}' > "$sandbox/candidate.json"
if calendar_validate_file "$sandbox/candidate.json" 2026 "$sandbox/candidate.days"; then fail 'date TSV injection accepted'; fi
[ ! -s "$sandbox/candidate.days" ] || fail 'invalid structure emitted partial TSV'

# A failed transaction retains both old chains. A stopped session cannot restore
# rules, even if a pending worker subsequently tries to refresh or download.
FROZEN_TODAY=2026-03-08
calendar_refresh "$token" || fail 'preparing transaction retention case'
cp "$sandbox/firewall/accesscontrol_calendar" "$sandbox/calendar.saved.rules" || fail 'saving calendar chain before failed transaction'
cp "$sandbox/firewall/accesscontrol" "$sandbox/ordinary.saved" || fail 'saving ordinary chain before failed transaction'
NFT_FAIL_BATCH=1
if calendar_refresh "$token"; then fail 'failed nft transaction reported success'; fi
assert_file_equal "$sandbox/firewall/accesscontrol_calendar" "$sandbox/calendar.saved.rules" 'failed transaction discarded old calendar rules'
assert_file_equal "$sandbox/firewall/accesscontrol" "$sandbox/ordinary.saved" 'failed transaction touched ordinary rules'
assert_equal "$(cat "$ACCESSCONTROL_CALENDAR_STATUS")" apply-error 'failed transaction status'
NFT_FAIL_BATCH=0
replace_config 'config.rules[0].end_time="25:00";'
if calendar_refresh "$token"; then fail 'invalid rule build reported success'; fi
assert_equal "$(cat "$ACCESSCONTROL_CALENDAR_STATUS")" apply-error 'failed build status'
assert_file_equal "$sandbox/firewall/accesscontrol_calendar" "$sandbox/calendar.saved.rules" 'failed build replaced prior rules'
replace_config 'config.rules[0].end_time="09:00";'
calendar_refresh "$token" || fail 'recovering from build and transaction errors'
assert_equal "$(cat "$ACCESSCONTROL_CALENDAR_STATUS")" ready 'successful recovery did not clear apply-error'
stop_service || fail 'service stop'
[ ! -f "$sandbox/firewall/accesscontrol" ] && [ ! -f "$sandbox/firewall/accesscontrol_calendar" ] || fail 'stop left accesscontrol chains'
[ ! -f "$ACCESSCONTROL_CALENDAR_STATE/active" ] && [ ! -f "$ACCESSCONTROL_CALENDAR_STATUS" ] || fail 'stop left calendar session or status'
if calendar_refresh "$token"; then fail 'stopped worker restored rules'; fi
requests_before=$(wc -l < "$sandbox/downloads")
if calendar_fetch_due "$token" "$FROZEN_TODAY"; then fail 'stopped worker fetched data'; fi
assert_equal "$(wc -l < "$sandbox/downloads")" "$requests_before" 'network request after stop'

# Simulate fw4 replacing its table: service start reconstructs both chains from
# caches without a download, and declares exactly one new watcher instance.
cp "$sandbox/original-config.json" "$sandbox/config.json"
: > "$sandbox/workers"
: > "$sandbox/firewall/forward"
start_service || fail 'restoring rules after firewall reload'
assert_equal "$(cat "$ACCESSCONTROL_CALENDAR_STATUS")" ready 'firewall reload cache status'
[ -s "$sandbox/firewall/accesscontrol" ] && [ -s "$sandbox/firewall/accesscontrol_calendar" ] || fail 'firewall reload lost mixed rules'
assert_equal "$(wc -l < "$sandbox/workers" | tr -d ' ')" 1 'firewall reload worker count'
assert_equal "$(wc -l < "$sandbox/downloads")" "$requests_before" 'firewall reload performed network I/O'
NFT_FAIL_BATCH=1
start_service || fail 'starting service with initial transaction failure'
assert_equal "$(cat "$ACCESSCONTROL_CALENDAR_STATUS")" apply-error 'startup relabeled apply failure as unavailable'
NFT_FAIL_BATCH=0
token=$(cat "$ACCESSCONTROL_CALENDAR_STATE/active")
calendar_refresh "$token" || fail 'recovering startup transaction failure'
assert_equal "$(cat "$ACCESSCONTROL_CALENDAR_STATUS")" ready 'startup transaction recovery status'

# Respect-holidays off, all rules disabled, and globally disabled each remove the
# worker/session and never request calendar data. Ordinary rules remain ordinary.
replace_config 'config.rules[0].respect_holidays="0";'
: > "$sandbox/workers"
start_service || fail 'ordinary-only service start'
[ ! -s "$sandbox/workers" ] && [ ! -f "$ACCESSCONTROL_CALENDAR_STATE/active" ] || fail 'ordinary-only mode declared a calendar worker'
[ ! -f "$sandbox/firewall/accesscontrol_calendar" ] || fail 'ordinary-only mode retained calendar chain'
assert_equal "$(wc -l < "$sandbox/downloads")" "$requests_before" 'ordinary-only mode downloaded data'
replace_config 'for (let i = 0; i < length(config.rules); i++) { config.rules[i].enabled="0"; config.rules[i].respect_holidays="1"; }'
start_service || fail 'all-disabled rules service start'
[ ! -s "$sandbox/workers" ] && [ ! -f "$ACCESSCONTROL_CALENDAR_STATE/active" ] || fail 'disabled rules declared a calendar worker'
replace_config 'config.global.enabled="0"; for (let i = 0; i < length(config.rules); i++) config.rules[i].enabled="1";'
start_service || fail 'globally disabled service start'
[ ! -f "$sandbox/firewall/accesscontrol" ] && [ ! -f "$sandbox/firewall/accesscontrol_calendar" ] || fail 'globally disabled service retained rules'
[ ! -s "$sandbox/workers" ] && [ ! -f "$ACCESSCONTROL_CALENDAR_STATUS" ] || fail 'globally disabled service retained a worker or status'
assert_equal "$(wc -l < "$sandbox/downloads")" "$requests_before" 'disabled mode downloaded data'

# Independent sessions keep the continuous watcher, retry clock and process
# lifecycle probes separate from the mixed service/disable checks above.
probe_session() {
	ACCESSCONTROL_CALENDAR_CACHE="$sandbox/$1.cache"
	ACCESSCONTROL_CALENDAR_STATE="$sandbox/$1.state"
	ACCESSCONTROL_CALENDAR_STATUS="$sandbox/$1.status"
	mkdir -p "$ACCESSCONTROL_CALENDAR_CACHE"
	calendar_lock || fail 'creating probe state'
	calendar_new_session || fail 'creating probe session'
	token="$CALENDAR_SESSION"
	calendar_unlock
}
cp "$sandbox/original-config.json" "$sandbox/config.json"

# A temporarily missing WAN must not suppress the required current year for an
# entire date. Prefetch failure remains daily while that year is not in use.
(
	trap - EXIT INT TERM
	probe_session retry
	FROZEN_TODAY=2026-03-08
	DOWNLOAD_INVALID=0
	DOWNLOAD_FAIL_CURRENT=1
	DOWNLOAD_NEXT=0
	ACCESSCONTROL_CALENDAR_NOW_EPOCH=1000
	: > "$sandbox/downloads"
	if calendar_fetch_due "$token" "$FROZEN_TODAY"; then fail 'WAN failure committed a cache'; fi
	calendar_refresh "$token" || fail 'applying missing-WAN fallback'
	assert_equal "$(cat "$ACCESSCONTROL_CALENDAR_STATUS")" unavailable 'WAN fallback status'
	assert_equal "$(wc -l < "$sandbox/downloads" | tr -d ' ')" 2 'initial current and next-year requests'
	ACCESSCONTROL_CALENDAR_NOW_EPOCH=4599
	if calendar_fetch_due "$token" "$FROZEN_TODAY"; then fail 'backoff was bypassed'; fi
	assert_equal "$(wc -l < "$sandbox/downloads" | tr -d ' ')" 2 'WAN failure retried before the hourly bound'
	ACCESSCONTROL_CALENDAR_NOW_EPOCH=4600
	DOWNLOAD_FAIL_CURRENT=0
	calendar_fetch_due "$token" "$FROZEN_TODAY" || fail 'same-day WAN recovery was never retried'
	calendar_refresh "$token" || fail 'applying recovered WAN calendar'
	assert_equal "$(cat "$ACCESSCONTROL_CALENDAR_STATUS")" ready 'WAN recovery did not restore calendar status'
	assert_equal "$(wc -l < "$sandbox/downloads" | tr -d ' ')" 3 'unused next year was retried hourly'
	ACCESSCONTROL_CALENDAR_NOW_EPOCH=9000
	if calendar_fetch_due "$token" "$FROZEN_TODAY"; then fail 'successful year was downloaded twice in a date'; fi
	assert_equal "$(wc -l < "$sandbox/downloads" | tr -d ' ')" 3 'daily successful-download throttle'
	# Roll the wall clock backwards after a new failed request. A future retry
	# timestamp must not lock this required year out until time catches up.
	FROZEN_TODAY=2026-03-09
	rm -f "$ACCESSCONTROL_CALENDAR_CACHE/2026.json"
	DOWNLOAD_FAIL_CURRENT=1
	ACCESSCONTROL_CALENDAR_NOW_EPOCH=5000
	if calendar_fetch_due "$token" "$FROZEN_TODAY"; then fail 'rollback setup unexpectedly fetched a valid year'; fi
	DOWNLOAD_FAIL_CURRENT=0
	ACCESSCONTROL_CALENDAR_NOW_EPOCH=100
	calendar_fetch_due "$token" "$FROZEN_TODAY" || fail 'clock rollback stranded a failed year'
	calendar_refresh "$token" || fail 'applying post-rollback recovery'
	assert_equal "$(cat "$ACCESSCONTROL_CALENDAR_STATUS")" ready 'clock rollback recovery status'
	assert_equal "$(wc -l < "$sandbox/downloads" | tr -d ' ')" 6 'rollback retried an unused prefetch year'
) || fail 'bounded retry behavior'

# Execute the production watcher loop for three consecutive iterations with a
# fixed civil/timezone key. The download succeeds, its immediate nft transaction
# fails once, and the following loop must recover using only that cached data.
(
	trap - EXIT INT TERM
	probe_session watch
	FROZEN_TODAY=2026-03-08
	DOWNLOAD_INVALID=0
	DOWNLOAD_FAIL_CURRENT=0
	DOWNLOAD_NEXT=0
	NFT_BATCH_CALLS=0
	NFT_FAIL_ON_BATCH=2
	NFT_FAIL_BATCH=0
	: > "$sandbox/downloads"
	: > "$sandbox/batch.attempts"
	: > "$sandbox/watch.history"
	printf '0\n' > "$sandbox/watch.cycles"
	calendar_clock_key() { printf 'fixed-clock-key\n'; }
	sleep() {
		local cycle
		cycle=$(cat "$sandbox/watch.cycles")
		cat "$ACCESSCONTROL_CALENDAR_STATUS" >> "$sandbox/watch.history"
		cycle=$((cycle + 1))
		printf '%s\n' "$cycle" > "$sandbox/watch.cycles"
		[ "$cycle" -lt 3 ] || rm -f "$ACCESSCONTROL_CALENDAR_STATE/active"
	}
	ACCESSCONTROL_FUNCTIONS_LIB=/dev/null
	ACCESSCONTROL_INIT_SCRIPT=/dev/null
	set -- "$token"
	. "$package/root/usr/libexec/accesscontrol-calendar-watch"
) || fail 'continuous production watcher'
assert_equal "$(cat "$sandbox/watch.status")" ready 'watcher did not retry the failed post-download apply'
assert_equal "$(wc -l < "$sandbox/batch.attempts" | tr -d ' ')" 3 'watcher refresh attempts after failed apply'
assert_equal "$(wc -l < "$sandbox/downloads" | tr -d ' ')" 2 'watcher retried network rather than the existing cache'
assert_equal "$(cat "$sandbox/watch.history")" "$(printf 'apply-error\nready\nready')" 'watcher status recovery history'

# The executable fetch boundary can be controlled without a real network. The
# production timeout owns and reaps this process; no BusyBox timeout is assumed.
mkdir -p "$sandbox/bin"
cat > "$sandbox/bin/uclient-fetch" <<'EOF'
#!/bin/sh
output=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-O) output="$2"; shift 2 ;;
		*) shift ;;
	esac
done
printf '%s %s\n' "$$" "$PPID" > "$CALENDAR_TEST_FETCH_PIDS"
case "$CALENDAR_TEST_FETCH_MODE" in
	good) cp "$CALENDAR_TEST_FETCH_DATA" "$output" ;;
	fail) exit 7 ;;
	wait) exec sleep 30 ;;
	*) exit 8 ;;
esac
EOF
chmod 700 "$sandbox/bin/uclient-fetch"
PATH="$sandbox/bin:$PATH"
export PATH
export CALENDAR_TEST_FETCH_DATA="$sandbox/fixtures/2026.json"
export CALENDAR_TEST_FETCH_PIDS="$sandbox/fetch.pids"
(
	trap - EXIT INT TERM
	. "$ACCESSCONTROL_CALENDAR_LIB"
	ACCESSCONTROL_CALENDAR_DOWNLOAD_DEADLINE=1
	export CALENDAR_TEST_FETCH_MODE=good
	calendar_download 2026 "$sandbox/fetched.json" || fail 'normal fetch with total deadline'
	assert_file_equal "$sandbox/fetched.json" "$CALENDAR_TEST_FETCH_DATA" 'normal fetch result'
	read -r fetch_pid deadline_pid < "$CALENDAR_TEST_FETCH_PIDS"
	if kill -0 "$fetch_pid" 2>/dev/null || kill -0 "$deadline_pid" 2>/dev/null; then fail 'normal fetch left a managed process'; fi
	export CALENDAR_TEST_FETCH_MODE=fail
	result=0
	calendar_download 2026 "$sandbox/fetched.json" || result=$?
	assert_equal "$result" 7 'normal fetch exit status was lost'
	read -r fetch_pid deadline_pid < "$CALENDAR_TEST_FETCH_PIDS"
	if kill -0 "$fetch_pid" 2>/dev/null || kill -0 "$deadline_pid" 2>/dev/null; then fail 'failed fetch left a managed process'; fi
	exec 8>"$sandbox/deadline.lock"
	busybox flock -x 8 || fail 'preparing deadline lock'
	export CALENDAR_TEST_FETCH_MODE=wait
	result=0
	started=$(busybox date +%s)
	calendar_download 2026 "$sandbox/fetched.json" || result=$?
	assert_equal "$result" 124 'independent total deadline did not terminate fetch'
	elapsed=$(($(busybox date +%s) - started))
	[ "$elapsed" -le 4 ] || fail 'total fetch deadline was not bounded'
	assert_equal "${ACCESSCONTROL_FETCH_PID:-}" '' 'completed fetch remained marked active'
	read -r fetch_pid deadline_pid < "$CALENDAR_TEST_FETCH_PIDS"
	if kill -0 "$fetch_pid" 2>/dev/null || kill -0 "$deadline_pid" 2>/dev/null; then fail 'deadline left fetch or timeout running'; fi
	exec 8>&-
	(exec 8>"$sandbox/deadline.lock"; busybox flock -n -x 8) || fail 'deadline child retained an inherited lock FD'
) || fail 'production download deadline behavior'

# TERM while the watcher waits in a real timeout must reap fetch and timeout,
# remove private candidate data, and release the actual download lock.
CALENDAR_TEST_FETCH_PIDS="$sandbox/term-fetch.pids"
export CALENDAR_TEST_FETCH_PIDS
(
	trap - EXIT INT TERM
	. "$ACCESSCONTROL_CALENDAR_LIB"
	calendar_log() { printf '%s\n' "$*" >> "$sandbox/messages"; }
	probe_session terminate
	FROZEN_TODAY=2026-03-08
	ACCESSCONTROL_CALENDAR_DOWNLOAD_DEADLINE=30
	export CALENDAR_TEST_FETCH_MODE=wait
	ACCESSCONTROL_FUNCTIONS_LIB=/dev/null
	ACCESSCONTROL_INIT_SCRIPT=/dev/null
	set -- "$token"
	. "$package/root/usr/libexec/accesscontrol-calendar-watch"
) &
watcher_pid=$!
attempt=0
while [ ! -s "$CALENDAR_TEST_FETCH_PIDS" ] && [ "$attempt" -lt 10 ]; do
	busybox sleep 1
	attempt=$((attempt + 1))
done
if [ ! -s "$CALENDAR_TEST_FETCH_PIDS" ]; then
	kill "$watcher_pid" 2>/dev/null
	wait "$watcher_pid" 2>/dev/null
	fail 'watcher never entered the managed fetch'
fi
kill "$watcher_pid" || fail 'terminating fetching watcher'
wait "$watcher_pid" || fail 'watcher TERM cleanup failed'
read -r fetch_pid deadline_pid < "$CALENDAR_TEST_FETCH_PIDS"
if kill -0 "$fetch_pid" 2>/dev/null || kill -0 "$deadline_pid" 2>/dev/null; then fail 'watcher TERM left fetch or timeout running'; fi
(exec 8>"$sandbox/terminate.state/download.lock"; busybox flock -n -x 8) || fail 'watcher TERM left download lock held'
for directory in "$sandbox/terminate.cache"/.fetch.* "$sandbox/terminate.state"/rules.*; do
	[ ! -d "$directory" ] || fail 'watcher TERM retained private work'
done
printf 'Calendar source years, retries, atomic status recovery, watcher and deadline regressions passed\n'
