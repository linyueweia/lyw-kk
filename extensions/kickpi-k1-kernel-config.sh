#!/usr/bin/env bash
#
# KICKPI K1 (RK3568) —— 内核配置兜底：SATA 主机内建 + PCIe MSI
#
# 为什么要这个扩展（三线判据）：
#   1) CONFIG_AHCI_DWC：6.1 里 compatible="snps,dwc-ahci" 唯一匹配 drivers/ata/ahci_dwc.c，
#      Kconfig 是 tristate 且无 default；实机 /proc/modules 里没有 ahci*、/sys/bus/platform/drivers/ahci
#      已绑定 fc000000.sata → 实机是【内建】。目标 defconfig 里它是 =m，而 rootfs 不带该 .ko
#      → SATA 不 probe、root-on-SATA/热插拔全无，且旧门禁 `^CONFIG_AHCI_DWC=` 连 =m 都放行。
#   2) CONFIG_PCI_MSI：实机 /proc/config.gz: PCI_MSI=y（GENERIC_MSI_IRQ/GENERIC_MSI_IRQ_DOMAIN/
#      PCI_MSI_IRQ_DOMAIN=y 同在）；6.1 drivers/pci/Kconfig:39-41 显示 PCI_MSI 是 bool、无 default、
#      arm64 不 select（GENERIC_MSI_IRQ 由它 select、PCI_MSI_IRQ_DOMAIN 是 def_bool y+depends），
#      所以只要显式开 PCI_MSI，另外三个自动跟上。不显式开 → NVMe/PCIe 退化 INTx，
#      队列数与中断亲和失效，吞吐与 CPU 占用显著劣化。
#
# 用法：由 build.yml 的 ENABLE_EXTENSIONS 启用（与其他 kickpi-k1-* 扩展并列）。
# 机制：与 kickpi-k1-maxio.sh 相同——opts_y 由框架在 custom_kernel_config 之后统一写进 .config，
#       本钩子只做【Kconfig 入口确实存在】的硬自检（补丁没打进树就立刻失败，不留静默降级），
#       最终值由 build.yml 的镜像自检（AHCI_DWC=y / PCI_MSI=y）二次断言。
#
function custom_kernel_config__kickpi_k1_storage_irq() {
	kernel_config_modifying_hashes+=("kickpi-k1-kernel-config")

	# 目标值（=y：SATA 必须内建；PCI_MSI=y 才能让 MSI 域自动 select 起来）
	opts_y+=("AHCI_DWC" "PCI_MSI")

	# WiFi 前置：WLAN_VENDOR_SWT6621S 依赖 CFG80211（swt6621s-wifi-bt-driver.patch:16622），
	# 两份 defconfig（armbian-rk35xx-vendor.config 与框架自带的 linux-rk35xx-vendor.config，
	# md5 相同）都没有 CFG80211/MAC80211 —— make olddefconfig 会把依赖不满足的
	# WLAN_VENDOR_SWT6621S 直接丢掉。实机 /proc/config.gz: CFG80211=y、MAC80211=y。
	opts_y+=("CFG80211" "MAC80211")

	# 板载按键 / 摄像头 / 串口蓝牙：实机 =y，defconfig 是 =m —— 靠 modalias 装载，
	# 一旦镜像里 modules.dep 没覆盖就静默失效（按键/摄像头无声无息），按实机对齐为 =y。
	opts_y+=("KEYBOARD_ADC" "KEYBOARD_GPIO" "VIDEO_GC5035" "BT_HCIUART")

	# 网口 PHY 驱动兜底（三线判据：实机 /proc/config.gz =y、官方 6.1 drivers/net/phy/Kconfig:300 有、
	# armbian rk-6.1-rkr5.1 原生无该符号 → 只能由 general-drv-net-phy-maxio-mae0621a.patch 提供）。
	# 静态 defconfig 里没有它，脱离 kickpi-k1-maxio 扩展会编出两个口全哑的内核，故在此再写一次。
	opts_y+=("MAXIO_PHY")

	# HDMI/显示链路的隐式依赖（HDMI report：这些全部靠 select/default 拿到，defconfig 一个字都没有，
	# 上游 select 条件一变就静默丢失；显式写 =y 与实机 /proc/config.gz 对齐）。
	opts_y+=("DRM" "DRM_ROCKCHIP" "ROCKCHIP_DW_HDMI" "DRM_DW_HDMI" "DRM_DW_HDMI_CEC"
		"DRM_DW_HDMI_I2S_AUDIO" "DRM_DW_MIPI_DSI" "DRM_ANALOGIX_DP" "DRM_KMS_HELPER"
		"DRM_GEM_DMA_HELPER" "VIDEOMODE_HELPERS" "DRM_PANEL" "DRM_EDID" "HDMI"
		"DRM_PANEL_ORIENTATION_QUIRKS" "DRM_FBDEV_EMULATION" "CEC_CORE" "CEC_NOTIFIER"
		"SND_SOC_HDMI_CODEC" "SND_SIMPLE_CARD_UTILS" "BACKLIGHT_CLASS_DEVICE")

	if [[ -f .config ]]; then
		# Kconfig 入口自检（写错符号名会把自己判死，故逐个点名）
		grep -qE '^config AHCI_DWC' drivers/ata/Kconfig \
			|| exit_with_error "AHCI_DWC Kconfig entry missing (ahci_dwc patch/Kconfig not in tree)"
		grep -qE '^config PCI_MSI$' drivers/pci/Kconfig \
			|| exit_with_error "PCI_MSI Kconfig entry missing"
		grep -qE '^config CFG80211' net/wireless/Kconfig \
			|| exit_with_error "CFG80211 Kconfig entry missing"
		grep -qE '^config VIDEO_GC5035' drivers/media/i2c/Kconfig \
			|| exit_with_error "VIDEO_GC5035 Kconfig entry missing (gc5035 patch not applied)"
		# MAXIO_PHY 只有 maxio 补丁打上才会出现；缺它就等于两个千兆口全哑，立刻失败
		grep -qE '^config MAXIO_PHY' drivers/net/phy/Kconfig \
			|| exit_with_error "MAXIO_PHY Kconfig entry missing (maxio patch not applied -> dual GbE dead)"
		grep -qE '^config ROCKCHIP_DW_HDMI' drivers/gpu/drm/rockchip/Kconfig \
			|| exit_with_error "ROCKCHIP_DW_HDMI Kconfig entry missing"
		grep -qE '^config DRM_DW_HDMI_CEC' drivers/gpu/drm/bridge/synopsys/Kconfig \
			|| exit_with_error "DRM_DW_HDMI_CEC Kconfig entry missing"
		display_alert "${EXTENSION}" "AHCI_DWC/PCI_MSI/CFG80211/MAXIO_PHY + keys/cam/BT + HDMI/CEC =y will be applied" "info"
	fi

	return 0
}
