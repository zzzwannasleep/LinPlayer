# 超分与画质增强知识

> 面向 Go 核心层重写。外部事实带 URL,代码结论带 `文件:行号`(行号对应写作时的 `main` 分支,
> 提交 `85b47417`)。**凡未经本人在本仓库/官方原文核实的,一律标「未确认」并写明查过哪里** ——
> 不写「应该/可能/大概」。

---

## 0. 一句话 + 最重要的一个区分

**一句话**:我们没有自研任何画质算法。我们做的是「把一批第三方 mpv user shader(`.glsl`)
编进二进制 → 首次使用时落盘 → 按**档位**组合成 shader 链 + 一组调好的参数 → 通过 libmpv 的
`glsl-shaders` / `glsl-shader-opts` 两个属性挂上去 → **回读校验它到底会不会跑**」。
全部算力在 GPU 上由 mpv/libplacebo 执行,Rust(将来 Go)侧只负责**选链、调参、说实话**。

### ★ 最重要的一个区分:锐化/去噪 ≠ 放大

这是本项目在超分这块最贵的一课,`apps/desktop/src/shaders.rs:7-17` 把它写在文件头:

```
//! **核心教训:锐化/去噪 和 放大 是两件事,别糅成一坨。**
//! 此前六档全是 Anime4K 的 CNN **放大**链,而 Anime4K 每个 CNN pass 都带门槛
//! `//!WHEN OUTPUT.w MAIN.w / 1.200 > ...` —— 输出没比源大 1.2 倍就**一帧都不跑**。
//! 于是窗口里播 1080p(输出 1770×1080 < 源 1920×1080)点什么档位都毫无变化。
```

两类 shader 的**判据是 `//!WHEN` 这一行里比的是什么**,不是名字、不是直觉:

| 类别 | `//!WHEN` 比的是 | 窗口模式(输出 ≤ 源) | 本仓库实例 |
|---|---|---|---|
| **效果类**(锐化/去噪) | **参数**,或干脆没有 `//!WHEN` | ✅ 照跑 | `AMD_CAS_luma_RT.glsl:22` = `//!WHEN STR` |
| **放大类** | **`OUTPUT.` 与源尺寸的比值** | ❌ 一帧都不跑 | `Anime4K_Upscale_CNN_x2_M.glsl:31` = `//!WHEN OUTPUT.w MAIN.w / 1.200 > OUTPUT.h MAIN.h / 1.200 > *` |

代码里这个判据是**从 shader 源现算的,不是手工白名单** —— `apps/desktop/src/shaders.rs:141-145`:

```rust
fn is_upscale_gated(name: &str) -> bool {
    body_of(name)
        .lines()
        .any(|l| l.starts_with("//!WHEN") && l.contains("OUTPUT."))
}
```

理由写在 `shaders.rs:140`:「**从源里现算,不手工维护名单**:换 shader 文件时结论自动跟着变,
不会留下过期的白名单。」Go 侧必须原样保留这个性质(见第 7 节)。

**推论**:用户说「我开了超分没变化」,第一件要问的不是「你显卡什么」,而是
**「你是全屏还是窗口?你选的是哪一族?」**。完整排查树见第 3 节。

---

## 1. 模型全景

**本仓库实际打包了哪些**(17 个,`apps/desktop/shaders/`,由 `apps/desktop/src/shaders.rs:38-120`
的 `FILES` 常量 `include_str!` 编入二进制):

| 模型 / shader | 定位 | 属锐化类还是放大类 | 适用片源 | 开销 | 出处 URL |
|---|---|---|---|---|---|
| **Anime4K** Denoise_Bilateral_{Mean,Mode} | 双边去噪 | 效果类(**无 `//!WHEN`**,永远跑) | 动画,有压缩噪点/色带 | 低 | https://github.com/bloc97/Anime4K |
| **Anime4K** Upscale_CNN_x2_{S,M,L,VL,UL} | CNN 2× 放大 | 放大类(`OUTPUT.w MAIN.w / 1.200 >`) | 原生 1080p 动画 | 每升一档 ×2 | 同上 |
| **Anime4K** Upscale_Denoise_CNN_x2_* | CNN 放大 + 去噪一体 | 放大类 | 降采样过/噪点多的动画 | 同上,VL 本地 143 KB | 同上 |
| **Anime4K** Clamp_Highlights | 去振铃辅助(统计高光后钳位) | 辅助(自身无可见效果) | 配合放大链 | 极低 | 同上 |
| **Anime4K** AutoDownscalePre_x{2,4} | 把中间放大结果降回显示分辨率 | 辅助 | 配合放大链 | 极低 | 同上 |
| **ArtCNN** C4F16 | luma-only 4 层 CNN 放大 | 放大类(`OUTPUT.w LUMA.w 1.200 * >`) | 动画,追求清晰/开销比 | 本地 213 KB 单文件 | https://github.com/Artoriuz/ArtCNN |
| **AMD CAS**(`AMD_CAS_luma_RT`) | 对比度自适应锐化 | 效果类(`//!WHEN STR`) | 通用 | 极低 | AMD FidelityFX,mpv 移植见下 |
| **AMD FSR1 EASU** | FSR1 边缘自适应放大 | 放大类(`OUTPUT.w HOOKED.w 1.0 * >`) | 通用 | 低 | 同上 |
| **AMD FSR1 RCAS** | FSR1 配套锐化 | 效果类(`//!WHEN SHARP 4.0 <`) | 通用 | 极低 | 同上 |
| **AMD BCAS** | 双边 CAS(锐化 + 按局部方差压噪) | 效果类(`//!WHEN STR`) | 通用,噪点较多时 | 低 | 同上 |
| **NVIDIA NIS** NVSharpen | NVIDIA Image Scaling 的纯锐化半 | 效果类(`//!WHEN SHARP`) | 通用 | 低 | NVIDIA Image Scaling SDK |
| **NVIDIA NIS** NVScaler | NIS 放大 + 内建锐化 | 放大类(`OUTPUT.w HOOKED.w 1.0 * >`) | 通用 | 中 | 同上 |
| **Adaptive_sharpen_lite_luma** | 按局部对比自适应锐化 | 效果类(`//!WHEN STR`) | 通用,过冲小 | 低(luma-only) | 见「来源」 |
| **FineSharp** | RemoveGrain 系,先柔化再锐化 | 效果类(`//!WHEN SSTR`) | 通用,细节多不易起噪 | 低(luma-only) | 见「来源」 |
| **aWarpSharp2** | 把像素往边缘推,收紧线条 | 效果类(`//!WHEN STR`) | **动漫线稿最明显** | 低(luma-only) | 见「来源」 |

#### ★ 来源与授权(逐个文件读 `.glsl` 头部的 LICENSE 段,不是靠 `shaders.rs` 的转述)

`apps/desktop/src/shaders.rs:36-37` 只写了「取自 hooke007/mpv_PlayKit」。但**每个 `.glsl`
文件头部自带原始出处 URL**,这才是一手来源:

| 本地文件 | 第 1 行都是 | 原始出处(文件头 LICENSE 段) |
|---|---|---|
| `AMD_CAS_luma_RT.glsl`、`AMD_BCAS_RT.glsl` | `// 文档 https://github.com/hooke007/mpv_PlayKit/wiki/4_GLSL` | FidelityFX-SDK **v1.1.4** `sdk/include/FidelityFX/gpu/cas/ffx_cas.h` |
| `AMD_FSR1_EASU.glsl`、`AMD_FSR1_RCAS_RT.glsl` | 同上 | FidelityFX-SDK **v2.1.0** `Kits/FidelityFX/upscalers/fsr3/include/gpu/fsr1/ffx_fsr1.h` |
| `NVSharpen_RT.glsl`、`NVScaler_RT.glsl` | 同上 | NVIDIAGameWorks/NVIDIAImageScaling **v1.0.3** |
| `Adaptive_sharpen_lite_luma_RT.glsl` | 同上 | **bacondither**,`Copyright (c) 2015-2021`,BSD 式三条款许可(全文在文件头) |
| `FineSharp_RT.glsl` | 同上 | Doom9 论坛原帖 https://forum.doom9.org/showthread.php?p=1569035#post1569035(RAW 版)+ Shiandow 版 `...?p=1698648#post1698648` |
| `aWarpSharp2_RT.glsl` | 同上 | AviSynth 版 http://ldesoras.fr/src/avs/awarpsharp2-2015.12.30.zip;VapourSynth 版 https://github.com/dubhater/vapoursynth-awarpsharp2 |
| `ArtCNN_C4F16.glsl` | 同上 | **MIT**,`Copyright (c) 2024 Joao Chrisostomo, Kacper Michajłow` |
| `Anime4K_*.glsl` | 同上 | **MIT**,`Copyright (c) 2019-2021 bloc97` |

Anime4K 仓库整体 License 经 GitHub API 核实同为 **MIT**(`spdx_id: "MIT"`,
https://api.github.com/repos/bloc97/Anime4K)。

#### ★★ `_RT` 后缀不只是「参数可调」—— 它换掉了触发条件(本人 2026-08-30 A/B 实测)

社区里另一套广为流传的 AMD/NVIDIA mpv 移植是 agyild 的 gist。**它和我们用的 `_RT` 版
在 `//!WHEN` 上语义完全不同**,直接决定「窗口模式下跑不跑」:

| shader | agyild 版(gist,基于 SDK v1.0.2) | 我们的 `_RT` 版(PlayKit,基于 SDK v1.1.4 / v1.0.3) |
|---|---|---|
| CAS | `//!WHEN OUTPUT.w OUTPUT.h * LUMA.w LUMA.h * / 1.0 >` → **放大类** | `//!WHEN STR` → **效果类,窗口也跑** |
| NVSharpen | `//!WHEN OUTPUT.w OUTPUT.h * LUMA.w LUMA.h * / 1.0 >` → **放大类** | `//!WHEN SHARP` → **效果类,窗口也跑** |

验证命令(可复现):
```
curl -sL https://gist.githubusercontent.com/agyild/bbb4e58298b2f86aa24da3032a0d2ee6/raw | grep '^//!WHEN'
grep '^//!WHEN' apps/desktop/shaders/AMD_CAS_luma_RT.glsl
```

**这条对 Go 迁移是硬约束**:我们整个「FSR 锐化三档 + NVIDIA 锐化三档窗口模式也生效」的设计,
**依赖的是 PlayKit 的 `_RT` 版本,不是 agyild 版**。谁哪天为了「换个更权威的上游」把文件换成
agyild 的,这六档会在窗口模式下静默变成一帧不跑 —— 画面毫无变化,mpv 不报错。
好消息是**现有测试会当场变红**:`is_upscale_gated()` 扫的是 `//!WHEN` 里有没有 `OUTPUT.`,
换了文件它立刻判成放大类,于是 `sharpen_denoise_levels_work_in_windowed_mode`
(`apps/desktop/src/shaders.rs:698-710`,显式列了 `fsr_sharp_l/m/h` 与 `nv_sharp_l/m/h`)会失败。
**这个测试必须原样移植到 Go**(见第 7 节)。

### 1.1 Anime4K

**是什么**(官方 README 原文):"A set of open-source, high-quality real-time anime
upscaling/denoising algorithms that can be implemented in any programming language."
目标片源是 **"native 1080p anime encoded with h.264, h.265 or VC-1"**。作者 bloc97。
出处:https://github.com/bloc97/Anime4K

**官方明确说不适用**(README 原文):"Downscaled 720p, 480p or standard definition anime
(eg. DVDs)" 和 "Older anime (especially pre-digital era production)" —— 理由是这些片源自带
反交错缺陷、摄影模糊、振铃和胶片颗粒。同时声明它**不是 SRGAN 的替代品**:SRGAN 在低分辨率/
重度劣化图像上表现好得多,但不实时。

**版本演进**(README 原文):

- **v3**:"The monolithic Anime4K shader is broken into modular components",并做了
  "a complete overhaul of the algorithm(s) for speed, quality and efficiency"。
- **v4**:"introduces a line reconstruction algorithm that aims to tackle the distribution
  shift problem seen in 1080p anime"。
- v1 / v2 的具体差异:**README 里没写,未确认**(查过 README 与 `md/` 目录下的 11 个
  `GLSL_Instructions*.md` 文件名清单,均无版本对照表)。

**实测到的版本混装**(本人 2026-08-30 拉 raw 文件核对):master 分支上 **Restore 族与
Clamp_Highlights 是 v4.0,Upscale / Upscale+Denoise / Denoise / Deblur / Thin 仍是 v3.2**。
证据是各文件的 `//!DESC` 行,例如
`glsl/Restore/Anime4K_Restore_CNN_M.glsl` 第一行 DESC 是 `Anime4K-v4.0-Restore-CNN-(M)-Conv-4x3x3x3`,
而 `glsl/Upscale/Anime4K_Upscale_CNN_x2_M.glsl` 是 `Anime4K-v3.2-Upscale-CNN-x2-(M)-Conv-4x3x3x3`。
**即 v4 只换掉了 Restore(线条重建),放大器没动。** 我们本地四个 Anime4K 文件的 `//!DESC`
与上游 master 逐字一致(已 A/B 对过),不是陈旧副本。

#### shader 文件完整清单(GitHub API 拉 `glsl/` 全树,2026-08-30)

来源:`https://api.github.com/repos/bloc97/Anime4K/git/trees/master?recursive=1`

| 族 | 目录 | 文件 |
|---|---|---|
| **Restore**(CNN) | `glsl/Restore/` | `Anime4K_Restore_CNN_{S,M,L,VL,UL}.glsl` |
| **Restore Soft** | `glsl/Restore/` | `Anime4K_Restore_CNN_Soft_{S,M,L,VL,UL}.glsl` |
| **Restore GAN** | `glsl/Restore/` | `Anime4K_Restore_GAN_UL.glsl`、`Anime4K_Restore_GAN_UUL.glsl` |
| **Clamp** | `glsl/Restore/` | `Anime4K_Clamp_Highlights.glsl` |
| **Upscale**(CNN) | `glsl/Upscale/` | `Anime4K_Upscale_CNN_x2_{S,M,L,VL,UL}.glsl` |
| **Upscale GAN** | `glsl/Upscale/` | `Anime4K_Upscale_GAN_x2_{S,M}`、`_x3_{L,VL}`、`_x4_{UL,UUL}.glsl` |
| **Upscale 传统** | `glsl/Upscale/` | `Anime4K_Upscale_{Original,DoG,DTD}_x2.glsl`、`Anime4K_Upscale_Deblur_{DoG,Original}_x2.glsl` |
| **Upscale 3D** | `glsl/Upscale/` | `Anime4K_3DGraphics_Upscale_x2_US.glsl`、`Anime4K_3DGraphics_AA_Upscale_x2_US.glsl` |
| **AutoDownscalePre** | `glsl/Upscale/` | `Anime4K_AutoDownscalePre_x2.glsl`、`_x4.glsl` |
| **Upscale+Denoise** | `glsl/Upscale+Denoise/` | `Anime4K_Upscale_Denoise_CNN_x2_{S,M,L,VL,UL}.glsl` |
| **Denoise** | `glsl/Denoise/` | `Anime4K_Denoise_Bilateral_{Mean,Median,Mode}.glsl` |
| **Deblur** | `glsl/Deblur/` | `Anime4K_Deblur_{DoG,Original}.glsl` |
| **Thin**(实验) | `glsl/Experimental-Effects/` | `Anime4K_Thin_{VeryFast,Fast,HQ}.glsl` |
| **Darken**(实验) | `glsl/Experimental-Effects/` | `Anime4K_Darken_{VeryFast,Fast,HQ}.glsl` |

**AutoDownscalePre 的作用**:它不是放大器也不是效果器,是**降采样时机控制**。本地
`apps/desktop/shaders/Anime4K_AutoDownscalePre_x2.glsl:30` 的门槛是一个**区间闸**:

```
//!WHEN OUTPUT.w NATIVE.w / 2.0 < OUTPUT.h NATIVE.h / 2.0 < * OUTPUT.w NATIVE.w / 1.2 > OUTPUT.h NATIVE.h / 1.2 > * *
```

即「输出在源的 1.2 ~ 2.0 倍之间」才跑;`_x4.glsl:30` 管 2.4 ~ 4.0 倍。作用是在 CNN 把画面翻到
2×/4× 之后,**先降到实际输出尺寸再交给下一级 CNN**,避免下一级在超出必要的分辨率上白烧算力。
⚠️ 它的基准是 **`NATIVE`,不是 `MAIN`** —— 本仓库的 `when_ratio_matches_shader_source` 测试
(`apps/desktop/src/shaders.rs:735-759`)**故意只查 MAIN 门槛**,注释在 `shaders.rs:733-734`:
「故意不查 AutoDownscalePre 的 `NATIVE` 区间闸(x2 管 1.2~2.0 倍、x4 管 2.4~4.0 倍),
那是另一套机制。」

**S/M/L/VL/UL 的含义**:官方只给了**开销**口径,没给结构口径。
`md/GLSL_Instructions_Advanced.md` 原文:"Each step in size for CNN shaders doubles the
processing time. For example, if the M version takes 5ms to run, the L version should take
approximately 10ms to run, 20ms for VL and so on."
**这些后缀具体对应几层/几通道:官方文档未说明,未确认。**(查过 README 与
`GLSL_Instructions_Advanced.md`。)可以从 shader 源的 `//!DESC` 里的卷积规格反推 ——
本地 `Anime4K_Upscale_CNN_x2_M.glsl:24` 是 `Conv-4x3x3x3` 起手、后续全是 `Conv-4x3x3x8`,
而 `Anime4K_Upscale_Denoise_CNN_x2_VL.glsl:68` 是 `Conv-4x3x3x16` —— **VL 的通道数是 M 的 2 倍**。

`_Soft_` 变体:官方在预设里把它用于 Mode B(见下表),对应 README 说的低模糊片源。
**`_Soft_` 与普通 Restore 的算法差异:官方文档未说明,未确认。**

#### 官方预设组合(逐字从官方模板 `input.conf` 抄,不是二手转述)

来源:https://github.com/bloc97/Anime4K/blob/master/md/Template/GLSL_Windows_High-end/input.conf
与 `.../GLSL_Windows_Low-end/input.conf`

**HQ(高端 GPU)**:

| 模式 | 完整 shader 链(顺序即 `glsl-shaders` 的分号顺序) |
|---|---|
| **A (HQ)** | `Clamp_Highlights` → `Restore_CNN_VL` → `Upscale_CNN_x2_VL` → `AutoDownscalePre_x2` → `AutoDownscalePre_x4` → `Upscale_CNN_x2_M` |
| **B (HQ)** | `Clamp_Highlights` → `Restore_CNN_Soft_VL` → `Upscale_CNN_x2_VL` → `AutoDownscalePre_x2` → `AutoDownscalePre_x4` → `Upscale_CNN_x2_M` |
| **C (HQ)** | `Clamp_Highlights` → `Upscale_Denoise_CNN_x2_VL` → `AutoDownscalePre_x2` → `AutoDownscalePre_x4` → `Upscale_CNN_x2_M` |
| **A+A (HQ)** | `Clamp_Highlights` → `Restore_CNN_VL` → `Upscale_CNN_x2_VL` → **`Restore_CNN_M`** → `AutoDownscalePre_x2` → `AutoDownscalePre_x4` → `Upscale_CNN_x2_M` |
| **B+B (HQ)** | `Clamp_Highlights` → `Restore_CNN_Soft_VL` → `Upscale_CNN_x2_VL` → `AutoDownscalePre_x2` → `AutoDownscalePre_x4` → **`Restore_CNN_Soft_M`** → `Upscale_CNN_x2_M` |
| **C+A (HQ)** | `Clamp_Highlights` → `Upscale_Denoise_CNN_x2_VL` → `AutoDownscalePre_x2` → `AutoDownscalePre_x4` → **`Restore_CNN_M`** → `Upscale_CNN_x2_M` |

**Fast(低端 GPU)**:同结构,把 `VL`→`M`、末尾 `Upscale_CNN_x2_M`→`_S`、第二个 Restore `M`→`S`。

注意 A+A 与 B+B 的第二个 Restore **插入位置不同**(A+A 在 AutoDownscalePre 之前,
B+B 在之后)。这不是我抄错 —— HQ 与 Fast 两份 input.conf 都是这样写的。**原因官方未说明,未确认。**

**各模式适用片源**(`GLSL_Instructions_Advanced.md`):

- **Mode A**:"Most 1080p anime, Some older 720p anime, Most old SD anime" —— 高模糊/重采样/重压缩
- **Mode B**:"Some 1080p anime, Most 720p anime, 1080p->720p downscaled anime" —— 低模糊
- **Mode C**:"1080p->480p downscaled anime, Very rarely, 1080p animated movies, Images with
  no degradation, Wallpapers, Pixiv art"
- **A+A / B+B / C+A**:片源同 A/B/C,但**仅用于 2 倍以上放大**("for x2+ upscaling only")

#### Restore 系为什么会有害 —— 三条独立证据

1. **官方自己说的**(`GLSL_Instructions_Advanced.md`):"Adding a `Restore` shader after an
   upscaling step improves perceptual quality, but makes processing slower and **might introduce
   artifacts**";并明确 A+A 在原生 1080p 上 "will most likely **oversharpen and degrade the
   image**",可能 "cause severe **ringing, banding, aliasing**"。
2. **我们的用户两次否掉**:`apps/desktop/src/shaders.rs:25-26` 记录 ——「Restore CNN:用户
   2026-07-11(a5e21885)明确否掉 —— 动态画面边缘振铃/拖影,且最吃显卡。现在他又问了一遍
   『为什么要用还原』。**别加回来**,有测试钉。」测试是 `apps/desktop/src/shaders.rs:683-694`
   的 `no_preset_uses_restore`。
3. **★ 结构性原因(本人 2026-08-30 拉 raw 实测,这条最要紧)**:
   **Restore 族的 `//!WHEN` 行数是 0** —— 它**没有任何尺寸门槛,在源分辨率上无条件跑**。
   同样为 0 的还有 Deblur、Thin、Denoise_Bilateral 三族:

   | 上游文件 | `grep -c '^//!WHEN'` |
   |---|---|
   | `glsl/Restore/Anime4K_Restore_CNN_M.glsl` | 0 |
   | `glsl/Deblur/Anime4K_Deblur_DoG.glsl` | 0 |
   | `glsl/Experimental-Effects/Anime4K_Thin_HQ.glsl` | 0 |
   | `glsl/Denoise/Anime4K_Denoise_Bilateral_Median.glsl` | 0 |
   | `glsl/Upscale/Anime4K_Upscale_CNN_x2_M.glsl` | 有(`OUTPUT.w MAIN.w / 1.200 >`) |

   这直接解释了本项目 commit `bcdd7cb5` 里的那句判决:「抄错的那版表里 Restore_CNN_M
   **没有 `//!WHEN`**(实测 `grep -c WHEN = 0`),无条件在 1080p 上跑,还跑在核显上。」
   —— **一个重型 CNN + 零门槛 + 核显 = 「非常非常卡」。** 详见第 6 节。

   反过来说也成立:**Restore/Deblur/Thin/Denoise 这四族才是「窗口模式下也生效」的那一类**,
   跟 CAS/RCAS/NVSharpen 属于同一类(第 0 节的「效果类」)。我们只用了 Denoise 一族。

#### 性能开销量级

- 官方给的是**相对**口径,不是绝对 benchmark 表:"Each step in size for CNN shaders doubles
  the processing time"(`GLSL_Instructions_Advanced.md`)。
- 官方给的**预算**口径:同文档给出帧时间上限 —— 24fps → 41ms("The target for 24fps video
  is usually ~41ms")、30fps → 33ms、60fps → 16ms。
- README 提到 "Performance numbers are obtained using a Vega64 GPU and are tested using `UL`
  shader variants. The fast version is for `M` variants." —— **但对应的具体 fps/ms 数字在我
  拉到的 README 正文里没有。绝对性能表:未确认。**
- **我们自己没有任何 shader 开销的量化数据。** 仓库里没有 benchmark 脚本,没有帧时间日志
  (`grep -rn "frame-time\|render-time" --include=*.rs` 无命中)。见第 9 节。

### 1.2 ArtCNN

**是什么**(官方 README 原文):"ArtCNN is a collection of simple SISR models aimed at anime
content."(SISR = 单图超分)出处:https://github.com/Artoriuz/ArtCNN
README 里**没有提到真人片源的适用性**(查过 README 全文)。

**和 Anime4K 的定位差异**:Anime4K 是一整套模块(还原/放大/去噪/去模糊/细线),要按片源拼链;
ArtCNN 是**单文件 luma 放大器**,一个文件就是一条完整链,不需要 Clamp/AutoDownscalePre 之类的辅助 pass。
本仓库把它归进 Anime4K 家族,理由写在 `apps/desktop/src/shaders.rs:302-303`:「同为动漫向 luma CNN,
但比 `Upscale_CNN_x2_M` 清晰、比 VL 便宜 —— 用户要的『清晰且不吃性能』就是这一档」。

**变体命名**(官方 README 只给了部分定义,以下区分开写):

| 记号 | 含义 | 出处 |
|---|---|---|
| `C` / `R` | 架构族:`C` 是卷积式(偏速度),`R` 是残差块式(偏质量) | README **未逐字定义字母**,是按上下文归纳的 —— 标为**未确认** |
| `F<n>` | 每层滤波器数,如 `F32` = 32、`F96` = 96 | README |
| `_DS` | "Luma doublers trained to **denoise and sharpen**" | README 原文 |
| `_DN` | "Luma doublers trained to **denoise and soften**" | README 原文 |
| `_Chroma` / `_YCbCr` | "Trained to reconstruct chroma. These are intended to be used on 4:2:0 BT.709 YCbCr content, and **chroma must be upscaled with bilinear first**" | README 原文 |

**官方推荐序**(README):`R16F96` 最高质量(非实时)→ `R8F64` 平衡 → `C4F32` 硬件够时的实时选择
→ `C4F16` 最轻。参数量跨度 README 给的是 "~12k to ~4m"。

**上游 `GLSL/` 目录实际文件**(GitHub API 拉 `main` 全树,2026-08-30,
`https://api.github.com/repos/Artoriuz/ArtCNN/git/trees/main?recursive=1`):

```
GLSL/ArtCNN_C4F16.glsl      GLSL/ArtCNN_C4F16_DN.glsl   GLSL/ArtCNN_C4F16_DS.glsl
GLSL/ArtCNN_C4F32.glsl      GLSL/ArtCNN_C4F32_DN.glsl   GLSL/ArtCNN_C4F32_DS.glsl
GLSL/Experiments/ArtCNN_R4F32_YCbCr.glsl（+_DN +_DS）
```

注意:**上游 `GLSL/` 里目前没有 `R8F64` / `R16F96` 的 .glsl 成品**(只有 `Experiments/` 下的
`R4F32_YCbCr` 三个)。README 推荐的 R 系大模型以什么形式分发:**未确认**(查了上述 API 全树)。

**hook 点与门槛**(本地文件实测):`//!HOOK LUMA`(只处理亮度)、`//!COMPUTE 24 32 12 16`
(compute shader)、最后一个 pass 是 `Depth-To-Space`。见 `apps/desktop/shaders/ArtCNN_C4F16.glsl:27-33`
与 `:1384-1391`。它属**放大类**。

**★ 上游与我们这份的门槛不一样(本人 2026-08-30 A/B 实测)**:

| | `//!WHEN` 原文 | 实际阈值 |
|---|---|---|
| 上游 `Artoriuz/ArtCNN` main | `OUTPUT.w LUMA.w / 1.3 > OUTPUT.h LUMA.h / 1.3 > *` | **1.3 倍** |
| 我们这份(PlayKit 转录) | `OUTPUT.w LUMA.w 1.200 * > OUTPUT.h LUMA.h 1.200 * >  *` | **1.2 倍** |

两者不仅数值不同,写法也从「除法」改成了「乘法」。这条的后果见 **§6 坑 7**(一个当前就存在的假绿风险)。

### 1.3 其它(FSRCNNX / ravu / NNEDI3 / superxbr / FSR / CAS)

本仓库**没有打包** FSRCNNX 和 ravu,以下是选型参考。

| 项目 | 是什么 | 现状 | URL |
|---|---|---|---|
| **FSRCNNX** | FSRCNN 的 mpv GLSL 移植,luma 放大器。命名如 `FSRCNNX_x2_8-0-4-1`,数字是网络结构参数 | **本仓库未打包;维护状态未确认**(未拉仓库核对) | https://github.com/igv/FSRCNN-TensorFlow |
| **ravu** | bjin 的 prescaler 集合,RAISR 派生(查表式,非逐帧卷积)。有 `ravu-lite` / `ravu-zoom` / `ravu-3x` 及 `-r2/r3/r4` 半径档 | **本仓库未打包;各变体差异与开销未确认**(未拉仓库核对) | https://github.com/bjin/mpv-prescalers |
| **NNEDI3 / superxbr** | mpv 早期的内置 prescaler | **已从 mpv 移除**。判据:`DOCS/man/options.rst`(master,2026-08-30)里 `nnedi3` 与 `superxbr` 的命中数为 **0** | https://github.com/mpv-player/mpv/blob/master/DOCS/man/options.rst |
| **AMD CAS** | 对比度自适应锐化(FidelityFX)。**不是放大器** | 已打包,见 §1 来源表 | FidelityFX-SDK v1.1.4 `ffx_cas.h` |
| **AMD FSR1 EASU + RCAS** | FSR1 官方两段:EASU 放大 → RCAS 锐化。**RCAS 单用即纯锐化** | 已打包 | FidelityFX-SDK v2.1.0 `ffx_fsr1.h` |
| **NVIDIA NIS** | NVScaler(放大+锐化)与 NVSharpen(纯锐化) | 已打包 | https://github.com/NVIDIAGameWorks/NVIDIAImageScaling |

**CAS 与 RCAS 的区别**:两者在本仓库里挂**不同 hook 阶段** —— `AMD_CAS_luma_RT.glsl:19` 是
`//!HOOK LUMA`,`AMD_FSR1_RCAS_RT.glsl:25` 是 `//!HOOK MAIN`。正因如此它们可以叠在同一档
(`fsr_sharp_h`,见 `apps/desktop/src/shaders.rs:246-250` 的注释:「CAS 挂 LUMA、RCAS 挂 MAIN
—— 不同阶段,可以叠」)。**两者算法层面的差异:未确认**(本仓库注释未记,我也没读 SDK 源码)。

**2025–2026 有没有更新的值得关注的**:**未确认**。我这轮只核对了 Anime4K / ArtCNN / mpv manual
三处一手源,没有系统检索社区新项目。DLSS / FSR2/3 是否有 mpv 侧实现,同样未确认。

---

## 2. mpv 内置画质选项

**出处统一**:mpv master 的 `DOCS/man/options.rst`,
https://github.com/mpv-player/mpv/blob/master/DOCS/man/options.rst
(本人 2026-08-30 拉的 raw,行号对应该次快照)。

| 选项 | 作用 | 默认 | 备注 / 原文要点 |
|---|---|---|---|
| `--scale=<filter>` | 放大用的缩放器 | `lanczos` | 可选值含 `bilinear`(最快最差,`fast` profile 默认)、`lanczos`、`ewa_lanczos`(=jinc,慢但好)、`ewa_lanczossharp`(**`high-quality` profile 的默认**)、`ewa_lanczos4sharpest`(更锐、更慢、易振铃,官方建议配 antiring)等 |
| `--cscale=<filter>` | 色度插值 | 未设时**跟随 `--scale`** | 原文:"If the image is not subsampled, this option is ignored entirely." |
| `--dscale=<filter>` | 缩小时用的 | — | 原文:"Like `--scale`, but apply these filters on downscaling instead." |
| `--tscale=<filter>` | 时间轴(帧)插值 | `oversample` | **只在 `--interpolation` 打开时才用**;只接受可分离卷积滤波器 |
| `--scale-antiring` 等四个 | 抗振铃强度 0.0~1.0 | `0.0` | `high-quality` profile 设成 `0.6` |
| `--sigmoid-upscaling` | 放大时走 sigmoid 色彩变换,压振铃 | **开** | 与 `--linear-upscaling` **互斥并取代之** |
| `--linear-upscaling` | 放大时在线性光下做 | 关 | 原文:"not usually recommended except for testing/specific purposes" |
| `--linear-downscaling` | 缩小时在线性光下做 | **开** | 原文:"This option **has no effect on HDR content**." |
| `--correct-downscaling` | 缩小时扩大卷积核 | **开** | 提质降速;`--vo=gpu` 下用 bilinear 缩小时该选项被忽略 |
| `--deband` | 去色带 | 关 | 原文:"virtually always an improvement - the only reason to disable it would be for performance" |
| `--deband-iterations` | 每样本去带迭代数 0~16 | `1` | 原文:">4 practically useless" |
| `--deband-threshold` | 截止阈值 0~4096 | `48` | 越高越狠,细节流失越快 |
| `--deband-range` | 初始半径 1~64 | `16` | 加大 iterations 时应相应调小 |
| `--deband-grain` | 补噪掩盖量化痕迹 0~4096 | `32` | — |
| `--sharpen=<value>` | unsharp mask 锐化 | `0`(关) | ★ 原文明确 **"(Only for `--vo=gpu`)"** —— 我们桌面跑 `gpu-next`,**这个选项对我们完全无效** |
| `--glsl-shaders` | 挂 user shader(分号分隔路径) | 空 | 我们用的就是它 |
| `--glsl-shader-opts=k=v,...` | shader 可调参数 | 空 | ★ 原文:"You can target specific named shaders by **prefixing the shader name with a `/`**, e.g. `shader/param=value`. Without a prefix, parameters affect all shaders." 见 §8 |
| `--gpu-shader-cache` | 缓存编译好的 shader | **`yes`** | 原文:"It mostly matters for anything involving GLSL to SPIR-V conversion, that is: **D3D11, ANGLE or Vulkan**" |
| `--gpu-shader-cache-dir` | 缓存目录 | **未设时用系统缓存目录**(`~/.cache/mpv`) | ★ 这一条是我们必须显式给的原因,见 §6 坑 3 |
| `--hwdec` | 硬解 | — | 我们:桌面 `auto-safe`、安卓 `mediacodec-copy` |
| `--vo` | 视频输出 | — | 我们:桌面 `gpu-next`、安卓 `gpu` |
| `--gpu-api` | 图形 API | — | 我们 Windows 上只钉 `gpu-context=d3d11`,不钉 `gpu-api` |
| `--hdr-compute-peak` | 逐帧算 HDR 峰值 = 动态 tone mapping | **`auto`** | 见下 |
| `--tone-mapping` | tone mapping 曲线 | — | 未细查,标未确认 |
| `--corner-rounding` | 圆角输出 | `0` | **`gpu-next` only**;与画质无关,列出仅为说明「gpu-next 独有项」确实存在 |

### `--gpu-shader-cache-dir` 为什么我们必须显式给

manual 原文:"Cache is stored in the system's cache directory (usually `~/.cache/mpv`)
**if this is unset**." —— 即它依赖 mpv 的配置/缓存目录解析。
而 **libmpv 嵌入时没有配置目录**:`crates/mpv/src/lib.rs:1283-1289` 记录了真机日志
`cache path: '' -> '-'`,结论是「不显式给路径就**没有任何缓存**」。
所以默认值 `yes` 在 libmpv 下等于空转 —— **开着,但没地方写**。详见 §6 坑 3。

### `--hdr-compute-peak` 与移动端

manual 原文:"Requires compute shaders, which is a fairly recent OpenGL feature, and will
**probably also perform horribly on some drivers**, so enable at your own risk."
默认 `auto` = 在支持 compute shader 与 SSBO 时自动开。
相关的 `--allow-delayed-peak-detect` 原文注明 "(Only affects `--vo=gpu-next`, note that
`--vo=gpu` **always delays the peak**.)" —— 即安卓那边跑 `gpu`,峰值检测本就是延迟一帧的。
`--hdr-peak-percentile` 也标了 "(Only for `--vo=gpu-next`)"。

**我们代码里有没有动这些**:**没有**。`grep -rn "hdr-compute-peak" --include=*.rs` 在
`crates/`、`apps/` 下零命中(本人执行确认)。记忆索引 [[dolby-auto-decode]] 提到「移动端软解关
`hdr-compute-peak`」,**但当前 Rust 代码里找不到这行** —— 那是 Flutter 期的做法,
换栈后**没有迁过来**。这是一个真实的能力回退,记在 §9。

### `gpu` vs `gpu-next`

我们的选择与理由在 `crates/mpv/src/lib.rs:1232-1235`:

```
/* ★ 安卓不用 gpu-next。它要 Vulkan/更新的 libplacebo,机顶盒上的 GPU 驱动
   参差不齐,起不来是**黑屏而不是报错**。gpu + gpu-context=android 是
   mpv-android 多年验证过的组合,先要能出画面。 */
set("vo", if cfg!(target_os = "android") { "gpu" } else { "gpu-next" });
```

**两者的完整差异列表:未确认。** 我在 `options.rst` 里逐项核到的、明确标注了适用范围的只有:
`--sharpen`(gpu only)、`--corner-rounding`(gpu-next only)、`--hdr-peak-percentile`
(gpu-next only)、`--allow-delayed-peak-detect`(gpu-next only)、
`--gpu-shader-cache` 的清理策略(gpu-next 有 128 MiB 上限与 24 小时淘汰,gpu 永不清理)。
我没有找到官方的对照总表(查过 `options.rst`;未查 mpv wiki)。
**这对我们的实际影响**:桌面与安卓跑的是两个不同渲染器,**同一条 shader 链在两端行为不保证一致**,
而我们两端共用同一张档位表(见 §5)。

---

## 3. 触发条件与常见误解 —— 「为什么我开了超分没变化」

这是本项目反复被投诉的一件事,历史上**至少有 6 个互不相同的根因**都表现为同一句话。
下表按「先查哪个」排序,每条给可执行的判定方法。

> 前置事实:`crates/mpv/src/lib.rs:1940-1947` 的 `shader_count()` 上写着
> 「⚠️ 它只说明 mpv **收下了**路径,**不代表 shader 会跑**」。
> **任何以 `count > 0` 为依据的「已生效」结论都是无效结论。**

### 判定顺序表

| # | 根因 | 症状 | 判定方法 | 现状 |
|---|---|---|---|---|
| 1 | **选了放大档 + 窗口模式** | 画面**完全**无变化 | 比 `dwidth/dheight`(源)与 `osd-width/osd-height`(输出)。输出 ÷ 源 ≤ 1.2 → 放大类一帧不跑 | 已治:`will_run()` 直接告诉用户,见下 |
| 2 | **强度吃 shader 自带默认** | 有变化,但「只有一点点」 | 读 mpv 的 `glsl-shader-opts` 属性,看是不是空串 | 已治:强度烧进档位 |
| 3 | **参数名写错 → mpv 拒掉整条 opts** | 同上,且**完全不报错** | 设完回读 `glsl-shader-opts`,与写入值比对 | 已治:`set_shader_opts` 回读 |
| 4 | **参数被设成「死值」** | 那个 pass 一帧不跑 | 查该 shader 的 `//!WHEN`:`//!WHEN STR` → 0 是死值;`//!WHEN SHARP 4.0 <` → 4.0 是死值 | 已治:有测试钉 |
| 5 | **同档两个 shader 用同名 PARAM** | 画面「不对劲」,不报错 | 扫本档所有 `//!PARAM`,看有无重名 | 已治:有测试钉 |
| 6 | **渲染路径根本不跑 GLSL** | `count>0` 但画面零变化 | 读 `current-vo`;历史上 media_kit 的软件纹理(`MPV_RENDER_API_TYPE_SW`)不跑 user shader | 已消失(现在是原生 libmpv + `gpu-next`) |
| 7 | **片源不对**(真人片用 Anime4K) | 吃 GPU 但看不出变化 | 看片源类型 | **未治**,UI 不提示 |
| 8 | **重启后档位回了 `off`** | 「我明明开着的」 | 见 §4「持久化」 | **设计如此**,见 §4 |

### 1. 放大类的门槛究竟怎么算

判据取自 shader 源本身,不是文档:

```
Anime4K CNN : //!WHEN OUTPUT.w MAIN.w / 1.200 > OUTPUT.h MAIN.h / 1.200 > *
ArtCNN(我们这份): //!WHEN OUTPUT.w LUMA.w 1.200 * > OUTPUT.h LUMA.h 1.200 * > *
FSR1 EASU   : //!WHEN OUTPUT.w HOOKED.w 1.0 * > OUTPUT.h HOOKED.h 1.0 * > *
NVScaler    : //!WHEN OUTPUT.w HOOKED.w 1.0 * > OUTPUT.h HOOKED.h 1.0 * > *
```

三点容易搞错的:

- **`OUTPUT` 是 mpv 的画面区,不是屏幕分辨率。** 全屏时才等于屏幕。
  代码取值:`crates/mpv/src/lib.rs:1934-1938` 用 `osd-width` / `osd-height`;
  源尺寸用 `dwidth` / `dheight`(`:1928-1932`,注释写明「已算进非方像素/裁剪,正是 shader 里的 MAIN」)。
- **宽和高都要过线(是 AND 不是 OR)。** `//!WHEN` 末尾那个 `*` 是逆波兰的逻辑与。
  测试钉在 `apps/desktop/src/shaders.rs:722`:`3840×1080` 输出 + `1920×1080` 源 → 判 `false`。
- **是 `>` 不是 `>=`。** 恰好 1.2 倍不跑。测试:`apps/desktop/src/shaders.rs:724`。

真机现场(commit `bcdd7cb5` 的日志):源 `1920×1080`、mpv 输出 `1770×1080` → `0.92×` → 全跳过。
mpv 日志里**看得到 shader 被加载**,所以「加载成功」这个信号具有欺骗性:

```
[v][vo/gpu-next/libplacebo] Loaded user shader:
[v][vo/gpu-next/libplacebo] Registering hook pass: Anime4K-v3.2-Upscale-Denoise-CNN-x2-(VL)-...
```

### 2. 「强度不够」的根因:shader 自带默认极保守

这是**第二类**根因,和尺寸无关,画面**有**变化只是很弱。数据在
`apps/desktop/src/shaders.rs:56-59` 与 `:200-203`:

| shader | 参数 | 自带默认 | 范围 | 方向 |
|---|---|---|---|---|
| `AMD_CAS_luma_RT` | `STR` | **0.5** | 0.0~1.0 | 越大越锐 |
| `Adaptive_sharpen_lite_luma_RT` | `STR` | **1.0** | 0.0~2.0 | 越大越锐 |
| `FineSharp_RT` | `SSTR` | **0.5** | 0.0~8.0 | 越大越锐 |
| `aWarpSharp2_RT` | `STR` | **4.0** | -20.0~20.0 | 越大越锐 |
| `AMD_FSR1_RCAS_RT` | `SHARP` | 0.2 | 0.0~4.0 | **越小越锐** |

`shaders.rs:201` 记了 CAS 的算式 `peak = -1.0 / mix(8.0, 5.0, STR)`,`:203` 记了 RCAS 的
`sharp = exp2(-SHARP)`。**方向相反是这里最容易写反的地方** —— commit `732ce619` 的
`strength_endpoints_are_coherent` 测试就是钉这个的(「方向搞反 = 越调越糊」)。

### 3. 「卡」不等于「没生效」—— 两个独立的量级来源

- **跑在核显上**:双显卡笔记本 D3D11 默认适配器是接显示器那块(核显)。
  真机日志 `[v][vo/gpu-next/d3d11] Device Name: Intel(R) UHD Graphics` / `Device ID: 8086:468b`。
  **判定方法**:`set LP_MPV_LOG=1 && LinPlayer.exe`,读 `%TEMP%\linplayer_mpv.log` 里的
  `Device Name:`。日志门控见 `crates/mpv/src/lib.rs:1325-1330`。修法见 §6 坑 1。
- **shader 每次起播重编译**:libmpv 没有配置目录 → 无缓存。判定方法见 §6 坑 3。

⚠️ **这两条 + 「档位表抄错挂了无门槛的 Restore」三件事曾同时存在**,
`apps/desktop/src/shaders.rs` 的历史注释与 commit `632bb07e` 都明确写了
「**谁都不单独解释全部现象**」。排查这类问题时,找到一个原因**不等于**找到了全部。

### 4. 我们现在怎么把真相告诉用户

核层 `set_shader_level` 挂载后做**双重回读**(`apps/desktop/src/lib.rs:2917-2954`):

1. 回读 `glsl-shaders` 数路径个数 → `count`,为 0 且档位非 off 直接返回错误("超分未生效")
2. 读 `dwidth/dheight` 与 `osd-width/osd-height`,交给 `shaders::will_run()` 算这条链会不会跑

`will_run` 返回 `false` 时,`apps/desktop/src/lib.rs:2945-2951` 生成**带真实数字**的解释:

> 这档是**放大**滤镜,当前尺寸下不会生效:要求画面区大于源的 1.2 倍才工作。
> 现在源 1920×1080、画面区只有 1770×1080(0.92×)—— 你在缩小画面,没有可放大的。
> 按 F 全屏即可生效;想在窗口里就见效,请选「锐化」「去噪」「锐化+去噪」这三档。

`will_run()` 本体在 `apps/desktop/src/shaders.rs:166-178`,三条边界:
`preset` 不存在 → `None`;`works_at_any_size` → 直接 `Some(true)`;
源尺寸为 0 或未在播 → `None`(注释 `:725` 写明「别除零除出 inf 说『能跑』」)。

---

## 4. 我们的档位设计

单一事实源:`apps/desktop/src/shaders.rs`(安卓那份是逐字副本,见 §5)。
`levels()` 在 `:329-364`,`preset()` 在 `:204-320`。

**实点计数**(`sed -n '329,365p' | grep -c`):共 **28 条**,= `off` + Anime4K 8 + FSR 6 +
NVIDIA 6 + Sharpen 7 = **27 个真档位**。
(注:`shaders.rs:339` 的注释写「档位从 19 涨到 26」,与实际 27 差 1 —— 注释没跟上,以代码为准。)

### 4.1 完整档位映射表

**顺序就是 pipeline**。`Preset.files` 的字段注释(`shaders.rs:182`)写明:
「先去噪(在源分辨率上最干净)→ 再放大 → 最后锐化」。

| 档位 id | 显示名 | 家族 | shader 链(**顺序即挂载顺序**) | `glsl-shader-opts` | 窗口下有效? |
|---|---|---|---|---|---|
| `off` | 关闭 | — | (空) | (空串,**用于清掉上一档参数**) | — |
| `ak_denoise_l` | 去噪 · 轻 | Anime4K | `Denoise_Bilateral_Mean` | — | ✅ |
| `ak_denoise_h` | 去噪 · 强 | Anime4K | `Denoise_Bilateral_Mode` | — | ✅ |
| `ak_sharp` | 锐化+去噪 · 推荐 | Anime4K | `Denoise_Bilateral_Mode` → `AMD_CAS_luma_RT` | `STR=0.85` | ✅ |
| `ak_up_m` | 放大 · CNN M | Anime4K | `Clamp_Highlights` → `Upscale_CNN_x2_M` | — | ❌ |
| `ak_up_dn` | 放大+去噪 · CNN M | Anime4K | `Denoise_Bilateral_Mode` → `Clamp_Highlights` → `Upscale_CNN_x2_M` | — | ✅(退化成只去噪) |
| `ak_up_vl` | 放大去噪 · CNN VL · 壮机 | Anime4K | `Clamp_Highlights` → `Upscale_Denoise_CNN_x2_VL` → `AutoDownscalePre_x2` → `AutoDownscalePre_x4` → `Upscale_CNN_x2_M` | — | ❌ |
| `ak_up_artcnn` | 放大 · ArtCNN · 清晰轻量 | Anime4K | `Clamp_Highlights` → `ArtCNN_C4F16` | — | ❌ |
| `ak_up_artcnn_sh` | 放大+锐化 · ArtCNN · 最清晰 | Anime4K | `Clamp_Highlights` → `ArtCNN_C4F16` → `Adaptive_sharpen_lite_luma_RT` | `STR=1.30` | ✅(退化成只锐化) |
| `fsr_sharp_l` | 锐化 · 轻 | FSR | `AMD_CAS_luma_RT` | `STR=0.60` | ✅ |
| `fsr_sharp_m` | 锐化 · 推荐 | FSR | `AMD_CAS_luma_RT` | `STR=0.85` | ✅ |
| `fsr_sharp_h` | 锐化 · 强 | FSR | `AMD_CAS_luma_RT` → `AMD_FSR1_RCAS_RT` | `STR=1.00,SHARP=0.00` | ✅ |
| `fsr_up` | 放大+锐化 · FSR1 | FSR | `AMD_FSR1_EASU` → `AMD_FSR1_RCAS_RT` | `SHARP=0.25` | ✅(退化成只锐化) |
| `fsr_up_h` | 放大+锐化 · 强 | FSR | `AMD_FSR1_EASU` → `AMD_FSR1_RCAS_RT` | `SHARP=0.00` | ✅(同上) |
| `fsr_up_dn` | 放大+锐化+去噪 | FSR | `Denoise_Bilateral_Mode` → `AMD_FSR1_EASU` → `AMD_FSR1_RCAS_RT` | `SHARP=0.00` | ✅ |
| `nv_sharp_l` | 锐化 · 轻 | NVIDIA | `NVSharpen_RT` | `SHARP=0.30` | ✅ |
| `nv_sharp_m` | 锐化 · 推荐 | NVIDIA | `NVSharpen_RT` | `SHARP=0.50` | ✅ |
| `nv_sharp_h` | 锐化 · 强 | NVIDIA | `NVSharpen_RT` | `SHARP=0.85` | ✅ |
| `nv_up` | 放大 · NIS | NVIDIA | `NVScaler_RT` | `SHARP=0.30` | ❌ |
| `nv_up_h` | 放大+锐化 · NIS | NVIDIA | `NVScaler_RT` | `SHARP=0.50` | ❌ |
| `nv_up_dn` | 放大+锐化+去噪 · NIS | NVIDIA | `Denoise_Bilateral_Mode` → `NVScaler_RT` | `SHARP=0.50` | ✅(退化成只去噪) |
| `sh_ada_l` | 自适应锐化 · 轻 | Sharpen | `Adaptive_sharpen_lite_luma_RT` | `STR=0.70` | ✅ |
| `sh_ada_m` | 自适应锐化 · 推荐 | Sharpen | 同上 | `STR=1.30` | ✅ |
| `sh_ada_h` | 自适应锐化 · 强 | Sharpen | 同上 | `STR=1.90` | ✅ |
| `sh_fine_m` | 精细锐化 · 推荐 | Sharpen | `FineSharp_RT` | `SSTR=2.50` | ✅ |
| `sh_fine_h` | 精细锐化 · 强 | Sharpen | 同上 | `SSTR=5.00` | ✅ |
| `sh_warp` | 线条锐化 · 动漫线稿 | Sharpen | `aWarpSharp2_RT` | `STR=10.00` | ✅ |
| `sh_bcas` | 双边锐化 BCAS · 强 | Sharpen | `AMD_BCAS_RT` | `STR=1.00,SIGMA=0.30` | ✅ |

「窗口下有效?」这一列**不是手写的**,是 `works_at_any_size()`(`shaders.rs:154-160`)从
shader 源现算的。它的语义是「**有效果**」而不是「全部 pass 都跑」—— 注释 `:150-153` 记了
第一版把 FSR 档标错的经过:「我照直觉把 FSR 档标成 false,是
`window_ok_flag_matches_shader_gates` 红了才发现 RCAS 的门槛(`//!WHEN SHARP 4.0 <`)
是**参数**不是尺寸」。

### 4.2 第四族「锐化专精」与 ArtCNN 是怎么接的

**背景**(`shaders.rs:282-286`,用户 2026-07-20 原话):
「其实清晰最重要的是锐化 锐化是最能提升看起来清晰的程度的」「参考人家的滤镜是怎么加的清晰且不吃性能的」。

这一族的三条设计约束,全部写在 `shaders.rs:285-289`:

1. **全部窗口模式就生效** —— 门槛是参数不是尺寸。测试 `sharpen_family_runs_windowed_and_is_stronger_than_defaults`
   (`:632-679`)逐档断言 `works_at_any_size(id)` 为真。
2. **全部 luma-only** —— 只 `//!HOOK LUMA`,不碰色度,便宜。
3. **每档只挂一个锐化器**。原因是 `glsl-shader-opts` 是**全局**的一张 K=V 表,
   而 Adaptive / aWarpSharp2 / BCAS **都叫 `STR`**、量纲却是 0~2 / -20~20 / 0~1。
   叠在同一档会共用一个值、必然串味且 mpv 不报错。
   测试 `no_preset_loads_two_shaders_sharing_a_param_name`(`:539-555`)钉住。

**ArtCNN 归在 Anime4K 族而不是新开一族**,理由在 `shaders.rs:302-303`:「同为动漫向 luma CNN,
但比 `Upscale_CNN_x2_M` 清晰、比 VL 便宜」。它接了两档:纯放大 `ak_up_artcnn`,
以及放大后再补一刀 Adaptive 的 `ak_up_artcnn_sh`(`:309-316`)。
后者能叠是因为 ArtCNN **没有任何 `//!PARAM`**,与 Adaptive 的 `STR` 不冲突。

### 4.3 强度为什么烧死在档位里(不给用户拧)

`shaders.rs:194-197` 记的用户原话(2026-07-15):
「强度不是靠用户调的 是让你设计挡位的 我说看不太出来 你就把各个档位都调高不就好了吗 用户又不会调」。

落地方式:`Prefs` 里**曾有** `shader_strength: u8`(0~100)+ UI 一个 stepper,
commit `396c4473` 整条删掉。删除位置留了注释:`crates/core/src/config.rs:176-179`。
配套的兼容性测试 `stale_shader_strength_key_from_old_builds_is_ignored_not_fatal`
(`crates/core/src/config.rs:866`)钉的是**老配置里残留这个键不能让解析失败**
——「这条守的是别给 `Prefs` 加 `deny_unknown_fields`」。

梯度由档位名(轻/推荐/强)承诺,并有测试钉**单调递增**:
`sharpen_ladder_is_monotonic_and_above_shader_default`(`shaders.rs:560-577`),
它同时断言 `light > 0.5`(必须高于 CAS 自带默认)与 `strong == 1.0`(必须顶到 `//!MAXIMUM`)。

### 4.4 档位是否持久化 —— 事实与归因分开写

**事实(已验证)**:**不持久化**。四条证据:

1. `Prefs` 结构体里**没有**任何档位字段。`grep -n "shader" crates/core/src/config.rs`
   只命中已删除的 `shader_strength` 的注释与测试,没有 `shader_level`。
2. 前端是纯组件态:`ui/desktop/App.tsx:327` 是 `useState("off")`,
   `ui/mobile/pages/SettingsPage.tsx:262` 是 `useState("off")` —— **都不从 `get_prefs` 回读**。
3. 还有一条主动复位:`ui/desktop/App.tsx:675`
   `setShaderLv((lv) => (o.shader_count > 0 ? lv : "off"))` —— 1200ms 轮询里,
   mpv 报 `shader_count == 0` 就把 UI 档位打回 `off`。
4. **★ 代码里有一条明确写出这个设计的注释**,在 TV 端设置页
   `ui/tv/pages/SettingsPage.tsx:59-61`(该页列举「哪些项故意没画」):

   > 仍然**没画**的:画质增强(**超分档位是跟着当前播放的运行时开关,不落盘**,
   > 见 setShaderLevel,**离开播放页设它没有意义**)

**归因(是不是有意设计)—— 分三档说清**:

| 说法 | 证据强度 | 出处 |
|---|---|---|
| 「不持久化」是事实 | **已验证** | 上述四条 |
| 「不落盘是设计,不是遗漏」 | **代码内有据** | `ui/tv/pages/SettingsPage.tsx:59-61`,并给了理由(运行时开关 / 离开播放页设它没意义) |
| 「是用户明确要求的」 | **代码与 git 里无据** | 见下 |

第三档的核查过程(按「未验证的归因是甩锅」的口径,如实写):
我执行过 `git log --all -S"shader_level"` —— 命中的全是 `set_shader_level` **命令名**,
不是持久化字段;`git log --all -S"shader_strength"` —— 只有两次提交(`732ce619` 新增、
`396c4473` 删除),**两条 message 都只讲「强度」,没有一句提到「档位」是否该持久化**。
**git 历史里没有说明。**

唯一记录了「用户明确要求」的地方不在本仓库,而在项目记忆文件
`~/.claude/projects/D--LinPlayer/memory/anime4k-denoise-ladder.md`,其中记有 2026-07-20 用户原话:
「超分档位不持久化 我故意这么做的 用户不是每集都需要」,并注明「我这轮就是先误诊成这个、
动手改了 `config.rs` 才被叫停」。

→ **Go 侧的结论口径**:**不要给它加持久化字段。** 依据是 `ui/tv/pages/SettingsPage.tsx:59-61`
这条代码内注释(设计意图明确),而不是记忆文件。但**桌面/移动端的 `shaders.rs` 与 `config.rs`
里没有同样的注释** —— 一个改核层的人不会去读 TV 设置页。建议在 Go 侧把这句话搬到档位表旁边,
见 §9。

---

## 5. 平台差异(桌面 / 安卓 / TV)

### 5.1 档位表本身:零分叉

`apps/android/src/shaders.rs` 是 `apps/desktop/src/shaders.rs` 的**逐字副本**。
我做过全文 diff(忽略行尾空白),**38 行差异全部是** `include_str!` 的路径,
外加安卓那份多出的 4 行头注释(`apps/android/src/shaders.rs:1-4`):

```
/* ★ 本文件从 apps/desktop/src/shaders.rs 复制,**但 .glsl 不复制** ——
   include_str! 的路径改指向 `../../desktop/shaders/`。那些着色器有几百 KB,
   在仓库里放两份等于以后改一份忘一份,而 include_str! 是编译期读文件,
   跨目录引用完全可行。 */
```

→ **档位表、参数、`will_run` 逻辑、全部 16 个测试,两端完全一致。**
`set_shader_level` 命令也一致(`apps/desktop/src/lib.rs:2920` vs
`apps/android/src/lib.rs:3343`),唯一差别是 State 类型(`AppState` vs `PlayerState`)。

⚠️ 但**它是复制,不是共享**。两个文件之间没有任何机制保证同步 —— 改一份忘一份不会报错。
Go 侧应当把它**提成一个共享包**,见 §7。

### 5.2 shader 文件怎么随包分发

**两端都不用资源目录、不用安卓 assets。** 机制统一是「编译期嵌入 + 运行时落盘」:

| 阶段 | 做法 | 代码位置 |
|---|---|---|
| 编译期 | `include_str!` 把 17 个 `.glsl` 的**文本**编进二进制 | `apps/desktop/src/shaders.rs:38-120` |
| 首次使用 | `ensure_files()` 写到磁盘,**按文件长度判新旧**(长度一致就跳过,避免每次起播重写) | `shaders.rs:373-388` |
| 挂载 | 把绝对路径列表交给 mpv 的 `glsl-shaders`(分号分隔) | `crates/mpv/src/lib.rs:1910-1917` |
| 落盘位置 | `linplayer_core::paths::cache_dir("shaders")` | `apps/desktop/src/lib.rs:2922` / `apps/android/src/lib.rs:3345` |

**为什么要落盘而不是直接喂内容**:`shaders.rs:29-31` 写明 ——「绿色版是 `app.exe + libmpv-2.dll`
平铺(`bundle.active=false`),没有 resources 目录可用。首次用时落盘到 app data ——
**mpv 的 `glsl-shaders` 只收文件路径**。」

归 `cache/` 而不是 `data/` 的理由(`apps/desktop/src/lib.rs:2921`):「丢了能重生成」。

### 5.3 渲染栈差异(这才是真正的平台分叉)

| | 桌面(Win / Linux) | 安卓 |
|---|---|---|
| `vo` | `gpu-next` | **`gpu`** |
| `gpu-context` | Win 钉 `d3d11`;**Linux 故意不设** | `android` |
| `hwdec` | `auto-safe` | `mediacodec-copy` |
| 独显钉定 | Win 有(`NvOptimusEnablement`) | 无(移动 GPU 只有一块) |
| 额外必设项 | — | `ao=audiotrack`、`sub-fonts-dir=/system/fonts`、`android-surface-size` |

出处集中在 `crates/mpv/src/lib.rs:1232-1272`。安卓不用 `gpu-next` 的理由逐字如下(`:1232-1234`):

```
/* ★ 安卓不用 gpu-next。它要 Vulkan/更新的 libplacebo,机顶盒上的 GPU 驱动
   参差不齐,起不来是**黑屏而不是报错**。gpu + gpu-context=android 是
   mpv-android 多年验证过的组合,先要能出画面。 */
```

Linux 故意不钉 `gpu-context` 的理由(`:1238-1242`):写死任何一个都会在缺对应驱动/会话类型的
机器上「起不来且不报错」。

**⚠️ 这条差异的后果**:同一条 shader 链在桌面走 libplacebo、在安卓走旧 gpu 渲染器。
`--sharpen` 之类「只在 gpu 有效 / 只在 gpu-next 有效」的选项在两端行为不同(见 §2),
`--gpu-shader-cache` 的清理策略也不同(gpu-next 有 128 MiB 上限与 24h 淘汰,gpu 永不清理)。
**我们两端共用同一张档位表,但没有任何一端做过 A/B 画质对比。** 记在 §9。

### 5.4 libmpv 来源与版本

| 平台 | 来源 | 版本 | 出处 |
|---|---|---|---|
| Windows | shinchiro/mpv-winbuild-cmake 的 `mpv-dev-x86_64-*.7z` | **`releases/latest`,未钉版本** | `.github/workflows/build.yml:147-164` |
| Android | media-kit/libmpv-android-video-build 的 `full-<abi>.jar` | **`v1.1.11`,已钉** | `.github/workflows/build.yml:669-680` |
| Linux | **不打包**,运行时 `dlopen` 系统 libmpv | 随发行版 | `.github/workflows/build.yml:280-283` |

Windows 侧取 `latest` 意味着**libplacebo 版本会在无人察觉时变动**,而 shader 的行为由它执行。
CI 里唯一的护栏是体积下限(`if ($size -lt 60MB) { throw ... }`,`build.yml:164`),
那是防精简版,**不防版本漂移**。记在 §9。

### 5.5 TV 端:没有超分入口

`ui/tv/` 全目录 grep `shader` 只有一处命中,是设置页说明**为什么没画**
(`ui/tv/pages/SettingsPage.tsx:59-61`,原文见 §4.4)。
即 TV 端后端命令是有的(`apps/android/src/lib.rs:4889` 注册了 `shader_levels`,与手机端同一个二进制),
**只是 UI 没有入口**。Go 侧不需要为 TV 做任何额外事情。

---

## 6. 踩坑清单

格式:**症状 / 真因 / 现在怎么处理 / Go 侧怎么落**。
每条都是真机上发生过的,不是假想。

### 坑 1 —— 「5060 超分非常非常卡」

- **症状**:用户原话「我用 mpvplaykit 都没这么卡,你肯定是使用方式有问题」。
- **真因**:**mpv 整条 CNN 链跑在 Intel 核显上,RTX 5060 全程没参与。**
  混合显卡笔记本上 D3D11 的默认适配器是接显示器那块;`LinPlayer.exe` 是新面孔,
  NVIDIA 驱动的程序配置库里没有它 → 落到集显档。
  判决性证据(mpv 日志第一屏):`[v][vo/gpu-next/d3d11] Device Name: Intel(R) UHD Graphics` /
  `Device ID: 8086:468b`。
- **现在怎么处理**:exe 导出 Optimus/Enduro 的进程级切卡符号。
  `apps/desktop/src/lib.rs:20-27` 声明静态量,`apps/desktop/build.rs:33-34` 加 `/EXPORT`。
  **两半缺一不可,且缺任一半都不报错、只是继续用核显**(`lib.rs:14-19` 的注释写明:
  `#[used]` 扛 LTO 裁剪,`/EXPORT` 补 Rust exe 默认没有的导出表)。
  A/B 验证过:改后日志变成 `NVIDIA GeForce RTX 5060 Laptop GPU (10de:2d19)`,
  且 **release(LTO)版单独验过**。
- **Go 侧怎么落**:⚠️ **这是本次迁移最容易掉的一条。**
  它不是 mpv 选项、不是配置、不是代码逻辑 —— 它是**最终可执行文件 PE 导出表里的两个符号**。
  Go 的 `//export` 只对 c-archive/c-shared 生效,普通 `go build` 出的 exe 导出表行为需另行确认。
  **迁移后必须重新做一次 A/B 日志验证,不能假设它还在。**
- **判定方法**:`set LP_MPV_LOG=1 && LinPlayer.exe`,读 `%TEMP%\linplayer_mpv.log` 的 `Device Name:`。
- **相关**:`crates/mpv/src/lib.rs:1325-1330`(日志门控)。

### 坑 2 —— 「超分直接不生效」而 UI 报「已生效」

- **症状**:画面**完全**没变化,但 toast 显示「超分已生效 · 挂载 6 个 shader」。
- **真因**:**两层**。
  ① Anime4K 每个 CNN pass 都带 `//!WHEN OUTPUT.w MAIN.w / 1.200 >`,
  真机源 `1920×1080` / 窗口 `1770×1080` = `0.92×` → 一帧都不跑。这是 shader 的**正确行为**。
  ② **真正该修的是 UI 在撒谎**:`count > 0` 只证明 mpv **收下了路径**,证明不了 shader 会跑。
- **现在怎么处理**:`set_shader_level` 返回 `ShaderApplied { count, will_run, note }`,
  做**双重回读**(`apps/desktop/src/lib.rs:2917-2954`);`will_run=false` 时把带真实数字的
  解释原样交给用户(`:2945-2951`)。前端不粉饰:`ui/desktop/App.tsx:1341-1354`。
- **Go 侧怎么落**:原样保留 `will_run` 三态(`true` / `false` / `None`)。
  **`None` 不能塌成 `false`** —— 没在播时下结论就是新的撒谎。边界见
  `apps/desktop/src/shaders.rs:713-730` 的六条断言。
- **教训**(`apps/desktop/src/lib.rs:2904-2906` 原文):「那就是在撒谎,**正是本项目最贵的那类 bug**」。

### 坑 3 —— 「起播慢」+「一开超分就卡」的同一个原因

- **症状**:每次起播都要干等,开超分尤其明显。
- **真因**:**libmpv 没有配置目录 → 完全没有 shader 缓存。**
  mpv 日志证据:`cache path: '' -> '-'`。
  manual 说 `--gpu-shader-cache` 默认 `yes`、目录未设时用系统缓存目录 —— 但 libmpv 解析不出那个目录,
  于是**开着,但没地方写**。结果每次起播把整条链重新 `glsl → SPIR-V (shaderc) → HLSL (spirv-cross)
  → D3D` 编译一遍,首帧干等一整轮。
- **现在怎么处理**:`crates/mpv/src/lib.rs:1288-1291` 显式设 `gpu-shader-cache=yes` +
  `gpu-shader-cache-dir=<cache_dir("shader-cache")>`;并且 **`mpv_initialize` 之后回读校验**
  (`:1336-1359`)—— 因为那个 `set()` 包装**吞掉了 mpv 的返回码**,选项名写错是静默无效。
  回读不一致就 `poclog` 报警。
- **Go 侧怎么落**:两件事都要 ——(a)显式给目录;(b)**回读校验**。
  注释 `:1336-1339` 的原话值得抄进 Go:「本项目吃过太多次『不报错,只是静默不干活』的亏,
  这类优化必须回读确认」。
  目录放数据根不放 `%TEMP%`(`:248-252`:「它就是要跨次启动活着才有意义,被临时目录清理掉就等于没缓存」)。

### 坑 4 —— 「开到最大档位也只有一点点变清晰」

- **症状**:有效果,但弱到几乎看不出。**发生过两次**(2026-07-15、2026-07-20)。
- **真因**:**这些 shader 是参数驱动的,而我们一个 `glsl-shader-opts` 都没设 → 全程吃自带默认**,
  而自带默认极保守:CAS `STR=0.5`(范围 0~1)、Adaptive `STR=1.0`(0~2)、
  FineSharp `SSTR=0.5`(0~8)、aWarpSharp2 `STR=4.0`(-20~20)。
  commit `732ce619` 原文:「把它们当死文件用了,是我漏掉了整个参数层。」
- **现在怎么处理**:强度**烧死在档位里**(`apps/desktop/src/shaders.rs:204-320` 的 `preset()`),
  梯度由档位名承诺;UI 上没有任何数字可拧。
  测试 `sharpen_family_runs_windowed_and_is_stronger_than_defaults`(`:632-679`)
  **从 shader 源现读自带默认值**并断言推荐档必须高于它(`:661-678` 的 `default_of` 闭包)。
- **Go 侧怎么落**:`default_of` 这个「从源里现读默认值再断言」的手法必须移植 ——
  写死一个数字,换个 shader 版本就变成假绿。

### 坑 5 —— 参数名写错,mpv 拒掉**整条** opts 且不报错

- **症状**:锐化强度悄悄回到默认(=坑 4 的那个状态),**完全没有提示**。
- **真因**:`glsl-shader-opts` 遇到不认识的参数名会**整条拒掉**,不是忽略那一个。
  典型踩法(`apps/desktop/src/shaders.rs:439` 记的):给只挂 CAS 的档写上 `SHARP=0`
  —— RCAS 根本没加载。
- **现在怎么处理**:两道闸。
  ① 运行时:`set_shader_opts` **写完回读比对**,返回 bool(`crates/mpv/src/lib.rs:1921-1924`);
  设不上就 `poclog`(`apps/desktop/src/lib.rs:2930-2932`)。
  ② 编译期:测试 `every_preset_opt_names_a_param_that_this_preset_loads`
  (`shaders.rs:440-455`)断言每档 opts 里的每个键都真的存在于**本档挂载的** shader 的 `//!PARAM` 里。
- **Go 侧怎么落**:两道闸都要。②那道是纯静态检查,Go 里同样能做(解析嵌入的 shader 文本)。

### 坑 6 —— 同一档挂两个 shader,它们的参数**串味**且不报错

- **症状**:画面「不对劲」,说不上哪里错。
- **真因**:`glsl-shader-opts` 是**一张全局 K=V 表,不区分给哪个 shader**。
  而 `Adaptive_sharpen` / `aWarpSharp2` / `AMD_BCAS` **都声明 `//!PARAM STR`**,
  量纲却是 `0~2` / `-20~20` / `0~1`。叠进同一档 → 共用一个值 → 其中一个被喂了荒谬的强度,
  **mpv 不报错**。
- **现在怎么处理**:测试 `no_preset_loads_two_shaders_sharing_a_param_name`
  (`apps/desktop/src/shaders.rs:539-555`)禁止同档出现重名 `//!PARAM`;
  设计上「锐化专精族每档只挂一个锐化器」(`:287-289`)。
- **Go 侧怎么落**:这条测试必须移植。**但更好的做法是根本不需要它** —— 见 §8 建议 1。

### 坑 7 —— ★ 一个**当前就存在**的假绿测试(本次调研最重要的发现)

> 这不是迁移才有的风险,**现在就在 main 分支上**。今天没出事,只因为文件恰好还没被刷新过。

- **症状(尚未发生,但会发生)**:有人把 `ArtCNN_C4F16.glsl` 从上游刷新一次,
  之后在 1.2×~1.3× 之间的窗口尺寸下,UI 报「超分已生效」而画面毫无变化 ——
  **整套双重回读机制在这一档上失效,且全部测试保持绿色**。
- **真因(完整因果链)**:

  1. **上游和我们这份的门槛数值不同**(本人 2026-08-30 拉 raw A/B 实测):

     | | `//!WHEN` 原文 | 阈值 |
     |---|---|---|
     | 上游 `Artoriuz/ArtCNN` `main` 分支 `GLSL/ArtCNN_C4F16.glsl` | `OUTPUT.w LUMA.w / 1.3 > OUTPUT.h LUMA.h / 1.3 > *` | **1.3** |
     | 我们这份 `apps/desktop/shaders/ArtCNN_C4F16.glsl:33` | `OUTPUT.w LUMA.w 1.200 * > OUTPUT.h LUMA.h 1.200 * > *` | **1.2** |

     复现命令:
     ```
     curl -sL https://raw.githubusercontent.com/Artoriuz/ArtCNN/main/GLSL/ArtCNN_C4F16.glsl | grep -m1 '^//!WHEN'
     grep -m1 '^//!WHEN' apps/desktop/shaders/ArtCNN_C4F16.glsl
     ```

  2. **守住 `WHEN_RATIO` 的那条测试扫不到 ArtCNN。**
     `when_ratio_matches_shader_source`(`apps/desktop/src/shaders.rs:735-759`)的筛选条件是:
     ```rust
     .filter(|l| l.starts_with("//!WHEN") && l.contains("MAIN.w"))
     ```
     **ArtCNN 用的是 `LUMA.w`,不是 `MAIN.w`** → 它的 `//!WHEN` 行**一行都不进这个循环**。
     而末尾那条 `assert!(seen > 0)`(`:758`)仍然成立 —— 因为 Anime4K 那几个文件还在贡献 `MAIN.w` 命中。
     **哨兵断言在这里救不了场。**

  3. **其它守卫也都判「对」**:`is_upscale_gated()`(`:141-145`)只看 `//!WHEN` 里有没有
     `OUTPUT.`,换成 1.3 版依然含有 → 仍判放大类 → `works_at_any_size` 结论不变 →
     `upscale_gate_detection_is_sane`(`:762-773`)绿。

  4. **于是 `WHEN_RATIO` 常量停在 1.2**(`:133`),而 `will_run()`(`:166-178`)拿它算:
     ```rust
     Some(ow / vw > WHEN_RATIO && oh / vh > WHEN_RATIO)
     ```
     在 `1.25×` 时返回 `Some(true)` → `set_shader_level` 的 `note` 为 `None` →
     前端走 `say("超分已生效 · 挂载 N 个 shader")`(`ui/desktop/App.tsx:1351`)。
     **而 ArtCNN 实际要 > 1.3,一帧都没跑。**

- **今天为什么没出事**:我们这份文件是 PlayKit 转录版,阈值恰好是 1.2,与 `WHEN_RATIO` 一致。
  `apps/desktop/src/shaders.rs:78-79` 的注释也记了这件事(「和 Anime4K 的 `OUTPUT.w MAIN.w / 1.200 >`
  **数学等价**,同为 1.2 倍闸」)—— **注释是对的,但它描述的是一个没有测试保护的巧合。**
- **现在怎么处理**:**没有处理。** 这是一个未被守卫覆盖的面。
- **Go 侧怎么落 / 修法**:见 §9 第 1 条(修法建议写在那里)。

### 坑 8 —— Restore 没有 `//!WHEN`,无条件跑

- **症状**:「超分非常非常卡」的次要因素(主要因素是坑 1)。
- **真因**:档位表被抄成了用户已否掉的 Restore 梯子,而 **Restore 族 `grep -c '^//!WHEN'` = 0**
  —— 一个重型 CNN 在源分辨率上**无条件逐帧跑**(本人 2026-08-30 对上游 raw 复核,见 §1.1)。
  抄错的原因(commit `a8857f79` 原文):照**工作区**里一份未提交的回退版本抄的。
- **现在怎么处理**:测试 `no_preset_uses_restore`(`apps/desktop/src/shaders.rs:683-694`)
  禁止任何档位挂 `Restore`。
- **Go 侧怎么落**:①移植这条测试;②**抄任何表都用 `git show HEAD:<path>`,不要照工作区抄**。

### 坑 9 —— 换个「更权威的上游」会让整个锐化族静默失效

- **症状(尚未发生)**:把 CAS / NVSharpen 换成 agyild 的 gist 版本后,
  FSR 与 NVIDIA 两族的锐化六档在窗口模式下全部不跑。
- **真因**:两套移植的 `//!WHEN` 语义根本不同(本人 A/B 实测,详见 §1.1):
  agyild 版是 `OUTPUT.w OUTPUT.h * LUMA.w LUMA.h * / 1.0 >`(**放大类**),
  我们的 `_RT` 版是 `//!WHEN STR` / `//!WHEN SHARP`(**效果类**)。
- **现在怎么处理**:**已被现有测试覆盖**(这条是好消息)。
  `is_upscale_gated` 从源现算 → `works_at_any_size` 翻转 →
  `sharpen_denoise_levels_work_in_windowed_mode`(`apps/desktop/src/shaders.rs:698-710`,
  显式列了 `fsr_sharp_l/m/h` 与 `nv_sharp_l/m/h`)当场变红。
- **Go 侧怎么落**:**这就是「从源里现算,不手工维护白名单」的价值证明**(`shaders.rs:140` 的设计)。
  Go 侧若图省事改成硬编码名单,这道保护就没了。

### 坑 10 —— 前端家族名少登记一个,整族从面板静默消失

- **症状**:某一族的 6~7 个档位在 UI 上完全看不见,不报错。
- **真因**:UI 按家族名分组渲染,前端有一份 `SHADER_FAMILIES`
  (`ui/desktop/App.tsx:118-123`),必须与核层 `levels()` 的第三字段**逐字一致**。
- **现在怎么处理**:核层测试钉家族名集合(`apps/desktop/src/shaders.rs:597-626`
  的 `FAMILIES` 与 `every_family_has_at_least_six_modes`),前端侧有
  `api_contract_tests::shader_family_groups_match_the_core_level_table` 对齐两边
  (出处:commit `b02ac574` 的 message)。
- **Go 侧怎么落**:跨语言契约测试要一起迁。同类前车之鉴见记忆 [[sourcekind-wire-is-lowercase]]:
  前端把枚举值大小写写错,**两边都不报错**。

---

## 7. Go 侧移植要点

### 7.1 三条不能丢的设计原则

1. **一切判据从 shader 源现算,不维护白名单。**
   `is_upscale_gated`(`apps/desktop/src/shaders.rs:141-145`)、`params_of`、`param_range`、
   `dead_value`、`default_of` 全是运行时/测试期解析嵌入的 `.glsl` 文本。
   理由写在 `:140`:「换 shader 文件时结论自动跟着变,不会留下过期的白名单」。
   坑 9 证明了它真的救过场。**Go 里图省事改成硬编码表 = 主动废掉这道保护。**
2. **凡是 mpv 的 setter 都要回读。** 现有三处:
   `glsl-shader-opts`(`crates/mpv/src/lib.rs:1921-1924`)、
   `gpu-shader-cache-dir`(`:1336-1359`)、
   `glsl-shaders` 的条数(`:1943-1947`)。
   共同点是**写失败不报错**。
3. **不许把「挂上了」说成「生效了」。** `count > 0` 与 `will_run` 是两件事(坑 2)。

### 7.2 直接对应关系

| Rust 现状 | Go 对应 | 注意 |
|---|---|---|
| `include_str!("../shaders/X.glsl")` | `//go:embed shaders/*.glsl` + `embed.FS` | `go:embed` **不能跨模块目录向上引用**(`..` 非法)。安卓那份现在靠 `include_str!("../../desktop/shaders/…")` 跨目录 —— **这个手法在 Go 里不成立**,必须改成共享包(见 7.3) |
| `FILES: &[(&str, &str)]` | 从 `embed.FS` 遍历,或显式 `map[string]string` | 保留「文件名 → 内容」的形状即可 |
| `Preset { files, opts }` | 同名 struct | **`files` 是有序切片,不是集合** —— 顺序就是 mpv 的挂载顺序,不能用 map |
| `preset(level) -> Option<Preset>` | `func preset(level string) (Preset, bool)` | `off` 与未知都返回 `false` |
| `will_run(...) -> Option<bool>` | `func willRun(...) (bool, bool)` 或 `*bool` | **三态必须保住**,`None` 不能塌成 `false` |
| `shader_opts(level) -> &str` | 返回 `string` | `off` 必须返回**空串**(用于清掉上一档参数),不是不调用 |
| `ensure_files(dir)` | 同逻辑 | 按**文件长度**判新旧(`:378-381`),避免每次起播重写 |

### 7.3 ★ 顺手把「复制」改成「共享」

现状:`apps/android/src/shaders.rs` 是 `apps/desktop/src/shaders.rs` 的**逐字副本**
(38 行差异全是 `include_str!` 路径,见 §5.1)。两份之间**没有任何同步机制**。

Go 侧应当:把档位表 + `.glsl` + 16 个测试放进**一个共享包**,两端 import。
这不是重构洁癖 —— 现在改一份忘一份**不会有任何编译错误或测试失败**,
而两端的 `set_shader_level` 命令返回同一个结构体给同一份前端代码。

### 7.4 必须一起迁的 16 个测试

出处均为 `apps/desktop/src/shaders.rs`。**这些测试是本模块的全部安全网**,
少迁一条就多一个静默失效面。

| # | 测试 | 行号 | 它防的是什么 |
|---|---|---|---|
| 1 | `every_preset_file_is_embedded` | 413 | 档位引用了没嵌进来的文件 → 运行时才炸 |
| 2 | `every_preset_opt_names_a_param_that_this_preset_loads` | 441 | **坑 5**:参数名不属本档 → mpv 拒整条 opts |
| 3 | `preset_opt_values_are_in_range_and_actually_run` | 504 | 值越界,或恰好等于「`//!WHEN` 为假」的死值 |
| 4 | `no_preset_loads_two_shaders_sharing_a_param_name` | 540 | **坑 6**:同名 `//!PARAM` 串味 |
| 5 | `sharpen_ladder_is_monotonic_and_above_shader_default` | 561 | **坑 4**:梯度必须单调且高于自带默认 |
| 6 | `off_clears_opts` | 581 | 切回关闭时上一档参数还挂着 |
| 7 | `off_yields_no_shaders` | 589 | 同上 |
| 8 | `every_family_has_at_least_six_modes` | 603 | **坑 10**:家族名打错 → 整族消失;顺带查 id 重复 |
| 9 | `sharpen_family_runs_windowed_and_is_stronger_than_defaults` | 633 | 锐化族必须窗口生效 + 强于自带默认 |
| 10 | `no_preset_uses_restore` | 684 | **坑 8**:用户两次否掉 Restore |
| 11 | `sharpen_denoise_levels_work_in_windowed_mode` | 699 | **坑 9**:换上游文件会在这里红 |
| 12 | `upscale_levels_need_upscaling` | 714 | `will_run` 的六条边界(含除零、恰好 1.2、单边过线) |
| 13 | `when_ratio_matches_shader_source` | 736 | 常量必须等于 shader 源里真写的数(**有覆盖缺口,见坑 7**) |
| 14 | `upscale_gate_detection_is_sane` | 763 | 先验门槛识别本身判得对,否则上面几条全是空转 |
| 15 | `param_extraction_is_sane` | 777 | 先验参数抽取本身对,同理 |
| 16 | `embedded_files_non_empty` | 786 | 文件被清空/拉取失败会静默变成空串 |

⚠️ 注意 14/15/16 是**地基测试**:它们验证的是「解析器本身没坏」。
没有它们,1~13 会在解析器失效时全部落到空集上断言而恒绿 —— 这正是记忆 [[test-must-fail-first]] 里
「断言的时序让 bug 没机会发生 / 清理类断言最易测成空集」那一类假绿。

### 7.5 mpv 属性清单(Go 侧要用到的全部)

| 属性 | 用途 | 代码位置 |
|---|---|---|
| `glsl-shaders` | 写:分号分隔的绝对路径;读:数条数 | `crates/mpv/src/lib.rs:1910-1917`、`:1943-1947` |
| `glsl-shader-opts` | 写:`K=V,K=V`;**写完必须回读比对** | `:1921-1924` |
| `dwidth` / `dheight` | 源尺寸(= shader 里的 `MAIN`) | `:1928-1932` |
| `osd-width` / `osd-height` | 输出区尺寸(= shader 里的 `OUTPUT`) | `:1933-1938` |
| `gpu-shader-cache` / `gpu-shader-cache-dir` | **初始化前**设,初始化后回读 | `:1288-1291`、`:1336-1359` |
| `vo` / `gpu-context` / `hwdec` | 平台分叉,见 §5.3 | `:1232-1272` |

⚠️ `dwidth`/`dheight` 而不是 `width`/`height`:注释 `:1926` 写明「**显示**尺寸,已算进
非方像素/裁剪,正是 shader 里的 `MAIN`」。用错就会在 anamorphic 片源上判错。

### 7.6 最容易在迁移中丢掉的一条

**坑 1 的独显钉定不是代码逻辑,是最终可执行文件的 PE 导出表。**
Rust 侧靠 `#[used] #[no_mangle]` 静态量(`apps/desktop/src/lib.rs:20-27`)+
链接器参数 `/EXPORT:`(`apps/desktop/build.rs:33-34`)两半合成。
**Go 侧要如何产出同样的导出符号:未确认** —— 我没有验证过 Go 工具链在这件事上的行为。
**迁移后必须做一次 A/B 日志验证**(`set LP_MPV_LOG=1`,读 `Device Name:`),
不能因为「代码看起来搬过来了」就认为它还在 —— 这条**缺了不报错,只是继续用核显**。

---

## 8. 可以考虑引入的新模型 / 新选项

**克制原则**:我们现在有 27 个档位。**再加东西之前先问它解决谁的问题。**
以下每条都标了代价,按「性价比」排序,不是许愿单。

### 建议 1(最划算)—— 打开 mpv 内置的 `--deband`

- **理由**:我们**一个 mpv 内置画质选项都没设**(本人 grep 确认:`deband` / `scale` / `cscale` /
  `sigmoid` / `tone-mapping` 在 `crates/` `apps/` 下零命中),全吃默认,而 `--deband` **默认是关的**。
  manual 原文:"virtually always an improvement - the only reason to disable it would be for performance."
  动画的色带是用户实际会看到的问题,而我们现在**完全没治**。
- **代价**:① 轻微模糊最细的细节(manual 原文承认);② 有 GPU 开销;
  ③ 它是**全局渲染选项**,不属于任何 shader 档位 —— 需要新的开关面(不能塞进现有档位表)。
- **未确认**:开销量级。manual 没给数字,我也没实测。

### 建议 2 —— ArtCNN 的 `_DS` 变体(去噪 + 锐化二合一)

- **理由**:官方 README 原文 `_DS` = "Luma doublers trained to **denoise and sharpen**"。
  我们现在实现同样效果要挂两个 pass(如 `ak_up_artcnn_sh` = ArtCNN + Adaptive)。
  单文件一体化通常更省。文件已在上游:`GLSL/ArtCNN_C4F16_DS.glsl`。
- **代价**:① 又多两档,档位表已经 27 个了;② 它是放大类,窗口下不跑,
  和已有的 `ak_up_artcnn_sh` 定位重叠 —— **是否优于现有实现未实测**;
  ③ 引入前必须核对它的 `//!WHEN` 阈值(见坑 7,上游是 1.3 不是 1.2)。
- **建议**:**先不做。** 除非有人实测出它明显优于现有的 `ak_up_artcnn_sh`。

### 建议 3 —— ArtCNN `C4F32`(比 C4F16 大一档)

- **理由**:README 的推荐序是 `R16F96` > `R8F64` > `C4F32`(硬件够时的实时选择)> `C4F16`(最轻)。
  我们只用了**最轻的那个**。壮机用户的上限被我们人为压住了。
- **代价**:① 文件更大(C4F16 本地已 213 KB);② GPU 开销显著上升;
  ③ 需要给用户一个「我的机器够不够」的判断依据 —— 而我们**没有任何性能埋点**(见 §9)。
- **建议**:**等有了帧时间埋点再做。** 现在加等于让用户拿自己的机器试错。

### 建议 4 —— `--scale=ewa_lanczossharp`(mpv 内置,不是 shader)

- **理由**:manual 说它是 `high-quality` profile 的默认,而我们用的是 mpv 默认 `lanczos`。
  它作用于**所有**缩放(含缩小播放),不挑尺寸。
- **代价**:① EWA 系明确标注 "Relatively slow";② 它和我们的放大类 shader **作用阶段重叠**,
  叠加效果未确认;③ 同样是全局选项,不属于档位表。
- **未确认**:与现有 shader 链叠加后的画质与开销。**必须实测才能上。**

### 不建议引入的

| 项 | 为什么不 |
|---|---|
| **Anime4K Restore / Restore_Soft / Restore_GAN** | 用户两次明确否掉,有测试钉(坑 8);且**无 `//!WHEN`,无条件跑**(§1.1) |
| **Anime4K Deblur / Thin / Darken** | 同样**无 `//!WHEN`** = 在源分辨率上逐帧无条件跑,是坑 1 那个量级的开销来源;Thin/Darken 官方还标了 Experimental |
| **FSRCNNX / ravu** | 我这轮**没有核实过**它们的现状与开销(§1.3 标了未确认)。在没做过评估之前把文件塞进包里,就是把 213 KB 级的东西压给所有用户 |
| **agyild 版 CAS / NVSharpen** | 门槛语义与我们相反,换进来会让锐化族在窗口下静默失效(坑 9) |

### 顺带记一条 manual 事实(不是建议,是纠正)

`apps/desktop/src/shaders.rs:535-538` 与测试 4 都断言「`glsl-shader-opts` 是**全局**的一张
K=V 表,不区分是给哪个 shader 的」。
**这句话在当前 mpv manual 下不完整** —— 原文:

> You can target specific named shaders by **prefixing the shader name with a `/`**,
> e.g. `shader/param=value`. Without a prefix, parameters affect all shaders.
> The shader name is the base part of the shader filename, without the extension.

我核对过 `v0.35.0` / `v0.38.0` / `v0.40.0` 三个 tag 的 `options.rst`,**这段话三处都在**,
不是新特性。
→ 即坑 6 的那条限制**在技术上可以解除**(写成 `Adaptive_sharpen_lite_luma_RT/STR=1.30`)。
**但我不建议现在动**:代价是每个档位的 opts 都要带上文件名前缀、测试 2/3/4 全要改,
而收益仅仅是「允许一档挂两个同名参数的锐化器」—— 而这件事本身用户没要求过,
`shaders.rs:287` 的设计是「每档只挂一个锐化器」。
**记在这里是为了纠正代码注释里的事实错误,不是为了改它。**

---

## 9. 存疑 / 需要实测验证的

### 9.1 ★ 当前就存在的风险(不是迁移才有的)

#### (1) `when_ratio_matches_shader_source` 有覆盖缺口 —— 一个活的假绿

**这是本次调研最重要的发现,详细因果链见坑 7。** 摘要:

- 测试筛选条件是 `l.contains("MAIN.w")`(`apps/desktop/src/shaders.rs:741`),
  而 **ArtCNN 用 `LUMA.w`** → 它的门槛**从未被这条测试检查过**。
- 我们这份 ArtCNN 阈值是 **1.2**,**上游 `Artoriuz/ArtCNN` main 是 1.3**(已 A/B 实测)。
- 一旦有人从上游刷新该文件:`WHEN_RATIO` 仍是 1.2 → `will_run()` 在 1.25× 返回 `Some(true)`
  → UI 报「超分已生效」→ 实际一帧不跑。**16 个测试全绿。**

**修法建议(三选一,按推荐度排)**:

1. **推荐 —— 从 shader 源解析它实际用的基准变量名,不写死 `MAIN.w`。**
   `//!WHEN` 是逆波兰式,形如 `OUTPUT.w <BASE>.w <op> <num> ...`。
   扫描时改成:凡是 `//!WHEN` 行里同时出现 `OUTPUT.` 和 `.w`,就把该行里的数值抽出来比对
   `WHEN_RATIO`,**不预设基准是 `MAIN` 还是 `LUMA` 还是 `HOOKED`**。
   这与本模块「一切从源现算,不维护白名单」的既有设计一致(`shaders.rs:140`)。
   ⚠️ 实现时要排除掉 `AutoDownscalePre` 的 `NATIVE` **区间闸**(x2 管 1.2~2.0、x4 管 2.4~4.0),
   那是另一套机制 —— 现有注释 `shaders.rs:733-734` 已经点明,别再踩一次。
   同样要排除 FSR1 EASU / NVScaler 的 `HOOKED.w 1.0 *`(阈值 1.0,不是 1.2,是「只要放大就跑」)。
2. **次选 —— 最小改动**:筛选条件从 `contains("MAIN.w")` 改成
   `contains("MAIN.w") || contains("LUMA.w")`。够治当前这一例,但下次换个用 `HOOKED` 的文件又漏。
3. **兜底 —— 加一条独立断言**:`WHEN_RATIO` 必须等于**每个被判为放大类的 shader** 里出现的
   非 1.0 阈值。比 2 严,比 1 好写。

**无论选哪个,先做反向注入验红**:把 `ArtCNN_C4F16.glsl` 的 `1.200` 手改成 `1.300`,
确认新测试变红 —— 不验红的测试等于没写(见记忆 [[test-must-fail-first]])。

#### (2) 移动端 `hdr-compute-peak` 能力回退

记忆 [[dolby-auto-decode]] 记载 Flutter 期做过「移动端软解关 `hdr-compute-peak`」,
但**当前 Rust 代码里 `grep -rn "hdr-compute-peak"` 零命中**(本人执行确认)。
manual 原文说它 "will probably also perform horribly on some drivers"、默认 `auto`(自动开)。
→ **换栈时这条没迁过来,现在移动端是开着的。** 影响未实测。

#### (3) Windows 侧 libmpv 未钉版本

`.github/workflows/build.yml:153` 取 shinchiro 的 `releases/latest`。
libplacebo 是 shader 的实际执行者,版本会在无人察觉时变动。
CI 唯一护栏是体积下限(`:164`),**不防版本漂移**。安卓侧是钉住的(`v1.1.11`)。

### 9.2 我们完全没有的东西

| 缺什么 | 后果 | 建议 |
|---|---|---|
| **任何性能埋点** | `grep -rn "frame-time\|render-time\|frame-drop"` 全仓零命中(已确认)。「卡不卡」全靠用户口头反馈,而坑 1 证明口头反馈会把原因归错 | 至少读一次 mpv 的帧时间属性,才能回答「这台机器能不能开 C4F32」(建议 3 的前提) |
| **两端渲染栈的画质 A/B** | 桌面 `gpu-next`(libplacebo)、安卓 `gpu`(旧渲染器),**共用同一张档位表**,从未对比过 | 同一片源同一档位两端各截一帧比对 |
| **真人片源提示** | Anime4K 官方明说是 anime 专用;真人片开了照样吃 GPU 却看不出变化,UI 不提示 | 低优先级,但这是「用户觉得没生效」的第 7 类原因(§3 表)|

### 9.3 代码里已知的小出入(不影响功能,但会误导人)

- `apps/desktop/src/shaders.rs:339` 注释写「档位从 19 涨到 **26**」,实点是 **27**
  (`off` 除外)。以代码为准。
- `crates/mpv/src/lib.rs:1908` 的 doc 注释仍写「超分(**Anime4K**):按档位挂 glsl-shaders」,
  实际已是四家族(Anime4K / FSR / NVIDIA / Sharpen)。
- **「档位不持久化」的设计说明只写在 `ui/tv/pages/SettingsPage.tsx:59-61`** ——
  一个改核层的人不会去读 TV 设置页。建议 Go 侧把这句搬到档位表旁边(见 §4.4)。
- `apps/desktop/src/shaders.rs:535-538` 断言 `glsl-shader-opts` 是纯全局表,
  **manual 说它支持 `shader/param=value` 前缀定向**(见 §8 末)。注释不完整。

### 9.4 外部知识里我没查实的

逐条列出,**别把它们当成已知**:

| 问题 | 我查了哪里 | 状态 |
|---|---|---|
| Anime4K v1 / v2 的差异 | README、`md/` 目录文件清单 | 未确认(官方无版本对照表) |
| S/M/L/VL/UL 对应几层几通道 | README、`GLSL_Instructions_Advanced.md` | 未确认(官方只给「每升一档耗时翻倍」);可从 `//!DESC` 的 `Conv-4x3x3xN` 反推 |
| `Restore_CNN_Soft_*` 与普通 Restore 的算法差异 | 同上 | 未确认 |
| Anime4K 官方绝对性能表(fps/ms) | README | 未确认(README 提到用 Vega64 测过 UL,但正文里没有数字表) |
| Mode A+A 与 B+B 第二个 Restore 插入位置为何不同 | 两份官方 `input.conf` | 未确认(两份都这么写,不是笔误) |
| ArtCNN 的 `C` / `R` 字母确切定义 | ArtCNN README | 未确认(README 未逐字定义;`F` 是滤波器数是明确的) |
| ArtCNN `R8F64` / `R16F96` 以什么形式分发 | GitHub API 拉 `main` 全树 | 未确认(`GLSL/` 下只有 C4F16/C4F32 与 `Experiments/R4F32_YCbCr`) |
| Adaptive_sharpen / FineSharp / aWarpSharp2 是否有活跃上游 | 文件头 LICENSE 段(已拿到原始出处) | 维护状态未确认 |
| FSRCNNX / ravu 的现状、变体差异、开销 | **没查** | 未确认 |
| `gpu` vs `gpu-next` 的完整差异总表 | `options.rst` 逐项 | 未找到官方总表;我只核到 5 个明确标注适用范围的选项(§2 末) |
| CAS 与 RCAS 的算法差异 | 本仓库注释 | 未确认(只知道它们挂不同 hook 阶段,所以能叠) |
| 2025–2026 新出的 mpv 画质项目 | **没系统检索** | 未确认 |
