include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-leigodhelper
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Claude
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-leigodhelper
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI Support for Leigod Accelerator Helper
  DEPENDS:=+luci-base +iptables +ipset +curl
  PKGARCH:=all
endef

define Package/luci-app-leigodhelper/description
  LuCI interface for Leigod Accelerator Helper sync script.
endef

define Build/Compile
endef

define Package/luci-app-leigodhelper/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./usr/bin/leigodhelper_sync.sh $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./etc/init.d/leigodhelper $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./usr/share/luci/menu.d/luci-app-leigodhelper.json $(1)/usr/share/luci/menu.d/

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./usr/share/rpcd/acl.d/luci-app-leigodhelper.json $(1)/usr/share/rpcd/acl.d/

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/leigodhelper
	$(INSTALL_DATA) ./www/luci-static/resources/view/leigodhelper/main.js $(1)/www/luci-static/resources/view/leigodhelper/
endef

$(eval $(call BuildPackage,luci-app-leigodhelper))
