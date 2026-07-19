#!/bin/bash
# 路径: /usr/bin/leigodhelper_sync.sh
# 权限: chmod +x /usr/bin/leigodhelper_sync.sh

# . /lib/functions.conf
. /lib/functions.sh

# 日志文件路径
LOG_FILE="/tmp/leigodhelper.log"

# 常量定义
IPSET_CONSOLE="target_Game"
TUN_CONSOLE="tun_Game"
MARK_CONSOLE="0x103"

IPSET_PC="target_PC"
TUN_PC="tun_PC"
MARK_PC="0x102"

FW4_FORWARD_CHAIN="leigodhelper_forward"
LAN_DEVICE="br-lan"

# 空闲检测状态变量
IDLE_START_TIME=0
LAST_BYTES=0
NOTIFICATION_SENT=false

# 加速时长检测状态变量
ACCEL_START_TIME=0
ACCEL_DURATION_NOTIFIED=false

# 状态变化日志追踪
PREV_STATUS="unknown"

# 当前雷神进程快照，每轮检测时刷新
ACC_PROCESS_LIST=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

send_notification() {
    local message="$1"
    log "NOTIFICATION: $message"
    logger -t leigodhelper "Idle Notification: $message"

    config_get notification_type main notification_type "none"

    if [ "$notification_type" == "telegram" ]; then
        config_get tg_token main tg_token
        config_get tg_chatid main tg_chatid
        if [ -n "$tg_token" ] && [ -n "$tg_chatid" ]; then
            log "Sending Telegram notification..."
            local res=$(curl -s -X POST "https://api.telegram.org/bot${tg_token}/sendMessage" \
                -d "chat_id=${tg_chatid}" \
                -d "text=${message}")
            if echo "$res" | grep -q '"ok":true'; then
                log "Telegram notification sent successfully."
            else
                log "Failed to send Telegram notification: $res"
            fi
        fi
    elif [ "$notification_type" == "bark" ]; then
        config_get bark_key main bark_key
        if [ -n "$bark_key" ]; then
            log "Sending Bark notification..."
            local res=$(curl -s -L -G "https://api.day.app/${bark_key}" \
                --data-urlencode "title=雷神加速器" \
                --data-urlencode "body=${message}")
            if echo "$res" | grep -q '"code":200'; then
                log "Bark notification sent successfully."
            else
                log "Failed to send Bark notification: $res"
            fi
        fi
    elif [ "$notification_type" == "wecom" ]; then
        config_get wecom_key main wecom_key
        if [ -n "$wecom_key" ]; then
            log "Sending WeCom notification..."
            local res=$(curl -s -X POST "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=${wecom_key}" \
                -H 'Content-Type: application/json' \
                -d "{\"msgtype\": \"text\", \"text\": {\"content\": \"【雷神加速器】\n${message}\"}}")
            if echo "$res" | grep -q '"errcode":0'; then
                log "WeCom notification sent successfully."
            else
                log "Failed to send WeCom notification: $res"
            fi
        fi
    fi
}

# --- Singbox 冲突解决函数 ---
ensure_singbox_bypass() {
    local ips=$1

    # 检查 sing-box 表是否存在
    if ! nft list table inet sing-box >/dev/null 2>&1; then
        return
    fi

    # 创建 bypass 集合 (如果不存在)
    if ! nft list set inet sing-box leigod_bypass >/dev/null 2>&1; then
        nft add set inet sing-box leigod_bypass { type ipv4_addr\; }
    fi

    # 插入 bypass 规则 (如果不存在)
    if ! nft list chain inet sing-box prerouting | grep -q "@leigod_bypass counter packets"; then
        nft insert rule inet sing-box prerouting ip saddr @leigod_bypass counter return
    fi

    if ! nft list chain inet sing-box prerouting_udp_icmp | grep -q "@leigod_bypass counter packets"; then
        nft insert rule inet sing-box prerouting_udp_icmp ip saddr @leigod_bypass counter return
    fi

    # 添加 IP 到集合
    for ip in $ips; do
        nft add element inet sing-box leigod_bypass { $ip } >/dev/null 2>&1
    done

    ensure_singbox_bypass6 "$ips"
}

ensure_singbox_bypass6() {
    local ips=$1
    local ip mac ipv6

    if ! nft list table inet sing-box >/dev/null 2>&1; then
        return
    fi

    if ! nft list set inet sing-box leigod_bypass6 >/dev/null 2>&1; then
        nft add set inet sing-box leigod_bypass6 { type ipv6_addr\; } >/dev/null 2>&1
    fi

    if ! nft list chain inet sing-box prerouting | grep -q "ip6 saddr @leigod_bypass6"; then
        nft insert rule inet sing-box prerouting ip6 saddr @leigod_bypass6 counter return >/dev/null 2>&1
    fi

    if ! nft list chain inet sing-box prerouting_udp_icmp | grep -q "ip6 saddr @leigod_bypass6"; then
        nft insert rule inet sing-box prerouting_udp_icmp ip6 saddr @leigod_bypass6 counter return >/dev/null 2>&1
    fi

    for ip in $ips; do
        mac=$(ip neigh show "$ip" 2>/dev/null | awk '$4 == "lladdr" { print tolower($5); exit }')
        [ -z "$mac" ] && continue

        ip -6 neigh show dev "$LAN_DEVICE" 2>/dev/null | \
            awk -v mac="$mac" '($2 == "lladdr" && tolower($3) == mac) || ($4 == "lladdr" && tolower($5) == mac) { print $1 }' | \
            while read -r ipv6; do
                [ -n "$ipv6" ] && nft add element inet sing-box leigod_bypass6 { "$ipv6" } >/dev/null 2>&1
            done
    done
}

remove_singbox_bypass() {
    local ips=$1
    if nft list set inet sing-box leigod_bypass >/dev/null 2>&1; then
        for ip in $ips; do
            nft delete element inet sing-box leigod_bypass { $ip } >/dev/null 2>&1
        done
    fi

    remove_singbox_bypass6 "$ips"
}

remove_singbox_bypass6() {
    local ips=$1
    local ip mac ipv6

    if ! nft list set inet sing-box leigod_bypass6 >/dev/null 2>&1; then
        return
    fi

    for ip in $ips; do
        mac=$(ip neigh show "$ip" 2>/dev/null | awk '$4 == "lladdr" { print tolower($5); exit }')
        [ -z "$mac" ] && continue

        ip -6 neigh show dev "$LAN_DEVICE" 2>/dev/null | \
            awk -v mac="$mac" '($2 == "lladdr" && tolower($3) == mac) || ($4 == "lladdr" && tolower($5) == mac) { print $1 }' | \
            while read -r ipv6; do
                [ -n "$ipv6" ] && nft delete element inet sing-box leigod_bypass6 { "$ipv6" } >/dev/null 2>&1
            done
    done
}

clean_singbox_bypass() {
    if nft list set inet sing-box leigod_bypass >/dev/null 2>&1; then
        nft flush set inet sing-box leigod_bypass >/dev/null 2>&1
    fi
    if nft list set inet sing-box leigod_bypass6 >/dev/null 2>&1; then
        nft flush set inet sing-box leigod_bypass6 >/dev/null 2>&1
    fi
}

# --- Mihomo 冲突解决函数 ---
ensure_mihomo_bypass() {
    local ips=$1

    # 检查 mihomo 表是否存在
    if ! nft list table inet mihomo >/dev/null 2>&1; then
        return
    fi

    # 创建 bypass 集合 (如果不存在)
    if ! nft list set inet mihomo leigod_bypass >/dev/null 2>&1; then
        nft add set inet mihomo leigod_bypass { type ipv4_addr\; }
    fi

    # 插入 bypass 规则 (如果不存在)
    if ! nft list chain inet mihomo prerouting | grep -q "@leigod_bypass counter packets"; then
        nft insert rule inet mihomo prerouting ip saddr @leigod_bypass counter return
    fi

    # 添加 IP 到集合
    for ip in $ips; do
        nft add element inet mihomo leigod_bypass { $ip } >/dev/null 2>&1
    done
}

remove_mihomo_bypass() {
    local ips=$1
    if nft list set inet mihomo leigod_bypass >/dev/null 2>&1; then
        for ip in $ips; do
            nft delete element inet mihomo leigod_bypass { $ip } >/dev/null 2>&1
        done
    fi
}

clean_mihomo_bypass() {
    if nft list set inet mihomo leigod_bypass >/dev/null 2>&1; then
        nft flush set inet mihomo leigod_bypass >/dev/null 2>&1
    fi
}

# --- 核心函数：控制冲突插件 ---
control_conflict_svc() {
    local leigod_active=$1
    config_get conflict_svc main conflict_svc "none"

    [ "$conflict_svc" = "none" ] && return

    if [ ! -f "/etc/init.d/$conflict_svc" ]; then
        log "警告: 配置的冲突插件 $conflict_svc 未安装 (未找到 /etc/init.d/$conflict_svc)"
        return
    fi

    local svc_status=$(/etc/init.d/"$conflict_svc" status 2>/dev/null)

    if [ "$leigod_active" = "true" ]; then
        if echo "$svc_status" | grep -q "running"; then
            log "检测到雷神已启动，正在关闭 $conflict_svc 插件以避免冲突..."
            /etc/init.d/"$conflict_svc" stop
        fi
    else
        if ! echo "$svc_status" | grep -q "running"; then
            log "检测到雷神已关闭，正在重新启动 $conflict_svc 插件..."
            /etc/init.d/"$conflict_svc" start
        fi
    fi
}

# 只有 -r acc 的 TUN 进程才表示存在真实加速任务。
# -r web -m tun 是雷神未开启加速时也会常驻的管理进程。
is_tun_acc_active() {
    local task_type=$1

    printf '%s\n' "$ACC_PROCESS_LIST" | awk -v task_type="$task_type" '
        function has_option(option, value, i) {
            for (i = 1; i < NF; i++) {
                if ($i == option && $(i + 1) == value) {
                    return 1
                }
            }
            return 0
        }

        /\/acc-gw\.router[^[:space:]]*/ &&
        has_option("-r", "acc") &&
        has_option("-m", "tun") &&
        (task_type == "" || has_option("-t", task_type)) {
            found = 1
            exit
        }

        END { exit !found }
    '
}

# --- 核心函数：检测雷神真实运行状态 ---
check_leishen_status() {
    local tun_iface=$1
    local ipset_name=$2
    local task_type=""

    case "$tun_iface" in
        tun_Game) task_type="Game" ;;
        tun_PC)   task_type="PC" ;;
    esac

    if is_tun_acc_active "$task_type"; then
        echo "tun"
        return
    fi

    if iptables -t mangle -S GAMEACC 2>/dev/null | grep -q -E "match-set $ipset_name src.*TPROXY"; then
        echo "tproxy"
        return
    fi

    echo "off"
}

get_lan_device() {
    local device

    device=$(uci -q get network.lan.device 2>/dev/null)
    if [ -z "$device" ] && command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
        device=$(ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@.l3_device')
    fi

    echo "${device:-br-lan}"
}

remove_commented_iptables_rules() {
    local table=$1
    local chain=$2
    local comment=$3
    local rule_num

    while true; do
        rule_num=$(iptables -t "$table" -nL "$chain" --line-numbers 2>/dev/null | \
            awk -v comment="$comment" 'index($0, comment) { print $1; exit }')
        [ -z "$rule_num" ] && break
        iptables -t "$table" -D "$chain" "$rule_num" >/dev/null 2>&1 || break
    done
}

remove_tun_rules() {
    local tun=$1

    remove_commented_iptables_rules mangle GAMEACC "leigodhelper-$tun-mark"
    remove_commented_iptables_rules filter FORWARD "leigodhelper-$tun-out"
    remove_commented_iptables_rules filter FORWARD "leigodhelper-$tun-in"
}

ensure_tun_rules() {
    local tun=$1
    local ipset_name=$2
    local mark=$3
    local mark_comment="leigodhelper-$tun-mark"
    local out_comment="leigodhelper-$tun-out"
    local in_comment="leigodhelper-$tun-in"

    if ! iptables -t mangle -C GAMEACC -i "$LAN_DEVICE" \
        -m set --match-set "$ipset_name" src \
        -m comment --comment "$mark_comment" \
        -j MARK --set-xmark "$mark/0xffffffff" >/dev/null 2>&1; then
        remove_commented_iptables_rules mangle GAMEACC "$mark_comment"
        if iptables -t mangle -A GAMEACC -i "$LAN_DEVICE" \
            -m set --match-set "$ipset_name" src \
            -m comment --comment "$mark_comment" \
            -j MARK --set-xmark "$mark/0xffffffff" >/dev/null 2>&1; then
            log "已添加 TUN 标记规则: $LAN_DEVICE -> $tun ($ipset_name, mark=$mark)"
        else
            log "错误: 无法添加 TUN 标记规则: $LAN_DEVICE -> $tun"
        fi
    fi

    if ! iptables -t filter -C FORWARD -i "$LAN_DEVICE" -o "$tun" \
        -m comment --comment "$out_comment" -j ACCEPT >/dev/null 2>&1; then
        remove_commented_iptables_rules filter FORWARD "$out_comment"
        iptables -t filter -A FORWARD -i "$LAN_DEVICE" -o "$tun" \
            -m comment --comment "$out_comment" -j ACCEPT >/dev/null 2>&1
    fi

    if ! iptables -t filter -C FORWARD -i "$tun" -o "$LAN_DEVICE" \
        -m conntrack --ctstate RELATED,ESTABLISHED \
        -m comment --comment "$in_comment" -j ACCEPT >/dev/null 2>&1; then
        remove_commented_iptables_rules filter FORWARD "$in_comment"
        iptables -t filter -A FORWARD -i "$tun" -o "$LAN_DEVICE" \
            -m conntrack --ctstate RELATED,ESTABLISHED \
            -m comment --comment "$in_comment" -j ACCEPT >/dev/null 2>&1
    fi
}

ensure_fw4_forward_chain() {
    nft list table inet fw4 >/dev/null 2>&1 || return 1

    if ! nft list chain inet fw4 "$FW4_FORWARD_CHAIN" >/dev/null 2>&1; then
        nft add chain inet fw4 "$FW4_FORWARD_CHAIN" >/dev/null 2>&1 || return 1
    fi

    if ! nft list chain inet fw4 forward 2>/dev/null | grep -q "jump $FW4_FORWARD_CHAIN"; then
        nft insert rule inet fw4 forward jump "$FW4_FORWARD_CHAIN" >/dev/null 2>&1 || return 1
    fi

    return 0
}

sync_fw4_tun_rules() {
    local status_console=$1
    local status_pc=$2
    local current_rules
    local current_rule_count
    local expected_rule_count=0
    local needs_update=false

    ensure_fw4_forward_chain || return

    current_rules=$(nft list chain inet fw4 "$FW4_FORWARD_CHAIN" 2>/dev/null)

    if [ "$status_console" = "tun" ] && [ -n "$LIST_CONSOLE" ]; then
        expected_rule_count=$((expected_rule_count + 2))
        echo "$current_rules" | grep -q "leigodhelper-$TUN_CONSOLE-out" || needs_update=true
        echo "$current_rules" | grep -q "leigodhelper-$TUN_CONSOLE-in" || needs_update=true
        echo "$current_rules" | grep -q "counter.*leigodhelper-$TUN_CONSOLE-out" || needs_update=true
        echo "$current_rules" | grep -q "counter.*leigodhelper-$TUN_CONSOLE-in" || needs_update=true
    elif echo "$current_rules" | grep -q "leigodhelper-$TUN_CONSOLE-"; then
        needs_update=true
    fi

    if [ "$status_pc" = "tun" ] && [ -n "$LIST_PC" ]; then
        expected_rule_count=$((expected_rule_count + 2))
        echo "$current_rules" | grep -q "leigodhelper-$TUN_PC-out" || needs_update=true
        echo "$current_rules" | grep -q "leigodhelper-$TUN_PC-in" || needs_update=true
        echo "$current_rules" | grep -q "counter.*leigodhelper-$TUN_PC-out" || needs_update=true
        echo "$current_rules" | grep -q "counter.*leigodhelper-$TUN_PC-in" || needs_update=true
    elif echo "$current_rules" | grep -q "leigodhelper-$TUN_PC-"; then
        needs_update=true
    fi

    current_rule_count=$(echo "$current_rules" | grep -c 'comment "leigodhelper-' 2>/dev/null)
    [ "$current_rule_count" -eq "$expected_rule_count" ] 2>/dev/null || needs_update=true
    [ "$needs_update" = false ] && return

    {
        echo "flush chain inet fw4 $FW4_FORWARD_CHAIN"
        if [ "$status_console" = "tun" ] && [ -n "$LIST_CONSOLE" ]; then
            echo "add rule inet fw4 $FW4_FORWARD_CHAIN iifname \"$LAN_DEVICE\" oifname \"$TUN_CONSOLE\" counter accept comment \"leigodhelper-$TUN_CONSOLE-out\""
            echo "add rule inet fw4 $FW4_FORWARD_CHAIN iifname \"$TUN_CONSOLE\" oifname \"$LAN_DEVICE\" ct state established,related counter accept comment \"leigodhelper-$TUN_CONSOLE-in\""
        fi
        if [ "$status_pc" = "tun" ] && [ -n "$LIST_PC" ]; then
            echo "add rule inet fw4 $FW4_FORWARD_CHAIN iifname \"$LAN_DEVICE\" oifname \"$TUN_PC\" counter accept comment \"leigodhelper-$TUN_PC-out\""
            echo "add rule inet fw4 $FW4_FORWARD_CHAIN iifname \"$TUN_PC\" oifname \"$LAN_DEVICE\" ct state established,related counter accept comment \"leigodhelper-$TUN_PC-in\""
        fi
    } | nft -f - >/dev/null 2>&1 || log "错误: 无法同步 fw4 TUN 转发规则"
}

flush_fw4_tun_rules() {
    if nft list chain inet fw4 "$FW4_FORWARD_CHAIN" >/dev/null 2>&1; then
        nft flush chain inet fw4 "$FW4_FORWARD_CHAIN" >/dev/null 2>&1
    fi
}

# --- 动作：应用规则 ---
apply_rules() {
    local mode=$1
    local tun=$2
    local ipset_name=$3
    local mark=$4
    local ips=$5

    for ip in $ips; do
        ipset test "$ipset_name" "$ip" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            ipset add "$ipset_name" "$ip" >/dev/null 2>&1
        fi
    done

    if [ "$mode" = "tun" ]; then
        ensure_tun_rules "$tun" "$ipset_name" "$mark"
    else
        remove_tun_rules "$tun"
    fi
}

# --- 动作：清理规则 ---
clean_rules() {
    local tun=$1
    remove_tun_rules "$tun"
}

sync_task() {
    local ips=$1
    local tun=$2
    local ipset=$3
    local mark=$4
    local state=$5

    if [ -z "$ips" ]; then
        clean_rules "$tun" "$ipset" "$mark"
        return
    fi

    if [ "$state" == "off" ]; then
        clean_rules "$tun" "$ipset" "$mark"
        remove_singbox_bypass "$ips"
        remove_mihomo_bypass "$ips"
    else
        apply_rules "$state" "$tun" "$ipset" "$mark" "$ips"
        # 尝试处理 sing-box 冲突
        ensure_singbox_bypass "$ips"
        # 尝试处理 mihomo 冲突
        ensure_mihomo_bypass "$ips"
    fi
}

# Load config
config_load leigodhelper

    guess_device_type() {
        local ip=$1
        local mac=$2
        
        if [ -n "$mac" ] && [ -f "/tmp/dhcp.leases" ]; then
            local hostname=$(grep -i "$mac" /tmp/dhcp.leases | awk '{print $4}' | tr 'A-Z' 'a-z')
            if [ -n "$hostname" ] && [ "$hostname" != "*" ]; then
                if echo "$hostname" | grep -qE "xbox|playstation|ps4|ps5|nintendo|switch|steamdeck"; then
                    echo "console"
                    return
                fi
            fi
        fi
        
        if [ -n "$mac" ] && [ -f "/usr/share/leigodhelper/console_oui.txt" ]; then
            local oui=$(echo "$mac" | cut -d':' -f1-3 | tr 'a-z' 'A-Z')
            if grep -q "$oui" "/usr/share/leigodhelper/console_oui.txt"; then
                echo "console"
                return
            fi
        fi
        
        echo "pc"
    }

    handle_device_stop() {
        local cfg="$1"
        # stop command doesn't need to sort devices into PC or Console precisely
    }

if [ "$1" == "stop" ]; then
    config_load leigodhelper
    LAN_DEVICE=$(get_lan_device)
    clean_rules "$TUN_CONSOLE" "$IPSET_CONSOLE" "$MARK_CONSOLE"
    clean_rules "$TUN_PC"      "$IPSET_PC"      "$MARK_PC"
    flush_fw4_tun_rules
    clean_singbox_bypass
    clean_mihomo_bypass
    exit 0
fi

config_get_bool enabled main enabled 0
if [ "$enabled" -eq 0 ]; then
    exit 0
fi

config_get CHECK_INTERVAL main check_interval 5
# config_foreach handle_device_stop device

log "雷神自动同步脚本已启动..."

while true; do
    # Reload configuration to pick up changes without restart
    LIST_PC=""
    LIST_CONSOLE=""

    config_load leigodhelper

    config_get_bool enabled main enabled 0
    if [ "$enabled" -eq 0 ]; then
        log "服务已在配置中禁用，退出。"
        clean_rules "$TUN_CONSOLE" "$IPSET_CONSOLE" "$MARK_CONSOLE"
        clean_rules "$TUN_PC"      "$IPSET_PC"      "$MARK_PC"
        flush_fw4_tun_rules
        clean_singbox_bypass
        clean_mihomo_bypass
        exit 0
    fi

    config_get CHECK_INTERVAL main check_interval 5
    config_get notify_idle main notify_idle 0
    config_get idle_threshold main idle_threshold 30
    LAN_DEVICE=$(get_lan_device)

    # Helper function to get IP from MAC if IP is missing
    get_ip_from_mac() {
        local mac=$1
        local ip=$(ip neigh show | grep -i "$mac" | awk '{print $1}' | head -n 1)
        echo "$ip"
    }

    handle_device() {
        local cfg="$1"
        local ip mac type
        config_get ip "$cfg" ip
        config_get mac "$cfg" mac
        config_get type "$cfg" type

        # Fallback to MAC discovery if IP is empty
        if [ -z "$ip" ] && [ -n "$mac" ]; then
            ip=$(get_ip_from_mac "$mac")
        fi

        if [ -z "$mac" ] && [ -n "$ip" ]; then
            mac=$(ip neigh show | grep -w "$ip" | awk '{print $5}' | head -n 1)
        fi

        if [ -n "$ip" ]; then
            if [ "$type" == "auto" ] || [ -z "$type" ]; then
                type=$(guess_device_type "$ip" "$mac")
            fi

            if [ "$type" == "pc" ]; then
                LIST_PC="$LIST_PC $ip"
            elif [ "$type" == "console" ]; then
                LIST_CONSOLE="$LIST_CONSOLE $ip"
            fi
        fi
    }

    config_foreach handle_device device

    # 检测雷神是否在运行（任意一种类型）
    ACC_PROCESS_LIST=$(ps w 2>/dev/null)
    status_console=$(check_leishen_status "$TUN_CONSOLE" "$IPSET_CONSOLE")
    status_pc=$(check_leishen_status "$TUN_PC" "$IPSET_PC")

    if [ "$status_console" != "off" ] || [ "$status_pc" != "off" ]; then
        cur_status="on"
        control_conflict_svc "true"
    else
        cur_status="off"
        control_conflict_svc "false"
    fi

    if [ "$cur_status" != "$PREV_STATUS" ]; then
        if [ "$cur_status" = "on" ]; then
            log "加速器已开启 (console=$status_console pc=$status_pc)"
        else
            log "加速器已关闭"
        fi
        PREV_STATUS="$cur_status"
    fi

    sync_task "$LIST_CONSOLE" "$TUN_CONSOLE" "$IPSET_CONSOLE" "$MARK_CONSOLE" "$status_console"
    sync_task "$LIST_PC"      "$TUN_PC"      "$IPSET_PC"      "$MARK_PC"      "$status_pc"
    sync_fw4_tun_rules "$status_console" "$status_pc"

    # 空闲流量检测逻辑
    if [ "$notify_idle" -eq 1 ]; then
        if [ "$status_console" != "off" ] || [ "$status_pc" != "off" ]; then
            # TProxy 统计代理规则，TUN 统计辅助插件添加的 MARK 规则。
            current_bytes=$(iptables -t mangle -vnxL GAMEACC 2>/dev/null | \
                awk '$3=="TPROXY" || /leigodhelper-tun_(Game|PC)-mark/ {sum+=$2} END {print sum+0}')

            if [ -n "$current_bytes" ] && [ "$current_bytes" -gt "$LAST_BYTES" ]; then
                # 有流量，重置计时器
                LAST_BYTES=$current_bytes
                IDLE_START_TIME=$(date +%s)
                NOTIFICATION_SENT=false
            else
                # 无流量 or 流量未增加
                current_time=$(date +%s)
                if [ "$IDLE_START_TIME" -eq 0 ]; then
                    IDLE_START_TIME=$current_time
                fi

                idle_duration=$((current_time - IDLE_START_TIME))
                threshold_seconds=$((idle_threshold * 60))

                if [ "$idle_duration" -ge "$threshold_seconds" ] && [ "$NOTIFICATION_SENT" = false ]; then
                    send_notification "检测到加速器已开启但无流量持续超过 ${idle_threshold} 分钟，请检查设备连接 or 关闭加速以节省时长。"
                    NOTIFICATION_SENT=true
                fi
            fi
        else
            # 加速器关闭，重置状态
            IDLE_START_TIME=0
            LAST_BYTES=0
            NOTIFICATION_SENT=false
        fi
    fi

    # 加速时长超限通知
    if [ "$status_console" != "off" ] || [ "$status_pc" != "off" ]; then
        current_time=$(date +%s)
        if [ "$ACCEL_START_TIME" -eq 0 ]; then
            ACCEL_START_TIME=$current_time
            ACCEL_DURATION_NOTIFIED=false
        fi
        accel_duration=$((current_time - ACCEL_START_TIME))
        if [ "$accel_duration" -ge 28800 ] && [ "$ACCEL_DURATION_NOTIFIED" = false ]; then
            accel_hours=$((accel_duration / 3600))
            send_notification "加速器已持续开启超过 ${accel_hours} 小时，请确认是否仍需加速。"
            ACCEL_DURATION_NOTIFIED=true
        fi
    else
        ACCEL_START_TIME=0
        ACCEL_DURATION_NOTIFIED=false
    fi

    sleep "$CHECK_INTERVAL"
done
