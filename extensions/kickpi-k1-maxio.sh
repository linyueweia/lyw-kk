#!/usr/bin/env bash
#
# KICKPI K1 (RK3568) —— 启用 Maxio MAE0621A 千兆 PHY 驱动
#
# 为什么要这个扩展：
#   K1 V1.2 的两个千兆口用的是 Maxio MAE0621A-Q2C PHY（PHY ID 0x7b744411），
#   这是内核树外驱动（drivers/net/phy/maxio.c），armbian 框架对 rk35xx-vendor-6.1
#   这一族默认不打该补丁 → 编出来的镜像两个网口全哑，
#   且 DWMAC 会报 "DMA engine initialization failed"。
#   参考: armbian/linux-rockchip issue #471（维护者原话 "was trapped by maxio phy"）。
#
# 本扩展做两件事：
#   1) 把 CONFIG_MAXIO_PHY=y 写进内核 .config（用框架的 opts_y 机制，最干净）；
#   2) 自检内核树里确实有该 Kconfig 项（补丁真的打上了），否则直接报错终止构建。
#
function custom_kernel_config__kickpi_k1_maxio_phy() {
	kernel_config_modifying_hashes+=("kickpi-k1-maxio-phy")

	# 框架的 opts_y 数组会在 custom_kernel_config 之后统一应用到 .config
	opts_y+=("MAXIO_PHY")

	if [[ -f .config ]]; then
		if ! grep -qE '^config MAXIO_PHY' drivers/net/phy/Kconfig; then
			exit_with_error "MAXIO_PHY Kconfig entry missing: maxio PHY patch was not applied to the kernel tree"
		fi
		display_alert "${EXTENSION}" "CONFIG_MAXIO_PHY will be enabled (KICKPI K1 dual GbE)" "info"
	fi

	return 0
}
