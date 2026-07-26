/* ★ 本文件从 apps/desktop/src/shaders.rs 复制,**但 .glsl 不复制** ——
   include_str! 的路径改指向 `../../desktop/shaders/`。那些着色器有几百 KB,
   在仓库里放两份等于以后改一份忘一份,而 include_str! 是编译期读文件,
   跨目录引用完全可行。 */
//! 超分/画质增强档位 → glsl shader 链。
//!
//! ## 设计口径(用户 2026-07-15 定,推翻此前所有版本)
//! 用户原话:「为什么要用还原呢?不应该是**锐化+去噪**吗」「我也需要**窗口模式下也能锐化/去噪**」,
//! 并点名参考 hooke007/mpv_PlayKit。
//!
//! **核心教训:锐化/去噪 和 放大 是两件事,别糅成一坨。**
//! 此前六档全是 Anime4K 的 CNN **放大**链,而 Anime4K 每个 CNN pass 都带门槛
//! `//!WHEN OUTPUT.w MAIN.w / 1.200 > ...` —— 输出没比源大 1.2 倍就**一帧都不跑**。
//! 于是窗口里播 1080p(输出 1770×1080 < 源 1920×1080)点什么档位都毫无变化。
//! PlayKit 的做法才是对的:**锐化归锐化(门槛是参数,任何尺寸都跑),放大归放大(才看尺寸)**:
//! ```text
//! AMD_CAS_luma_RT   //!WHEN STR            ← 参数,窗口模式照跑
//! AMD_FSR1_RCAS_RT  //!WHEN SHARP 4.0 <    ← 参数,窗口模式照跑
//! Denoise_Bilateral //!WHEN 无             ← 永远跑
//! AMD_FSR1_EASU     //!WHEN OUTPUT.w HOOKED.w 1.0 * > ...  ← 放大器,才看尺寸
//! ```
//!
//! ## 前三档必须「窗口也能用」
//! modeA/B/C 只放**不挑尺寸**的 pass。`works_at_any_size()` 从 shader 源里现算这件事
//! (不手工维护名单),`levels()` 的第三个字段声明它,并有测试钉住两者一致 ——
//! 标着「窗口可用」却全是放大 pass,就是又一次「假装开了」。
//!
//! ## 历史(别再走回头路)
//! - Restore CNN:用户 2026-07-11(a5e21885)明确否掉 —— 动态画面边缘振铃/拖影,且最吃显卡。
//!   现在他又问了一遍「为什么要用还原」。**别加回来**,有测试钉。
//! - 纯 Anime4K CNN 去噪梯子(S/M/L/VL):看着合理,实际窗口模式下全程空转。只留 VL 作壮机全屏档。
//!
//! ## 为什么把 .glsl 编进二进制
//! 绿色版是 `app.exe + libmpv-2.dll` 平铺(bundle.active=false,见 [[pc-ui-react-build]]),
//! 没有 resources 目录可用。首次用时落盘到 app data —— mpv 的 glsl-shaders 只收文件路径。

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// 编译期嵌入(文件名, 内容)。CAS/FSR/Denoise_Bilateral 取自 hooke007/mpv_PlayKit
/// (AMD FSR/CAS 与 Anime4K 均为 MIT)。
const FILES: &[(&str, &str)] = &[
    // —— 不挑尺寸的效果 pass(窗口模式也跑) ——
    (
        "AMD_CAS_luma_RT.glsl",
        include_str!("../../desktop/shaders/AMD_CAS_luma_RT.glsl"),
    ),
    (
        "AMD_FSR1_RCAS_RT.glsl",
        include_str!("../../desktop/shaders/AMD_FSR1_RCAS_RT.glsl"),
    ),
    (
        "Anime4K_Denoise_Bilateral_Mean.glsl",
        include_str!("../../desktop/shaders/Anime4K_Denoise_Bilateral_Mean.glsl"),
    ),
    (
        "Anime4K_Denoise_Bilateral_Mode.glsl",
        include_str!("../../desktop/shaders/Anime4K_Denoise_Bilateral_Mode.glsl"),
    ),
    /* —— 锐化专精(2026-07-20 用户:「其实清晰最重要的是锐化,锐化是最能提升看起来清晰的程度的」)——
       全部 `//!WHEN <参数>` 门槛,窗口模式照跑;全部 HOOK LUMA(只动亮度,不碰色度)= 便宜。
       它们的**自带默认都很保守**(Adaptive STR=1.0 / FineSharp SSTR=0.5 / aWarpSharp2 STR=4.0),
       正是「开到最大档也只有一点点变清晰」的来源 —— 强度在 preset() 里按档位拉开。 */
    (
        "Adaptive_sharpen_lite_luma_RT.glsl",
        include_str!("../../desktop/shaders/Adaptive_sharpen_lite_luma_RT.glsl"),
    ),
    (
        "FineSharp_RT.glsl",
        include_str!("../../desktop/shaders/FineSharp_RT.glsl"),
    ),
    (
        "aWarpSharp2_RT.glsl",
        include_str!("../../desktop/shaders/aWarpSharp2_RT.glsl"),
    ),
    // BCAS = 双边 CAS:锐化的同时按局部方差压噪点,比裸 CAS 更敢开大。HOOK MAIN。
    (
        "AMD_BCAS_RT.glsl",
        include_str!("../../desktop/shaders/AMD_BCAS_RT.glsl"),
    ),
    /* ArtCNN C4F16:luma-only 的 4 层 CNN 放大器,PlayKit 里「清晰/开销」比最好的一档之一。
       单文件 213K(权重全写在源里),尺寸门控写法是 `OUTPUT.w LUMA.w 1.200 * >`
       —— 和 Anime4K 的 `OUTPUT.w MAIN.w / 1.200 >` 数学等价,同为 1.2 倍闸。 */
    (
        "ArtCNN_C4F16.glsl",
        include_str!("../../desktop/shaders/ArtCNN_C4F16.glsl"),
    ),
    // —— NVIDIA Image Scaling(NIS,取自 hooke007/mpv_PlayKit)——
    // NVSharpen:纯锐化,//!WHEN SHARP 是参数,窗口模式也跑;NVScaler:放大+锐化,//!WHEN OUTPUT 挑尺寸。
    (
        "NVSharpen_RT.glsl",
        include_str!("../../desktop/shaders/NVSharpen_RT.glsl"),
    ),
    (
        "NVScaler_RT.glsl",
        include_str!("../../desktop/shaders/NVScaler_RT.glsl"),
    ),
    // —— 放大器(要输出>源才跑) ——
    (
        "AMD_FSR1_EASU.glsl",
        include_str!("../../desktop/shaders/AMD_FSR1_EASU.glsl"),
    ),
    (
        "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl",
        include_str!("../../desktop/shaders/Anime4K_Upscale_Denoise_CNN_x2_VL.glsl"),
    ),
    (
        "Anime4K_Upscale_CNN_x2_M.glsl",
        include_str!("../../desktop/shaders/Anime4K_Upscale_CNN_x2_M.glsl"),
    ),
    // —— 辅助 pass(自己不产生可见效果) ——
    (
        "Anime4K_Clamp_Highlights.glsl",
        include_str!("../../desktop/shaders/Anime4K_Clamp_Highlights.glsl"),
    ),
    (
        "Anime4K_AutoDownscalePre_x2.glsl",
        include_str!("../../desktop/shaders/Anime4K_AutoDownscalePre_x2.glsl"),
    ),
    (
        "Anime4K_AutoDownscalePre_x4.glsl",
        include_str!("../../desktop/shaders/Anime4K_AutoDownscalePre_x4.glsl"),
    ),
];

/// 辅助 pass:自己不产生可见效果,只服务于放大链(高光钳位 / 降回显示分辨率)。
/// 判断「这档在窗口下有没有效果」时不算数 —— 只有它们跑起来等于什么都没发生。
const HELPERS: &[&str] = &[
    "Anime4K_Clamp_Highlights.glsl",
    "Anime4K_AutoDownscalePre_x2.glsl",
    "Anime4K_AutoDownscalePre_x4.glsl",
];

/// Anime4K CNN pass 的尺寸门槛:输出宽高都要 > 源的 1.2 倍。
/// shader 源里写死的是 `//!WHEN OUTPUT.w MAIN.w / 1.200 > OUTPUT.h MAIN.h / 1.200 > *`。
/// 有测试从嵌入的源里抠出这个数比对。
pub const WHEN_RATIO: f64 = 1.2;

fn body_of(name: &str) -> &'static str {
    FILES.iter().find(|(n, _)| *n == name).map(|(_, b)| *b).unwrap_or("")
}

/// 这个 shader 是不是「只有放大才跑」—— 直接看它的 `//!WHEN` 里有没有拿 OUTPUT 比尺寸。
/// **从源里现算,不手工维护名单**:换 shader 文件时结论自动跟着变,不会留下过期的白名单。
fn is_upscale_gated(name: &str) -> bool {
    body_of(name)
        .lines()
        .any(|l| l.starts_with("//!WHEN") && l.contains("OUTPUT."))
}

/// 这档在**任意尺寸**(含窗口模式、缩小播放)下有可见效果吗?
/// 判据:存在至少一个「非辅助、且不挑尺寸」的 pass。
///
/// ⚠️ 语义是「**有效果**」,不是「**全部 pass 都跑**」。FSR 档(modeAA/BB)在窗口下
/// EASU 放大那半会被跳过、RCAS 锐化那半照跑 → 判 true,即「退化成只锐化」。
/// 这是第一版写错的地方:我照直觉把 FSR 档标成 false,是 window_ok_flag_matches_shader_gates
/// 红了才发现 RCAS 的门槛(`//!WHEN SHARP 4.0 <`)是**参数**不是尺寸。
pub fn works_at_any_size(level: &str) -> bool {
    preset(level).is_some_and(|p| {
        p.files
            .iter()
            .any(|f| !HELPERS.contains(f) && !is_upscale_gated(f))
    })
}

/// 当前尺寸下这档会不会真的有效果。`None` = 尺寸未知(没在播),不下结论。
/// ★ 存在的理由:mpv 收下 glsl-shaders 路径 ≠ shader 会执行。
/// 2026-07-15 真机:窗口 1770×1080 播 1920×1080,六个 CNN pass 全被 //!WHEN 跳过,
/// 而 UI 还在报「超分已生效 · 挂载 6 个 shader」—— 典型的「不报错,只是静默不干活」。
pub fn will_run(level: &str, video: Option<(f64, f64)>, output: Option<(f64, f64)>) -> Option<bool> {
    if preset(level).is_none() {
        return None; // off / 未知
    }
    if works_at_any_size(level) {
        return Some(true); // 锐化/去噪档:不挑尺寸,永远有效果
    }
    let ((vw, vh), (ow, oh)) = (video?, output?);
    if vw <= 0.0 || vh <= 0.0 {
        return None;
    }
    Some(ow / vw > WHEN_RATIO && oh / vh > WHEN_RATIO)
}

/// 一个档位 = shader 链 + 这条链的**调好的参数**。
pub struct Preset {
    /// **顺序就是 pipeline**:先去噪(在源分辨率上最干净)→ 再放大 → 最后锐化。
    pub files: &'static [&'static str],
    /// 喂 mpv `glsl-shader-opts` 的 `K=V,K=V`。空 = 这条链没有可调参数。
    ///
    /// ⚠️ 只能写**本档 files 里真实存在**的 `//!PARAM` —— mpv 遇到不认识的参数名会
    /// 整条 opts 拒掉(于是锐化强度静默回到默认)。有测试逐档钉这件事。
    pub opts: &'static str,
}

/// 档位 → shader 链 + 参数。
/// 键名 modeA..modeAC 是历史键,与内容无关 —— 别为了「名字对得上」去改键,改了用户存的档位就丢。
///
/// ## 强度是**档位设计的一部分**,不是用户的活(用户 2026-07-15 定)
/// 原话:「强度不是靠用户调的 是让你设计挡位的 我说看不太出来 你就把各个档位都调高不就好了吗
/// 用户又不会调」。此前我加了个 0~100 的 stepper 让用户自己找甜点 —— 那是把设计责任外包给用户。
/// 现在每档的参数**在这里调死**,梯度由档位名承诺(轻/推荐/强),UI 上没有任何数字可拧。
///
/// 参数怎么来的(别拍脑袋改,先看这段):
/// - `STR`(CAS,0.0~1.0,**越大越锐**):shader 默认 0.5 = 只开一半,就是「看不太出来」的根因。
///   代码 `peak = -1.0 / mix(8.0, 5.0, STR)`。0 = 不跑(`//!WHEN STR`)。
/// - `SHARP`(RCAS,0.0~4.0,**越小越锐**):代码 `sharp = exp2(-SHARP)`,默认 0.2 本就接近最锐,
///   所以放大档的提升空间不在这儿。4.0 = 不跑(`//!WHEN SHARP 4.0 <`)。
fn preset(level: &str) -> Option<Preset> {
    Some(match level {
        // ═══════════ 家族一:Anime4K(动漫特化:双边去噪 + CNN 超分) ═══════════
        // Denoise_Bilateral 没有 //!PARAM,强度靠换 Mean(温和)/Mode(更狠)两个算法拉开。
        "ak_denoise_l" => Preset { files: &["Anime4K_Denoise_Bilateral_Mean.glsl"], opts: "" },
        "ak_denoise_h" => Preset { files: &["Anime4K_Denoise_Bilateral_Mode.glsl"], opts: "" },
        // 去噪 + CAS 锐化(CAS 的 STR 越大越锐,烧进档位)。
        "ak_sharp" => Preset {
            files: &["Anime4K_Denoise_Bilateral_Mode.glsl", "AMD_CAS_luma_RT.glsl"],
            opts: "STR=0.85",
        },
        // CNN x2 放大(窗口下不跑,全屏才生效)。Clamp_Highlights 是前置辅助 pass。
        "ak_up_m" => Preset {
            files: &["Anime4K_Clamp_Highlights.glsl", "Anime4K_Upscale_CNN_x2_M.glsl"],
            opts: "",
        },
        // 去噪 + CNN x2 放大。
        "ak_up_dn" => Preset {
            files: &[
                "Anime4K_Denoise_Bilateral_Mode.glsl",
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl",
            ],
            opts: "",
        },
        // 重型 CNN 去噪放大链(壮机 + 全屏)。VL 模型 143K,这才是真「超分」。
        // Anime4K CNN 没有 //!PARAM —— 权重写死在模型里,强度不可调,只能换模型大小。
        "ak_up_vl" => Preset {
            files: &[
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl",
            ],
            opts: "",
        },

        // ═══════════ 家族二:AMD FSR(通用锐化 + FSR1 放大) ═══════════
        // 「轻」也比 shader 默认(0.5)高一档:用户基线是「默认档我看不出来」。CAS 的 STR 越大越锐。
        "fsr_sharp_l" => Preset { files: &["AMD_CAS_luma_RT.glsl"], opts: "STR=0.60" },
        "fsr_sharp_m" => Preset { files: &["AMD_CAS_luma_RT.glsl"], opts: "STR=0.85" },
        // 「强」:CAS 挂 LUMA、RCAS 挂 MAIN —— 不同阶段,可以叠,两个都拉到各自最锐端。
        "fsr_sharp_h" => Preset {
            files: &["AMD_CAS_luma_RT.glsl", "AMD_FSR1_RCAS_RT.glsl"],
            opts: "STR=1.00,SHARP=0.00",
        },
        // FSR1 官方链:EASU 放大 → RCAS 锐化。RCAS 门槛是参数,窗口下退化成「只锐化」。
        "fsr_up" => Preset {
            files: &["AMD_FSR1_EASU.glsl", "AMD_FSR1_RCAS_RT.glsl"],
            opts: "SHARP=0.25",
        },
        "fsr_up_h" => Preset {
            files: &["AMD_FSR1_EASU.glsl", "AMD_FSR1_RCAS_RT.glsl"],
            opts: "SHARP=0.00",
        },
        "fsr_up_dn" => Preset {
            files: &[
                "Anime4K_Denoise_Bilateral_Mode.glsl",
                "AMD_FSR1_EASU.glsl",
                "AMD_FSR1_RCAS_RT.glsl",
            ],
            opts: "SHARP=0.00",
        },

        // ═══════════ 家族三:NVIDIA Image Scaling(NIS) ═══════════
        // NVSharpen:纯锐化,//!WHEN SHARP 是参数(0~1,越大越锐),窗口模式也跑。SHARP=0 = 不跑。
        "nv_sharp_l" => Preset { files: &["NVSharpen_RT.glsl"], opts: "SHARP=0.30" },
        "nv_sharp_m" => Preset { files: &["NVSharpen_RT.glsl"], opts: "SHARP=0.50" },
        "nv_sharp_h" => Preset { files: &["NVSharpen_RT.glsl"], opts: "SHARP=0.85" },
        // NVScaler:放大 + 内建锐化(//!WHEN OUTPUT 挑尺寸,全屏才跑)。
        "nv_up" => Preset { files: &["NVScaler_RT.glsl"], opts: "SHARP=0.30" },
        "nv_up_h" => Preset { files: &["NVScaler_RT.glsl"], opts: "SHARP=0.50" },
        "nv_up_dn" => Preset {
            files: &["Anime4K_Denoise_Bilateral_Mode.glsl", "NVScaler_RT.glsl"],
            opts: "SHARP=0.50",
        },

        /* ═══════════ 家族四:锐化专精(2026-07-20 新增)═══════════
           用户原话:「其实清晰最重要的是锐化 锐化是最能提升看起来清晰的程度的」
           「参考人家的滤镜是怎么加的清晰且不吃性能的」。
           这一族**全部窗口模式就生效**(门槛是参数不是尺寸)、**全部 luma-only**(不碰色度,便宜),
           且强度一律开到远高于 shader 自带默认 —— 那个默认正是「开到最大也只有一点点」的病根。
           ⚠️ 每档只挂**一个**锐化器:Adaptive / aWarpSharp2 / BCAS 都叫 `STR`,而
           `glsl-shader-opts` 是**全局**的 —— 叠在同一档里会共用一个值、量纲还不同
           (0~2 / -20~20 / 0~1),必然串味且不报错。有测试钉住这条。 */
        // Adaptive_sharpen:按局部对比自适应,过冲小、不放大噪点。STR 0~2,自带默认才 1.0。
        "sh_ada_l" => Preset { files: &["Adaptive_sharpen_lite_luma_RT.glsl"], opts: "STR=0.70" },
        "sh_ada_m" => Preset { files: &["Adaptive_sharpen_lite_luma_RT.glsl"], opts: "STR=1.30" },
        "sh_ada_h" => Preset { files: &["Adaptive_sharpen_lite_luma_RT.glsl"], opts: "STR=1.90" },
        // FineSharp:RemoveGrain 系,先柔化再锐化,细节多且不易起噪。SSTR 0~8,自带默认才 0.5。
        "sh_fine_m" => Preset { files: &["FineSharp_RT.glsl"], opts: "SSTR=2.50" },
        "sh_fine_h" => Preset { files: &["FineSharp_RT.glsl"], opts: "SSTR=5.00" },
        // aWarpSharp2:不加对比度,靠**把像素往边缘推**收紧线条 —— 动漫线稿提升最明显。
        "sh_warp" => Preset { files: &["aWarpSharp2_RT.glsl"], opts: "STR=10.00" },
        // BCAS:双边 CAS,锐化同时按局部方差压噪,比裸 CAS 敢开到顶。
        "sh_bcas" => Preset { files: &["AMD_BCAS_RT.glsl"], opts: "STR=1.00,SIGMA=0.30" },

        /* ArtCNN C4F16 放大(尺寸门控,全屏才跑)。放 Anime4K 族:同为动漫向 luma CNN,
           但比 Upscale_CNN_x2_M 清晰、比 VL 便宜 —— 用户要的「清晰且不吃性能」就是这一档。 */
        "ak_up_artcnn" => Preset {
            files: &["Anime4K_Clamp_Highlights.glsl", "ArtCNN_C4F16.glsl"],
            opts: "",
        },
        // 放大 + 锐化收尾:CNN 放大后再补一刀 Adaptive,全屏下最清晰的一档。
        "ak_up_artcnn_sh" => Preset {
            files: &[
                "Anime4K_Clamp_Highlights.glsl",
                "ArtCNN_C4F16.glsl",
                "Adaptive_sharpen_lite_luma_RT.glsl",
            ],
            opts: "STR=1.30",
        },

        _ => return None, // off / 未知 = 关
    })
}

/// UI 档位清单 `(id, 显示名, 滤镜家族)`。
/// 用户 2026-07-16:「去掉放大才生效的模式那种分组,加入 FSR、专门的 NV 滤镜,三种滤镜每种六个模式」。
/// 第三个字段是**家族名**(Anime4K / FSR / NVIDIA),UI 按它分三组,每组六档 ——
/// 不再按「窗口可用 / 需放大」分组(那个割裂的角标去掉了)。
/// 「某档在当前窗口尺寸下会不会真跑」仍由 will_run() 在点击时如实 toast,不在列表里预标。
///
/// 名字里的 轻/推荐/强 是强度梯度的**唯一**出口 —— 参数在 preset() 里调死。
pub fn levels() -> Vec<(&'static str, &'static str, &'static str)> {
    vec![
        ("off", "关闭", ""),
        // —— Anime4K:动漫特化(双边去噪 + CNN 超分)——
        ("ak_denoise_l", "去噪 · 轻", "Anime4K"),
        ("ak_denoise_h", "去噪 · 强", "Anime4K"),
        ("ak_sharp", "锐化+去噪 · 推荐", "Anime4K"),
        ("ak_up_m", "放大 · CNN M", "Anime4K"),
        ("ak_up_dn", "放大+去噪 · CNN M", "Anime4K"),
        ("ak_up_vl", "放大去噪 · CNN VL · 壮机", "Anime4K"),
        ("ak_up_artcnn", "放大 · ArtCNN · 清晰轻量", "Anime4K"),
        ("ak_up_artcnn_sh", "放大+锐化 · ArtCNN · 最清晰", "Anime4K"),
        // —— AMD FSR:通用锐化 + FSR1 放大 ——
        ("fsr_sharp_l", "锐化 · 轻", "FSR"),
        ("fsr_sharp_m", "锐化 · 推荐", "FSR"),
        ("fsr_sharp_h", "锐化 · 强", "FSR"),
        ("fsr_up", "放大+锐化 · FSR1", "FSR"),
        ("fsr_up_h", "放大+锐化 · 强", "FSR"),
        ("fsr_up_dn", "放大+锐化+去噪", "FSR"),
        // —— NVIDIA Image Scaling(NIS)——
        ("nv_sharp_l", "锐化 · 轻", "NVIDIA"),
        ("nv_sharp_m", "锐化 · 推荐", "NVIDIA"),
        ("nv_sharp_h", "锐化 · 强", "NVIDIA"),
        ("nv_up", "放大 · NIS", "NVIDIA"),
        ("nv_up_h", "放大+锐化 · NIS", "NVIDIA"),
        ("nv_up_dn", "放大+锐化+去噪 · NIS", "NVIDIA"),
        /* —— 锐化专精:窗口/全屏都生效,开销最低,用户点名「最能提升看起来的清晰度」——
              放最后一族但它才是日常首选,UI 分组标题里写明「窗口也生效」。 */
        ("sh_ada_l", "自适应锐化 · 轻", "Sharpen"),
        ("sh_ada_m", "自适应锐化 · 推荐", "Sharpen"),
        ("sh_ada_h", "自适应锐化 · 强", "Sharpen"),
        ("sh_fine_m", "精细锐化 · 推荐", "Sharpen"),
        ("sh_fine_h", "精细锐化 · 强", "Sharpen"),
        ("sh_warp", "线条锐化 · 动漫线稿", "Sharpen"),
        ("sh_bcas", "双边锐化 BCAS · 强", "Sharpen"),
    ]
}

/// 档位 → `glsl-shader-opts` 的值。off/未知 → 空串(=清掉上一档的参数)。
pub fn shader_opts(level: &str) -> &'static str {
    preset(level).map(|p| p.opts).unwrap_or("")
}

/// 把嵌入的 shader 落盘到 dir(已存在且大小一致就跳过),返回 文件名→绝对路径。
fn ensure_files(dir: &Path) -> Result<HashMap<&'static str, PathBuf>, String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("建 shader 目录失败: {e}"))?;
    let mut map = HashMap::new();
    for (name, body) in FILES {
        let p = dir.join(name);
        // 内容是编译期常量,长度一致即认为已是当前版本(避免每次起播重写)。
        let fresh = std::fs::metadata(&p)
            .map(|m| m.len() == body.len() as u64)
            .unwrap_or(false);
        if !fresh {
            std::fs::write(&p, body).map_err(|e| format!("写 {name} 失败: {e}"))?;
        }
        map.insert(*name, p);
    }
    Ok(map)
}

/// 档位 → 可直接喂给 mpv glsl-shaders 的绝对路径列表。off/未知 → 空列表(=关)。
pub fn shader_paths(dir: &Path, level: &str) -> Result<Vec<String>, String> {
    let Some(p) = preset(level) else {
        return Ok(vec![]);
    };
    let files = ensure_files(dir)?;
    p.files
        .iter()
        .map(|n| {
            files
                .get(n)
                .map(|p| p.to_string_lossy().into_owned())
                .ok_or_else(|| format!("缺少 shader: {n}"))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 档位表里引用的每个文件都必须真的嵌进来了 —— 否则运行时才炸(超分点了没反应)。
    #[test]
    fn every_preset_file_is_embedded() {
        for (id, _, _) in levels() {
            let Some(p) = preset(id) else { continue };
            for f in p.files {
                assert!(
                    FILES.iter().any(|(n, _)| n == f),
                    "档位 {id} 引用了未嵌入的 shader: {f}"
                );
            }
        }
    }

    /// 抠出一个 shader 里所有 `//!PARAM X` 的参数名。
    fn params_of(file: &str) -> Vec<&'static str> {
        body_of(file)
            .lines()
            .filter_map(|l| l.trim().strip_prefix("//!PARAM "))
            .map(|s| s.trim())
            .collect()
    }

    /// ★★ 本档 opts 里写的每个参数名,都必须真的存在于**本档挂载的 shader** 里。
    ///
    /// 这是新设计(强度烧进档位)唯一会静默失效的地方:mpv 遇到不认识的参数名会把
    /// **整条 glsl-shader-opts 拒掉** —— 于是锐化悄悄回到默认 STR=0.5,正是用户
    /// 「看不太出来」的那个状态,而且不报错。
    /// 典型踩法:给只挂 CAS 的 modeA 写上 `SHARP=0`(RCAS 根本没加载)。
    #[test]
    fn every_preset_opt_names_a_param_that_this_preset_loads() {
        for (id, label, _) in levels() {
            let Some(p) = preset(id) else { continue };
            let available: Vec<&str> = p.files.iter().flat_map(|f| params_of(f)).collect();
            for kv in p.opts.split(',').filter(|s| !s.is_empty()) {
                let key = kv.split('=').next().unwrap().trim();
                assert!(
                    available.contains(&key),
                    "档位 {id}({label}) 的 opts 设了 {key},但它挂的 shader {:?} 里没有 //!PARAM {key} —— \
                     mpv 会拒掉整条 opts,强度静默回默认",
                    p.files
                );
            }
        }
    }

    /// 声明了 `//!PARAM name` 的那个文件里,它的 `//!MINIMUM`/`//!MAXIMUM` 是多少。
    /// **从源里现算** —— 各 shader 的量纲差得很远(Adaptive STR 0~2、aWarpSharp2 STR -20~20、
    /// FineSharp SSTR 0~8),写死一个统一区间只会在加新 shader 时误伤或漏放
    /// (这条测试原本就写死了 `0.0..=4.0`,加锐化族时当场误伤)。
    fn param_range(file: &str, param: &str) -> Option<(f64, f64)> {
        let mut lines = body_of(file)
            .lines()
            .skip_while(|l| l.trim().strip_prefix("//!PARAM ").map(str::trim) != Some(param));
        lines.next()?; // 消费掉 //!PARAM 那行
        let (mut min, mut max) = (None, None);
        for l in lines {
            let t = l.trim();
            // 下一个 //!PARAM / //!HOOK 之前才算本参数的属性
            if t.starts_with("//!PARAM") || t.starts_with("//!HOOK") {
                break;
            }
            if let Some(v) = t.strip_prefix("//!MINIMUM ") {
                min = v.trim().parse().ok();
            }
            if let Some(v) = t.strip_prefix("//!MAXIMUM ") {
                max = v.trim().parse().ok();
            }
        }
        Some((min?, max?))
    }

    /// 这个文件里,参数 `param` 取什么值会让它的 `//!WHEN` 为假(=这个 pass 一帧都不跑)。
    /// 两种写法都认:`//!WHEN STR`(0 为假)、`//!WHEN SHARP 4.0 <`(等于 4.0 为假)。
    /// **必须按文件算**:同名 SHARP 在 RCAS 里 4.0 是死值、在 NVSharpen 里 0 才是死值,
    /// 原来那张全局 `[("SHARP", 4.0)]` 表在两者并存时必然判错一边。
    fn dead_value(file: &str, param: &str) -> Option<f64> {
        for l in body_of(file).lines().filter(|l| l.starts_with("//!WHEN ")) {
            let t: Vec<&str> = l["//!WHEN ".len()..].split_whitespace().collect();
            match t.as_slice() {
                [p] if *p == param => return Some(0.0),
                [p, n, "<"] if *p == param => return n.parse().ok(),
                _ => {}
            }
        }
        None
    }

    /// 每档的参数值必须落在**声明它的那个 shader** 的 //!MINIMUM~//!MAXIMUM 内,
    /// 且**不等于「不跑」的那个端点**。
    /// 防的是:手滑把某档写成 SHARP=4.0 → `//!WHEN SHARP 4.0 <` 为假 → 这档最猛的那个 pass
    /// 一帧都不跑,UI 还显示「强」。
    #[test]
    fn preset_opt_values_are_in_range_and_actually_run() {
        for (id, label, _) in levels() {
            let Some(p) = preset(id) else { continue };
            for kv in p.opts.split(',').filter(|s| !s.is_empty()) {
                let (key, val) = kv.split_once('=').expect("opts 必须是 K=V");
                let v: f64 = val.parse().unwrap_or_else(|_| panic!("{id} 的 {kv} 不是数字"));
                // 上一条测试已保证 key 一定属于本档某个 file,这里找出是哪个。
                let owner = p
                    .files
                    .iter()
                    .find(|f| params_of(f).contains(&key))
                    .unwrap_or_else(|| panic!("{id} 的 {key} 没有归属文件"));
                let (min, max) = param_range(owner, key)
                    .unwrap_or_else(|| panic!("{owner} 的 //!PARAM {key} 没声明 MIN/MAX"));
                assert!(
                    (min..=max).contains(&v),
                    "{id}({label}) 的 {kv} 超出 {owner} 声明的 {min}~{max}"
                );
                if let Some(d) = dead_value(owner, key) {
                    assert!(
                        (v - d).abs() > 1e-9,
                        "{id}({label}) 把 {key} 设成了 {v} —— 那正是 {owner} 的 //!WHEN 为假的值,\
                         这个 pass 一帧都不会跑"
                    );
                }
            }
        }
    }

    /// ★ 同一档位里**不能有两个 shader 声明同名 //!PARAM**。
    ///
    /// `glsl-shader-opts` 是**全局**的一张 K=V 表,不区分是给哪个 shader 的。把两个都叫 `STR`
    /// 的锐化器叠进同一档,它们会共用同一个值,而量纲根本不同
    /// (Adaptive 0~2 / aWarpSharp2 -20~20 / BCAS 0~1)—— 结果是其中一个被喂了荒谬的强度,
    /// **mpv 不报错**,只是画面不对劲。这是加锐化家族时新长出来的静默失效面,钉住它。
    #[test]
    fn no_preset_loads_two_shaders_sharing_a_param_name() {
        for (id, label, _) in levels() {
            let Some(p) = preset(id) else { continue };
            for (i, a) in p.files.iter().enumerate() {
                for b in &p.files[i + 1..] {
                    for pa in params_of(a) {
                        assert!(
                            !params_of(b).contains(&pa),
                            "档位 {id}({label}) 同时挂了 {a} 和 {b},两者都声明 //!PARAM {pa} —— \
                             glsl-shader-opts 是全局表,它们会共用一个值(量纲还不同),必然串味且不报错"
                        );
                    }
                }
            }
        }
    }

    /// 强度梯度必须真的**单调递增**:轻 < 推荐 < 强。
    /// 用户的原话是「你就把各个档位都调高不就好了吗」—— 光有档位名没有梯度就是骗人。
    /// 注意 CAS 的 STR 越大越锐,所以这里比的是 STR 本身。
    #[test]
    fn sharpen_ladder_is_monotonic_and_above_shader_default() {
        let str_of = |id: &str| -> f64 {
            preset(id)
                .unwrap()
                .opts
                .split(',')
                .find_map(|kv| kv.strip_prefix("STR="))
                .unwrap_or_else(|| panic!("{id} 没设 STR"))
                .parse()
                .unwrap()
        };
        let (light, rec, strong) = (str_of("fsr_sharp_l"), str_of("fsr_sharp_m"), str_of("fsr_sharp_h"));
        assert!(light < rec && rec < strong, "锐化梯度必须 轻({light}) < 推荐({rec}) < 强({strong})");
        // 连最轻的一档都必须高于 shader 自带默认 0.5 —— 默认值就是用户说「看不出来」的那个。
        assert!(light > 0.5, "最轻档 STR={light} 没超过 shader 默认 0.5,等于没调");
        assert_eq!(strong, 1.0, "最强档必须顶到 //!MAXIMUM");
    }

    /// off/未知必须返回空 opts —— 否则切回「关闭」时上一档的参数还挂在 mpv 上。
    #[test]
    fn off_clears_opts() {
        assert_eq!(shader_opts("off"), "");
        assert_eq!(shader_opts("nonsense"), "");
        assert_eq!(shader_opts("fsr_sharp_h"), "STR=1.00,SHARP=0.00");
    }

    /// off/未知不该挂任何 shader。
    #[test]
    fn off_yields_no_shaders() {
        assert!(preset("off").is_none());
        assert!(preset("nonsense").is_none());
        assert!(preset("fsr_sharp_l").is_some());
    }

    /// UI 折叠分组按家族建,这里是家族名的**单一事实源**:核层多一个家族而 UI 没加,
    /// 那一整组就从面板里静默消失。测试同时钉住两边(前端那份有 api_contract 测试对齐)。
    const FAMILIES: [&str; 4] = ["Anime4K", "FSR", "NVIDIA", "Sharpen"];

    /// 四个家族每个至少六档 —— 用户 2026-07-16「三种滤镜每种六个模式」的底线仍在;
    /// 2026-07-20 又要求「加多几个档位」,所以放宽成**下限**而不是等号,
    /// 但家族本身必须一个不少。
    #[test]
    fn every_family_has_at_least_six_modes() {
        for fam in FAMILIES {
            let n = levels().iter().filter(|(_, _, f)| *f == fam).count();
            assert!(n >= 6, "家族 {fam} 至少 6 档,实际 {n}");
        }
        // 除 off 外每档都必须能解析出 preset,且家族名必须是 UI 认识的那几个之一 ——
        // 打错一个字(比如 "Sharpen" 写成 "sharpen")这档就从面板里静默消失。
        for (id, _, fam) in levels() {
            if id == "off" {
                continue;
            }
            assert!(
                FAMILIES.contains(&fam),
                "档位 {id} 的家族 {fam:?} 不在 UI 的分组表里,它会从面板里静默消失"
            );
            assert!(preset(id).is_some(), "档位 {id} 没有对应 preset");
        }
        // 档位 id 不能重复:UI 的 key 撞车,且用户存的档位指向哪个全看顺序。
        let ids: Vec<&str> = levels().iter().map(|(i, _, _)| *i).collect();
        let mut uniq = ids.clone();
        uniq.sort_unstable();
        uniq.dedup();
        assert_eq!(uniq.len(), ids.len(), "档位 id 有重复");
    }

    /// 锐化家族**必须整族都在窗口模式下就生效** —— 它存在的全部理由就是这个
    /// (用户 2026-07-20:「其实清晰最重要的是锐化」,而放大档在窗口下一帧都不跑)。
    /// 顺带钉强度梯度,以及「必须高于 shader 自带默认」——
    /// 那个保守默认正是用户报「开到最大档位也只有一点点变清晰」的根因。
    #[test]
    fn sharpen_family_runs_windowed_and_is_stronger_than_defaults() {
        for (id, label, fam) in levels() {
            if fam != "Sharpen" {
                continue;
            }
            assert!(works_at_any_size(id), "{id}({label}) 在锐化族里却挑尺寸");
            assert_eq!(
                will_run(id, Some((1920.0, 1080.0)), Some((1770.0, 1080.0))),
                Some(true),
                "{id}({label}) 在真机那个缩小窗口下必须有效果"
            );
        }
        let opt = |id: &str, k: &str| -> f64 {
            preset(id)
                .unwrap()
                .opts
                .split(',')
                .find_map(|kv| kv.strip_prefix(&format!("{k}=")))
                .unwrap_or_else(|| panic!("{id} 没设 {k}"))
                .parse()
                .unwrap()
        };
        let (l, m, h) = (opt("sh_ada_l", "STR"), opt("sh_ada_m", "STR"), opt("sh_ada_h", "STR"));
        assert!(l < m && m < h, "自适应锐化梯度必须 轻({l}) < 推荐({m}) < 强({h})");
        assert!(opt("sh_fine_m", "SSTR") < opt("sh_fine_h", "SSTR"), "精细锐化梯度反了");

        // shader 自带默认值:`//!PARAM`/`//!TYPE`/`//!MINIMUM`/`//!MAXIMUM` 之后紧跟的裸数字行。
        // 从源里现读,别写死 —— 换个 shader 版本默认值变了,这条要自动跟着变。
        let default_of = |file: &str, k: &str| -> f64 {
            let mut it = body_of(file)
                .lines()
                .skip_while(|l| l.trim().strip_prefix("//!PARAM ").map(str::trim) != Some(k));
            it.next().unwrap();
            it.find(|l| !l.trim().starts_with("//!") && !l.trim().is_empty())
                .unwrap()
                .trim()
                .parse()
                .unwrap()
        };
        let ada_def = default_of("Adaptive_sharpen_lite_luma_RT.glsl", "STR");
        assert!(m > ada_def, "自适应锐化推荐档 STR={m} 没超过自带默认 {ada_def},等于没调");
        let fine_def = default_of("FineSharp_RT.glsl", "SSTR");
        assert!(
            opt("sh_fine_m", "SSTR") > fine_def,
            "精细锐化推荐档没超过自带默认 {fine_def} —— 那正是「看不出来」的那个状态"
        );
    }

    /// 用户 2026-07-11(a5e21885)明确否掉 Restore:动态画面边缘振铃/拖影,且最吃显卡。
    /// 2026-07-15 他又问了一遍「为什么要用还原」。别再加回来。
    #[test]
    fn no_preset_uses_restore() {
        for (id, _, _) in levels() {
            let Some(p) = preset(id) else { continue };
            for f in p.files {
                assert!(
                    !f.contains("Restore"),
                    "档位 {id} 挂了 Restore({f}) —— 用户两次明确不要:拖影且最吃显卡"
                );
            }
        }
    }

    /// 每个家族的「锐化/去噪」档(不含放大)必须窗口模式下真有效果,一个尺寸门槛都不许有。
    /// (放大档 works_at_any_size 可真可假 —— 见 upscale_levels_need_upscaling。)
    #[test]
    fn sharpen_denoise_levels_work_in_windowed_mode() {
        // 三家族各挑纯锐化/去噪档(无放大 pass)。
        for id in ["ak_denoise_l", "ak_denoise_h", "ak_sharp", "fsr_sharp_l", "fsr_sharp_m", "fsr_sharp_h", "nv_sharp_l", "nv_sharp_m", "nv_sharp_h"] {
            assert!(works_at_any_size(id), "{id} 必须窗口模式下就能生效");
            // 缩小播放(1770×1080 窗口播 1920×1080,真机现场)也必须有效果
            assert_eq!(
                will_run(id, Some((1920.0, 1080.0)), Some((1770.0, 1080.0))),
                Some(true),
                "{id} 在真机那个窗口尺寸下必须有效果"
            );
        }
    }

    /// 纯放大档(全链都带尺寸门槛)在窗口下确实不生效 —— 不是 bug,是 shader 设计,如实由 will_run 报。
    #[test]
    fn upscale_levels_need_upscaling() {
        // ak_up_vl(纯 CNN)与 nv_up(NVScaler)都无「不挑尺寸」的 pass → 窗口不跑,全屏才跑。
        for id in ["ak_up_vl", "nv_up"] {
            assert!(!works_at_any_size(id), "{id} 应是纯放大档(窗口下无效果)");
            assert_eq!(will_run(id, Some((1920.0, 1080.0)), Some((1770.0, 1080.0))), Some(false), "{id} 窗口下不该跑");
            assert_eq!(will_run(id, Some((1920.0, 1080.0)), Some((2560.0, 1600.0))), Some(true), "{id} 全屏放大应跑");
        }
        // 只有一边过线也不行(WHEN 是 宽 AND 高)
        assert_eq!(will_run("ak_up_vl", Some((1920.0, 1080.0)), Some((3840.0, 1080.0))), Some(false));
        // 恰好 1.2 倍:shader 用的是 `>` 不是 `>=`
        assert_eq!(will_run("ak_up_vl", Some((1000.0, 1000.0)), Some((1200.0, 1200.0))), Some(false));
        // 没在播 / 源尺寸为 0(mpv 还没 reconfig)→ 不下结论,别除零除出 inf 说「能跑」
        assert_eq!(will_run("ak_up_vl", None, Some((2560.0, 1600.0))), None);
        assert_eq!(will_run("ak_up_vl", Some((0.0, 0.0)), Some((2560.0, 1600.0))), None);
        // off 不下结论
        assert_eq!(will_run("off", Some((1920.0, 1080.0)), Some((1770.0, 1080.0))), None);
    }

    /// WHEN_RATIO 必须等于 shader 源里真写的那个数,不能是我拍脑袋的常量。
    /// 只查**对 MAIN 的门槛** —— 那才是「这条链跑不跑」的总闸。故意不查 AutoDownscalePre 的
    /// `NATIVE` 区间闸(x2 管 1.2~2.0 倍、x4 管 2.4~4.0 倍),那是另一套机制。
    #[test]
    fn when_ratio_matches_shader_source() {
        let mut seen = 0;
        for (name, body) in FILES {
            for line in body
                .lines()
                .filter(|l| l.starts_with("//!WHEN") && l.contains("MAIN.w"))
            {
                let nums: Vec<f64> = line
                    .split_whitespace()
                    .filter_map(|t| t.parse::<f64>().ok())
                    .collect();
                assert!(!nums.is_empty(), "{name} 的 WHEN 行没解析出阈值: {line}");
                for n in nums {
                    assert!(
                        (n - WHEN_RATIO).abs() < 1e-6,
                        "{name} 的 MAIN 门槛是 {n},但 WHEN_RATIO={WHEN_RATIO} —— \
                         提示文案会报错误的数字,will_run 也会判错"
                    );
                    seen += 1;
                }
            }
        }
        assert!(seen > 0, "一个 MAIN 门槛都没扫到 —— 这条测试等于没跑,先查 shader 是不是换格式了");
    }

    /// is_upscale_gated 是从源里现算的,先验它在已知样本上判得对(不然上面几条全是空转)。
    #[test]
    fn upscale_gate_detection_is_sane() {
        assert!(is_upscale_gated("AMD_FSR1_EASU.glsl"), "EASU 是放大器,必须判成挑尺寸");
        assert!(is_upscale_gated("Anime4K_Upscale_Denoise_CNN_x2_VL.glsl"));
        assert!(is_upscale_gated("NVScaler_RT.glsl"), "NVScaler 的 //!WHEN OUTPUT 挑尺寸");
        assert!(!is_upscale_gated("NVSharpen_RT.glsl"), "NVSharpen 的 //!WHEN SHARP 是参数,不挑尺寸");
        assert!(!is_upscale_gated("AMD_CAS_luma_RT.glsl"), "CAS 的 //!WHEN STR 是参数,不挑尺寸");
        assert!(!is_upscale_gated("AMD_FSR1_RCAS_RT.glsl"), "RCAS 的 //!WHEN SHARP 是参数,不挑尺寸");
        assert!(!is_upscale_gated("Anime4K_Denoise_Bilateral_Mode.glsl"), "去噪没有 WHEN,永远跑");
        // 名字不存在时别默默返回 false 把「不挑尺寸」栽给一个不存在的文件
        assert_eq!(body_of("不存在.glsl"), "");
    }

    /// params_of 是上面两条 opts 测试的地基,先验它在已知样本上抠得对(不然那两条全是空转)。
    #[test]
    fn param_extraction_is_sane() {
        assert_eq!(params_of("AMD_CAS_luma_RT.glsl"), vec!["STR"]);
        assert!(params_of("AMD_FSR1_RCAS_RT.glsl").contains(&"SHARP"));
        assert!(params_of("Anime4K_Denoise_Bilateral_Mode.glsl").is_empty(), "去噪没有可调参数");
        assert!(params_of("AMD_FSR1_EASU.glsl").is_empty());
    }

    /// 嵌入的内容不能是空的(文件被清空/拉取失败会静默变成空串)。
    #[test]
    fn embedded_files_non_empty() {
        for (n, body) in FILES {
            assert!(body.len() > 200, "{n} 内容异常短: {}", body.len());
            assert!(body.contains("//!HOOK"), "{n} 不像个 mpv user shader(没有 //!HOOK)");
        }
    }
}
