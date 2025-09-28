#!/bin/sh

# Multi-WAN Common Functions Library
# 共享函数库，避免代码冗余

STATE_DIR="/var/run/multiwan"
NFT_TABLE="multiwan"
PREROUTING_CHAIN="prerouting_hook"
OUTPUT_CHAIN="output_hook"

# 日志函数
log() {
    local tag="$1"
    local message="$2"
    logger -t "$tag" "$message"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$tag] $message"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$tag] $message" >> /var/log/multiwan.log
}

# 使用JSON结构化数据获取规则信息
get_chain_rules_json() {
    local chain=$1
    nft -j list chain inet $NFT_TABLE $chain 2>/dev/null
}

# 获取负载均衡规则的handle（jhash规则）
get_balance_rule_handle() {
    local chain=$1
    get_chain_rules_json $chain | jq -r '
        .nftables[]? | 
        select(.rule?) | 
        .rule | 
        select(.expr[]?.mangle?.value?.map?.key?.jhash?) | 
        .handle'
}

# 通用的规则mark值替换函数
replace_rule_mark() {
    local chain=$1
    local handle=$2
    local new_mark=$3
    
    # 获取当前规则的完整文本
    local current_rule=$(nft -a list chain inet $NFT_TABLE $chain 2>/dev/null | grep "handle $handle" | sed 's/.*handle [0-9]*//')
    if [ -n "$current_rule" ]; then
        # 替换mark值，保持其他部分不变
        local new_rule=$(echo "$current_rule" | sed "s/meta mark set 0x[0-9a-fA-F]*/meta mark set $new_mark/")
        nft replace rule inet $NFT_TABLE $chain handle $handle $new_rule 2>/dev/null
        return $?
    fi
    return 1
}

# 重定向所有mark规则到指定mark（保护IPTV规则）
redirect_marks_to_target() {
    local target_mark=$1
    
    # 遍历所有链，重定向mark规则
    for chain in "$PREROUTING_CHAIN" "$OUTPUT_CHAIN"; do
        # 获取策略路由规则（有简单mark值的规则）
        get_chain_rules_json "$chain" | jq -r '
            .nftables[]? | 
            select(.rule?) | 
            .rule | 
            select(
                # 只选择有简单mark值设置的规则（排除负载均衡规则）
                (.expr[] | select(.mangle?.value? and (.mangle.value | type) == "number"))
            ) | 
            {
                handle: .handle,
                current_mark: (.expr[] | select(.mangle?.value? and (.mangle.value | type) == "number") | .mangle.value)
            } | 
            "\(.handle)|\(.current_mark)"' | while IFS='|' read -r handle current_mark; do
            
            [ -z "$handle" ] || [ -z "$current_mark" ] && continue
            
            # 将当前mark转换为十六进制格式
            local hex_mark=$(printf "0x%x" "$current_mark")
            
            # 重定向到目标mark（保护IPTV规则0x300和已经是目标mark的规则）
            if [ "$hex_mark" != "0x300" ] && [ "$hex_mark" != "$target_mark" ]; then
                replace_rule_mark "$chain" "$handle" "$target_mark"
                log "multiwan-routing" "Redirected rule handle=$handle from $hex_mark to $target_mark"
            fi
        done
    done
}

# 从multiwan.nft文件恢复原始规则
restore_rules_from_config() {
    local nft_config_file="/etc/multiwan/multiwan.nft"
    
    if [ ! -f "$nft_config_file" ]; then
        log "multiwan-routing" "ERROR: NFT config file not found: $nft_config_file"
        return 1
    fi
    
    # 重新加载整个multiwan表来恢复原始规则
    log "multiwan-routing" "Reloading NFT rules from config file"
    if nft -f "$nft_config_file" 2>/dev/null; then
        log "multiwan-routing" "Successfully restored original rules from config"
        return 0
    else
        log "multiwan-routing" "ERROR: Failed to reload NFT rules from config"
        return 1
    fi
}

# 更新全局路由状态的核心逻辑
update_global_routing() {
    local caller="${1:-unknown}"
    local wan_status vwan_status new_state current_state
    
    # 读取各接口状态
    wan_status="down"
    vwan_status="down"
    [ -f "$STATE_DIR/wan_status" ] && wan_status=$(cat "$STATE_DIR/wan_status")
    [ -f "$STATE_DIR/vwan1_status" ] && vwan_status=$(cat "$STATE_DIR/vwan1_status")
    
    # 确定新的路由状态
    if [ "$wan_status" = "up" ] && [ "$vwan_status" = "up" ]; then
        new_state="balanced"
    elif [ "$wan_status" = "up" ] && [ "$vwan_status" = "down" ]; then
        new_state="wan_only"
    elif [ "$wan_status" = "down" ] && [ "$vwan_status" = "up" ]; then
        new_state="vwan_only"
    else
        # 都down时选择一个默认出口，避免流量黑洞
        new_state="wan_only"  # 默认尝试WAN，即使down也比负载均衡到两个down的出口好
        log "multiwan-routing" "WARNING: Both interfaces are down, defaulting to WAN"
    fi
    
    # 检查是否需要更新
    current_state="unknown"
    [ -f "$STATE_DIR/routing_state" ] && current_state=$(cat "$STATE_DIR/routing_state")
    
    if [ "$new_state" != "$current_state" ]; then
        log "multiwan-routing" "State changing from '$current_state' to '$new_state' (triggered by: $caller)"
        log "multiwan-routing" "Interface status: WAN=$wan_status, VWAN=$vwan_status"
        
        case "$new_state" in
            "balanced")
                # 负载均衡：从配置文件恢复原始规则
                restore_rules_from_config
                log "multiwan-routing" "Restored load balancing mode from config"
                ;;
            "wan_only"|"vwan_only")
                # 获取需要更新的规则handle（仅在需要修改规则时获取）
                local pr_balance_handle op_balance_handle
                
                pr_balance_handle=$(get_balance_rule_handle $PREROUTING_CHAIN)
                op_balance_handle=$(get_balance_rule_handle $OUTPUT_CHAIN)
                
                if [ -n "$pr_balance_handle" ] && [ -n "$op_balance_handle" ]; then
                    case "$new_state" in
                        "wan_only")
                            # 仅WAN可用：重定向所有流量到WAN
                            redirect_marks_to_target "0x100"
                            nft replace rule inet $NFT_TABLE $PREROUTING_CHAIN handle $pr_balance_handle meta mark set 0x100 2>/dev/null
                            nft replace rule inet $NFT_TABLE $OUTPUT_CHAIN handle $op_balance_handle meta mark set 0x100 2>/dev/null
                            log "multiwan-routing" "Redirected all traffic to WAN (VWAN down)"
                            ;;
                        "vwan_only")
                            # 仅VWAN可用：重定向所有流量到VWAN
                            redirect_marks_to_target "0x200"
                            nft replace rule inet $NFT_TABLE $PREROUTING_CHAIN handle $pr_balance_handle meta mark set 0x200 2>/dev/null
                            nft replace rule inet $NFT_TABLE $OUTPUT_CHAIN handle $op_balance_handle meta mark set 0x200 2>/dev/null
                            log "multiwan-routing" "Redirected all traffic to VWAN (WAN down)"
                            ;;
                    esac
                else
                    log "multiwan-routing" "ERROR: Could not find balance rule handles for single interface mode"
                    return 1
                fi
                ;;
        esac
        
        # 保存新状态
        echo "$new_state" > "$STATE_DIR/routing_state"
        log "multiwan-routing" "NFTables rules updated for state: $new_state"
        
        # 强制清理连接跟踪表以确保已有连接使用新路由
        # 这对于切换出口时的流量重定向非常重要
        if [ "$current_state" != "unknown" ] && [ "$current_state" != "$new_state" ]; then
            # 清理所有连接跟踪条目，让流量重新路由
            conntrack -F 2>/dev/null || true
            log "multiwan-routing" "Connection tracking table flushed to redirect existing connections"
            
            # 如果是从balanced切换到单出口，或者单出口之间切换，需要额外处理
            case "$current_state:$new_state" in
                "balanced:wan_only"|"balanced:vwan_only")
                    log "multiwan-routing" "Switched from load balancing to single interface, all traffic redirected"
                    ;;
                "wan_only:vwan_only"|"vwan_only:wan_only")
                    log "multiwan-routing" "Switched between single interfaces, all traffic redirected"
                    ;;
                "*:balanced")
                    log "multiwan-routing" "Switched to load balancing mode"
                    ;;
            esac
        elif [ "$caller" = "hotplug" ]; then
            # hotplug触发时也清理连接跟踪
            conntrack -F 2>/dev/null || true
            log "multiwan-routing" "Connection tracking table flushed for immediate effect (hotplug)"
        fi
    else
        log "multiwan-routing" "No state change needed, current state: $current_state"
    fi
    return 0
}

# 更新接口状态
update_interface_status() {
    local interface="$1"
    local new_status="$2"
    local caller="${3:-unknown}"
    
    # 确保状态目录存在
    mkdir -p "$STATE_DIR"
    
    # 更新接口状态
    echo "$new_status" > "$STATE_DIR/${interface}_status"
    
    # 重置计数器（仅在hotplug时）
    if [ "$caller" = "hotplug" ]; then
        echo "0" > "$STATE_DIR/${interface}_fail_count"
        echo "0" > "$STATE_DIR/${interface}_success_count"
    fi
    
    log "multiwan-status" "Interface $interface status updated to: $new_status (by: $caller)"
    
    # 更新全局路由状态
    update_global_routing "$caller"
}

# 向tracker进程发送信号
notify_tracker() {
    local interface="$1"
    local tracker_pid
    
    # 查找对应接口的tracker进程
    tracker_pid=$(pgrep -f "multiwan_tracker $interface")
    if [ -n "$tracker_pid" ]; then
        # 发送USR1信号触发立即检查
        kill -USR1 "$tracker_pid" 2>/dev/null
        log "multiwan-signal" "Notified tracker for $interface (PID: $tracker_pid)"
        return 0
    else
        log "multiwan-signal" "Warning: No tracker process found for interface $interface"
        return 1
    fi
}

# 使用 ubus 获取接口信息并设置路由
setup_route() {
    local iface=$1
    local table=$2
    local device gateway status
    local max_retries=3
    local retry_count=0

    # 添加锁机制防止竞态条件
    local lock_file="/var/lock/multiwan_route_${table}"
    exec 200>"$lock_file"
    if ! flock -n 200; then
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
                flock -u 200
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
                flock -u 200
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
                flock -u 200
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
                flock -u 200
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
    
    # 只删除默认路由，保留其他路由
    ip route del default table "$table" 2>/dev/null || true

    # 添加新的默认路由
    if [ -n "$gateway" ]; then
        if ip route add default via "$gateway" dev "$device" table "$table" 2>/dev/null; then
            log "multiwan-route" "  -> Route: default via $gateway dev $device table $table"
        else
            log "multiwan-route" "  -> Failed to add route via $gateway, trying device-only route"
            ip route add default dev "$device" table "$table" 2>/dev/null
            log "multiwan-route" "  -> Route: default dev $device table $table (fallback)"
        fi
    else
        if ip route add default dev "$device" table "$table" 2>/dev/null; then
            log "multiwan-route" "  -> Route: default dev $device table $table (no gateway specified)"
        else
            log "multiwan-route" "  -> Failed to add default route for $device in table $table"
            flock -u 200
            return 1
        fi
    fi
    
    flock -u 200
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
    
    # 对每个跟踪IP进行ping测试
    for ip in $track_ip_list; do
        if ping -c "$count" -W "$timeout" -s "$size" -t "$ttl" -I "$l3_dev" "$ip" >/dev/null 2>&1; then
            successes=$((successes + 1))
        fi
    done
    
    [ $successes -ge $reliability ] && return 0 || return 1
}

