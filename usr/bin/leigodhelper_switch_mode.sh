#!/bin/sh
# 路径: /usr/bin/leigodhelper_switch_mode.sh
# 权限: chmod +x /usr/bin/leigodhelper_switch_mode.sh
#
# 雷神加速服务 (acc) tproxy <-> tun 模式切换脚本
# 用法: leigodhelper_switch_mode.sh <tun|tproxy>
#
# 由 LuCI 控制器后台调用，全部输出写入 LOG_FILE 供前端轮询显示。

LOG_FILE="${LOG_FILE:-/tmp/leigodhelper_switch.log}"
ACC_INIT="${ACC_INIT:-/etc/init.d/acc}"
PS_CMD="${PS_CMD:-ps}"
# acc 启动行的定位标识（与 -m <mode> 同行）
MARKER="10.20.30.40"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

TARGET="$1"

# --- 参数白名单校验 ---
if [ "$TARGET" != "tun" ] && [ "$TARGET" != "tproxy" ]; then
    log "错误: 非法的目标模式 '$TARGET' (仅支持 tun / tproxy)。"
    log "===切换失败==="
    exit 1
fi

log "===开始切换加速模式 -> $TARGET==="

# --- 前置校验: acc 启动脚本存在 ---
if [ ! -f "$ACC_INIT" ]; then
    log "错误: 未找到雷神加速服务启动脚本 $ACC_INIT，请先安装官方雷神加速插件。"
    log "===切换失败==="
    exit 1
fi

# --- 解析当前模式 ---
CUR_LINE=$(grep "$MARKER" "$ACC_INIT" | head -n 1)
CUR_MODE=""
case "$CUR_LINE" in
    *tproxy*) CUR_MODE="tproxy" ;;
    *tun*)    CUR_MODE="tun" ;;
esac

if [ -n "$CUR_MODE" ]; then
    log "当前模式: $CUR_MODE"
else
    log "警告: 无法从 $ACC_INIT 解析当前模式，继续尝试切换。"
fi

# --- 幂等: 已是目标模式则退出 ---
if [ "$CUR_MODE" = "$TARGET" ]; then
    log "已是 $TARGET 模式，无需切换。"
    log "===切换成功==="
    exit 0
fi

# --- 步骤 1: 停止雷神加速服务 ---
log "[1/5] 停止雷神加速服务..."
"$ACC_INIT" stop >> "$LOG_FILE" 2>&1

# 兜底 kill acc 相关进程（排除 grep 自身与本插件进程，避免误杀）
ACC_PIDS=$($PS_CMD | grep acc | grep -v grep | grep -v leigodhelper | grep -v acc_switch | awk '{print $1}')
if [ -n "$ACC_PIDS" ]; then
    log "清理残留 acc 进程: $ACC_PIDS"
    echo "$ACC_PIDS" | xargs -r kill -9 2>/dev/null
fi

# --- 步骤 2: 修改启动脚本模式 ---
log "[2/5] 修改启动脚本模式 ($ACC_INIT)..."
TMP_ACC_INIT="${ACC_INIT}.tmp.$$"
if [ "$TARGET" = "tun" ]; then
    sed "/$MARKER/ s/tproxy/tun/" "$ACC_INIT" > "$TMP_ACC_INIT"
else
    sed "/$MARKER/ s/tun/tproxy/" "$ACC_INIT" > "$TMP_ACC_INIT"
fi

if [ $? -ne 0 ] || [ ! -s "$TMP_ACC_INIT" ]; then
    rm -f "$TMP_ACC_INIT"
    log "错误: 启动脚本模式替换失败。"
    log "===切换失败==="
    exit 1
fi
cat "$TMP_ACC_INIT" > "$ACC_INIT"
rm -f "$TMP_ACC_INIT"

# 校验修改结果
NEW_LINE=$(grep "$MARKER" "$ACC_INIT" | head -n 1)
case "$NEW_LINE" in
    *"$TARGET"*) log "启动脚本已更新为 $TARGET 模式。" ;;
    *) log "警告: 启动脚本修改后未检测到 $TARGET 关键字，请手动确认。" ;;
esac

# # --- 步骤 3: 安装 tun 模式依赖 (仅切换到 tun 时) ---
# if [ "$TARGET" = "tun" ]; then
#     log "[3/5] 安装 tun 模式依赖包 (opkg)..."
#     opkg update >> "$LOG_FILE" 2>&1
#     opkg install libpcap iptables kmod-tun kmod-ipt-nat kmod-ipt-ipset ipset curl >> "$LOG_FILE" 2>&1
#     if [ $? -eq 0 ]; then
#         log "依赖包安装完成。"
#     else
#         log "警告: 依赖包安装可能未完全成功，请检查上方 opkg 输出（需保证 opkg 源可访问）。"
#     fi
# else
#     log "[3/5] 切换到 tproxy 模式，跳过依赖安装。"
# fi

# --- 步骤 4: 启动雷神加速服务 ---
log "[4/5] 启动雷神加速服务..."
"$ACC_INIT" start >> "$LOG_FILE" 2>&1

# --- 步骤 5: 验证进程 ---
log "[5/5] 验证加速进程..."
sleep 2
PS_OUT=$($PS_CMD | grep acc | grep -v grep | grep -v leigodhelper | grep -v acc_switch)
if [ -n "$PS_OUT" ]; then
    log "加速进程运行中:"
    echo "$PS_OUT" >> "$LOG_FILE"
    log "===切换成功==="
    exit 0
else
    log "错误: 未检测到加速进程，启动可能失败，请检查 acc 日志。"
    log "===切换失败==="
    exit 1
fi
