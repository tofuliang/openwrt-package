
# Copyright (C) 2024 OpenWrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Internet Access Schedule Control
LUCI_DESCRIPTION:=Web interface for controlling internet access schedules by MAC address and time, with holiday-aware scheduling
# Reuse LuCI's ucode runtime and BusyBox's flock applet instead of jq/util-linux.
# The flock select applies to firmware builds; prebuilt images must include it.
# Keep HTTPS trust/TLS and GNU timeout explicit: idle timeout is not a deadline.
LUCI_DEPENDS:=+luci-base +ucode +ucode-mod-fs +@BUSYBOX_CONFIG_FLOCK +uclient-fetch +ca-bundle +coreutils-timeout \
	+PACKAGE_libustream-openssl:libustream-openssl \
	+PACKAGE_libustream-wolfssl:libustream-wolfssl \
	+!(PACKAGE_libustream-openssl||PACKAGE_libustream-wolfssl):libustream-mbedtls
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-accesscontrol
PKG_VERSION:=2.0
PKG_RELEASE:=1

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
