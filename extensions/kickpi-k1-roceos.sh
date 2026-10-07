#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# KICKPI K1 板级扩展：装入 roceos 网页后台 + AIC8800 WiFi 固件
#
# 为什么用扩展 + post_post_debootstrap_tweaks 这个早期钩子：
#   官方 istorenext 扩展就是在这一阶段用
#       chroot_sdcard systemctl --no-reload enable <unit>
#   启用它自己的服务的。实测（构建 #37404316629）在 customize-image.sh 阶段
#   用 `ln -sf` 建 multi-user.target.wants 链接，钩子内自检通过、但最终镜像里
#   链接消失（被后续流程清掉），导致构建自证失败。改用官方同款阶段后链接可留存。
#
# 装的东西（与官方 Easepi-r1 镜像逐项一致；K1 版不含 AIC8800 固件 —— 本板用 SWT6621S，
#   其固件已由本仓库 overlay（firmware/SWT6621S_*）单独投递）：
#   /opt/roceos、/opt/roceos-ai、roceos{,-ai,-vision}.service（并启用）、
#   nginx 站点+证书（移除 default 站点）、Flask 栈、AIC8800 SDIO 固件
# ══════════════════════════════════════════════════════════════════════════

# 载荷 sha256（与 release roceos-payload-v1 一致；内容一变就报错）
ROCEOS_PAYLOAD_SHA256="6b819584a1b1701163f8983bd59a31821643f64dd65c76ba8f500ef54c5e8bb5"

function post_post_debootstrap_tweaks__kickpi_k1_roceos() {
	display_alert "Installing roceos web UI (KICKPI K1)" "$EXTENSION" "info"

	local payload="${USERPATCHES_PATH}/overlay/roceos-payload.tar.gz"
	[[ -f "$payload" ]] || exit_with_error "roceos payload not found: ${payload}"
	# 指纹固定断言：不留"以为改了其实没改"的余地
	echo "${ROCEOS_PAYLOAD_SHA256}  ${payload}" | sha256sum -c - || exit_with_error "roceos payload sha256 mismatch"

	local stage
	stage="$(mktemp -d)"
	tar xzf "$payload" -C "$stage"
	for f in opt/roceos/roceos opt/roceos/www/index.html opt/roceos-ai/server.py \
		etc/systemd/system/roceos.service etc/nginx/sites-available/roceos.conf \
		etc/nginx/ssl/roceos.key; do
		[[ -e "${stage}/${f}" ]] || exit_with_error "payload missing ${f}"
	done

	# ── 应用本体 ────────────────────────────────────────────────
	mkdir -p "${SDCARD}/opt" "${SDCARD}/storage"
	rm -rf "${SDCARD}/opt/roceos" "${SDCARD}/opt/roceos-ai"
	cp -a "${stage}/opt/roceos" "${stage}/opt/roceos-ai" "${SDCARD}/opt/"
	mkdir -p "${SDCARD}/opt/roceos/data" "${SDCARD}/opt/roceos/logs"
	chmod +x "${SDCARD}/opt/roceos/roceos" "${SDCARD}/opt/roceos/roceos-vision" 2>/dev/null || true
	for b in "${SDCARD}"/opt/roceos/bin/*; do [[ -e "$b" ]] && chmod +x "$b"; done
	chown -R root:root "${SDCARD}/opt/roceos" "${SDCARD}/opt/roceos-ai" "${SDCARD}/storage"

	# ── systemd 服务 ───────────────────────────────────────────
	# 官方 unit 没有 [Install] 段（所以 systemctl enable 无从建立 wants 链接）；
	# 这里补上（幂等），配合下面的直接建链接双保险。
	for s in roceos.service roceos-ai.service roceos-vision.service; do
		cp -a "${stage}/etc/systemd/system/${s}" "${SDCARD}/etc/systemd/system/"
		if ! grep -q '^\[Install\]' "${SDCARD}/etc/systemd/system/${s}"; then
			printf '\n[Install]\nWantedBy=multi-user.target\n' >> "${SDCARD}/etc/systemd/system/${s}"
		fi
	done

	# ── nginx 站点与证书（default 站点必须移除：它与 roceos.conf 抢 default_server）──
	mkdir -p "${SDCARD}/etc/nginx/ssl" "${SDCARD}/etc/nginx/sites-available" "${SDCARD}/etc/nginx/sites-enabled"
	cp -a "${stage}/etc/nginx/ssl/roceos.crt" "${stage}/etc/nginx/ssl/roceos.key" "${SDCARD}/etc/nginx/ssl/"
	cp -a "${stage}/etc/nginx/sites-available/roceos.conf" "${SDCARD}/etc/nginx/sites-available/"
	ln -sf /etc/nginx/sites-available/roceos.conf "${SDCARD}/etc/nginx/sites-enabled/roceos.conf"
	rm -f "${SDCARD}/etc/nginx/sites-enabled/default"

	# ── Flask 栈（roceos-ai 用）：apt 优先，失败回退载荷内文件 ────
	chroot_sdcard apt-get install -y -qq python3-flask python3-werkzeug python3-jinja2 \
		python3-itsdangerous python3-markupsafe python3-blinker || true
	# 注意：框架的 chroot_sdcard 以 "$*" 拼串后交给 bash -c，引号会被吃掉，
	# 因此必须把「整条命令」作为一个参数传入（否则 python 只收到 -c import → SyntaxError）。
	local flask_test="python3 -c 'import flask, werkzeug, jinja2, itsdangerous, markupsafe, blinker'"
	local flask_out
	if ! flask_out=$(chroot_sdcard "$flask_test" 2>&1); then
		display_alert "Flask stack not importable (apt had no DNS): ${flask_out##*$'\n'}" "$EXTENSION" "warn"
		# 回退：整体拷入载荷的 dist-packages（实测仅 4.3MB，含 flask/werkzeug/jinja2/
		# itsdangerous/markupsafe/blinker 及其元数据）。不做挑选，避免漏掉 metadata
		# 导致 importlib.metadata.version() 查不到包（曾被 CI 校验抓到）。
		mkdir -p "${SDCARD}/usr/lib/python3/dist-packages"
		cp -a "${stage}/usr/lib/python3/dist-packages/." "${SDCARD}/usr/lib/python3/dist-packages/"
		# 兜底拷贝后必须复验，否则"以为装好了其实没有"
		flask_out=$(chroot_sdcard "$flask_test" 2>&1) || \
			exit_with_error "Flask stack still not importable after payload fallback: ${flask_out##*$'\n'}"
		display_alert "Flask stack OK after payload fallback" "$EXTENSION" "info"
	fi

	rm -rf "$stage"

	# ── 启用服务 ──────────────────────────────────────────────
	# 不用 chroot_sdcard systemctl enable：实测（构建 37423507035）在构建容器里
	# 它不会在镜像内生成 multi-user.target.wants 链接——自证因此失败。直接建链接可靠。
	mkdir -p "${SDCARD}/etc/systemd/system/multi-user.target.wants"
	for s in roceos.service roceos-ai.service roceos-vision.service; do
		ln -sf "/etc/systemd/system/${s}" "${SDCARD}/etc/systemd/system/multi-user.target.wants/${s}"
	done

	# ── 防"更新流程删固件"：apt 禁止清单 + 同名空壳包 ──────────────
	# 实机定位（2026-10）：roceos 的"系统更新/安装依赖"会去装发行版固件包，而
	# armbian-firmware 的 control 里 Provides 且 Conflicts 了其中一部分 —— apt 为
	# 满足冲突会把 armbian-firmware 整个卸载，连带删掉它管理的 /lib/firmware/aic8800
	#（WiFi 固件）等文件；且该包不在任何 apt 源里（随镜像首启安装后即删），装不回来。
	# 两道防护：
	#   ① apt pin -1：禁止安装与 armbian-firmware 互斥的那几个包（内容已由它提供）；
	#   ② 其余更新流程会请求的固件包，装"同名空壳包"（不含文件，仅让依赖检查成立）。
	mkdir -p "${SDCARD}/etc/apt/preferences.d" "${SDCARD}/tmp"
	cat >"${SDCARD}/etc/apt/preferences.d/10-inextos-firmware-conflict" <<-'EOF'
	# 与 armbian-firmware 互斥（armbian-firmware 已 Provides 其全部内容）。
	# 若被安装，apt 会为满足冲突而卸载 armbian-firmware，连带删除 WiFi/网卡固件。
	Package: linux-firmware firmware-brcm80211 firmware-ralink firmware-samsung firmware-realtek armbian-firmware-full
	Pin: version *
	Pin-Priority: -1
	EOF

	local name ver sdir
	for name in firmware-atheros firmware-ath9k-htc firmware-carl9170 firmware-iwlwifi \
		firmware-libertas firmware-mediatek firmware-misc-nonfree firmware-sof-signed \
		firmware-ti-connectivity; do
		case "$name" in
			firmware-ath9k-htc) ver="1.4.0-110-ge888634+dfsg1-0.1" ;;
			firmware-carl9170)  ver="1.9.9-450-gad1c721+dfsg-0.1" ;;
			firmware-sof-signed) ver="2025.01-1" ;;
			*)                   ver="20250410-2" ;;
		esac
		sdir="$(mktemp -d)/${name}"
		mkdir -p "${sdir}/DEBIAN"
		cat >"${sdir}/DEBIAN/control" <<-EOF
		Package: ${name}
		Version: ${ver}+inextos1
		Architecture: all
		Section: kernel
		Priority: optional
		Maintainer: iNextOS KICKPI K1 <root@localhost>
		Description: Compatibility stub for ${name}
		 Firmware content is provided by armbian-firmware. This stub only
		 satisfies dependency checks from the vendor update flow so that
		 installing it cannot remove armbian-firmware or its firmware files.
		EOF
		dpkg-deb -b "${sdir}" "${SDCARD}/tmp/stub-${name}.deb" >/dev/null
		chroot_sdcard dpkg -i "/tmp/stub-${name}.deb" >/dev/null 2>&1 || \
			display_alert "firmware stub ${name} install failed (non-fatal)" "$EXTENSION" "warn"
		rm -rf "$(dirname "$sdir")"
	done
	rm -f "${SDCARD}"/tmp/stub-*.deb

	# ── 消掉 ttyFIQ0 报错 ──────────────────────────────────────
	# 框架启用了 serial-getty@ttyFIQ0，而本板无该串口（rk3568 FIQ debugger 未接），
	# 启动时会 "Timed out waiting for device dev-ttyFIQ0.device" 且 getty 反复重启。
	# 直接建 mask 链接（等价 systemctl mask，不依赖 chroot 里跑 systemd）。
	ln -sf /dev/null "${SDCARD}/etc/systemd/system/serial-getty@ttyFIQ0.service"

	# ── 阶段内自证 ────────────────────────────────────────────
	local fail=0
	# 清单与 TF 卡逐项一致（卡上存在什么，这里就断言什么）
	for f in opt/roceos/roceos opt/roceos/www/index.html \
		opt/roceos-ai/server.py opt/roceos-ai/librkllmrt.so \
		etc/systemd/system/roceos.service \
		etc/nginx/sites-available/roceos.conf etc/nginx/ssl/roceos.crt etc/nginx/ssl/roceos.key; do
		[[ -e "${SDCARD}/${f}" ]] || { display_alert "missing ${f}" "$EXTENSION" "err"; fail=1; }
	done
	# 三个启用链接必须用 -L 判定：它们是符号链接，链接目标 /etc/systemd/system/*.service
	# 是【镜像内】绝对路径，宿主机上不存在，用 -e 会跟随链接而误判为缺失。
	for f in roceos.service roceos-ai.service roceos-vision.service; do
		[[ -L "${SDCARD}/etc/systemd/system/multi-user.target.wants/${f}" ]] || \
			{ display_alert "missing wants link ${f}" "$EXTENSION" "err"; fail=1; }
	done
	[[ -L "${SDCARD}/etc/nginx/sites-enabled/roceos.conf" ]] || { display_alert "nginx site not enabled" "$EXTENSION" "err"; fail=1; }
	# ── 更新防护与 ttyFIQ0 自证 ──
	[[ -f "${SDCARD}/etc/apt/preferences.d/10-inextos-firmware-conflict" ]] || { display_alert "apt pin file missing" "$EXTENSION" "err"; fail=1; }
	grep -q '^Pin-Priority: -1' "${SDCARD}/etc/apt/preferences.d/10-inextos-firmware-conflict" || { display_alert "apt pin priority wrong" "$EXTENSION" "err"; fail=1; }
	grep -q '^Package: firmware-atheros$' "${SDCARD}/var/lib/dpkg/status" || { display_alert "firmware stub firmware-atheros not installed" "$EXTENSION" "err"; fail=1; }
	grep -q '^Package: firmware-iwlwifi$' "${SDCARD}/var/lib/dpkg/status" || { display_alert "firmware stub firmware-iwlwifi not installed" "$EXTENSION" "err"; fail=1; }
	[[ -L "${SDCARD}/etc/systemd/system/serial-getty@ttyFIQ0.service" ]] || { display_alert "ttyFIQ0 getty not masked" "$EXTENSION" "err"; fail=1; }
	[[ -e "${SDCARD}/etc/nginx/sites-enabled/default" ]] && { display_alert "default site still present" "$EXTENSION" "err"; fail=1; }
	[[ $fail == 0 ]] || exit_with_error "KICKPI K1 roceos customization self-check failed"

	display_alert "roceos web UI installed and enabled (KICKPI K1)" "$EXTENSION" "info"
	return 0
}

# ══════════════════════════════════════════════════════════════════════════
# 晚钩子：框架在 post_post_debootstrap_tweaks 之后还会做"启用串口控制台"等收尾动作，
# 会把 serial-getty@ttyFIQ0 重新启用；且卡的最终态就是「mask + 框架的 getty.target.wants 链接」，
# 使本板（无 ttyFIQ0 串口）在启动时 "Timed out waiting for device dev-ttyFIQ0.device"。
# 因此在 rootfs 仍挂载、框架收尾之后的 pre_umount_final_image 再施加一次屏蔽。
# ══════════════════════════════════════════════════════════════════════════
function pre_umount_final_image__kickpi_k1_roceos() {
	display_alert "Final-pass: masking ttyFIQ0 getty (KICKPI K1)" "$EXTENSION" "info"

	# 与 TF 卡（已验收完美）完全一致：只建立 mask，指向 /dev/null。
	# 框架建的 getty.target.wants/serial-getty@ttyFIQ0.service 在卡上【是存在的】，
	# 不动它 —— mask 的存在即足以让该 getty 无法启动（systemd 对 masked 单元拒绝启动）。
	mkdir -p "${SDCARD}/etc/systemd/system"
	ln -sf /dev/null "${SDCARD}/etc/systemd/system/serial-getty@ttyFIQ0.service"

	# 最终态断言：mask 必须是符号链接且指向 /dev/null
	[[ -L "${SDCARD}/etc/systemd/system/serial-getty@ttyFIQ0.service" ]] || \
		exit_with_error "ttyFIQ0 mask missing after final pass"
	[[ "$(readlink "${SDCARD}/etc/systemd/system/serial-getty@ttyFIQ0.service")" == "/dev/null" ]] || \
		exit_with_error "ttyFIQ0 mask does not point to /dev/null"
	return 0
}
