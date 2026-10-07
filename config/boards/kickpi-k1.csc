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

# iNextOS 的用户态网络初始化由 istorenext 扩展里的两个脚本负责：
#   fix-ifaces-name          —— 按 /proc/device-tree/eth_order 或 /etc/eth_order 把网口重命名
#   istorenext-init-network  —— 取 /root/.default-network（若存在）否则 eth* 里最后一个，
#                               把它配成静态 192.168.100.1（网页后台入口）
# 两者都没有时，命名只能靠内核探测顺序，LAN 口落到哪个物理口是不确定的。
# 官方 easepi-r1 与本仓的 T68M 都是用「udev 规则 + /etc/eth_order + .default-network」
# 三者并用把身份钉死，本板照做。
#
# KICKPI K1 只有【两个】板载千兆口（RK3568 双 gmac），没有 PCIe 网卡：
#   实测厂商运行态：eth0 = fe010000.ethernet（该口插线，carrier=1，1000Mb/s）
#                  eth1 = fe2a0000.ethernet（未插线）
#   而实机 DT 的 aliases 写的是 ethernet0=/ethernet@fe2a0000 —— 与运行态不一致，
#   正说明命名不可依赖，必须按平台地址钉死。
# 因此把【实测在用】的 fe010000 定为 eth0（= LAN，192.168.100.1），
# 另一个 fe2a0000 定为 eth1（可在网页后台里配成外网口）。
# 若将来想对调两个物理口，只需交换下面两行的 NAME 值。
function post_family_tweaks__kickpi_k1_network_interfaces() {
	display_alert "$BOARD" "Pinning KICKPI K1 network interfaces to eth0/eth1" "info"

	mkdir -p "${SDCARD}/etc/udev/rules.d/"
	cat <<- EOF > "${SDCARD}/etc/udev/rules.d/70-persistent-net.rules"
		SUBSYSTEM=="net", ACTION=="add", KERNELS=="fe010000.ethernet", NAME:="eth0"
		SUBSYSTEM=="net", ACTION=="add", KERNELS=="fe2a0000.ethernet", NAME:="eth1"
	EOF

	# LAN 口：iStoreNext 的 istorenext-init-network 会读它并配成 192.168.100.1
	echo "DEFAULT_INTERFACE=eth0" > "${SDCARD}/root/.default-network"
	echo "fe010000.ethernet,fe2a0000.ethernet" > "${SDCARD}/etc/eth_order"

	# 自证：三样东西必须真的落到镜像里
	for f in etc/udev/rules.d/70-persistent-net.rules root/.default-network etc/eth_order; do
		[[ -e "${SDCARD}/${f}" ]] || exit_with_error "network init file missing: ${f}"
	done
	grep -q 'KERNELS=="fe010000.ethernet", NAME:="eth0"' \
		"${SDCARD}/etc/udev/rules.d/70-persistent-net.rules" \
		|| exit_with_error "udev rule for eth0/fe010000 missing"
	grep -q '^DEFAULT_INTERFACE=eth0$' "${SDCARD}/root/.default-network" \
		|| exit_with_error ".default-network wrong"
	display_alert "$BOARD" "K1 network pinned: eth0=fe010000(LAN 192.168.100.1), eth1=fe2a0000" "info"
	return 0
}
