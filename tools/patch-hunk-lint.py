#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""补丁 hunk 行数一致性门禁（lyw-kk CI 早期自检）。

背景：`swt6621s-wifi-bt-driver.patch` 曾因新增文件的 hunk 头 `@@ -0,0 +1,179 @@`
没跟着内容一起改成 181，补丁应用时文件末尾 2 行（含 `#endif`）被静默丢弃 ——
patch 依然报“应用成功”，但源码 `#ifndef` 未闭合，整个编译以几百条假错误炸掉。
这种“行数不一致 → 文件被静默截断”的错误 GNU patch 不会报，只能静态检查。

判据：每个 unified hunk 声明的新/旧侧行数 == 该 hunk 实际的 +/-/context 行数。
只对能识别为 unified diff 的文件做严格校验；认不出格式的打 SKIP 并放行（避免误报白跑）。
"""
import os
import re
import sys

HUNK_RE = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')

# diff 元信息行（不参与任何一侧计数）
META_PREFIXES = (
    'diff --git ', 'index ', 'old mode ', 'new mode ', 'new file mode ',
    'deleted file mode ', 'similarity index ', 'rename from ', 'rename to ',
    'Binary files ', 'GIT binary patch', 'literal ', 'delta ',
)


def check_patch(text):
    """返回 (hunk_count, issues, recognized_files)；issues 为空即通过。

    解析规则对齐 GNU patch：一个 hunk 从声明行数读满的那一刻结束；
    结束后到下一个 hunk/文件头之间只允许空行与 diff 元信息（patch 会忽略它们）。
    读满后又冒出内容行 = 声明行数偏小 = 文件末尾被静默截断（本次事故的形态）。
    """
    hunks = []
    issues = []
    cur_file = None
    h = None
    recognized = 0

    def finish(hh, idx, line):
        """hunk 已读满后遇到的行：只有空行/元信息/换行标记/签名合法。"""
        if (line.strip() == '' or line.startswith(META_PREFIXES)
                or line.startswith('\\')          # \ No newline at end of file
                or line.startswith('-- ')):       # git format-patch 尾部签名
            return None
        if line.startswith('@@') or line.startswith('--- ') or line.startswith('+++ '):
            return None
        issues.append(
            'hunk 声明行数偏小: %s:%d (文件 %s)  读满 %d/%d 行后仍有内容行 %r —— '
            '补丁应用会静默截断该文件末尾'
            % (hh['file'], hh['line'], cur_file, hh['new'], hh['old'], line[:60]))
        return None

    for idx, line in enumerate(text.splitlines(), 1):
        if h is not None and (h['m'] + h['c'] == h['old']) and (h['p'] + h['c'] == h['new']):
            # 本 hunk 已按声明读满
            h = finish(h, idx, line)

        if line.startswith(META_PREFIXES):
            if h is not None:
                issues.append('hunk 提前结束（声明行数偏大）: %s:%d' % (h['file'], h['line']))
            h = None
            continue
        if line.startswith('+++ '):
            cur_file = line[4:].split('\t')[0]
            if h is not None:
                issues.append('hunk 提前结束（声明行数偏大）: %s:%d' % (h['file'], h['line']))
            h = None
            recognized += 1
            continue
        if line.startswith('--- '):
            if h is not None:
                issues.append('hunk 提前结束（声明行数偏大）: %s:%d' % (h['file'], h['line']))
            h = None
            continue
        m = HUNK_RE.match(line)
        if m:
            if h is not None:
                issues.append('hunk 提前结束（声明行数偏大）: %s:%d' % (h['file'], h['line']))
            h = {
                'file': cur_file, 'line': idx,
                'old': int(m.group(2)) if m.group(2) is not None else 1,
                'new': int(m.group(4)) if m.group(4) is not None else 1,
                'p': 0, 'm': 0, 'c': 0,
            }
            hunks.append(h)
            continue
        if h is None:
            continue
        if line.startswith('\\'):
            continue
        if line.startswith('+'):
            h['p'] += 1
        elif line.startswith('-'):
            h['m'] += 1
        else:
            h['c'] += 1

    if h is not None and not ((h['m'] + h['c'] == h['old']) and (h['p'] + h['c'] == h['new'])):
        issues.append(
            'hunk 未读满即到文件尾: %s:%d  声明 -%d/+%d，实际 -%d/+%d'
            % (h['file'], h['line'], h['old'], h['new'], h['m'] + h['c'], h['p'] + h['c']))
    return len(hunks), issues, recognized


def main(argv):
    if len(argv) < 2:
        print('usage: patch-hunk-lint.py <dir-or-file> [<dir-or-file> ...]', file=sys.stderr)
        return 2
    paths = []
    for a in argv[1:]:
        if os.path.isdir(a):
            for root, _dirs, files in os.walk(a):
                paths += [os.path.join(root, f) for f in files if f.endswith('.patch')]
        elif os.path.isfile(a):
            paths.append(a)
        else:
            print('!! 路径不存在: %s' % a, file=sys.stderr)
            return 2

    total_hunks = 0
    total_files = 0
    all_issues = []
    skipped = []
    for p in sorted(paths):
        with open(p, encoding='utf-8', errors='replace') as fh:
            text = fh.read()
        n, issues, recognized = check_patch(text)
        if recognized == 0:
            skipped.append(p)
            continue
        total_files += 1
        total_hunks += n
        for msg in issues:
            all_issues.append('%s\n    %s' % (p, msg))

    print('--- patch-hunk-lint ---')
    print('补丁文件: %d 个已校验, %d 个跳过(非 unified diff)' % (total_files, len(skipped)))
    print('hunk 总数: %d' % total_hunks)
    for p in skipped:
        print('  SKIP  %s' % p)
    if all_issues:
        print('!! 发现 %d 处 hunk 行数不一致：' % len(all_issues))
        for msg in all_issues:
            print('  ' + msg)
        return 1
    print('OK  全部 hunk 声明行数与实际一致')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
