#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# KICKPI K1 板级扩展：网口角色归一（WAN=eth0 / LAN=eth1，开机自纠正）
#
# 问题（实机复现，2026-10-14）：
#   roceos 的"设置向导"按枚举顺序自动分配角色，本板两次装机都分反了：
#   eth0 被当成 LAN、eth1 被当成 WAN。用户明确要求：**ETH0 = WAN 口，eth1 = LAN 口**。
#   关键：角色真源不是 /etc/roceos/factory-env.json（那个改了没用），
#        而是 sqlite 库 /opt/roceos/data/roceos.db 的三张表：
#          network_interfaces(id,name,type,device,method,...)
#          interface_bindings(binding_name,interface_type,type,physical_nics,physical_nic_macs,...)
#          lan_configs(binding_id,nic_ids,ip_address,netmask,...)
#   手工改库 + 重启后实机生效（eth0 拿到上游 DHCP、eth1 = 192.168.100.1），
#   但重装镜像会再反一次 —— 所以本扩展把它变成"每次开机自纠正"。
#
# 本扩展做两件事：
#   1) /usr/local/sbin/kickpi-k1-net-roles.py —— 幂等纠正脚本：
#      · wan1.device=eth0、lan1.device=eth1；
#      · wan1/lan1 两个 binding 的 physical_nics 同步；physical_nic_macs 取该口
#        **当前真实 MAC**（各台机器 MAC 不同，不能写死）；
#      · lan_configs.nic_ids 同步为 ["eth1"]，其余字段（IP/掩码/DHCP）一律不动；
#      · 只在库里已有 roceos 记录时生效（全新镜像首次开机 roceos 还没建库 → 跳过）。
#   2) kickpi-k1-net-roles.service —— roceos 起之前跑一次（Before=roceos.service），
#      这样 roceos 读到的就是纠正后的配置，不需要额外重启任何服务。
#
# 不做什么：不碰 factory-env.json、不写死任何 MAC、不重启 roceos、不做周期轮询。
# ══════════════════════════════════════════════════════════════════════════

function post_post_debootstrap_tweaks__kickpi_k1_net_roles() {
	display_alert "Installing NIC role normalizer (KICKPI K1: WAN=eth0 / LAN=eth1)" "$EXTENSION" "info"

	mkdir -p "${SDCARD}/usr/local/sbin" "${SDCARD}/etc/systemd/system"

	cat <<- 'EOF' > "${SDCARD}/usr/local/sbin/kickpi-k1-net-roles.py"
		#!/usr/bin/env python3
		# KICKPI K1：把 roceos 的角色表纠正为 WAN=eth0 / LAN=eth1（幂等）。
		# 依据：实机定案 —— 角色真源是 roceos.db 三张表，不是 factory-env.json。
		import json, os, sqlite3, sys, time

		DB = "/opt/roceos/data/roceos.db"
		# 用户定义：eth0 = WAN，eth1 = LAN
		WANT = {"wan1": "eth0", "lan1": "eth1"}

		def log(msg):
		    with open("/var/log/kickpi-k1-net-roles.log", "a") as f:
		        f.write("[%s] %s\n" % (time.strftime("%F %T"), msg))

		if not os.path.exists(DB):
		    log("roceos.db 不存在，跳过（首次开机 roceos 尚未建库）")
		    sys.exit(0)

		def mac_of(dev):
		    try:
		        with open("/sys/class/net/%s/address" % dev) as f:
		            return f.read().strip()
		    except OSError:
		        return ""

		con = sqlite3.connect(DB)
		cur = con.cursor()
		fixed = []

		# ① network_interfaces.device
		for name, dev in WANT.items():
		    if not os.path.exists("/sys/class/net/" + dev):
		        log("跳过 %s→%s：接口 %s 不存在" % (name, dev, dev))
		        continue
		    for row in cur.execute("select device from network_interfaces where id=?", (name,)):
		        if row[0] != dev:
		            cur.execute("update network_interfaces set device=?, updated_at=? where id=?",
		                        (dev, time.strftime("%Y-%m-%d %H:%M:%S"), name))
		            fixed.append("network_interfaces.%s.device: %s→%s" % (name, row[0], dev))

		# ② interface_bindings.physical_nics / physical_nic_macs（MAC 取实机现值）
		for name, dev in WANT.items():
		    if not os.path.exists("/sys/class/net/" + dev):
		        continue
		    mac = mac_of(dev)
		    for row in cur.execute(
		            "select physical_nics, physical_nic_macs from interface_bindings where binding_name=?", (name,)):
		        want_nics, want_macs = json.dumps([dev]), json.dumps([mac]) if mac else row[1]
		        if row[0] != want_nics or (mac and row[1] != want_macs):
		            cur.execute("update interface_bindings set physical_nics=?, physical_nic_macs=?, updated_at=? "
		                        "where binding_name=?", (want_nics, want_macs,
		                                                 time.strftime("%Y-%m-%d %H:%M:%S"), name))
		            fixed.append("interface_bindings.%s: %s→%s" % (name, row[0], want_nics))

		# ③ lan_configs.nic_ids（经 binding_id 关联，仅同步网卡列表）
		for name, dev in WANT.items():
		    if name != "lan1" or not os.path.exists("/sys/class/net/" + dev):
		        continue
		    want = json.dumps([dev])
		    for bid, nics in cur.execute(
		            "select b.id, l.nic_ids from interface_bindings b join lan_configs l "
		            "on l.binding_id = b.id where b.binding_name=?", (name,)):
		        if nics != want:
		            cur.execute("update lan_configs set nic_ids=?, updated_at=? where binding_id=?",
		                        (want, time.strftime("%Y-%m-%d %H:%M:%S"), bid))
		            fixed.append("lan_configs.nic_ids: %s→%s" % (nics, want))

		if fixed:
		    con.commit()
		    log("已纠正 %d 项：%s" % (len(fixed), "; ".join(fixed)))
		else:
		    log("角色已正确（WAN=eth0 / LAN=eth1），无需改动")
		con.close()
		sys.exit(0)
	EOF
	chmod 0755 "${SDCARD}/usr/local/sbin/kickpi-k1-net-roles.py"

	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/kickpi-k1-net-roles.service"
		[Unit]
		Description=iNextOS(KICKPI K1): normalize roceos NIC roles (WAN=eth0 / LAN=eth1)
		DefaultDependencies=no
		After=local-fs.target
		Before=roceos.service network-pre.target
		ConditionPathExists=/usr/local/sbin/kickpi-k1-net-roles.py

		[Service]
		Type=oneshot
		ExecStart=/usr/local/sbin/kickpi-k1-net-roles.py
		RemainAfterExit=yes

		[Install]
		WantedBy=multi-user.target
	EOF

	chroot_sdcard systemctl --no-reload enable kickpi-k1-net-roles.service >/dev/null 2>&1 || true

	display_alert "NIC role normalizer installed (script + pre-roceos unit)" "$EXTENSION" "info"
	return 0
}

# ══════════════════════════════════════════════════════════════════════════
# 最终态断言：角色纠正脚本 + unit 必须在镜像里（否则装机后再反一次，用户要手工改库）
# ══════════════════════════════════════════════════════════════════════════
function pre_umount_final_image__kickpi_k1_net_roles() {
	display_alert "Final-pass: verify NIC role normalizer (KICKPI K1)" "$EXTENSION" "info"

	local fail=0
	[[ -x "${SDCARD}/usr/local/sbin/kickpi-k1-net-roles.py" ]] || {
		display_alert "角色纠正脚本缺失或不可执行" "$EXTENSION" "err"; fail=1; }
	python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" \
		"${SDCARD}/usr/local/sbin/kickpi-k1-net-roles.py" 2>/dev/null || {
		display_alert "kickpi-k1-net-roles.py 语法错误" "$EXTENSION" "err"; fail=1; }
	grep -q '/opt/roceos/data/roceos.db' "${SDCARD}/usr/local/sbin/kickpi-k1-net-roles.py" || {
		display_alert "纠正脚本没指向 roceos.db（改错地方 = 无效）" "$EXTENSION" "err"; fail=1; }
	grep -q '"eth0"' "${SDCARD}/usr/local/sbin/kickpi-k1-net-roles.py" || {
		display_alert "纠正脚本缺 eth0=WAN 规则" "$EXTENSION" "err"; fail=1; }
	[[ -f "${SDCARD}/etc/systemd/system/kickpi-k1-net-roles.service" ]] || {
		display_alert "角色纠正 unit 缺失" "$EXTENSION" "err"; fail=1; }
	grep -q 'Before=roceos.service' "${SDCARD}/etc/systemd/system/kickpi-k1-net-roles.service" || {
		display_alert "unit 未排在 roceos 之前（改了库也要等重启才生效）" "$EXTENSION" "err"; fail=1; }
	mkdir -p "${SDCARD}/etc/systemd/system/multi-user.target.wants"
	ln -sf /etc/systemd/system/kickpi-k1-net-roles.service \
		"${SDCARD}/etc/systemd/system/multi-user.target.wants/kickpi-k1-net-roles.service"

	[[ $fail == 0 ]] || exit_with_error "KICKPI K1 NIC role normalizer self-check failed"
	display_alert "NIC role normalizer verified in image" "$EXTENSION" "info"
	return 0
}
