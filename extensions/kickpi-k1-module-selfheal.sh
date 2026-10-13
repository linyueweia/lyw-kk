#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# KICKPI K1 板级扩展：板级模块自愈（内核不钉死，在线更新后网口自动恢复）
#
# 这一条解决的是本板最要命的风险链（实机事实，2026-10-13 定案）：
#   本板双千兆靠自建 Maxio MAE0621A PHY 驱动（patch/general-drv-net-phy-maxio-mae0621a.patch）。
#   内建（=y）时，任何"换了内核 Image"的更新都会把驱动一起换掉 → 两个网口同时失联，
#   而板子只有这两个网口做管理面 → 一次在线更新就能把设备变成砖（只能拔卡救）。
#   内建驱动没有任何补救手段；模块化之后才有：源码随镜像 + 对新内核重编 + 开机自愈装载。
#
# 方案来源与证据（不重复造轮子）：
#   lyw-kf（飞牛线）在同一块 K1 上用同款机制跑通并实测：
#     2026-10-12 18:45 起走官方在线更新 → 装新内核 6.18.18.c1145-trim →
#     /etc/kernel/postinst.d 钩子自动为新内核编出 maxio.ko → 18:52 双网口恢复，
#     全程无人干预（lyw-kf/TROUBLESHOOTING.md §2.1，判据：uname -r 为新内核且
#     /usr/lib/modules/$(uname -r)/updates/kickpi-k1/maxio.ko 存在、dmesg 出现
#     phy_id=0x7b744411 与 Link is Up）。
#
# 本扩展装进镜像的东西（每件都有为什么）：
#   1) /usr/src/kickpi-k1/{maxio.c,Makefile}
#      —— 树外源码。maxio.c 直接【从本仓补丁提取】（单一事实来源，避免两份源码漂移），
#         并在钩子里断言提取出的版本串与补丁一致。
#   2) /usr/src/maxio-1.8.1.1/{maxio.c,Makefile,dkms.conf} + dkms add
#      —— DKMS 注册（镜像里已自带 dkms 与 /etc/kernel/postinst.d/dkms，r8125/r8723bs 是既有先例）。
#         只注册不构建：当前内核的 .ko 由树内构建提供，DKMS 负责【将来】的新内核自动重编。
#   3) /usr/local/sbin/kickpi-k1-build-maxio
#      —— 设备端现编脚本：按指定 release 编 maxio.ko 到 /usr/lib/modules/$rel/updates/kickpi-k1/，
#         并用 vermagic 硬闸校验（lyw-kf BUILD-RECIPE 的教训：vermagic 差一个后缀装机直接被拒，
#         而 CONFIG_MODULE_SIG/MODVERSIONS 未开 → 必须逐字匹配 release）。
#   4) /etc/kernel/postinst.d/zz-kickpi-k1-maxio
#      —— 每装一个新内核自动触发上面的构建；chroot/CI 环境跳过；
#         头文件未就绪则写 /var/lib/kickpi-k1/needs-build-<rel> 标记，交给开机自愈补编。
#   5) /usr/local/sbin/kickpi-k1-load-modules + kickpi-k1-modules.service
#      —— 开机自愈：按 uname -r 定位模块，缺则现编现装再加载；顺序 maxio → stmmac → dwmac-rockchip；
#         自检结果写 /var/log/kickpi-k1-modules.log（也可从卡上离线读）。
#   6) /etc/modprobe.d/kickpi-k1.conf
#      —— softdep 保证 maxio 先于 MAC 驱动注册。为什么必须：phylib 在 MAC 探测时就把 PHY
#         绑到当时的驱动上，晚到的 maxio 会被跳过（lyw-kf PORTING 坑④ 实测）。
#   7) /etc/modules-load.d/kickpi-k1.conf —— 开机尽早加载 maxio（systemd-modules-load），
#      与 softdep、开机单元构成三重顺序保障。
#
# 不做什么（刻意的）：
#   · 不钉死/不 hold 任何内核包 —— 在线更新该更新就更新；网口靠模块自愈，不靠禁止更新。
#   · 不改 u-boot（在 SD 卡裸区，任何在线更新都碰不到）。
# ══════════════════════════════════════════════════════════════════════════

K1_MAXIO_SRC_DIR="${SRC:-/armbian/userpatches}"  # 仅作占位；实际路径由构建期变量决定

function post_post_debootstrap_tweaks__kickpi_k1_module_selfheal() {
	display_alert "Installing board-module self-heal (KICKPI K1)" "$EXTENSION" "info"

	local patch="${SRC}/patch/kernel/rk35xx-vendor-6.1/general-drv-net-phy-maxio-mae0621a.patch"
	[[ -f "$patch" ]] || exit_with_error "maxio patch not found for source extraction: ${patch}"

	# ── 1) 从补丁提取 maxio.c（单一事实来源）───────────────────────────
	mkdir -p "${SDCARD}/usr/src/kickpi-k1"
	python3 - "$patch" "${SDCARD}/usr/src/kickpi-k1/maxio.c" <<'PYEOF' || exit_with_error "maxio.c extraction failed"
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8', errors='replace').read()
m = re.search(r'diff --git a/drivers/net/phy/maxio\.c b/drivers/net/phy/maxio\.c\n(.*?)(?=\ndiff --git |\Z)', text, re.S)
if not m:
    sys.exit("maxio.c hunk not found in patch")
body = []
for line in m.group(1).splitlines():
    if line.startswith(('@@', '---', '+++', 'index ')):
        continue
    if line.startswith('+'):
        body.append(line[1:])
code = '\n'.join(body) + '\n'
if 'module_phy_driver' not in code or '0x7b744411' not in code:
    sys.exit("extracted maxio.c looks wrong (no module_phy_driver / PHY ID)")
open(dst, 'w', newline='\n').write(code)
print("extracted maxio.c: %d bytes" % len(code))
PYEOF
	printf 'obj-m += maxio.o\n' > "${SDCARD}/usr/src/kickpi-k1/Makefile"

	# ── 2) DKMS 注册（只注册，不在此处构建）────────────────────────────
	if [[ -x "${SDCARD}/usr/sbin/dkms" ]]; then
		local dk="/usr/src/maxio-1.8.1.1"
		mkdir -p "${SDCARD}${dk}"
		cp "${SDCARD}/usr/src/kickpi-k1/maxio.c" "${SDCARD}${dk}/maxio.c"
		cp "${SDCARD}/usr/src/kickpi-k1/Makefile" "${SDCARD}${dk}/Makefile"
		cat <<- 'EOF' > "${SDCARD}${dk}/dkms.conf"
			PACKAGE_NAME="maxio"
			PACKAGE_VERSION="1.8.1.1"
			BUILT_MODULE_NAME[0]="maxio"
			BUILT_MODULE_LOCATION[0]="."
			DEST_MODULE_LOCATION[0]="/updates/kickpi-k1"
			AUTOINSTALL="yes"
			MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
			CLEAN="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build clean"
		EOF
		# 注册（不 build/install）：当前内核的 .ko 由树内构建提供
		chroot_sdcard dkms add -m maxio -v 1.8.1.1 >/dev/null 2>&1 || true
		[[ -f "${SDCARD}/var/lib/dkms/maxio/1.8.1.1/source/maxio.c" ]] || \
			display_alert "dkms registration skipped (will still work via postinst hook + boot self-heal)" "$EXTENSION" "wrn"
	else
		display_alert "dkms not in image; using postinst hook + boot self-heal only" "$EXTENSION" "wrn"
	fi

	# ── 2b) 尽量把本内核的 headers 也装进镜像（可选件：只为"离线也能现编"）─────
	# 为什么标"可选"：apt 装来的内核，其 headers 必在同一 apt 源里（postinst 钩子会自动拉）；
	# 而本仓自己的内核包本身就带 =m 产物 maxio.ko（压根不需要重编）。
	# 所以 headers 缺失不构成硬失败，能装上就装上（构建期磁盘/网络都充裕，反而省钱省事）。
	local hdr_n=0
	hdr_n=$(ls -d "${SDCARD}"/usr/src/linux-headers-* 2>/dev/null | wc -l)
	if [[ "${hdr_n}" -eq 0 ]]; then
		chroot_sdcard_apt_get_install linux-headers-vendor-rk35xx >/dev/null 2>&1 || true
		hdr_n=$(ls -d "${SDCARD}"/usr/src/linux-headers-* 2>/dev/null | wc -l)
	fi
	if [[ "${hdr_n}" -eq 0 ]]; then
		# 退路：直接用框架刚编出来的 headers deb（apt 路由不通时）
		local d hdr_deb=""
		for d in /armbian/output/debs /armbian/debs "${SRC}/../output/debs" "${DEBS_DIR:-/nonexistent}"; do
			[[ -d "$d" ]] || continue
			hdr_deb="$(ls "$d"/linux-headers-*.deb 2>/dev/null | head -1 || true)"
			[[ -n "$hdr_deb" ]] && break
		done
		if [[ -n "$hdr_deb" ]]; then
			cp -f "$hdr_deb" "${SDCARD}/tmp/" 2>/dev/null || true
			chroot_sdcard dpkg -i "/tmp/$(basename "$hdr_deb")" >/dev/null 2>&1 || true
			chroot_sdcard apt-get -y -f install >/dev/null 2>&1 || true
			hdr_n=$(ls -d "${SDCARD}"/usr/src/linux-headers-* 2>/dev/null | wc -l)
		fi
	fi
	if [[ "${hdr_n}" -gt 0 ]]; then
		display_alert "kernel headers installed in image (offline rebuild可用)" "$EXTENSION" "info"
	else
		display_alert "kernel headers 未装进镜像（可选）：换内核后钩子会 apt 拉取；本仓内核包自带 maxio.ko，不影响网口恢复" "$EXTENSION" "wrn"
	fi

	# ── 3) 设备端现编脚本（vermagic 硬闸）─────────────────────────────
	mkdir -p "${SDCARD}/usr/local/sbin"
	cat <<- 'EOF' > "${SDCARD}/usr/local/sbin/kickpi-k1-build-maxio"
		#!/bin/bash
		# 为指定内核 release 编译并安装 maxio.ko。
		# 位置：/usr/lib/modules/<rel>/updates/kickpi-k1/maxio.ko（与 lyw-kf 同款，便于比对）
		# 硬闸：产物 vermagic 必须逐字包含目标 release（MODULE_SIG/MODVERSIONS 未开 → 只能逐字匹配）。
		set -u
		REL="${1:-$(uname -r)}"
		SRCDIR=/usr/src/kickpi-k1
		DEST="/usr/lib/modules/$REL/updates/kickpi-k1"
		KDIR="/lib/modules/$REL/build"
		LOG=/var/log/kickpi-k1-modules.log
		say(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

		[[ -d "$SRCDIR" ]] || { say "✗ 缺 $SRCDIR（镜像未注入板级源码）"; exit 1; }
		[[ -d "$KDIR" ]] || { say "✗ 缺 $KDIR（内核 $REL 的 headers 未安装，如 linux-headers-$REL）"; exit 1; }
		command -v make >/dev/null || { say "✗ 无 make"; exit 1; }
		command -v gcc  >/dev/null || { say "✗ 无 gcc"; exit 1; }

		mkdir -p "$DEST"
		if [[ -f "$DEST/maxio.ko" ]] && strings "$DEST/maxio.ko" 2>/dev/null | grep -q "vermagic=.*$REL"; then
			say "✓ $REL 已有可用 maxio.ko，跳过编译"; exit 0
		fi

		WORK="$(mktemp -d /tmp/k1maxio.XXXXXX)"; trap 'rm -rf "$WORK"' EXIT
		mkdir -p "$WORK/src"
		cp "$SRCDIR/maxio.c" "$WORK/src/maxio.c"
		printf 'obj-m += maxio.o\n' > "$WORK/src/Makefile"
		if make -C "$KDIR" ARCH=arm64 M="$WORK/src" modules >"$WORK/build.log" 2>&1; then
			if [[ -f "$WORK/src/maxio.ko" ]] && strings "$WORK/src/maxio.ko" | grep -q "vermagic=.*$REL"; then
				cp -f "$WORK/src/maxio.ko" "$DEST/maxio.ko"
				( cd / && depmod -a "$REL" ) >/dev/null 2>&1 || true
				say "✓ maxio.ko 已装入 $DEST（vermagic 与 $REL 匹配）"
			else
				say "✗ vermagic 与 $REL 不匹配，拒绝安装（见 $WORK/build.log）"; exit 1
			fi
		else
			say "✗ 编译失败，日志尾部："; tail -12 "$WORK/build.log" | sed 's/^/    /' | tee -a "$LOG"; exit 1
		fi
		exit 0
	EOF
	chmod 0755 "${SDCARD}/usr/local/sbin/kickpi-k1-build-maxio"

	# ── 4) 内核 postinst 钩子（新内核自动重编）─────────────────────────
	mkdir -p "${SDCARD}/etc/kernel/postinst.d" "${SDCARD}/var/lib/kickpi-k1"
	cat <<- 'EOF' > "${SDCARD}/etc/kernel/postinst.d/zz-kickpi-k1-maxio"
		#!/bin/sh
		# KICKPI K1：每次内核安装/升级后，把板级 PHY 驱动对新内核重编并装好。
		# 由 dpkg 在 linux-image-* 安装后调用，$1 = 内核 release。
		# chroot/CI（镜像装配）里跳过：那里编不了也没必要编。
		set -e
		REL="${1:-}"
		[ -n "$REL" ] || exit 0
		# chroot 判定：根设备与 PID1 根设备不同即视为 chroot（镜像装配/CI）
		if [ "$(stat -c %d / 2>/dev/null)" != "$(stat -c %d /proc/1/root 2>/dev/null || echo same)" ]; then
			echo "kickpi-k1: chroot 环境，跳过 $REL 的板级模块构建"
			exit 0
		fi
		[ -x /usr/local/sbin/kickpi-k1-build-maxio ] || exit 0
		mkdir -p /var/lib/kickpi-k1
		# 快路径：该内核已经有 maxio.ko（本仓自己的内核包本身就带 =m 产物）→ 不必重编
		if [ -f "/lib/modules/$REL/kernel/drivers/net/phy/maxio.ko" ] || [ -f "/usr/lib/modules/$REL/updates/kickpi-k1/maxio.ko" ]; then
			echo "kickpi-k1: $REL 已有 maxio.ko，跳过构建"
			rm -f "/var/lib/kickpi-k1/needs-build-$REL"
			exit 0
		fi
		if [ ! -d "/lib/modules/$REL/build" ]; then
			# headers 没到位：先自己试着从 apt 拉（apt 装来的内核，其 headers 必在同一源里）——
			# 这是"装了新内核，网口自动回来"的最后一块拼图。断网/无源也不影响内核安装本身。
			if command -v apt-get >/dev/null 2>&1; then
				echo "kickpi-k1: $REL 缺 headers，尝试 apt 安装 linux-headers-$REL …"
				apt-get install -y --no-install-recommends \
					-o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
					"linux-headers-$REL" >/dev/null 2>&1 || true
			fi
		fi
		if [ ! -d "/lib/modules/$REL/build" ]; then
			echo "kickpi-k1: $REL 的 headers 未就绪，标记待开机补编"
			date '+%F %T' > "/var/lib/kickpi-k1/needs-build-$REL"
			exit 0
		fi
		echo "kickpi-k1: 为内核 $REL 构建 maxio.ko …"
		if /usr/local/sbin/kickpi-k1-build-maxio "$REL"; then
			rm -f "/var/lib/kickpi-k1/needs-build-$REL"
		else
			date '+%F %T' > "/var/lib/kickpi-k1/needs-build-$REL"
			echo "kickpi-k1: $REL 构建未成功（已标记，开机自愈会重试）" >&2
		fi
		exit 0
	EOF
	chmod 0755 "${SDCARD}/etc/kernel/postinst.d/zz-kickpi-k1-maxio"

	# ── 5) 开机加载 + 自愈单元 ─────────────────────────────────────────
	cat <<- 'EOF' > "${SDCARD}/usr/local/sbin/kickpi-k1-load-modules"
		#!/bin/bash
		# 按 uname -r 确定性加载板级模块；【缺模块才现编】（自愈），并记录自检结果。
		# 顺序：maxio(PHY) → stmmac → dwmac-rockchip，保证 PHY 驱动先注册（否则 PHY 会被绑到通用驱动）。
		#
		# 设计约束（用户明确要求，2026-10-13）：这是开机路径，绝不能拖慢启动 ——
		#   · 快路径（正常情况，99.9% 的启动）：只做几次文件存在判断（毫秒级），
		#     模块在位就直接加载，【完全不调用编译器】；
		#   · 慢路径（换过内核 / 模块丢了）：才现编补齐，且仅在 headers 在位时才动手；
		#   · 死路不重试：headers 缺失时写标记，后续启动直接跳过（headers 出现后标记自动失效）。
		set -u
		REL="$(uname -r)"
		DEST="/usr/lib/modules/$REL/updates/kickpi-k1"
		INBUILT="/lib/modules/$REL/kernel/drivers/net/phy/maxio.ko"
		KDIR="/lib/modules/$REL/build"
		STATE=/var/lib/kickpi-k1
		LOG=/var/log/kickpi-k1-modules.log
		say(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

		# ── 快路径：模块已在位 → 什么都不编 ──────────────────────────────
		if [ -f "$DEST/maxio.ko" ] || [ -f "$INBUILT" ]; then
			say "maxio.ko 已在位（$REL），跳过构建"
		else
			# ── 慢路径：模块缺失，才考虑现编 ────────────────────────────
			mkdir -p "$STATE"
			if [ ! -d "$KDIR" ]; then
				# 没有本内核 headers：编不了，本次不试（避免每次开机白等一遍）
				if [ ! -f "$STATE/noheaders-$REL" ]; then
					date '+%F %T' > "$STATE/noheaders-$REL"
					say "缺 maxio.ko 且缺 $KDIR（内核 headers）→ 本次不构建；装上 linux-headers-$REL 后重启即可自愈"
				fi
			else
				rm -f "$STATE/noheaders-$REL"
				say "缺 maxio.ko（$REL）但 headers 在位 → 现编补齐"
				/usr/local/sbin/kickpi-k1-build-maxio "$REL" >/dev/null 2>&1 \
					|| say "现编未成功（详见 /var/log/kickpi-k1-modules.log 与 build 输出）"
			fi
		fi

		# maxio 无外部依赖 → 绝对路径 insmod 兜底；MAC 侧有依赖 → modprobe
		if ! /sbin/modprobe -s maxio 2>>"$LOG"; then
			[ -f "$DEST/maxio.ko" ] && /sbin/insmod "$DEST/maxio.ko" 2>>"$LOG" \
				|| say "✗ maxio 不可加载（$DEST/maxio.ko 缺失或 vermagic 不符）"
		fi
		/sbin/modprobe stmmac         2>>"$LOG" || say "modprobe stmmac 失败"
		/sbin/modprobe stmmac-platform 2>>"$LOG" || say "modprobe stmmac-platform 失败"
		/sbin/modprobe dwmac-rockchip 2>>"$LOG" || say "modprobe dwmac-rockchip 失败"

		{
			echo "---- kickpi-k1 自检 $(date '+%F %T') kernel=$REL ----"
			lsmod | grep -E '^(maxio|stmmac|stmmac_platform|dwmac_rockchip)' || echo "(板级网络模块未加载)"
			dmesg 2>/dev/null | grep -E 'MAE0621A|MAXIO_PHY_VER|phy_id=0x7b744411|Link is Up' | tail -8
		} >>"$LOG" 2>&1
		exit 0
	EOF
	chmod 0755 "${SDCARD}/usr/local/sbin/kickpi-k1-load-modules"

	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/kickpi-k1-modules.service"
		[Unit]
		Description=iNextOS(KICKPI K1): load board modules (maxio PHY) with self-heal
		DefaultDependencies=no
		After=systemd-modules-load.service local-fs.target
		Before=network-pre.target
		Wants=network-pre.target
		ConditionPathExists=/usr/local/sbin/kickpi-k1-load-modules

		[Service]
		Type=oneshot
		ExecStart=/usr/local/sbin/kickpi-k1-load-modules
		TimeoutStartSec=300
		RemainAfterExit=yes

		[Install]
		WantedBy=multi-user.target
	EOF

	# ── 6/7) 顺序三重保障：softdep + modules-load.d ────────────────────
	mkdir -p "${SDCARD}/etc/modprobe.d" "${SDCARD}/etc/modules-load.d"
	cat <<- 'EOF' > "${SDCARD}/etc/modprobe.d/kickpi-k1.conf"
		# KICKPI K1：phylib 在 MAC 探测时就把 PHY 绑到当时的驱动上，
		# 晚到的 maxio 会被跳过（lyw-kf PORTING 坑④ 实测）→ MAC 驱动加载前必须先有 maxio。
		# 模块名按本仓 vendor 6.1 树实测：dwmac-rockchip.ko（非飞牛的 dwmac_rk）。
		softdep dwmac-rockchip pre: maxio
		softdep stmmac-platform pre: maxio
	EOF
	printf 'maxio\n' > "${SDCARD}/etc/modules-load.d/kickpi-k1.conf"

	for u in kickpi-k1-modules.service; do
		chroot_sdcard systemctl --no-reload enable "$u" >/dev/null 2>&1 || true
	done

	display_alert "board-module self-heal installed (source + dkms + postinst hook + boot unit + softdep)" "$EXTENSION" "info"
	return 0
}

# ══════════════════════════════════════════════════════════════════════════
# 最终态断言：确认自愈链条的每一环都真的落在镜像里（缺一环 = 在线更新后网口可能救不回）
# ══════════════════════════════════════════════════════════════════════════
function pre_umount_final_image__kickpi_k1_module_selfheal() {
	display_alert "Final-pass: verify module self-heal chain (KICKPI K1)" "$EXTENSION" "info"

	local fail=0
	for f in usr/src/kickpi-k1/maxio.c usr/src/kickpi-k1/Makefile \
	         usr/local/sbin/kickpi-k1-build-maxio usr/local/sbin/kickpi-k1-load-modules \
	         etc/kernel/postinst.d/zz-kickpi-k1-maxio \
	         etc/systemd/system/kickpi-k1-modules.service \
	         etc/modprobe.d/kickpi-k1.conf etc/modules-load.d/kickpi-k1.conf; do
		[[ -e "${SDCARD}/${f}" ]] || { display_alert "self-heal file missing: ${f}" "$EXTENSION" "err"; fail=1; }
	done
	for f in usr/local/sbin/kickpi-k1-build-maxio usr/local/sbin/kickpi-k1-load-modules etc/kernel/postinst.d/zz-kickpi-k1-maxio; do
		[[ -x "${SDCARD}/${f}" ]] || { display_alert "not executable: ${f}" "$EXTENSION" "err"; fail=1; }
	done
	grep -q 'softdep dwmac-rockchip pre: maxio' "${SDCARD}/etc/modprobe.d/kickpi-k1.conf" || \
		{ display_alert "softdep missing (PHY 可能被通用驱动抢绑)" "$EXTENSION" "err"; fail=1; }
	grep -q 'module_phy_driver' "${SDCARD}/usr/src/kickpi-k1/maxio.c" || \
		{ display_alert "extracted maxio.c looks invalid" "$EXTENSION" "err"; fail=1; }
	# 模块本体必须已经在镜像里（=m 构建产物，当前内核用）
	local any_ko
	any_ko="$(ls "${SDCARD}"/lib/modules/*/kernel/drivers/net/phy/maxio.ko 2>/dev/null | head -1 || true)"
	[[ -n "$any_ko" ]] || { display_alert "maxio.ko not found in image rootfs (MAXIO_PHY 未按 =m 构建？)" "$EXTENSION" "err"; fail=1; }
	# 顺序三重保障：wants 链接
	mkdir -p "${SDCARD}/etc/systemd/system/multi-user.target.wants"
	ln -sf /etc/systemd/system/kickpi-k1-modules.service \
		"${SDCARD}/etc/systemd/system/multi-user.target.wants/kickpi-k1-modules.service"

	[[ $fail == 0 ]] || exit_with_error "KICKPI K1 module-selfheal self-check failed"
	display_alert "module self-heal chain verified in image" "$EXTENSION" "info"
	return 0
}
