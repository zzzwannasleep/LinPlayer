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

1. `COMMANDS.md` 的「返回」列给出返回类型名,在 `core/**.go` 里找同名 struct,
   收集它的 `json:"..."` 标签(嵌一层)。**查不到同名 struct 的一律放行** ——
   成功那行会把放行数和占比一起印出来,别把「✓ N 处」读成全覆盖。
2. Kotlin 侧从 `app.call("x.y")` 往下扫到**下一个 call / 下一个函数头 / 20 行**。
   窗口从**参数表结束之后**开始 —— 不然 `args("k" to o.str("k"))` 里那个取值
   会被当成读了响应。
3. 一处读取归给谁:
   - 认得出**接收者变量**(`r.obj().str("x")` 里的 `r`),而且这个名字在本函数里
     只被赋值过一次(赋值超过一次 = 被 lambda 遮蔽过,不可信)→ 归给绑它的那条命令;
   - 认不出 → 回落到「本函数调过的所有命令的字段并集」。宽,但不造假红。
4. 归属命令不发这个键 → 红。

## 这个方法抓不到什么

- **读串了对象、而同函数里另一条命令恰好发这个键。** 回落分支会放过它。
  想让它精确,把响应**绑到一个变量**上再读,别写成一长串链式。
- 解析被抽进另一个函数(参数是 JsonObject)。窗口跟不进去。
- 同名 struct 跨包合并成并集(成功行会 ⚠ 出来是哪几个)。
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
    """struct 名 -> (json 标签集合, 子 struct 名集合, 定义它的文件数)。

    ☠ 同名 struct **跨包合并**,字段集变成并集 —— 那是**弱化**不是等价:
      `Item` 在 download 和 emby 里各有一个,合起来什么字段名都放得进去。
      合并本身不会造假红,但它会让这条命令的对账形同虚设,所以下面要**报出来**。
    """
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
                tags, kids, where = out.setdefault(m.group(1), (set(), set(), set()))
                where.add(os.path.join(base, f))
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
    tags, kids = structs[name][0], structs[name][1]
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
# ☠ 新写一个取值器就要加进来。漏掉的表现是**闸门静默少数几处** ——
# 它照样打「✓ N 处」,只是那几处从来没被对过账(namedList 就这么漏过一次)。
# ☠ 键名必须连**驼峰**一起收。原来只认 `[a-z_0-9]`,于是 `.str("assetSize")`
# 这种写法整条从视野里消失 —— 闸门一声不吭。而核心层清一色蛇形,
# 驼峰恰恰是这条边界上最容易写出来的错(实测注入 hasUpdate / assetSize 都没红)。
READ = re.compile(
    r'\.(?:str|dbl|long|bool|boolOrNull|strList|namedList|arr|obj|get)\(\s*"([A-Za-z_0-9]+)"\s*\)')


def after_args(src, at):
    """跳过这条命令自己的参数表。

    ☠ 窗口从命令名后面开始的话,`args("anime_id" to anime.str("anime_id"))`
      里那个**取值**会被当成「读了响应的 anime_id」—— 而它读的是请求参数的来源。
      实测这一条就误伤了 danmaku.episodes。
    """
    depth = 0
    for k in range(at, min(at + 4000, len(src))):
        if src[k] == '(':
            depth += 1
        elif src[k] == ')':
            depth -= 1
            if depth <= 0:
                return k + 1
    return at


BLOCK_COMMENT = re.compile(r'/\*.*?\*/', re.S)
LINE_COMMENT = re.compile(r'//.*')   # 默认 . 不跨行,正好一行一条


def strip_comments(src):
    """注释里的代码片段不算读取,但**长度要原样保住**(行号和窗口都按下标算)。

    ☠ 一条「原来还并了一句 `o.str("kind")`」的注释会被当成真的读了 kind ——
      也就是说,**解释清楚自己删了什么反而会把闸门弄红**。
    """
    def blank(m):
        # 换行要留着,不然块注释一压平,后面所有行号全偏
        return ''.join(c if c == chr(10) else ' ' for c in m.group(0))
    for rx in (BLOCK_COMMENT, LINE_COMMENT):
        src = rx.sub(blank, src)
    return src


def windows(src):
    """每个调用点的 (起, 止, 命令名)。窗口 = 到下一个调用点 / 下一个函数头 / 20 行。"""
    hits = list(CALL.finditer(src))
    out = []
    for i, m in enumerate(hits):
        a = after_args(src, m.end())
        fn = FUNC.search(src, a)
        stop = min(([hits[i + 1].start()] if i + 1 < len(hits) else [])
                   + ([fn.start()] if fn else []) + [a + 20 * 90])
        out.append((a, max(a, stop), m.group(1)))
    return out


# 读取前面那一截接收者:`r.obj().` / `cur.` 这种。前面挨着 . ) ] } 的不算 ——
# 那说明它是链子中间的一环(`}.getOrNull().obj()`),不是一个变量。
RECV = re.compile(r'(?:^|[^\w.)\]}])(\w+)(?:\.\w+\(\s*\))*$')
# `xxx = ` 的左值,用来把一次调用的结果绑到变量名上
LVAL = re.compile(r'(\w+)\s*=\s*[^=\n]{0,120}$')
# `val cur = source` —— 一层别名就够用了,再多层这个仓库里没有
# 任何一次给这个名字赋值/绑参(含 lambda 形参 `{ x ->`)
ASSIGN_ANY = re.compile(r'(?:^|[^\w.])(\w+)\s*(?:=[^=]|->)')
ALIAS = re.compile(r'^\s*(?:val|var)\s+(\w+)\s*=\s*(\w+)\s*$', re.M)


def bindings(src, spans):
    """变量名 -> 它装的是哪条命令的返回值。

    ☠ 没有这一步的话,判据只能放宽到「整个函数里的命令并集」,而那会**放走真错**:
      实测把「线程数去 download.list 里读」注回去,并集里因为有 setThreads 的
      ThreadsReply 而照样绿 —— 那正是这一轮抓到的真 bug 之一。

    ☠ 键要带上**所在函数**。`o` / `r` 这种名字满文件都是,只按名字存的话
      一个函数里的 `val o = ...getUpdateSettings()` 会去认领另一个函数里的 `o`,
      当场报出一片假红(实测就这么炸了 4 条)。
    """
    out = {}
    for a, _, cmd in spans:
        m = LVAL.search(src[max(0, a - 200):a])
        if m:
            out[(fn_of(src, a), m.group(1))] = cmd
    for m in ALIAS.finditer(src):
        key = (fn_of(src, m.start()), m.group(2))
        if key in out:
            out.setdefault((key[0], m.group(1)), out[key])
    # ☠ 同名变量在一个函数里被赋值不止一次 = 被 lambda 遮蔽过,这条绑定不能信。
    #   实测 `p` 在详情页既是 prefs.getPrefs 的结果,又是 people 那个 lambda 的形参,
    #   不这么收的话它会拿 Prefs 的字段表去判 people 里的 id / name,报两条假红。
    for (fn, name) in list(out):
        n = 0
        for m in ASSIGN_ANY.finditer(src):
            if m.group(1) == name and fn_of(src, m.start()) == fn:
                n += 1
        if n != 1:
            del out[(fn, name)]
    return out


def fn_of(src, pos):
    """这一处落在哪个函数里(取它前面最近的一个函数头)。"""
    start = 0
    for m in FUNC.finditer(src):
        if m.start() > pos:
            break
        start = m.start()
    return start


def scope_fields(src, spans, structs, rets, pos):
    """这一处读取所在的**函数**里,调过的所有命令加起来能发的字段。

    ☠ 判据从「窗口里那一条命令」放宽到「同一个函数里的所有命令」,是因为
      **两条命令挨着写**是这个方法最常见的误伤:`source.currentSource` 在上一行、
      `account.listAccounts` 在下一行,十行之后读 `cur.str("server_name")`,
      窗口法会把它算到后一条头上并报红 —— 而它完全正确。

    放宽之后还剩下的判据是:**这个键,本函数里没有任何一条命令会发**。
    它抓不到「读串了对象」,但那一类的后果只是拿到 null;真正要抓的
    「核心层压根没有这个字段」照样一条不漏(实测 threads / state / modified
    / kind 四条真错在放宽后仍然全红)。
    """
    fn_start = 0
    for mm in FUNC.finditer(src):
        if mm.start() > pos:
            break
        fn_start = mm.start()
    fn_end = len(src)
    for mm in FUNC.finditer(src, pos):
        fn_end = mm.start()
        break
    out = set(LOCAL_KEYS)
    for a2, _, c2 in spans:
        if not (fn_start <= a2 < fn_end):
            continue
        t2 = rets.get(c2, '')
        if t2 not in OPAQUE and t2 in structs:
            out |= flatten(structs, t2)
    return out


def main():
    structs = go_struct_fields()
    rets = doc_return_types()
    bad = checked = waved = 0
    merged = set()

    for base, _, files in os.walk(UI):
        for f in sorted(files):
            if not f.endswith('.kt'):
                continue
            path = os.path.join(base, f)
            src = strip_comments(io.open(path, encoding='utf-8').read())
            spans = windows(src)
            binds = bindings(src, spans)
            for a, b, cmd in spans:
                ty = rets.get(cmd, '')
                if ty in OPAQUE or ty not in structs:
                    waved += 1
                    continue          # 类型查不到就不判,别造假红
                if len(structs[ty][2]) > 1:
                    merged.add(ty)
                checked += 1
                spans_cmd, spans_ty = cmd, ty
                for r in READ.finditer(src[a:b]):
                    k = r.group(1)
                    if k in LOCAL_KEYS:
                        continue
                    pos = a + r.start()
                    # 认得出接收者就**按它归属**,认不出才回落到函数作用域。
                    # 只回落的话「读串了对象」这一整类就放走了。
                    rv = RECV.search(src[max(0, pos - 120):pos])
                    own = binds.get((fn_of(src, pos), rv.group(1))) if rv else None
                    if own is not None:
                        t = rets.get(own, '')
                        ok = t not in OPAQUE and t in structs and k in flatten(structs, t)
                        if ok or k in LOCAL_KEYS:
                            continue
                        if t in OPAQUE or t not in structs:
                            continue        # 那条命令查不到类型,不判
                        cmd, ty = own, t
                    elif k in scope_fields(src, spans, structs, rets, pos):
                        continue
                    print('  ✗ %s:%d  %s 读 `%s`,但 %s 只发:%s'
                          % (os.path.relpath(path, ROOT),
                             src.count(chr(10), 0, pos) + 1, cmd, k, ty,
                             ', '.join(sorted(flatten(structs, ty)))))
                    bad += 1
                    cmd, ty = spans_cmd, spans_ty

    if not checked:
        print('一条都没查到 —— 正则或 COMMANDS.md 的「返回」列变了。判失败。')
        return 1
    if bad:
        print('\n%d 处响应字段名对不上。这类错**两边都不报错**,只会画成空页。' % bad)
        return 1
    # ☠ 覆盖率要**报出来**。只印「✓ N 处」的话它读起来像全覆盖,
    # 而放行的那些(返回裸 map、或者 COMMANDS.md 的返回类型在核心层查无此名)
    # 一个字段都没对过账 —— 那正是这类 bug 藏身的地方。
    print('✓ %d 处调用点的响应字段名,核心层都真的发(另有 %d 处放行:'
          '返回类型在核心层查不到同名 struct,占 %.0f%%)'
          % (checked, waved, 100.0 * waved / (checked + waved)))
    if merged:
        # 并集 = 弱化。不报的话「对上账了」这句话会比实际强
        print('  ⚠ 这几个类型名在多个包里都有,字段按并集算,对账被削弱:%s'
              % ', '.join(sorted(merged)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
