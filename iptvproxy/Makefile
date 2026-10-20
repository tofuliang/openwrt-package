PKG_NAME:=iptvproxy
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

SOURCES:=main.c proxy_server.c proxy_runtime.c proxy_decoder.c proxy_http.c
LOCAL_CC?=cc
LOCAL_CFLAGS?=-std=c11 -O2 -Wall -Wextra -Wpedantic -pthread
LOCAL_CPPFLAGS?=
LOCAL_LDFLAGS?=
LOCAL_LDLIBS?=-lcurl -pthread
LOCAL_BUILD_DIR?=$(CURDIR)/build
LOCAL_BIN:=$(LOCAL_BUILD_DIR)/$(PKG_NAME)

PKG_FILE_DIR:=$(dir $(abspath $(lastword $(MAKEFILE_LIST))))

ifeq ($(wildcard $(TOPDIR)/rules.mk),)
.PHONY: all clean test self-test smoke package package-local

all: $(LOCAL_BIN)

$(LOCAL_BIN): $(addprefix $(PKG_FILE_DIR)/,$(SOURCES)) $(PKG_FILE_DIR)/proxy.h
	@mkdir -p $(LOCAL_BUILD_DIR)
	$(LOCAL_CC) $(LOCAL_CPPFLAGS) $(LOCAL_CFLAGS) $(LOCAL_LDFLAGS) -o $@ $(addprefix $(PKG_FILE_DIR)/,$(SOURCES)) $(LOCAL_LDLIBS)

self-test: $(LOCAL_BIN)
	$(LOCAL_BIN) --self-test

test: self-test
	@if $(LOCAL_BIN) --profile unsupported >/dev/null 2>&1; then echo "unsupported profile unexpectedly accepted"; exit 1; fi

smoke: $(LOCAL_BIN)
	IPTVPROXY_SMOKE_PORT=$${IPTVPROXY_SMOKE_PORT:-3457} sh $(PKG_FILE_DIR)/scripts/smoke.sh $(LOCAL_BIN)

package-local: $(LOCAL_BIN)
	@mkdir -p $(LOCAL_BUILD_DIR)/package/usr/sbin $(LOCAL_BUILD_DIR)/package/etc/init.d
	install -m 0755 $(LOCAL_BIN) $(LOCAL_BUILD_DIR)/package/usr/sbin/$(PKG_NAME)
	install -m 0755 $(PKG_FILE_DIR)/files/etc/init.d/$(PKG_NAME) $(LOCAL_BUILD_DIR)/package/etc/init.d/$(PKG_NAME)
	@printf '%s\n' 'Package: $(PKG_NAME)' 'Version: $(PKG_VERSION)-$(PKG_RELEASE)' 'Architecture: target' 'Depends: libcurl' > $(LOCAL_BUILD_DIR)/package/control
	@printf 'package-local: staged %s/usr/sbin/%s and %s/etc/init.d/%s\n' '$(LOCAL_BUILD_DIR)/package' '$(PKG_NAME)' '$(LOCAL_BUILD_DIR)/package' '$(PKG_NAME)'

package:
	@if test -n "$${OPENWRT_DIR:-}"; then \
		$(MAKE) -C "$${OPENWRT_DIR}" package/$(PKG_NAME)/compile V=s; \
	else \
		$(MAKE) package-local; \
	fi

clean:
	rm -rf $(LOCAL_BUILD_DIR)
endif

# OpenWrt buildroot integration. The package source files stay in this
# directory; Build/Prepare copies only source inputs into PKG_BUILD_DIR.
ifneq ($(wildcard $(TOPDIR)/rules.mk),)
include $(TOPDIR)/rules.mk

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/iptvproxy
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Lightweight 345 IPTV streaming proxy
  URL:=https://github.com/tofuliang/openwrt-package
  DEPENDS:=+libcurl
endef

define Package/iptvproxy/description
  Lightweight C implementation of the 345 IPTV page decoder, media stream
  proxy and HLS playlist proxy.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(addprefix $(PKG_FILE_DIR)/,$(SOURCES)) $(PKG_FILE_DIR)/proxy.h $(PKG_BUILD_DIR)/
endef

IPTVPROXY_STRIP:=$(TARGET_CROSS)strip
IPTVPROXY_READELF:=$(TARGET_CROSS)readelf

define Build/Compile
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) -std=c11 -O2 -Wall -Wextra -Wpedantic -pthread \
		-o $(PKG_BUILD_DIR)/$(PKG_NAME) \
		$(addprefix $(PKG_BUILD_DIR)/,$(SOURCES)) \
		$(TARGET_LDFLAGS) -lcurl -pthread
	@echo "iptvproxy ELF size before strip (SDK size):"; $(TARGET_CROSS)size $(PKG_BUILD_DIR)/$(PKG_NAME); \
		echo "iptvproxy strip tool: $(IPTVPROXY_STRIP) --strip-unneeded"; \
		$(IPTVPROXY_STRIP) --strip-unneeded $(PKG_BUILD_DIR)/$(PKG_NAME); \
		echo "iptvproxy ELF size after strip (SDK size):"; $(TARGET_CROSS)size $(PKG_BUILD_DIR)/$(PKG_NAME); \
		echo "iptvproxy ELF file:"; file $(PKG_BUILD_DIR)/$(PKG_NAME); \
		echo "iptvproxy ELF header:"; $(IPTVPROXY_READELF) -h $(PKG_BUILD_DIR)/$(PKG_NAME); \
		echo "iptvproxy ELF sections:"; $(IPTVPROXY_READELF) -S $(PKG_BUILD_DIR)/$(PKG_NAME)
endef

define Package/iptvproxy/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/$(PKG_NAME) $(1)/usr/sbin/$(PKG_NAME)
	$(INSTALL_BIN) $(PKG_FILE_DIR)/files/etc/init.d/$(PKG_NAME) $(1)/etc/init.d/$(PKG_NAME)
endef

$(eval $(call BuildPackage,iptvproxy))
endif
