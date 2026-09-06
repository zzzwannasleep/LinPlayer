#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""门禁:安卓 UI 从响应里读的字段名,核心层必须真的发。

    python scripts/check-android-fields.py

## 为什么要有它

`check-android-args.py` 守的是**请求参数名**。响应字段名同样是字符串,
同样两边都不报错 —— 而且症状更隐蔽:参数名错了核心层多半会报「缺少 X」,
响应字段名错了只是**取到 null**,页面画成空,看起来像「这个功能没数据」。

实测抓到的一批(2026-09-06 首次运行,三个整页失效):
    emby.aggregateOverview  读 server/name/items,核心层发 server_name/resume
    emby.rankingCategories  读 name,核心层发 label
    emby.rankingFetch       当成 Emby Item 解析,核心层发的是 ranking.Entry
    sync.bangumiCalendar    读按天分组的 items[].name_cn/air_time,
                            核心层发的是平铺数组 title/weekday/broadcast_at

## 怎么判

1. `COMMANDS.md` 的「返回」列给出返回类型名(`Result<Vec<SourceOverview>,_>`
   → `SourceOverview`)。
2. 在 `core/**.go` 里找这个类型的 struct,收集它的 `json:"..."` 标签。
3. Kotlin 侧:从 `app.call("x.y")` / `app.block("x.y")` 往下扫,
   到**下一个 call/block 为止**(最多 30 行),这段里的
   `.str("k")` / `.dbl("k")` / `.get("k")` … 都算「读了 k」。
4. 读了但核心层不发 → 红。

# ponytail: 窗口法有天花板 —— 解析被抽进另一个函数就扫不到。
# 真出现了再按调用图追;现在三个真 bug 全在调用点 25 行内。
"""
import io
import os
import re
import sys

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = os.path.join(ROOT, 'core')
UI = os.path.join(ROOT, 'apps', 'android', 'app', 'src', 'main', 'kotlin')
DOC = os.path.join(ROOT, 'docs', 'go-migration', 'COMMANDS.md')

# 返回类型不是 struct、或结构由核心层动态拼的,查不了,放行。
OPAQUE = {'', 'String', 'bool', 'i64', 'u64', 'f64', 'Value', 'any',
          'serde_json::Value', 'JsonValue', '—', '-'}

# 这些键由 UI 自己构造的 JSON 用(不是从核心层响应里读),白名单放行。
LOCAL_KEYS = {'url'}


# 一行字段:`People []Person `json:"people"``  ->  (Person, people)
FIELD = re.compile(r'^\s*\w+\s+[\[\]\*]*(?:\w+\.)?(\w+)[^`]*`[^`]*json:"([^",]+)', re.M)


def go_struct_fields():
    """struct 名 -> (json 标签集合, 子 struct 名集合)。同名 struct 合并(跨包重名极少)。"""
    out = {}
    st = re.compile(r'\btype\s+(\w+)\s+struct\s*\{')
    for base, _, files in os.walk(CORE):
        for f in files:
            if not f.endswith('.go') or f.endswith('_test.go'):
                continue
            src = io.open(os.path.join(base, f), encoding='utf-8', errors='ignore').read()
            for m in st.finditer(src):
                depth, i = 1, m.end()
                while i < len(src) and depth:
                    if src[i] == '{':
                        depth += 1
                    elif src[i] == '}':
                        depth -= 1
                    i += 1
                tags, kids = out.setdefault(m.group(1), (set(), set()))
                for ty, tag in FIELD.findall(src[m.end():i]):
                    tags.add(tag)
                    kids.add(ty)
    return out


def flatten(structs, name, depth=1, seen=None):
    """一个类型**连同它嵌的类型**能发出来的所有字段名。

    ★ 少了这一步会造**假红**:`ItemDetail.People []Person` 里的 `role`、
      `MediaVersion.Streams []StreamInfo` 里的 `width` / `height`,
      UI 读的都是嵌套对象的字段,而它们当然不在外层 struct 的标签里。
      假红比漏报更贵 —— 长期红的门禁等于没有门禁,真信号会淹在噪音里。

    ★ 只展开**一层**。展到两层会把 `ItemDetail.Children []Item` 底下那一整串
      也算进来,字段集大到几乎什么都放行 —— 那就从假红滑到漏报了。
    """
    if seen is None:
        seen = set()
    if name not in structs or name in seen or depth < 0:
        return set()
    seen.add(name)
    tags, kids = structs[name]
    out = set(tags)
    for k in kids:
        out |= flatten(structs, k, depth - 1, seen)
    return out


def doc_return_types():
    """命令名 -> 返回类型的裸名。"""
    out = {}
    row = re.compile(r'^\|[^|]*\|\s*`([a-z]+\.[A-Za-z]+)`\s*\|[^|]*\|[^|]*\|([^|]*)\|')
    for line in io.open(DOC, encoding='utf-8'):
        m = row.match(line.strip())
        if not m:
            continue
        t = m.group(2).strip().strip('`')
        # Result<Vec<X>, String> / Option<X> / Vec<a::b::X> -> X
        while True:
            inner = re.match(r'^\w+<(.+)>$', t)
            if not inner:
                break
            t = inner.group(1).split(',')[0].strip()
        out[m.group(1)] = t.split('::')[-1].strip()
    return out


CALL = re.compile(r'\b(?:call|block|callJson)\(\s*"([a-z]+\.[A-Za-z]+)"')
NL = chr(10)
FUNC = re.compile(NL + '(?:@Composable' + NL + ')?(?:private |internal )?fun ')
READ = re.compile(r'\.(?:str|dbl|long|bool|strList|get)\(\s*"([a-z_0-9]+)"\s*\)')


def main():
    structs = go_struct_fields()
    rets = doc_return_types()
    bad = checked = 0

    for base, _, files in os.walk(UI):
        for f in sorted(files):
            if not f.endswith('.kt'):
                continue
            path = os.path.join(base, f)
            src = io.open(path, encoding='utf-8').read()
            hits = list(CALL.finditer(src))
            for i, m in enumerate(hits):
                cmd = m.group(1)
                ty = rets.get(cmd, '')
                if ty in OPAQUE or ty not in structs:
                    continue          # 类型查不到就不判,别造假红
                fields = flatten(structs, ty)
                # 窗口右界:下一个调用点、下一个函数头、或 30 行,取最近的一个。
                # 少了「函数头」这一条,收藏页会把下面下载页的字段算到自己头上(假红)。
                nxt = [hits[i + 1].start()] if i + 1 < len(hits) else []
                fn = FUNC.search(src, m.end())
                if fn:
                    nxt.append(fn.start())
                stop = min(nxt + [m.end() + 30 * 90])
                checked += 1
                for k in set(READ.findall(src[m.end():stop])):
                    if k in fields or k in LOCAL_KEYS:
                        continue
                    line = src.count('\n', 0, m.start()) + 1
                    print('  ✗ %s:%d  %s 读 `%s`,但 %s 只发:%s'
                          % (os.path.relpath(path, ROOT), line, cmd, k, ty,
                             ', '.join(sorted(fields))))
                    bad += 1

    if not checked:
        print('一条都没查到 —— 正则或 COMMANDS.md 的「返回」列变了。判失败。')
        return 1
    if bad:
        print('\n%d 处响应字段名对不上。这类错**两边都不报错**,只会画成空页。' % bad)
        return 1
    print('✓ %d 处调用点的响应字段名,核心层都真的发' % checked)
    return 0


if __name__ == '__main__':
    sys.exit(main())
