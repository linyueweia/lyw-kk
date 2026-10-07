#!/usr/bin/env python3
"""把 SWT6621S 驱动生成成可应用于 6.1 厂商树的内核补丁。

方法（与 Maxio PHY 补丁相同）：
  1. 取厂商 6.1 树里要被修改的两个文件（Kconfig / Makefile）的真实内容
  2. 在临时目录里装配"打补丁后"的版本
  3. diff 生成补丁
  4. dry-run 验证
"""
import pathlib, re, shutil, subprocess, sys, os

W = pathlib.Path('/work/kk')
DRV = W / 'wifi-swt6621s/main'
TREE = W / 'wifitree'
STAGE = W / 'wifi-stage'

BR = 'rk-6.1-rkr5.1'
BASE = 'https://raw.githubusercontent.com/armbian/linux-rockchip/' + BR

# 目标位置：所有驱动文件放到 drivers/net/wireless/seekwave/
DEST = 'drivers/net/wireless/seekwave'

if TREE.exists():
    shutil.rmtree(TREE)
TREE.mkdir(parents=True)

def fetch(rel):
    out = TREE / rel
    out.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(['curl', '-sL', '-m', '60', '-o', str(out), BASE + '/' + rel],
                       capture_output=True, text=True)
    if not out.exists() or out.stat().st_size == 0:
        sys.exit('拉取失败: ' + rel)
    return out.read_text(errors='replace')

print('1) 取厂商树里要改的两个文件')
wk = fetch('drivers/net/wireless/Kconfig')
wm = fetch('drivers/net/wireless/Makefile')
print('   Kconfig %d 字节, Makefile %d 字节' % (len(wk), len(wm)))

# ── 2) 装配阶段目录 ──
if STAGE.exists():
    shutil.rmtree(STAGE)
STAGE.mkdir(parents=True)

def copy_tree(src, dst):
    for p in pathlib.Path(src).rglob('*'):
        if '.git' in p.parts:
            continue
        rel = p.relative_to(src)
        t = pathlib.Path(dst) / rel
        if p.is_dir():
            t.mkdir(parents=True, exist_ok=True)
        else:
            t.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, t)

print('2) 复制驱动源码到 %s' % DEST)
copy_tree(DRV / 'drivers', STAGE / DEST / 'drivers')
copy_tree(DRV / 'include', STAGE / DEST / 'include')
# 顶层 Makefile（dkms 用），改成 in-tree 形态
(STAGE / DEST / 'Makefile').write_text(
    'skw_extra_flags := -I$(src)/include/linux -I$(src)/include/linux/platform_data\n'
    'export skw_extra_flags\n\n'
    'obj-$(CONFIG_SEEKWAVE_BSP_DRIVERS) += drivers/\n')

# ── 3) 修 Kconfig 里的路径（原为 drivers/misc/...，改为我们的位置） ──
for kf in (STAGE / DEST).rglob('Kconfig'):
    s = kf.read_text(errors='replace')
    s2 = s.replace('drivers/misc/seekwaveplatform_lite', DEST + '/drivers/seekwaveplatform_lite')
    if s != s2:
        kf.write_text(s2)
        print('   修路径: %s' % kf.relative_to(STAGE))

# 在 DEST 顶层放一个 Kconfig，供 wireless/Kconfig source 进来
(STAGE / DEST / 'Kconfig').write_text('''# SPDX-License-Identifier: GPL-2.0
# Seekwave SWT6621S (SDIO WiFi + BT) — KICKPI K1
source "drivers/net/wireless/seekwave/drivers/seekwaveplatform_lite/Kconfig"
source "drivers/net/wireless/seekwave/drivers/swt6621s_wifi/Kconfig"
source "drivers/net/wireless/seekwave/drivers/swtbt4l/Kconfig"
''')

# ── 4) 装配修改后的 Kconfig / Makefile ──
wk_new = wk.rstrip('\n') + '\n\nsource "' + DEST + '/Kconfig"\n'
wm_new = wm
if 'seekwave' not in wm:
    wm_new = wm.rstrip('\n') + '\nobj-$(CONFIG_SEEKWAVE_BSP_DRIVERS) += seekwave/\n'
(STAGE / 'drivers/net/wireless/Kconfig').parent.mkdir(parents=True, exist_ok=True)
(STAGE / 'drivers/net/wireless/Kconfig').write_text(wk_new)
(STAGE / 'drivers/net/wireless/Makefile').write_text(wm_new)

# ── 5) 生成补丁：a/ = 原文件（仅存在的两个），b/ = 装配结果 ──
A = W / 'wifi-A'
if A.exists():
    shutil.rmtree(A)
(A / 'drivers/net/wireless').mkdir(parents=True, exist_ok=True)
(A / 'drivers/net/wireless/Kconfig').write_text(wk)
(A / 'drivers/net/wireless/Makefile').write_text(wm)

print('3) 生成补丁（diff -ruN）')
r = subprocess.run(['diff', '-ruN', '--label', 'a/drivers/net/wireless/Kconfig',
                    '--label', 'b/drivers/net/wireless/Kconfig', str(A), str(STAGE)],
                   capture_output=True, text=True)
# diff -ruN 目录级：用更可控的方式逐文件生成
out = []
def gen(rel_a, rel_b, fn):
    ra = A / rel_a
    rb = STAGE / rel_b
    if not ra.exists():
        # 新文件
        d = subprocess.run(['diff', '-uN', '/dev/null', str(rb)], capture_output=True, text=True)
        lines = d.stdout.splitlines()
    else:
        d = subprocess.run(['diff', '-u', str(ra), str(rb)], capture_output=True, text=True)
        lines = d.stdout.splitlines()
    if not lines:
        return
    hdr = ['--- a/' + rel_a, '+++ b/' + rel_b]
    body = [l for l in lines if not l.startswith('---') and not l.startswith('+++')]
    out.extend(hdr + body)

# 修改的两个文件
gen('drivers/net/wireless/Kconfig', 'drivers/net/wireless/Kconfig', None)
gen('drivers/net/wireless/Makefile', 'drivers/net/wireless/Makefile', None)
# 新增的驱动文件
for p in sorted((STAGE / DEST).rglob('*')):
    if p.is_file():
        rel = str(p.relative_to(STAGE))
        gen(rel, rel, None)

print('   补丁行数: %d' % len(out))
patch_file = W / 'swt6621s-driver.patch'
patch_file.write_text('\n'.join(out) + '\n')
print('   ✅ %s (%.1f MB)' % (patch_file, patch_file.stat().st_size / 1048576))
