#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# KICKPI K1 板级扩展：在线更新配套（内核【不钉死】；模块自愈为主，快照回退为兜底）
#
# 定位：真正让"更新后网口还能起来"的是 extensions/kickpi-k1-module-selfheal.sh
#       （模块化 + DKMS + postinst 钩子 + 开机自愈 + softdep，方案与实证见该文件）。
#       本扩展只做三件配套的事，且刻意【不碰】apt 的升级能力：
#         a) 更新后自动体检：内核 release 一变，就把网口/驱动/模块状态写进日志与 /boot，
#            这样"更新有没有把网口弄坏"当场可见（卡拔下来插到 PC 上也能看）。
#         b) 最后一道兜底：/boot 保存"网口已验证可用"的引导快照 *.good；开机守卫在网络起不来的
#            情况下用快照回滚一次并重启（要人救急时也有手工路径）。
#         c) 救急通道自检：USB 网卡 / 串口 / HDMI 是否具备（不依赖板级 PHY 驱动）。
#
# 为什么不做"钉死内核"（2026-10-13 用户明确要求 + 事实核对）：
#   · 在线更新是必须保留的能力（官方就是这么更新内核的）；
#   · 钉死 / hold 只是把问题变成"永远不敢更新"，且一旦被 unhold 就静默失效；
#   · 本板正解是让驱动跟着内核走（模块自愈）—— lyw-kf/飞牛线已实机跑通
#     （2026-10-12 内核 c951→c1145 更新后 15 秒网口恢复）。故这里不写 pin、不写 apt 偏好。
# ══════════════════════════════════════════════════════════════════════════

function post_post_debootstrap_tweaks__kickpi_k1_update_guard() {
	display_alert "Installing online-update companion (KICKPI K1)" "$EXTENSION" "info"

	mkdir -p "${SDCARD}/usr/local/sbin" "${SDCARD}/usr/local/share/k1" "${SDCARD}/etc/systemd/system"

	# ── (a) 更新后体检：内核变了就记录 + 体检，落盘到 /var/log 与 /boot ──
	cat <<- 'EOF' > "${SDCARD}/usr/local/sbin/k1-update-check"
		#!/bin/bash
		# 在线更新后自动体检：运行内核与上次记录不同 → 记一笔并跑体检。
		# 同时写 /var/log/k1-update-check.log 与 /boot/k1-update-check.log：
		# 后者的意义是【卡拔下来插到任意 PC 上就能看】，不需要设备能联网或能登录。
		set -u
		STATE=/var/lib/k1-last-kernel
		LOG=/var/log/k1-update-check.log
		BOOTLOG=/boot/k1-update-check.log
		REL="$(uname -r)"
		last=""; [ -f "$STATE" ] && last="$(cat "$STATE" 2>/dev/null)"
		if [ "$REL" != "$last" ]; then
			mkdir -p "$(dirname "$STATE")"
			{
				echo "==== $(date '+%F %T') kernel=$REL (上次=$last) ===="
				/usr/local/sbin/k1-net-health 2>/dev/null || true
			} | tee -a "$LOG" >> "$BOOTLOG"
			echo "$REL" > "$STATE"
		fi
		exit 0
	EOF
	chmod 0755 "${SDCARD}/usr/local/sbin/k1-update-check"

	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/k1-update-check.service"
		[Unit]
		Description=iNextOS(KICKPI K1): post-update kernel/NIC health check
		DefaultDependencies=no
		After=network-online.target kickpi-k1-modules.service
		Wants=network-online.target
		RequiresMountsFor=/boot
		ConditionPathExists=/usr/local/sbin/k1-update-check

		[Service]
		Type=oneshot
		ExecStart=/usr/local/sbin/k1-update-check
		RemainAfterExit=yes

		[Install]
		WantedBy=multi-user.target
	EOF

	# ── (b) 引导快照 + 开机守卫（兜底回滚）──────────────────────────────
	cat <<- 'EOF' > "${SDCARD}/usr/local/sbin/k1-boot-snapshot"
		#!/bin/bash
		# 只在"有线网口已 carrier"的启动里快照 —— 保证 *.good 一定是"网口能用"的那套引导文件。
		set -u
		BOOT=/boot
		LOG=/var/log/k1-boot-guard.log
		log(){ echo "$(date -Is) snapshot: $*" >> "$LOG"; logger -t k1-boot-snapshot "$*"; }
		net_ok=0
		for n in /sys/class/net/eth*; do
			[ -e "$n" ] || continue
			[ "$(cat "$n/carrier" 2>/dev/null)" = 1 ] && net_ok=1
		done
		[ "$net_ok" = 1 ] || { log "跳过：当前启动没有任何有线网口 carrier"; exit 0; }
		[ -f "$BOOT/Image" ] || { log "跳过：没有 $BOOT/Image"; exit 0; }
		snap=0
		for f in Image uInitrd; do
			[ -f "$BOOT/$f" ] || continue
			if ! cmp -s "$BOOT/$f" "$BOOT/$f.good"; then cp -f "$BOOT/$f" "$BOOT/$f.good"; snap=1; fi
		done
		DTB=$(sed -n 's/^fdtfile=//p' "$BOOT/armbianEnv.txt" 2>/dev/null | tr -d '\r' | head -1)
		if [ -n "$DTB" ] && [ -f "$BOOT/dtb/$DTB" ]; then
			base=$(basename "$DTB")
			if ! cmp -s "$BOOT/dtb/$DTB" "$BOOT/$base.good"; then cp -f "$BOOT/dtb/$DTB" "$BOOT/$base.good"; snap=1; fi
		fi
		if [ "$snap" = 1 ]; then
			( cd "$BOOT" && sha256sum Image.good uInitrd.good *.dtb.good 2>/dev/null > .k1-boot-good.sha256 )
			sync; log "已更新引导快照 *.good（kernel $(uname -r)）"
		else
			log "快照已是最新"
		fi
		exit 0
	EOF
	chmod 0755 "${SDCARD}/usr/local/sbin/k1-boot-snapshot"

	cat <<- 'EOF' > "${SDCARD}/usr/local/sbin/k1-boot-guard"
		#!/bin/bash
		# 最后一道兜底：管理网口在 K1_NET_TIMEOUT 秒内没有 carrier，就用 *.good 回滚引导文件并重启一次。
		# 主路径是模块自愈（kickpi-k1-modules.service）；本守卫只在"自愈也没救回来"时出手，
		# 避免设备变成只能拔卡的砖。marker 防启动循环。
		set -u
		BOOT=/boot
		LOG=/var/log/k1-boot-guard.log
		MARK="$BOOT/.k1-rollback-attempted"
		TIMEOUT="${K1_NET_TIMEOUT:-60}"
		log(){ echo "$(date -Is) guard: $*" >> "$LOG"; logger -t k1-boot-guard "$*"; }

		[ -e "$MARK" ] && { log "marker 存在（本次已回滚过一次），不再尝试，避免启动循环"; exit 0; }

		ok=0; t=0
		while [ "$t" -lt "$TIMEOUT" ]; do
			for n in /sys/class/net/eth*; do
				[ -e "$n" ] || continue
				[ "$(cat "$n/carrier" 2>/dev/null)" = 1 ] && ok=1
			done
			[ "$ok" = 1 ] && break
			sleep 2; t=$((t+2))
		done
		if [ "$ok" = 1 ]; then log "有线网口已 carrier（${t}s），引导组合判定可用"; rm -f "$MARK"; exit 0; fi

		log "WARN ${TIMEOUT}s 内没有任何有线网口 carrier —— 先看模块自愈日志，再考虑回滚"
		restore=0
		if [ -f "$BOOT/Image.good" ] && ! cmp -s "$BOOT/Image.good" "$BOOT/Image"; then
			cp -f "$BOOT/Image.good" "$BOOT/Image"; restore=1; log "回滚 Image"
		fi
		if [ -f "$BOOT/uInitrd.good" ] && ! cmp -s "$BOOT/uInitrd.good" "$BOOT/uInitrd"; then
			cp -f "$BOOT/uInitrd.good" "$BOOT/uInitrd"; restore=1; log "回滚 uInitrd"
		fi
		DTB=$(sed -n 's/^fdtfile=//p' "$BOOT/armbianEnv.txt" 2>/dev/null | tr -d '\r' | head -1)
		if [ -n "$DTB" ]; then
			base=$(basename "$DTB")
			if [ -f "$BOOT/$base.good" ] && [ -f "$BOOT/dtb/$DTB" ] && ! cmp -s "$BOOT/$base.good" "$BOOT/dtb/$DTB"; then
				cp -f "$BOOT/$base.good" "$BOOT/dtb/$DTB"; restore=1; log "回滚 DTB $base"
			fi
		fi
		touch "$MARK"; sync
		if [ "$restore" = 1 ]; then log "引导文件已回滚，重启一次验证"; /sbin/reboot -f; else
			log "没有可用快照或与现状一致 —— 保持现状（改用串口 / USB 网卡介入）"; fi
		exit 0
	EOF
	chmod 0755 "${SDCARD}/usr/local/sbin/k1-boot-guard"

	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/k1-boot-guard.service"
		[Unit]
		Description=iNextOS(KICKPI K1): roll back boot files if the wired NIC never comes up
		DefaultDependencies=no
		After=local-fs.target boot.mount kickpi-k1-modules.service
		RequiresMountsFor=/boot
		ConditionPathExists=/usr/local/sbin/k1-boot-guard

		[Service]
		Type=oneshot
		ExecStart=/usr/local/sbin/k1-boot-guard
		TimeoutStartSec=180
		RemainAfterExit=yes

		[Install]
		WantedBy=multi-user.target
	EOF

	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/k1-boot-snapshot.service"
		[Unit]
		Description=iNextOS(KICKPI K1): snapshot known-good boot files (Image/dtb/uInitrd)
		DefaultDependencies=no
		After=network-online.target k1-boot-guard.service
		RequiresMountsFor=/boot
		ConditionPathExists=/usr/local/sbin/k1-boot-snapshot

		[Service]
		Type=oneshot
		ExecStart=/usr/local/sbin/k1-boot-snapshot
		RemainAfterExit=yes

		[Install]
		WantedBy=multi-user.target
	EOF

	# ── (c) 体检工具（排障第一入口）────────────────────────────────────
	cat <<- 'EOF' > "${SDCARD}/usr/local/sbin/k1-net-health"
		#!/bin/bash
		# 一眼看清"网口这件事"：板级 PHY 驱动在不在（本板为模块形态）、两个 gmac 绑了没、carrier 如何、
		# 自愈链条是否完整、救急通道是否存在。排障先跑它。
		set -u
		echo "===== 内核 ====="
		uname -a
		echo
		echo "===== 板级 PHY 驱动（双千兆命门，本板为模块形态）====="
		if modinfo maxio >/dev/null 2>&1; then
			modinfo maxio | grep -E '^(filename|version|vermagic)' | sed 's/^/  /'
			if lsmod | grep -q '^maxio'; then echo "  ✓ maxio 已加载"; else echo "  ! maxio 未加载（自检单元会尝试拉起，见 /var/log/kickpi-k1-modules.log）"; fi
		else
			echo "  ✗ 模块索引里没有 maxio —— 当前内核可能没有板级驱动（见 /var/log/kickpi-k1-modules.log）"
		fi
		echo
		echo "===== 两个 gmac 与其 PHY ====="
		for d in /sys/class/net/eth*; do
			[ -e "$d" ] || continue
			n=$(basename "$d")
			drv=$(readlink -f "$d/device/driver" 2>/dev/null | xargs -r basename)
			printf '  %-6s driver=%-18s carrier=%-2s speed=%-7s mac=%s\n' "$n" "${drv:-无}" \
				"$(cat "$d/carrier" 2>/dev/null || echo '?')" "$(cat "$d/speed" 2>/dev/null || echo '-')" "$(cat "$d/address" 2>/dev/null)"
		done
		echo
		echo "===== EEE/LPI 省电（必须全 off：开着 = 网口会间歇整口掉线）====="
		if command -v ethtool >/dev/null 2>&1; then
			for d in /sys/class/net/eth* /sys/class/net/en*; do
				[ -e "$d" ] || continue
				n=$(basename "$d")
				st=$(ethtool --show-eee "$n" 2>/dev/null | awk -F': ' '/^EEE status/{print $2}')
				pm=$(cat "$d/device/power/control" 2>/dev/null || echo '-')
				printf '  %-6s EEE=%-16s power/control=%s\n' "$n" "${st:-不支持或不可查}" "$pm"
			done
			echo "  · 期望：EEE=disabled / power/control=on（修复件 kickpi-k1-eee-off.service + NM dispatcher）"
		else
			echo "  ✗ 镜像里没有 ethtool —— EEE 状态无法核对（修复件也失效）"
		fi
		echo
		echo "===== 自愈链条（在线更新后靠它把网口拉回来）====="
		for f in /usr/src/kickpi-k1/maxio.c /usr/local/sbin/kickpi-k1-build-maxio \
		         /usr/local/sbin/kickpi-k1-load-modules /etc/kernel/postinst.d/zz-kickpi-k1-maxio \
		         /etc/modprobe.d/kickpi-k1.conf /etc/modules-load.d/kickpi-k1.conf; do
			[ -e "$f" ] && echo "  ✓ $f" || echo "  ✗ 缺 $f"
		done
		if [ -d "/lib/modules/$(uname -r)/build" ]; then echo "  ✓ 本内核 headers 在位（可现编）"; else
			echo "  ! 本内核 headers 不在（现编不可用；装 linux-headers-$(uname -r) 即可）"; fi
		echo
		echo "===== 引导快照对照 ====="
		for f in /boot/Image /boot/uInitrd; do
			[ -f "$f.good" ] || { echo "  · 缺 $f.good"; continue; }
			cmp -s "$f.good" "$f" && echo "  ✓ $(basename "$f") 与快照一致" || echo "  ! $(basename "$f") 与快照不同（可能刚换过内核）"
		done
		echo
		echo "===== 救急通道（不依赖板级 PHY 驱动）====="
		for m in r8152 ax88179_178a cdc_ether usbnet; do
			grep -q "^$m " /proc/modules 2>/dev/null && echo "  ✓ $m 已加载" || echo "  · $m 未加载（插上对应 USB 网卡会按需加载）"
		done
		echo "  · 串口控制台 /dev/ttyS2@1500000、HDMI 控制台；u-boot 在 SD 卡裸区，在线更新碰不到"
		exit 0
	EOF
	chmod 0755 "${SDCARD}/usr/local/sbin/k1-net-health"

	cat <<- 'EOF' > "${SDCARD}/usr/local/share/k1/UPDATES.md"
		# iNextOS(KICKPI K1) 在线更新说明（内核不钉死）

		## 结论先说
		- 在线更新**照常做**，内核该更新就更新，安装包不被 hold、不被 pin。
		- 网口能起来靠**模块自愈**：板级 PHY 驱动是模块（maxio.ko），
		  每次内核安装后由 `/etc/kernel/postinst.d/zz-kickpi-k1-maxio` 对新内核重编装好；
		  没编成也有开机自愈（`kickpi-k1-modules.service`，按 `uname -r` 补编再加载）。
		- 万一还是没起来：`k1-net-health` 看现场 → 需要时用 `/boot/*.good` 回滚（开机守卫也会自动试一次），
		  或直接用串口 / USB 网卡介入（不依赖板级驱动）。

		## 更新完怎么验证（一条命令）
		    k1-net-health
		过关判据（四项全中才算好）：
		  1) `modinfo maxio` 有输出，且 `lsmod` 里 maxio 在；
		  2) 两个 `eth*` 的 `driver=dwmac_rockchip`，插线的那个 `carrier=1`；
		  3) `/var/log/kickpi-k1-modules.log` 里出现 `phy_id=0x7b744411` 与 `Link is Up`；
		  4) `ethtool --show-eee ethX` 全是 disabled、`power/control` 全是 on
		     （EEE 开着 = 链路会间歇整口掉线，实机 34 次/3h；修复件 kickpi-k1-eee-off.service）。

		## 出问题看哪里
		- `/boot/k1-update-check.log`、`/var/log/k1-update-check.log`：内核一变就自动体检的结果（卡拔到 PC 上也能看）。
		- `/var/log/kickpi-k1-modules.log`：模块加载 / 现编 / 自检全过程。
		- `/var/log/k1-boot-guard.log`：兜底回滚记录。
		- `/var/lib/kickpi-k1/needs-build-<新内核>`：说明那时 headers 没到位；装上
		  `linux-headers-<新内核>` 后重启，自愈单元会补编。

		## 救急（网口彻底不通）
		1) 串口：板载 UART 1500000（COM3）或 HDMI 控制台；
		2) USB 网卡：内核带 r8152 / ax88179_178a / cdc_ether（按需加载），插上即有第二条网口；
		3) 取卡插到别的机器：/boot 是 FAT，可直接看 *.good 与 k1-update-check.log；Windows 也能读。
		EOF

	for u in k1-update-check.service k1-boot-guard.service k1-boot-snapshot.service; do
		chroot_sdcard systemctl --no-reload enable "$u" >/dev/null 2>&1 || true
	done

	display_alert "online-update companion installed (check + snapshot/rollback + rescue selfcheck)" "$EXTENSION" "info"
	return 0
}

# ══════════════════════════════════════════════════════════════════════════
# 最终态断言
# ══════════════════════════════════════════════════════════════════════════
function pre_umount_final_image__kickpi_k1_update_guard() {
	display_alert "Final-pass: verify online-update companion (KICKPI K1)" "$EXTENSION" "info"

	local fail=0
	for f in usr/local/sbin/k1-update-check usr/local/sbin/k1-boot-snapshot \
	         usr/local/sbin/k1-boot-guard usr/local/sbin/k1-net-health \
	         etc/systemd/system/k1-update-check.service etc/systemd/system/k1-boot-guard.service \
	         etc/systemd/system/k1-boot-snapshot.service usr/local/share/k1/UPDATES.md; do
		[[ -e "${SDCARD}/${f}" ]] || { display_alert "companion file missing: ${f}" "$EXTENSION" "err"; fail=1; }
	done
	for f in k1-update-check k1-boot-snapshot k1-boot-guard k1-net-health; do
		[[ -x "${SDCARD}/usr/local/sbin/${f}" ]] || { display_alert "not executable: ${f}" "$EXTENSION" "err"; fail=1; }
	done
	# 刻意不钉内核：镜像里不应出现对本板内核包的 apt -1 偏好
	if grep -rq 'linux-image-vendor-rk35xx' "${SDCARD}/etc/apt/preferences.d/" 2>/dev/null; then
		display_alert "发现内核 pin（与本板设计相悖：内核不钉死，靠模块自愈）" "$EXTENSION" "err"; fail=1
	fi

	for u in k1-update-check k1-boot-guard k1-boot-snapshot; do
		mkdir -p "${SDCARD}/etc/systemd/system/multi-user.target.wants"
		ln -sf "/etc/systemd/system/${u}.service" "${SDCARD}/etc/systemd/system/multi-user.target.wants/${u}.service"
	done

	[[ $fail == 0 ]] || exit_with_error "KICKPI K1 online-update companion self-check failed"
	display_alert "online-update companion verified in image" "$EXTENSION" "info"
	return 0
}
