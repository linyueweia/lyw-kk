# Rockchip RK3568 quad core, KICKPI K1 (V1.2) SBC
#   compatible: kickpi,k1 / rockchip,rk3568   (vendor firmware may report rk3568-kickpi-k1a)
#   NET : 2x GbE (gmac0@fe2a0000, gmac1@fe010000) + SDIO WiFi (Seekwave SWT6621S, 1ffe:6621)
#   STO : eMMC 64G (sdhci) + microSD (sdmmc0) + M.2 NVMe (pcie3x2)
#   PMIC: RK809 + fan53555(vdd_cpu);  LED: kickpi:blue:work;  FAN: leds/fan (GPIO0 RK_PD6, 非 PWM)
BOARD_NAME="KICKPI K1"
BOARD_VENDOR="kickpi"
BOARDFAMILY="rk35xx"
BOARD_MAINTAINER="linyueweia"
# rock-3a 的 SD 槽挂在 sdhci@fe310000，而本板 K1 的 SD 槽是标准 dwmmc(SDMMC0)。
# 实测教训（飞牛卡）：用 rock-3a 编出的 u-boot 从 SD 启动会死在 SPL —— 电源灯亮、
# 系统灯不亮、完全起不来。与同为 rk3568 双千兆 NAS 板的官方 easepi-r1 及本仓 T68M
# 保持一致，改用 radxa-e25-rk3568_defconfig。
BOOTCONFIG="radxa-e25-rk3568_defconfig"
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
	# ── G1：首启时「LAN 静态配置生成」与「NetworkManager 启动」之间没有排序 ─────────
	# 取证（deleg_13c8d3f3，kk-static.json gap G1）：
	#   istorenext-init-network.service  只有 After=local-fs.target / Before=networking.service
	#   NetworkManager.service           只有 After=network-pre.target dbus.service
	#   而 network-pre.target 没有被任何【已使能】单元拉入（systemd-network-generator/nftables
	#   均未启用），该前置关系在首启时形同虚设 → 两个单元并行启动，NM 可能在
	#   /etc/network/interfaces 生成之前就接管 eth0，与 ifupdown 抢 LAN 口，
	#   192.168.100.1（管理界面入口）就可能配不上 —— 正是「插上网线拿不到该有的地址」。
	# 修法：给 NM 加 drop-in，把它排在 istorenext-init-network.service 与 networking.service
	# 之后。二者都没有被 NM Wants，排序只在「同在启动队列」时生效：
	#   首启：二者均使能 → 生效；后续 istorenext-init-network 自 disable → 排序为空操作。
	# 已核过无排序环（networking.service 的 Before 只有 network.target/shutdown.target/
	# network-online.target，不回指 NM）。
	display_alert "$BOARD" "KICKPI K1: pin NetworkManager after iStoreNext LAN init (gap G1)" "info"
	mkdir -p "${SDCARD}/etc/systemd/system/NetworkManager.service.d"
	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/NetworkManager.service.d/10-k1-lan-order.conf"
		# KICKPI K1 板级：先让 iStoreNext 把 LAN（eth0 → 192.168.100.1）写进
		# /etc/network/interfaces 并由 networking.service 应用，NM 再启动。
		# 否则首启 NM 会先接管 eth0（此时 interfaces 还没生成），与 ifupdown 抢口。
		[Unit]
		After=istorenext-init-network.service networking.service
	EOF

	# 自证：三样东西必须真的落到镜像里
	for f in etc/udev/rules.d/70-persistent-net.rules root/.default-network etc/eth_order \
		etc/systemd/system/NetworkManager.service.d/10-k1-lan-order.conf; do
		[[ -e "${SDCARD}/${f}" ]] || exit_with_error "network init file missing: ${f}"
	done
	grep -q 'KERNELS=="fe010000.ethernet", NAME:="eth0"' \
		"${SDCARD}/etc/udev/rules.d/70-persistent-net.rules" \
		|| exit_with_error "udev rule for eth0/fe010000 missing"
	grep -q '^DEFAULT_INTERFACE=eth0$' "${SDCARD}/root/.default-network" \
		|| exit_with_error ".default-network wrong"
	grep -q '^After=istorenext-init-network.service networking.service$' \
		"${SDCARD}/etc/systemd/system/NetworkManager.service.d/10-k1-lan-order.conf" \
		|| exit_with_error "NM LAN-order drop-in wrong"
	display_alert "$BOARD" "K1 network pinned: eth0=fe010000(LAN 192.168.100.1), eth1=fe2a0000; NM ordered after LAN init" "info"
	return 0
}
