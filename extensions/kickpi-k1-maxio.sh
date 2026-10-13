#!/usr/bin/env bash
#
# KICKPI K1 (RK3568) —— 启用 Maxio MAE0621A 千兆 PHY 驱动（模块化，支持在线更新自愈）
#
# 为什么要这个扩展：
#   K1 V1.2 的两个千兆口用的是 Maxio MAE0621A-Q2C PHY（PHY ID 0x7b744411），
#   这是内核树外驱动（drivers/net/phy/maxio.c），armbian 框架对 rk35xx-vendor-6.1
#   这一族默认不打该补丁 → 编出来的镜像两个网口全哑，
#   且 DWMAC 会报 "DMA engine initialization failed"。
#   参考: armbian/linux-rockchip issue #471（维护者原话 "was trapped by maxio phy"）。
#
# ⚠ 为什么必须是【模块 =m】而不是内建 =y（实机事实，2026-10-13 定案）：
#   本板内核是自建 vendor 6.1（补丁把 maxio 打进树内）。若编成 =y，那么"在线更新换了内核"
#   就等于把 PHY 驱动一起换掉 —— 内建驱动没有任何外挂补救手段（不能装载、不能重建）。
#   编成 =m 之后才有完整自愈链（见 extensions/kickpi-k1-module-selfheal.sh）：
#     树外源码随镜像 + DKMS 注册 + /etc/kernel/postinst.d 钩子对新内核重编
#     + 开机自愈单元按 uname -r 补编/加载 + softdep 保证 maxio 先于 MAC 驱动注册。
#   这是 lyw-kf（飞牛线）已实机跑通的同款方案：2026-10-12 在线更新装新内核 c951→c1145，
#   钩子自动编出 maxio.ko，15 秒后双网口恢复（见 lyw-kf/TROUBLESHOOTING.md §2.1）。
#
# ⚠ 为什么连 MAC 驱动也要一起模块化（本仓与飞牛的实测差异，不能照抄）：
#   phylib 是在【MAC 探测时】就把 PHY 绑到当时的驱动上。飞牛那边 dwmac_rk 本身就是模块，
#   所以外挂 maxio 先加载即可；而本板原为 STMMAC_ETH=y / DWMAC_ROCKCHIP=y（内建），
#   内建 MAC 必然先于任何模块完成 PHY attach → 晚到的 maxio 被跳过（lyw-kf PORTING 坑④
#   实测同款现象），自愈链条形同虚设。故这里把 MAC 侧一并改 =m，
#   加载顺序由 /etc/modprobe.d/kickpi-k1.conf 的 softdep（module-selfheal 扩展安装）保证。
#   PCS_XPCS / PHYLIB / MDIO_DEVICE 保持 =y（由上面几个 select，无板级差异）。
#
# 本扩展做三件事：
#   1) 把 MAXIO_PHY / STMMAC_ETH / STMMAC_PLATFORM / DWMAC_ROCKCHIP 写成 =m（框架 opts_m 机制）；
#   2) 自检内核树里确实有 MAXIO_PHY 这个 Kconfig 项（补丁真的打上了），否则直接报错终止构建；
#   3) 模块名硬自检：DWMAC_ROCKCHIP 编出的是 dwmac-rockchip.ko、MAXIO_PHY 是 maxio.ko，
#      这两个名字被 selfheal 扩展的 softdep 与开机单元写死引用 —— 上游改名就在这里立刻暴露。
#
function custom_kernel_config__kickpi_k1_maxio_phy() {
	kernel_config_modifying_hashes+=("kickpi-k1-maxio-phy")

	# 树外/自建 PHY 驱动 + MAC 胶合层全部模块化（=m）："驱动跟着内核走"的前提
	opts_m+=("MAXIO_PHY" "STMMAC_ETH" "STMMAC_PLATFORM" "DWMAC_ROCKCHIP")

	if [[ -f .config ]]; then
		if ! grep -qE '^config MAXIO_PHY' drivers/net/phy/Kconfig; then
			exit_with_error "MAXIO_PHY Kconfig entry missing: maxio PHY patch was not applied to the kernel tree"
		fi
		grep -q 'dwmac-rockchip.o' drivers/net/ethernet/stmicro/stmmac/Makefile \
			|| exit_with_error "DWMAC_ROCKCHIP module target changed (expected dwmac-rockchip.o) —— softdep/开机单元会静默失效"
		grep -qE 'obj-\$\(CONFIG_MAXIO_PHY\)[[:space:]]*\+=[[:space:]]*maxio\.o' drivers/net/phy/Makefile \
			|| exit_with_error "MAXIO_PHY module target missing in drivers/net/phy/Makefile (expected maxio.o)"
		display_alert "${EXTENSION}" "CONFIG_MAXIO_PHY/STMMAC/DWMAC = m (KICKPI K1 dual GbE + 在线更新自愈)" "info"
	fi

	return 0
}
