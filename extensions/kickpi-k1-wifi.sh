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
#   内核补丁：patch/kernel/rk35xx-vendor-6.1/swt6621s-wifi-bt-driver.patch
#            （【只含新增文件】，装进 drivers/net/wireless/seekwave/）
#
#   为什么不把 Kconfig / Makefile 的挂钩写进补丁：
#     框架在应用本补丁之前，已经用它自己的补丁改过 drivers/net/wireless/{Kconfig,Makefile}，
#     硬改会因上下文不匹配导致 "Failed to apply 1 patches" 整体失败（已实际踩到）。
#     所以挂钩在这里用"追加 + 幂等守卫"完成。
#
# 固件：firmware/SWT6621S_*（15 个文件，取自实机 v1.2 原厂系统，经 overlay 随镜像安装）
# ── SWT6621S 固件落进镜像 ─────────────────────────────────────────
# 实测：只把固件放进 userpatches/overlay/ 时，成品镜像的 /lib/firmware 里
# 一个 SWT6621S 文件都没有（自证步骤报 "SWT6621S 固件缺失（实机有 15 个）"）。
# 所以像 roceos 载荷那样，在构建阶段由扩展自己拷进镜像根，不赌 overlay 时序。
function post_family_tweaks__kickpi_k1_wifi_firmware() {
    local dst="${SDCARD}/lib/firmware"
    local n=0
    mkdir -p "$dst"
    for src in /tmp/overlay/lib/firmware/SWT6621S_* "${SRC}"/userpatches/overlay/lib/firmware/SWT6621S_*; do
        for f in $src; do
            [[ -f "$f" ]] || continue
            cp -f "$f" "$dst/" && n=$((n+1))
        done
    done
    if [[ $n -lt 10 ]]; then
        display_alert "$BOARD" "SWT6621S 固件只落了 $n 个（应 ≥15）" "warn"
    else
        display_alert "$BOARD" "SWT6621S 固件已落镜像 $n 个" "info"
    fi
    return 0
}


function custom_kernel_config__kickpi_k1_swt6621s() {
	# 这个钩子会被调用【两次】，必须区分：
	#   1) artifact_kernel_prepare_version() 阶段：内核源码还没拉取，cwd=/armbian，
	#      框架只是借这个钩子算 artifact 版本号。此时做任何文件操作都是错的
	#      （实测：曾在此处误判"驱动未生效"而整体失败）。
	#   2) kernel_config_initialize() 阶段：已 cd 进内核源码树、补丁已应用 —— 真正该干活的时候。
	# 判据用"内核源码树是否就位"，不依赖调用顺序。
	if [[ ! -f drivers/net/wireless/Kconfig ]]; then
		return 0
	fi

	kernel_config_modifying_hashes+=("kickpi-k1-swt6621s")

	local WK="drivers/net/wireless/Kconfig"
	local WM="drivers/net/wireless/Makefile"
	local DST="drivers/net/wireless/seekwave"

	# 驱动必须已由补丁放进内核树，否则直接失败（不留静默降级）
	if [[ ! -d "$DST" ]]; then
		exit_with_error "SWT6621S 驱动目录 $DST 不存在：swt6621s-wifi-bt-driver.patch 未生效"
	fi

	# 追加 Kconfig 挂钩（幂等）
	if ! grep -q "seekwave/Kconfig" "$WK" 2>/dev/null; then
		echo "source \"$DST/Kconfig\"" >> "$WK"
		display_alert "${EXTENSION}" "追加 Kconfig 挂钩: $WK" "info"
	fi

	# 追加 Makefile 挂钩（幂等）
	if ! grep -q 'CONFIG_SEEKWAVE_BSP_DRIVERS) += seekwave/' "$WM" 2>/dev/null; then
		echo 'obj-$(CONFIG_SEEKWAVE_BSP_DRIVERS) += seekwave/' >> "$WM"
		display_alert "${EXTENSION}" "追加 Makefile 挂钩: $WM" "info"
	fi

	# 三块：平台 HAL(SDIO) + WiFi + 蓝牙；SKW_NO_CONFIG=y 表示不依赖 dts 配置
	opts_m+=("SEEKWAVE_BSP_DRIVERS" "SKW_SDIOHAL" "WLAN_VENDOR_SWT6621S" "SKW_BT")
	opts_y+=("SKW_NO_CONFIG")

	if [[ -f .config ]]; then
		# 自检各 Kconfig 项确实存在（注意符号的真实写法与所在文件，
		# 三者都不在同一个 Kconfig 里——写错会把自己判死）
		grep -qE '^(menu)?config SEEKWAVE_BSP_DRIVERS' \
			"$DST/drivers/seekwaveplatform_lite/Kconfig" \
			|| exit_with_error "SEEKWAVE_BSP_DRIVERS Kconfig 缺失"
		grep -qE '^config SKW_SDIOHAL' \
			"$DST/drivers/seekwaveplatform_lite/sdio/Kconfig" \
			|| exit_with_error "SKW_SDIOHAL Kconfig 缺失"
		grep -qE '^config WLAN_VENDOR_SWT6621S' \
			"$DST/drivers/swt6621s_wifi/Kconfig" \
			|| exit_with_error "WLAN_VENDOR_SWT6621S Kconfig 缺失"
		grep -qE '^config SKW_BT' \
			"$DST/drivers/swtbt4l/Kconfig" \
			|| exit_with_error "SKW_BT Kconfig 缺失"
		# 顶层 Kconfig 由补丁提供，扩展靠它挂进 wireless/Kconfig
		[[ -f "$DST/Kconfig" ]] \
			|| exit_with_error "$DST/Kconfig 缺失（补丁未提供顶层 Kconfig）"
		display_alert "${EXTENSION}" "SWT6621S WiFi/BT 驱动将编入内核 (KICKPI K1 SDIO)" "info"
	fi

	return 0
}
