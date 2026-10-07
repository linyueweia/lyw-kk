# Rockchip RK3568 quad core, KICKPI K1 (V1.2) SBC
#   compatible: kickpi,k1 / rockchip,rk3568   (vendor firmware may report rk3568-kickpi-k1a)
#   NET : 2x GbE (gmac0@fe2a0000, gmac1@fe010000) + SDIO WiFi (AIC8800)
#   STO : eMMC 64G (sdhci) + microSD (sdmmc0) + M.2 NVMe (pcie3x2)
#   PMIC: RK809 + fan53555(vdd_cpu);  LED: kickpi:blue:work;  FAN: gpio-fan
BOARD_NAME="KICKPI K1"
BOARD_VENDOR="kickpi"
BOARDFAMILY="rk35xx"
BOARD_MAINTAINER="linyueweia"
BOOTCONFIG="rock-3a-rk3568_defconfig"
KERNEL_TARGET="vendor"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3568-kickpi-k1.dtb"
BOOT_SCENARIO="spl-blobs"
# 注意：本机实测【没有 SPI NOR 芯片】(/proc/mtd 无设备、dmesg 无 spi-nor)，
# 因此绝不能开 BOOT_SUPPORT_SPI。实测教训：只写 BOOT_SUPPORT_SPI="yes" 而不配对
# BOOT_SPI_RKSPI_LOADER，框架会去生成 rkspi_loader.img 并找 spl-blobs 场景下不存在的
# tpl/u-boot-tpl.bin，导致构建在 uboot_custom_postprocess 阶段失败
#   "mkimage: Can't open tpl/u-boot-tpl.bin" / "SPL image is too large (size 0xffffffff)"
IMAGE_PARTITION_TABLE="gpt"
BOOTFS_TYPE="fat"

function post_family_tweaks__kickpi_k1_hold_dtb() {
	display_alert "$BOARD" "Prevent armbian-upgrade from removing our dtb" "info"
	chroot_sdcard apt-mark hold linux-dtb-vendor-rk35xx || true
	return 0
}
