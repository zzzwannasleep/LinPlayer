#!/usr/bin/env python
"""接线报告:哪些已注册的核心层命令,Windows 宿主一次都没调过。

**这是报告,不是门禁。** 做成门禁的话它从第一天起就是红的,
而「长期红的门禁 = 没有门禁」—— 真信号会淹在噪音里。

背景(2026-09-02):`scripts/check-bindings.sh` 比的是 `bindings/csharp` 这层
**生成的绑定**,它永远和 COMMANDS.md 一致 —— 照不到「App 有没有真去调」。
`player.setShaderLevel` / `player.shaderLevels` 就是这么漏的:
核心层有 28 个画质档位,播放页一次都没调过,而门禁全绿。

⚠️ **结果要打折看。** 「零调用」不等于「功能缺失」:
不少命令有等价路径(比如 `emby.seriesSeasons` 的活由 `emby.getItems` 干了)。
它是**待查清单**,不是缺陷清单。

    python scripts/report-wiring.py
"""
import io
import os
import subprocess
import sys

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
APP = os.path.join(ROOT, "apps", "windows", "LinPlayer.Desktop")


def registered():
    """问 Go 注册表要命令名。libmpv 得在搜索路径上,否则 cgo 出来的探针起不来。"""
    env = dict(os.environ)
    env["PATH"] = os.path.join(ROOT, "crates", "mpv", "libmpv") + os.pathsep + env["PATH"]
    out = subprocess.run(
        ["go", "run", "./cmd/listcommands"],
        cwd=os.path.join(ROOT, "core"), env=env, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("拿不到 Go 命令表(先 source scripts/env.sh):\n" + out.stderr[-800:])
    return sorted(l.strip() for l in out.stdout.splitlines() if l.strip())


def app_source():
    parts = []
    for root, _dirs, files in os.walk(APP):
        seg = root.split(os.sep)
        if "bin" in seg or "obj" in seg:
            continue
        for f in files:
            if f.endswith((".cs", ".axaml")):
                parts.append(io.open(os.path.join(root, f), encoding="utf-8",
                                     errors="replace").read())
    return "\n".join(parts)


def main():
    cmds = [c for c in registered() if not c.startswith("debug.")]
    blob = app_source()
    missing = []
    for c in cmds:
        # 生成的绑定把 emby.getItems 变成扩展方法 EmbyGetItems
        m = "".join(p[:1].upper() + p[1:] for p in c.split("."))
        if m in blob or ('"' + c + '"') in blob:
            continue
        missing.append(c)

    print("已注册(不含 debug.*):%d 条" % len(cmds))
    print("Windows 宿主零调用:%d 条\n" % len(missing))
    group = {}
    for c in missing:
        group.setdefault(c.split(".")[0], []).append(c)
    for ns in sorted(group):
        print("  %-10s %2d 条: %s" % (ns, len(group[ns]), ", ".join(group[ns])))
    print("\n★ 零调用 ≠ 功能缺失。有等价路径的算正常,拿它当待查清单。")


if __name__ == "__main__":
    main()
