#!/usr/bin/env python3
"""verify-assert-lint —— 抓「自相矛盾断言」：同一个路径既被断言必须存在、又被断言必须不存在。

为什么需要：删掉某个板级自检件（如 EEE 三件）时，很容易只加反向断言「无 X」而忘记删掉
原来的正向断言「缺 X 就算失败」。CI 的表现是：镜像**已经编好**，才在 verify-image.sh 里
同时打印 "✓ 无 …" 与 "✗ 缺 …" 然后 exit 1 —— 整车白跑一轮（lyw-kk run #49 就是这么挂的，
117 分钟构建的成本）。静态扫一遍 0 成本，别再用「跑一遍 CI 看看」当检查手段。

判据（对齐本仓 verify-image.sh 的写法）：
  正向 = [[ -e|-x|-f|-d|-L "$RMNT/<path>" ]] … && ok     ← 存在才算过
  反向 = [[ -e|-x|-f|-d|-L "$RMNT/<path>" ]] … && bad    ← 存在即失败
       + for f in <p1> <p2> …; do [[ -e "$RMNT/$f" ]] && bad … done 里的列表展开
  两者交集 → 失败。

用法：python3 tools/verify-assert-lint.py [tools/verify-image.sh]
退出码：0 一致；1 有矛盾；2 用错/文件缺失。
"""
import os
import re
import sys

FOR_LOOP = re.compile(r"\bfor\s+(\w+)\s+in\s+([^;\n]+);\s*do\b")
# for 循环体里「存在即失败」的形态：[[ -e "$RMNT/$f" ]] && bad …
FOR_ABSENT_BODY = re.compile(r'\[\[\s*-\w+\s+"?\$RMNT/\$\w+"?\s*\]\]\s*&&\s*bad')
ASSERT = re.compile(r'\[\[\s*-(\w+)\s+"?\$RMNT/([^"\s]+)"?\s*\]\][^\n]*?&&\s*(ok|bad)')


def logical_lines(text):
    """把行尾反斜杠续行拼成逻辑行，返回 [(起始行号, 内容)]。"""
    out, buf, start = [], "", 0
    for i, raw in enumerate(text.splitlines(), 1):
        if not buf:
            start = i
        stripped = raw.rstrip()
        if stripped.endswith("\\"):
            buf += stripped[:-1] + " "
            continue
        buf += stripped
        out.append((start, buf))
        buf = ""
    if buf:
        out.append((start, buf))
    return out


def scan(path):
    text = open(path, "r", encoding="utf-8", errors="replace").read()
    lines = logical_lines(text)

    must_exist, must_absent = {}, {}
    for idx, (lineno, line) in enumerate(lines):
        if line.lstrip().startswith("#"):
            continue

        # for 循环：列表里的件由循环体决定是"必须存在"还是"必须不存在"
        m = FOR_LOOP.search(line)
        if m and not m.group(1).startswith("$"):
            body = " ".join(l for _, l in lines[idx + 1: idx + 4])
            if FOR_ABSENT_BODY.search(body):
                for tok in m.group(2).split():
                    must_absent.setdefault(tok, lineno)

        for _op, target, verdict in ASSERT.findall(line):
            target = target.strip()
            if "$" in target:          # 变量路径（for 循环体的 $f）由上面的展开负责
                continue
            if verdict == "ok":
                must_exist.setdefault(target, lineno)
            else:
                must_absent.setdefault(target, lineno)

    conflicts = sorted(set(must_exist) & set(must_absent))
    return must_exist, must_absent, conflicts


def main(argv):
    path = argv[1] if len(argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "verify-image.sh")
    if not os.path.isfile(path):
        print("verify-assert-lint: 找不到 %s" % path)
        return 2

    must_exist, must_absent, conflicts = scan(path)
    print("--- verify-assert-lint (%s) ---" % path)
    print("    正向断言（必须存在）%d 条，反向断言（必须不存在）%d 条"
          % (len(must_exist), len(must_absent)))
    if not conflicts:
        print("OK 无自相矛盾断言")
        return 0

    for p in conflicts:
        print("FAIL %s : 既要求存在（line %d）又要求不存在（line %d）"
              % (p, must_exist[p], must_absent[p]))
    print("FAIL 共 %d 处自相矛盾断言（构建会成功、自检必红）" % len(conflicts))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
