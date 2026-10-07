#!/usr/bin/env bash
#
# KICKPI K1 (RK3568) —— 启用 Seekwave SWT6621S SDIO WiFi + 蓝牙 驱动
#
# 为什么需要：
#   实机 SDIO 器件 mmc3:0001:1 = vendor 0x1ffe / device 0x6621（SWT6621S），
#   实机加载的正是 swt6621s_wifi / skw_sdio_lite / skwbt 三个【树外】模块，
#   内核里没有任何 SWT/SKW 配置项 —— 属于纯树外驱动，必须自己接入。
#
#   驱动源码：retro98boy/seekwave-swt6621s @ b1b15016119cb21965fc64dd374e42f46f011bb4
#   已生成内核补丁：patch/kernel/rk35xx-vendor-6.1/swt6621s-wifi-bt-driver.patch
#   （补丁把驱动装进 drivers/net/wireless/seekwave/，并挂好 Kconfig / Makefile）
#
# 固件：firmware/SWT6621S_*（15 个文件，取自实机 v1.2 原厂系统）
#
function custom_kernel_config__kickpi_k1_swt6621s() {
	kernel_config_modifying_hashes+=("kickpi-k1-swt6621s")

	# 三块：平台 HAL(SDIO) + WiFi + 蓝牙；SKW_NO_CONFIG=y 表示不依赖 dts 配置
	opts_m+=("SEEKWAVE_BSP_DRIVERS" "SKW_SDIOHAL" "WLAN_VENDOR_SWT6621S" "SKW_BT")
	opts_y+=("SKW_NO_CONFIG")

	if [[ -f .config ]]; then
		if ! grep -qE '^config (SEEKWAVE_BSP_DRIVERS|SKW_SDIOHAL)' \
			drivers/net/wireless/seekwave/drivers/seekwaveplatform_lite/Kconfig 2>/dev/null; then
			exit_with_error "SWT6621S 驱动未进入内核树：swt6621s-wifi-bt-driver.patch 似乎未生效"
		fi
		if ! grep -qE '^(menu)?config WLAN_VENDOR_SWT6621S' \
			drivers/net/wireless/seekwave/drivers/swt6621s_wifi/Kconfig 2>/dev/null; then
			exit_with_error "WLAN_VENDOR_SWT6621S Kconfig 缺失"
		fi
		display_alert "${EXTENSION}" "SWT6621S WiFi/BT 驱动将编入内核 (KICKPI K1 SDIO)" "info"
	fi

	return 0
}
