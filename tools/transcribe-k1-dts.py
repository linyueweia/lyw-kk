#!/usr/bin/env python3
"""从实机 DT 转写 KICKPI K1 板级 DTS。

思路：
  - 实机 DT 是"展开"过的完整树，包含 SoC 内部节点和全部板级信息。
  - 板级 DTS 的正确形态 = #include "rk3568.dtsi" + 板级根节点 + 对 SoC 节点的覆写。
  - 因此：根节点(/xxx)全量转写；SoC 节点(/xxx@addr)只保留"板级属性"白名单。
  - 所有 phandle 数字还原为 &{/路径} 或标准标签(&gpio3/&cru/pinctrl)。

用法: transcribe-k1-dts.py <live.dts> <out.dts>
"""
import re, sys, pathlib, collections

SRC = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/work/kk/kickpi-k1a-live.dts')
OUT = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else '/work/kk/k1-transcribed.dts')

lines = SRC.read_text(errors='replace').splitlines()

# ---------- 1) 解析节点树 ----------
NODESTART = re.compile(r'^(\s*)(?:([A-Za-z0-9_,.+\-]+):\s*)?([A-Za-z0-9_,.+\-@]+)\s*\{$')
PROP = re.compile(r'^(\s*)([A-Za-z0-9_,.+\-#]+)\s*=\s*(.+);\s*$')

nodes = collections.OrderedDict()   # path -> {'props': [(name, value)], 'children': [path]}
order = []
stack = []
ph2path = {}

for ln in lines:
    m = NODESTART.match(ln)
    if m:
        name = m.group(3) or m.group(2)
        stack.append(name)
        p = '/' + '/'.join([s for s in stack if s])
        if p not in nodes:
            nodes[p] = {'props': [], 'children': [], 'raw': []}
            order.append(p)
        if len(stack) > 1:
            parent = '/' + '/'.join([s for s in stack[:-1] if s])
            if p not in nodes[parent]['children']:
                nodes[parent]['children'].append(p)
        continue
    if ln.strip() == '};':
        if stack:
            p = '/' + '/'.join([s for s in stack if s])
            stack.pop()
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

# 补一遍全量 phandle 预扫描（主循环只记录已建节点时的 phandle，可能漏掉深层节点）
_stack, _cur = [], None
for ln in lines:
    _m = re.match(r'^(\s*)([A-Za-z0-9_,.+\-@]+)\s*([A-Za-z0-9_,.+\-@]*)\s*\{$', ln)
    if _m:
        _nm = _m.group(3) or _m.group(2)
        _stack.append(_nm)
        _cur = "/" + "/".join([s for s in _stack if s])
        continue
    if ln.strip() == '};':
        if _stack: _stack.pop()
        _cur = "/" + "/".join([s for s in _stack if s]) if _stack else "/"
        continue
    _mm = re.match(r'^\s*(?:linux,)?phandle = <0x([0-9a-fA-F]+)>;', ln)
    if _mm and _cur:
        ph2path.setdefault(int(_mm.group(1), 16), _cur)

print("节点总数: %d" % len(order))
print("phandle 映射: %d" % len(ph2path))

# ---------- 2) 标签映射 ----------
# 实机 DT 的节点路径 -> 6.1 厂商树的标签
LABEL_BY_PATH = {
    '/ethernet@fe2a0000': 'gmac0',       # eth1
    '/ethernet@fe010000': 'gmac1',       # eth0
    '/sdhci@fe310000': 'sdhci',
    '/dwmmc@fe2b0000': 'sdmmc0',
    '/dwmmc@fe2c0000': 'sdmmc1',
    '/dwmmc@fe000000': 'sdmmc2',
    '/usbdrd': 'usbdrd30',
    '/usbhost': 'usbhost30',
    '/pcie@fe260000': 'pcie2x1',
    '/pcie@fe270000': 'pcie3x1',
    '/pcie@fe280000': 'pcie3x2',
    '/sata@fc000000': 'sata0',
    '/sata@fc400000': 'sata1',
    '/sata@fc800000': 'sata2',
    '/hdmi@fe0a0000': 'hdmi',
    '/vop@fe040000': 'vop',
    '/saradc@fe720000': 'saradc',
    '/tsadc@fe530000': 'tsadc',
    '/serial@fe660000': 'uart2',
    '/i2c@fdd40000': 'i2c0',
    '/i2c@fe5a0000': 'i2c1',
    '/i2c@fe5b0000': 'i2c2',
    '/i2c@fe5c0000': 'i2c3',
    '/i2c@fe5d0000': 'i2c4',
    '/i2c@fe5e0000': 'i2c5',
    '/pinctrl': 'pinctrl',
    '/syscon@fdc20000': 'pmugrf',
    '/syscon@fdc60000': 'grf',
    '/clock-controller@fdd00000': 'cru',
    '/clock-controller@fdd20000': 'pmucru',
    '/phy@fe820000': 'combphy0_us',
    '/phy@fe830000': 'combphy1_usq',
    '/phy@fe840000': 'combphy2_psq',
    '/phy@fe8c0000': 'pcie30phy',
    '/usb2-phy@fe8a0000': 'usb2phy0',
    '/usb2-phy@fe8b0000': 'usb2phy1',
}
for gp, n in (('fdd60000', 'gpio0'), ('fe740000', 'gpio1'), ('fe750000', 'gpio2'),
              ('fe760000', 'gpio3'), ('fe770000', 'gpio4')):
    LABEL_BY_PATH['/pinctrl/gpio%s@%s' % (n[-1], gp)] = n

def label_for(path):
    if path in LABEL_BY_PATH:
        return '&' + LABEL_BY_PATH[path]
    # 板级节点：用节点名，'-' 换成 '_'
    name = path.split('/')[-1]
    name = re.sub(r'@.*$', '', name)
    return '&' + name.replace('-', '_')

# 只有这些属性里的 <0xNN> 才可能是 phandle（避免 tx_delay=<0x21> 被误当引用）
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

def resolve(name, val, keep_angle=True):
    if not PH_PROP.search(name):
        return val          # 纯数字/字符串属性，原样保留
    def rep(m):
        n = int(m.group(1), 16)
        p = ph2path.get(n)
        if p:
            return ('<&{%s}>' % p) if keep_angle else ('&{%s}' % p)
        return ('<0x%x>' % n)
    return re.sub(r'<0x([0-9a-fA-F]+)>', rep, val)

# ---------- 3) 属性白名单（SoC 节点只保留板级覆写） ----------
# 只保留"板级覆写"属性；compatible/reg/clocks/interrupts/resets 等一律交给 6.1 的 dtsi，
# 硬搬 5.10 的编号会覆盖错 6.1 的值（这是转写最容易踩的坑）。
KEEP_EXACT = {
    'status', 'pinctrl-names', 'pinctrl-0', 'pinctrl-1', 'pinctrl-2', 'pinctrl-3',
    'phy-handle', 'phy-mode', 'phy-supply', 'clock_in_out', 'tx_delay', 'rx_delay',
    'num-lanes', 'dr_mode', 'maximum-speed', 'mmc-pwrseq', 'non-removable',
    'disable-wp', 'keep-power-in-suspend', 'cap-sdio-irq', 'wakeup-source',
    'reset-gpios', 'snps,reset-gpio', 'snps,reset-active-low', 'snps,reset-delays-us',
    'assigned-clocks', 'assigned-clock-parents', 'assigned-clock-rates',
    'vmmc-supply', 'vqmmc-supply', 'vpcie3v3-supply', 'vpcie1v8-supply',
    'vpcie0v9-supply', 'io-domains', 'rockchip,grf', 'rockchip,pmu',
    'remote-endpoint', 'data-lanes', 'wakeup-source', 'gpio', 'gpios',
}
KEEP_RE = re.compile(r'(-supply$|^cap-|^no-|^sd-uhs|^disable-|^regulator-|^rockchip,camera-|^enable-active|^vin-|^pwms?$|^bus-width$|^max-frequency$)')

SOCR_PREFIX = re.compile(r'^/(cpus|pmu|sram|syscon|clock-controller|power-controller|opp-table|otp|qos|mailbox|rng|iommu|mmu|display-subsystem|mipi|dsi|isp|rga|jpeg|vpu|vepu|vdpu|rkvdec|rkvenc|iep|npu|gpu|crypto|dmac|dma|watchdog|timer|pwm|spi|can|i2s|spdif|acodec|pdm|vad|usb2-phy|usbdrd3?$|usbhost3?$|combphy|pcie|nandc|sfc|sdmmc|sdhci|ethernet|emmc|debug|chosen|aliases|memory|reserved-memory)')

def is_board_root(path):
    """板级根节点：/ 的直接子节点，且不是 SoC 外设节点"""
    if path.count('/') != 1:
        return False
    name = path[1:]
    # SoC 外设（带 @地址）通常不是板级节点，但也有例外（如 vcc 稳压器无地址）
    if '@' in name:
        return False
    return True

# ---------- 4) 生成 ----------
out = []
out.append('// SPDX-License-Identifier: GPL-2.0-or-later OR MIT')
out.append('// 本文件由实机 DT 机械转写生成（transcribe-k1-dts.py）')
out.append('// 数据来源：KICKPI K1 V1.2 运行中系统的 /sys/firmware/fdt')
out.append('// 说明：以实机为准，社区 j3ffs/Kickpi-K1 的条目已废弃。')
out.append('')
out.append('/dts-v1/;')
out.append('#include <dt-bindings/gpio/gpio.h>')
out.append('#include <dt-bindings/input/input.h>')
out.append('#include <dt-bindings/leds/common.h>')
out.append('#include <dt-bindings/pinctrl/rockchip.h>')
out.append('#include <dt-bindings/soc/rockchip,vop2.h>')
out.append('#include "rk3568.dtsi"')
out.append('')
out.append('/ {')
out.append('\tmodel = "KICKPI K1";')
out.append('\tcompatible = "kickpi,k1", "rockchip,rk3568";')
out.append('')

board_roots = [p for p in order if is_board_root(p) and not p.startswith('/memory')]
# 无 @地址但属于外设 glue 的 SoC 节点（实机里就是这个形态）
SOC_NO_ADDR = {'/usbdrd', '/usbhost', '/usbdrd_dwc3', '/usbhost_dwc3',
               '/pinctrl', '/dfi', '/display-subsystem'}
soc_nodes = [p for p in order
             if (re.match(r'^/[a-z0-9_.+-]+@[0-9a-f]+$', p) and not p.startswith('/memory'))
             or p in SOC_NO_ADDR]
# 总线挂载的板级器件：父节点是"带 reg 的外设节点"（i2c/mmc/ethernet/spi 等），
# 本节点自己有 compatible（= 真实器件，如 RK809/TCS4525/HYM8563/GC5035）
bus_children = {}
for p in order:
    parent = p.rsplit('/', 1)[0]
    if not parent or parent == '' or parent not in nodes:
        continue
    if not any(n == 'compatible' for n, _ in nodes[p]['props']):
        continue
    # 父节点必须是 SoC 外设总线（有 reg，且不是根）
    pprops = [n for n, _ in nodes[parent]['props']]
    if 'reg' in pprops and parent != '/':
        bus_children.setdefault(parent, []).append(p)

print("板级根节点: %d 个" % len(board_roots))
print("SoC 节点(带地址): %d 个" % len(soc_nodes))

# 4a) 板级根节点全量转写
out.append('\t/* ===== 板级节点（实机全量转写） ===== */')
for p in board_roots:
    nd = nodes[p]
    if not nd['props']:
        continue
    kids = [c for c in nd['children'] if nodes[c]['props']]
    if not nd['props'] and not kids:
        continue
    label = p[1:].replace('-', '_')
    out.append('\t%s: %s {' % (label, p[1:]))
    for name, val in nd['props']:
        if name in ('phandle', 'linux,phandle') or name == 'reg':
            continue
        out.append('\t\t%s = %s;' % (name, resolve(name, val)))
    for c in kids:
        cname = c.split('/')[-1]
        out.append('\t\t%s {' % cname)
        for name, val in nodes[c]['props']:
            if name in ('phandle', 'linux,phandle') or name == 'reg':
                continue
            out.append('\t\t\t%s = %s;' % (name, resolve(name, val)))
        out.append('\t\t};')
    out.append('\t};')
out.append('};')
out.append('')

# 4b) SoC 节点覆写
out.append('/* ===== SoC 节点覆写（只保留板级相关属性） ===== */')
for p in soc_nodes:
    nd = nodes[p]
    picked = []
    for name, val in nd['props']:
        if name in ('phandle', 'linux,phandle'):
            continue
        if name in KEEP_EXACT or KEEP_RE.search(name):
            picked.append((name, val))
    if not picked:
        continue
    out.append('%s {' % label_for(p))
    for name, val in picked:
        out.append('\t%s = %s;' % (name, resolve(name, val)))
    # 该总线下挂的板级器件（RK809 / TCS4525 / HYM8563 / GC5035 等）
    for c in bus_children.get(p, []):
        cname = c.rsplit('/', 1)[1]
        out.append('\t%s {' % cname)
        for name, val in nodes[c]['props']:
            if name in ('phandle', 'linux,phandle'):
                continue
            out.append('\t\t%s = %s;' % (name, resolve(name, val)))
        out.append('\t};')
    out.append('};')
    out.append('')

text = '\n'.join(out)

# ---------- 5) 后处理：残留裸 phandle 的 pinctrl 引用 -> 6.1 标签名 ----------
_root_stack, _root_cur = [], None
_name_by_ph = {}
for ln in lines:
    _m = re.match(r'^(\s*)([A-Za-z0-9_,.+\-@]+):?\s*([A-Za-z0-9_,.+\-@]*)\s*\{$', ln)
    if _m:
        _nm = _m.group(3) or _m.group(2)
        _root_stack.append(_nm)
        _root_cur = "/".join([s for s in _root_stack if s])
        continue
    if ln.strip() == '};':
        if _root_stack: _root_stack.pop()
        continue
    _mm = re.match(r'^\s*phandle = <0x([0-9a-fA-F]+)>;', ln)
    if _mm and _root_cur:
        _name_by_ph[int(_mm.group(1), 16)] = _root_cur.split('/')[-1].replace('-', '_')

def _fix_pinctrl(m):
    prop, body = m.group(1), m.group(2)
    toks = []
    for t in body.split():
        if t.startswith('0x'):
            nm = _name_by_ph.get(int(t, 16))
            toks.append('&' + nm if nm else t)
        else:
            toks.append(t)
    return '%s = <%s>' % (prop, ' '.join(toks))

text, _nfix = re.subn(r'(pinctrl-[0-9]+) = <([0-9a-fx ]+)>', _fix_pinctrl, text)
print("pinctrl 标签化: %d 处" % _nfix)

OUT.write_text(text)
print("✅ 已生成 %s（%d 行, %d 字节）" % (OUT, len(text.splitlines()), OUT.stat().st_size))
