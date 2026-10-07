#!/usr/bin/env python3
"""生成 SWT6621S 驱动补丁 —— 【只含新增文件】，不修改任何既有文件。

为什么不改 drivers/net/wireless/{Kconfig,Makefile}：
  框架在应用本补丁前，已用它自己的补丁改过这两个文件；硬改会因上下文不匹配
  导致 "Failed to apply 1 patches" 整体失败（已实际踩到）。挂钩改由扩展在
  构建期追加（见 extensions/kickpi-k1-wifi.sh），带幂等守卫。
"""
import pathlib, shutil, subprocess, sys

W = pathlib.Path('/work/kk')
DRV = W / 'wifi-swt6621s/main'
STAGE = W / 'wifi-stage2'
DEST = 'drivers/net/wireless/seekwave'

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

print('1) 装配驱动文件到 %s' % DEST)
copy_tree(DRV / 'drivers', STAGE / DEST / 'drivers')
copy_tree(DRV / 'include', STAGE / DEST / 'include')
(STAGE / DEST / 'Makefile').write_text(
    'skw_extra_flags := -I$(src)/include/linux -I$(src)/include/linux/platform_data\n'
    'export skw_extra_flags\n\n'
    'obj-$(CONFIG_SEEKWAVE_BSP_DRIVERS) += drivers/\n')

# 修正 Kconfig 里写死的 drivers/misc/... 路径
fixed = 0
for kf in (STAGE / DEST).rglob('Kconfig'):
    s = kf.read_text(errors='replace')
    s2 = s.replace('drivers/misc/seekwaveplatform_lite', DEST + '/drivers/seekwaveplatform_lite')
    if s != s2:
        kf.write_text(s2); fixed += 1
print('   修正 Kconfig 路径: %d 个文件' % fixed)

# 顶层 Kconfig（由扩展挂进 wireless/Kconfig）
(STAGE / DEST / 'Kconfig').write_text(
    '# SPDX-License-Identifier: GPL-2.0\n'
    '# Seekwave SWT6621S (SDIO WiFi + BT) — KICKPI K1\n'
    'source "drivers/net/wireless/seekwave/drivers/seekwaveplatform_lite/Kconfig"\n'
    'source "drivers/net/wireless/seekwave/drivers/swt6621s_wifi/Kconfig"\n'
    'source "drivers/net/wireless/seekwave/drivers/swtbt4l/Kconfig"\n')

print('2) 生成补丁（逐文件 diff -uN /dev/null）')
out = []
for p in sorted((STAGE / DEST).rglob('*')):
    if not p.is_file():
        continue
    rel = str(p.relative_to(STAGE))
    d = subprocess.run(['diff', '-uN', '/dev/null', str(p)], capture_output=True, text=True)
    lines = d.stdout.splitlines()
    if not lines:
        continue
    hdr = ['--- a/' + rel, '+++ b/' + rel]
    body = [l for l in lines if not (l.startswith('---') or l.startswith('+++'))]
    out.extend(hdr + body)

patch_file = W / 'swt6621s-driver.patch'
patch_file.write_text('\n'.join(out) + '\n')
n_files = sum(1 for l in out if l.startswith('--- a/'))
print('   文件数: %d | 补丁行数: %d' % (n_files, len(out)))
print('   ✅ %s (%.1f MB)' % (patch_file, patch_file.stat().st_size / 1048576))
