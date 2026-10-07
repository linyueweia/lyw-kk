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
echo "── (0) 引导区内嵌 DDR 固件指纹（必须是 1560MHz 系列，且不是别板固件）──"
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
bad = [n for n in names if "1560MHz" not in n]
if bad:
    print("    ✗ 内嵌 DDR 非 1560MHz 系列:", bad); sys.exit(1)
if names:
    print("    ✓ 内嵌 DDR 为 1560MHz 系列:", names)
else:
    sys.exit(0)
PYEOF
if strings -n 8 <(dd if="$IMG" bs=512 skip=64 count=800 status=none 2>/dev/null) 2>/dev/null | grep -qiE 'ddr.*v1\.[0-9]+'; then
    DDRLINE="$(dd if="$IMG" bs=512 skip=64 count=800 status=none 2>/dev/null | strings | grep -iE 'ddr.*v1\.[0-9]+|fwver' | head -2)"
    echo "$DDRLINE" | sed 's/^/    /'
    if echo "$DDRLINE" | grep -qiE '1056MHz|f366f69a7d'; then
        bad "引导区 DDR 固件是 1056MHz / T68M 的 V1.18（本板需 1560MHz）"
    else
        ok "引导区 DDR 非 1056MHz/V1.18"
    fi
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
    for p in /mpp-srv /rkvdec@fdf80200 /rkvenc@fdf40000 /vdpu@fdea0400 \
             /vepu@fdee0000 /rk_rga@fdeb0000 /iep@fdef0000 /jpegd@fded0000 \
             /rng@fe388000 /npu@fde40000 /iommu@fdf80800 /iommu@fdf40f00; do
        st=$(fdtget -t s "$DT" "$p" status 2>/dev/null || echo MISSING)
        printf "      %-24s %s\n" "$(basename "$p")" "$st"
        [[ "$st" == "okay" ]] || dtfail=1
    done
    [[ $dtfail -eq 0 ]] && ok "SoC IP 块全部 okay" || bad "有 IP 块未使能（DTS 未生效或遗漏）"

    echo "    ── (2c) 网口 PHY 与实机 RGMII 延迟 ──"
    DTC=$(mktemp)
    if command -v dtc >/dev/null 2>&1 && dtc -I dtb -O dts -o "$DTC" "$DT" 2>/dev/null; then
        for pat in "tx_delay = <0x21>" "rx_delay = <0x3c>" "tx_delay = <0x2f>" "rx_delay = <0x39>"; do
            grep -q "$pat" "$DTC" && ok "实机值 $pat" || bad "缺实机值 $pat"
        done
        grep -qiE 'maxio|mae0621' "$DTC" && ok "网口 PHY 为 Maxio 系" || bad "未见 Maxio PHY"
        grep -q "maxio" "$DTC" 2>/dev/null
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
[[ $FAIL -eq 0 ]] && echo "✅ 后处理校验全部通过" || echo "✗ 后处理校验有未通过项"
exit $FAIL
