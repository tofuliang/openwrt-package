# Copyright (C) 2016 Openwrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for Webrestriction From Koolshare
LUCI_PKGARCH:=all
PKG_VERSION:=1.0
PKG_RELEASE:=5-20200107

define Package/luci-app-control-webrestriction/conffiles
/etc/config/webrestriction_bypass.list
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature


