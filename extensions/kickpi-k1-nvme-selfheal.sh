#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# KICKPI K1 板级扩展：PCIe/NVMe 开机自愈（pcie30 PHY 上电时序兜底）
#
# 实机定案（2026-10-14，串口+journal 逐秒取证）：
#   NVMe(M.2) 走独立 pcie30 PHY（phy@fe8c0000）+ pcie3x2（pcie@fe280000）。
#   PHY 初始化在 t≈13.94s，而它自己的模拟供电 pcie30_avdd0v9 / pcie30_avdd1v8
#   在 t≈15.07s 才 ready（晚约 1.1s）→ PHY 内部 SRAM 初始化等不到就超时：
#       rockchip_p3phy_rk3568_init: lock failed 0x6890000 →
#       phy init failed -110 → dw-pcie: invalid resource → rk-pcie -ETIMEDOUT →
#       rk_pcie_remove() 空指针 Oops → dw-pcie probe failed -22
#   供电就绪后把 rk-pcie 重新 bind 一次即正常枚举（实测：15.752 Gb/s x2、
#   nvme0n1 238.5GB 出盘、挂载正常）。
#
# 本扩展做两件事：
#   1) DTS 侧（正本清源）：patch/kernel/rk35xx-vendor-6.1/dt/rk3568-kickpi-k1.dts 里
#      · vcc3v3_pcie 加槽电源 gpio0 RK_PD4(=pin28) + enable-active-high + pinmux；
#      · 补 pcie30_avdd0v9 / pcie30_avdd1v8 两路常开 regulator。
#      【注意】绝不要给 &pcie30phy 挂 phy-supply —— 实测会导致永久 deferred probe。
#   2) 运行期兜底（本扩展）：开机后若 /dev/nvme0 还没出现，就重绑定 rk-pcie 再试。
#      · 快路径：冷启动已成功（绝大多数情况）→ 只做一次 test -e，直接退出，零额外开销；
#      · 慢路径：最多 5 次 unbind/bind，成功即记录到 syslog 并退出。
#
# 不做什么：不钉内核、不改 u-boot、不做周期轮询（只有开机那一次，不拖慢启动）。
# ══════════════════════════════════════════════════════════════════════════

function post_post_debootstrap_tweaks__kickpi_k1_nvme_selfheal() {
	display_alert "Installing PCIe/NVMe self-heal (KICKPI K1)" "$EXTENSION" "info"

	mkdir -p "${SDCARD}/usr/local/sbin" "${SDCARD}/etc/systemd/system"

	# ── 1) 自愈脚本 ────────────────────────────────────────────────────
	cat <<- 'EOF' > "${SDCARD}/usr/local/sbin/kickpi-k1-nvme-selfheal.sh"
		#!/bin/bash
		# KICKPI K1：pcie30 PHY 初始化早于其 0.9V/1.8V 模拟供电就绪 → 首次 init 超时失败
		# （dmesg: rockchip_p3phy_rk3568_init: lock failed），供电到位后重绑定 rk-pcie
		# 即可正常枚举 NVMe（实机验证：重绑定后 nvme0n1 238.5GB 出盘）。
		# 快路径：冷启动已成功则直接退出，零额外开销。
		[ -e /dev/nvme0 ] && exit 0
		modprobe -q rk-pcie 2>/dev/null
		for i in 1 2 3 4 5; do
			echo 3c0800000.pcie > /sys/bus/platform/drivers/rk-pcie/unbind 2>/dev/null
			sleep 1
			echo 3c0800000.pcie > /sys/bus/platform/drivers/rk-pcie/bind 2>/dev/null
			sleep 4
			if [ -e /dev/nvme0 ]; then
				logger -t kickpi-nvme "self-heal OK: nvme0 ready (attempt $i)"
				exit 0
			fi
		done
		logger -t kickpi-nvme "self-heal FAILED after 5 attempts"
		exit 1
	EOF
	chmod 0755 "${SDCARD}/usr/local/sbin/kickpi-k1-nvme-selfheal.sh"

	# ── 2) 开机单元（多用户之后跑：那时 pcie30 供电一定已就绪）──────────
	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/kickpi-k1-nvme-selfheal.service"
		[Unit]
		Description=KICKPI K1 PCIe/NVMe self-heal (retry PHY init after analog rails are ready)
		After=multi-user.target
		ConditionPathExists=/usr/local/sbin/kickpi-k1-nvme-selfheal.sh

		[Service]
		Type=oneshot
		ExecStart=/usr/local/sbin/kickpi-k1-nvme-selfheal.sh
		RemainAfterExit=yes

		[Install]
		WantedBy=multi-user.target
	EOF

	chroot_sdcard systemctl --no-reload enable kickpi-k1-nvme-selfheal.service >/dev/null 2>&1 || true

	display_alert "PCIe/NVMe self-heal installed (script + boot unit)" "$EXTENSION" "info"
	return 0
}

# ══════════════════════════════════════════════════════════════════════════
# 最终态断言：自愈链每一环都要真在镜像里（缺了 = 冷启动 NVMe 不上盘时没人救）
# ══════════════════════════════════════════════════════════════════════════
function pre_umount_final_image__kickpi_k1_nvme_selfheal() {
	display_alert "Final-pass: verify NVMe self-heal (KICKPI K1)" "$EXTENSION" "info"

	local fail=0
	[[ -x "${SDCARD}/usr/local/sbin/kickpi-k1-nvme-selfheal.sh" ]] || {
		display_alert "NVMe 自愈脚本缺失或不可执行" "$EXTENSION" "err"; fail=1; }
	sh -n "${SDCARD}/usr/local/sbin/kickpi-k1-nvme-selfheal.sh" 2>/dev/null || {
		display_alert "kickpi-k1-nvme-selfheal.sh 语法错误" "$EXTENSION" "err"; fail=1; }
	grep -q 'rk-pcie/unbind' "${SDCARD}/usr/local/sbin/kickpi-k1-nvme-selfheal.sh" || {
		display_alert "自愈脚本缺 rk-pcie unbind（重绑定逻辑不存在）" "$EXTENSION" "err"; fail=1; }
	[[ -f "${SDCARD}/etc/systemd/system/kickpi-k1-nvme-selfheal.service" ]] || {
		display_alert "NVMe 自愈 unit 缺失" "$EXTENSION" "err"; fail=1; }
	mkdir -p "${SDCARD}/etc/systemd/system/multi-user.target.wants"
	ln -sf /etc/systemd/system/kickpi-k1-nvme-selfheal.service \
		"${SDCARD}/etc/systemd/system/multi-user.target.wants/kickpi-k1-nvme-selfheal.service"

	[[ $fail == 0 ]] || exit_with_error "KICKPI K1 NVMe self-heal self-check failed"
	display_alert "NVMe self-heal verified in image" "$EXTENSION" "info"
	return 0
}
