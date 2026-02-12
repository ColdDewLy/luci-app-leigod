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

# 空闲检测状态变量
IDLE_START_TIME=0
LAST_BYTES=0
NOTIFICATION_SENT=false

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
}

remove_singbox_bypass() {
    local ips=$1
    if nft list set inet sing-box leigod_bypass >/dev/null 2>&1; then
        for ip in $ips; do
            nft delete element inet sing-box leigod_bypass { $ip } >/dev/null 2>&1
        done
    fi
}

clean_singbox_bypass() {
    if nft list set inet sing-box leigod_bypass >/dev/null 2>&1; then
        nft flush set inet sing-box leigod_bypass >/dev/null 2>&1
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

# --- 核心函数：检测雷神真实运行状态 ---
check_leishen_status() {
    local tun_iface=$1
    local ipset_name=$2

    if ip addr show "$tun_iface" >/dev/null 2>&1; then
        echo "tun"
        return
    fi

    if iptables -t mangle -S GAMEACC 2>/dev/null | grep -q -E "match-set $ipset_name src.*TPROXY"; then
        echo "tproxy"
        return
    fi

    echo "off"
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
}

# --- 动作：清理规则 ---
clean_rules() {
    :
}

sync_task() {
    local ips=$1
    local tun=$2
    local ipset=$3
    local mark=$4

    if [ -z "$ips" ]; then return; fi

    local state=$(check_leishen_status "$tun" "$ipset")

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

handle_device() {
    local cfg="$1"
    local ip type
    config_get ip "$cfg" ip
    config_get type "$cfg" type
    if [ "$type" == "pc" ]; then
        LIST_PC="$LIST_PC $ip"
    elif [ "$type" == "console" ]; then
        LIST_CONSOLE="$LIST_CONSOLE $ip"
    fi
}

config_get_bool enabled main enabled 0
if [ "$enabled" -eq 0 ]; then
    exit 0
fi

config_get CHECK_INTERVAL main check_interval 5
config_foreach handle_device device

if [ "$1" == "stop" ]; then
    config_load leigodhelper
    clean_rules "$TUN_CONSOLE" "$IPSET_CONSOLE" "$MARK_CONSOLE"
    clean_rules "$TUN_PC"      "$IPSET_PC"      "$MARK_PC"
    clean_singbox_bypass
    clean_mihomo_bypass
    exit 0
fi

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
        clean_singbox_bypass
        clean_mihomo_bypass
        exit 0
    fi

    config_get CHECK_INTERVAL main check_interval 5
    config_get notify_idle main notify_idle 0
    config_get idle_threshold main idle_threshold 30

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

        if [ -n "$ip" ]; then
            if [ "$type" == "pc" ]; then
                LIST_PC="$LIST_PC $ip"
            elif [ "$type" == "console" ]; then
                LIST_CONSOLE="$LIST_CONSOLE $ip"
            fi
        fi
    }

    config_foreach handle_device device

    # 检测雷神是否在运行（任意一种类型）
    status_console=$(check_leishen_status "$TUN_CONSOLE" "$IPSET_CONSOLE")
    status_pc=$(check_leishen_status "$TUN_PC" "$IPSET_PC")

    if [ "$status_console" != "off" ] || [ "$status_pc" != "off" ]; then
        control_conflict_svc "true"
    else
        control_conflict_svc "false"
    fi

    sync_task "$LIST_CONSOLE" "$TUN_CONSOLE" "$IPSET_CONSOLE" "$MARK_CONSOLE"
    sync_task "$LIST_PC"      "$TUN_PC"      "$IPSET_PC"      "$MARK_PC"

    # 空闲流量检测逻辑
    if [ "$notify_idle" -eq 1 ]; then
        if [ "$status_console" != "off" ] || [ "$status_pc" != "off" ]; then
            # 获取 GAMEACC 链中 TPROXY 规则的累计字节数（只统计实际加速的流量）
            current_bytes=$(iptables -t mangle -vnxL GAMEACC 2>/dev/null | awk '$3=="TPROXY" {sum+=$2} END {print sum+0}')

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

    sleep "$CHECK_INTERVAL"
done
