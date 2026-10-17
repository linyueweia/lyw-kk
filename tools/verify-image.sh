#!/usr/bin/env bash
#
# iNextOS(KICKPI K1) 产出镜像的【后处理校验】—— 移植自 lyw-OS(T68M) 的同名步骤，
# 断言按 K1 实机情况调整。
#
# 为什么需要它（血泪教训）：
#   仅"构建成功"不等于镜像可用。T68M 就曾因 DTS 只 include 了 rk3568.dtsi、
#   而视频/NPU 这些 SoC IP 块默认是 disabled，导致硬件解码/RGA/JPEG/硬转码
#   在系统里全部不可用 —— 而构建过程一声不吭。K1 首版也漏了同一批节点，
#   已补；此脚本确保以后不再漏。
#
# 用法: verify-image.sh <image.img>
set -uo pipefail

IMG="${1:?用法: verify-image.sh <image.img>}"
FAIL=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; FAIL=1; }

[[ -f "$IMG" ]] || { echo "✗ 镜像不存在: $IMG"; exit 1; }
echo "==== 镜像: $IMG ($(stat -c%s "$IMG") 字节) ===="

echo
echo "── (0) 引导区内嵌 DDR 固件指纹（必须 = K1 真机 eMMC 原厂同款 v1.23-03ea844c5d）──"
# 证据链（2026-10-12 定案，详见 build.yml DDR 段注释）：
#   K1 真机原厂 = ddr-v1.23-03ea844c5d = rkbin 的 rk3568_ddr_1056MHz_v1.23.bin；
#   框架默认 1560_v1.21 未在 K1 实测（同方案 T68M 上训练失败）；1560_v1.26 在 K1 上 SPL 即断。
#   本板原厂固件内字符串【不含】任何频率串（1056/1560MHz 均 False），所以按指纹判。
python3 - "$IMG" <<'PYEOF' || FAIL=1
import sys, pathlib
img = sys.argv[1]
with open(img, 'rb') as fh:
    fh.seek(0x8000)
    region = fh.read(0x36000 - 0x8000)
names = []
for base in ("build/cache/sources/rkbin-tools/rk35", "build/cache/sources/rkbin/rk35"):
    for f in sorted(pathlib.Path(base).glob("rk3568_ddr_*.bin")) if pathlib.Path(base).exists() else []:
        blob = f.read_bytes()
        if region.find(blob) >= 0:
            names.append(f.name)
print("    命中:", names or "（未匹配到本地 rkbin 固件，退化用字符串判断）")
good = [n for n in names if n.startswith("rk3568_ddr_1056MHz_v1.23")]
if names and not good:
    print("    ✗ 内嵌 DDR 不是真机原厂同款 rk3568_ddr_1056MHz_v1.23.bin:", names); sys.exit(1)
if good:
    print("    ✓ 内嵌 DDR = 真机 eMMC 原厂同款:", good)
else:
    sys.exit(0)
PYEOF
IDB="$(dd if="$IMG" bs=512 skip=64 count=800 status=none 2>/dev/null)"
DDRLINE="$(echo "$IDB" | strings | grep -iE 'ddr.*v1\.[0-9]+|fwver' | head -2 || true)"
echo "$DDRLINE" | sed 's/^/    /'
if echo "$DDRLINE" | grep -q '03ea844c5d'; then
    ok "引导区 DDR 指纹 = 03ea844c5d（K1 真机原厂同款）"
else
    bad "引导区 DDR 指纹不是 03ea844c5d（真机原厂 = ddr-v1.23-03ea844c5d）"
fi
if echo "$DDRLINE" | grep -qiE 'f366f69a7d|v1\.21'; then
    bad "引导区 DDR 是 T68M V1.18 或未实测的 v1.21 —— 本板启动链不通的已知风险"
fi

echo
echo "── (1) U-Boot FIT 魔数 @8MiB ──"
MAGIC=$(dd if="$IMG" bs=1 skip=$((8*1024*1024)) count=4 status=none 2>/dev/null | xxd -p)
echo "    magic = $MAGIC"
[[ "$MAGIC" == "d00dfeed" ]] && ok "8MiB 处为 FIT/FDT 魔数" || bad "8MiB 处不是 FIT 魔数（bootloader 未就位？）"

echo
echo "── (2) 挂载 boot 分区，校验 DTB 与本板内容 ──"
MNT=/mnt/ib_v
mkdir -p "$MNT"
LOOP="$(losetup -fP --show "$IMG")"
cleanup(){ mountpoint -q "$MNT" && umount "$MNT"; [[ -n "${LOOP:-}" ]] && losetup -d "$LOOP"; }
trap cleanup EXIT
sleep 1
BP=""; for c in "${LOOP}p1" "${LOOP}1"; do [[ -e "$c" ]] && BP="$c" && break; done
[[ -n "$BP" ]] || { bad "没有 boot 分区"; exit 1; }
mount "$BP" "$MNT" || { bad "挂载失败"; exit 1; }

DT="$MNT/dtb/rockchip/rk3568-kickpi-k1.dtb"
if [[ -f "$DT" ]]; then
    ok "DTB 存在于镜像: $(stat -c%s "$DT") 字节"
else
    bad "镜像里没有 dtb/rockchip/rk3568-kickpi-k1.dtb"
fi

if [[ -f "$DT" ]]; then
    echo "    ── (2b) SoC IP 块必须使能（缺则硬解/RGA/JPEG/硬转码/NPU 全废）──"
    if ! command -v fdtget >/dev/null 2>&1; then
        apt-get install -y -qq device-tree-compiler >/dev/null 2>&1 || true
    fi
    dtfail=0
    # 注意 /video-codec@fdea0400：vendor 6.1 树在同一地址上有两个节点 ——
    #   vpu:  video-codec@fdea0400  ← 真 VPU（实机实为 okay，本表要查的就是它）
    #   vdpu: vdpu@fdea0400         ← 同地址的占位节点(reg 仅 0x400)，常年 disabled
    # 曾经误查后者，导致明明 DTS 生效却报"有 IP 块未使能"。
    for p in /mpp-srv /rkvdec@fdf80200 /rkvenc@fdf40000 /video-codec@fdea0400 \
             /vepu@fdee0000 /rk_rga@fdeb0000 /iep@fdef0000 /jpegd@fded0000 \
             /rng@fe388000 /iommu@fdf80800 /iommu@fdf40f00; do
        st=$(fdtget -t s "$DT" "$p" status 2>/dev/null || echo MISSING)
        printf "      %-24s %s\n" "$(basename "$p")" "$st"
        [[ "$st" == "okay" ]] || dtfail=1
    done
    # 必须【disabled】的块 —— 与成功线 T68M 一致（其官方 DTS 注释明写 NPU 出厂即 disabled）。
    # 实机定案（commit 481bedd）：npu=okay 时 rockchip-pm-domain 向 npu 域发 idle 请求
    # 等不到 ack（failed to get ack on domain 'npu', val=0x1ee）→ vendor 内核
    # panic_on_set_idle 直接 Kernel panic（实机跑到 15.93s 挂）。软路由/NAS 场景不用 NPU。
    # 反向断言的意义：将来有人"顺手把 NPU 打开"，这里会立刻拦住，而不是让它上板再炸。
    # 2026-10-14 起镜像内已带 \`rockchip-pm-domain-ack-warn.patch\`（把 pm_domains.c 的
    # `panic("panic_on_set_idle/set_domain")` 降级为 WARN_ONCE）：要真正打开 NPU，需
    #   ① 确认该补丁在新内核构建里生效（CI 日志能看到 patch 应用行）；
    #   ② 把本处期望值由 disabled 改为 okay；
    #   ③ 真机（串口在手）验证不再 panic 后再合并 —— 顺序不能颠倒。
    for p in /npu@fde40000; do
        st=$(fdtget -t s "$DT" "$p" status 2>/dev/null || echo MISSING)
        printf "      %-24s %s（期望 disabled：开了会 panic）\n" "$(basename "$p")" "$st"
        [[ "$st" == "disabled" ]] || dtfail=1
    done
    [[ $dtfail -eq 0 ]] && ok "SoC IP 块状态全部符合预期（该开的都 okay，NPU 按实机定案保持 disabled）" \
                        || bad "SoC IP 块状态不符（该开未开，或 NPU 被意外打开）"

    echo "    ── (2c) 网口 PHY 与实机 RGMII 延迟 ──"
    DTC=$(mktemp)
    if command -v dtc >/dev/null 2>&1 && dtc -I dtb -O dts -o "$DTC" "$DT" 2>/dev/null; then
        for pat in "tx_delay = <0x21>" "rx_delay = <0x3c>" "tx_delay = <0x2f>" "rx_delay = <0x39>"; do
            grep -q "$pat" "$DTC" && ok "实机值 $pat" || bad "缺实机值 $pat"
        done
        # PHY 说明：本板 PHY 是 Maxio MAE0621A，但 DT 里【不会】出现 "maxio" 字样 ——
        # 实测实机 DT 两处 PHY 均为 compatible = "ethernet-phy-ieee802.3-c22"（通用 C22），
        # Maxio 驱动是按运行时读到的 PHY ID 匹配的。所以这里该查两件事：
        #   (a) 两个 PHY 节点确实存在（C22）
        #   (b) 内核配置里板级网络驱动是【模块 =m】（双千兆命门，且是在线更新自愈的前提）
        nphy=$(grep -c 'ethernet-phy-ieee802.3-c22' "$DTC" 2>/dev/null || echo 0)
        [[ "${nphy:-0}" -ge 2 ]] && ok "DT 里 PHY 节点 $nphy 个（通用 C22，实机即如此）" \
                                 || bad "DT 里 PHY 节点不足（找到 ${nphy:-0} 个，本板应为 2）"
        # PHY 复位脚门禁（2026-10-14 实机定案）：第二口曾因这一行写错控制器/引脚而整口不可用 ——
        # PHY 被按在复位里 → 其 MDIO 地址 0/1/2 全无应答 → "Cannot attach to PHY (error: -19)"。
        # 期望值与"双口可用的飞牛线 DTB"逐属性对照一致：
        #   ethernet@fe2a0000 → /pinctrl/gpio@fe750000(gpio2) pin 27
        #   ethernet@fe010000 → /pinctrl/gpio@fe760000(gpio3) pin 7
        for spec in "/ethernet@fe2a0000 fe750000 27" "/ethernet@fe010000 fe760000 7"; do
            set -- $spec; node="$1"; ctrl="$2"; want="$3"
            rv="$(fdtget -t x "$DT" "$node" snps,reset-gpio 2>/dev/null || true)"
            if [[ -z "$rv" ]]; then
                bad "$node 缺 snps,reset-gpio（第二口 PHY 不会复位 → 整口不可用）"; continue
            fi
            ph=$((16#$(echo "$rv" | cut -d' ' -f1)))
            pin=$((16#$(echo "$rv" | cut -d' ' -f2)))
            got="$(fdtget -t x "$DT" "/pinctrl/gpio@$ctrl" phandle 2>/dev/null || true)"
            if [[ -n "$got" && "$((16#$got))" == "$ph" && "$pin" == "$want" ]]; then
                ok "$(basename "$node") reset-gpio → gpio@$ctrl pin $pin（实机定案值，第二口可用）"
            else
                bad "$(basename "$node") reset-gpio 控制器 phandle=$(printf '0x%x' "$ph") pin=$pin \
—— 期望 gpio@$ctrl pin $want（写错则该口 PHY 永不复位、整口不可用）"
            fi
        done

        KCFG="$(ls "$MNT"/config-* 2>/dev/null | head -1 || true)"
        if [[ -n "$KCFG" ]]; then
            # 为什么是 =m 而不是 =y：内建驱动在"在线更新换了内核"时无法补救（不能装载/重建）；
            # 模块化才有 DKMS + postinst 钩子 + 开机自愈这条链（见 extensions/kickpi-k1-module-selfheal.sh）。
            # 为什么连 MAC 侧也要 =m：phylib 在 MAC 探测时就绑 PHY，内建 MAC 会先抢绑通用驱动，
            # 晚到的 maxio 被跳过（lyw-kf PORTING 坑④ 实测）。
            if grep -qE '^CONFIG_MAXIO_PHY=m' "$KCFG"; then
                ok "内核配置 CONFIG_MAXIO_PHY=m（双千兆命门 + 可自愈）"
            else
                bad "内核配置不是 CONFIG_MAXIO_PHY=m —— 内建/未开都会让在线更新后无法恢复网口"
            fi
            for sym in STMMAC_ETH STMMAC_PLATFORM DWMAC_ROCKCHIP; do
                grep -qE "^CONFIG_${sym}=m" "$KCFG" && ok "CONFIG_${sym}=m（PHY 绑定时序可控）" \
                    || bad "CONFIG_${sym} 不是 =m（内建 MAC 会抢绑 PHY，maxio 自愈失效）"
            done
            grep -E '^CONFIG_(MAXIO_PHY|STMMAC_ETH|STMMAC_PLATFORM|DWMAC_ROCKCHIP|PHYLIB|PCS_XPCS)=' "$KCFG" | sed 's/^/       /' || true
        else
            echo "    · boot 分区未见 config-*（跳过内核配置检查）"
        fi
    else
        bad "dtc 不可用或无法反解 DTB"
    fi
    rm -f "$DTC"
fi

echo "    ── (3) 引导配置指向本板 DTB ──"
for f in "$MNT/armbianEnv.txt" "$MNT/extlinux/extlinux.conf" "$MNT/fnEnv.txt"; do
    [[ -f "$f" ]] || continue
    grep -q 'rk3568-kickpi-k1.dtb' "$f" && ok "$(basename "$f") 指向本板 DTB" || echo "    · $(basename "$f") 未提及本板 DTB"
done
if [[ -f "$MNT/boot.scr" ]]; then
    strings "$MNT/boot.scr" 2>/dev/null | grep -q 'kickpi-k1.dtb' && ok "boot.scr 含本板 DTB" || echo "    · boot.scr 未含本板 DTB 名（由 armbianEnv 提供亦可）"
fi

echo
echo "── (4) 挂载 rootfs，校验板级网络驱动自愈链（在线更新后网口能不能回来就靠这条链）──"
# 为什么要在镜像里断言这条链：本板双千兆靠自建 Maxio PHY 驱动，一旦它在在线更新换内核后丢失，
# 两个网口同时失联 = 设备变砖（只能拔卡）。链上任一环缺失，都会让"更新后自动恢复网口"变成空话，
# 所以这里逐件断言（方案与实证见 extensions/kickpi-k1-module-selfheal.sh 头部注释）。
RMNT=/mnt/ib_r
mkdir -p "$RMNT"
RP=""; for c in "${LOOP}p2" "${LOOP}2"; do [[ -e "$c" ]] && RP="$c" && break; done
if [[ -z "$RP" ]]; then
    bad "没有 rootfs 分区（p2）—— 无法校验自愈链"
else
    if mount -o ro "$RP" "$RMNT" 2>/dev/null; then
        for f in usr/src/kickpi-k1/maxio.c usr/src/kickpi-k1/Makefile \
                 usr/local/sbin/kickpi-k1-build-maxio usr/local/sbin/kickpi-k1-load-modules \
                 etc/kernel/postinst.d/zz-kickpi-k1-maxio \
                 etc/systemd/system/kickpi-k1-modules.service \
                 etc/modprobe.d/kickpi-k1.conf etc/modules-load.d/kickpi-k1.conf \
                 usr/local/sbin/k1-net-health etc/systemd/system/k1-update-check.service \
                 usr/local/sbin/k1-boot-guard etc/systemd/system/k1-boot-guard.service; do
            [[ -e "$RMNT/$f" ]] && ok "自愈/自检件在位: $f" || bad "缺件: $f"
        done
        grep -q 'module_phy_driver' "$RMNT/usr/src/kickpi-k1/maxio.c" 2>/dev/null \
            && ok "树外源码 maxio.c 有效（含 module_phy_driver）" \
            || bad "maxio.c 内容异常（补丁提取失败？）"
        grep -q 'softdep dwmac-rockchip pre: maxio' "$RMNT/etc/modprobe.d/kickpi-k1.conf" 2>/dev/null \
            && ok "softdep 已保证 maxio 先于 MAC 驱动注册" \
            || bad "缺 softdep（PHY 会被通用驱动抢绑，自愈失效）"
        KO="$(ls "$RMNT"/lib/modules/*/kernel/drivers/net/phy/maxio.ko 2>/dev/null | head -1 || true)"
        [[ -n "$KO" ]] && ok "maxio.ko 已随镜像安装（$(basename "$(dirname "$(dirname "$KO")")") 内核）" \
                       || bad "镜像里没有 maxio.ko（=m 构建产物缺失，当前内核网口起不来）"
        if ls "$RMNT"/usr/src/linux-headers-* >/dev/null 2>&1 || ls -d "$RMNT"/lib/modules/*/build >/dev/null 2>&1; then
            ok "内核 headers 随镜像安装（离线也能现编 maxio）"
        else
            echo "    · 镜像未装内核 headers（可选件）：换内核后由 postinst 钩子自动 apt 拉 linux-headers-\$rel；"
            echo "      本仓自己的内核包/内核升级包本身就带 maxio.ko，因此不装也不影响网口恢复"
        fi
        [[ -d "$RMNT/var/lib/dkms/maxio" ]] && ok "DKMS 已注册 maxio（将来新内核自动重编）" \
            || echo "    · DKMS 未注册（仍有 postinst 钩子 + 开机自愈兜底）"
        # EEE 按 inextos 官方默认保持开启：镜像里不得有任何 EEE 关闭件（2026-10-17 改判）
        for f in usr/local/sbin/kickpi-k1-eee-off.sh etc/systemd/system/kickpi-k1-eee-off.service \
                 etc/NetworkManager/dispatcher.d/90-kickpi-k1-eee-off etc/network/if-up.d/zz-kickpi-k1-eee-off \
                 etc/systemd/system/kickpi-k1-eee-off-watch.timer; do
            [[ -e "$RMNT/$f" ]] && bad "仍有 EEE 关闭件: $f（与官方默认不一致）" || ok "无 $f"
        done
        [[ -L "$RMNT/etc/systemd/system/multi-user.target.wants/kickpi-k1-eee-off.service" ]] \
            && bad "EEE 关闭服务仍被 enable" || ok "EEE 关闭服务未 enable"
        [[ -L "$RMNT/etc/systemd/system/multi-user.target.wants/kickpi-k1-modules.service" ]] 2>/dev/null \
            && ok "开机自愈单元已 enable" \
            || bad "kickpi-k1-modules.service 未 enable（重启不加载板级模块）"
        # EEE 第 4/5 层（2026-10-14 实机复现：只挂 NM dispatcher 时，roceos 走 ifupdown-ng
        # 重配网络后 EEE 会回来 → 端口每 15~20 秒 Up/Down 抖动）
        [[ -x "$RMNT/etc/network/if-up.d/zz-kickpi-k1-eee-off" ]] \
            && ok "ifupdown-ng 钩子在位（roceos 重配网络后重关 EEE）" \
            || bad "缺 ifupdown-ng 钩子（重配网络后 EEE 复发）"
        [[ -f "$RMNT/etc/systemd/system/kickpi-k1-eee-off-watch.timer" ]] \
            && ok "EEE 周期兜底 timer 在位" || bad "缺 kickpi-k1-eee-off-watch.timer"
        # NVMe 自愈链（实机定案：pcie30 PHY init 早于模拟供电就绪 → 冷启动可能不上盘）
        [[ -x "$RMNT/usr/local/sbin/kickpi-k1-nvme-selfheal.sh" ]] \
            && ok "NVMe 自愈脚本在位" || bad "缺 kickpi-k1-nvme-selfheal.sh"
        grep -q 'rk-pcie/unbind' "$RMNT/usr/local/sbin/kickpi-k1-nvme-selfheal.sh" 2>/dev/null \
            && ok "NVMe 自愈脚本含 rk-pcie 重绑定" || bad "NVMe 自愈脚本内容不对"
        [[ -f "$RMNT/etc/systemd/system/kickpi-k1-nvme-selfheal.service" ]] \
            && ok "NVMe 自愈单元已装" || bad "缺 kickpi-k1-nvme-selfheal.service"
        [[ -L "$RMNT/etc/systemd/system/multi-user.target.wants/kickpi-k1-nvme-selfheal.service" ]] \
            && ok "NVMe 自愈单元已 enable" || bad "NVMe 自愈单元未 enable"
        [[ -L "$RMNT/etc/systemd/system/multi-user.target.wants/kickpi-k1-net-roles.service" ]] \
            && ok "网口角色归一单元已 enable" || bad "网口角色归一单元未 enable"
        # 网口角色归一（用户定义 WAN=eth0 / LAN=eth1）
        [[ -x "$RMNT/usr/local/sbin/kickpi-k1-net-roles.py" ]] \
            && ok "网口角色归一脚本在位" || bad "缺 kickpi-k1-net-roles.py"
        grep -q '/opt/roceos/data/roceos.db' "$RMNT/usr/local/sbin/kickpi-k1-net-roles.py" 2>/dev/null \
            && ok "角色真源指向 roceos.db（不是 factory-env.json）" \
            || bad "角色脚本改错地方（factory-env.json 无效）"
        # 反面断言：不许出现"钉死内核"的痕迹（本板设计是更新后自愈，不是禁止更新）
        if grep -rqs 'linux-image-vendor-rk35xx' "$RMNT/etc/apt/preferences.d/" 2>/dev/null; then
            bad "镜像里出现内核 apt pin（与设计相悖：内核不钉死）"
        else
            ok "无内核 pin（在线更新不受阻）"
        fi
        umount "$RMNT" 2>/dev/null || true
    else
        bad "rootfs 分区挂载失败"
    fi
fi

echo
[[ $FAIL -eq 0 ]] && echo "✅ 后处理校验全部通过" || echo "✗ 后处理校验有未通过项"
exit $FAIL
