# Copyright (C) 2024 OpenWrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Web Access Restriction
LUCI_DESCRIPTION:=Web interface for controlling internet access using whitelist/blacklist mode
LUCI_DEPENDS:=
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-webrestriction
PKG_VERSION:=2.0
PKG_RELEASE:=1

define Package/luci-app-webrestriction/conffiles
/etc/config/webrestriction_bypass.list
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature


