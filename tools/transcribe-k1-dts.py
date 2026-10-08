#!/usr/bin/env python3
"""从实机 DT 转写 KICKPI K1 板级 DTS（结构化版 v2）。

设计要点（每一条都是构建实测踩出来的）：
 1. 根节点(/xxx)按板级清单 emit；SoC 节点(/xxx@addr)只 emit "板级覆写"白名单属性。
 2. 【不加标签】：引用统一用路径 &{/path}；加标签会与 6.1 dtsi 的同名标签冲突
    （实测 /cpu0-opp-table 的 cpu0_opp_table 撞 /opp-table-0）。
 3. 【递归 emit 子节点】：6.1 的 dtsi 自己会引用
    /i2c@fdd40000/pmic@20/regulators/DCDC_REG1 与 gmac 的 mdio/phy@0，
    所以第二层（regulators/DCDC_*/mdio/phy）必须一并转写。
 4. 【稳压器打标签】：dtsi 引用 <&vdd_logic>，板级需按 regulator-name 打出
    vdd_logic / vdd_gpu 等标签。
 5. pinctrl 引用一律走路径，并【同时 emit 组定义】（板级独有的组如 pmic_int
    在 6.1 树里不存在）。
 6. 只保留 pinctrl-0；pinctrl-1..3 引用板级睡眠引脚组(&soc_slppin_*/&rk817_slppin_*)
    在 6.1 树里不存在。
 7. 不得重复定义 SoC 内部根节点(opp-table/arm-pmu/chosen/thermal-zones...)。
"""
import re, sys, pathlib, collections

SRC = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/work/kk/kickpi-k1a-live.dts')
OUT = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else '/work/kk/k1-transcribed.dts')
lines = SRC.read_text(errors='replace').splitlines()

NODESTART = re.compile(r'^(\s*)(?:([A-Za-z0-9_,.+\-]+):\s*)?([A-Za-z0-9_,.+\-@]+)\s*\{$')
PROP = re.compile(r'^(\s*)([A-Za-z0-9_,.+\-#]+)\s*=\s*(.+);\s*$')

# ── 1) 解析 ──
order, nodes, ph2path = [], collections.OrderedDict(), {}
stack = []
for ln in lines:
    m = NODESTART.match(ln)
    if m:
        nm = m.group(3) or m.group(2)
        stack.append(nm)
        p = '/' + '/'.join([s for s in stack if s])
        if p not in nodes:
            nodes[p] = {'props': [], 'children': []}
            order.append(p)
        if len(stack) > 1:
            par = '/' + '/'.join([s for s in stack[:-1] if s])
            if p not in nodes[par]['children']:
                nodes[par]['children'].append(p)
        continue
    if ln.strip() == '};':
        if stack:
            p = '/' + '/'.join([s for s in stack if s]); stack.pop()
        continue
    p = '/' + '/'.join([s for s in stack if s]) if stack else None
    if p and p in nodes:
        pm = PROP.match(ln)
        if pm:
            nodes[p]['props'].append((pm.group(2), pm.group(3).strip()))
            if pm.group(2) in ('phandle', 'linux,phandle'):
                v = re.match(r'<0x([0-9a-fA-F]+)>', pm.group(3).strip())
                if v:
                    ph2path[int(v.group(1), 16)] = p

# ── 2) 标签映射（已确认存在于 6.1 树）──
LABEL_BY_PATH = {
    '/ethernet@fe2a0000': 'gmac0', '/ethernet@fe010000': 'gmac1',
    '/sdhci@fe310000': 'sdhci', '/dwmmc@fe2b0000': 'sdmmc0',
    '/dwmmc@fe2c0000': 'sdmmc1', '/dwmmc@fe000000': 'sdmmc2',
    '/usbdrd': 'usbdrd30', '/usbhost': 'usbhost30',
    '/usb@fd800000': 'usb_host0_ehci', '/usb@fd840000': 'usb_host0_ohci',
    '/usb@fd880000': 'usb_host1_ehci', '/usb@fd8c0000': 'usb_host1_ohci',
    '/usbdrd/usbdrd_dwc3': 'usbdrd_dwc3', '/usbhost/usbhost_dwc3': 'usbhost_dwc3',
    '/pcie@fe260000': 'pcie2x1', '/pcie@fe270000': 'pcie3x1', '/pcie@fe280000': 'pcie3x2',
    '/sata@fc000000': 'sata0', '/sata@fc400000': 'sata1', '/sata@fc800000': 'sata2',
    '/hdmi@fe0a0000': 'hdmi', '/vop@fe040000': 'vop',
    '/saradc@fe720000': 'saradc', '/tsadc@fe530000': 'tsadc',
    '/serial@fe660000': 'uart2', '/i2c@fdd40000': 'i2c0',
    '/i2c@fe5a0000': 'i2c1', '/i2c@fe5b0000': 'i2c2', '/i2c@fe5c0000': 'i2c3',
    '/i2c@fe5d0000': 'i2c4', '/i2c@fe5e0000': 'i2c5',
    '/pinctrl': 'pinctrl', '/syscon@fdc20000': 'pmugrf', '/syscon@fdc60000': 'grf',
    '/clock-controller@fdd00000': 'cru', '/clock-controller@fdd20000': 'pmucru',
    '/phy@fe820000': 'combphy0_us', '/phy@fe830000': 'combphy1_usq',
    '/phy@fe840000': 'combphy2_psq', '/phy@fe8c0000': 'pcie30phy',
    '/usb2-phy@fe8a0000': 'usb2phy0', '/usb2-phy@fe8b0000': 'usb2phy1',
    '/spdif@fe460000': 'spdif_8ch',
    # ── 视频/图像/NPU 集群（此前整批遗漏，导致镜像里硬解/NPU/硬转码全废）──
    # 标签名按 armbian/linux-rockchip rk-6.1-rkr5.1 的 rk356x.dtsi 实测：
    # 注意实机节点名与主线不同（实机 video-codec@fdea0400 → 主线标签 vpu），靠地址配对
    '/video-codec@fdea0400': 'vpu', '/vdpu@fdea0400': 'vpu',
    '/rk_rga@fdeb0000': 'rk_rga', '/rkv_rga@fdeb0000': 'rk_rga',
    '/jpegd@fded0000': 'jpegd', '/vepu@fdee0000': 'vepu',
    '/iep@fdef0000': 'iep', '/rkvenc@fdf40000': 'rkvenc',
    '/rkvdec@fdf80200': 'rkvdec', '/npu@fde40000': 'rknpu',
    '/iommu@fde4b000': 'rknpu_mmu', '/iommu@fdea0800': 'vdpu_mmu',
    '/iommu@fdf40f00': 'rkvenc_mmu', '/iommu@fdf80800': 'rkvdec_mmu',
    '/iommu@fdee0800': 'vepu_mmu', '/iommu@fdef0800': 'iep_mmu',
    '/iommu@fded0480': 'jpegd_mmu', '/iommu@fe043e00': 'vop_mmu',
    '/rkvdec-sram@0': 'rkvdec_sram',
    '/nand-controller@fe330000': 'nandc', '/spi@fe610000': 'spi0',
    '/spi@fe620000': 'spi1', '/spi@fe630000': 'spi2', '/spi@fe640000': 'spi3',
    '/sfc@fe300000': 'sfc', '/pwm@fe6e0000': 'pwm4', '/pwm@fe6f0000': 'pwm5',
    '/pwm@fdd70000': 'pwm0', '/pwm@fdd70010': 'pwm1',
    '/pwm@fdd70020': 'pwm2', '/pwm@fdd70030': 'pwm3',
    '/serial@fdd50000': 'uart0', '/serial@fe650000': 'uart1',
    '/serial@fe670000': 'uart3', '/serial@fe680000': 'uart4', '/serial@fe690000': 'uart5',
    '/serial@fe6a0000': 'uart6', '/serial@fe6b0000': 'uart7',
    '/serial@fe6c0000': 'uart8', '/serial@fe6d0000': 'uart9',
    '/i2s@fe410000': 'i2s0_8ch', '/i2s@fe420000': 'i2s1_8ch', '/i2s@fe430000': 'i2s2_2ch',
    '/pdm@fe440000': 'pdm', '/vad@fe450000': 'vad',
    '/dmac@fe550000': 'dmac0', '/dmac@ff100000': 'dmac1',
    # 实机(5.10)的 dmac 在 fe530000，6.1 树在 fe550000 —— 地址不同，必须走标签引用
    '/dmac@fe530000': 'dmac0', '/dmac@fe540000': 'dmac1',
    '/rng@fe388000': 'rng', '/crypto@fe380000': 'crypto',
    '/watchdog@fe600000': 'wdt', '/timer@fe5f0000': 'timer',
    '/can@fe570000': 'can0', '/can@fe580000': 'can1', '/can@fe590000': 'can2',
}
for gp, n in (('fdd60000', 'gpio0'), ('fe740000', 'gpio1'), ('fe750000', 'gpio2'),
              ('fe760000', 'gpio3'), ('fe770000', 'gpio4')):
    LABEL_BY_PATH['/pinctrl/gpio%s@%s' % (n[-1], gp)] = n

# ── 3) 稳压器标签（预扫描，供引用使用）──
REG_LABEL = {}
for p, nd in nodes.items():
    for n, v in nd['props']:
        if n == 'regulator-name':
            lbl = v.strip().strip('"').replace('-', '_')
            if re.match(r'^[a-zA-Z_][a-zA-Z0-9_]*$', lbl):
                REG_LABEL[p] = lbl

def label_for(path):
    if path in LABEL_BY_PATH:
        return '&' + LABEL_BY_PATH[path]
    if path in REG_LABEL:
        return '&' + REG_LABEL[path]
    return '&{%s}' % path

PH_PROP = re.compile(
    r'(^|,)('
    r'clocks|assigned-clocks|assigned-clock-parents|assigned-clock-rates|resets|phys|phys-names|'
    r'pinctrl-[0-9]+|io-channels|io-channel-names|power-domains|dmas|dma-names|memory-region|'
    r'rockchip,grf|rockchip,pmu|rockchip,usbgrf|rockchip,php-grf|rockchip,pipe-grf|rockchip,vo-grf|'
    r'rockchip,vo1-grf|rockchip,sgrf|rockchip,usb-grf|rockchip,vpu-grf|rockchip,vdec-grf|'
    r'rockchip,venc-grf|rockchip,vi-grf|rockchip,isp-grf|rockchip,mipi-grf|rockchip,dsi-grf|'
    r'rockchip,hwp-grf|rockchip,cpu-grf|rockchip,pipephy-grf|rockchip,usbphp-grf|rockchip,pmugrf|'
    r'[a-z0-9-]*-supply|[a-z0-9-]*-gpios?|gpio|gpios|phy-handle|mmc-pwrseq|remote-endpoint|'
    r'operating-points-v2|nvmem-cells|mboxes|interrupt-parent|iommus|rockchip,io-domains|io-domains'
    r')$')

# provider 类节点（只有引用这些才可能是 phandle；避免把时钟 ID 等数字误当 phandle）
PROVIDER_PATH = re.compile(
    r'^/(clock-controller|syscon|power-controller|pinctrl|phy@|usb2-phy|combphy|pcie3|'
    r'saradc|tsadc|npu@|gpu@|dmc|dfi|iommu|rkvdec|rkvenc|rkv|vop|hdmi|mipi|dsi|isp|rga|jpeg|'
    r'vpu|iep|vdpu|vepu|usbdrd|usbhost|sdhci|dwmmc|ethernet|i2c@|sfc|nand-controller)')
# 板级自带节点（固定时钟/稳压器等）同样是合法 provider，必须纳入，
# 否则它们的引用会以裸数字残留（实测 clocks = <0x02 0x02> 就是引用板级固定时钟）
def _is_provider(p):
    # 本质判定：声明了 #xxx-cells 的节点就是 provider（gpio/clock/phy/power-domain/... 皆如此）
    nd = nodes.get(p)
    if not nd:
        return False
    if PROVIDER_PATH.match(p):
        return True
    for n, _ in nd['props']:
        if re.match(r'^#.*-cells$', n):
            return True
    return False

PROVIDER_PH = {n for n, p in ph2path.items() if _is_provider(p)}


def resolve(name, val):
    """token 级解析 <...> 组：只有 token 确实是 provider 节点的 phandle 才替换成引用。
    注意旧实现用 <0xNN> 正则，多 cell 属性(clocks/phys/resets 等)因数字后是空格而完全漏解析，
    导致裸数字被内核当 phandle 误解 —— 必须按 token 处理。"""
    if not PH_PROP.search(name):
        return val

    def fix_group(gm):
        toks = gm.group(1).split()
        out = []
        for t in toks:
            m = re.match(r'^0x([0-9a-fA-F]+)$', t)
            if m:
                nn = int(m.group(1), 16)
                if nn in PROVIDER_PH:
                    out.append(label_for(ph2path[nn]))
                    continue
            out.append(t)
        return '<%s>' % ' '.join(out)

    return re.sub(r'<([^<>]*)>', fix_group, val)

KEEP_EXACT = {
    'status', 'pinctrl-names', 'pinctrl-0',
    'phy-handle', 'phy-mode', 'phy-supply', 'clock_in_out', 'tx_delay', 'rx_delay',
    'num-lanes', 'dr_mode', 'maximum-speed', 'mmc-pwrseq', 'non-removable',
    'disable-wp', 'keep-power-in-suspend', 'cap-sdio-irq', 'wakeup-source',
    'reset-gpios', 'snps,reset-gpio', 'snps,reset-active-low', 'snps,reset-delays-us',
    'assigned-clocks', 'assigned-clock-parents', 'assigned-clock-rates',
    'vmmc-supply', 'vqmmc-supply', 'vpcie3v3-supply', 'vpcie1v8-supply',
    'vpcie0v9-supply', 'io-domains', 'rockchip,grf', 'rockchip,pmu',
    'remote-endpoint', 'data-lanes', 'gpio', 'gpios',
}
KEEP_RE = re.compile(r'(-supply$|^cap-|^no-|^sd-uhs|^disable-|^regulator-|^rockchip,camera-|^enable-active|^vin-|^bus-width$|^max-frequency$|^clock-frequency$|^#clock-cells$)')
SKIP_PROPS = {'phandle', 'linux,phandle', 'pinctrl-1', 'pinctrl-2', 'pinctrl-3'}
# SoC 覆写时丢弃这些属性：它们引用 SoC 内部 provider，6.1 的 dtsi 已有正确取值，
# 而实机是 5.10 树，时钟/复位编号可能不同，硬搬会污染 6.1（实测过 clocks cell 非 phandle 的告警）
SOC_SKIP_PROPS = {'clocks', 'clock-names', 'assigned-clocks', 'assigned-clock-parents',
                  'assigned-clock-rates', 'resets', 'reset-names', 'phys', 'phy-names',
                  'power-domains', 'iommus', 'io-channels', 'interrupt-parent',
                  'nvmem-cells', 'dmas', 'dma-names', 'mboxes', 'operating-points-v2'}

SOC_INTERNAL_ROOTS = {
    'memory', 'reserved-memory', 'chosen', 'cpus', 'pmu', 'psci', 'timer',
    'arm-pmu', 'cpu0-opp-table', 'cpu1-opp-table', 'cpu2-opp-table', 'cpu3-opp-table',
    'opp-table', 'opp-table-0', 'opp-table-1', 'opp-table-2', 'opp-table-3',
    'firmware', 'thermal-zones', 'scmi-shmem',
    # USB3 glue 节点由专门的 glue 逻辑输出，避免重复定义
    'usbdrd', 'usbhost',
}

BOARD_COMPAT = re.compile(
    r'(regulator-fixed|gpio-leds|gpio-keys|adc-keys|gpio-fan|pwm-fan|pwm-backlight|'
    r'fixed-clock|mmc-pwrseq|gpio-connector|hdmi-connector|simple-audio-card|gpio-ir|'
    r'gpio-keys-polled|gpio-poweroff|gpio-restart|leds-gpio|regulator-gpio|wifi-|bluetooth|'
    # 以下板级必需，但 compatible 不是"板级驱动"风格，必须显式保留：
    r'rockchip,rk3568-pinctrl|wlan-platdata|multicodecs-card|dummy-codec|'
    r'rockchip,fiq-debugger|rockchip,display-subsystem)')


def is_board_root(path):
    """板级根节点：/ 的直接子节点，且不是 SoC 内部节点。
    带 compatible 的必须是板级驱动；不带 compatible 的视为容器(aliases/leds/sound 等)。
    这样 /bus-npu /dmc /firmware 这类 SoC 内部节点不会被当板级节点重复定义。"""
    if path.count('/') != 1 or '@' in path[1:]:
        return False
    if path[1:] in SOC_INTERNAL_ROOTS:
        return False
    nd = nodes.get(path)
    if not nd:
        return False
    comp = [v for n, v in nd['props'] if n == 'compatible']
    if not comp:
        return True          # 纯容器
    return bool(BOARD_COMPAT.search(comp[0]))

# ── 4) 递归 emit ──
PINCTRL_GROUPS = {}   # path -> None，收集需要转写的 pinctrl 组

def emit_node(path, indent, mode):
    """mode: 'full' 板级节点全量；'soc' 只保留板级属性"""
    name = path.rsplit('/', 1)[1]
    nd = nodes[path]
    if mode == 'soc':
        props = [(n, v) for n, v in nd['props']
                 if n not in SKIP_PROPS and n not in SOC_SKIP_PROPS
                 and (n in KEEP_EXACT or KEEP_RE.search(n))]
        if any(n == 'pinctrl-0' for n, _ in props):
            props = [(n, '"default"' if n == 'pinctrl-names' else v) for n, v in props]
        elif any(n == 'pinctrl-names' for n, _ in props):
            props = [(n, v) for n, v in props if n != 'pinctrl-names']
    else:
        props = [(n, v) for n, v in nd['props'] if n not in SKIP_PROPS]

    if not props and not nd['children']:
        return
    lbl = (REG_LABEL[path] + ': ') if path in REG_LABEL else ''
    out.append('%s%s%s {' % (indent, lbl, name))
    for n, v in props:
        out.append('%s\t%s = %s;' % (indent, n, resolve(n, v)))
    for ch in nd['children']:
        # 记录 pinctrl 组定义（6.1 树可能没有，需一并转写）
        # 排除 gpio 控制器本身（它是 /pinctrl/gpioN@addr，不是"组"，误收会导致双层嵌套）
        if ch.startswith('/pinctrl/') and not re.search(r'/pinctrl/gpio[0-9]@', ch):
            PINCTRL_GROUPS[ch] = None
        emit_node(ch, indent + '\t', mode)
    out.append('%s};' % indent)

out = []
out += [
    '// SPDX-License-Identifier: GPL-2.0-or-later OR MIT',
    '// 由实机 DT 机械转写生成（tools/transcribe-k1-dts.py）',
    '// 数据来源：KICKPI K1 V1.2 运行中系统的 /sys/firmware/fdt',
    '// 说明：以实机为准；社区 j3ffs/Kickpi-K1 条目已废弃。',
    '',
    '/dts-v1/;',
    '#include <dt-bindings/gpio/gpio.h>',
    '#include <dt-bindings/input/input.h>',
    '#include <dt-bindings/leds/common.h>',
    '#include <dt-bindings/pinctrl/rockchip.h>',
    '#include <dt-bindings/soc/rockchip,vop2.h>',
    '#include "rk3568.dtsi"',
    '',
    '/ {',
    # 身份对齐官方 6.1 SDK（rk3568-kickpi-k1.dtsi），kickpi,k1 保留为次级 compatible
    '\tmodel = "Rockchip RK3568 KICKPI K1 Board";',
    '\tcompatible = "rockchip,rk3568-kickpi-k1", "kickpi,k1", "rockchip,rk3568";',
    '',
    '\t/* ===== 板级节点（实机全量转写） ===== */',
]

board_roots = [p for p in order if is_board_root(p)]
# 先扫一遍确定哪些 pinctrl 组被引用
refd = set(re.findall(r'&\{(/pinctrl/[^}]+)\}', SRC.read_text(errors='replace')))
for p in board_roots:
    emit_node(p, '\t', 'full')
out.append('};')
out.append('')

# ── 5) pinctrl 组定义（板级独有、6.1 树没有的）──
pin_defs = []
for gp in sorted(PINCTRL_GROUPS):
    nd = nodes.get(gp)
    if not nd or not nd['props']:
        continue
    pin_defs.append('\t\t%s {' % gp.rsplit('/', 1)[1])
    for n, v in nd['props']:
        if n in SKIP_PROPS:
            continue
        pin_defs.append('\t\t\t%s = %s;' % (n, resolve(n, v)))
    pin_defs.append('\t\t};')
if pin_defs:
    out.append('&pinctrl {')
    out.append(pin_defs[0].lstrip('\t') if False else '')
    out[-1] = '\t/* 板级独有 pinctrl 组（6.1 树未定义，随本文件转写） */'
    # 按所属组分层输出
    cur = None
    for gp in sorted(PINCTRL_GROUPS):
        nd = nodes.get(gp)
        if not nd or not nd['props']:
            continue
        grp = gp.split('/')[2]
        if grp != cur:
            if cur is not None:
                out.append('\t};')
            out.append('\t%s {' % grp)
            cur = grp
        out.append('\t\t%s {' % gp.rsplit('/', 1)[1])
        for n, v in nd['props']:
            if n in SKIP_PROPS:
                continue
            out.append('\t\t\t%s = %s;' % (n, resolve(n, v)))
        out.append('\t\t};')
    if cur is not None:
        out.append('\t};')
    out.append('};')
    out.append('')

# ── 6) SoC 节点覆写 ──
out.append('/* ===== SoC 节点覆写（只保留板级相关属性） ===== */')
soc_nodes = [p for p in order
             if re.match(r'^/[a-z0-9_.+-]+@[0-9a-f]+$', p)
             and not p.startswith('/memory') and not p.startswith('/pinctrl/')]
for p in soc_nodes:
    if p not in LABEL_BY_PATH:
        continue
    before = len(out)
    out.append('%s {' % label_for(p))
    nd = nodes[p]
    props = [(n, v) for n, v in nd['props']
             if n not in SKIP_PROPS and n not in SOC_SKIP_PROPS
             and (n in KEEP_EXACT or KEEP_RE.search(n))]
    if any(n == 'pinctrl-0' for n, _ in props):
        props = [(n, '"default"' if n == 'pinctrl-names' else v) for n, v in props]
    if not props:
        del out[before]
        continue
    for n, v in props:
        out.append('\t%s = %s;' % (n, resolve(n, v)))
    # 总线子器件（RK809/TCS4525/RTC/摄像头/mdio+phy 等，递归）
    kids = [c for c in nd['children']
            if (any(x == 'compatible' for x, _ in nodes[c]['props']) or nodes[c]['children'])
            and not c.startswith('/pinctrl')]
    for c in kids:
        emit_node(c, '\t', 'full')
    out.append('};')
    out.append('')

# 无 @ 地址的 SoC 节点：同样需要板级覆写（缺了 mpp-srv，/dev/mpp_service 不存在，
# 硬件转码全线不可用；这才是 T68M 踩过的同一个坑）
NOLABEL_SOC = {'/mpp-srv': 'mpp_srv', '/bus-npu': 'bus_npu'}
for p, lbl in NOLABEL_SOC.items():
    if p not in nodes:
        continue
    nd = nodes[p]
    props = [(n, v) for n, v in nd['props']
             if n not in SKIP_PROPS and n not in SOC_SKIP_PROPS
             and (n in KEEP_EXACT or KEEP_RE or n == 'status')]
    if not props:
        continue
    out.append('&%s {' % lbl)
    for n, v in props:
        out.append('\t%s = %s;' % (n, resolve(n, v)))
    out.append('};')
    out.append('')

# 非 @地址的 glue 节点（usbdrd/usbhost）
for p in ('/usbdrd', '/usbhost'):
    if p not in nodes:
        continue
    nd = nodes[p]
    kids = [c for c in nd['children'] if any(x == 'compatible' for x, _ in nodes[c]['props'])]
    if not kids:
        continue
    out.append('%s {' % label_for(p))
    out.append('\tstatus = "okay";')
    GLUE_KEEP = {'dr_mode', 'phys', 'phy-names', 'maximum-speed', 'status'}
    for c in kids:
        cnd = nodes[c]
        cprops = [(n, v) for n, v in cnd['props'] if n in GLUE_KEEP]
        if not cprops:
            continue
        out.append('\t%s {' % c.rsplit('/', 1)[1])
        for n, v in cprops:
            out.append('\t\t%s = %s;' % (n, resolve(n, v)))
        out.append('\t};')
    out.append('};')
    out.append('')

OUT.write_text('\n'.join(out))
print('板级根节点: %d | SoC 覆写: %d | pinctrl 组: %d' % (
    len(board_roots), sum(1 for l in out if re.match(r'^&[a-z0-9_]+ \{$', l)),
    len(PINCTRL_GROUPS)))
print('✅ %s（%d 行, %d 字节）' % (OUT, len(out), OUT.stat().st_size))
