#!/bin/sh

# Multi-WAN Common Functions Library
# 共享函数库，避免代码冗余

STATE_DIR="/var/run/multiwan"
NFT_TABLE="multiwan"
ROUTE_MARK_WAN=0x00010000
ROUTE_MARK_VWAN1=0x00020000
ROUTE_MARK_VWAN2=0x00040000
# 日志函数
log() {
    local tag="$1"
    local message="${2:-}"

    # 单参数调用时整句都是正文；否则 logger 会把正文当成标签并截断到 32 字节。
    if [ -z "$message" ]; then
        tag="multiwan"
        message="$1"
    fi
    logger -t "$tag" "$message"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$tag] $message"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$tag] $message" >> /var/log/multiwan.log
}


# 原子重建运营商目的地址策略子链；每条规则都保存新连接标记。
apply_destination_policy() {
    local state=$1 mobile telecom china international mobile6 international6 telecom6 china6

    # IPv6 移动出口兜底：vwan2 在线走移动，否则回退 WAN/VWAN1。
    case "$state" in
        balanced|wan_cmcc|vwan_cmcc|cmcc_only)
            mobile6="meta mark set $ROUTE_MARK_VWAN2 goto save_mark"
            ;;
        ct_only)
            mobile6="meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 2 map { 0 : $ROUTE_MARK_WAN, 1 : $ROUTE_MARK_VWAN1 } goto save_mark"
            ;;
        wan_only)
            mobile6="meta mark set $ROUTE_MARK_WAN goto save_mark"
            ;;
        vwan_only)
            mobile6="meta mark set $ROUTE_MARK_VWAN1 goto save_mark"
            ;;
        *) return 1 ;;
    esac

    # IPv6 目的地分流：与 v4 同构，仅作用于路由器自身发出的 v6。
    case "$state" in
        balanced)
            telecom6="meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 2 map { 0 : $ROUTE_MARK_WAN, 1 : $ROUTE_MARK_VWAN1 } goto save_mark"
            china6="meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 3 map { 0 : $ROUTE_MARK_WAN, 1 : $ROUTE_MARK_VWAN1, 2 : $ROUTE_MARK_VWAN2 } goto save_mark"
            ;;
        ct_only)
            telecom6="meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 2 map { 0 : $ROUTE_MARK_WAN, 1 : $ROUTE_MARK_VWAN1 } goto save_mark"
            china6="$telecom6"
            ;;
        wan_cmcc)
            telecom6="meta mark set $ROUTE_MARK_WAN goto save_mark"
            china6="meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 2 map { 0 : $ROUTE_MARK_WAN, 1 : $ROUTE_MARK_VWAN2 } goto save_mark"
            ;;
        vwan_cmcc)
            telecom6="meta mark set $ROUTE_MARK_VWAN1 goto save_mark"
            china6="meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 2 map { 0 : $ROUTE_MARK_VWAN1, 1 : $ROUTE_MARK_VWAN2 } goto save_mark"
            ;;
        wan_only)
            telecom6="meta mark set $ROUTE_MARK_WAN goto save_mark"
            china6="$telecom6"
            ;;
        vwan_only)
            telecom6="meta mark set $ROUTE_MARK_VWAN1 goto save_mark"
            china6="$telecom6"
            ;;
        cmcc_only)
            telecom6="meta mark set $ROUTE_MARK_VWAN2 goto save_mark"
            china6="$telecom6"
            ;;
        *) return 1 ;;
    esac

    case "$state" in
        balanced)
            mobile="meta mark set $ROUTE_MARK_VWAN2 goto save_mark"
            telecom="meta mark set jhash ip saddr . ip daddr . meta l4proto . th sport . th dport mod 2 map { 0 : $ROUTE_MARK_WAN, 1 : $ROUTE_MARK_VWAN1 } goto save_mark"
            china="meta mark set jhash ip saddr . ip daddr . meta l4proto . th sport . th dport mod 3 map { 0 : $ROUTE_MARK_WAN, 1 : $ROUTE_MARK_VWAN1, 2 : $ROUTE_MARK_VWAN2 } goto save_mark"
            international="$china"
            international6="meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 3 map { 0 : $ROUTE_MARK_WAN, 1 : $ROUTE_MARK_VWAN1, 2 : $ROUTE_MARK_VWAN2 } goto save_mark"
            ;;
        ct_only)
            mobile="meta mark set jhash ip saddr . ip daddr . meta l4proto . th sport . th dport mod 2 map { 0 : $ROUTE_MARK_WAN, 1 : $ROUTE_MARK_VWAN1 } goto save_mark"
            telecom="$mobile"
            china="$mobile"
            international="$mobile"
            international6="meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 2 map { 0 : $ROUTE_MARK_WAN, 1 : $ROUTE_MARK_VWAN1 } goto save_mark"
            ;;
        wan_cmcc)
            mobile="meta mark set $ROUTE_MARK_VWAN2 goto save_mark"
            telecom="meta mark set $ROUTE_MARK_WAN goto save_mark"
            china="meta mark set jhash ip saddr . ip daddr . meta l4proto . th sport . th dport mod 2 map { 0 : $ROUTE_MARK_WAN, 1 : $ROUTE_MARK_VWAN2 } goto save_mark"
            international="$china"
            international6="meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 2 map { 0 : $ROUTE_MARK_WAN, 1 : $ROUTE_MARK_VWAN2 } goto save_mark"
            ;;
        vwan_cmcc)
            mobile="meta mark set $ROUTE_MARK_VWAN2 goto save_mark"
            telecom="meta mark set $ROUTE_MARK_VWAN1 goto save_mark"
            china="meta mark set jhash ip saddr . ip daddr . meta l4proto . th sport . th dport mod 2 map { 0 : $ROUTE_MARK_VWAN1, 1 : $ROUTE_MARK_VWAN2 } goto save_mark"
            international="$china"
            international6="meta mark set jhash ip6 saddr . ip6 daddr . meta l4proto . th sport . th dport mod 2 map { 0 : $ROUTE_MARK_VWAN1, 1 : $ROUTE_MARK_VWAN2 } goto save_mark"
            ;;
        wan_only)
            mobile="meta mark set $ROUTE_MARK_WAN goto save_mark"
            telecom="$mobile"
            china="$mobile"
            international="$mobile"
            international6="$mobile"
            ;;
        vwan_only)
            mobile="meta mark set $ROUTE_MARK_VWAN1 goto save_mark"
            telecom="$mobile"
            china="$mobile"
            international="$mobile"
            international6="$mobile"
            ;;
        cmcc_only)
            mobile="meta mark set $ROUTE_MARK_VWAN2 goto save_mark"
            telecom="$mobile"
            china="$mobile"
            international="$mobile"
            international6="$mobile"
            ;;
        *) return 1 ;;
    esac

    nft -f - <<EOF
flush chain inet $NFT_TABLE route_mobile
add rule inet $NFT_TABLE route_mobile $mobile
flush chain inet $NFT_TABLE route_mobile6
add rule inet $NFT_TABLE route_mobile6 $mobile6
flush chain inet $NFT_TABLE route_telecom6
add rule inet $NFT_TABLE route_telecom6 $telecom6
flush chain inet $NFT_TABLE route_china6
add rule inet $NFT_TABLE route_china6 $china6
flush chain inet $NFT_TABLE route_telecom
add rule inet $NFT_TABLE route_telecom $telecom
flush chain inet $NFT_TABLE route_china
add rule inet $NFT_TABLE route_china $china
flush chain inet $NFT_TABLE route_international
add rule inet $NFT_TABLE route_international $international
flush chain inet $NFT_TABLE route_international6
add rule inet $NFT_TABLE route_international6 $international6
EOF
}

route_table_ready() {
    ip route show table "$1" 2>/dev/null | grep -q '^default'
}

# 刷新 localnetwork6 集合：本机自身地址、内网前缀与特殊范围，避免被策略路由改写出口。
update_localnetwork6() {
    local elements="" addr prefix line

    # 表尚未加载（开机时 hotplug 早于 S95）时跳过；服务启动后会重新填充。
    nft list set inet "$NFT_TABLE" localnetwork6 >/dev/null 2>&1 || return 0

    # 特殊范围
    elements="fe80::/10, fc00::/7, ff00::/8, ::1/128"

    # 路由器自身接口上的全局地址（/128）
    for addr in $(ip -6 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]"/128"}'); do
        elements="$elements, $addr"
    done

    # 内网侧接口承载的前缀
    for prefix in $(ip -6 route show table main 2>/dev/null | awk '/dev (br-lan|eth1|macvlan1|macvlan2|modem2)/ {print $1}'); do
        elements="$elements, $prefix"
    done

    nft -f - <<EOF
flush set inet $NFT_TABLE localnetwork6
add element inet $NFT_TABLE localnetwork6 { $elements }
EOF
}

# 为路由器自身的IPv6流量提供无源默认路由；各WAN的源前缀路由仍优先匹配。
ensure_ipv6_host_default() {
    local iface device

    ip -6 route del default metric 4096 2>/dev/null || true
    for iface in wan vwan1 vwan2_6; do
        [ -f "$STATE_DIR/${iface%_6}_status" ] || continue
        [ "$(cat "$STATE_DIR/${iface%_6}_status")" = up ] || continue
        device=$(ubus call network.interface."$iface" status 2>/dev/null | jsonfilter -e '@.l3_device')
        [ -n "$device" ] || continue
        ip -6 -o addr show dev "$device" scope global | grep -q 'inet6 ' || continue
        if ip -6 route replace default dev "$device" metric 4096 2>/dev/null; then
            log "multiwan-ipv6" "Host IPv6 default route via $device"
            update_localnetwork6 || log "multiwan-ipv6" "Warning: failed to refresh localnetwork6 set"
            return 0
        fi
    done
    log "multiwan-ipv6" "No healthy interface has an IPv6 host default route"
    update_localnetwork6 || true
    return 1
}


# 更新全局路由状态的核心逻辑
update_global_routing() {
    local caller="${1:-unknown}"
    local lock_file="${MULTIWAN_LOCK_DIR:-/var/lock}/multiwan_policy"
    local wan_status="down" vwan_status="down" cmcc_status="down"
    local new_state current_state owns_lock=0

    if [ "${MULTIWAN_POLICY_LOCK_HELD:-0}" != 1 ]; then
        mkdir -p "${MULTIWAN_LOCK_DIR:-/var/lock}" || return 1
        exec 8>"$lock_file" || return 1
        flock 8 || return 1
        owns_lock=1
    fi

    # 表尚未加载时（开机阶段先于 S95 的 hotplug 事件）无法应用策略，交由服务启动处理。
    if ! nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        log "multiwan-routing" "Policy table inet $NFT_TABLE not loaded yet; deferring policy update (triggered by: $caller)"
        [ "$owns_lock" -eq 1 ] && flock -u 8
        return 0
    fi

    [ -f "$STATE_DIR/wan_status" ] && wan_status=$(cat "$STATE_DIR/wan_status")
    [ -f "$STATE_DIR/vwan1_status" ] && vwan_status=$(cat "$STATE_DIR/vwan1_status")
    [ -f "$STATE_DIR/vwan2_status" ] && cmcc_status=$(cat "$STATE_DIR/vwan2_status")
    [ "$wan_status" = "up" ] && ! route_table_ready 100 && wan_status="down"
    [ "$vwan_status" = "up" ] && ! route_table_ready 200 && vwan_status="down"
    [ "$cmcc_status" = "up" ] && ! route_table_ready 400 && cmcc_status="down"

    if [ "$wan_status" = "up" ] && [ "$vwan_status" = "up" ] && [ "$cmcc_status" = "up" ]; then
        new_state="balanced"
    elif [ "$wan_status" = "up" ] && [ "$vwan_status" = "up" ]; then
        new_state="ct_only"
    elif [ "$wan_status" = "up" ] && [ "$cmcc_status" = "up" ]; then
        new_state="wan_cmcc"
    elif [ "$vwan_status" = "up" ] && [ "$cmcc_status" = "up" ]; then
        new_state="vwan_cmcc"
    elif [ "$wan_status" = "up" ]; then
        new_state="wan_only"
    elif [ "$vwan_status" = "up" ]; then
        new_state="vwan_only"
    elif [ "$cmcc_status" = "up" ]; then
        new_state="cmcc_only"
    else
        new_state="wan_only"
        log "multiwan-routing" "WARNING: All load-balance interfaces are down, defaulting to WAN"
    fi

    current_state="unknown"
    [ -f "$STATE_DIR/routing_state" ] && current_state=$(cat "$STATE_DIR/routing_state")
    if [ "$new_state" != "$current_state" ]; then
        log "multiwan-routing" "State changing from '$current_state' to '$new_state' (triggered by: $caller)"
        log "multiwan-routing" "Interface status: WAN=$wan_status, VWAN1=$vwan_status, VWAN2=$cmcc_status"
        if ! apply_destination_policy "$new_state"; then
            log "multiwan-routing" "ERROR: Failed to apply destination policy for $new_state"
            [ "$owns_lock" -eq 1 ] && flock -u 8
            return 1
        fi
        if ! printf '%s\n' "$new_state" > "$STATE_DIR/routing_state.new" || ! mv -f "$STATE_DIR/routing_state.new" "$STATE_DIR/routing_state"; then
            log "multiwan-routing" "ERROR: Failed to commit routing state $new_state"
            case "$current_state" in
                balanced|ct_only|wan_cmcc|vwan_cmcc|wan_only|vwan_only|cmcc_only) rollback_state="$current_state" ;;
                *) rollback_state="" ;;
            esac
            if [ -n "$rollback_state" ] && ! apply_destination_policy "$rollback_state"; then
                log "multiwan-routing" "ERROR: Failed to restore destination policy $rollback_state"
            fi
            rm -f "$STATE_DIR/routing_state" "$STATE_DIR/routing_state.new"
            [ "$owns_lock" -eq 1 ] && flock -u 8
            return 1
        fi
        log "multiwan-routing" "Destination policies updated for state: $new_state"

        if [ "$current_state" != "unknown" ]; then
            conntrack -F 2>/dev/null || true
            log "multiwan-routing" "Connection tracking table flushed after policy change"
        elif [ "$caller" = "hotplug" ]; then
            conntrack -F 2>/dev/null || true
            log "multiwan-routing" "Connection tracking table flushed after hotplug policy change"
        fi
    else
        log "multiwan-routing" "No state change needed, current state: $current_state"
    fi
    ensure_ipv6_host_default || true
    [ "$owns_lock" -eq 1 ] && flock -u 8
    return 0
}

update_interface_status() {
    local interface="$1" new_status="$2" caller="${3:-unknown}"
    local status_file="$STATE_DIR/${interface}_status"
    local old_status="" lock_file="${MULTIWAN_LOCK_DIR:-/var/lock}/multiwan_policy"

    mkdir -p "$STATE_DIR" "${MULTIWAN_LOCK_DIR:-/var/lock}" || return 1
    exec 8>"$lock_file" || return 1
    flock 8 || return 1
    [ -f "$status_file" ] && old_status=$(cat "$status_file")
    printf '%s\n' "$new_status" > "$status_file.new" || { flock -u 8; return 1; }
    mv -f "$status_file.new" "$status_file" || { flock -u 8; return 1; }

    if ! MULTIWAN_POLICY_LOCK_HELD=1 update_global_routing "$caller"; then
        if [ -n "$old_status" ]; then
            printf '%s\n' "$old_status" > "$status_file.new" && mv -f "$status_file.new" "$status_file"
        else
            rm -f "$status_file"
        fi
        flock -u 8
        log "multiwan-status" "Failed to apply policy; restored $interface status to ${old_status:-unset}"
        return 1
    fi
    if [ "$caller" = "hotplug" ]; then
        printf '0\n' > "$STATE_DIR/${interface}_fail_count"
        printf '0\n' > "$STATE_DIR/${interface}_success_count"
    fi
    flock -u 8
    log "multiwan-status" "Interface $interface status updated to: $new_status (by: $caller)"
    return 0
}

# 向tracker进程发送信号
notify_tracker() {
    local interface="$1"
    local tracker_pid

    tracker_pid=$(pgrep -f "multiwan_tracker $interface")
    if [ -n "$tracker_pid" ]; then
        kill -USR1 "$tracker_pid" 2>/dev/null
        log "multiwan-signal" "Notified tracker for $interface (PID: $tracker_pid)"
        return 0
    fi
    log "multiwan-signal" "Warning: No tracker process found for interface $interface"
    return 1
}

# PPPoE重拨后刷新WireGuard回包的源公网地址。
update_special_udp_source() {
    local iface="$1" mark address

    case "$iface" in
        wan) mark="$ROUTE_MARK_WAN" ;;
        vwan1) mark="$ROUTE_MARK_VWAN1" ;;
        *) return 0 ;;
    esac
    address=$(ubus call network.interface."$iface" status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address')
    [ -n "$address" ] || return 1
    printf '%s\n' "delete element inet $NFT_TABLE special_udp_source_by_mark { $mark }" "add element inet $NFT_TABLE special_udp_source_by_mark { $mark : $address }" | nft -f -
}

# 启动阶段 PPPoE 常常还没拿到地址；短暂重试后交给 hotplug 补齐，不作为启动失败条件。
refresh_special_udp_sources() {
    local attempt=1 max_attempts=5

    while [ "$attempt" -le "$max_attempts" ]; do
        if update_special_udp_source wan && update_special_udp_source vwan1; then
            return 0
        fi
        [ "$attempt" -lt "$max_attempts" ] && sleep 2
        attempt=$((attempt + 1))
    done
    return 1
}


# --- 强制出口集合的持久化 ---
# 条目写入 /etc/multiwan/force_egress.list（该目录随 sysupgrade 保留），
# 服务启动/重启后由 restore_force_sets 重新灌入 nft。
force_store_file() {
    printf '%s\n' "${MULTIWAN_FORCE_FILE:-/etc/multiwan/force_egress.list}"
}

force_store_add() {
    local set="$1" element="$2" file tmp
    file=$(force_store_file)
    mkdir -p "${file%/*}" 2>/dev/null || true
    tmp="$file.new.$$"
    grep -v -x -F "$set $element" "$file" 2>/dev/null > "$tmp" || :
    printf '%s %s\n' "$set" "$element" >> "$tmp"
    mv -f "$tmp" "$file"
}

force_store_del() {
    local element="$1" file tmp count=0
    file=$(force_store_file)
    [ -f "$file" ] || return 0
    tmp="$file.new.$$"
    awk -v e="$element" '{ if ($2 != e) print; else c++ } END { exit (c > 0 ? 0 : 1) }' "$file" > "$tmp" || true
    mv -f "$tmp" "$file"
}

# 按持久化文件恢复强制集合（幂等；元素已存在时忽略）
restore_force_sets() {
    local file set element rc=0
    file=$(force_store_file)
    [ -f "$file" ] || return 0
    while read -r set element; do
        [ -n "$set" ] || continue
        [ -n "$element" ] || continue
        case "$set" in \#*) continue ;; esac
        nft get element inet "$NFT_TABLE" "$set" { "$element" } >/dev/null 2>&1 && continue
        nft add element inet "$NFT_TABLE" "$set" { "$element" } 2>/dev/null \
            || { log "multiwan-force" "Failed to restore $element into $set"; rc=1; }
    done < "$file"
    return "$rc"
}

# 使用 ubus 获取接口信息并设置路由
setup_route() {
    local iface=$1
    local table=$2
    local device gateway status
    local max_retries=3
    local retry_count=0

    # BusyBox ash supports single-digit file descriptors reliably.
    local lock_dir="${MULTIWAN_LOCK_DIR:-/var/lock}"
    mkdir -p "$lock_dir" || return 1
    local lock_file="$lock_dir/multiwan_route_${table}"
    exec 9>"$lock_file" || return 1
    if ! flock -n 9; then
        log "multiwan-route" "Route setup for table $table is already in progress, skipping"
        return 1
    fi

    while [ $retry_count -lt $max_retries ]; do
        retry_count=$((retry_count + 1))

        # 检查接口是否存在
        if ! ubus list network.interface."$iface" >/dev/null 2>&1; then
            log "multiwan-route" "Interface $iface not found (attempt $retry_count/$max_retries)"
            if [ $retry_count -eq $max_retries ]; then
                log "multiwan-route" "Interface $iface not present after $max_retries attempts. Checking if table $table has routes..."
                # 检查路由表是否为空，如果为空则说明可能是重拨后的问题
                if ! ip route show table "$table" | grep -q "default"; then
                    log "multiwan-route" "No default route in table $table, will retry later rather than preserve empty table"
                else
                    log "multiwan-route" "Preserving existing routes in table $table"
                fi
                flock -u 9
                return 1
            fi
            sleep 2
            continue
        fi

        # 获取接口状态
        status=$(ubus call network.interface."$iface" status 2>/dev/null | jsonfilter -e '@.up')
        if [ "$status" != "true" ]; then
            log "multiwan-route" "Interface $iface is down (attempt $retry_count/$max_retries)"
            if [ $retry_count -eq $max_retries ]; then
                log "multiwan-route" "Interface $iface still down after $max_retries attempts. Checking table $table status..."
                if ! ip route show table "$table" | grep -q "default"; then
                    log "multiwan-route" "No default route in table $table, interface may need more time after redial"
                else
                    log "multiwan-route" "Preserving existing routes in table $table"
                fi
                flock -u 9
                return 1
            fi
            sleep 2
            continue
        fi

        # 获取L3设备
        device=$(ubus call network.interface."$iface" status 2>/dev/null | jsonfilter -e '@.l3_device')
        if [ -z "$device" ]; then
            log "multiwan-route" "Could not find l3_device for $iface (attempt $retry_count/$max_retries)"
            if [ $retry_count -eq $max_retries ]; then
                log "multiwan-route" "No l3_device for $iface after $max_retries attempts. Preserving existing routes in table $table."
                flock -u 9
                return 1
            fi
            sleep 2
            continue
        fi

        # 检查设备是否真实存在
        if ! ip link show "$device" >/dev/null 2>&1; then
            log "multiwan-route" "Device $device does not exist (attempt $retry_count/$max_retries)"
            if [ $retry_count -eq $max_retries ]; then
                log "multiwan-route" "Device $device not found after $max_retries attempts. Preserving existing routes in table $table."
                flock -u 9
                return 1
            fi
            sleep 2
            continue
        fi

        # 成功获取到设备信息，跳出重试循环
        break
    done

    # 尝试获取网关
    gateway=$(ubus call network.interface."$iface" status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].nexthop' -e '@["ipv4-address"][0].ptpaddress')
    log "multiwan-route" "Setting up route for $iface (dev: $device) in table $table"
    if [ -n "$gateway" ]; then
        if ip route replace default via "$gateway" dev "$device" table "$table" 2>/dev/null; then
            log "multiwan-route" "  -> Route: default via $gateway dev $device table $table"
        elif ip route replace default dev "$device" table "$table" 2>/dev/null; then
            log "multiwan-route" "  -> Route: default dev $device table $table (fallback)"
        else
            log "multiwan-route" "  -> Failed to install default route for $device in table $table"
            flock -u 9
            return 1
        fi
    elif ip route replace default dev "$device" table "$table" 2>/dev/null; then
        log "multiwan-route" "  -> Route: default dev $device table $table (no gateway specified)"
    else
        log "multiwan-route" "  -> Failed to install default route for $device in table $table"
        flock -u 9
        return 1
    fi

    # 若设备持有全局IPv6地址，则同时在该table安装IPv6默认路由（IPv6-only出口如vwan2也适用）。
    if ip -6 -o addr show dev "$device" scope global 2>/dev/null | grep -q 'inet6 '; then
        ip -6 route replace default dev "$device" table "$table" 2>/dev/null \
            && log "multiwan-route" "  -> IPv6 default route: default dev $device table $table" \
            || log "multiwan-route" "  -> Warning: failed to install IPv6 default route in table $table"
    fi

    flock -u 9
    return 0
}

# 检查接口健康状况的通用函数（从mwan3借鉴）
check_interface_health() {
    local interface="$1"
    local track_ip_list="$2"
    local reliability="$3"
    local count="$4"
    local size="$5"
    local timeout="$6"
    local ttl="$7"

    local l3_dev successes=0

    # 获取接口的L3设备
    l3_dev=$(ubus call network.interface."$interface" status 2>/dev/null | jsonfilter -e '@.l3_device')
    if [ -z "$l3_dev" ]; then
        return 1
    fi

    # 按接口family选择ping工具；IPv6接口需用接口上的全局源地址绑定，否则策略路由会选错出口。
    local ping_bin=ping ping_src="$l3_dev"
    if [ "$(uci -q get multiwan."$interface".family || echo ipv4)" = ipv6 ]; then
        ping_bin=ping6
        ping_src=$(ip -6 -o addr show dev "$l3_dev" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
        [ -n "$ping_src" ] || return 1
    fi

    # 对每个跟踪IP进行ping测试
    for ip in $track_ip_list; do
        if "$ping_bin" -c "$count" -W "$timeout" -s "$size" -t "$ttl" -I "$ping_src" "$ip" >/dev/null 2>&1; then
            successes=$((successes + 1))
        fi
    done

    [ $successes -ge $reliability ] && return 0 || return 1
}

