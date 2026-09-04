# S1.2 · Avalonia 侧能不能接上路径 B

> 状态:**已结题(Windows 侧)**;Linux 侧未测(S1.4 / S1.4b)
> 起止:2026-08-31
> 关联:`SPEC.md` §7.2、§7.3、`TODO.md` S1.2、`spikes/SPIKE-1b-zero-copy.md`

## 1. 要回答的问题

**Avalonia 的 `OpenGlControlBase` 能不能把核心层渲的视频当成 UI 场景里的一层,
并且让一个半透明 Avalonia 控件真的叠在它上面?**

mpv 侧「渲进纹理 FBO」在 SPIKE-1a / 1b 已实测通过(含 PGS 图形字幕与硬解)。
剩下的一半 —— 宿主侧 —— 一次都没试过。

## 2. 为什么它排在业务代码之前

这一半塌了,`UI_PC.md` §8(播放页与 OSD)整章要重写,PC 端要退回 A2(双顶层窗口),
连带 §7.3 的裁决要翻案。**它是唯一一个能推翻 PC 端 UI 呈现模型的实验。**

## 3. 做法

> ⚠️ **2026-08-31 后续:本报告里的 `AvaloniaProbe` 已经改造过。**
> 当时它通过 `lp_spike_*` 专用导出直接驱动 Rust 桩;SPIKE-2 阶段 B 之后,
> 它改成**只用 SPEC §5.1 的 13 个契约导出**驱动 Go 核心。
> 本报告的数据是改造前测的,**结论不受影响**(Go 核心上四条判据同样全过,
> 性能同量级,见 `SPIKE-2-go-ffi.md` §4.4)。
> 那个 Rust 桩(`lpcore-stub/`)2026-09-04 随 Rust 栈一起删除 —— 它早已不被探针使用,
> 要看当时的源码:`git show rust-final:docs/go-migration/spikes/s1-2/lpcore-stub/src/lib.rs`。

### 3.1 工程

```
docs/go-migration/spikes/s1-2/
  AvaloniaProbe/      Avalonia 工程。UI 全在 Program.cs 里用代码搭,不用 XAML
  mkclip.py           用 libmpv 自己的 encode 模式造 H.264 语料
  swap-ab.py          从 spike-1b-glbackend.py 派生,唯一改动是 report_swap 变环境变量门控
```

**为什么核心层桩是 Rust 不是 Go:** 本机 `go` / `gcc` / `clang` / `cl` / `zig`
**全部 command not found**(2026-08-31 实测)。C ABI 侧一字不差,Go 核心落地后换掉 dll
即可,C# 侧一行不用改。**这不代表 SPIKE-2(Go 三宿主 FFI)已验** —— 那条仍然未验。

关键的一条自我约束:**C# 侧只拿得到 `fbo / w / h / flip_y`,拿不到任何 mpv 类型。**
这本身就是被验的东西之一 —— SPEC §7.1 说「UI 层不直接调用 libmpv」,
那个窄接口到底够不够用。结论:**够**,`OnOpenGlRender(GlInterface gl, int fb)`
给的东西和契约需要的东西一一对上,不需要额外开口子。

### 3.2 契约映射(实测可用)

| Avalonia 回调 | 调什么 |
|---|---|
| `OnOpenGlInit(GlInterface gl)` | `lp_gl_init(fp, ctx)`,`fp` = `Marshal.GetFunctionPointerForDelegate` 包的 `gl.GetProcAddress` |
| `OnOpenGlRender(GlInterface gl, int fb)` | `lp_gl_wants_redraw()` → `lp_gl_render((uint)fb, w, h, 1)` → `lp_gl_swapped()` |
| `OnOpenGlDeinit(GlInterface gl)` | `lp_gl_uninit()` |

`w` / `h` 用 `Bounds.Size × TopLevel.RenderScaling` 算,实测与 Avalonia 给的 FBO 尺寸一致
(逻辑 1280×720 @1.5 缩放 → `fb=1 1920x1080`)。

**委托必须自己拿住**(`private GetProcAddressFn _gpaKeepAlive`),否则 GC 掉之后
mpv 回调进来是野指针。

### 3.3 复跑命令

```bash
cd docs/go-migration/spikes/s1-2
python mkclip.py clip1080p60.mp4 1920 1080 60 15      # 语料不入库,现造
bash ../../../../scripts/build-core.sh                # 出 build/core/lpcore.dll
(cd AvaloniaProbe && dotnet build -c Release -p:NoWarn=CA1416)

P=./AvaloniaProbe/bin/Release/net10.0/AvaloniaProbe.exe
C=../../../../build/core/lpcore.dll
$P --clip clip1080p60.mp4 --core $C --out out --tag final --gl angle --no-decorations \
   --seconds 12 --shots 6
```

开关:`--gl wgl|angle|default`、`--no-swapped`(反向验证)、`--no-anim`、`--no-video`
(不调 `lp_gl_render`,量宿主底噪)、`--no-core`(整条核心层都不碰)、`--resize`
(反复改尺寸,逼 Avalonia 重建 FBO)。环境变量:`LP_MPV_LOG`、
`LP_BLOCK_FOR_TARGET_TIME`、`LP_VIDEO_SYNC`。

### 3.4 判据怎么算的(这一节比结论重要)

「窗口里出画面」「半透明控件可见且不闪」不能靠看一眼。探针每隔一段截一次屏
(Win32 `CopyFromScreen`,视频层在 Avalonia 窗口内合成,所以截得到),然后:

| 判据 | 怎么量 | 阈值 |
|---|---|---|
| A 出画面 | 视频区两张截图之间的**逐像素**平均绝对差(64×36 灰度缩略图) | > 1.0 |
| B 叠加可见 | 叠加区相对视频区的品红偏移 `(R-G)+(B-G)` 之差 | > 10 |
| C 确实是半透明 | **叠加区**自己在两张截图之间的逐像素帧间差 —— 不透明的话它恒定 | > 0.5 |
| D 不闪 | B 的**最小值**(不是平均值)为正 = 每一帧叠加都在 | > 10 |

> **踩过的坑:** 第一版 A 和 C 用的是「区域均值之差」,判据 A 假红了 ——
> 取样点落在 testsrc2 的静止色条上,视频明明在动,均值恒为 `149,167,0`。
> **运动会在均值里互相抵消。** 改成逐像素 MAD 之后立刻正确。
> 这是 `AGENTS.md` §4.1 假绿五类里的第 4 类(语料/取样选错),只不过这次是假红。

## 4. 实测数据

### 4.0 环境(缺一项就没法复现)

| 项 | 值 |
|---|---|
| OS | Windows 11 Home China 10.0.26200 |
| 显示器 | 物理 2560×1600,逻辑 1707×1067,`RenderScaling` = 1.5 |
| **GPU(实际跑的)** | **Intel UHD 770 核显** —— 机器上还有 RTX 5060 Laptop,**没用上** |
| .NET | SDK 10.0.301,目标 `net10.0` |
| Avalonia | **11.3.20**(SPEC §7.2 写的是「Avalonia 11」,验的就是它)。12.1.1 已发布,**未验** |
| libmpv | `mpv v0.41.0-744-g304426c39`,FFmpeg `N-124930-g2576e0943` |
| Rust | 1.96.0,`x86_64-pc-windows-msvc` |
| GL · ANGLE | `OpenGL ES 3.0.0 (ANGLE 2.1.25606)` / `ANGLE (Intel, Intel(R) UHD Graphics, Direct3D11 vs_5_0 ps_5_0)` |
| GL · WGL | `4.0.0 - Build 32.0.101.6647` / `Intel(R) UHD Graphics 770` |
| 语料 | libmpv encode 的 `testsrc2` H.264:1080p60(36.3 MB)、4K24(76.1 MB)、4K60(141.3 MB),各 15s |
| 输出分辨率 | **统一 1920×1080**(逻辑 1280×720 × 1.5),和 SPIKE-1b 一致,数字可比 |

> **GPU 这条要显式说:** Avalonia 探针进程没有 `NvOptimusEnablement` 导出符号,
> 也没设按应用 GPU 偏好,所以落在核显上 —— 这是风险 R10 的现场,也是**刻意保留的主场景**
> (项目负责人 2026-08-31:「要测试集显的,有些人可能不装显卡的」)。
> 独显上的数字是另一个问题(S1.8),不能拿它替核显签字。

### 4.1 判据:四条全过

`--tag final --gl angle --clip clip1080p60.mp4 --seconds 12 --shots 6`

```
lp_gl_init       : OK
FBO(末次)       : fb=1 1920x1080
hwdec-current    : d3d11va-copy
video            : 1920x1080  container-fps=60.066742
lp_gl_render     : 751 次  ->  60.0 fps
lp_gl_swapped    : 751 次
播放推进         : 12.52s / 12.51s = 1.000  跟得上
frame-drop-count : +0

  #   t(s)   视频区 RGB          叠加区 RGB          品红偏移
  0    2.0     129,  126,  135     177,   47,  252     323.4
  1    4.1     127,  130,  126     181,   49,  248     335.4
  2    6.2     125,  129,  128     177,   47,  252     341.5
  3    8.3     125,  128,  128     177,   48,  251     335.4
  4   10.4     126,  130,  126     177,   47,  252     342.6
  5   12.4     128,  128,  128     177,   47,  252     335.9

  A 窗口里出画面        : 视频区逐像素帧间差 2.47  -> 通过
  B 半透明控件可见      : 最小品红偏移 323.4 -> 通过
  C 控件确实是半透明    : 叠加区逐像素帧间差 1.18 -> 通过(视频透上来了)
  D 不闪(每帧都在)    : 最小值 > 0 即每帧都可见 -> 通过
```

截图 `out/final-shot3.png` 目视复核:testsrc2 的色条透过底部 50% 品红带清晰可见
(红→粉、绿→灰紫、黄→鲑、蓝→紫、青→藕),白色文字压在最上层清晰,
左上角 mpv 自己的时间码 `00:00:09.750` 在走。**单窗口内合成、UI 压在视频上,成立。**

### 4.2 三档分辨率(WGL,干净配置:无动画、无截屏)

| 片源 | `lp_gl_render` | 播放推进 | 丢帧 | CPU 单核 |
|---|---:|---:|---:|---:|
| 1080p60 | **60.0 fps** | 1.000 | **+0** | 18~24% |
| 4K24 | **24.0 fps** | 0.999 | **+0** | 13~26% |
| 4K60 | 9.5~10.0 fps | 1.005 | +600 | 25~30% |

**判别器(同机、同片、同 libmpv,换成 SPIKE-1b 的裸 harness):**

| 片源 | 裸 harness(WGL) | Avalonia(WGL) |
|---|---:|---:|
| 1080p60 | 59.9 fps · CPU **15%** | 60.0 fps · CPU **18~24%** |
| 4K60 | **19.5 fps** · CPU 32% | **9.5~10.0 fps** · CPU 25~30% |

- 1080p60:Avalonia 比裸 harness 多约 **3~9 个百分点**的 CPU,这就是「多了一层真 UI 合成」的价钱。
  裸 harness 的 15% 和 SPIKE-1b 记的 14% 对得上,说明测试台没漂。
- 4K60:**Avalonia 只有裸 harness 的一半帧率(9.7 vs 19.5)。**
  两边都远低于实时,这块核显本来就跑不动 4K60(SPIKE-1b 同结论),
  但「合成一层要额外掏多少」在 4K60 上被放大了一倍。**这一条是新发现。**

### 4.3 GL 后端:ANGLE 是 Avalonia 的默认,也是贵的那个

1080p60 → 输出 1920×1080,全部满帧 0 丢帧,只比 CPU:

| 配置 | CPU 单核 |
|---|---:|
| 判据跑(ANGLE + 动画 + 6 张截屏) | 75~78% |
| **干净跑 · ANGLE**(Avalonia 默认后端) | **60%** |
| 宿主底噪 · ANGLE(`--no-video`,不调 `lp_gl_render`) | 39% |
| **干净跑 · WGL** | **18~24%** |
| 宿主底噪 · WGL | 13% |

**ANGLE 比 WGL 贵约 2.9 倍**,而且贵在**宿主底噪**上(39% vs 13%)——
不是 mpv 渲得慢,是 Avalonia 每帧把那张 FBO 合成上屏,走 ANGLE 的 D3D11 翻译层就要 39%。

SPEC §7.2 的【待验证】写「ANGLE 比原生 WGL 高一档」—— **实测证实,而且不止一档。**

### 4.4 `lp_gl_swapped` 的反向验证:**没有复现掉帧**

任务书与 `SPEC.md` §7.2 约束 2 都写:漏调它「实测 4K60 从满帧掉到 18fps」。
本轮**在两个宿主上都测不出任何差别**。

Avalonia 侧(WGL,12s,每格一次):

| 片源 | `block_for_target_time` | swapped 开 | swapped 关 |
|---|:---:|---:|---:|
| 1080p60 | 1 | 60.0 fps · 丢帧 0 | 60.0 fps · 丢帧 0 |
| 1080p60 | 0 | 60.0 fps · 丢帧 0 | 60.0 fps · 丢帧 0 |
| 4K24 | 1 | 24.0 fps · 丢帧 0 | 24.0 fps · 丢帧 0 |
| 4K24 | 0 | 23.9 fps · 丢帧 2 | 23.9 fps · 丢帧 2 |
| 4K60 | 1 | 9.7 fps · 丢帧 609 | 9.9 fps · 丢帧 605 |
| 4K60 | 0 | 9.7 fps · 丢帧 606 | 9.5 fps · 丢帧 613 |

换 `video-sync=display-resample`(report_swap 喂的正是这条路)再测:

| 片源 | swapped 开 | swapped 关 |
|---|---:|---:|
| 1080p60 | 60.0 fps · 丢帧 0 | 60.0 fps · 丢帧 0 |
| 4K24 | 24.0 fps · 丢帧 0 | 24.0 fps · 丢帧 0 |

**裸 harness**(从 `spike-1b-glbackend.py` 派生,唯一改动是 report_swap 门控,
同机同片,忙轮询无 vsync —— 这正是 SPIKE-1b 当时的条件):

| 片源 | `LP_REPORT_SWAP=1` | `LP_REPORT_SWAP=0` |
|---|---:|---:|
| 1080p60 | 59.9 fps · CPU 15% · 丢帧 35 | 59.4 fps · CPU 13% · 丢帧 42 |
| 4K60 | 19.5 fps · CPU 32% · 丢帧 502 | 19.7 fps · CPU 35% · 丢帧 494 |

另一个直接观测:**`estimated-display-fps` 无论开关都是空的**,`display-fps` 也是空的。
也就是说在 `vo=libmpv` + render API 这条路上,`report_swap` 根本没产出 mpv 的显示时序估计。

### 4.5 `block_for_target_time` 才是节奏源(新发现)

`mpv_render_context_render` 默认**阻塞到该帧的呈现时刻**。对裸 harness 无所谓,
对 Avalonia 是**把整条 UI 渲染线程按片源帧率钉住**:

| 片源 | `block=1`(mpv 默认)循环 tick | `block=0` 循环 tick | 渲染帧数 |
|---|---:|---:|---:|
| 4K24 | **~300 次 / 12s(25/s)** | ~778 次 / 12s(65/s) | 两者都是 24 fps |
| 1080p60 | ~722 次 / 12s(60/s) | ~755 次 / 12s | 两者都是 60 fps |

24 fps 的片子,`block=1` 时 Avalonia 的渲染线程只转 25 次/秒 ——
**OSD 动画、进度条拖动、悬停反馈全部只有 25 Hz。** 1080p60 看不出来是因为它本来就 60。

### 4.6 崩溃:`Unable to configure OpenGL FBO`,与路径 B 无关

```
Avalonia.OpenGL.OpenGlException: Unable to configure OpenGL FBO failed with error GL_NO_ERROR (0x00000000)
   at Avalonia.OpenGL.Controls.OpenGlControlBaseResources.BeginDraw(PixelSize size)
   at Avalonia.Rendering.Composition.Compositor.CommitCore()
   at Avalonia.Media.MediaContext.CommitCompositorsWithThrottling()
```

它崩在 Avalonia **重建自己的 FBO** 那一步。用 `--resize`(每 400ms 改一次窗口尺寸)
把偶发变必现之后,归因矩阵(每格 10 次,1080p60,5s):

| 组 | 碰核心层 | GL 后端 | 崩 |
|---|---|---|---:|
| D 纯 Avalonia | **完全不碰** | WGL | **2 / 10** |
| E 纯 Avalonia | 完全不碰 | ANGLE | 0 / 10 |
| F 接核心层 + 渲视频 | 接 | ANGLE | 0 / 10 |
| G 接核心层 + 渲视频 + 渲完复位 GL 状态 | 接 | WGL | 1 / 10 |
| H 接核心层 + 渲视频 + 不复位 | 接 | WGL | 2 / 10 |

**D 是决定性的:整条核心层一次都没调用,照样崩 2/10。** 所以这不是 libmpv 弄脏 GL 状态,
也不是路径 B 的问题,是 **Avalonia `OpenGlControlBase` 在 WGL 后端下重建 FBO 的问题**
(或 Intel WGL 驱动)。ANGLE 上 20 次 0 崩。

不加 `--resize` 时也会发生,频次约 **2/14 ~ 2/12**。

## 5. 结论

### 5.1 判据

> **路径 B 在 Avalonia 上成立。四条判据全部通过,有像素数据和截图。**
>
> · 窗口里出画面:1080p60 满帧 60.0、4K24 满帧 24.0,丢帧均为 0,`hwdec-current=d3d11va-copy`
> · 半透明 Avalonia 控件叠在视频上:可见(品红偏移 323~343)、真半透明(视频透上来)、不闪(每帧都在)
> · SPEC §7.2 那个窄接口(`fbo / w / h / flip_y`)**够用**,不需要给 UI 层开额外口子
>
> **`UI_PC.md` §8 不需要重写。**

### 5.2 两条被实测发现的顺序约束(SPEC 里没写)

**一、起播必须排在 `lp_gl_init` 之后。**

`vo=libmpv` 在 render context 存在之前初始化就是致命失败,而且 **mpv 不重试**:

```
[   0.013][i][cplayer] ● Video  --vid=1  (h264 1920x1080 60.0667 fps 19369 kbps) [default]
[   0.013][f][vo/libmpv] No render context set.
[   0.013][f][cplayer] Error opening/initializing the selected video_out (--vo) device.
[   0.013][v][lavf] deselect track 0
[   0.013][i][cplayer] Video: no video
```

宿主侧看到的现象是:**全程黑屏、`lp_gl_wants_redraw()` 恒 0(实测 12s 内 3029 次全 0)、
所有 mpv 属性为空,没有任何回调会喊。** 第一版探针就栽在这里。

在真实 UI 里这条极容易踩:导航到播放页时先发 `player.play`,而 GL 控件的
`OnOpenGlInit` 还没到 —— 结果是一个静默死掉的播放器。

**二、关停顺序:先拆 UI,再关核心。**

`lp_gl_uninit()` 必须排在关核心之前。反过来先关 mpv、render context 还活着,
Avalonia 合成器当场抛异常。SPEC §5.1 只写了「`lp_gl_uninit` 要在销毁 GL 上下文之前」,
**没写它和 `lp_shutdown` 谁先** —— 要补。

### 5.3 GL 状态复位:测了,无效,已删

一度怀疑 mpv 渲完留下脏 GL 状态(尤其 PBO 还绑着会让宿主的 `glTexImage2D` 读错源)。
在桩里加了复位(FBO / 纹理 / renderbuffer / program / PBO / VAO),
**实测崩溃率没有差别(1/10 vs 2/10),而纯 Avalonia 不碰核心层照样崩 2/10。**

假设被推翻,**代码已删**。留一段证明无效的猜测代码,下一个人会以为它在挡什么。

### 5.4 `lp_gl_swapped`:掉帧没复现,SPIKE-1b §7 第 3 条要订正

> **`SPIKE-1b-zero-copy.md` §7 第 3 条「漏调 `report_swap` 会让 4K60 从满帧掉到 18fps /
> 补上之后 1080p60 才达成满帧 60.0」在本机复现不出来。**

证据面:Avalonia 侧 8 组配置(三档分辨率 × `block_for_target_time` 0/1 ×
`video-sync` audio/display-resample),裸 harness 2 组(用 SPIKE-1b 自己的代码,
只把那一行改成门控)—— **全部无可测差别**,`estimated-display-fps` 开关都为空。

**最可能的解释是归因错位。** SPIKE-1b §7 第 2 条(对离屏窗口每帧 `eglSwapBuffers`)
自己就写着「改成渲进纹理 FBO、完全不 swap 之后**立刻正常**」—— 帧率是被第 2 条修好的,
第 3 条被顺带记了功。

**做法上不变:`lp_gl_swapped()` 继续调,继续留在契约里。** 它是 mpv 文档规定的
呈现时刻上报口,在别的显示器刷新率 / 别的 vsync 模型 / 别的平台上可能有用,而代价是零。
**但 SPEC 里那句「实测 4K60 从满帧掉到 18fps」必须改掉** ——
留着一个复现不了的「实测数字」,下一个人看到帧率不对时会照着它去追一个不存在的原因。
这正是文档腐坏最贵的一种。

### 5.5 性能:能用,但两件事要记进 PC 端规格

1. **别用 Avalonia 在 Windows 上的默认 GL 后端。** ANGLE 60% vs WGL 18~24%,
   差 2.9 倍,且差在宿主合成底噪上(39% vs 13%)。
   但 **WGL 有那个 FBO 重建崩溃(2/10 带 resize)而 ANGLE 没有** ——
   这是一条真实的取舍,不是随便挑一个。见 §8 遗留问题。
2. **`block_for_target_time` 默认会把 UI 渲染线程按片源帧率钉住。**
   24 fps 的片子 = 25 Hz 的 OSD。要不要关掉它、关掉之后谁来给节奏,
   是 `UI_PC.md` §8 必须回答的问题。

## 6. 若失败:备选方案

本次没失败,但把退路写清楚:

| 触发条件 | 走哪条 |
|---|---|
| WGL 的 FBO 崩溃在真机上收敛不掉,而 ANGLE 的 CPU 又超预算 | 先试 Avalonia 12.x(§8),再考虑退 A2 |
| 低端机型 4K24 下 CPU 余量不够(S1.10) | 退 A2 双顶层窗口(已在产验证,坑记录在 `docs/lessons/`) |
| Linux/Wayland 上路径 B 不成立(S1.4b) | 两端分别选路,核心层一行不动 —— 这正是三通道分层的价值 |

## 7. 对 SPEC 的影响

- [x] `SPEC.md` §7.2 —— 新增第 6 条硬约束:**起播必须排在 `lp_gl_init` 之后**(§5.2 一)
- [x] `SPEC.md` §7.2 约束 2 —— `lp_gl_swapped` 那句「实测 4K60 从满帧掉到 18fps」改成
      「未复现,但继续调」,并指到本报告 §5.4
- [x] `SPEC.md` §7.2 —— 「Avalonia 侧怎么接」的【待验证】改成【已验证】,补 ANGLE/WGL 实测
- [x] `SPEC.md` §7.2 —— 新增 `block_for_target_time` 一条
- [x] `SPEC.md` §5.1 —— `lp_gl_uninit` 注释补「必须排在 `lp_shutdown` 之前」
- [x] `TODO.md` S1.2 打勾;新增 S1.11(Avalonia WGL 崩溃)、S1.12(Avalonia 12.x)
- [x] `TODO.md` S1.2b 的条目文字订正(它还留着 SPIKE-1b 自己已经推翻的第一版结论)
- [x] `spikes/SPIKE-1b-zero-copy.md` §7 第 3 条 —— 加订正批注,指到本报告 §5.4

## 8. 遗留问题

1. 🔴 **Avalonia + WGL 的 FBO 重建崩溃**(§4.6)。纯 Avalonia 也崩,与我们无关,
   但它挡在「用便宜的 WGL」这条路上。下一步:Avalonia 12.x 上重测;查 Avalonia issue;
   若确为上游 bug,评估「固定窗口尺寸期间不重建 FBO」能不能绕开。
2. **Avalonia 12.1.1 未验。** 本次钉 11.3.20 是因为 SPEC §7.2 写的是「Avalonia 11」。
   12.x 的 `OpenGlControlBase` 是否同签名、崩溃是否已修,都没测。
3. **4K60 上 Avalonia 只有裸 harness 一半帧率**(9.7 vs 19.5)。这块核显本来就跑不动
   4K60,但这个倍数差没查根因。
4. **只测了核显。** 独显对照是 S1.8。
5. **Linux 一行没跑。** S1.4(X11)/ S1.4b(Wayland)。Wayland 上还要额外回答
   「窗口位置能不能记忆」(`UI_PC.md` §3.3)。
6. **没测多显示器 / 分数缩放切换 / 全屏切换**,这些正是 A2 时代几何 bug 的高发区,
   路径 B 下要重新验一遍才能说「那一类 bug 消灭了」。
7. **`estimated-display-fps` 恒空** 没查根因(§4.4)。它是不是 `vo=libmpv` 的固有行为,
   影响到未来要不要上 `video-sync=display-*`。
