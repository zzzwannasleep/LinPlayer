#!/usr/bin/env python3
"""从 Tauri 注册表生成 docs/go-migration/COMMANDS.md 的表格部分。

用法:
    python scripts/gen-commands.py            # 写回 COMMANDS.md 的表格段
    python scripts/gen-commands.py --check    # 只校验:表格与注册表不一致则退出 1

为什么要有这个脚本:
    三端的 FFI 绑定层从 COMMANDS.md 生成。手写 266 x 3 = 798 次抄写机会,
    错的那几次全是运行时才发现。表格必须是生成的,不是维护的。

--check 是 CI 用的门禁:有人加了命令但没跑生成器,CI 就红。
"""
import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, "docs", "go-migration", "COMMANDS.md")
MARK_BEGIN = "<!-- BEGIN GENERATED -->"
MARK_END = "<!-- END GENERATED -->"

SIG_SOURCES = [
    "apps/desktop/src/lib.rs",
    "apps/desktop/src/pluginmarket.rs",
    "apps/desktop/src/pluginassets.rs",
    "apps/desktop/src/updater.rs",
    "apps/desktop/src/shaders.rs",
    "apps/desktop/src/imgcache.rs",
    "apps/desktop/src/telemetry.rs",
    "apps/desktop/src/plugins_host.rs",
]
DESKTOP_REG = "apps/desktop/src/lib.rs"
ANDROID_REG = "apps/android/src/lib.rs"

# ── 域归属 ──────────────────────────────────────────────────────────────
# EXPLICIT 是写死的:凡是前缀/关键字启发式会认错的,一律列在这里。
# 认错的代价是三个端各理解成一件不同的事,所以宁可写死也不要"聪明"。
EXPLICIT = {}
for _c in ("login relogin current_session aggregate_search aggregate_overview views is_admin "
           "set_played scan_libraries refresh_item similar_items get_filters list_latest "
           "list_next_up list_random list_resume list_collections blocked_list set_blocked "
           "report_progress").split():
    EXPLICIT[_c] = "emby"
for _c in ("test_connection probe_accounts batch_parse batch_add_servers startup_deep_link "
           "parse_deep_link probe_lines").split():
    EXPLICIT[_c] = "account"
for _c in ("play play_local play_external status stop_playback set_pause set_hwdec set_mute "
           "set_aspect_ratio set_audio_delay set_sub_delay set_sub_style set_secondary_sub "
           "set_secondary_sub_opts chapter_info get_playback_prefs set_playback_prefs").split():
    EXPLICIT[_c] = "player"
for _c in ("quark_scan_start quark_scan_poll").split():
    EXPLICIT[_c] = "source"
for _c in ("afdian_sponsor_url afdian_verify cache_size clear_cache data_paths open_data_dir "
           "pick_file pick_directory pick_local_folder").split():
    EXPLICIT[_c] = "system"
EXPLICIT["set_detail_blur"] = "prefs"

# -- 新契约里有、Rust 版没有的命令 --------------------------------------
# 这张表**是手维护的**,和上面从 Rust 注册表抽出来的那批不同。
#
# 为什么需要它:新架构有几条命令在 Rust 版里根本不存在(核心层自检、能力协商、
# 诊断导出…),它们同样要进三端绑定。没有这张表的话,Go 侧注册了、
# 绑定里却没有 —— 四方比对(scripts/check-bindings.sh)当场红,
# 而红的理由会被误读成「Go 里有野命令」。
#
# 只放**产品命令**。探针 / 自检用的一律走 debug.*,不进契约
# (debug.* 由 LP_DEBUG_CMDS 门控,三端绑定里不该出现)。
ADDED = {
    "emby": [
        ("emby.counts", "server, token, user_id", "Counts",
         "媒体库规模统计。Rust 版里 emby::counts 只被 aggregate_overview 内部调用,没单独成命令"),
        ("emby.logout", "server, token, user_id, device_id", "{ server_ok: bool }",
         "服务端登出。尽力而为:某 fork 该端点 404 且 token 仍可用,失败不挡本地删账号"),
    ],
    "system": [
        ("system.ping", "-", "{ pong: true, ... }", "核心层活着吗。契约测试的第一条"),
        ("system.capabilities", "-", "{ commands: string[], ... }",
         "本平台支持哪些命令。UI 启动时拿它隐藏入口(SPEC 5.6)"),
        ("system.exportDiagnostics", "-", "{ ... }", "诊断导出(SPEC 5.6)。**不许带凭据**"),
    ],
}

PREFIXES = [
    ("anirss_", "anirss"), ("player_", "player"), ("plugin_", "plugin"), ("plugins_", "plugin"),
    ("danmaku_", "danmaku"), ("source_", "source"), ("download_", "download"),
    ("trakt_", "sync"), ("bangumi_", "sync"), ("calendar_", "sync"),
    ("whisper_", "translate"), ("translate_", "translate"), ("translation_", "translate"),
    ("cf_", "prefs"), ("prefetch_", "prefs"), ("preload_", "prefs"), ("icon_", "prefs"),
    ("vod_", "source"), ("netdisk_", "source"), ("companion_", "system"),
]
KEYWORDS = [
    ("danmaku", "danmaku"), ("plugin", "plugin"), ("player", "player"), ("mpv", "player"),
    ("subtitle", "player"), ("track", "player"), ("speed", "player"), ("volume", "player"),
    ("seek", "player"), ("screenshot", "player"), ("shader", "player"),
    ("source", "source"), ("download", "download"),
    ("trakt", "sync"), ("bangumi", "sync"), ("calendar", "sync"),
    ("account", "account"), ("server", "account"), ("line", "account"),
    ("item", "emby"), ("librar", "emby"), ("favorite", "emby"), ("search", "emby"),
    ("season", "emby"), ("episode", "emby"), ("person", "emby"), ("ranking", "emby"),
    ("history", "emby"),
    ("prefs", "prefs"), ("setting", "prefs"), ("config", "prefs"), ("theme", "prefs"),
    ("proxy", "prefs"),
    ("update", "system"), ("log", "system"), ("path", "system"),
]
TITLES = {
    "emby": "Emby 浏览与详情", "account": "账号与线路", "player": "播放器",
    "source": "媒体源(浏览型 / 影视目录)", "anirss": "Ani-RSS 管理", "danmaku": "弹幕",
    "plugin": "插件", "download": "下载", "sync": "同步(Trakt / Bangumi / 日历)",
    "translate": "字幕翻译 / Whisper(桌面独占)", "prefs": "设置与偏好", "system": "系统",
}
ORDER = ["emby", "account", "player", "source", "anirss", "danmaku", "plugin",
         "download", "sync", "translate", "prefs", "system"]


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return f.read()


def registry(path):
    """从 invoke_handler(generate_handler![...]) 里取裸命令名。

    命令必须用裸名字注册(不能写成 `mod::cmd`),否则这里取不到 —— 现有
    api_contract_tests 也有同样的约束,两处保持一致。
    """
    text = read(path)
    m = re.search(r"invoke_handler\(tauri::generate_handler!\[(.*?)\]\s*\)", text, re.S)
    if not m:
        sys.exit(f"找不到注册表:{path}")
    names = re.findall(r"[a-z_0-9]+", m.group(1))
    return list(dict.fromkeys(names))


def signatures():
    out = {}
    for path in SIG_SOURCES:
        full = os.path.join(ROOT, path)
        if not os.path.exists(full):
            continue
        text = read(path)
        for m in re.finditer(r"#\[tauri::command\][^\n]*\n((?:pub )?(?:async )?fn .*?)\{", text, re.S):
            sig = " ".join(m.group(1).split())
            name = re.search(r"fn ([a-z_0-9]+)", sig)
            if name:
                out[name.group(1)] = sig
    return out


def domain(cmd):
    if cmd in EXPLICIT:
        return EXPLICIT[cmd]
    for pre, dom in PREFIXES:
        if cmd.startswith(pre):
            return dom
    for kw, dom in KEYWORDS:
        if kw in cmd:
            return dom
    return "system"


def new_name(cmd, dom):
    body = cmd[len(dom) + 1:] if cmd.startswith(dom + "_") else cmd
    parts = [p for p in body.split("_") if p]
    if not parts:
        return f"{dom}.{cmd}"
    return f"{dom}." + parts[0] + "".join(p.capitalize() for p in parts[1:])


def split_args(raw):
    out, depth, cur = [], 0, ""
    for ch in raw:
        if ch in "<([":
            depth += 1
        if ch in ">)]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def args_of(sig):
    m = re.search(r"\((.*)\)\s*->", sig) or re.search(r"\((.*)\)$", sig)
    if not m:
        return "—"
    # Tauri 注入的参数在新架构不存在,隐去
    keep = [a for a in split_args(m.group(1))
            if not re.match(r"^_?(state|app|window|webview)\s*:", a)]
    return ", ".join(keep) if keep else "—"


def ret_of(sig):
    m = re.search(r"->\s*(.+)$", sig)
    return m.group(1).strip() if m else "()"


def build():
    sigs = signatures()
    desktop = registry(DESKTOP_REG)
    android = set(registry(ANDROID_REG))
    groups = {}
    for cmd in desktop:
        groups.setdefault(domain(cmd), []).append(cmd)

    esc = lambda t: t.replace("|", r"\|")
    summary = ["| 域 | 前缀 | 条数 | 安卓已有 |", "|---|---|--:|--:|"]
    body, total, and_total = [], 0, 0
    for dom in ORDER:
        cmds = sorted(groups.get(dom, []))
        added = sorted(ADDED.get(dom, []))
        if not cmds and not added:
            continue
        n_and = sum(1 for c in cmds if c in android)
        n = len(cmds) + len(added)
        summary.append(f"| {TITLES[dom]} | `{dom}.*` | {n} | {n_and} |")
        body.append(f"\n### {TITLES[dom]} · `{dom}.*` — {n} 条\n")
        body.append("| 移植 | 新命令名 | 现有名 | 参数 | 返回 | 安卓已注册 |")
        body.append("|:--:|---|---|---|---|:--:|")
        rows = []
        for c in cmds:
            sig = sigs.get(c, "")
            mark = "✅" if c in android else "❌"
            rows.append((new_name(c, dom),
                         f"| [ ] | `{new_name(c, dom)}` | `{c}` | "
                         f"`{esc(args_of(sig))}` | `{esc(ret_of(sig))}` | {mark} |"))
        # 新增的那批:「现有名」写「新增」,理由塞进行尾的 HTML 注释里(渲染时不显示)
        for name, a, r, why in added:
            rows.append((name,
                         f"| [ ] | `{name}` | **新增** | `{esc(a)}` | `{esc(r)}` | — |"
                         f" <!-- {why} -->"))
        for _, line in sorted(rows):
            body.append(line)
        total += n
        and_total += n_and
    summary.append(f"| **合计** | | **{total}** | **{and_total}** |")
    return "\n".join(summary) + "\n" + "\n".join(body) + "\n", total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只校验,不写文件")
    a = ap.parse_args()

    generated, total = build()
    doc = read(os.path.relpath(DOC, ROOT))
    if MARK_BEGIN not in doc or MARK_END not in doc:
        sys.exit(f"{DOC} 里找不到 {MARK_BEGIN} / {MARK_END} 标记")
    head, rest = doc.split(MARK_BEGIN, 1)
    _, tail = rest.split(MARK_END, 1)
    new_doc = head + MARK_BEGIN + "\n" + generated + MARK_END + tail

    if a.check:
        if new_doc != doc:
            print("COMMANDS.md 与注册表不一致。跑 `python scripts/gen-commands.py` 重新生成。",
                  file=sys.stderr)
            sys.exit(1)
        print(f"OK:{total} 条命令,COMMANDS.md 与注册表一致。")
        return
    with open(DOC, "w", encoding="utf-8", newline="\n") as f:
        f.write(new_doc)
    print(f"已写入 {DOC}:{total} 条命令。")


if __name__ == "__main__":
    main()
