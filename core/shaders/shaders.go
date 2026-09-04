// Package shaders 是超分 / 画质增强档位 → glsl shader 链。
//
// **Rust 版是黄金实现。**
// # 设计口径(用户 2026-07-15 定,推翻此前所有版本)
//
// 用户原话:「为什么要用还原呢?不应该是**锐化+去噪**吗」
// 「我也需要**窗口模式下也能锐化/去噪**」。
//
// **核心教训:锐化/去噪 和 放大 是两件事,别糅成一坨。**
//
// 此前六档全是 Anime4K 的 CNN **放大**链,而 Anime4K 每个 CNN pass 都带门槛
// `//!WHEN OUTPUT.w MAIN.w / 1.200 > ...` —— 输出没比源大 1.2 倍就**一帧都不跑**。
// 于是窗口里播 1080p(输出 1770×1080 < 源 1920×1080)点什么档位都毫无变化,
// 而 UI 还在报「超分已生效 · 挂载 6 个 shader」—— 典型的「不报错,只是静默不干活」。
//
// 正确的分法是:**锐化归锐化(门槛是参数,任何尺寸都跑),放大归放大(才看尺寸)**。
//
// # 强度是「档位设计」的一部分,不是用户的活
//
// 用户 2026-07-15 原话:「强度不是靠用户调的 是让你设计挡位的 我说看不太出来
// 你就把各个档位都调高不就好了吗 用户又不会调」。
// 此前加过一个 0~100 的 stepper 让用户自己找甜点 —— 那是把设计责任外包给用户。
// 现在每档的参数**在 presets 里调死**,梯度由档位名承诺(轻 / 推荐 / 强),
// UI 上没有任何数字可拧。
//
// # 历史(别再走回头路)
//
//   - Restore CNN:用户 2026-07-11 明确否掉 —— 动态画面边缘振铃 / 拖影,且最吃显卡。
//     **别加回来**,有测试钉。
//   - 纯 Anime4K CNN 去噪梯子(S/M/L/VL):看着合理,实际窗口模式下全程空转。
//     只留 VL 作壮机全屏档。
//
// # 为什么把 .glsl 编进二进制
//
// 绿色版是平铺分发,没有 resources 目录可用。首次用时落盘到数据目录 ——
// mpv 的 glsl-shaders 只收**文件路径**。
//
// ★ `files/` 下这份是本仓唯一一份。迁移期曾在旧栈里另有一份拷贝,
// 2026-09-04 那一份随旧栈一并删除。
package shaders

import (
	"embed"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

//go:embed files/*.glsl
var embedded embed.FS

// WhenRatio Anime4K CNN pass 的尺寸门槛:输出宽高都要 > 源的 1.2 倍。
//
// shader 源里写死的是 `//!WHEN OUTPUT.w MAIN.w / 1.200 > OUTPUT.h MAIN.h / 1.200 * >`。
// 有测试从嵌入的源里抠出这个数比对 —— 免得哪天换了 shader 文件而这里还写着旧值。
const WhenRatio = 1.2

// helpers 辅助 pass:自己不产生可见效果,只服务于放大链(高光钳位 / 降回显示分辨率)。
//
// ★ 判断「这档在窗口下有没有效果」时**不算数** —— 只有它们跑起来等于什么都没发生。
var helpers = map[string]bool{
	"Anime4K_Clamp_Highlights.glsl":    true,
	"Anime4K_AutoDownscalePre_x2.glsl": true,
	"Anime4K_AutoDownscalePre_x4.glsl": true,
}

// Preset 一个档位 = shader 链 + 这条链**调好的参数**。
type Preset struct {
	// Files **顺序就是 pipeline**:先去噪(在源分辨率上最干净)→ 再放大 → 最后锐化。
	Files []string
	// Opts 喂 mpv `glsl-shader-opts` 的 `K=V,K=V`。空 = 这条链没有可调参数。
	//
	// ⚠️ 只能写**本档 Files 里真实存在**的 `//!PARAM` —— mpv 遇到不认识的参数名会
	// **整条 opts 拒掉**(于是锐化强度静默回到 shader 自带默认,正是用户
	// 「看不太出来」的那个状态)。有测试逐档钉这件事。
	Opts string
}

// Level 一个档位的 UI 信息。**顺序就是 UI 里的顺序**,别按字母排。
type Level struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Group string `json:"group"`
}

// Levels 全部档位。
//
// ## 2026-09-02:砍到只剩 Anime4K 一族
//
// 用户原话:「有一个 Anime4K 足以了超分,其他的不需要」。此前有四族 28 档
// (Anime4K / FSR / NVIDIA / 锐化专精,2026-07-16 与 07-20 陆续加的),现在只留第一族。
//
// **直接起因**:换渲染后端之后真机全表跑了一遍,`AMD_CAS_luma_RT.glsl` 在
// `gl_video` + ANGLE(`#version 300 es`)下编译不过(`linearize()` 是 libplacebo 才有的),
// 用它的四个档位全是坏的。既然要删坏的,顺手把用不上的三族一起删了 ——
// 少一族就少一族要在每次换后端时重验的东西。
//
// ★ `ak_sharp` 原来挂的就是那个坏文件,**换成了 Adaptive_sharpen_lite**
// (同一轮真机验过能编译)。不是删掉这一档:它是唯一「窗口模式也生效」的
// 锐化+去噪档,而用户的基线是「清晰最重要的是锐化」。
//
// 「某档在当前窗口尺寸下会不会真跑」由 WillRun 在点击时如实告知,不在列表里预标。
//
// ★ 档位 id 是**历史键**,与内容无关 —— 别为了「名字对得上」去改键,
// 改了用户存的档位就丢。
func Levels() []Level {
	return []Level{
		{"off", "关闭", ""},
		{"ak_denoise_l", "去噪 · 轻", "Anime4K"},
		{"ak_denoise_h", "去噪 · 强", "Anime4K"},
		{"ak_sharp", "锐化+去噪 · 推荐", "Anime4K"},
		{"ak_up_m", "放大 · CNN M", "Anime4K"},
		{"ak_up_dn", "放大+去噪 · CNN M", "Anime4K"},
		{"ak_up_vl", "放大去噪 · CNN VL · 壮机", "Anime4K"},
		{"ak_up_artcnn", "放大 · ArtCNN · 清晰轻量", "Anime4K"},
		{"ak_up_artcnn_sh", "放大+锐化 · ArtCNN · 最清晰", "Anime4K"},
	}
}

/*
	presets 档位 → shader 链 + 参数。

参数怎么来的(别拍脑袋改,先看这段):
  - `STR`(CAS,0.0~1.0,**越大越锐**):shader 默认 0.5 = 只开一半,
    就是「看不太出来」的根因。代码 `peak = -1.0 / mix(8.0, 5.0, STR)`。
    0 = 不跑(`//!WHEN STR`)。
  - `SHARP`(RCAS,0.0~4.0,**越小越锐**):代码 `sharp = exp2(-SHARP)`,
    默认 0.2 本就接近最锐,所以放大档的提升空间不在这儿。4.0 = 不跑。
*/
var presets = map[string]Preset{
	// Denoise_Bilateral 没有 //!PARAM,强度靠换 Mean(温和)/ Mode(更狠)两个算法拉开
	"ak_denoise_l": {Files: []string{"Anime4K_Denoise_Bilateral_Mean.glsl"}},
	"ak_denoise_h": {Files: []string{"Anime4K_Denoise_Bilateral_Mode.glsl"}},
	/* ★★ 原来第二个 pass 是 AMD_CAS_luma_RT.glsl,**在新渲染后端上编译不过**
	   (2026-09-02 真机:`ERROR: 'linearize' : no matching overloaded function found`,
	   整屏变纯蓝)。换成 Adaptive_sharpen_lite —— 同一轮扫描里验过能编译,
	   而且 ak_up_artcnn_sh 一直在用它。
	   STR 量纲跟着换了:CAS 是 0~1,Adaptive 是 0~2,所以 0.85 → 1.30
	   (对齐 sh_ada_m 那档「推荐」的强度,那个值是 2026-07-20 调出来的)。 */
	"ak_sharp": {
		Files: []string{"Anime4K_Denoise_Bilateral_Mode.glsl", "Adaptive_sharpen_lite_luma_RT.glsl"},
		Opts:  "STR=1.30",
	},
	// CNN x2 放大(窗口下不跑,全屏才生效)。Clamp_Highlights 是前置辅助 pass
	"ak_up_m": {Files: []string{"Anime4K_Clamp_Highlights.glsl", "Anime4K_Upscale_CNN_x2_M.glsl"}},
	"ak_up_dn": {Files: []string{
		"Anime4K_Denoise_Bilateral_Mode.glsl",
		"Anime4K_Clamp_Highlights.glsl",
		"Anime4K_Upscale_CNN_x2_M.glsl",
	}},
	// 重型 CNN 去噪放大链(壮机 + 全屏)。
	// ★ Anime4K CNN 没有 //!PARAM —— 权重写死在模型里,强度不可调,只能换模型大小
	"ak_up_vl": {Files: []string{
		"Anime4K_Clamp_Highlights.glsl",
		"Anime4K_Upscale_Denoise_CNN_x2_VL.glsl",
		"Anime4K_AutoDownscalePre_x2.glsl",
		"Anime4K_AutoDownscalePre_x4.glsl",
		"Anime4K_Upscale_CNN_x2_M.glsl",
	}},
	"ak_up_artcnn": {Files: []string{"Anime4K_Clamp_Highlights.glsl", "ArtCNN_C4F16.glsl"}},
	// 放大 + 锐化收尾:CNN 放大后再补一刀 Adaptive,全屏下最清晰的一档
	"ak_up_artcnn_sh": {
		Files: []string{"Anime4K_Clamp_Highlights.glsl", "ArtCNN_C4F16.glsl", "Adaptive_sharpen_lite_luma_RT.glsl"},
		Opts:  "STR=1.30",
	},
}

// PresetOf 取一个档位。off / 未知 = 关(ok=false)。
func PresetOf(level string) (Preset, bool) {
	p, ok := presets[level]
	return p, ok
}

// Opts 这一档的 `glsl-shader-opts` 串。off / 未知 = 空串。
//
// ★ 切到 off 时给空串,**顺带把上一档的参数清掉** —— 不清的话下一档会吃到
// 上一档留下的值(glsl-shader-opts 是全局的)。
func Opts(level string) string {
	p, ok := presets[level]
	if !ok {
		return ""
	}
	return p.Opts
}

func bodyOf(name string) string {
	b, err := embedded.ReadFile("files/" + name)
	if err != nil {
		return ""
	}
	return string(b)
}

// isUpscaleGated 这个 shader 是不是「只有放大才跑」。
//
// ★ **从源里现算,不手工维护名单** —— 换 shader 文件时结论自动跟着变,
// 不会留下过期的白名单。判据:`//!WHEN` 里有没有拿 OUTPUT 比尺寸。
func isUpscaleGated(name string) bool {
	for _, l := range strings.Split(bodyOf(name), "\n") {
		if strings.HasPrefix(l, "//!WHEN") && strings.Contains(l, "OUTPUT.") {
			return true
		}
	}
	return false
}

// WorksAtAnySize 这档在**任意尺寸**(含窗口模式、缩小播放)下有可见效果吗。
//
// 判据:存在至少一个「非辅助、且不挑尺寸」的 pass。
//
// ⚠️ 语义是「**有效果**」,不是「**全部 pass 都跑**」。FSR 档在窗口下 EASU 放大那半
// 会被跳过、RCAS 锐化那半照跑 → 判 true,即「退化成只锐化」。
// 这是 Rust 侧第一版写错的地方:照直觉把 FSR 档标成 false,
// 是测试红了才发现 RCAS 的门槛(`//!WHEN SHARP 4.0 <`)是**参数**不是尺寸。
func WorksAtAnySize(level string) bool {
	p, ok := presets[level]
	if !ok {
		return false
	}
	for _, f := range p.Files {
		if !helpers[f] && !isUpscaleGated(f) {
			return true
		}
	}
	return false
}

// WillRun 当前尺寸下这档会不会真的有效果。ok=false 表示尺寸未知(没在播),**不下结论**。
//
// ★★ 存在的理由:**mpv 收下 glsl-shaders 路径 ≠ shader 会执行**。
// 2026-07-15 真机:窗口 1770×1080 播 1920×1080,六个 CNN pass 全被 //!WHEN 跳过,
// 而 UI 还在报「超分已生效 · 挂载 6 个 shader」。那是在撒谎,正是本项目最贵的那类 bug。
func WillRun(level string, videoW, videoH, outW, outH float64) (run bool, ok bool) {
	if _, exists := presets[level]; !exists {
		return false, false // off / 未知
	}
	if WorksAtAnySize(level) {
		return true, true // 锐化 / 去噪档:不挑尺寸,永远有效果
	}
	if videoW <= 0 || videoH <= 0 || outW <= 0 || outH <= 0 {
		return false, false // 尺寸未知,不下结论
	}
	return outW/videoW > WhenRatio && outH/videoH > WhenRatio, true
}

// EnsureFiles 把嵌入的 shader 落到 dir 下,返回文件名 → 绝对路径。
//
// ★ 内容是编译期常量,**长度一致即认为已是当前版本** —— 免得每次起播重写 520KB。
func EnsureFiles(dir string) (map[string]string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("建 shader 目录失败: %w", err)
	}
	ents, err := embedded.ReadDir("files")
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for _, e := range ents {
		name := e.Name()
		body, err := embedded.ReadFile("files/" + name)
		if err != nil {
			return nil, err
		}
		p := filepath.Join(dir, name)
		if st, err := os.Stat(p); err != nil || st.Size() != int64(len(body)) {
			if err := os.WriteFile(p, body, 0o644); err != nil {
				return nil, fmt.Errorf("写 %s 失败: %w", name, err)
			}
		}
		out[name] = p
	}
	return out, nil
}

// Paths 档位 → 可直接喂给 mpv glsl-shaders 的绝对路径列表。
// off / 未知 → 空列表(= 关)。
func Paths(dir, level string) ([]string, error) {
	p, ok := presets[level]
	if !ok {
		return []string{}, nil
	}
	files, err := EnsureFiles(dir)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(p.Files))
	for _, n := range p.Files {
		abs, ok := files[n]
		if !ok {
			return nil, fmt.Errorf("缺少 shader: %s", n)
		}
		out = append(out, abs)
	}
	return out, nil
}

// ParamsOf 一个 shader 文件声明了哪些 `//!PARAM`。测试用。
func ParamsOf(file string) []string {
	var out []string
	for _, l := range strings.Split(bodyOf(file), "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(l), "//!PARAM "); ok {
			out = append(out, strings.TrimSpace(v))
		}
	}
	return out
}
