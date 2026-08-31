# 工作方法与纪律

**这个领域最容易踩的坑:**
1. **新写的测试必须反向注入真 bug 看它先红**;假绿至少有六类(注入不忠实 / 环境不同 / 夹具不真实 / 语料选错 / 断言时序让 bug 没机会发生 / 门禁解析失败恒真)。
2. **长期红的门禁 = 没有门禁**,真信号会淹在噪音里。
3. **UI/数据类结论必须驱动真实运行的 App 拿**(WebView2 CDP),手写 probe.html 和子 agent 的汇报都不是证据。
4. **写「核层暂无 / 待接」之前必须 grep 命令表并读真实签名** —— 后端多半领先前端,这类注释会自我延续。
5. **用户点名的元素形态照留,只改他要改的属性**;说了「全做完我再测」就别中途丢半成品。

> 本文件共 **8** 条。每条都标了它的原记忆文件名与类型;正文按原样搬运,未做压缩或改写。

## 本页条目

- 测试必须先红 — `test-must-fail-first.md`
- 「待接」多半是谎 — `stale-waijie-lies.md`
- 挂真机 CDP 调试 — `drive-the-real-app-via-cdp.md`
- 本周看板定案+PC视觉自检 — `calendar-week-board-and-visual-selfcheck.md`
- 每次都要出可测 exe — `always-ship-testable-exe.md`
- 别过度解读需求 — `dont-over-interpret-requests.md`
- 做完所有再交付 — `finish-all-before-handoff.md`
- Git workflow — `git-workflow.md`

---

### 测试必须先红

> 原记忆:`test-must-fail-first.md` · 类型:`feedback`

**规矩:任何新写的测试/检查脚本,必须反向注入一次真实的 bug,亲眼看它变红,才算数。**

**Why**(2026-07-15 一次任务内栽了两回):
1. 给 `DownloadManager::forget`(只清记录不删文件)写测试,`forget()` 后立刻
   `assert!(file.exists())` → **注入 bug 后测试照样绿**。因为 `delete_files` 是
   `tokio::spawn` 出去的,立刻断言必然赢下竞态。**修法:断言前 sleep 300ms。**
   不 sleep 的话这条测试会带着「已覆盖」的假象入库,而文件照删。
2. 验 invoke 交叉核对脚本时,注入的是 `_probe("不存在的命令")`(把 invoke 起了别名),
   而脚本正则只认字面量 `invoke("…")` → **没抓到,但那是我注入得不对,不是脚本坏**。
   改成字面量注入后立刻红。

两次都是**注入不忠实**导致误判。教训不止「要写测试」,而是:
- **异步/spawn 的副作用**:断言前必须给它落地的时间,否则测的是竞态不是逻辑。
- **注入必须走真实代码路径**:起别名、绕过被测函数,证明不了任何事。
- 反向验证失败时,先怀疑**自己的注入**,再怀疑被测对象。

**How to apply**:先跑「注入 → 必须 FAIL」,再跑「还原 → 必须 PASS」,两次输出都贴出来。
只有 PASS 的那半是自嗨。

---

##### 变体:注入必须**能编译**,否则「没红」是假的(2026-08-31)

给 Go 核心的屏蔽名单做反向注入 —— 删掉「按 series_id 判」那条 case。
跑对账,`grep 不通过` 没有输出,我读成了「这条判据没在测东西」。

**实际上是注入版根本没编译过**(删掉 case 之后 `series` 变成「声明未使用」),
`go run` 直接失败,对账器一次都没跑起来。改成 `case false && series != "":`
(保持变量被用到)之后,立刻精确变红。

> **「注入之后没红」有两种可能:护栏没在测东西,或者注入压根没跑。**
> 先确认注入**跑起来了**(看退出码 / 看有没有编译错误),再下结论。
> 只 grep 失败关键词会把「构建失败」和「没有失败」混成一个样子。

##### 变体:用例可能在**用错误的理由**通过 —— 只有注入揭得出来(2026-08-31)

差分对账写了一条用例:「屏蔽一部剧,继续观看里它的分集也要消失」。绿的。

停用「按 series_id 判」那条判据之后,**它照样绿**。查下来:语料里屏蔽项的 `name`
和分集的 `SeriesName` 恰好相同,于是**「按剧名命中」那条判据先兜住了** ——
`series_id` 那条从头到尾没被执行过。

修法是把一条用例拆成两条,每条**只留一条判据能生效**:
- 判据 2:名字故意对不上,只有 `series_id` 能命中
- 判据 3:id 全对不上(模拟跨服),只有剧名能命中

停用哪条,就只有对应那条用例红。

> **一条覆盖多个判据的用例,等于没覆盖其中任何一个。**
> 判断依据不是「用例绿不绿」,是「逐条停用之后,红的是不是**只有**对应那一条」。

---

##### 变体:验证环境 ≠ 真实环境,同样等于没验证(2026-07-20,一天内两次)

注入是忠实的、断言也是对的,但**跑它的环境和真实环境不一样**,结论照样是假的:

1. **测试数据不真实**:量 TV 面板有没有裁字,harness 用「选项 1」这种占位符 —— 一行放得下,
   永远绿。真实数据是 80 字的文件名,换行后被 `height:64px` 切掉第二行。
   **连着两轮报「复现不出来」,根因就是这个。** 量 UI 必须喂**真实形态**的数据
   (长文件名/长音轨名/无断点串),不是占位符。
2. **Shell 选项不一致**:CI 的 `run:` 块里有 `set -euo pipefail`,我在交互式 bash 里验
   (没开)。`llvm-nm ... | grep -q X` 在 pipefail 下会**命中反而判失败** ——
   grep -q 命中即退出关掉管道,上游吃 SIGPIPE 非零退出。
   **修法:校验一律「先落盘再 grep」,别写 `| grep -q`。**
   验 shell 片段时用 `bash -c "set -euo pipefail; ..."` 复刻 CI 的开关。

**共同点**:两次的断言逻辑都没错,错在**跑它的条件**。所以自检要多问一句 ——
「我这次验证,和它在真实环境里跑的条件,哪里不一样?」

---

##### 变体:**夹具不真实** —— 注入了 bug 也照样绿(2026-07-21)

给 `VideoDiag::problem()` 写「纯音频不该报故障」这条,夹具是
`VideoDiag { has_video_track: false, ..ok }` —— 只翻了那一个字段,却留着
`vo:"gpu"`、`1920x1080`。于是把 `has_video_track` 那道守卫**整个删掉**,
函数走到后面的分支也返回 None,**测试照过**。等于什么都没守住。

改成真实的纯音频状态(`vo:""`、`0x0`、`hwdec:""`)后,注入立刻红。

**教训**:用 `..base` 展开构造反例时,**只翻一个字段往往构造不出真实的那个状态**。
问一句:「现实里处于这个状态时,其它字段会是什么?」不一致的夹具 = 假绿。

---

##### 变体:**语料选错**,静态契约测试的两种假绿(2026-07-22,一条测试内连栽两次)

写「壳喊的每个按键前端都得有人处理」这条 gate 时:

1. **把声明当成实现**:语料里放了 `focus.ts` —— 那是 `TvKey` 联合类型的**声明**,
   每个键名都在。删掉 PlayerPage 的 menu 处理器,测试照样绿。
   ⇒ 搜"有没有人处理"时,**必须把类型/常量声明文件排除在语料外**。
2. **substring 撞同名**:只搜 `"next"`,撞上按钮的 `icon="next"` —— 图标名被当成处理器。
   ⇒ 要匹配**处理形态**(`k === "next"`),不是匹配名字出现过。

两次都是"断言逻辑没错,喂给它的语料不对"。
另外:这类 gate 要配 **allowlist + 反向断言**(明知没做的列出来,并断言"做了就必须从名单删"),
否则名单会烂成永久豁免。

---

##### 变体:**断言的时序让 bug 没机会发生**(2026-07-26)

给「换片时清 `pending_danmaku`,上一集的弹幕不能漏到下一集」写测试:
挂弹幕 → 等它挂上 → 换片 → 断言没有弹幕轨。**注入 bug(删掉那句清理)照样绿。**

因为第一次挂载**已经成功**,队列早空了 —— 换片时压根没有"残留"可漏。
断言指向的那个状态在测试里从未出现过。

改成 `load(B) → attach(进队列) → 不等 FILE_LOADED 立刻 load(C)`,注入立刻红。

**教训**:构造反例时不只要问「字段对不对」(那是 [测试必须先红](methodology.md) 上面那条夹具变体),
还要问 **「我这条路径,真的会让那个 bug 有机会发生吗?」**
清理类/竞态类的断言尤其容易写成「测了个空集」。

---

##### 变体:**长期红的门禁 = 没有门禁**(2026-07-26)

`scripts/check-commands.sh`(每个 `#[tauri::command]` 都得注册)在 HEAD 上**一直是红的**:
它只扫 `lib.rs`(漏 `pluginmarket.rs` 等同级模块)、`grep -B1` 看不到 `#[tauri::command]`
和 `fn` 之间夹了注释的命令、末项没有尾逗号读不到。7 个假阳性 + 漏检 1 个。

后果不是"少了个检查",是**更糟**:真漏注册的那条会淹没在噪音里,而所有人都学会了无视它。
修好后 defined 从 241 涨到 249。

**How to apply**:接手/新增 gate 时先看它**当前是不是绿的**。红着的 gate 要么当场修,
要么当场删 —— 留着比没有更有害。修完照例两种失败模式各注入一次验红。

相关:[「待接」多半是谎](methodology.md)(同一类病:不报错的错才最贵)、
[PowerShell GBK/UTF-8 坑](build-release.md)(同样是「环境差异让绿变成假绿」)、
[安卓视频透出四层](android.md)

---

##### 第六类假绿:门禁**解析失败**而不是断言失败(2026-08-16)

本仓有一批「源码级契约测试」——把 `lib.rs` 用 `include_str!` 读进来,
按字面量找 `\n}\n` / `\nfn ` 这种 needle,再断言函数体里有没有某句话
(例:`every_play_command_reveals_the_video_window` 钉「每个起播命令都要 show_video」)。

**Windows 上 git 的 autocrlf 会把工作区源码整份变成 CRLF**(实测 apps/desktop/src/lib.rs
6789 个 CRLF、0 个裸 LF),于是 `include_str!` 拿到 CRLF,所有换行 needle 全部落空:
- 好一点的结局是当场 panic「找不到函数结尾」;
- 坏的结局是**静默匹配到 0 处,循环一次都不进,断言恒真** —— 那就是彻底的假绿。

表现极具迷惑性:**Linux CI 全绿、Windows CI 恒红**,而本地 `cargo check` 一声不吭
(它们是 test,check 根本不跑)。这两条门禁是加进来那天起就没绿过。

**教训三条**:
1. 任何**解析源码/文本**的测试,开头先 `.replace("\r\n", "\n")` 归一;
   不归一的话它在哪个平台是真门禁、哪个平台是摆设,全看 checkout 设置。
2. **「红」也要看红的方式**。解析失败的红和断言失败的红是两回事:前者说明
   门禁根本没跑到被测的东西上,离「换个写法就变恒真」只有一步。
3. **`cargo check` 不等于 `cargo test`**。我这轮只跑了 `cargo check -p app` 就以为桌面没问题,
   而这两条恒红的测试只有 `cargo test -p app --lib` 才照得到 —— 推之前**桌面壳也要跑 test**,
   别只跑 core 的。

修完必须逐条反向注入,确认它现在是冲着**真 bug** 报错的
(删掉 source_play 里的 show_video → 报「命令 source_play 把新文件塞给了 mpv,却没有 show_video」)。

---

### 「待接」多半是谎

> 原记忆:`stale-waijie-lies.md` · 类型:`project`

2026-07-15 照草稿补 PC UI 时发现:**后端不是落后于前端,是领先。**
197 个 Rust 命令里 **30 个前端一次没调过**,而 UI 上写着十几处
「核层暂无对应命令,待接」/「服务端不透传」/「后端待接」—— **绝大多数是谎**。

更讽刺的是,好几个命令的 Rust 文档注释里**就点名了它为哪个草稿标注而写**:
- `test_connection` → 「草稿页 06「测试连接」」
- `cf_proxy_status` → 「设置页展示"哪台服在走优选、钉的哪个 IP"」
- `config_export_qr` → 「**前端渲染成二维码**」(而前端写着「无内置二维码库」,
  可 `qrcode@1.5.4` 早在 package.json 里躺着,零 import)
- `get_cross_server_resume` → 「跨服务器续播开关(**设置页**)」
- `parse_deep_link` → 「前端**必须**弹确认框…用户点头后才 batch_add_servers」

**Why 这类谎最贵**:它不报错、不崩溃,只是让一个已经做好的子系统**永远不可达**
(弹幕智能匹配整套 auto_load/match/min_score 建好了没人调),
且下一个人读到注释就信了,不会去核实 —— 谎会自我延续。

**How to apply**:
- **写「核层没有 X」之前必须先跑**:
  `grep -B1 -A2 '#\[tauri::command\]' src-tauri/src/lib.rs | grep -oP '(?:async )?fn \K\w+' | sort`
  并**读那个 fn 的真实签名**(别猜参数名/形状)。
- **api.ts 是所有页面的共同根因**。类型漏字段会伪装成「服务端不透传」:
  `Item` 漏了 `played/genres/year/rating` → 就有人写下「只能本地排序」的假注释。
  `invoke<T>` 是**无校验断言**,tsc 抓不到形状不符 —— 必须对着 Rust struct 逐字段核。
- **交叉核对脚本**(已验证能抓到不存在的命令名):把 `src/` 里所有 `invoke("name")`
  与 lib.rs 的 `#[tauri::command]` + `generate_handler![]` 求差集。
  invoke 名打错只在运行时炸,tsc 永远绿。
- 真缺口就诚实留白,**别硬凑**(草稿自己立的规矩:「没有就不显示、不硬凑」)。
  弹个「待接」toast 的假菜单项比没有更坏:用户以为坏了,下一个人以为接过了。

相关:「pc-ui-react-build」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)、[对着桌面草稿做](ui-desktop.md)、[端范围已定](decisions.md)

---

### 挂真机 CDP 调试

> 原记忆:`drive-the-real-app-via-cdp.md` · 类型:`feedback`

**PC 端 UI/数据类 bug，必须驱动真实运行的 App 验证，不许拿手写的 probe.html 当证据。**

**Why:** 2026-07-19 我为"收藏排序点不动"连交两次假修复：第一次拿另一台服务器 curl 的结论签字，
第二次拿自己手写的合成 DOM 探针当绿灯。真机一挂上，两分钟就抓到真因。用户连吃两次空包。

**How to apply** —— 挂真实进程（WebView2 支持 CDP）：
```powershell
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9222"
Start-Process "D:\LinPlayer\native-poc\dist-portable\LinPlayer\LinPlayer.exe"
# http://127.0.0.1:9222/json/list 拿 webSocketDebuggerUrl
```
Node 24 自带全局 WebSocket，直接 `Runtime.evaluate` 就能在真页面里跑 JS：
- 读真实 DOM：`document.querySelector(".cbar").outerHTML`
- 判"点下去命中谁"：`document.elementFromPoint(r.left+r.width/2, r.top+r.height/2)`
- **绕开 UI 直调 Rust 命令**：`window.__TAURI_INTERNALS__.invoke("list_favorites", {...})`
  ← 这一步是分水岭：一次调用就切开"前端没送到" vs "后端/服务端不听话"

**配套**：Rust 侧临时 `poclog` 打 URL（token 走 header，URL 不含密钥，可安全落日志），
日志在 `dist-portable/LinPlayer/userdata/logs/app.log`。查完**必须删掉 TRACE**。

**红线**：凭据不落盘、不打印（往文件写 token 会被安全分类器直接拦，也确实不该写）；
要打真实端点就在**页面内** fetch，只把结果顺序带回来。

见 [每次都要出可测 exe](methodology.md)（出包）、[UHD fork 无视收藏 SortBy](emby.md)（这次抓到的真因）。

---

### 本周看板定案+PC视觉自检

> 原记忆:`calendar-week-board-and-visual-selfcheck.md` · 类型:`project`

**本周看板(WeekBoard)定案(2026-07-17,前后翻车5轮)**：窄列(clamp 272~336px)+「小缩略图左+文字右」对 2:3 竖版海报天生不合适。用户反复的核心批评=**标题被 `-webkit-line-clamp` 截成「…」= 显示不全**;对比本日(宽行900px,标题一句话全展开)就懂。定案:
- 标题 `.cal-bt1` **去掉行截断**(不要 -webkit-box/line-clamp),放开整段换行,标题一律完整,卡片随之变高(完整 > 等高)。加 `overflow-wrap:anywhere` 防长英文词横向溢出被切半个字母。
- 封面尺寸=**写死像素 width+height**(本周 76×108、本日 56×80,≈实测 0.70 比例),`object-fit:cover`。★★ **绝对不要用 aspect-ratio 或 height:100%**:即便 aspect-ratio 挂在容器上,用户真机(2026-07-17)仍报封面塌;写死像素是唯一在 WebView2 上稳的。实测两个窗宽下封面恒 76×108、与窗口完全脱钩。
- **液态玻璃整套已被用户否掉删除(2026-07-17:「别做液态玻璃了,不适合你,样式不适配,问题太多」)**:backdrop-filter/极光::before/流光::after/--cg-*变量/光晕投影全撤,回归实心 var(--panel)+var(--line)+var(--card-shadow)。别再往日历加 blur/glow。CSS 从 78KB 降到 73.8KB。

**★ 封面塌成横条的真凶(2026-07-17)=CSS 循环依赖 + 引擎差异**：`.cal-bth`/`.cal-lth` 容器无确定高度,却在 `<img>` 上同时写 `height:100%` + `aspect-ratio:2/3` → 「img 高取容器、容器高取 img」循环。**WebView2(用户真机)解析成塌陷 → 封面变一条横条;而我的无头 Edge(较新 Chromium)能猜对高度、渲染正常 → 自检骗过我**。教训:**同一份有歧义的 CSS,WebView2 和新版 Edge 渲染可能不同,无头 Edge 自检对这类循环依赖是瞎的**。修法=aspect-ratio 挂**容器**(确定盒子),img 只留 `object-fit`,不再声明 aspect-ratio/height:100%。★ Bangumi 封面实测比例=**0.707~0.711(≈5:7 竖版)**,不是 2:3;盒子设 `aspect-ratio:5/7` + contain 满幅无边不裁。curl 量图尺寸法:JPEG 找 0xFFC0~CF(除C4/C8/CC)段读 SOF 的 H/W。

**PC 视觉自检法(零安装,治「不先过眼」)**：这项目没装 playwright/puppeteer,但 Windows 自带 Edge 支持无头截图,直接拿来渲染真实 DOM+打包后的真 CSS,再用 Read 工具看图(★ 但注意上面:有歧义的 CSS 自检可能和 WebView2 不一致,尽量写确定性 CSS):
1. `npx vite build` 出 `dist/assets/index-*.css`(带哈希,每次变)。
2. 写静态 harness.html:`<link>` 那个真 CSS,`<body class="app-surface" data-theme="dark">`,里面**照 TSX 抄真实 class 层级**(cal-boardwrap>cal-board>cal-bcol>cal-bhd+cal-bbody>cal-brow...),封面用内联 SVG data URI(2:3),标题放超长的压测截断。
3. `"/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" --headless=new --disable-gpu --hide-scrollbars --window-size=W,H --screenshot=out.png "file:///C:/绝对/正斜杠/path.html"`。★ file URL 必须正斜杠绝对路径,别用 sed 拼(拼坏→ERR_TOO_MANY_REDIRECTS 错误页,31KB 小图=没渲染)。`--force-device-scale-factor=2` 可放大查字底裁切。
4. 深浅主题:改 `data-theme="light"` 再截一张,防「深底深字」。
参见 [「不秒加载」是加载结构不是动画](ui-desktop.md) [flex 挂错层 + auto-fill 陷阱](ui-desktop.md) [别过度解读需求](methodology.md)。

---

##### ★ TV 端也归这条管:「电视上的 bug」不等于「原生层的 bug」(2026-07-22)

用户报「播放页 OSD 上下栏根本不出现」。我连着两轮往 **Android 合成层**上猜(SurfaceView punch hole /
z-order / HWC overlay / 窗口 translucent),还派了 agent 去查 AOSP 源码 —— **全部白费**。
真相是纯 CSS:`.osd-bot` 的实测位置是 **y = −200**,整条底栏在屏幕上方 200px 外。
根因见 [transform 关键帧毁 fixed 定位](ui-desktop.md) 的 TV 变体。

**为什么会跑偏**:「有声音没画面」那次确实是原生层(windowBackground),于是我把
「播放页 + 看不见」直接映射到了同一个抽象层。**上一个 bug 在哪一层,不是这个 bug 在哪一层的证据。**

**规矩**:TV 前端的显示问题,**先用本条的无头 Edge 法把那一页渲染出来量 `getBoundingClientRect`**,
再考虑原生层。TV UI 就是 Chromium 里的 React,没有任何理由豁免视觉自检。
判据很硬:**元素在浏览器里量出来位置就是错的 ⇒ 前端有罪,和电视无关。**
量的时候要带上 `offsetParent` —— 定位参照错了(包含块被祖先的 transform/will-change 改掉)
光看 rect 只知道"位置不对",看 offsetParent 才知道"错在谁身上"。
把路由推到目标页最省事的办法:临时给初始 stack 加个 `window.__LP_PROBE_STACK` 后门,量完还原。

---

### 每次都要出可测 exe

> 原记忆:`always-ship-testable-exe.md` · 类型:`feedback`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

改完 PC 端（native-poc）**必须**跑 `npm run pack`，把可运行的 exe 路径给用户，
他要亲手测。只报 `tsc --noEmit` / `cargo check` / `vite build` 绿 = 没交付。

**Why:** 用户 2026-07-19 明确要求「做完改动之后要构建一个我能测试的 exe 给我，你要牢记」。
类型检查证明不了 UI 真跑得起来（见 [「黑屏」多半是 JS 崩了](ui-desktop.md)）。

**How to apply:**
- `cd native-poc && npm run pack`（约 1.5 分钟，会自动 tsc+vite+cargo release+zip）
- 测试路径：`native-poc/dist-portable/LinPlayer/LinPlayer.exe`（这个目录保留 userdata，登录不掉）
- 分发 zip：`native-poc/dist-portable/LinPlayer_<ver>_portable_x64.zip`
- 只想刷新测试目录不打包：`npm run pack:fast`
- 三目录分离的理由见 scripts/pack-portable.ps1 抬头注释（防止 token 打进 zip），别合并。
- 和 [做完所有再交付](methodology.md) 一起用：整体做完再一次出包，别中途丢半成品。

---

### 别过度解读需求

> 原记忆:`dont-over-interpret-requests.md` · 类型:`feedback`

用户让"季封面靠边、别留太多空白"，我却擅自把季封面改成了胶囊条 → 被批"我没和你说要改成胶囊吧，多此一举"，要求改回封面。

**Why:** 用户对 UI 有明确心智模型，需求里的每个名词（"季封面"）都是有意的；把它换成另一种控件（胶囊）是超出授权的改动，等于返工。

**How to apply:** 做视觉/交互改动时，严格保留用户点名的元素形态，只改他明确要改的属性（对齐/留白/位置）。要换控件类型/信息架构先问或先说明。只有当用户明确说"你平衡好/你决定"时才自由发挥。与 ponytail 的"最小改动"一致。

##### 线路地址:除线路管理外,全端只显示**名称**(2026-07-16 定,2026-07-19 我又破了一次)

用户原话(2026-07-16):「线路选择不要直接显示地址 显示名称就行」。
App.tsx 与 DetailPage 的线路面板早就照做了(代码里还留着引用这句话的注释),
但我 2026-07-19 做「多线程加载按服务器开」时,又在设置页行里写了
`${a.lines.length} 条线路 · ${a.server}` —— 线路数 + 完整地址全暴露,用户当场指出。

**规则**:除「服务器线路管理」窗口外,任何界面都不显示线路地址;需要标识就用
服务器名 / 线路名(`lineName()`)。写任何涉及服务器的列表前,先 grep 一遍现有线路面板的口径。

**同类**:说明文案也一样 —— 用户 2026-07-19「那么多描述 看的眼睛都花了」,
设置页每行说明砍到十几个字;`.hint` 段落一句话讲完。写长篇解释前先问:用户需要这段吗?

---

### 做完所有再交付

> 原记忆:`finish-all-before-handoff.md` · 类型:`feedback`

用户明确讲过「**先把所有 PC 端页面做完了我再去测试,现在测试半成品就是乱搞**」。我却一版版丢占位页/半成品让他装来体验,惹恼了他。

**Why:** 用户的时间宝贵;让他反复安装半成品、逐个发现缺漏,是把验证成本转嫁给他。他要的是"一整套做完再一次性验",不是增量试用。

**How to apply:** 当用户给出"先全部完成再交付/再测"这类**显式完成门槛**时,把它当硬约束——**在所有目标项都落地 + 构建验证通过前,不要交付中间态让他试用**。可以内部分批做(甚至并行 subagent),但对外只在整体闭环后交一次。中途只报进度、不催他测。跟 [别过度解读需求](methodology.md) 一样:用户怎么说就怎么执行,别自作主张改变交付节奏。

---

### Git workflow

> 原记忆:`git-workflow.md` · 类型:`feedback`

User works directly on `main` — commit and push straight to `main`, do NOT create feature branches or PRs (stated 2026-06-24, "以后也是" = applies going forward).

**Why:** Solo/personal workflow on this repo; branch+PR overhead is unwanted.

**How to apply:** When work is done and the user asks to commit/push (or has pre-authorized), commit on `main` and `git push origin main`. Still end commit messages with the Co-Authored-By trailer.

---

## 跨域交叉引用

这些条目和本领域强相关,但正文放在别的文件里(一条经验只存一份正文):

- [正则筛选前端接线](ui-desktop.md) — 「核层有单测 + 文档写得对」≠ 功能能用
- [界面在撒谎:当前版本](ui-desktop.md) — 「功能没生效」的第二类根因:界面在撒谎
- [媒体库屏蔽](emby.md) — 一个功能有几套入口,就得每套都点一遍
- 本页「测试必须先红」新增两条变体(2026-08-31):**注入必须能编译**;
  **用例可能在用错误的理由通过**
- [发布版本单调性](build-release.md) — 静默失效、CI 全绿、只有用户那边不对
- [手机端动效重做](ui-mobile.md) — 自检环境和用户环境不一致 = 假绿
