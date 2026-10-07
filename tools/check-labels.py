#!/usr/bin/env python3
"""一次性找出生成 DTS 里所有"引用了但 6.1 树没有"的标签。"""
import re, pathlib
from collections import Counter

W = pathlib.Path('/work/kk/dtstest')
DTS = W / 'arch/arm64/boot/dts/rockchip'

# 1) 收集 6.1 树里定义的全部标签
defined = set()
for f in DTS.glob('*.dtsi'):
    s = f.read_text(errors='replace')
    for m in re.finditer(r'(?:^|[\s;{])([a-zA-Z_][a-zA-Z0-9_]*):\s*[a-zA-Z0-9_,.+\-@]*\s*\{', s):
        defined.add(m.group(1))
# 6.1 树里 dtsi 引用但定义在别处的（如 dt-bindings 里的宏不算标签），忽略
print('6.1 树定义标签数: %d' % len(defined))

# 2) 我的生成文件里用到的引用
gen = pathlib.Path('/work/kk/k1-transcribed.dts').read_text()
refs = Counter(re.findall(r'&([a-zA-Z_][a-zA-Z0-9_]*)', gen))
print('生成文件引用标签数: %d（去重）' % len(refs))

# 3) 不在 6.1 树里 + 不在我自己定义里的 -> 有问题
mine = set(re.findall(r'^\t([a-zA-Z_][a-zA-Z0-9_]*):\s', gen, re.M))
mine |= set(re.findall(r'\t\t([a-zA-Z_][a-zA-Z0-9_]*):\s', gen))
broken = {k: v for k, v in refs.items() if k not in defined and k not in mine}
print('\n❌ 引用了但 6.1 树与我方都未定义的标签: %d 个' % len(broken))
for k, v in sorted(broken.items(), key=lambda x: -x[1]):
    print('   &%-24s %d 次' % (k, v))

# 4) 6.1 树里存在但名字可能不同的相似标签（帮助定位正确名）
print('\n🔍 相似标签建议:')
for k in sorted(broken):
    cand = [d for d in defined if k in d or d.startswith(k)]
    if cand:
        print('   &%-20s -> %s' % (k, ', '.join(sorted(cand)[:6])))
