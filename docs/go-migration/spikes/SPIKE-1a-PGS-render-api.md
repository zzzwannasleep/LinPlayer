# SPIKE-1a · libmpv 的 GL render API 会不会合成 PGS/SUP 图形字幕

> 状态:**已结题**
> 起止:2026-08-30(单次会话内完成)
> 关联:`SPEC.md` §7.3(路径 A/B/C 选型)、§15.3(硬解)

## 1. 要回答的问题

**用 mpv 的 render API 把画面渲进一张纹理时,PGS / SUP 这类图形字幕还显示不显示?**

## 2. 为什么它排在业务代码之前

`SPEC.md` §7.3 原文写着「**默认赌 B**」(render API + 纹理互操作)。

而项目负责人提出了一条来自真实经历的反对意见:

> 「之前写 flutter 就是因为纹理导致 libmpv 一直显示不了 PGS/SUP 这类图形字幕」

如果这条成立,路径 B 直接出局 —— 因为**图形字幕是蓝光原盘/WEB-DL 片源的常态**,
一个显示不了 PGS 的播放器在这个项目的目标场景里是残废的。
那样 §7.3 就要改押路径 A(子窗口 `--wid`),而 A 的代价是 **OSD 盖不上视频**,
整个 `UI_PC.md` §8(播放页与 OSD)要重写。

**所以这一条必须先测,而且要早于 SPIKE-1 的性能实测。**

## 3. 做法

### 3.1 环境

| 项 | 值 |
|---|---|
| 系统 | Windows 11 |
| GPU | Intel UHD Graphics 770(核显) |
| GL | `GL_VERSION = 4.6.0 - Build 32.0.101.6647`,WGL 桌面 OpenGL |
| libmpv | 仓库内 `crates/mpv/libmpv/libmpv-2.dll`,117 MB(完整版) |
| 语料 | 真实 PGS:`.sup` 25.5 MB,1359 条字幕,画布 1920×1080 |
| 驱动方式 | Python ctypes 直调 libmpv + Win32/WGL,无第三方依赖 |

复现脚本已收进本目录(零第三方依赖,只用 Python 标准库 + ctypes):

```
python spike-1a-pgs-parse.py <某个.sup>          # 列出所有字幕起止,挑一条长的取中点
python spike-1a-mkclip.py                        # 用 libmpv 自己 encode 一个 12s 真 H.264 片
python spike-1a-pgs.py <某个.sup> <中点秒数>      # 跑矩阵
```

**结论所依赖的数据全部贴在下面第 4 节,不依赖脚本还在不在。**

### 3.2 实验设计(带正负对照)

一个「开关字幕看画面变不变」的实验,最容易出的假象有两个:
**① 视频本身就没渲染出来** ② **差异其实是两次渲染之间的抖动噪声**。
所以设计里各加了一个对照:

| 控制项 | 做法 |
|---|---|
| **正对照** | 断言 `track-list` 里真的有一条 `codec=hdmv_pgs_subtitle` 且 `selected=yes` 的外挂轨;断言画面非黑像素占比 |
| **负对照** | **同一设置连渲两次求差** = 噪声基线 N。只有信号 S ≫ N 才算数 |
| 去噪 | `dither=no` + `temporal-dither=no`,让噪声基线可以真的降到 0 |
| 静态化 | 视频源静态 + `pause=yes`,差分里只剩字幕 |
| 定位 | 用 `sub-delay` 把第 535 秒那条字幕挪到视频第 0 秒,**避开 lavfi 不可 seek** |
| 交叉验证 | 自己写的 PGS 解析器算出该条为 `532.824~537.370`;mpv 报 `sub-start=532.823956 sub-end=537.370167` —— **两个独立实现互证** |

### 3.3 矩阵

| 轮次 | 渲染目标 | 视频源 | 硬解 |
|---|---|---|---|
| v2 | `fbo=0`(窗口默认帧缓冲) | lavfi 静态彩条 | 软解 |
| v3 | **自建纹理 FBO** | lavfi 静态彩条 | — |
| v4 | **自建纹理 FBO** | **真 H.264 文件**(用 libmpv 自己 encode 出来的 12s 片) | 软解 / auto / 显式 d3d11va |

## 4. 实测数据

### 4.1 v2 · fbo=0

```
GL_VERSION  = 4.6.0 - Build 32.0.101.6647
GL_RENDERER = Intel(R) UHD Graphics 770
轨道:#0 video wrapped_avframe selected=yes
      #1 sub   hdmv_pgs_subtitle external=yes selected=yes
sub-start=532.823956  sub-end=537.370167

视频渲染确认 : 非黑像素 778519 / 921600 (84.5%)
噪声基线   N : 0
字幕信号   S : 21682  (2.353%)
差异包围盒   : x 301..977  y 22..88   (677×67,位于画面底部)
```

### 4.2 v3 · 自建纹理 FBO(lavfi 源)

```
用例           PGS轨   视频非黑   噪声N   字幕S
tex_swdec     True    90.8%     0       21682
tex_hwdec     True    90.8%     0       21682
fbo0_hwdec    True    84.5%     0       21682
```

> ⚠️ 这一轮的 `hwdec` 维度**实际上没被测到** —— lavfi 出的是 `wrapped_avframe` 裸帧,
> 没有可硬解的东西,`hwdec-current` 恒为 `no`。这是 v4 存在的理由。

### 4.3 v4 · 自建纹理 FBO + 真 H.264 + 真硬解

```
用例             hwdec-current   PGS轨   视频非黑   噪声N   字幕S
swdec            no              True    100.0%    0       25827
hwdec_auto       d3d11va-copy    True    100.0%    0       25827
hwdec_d3d11va    no              True    100.0%    0       25827

包围盒 x301..978 y21..88(677×68,画面底部)
```

**截图肉眼确认**:字幕内容为中英双行,渲染完整、位置正确、描边正常。

## 5. 结论

### 5.1 主结论

> **libmpv 的 GL render API 会正常合成 PGS/SUP 图形字幕,渲进自建纹理 FBO 也一样。**
> **「纹理导致 PGS 显示不了」这个归因不成立。路径 B 没有被 PGS 排除。**

证据强度:6 个用例全部 S ≈ 2.2~2.8 万像素、噪声基线恒为 0、差异区域聚成
677×67 的一块且位于画面底部、截图肉眼可辨认字幕文字。

### 5.2 那当年 Flutter 为什么不显示?

**没有直接证据,但代码里有一个高度可疑点,而且是可检验的。**

从 git 历史里取出当年的实现(`0dd295fe^:android/app/src/main/cpp/mpv_render_jni.cpp`),
它建的 EGL 上下文是:

```c
const EGLint contextAttribs[] = {
    EGL_CONTEXT_CLIENT_VERSION, 2,      // ← OpenGL ES 2.0
    EGL_NONE
};
...
{MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_OPENGL_ES},
```

**GLES 2.0。** mpv 的 GPU 渲染器在 GLES 2 上功能被大幅裁剪(它面向 GLES 3.0+ 设计)。
本次实测跑的是**桌面 OpenGL 4.6**,两者不是一回事。

另外当年那份实现还有两个可疑处:没有传 `MPV_RENDER_PARAM_ADVANCED_CONTROL`;
渲染循环是 `usleep(16000)` 轮询而不是靠 `update` 回调驱动。

**这一条列为「未证实的最可能原因」,不写进 SPEC 当结论。**
真要确认,需要在 Android 上用 GLES 2 与 GLES 3 各跑一次同样的 A/B ——
但**新架构下已经没有理由再用 GLES 2**,所以这个确认的优先级很低。

### 5.3 顺带测出的一条与 SPEC 冲突的事实 🔴

| 设置 | 实测 `hwdec-current` |
|---|---|
| `hwdec=auto` | **`d3d11va-copy`** |
| `hwdec=d3d11va`(显式要零拷贝) | **`no`** —— 起不来,回落软解 |

也就是说:**在桌面 OpenGL(WGL)上跑 render API 时,`d3d11va` 零拷贝拿不到**,
最好只能到 `d3d11va-copy`(每帧一次显存→内存→显存的拷贝)。

这与 `SPEC.md` §15.3 写的「Windows 默认 `d3d11va`,零拷贝,是 Win 上的最佳档」**冲突** ——
那条结论来自现有 Rust 版,而现有 Rust 版走的是路径 A(mpv 自己拥有窗口、自己建 D3D11 设备)。
**路径 B 会让这条结论失效。**

要拿回零拷贝,GL 上下文得换成 **ANGLE(EGL over D3D11)**,让 mpv 和 UI 共享同一个 D3D11 设备 ——
这正是 §7.3 里 "ANGLE 与 D3D11 共享句柄的同步(keyed mutex)" 那句话背后的工作量。

**这条要进 SPIKE-1 主体的实测项**:路径 B 在 ANGLE 下能否拿到 `d3d11va` 零拷贝,
以及 `d3d11va-copy` 在 4K60 下的实际代价。

## 6. 对 SPEC 的影响

| 文件 | 改动 |
|---|---|
| `SPEC.md` §7.3 | 加「PGS 已实测通过」的结论 + 把零拷贝问题列为 B 的新增风险 |
| `SPEC.md` §15.3 | 「Windows 默认 d3d11va 零拷贝」加限定:**那是路径 A 的结论** |
| `TODO.md` SPIKE-1 | 新增 ANGLE + 零拷贝实测项 |
| 风险登记册 | 新增 R14 |

## 7. 本次实验自己踩的坑(留给下一个重跑的人)

1. **mpv 的事件号:`START_FILE=6` / `END_FILE=7` / `FILE_LOADED=8`。**
   第一版把 6 当成 FILE_LOADED,于是在文件还没加载完就查属性,
   `track-list/count` 全是 0、`video-format` 是 `None` —— 对照信息全废,结论不能用。
2. **必须有负对照。** 第一版只有「开关字幕的差异 = 2 万像素」这一个数字,
   而它可能全是抖动噪声。加上 `dither=no` + 同设置连渲两次之后,噪声基线降到 0,
   那 2 万像素才有意义。
3. **`sub-delay` 幅度很大时不要再叠 seek。** v4 第一版用「seek 到 5s + sub-delay −530s」,
   结果 `sub-start` 是 `None`(外挂字幕流没跟上),三个用例全部 S=0 ——
   看起来像"硬解下 PGS 不显示",实际是实验设置坏了。**改成不 seek、停在 0 秒**后立刻正常。
4. **64 位 Win32 的所有句柄都要显式声明成 `c_void_p`。** 不声明 ctypes 按 `c_int` 转,
   句柄大于 2^31 时直接 `OverflowError`。
5. **lavfi 源测不了硬解。** 它出的是裸帧,`hwdec-current` 恒为 `no`。
   要测硬解必须有真的编码过的文件 —— 可以用 libmpv 自己的 encode 模式现造一个。
