package player

// 播放器的**纯偏好类**命令:不碰 mpv 状态,只读写配置 + 算区间。
//
// 和 core/prefs 的分工:那边是设置页的通用偏好,这边是**播放器**行为
// (解码器、倍速、跳过片头、选轨正则、超分档位)。
// 分开是因为契约里就是分开的(`prefs.*` 与 `player.*`),不是随手划的。

import (
	"context"
	"os"
	"strings"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/emby"
	"linplayer/core/media"
)

// shaderLevel 一个超分/锐化档位。
type shaderLevel struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Group string `json:"group"`
}

// shaderLevels 全部档位。**顺序就是 UI 里的顺序**,别按字母排。
//
// ★ 「锐化/去噪(源分辨率就跑,窗口也生效)」与「放大(要输出 > 源 1.2 倍)」
// 是两件事。放大族在窗口模式下整条链空转,画面一点不变 —— 所以「锐化专精」
// 那一族放在最后但**它才是日常首选**,UI 分组标题里要写明「窗口也生效」。
//
// ★ 档位**不持久化**是故意的,别改。
var shaderLevels = []shaderLevel{
	{"off", "关闭", ""},
	// Anime4K:动漫特化(双边去噪 + CNN 超分)
	{"ak_denoise_l", "去噪 · 轻", "Anime4K"},
	{"ak_denoise_h", "去噪 · 强", "Anime4K"},
	{"ak_sharp", "锐化+去噪 · 推荐", "Anime4K"},
	{"ak_up_m", "放大 · CNN M", "Anime4K"},
	{"ak_up_dn", "放大+去噪 · CNN M", "Anime4K"},
	{"ak_up_vl", "放大去噪 · CNN VL · 壮机", "Anime4K"},
	{"ak_up_artcnn", "放大 · ArtCNN · 清晰轻量", "Anime4K"},
	{"ak_up_artcnn_sh", "放大+锐化 · ArtCNN · 最清晰", "Anime4K"},
	// AMD FSR:通用锐化 + FSR1 放大
	{"fsr_sharp_l", "锐化 · 轻", "FSR"},
	{"fsr_sharp_m", "锐化 · 推荐", "FSR"},
	{"fsr_sharp_h", "锐化 · 强", "FSR"},
	{"fsr_up", "放大+锐化 · FSR1", "FSR"},
	{"fsr_up_h", "放大+锐化 · 强", "FSR"},
	{"fsr_up_dn", "放大+锐化+去噪", "FSR"},
	// NVIDIA Image Scaling
	{"nv_sharp_l", "锐化 · 轻", "NVIDIA"},
	{"nv_sharp_m", "锐化 · 推荐", "NVIDIA"},
	{"nv_sharp_h", "锐化 · 强", "NVIDIA"},
	{"nv_up", "放大 · NIS", "NVIDIA"},
	{"nv_up_h", "放大+锐化 · NIS", "NVIDIA"},
	{"nv_up_dn", "放大+锐化+去噪 · NIS", "NVIDIA"},
	// 锐化专精:窗口/全屏都生效,开销最低
	{"sh_ada_l", "自适应锐化 · 轻", "Sharpen"},
	{"sh_ada_m", "自适应锐化 · 推荐", "Sharpen"},
	{"sh_ada_h", "自适应锐化 · 强", "Sharpen"},
	{"sh_fine_m", "精细锐化 · 推荐", "Sharpen"},
	{"sh_fine_h", "精细锐化 · 强", "Sharpen"},
	{"sh_warp", "线条锐化 · 动漫线稿", "Sharpen"},
	{"sh_bcas", "双边锐化 BCAS · 强", "Sharpen"},
}

var prefsClient *emby.Client

// registerPrefsCommands 由 RegisterCommands 调用。
func registerPrefsCommands(version string) {
	prefsClient = emby.NewClient(version)

	bus.Register("player.shaderLevels", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		return shaderLevels, nil
	})

	// validateTrackRegex 设置页的即时校验。
	//
	// ★ **必须用核心层这套正则引擎校验,不能用前端的 JS RegExp** ——
	//   两套语法集不同,JS 放行而这边编译不过的表达式会**静默失效**:
	//   用户在设置页看到「合法」,实际一条都匹配不上。
	bus.Register("player.validateTrackRegex", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		p, _ := a["pattern"].(string)
		if err := media.ValidateTrackRegex(p); err != nil {
			return nil, bus.NewErr(bus.EInvalid, "正则不合法: %v", err)
		}
		return map[string]any{"ok": true}, nil
	})

	// setTrackRegexes 三条正则一起设。
	// ★ 同 prefs.setPrefs:**只改这三项,别整体覆盖**。
	bus.Register("player.setTrackRegexes", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		ver, _ := a["version_regex"].(string)
		sub, _ := a["sub_regex"].(string)
		aud, _ := a["audio_regex"].(string)
		// ★ 三条**都要先校验完再落盘** —— 边校验边写的话,第三条不合法时
		//   前两条已经存进去了,用户看到报错却发现设置被改了一半。
		for _, p := range []string{ver, sub, aud} {
			if err := media.ValidateTrackRegex(p); err != nil {
				return nil, bus.NewErr(bus.EInvalid, "正则不合法(%s): %v", p, err)
			}
		}
		c := config.Current()
		pf := c.PrefsOf()
		pf.VersionRegex, pf.SubRegex, pf.AudioRegex = ver, sub, aud
		return pf, savePrefs(c, pf)
	})

	// ---- 播放器默认行为 ----
	bus.Register("player.getPlaybackPrefs", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		p := config.Current().PrefsOf()
		return map[string]any{
			"hwdec": p.Hwdec, "default_speed": p.DefaultSpeed,
			"skip_intro": p.SkipIntro, "skip_outro": p.SkipOutro,
			"preview_thumbs": p.PreviewThumbs, "dolby_auto_sw": p.DolbyAutoSW,
			"external_player": p.ExternalPlayer,
		}, nil
	})
	bus.Register("player.setPlaybackPrefs", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		s := settingsOf(a)
		c := config.Current()
		p := c.PrefsOf()

		// ★ 拒而不是夹:静默夹紧 = 用户以为设上了(同 prefs.setPrefetchSettings 的理由)
		if v, ok := s["hwdec"].(string); ok {
			if v != "auto-safe" && v != "no" {
				return nil, bus.NewErr(bus.EInvalid, "未知的解码方式: %s", v)
			}
			p.Hwdec = v
		}
		if v, ok := s["default_speed"].(float64); ok {
			if v < config.SpeedMin || v > config.SpeedMax {
				return nil, bus.NewErr(bus.EInvalid, "默认倍速只支持 %.2f~%.2f×,实得 %v",
					config.SpeedMin, config.SpeedMax, v)
			}
			p.DefaultSpeed = v
		}
		// ★ 外部播放器:**给了路径就必须真的存在**。存一个打不开的路径,
		//   等到起播时才炸,那时用户早忘了自己填过什么。
		if v, ok := s["external_player"].(string); ok {
			ext := strings.TrimSpace(v)
			if ext != "" {
				st, err := os.Stat(ext)
				if err != nil || st.IsDir() {
					return nil, bus.NewErr(bus.EInvalid, "找不到外部播放器: %s", ext)
				}
			}
			p.ExternalPlayer = ext
		}
		// ★ 片头片尾是**两个**开关,别用一个字段喂两行
		if v, ok := s["skip_intro"].(bool); ok {
			p.SkipIntro = v
		}
		if v, ok := s["skip_outro"].(bool); ok {
			p.SkipOutro = v
		}
		if v, ok := s["preview_thumbs"].(bool); ok {
			p.PreviewThumbs = v
		}
		if v, ok := s["dolby_auto_sw"].(bool); ok {
			p.DolbyAutoSW = v
		}
		return p, savePrefs(c, p)
	})

	// chapterInfo 章节 + 片头片尾区间。**一次请求同时喂两个功能**。
	bus.Register("player.chapterInfo", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		id, _ := a["item_id"].(string)
		if id == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 item_id")
		}
		sess, err := sessionFrom(a)
		if err != nil {
			return nil, err
		}
		runtime, _ := a["runtime_secs"].(float64)
		w := 320
		if v, ok := a["thumb_width"].(float64); ok && v > 0 {
			w = int(v)
		}
		// ★ 不报错:没刮削章节的库返回空表,两个功能都自动静默不工作 ——
		//   那是**正常情况**,不该让播放页弹红字。
		info := prefsClient.ChapterInfoOf(ctx, sess, id, runtime, w)
		/* ★★ 用户关了开关时这里就该恒为 null —— **调用方不必再判一次开关**。
		   判两次早晚判岔:一边按核心层给的区间跳、一边按自己那份开关决定要不要跳,
		   两处状态一不同步就是「关了还在跳」或者「开了不跳」。 */
		pf := config.Current().PrefsOf()
		if !pf.SkipIntro {
			info.Intro = nil
		}
		if !pf.SkipOutro {
			info.Outro = nil
		}
		return map[string]any{
			"chapters": info.Chapters, "intro": info.Intro, "outro": info.Outro,
			// 缩略图开关(关着时调用方别去加载章节图,白费流量)
			"thumbs": pf.PreviewThumbs,
		}, nil
	})
}

func savePrefs(c *config.AppConfig, p config.Prefs) error {
	if err := c.SetPrefs(p); err != nil {
		return bus.NewErr(bus.EInternal, "偏好序列化失败: %v", err)
	}
	if err := c.Save(); err != nil {
		return bus.NewErr(bus.EInternal, "配置保存失败: %v", err)
	}
	return nil
}

// settingsOf 嵌套与摊平两种传法都收。
func settingsOf(a map[string]any) map[string]any {
	if m, ok := a["settings"].(map[string]any); ok {
		return m
	}
	return a
}

// sessionFrom 从命令参数取会话;没传就用当前活跃账号。
//
// ponytail: 迁移期两种都收。等三端绑定统一之后只留后者。
func sessionFrom(a map[string]any) (*emby.Session, error) {
	get := func(k string) string { v, _ := a[k].(string); return v }
	if get("server") != "" && get("user_id") != "" {
		return &emby.Session{
			Server: get("server"), Token: get("token"),
			UserID: get("user_id"), DeviceID: get("device_id"),
		}, nil
	}
	c := config.Current()
	acc := c.ActiveAccount()
	if acc == nil || acc.IsFileBrowse() {
		return nil, bus.NewErr(bus.EAuth, "没有活跃的 Emby 账号")
	}
	return &emby.Session{
		Server: acc.ActiveLineURL(), Token: acc.Token,
		UserID: acc.UserID, DeviceID: c.DeviceID,
	}, nil
}
