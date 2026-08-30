# 播放器 / libmpv / 字幕 / 画质 / 播放窗口

**这个领域最容易踩的坑:**
1. **视频窗是独立顶层窗口,不是网页里的元素** —— 「有声音没画面」几乎都是窗口显隐/几何/层叠出错,不是 mpv 出错;可见性只能用 Win32 `EnumWindows` 找窗口类 `lpvid` 量,CDP 截不到。
2. **mpv 的命令是异步排队的**:`loadfile` 只排队就返回,紧跟的 `sub-add`/`seek` 必失败且常被 `let _ =` 吞掉;要等 `FILE_LOADED`。
3. **属性不可用 ≠ 属性等于 0**:`get_f64` 不看返回值就会把栈上的 `0.0` 当成位置交出去;`keep-open=yes` 下 `END_FILE` 永远不发,判播完只能读 `eof-reached`。
4. **改 mpv 选项前先确认它在这颗库里真的存在**(不同 build 会砍选项),写错是静默 no-op。
5. **画质档位的「不生效」多半不是档位表**:双显卡默认跑核显、软件纹理根本不跑 GLSL、放大类 shader 有尺寸门槛。

> 本文件共 **21** 条。每条都标了它的原记忆文件名与类型;正文按原样搬运,未做压缩或改写。

## 本页条目

- 关掉程序还有残留进程 — `app-exit-leaves-hidden-window.md`
- PC 播放页独立窗口 — `pc-standalone-player-window.md`
- 播放窗标题栏 + 换片黑屏 — `player-window-chrome-and-black-gap.md`
- wndproc 钩子重入爆栈 — `win-wndproc-hook-reentrancy.md`
- 全屏白边=几何没跟上 — `fullscreen-white-edge-geometry.md`
- 起播不露视频窗 — `source-play-never-showed-video.md`
- 桌面双声音/孤儿播放器 — `desktop-double-audio-orphan-player.md`
- Windows 无画无声"加载不出来" — `windows-egl-surface-no-video.md`
- 网盘/strm 播放两大坑 — `netdisk-strm-playback.md`
- 没加载完就点进度条 — `seek-before-file-loaded.md`
- 进度条三症状一条链 — `progress-bar-three-symptoms-one-chain.md`
- keep-open 下 EOF 检测 — `mpv-keepopen-eof-detection.md`
- loadfile 异步吞掉 sub-add — `mpv-loadfile-async-subadd.md`
- mpv 字幕属性实测 — `mpv-subtitle-property-truths.md`
- Android mpv subtitle fonts — `android-mpv-subtitle-fonts.md`
- mpv 发行版卫生 — `mpv-release-hygiene.md`
- 画质档位口径 — `anime4k-denoise-ladder.md`
- 双显卡必须钉独显 — `hybrid-gpu-must-pin-dgpu.md`
- 超分失效根因+toast统一位置 — `superres-and-toast.md`
- Dolby auto decode — `dolby-auto-decode.md`
- FFmpeg magicyuv CVE — `ffmpeg-magicyuv-cve.md`

---

### 关掉程序还有残留进程

> 原记忆:`app-exit-leaves-hidden-window.md` · 类型:`project`

2026-08-17 用户报「关闭程序后仍有残留进程」。**不是 mpv、不是子进程,是 LinPlayer.exe 自己**。

**根因**:`player_window_close` 是**藏起来不销毁**(重开 WebView2 要几百毫秒)。
主窗被关掉后,进程里还剩那个隐藏窗口 → tao 永远不发「最后一个窗口关闭」→
Tauri 默认退出路径根本不触发。表现:UI 全没了,进程 + mpv 还在后台,**一声不吭**。
所以只有「播过一次再关」才复现,没播过的直接关是好的。

**修法**(apps/desktop/src/lib.rs,setup 里主窗 `on_window_event`):
- 没在播 → `ah.exit(0)`;
- 在播(播放窗 `is_visible()`)→ `prevent_close` + 置 `QUIT_AFTER_PLAYER` + emit `lp://player-close`,
  走和 Alt+F4 关播放窗同一条正规退出(stopPlayback 落库),`player_window_close` 里 swap 到就 exit。
  直接 exit 会丢这一段进度(每 5s 才回传一次)。
- **兜底 3s 硬退**:播放窗前端崩了接不住时,关闭按钮按下去没反应比丢几秒进度糟得多。

**验证只能挂真 exe**:`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=…` 起
dist-portable 的包 → CDP invoke `player_window_open` 再 `player_window_close`(造出隐藏窗)
→ invoke `plugin:window|close {label:'main'}` → tasklist 看进程。反向注入(去掉 exit)确认过报红。
注意:关窗会当场断开那一页,`Runtime.evaluate` 永远不 resolve —— **只发不等**。
CI 里那份是源码级守门测试 `closing_the_main_window_must_exit_the_process`。

见 [PC 播放页独立窗口](player-mpv.md) [挂真机 CDP 调试](methodology.md)

---

### PC 播放页独立窗口

> 原记忆:`pc-standalone-player-window.md` · 类型:`project`

2026-08-01 落地。播放页不再是主窗里的一层,而是**独立 Tauri 窗口**。

**同包分流,不抽 bundle**:`index.html#player` 建第二个窗口,前端
`IS_PLAYER_WINDOW = location.hash === "#player"` 决定只渲染播放层。
播放层那一千多行(OSD/面板/弹幕/快捷键/seek 闩/进度回传/Trakt·Bangumi 收尾)
**一行没动** —— 抽出去等于重写全项目回归风险最高的一块,收益只是少几百 KB JS。

**必须一起做对的四件事:**
1. `apps/desktop/capabilities/default.json` 的 `"windows"` **必须加 `"player"`**。
   Tauri v2 按窗口 label 授权,漏了 = 播放窗每个 invoke 都失败,而窗口是透明的
   → **全黑且不报错**(同 [「黑屏」多半是 JS 崩了](ui-desktop.md) 的观感)。
2. 视频窗(mpv 独立顶层窗)要能**改挂**:`mpv::pin_overlay_below` 从「只装一次」
   改成可改挂,`PREV_PROC` 只有一个槽 —— 不先卸就装第二个,旧宿主的原 wndproc
   被永久覆盖,那个窗口从此不响应。几何来源和 wndproc 钩子**必须一起换**,
   只换一个 = 画面跟着 A 窗、层级跟着 B 窗。
3. 两个窗口都装几何同步回调,非宿主的那份必须靠 `mpv::is_overlay_host(hwnd)` 早退,
   否则拖动主窗会把播放窗里的画面拽回主窗矩形。
4. `CloseRequested`(Alt+F4)必须 `prevent_close()` + 广播给前端走正规退出:
   窗口一销毁 = 孤儿 mpv 还在出声 + 丢这段进度([桌面双声音/孤儿播放器](player-mpv.md))。

**待播条目**走核层中转(`player_window_open` 塞 → `player_take_pending` 取),
不用 URL 参数/localStorage:前者有长度和编码问题,后者是隐式耦合、时序靠猜。
窗口复用不销毁(重开 WebView2 要几百毫秒),换片靠 `lp://play-pending` 事件。

**几何照抄主窗、不 maximize**:无边框窗最大化在 Windows 上四周溢出 8px
([Win最大化控制栏消失](ui-desktop.md)),没必要为开个窗再踩一遍;照抄也让 OSD 的
布局假设一字不用改。

---

### 播放窗标题栏 + 换片黑屏

> 原记忆:`player-window-chrome-and-black-gap.md` · 类型:`project`

2026-08-02。用户两条:「单开的播放页要有标题栏,不然我拖动不了播放窗口,也点不到别的
地方的选项」+「播过一个视频再播第二个,缓冲出来之前的背景不是黑色,是之前的视频的画面」。

##### 1. 播放窗常驻标题栏 —— 视频窗必须让位,而且**两个几何入口都要减**

播放窗(见 [PC 播放页独立窗口](player-mpv.md))是无边框透明窗,原来能拖的只有 OSD 顶栏里
那条 `.p-drag`。OSD 静止 3 秒淡出、起播前整个 OSD 根本不渲染 —— 于是那几秒里窗口是一块
盖住主窗、拖不动也关不掉的黑板。修法是**不全屏就常驻** `<Titlebar/>`(和主窗同一个组件)。

标题栏不压画面:mpv 视频窗顶部让出 `--titlebar-h`(36 CSS px × scale_factor)。
★ **让位必须放在 mpv 层的一个进程级值里**(`crates/mpv` 的 `OVERLAY_TOP_INSET` +
`apply_top_inset`),不能在调用方把 y/h 算好再传:几何有**两个入口** ——
  · 宿主窗的 Tauri 事件 → `sync_overlay`
  · Alt-Tab / 点任务栏 / DPI 变化 → 只发 `WM_WINDOWPOSCHANGED`,由子类化钩子里的
    `align_to_host` 自己 GetClientRect 重算,**看不到调用方算过什么**
只在前者减的话:Alt-Tab 回来画面就被还原成满客户区、顶到标题栏底下,且只在特定操作后复现。
这是 [全屏白边=几何没跟上](player-mpv.md) 的镜像版:缺的从来不是计算,是触发。
`align_target` 已加护栏测试(摘掉让位当场红);0×0 的"最小化不动"守则必须**先于**让位跑。

##### 2. 「第二个视频露上一片画面」—— 我第一版诊断是错的

第一反应是"`ready` 从没被置回 false"。**不对**:`afterStart` 里一直有 `setReady(false)`。
真因是两件事叠加:
1. 那一句排在 `getPlaybackPrefs()` 和 `play()` 两个 await **后面**,而 play() 要走
   PlaybackInfo → 取流地址 → 起预取代理,慢服务器上是好几秒;
2. 这几秒里**上一片的状态轮询还在跑**(effect 依赖 `[playing]`,playing 还没换),
   它每 250ms 就把 `ready` 拍回 true —— 所以哪怕把复位提到 `playItem` 第一行也会被当场盖掉。
   我确实先只做了第 1 步,CDP 用例照样红,才把 `starting` 那面旗子逼出来。

现在:`playItem/playDownload/playSource` 开头 `starting.current = true; setReady(false)`,
`finally` 落旗(失败/提前 return 也要落,否则轮询被永久闭麦 = 黑屏再也撤不掉),
轮询里 `if (!starting.current && …) setReady(true)`。

顺带两条同类:
- 撤黑屏的判据从 `st.time > 0` 改成 `st.time > startPos + 0.05`。续播时核层一 loadfile
  就把位置记账成续播点,第一拍读到的就已经 >0 —— 旧判据在续播路径上等于"起播即放行"。
- 4s 兜底从"到点就放行"改成"到点**且不在等缓冲**才放行"。
- 核层补了换片前 `stop`(`crates/mpv` 的 `load_inner`):keep-open=yes 不卸载文件,
  画面冻在最后一帧;`stop` 让 mpv 自己画黑底。同时显式 `idle=yes`——libmpv 默认就是,
  但 idle=no 时 `stop` 会让核心退出 = "播第二个视频整个播放器没了"。

##### 3. 自检台:`ui/shared/player-chrome.check.mjs`

`npx vite build && node ui/shared/player-chrome.check.mjs`。真渲染 + 真点击,
六个反向注入逐个验证过报红(见文件头)。三个只有写这个台子才会撞上的坑:
- `Page.navigate` 到**完全相同**的 `index.html#player` 是**同文档**导航,
  addScriptToEvaluateOnNewDocument 不重跑、React 不重挂 → 第二次注入的待播条目进不去。
  必须带每次都变的 query。
- 假后端里 `plugin:window|is_fullscreen` 不能跟着"plugin: 就返回 1"—— 返回真值 1
  会让播放页以为在全屏,标题栏按设计本就不渲染,断言红得像功能坏了。
- `play` 必须**可延时**且在 resolve 时把 `__ST.time` 清回 0(核层 load_inner 就是这么做的)。
  秒回的 play() 把"露残帧"那个时间窗整个抹掉,测出来必然假绿。

---

### wndproc 钩子重入爆栈

> 原记忆:`win-wndproc-hook-reentrancy.md` · 类型:`project`

PC 端是「mpv 独立顶层窗 + 透明 Tauri 主窗」两层。对齐/层叠原来只挂在 Tauri 的
`Resized | Moved | Focused(true)` 三个事件上,而 **Alt-Tab、点任务栏、别的窗口插进来、
WebView2 自己动都不产生这三个事件** → 视频层「掉」到 UI 后面。

**正解:子类化主窗 HWND 接管 `WM_WINDOWPOSCHANGED`**(位置/尺寸/z 序任一变化都发),
一处钩子吃掉整类漏网,不用定时器轮询。`crates/mpv/src/lib.rs` 的 `mod overlay`。

##### ★ 三个必须记住的坑

1. **重入闸不能省 —— 少了就是当场爆栈。**
   回调里调 `SetWindowPos`/`ShowWindow` 摆视频窗 → 改变主窗相对 z 序 →
   Windows 又发一条 `WM_WINDOWPOSCHANGED` → 再进来 → 递归到栈溢出,
   **进程无声消失**:日志停在最后一行、没有 panic、Windows 事件日志里也查不到。
   实测症状 = 装上钩子后鼠标挪一下窗口 App 就没了。
   用 `AtomicBool::swap(true)` 做闸;另外状态已经对时**不要**调 `ShowWindow`(它也动 z 序)。
2. **取不到原 wndproc 就别装**。装了却把消息全喂 `DefWindowProcW` = 把 Tauri 的窗口过程
   整个换掉,窗口彻底不响应。降级回事件驱动远比这好。
3. 钩子里用的视频窗句柄可能已失效(Player 在 `Mutex<Option<Player>>` 里会被替换),
   先 `IsWindow` 再用。

##### 显隐必须是「与」

视频窗原来建出来就 `WS_VISIBLE`(X11 那半是建完就 `XMapWindow`)、每次 sync 又带
`SWP_SHOWWINDOW` → 从 App 启动起就一直在桌面上,**主窗一最小化就露出来**
(用户说的「反复最小化能看到后面在放」)。
收敛成 `WANT_VISIBLE(在播片) && 主窗没最小化/没隐藏`,三个调用点共用一个函数 ——
散着写必然出现「A 藏了 B 又亮出来」。

**X11 没有等价钩子**(要 `XSelectInput(StructureNotify)` 主窗 frame 再自己跑事件循环,
而那个 frame 会被 WM reparent),只能继续靠 Tauri 事件。这是已知能力差,不是忘了写。

##### 验法
`EnumWindows` 找窗口类 `lpvid` 查 `IsWindowVisible`/`IsIconic`,四态(未播放/播放中/
最小化/恢复)逐个对。注意 `FindWindowW(null,"LinPlayer")` 会找错窗口,**按窗口类找**。

录屏限制:两个独立顶层窗,窗口捕获只能抓一层 —— 要 UI+画面同时录只能用**显示器采集**。
真正的单窗口合成需要 WebView2 visual hosting(`CreateCoreWebView2CompositionController`),
**wry/Tauri v2 不暴露**,要做得 fork wry。

相关:[PC 窗口 chrome](ui-desktop.md)、[Win最大化控制栏消失](ui-desktop.md)、[弹幕交给 libass](danmaku-sync.md)

---

### 全屏白边=几何没跟上

> 原记忆:`fullscreen-white-edge-geometry.md` · 类型:`project`

2026-08-01。用户：「切换回播放器，白边不会消失，一直存在，**必须窗口化，再次全屏，才能消除**。其他播放器没这问题。」

**判据先于修法**：一个症状能被某个特定手势**稳定**治好，说明缺的不是**计算**，是**触发**。
「窗口化→再全屏」恰恰是会发 `WindowEvent::Resized` 的两步 —— 那就是事件那条路被激活了。

**根因**：mpv 视频窗是独立顶层窗口，它的几何**只**由 `apps/desktop` 的 `sync_video` 摆，
而那个挂在 Tauri 的 `Resized / Moved / Focused(true)` 三个事件上。
主窗几何还有别的路径会变，而那些路径**不产生**这三个事件：Alt-Tab 回来、点任务栏回来、
DPI 变化、别的全屏应用切走再切回。视频窗于是停在旧矩形上，主窗已铺满屏幕而它还是窗口大小，
四周露出的那一圈就是白边。

**修法**：几何跟着 z 序一起挪进 **`WM_WINDOWPOSCHANGED`**(位置/尺寸/层叠任一变化都发它)，
不用再枚举「还有哪些路径没覆盖到」。这和 [wndproc 钩子重入爆栈](player-mpv.md) 治 z 序漂移是同一个钩子、
同一条道理 —— 那次只挪了 z 序和显隐，几何留在了外面。

原来不在钩子里做几何的理由写在注释上：「这里拿不到 Tauri 的 inner_position」。
**那个理由不成立**：`GetClientRect` + `ClientToScreen` 量的就是同一个矩形。
实测逐像素相同 —— 窗口 `203,203 1195x729`(无边框窗口那圈不可见调整边框)，
客户区 `210,204 1180x720`，后者正是 Tauri 报的值。

两条必须留的守则(有单测 `align_target` 钉住)：
- **客户区 0×0(最小化)时不动** —— 照摆会把视频窗缩成 0×0 且再也长不回来。
- **已经对上了不动** —— 我们跑在消息回调里，`SetWindowPos` 即使不改任何东西也会再发一条。

Linux(X11)那条路没动，这个症状是 Windows 独有的。

**顺带**：驱动真 exe 复现时，`Input.dispatchMouseEvent` 的坐标是 **CSS px**(dpr=1.5 也不用换算，
实测事件落点与 `getBoundingClientRect` 中心一致)；但页面上可能盖着 sheet/更新横幅把点击吃掉，
先用 `elementFromPoint` 确认命中的是谁。CDP 挂法见 [挂真机 CDP 调试](methodology.md)。

---

### 起播不露视频窗

> 原记忆:`source-play-never-showed-video.md` · 类型:`project`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。

2026-08-16 用户报「VOD 插件播放不显示画面窗口」。**两个独立的真因叠在一起**,
各自都足以让画面消失,而且**两个都是编译绿、单测绿、类型也绿**。

##### ① 核层:`source_play` 从来没露过视频窗

桌面的视频窗是**独立顶层窗口(窗口类 `lpvid`)**,平时**藏着**(常驻可见的话主窗一
最小化就是一块黑留在桌面)。起播那一刻由 `show_video(&state, true)` 露出来。

`show_video` 是 4f72060c 引入的,当时给 `play`(Emby)和 `play_local`(下载文件)
都补上了,**唯独漏了 `source_play`** —— 而网盘 / 资源站插件 / Stremio / 飞牛
**全走那一条**。表现:mpv 在放、有声音、进度也在走,画面窗口从头到尾没露面。
没有任何报错(那是个 Win32 窗口的显隐,没返回值可断言)。

同 [媒体库屏蔽](emby.md) 那条教训的反面:**加一个横切开关,必须 grep 一遍所有调用者**。

##### ② 前端:`VodPage` 自己 invoke,绕开了播放窗

桌面起播 ≠ invoke 一次 `source_play`。真正的入口是 App.tsx 的 `playSource`:
它先 `playerWindowOpen` 把**独立播放窗**拉起来(视频窗焊在它背面、OSD 也在那个窗里),
播放窗自取待播条目后才在**那个窗里**调 source_play。

`NetdiskPage` 拿的是 `onPlay`,`SourceBrowsePage` 却**只把 onPlay 传给了 NetdiskPage**,
VodPage 那一支漏了 → 它只好自己 `playEpisode()` → 直接 invoke。播放窗根本没开。

手机端是同一根因的另一半:那边画面走的是 webview **底下**那层 SurfaceView,
页面起播完只 `back()`、**从不导航到播放页** → 不透明的目录页/详情卡盖着画面,
同样只剩声音。**网盘页和 VOD 页都是这样**(TV 端反而是对的:play 完 `go({page:"player"})`)。

修法:`playEpisode` 改成只造壳的 `episodeEntry`,页面一律走各端 App 的起播函数
(desktop 的 `playSource` prop / mobile 的 `ctx.playSource`)。

##### 钉住它的两条测试(apps/desktop/src/lib.rs `api_contract_tests`)

- `every_play_command_reveals_the_video_window` —— 扫自己的源码,凡是把新文件塞给 mpv
  的命令必须有 `show_video(&state, true)`;唯一豁免 `source_watchdog`(302 重签是播放中换链,
  窗早开着)写在测试里的白名单。**needle 用 `concat!` 拼**,否则 include_str! 会匹配到测试自己。
- `source_pages_start_playback_through_the_app` —— 桌面两个源页面都必须拿 onPlay、
  SourceBrowsePage 两个标签都必须传 onPlay;手机端 `playSource` 必须 `push({page:"player"})`、
  两个页面不许出现 `sourcePlay(`。**手机端的断言故意放在桌面这套测试里**:安卓那个 crate
  在本机连编都要 NDK,放那边等于没有门禁。
- 两条都反向注入真 bug 验过会红(删 show_video / 摘掉 onPlay / 摘掉 push)。

##### 真机验证(脚本在 scratchpad,没进仓库——它依赖用户自己的账号和线上站点)

挂打包好的 exe + CDP(`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=`),
用 `__TAURI_INTERNALS__.invoke` 走真链路;**视频窗可见性从进程外用 PowerShell 量**:
`EnumWindows` 找窗口类 `lpvid` → `IsWindowVisible` + `GetWindowRect`。
CDP 截图只截得到 webview,截不到那个独立窗口 —— 这类问题只能用 Win32 量。
实测:起播前 visible=false(基线)→ 起播后 visible=true 且矩形跟着播放窗走。

**顺带量到的一件事,不是我们的 bug**:采集站甲 那条线路起播要 ~17s。curl 实测它的
子播放列表(2777s 的片、2s 一段 ≈1400 条)**30s 都下不完**,是站点慢,不是客户端。

相关:[PC 播放页独立窗口](player-mpv.md)、[播放窗标题栏 + 换片黑屏](player-mpv.md)、
[VOD 资源站插件](plugins.md)、[挂真机 CDP 调试](methodology.md)、[测试必须先红](methodology.md)、
[媒体库屏蔽](emby.md)

---

### 桌面双声音/孤儿播放器

> 原记忆:`desktop-double-audio-orphan-player.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

**症状**：桌面播放「有两个声音」，暂停后声音还在、再播放又叠一个（同一音轨回声）。

**根因（日志铁证）**：`userdata/.../logs/linplayer-*.log` 里同一会话出现**两次**
`开始初始化 media_kit 内核`（相隔 ~62ms、中间无任何 dispose），随后两次「初始化完成」——
即**两个 VideoPlayerService/两个 mpv 实例同时存活**，各自解同一文件 → 两份音轨。暂停只作用于
UI 绑定的那个，另一个成孤儿继续出声。触发=**播放页被重复导航打开**（`context.push('/player/:id')`
手抖双击/事件重发）。media_kit `Player.open()` 自身会先 `stop()` 再 loadfile（real.dart:173），
所以**不是** reload 叠流；就是两个独立 Player。

**修法（都在桌面）**：
1. 导航去重：`lib/desktop/routes/player_navigation.dart` 的 `pushPlayerRoute(context,location)`，
   1s 内对**同一 location** 的重复 push 直接忽略。已替换 detail 头部播放按钮/菜单、下载页的
   `context.push('/player/...')`；换集用 `context.replace` 不叠、不动。
2. 孤儿守卫：`MpvPlayerAdapter` 加 `_adapterDisposed`——initialize 收尾前若已被 dispose 顶替，
   销掉刚建的 Player 再退，堵住「后台空跑出声」的孤儿(代码本就在 video_player_service.dart:662
   注释里记过这个 race)。

**排查纪律**：dev/release 版日志在 **exe 同目录 `userdata/app_support/logs`（或回退 `userdata/temp/linplayer_logs`）**，
不在 `%APPDATA%\Linplayer`。数 `开始初始化 media_kit` 次数 vs `dispose`，多出来的就是孤儿。

**同批**：Windows hwdec 默认从 `auto-copy` 改 **`d3d11va`(零拷贝)**——硬件纹理下 auto-copy 每帧
GPU→内存拷回引起卡/闪，d3d11va 与 ANGLE 同 D3D11 后端直连、消卡消闪(用户实测)。日志里
`dxva2-egl Failed to create EGL surface` 是**无害红鲱鱼**(见 [Windows 无画无声"加载不出来"](player-mpv.md))，
别被它带偏。默认 `_zeroCopyHwdec=Platform.isWindows`，更多菜单可切回 auto-copy 兜底。见 [超分失效根因+toast统一位置](player-mpv.md)。

---

### Windows 无画无声"加载不出来"

> 原记忆:`windows-egl-surface-no-video.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

**真正根因(commit 23e8c1e,ffprobe 实测锤死)**:桌面 mpv「所有视频加载不出来、无画无声」
是 `stream-lavf-o` 里的 **`multiple_requests=1`**(HTTP keep-alive 复用连接发 Range,
8ffac6f「连接保温」引入)。对部分 Emby/源,libavformat 复用连接做 seek/Range 会灾难性变慢。
ffprobe 打开同一网络 MKV 实测:**默认 1.6s;+multiple_requests=1 → 3m35s(×130);
+reconnect 系列 → 1.9s(无害)**。表现:mpv 读 MKV 尾部 Cues 索引(seek 到文件尾)卡十几秒
→无帧→无画无声。修法:`mpv_player_adapter.dart` initialize 的 stream-lavf-o **去掉
multiple_requests=1,保留 reconnect 系列**。

**红鲱鱼警告(我在这上面浪费了 5 轮)**:日志里
`mpv[libmpv_render/dxva2-egl] Failed to create EGL surface` **是无害的**——mpv 在 GL 初始化
时逐个探测 hwdec interop(d3d11va/d3d11-egl/dxva2-egl/cuda/vaapi...)全失败中的一条。
**判据**:同日志有 `GL_RENDERER='ANGLE (Intel..., D3D11)'` → 硬件渲染上下文其实正常。
别再:①当成 media_kit 渲染 surface 失败去关硬件加速(软件渲染封顶 1080p,4K 不可接受);
②当成 hwdec 问题反复改 hwdec。这些都试过,全错。

**排查方法论(有效,下次照做)**:
1. mpv 卡在哪 → 提日志到 `MPVLogLevel.debug`(Windows 平时 warn),看 GL_RENDERER + 卡住前最后一条(本次是 "Seeking to <大偏移> to read header element 0x1c53bb6b"=MKV Cues)。
2. 网络还是我们的设置 → **curl/ffprobe 直接打同一 URL**:curl 分段 range 都 <2s → 网络/服务器没问题;`ffprobe -i URL` 默认 1.6s vs 加我们的 `stream-lavf-o` 选项 → 一眼看出是自家设置。
3. 逐项 bisect libav 选项(ffprobe -multiple_requests 1 / -reconnect 1 单独测)锁定真凶。

保留的对的改动:hwdec 桌面用 copy-back(Win `auto-copy`/mac `videotoolbox-copy`,避 interop 崩溃,见 「macos-no-video-hwdec」(该条不在本库,多为 Flutter 时代的旧记忆,已作废));_applyStartupSeek 的 _player 空指针守卫。

---

### 网盘/strm 播放两大坑

> 原记忆:`netdisk-strm-playback.md` · 类型:`project`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

针对 strm/网盘 后端(实测 `<某 strm/115 型 Emby 服>`「稳健115」= Emby 4.9.5.0 兼容,strm 指向 115 CDN)的两个非显然坑,均已修(commit 4d5837c + player_screen_panels 回退):

**① strm 选不了字幕/音频 —— 服务器空流,不是我们的 bug。**
strm 条目的 `PlaybackInfo` 返回 **0 视频/0 音频/0 字幕流**(服务器不 ffprobe 远程文件)。而各端字幕/音频面板原本只从 `mediaSource.mediaStreams` 建选择列表 → 空 → 没法选。**但 mpv 播放后自己解封装读到了真实轨道**(`playerService.tracksInfo`)。修:`player_screen_panels.dart` 音频/字幕面板在 Emby 流为空时**回退用 mpv 真轨**(含"关闭"项),按 mpv 轨道 id 直接 `selectAudioTrack/selectSubtitleTrack`。对普通文件(流非空)无影响。诊断:`curl -sX POST $BASE/Items/$ID/PlaybackInfo` 数 `"Type":"Audio"/"Subtitle"` 条数=0 即确认。

**② 大电影卡 = 单连接吞吐被打死,不是解码/磁盘。**
strm 播放 URL 是 `/Videos/{id}/stream` **302 跳转**到 CDN(如 `<115 CDN 域名>`)。curl 实测:**单条流式 GET(跟随302一次)=28-38MB/s,而分段 Range(每段重打 Emby URL→各自302+重连+TLS)=1.8MB/s(×15慢)**。真凶是 `stream-lavf-o` 的 **`multiple_requests=1`**(诱发大量分段 Range)。桌面 `mpv_player_adapter.dart` 早已删除(注释:同 MKV ffprobe 默认1.6s→加该参数3m35s ×130),**但 Android 原生 `MpvPlayerPlugin.kt` 漏同步一直留着** → 网盘大电影只有 ~10MB/s、缓冲跟不上。修:Android stream-lavf-o 删掉 `multiple_requests=1`,只留 reconnect 系列。

**教训**:①"选了轨不显示/没轨可选"先分清是 libass 字体(见 [Android mpv subtitle fonts](player-mpv.md))还是**服务器空流**(strm/网盘)——后者要回退播放器真轨。②排吞吐先 `curl -sL -w '%{speed_download}'` 直连测 CDN 能到多少,再看是不是我们客户端配置卡的(cache-on-disk 在**内部存储**不是瓶颈,别误判成磁盘慢)。③**Android 原生 mpv 配置(MpvPlayerPlugin.kt)与桌面(mpv_player_adapter.dart)是两套,桌面的网络/字幕修复容易漏同步到 Android**——排 Android 播放问题先对照桌面同名设置。相关:「unified-ua-and-prefs」(该条不在本库,多为 Flutter 时代的旧记忆,已作废) [Multi-thread loading prefetch proxy](network.md)

---

### 没加载完就点进度条

> 原记忆:`seek-before-file-loaded.md` · 类型:`project`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。

2026-07-27 修。用户报「视频还没缓冲到能播时点进度条跳转,之后进度条跟着缓冲进度走、
画面不变,后续调进度稳定复现」。**三个独立 bug 叠在一起**,单看每个都不像 bug。

##### 1. 量程塌成 1 秒(直接根因,三端)

核层每次 `loadfile` 都把 duration 记账清回 0,mpv 要到 FILE_LOADED 才报得出来。
**真服(<用户主力 Emby 服(UHD fork)>)实测这个窗口 6~7 秒。** 窗口内:

- PC `max={Math.max(1, status.duration)}` → max=**1**
- 手机 `max={dur || 1}` → max=**1**

用户点在条中间 → 目标 **0.5 秒**,不是片长的一半。核层照单全收地跳回片头 =「画面不变」。

同一个 `|| 0` 还有**三处克隆**,是相对跳转的上界:`Math.min(duration || 0, time+d)` ——
duration=0 时 `Math.min(0, …)` 把目标一律夹成 0,加载期快进反而跳回片头。
位置:mobile PlayerPage 的 jump、mobile Gestures.ts 横滑、tv PlayerPage 的 jump。
全改 `|| Infinity`(封不了顶就交给 mpv 夹)。

修法:PC 轮询里 `duration>0 ? st : {...st, duration: 上一次的}`(起播时已用 Emby
runtime 播下正确时长);**statusRef 必须和 state 一起写**(putStatus),只写 state
的话兜底会拿到上一集的时长。手机兜底到 `item.runtime_secs`。两端再补 `disabled`——
量程真不可信时(本地文件/网盘,runtime 未知)就不该能点。

##### 2. FILE_LOADED 之前的 seek 被静默丢掉(核层)

mpv 那会儿没有文件可跳,`seek` 只拿回命令错误;而 seek 闩在发命令**之前**就设上了
(那是 [进度条三症状一条链](player-mpv.md) 故意的设计),于是条压着用户点的
位置 2.5s,再弹回 `start=` 的续播点。

**解法和外挂字幕是同一个**(见 `add_subtitle`):没开好就排进 `SubState.pending_seek`,
FILE_LOADED 由事件线程补发。两个细节缺一不可:
- 补发时**重置闩的计时起点**,否则加载花掉的几秒让它一进来就判超时;
- 命令真失败时把闩清掉(不清 = 条钉在一个到不了的位置上 2.5s)。

顺带:`seek_abs` 送的是 `secs` 而闩记的是 `max(0.0)` 后的值,负数两边对不上。

##### 3. 缓冲条从 0 画起,右边缘永远压在播放头上(PC/TV)

`demuxer-cache-time` 是缓冲末端的**绝对时间戳**,而 demuxer 的缓存**只往前存** ——
跳到 50 分钟处时 [0, 50:00] 一个字节都没有。从 0 画到缓冲末端既是假的,更要命的是
真服实测缓冲只领先 4 秒(0.05% 宽),两条边缘完全重合 —— 这就是用户那句
「进度条卡在缓存进度上面」的**字面来源**。改成从播放头画到缓冲末端。

**Why:** 三处全都编译绿、单测绿、不抛异常,而且本地文件永远复现不出来(本地 duration
一拍就有、seek 一拍就完)。用户的描述("跟着缓存走")是**字面准确**的,别当成比喻。

**How to apply:**
- 查这类问题必须**测量加载窗口**:真服 `play` 后每 250ms 打 `status`,看 duration 多久
  才非 0。这个窗口是所有"起播期"bug 的舞台。
- 驱动真 exe 用 [挂真机 CDP 调试](methodology.md);本次靠它读到 `input.max=4165` 而非 1。
- 相关:[进度条三症状一条链](player-mpv.md)(上一轮的三症状)、
  「player-buffered-progress」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)、[loadfile 异步吞掉 sub-add](player-mpv.md)(同一个 FILE_LOADED 排队坑)、
  [测试必须先红](methodology.md)(`seek_before_file_loaded_is_queued_not_sent` 反向注入验过红)。

---

### 进度条三症状一条链

> 原记忆:`progress-bar-three-symptoms-one-chain.md` · 类型:`project`

2026-07-23 修。用户报三个现象,以为是三个 bug,其实是**一条链上的三处**,而且全都不报错:

| 现象 | 真因 | 位置 |
|---|---|---|
| 正常播放进度条不走 | `onMouseUp` 挂在 `<input type=range>` **自己身上**。拖着滑块移出条外/移出窗口松手 → input 收不到 mouseup → `setSeeking(null)` 不执行 → `seeking` 永远非 null → `curTime = seeking ?? status.time` **永久钉死** | `ui/desktop/App.tsx` 进度条 JSX |
| 拖完弹回旧位置 | mpv 的 `seek` 是**排队命令**,cmd 返回只代表「收到」;`time-pos` 要 50~500ms 后才跳过去。轮询必然打进这个窗口,把旧位置画上去 | `crates/mpv/src/lib.rs` `seek_abs` |
| 条和画面对不上 / 时间抽回 0 | `get_f64` **不看 `mpv_get_property` 返回值**。属性不可用(seek 中/换片解码就绪前/缓冲饥饿)时它 < 0 且**不写 out**,栈上初值 `0.0` 被当成「位置=0」交出去 | `crates/mpv/src/lib.rs` `get_f64` |

##### 修法(都在核层,不是前端补丁)

- `try_f64` 看返回值 + 查 `is_finite`;`sticky_f64` 读不到就沿用上次(**属性暂时不可用 ≠ 值变成 0**)。`loadfile` 时清账,否则上一集的位置漏给下一集。
- **seek 闩** `apply_seek_latch(latch, reported)`:seek 后到位之前一律报目标位;`|reported-target| <= 1.5s`(mpv 按关键帧落点,精确命中是例外)或 2.5s 超时就松闩放真值。**必须有超时** —— 一直压制会把「弹回」换成更难查的「永远不动」。抽成自由函数才能脱离 libmpv 单测(`Player::new` 要建叠加窗口+桌面会话)。
- 前端提交动作挂 **window** 的 `pointerup`/`pointercancel`/`blur`,不挂 input;拖动值同时存 ref(window 监听器闭包读 state 是注册那刻的快照)。
- 轮询 500→250ms,补间交给 **CSS `transition: width 260ms linear`** 而不是 rAF+setState(App 是上千行单组件,每帧重渲染 = 拿卡顿换顺滑);拖动中加 `.dragging` 关掉过渡。上报改 `% 20` 保持 5s。
- 轮询的 `catch { /* 未就绪忽略 */ }` 是**空的** —— 起播头几拍失败该忽略,但它把「持续失败」一起咽了,故障因此只能靠猜。改成连续 8 拍(2s)后 `say()` 一次。

**Why:** 这三处任何一处单独发作都长得像「播放器坏了」,而三处都不抛异常、编译绿、测试绿。
**How to apply:** 见 「player-buffered-progress」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)(缓冲进度三端口径)、[keep-open 下 EOF 检测](player-mpv.md)(同类「属性才是真相、事件不发」的坑)、[测试必须先红](methodology.md)(两条新测试都做过反向注入验红:`120 != 600`)。

---

### keep-open 下 EOF 检测

> 原记忆:`mpv-keepopen-eof-detection.md` · 类型:`reference`

我们的 mpv 开着 `keep-open=yes`（到结尾停在最后一帧而不是黑屏）。
**后果：文件不会被卸载，`MPV_EVENT_END_FILE` 因此永远不发。**
只监听事件来判「播放结束」= 写了一个永不触发的死分支。

正确做法：轮询 **`eof-reached`** 属性（mpv 文档明说它就是为 keep-open 场景准备的）。

2026-07-21 用 ctypes 直接加载 `libmpv-2.dll` 实测（1 秒 testsrc，keep-open=yes）：

```
time-pos=0.9  duration=1.0  eof-reached=no
time-pos=0.9  duration=1.0  eof-reached=yes   ← 翻转
```

duration 仍可读 = 文件确实没卸载，反证 END_FILE 不会来。
未加载文件时 `eof-reached` 返回 None（属性不可用），不是 "no" —— 判定要写成 `== Some("yes")`。

**这个坑的代价**：播放结束检测不到 → `stop_playback` 只在用户手动退出时才跑 →
Trakt/Bangumi 的「看完」一次都不会上报（用户报的「播完历史观看里没有同步」）。
换片时要清标志，否则上一集的 eof 会被下一集第一次轮询读到。

查属性是否存在的手法（别信文档信实测）：ctypes 加载 dll → `mpv_get_property_string(ctx, b"property-list")`
→ 在返回的大字符串里 grep。注意 `sub-add` 查不到是对的 —— 它是**命令**不是属性。
相关 [mpv 字幕属性实测](player-mpv.md)、[mpv 发行版卫生](player-mpv.md)。

---

### loadfile 异步吞掉 sub-add

> 原记忆:`mpv-loadfile-async-subadd.md` · 类型:`project`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。

**`loadfile` 只把条目排进 playlist 就返回,此刻并没有「当前文件」。**
`sub-add` 作用于当前文件,所以紧跟在 `load` 后面发必然拿到 **-12 error running command**。

ctypes 实跑 libmpv v0.41 复现(手法见 [keep-open 下 EOF 检测](player-mpv.md)):

```
loadfile        -> 0 success
sub-add(立刻)   -> -12 error running command   字幕轨 0 条
sub-add(等 FILE_LOADED=8 之后) -> 0 success    字幕轨 1 条
```

2026-07-21 事故:外挂字幕两端全都挂不上(用户「软件里看得见,播放页字幕选项里没有」)。
**双重静默**:`add_subtitle` 是 `let _ = self.cmd(...)` 吞掉错误,调用点还**无条件**
打一行「挂载外挂字幕 N 条」—— 日志看起来完全正常。

**已修**:事件线程 latch `MPV_EVENT_FILE_LOADED`(=8),挂载改由它在那一刻执行。
- **不能在调用点阻塞等** —— 两端 play 都在播放器锁内,等于拿着锁卡住 UI。
- **也不要另开线程**:`Drop` 是 `running=false → join(事件线程) → mpv_terminate_destroy`,
  只有跑在事件线程上才被那个 join 保护;另开线程 = 用户在字幕下载途中关播放器就 ctx 悬垂。
  代价是 `sub-add` 会**同步拉取字幕文件**(真服实测两条相隔 4s),这期间 END_FILE 只是延迟 latch。
  每条挂载前检查 `running`,关闭时不挂剩下的。
- `loaded` 与 `pending` **必须同一把锁**:拆成 AtomicBool+Mutex 会 TOCTOU ——
  调用方读到 false 正要入队时事件线程恰好取走空队列,字幕永远没人挂(同 [预取环形缓存并发竞态(已修)](network.md))。
- 判断放进 `add_subtitle` 内部,**五个**调用点(两端起播/网盘源/手动加/翻译字幕)一次全好。

**排除过的修法**(都实测否掉,别再走):
- `sub-files-append` **属性不存在**(-8 property not found)。
- `sub-files` 属性、`loadfile` 第4参 options:都能挂上,但**丢 title** ——
  前端字幕列表显示的就是 title,挂上了也是一条空白项,等于选不了。只有 `sub-add` 能带标题。
- `loadfile` 三参 options(老语法)→ -4 invalid parameter。

**前端那一半也要修**:TV 播放页原来 mount 拉一次 `tracks()` 就定死,
外挂字幕晚到(真服 6.7s / 10.8s)永远进不了面板。桌面那份「探到稳定」的轮询
已提到 `ui/shared/track-poll.ts` 两端共用 —— **两端各写一份正是这个 bug 的成因**。
另:Emby 的 stream index ≠ mpv 的 sid(外挂是追加进 track-list 的),按 title 认才对。

**验收手法(这次差点栽的地方)**:
真服 `<Emby 测试服 B>`「搏击俱乐部」内封 15 + 外挂 2(「emby-test-server-2-测试服 B」(该条不在本库,多为 Flutter 时代的旧记忆,已作废))。
我的探测脚本写了 `if len(subs)>=2: break` —— **15 条内封就满足了**,第 6 秒退出,
只看到 15 条,我差点签字说「修复在真机上没生效」并回头改代码。
**先数清楚 Emby 侧内封/外挂各几条再定阈值**;开 `LP_MPV_LOG=1` 回读 mpv 日志里的
`Run command: sub-add` 才是硬证据。归入 [测试必须先红](methodology.md) 的「验证环境≠真实环境」。

配套:[外挂字幕真根因](emby.md)(四层断口的前三层)、[网盘/strm 播放两大坑](player-mpv.md)。

---

### mpv 字幕属性实测

> 原记忆:`mpv-subtitle-property-truths.md` · 类型:`reference`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

2026-07-16 用 ctypes 直接加载 `native-poc/src-tauri/libmpv/libmpv-2.dll`(**mpv v0.41.0-744**)问出来的,不是查文档猜的。查法(可复现):

```python
import ctypes, os
os.add_dll_directory(os.getcwd())          # libmpv 所在目录
m = ctypes.CDLL("libmpv-2.dll"); m.mpv_create.restype = ctypes.c_void_p
h = ctypes.c_void_p(m.mpv_create()); m.mpv_initialize(h)
m.mpv_get_property_string.restype = ctypes.c_char_p
m.mpv_get_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
print(m.mpv_get_property_string(h, b"property-list"))   # ← 全部属性,别猜名字
```
没有 mpv.exe 也能问;`property-list` 是权威清单。

##### 两条会咬人的事实
1. **`sub-ass-override` 默认 `scale`,该模式下 ASS 字幕完全无视 `sub-font-size`,只认 `sub-scale`。**
   内封字幕(尤其番剧)几乎都是 ASS → 拿 sub-font-size 当「字幕大小」旋钮**对内封从来没生效过**。
   字幕大小一律用 `sub-scale`(对 ASS 和纯文本都生效)。
2. **`secondary-sub-ass-override` 默认 `strip`**(把次字幕 ASS 剥成纯文本)→ 次字幕反而**只认** sub-font-size。
   合起来就是用户 2026-07-16 报的怪象:「只能调次字幕的字体大小,主字幕调不动」+「次字幕不渲染样式」——**同一个根因的两个面**。
3. **`secondary-*` 只有** sid / ass-override / delay / pos / visibility / text / start / end / lines。
   **不存在** `secondary-sub-font-size` / `-font` / `-color` / `-scale` / `-border-size`(set 回 -8 property not found)。
   → 「次字幕单独设字号」在 mpv 层面**做不到**;所有 `sub-*` 样式是主次共用的一份。UI 要如实标「主次共用」,别造假 stepper。

**Why**:这类事「看起来接了、也不报错、就是不生效」,靠读代码永远查不出,只能问 libmpv 本人。
**How to apply**:动 mpv 字幕/属性前先跑上面那段拉 `property-list`;换 libmpv 版本后结论要重验。
⚠️ `secondary-sub-ass-override=scale`(保留原样式)可能让次字幕按 ASS 自带定位画 → 压到主字幕上、`secondary-sub-pos` 推不动。已做成开关让用户自己切,默认 scale,待真机验证。

相关:[Android mpv subtitle fonts](player-mpv.md)(libass 缺字体)、[「待接」多半是谎](methodology.md)(别信「核层没有」的注释)、[夸克二维码是图不是文本](sources.md)(观察和推理冲突时先打真接口)

---

### Android mpv subtitle fonts

> 原记忆:`android-mpv-subtitle-fonts.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

> **更正(2026 会话,libmpv 升级到 0.41 后)**:字体方案已改成**版本无关双铺**,函数改名 `setupFontconfig`→`setupLibassFonts`。二进制核实关键差异:**0.36 无 fontconfig**(FcInit 全 miss)、只走 libass **目录 provider**(扫 `config-dir/fonts` + `config-dir/subfont.ttf` 默认字体);**0.41 有 fontconfig** 且读 `FONTCONFIG_FILE`。所以现在 `setupLibassFonts` **同时**:①把 `/system/fonts` 软链进 `config-dir/fonts` + 挑 CJK 字体软链成 `subfont.ttf`(喂 0.36 目录 provider,零打包);②生成 `fonts.conf`+设 `FONTCONFIG_FILE`(喂 0.41 fontconfig)。两套 .so 都能显示文本字幕。`sub-fonts-dir`/`sub-font` 选项在**两版都不存在**(核实过),别再设。诊断行 `sub-diag` 已带 `libass-fonts` 字段(软链数/默认字体/fontconfig 状态)。下面旧内容(fonts.conf 单铺)是 0.36 时的中间态,已被双铺取代。

安卓原生 mpv（MpvPlayerPlugin.kt → libmpv.so）**内封/外挂文本字幕(SRT/ASS)整段不渲染**的根因:Android 上 libass 没有 fontconfig,若不显式给字体目录,libass 找不到任何字体 → 文本字幕画面空白(位图 PGS/SUP 不依赖字体,不受影响,所以"全都不显示"其实主因是文本类)。

> **↑ 本条自己的更正(双铺 `setupLibassFonts`)已取代下面这套旧方案,原文已删除。**
> 旧方案是 `sub-fonts-dir` + `sub-font` 守卫;而更正里核实 `sub-fonts-dir`/`sub-font` 在 0.36/0.41 **两版都不存在**。

**How to apply:** 排"原生 mpv 选了字幕轨也不显示"先查字体,不是查选轨。诊断:FILE_LOADED 日志里 sid 已选中但无画面字幕 → 几乎都是 libass 无字体。位图字幕(PGS)走 OSD 覆盖层、`blend-subtitles=no`/`sub-visibility=yes` 即可,与字体无关。相关原生坑见 「android-storage-and-mpv-logs」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)、[Android R8 JNI keep](android.md)。

---

**更完整的根因(2026-07-08 修,补上一个更常见的坑)**:字体到位后"内封字幕仍不显示"的真正主因不是字体,是**原生轨道列表推送竞态**——Dart 侧 `_tracks` 只靠 push 的 `tracksChanged` 事件填充,而它仅在 `FILE_LOADED` 时经 `emitEvent` 推一次:
- `MpvPlayerPlugin.kt` 的 `onListen` 订阅时**不回放 `currentTracks`** → 局域网/快源 Emby 直连下 `FILE_LOADED` 抢在 Dart 订阅 EventChannel(在 `await createPlayer` **之后**才 listen)前触发,唯一一次事件投递到 null sink 后**永久丢失** → `_tracks` 整场为空。
- `track-list` 原用 `MpvFormat.NODE` 观察,但 `eventProperty` 没有任何 NODE 重载消费它 → 轨道变化**从不二次上报**。
→ `_selectInternalSubtitleMPV`/`ViaTrack` 拿到空轨道 → 退化成 `sid=auto`,内封字幕(文本+PGS)选不中/选错 → 表现为"都不显示"。**桌面 media_kit 有响应式 `stream.tracks` 持续补发+6 次 sid 校验重试(`mpv_player_adapter.dart:820-878,1144-1197`),所以三端里只有安卓 nativeMpv 炸。**

**修(全在 `MpvPlayerPlugin.kt`,commit 26484fd)**:① `onListen` 建立订阅时立即回放 `currentTracks`;② `track-list` 改 `MpvFormat.NONE` 观察 + `eventProperty(String)` 里 `when("track-list")→loadTracks()` 重解析重推(覆盖 FILE_LOADED 后才就绪的字幕轨);③ 轨道 map 同时带 `"title"` 与 `"label"` 键——选轨匹配器 `player_subtitle_loader.matchMpvSubtitleTrack` 读的是 `t["title"]`,原来只塞 `"label"` → 多条同语言内封轨(简/繁/简日/特效)按标题消歧全失效。**顺带修好 nativeMpv 音轨按正则/首选自动选**(同吃空 `_tracks`)。

**教训**:安卓原生一次性 push 的列表事件(轨道/尺寸)必须给 `onListen` 回放兜底,否则订阅竞态下永久丢事件。诊断"选了轨也不显示"先看 App 日志 `MPV 可用字幕轨道: N 个`——N=0 就是这个竞态,不是字体。

---

**第二层根因(2026-07-08 真机复验后修,commit e71090f)——这才是"内封字幕仍不显示"的最终元凶**:轨道投递竞态(第一层)修好后,app 确实能调到选轨了(日志有 `[NativeMpv] 选择字幕轨道: 1/2`),但**字幕仍不渲染**。真机日志实锤:每条"选择字幕轨道"后 1ms 内必跟 `ERROR mpv/main: Command 'set_property' not found`。根因在 `MpvPlayerPlugin.kt` `selectSubtitleTrack`/`deselectSubtitleTrack`:
```kotlin
MPVLib.command(arrayOf("set_property", "sid", trackId))  // 错!
```
`set_property` 是 **libmpv C API 函数名**,mpv **命令接口里根本没有这个命令** → mpv 拒绝执行 → `sid` 从未真正设上 → 选了字幕轨也不渲染。**音频轨(`selectAudioTrack`)本就用 `MPVLib.setPropertyString("aid", trackId)` 所以一直正常**——这是天然对照组,也解释了"有声无字幕"。修:sid 同样改走 `MPVLib.setPropertyString("sid", trackId)`(deselect 用 `"no"`)。

**诊断 SOP 升级**:安卓原生"选了轨仍不显示",按层排——①App 日志 `可用字幕轨道: N`,N=0=投递竞态(第一层);②N>0 且有 `选择字幕轨道` 却不显示 → **grep 日志 `Command '.*' not found`**,有=原生用错了 mpv 命令接口(命令接口用 `set`/属性接口用 `setProperty*`,别拿 C API 函数名 `set_property` 当命令);③都对再查字体。设属性正确写法:数值/字符串属性一律 `MPVLib.setPropertyString/Int(name,val)`,**不要** `command("set_property",…)`。

---

**第三层根因 = 字体,但上次的字体修法对这版 libmpv 是无效选项(2026-07-08 二次真机复验后修,commit bb9dd04)**:前两层修好后日志已无 `set_property` 报错、sid 能设上,但文本字幕**仍空白**。**二进制符号级实锤**(`libmpv.so` arm64,mpv v0.36):
- libass **已编入**(`ass_library_init`/`ass_render_frame`/`ass_set_fonts` 符号都在),不是缺 libass;
- 但 **`sub-fonts-dir`/`sub-font`/`sub-font-size` 这些选项在这颗 .so 里根本不存在**(精确 `grep -a` 全 miss,而 `sub-visibility`/`sub-scale` 在)→ 之前(以及本条最上面写的)`setOptionString("sub-fonts-dir","/system/fonts")` 是**未知选项、静默 no-op**,字体目录从没设进去(报错还被 `mpv/overflow: log message buffer overflow: N messages skipped` 丢了,所以日志里看不到);
- 这版 **libass 走 fontconfig**(`.so` 含 `fontconfig`/`fonts.conf`/`fontselect` 符号),Android 默认无 fontconfig 配置 → fontconfig 无字体源 → 文本字幕整段空白。位图 PGS 不依赖字体,另说。

**修**:`MpvPlayerPlugin.setupFontconfig()` 在 `MPVLib.create()` **之前**生成一份指向 `/system/fonts` 的 `fonts.conf`(泛族 sans-serif/serif/monospace + 末位兜底都解析到 NotoSansCJK/Roboto/DroidSansFallback)+ 设 `FONTCONFIG_FILE`/`FONTCONFIG_PATH` 环境变量(libass 初始化即读,故必须在 create 前)。`<cachedir>` 显式给 App 私有目录(别设 HOME,免影响其它原生库)。

**教训(重磅)**:**别假设 mpv 选项名在所有 build 都存在**——第三方/精简 libmpv(尤其安卓预编译)可能砍掉或换名。改 mpv 选项前先 `grep -a -o "选项名" libmpv.so` 确认它真在库里,否则 setOptionString 静默失败、你还以为设上了。安卓 libass 字体是 **fontconfig 问题不是 sub-fonts-dir 问题**(那选项在此 build 压根没有)。诊断被 mpv 日志缓冲区溢出挡住时,自己 `emitEvent("log")` 直发关键诊断进 App 日志(已加 `sub-diag` 行:sid/可见性/字幕轨 codec)。**候选修复,待真机复验**(能否上屏只有设备能证)。

---

### mpv 发行版卫生

> 原记忆:`mpv-release-hygiene.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

`native-poc/src-tauri/src/mpv.rs` 的 `Player::new()` 上,2026-07-15 修的三件事:

##### 1. `log-file` 是有真实成本的调试设置,不能无条件开
`set("log-file", ...)` 一旦给路径,mpv 就把日志目标**钉在 MSGL_DEBUG**,`msg-level=all=v`
**管不住它**(证据:日志里全是 `[d]` 行),还会连带把 ffmpeg 的 `av_log_set_level` 拉到 debug
→ 解码器逐 packet 打日志并**同步写盘**。实测:一个文件都没加载、光 mpv init 就写了 247 行 / 24KB。
→ 已改成 `LP_MPV_LOG` 环境变量门控:`set LP_MPV_LOG=1 && LinPlayer.exe`。

##### 2. libmpv 没有配置目录 → 不显式设就**完全没有 shader 缓存**
日志证据:`cache path: '' -> '-'`、`home path: '' -> '-'`。
后果:每次起播把整条 Anime4K 链(最重档 6 pass、VL 模型 143K)重新
glsl→SPIR-V(shaderc)→HLSL(spirv-cross)→D3D 编译一遍,首帧干等一整轮。
→ 已设 `gpu-shader-cache=yes` + `gpu-shader-cache-dir=<cache_dir>/LinPlayer/shader-cache`
(放 app data 不放 %TEMP%:被清掉就等于没缓存)。

##### 3. 查「这个 mpv 认不认某个选项」的正确姿势
`strings` 在本机 Git Bash 里**静默返回 0 行**(不报错!),据此得出的「不认这个选项」全是假的。
用 python 直接扫 DLL,并且**必须带对照组**(拿 `glsl-shaders`/`hwdec` 这种确定存在的先验一下,
方法本身不可信就别信结论):
```python
import re; b=open('src-tauri/libmpv/libmpv-2.dll','rb').read()
found={m.group(0).decode() for m in re.finditer(rb'[ -~]{4,}', b)}
```
注:`mpv.rs` 的 `set()` **忽略 mpv_set_option_string 的返回值** → 选项名写错是**静默无效**,
不会报错。这就是为什么必须先验证选项存在。

##### 已排除的怀疑(别再查一遍)
`libmpv-2.dll` **不是 debug 构建**。112MB 全是静态链进去的代码(ffmpeg+libplacebo+vulkan+
shaderc+spirv-cross+luajit+vapoursynth…),PE 段表无任何 `.debug_*` 段,日志原文
`-Doptimization=3 -Db_lto=true` + `Built with NDEBUG.`。`enabled features` 里的
`debug`/`dxgi-debug-d3d11` 是**编译期可用性标记**,不是运行期开关。

相关:[画质档位口径](player-mpv.md)、[预取代理死锁(已修)](network.md)

---

### 画质档位口径

> 原记忆:`anime4k-denoise-ladder.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

##### 用户定的口径(2026-07-15,推翻此前所有版本)
原话:「为什么要用**还原**呢?不应该是**锐化+去噪**吗」「我也需要**窗口模式下也能锐化/去噪**」
「你真应该看看人家(hooke007/mpv_PlayKit)的滤镜是怎么做的」。

##### ★ 核心:锐化/去噪 ≠ 放大,别糅成一坨
**Anime4K 是放大器**。它每个 CNN pass 都带门槛:
```
//!WHEN OUTPUT.w MAIN.w / 1.200 > OUTPUT.h MAIN.h / 1.200 > *
```
输出(mpv 画面区 = **窗口大小,不是屏幕大小**)宽高都要 > 源的 1.2 倍,否则**一帧都不跑**。
真机:源 1920×1080、窗口 1770×1080 → 0.92× → 点什么档位都毫无变化。

PlayKit 的做法才对 —— **锐化的门槛是参数、跟尺寸无关**(实测):
| shader | 门槛 | 窗口下 |
|---|---|---|
| `AMD_CAS_luma_RT`(锐化 2.3K) | `//!WHEN STR` | ✅ 跑 |
| `AMD_FSR1_RCAS_RT`(锐化 4.1K) | `//!WHEN SHARP 4.0 <` | ✅ 跑 |
| `Anime4K_Denoise_Bilateral_*`(去噪) | **无 WHEN** | ✅ 永远跑 |
| `AMD_FSR1_EASU`(放大 10K) | `OUTPUT.w HOOKED.w 1.0 * >` | 仅放大时 |

##### ★ 2026-07-16 重构:三家族 × 每家六档(推翻旧的 modeA..modeAC + 「窗口/需放大」两组分法)
用户原话:「去掉放大才生效的模式那种分组,加入 FSR、专门的 NV 滤镜,三种滤镜每种六个模式」。
`levels()` 第三元由 `bool(窗口是否生效)` 改成 **家族名字符串**(`Anime4K`/`FSR`/`NVIDIA`),
UI(App.tsx `SHADER_FAMILIES`)按家族分三组,每组六档;**不再打「需放大」角标**
(那个割裂分组用户明确要去掉)。某档在当前窗口尺寸下跑不跑,仍由 `will_run()` 在**点击时** toast。
- **Anime4K**:去噪·轻/强(Bilateral Mean/Mode)、锐化+去噪·推荐(Bilateral+CAS)、放大 CNN M、放大+去噪 CNN M、放大去噪 CNN VL·壮机
- **FSR**:锐化 轻/推荐/强(CAS STR 0.60/0.85/1.0+RCAS)、放大+锐化 FSR1 / 强 / +去噪
- **NVIDIA(NIS)**:锐化 轻/推荐/强(NVSharpen SHARP 0.30/0.50/0.85)、放大 NIS / +锐化 / +去噪(NVScaler SHARP)

新增 shader:`NVScaler_RT.glsl`(放大,`//!WHEN OUTPUT` 挑尺寸)+`NVSharpen_RT.glsl`
(锐化,`//!WHEN SHARP` 是参数、窗口也跑),取自 `hooke007/mpv_PlayKit/portable_config/shaders/NV/`。
键名前缀 `ak_/fsr_/nv_`,别为「名字对得上」改键(改了用户存的档位就丢)。测试 `three_families_six_modes_each` 钉每族=6。

shader 取自 `hooke007/mpv_PlayKit/portable_config/shaders`(AMD/ 与 Anime4K/ 与 NV/,均 MIT)。
那个仓库还有 ArtCNN/FSRCNNX/nlmeans/Adaptive_sharpen/SSim 等,要加档先去那儿翻。
下载法:`curl raw.githubusercontent.com/hooke007/mpv_PlayKit/main/portable_config/shaders/<dir>/<file>.glsl`
(先 `api.github.com/repos/.../git/trees/main?recursive=1` 列路径)。

##### ★ 2026-07-20:四家族 + 锐化专精族 + 折叠 UI(用户报「强度不够」)
用户原话:「我感觉像 Anime4K 和 FSR 和 NVIDIA 三款模型的强度不够?开到最大档位有一点点变清晰
**其实清晰最重要的是锐化 锐化是最能提升看起来清晰的程度的**」「加多几个档位 这样的话就不能直接
展示了 **要叠起来 用户点击了某款超分模型再展开**」。

- **新家族 `Sharpen`「锐化 · 清晰度首选」7 档**,全部窗口就生效、全部 luma-only(便宜):
  Adaptive_sharpen_lite_luma(STR 0.70/1.30/1.90)、FineSharp(SSTR 2.50/5.00)、
  aWarpSharp2(STR=10,推像素收紧线条,动漫线稿最明显)、AMD_BCAS(双边 CAS,STR=1.0+SIGMA=0.3)。
- **Anime4K 族加 ArtCNN_C4F16 两档**(`ak_up_artcnn` / `ak_up_artcnn_sh`):PlayKit 里
  「清晰/开销」比最好的放大器之一,213K 单文件。尺寸门控写法是 `OUTPUT.w LUMA.w 1.200 * >`
  ——和 Anime4K 的 `OUTPUT.w MAIN.w / 1.200 >` **数学等价**,但 `when_ratio_matches_shader_source`
  只扫 MAIN.w,扫不到它(不影响,`is_upscale_gated` 认 `OUTPUT.` 判得对)。
- **强度不够的根因**:这些 shader 自带默认都极保守(Adaptive STR=1.0 / FineSharp SSTR=**0.5** /
  aWarpSharp2 STR=4.0),而档位不设参数就吃默认。新测试
  `sharpen_family_runs_windowed_and_is_stronger_than_defaults` **从 shader 源现读默认值**并断言
  推荐档必须高于它。
- **UI 改折叠**:`App.tsx` 的 `SHADER_FAMILIES` 变三元组 `[键, 标题, 说明]`,四族按
  已有惯例 `.p-li static` + `.rt.sel`(「当前档 ▾」)+ `.p-li.sub` 渲染 —— 这套折叠**仓库里
  早就有**(画面比例/定时播放/字幕字体都在用),别自造。收起时行内仍显示本族已选中的档。
- **新增两条静默失效守卫**(都反向注入验过红):
  1. `no_preset_loads_two_shaders_sharing_a_param_name` —— `glsl-shader-opts` 是**全局**
     K=V 表,Adaptive/aWarpSharp2/BCAS **都叫 `STR`** 但量纲是 0~2 / -20~20 / 0~1,
     叠进同一档会共用一个值、必然串味且 mpv 不报错。
  2. `api_contract_tests::shader_family_groups_match_the_core_level_table` —— 核层家族名与
     App.tsx 的 `SHADER_FAMILIES` 逐字对齐,前端漏登记一族 = 那族**整组从面板静默消失**。
- 顺带把 `preset_opt_values_are_in_range_and_actually_run` 里写死的 `0.0..=4.0` 改成
  **从声明该参数的那个 shader 源里现读 MIN/MAX**,死值判定(`//!WHEN` 为假的端点)也改成按文件算
  —— 原来那张全局表在 RCAS(SHARP=4.0 死)和 NVSharpen(SHARP=0 死)并存时必然判错一边。

**⚠️ 超分档位「不持久化」是用户故意的设计,不是 bug**(2026-07-20 原话:「超分档位不持久化
我故意这么做的 用户不是每集都需要」)。**别再去给它加 Prefs 字段/起播回放** —— 我这轮就是先
误诊成这个、动手改了 config.rs 才被叫停。见 [别过度解读需求](methodology.md)。

##### 永远不要 Restore
用户 **2026-07-11(a5e21885)** 和 **07-15** 两次否掉:动态画面边缘振铃/拖影,且最吃显卡。
有测试 `no_preset_uses_restore` 钉住。

##### 别再犯的两个错
1. **抄档位表要认 `git show HEAD:`**。`lib/core/services/anime4k_shaders.dart` 工作区有未提交的
   回退改动,照工作区抄会抄到用户已否掉的东西 —— 犯过。
2. **`count>0` ≠ shader 会跑**。mpv 收下 glsl-shaders 路径只证明路径合法。
   `set_shader_level` 现在双重回读,返回 `ShaderApplied{count, will_run, note}`;
   `shader_levels()` 多返回「窗口是否也生效」,UI 分两组 + 打「需放大」角标,**点之前就说清**。
   这个标志由 `is_upscale_gated()` 从 shader 源现算(扫 `//!WHEN` 里有没有拿 OUTPUT 比尺寸),
   **不是前端写死的名单** —— 换 shader 文件结论自动跟着变。

##### 测试当场抓到的事(说明这类测试值)
`window_ok_flag_matches_shader_gates` 抓到:我照直觉把 FSR 档标成「需放大」,
但 **RCAS 的门槛是参数不是尺寸** → FSR 档在窗口下会退化成「只锐化」,仍有效果。
`when_ratio_matches_shader_source` 抓到:`AutoDownscalePre` 用的是 **NATIVE 基准的区间闸**
(x2 管 1.2~2.0 倍、x4 管 2.4~4.0 倍),不是总闸,别拿 WHEN_RATIO 去套。

##### 另一半真相
[双显卡必须钉独显](player-mpv.md):在这之前,mpv 一直跑在**核显**上,5060 全程没参与 —— 那才是
「非常非常卡」的量级来源。而 [超分失效根因+toast统一位置](player-mpv.md):旧 Flutter 桌面端软件纹理**根本不跑 glsl**,
所以「以前测试不卡」很可能是超分从没真生效过。**这三件事叠在一起,谁都不单独解释全部现象。**

相关:[双显卡必须钉独显](player-mpv.md)、[mpv 发行版卫生](player-mpv.md)、「native-rendering-project」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)

---

### 双显卡必须钉独显

> 原记忆:`hybrid-gpu-must-pin-dgpu.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

##### 症状 → 真凶
2026-07-15 用户报「Anime4K 非常非常卡,我用 mpvplaykit 都没这么卡,你肯定是使用方式有问题」。
mpv 日志第一屏就是判决书:

```
[v][vo/gpu-next/d3d11] Device Name: Intel(R) UHD Graphics   ← 核显!
[v][vo/gpu-next/d3d11] Device ID: 8086:468b
```

**Anime4K 整条 CNN 链跑在 Intel UHD 上,RTX 5060 全程没参与。**
这就是 「native-rendering-project」(该条不在本库,多为 Flutter 时代的旧记忆,已作废) 立项要治的「5060 超分卡」的真正病根 —— 跟档位、跟
media_kit 软件纹理、跟 ANGLE **都没关系**(日志里 angle/egl/opengl **零命中**,走的是原生 d3d11)。

**为什么会这样**:混合显卡笔记本上 D3D11 的默认适配器 = 接显示器的那块(核显)。
LinPlayer.exe 是个新面孔,NVIDIA 驱动的程序配置库里没有它 → 落到默认的「集显」档。

##### 修法(commit 见 native-poc/src-tauri/build.rs + lib.rs 顶部)
```rust
#[cfg(windows)] #[used] #[no_mangle]
pub static NvOptimusEnablement: u32 = 0x0000_0001;          // NVIDIA Optimus
#[cfg(windows)] #[used] #[no_mangle]
pub static AmdPowerXpressRequestHighPerformance: u32 = 1;   // AMD Enduro
```
+ build.rs:`cargo:rustc-link-arg-bins=/EXPORT:NvOptimusEnablement`(两个都要)

**两半缺一不可**:Rust exe **默认没有导出表**,只写 `#[no_mangle]` 驱动看不见;
`#[used]` 不加则 LTO 把静态量整个丢掉。而且缺了任一半**都不报错,只是继续用核显**。

比硬编码 `d3d11-adapter=NVIDIA` 好:不认厂商名、单显卡机器上天然空操作。
(mpv 确实有 `d3d11-adapter` 选项,验证过存在,是备选方案。)

##### 验证方法(必须做,别默认它生效了)
```
set LP_MPV_LOG=1 && LinPlayer.exe     # 日志门控见 [mpv 发行版卫生](player-mpv.md)
```
看 `%TEMP%\linplayer_mpv.log` 里的 `Device Name:`。实测 A/B:
- 改前 `Intel(R) UHD Graphics` / 改后 `NVIDIA GeForce RTX 5060 Laptop GPU (10de:2d19)`
- **release(LTO)版单独验过**一次 —— debug 绿不代表 release 绿(`#[used]` vs LTO)。

还可以直接查 exe 导出表(python 解 PE 即可,别用 strings,见 [mpv 发行版卫生](player-mpv.md))。

##### 教训
用户说「你肯定是使用方式有问题」时他是对的,尽管他猜的机制(ANGLE 合成)不对。
**别因为对方的归因错了就连带否掉他的观察** —— 「mpvplaykit 不卡而你卡」这个对照本身
就说明问题在我们的用法,不在 mpv,更不在档位表。我上一轮把「卡」归给档位抄错
(见 [画质档位口径](player-mpv.md))是**在没量过 GPU 的情况下下的结论**,那条只是次要因素。

相关:[画质档位口径](player-mpv.md)、[mpv 发行版卫生](player-mpv.md)、「native-rendering-project」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)

---

### 超分失效根因+toast统一位置

> 原记忆:`superres-and-toast.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

**⚠️重大更正（2026-07-13 真机定论，见 「native-rendering-project」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)）**：本文下方多处把「5060 都卡」
归因于 media_kit→ANGLE→Flutter 纹理出画管线——**这是错的**。真机实测：Windows 原生渲染(绕开 ANGLE)
最大化后一样卡，而不开超分最大化不卡 => **卡=超分 shader 的 GPU 算力随输出分辨率暴涨，与渲染管线无关**。
且 **Anime4K 去噪梯子已整体换成 ArtCNN**（luma-only + WHEN 分辨率门控 + 单文件，又轻又清晰；键名沿用
modeA..modeAC）。下面关于 Anime4K 六档链路/软硬件纹理/ANGLE 归因的内容多已过时，仅留档。当前超分事实源
仍是 `anime4k_shaders.dart`（内容已是 ArtCNN）。

**超分(Anime4K)两大坑**（2026-07 修复，⚠️部分已被上方更正推翻）：
1. **PC(media_kit Win/macOS)无效**：desktop 为消除弹面板闪屏，VideoController 用了
   `enableHardwareAcceleration:false`(软件纹理)。media_kit `video_output.cc` 据此选
   `MPV_RENDER_API_TYPE_SW`，而 libmpv 软件渲染器**根本不跑 GLSL user shader**
   (`glsl-shaders`)→超分开了画面零变化、连闪都不闪。修法：`MpvPlayerAdapter.initialize`
   收 `superResolutionLevel`，开超分时强制走硬件纹理(`softwareTexture = (mac||win) && !wantsShaders`)；
   纹理模式建 VideoController 时定死。**⚠️别整段重建播放管线切超分**——那会把已缓冲流从头
   重新下载、进度跳回记录处、爆卡(用户明确反感)。现方案:软件纹理下开超分只**存档位+提示
   「下次播放生效」**(不 reload),下次起播用硬件纹理自然带 shader;已是硬件纹理(起播就带超分)
   则档位/开关全 live apply。判定靠 `MpvPlayerAdapter.isSoftwareTexture` →
   `VideoPlayerService.superResolutionCanApplyLive`(旧 superResolutionRequiresReinit 已删)。
   **⚠️更新(2026-07 用户要「三端一致·即时生效」)**：桌面三端已全部**恒硬件纹理**
   (`const softwareTexture = false;` + `VideoController(_player!)` 不传 config)——超分/六档
   中途随手 live 切换、关掉立即不卡,不再「下次播放」。代价按平台:Windows 弹面板闪一下回归;
   **macOS 硬件纹理黑屏风险(GL 上下文泄漏,反复播放后第 N 次黑屏有声)回归**——用户已知并要真机测;
   若 macOS 真机黑屏,`mpv_player_adapter.dart` softwareTexture 那行按注释换回
   `Platform.isMacOS && (_glslShaders?.isEmpty ?? true)` 并恢复 VideoController 三元 config 即回退
   (macOS 超分退「下次生效」)。见 「mediakit-texture-flash-swtexture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废) 「macos-no-video-hwdec」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)。
   **卡的根因是渲染栈固有**:media_kit=`vo=libmpv`+渲染API→mpv 画进离屏纹理再由 Flutter 合成呈现
   (非原生直接上屏),shader 走 ANGLE(GLES→D3D11 翻译)+Windows 强制 `hwdec=auto-copy` 每帧拷回。
   同 libmpv 内核但「出画」这段比原生 mpv/PotPlayer(原生 D3D11 零拷贝)重,无法抹平到原生;
   零拷贝解码(去 auto-copy)可省拷回但部分显卡 dxva2-egl 崩,只能做实验开关。
   **档位三端都是 6 档 A/B/C/AA/BB/AC**(桌面菜单曾漏成 3 档,f6461788 只补了移动端;已补齐)。
   **⚠️2026-07-11 定稿:六档=纯去噪放大梯子(无 Restore)**——用户实测 **Restore CNN(锐化/还原)在动态
   画面产生边缘振铃/拖影且最吃显卡,明确不要**;超分需求就是 Anime4K 的 Upscale+Denoise(去噪放大)。
   故六档全部剔除 Restore,做成核显→壮机的算力梯子(键名沿用 modeA..modeAC 不变,持久化/UI 兼容):
   modeA=去噪S(核显) / modeB=去噪M / modeC=去噪L / modeAA=去噪叠加M / modeBB=去噪叠加L /
   modeAC=去噪叠加VL。链路:Clamp→Upscale_Denoise(x2)→AutoDownscalePre_x2/x4→〔叠加档:二次 Denoise_M〕→Upscale_CNN_M。
   assets 只保留去噪梯子用到的 9 个 shader(Denoise S/M/L/VL + Upscale_CNN S/M + Clamp + ADP x2/x4),
   **Restore/Soft/大 Upscale 全部 git rm 清掉**(之前"官方模式"版加的现已无用)。映射单一事实源仍
   `anime4k_shaders.dart`;标签三端:desktop levels+_anime4KLevelLabel、mobile _showAnime4kPanel(TV 无超分)。
   **别再往里塞 Restore/锐化**——用户点名不要。曾试过:尺寸梯子(A=S/B=M/C=VL,C卡)→官方算法模式(含 Restore,拖影),均废。
   **软解(hwdec=no)会让 OSD 闪回归→别用,保持硬解 d3d11va**(见 [桌面双声音/孤儿播放器](player-mpv.md))。
   卡的真凶在 media_kit→ANGLE→Flutter 纹理出画管线(硬解帧每帧 map 进 GL 的 interop),非 shader/GPU(5060 都卡),
   去噪梯子给 S 档兜核显、减少 CNN 层数缓解,但天花板仍是出画管线,除非上原生渲染。
   **零拷贝解码实验开关(2026-07)**:Windows media_kit hwdec 默认 `auto-copy`(每帧 GPU→内存拷回,卡的
   一大来源);更多菜单加「零拷贝解码(实验)」→ live 切 `d3d11va`(与 ANGLE 同 D3D11 后端,免拷回,治卡/闪)。
   会话级不落盘(个别显卡 d3d11va-egl 崩,重启回默认防 brick)。VideoPlayerService._zeroCopyHwdec 线程给
   MpvPlayerAdapter.applyZeroCopyHwdec;仅 Windows+mpv 显示。用户实测:开零拷贝后卡/闪明显缓解。
   注意:Anime4K 是动画专用锐化,真人内容几乎看不出效果但仍吃 GPU(=开了爆卡却「没变清晰」是正常)。
2. **Android(原生 mpv)无效**：`native_mpv_player_adapter.applySuperResolutionLevel` 只存
   level，从没有 level→shader 映射(映射当时只在 media_kit 适配器里)，且被 `_superResolutionEnabled`
   门控(UI 从不置 true)→永远没 shader 可放。修法：档位→shader 抽到
   `lib/core/services/anime4k_shaders.dart`(kAnime4KShaderPresets + resolveAnime4KShaderPaths
   落地 asset 成文件路径)，两端共用；原生适配器 initialize + applySuperResolutionLevel 都解析并应用。

档位→shader 单一事实来源已是 `anime4k_shaders.dart`，别再往适配器里复制映射。

**三端 toast 位置约定**：`AppToast`(移动/桌面,`lib/ui/widgets/common/app_toast.dart`)加了
`AppToastPosition{topCenter,lowerCenter}`，**默认 lowerCenter(中部偏下)**——非播放页统一用默认；
**播放页传 `position: AppToastPosition.topCenter`**(顶部居中不挡底部控件)。TV 侧 `TvToast` 同理加
`top` 参数(默认中部偏下,播放页 `top:true`)。全库 ~150 处裸 `ScaffoldMessenger.showSnackBar`
已换成 AppToast；剩极少数(捕获 messenger 跨 await 无 mounted 守卫 / SnackBarAction / floating)
故意保留 SnackBar。新增提示别再用裸 SnackBar，走 AppToast/TvToast。见 [别过度解读需求](methodology.md)。

---

### Dolby auto decode

> 原记忆:`dolby-auto-decode.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

**杜比视界自动切换 gpu-next + 软解**（`dolbyAutoGpuNextSwProvider`,key `linplayer_dolby_auto_gpu_next_sw`,**默认 true**,可关）。检测到当前视频流为 DV 且内核为 mpv 系(media_kit / 原生mpv)时,强制 `hwdec=no`(软解) + gpu-next 渲染——硬件 mediacodec 解 DV 丢 RPU 会偏色,gpu-next(libplacebo) 软解链路才能正确映射 IPT-PQ。

- **DV 判定**在 `MediaStream.isDolbyVision`(lib/core/api/api_interfaces.dart):VideoRangeType 含 DOVI / 编解码标签 dvhe·dvh1·dav1 / 标题含 "dolby vision"·"dovi"。新增 `videoRange`/`videoRangeType` 字段,解析见 emby_api.dart `_parseMediaStream`。
- **接线在三端播放页**各自构建 initialize 参数处:player_screen_state.dart(移动)/tv_player_screen.dart(TV)/desktop_player_screen_state.dart(桌面)。`autoDvMode` 命中则 `hardwareDecoding=false`、nativeMpv 的 `useGpuNext=true`、mpv 的 `dolbyVisionFix=true`。
- **桌面 media_kit 走 vo=libmpv,没有独立 gpu-next vo**,无法对 DV RPU 做 libplacebo 映射;退而用软解 + `dolbyVisionFix` 的色彩提示/色调映射(target-colorspace-hint/tone-mapping=spline/hdr-compute-peak)。注意:`dolbyVisionFix` 之前在 mpv_player_adapter 里是**死参数**(只接收不应用),本次才让它真正生效。
- **设置项三端都加了**:settings_player.dart(移动/桌面,仅 mpv/nativeMpv 显示) + tv_settings_screen.dart;并入备份导出/导入(settings_screen.dart `dolbyAutoGpuNextSw`)。

**安卓原生 mpv 纯软解卡顿调优**(MpvPlayerPlugin.kt `setMpvOptions` 的 `hwdec=no` 分支)——4K HEVC/DV 软解极吃 CPU,默认配置移动端会严重卡顿:`vd-lavc-threads`=核心数(coerceIn 2..16,mpv auto 在部分机型只用一半核)、`vd-lavc-skiploopfilter=nonref`(跳非参考帧去块滤波,省 CPU 肉眼无损,是能否跑实时帧率的关键)、`vd-lavc-fast=yes`、`vd-lavc-dr=yes`、`framedrop=vo`。另外 gpu-next 的 `hdr-compute-peak` 改为**仅硬解开**(`if(hardwareDecoding)"yes" else "no"`):逐帧 GPU 直方图在移动 GPU 很贵,软解时 CPU 已满再叠加会卡。

相关:「android-storage-and-mpv-logs」(该条不在本库,多为 Flutter 时代的旧记忆,已作废) [Android mpv subtitle fonts](player-mpv.md)

---

### FFmpeg magicyuv CVE

> 原记忆:`ffmpeg-magicyuv-cve.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

CVE-2026-8461 "PixelSmash":libavcodec `magicyuv` 解码器堆越界写(恶意 slice_height),恶意 AVI/MKV/MOV → 崩溃/RCE。FFmpeg 8.1.2(2026-06-17)修复。

**本项目受影响面与处置:**
- **桌面(Win/Linux/macOS)= media_kit→libmpv**:Windows 钉 shinchiro 完整版(`magicyuv` 已编入)→ **受影响**。修复:`mpv_player_adapter.dart` 在 Player 初始化处 `setProperty('vd', '-magicyuv')` 拉黑该解码器(mpv `common/codecs.c` 语义:`-<decoder>`=排除,其余仍自动选)。一行即跨三桌面端消除攻击面,不等 libmpv 重打包。
- **Android / Android-TV = 原生 MPV 插件**:media-kit libmpv 用解码器白名单构建(`--disable-decoders` 再选择性 enable),`magicyuv` 未编入 → **本就不受影响**。
- **标准独立 ffmpeg**(CI 内置 + 运行时下载,仅 Whisper 抽音用)走 `-vn` 纯音频 → **非此视频解码器 CVE 的向量**。
- **残留**:tvOS(`apple_tv/`)用 **MDK**(非 mpv),无 mpv 式 per-codec 排除,待 MDK 自带 ffmpeg 升级;`windows/scripts/upgrade_libmpv_for_pgs.ps1` 的 shinchiro 钉版 `20260610` 早于修复,**待 shinchiro 发布 ≥20260618 构建后把 DownloadUrl 升上去**(脚本注释已标)。

**Why:** 预编译 libmpv 自带旧 ffmpeg,无法在本仓库重编;运行时拉黑单个冷门解码器是最快、跨端、零依赖的根除手段。
**How to apply:** 新增/换播放器内核时,确认走 [File-browse sources](sources.md) 的播放路径仍带 `vd=-magicyuv`;升级 Windows libmpv 钉版后该兜底仍可保留(无害)。

---

## 跨域交叉引用

这些条目和本领域强相关,但正文放在别的文件里(一条经验只存一份正文):

- [外挂字幕真根因](emby.md) — 外挂字幕不加载的第一层断口在 Emby 的 DeviceProfile,不在 mpv
- [跳到未缓冲位置卡死=我们拼错API根](emby.md) — 「跳到未缓冲位置卡死」是 URL 前缀拼错导致服务器不给 206
- [弹幕交给 libass](danmaku-sync.md) — 弹幕曾走 mpv 的 secondary-sid(2026-07-27 已整条删除)
- [PC 快捷键 + mpv.conf](ui-desktop.md) — 自定义 mpv.conf 靠 libmpv 的 config-dir,以及 seek 闩的粘性值坑
- [安卓视频透出四层](android.md) — 安卓「有声音没画面」的四层透出链
- [预取代理死锁(已修)](network.md) — 「有流量没画面」还有一整族根因在预取代理里
- [弹弹Play 三个静默失败](danmaku-sync.md) — 弹幕相关的静默失败
