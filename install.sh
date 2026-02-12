#!/bin/sh

# 雷神加速器辅助插件 (leigodhelper) 一键安装脚本
# 适用环境: OpenWrt 21.02+

GITHUB_RAW="https://raw.githubusercontent.com/ColdDewLy/luci-app-leigodhelper/main"

echo "开始安装 雷神加速器辅助插件..."

# 检查 curl
if ! command -v curl >/dev/null; then
    echo "正在安装 curl..."
    opkg update && opkg install curl
fi

# 创建目录
mkdir -p /usr/bin
mkdir -p /etc/init.d
mkdir -p /etc/config
mkdir -p /usr/share/luci/menu.d
mkdir -p /usr/share/rpcd/acl.d
mkdir -p /www/luci-static/resources/view/leigodhelper

# 下载文件
echo "正在下载文件..."
curl -fsSL ${GITHUB_RAW}/usr/bin/leigodhelper_sync.sh -o /usr/bin/leigodhelper_sync.sh
curl -fsSL ${GITHUB_RAW}/etc/init.d/leigodhelper -o /etc/init.d/leigodhelper
curl -fsSL ${GITHUB_RAW}/etc/config/leigodhelper -o /etc/config/leigodhelper
curl -fsSL ${GITHUB_RAW}/usr/share/luci/menu.d/luci-app-leigodhelper.json -o /usr/share/luci/menu.d/luci-app-leigodhelper.json
curl -fsSL ${GITHUB_RAW}/usr/share/rpcd/acl.d/luci-app-leigodhelper.json -o /usr/share/rpcd/acl.d/luci-app-leigodhelper.json
curl -fsSL ${GITHUB_RAW}/www/luci-static/resources/view/leigodhelper/main.js -o /www/luci-static/resources/view/leigodhelper/main.js

# 设置权限
chmod +x /usr/bin/leigodhelper_sync.sh
chmod +x /etc/init.d/leigodhelper

# 初始化服务
echo "正在启动服务..."
/etc/init.d/leigodhelper enable
/etc/init.d/leigodhelper restart

# 清理 LuCI 缓存
echo "清理 LuCI 缓存..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/*
/etc/init.d/rpcd restart

echo "安装完成！请刷新路由器界面。菜单路径: 服务 -> 雷神加速器辅助插件"
