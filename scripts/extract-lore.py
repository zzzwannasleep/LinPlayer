#!/usr/bin/env python3
"""把源码里成规模的中文注释块抽出来,汇成一份可检索的「代码口述史」。

用法:
    python scripts/extract-lore.py              # 写 docs/code-lore.md
    python scripts/extract-lore.py --stats      # 只报统计,不写文件

为什么要有这个:
    本仓库的注释不是"说明这行在干什么",而是记录**某次真实故障的根因**,以及
    "为什么不能改成看起来更简洁的写法"。这些知识散在 4 万行 Rust 和 4 万行 TS 里,
    只有改到那一处的人才看得到。抽出来汇总,才能被检索、被新人读、被 agent 用。

判据(什么算「有价值的注释块」):
    - 含中文
    - 连续注释行 >= MIN_LINES 行(单行的多是标注,信息量低)
    - 或者虽短但含强信号词(见 SIGNALS),这类往往是一句话点破根因

不抽:纯 ASCII 的注释(多是照抄上游文档)、doc test、被注释掉的代码。
"""
import argparse
import os
import re
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
OUT = os.path.join(ROOT, "docs", "code-lore.md")

MIN_LINES = 3

# 这些词出现 = 大概率在讲一次真实故障或一条硬约束,再短也要
SIGNALS = [
    "根因", "真因", "坑", "陷阱", "教训", "栽过", "炸", "崩", "静默", "不报错",
    "必须", "禁止", "不许", "别改", "不能改", "别删", "不要删", "务必",
    "否则", "会导致", "表现为", "症状", "复现", "实测", "亲测",
    "曾经", "以前", "历史", "遗留", "已修", "修过", "改过",
    "为什么", "理由", "缘由", "注意", "警告", "⚠", "★", "❌",
    "bug", "BUG", "FIXME", "HACK", "XXX", "TODO",
]

SCAN = [
    ("Rust 核心", "crates", (".rs",)),
    ("平台壳", "apps", (".rs", ".kt")),
    ("前端", "ui", (".ts", ".tsx")),
    ("脚本", "scripts", (".sh", ".ps1", ".mjs", ".py")),
]
SKIP_DIRS = {"node_modules", "target", "build", ".git", "gen", "dist", "dist-portable"}

# 各语言的行注释前缀
LINE_COMMENT = {
    ".rs": ("///", "//!", "//"),
    ".kt": ("///", "//"),
    ".ts": ("///", "//"),
    ".tsx": ("///", "//"),
    ".mjs": ("///", "//"),
    ".sh": ("#",),
    ".ps1": ("#",),
    ".py": ("#",),
}
BLOCK = {
    ".rs": ("/*", "*/"),
    ".kt": ("/*", "*/"),
    ".ts": ("/*", "*/"),
    ".tsx": ("/*", "*/"),
    ".mjs": ("/*", "*/"),
}

HAS_CJK = re.compile(r"[一-鿿]")
# 被注释掉的代码:以注释符开头,后面像语句
LOOKS_LIKE_CODE = re.compile(r"^\s*(let |const |fn |pub |if |for |return |import |use |\}|\{)")

# ── 脱敏 ───────────────────────────────────────────────────────────────
# 源码注释里有真实的测试服务器与线路地址(仓库既有问题,见 docs/lessons/red-line-audit.md)。
# 抽取汇编时必须替换掉 —— 汇总成一份文件会让这些地址更好找、更容易被顺手复制走。
#
# 白名单之外的所有主机名一律替换。白名单只放:公开厂商 API、公开文档站、占位符。
HOST_ALLOW = re.compile(
    r"^(localhost|127\.0\.0\.1|0\.0\.0\.0|"
    r"[a-z0-9.-]*\.?(aliyundrive\.com|baidu\.com|115\.com|139\.com|189\.cn|quark\.cn|"
    r"bgm\.tv|trakt\.tv|bilibili\.com|github\.com|githubusercontent\.com|mpv\.io|"
    r"tauri\.app|react\.dev|vite\.dev|rust-lang\.org|tokio\.rs|sentry\.io|docs\.rs|"
    r"themoviedb\.org|tmdb\.org|dandanplay\.(com|net)|anibt\.net|mikanani\.me|"
    r"emby\.media|jellyfin\.org|kodi\.wiki|bellard\.org|huggingface\.co|"
    r"w3\.org|whatwg\.org|badssl\.com|strem\.io|extscreen\.com|fetion\.com\.cn)|"
    r"(a|b|c|d|h|x|cdn|cdn1|cdn2|d1|d2|old-a|evil|ok|official|my-cdn)\.(com|net|lan|local)|"
    r"example\.(com|org)|[a-z0-9-]+\.(lan|local|invalid|test))$",
    re.I,
)
URL_RE = re.compile(r"(https?://)([a-zA-Z0-9.-]+)(:\d+)?")
# {0,3} 而不是 {1,3}:单点域名(形如 example.xyz)也要抓。写成 `xxx.xyz/api`
# 不带协议头时 URL_RE 抓不到,只能靠这条。误伤由白名单兜底。
BARE_HOST_RE = re.compile(r"\b([a-z0-9-]+(?:\.[a-z0-9-]+){0,3}\.(?:com|net|org|cn|de|io|tv|me|xyz|top|cc|lol|dev|app))\b", re.I)
IPV4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
IP_ALLOW = {"127.0.0.1", "0.0.0.0", "1.2.3.4", "8.8.8.8", "255.255.255.255"}


# 项目内部对两台测试服务端的代号(不带 TLD,连不上,但仍在暗示域名)。
# 换成中性标签而不是整句删掉 —— "两台服务端行为不同" 才是这些注释的价值所在,
# 抹掉区分等于把知识一起删了。
NICKNAMES = [
    (re.compile(r"\buhdnow\b", re.I), "服务端A"),
    (re.compile(r"\bmebimmer\b", re.I), "服务端B"),
    (re.compile(r"\bUHD\s*fork\b"), "服务端A(fork)"),
]


def redact(text):
    """把非白名单的主机名 / IP / 内部代号替换成占位符。宁可多替换,不可漏。"""
    def _url(m):
        host = m.group(2)
        if HOST_ALLOW.match(host):
            return m.group(0)
        return f"{m.group(1)}<主机已脱敏>{m.group(3) or ''}"

    text = URL_RE.sub(_url, text)
    text = BARE_HOST_RE.sub(lambda m: m.group(0) if HOST_ALLOW.match(m.group(1)) else "<主机已脱敏>", text)
    text = IPV4_RE.sub(lambda m: m.group(0) if m.group(0) in IP_ALLOW else "<IP已脱敏>", text)
    for pat, label in NICKNAMES:
        text = pat.sub(label, text)
    return text


def strip_marker(line, ext):
    s = line.strip()
    for m in LINE_COMMENT.get(ext, ()):
        if s.startswith(m):
            return s[len(m):].strip()
    return s.lstrip("*").strip()


def blocks_in(path, ext):
    """产出 (起始行号, [正文行...])。行注释连续段与 /* */ 块都收。"""
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except (UnicodeDecodeError, OSError):
        return
    markers = LINE_COMMENT.get(ext, ())
    open_b, close_b = BLOCK.get(ext, (None, None))

    i, n = 0, len(lines)
    while i < n:
        stripped = lines[i].strip()

        # /* ... */ 块
        if open_b and stripped.startswith(open_b):
            start, body = i + 1, []
            while i < n:
                body.append(strip_marker(lines[i].replace(open_b, "").replace(close_b, ""), ext))
                if close_b in lines[i] and not (i == start - 1 and lines[i].strip() == open_b):
                    break
                i += 1
            yield start, [b for b in body if b]
            i += 1
            continue

        # 连续行注释
        if markers and any(stripped.startswith(m) for m in markers):
            start, body = i + 1, []
            while i < n and any(lines[i].strip().startswith(m) for m in markers):
                body.append(strip_marker(lines[i], ext))
                i += 1
            yield start, [b for b in body if b]
            continue

        i += 1


def worth_keeping(body):
    text = "\n".join(body)
    if not HAS_CJK.search(text):
        return False
    # 被注释掉的代码不要
    code_like = sum(1 for b in body if LOOKS_LIKE_CODE.match(b))
    if code_like > len(body) / 2:
        return False
    if len(body) >= MIN_LINES:
        return True
    return any(s in text for s in SIGNALS)


def collect():
    out = {}
    total_files = 0
    for label, top, exts in SCAN:
        base = os.path.join(ROOT, top)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in sorted(filenames):
                ext = os.path.splitext(fn)[1]
                if ext not in exts:
                    continue
                path = os.path.join(dirpath, fn)
                rel = os.path.relpath(path, ROOT).replace("\\", "/")
                found = [(ln, body) for ln, body in blocks_in(path, ext) if worth_keeping(body)]
                if found:
                    out.setdefault(label, []).append((rel, found))
                    total_files += 1
    return out, total_files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stats", action="store_true")
    a = ap.parse_args()

    data, nfiles = collect()
    nblocks = sum(len(f) for groups in data.values() for _, f in groups)
    nlines = sum(len(b) for groups in data.values() for _, f in groups for _, b in f)

    if a.stats:
        for label, groups in data.items():
            cnt = sum(len(f) for _, f in groups)
            print(f"{label:10} {len(groups):4} 个文件  {cnt:5} 个注释块")
        print(f"{'合计':10} {nfiles:4} 个文件  {nblocks:5} 个注释块  {nlines} 行")
        return

    parts = [
        "# 代码口述史 · 源码注释汇编\n",
        "> **自动生成,勿手改。** 重新生成:`python scripts/extract-lore.py`\n",
        "",
        "本仓库的注释不是「说明这行在干什么」,而是记录**某次真实故障的根因**,",
        "以及「为什么不能改成看起来更简洁的写法」。这些知识散在几万行代码里,",
        "只有改到那一处的人才看得到 —— 这份文件把它们汇总起来,方便检索。",
        "",
        "**怎么用:** 遇到「这为什么这么写」的疑问,先在这里 grep 关键词",
        "(症状词、属性名、函数名都行),命中后按 `文件:行号` 回到现场读上下文。",
        "",
        f"**规模:** {nfiles} 个文件 · {nblocks} 个注释块 · {nlines} 行。",
        "",
        "> 抽取规则:含中文、连续 3 行以上,或虽短但含「根因/必须/否则/实测/坑」等强信号词。",
        "> 纯 ASCII 注释(多为照抄上游文档)与被注释掉的代码不收。",
        "",
        "---",
        "",
    ]
    for label, groups in data.items():
        cnt = sum(len(f) for _, f in groups)
        parts.append(f"\n## {label}({len(groups)} 个文件 / {cnt} 块)\n")
        for rel, found in sorted(groups, key=lambda g: -len(g[1])):
            parts.append(f"\n### `{rel}` — {len(found)} 块\n")
            for ln, body in found:
                parts.append(f"**{rel}:{ln}**")
                parts.append("")
                for b in body:
                    parts.append(f"> {redact(b)}")
                parts.append("")

    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(parts) + "\n")
    print(f"已写入 {OUT}:{nfiles} 文件 / {nblocks} 块 / {nlines} 行")


if __name__ == "__main__":
    main()
