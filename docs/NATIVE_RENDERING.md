# 桌面端视频合成（Windows / Linux）

> 单一事实源：PC 端「视频画面和 UI 是怎么叠在一起的」。最后更新：2026-07-26。
>
> 2026-07-14 版本的本文写的是 Flutter + media_kit 时代的调研（治「开面板整屏闪」）。
> 那套栈**已整体删除**，结论收在文末「历史结论」一节——那些坑现在仍然是我们不能走某些路的理由，
> 所以留着，但它们描述的**不是当前实现**。

## 1. 当前架构：两个顶层窗口

```
   ┌─────────────────────────────────┐
   │  Tauri 主窗（transparent=true） │  ← WebView2 / WebKitGTK 画 React UI
   │  decorations=false，自绘标题栏  │     视频区域是**透明像素**
   └─────────────────────────────────┘
                  ▲ 逐像素 alpha，由系统合成器（DWM / X11 合成器）叠
   ┌─────────────────────────────────┐
   │  视频窗（我们自己 Create 的）   │  ← libmpv 的 `wid` 指向它
   │  无边框 / 不进任务栏 / 不抢焦点 │     vo=gpu-next，Win 上 gpu-context=d3d11
   └─────────────────────────────────┘
```

两个都是**顶层窗口**，视频窗被持续对齐到主窗客户区、并压在主窗正下方。

代码位置：
- `crates/mpv/src/lib.rs` 的 `mod overlay` —— 建窗 / 对齐 / 层叠 / 显隐，Win 与 X11 各一份同构实现。
- `apps/desktop/src/lib.rs` 的 `sync_video()` / `show_video()` —— 几何来源（主窗客户区）与显隐时机。

### 为什么不能用子窗口

这是被实测证伪过的，别再试：

- **Windows**：子窗口进不了逐像素透明的分层窗口。WebView2 自己就是主窗的一个子 HWND，
  把 mpv 也做成兄弟子窗口时，WebView2 的透明像素**不会**透出兄弟窗口——Win32 的子窗口之间不做 alpha 混合。
- **X11**：合成器只合成**顶层**窗口。兄弟窗口之间同样不做 alpha 混合。

所以两边都只剩「顶层垫顶层」这一条路。

## 2. 层级维持（2026-07-26 重做）

### 之前坏在哪

对齐/排序只挂在 Tauri 的 `Resized | Moved | Focused(true)` 三个事件上。但主窗的 z 序还会被**别的路径**改：
Alt-Tab、点任务栏、别的窗口插进来、WebView2 自己动一下——这些**都不产生**那三个事件。
于是视频层「掉」到 UI 后面去。

而且视频窗建出来就带 `WS_VISIBLE`（X11 那半是建完就 `XMapWindow`），每次 sync 又都带 `SWP_SHOWWINDOW`——
它从 App 启动那一刻起就一直在桌面上。平时被主窗盖着看不出来，**主窗一最小化就露出来**，
表现是「反复最小化能看到后面有个窗口正在播放」。

### 现在怎么做

1. **显隐 = 两个条件的与**（`overlay::apply_visibility`）：
   - `WANT_VISIBLE`：在播片吗（`play` 置真，`stop_playback` 置假）；
   - 主窗自己还在屏幕上吗（没最小化、没隐藏）。

   任一不成立就藏。建窗时**不带** `WS_VISIBLE` / 不 map。

2. **Windows：子类化主窗接管 `WM_WINDOWPOSCHANGED`**（`overlay::pin_below`）。
   这条消息在位置、尺寸、z 序**任何一样变了**时都会发，钉住它，上面整类漏网一次消掉，
   也不用起定时器轮询。

   ⚠️ **重入闸不能删**。我们在这条回调里调 `SetWindowPos`/`ShowWindow` 摆视频窗，
   而那会改变主窗的相对 z 序 → Windows 又发一条 `WM_WINDOWPOSCHANGED` → 再进来 →
   递归到**栈溢出，进程无声消失**（日志停在最后一行，没有 panic，Windows 事件日志里也没有记录）。
   实测症状：装上钩子后鼠标挪一下窗口 App 就没了。

   同理 `apply_visibility` 里状态已经对就不要调 `ShowWindow`——它同样会动 z 序。

3. **取不到原 wndproc 就不装钩子**。装了却把消息全喂给 `DefWindowProcW`
   等于把 Tauri 的窗口过程整个换掉，窗口会彻底不响应。降级成「只靠 Tauri 事件重排」远比这个好。

4. **Linux/X11 没有等价的钩子**。要同样的效果得 `XSelectInput(StructureNotify)` 主窗的 frame
   再自己跑事件循环，而那个 frame 会被 WM reparent 掉、得跟着重挂。
   所以 X11 这半仍然只靠 Tauri 事件驱动的 `sync()`——**这是已知的能力差，不是忘了写**。

### 验收（2026-07-26 在真 exe 上实测）

用 `EnumWindows` 查视频窗（窗口类 `lpvid`）的 `IsWindowVisible`：

| 状态 | 视频窗可见 | z 序 |
|---|---|---|
| 未播放 | 否 | — |
| 播放中 | 是 | 主窗之下 |
| 主窗最小化 | **否** | — |
| 恢复 | 是 | 主窗之下 |

压力：最小化/恢复 ×8 + 挪窗 ×8 交替、连续最小化 ×6 不恢复 —— 进程存活，状态每次都对。

## 3. 已知限制：录屏只能录到一层

两个独立顶层窗口，**窗口捕获（OBS「窗口采集」/ WGC / PrintWindow）只能抓到其中一个**：
抓主窗得到 UI + 一块透明/黑，抓视频窗得到画面但没有 UI。这是窗口捕获的定义决定的，不是 bug。

**能用的办法**：
- 录制请用**显示器采集**（OBS「显示器采集」/ Windows 游戏栏的全屏录制），两层由系统合成器叠好后一起录。
- 只想录画面不要 UI：抓视频窗即可，而且**弹幕和字幕现在是 mpv 画的**（见下），会一起录进去。

**为什么不做成一个窗口**：真正的单窗口合成要把 WebView2 放进 visual hosting 模式
（`ICoreWebView2Environment3::CreateCoreWebView2CompositionController`），
把它的视觉和 mpv 的 D3D11 swapchain 挂进同一棵 DirectComposition 树。
**Tauri v2 / wry 不暴露 CompositionController**，只支持普通的 windowed hosting ——
要做就得 fork wry，是几周量级的改动。当前**不做**，需要时单独立项。

## 4. 弹幕改由 mpv 渲染（2026-07-26）

弹幕原来是 React 在**透明主窗**里用 Canvas 每帧画。除了它自身的性能问题
（见 `crates/core/src/danmaku/ass.rs` 头注释：位置插值里没有倍速），
它还让透明主窗每帧都要重新合成一次，直接压在这套合成方案上。

现在默认把弹幕生成成 ASS 交 libass 渲染：
- 生成：`crates/core/src/danmaku/ass.rs`（纯函数 + 单测）
- 挂载：`Player::set_danmaku_sub()` → `sub-add` 到 **secondary-sid**，
  并设 `secondary-sub-ass-override=no`（默认是 `strip`，会把 ASS 标记剥成纯文本，
  于是 `\move` / `\pos` / `\c` 全没了，弹幕变成顶上一行白字）。
- 主字幕位**空着留给用户真正的字幕轨**。实测 `sid=no` / `secondary-sid=1`，两者不打架。

副作用（正面）：mpv 的截图/录制会带上弹幕；倍速/seek/暂停全归 mpv，前端一帧都不用算。

代价：弹幕占了 mpv 唯一的次字幕位，**和双语字幕抢同一个位子**。
需要两者同开的用户可以在播放页弹幕面板把「渲染方式」切回「网页层」。

## 5. mpv 初始化参数（桌面）

在 `crates/mpv/src/lib.rs` 的 `Player::new()`：

| 参数 | 值 | 说明 |
|---|---|---|
| `wid` | 视频窗 HWND / X11 Window | 渲染面 |
| `vo` | `gpu-next` | |
| `gpu-context` | `d3d11`（仅 Win） | |
| `hwdec` | `auto-safe`（默认档，用户可调） | 双显卡必须钉独显，否则 mpv 会跑核显 |
| `keep-open` | `yes` | 播完停在最后一帧，**所以 END_FILE 不发**，判播完要读 `eof-reached` |
| `force-window` | `yes` | |
| `osc` / `terminal` / `input-default-bindings` / `input-vo-keyboard` | `no` | UI 全归我们 |
| `gpu-shader-cache` + `gpu-shader-cache-dir` | 开 + 显式目录 | libmpv 不给默认目录，不显式给就不缓存 |
| `msg-level` / `log-file` | 仅 `LP_MPV_LOG=1` 时开 | 常开会把 mpv+ffmpeg 钉在 debug 级 |

## 6. Wayland

整套方案要求「应用自己摆放顶层窗口」，而 **Wayland 协议上就不允许**。
`run()` 里强制 `GDK_BACKEND=x11` 走 XWayland。真落到 Wayland 原生会话时如实报错，
走和「拿不到窗口句柄」一样的降级路径（App 能起，视频层不工作），不假装成功。

## 7. 历史结论（Flutter + media_kit 时代，仅供别再走回头路）

那套栈已删，以下结论仍然有效：

- **症状**：Windows 上打开/滑动/悬停任何面板 → 整屏闪一下黑帧。
  **根因**：media_kit 把 mpv 渲成 Flutter Texture，经 ANGLE 合成，视频和 UI 在同一个 ANGLE 场景里；
  该机 EGL 损坏 → 只要有东西在视频纹理上方改变图层结构，整块外部纹理就 blank 一帧。
- 证伪过的假设：路由 vs 就地 Navigator、不透明面板遮挡、去掉裁剪 —— **全试过，全闪**。
  唯一有效的 Flutter 层手段是全屏冻结帧，用户否掉。
- 逆向 Hills（同为 Flutter+mpv 却从不闪）：它用 `SurfaceView` + mpv-android + Flutter PlatformView，
  即 mpv 直画原生 Surface、由系统合成器叠 UI。**这就是现在这套架构的思路来源。**
- `SetWindowRgn` 挖洞法（在 Flutter 视图上挖出视频区域）—— 顶层区域管不到子窗口，实测「没看到洞」。**此路不通。**
- 原生渲染治得了闪，**治不了「4K 超分卡」**：那是 shader 算力随输出像素暴涨，是物理，换渲染器无用。
  （真凶另有其人：mpv 默认跑核显，独显全程没参与，必须在 exe 里导出 `NvOptimusEnablement` 钉独显。）
