#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# KICKPI K1 板级扩展：关闭所有网口的 EEE/LPI 省电 + 钉死网卡运行时电源管理
#
# 为什么必须有（实机证据，2026-10-13 定案；lyw-OS / lyw-kf 同案同修，本仓补齐）：
#   现象：网口"灯亮但拿不到 IP"、整口间歇 Link Down —— 用网高峰 34 次/3h（1~7 分钟一次），
#         深夜几乎不掉；重启后好一阵子又复发。
#   根因链：对端 `phy_eee_wakeup_error_n=8126`、`irq_rx_path_in_lpi_mode_n`=7811 万
#         （EEE/LPI 省电态进出 7800 万次）→ EEE 唤醒时序在 RK3568 dwmac + PHY 上翻车 →
#         整口重新协商（两端 `rx_crc_errors=0` 已排除线材/水晶头；SoC 37°C 排除过热）。
#   处置判据：`ethtool --set-eee <if> eee off` 后掉线归零；关机重启后必须仍然是 off
#         （否则 EEE 会被重新协商打开，故障复发）。
#   与其它网口坑互不相同：`lyw-kf/PORTING.md` §3 那五层修的是"丢包/不通"，
#   本扩展修的是"通了但会间歇掉线"。
#
# 本扩展做三件事（三层持久化，缺一层都可能复发）：
#   1) /usr/local/sbin/kickpi-k1-eee-off.sh —— 对【每个真实网卡】执行 `--set-eee eee off`
#      并把 `/sys/class/net/<if>/device/power/control` 钉为 `on`（禁运行时挂起）；带重试
#      （PHY/接口可能尚未就绪），不支持 EEE 的口（wifi/虚拟口）自动跳过。
#   2) kickpi-k1-eee-off.service —— 开机在网卡就绪后执行一次（After=network-online + 模块自愈单元）。
#   3) NetworkManager dispatcher（90-kickpi-k1-eee-off）—— 每次接口 up 都再关一次：
#      EEE 会随重新协商被打开，只在开机关一次不够（实机复发就是这么来的）。
#
# 说明：脚本按"所有 /sys/class/net/* 真实网卡"遍历（含 USB 网卡、后续新增口），
#       不是只写死 eth0/eth1 —— 板子插 USB 网卡也有 EEE，同样要关。
# ══════════════════════════════════════════════════════════════════════════

function post_post_debootstrap_tweaks__kickpi_k1_net_eee() {
	display_alert "Installing NIC EEE/LPI fix (KICKPI K1)" "$EXTENSION" "info"

	local fail=0

	# ethtool 是命门（没有它这套修复等于不存在）
	if [[ ! -x "${SDCARD}/usr/sbin/ethtool" && ! -x "${SDCARD}/usr/bin/ethtool" ]]; then
		chroot_sdcard_apt_get_install ethtool >/dev/null 2>&1 || true
	fi
	if [[ -x "${SDCARD}/usr/sbin/ethtool" || -x "${SDCARD}/usr/bin/ethtool" ]]; then
		display_alert "ethtool present in image" "$EXTENSION" "info"
	else
		display_alert "ethtool 既不在镜像也无法安装 —— EEE 关闭服务将无效" "$EXTENSION" "err"
		fail=1
	fi

	mkdir -p "${SDCARD}/usr/local/sbin" "${SDCARD}/etc/systemd/system"
	mkdir -p "${SDCARD}/etc/NetworkManager/dispatcher.d"

	# ── 1) 关闭脚本（与 lyw-kf assets/kickpi-k1-eee-off.sh 同款，保持两线一致）──
	cat <<- 'EOF' > "${SDCARD}/usr/local/sbin/kickpi-k1-eee-off.sh"
		#!/bin/sh
		# KICKPI K1：关闭所有真实网卡的 EEE/LPI 省电，并把运行时电源管理钉为 on。
		# 为什么：EEE 唤醒时序在本板 RK3568 dwmac + Maxio MAE0621A 上翻车 → 整口间歇 Link Down
		# （实机判据：对端 phy_eee_wakeup_error_n=8126、LPI 进出 7800 万次；关上后掉线归零）。
		# 幂等：可反复执行（开机一次 + 每次接口 up 一次 + 人工随时跑）。

		ETHTOOL="$(command -v ethtool 2>/dev/null || echo /usr/sbin/ethtool)"
		[ -x "$ETHTOOL" ] || { echo "kickpi-k1-eee-off: ethtool missing"; exit 1; }

		attempt=0
		while [ "$attempt" -lt 15 ]; do
			attempt=$((attempt + 1))
			pending=0
			for d in /sys/class/net/*; do
				[ -e "$d" ] || continue
				nic=${d##*/}
				case "$nic" in
					lo|docker*|veth*|br-*|virbr*|wg*|tailscale*|tun*|p2p*) continue ;;
				esac
				if ! "$ETHTOOL" --set-eee "$nic" eee off 2>/dev/null; then
					# set 失败：该口若根本不支持 EEE（--show-eee 也失败）就不算欠账
					if "$ETHTOOL" --show-eee "$nic" >/dev/null 2>&1; then
						pending=1
					fi
				fi
				pm="$d/device/power/control"
				if [ -w "$pm" ]; then
					echo on > "$pm" 2>/dev/null || true
				fi
			done
			[ "$pending" -eq 0 ] && break
			sleep 2
		done
		echo "kickpi-k1-eee-off: done (attempt=$attempt)"
		exit 0
	EOF
	chmod 0755 "${SDCARD}/usr/local/sbin/kickpi-k1-eee-off.sh"

	# ── 2) 开机执行一次 ───────────────────────────────────────────────
	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/kickpi-k1-eee-off.service"
		[Unit]
		Description=iNextOS(KICKPI K1): disable NIC EEE/LPI (link-stability fix)
		After=network-online.target kickpi-k1-modules.service
		Wants=network-online.target
		ConditionPathExists=/usr/local/sbin/kickpi-k1-eee-off.sh

		[Service]
		Type=oneshot
		ExecStart=/bin/sh /usr/local/sbin/kickpi-k1-eee-off.sh
		RemainAfterExit=yes

		[Install]
		WantedBy=multi-user.target
	EOF

	# ── 3) 每次接口 up 再关一次（EEE 会随重新协商被打开，只在开机关一次不够）──
	cat <<- 'EOF' > "${SDCARD}/etc/NetworkManager/dispatcher.d/90-kickpi-k1-eee-off"
		#!/bin/sh
		# NetworkManager 在每个接口状态变化时调用：$1=接口 $2=动作。
		# 只关心 up 类动作；脚本自身幂等，重复调用无副作用。
		IFACE="$1"; ACTION="$2"
		case "$ACTION" in
			up|dhcp4-change|dhcp6-change|connectivity-change) ;;
			*) exit 0 ;;
		esac
		[ -x /usr/local/sbin/kickpi-k1-eee-off.sh ] || exit 0
		# dispatcher 是同步阻塞路径：放后台跑，避免拖慢 NM 状态机
		( /bin/sh /usr/local/sbin/kickpi-k1-eee-off.sh >>/var/log/kickpi-k1-eee-off.log 2>&1 & ) >/dev/null 2>&1
		exit 0
	EOF
	chmod 0755 "${SDCARD}/etc/NetworkManager/dispatcher.d/90-kickpi-k1-eee-off"

	chroot_sdcard systemctl --no-reload enable kickpi-k1-eee-off.service >/dev/null 2>&1 || true

	if [[ $fail -ne 0 ]]; then
		exit_with_error "KICKPI K1 EEE fix incomplete (ethtool unavailable)"
	fi
	display_alert "NIC EEE off installed (script + service + NM dispatcher)" "$EXTENSION" "info"
	return 0
}

# ══════════════════════════════════════════════════════════════════════════
# 最终态断言：关不掉 EEE 就等于链路间歇掉线会复发 —— 按仓库惯例直接 fail，不静默
# ══════════════════════════════════════════════════════════════════════════
function pre_umount_final_image__kickpi_k1_net_eee() {
	display_alert "Final-pass: verify NIC EEE fix (KICKPI K1)" "$EXTENSION" "info"

	local fail=0
	[[ -x "${SDCARD}/usr/local/sbin/kickpi-k1-eee-off.sh" ]] || {
		display_alert "EEE 关闭脚本未就位" "$EXTENSION" "err"; fail=1; }
	sh -n "${SDCARD}/usr/local/sbin/kickpi-k1-eee-off.sh" 2>/dev/null || {
		display_alert "kickpi-k1-eee-off.sh 语法错误" "$EXTENSION" "err"; fail=1; }
	grep -q -- '--set-eee' "${SDCARD}/usr/local/sbin/kickpi-k1-eee-off.sh" || {
		display_alert "EEE 脚本缺 --set-eee" "$EXTENSION" "err"; fail=1; }
	grep -q 'eee off' "${SDCARD}/usr/local/sbin/kickpi-k1-eee-off.sh" || {
		display_alert "EEE 脚本缺 'eee off'" "$EXTENSION" "err"; fail=1; }
	grep -q 'power/control' "${SDCARD}/usr/local/sbin/kickpi-k1-eee-off.sh" || {
		display_alert "EEE 脚本缺 power/control 钉死" "$EXTENSION" "err"; fail=1; }

	[[ -f "${SDCARD}/etc/systemd/system/kickpi-k1-eee-off.service" ]] || {
		display_alert "EEE 服务单元缺失" "$EXTENSION" "err"; fail=1; }
	mkdir -p "${SDCARD}/etc/systemd/system/multi-user.target.wants"
	ln -sf /etc/systemd/system/kickpi-k1-eee-off.service \
		"${SDCARD}/etc/systemd/system/multi-user.target.wants/kickpi-k1-eee-off.service"
	[[ -x "${SDCARD}/etc/NetworkManager/dispatcher.d/90-kickpi-k1-eee-off" ]] || {
		display_alert "NM dispatcher 缺失（接口 up 后不会重新关 EEE）" "$EXTENSION" "err"; fail=1; }

	local et
	et="$(ls "${SDCARD}"/usr/sbin/ethtool "${SDCARD}"/usr/bin/ethtool 2>/dev/null | head -1 || true)"
	[[ -n "$et" ]] || { display_alert "镜像缺 ethtool" "$EXTENSION" "err"; fail=1; }

	[[ $fail == 0 ]] || exit_with_error "KICKPI K1 EEE fix self-check failed"
	display_alert "NIC EEE fix verified in image" "$EXTENSION" "info"
	return 0
}
