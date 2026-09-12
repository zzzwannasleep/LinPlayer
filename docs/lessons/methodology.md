# 工作方法与纪律

**这个领域最容易踩的坑:**
1. **新写的测试必须反向注入真 bug 看它先红**;假绿至少有六类(注入不忠实 / 环境不同 / 夹具不真实 / 语料选错 / 断言时序让 bug 没机会发生 / 门禁解析失败恒真)。
2. **长期红的门禁 = 没有门禁**,真信号会淹在噪音里。
3. **UI/数据类结论必须驱动真实运行的 App 拿**(WebView2 CDP),手写 probe.html 和子 agent 的汇报都不是证据。
4. **写「核层暂无 / 待接」之前必须 grep 命令表并读真实签名** —— 后端多半领先前端,这类注释会自我延续。
5. **用户点名的元素形态照留,只改他要改的属性**;说了「全做完我再测」就别中途丢半成品。

> 本文件共 **8** 条。每条都标了它的原记忆文件名与类型;正文按原样搬运,未做压缩或改写。

## 本页条目

- 负例要让它走到那一行 — 2026-09-05

- 测试必须先红 — `test-must-fail-first.md`
- 「待接」多半是谎 — `stale-waijie-lies.md`
- 挂真机 CDP 调试 — `drive-the-real-app-via-cdp.md`
- 本周看板定案+PC视觉自检 — `calendar-week-board-and-visual-selfcheck.md`
- 每次都要出可测 exe — `always-ship-testable-exe.md`
- 别过度解读需求 — `dont-over-interpret-requests.md`
- 做完所有再交付 — `finish-all-before-handoff.md`
- Git workflow — `git-workflow.md`
- 空数据源被判「通过」:门禁的第二类假绿 — 2026-09-04
- 按文件名猜用途 = 误删 — 2026-09-04
- 正则改注释:别碰「只有 // 的那一行」 — 2026-09-04

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

### 空数据源被判「通过」:门禁的第二类假绿

> 2026-09-04 · 类型:`project`

`check-bindings.sh` 第 4 关拿 Go 注册表和 `COMMANDS.md` 比,判「有没有野命令」:

```bash
ORPHAN="$(comm -23 "$TMP/go.txt" "$TMP/md.txt" | grep -v '^debug\.')"
[ -z "$ORPHAN" ] && echo "无野命令"      # ← 空集也走这里
```

libmpv 搬家后 cgo 链不上,`go run ./cmd/listcommands` **一条都没吐出来**。
`comm` 拿空集去比,结果当然是空 —— 门禁报**「全部通过」**。
**编译失败被伪装成了绿灯**,这比直接红危险得多。

日志里其实有线索(两行「找不到 mpv.lib」+ 一行 `Go:0 / 218 条已注册`),
但结论行写着「全部通过」,不逐行读就过去了。

**教训**:凡是「拿一个外部命令的输出去比对」的门禁,
**必须先判输出非空**,不许把空集当成「没有差异」。同类写法值得全仓 grep 一遍。

这和「测试必须先红」里的假绿五类是同一族,但**成因不同**:
那五类是断言本身写歪了,这一类是**数据源没了而断言恒真**。

修完按规矩做了反向注入:把 `go run ./cmd/listcommands` 换成 `true`(不输出),
门禁必须红 —— 实测确实红了,还原后恢复绿。

---

### 按文件名猜用途 = 误删

> 2026-09-04 · 类型:`feedback`

删 Rust 栈时清理 `scripts/`,**看名字**就把这几个删了:

| 文件 | 我以为 | 实际 |
|---|---|---|
| `pack-win.sh` | Tauri 的 Windows 打包 | **C# 端**打包(`dotnet publish apps/windows`) |
| `selfcheck-win.sh` | Tauri 真机自检 | **C# 端**自检 |
| `shot-window.ps1` | Tauri 截图 | 通用截图,被 `selfcheck-real.sh` 调 |
| `dump-command-names.py` | Rust 命令导出 | 从 **COMMANDS.md** 提命令名,门禁第 4 关在用 |
| `report-wiring.py` | Rust 接线报告 | 查 **C# 宿主**有没有调核心层命令 |

五个全是**当前技术栈**的工具,`-win` 只是「Windows 平台」的意思,不是「Tauri」。
删完门禁当场报 `can't open file 'dump-command-names.py'`。

**Why**:文件名是**给人读的标签**,不是依赖声明。同一个词在不同年代指不同东西。

**How to apply**:删任何一个文件之前,**读它的头几行**(这个仓库每个脚本开头都有说明),
再 `grep -rn '<文件名>' .` 看谁在调它。两步都是秒级的,而误删的代价是门禁静默失效。
这是 `CLAUDE.md` 常犯错误表里「复用一个函数前没读它」的同一个毛病,换了个场景。

---

### 正则改注释:别碰「只有 `//` 的那一行」

> 2026-09-04 · 类型:`feedback`

清理 `core/**` 里 57 处「移植自 `crates/…`」的溯源注释,顺手加了一条收尾规则:

```python
s = re.sub(r'^// *\n', '', s, flags=re.M)   # 想删「删空后剩下的空注释行」
```

结果它删掉了**全仓所有只含 `//` 的行** —— 那是 Go 文档注释的**段落分隔符**:

```go
// Handler 是一条命令的实现。
//                          ← 这一行被删了,上下两段粘成一坨
// 约定:
```

波及 **192 个文件、1147 行**,而 `go build` / `go test` 全绿 ——
**注释排版坏了编译器一声不吭**。是 `git diff --stat` 的数字(−1302 行,而目标只有 57 处)
不对劲才发现的。

**How to apply**:
- 改注释的正则,**作用域限定在刚被自己改过的那一段**,别开全文件 `re.M`
- 改完先看 `git diff --numstat` 的**量级**:删除行数远超预期条目数 = 规则误伤了
- 恢复靠 `difflib` 以 HEAD 为参照,只把「HEAD 有、当前没有、且 strip 后 == `//`」的行插回原位 ——
  比整个 checkout 精确,不会连带丢掉同一批文件里的其它改动

---

## 负例要让它走到那一行 — 2026-09-05

跨服选版本有一条硬规则:**匹配不出可信的就整台不给**(挑错 = 用户以为在换画质,
实际换了一部片,全程零报错)。为它写的负例是「那台服务器上没有这一集」。

反向注入「随便挑第一个」时,它**没有变红** —— 那条路在挑之前就 return 了
(候选池是空的),负例根本没走到被注入的那一行。

改成「那台搜回来的是**别的剧**」(候选池非空)之后,注入当场红。

> 「新测试必须先红」不只是走个流程 —— **注入点和断言点之间要真的有一条路**。
> 断言对了、注入也是真 bug,两者不在同一条路上照样是假绿。

## 跨域交叉引用

这些条目和本领域强相关,但正文放在别的文件里(一条经验只存一份正文):

- [正则筛选前端接线](ui-desktop.md) — 「核层有单测 + 文档写得对」≠ 功能能用
- [界面在撒谎:当前版本](ui-desktop.md) — 「功能没生效」的第二类根因:界面在撒谎
- [媒体库屏蔽](emby.md) — 一个功能有几套入口,就得每套都点一遍
- 本页「测试必须先红」新增四条变体(2026-08-31):**注入必须能编译**
  (同一件事在一次迁移里栽了四回,后来改成一律用 `if false && …` 而不是删代码);
  **用例可能在用错误的理由通过**;
  **两条护栏重叠时,注入要挑一个能把它们分开的形状**;
  **注入本身可能是个等价改写**(改完行为没变,自然不红)
- [发布版本单调性](build-release.md) — 静默失效、CI 全绿、只有用户那边不对
- [手机端动效重做](ui-mobile.md) — 自检环境和用户环境不一致 = 假绿

## 自检跑之前先认退出码 — 2026-09-05

`selfcheck-win.sh` 编译失败会 `exit 1` 并且说清楚「再往下跑起的是上一次那个 exe」。
但我这样调它:

```bash
LP_PICK=1 bash scripts/selfcheck-win.sh v1 ... >/dev/null 2>&1 ; grep "\[点选\]" build/app.log
```

`>/dev/null` 把那句警告吞了,`;` 让 grep 照跑 —— 读到的是**上一轮**的 `build/app.log`,
断言全绿,而这一轮根本没编译成功。险些拿它当交付报上去。

★ 规矩:**跑自检一律 `&& grep`,不用 `;`**;要么就别把 stderr 丢掉。
  「脚本有防呆」不等于「我调用的方式有防呆」。

顺带:那次编译失败是我用 `sed -i '/AllowUnsafeBlocks/d'` 删掉了 csproj 里**本来就有**的
一行(`CoreClient.cs` 的 `LibraryImport` 需要它)。前一步的 `grep ... || sed ...` 里
grep 已经找到了、sed 没执行,我却把 grep 的输出误读成「是我加的」。
**删配置之前先 `git diff` 看它是不是本来就在。**

## 测试的等待窗撞上被测代码的超时 — 2026-09-06

`TestLogin_探服务器名不能拖慢登录` 在 CI 上红,本机绿。日志:

```
--- FAIL: TestLogin_探服务器名不能拖慢登录 (5.04s)
    login_servername_test.go:137: 等不到 result —— 命令没被执行,或者事件队列没吐出来
```

两个 5 撞在一起:被测的探名超时 `serverNameTimeout = 5 * time.Second`,
而 helper `waitResult` 的等待窗也是 `time.Now().Add(5 * time.Second)`。
结果恰好在 5.0 秒**之后**才到,helper 先一步放弃 —— 本机 4.99 秒赢、CI 5.04 秒输。

★ 真正的代价不是 flaky,是**那条断言从来没生效过**:
  测试正文写着「登录超过 8 秒就算失败」,可 helper 5 秒就死了,
  这 8 秒的预算永远没机会成为失败点。红的理由和它想测的东西完全无关。

规矩:**helper 的等待窗必须长于被测路径里最长的那个超时**,不是「差不多够」。
撞成同一个数时,失败信息会指向 helper 而不是被测行为 —— 查错方向当场被带偏。
超时消息里带上 `time.Since(t0)`:一眼能看出是「没执行」还是「执行得太慢」。

验证方式:把 `serverNameTimeout` 临时改成 12 秒(仍小于新的 20 秒等待窗),
失败信息变成 `登录用了 12.005s —— 名字探测必须有自己的短超时` ——
这才证明那条 8 秒断言现在真的活着。

## 闸门只认蛇形键名,驼峰整条从视野里消失 — 2026-09-12

`check-android-args.py` / `check-android-fields.py` 两个闸门的键名正则都写着
`"([a-z_0-9]+)"`。往新写的更新设置面板里反向注入四条:

```
inj 字段名 auto_check      -> auto_checkx  : RED
inj 字段名 current_version -> current_ver  : RED
inj 字段名 has_update      -> hasUpdate    : GREEN   ← 没红
inj 字段名 asset_size      -> assetSize    : GREEN   ← 没红
```

原因不是判错,是**根本没匹配上**:`hasUpdate` 里有大写字母,
正则不认,那一处读取整条从闸门视野里消失,于是它照样打 ✓。

而核心层清一色蛇形、Kotlin 侧顺手写驼峰 —— 这恰恰是这条边界上
**最容易写出来的那个错**,闸门却偏偏对它免疫。改成 `[A-Za-z_0-9]` 之后
同样三条注入全红,而且没有引出任何假红。

★ 教训不是「正则写窄了」,是**闸门必须拿它最该抓的那种错去注入**。
  拿一个改错到 `auto_checkx` 的假 bug 去验,验的是「能不能发现改动」,
  不是「能不能发现真实世界里会发生的那种改动」。

## 闸门报「✓ N 处」时必须同时报放行了多少 — 2026-09-12

`check-android-fields.py` 一直打「✓ 41 处调用点的响应字段名,核心层都真的发」。
读起来像全覆盖。实测:

```
安卓调用点总数 151,真被对账 41,放行 110(73%)
```

放行的原因是 `COMMANDS.md` 的「返回」列在核心层查不到同名 struct ——
42 处是真的没有返回值(`()`),其余是**文档还留着 Rust 时代的类型名**
(`AccountInfo` 真名 `Info`、`ItemPage` 真名 `Page`)或者命令返回的是裸 `map`。
这两类闸门一律跳过,一个字段都没对过账。

做法:
- 返回值有结构的命令,核心层**给它一个具名 struct**(这一轮把
  `prefs.getUpdateSettings` / `system.checkUpdate` 换成 `UpdateSettings` / `CheckResult`,
  换完当场对上了账);
- 闸门的成功行**把放行数和百分比一起印出来**。
  一个报「✓ 45 处」的闸门和一个报「✓ 45 处,另有 110 处放行(71%)」的闸门,
  给人的信心应该差很远 —— 前者会让人停止追问。

同一轮还量到窗口法的一个**代价**:把弹窗从 `AboutPanel` 抽成顶层的 `UpdateFlow`
治好了两处假红(进度条的 `total`/`downloaded` 被算到 `system.checkUpdate` 头上),
但 `version`/`notes`/`asset_size` 三处读取也跟着跑出了视野 ——
它们现在读的是**当参数传进来的 JsonObject**,窗口法跟不进去。
假红和漏报在这个方法上是一对跷跷板,别把「闸门变绿了」当成「覆盖变好了」。

## 把文档里的返回类型名修对,当场挖出三个真 bug — 2026-09-12

`COMMANDS.md` 的「返回」列有一批还留着 Rust 时代的类型名(`AccountInfo` 真名
`Info`、`ItemPage` 真名 `Page`、`DownloadItem` 真名 `Item`……),字段名门禁
查不到同名 struct 就整条放行。把 16 行改对之后,闸门当场吐出 9 条红。
逐条查出处,**3 条是真的**:

- **`download.list` 读 `threads`** —— 它返回的是**任务数组**,而下载页写的是
  `r.obj().long("threads")`:拿数组当对象读,恒 null,于是并发档位
  **永远显示 2**,用户设成 4 也看不出来。真出处是 `download.setThreads`
  不传参数时的回读(桌面端一直这么读)。
- **`account.probeAccounts` 的连通状态点从上线起就是空的。** 界面挂 `onPartial`
  按 `server_id` / `state` 取值,而 (a) **整个核心层只有 core/system 一处在发
  partial**,这条命令一次都不发,回调永远不触发;(b) 真实字段是
  `server` / `ok` / `ms` / `error`。同一类错(聚合页、搜索页)此前已经栽过两次,
  注释都还留着 —— 而这两处没人回头查。
- **文件浏览页的「修改时间」永远不显示**:`source.Entry` 根本没有 `modified`。
  同一页还挂着一个同样永不触发的 `onPartial`(「边列边出」),靠的一直是兜底那条。

★ 结论不是「文档没维护」,是**一处对不上的文档会让一整类检查静默失效**。
  闸门跳过的东西不会喊,只有把它跳过的比例印出来才看得见:改之前
  151 个调用点里只有 41 个真被对过账(27%),现在是 70/153(46%)。

## 字段名门禁重做判定:先按接收者归属,认不出才放宽 — 2026-09-12

窗口法(「调用点往下 N 行的取值都算这条命令的」)在 9 条红里造了 4 条假红。
量了一遍:窗口从 30 行缩到 6 行几乎没用 —— 误伤的根不是窗口太长,是**两条命令
挨着写**。改成三步:

1. 窗口从**参数表结束之后**开始(`args("k" to o.str("k"))` 里的取值不算读响应);
2. 认得出**接收者变量**、且这个名字在本函数里只被赋值过一次,就归给绑它的那条命令;
3. 认不出才回落到「本函数所有命令的字段并集」。

三个坑是实测踩出来的,不是设计出来的:

- 只做第 3 步(函数并集)会**放走真错**:把「线程数去 download.list 里读」
  注回去照样绿,因为同函数里的 `setThreads` 恰好发 `threads`。
- 绑定表按名字存会串:`p` 在详情页既是 `prefs.getPrefs` 的结果,又是 people
  那个 lambda 的形参 —— 当场两条假红。所以键要带函数,而且**赋值超过一次就不信**。
- 注释里的代码片段会被当成真读取:写一句「原来还并了一句 `o.str("kind")`」
  就把闸门弄红了。剥注释时**换行必须留着**,否则后面所有行号全偏。

★ 顺带一条给写 UI 的:**把响应绑到一个变量上再读**,别写成一长串链式。
  链式认不出接收者,闸门只能回落到宽判据;绑了变量它才能精确归属 ——
  这不是风格偏好,是「以后改错了会不会被抓住」的区别。

## 探针的假卡片不读数据 = 整类 bug 走不到(2026-09-12)

`LP_RAILPROBE` 造的是真轨道、真虚拟化面板、真按钮,从头点到尾再点回来,
十几条断言全绿 —— 而用户那边的同一条轨道每帧都在抛 NRE。

差别只有一句:探针的造卡函数是 `_ => new Button()`,**把入参整个忽略了**。
于是「回收时模板被拿 null 再走一遍」这条路,它一次都没走过。
真实调用点读的是 `it.Name` / `it.EpisodeSubtitle`,在那条路上当场炸。

用户原话:「你的一千集的测试完全没有用」。他是对的。

规律:**探针里的替身必须和真货用同一批入参**。替身可以简单(Button 代替 Card),
但不能少读一个字段 —— 少读的那个字段就是没被覆盖的那条路。
改完之后同一个探针报「模板被拿 null 调了 525 次」,加上守卫后归 0。

配套的第二个坑:断言的**位置**。第一版把这条断言写在滚动之前,那会儿一次回收都还没发生,
报的是 0 —— 一条永远绿的断言。和 [[test-must-fail-first]] 里「断言的时序让 bug 没机会发生」
是同一类。

## 裸 map 就是一份没人对得了账的契约 — 2026-09-12

上一轮把 `COMMANDS.md` 的返回类型名修对之后,门禁的覆盖率是 70/153(46%),
放行的 83 处里绝大多数是**核心层直接 `return map[string]any{...}`** ——
文档那一列要么写 `()`,要么写一个 Rust 时代留下的、核心层里根本不存在的名字
(`PlaybackPrefs` `DataPaths` `MpvConf` `PrefetchSettings` 等 12 个,一个都查不到)。

给其中 17 条补上具名 struct(`DanmakuStyle` / `SubStyle` / `MpvConf` /
`ShaderLevel` / `ShaderApplied` / `PlaybackPrefs` / `PrefetchSettings` /
`Blocklist` / `BlocklistImported` / `DataPaths` / `CacheSize` / `PlayResult` /
`IconData` / `BackupExported` / `BackupImported` / `IconLibraryReply`),
覆盖率到 96/153(63%),当场挖出一条真 bug:

- **安卓设置页的「数据目录」永远停在「读取中…」**:
  `system.dataPaths` 发的是 `root`,而 `SettingsPage.kt` 读的是 `dataRoot`。
  桌面端(`MorePages.cs`)读的是 `root`,对的 —— 一处对一处错,
  正是「同一功能几套入口就得每套点一遍」那条的又一次。

两条实操结论:

- **`omitempty` 是契约的一部分,别用结构体字段去测它。** `subStyleOf` 原来靠
  「没设过就不往 map 里放 `scale_by_window`」,换成 struct 之后这条规则住在
  tag 里。测试必须 `json.Marshal` 之后再判,直接看 Go 字段的话 omitempty
  漏写了也测不出来。
- **同名 struct 跨包会被门禁并成并集,那是弱化。** `system.Info`(更新信息)
  和 `account.Info`(账号)撞名,导致账号那几条命令的字段表里混进
  `asset_url` `prerelease` 这种东西,什么都放得进去。改名 `UpdateInfo`,
  7 处引用。剩下 `Entry` `Item` `TestResult` 三组仍在撞,门禁会把它们印出来。

★ 还剩 57 处放行。其中一大半是返回 `()` 的写命令(没字段可对),
  另一部分卡在**窗口法**:`app.call` 往下 20 行之外的取值不归任何命令 ——
  安卓设置页那种「先 call 一次拿回 `prefs`,再往下铺五十行开关」的写法
  整片在门禁视野之外。想被覆盖,就把响应绑到一个**只赋值一次**的变量上。

## 注册期写配置 = 把用户的账号清空 — 2026-09-12

给「快捷方式体检」加了一句「把 exe 现在的位置记进配置」,放在
`commands.RegisterAll` 里起的后台 goroutine 上。跑一遍自检,设置页变成了登录闸口
—— `config.json` 里 `"accounts": null`。

根因:`lp_init` 的顺序是 **RegisterAll → paths.EnsureDirs → AdoptPreviousInstall
→ config.Load**。注册期 `config.Current()` 回的是 `defaults()`(一份空配置),
拿它 `Save()` 就是把盘上的账号覆盖掉,而且一声不吭。

两层修:

- 那句话挪到 `config.Load()` **之后**再做;
- `config` 加一个 `Ready()`,启动早期要写配置的代码先问它。
  光靠「记得放对位置」是守不住的 —— 下一个人不会读这段注释。

★ 这条和 `docs/lessons/build-release.md` 里「migrate_legacy 的 cfg!(test) 守卫
别摘」是同一类:**配置的写入时机比写入内容更容易出事**,而症状永远是
「我的服务器没了」,没有任何一行错误日志。

## 真机自检替我抓到了三个只有真跑才现形的东西 — 2026-09-12

同一轮里,`scripts/selfcheck-win.sh` 一次抓到三个编译期全绿的问题:

1. 账号被清空(上一条)。判据是自检跑完去 `grep '"accounts"' config.json`。
2. 截图变成 237×39 —— 拍到了 PowerShell 的控制台黑框(见 `ui-desktop.md`)。
3. `.lnk` 读回来是乱码。PowerShell 的 stdout 走**控制台代码页**(简体中文机器上
   是 GBK),中文路径读回来全错;而它照样是个字符串,后面 `os.Stat` 必然失败,
   程序会以为每个快捷方式都坏了。修法是脚本头上钉
   `[Console]::OutputEncoding = [Text.Encoding]::UTF8`。

★ 三个都不是「写错逻辑」,是**环境**。这类东西单测照不到、编译照不到、
  code review 也照不到 —— 只有真起进程、真读文件、真截屏才现形。

## 自检里 `FindControl` 必须在 UI 线程上(2026-09-13)

新写的 `SelfCheckTools` 起手是 `Task.Run` → `await Task.Delay` → `FindControl(...)`,
然后才进 `Dispatcher.UIThread.InvokeAsync`。**整段自检一个字都没打**,
`build/app.log` 是 0 字节 —— 看上去和「环境变量没传进去」一模一样,
我先去查了脚本的 env 透传、查了调用点位置,都是对的。

真因:后台线程上碰控件树会抛,而这一抛落在 `Task` 里**没人接**
(.NET 默认不因未观察的 Task 异常崩进程)。把三行 `FindControl` 挪进
`InvokeAsync` 里就好了。

★ 判据:自检**一行都不打**时,先怀疑它自己抛了,别先怀疑开关没生效 ——
  开关没生效的表现是「进程跑完没有那几行」,和这个长得一样,但排查方向完全相反。

## 反向注入注错了地方会「注了个寂寞」(2026-09-13)

给媒体库版式开关做注入,我先删掉了 `_cols = -1` 和「换一支新模板」两句,
自检**照样全绿**。那不是自检假绿 —— 是那两句本来就不承重
(`Relayout` 在列数变了时自己会调 `Rebuild`,而网格和列表的列数在任何正常窗宽下都不同)。

处理方式是**删掉它们**,不是留着再配一段说它们多重要 —— 注释写着「不这样会怎样」
而实际上不会怎样,是比没有注释更坏的东西。真正承重的那一句
(`_listMode = value` 之后必须重排)注掉之后当场红:
「✗ 换列表没生效:列表行 0 / 海报 18,按钮写「▦ 网格」」—— 正好是「文案变了、
网格没变」那个真 bug。

☠ 顺带纠正一条断言口径:换回网格时只判「有海报卡」是不够的,
**要判数目和起手一样** —— 列数没重算、一行只剩一张的退化下屏上仍然有卡,只是少一多半。

## 「exit status 1」不是诊断;WScript.Shell 只认 ANSI 代码页(2026-09-13)

桌面快捷方式那条集成测试在 CI 上红了**六个提交**。前四个日志里只有一句
`写不出快捷方式: exit status 1` —— `exec.Cmd.Output()` 把 stderr 放在
`ExitError.Stderr` 里,不 `errors.As` 取出来就等于扔了。

让它说话之后拿到的是:`$s.TargetPath = ...` 抛 `System.ArgumentException:
Value does not fall within the expected range`,保存路径里测试名那十个汉字变成了十个 `?`。

☠ 我第一反应是「值在环境变量里被代码页啃了」,把入参改成 Base64 —— **CI 照红**,
而且这回连「纯 ASCII」那组也红。两处误判:

- 「纯 ASCII」那组不纯:`t.TempDir()` 会把**测试名**(中文)拼进目录名。
- 真因在 **WScript.Shell 自己**:它内部走系统 ANSI 代码页。简体中文机器(CP936)上
  拿**韩文目录**一试就复现,抛的是同一个 ArgumentException;en-US 的 runner 上连中文都不行。
  传输层怎么编码都救不了。

修法:不再经过 PowerShell / WScript.Shell,Go 里直接调 `IShellLinkW` + `IPersistFile`
(纯 `syscall`,没加依赖),全程 UTF-16。顺带没了 powershell 黑框、每个 .lnk 起一个进程
(这条测试从约 4 秒到 0.24 秒)、没有控制台时 `[Console]::OutputEncoding` 会抛的那条坑。
英文 Windows 上把 LinPlayer 放在中文目录里的用户,原来建快捷方式也是坏的。

★ 判据:
- 门禁红了先看它**说了什么**;什么都没说,第一件事是让它说话,别猜 —— 猜一轮就是 6 分钟。
- **编码类 bug 要在本机复现,就找本机代码页编不出的字**(中文机器用韩文 / emoji),
  不要把 CI 当复现环境。
- 换成 IShellLinkW 之后 CI 又红一次,这回是**同一个文件、两种写法**:runner 的临时目录是
  8.3 短名(`RUNNER~1`),外壳读回 .lnk 时展开成长名(`runneradmin`),`EqualFold` 对不上。
  这不只是测试的事 —— `shortcutStatus` 的 `Ok` 也是这么比的。改成两边都 `GetLongPathName`
  再比(`samePath`)。本机用户目录没有短名,**要自己 `GetShortPathName` 造一个**才复现得出来。
- 集成测试按路径形状分组(纯 ASCII / 中文 / 系统代码页之外),而且临时目录**别带测试名**,
  否则分组形同虚设。
- 反向注入可以用 `go test -overlay` 换掉一个文件,**不动工作区** —— 注入期间别的构建
  (自检、打包)照样拿到干净的源码。
- **盯 CI 要盯出问题的那个 job,不是整个 run。** Windows job 两分半就红了,Android job
  还要再跑三四分钟,等整个 run 结束才报 = 白白晚报三四分钟(用户当场嫌慢)。
