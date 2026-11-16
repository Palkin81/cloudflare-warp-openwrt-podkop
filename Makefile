include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-warp
PKG_VERSION:=0.1.13
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=luci-app-warp contributors

LUCI_TITLE:=WARP
LUCI_DESCRIPTION:=Standalone WARP interface with automatic endpoint selection
LUCI_URL:=https://github.com/moz9/cloudflare-warp-openwrt-podkop
LUCI_DEPENDS:=+luci-base +curl +jsonfilter
LUCI_EXTRA_DEPENDS:=warp-awg (>=0.1.0), warp-warpscout (>=0.1.0)
LUCI_PKGARCH:=all
# Keep the conventional LuCI package identity even when this source tree is
# checked out under a differently named directory.
LUCI_NAME:=luci-app-warp

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
