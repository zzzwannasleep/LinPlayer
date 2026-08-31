#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 COMMANDS.md / C# 绑定 / Kotlin 绑定里的命令名各导出成一份排序清单。

    python scripts/dump-command-names.py <仓库根> <输出目录>

给 scripts/check-bindings.sh 的第 4 关(四方比对)用。单独一个文件而不是塞进
那个 shell 里的 heredoc —— heredoc 里的反斜杠转义在多层引用下极易写错。

## 两条口径,少一条这份比对就是假的

1. **行尾必须是 LF。** `Path.write_text` 在 Windows 上会把 `\\n` 翻成 `\\r\\n`,
   而对面 `sort` 给的是 LF —— 行尾不一样时 `comm` 会把**每一条**都报成差异,
   看起来像「Go 里全是野命令」。所以这里一律 `write_bytes`。
2. **排序按码点。** 对面必须配 `LC_ALL=C sort`,否则系统 sort 会按语言环境排
   (忽略标点、可能不分大小写),两种顺序混用同样让 comm 全红。
"""

import pathlib
import re
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit("用法: dump-command-names.py <仓库根> <输出目录>")
    root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

    def dump(name, lines):
        out.joinpath(name).write_bytes(("\n".join(lines) + "\n").encode("utf-8"))

    md = root / "docs" / "go-migration" / "COMMANDS.md"
    text = md.read_text(encoding="utf-8")
    if "<!-- BEGIN GENERATED -->" not in text:
        sys.exit("COMMANDS.md 里找不到 <!-- BEGIN GENERATED --> 标记")
    body = text.split("<!-- BEGIN GENERATED -->", 1)[1]
    want = sorted({
        m.group(1)
        for m in re.finditer(r"^\|\s*\[[ x]\]\s*\|\s*`([a-zA-Z0-9_.]+)`", body, re.M)
    })
    if not want:
        sys.exit("COMMANDS.md 里一条命令都没解析出来 —— 表格格式变了?")
    dump("md.txt", want)

    for key, rel in [("cs", "bindings/csharp/Commands.g.cs"),
                     ("kt", "bindings/kotlin/Commands.g.kt")]:
        src = (root / rel).read_text(encoding="utf-8")
        got = sorted(set(re.findall(r'"([a-z][a-zA-Z0-9]*\.[a-zA-Z0-9]+)"', src)))
        dump(f"{key}.txt", got)

    print(f"COMMANDS.md {len(want)} 条已导出。")


if __name__ == "__main__":
    main()
