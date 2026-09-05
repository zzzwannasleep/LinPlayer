#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""门禁:安卓 UI 发出去的命令参数名,核心层必须真的读。

    python scripts/check-android-args.py

## 为什么要有它

命令名有 `check-bindings.sh` 的四方比对守着,**参数名没有任何东西守**。
而参数名同样是字符串:传 `view_id` 而核心层读的是 `parent_id`,
两边都不报错 —— 表现是「筛选设了没反应」「最新那条轨拉的是全库」
「退出播放进度不落地」。本仓库为这一类烧过好几个月
(正则筛选从上线起一次都没生效)。

实测抓到的一批(2026-09-06 首次运行):
    emby.listLatest      传 view_id,核心层读 parent_id
    emby.setFavorite     传 favorite,核心层读 fav
    emby.reportProgress  传 position_secs,核心层读 pos
    emby.rankingFetch    传 category,核心层读 category_id
    account.setActiveLine 传 url,核心层读 index

## 怎么判

- Go 侧:`bus.Register("x.y", ...)` / `list("x.y", ...)` 的函数体里
  出现过的 `a["k"]` / `str(a,"k")` / `xxxArg(a,"k")` 就算「读过 k」。
- Kotlin 侧:`call("x.y", args("k" to …, …))` 里的每个 k。
- UI 传了而 Go 从没读过 → 红。

**反过来不查**(Go 读了而 UI 没传):可选参数本来就可以不传。
"""
import io
import os
import re
import sys

# Windows 的控制台默认是 GBK,`✗` 和中文一起会 UnicodeEncodeError ——
# 门禁自己崩掉比不报警更坏(看起来像「跑过了」)。
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = os.path.join(ROOT, 'core')
UI = os.path.join(ROOT, 'apps', 'android', 'app', 'src', 'main', 'kotlin')

# 会话四件套由 AppState.call 统一注入,核心层在 sessionFrom 这个助手里读,
# 抓不到 —— 白名单放行。
SESSION = {'server', 'token', 'user_id', 'device_id'}

# 「读了一个参数」的各种写法。**漏一种就是一个假红**,而假红比没有门禁更坏
# —— 它会训练人无视这个门禁。
READ_PATTERNS = [
    re.compile(r'a(?:rgs)?\["([a-z_0-9]+)"\]'),
    # str / num / sub / strList / strPtr / intArg / int64Arg / boolArg …
    re.compile(r'\b\w+\(\s*a(?:rgs)?\s*,\s*"([a-z_0-9]+)"'),
    # 嵌套一层的:intArg(sub(a,"settings"), "threads", …)
    re.compile(r'\b\w+\(\s*s\s*,\s*"([a-z_0-9]+)"'),
]


def go_commands():
    """command -> 它读过的参数名集合。"""
    out = {}
    reg = re.compile(r'(?:bus\.Register|list)\("([a-z]+\.[A-Za-z]+)",\s*(\w+)?')
    for base, _, files in os.walk(CORE):
        for f in files:
            if not f.endswith('.go'):
                continue
            src = io.open(os.path.join(base, f), encoding='utf-8', errors='ignore').read()
            marks = [(m.start(), m.end(), m.group(1), m.group(2))
                     for m in reg.finditer(src)]
            for i, (_, end, name, handler) in enumerate(marks):
                stop = marks[i + 1][0] if i + 1 < len(marks) else len(src)
                body = src[end:stop]
                # `bus.Register("x", cmdFoo)` —— 处理函数在别处,跟过去一起读
                if handler and handler != 'func':
                    fm = re.search(r'\nfunc ' + re.escape(handler) + r'\(', src)
                    if fm:
                        nxt = src.find('\nfunc ', fm.end())
                        body += src[fm.end(): nxt if nxt > 0 else len(src)]
                keys = set()
                for p in READ_PATTERNS:
                    keys |= set(p.findall(body))
                out.setdefault(name, set()).update(keys)
    return out



CALL = re.compile(
    r'\b(?:call|block|callJson)\(\s*"([a-z]+\.[A-Za-z]+)"\s*,\s*args\((.*?)\)\s*\)',
    re.S)
PAIR = re.compile(r'"([a-z_0-9]+)"\s+to\b')


def ui_calls():
    """[(文件, 行号, command, [参数名…])]"""
    found = []
    for base, _, files in os.walk(UI):
        for f in files:
            if not f.endswith('.kt'):
                continue
            path = os.path.join(base, f)
            src = io.open(path, encoding='utf-8').read()
            for m in CALL.finditer(src):
                line = src.count('\n', 0, m.start()) + 1
                found.append((os.path.relpath(path, ROOT), line,
                              m.group(1), PAIR.findall(m.group(2))))
    return found


def main():
    go = go_commands()
    calls = ui_calls()
    if not calls:
        print('没扫到任何 UI 调用 —— 正则失效了。'
              '一个谁都拦不住的闸门比没有闸门更坏,所以判失败。')
        return 1

    bad = 0
    for path, line, cmd, keys in calls:
        known = go.get(cmd)
        if known is None:
            print('  ✗ %s:%d  %s 这条命令核心层没注册' % (path, line, cmd))
            bad += 1
            continue
        for k in keys:
            if k in SESSION or k in known:
                continue
            print('  ✗ %s:%d  %s 传了 `%s`,核心层从不读它(它读的是:%s)'
                  % (path, line, cmd, k, ', '.join(sorted(known)) or '(无)'))
            bad += 1

    if bad:
        print('\n%d 处参数名对不上。这类错**两边都不报错**,只会静默不生效。' % bad)
        return 1
    print('✓ %d 处 UI 调用的参数名,核心层都真的读' % len(calls))
    return 0


if __name__ == '__main__':
    sys.exit(main())
