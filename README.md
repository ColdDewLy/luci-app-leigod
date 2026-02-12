# luci-app-leigodhelper

雷神加速器辅助插件 (Leigod Accelerator Helper) OpenWrt LuCI 控制界面。

这是一个雷神加速器官方插件的辅助增强插件。

## 核心解决痛点

1. **单网口/非 br-lan 支持**：官方插件通常仅支持 `br-lan` 接口下的设备。本插件通过自定义 `iptables` 和 `ipset` 策略，解决了在非标准接口（如多拨、自定义物理网口）下官方插件无法正常识别或加速设备的问题。**尤其是N1盒子单网口设备**。
2. **空闲自动通知**：支持监控加速流量。当你忘记关闭加速器且持续一段时间无加速流量时，可通过 Telegram、Bark 或企业微信发送提醒，避免时长浪费。
3. **科学上网兼容**：支持和 singbox、mihomo tun 模式兼容。对于不兼容的情况，支持加速开启(关闭)时，自动关闭(开启)选择的科学上网插件。

## 主要功能

- **加速同步逻辑**：自动检测并同步雷神加速器的运行状态。
- **流量重定向**：基于 `iptables` 和 `ipset` 实现高效的流量转发。
- **多模式支持**：完美支持 TProxy 和 TUN 两种加速模式。
- **设备级管理**：通过 LuCI 界面针对每个设备单独配置路由规则。
- **广泛兼容**：兼容 OpenWrt 21、23 以及最新的 25 (支持 APK 包管理器) 版本。

## 安装说明

### 一键安装 (推荐)

在路由器 SSH 终端执行以下命令：

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ColdDewLy/luci-app-leigodhelper/main/install.sh)"
```

### 使用 OpenWrt SDK 编译

1. 将本项目目录移动或链接到 OpenWrt SDK 的 `package/utils/luci-app-leigodhelper` 路径。
2. 执行 `make menuconfig`，在 `LuCI -> 3. Applications -> luci-app-leigodhelper` 路径下选中本插件。
3. 使用 `make package/utils/luci-app-leigodhelper/compile V=s` 进行编译。
4. 将生成的 `.ipk` 或 `.apk` 文件上传到目标路由器并安装。

### 手动安装

你可以手动将文件拷贝到目标设备的对应路径：

- `usr/bin/leigodhelper_sync.sh` -> `/usr/bin/leigodhelper_sync.sh`
- `etc/init.d/leigodhelper` -> `/etc/init.d/leigodhelper`
- `etc/config/leigodhelper` -> `/etc/config/leigodhelper`
- `usr/share/luci/menu.d/luci-app-leigodhelper.json` -> `/usr/share/luci/menu.d/luci-app-leigodhelper.json`
- `usr/share/rpcd/acl.d/luci-app-leigodhelper.json` -> `/usr/share/rpcd/acl.d/luci-app-leigodhelper.json`
- `www/luci-static/resources/view/leigodhelper/main.js` -> `/www/luci-static/resources/view/leigodhelper/main.js`

拷贝完成后，请执行以下命令：

```bash
chmod +x /usr/bin/leigodhelper_sync.sh
chmod +x /etc/init.d/leigodhelper
/etc/init.d/leigodhelper enable
/etc/init.d/leigodhelper restart
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/*
/etc/init.d/rpcd restart
```

## 配置说明

配置文件路径为 `/etc/config/leigodhelper`。你可以通过 LuCI 网页界面进行配置，也可以直接编辑该文件。

## 致谢

为 OpenWrt 社区开发。
