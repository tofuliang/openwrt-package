#!/bin/sh
# Holiday-mode rules use local dates, but nft meta time takes epoch seconds.
# This file is sourced by the init script and its procd-managed watcher.

ACCESSCONTROL_CALENDAR_CACHE=${ACCESSCONTROL_CALENDAR_CACHE:-/etc/accesscontrol/holidays}
ACCESSCONTROL_CALENDAR_STATE=${ACCESSCONTROL_CALENDAR_STATE:-/var/run/accesscontrol-calendar}
ACCESSCONTROL_CALENDAR_STATUS=${ACCESSCONTROL_CALENDAR_STATUS:-/var/run/accesscontrol-calendar.status}
# NateScarlet names files after the State Council announcement year.  A file
# for year Y may also contain valid make-up/holiday dates from December Y-1.
# December therefore needs Y and Y+1: Y+1 entries override Y, and a missing
# required table keeps affected rules on their selected-weekday fallback.
ACCESSCONTROL_CALENDAR_SOURCE=https://raw.githubusercontent.com/NateScarlet/holiday-cn/master
ACCESSCONTROL_CALENDAR_DOWNLOAD_DEADLINE=${ACCESSCONTROL_CALENDAR_DOWNLOAD_DEADLINE:-30}
ACCESSCONTROL_CALENDAR_IDLE_TIMEOUT=${ACCESSCONTROL_CALENDAR_IDLE_TIMEOUT:-20}
ACCESSCONTROL_CALENDAR_RETRY_INTERVAL=${ACCESSCONTROL_CALENDAR_RETRY_INTERVAL:-3600}
# Local minutes from which a period counts as the night leading into the next
# day (18:00). Such a period belongs to the day it wakes up on: the night
# before a holiday stays open, the last holiday night is restricted, just like
# a period that crosses midnight.
ACCESSCONTROL_CALENDAR_NIGHT_START=${ACCESSCONTROL_CALENDAR_NIGHT_START:-1080}

calendar_log() {
	logger -t accesscontrol "$*"
}

calendar_init_state() {
	[ ! -L "$ACCESSCONTROL_CALENDAR_STATE" ] || return 1
	mkdir -p "$ACCESSCONTROL_CALENDAR_STATE" && chmod 700 "$ACCESSCONTROL_CALENDAR_STATE"
}

calendar_lock() {
	calendar_init_state || return 1
	exec 9>"$ACCESSCONTROL_CALENDAR_STATE/rules.lock"
	busybox flock -x 9
}

calendar_unlock() {
	busybox flock -u 9
	exec 9>&-
}

calendar_active() {
	local active
	[ -n "$1" ] && [ -r "$ACCESSCONTROL_CALENDAR_STATE/active" ] || return 1
	IFS= read -r active < "$ACCESSCONTROL_CALENDAR_STATE/active"
	[ "$active" = "$1" ]
}

calendar_new_session() {
	local temporary
	temporary=$(mktemp "$ACCESSCONTROL_CALENDAR_STATE/session.XXXXXX") || return 1
	CALENDAR_SESSION=${temporary##*/}
	printf '%s\n' "$CALENDAR_SESSION" > "$temporary"
	mv -f "$temporary" "$ACCESSCONTROL_CALENDAR_STATE/active"
}

calendar_clear_session() {
	rm -f "$ACCESSCONTROL_CALENDAR_STATE/active" "$ACCESSCONTROL_CALENDAR_STATUS"
}

calendar_set_status() {
	local status="$1" previous temporary
	previous=$(cat "$ACCESSCONTROL_CALENDAR_STATUS" 2>/dev/null)
	[ "$previous" = "$status" ] && return 0
	temporary=$(mktemp "$ACCESSCONTROL_CALENDAR_STATE/status.XXXXXX") || return 1
	printf '%s\n' "$status" > "$temporary"
	chmod 644 "$temporary"
	mv -f "$temporary" "$ACCESSCONTROL_CALENDAR_STATUS" || return 1
	case "$status" in
		ready) calendar_log 'Holiday calendar ready; holiday-mode rules follow actual working days' ;;
		unavailable) calendar_log 'Holiday calendar unavailable: required year data is missing or invalid; using selected weekdays for affected rules' ;;
		apply-error) calendar_log 'Holiday calendar apply failed; previous calendar rules retained and retrying' ;;
	esac
}

calendar_count_rule() {
	local enabled respect_holidays
	config_get enabled "$1" enabled 0
	config_get respect_holidays "$1" respect_holidays 0
	[ "$enabled" = 1 ] && [ "$respect_holidays" = 1 ] && CALENDAR_RULE_COUNT=$((CALENDAR_RULE_COUNT + 1))
	return 0
}

calendar_count_rules() {
	CALENDAR_RULE_COUNT=0
	config_foreach calendar_count_rule rule
}

calendar_valid_time() {
	case "$1" in
		[0-9]:[0-5][0-9]|[01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) return 0 ;;
		*) return 1 ;;
	esac
}

calendar_valid_mac() {
	case "$1" in
		[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
		*) return 1 ;;
	esac
}

calendar_time_minutes() {
	local hour="${1%:*}" minute="${1#*:}"
	hour=${hour#0}
	minute=${minute#0}
	printf '%s\n' "$(( ${hour:-0} * 60 + ${minute:-0} ))"
}

# Add civil days in UTC at noon; never add 86400 to a local/DST boundary.
calendar_adjacent_date() {
	local noon
	noon=$(TZ=UTC date -d "$1 12:00:00" +%s) || return 1
	TZ=UTC date -d "@$((noon + $2 * 86400))" +%Y-%m-%d
}

calendar_validate_file() {
	local file="$1" year="$2" table="$3" size day off normalized previous_date previous_year
	case "$year" in [0-9][0-9][0-9][0-9]) ;; *) return 1 ;; esac
	[ -f "$file" ] || return 1
	size=$(wc -c < "$file") || return 1
	[ "$size" -gt 0 ] && [ "$size" -le 262144 ] || return 1
	# Validate the entire JSON structure before emitting any rows. Date strings
	# must be exactly ASCII YYYY-MM-DD so raw TSV cannot inject extra columns
	# or rows; the real civil-date and announcement-year checks stay in shell.
	ucode -e '
		import { readfile } from "fs";
		let data = json(readfile(ARGV[0]));
		if (type(data) != "object" ||
		    (type(data.year) != "int" && type(data.year) != "double") ||
		    data.year != int(ARGV[1]) || type(data.days) != "array" ||
		    length(data.days) < 1 || length(data.days) > 397)
			exit(1);
		let seen = {};
		for (let i = 0; i < length(data.days); i++) {
			let day = data.days[i];
			if (type(day) != "object" || type(day.date) != "string" ||
			    type(day.isOffDay) != "bool" || length(day.date) != 10 ||
			    !match(day.date, /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) ||
			    seen[day.date] == true)
				exit(1);
			seen[day.date] = true;
		}
		for (let i = 0; i < length(data.days); i++)
			printf("%s\t%d\n", data.days[i].date, data.days[i].isOffDay ? 1 : 0);
	' "$file" "$year" > "$table" 2>/dev/null || return 1
	previous_date=$(calendar_adjacent_date "$year-01-01" -1) || return 1
	previous_year=${previous_date%%-*}
	while read -r day off; do
		case "$day" in
			"$year"-[0-9][0-9]-[0-9][0-9]) ;;
			"$previous_year"-12-[0-9][0-9]) ;;
			*) return 1 ;;
		esac
		normalized=$(TZ=UTC date -d "$day 12:00:00" +%Y-%m-%d 2>/dev/null) || return 1
		[ "$normalized" = "$day" ] || return 1
	done < "$table"
}

calendar_prepare_window() {
	local today="$1" work="$2" yesterday tomorrow after day year month source_year source_years years=' '
	yesterday=$(calendar_adjacent_date "$today" -1) || return 1
	tomorrow=$(calendar_adjacent_date "$today" 1) || return 1
	after=$(calendar_adjacent_date "$today" 2) || return 1
	printf '%s %s\n' "$yesterday" "$today" "$today" "$tomorrow" "$tomorrow" "$after" > "$work/window" || return 1
	# Yesterday is only an interval start; any still-active overnight period
	# ends today.  Its obsolete daytime period needs no previous-year table.
	for day in "$today" "$tomorrow" "$after"; do
		year=${day%%-*}
		month=${day#*-}; month=${month%%-*}
		source_years="$year"
		[ "$month" != 12 ] || source_years="$source_years $((year + 1))"
		for source_year in $source_years; do
			case "$years" in *" $source_year "*) continue ;; esac
			years="$years$source_year "
			if ! calendar_validate_file "$ACCESSCONTROL_CALENDAR_CACHE/$source_year.json" "$source_year" "$work/$source_year.days"; then
				rm -f "$work/$source_year.days"
			fi
		done
	done
}

# 0 = working day, 1 = day off, 2 = unknown year. Unknown is never a weekday default.
calendar_is_workday() {
	local day="$1" work="$2" year="${1%%-*}" entry off weekday month
	local current_file="$work/$year.days" override_file
	[ -f "$current_file" ] || return 2
	month=${day#*-}; month=${month%%-*}
	if [ "$month" = 12 ]; then
		override_file="$work/$((year + 1)).days"
		# A missing next-year table could conceal a December make-up day.
		# Do not claim ready or guess an ordinary weekday without that table.
		[ -f "$override_file" ] || return 2
		while read -r entry off; do
			if [ "$entry" = "$day" ]; then
				[ "$off" = 0 ]
				return $?
			fi
		done < "$override_file"
	fi
	while read -r entry off; do
		if [ "$entry" = "$day" ]; then
			[ "$off" = 0 ]
			return $?
		fi
	done < "$current_file"
	weekday=$(TZ=UTC date -d "$day 12:00:00" +%w) || return 2
	[ "$weekday" -ge 1 ] && [ "$weekday" -le 5 ]
}

# Emit one rule covering [from_date from_time, to_date to_time].  The HH:MM UI
# covers the complete ending minute, while a night-boundary cut lands on the
# exact second, so the caller selects which of the two applies.
calendar_emit_segment() {
	local macaddr="$1" from_date="$2" from_time="$3" to_date="$4" to_time="$5" decide_date="$6" inclusive="$7" work="$8" output="$9"
	local decision start_epoch end_epoch today
	today=${CALENDAR_BUILD_TODAY:-}
	# A part that ends before today is expired.  It must not reach into a
	# previous year's table, and must not make a valid calendar unavailable.
	if [ -n "$today" ] && [ "$to_date" \< "$today" ]; then
		return 0
	fi
	if calendar_is_workday "$decide_date" "$work"; then
		decision=0
	else
		decision=$?
	fi
	[ "$decision" -ne 2 ] || return 2
	[ "$decision" -eq 0 ] || return 0
	start_epoch=$(date -d "$from_date $from_time:00" +%s) || return 1
	end_epoch=$(date -d "$to_date $to_time:00" +%s) || return 1
	[ "$inclusive" != 1 ] || end_epoch=$((end_epoch + 60))
	# Use a half-open comparison, not an inclusive nft range with a
	# fractional-second gap.
	[ "$end_epoch" -gt "$start_epoch" ] || return 1
	printf 'add rule inet fw4 accesscontrol_calendar ether saddr %s meta time >= %s meta time < %s counter drop comment "AccessControl calendar %s"\n' \
		"$macaddr" "$start_epoch" "$end_epoch" "$macaddr" >> "$output" || return 1
}

calendar_emit_intervals() {
	local macaddr="$1" start_time="$2" end_time="$3" work="$4" output="$5"
	local start_minutes end_minutes start_date next_date end_date night_from_date night_from_time night_date later_date boundary
	start_minutes=$(calendar_time_minutes "$start_time")
	end_minutes=$(calendar_time_minutes "$end_time")
	boundary=$(printf '%02d:%02d' $((ACCESSCONTROL_CALENDAR_NIGHT_START / 60)) $((ACCESSCONTROL_CALENDAR_NIGHT_START % 60)))
	while read -r start_date next_date; do
		end_date="$start_date"
		[ "$start_minutes" -gt "$end_minutes" ] && end_date="$next_date"
		# Every part of a period belongs to the day it wakes up on: the part
		# before the night boundary keeps its own date, and the part from the
		# boundary on follows the next day.  A period that reaches the boundary
		# is split there, so the night before a holiday stays open and the last
		# holiday night is blocked.
		if [ "$start_minutes" -lt "$ACCESSCONTROL_CALENDAR_NIGHT_START" ]; then
			if [ "$start_minutes" -gt "$end_minutes" ] || [ "$end_minutes" -ge "$ACCESSCONTROL_CALENDAR_NIGHT_START" ]; then
				calendar_emit_segment "$macaddr" "$start_date" "$start_time" \
					"$start_date" "$boundary" "$start_date" 0 "$work" "$output" || return $?
			else
				calendar_emit_segment "$macaddr" "$start_date" "$start_time" \
					"$start_date" "$end_time" "$start_date" 1 "$work" "$output" || return $?
			fi
		fi
		if [ "$start_minutes" -ge "$ACCESSCONTROL_CALENDAR_NIGHT_START" ]; then
			night_from_date="$start_date"
			night_from_time="$start_time"
		elif [ "$start_minutes" -gt "$end_minutes" ] || [ "$end_minutes" -ge "$ACCESSCONTROL_CALENDAR_NIGHT_START" ]; then
			night_from_date="$start_date"
			night_from_time="$boundary"
		else
			continue
		fi
		night_date=$(calendar_adjacent_date "$night_from_date" 1) || return 1
		if [ "$end_date" = "$night_date" ] && [ "$end_minutes" -ge "$ACCESSCONTROL_CALENDAR_NIGHT_START" ]; then
			# A period long enough to reach the night of the following day keeps
			# that tail with the day after it.
			later_date=$(calendar_adjacent_date "$night_date" 1) || return 1
			calendar_emit_segment "$macaddr" "$night_from_date" "$night_from_time" \
				"$night_date" "$boundary" "$night_date" 0 "$work" "$output" || return $?
			calendar_emit_segment "$macaddr" "$night_date" "$boundary" \
				"$end_date" "$end_time" "$later_date" 1 "$work" "$output" || return $?
		else
			calendar_emit_segment "$macaddr" "$night_from_date" "$night_from_time" \
				"$end_date" "$end_time" "$night_date" 1 "$work" "$output" || return $?
		fi
	done < "$work/window"
}

calendar_process_rule() {
	local section="$1" enabled respect_holidays macaddr start_time end_time temporary result
	config_get enabled "$section" enabled 0
	config_get respect_holidays "$section" respect_holidays 0
	[ "$enabled" = 1 ] && [ "$respect_holidays" = 1 ] || return 0
	config_get macaddr "$section" macaddr
	config_get start_time "$section" start_time
	config_get end_time "$section" end_time
	if ! calendar_valid_mac "$macaddr" || ! calendar_valid_time "$start_time" || ! calendar_valid_time "$end_time"; then
		CALENDAR_BUILD_FAILED=1
		calendar_log "Cannot build holiday-mode rule $section: invalid MAC address or time; retaining previous calendar rules"
		return 0
	fi
	temporary=$(mktemp "$CALENDAR_WORK_DIR/rule.XXXXXX") || { CALENDAR_BUILD_FAILED=1; return 0; }
	if calendar_emit_intervals "$macaddr" "$start_time" "$end_time" "$CALENDAR_WORK_DIR" "$temporary"; then
		cat "$temporary" >> "$ACCESSCONTROL_RULE_BATCH" || CALENDAR_BUILD_FAILED=1
	else
		result=$?
		case "$result" in
			2)
				CALENDAR_BUILD_STATUS=unavailable
				# Reuse the original weekday implementation only when a required
				# annual table is unknown; this is a successful fallback transaction.
				process_rule "$section"
				;;
			*)
				CALENDAR_BUILD_FAILED=1
				calendar_log "Cannot build holiday-mode rule $section; retaining previous calendar rules"
				;;
		esac
	fi
	rm -f "$temporary"
	return 0
}

calendar_build_batch() {
	local today="$1" work="$2"
	local CALENDAR_WORK_DIR="$work" CALENDAR_BUILD_TODAY="$today" CALENDAR_BUILD_FAILED=0
	local ACCESSCONTROL_RULE_CHAIN=accesscontrol_calendar ACCESSCONTROL_RULE_BATCH="$work/batch"
	CALENDAR_BUILD_STATUS=ready
	calendar_prepare_window "$today" "$work" || return 1
	printf 'flush chain inet fw4 accesscontrol_calendar\n' > "$ACCESSCONTROL_RULE_BATCH" || return 1
	config_foreach calendar_process_rule rule || return 1
	[ "$CALENDAR_BUILD_FAILED" = 0 ]
}

# Caller holds rules.lock. No network activity is permitted on this path.
calendar_refresh_locked() {
	local token="$1" today work result
	calendar_active "$token" || return 1
	today=$(date +%Y-%m-%d) || {
		calendar_set_status apply-error
		return 1
	}
	work=$(mktemp -d "$ACCESSCONTROL_CALENDAR_STATE/rules.XXXXXX") || {
		calendar_set_status apply-error
		return 1
	}
	ACCESSCONTROL_RULES_DIR="$work"
	result=1
	if calendar_build_batch "$today" "$work"; then
		# nft commits the flush and every replacement rule as one transaction.
		if TZ=UTC nft -f "$work/batch"; then
			calendar_set_status "$CALENDAR_BUILD_STATUS"
			result=0
		else
			calendar_set_status apply-error
			calendar_log 'Holiday calendar rule transaction failed; previous rules retained'
		fi
	else
		calendar_set_status apply-error
		calendar_log 'Holiday calendar rule build failed; previous rules retained'
	fi
	rm -rf "$work"
	ACCESSCONTROL_RULES_DIR=
	return "$result"
}

calendar_refresh() {
	local token="$1" enabled result
	calendar_lock || return 1
	if ! calendar_active "$token"; then
		calendar_unlock
		return 1
	fi
	config_load "$CONFIG"
	config_get enabled global enabled 0
	calendar_count_rules
	if [ "$enabled" != 1 ] || [ "$CALENDAR_RULE_COUNT" = 0 ]; then
		calendar_clear_session
		calendar_unlock
		return 1
	fi
	if calendar_refresh_locked "$token"; then result=0; else result=$?; fi
	calendar_unlock
	return "$result"
}

calendar_clock_key() {
	date '+%Y-%m-%d %z %Z'
	[ ! -r /etc/TZ ] || sha256sum /etc/TZ
	[ ! -r /etc/localtime ] || sha256sum /etc/localtime
	return 0
}
calendar_now_epoch() {
	if [ -n "${ACCESSCONTROL_CALENDAR_NOW_EPOCH:-}" ]; then
		printf '%s\n' "$ACCESSCONTROL_CALENDAR_NOW_EPOCH"
	else
		date +%s
	fi
}

calendar_fetch_allowed() {
	local year="$1" today="$2" record last_date state last_epoch now current after month after_month after_year
	record=$(cat "$ACCESSCONTROL_CALENDAR_STATE/fetched.$year" 2>/dev/null) || return 0
	set -- $record
	last_date=${1:-}
	state=${2:-ok}
	last_epoch=${3:-}
	[ "$last_date" = "$today" ] || return 0
	case "$state" in
		ok) return 1 ;;
		fail-cached) [ ! -f "$ACCESSCONTROL_CALENDAR_CACHE/$year.json" ] || return 1 ;;
	esac
	current=${today%%-*}
	after=$(calendar_adjacent_date "$today" 2) || return 1
	after_year=${after%%-*}
	month=${today#*-}; month=${month%%-*}
	after_month=${after#*-}; after_month=${after_month%%-*}
	# Unpublished prefetches outside the rolling window stay daily.  Once
	# December (or January) enters that window a missing table retries hourly.
	if [ "$year" != "$current" ] && [ "$year" != "$after_year" ] &&
	   [ "$month" != 12 ] && [ "$after_month" != 12 ]; then
		return 1
	fi
	now=$(calendar_now_epoch) || return 1
	case "$last_epoch:$now" in
		*[!0-9:]*|:*|*:) return 0 ;;
	esac
	[ "$now" -lt "$last_epoch" ] && return 0
	[ "$((now - last_epoch))" -ge "$ACCESSCONTROL_CALENDAR_RETRY_INTERVAL" ]
}


calendar_download() {
	# Bound both idle and total request time.  Close inherited lock FDs in
	# the child so a terminated fetch can never hold the next download lock.
	(
		exec 8>&- 9>&-
		ulimit -f 512
		exec timeout -k 5 "$ACCESSCONTROL_CALENDAR_DOWNLOAD_DEADLINE" \
			uclient-fetch -q -T "$ACCESSCONTROL_CALENDAR_IDLE_TIMEOUT" -O "$2" \
			"$ACCESSCONTROL_CALENDAR_SOURCE/$1.json"
	) &
	ACCESSCONTROL_FETCH_PID=$!
	local result
	if wait "$ACCESSCONTROL_FETCH_PID"; then result=0; else result=$?; fi
	ACCESSCONTROL_FETCH_PID=
	return "$result"
}

calendar_fetch_year() {
	local year="$1" token="$2" today="$3" temporary valid=0 result=0 state=fail now
	calendar_fetch_allowed "$year" "$today" || return 1
	calendar_active "$token" || return 1
	[ ! -L "$ACCESSCONTROL_CALENDAR_CACHE" ] || return 1
	mkdir -p "$ACCESSCONTROL_CALENDAR_CACHE" && chmod 700 "$ACCESSCONTROL_CALENDAR_CACHE" || return 1
	temporary=$(mktemp -d "$ACCESSCONTROL_CALENDAR_CACHE/.fetch.XXXXXX") || return 1
	ACCESSCONTROL_FETCH_DIR="$temporary"
	if calendar_download "$year" "$temporary/data.json" && calendar_validate_file "$temporary/data.json" "$year" "$temporary/days"; then
		valid=1
	fi
	calendar_lock || { rm -rf "$temporary"; ACCESSCONTROL_FETCH_DIR=; return 1; }
	if calendar_active "$token"; then
		if [ "$valid" = 1 ]; then
			chmod 600 "$temporary/data.json"
			if mv -f "$temporary/data.json" "$ACCESSCONTROL_CALENDAR_CACHE/$year.json"; then
				result=1
				state=ok
			fi
		else
			calendar_log "Cannot fetch valid holiday data for $year; any valid cached calendar is retained"
		fi
		if [ "$result" != 1 ] && calendar_validate_file "$ACCESSCONTROL_CALENDAR_CACHE/$year.json" "$year" "$temporary/cached.days"; then
			state=fail-cached
		fi
		now=$(calendar_now_epoch 2>/dev/null) || now=0
		printf '%s %s %s\n' "$today" "$state" "$now" > "$ACCESSCONTROL_CALENDAR_STATE/fetched.$year"
	fi
	calendar_unlock
	rm -rf "$temporary"
	ACCESSCONTROL_FETCH_DIR=
	[ "$result" = 1 ]
}

calendar_fetch_due() {
	local token="$1" today="$2" current next year changed=1
	calendar_active "$token" || return 1
	exec 8>"$ACCESSCONTROL_CALENDAR_STATE/download.lock"
	if ! busybox flock -n -x 8; then exec 8>&-; return 1; fi
	current=${today%%-*}
	next=$((current + 1))
	for year in "$current" "$next"; do
		calendar_active "$token" || break
		if calendar_fetch_year "$year" "$token" "$today"; then changed=0; fi
	done
	busybox flock -u 8
	exec 8>&-
	return "$changed"
}
