# -*- coding: utf-8 -*-
"""门禁:cgo 生成的 lpcore.h 必须和 SPEC.md §5.1 的导出表**逐条对得上**。

    python scripts/check-ffi-contract.py [头文件路径]

判据:函数集合、顺序、返回类型、参数类型逐条一致。
两处**刻意允许**的差异,都会在输出里说明:
  · 参数名不比 —— cgo 用的是 Go 侧的形参名,和文档里的下划线命名不同
  · `const char*` 视同 `char*` —— **cgo 表达不了 const**,这是工具的限制不是我们的选择
  · `lp_debug_*` 允许多出来 —— 它们不是契约的一部分(自检用),但会列出来让人看见

为什么值得一个门禁:§5.1 标着【一次做对】。签名一旦和文档漂移,
三端绑定会照着文档写、照着头文件编 —— 编得过,但跑起来读到的内存不是它以为的那个东西。
这类故障没有任何一层会喊(SPEC §5.0 的原话)。
"""
import re
import sys
import os

# ★ Windows 的 CI runner 上 Python 默认按 cp1252 输出,打中文当场
#   UnicodeEncodeError —— 而本地开发机(GBK/UTF-8)复现不出来。
#   2026-09-04 新 CI 第一次跑就栽在这。不靠环境变量:PYTHONIOENCODING
#   优先级比 PYTHONUTF8 高,CI 上谁设了它就把 UTF-8 模式顶掉了。
import sys as _sys
for _s in (_sys.stdout, _sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = os.path.join(ROOT, "docs", "go-migration", "SPEC.md")
HEADER = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "core", "lpcore.h")

DECL = re.compile(r"^\s*(?:extern\s+)?([A-Za-z_][A-Za-z0-9_ *]*?)\s*\**\s*\b(lp_[a-z0-9_]+)\s*\(([^)]*)\)\s*;", re.M)


def norm_type(t):
    t = t.replace("const", " ").strip()
    t = re.sub(r"\s+", " ", t)
    t = t.replace(" *", "*").replace("* ", "*")
    return t


def parse(text):
    """返回 [(名字, 返回类型, [参数类型...])],按出现顺序。"""
    out = []
    for m in DECL.finditer(text):
        ret, name, params = m.group(1), m.group(2), m.group(3)
        # 返回类型里的 * 被正则吃到 name 前面了,补回来
        star = "*" if re.search(r"\*\s*" + re.escape(name) + r"\s*\(", m.group(0)) else ""
        ret = norm_type(ret + star)
        ps = []
        for p in params.split(","):
            p = p.strip()
            if not p or p == "void":
                continue
            # 去掉形参名:最后一个标识符
            p = re.sub(r"\b[A-Za-z_][A-Za-z0-9_]*\s*$", "", p).strip() or p
            ps.append(norm_type(p))
        out.append((name, ret, ps))
    return out


def spec_block():
    s = open(SPEC, encoding="utf-8").read()
    i = s.index("### 5.1 导出函数表")
    j = s.index("### 5.2", i)
    blocks = re.findall(r"```c\n(.*?)```", s[i:j], re.S)
    if not blocks:
        print("!! SPEC §5.1 里找不到 ```c 代码块")
        sys.exit(2)
    return "\n".join(blocks)


def main():
    if not os.path.exists(HEADER):
        print("!! 找不到头文件 %s —— 先跑 bash scripts/build-core.sh" % HEADER)
        return 2

    want = parse(spec_block())
    got_all = parse(open(HEADER, encoding="utf-8").read())
    got = [g for g in got_all if not g[0].startswith("lp_debug_")]
    extra = [g[0] for g in got_all if g[0].startswith("lp_debug_")]

    print("SPEC §5.1 声明 %d 个,头文件里有 %d 个(另有 %d 个 lp_debug_* 不计入契约)"
          % (len(want), len(got), len(extra)))
    if extra:
        print("  自检用的额外导出:%s" % ", ".join(extra))

    fail = 0
    wnames = [w[0] for w in want]
    gnames = [g[0] for g in got]

    missing = [n for n in wnames if n not in gnames]
    unexpected = [n for n in gnames if n not in wnames]
    for n in missing:
        print("  [不通过] 头文件里缺 %s" % n); fail += 1
    for n in unexpected:
        print("  [不通过] 头文件里多出契约外的 %s" % n); fail += 1

    if wnames != gnames and not missing and not unexpected:
        print("  [不通过] 顺序不一致")
        print("     SPEC : %s" % " ".join(wnames))
        print("     头文件: %s" % " ".join(gnames))
        fail += 1

    gmap = {g[0]: g for g in got}
    for name, ret, ps in want:
        if name not in gmap:
            continue
        _, gret, gps = gmap[name]
        if ret != gret:
            print("  [不通过] %s 返回类型:SPEC %s vs 头文件 %s" % (name, ret, gret)); fail += 1
        if ps != gps:
            print("  [不通过] %s 参数:SPEC (%s) vs 头文件 (%s)"
                  % (name, ", ".join(ps), ", ".join(gps))); fail += 1

    if fail == 0:
        print("全部一致。")
    else:
        print("有 %d 处不一致。" % fail)
    return fail


if __name__ == "__main__":
    sys.exit(main())
