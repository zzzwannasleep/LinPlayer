package player

// 播放器的**纯偏好类**命令:不碰 mpv 状态,只读写配置 + 算区间。
//
// 和 core/prefs 的分工:那边是设置页的通用偏好,这边是**播放器**行为
// (解码器、倍速、跳过片头、选轨正则、超分档位)。
// 分开是因为契约里就是分开的(`prefs.*` 与 `player.*`),不是随手划的。

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/emby"
	"linplayer/core/media"
	"linplayer/core/segments"
	"linplayer/core/paths"
	"linplayer/core/shaders"
)

var prefsClient *emby.Client

/* 这三个类型换掉的是三张裸 map。字段名是跨语言契约,而裸 map 里的键
   谁也对不了账 —— 拼错了核心层不报错、UI 取到 null,页面画成空。
   具名之后 check-android-fields.py 才查得到该发哪些字段。 */

// PlaybackPrefs 播放器默认行为(设置页那一屏的回显体)。
type PlaybackPrefs struct {
	Hwdec                   string            `json:"hwdec"`
	DefaultSpeed            float64           `json:"default_speed"`
	SkipIntro               bool              `json:"skip_intro"`
	SkipOutro               bool              `json:"skip_outro"`
	SkipAuto                bool              `json:"skip_auto"`
	SkipUseOnline           bool              `json:"skip_use_online"`
	PreviewThumbs           bool              `json:"preview_thumbs"`
	DolbyAutoSW             bool              `json:"dolby_auto_sw"`
	ExternalPlayer          string            `json:"external_player"`
	WatchedThresholdPercent int64             `json:"watched_threshold_percent"`
	Shortcuts               map[string]string `json:"shortcuts"`
}

// ShaderLevel 画面增强档位表里的一档。
type ShaderLevel struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Group    string `json:"group"`
	Selected bool   `json:"selected"`
	// WillRun 尺寸未知(没在播)时不发 —— 猜一个 false 会让抽屉里空一张表。
	WillRun *bool `json:"will_run,omitempty"`
}

// ShaderApplied 应用一档之后的回执。
//
// count>0 只证明 mpv 收下了路径,证明不了 shader 会跑 —— WillRun 才是那句话。
type ShaderApplied struct {
	Level string `json:"level"`
	Count int    `json:"count"`
	// Reverted 这档在本机跑不起来,已自动退回「关闭」。
	Reverted bool   `json:"reverted,omitempty"`
	WillRun  *bool  `json:"will_run,omitempty"`
	Note     string `json:"note,omitempty"`
}

/* 当前生效的画质档。进程里记一份是因为移动端的面板每次打开都是新建的,
   没有这个就回显不出「现在开着哪一档」,用户看到的是一张全都没选中的表。 */
var curShader atomic.Value

// currentShaderLevel 进程里没有就回落到**记住的那一档**(还没起播时就是这条路)。
func currentShaderLevel() string {
	v, _ := curShader.Load().(string)
	if v == "" {
		v = config.Current().PrefsOf().ShaderLevel
	}
	if v == "" {
		return "off"
	}
	return v
}

// rememberShader 用户**自己挑**的那一档:记进程,也落盘。
//
// ★ 2026-08-31 定过「档位故意不持久化」,理由是「档位跟这一片的分辨率和窗口大小绑定」。
//   那条已作废(用户 2026-09-12:「画面增强需要支持记忆」),而且 2026-09-07 重排之后
//   六档都带一个不挑尺寸的锐化 pass,原来的理由本身也不成立了。
// ★ 只有用户的选择走这里。起播时自动挂载失败而退回关闭的那一路**不能**走 ——
//   一次瞬时失败就把用户记住的档位抹了。
func rememberShader(level string) {
	curShader.Store(level)
	c := config.Current()
	p := c.PrefsOf()
	if p.ShaderLevel == level {
		return
	}
	p.ShaderLevel = level
	if err := c.SetPrefs(p); err == nil {
		err = c.Save()
	} else {
		bus.Logf("warn", "画面增强档位没记住: %v", err)
	}
}

// applySavedShader 起播时把记住的那一档挂回去。
//
// ★ 编译校验挪到 goroutine 里:那一步要**等真的渲染一帧**才等得到错误,
//   而这里还在起播路径上,同步等就是白白多出几百毫秒黑屏。
func applySavedShader(level string) {
	if level == "" || level == "off" {
		return
	}
	list, err := shaders.Paths(paths.ShaderSourceDir(), level)
	if err != nil || len(list) == 0 {
		return
	}
	if r := knownBadReason(level, list); r != "" {
		bus.Logf("warn", "记住的画面增强档位 %s 在这台机器上跑不起来,不挂:%s", level, r)
		curShader.Store("off")
		return
	}
	clearShaderErr()
	setProp("glsl-shader-opts", shaders.Opts(level))
	setProp("glsl-shaders", strings.Join(list, string(filepath.ListSeparator)))
	curShader.Store(level)
	go func() {
		if e := waitShaderCompileError(); e != "" {
			setProp("glsl-shader-opts", "")
			setProp("glsl-shaders", "")
			markShaderBad(level, list, e)
			curShader.Store("off")
			bus.Logf("error", "记住的画面增强档位 %s 跑不起来,已退回关闭:%s", level, e)
			return
		}
		markShaderOK(level, list)
	}()
}

// registerPrefsCommands 由 RegisterCommands 调用。
func registerPrefsCommands(version string) {
	prefsClient = emby.NewClient(version)
	registerSkip()

	/* shaderLevels 档位表。

	   ★★ 每一档都带 will_run —— 用户原话:「不生效的选项直接删掉,不要展示出来,
	     只保留生效的(目前很多选中了却不生效)」。
	     2026-09-07 重排档位之后,六档都带一个不挑尺寸的锐化 pass,所以这个字段
	     现在恒为 true;**它留着不是摆设** —— 它是「档位表里不许再出现纯放大档」
	     这条约束的运行期出口,哪天有人加了一档纯放大,UI 会自己把它藏掉。
	   ★ 判据和 setShaderLevel 用的是**同一个** shaders.WillRun + 同一份尺寸,
	     不另写一套 —— 两份判断迟早会说不一样的话。
	   ★ 尺寸未知(没在播)时**不给这个字段**,UI 那边就全都显示。
	     猜一个 false 会让「还没起播时打开抽屉」看到一张空表。 */
	bus.Register("player.shaderLevels", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		vw, vh := propF("video-params/w"), propF("video-params/h")
		ow, oh := propF("osd-dimensions/w"), propF("osd-dimensions/h")
		cur := currentShaderLevel()
		out := make([]ShaderLevel, 0, len(shaders.Levels()))
		for _, l := range shaders.Levels() {
			one := ShaderLevel{ID: l.ID, Name: l.Name, Group: l.Group, Selected: l.ID == cur}
			if run, ok := shaders.WillRun(l.ID, vw, vh, ow, oh); ok {
				one.WillRun = &run
			}
			out = append(out, one)
		}
		return out, nil
	})

	// setShaderLevel 应用一个画质档位。
	//
	// ★★ 返回体里**必须带 will_run**,不能只回一个「挂了几个 shader」的数字。
	//   `count>0` 只能证明 mpv **收下了**路径,**证明不了 shader 会跑** ——
	//   Anime4K 每个 pass 都带 `//!WHEN 输出>源*1.2`,窗口没比源大就整条链空转,
	//   画面一点没变,而旧版 UI 照样报「超分已生效 · 挂载 6 个 shader」。
	//   **那是在撒谎**,正是本项目最贵的那类 bug。
	bus.Register("player.setShaderLevel", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		level, _ := a["level"].(string)
		// .glsl 是编进二进制、首次用时落盘的 —— 丢了能重生成,所以归 cache/
		dir := paths.ShaderSourceDir()
		list, err := shaders.Paths(dir, level)
		if err != nil {
			return nil, bus.NewErr(bus.EInternal, "%v", err)
		}
		/* 强度是**档位设计的一部分**,每次挂载都得重设:glsl-shader-opts 是全局的,
		   不设就吃 shader 自带默认(CAS STR=0.5,只开一半)—— 用户实测「看不太出来」
		   正是这个。切到 off 时 opts 为空串,顺带把上一档的参数清掉。 */
		/* ★ 已经知道会坏的档位,**连试都不试** —— 不试就不会有那一帧纯色闪过去。
		   mpv 每个着色器程序一个进程里只报一次错(实测),所以「等错误冒出来」
		   这一招只挡得住第一档,后面共用同一个坏文件的全会漏过去。 */
		if r := knownBadReason(level, list); r != "" {
			rememberShader("off")
			return revertedResult(level, r), nil
		}

		clearShaderErr() // 先清,免得读到上一次的
		setProp("glsl-shader-opts", shaders.Opts(level))
		setProp("glsl-shaders", strings.Join(list, string(filepath.ListSeparator)))

		out := ShaderApplied{Level: level, Count: len(list)}
		if len(list) == 0 {
			rememberShader("off")
			return out, nil // off:关掉就完事,没有「会不会跑」这回事
		}

		/* ★★ 第三种「说了不算」:**shader 编译失败**。
		   前两种(收下路径 ≠ 会跑 / 尺寸不够)上面已经挡了,这一种更狠 ——
		   mpv 收下选项、返回 0、尺寸判断也过,但那一趟 pass 编译不过,
		   于是它继续渲染,输出**一片纯色**。没有任何返回码或属性会说这件事,
		   唯一的出口是 error 级日志(见 shaderguard.go)。
		   2026-09-02 真机:ak_sharp 整屏变蓝,根因是 AMD_CAS_luma_RT 调了
		   libplacebo 才有的 linearize()。

		   编译不过就**自己退回关闭** —— 宁可说「这档在你机器上用不了」,
		   也不能给用户一屏纯蓝还写「已启用」。 */
		if e := waitShaderCompileError(); e != "" {
			setProp("glsl-shader-opts", "")
			setProp("glsl-shaders", "")
			markShaderBad(level, list, e)
			rememberShader("off")
			bus.Logf("error", "着色器档位 %s 跑不起来,已退回关闭:%s", level, e)
			return revertedResult(level, e), nil
		}
		markShaderOK(level, list)
		rememberShader(level)
		vw, vh := propF("video-params/w"), propF("video-params/h")
		ow, oh := propF("osd-dimensions/w"), propF("osd-dimensions/h")
		/* 放大那半跑没跑**只进日志,不进界面**【用户定 2026-09-07:
		   「各种各样的莫名的提示……这个提示对这个选项没有用处」】。
		   它是「用户说开了不够清晰」时唯一能分清「档位没生效」和「屏幕就这么大」
		   的一行 —— 而屏幕就这么大不是故障,不该每次切档都念给他听。 */
		if up, ok := shaders.UpscaleWillRun(level, vw, vh, ow, oh); ok {
			bus.Logf("info", "档位 %s:放大那半%s(源 %.0f×%.0f → 画面区 %.0f×%.0f,"+
				"要 %.1f 倍以上才跑);锐化那半任何尺寸都跑",
				level, map[bool]string{true: "在跑", false: "没跑"}[up],
				vw, vh, ow, oh, shaders.WhenRatio)
		}
		if run, ok := shaders.WillRun(level, vw, vh, ow, oh); ok {
			out.WillRun = &run
			if !run {
				// ★ 说清楚**为什么**不生效,以及怎么办 —— 只回一个 false 等于让用户猜
				out.Note = fmt.Sprintf(
					"这档是**放大**滤镜,当前尺寸下不会生效:要求画面区大于源的 %.1f 倍才工作。"+
						"现在源 %.0f×%.0f、画面区只有 %.0f×%.0f(%.2f×)—— 你在缩小画面,没有可放大的。"+
						"全屏即可生效;想在窗口里就见效,请选「锐化」「去噪」那几族。",
					shaders.WhenRatio, vw, vh, ow, oh, ow/vw)
			}
		}
		// ok=false(尺寸未知 = 没在播)时**不给 will_run** —— 猜一个就是在撒谎
		return out, nil
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
		return PlaybackPrefs{
			Hwdec: p.Hwdec, DefaultSpeed: p.DefaultSpeed,
			SkipIntro: p.SkipIntro, SkipOutro: p.SkipOutro,
			SkipAuto: p.SkipAuto, SkipUseOnline: p.SkipUseOnline,
			PreviewThumbs: p.PreviewThumbs, DolbyAutoSW: p.DolbyAutoSW,
			ExternalPlayer:          p.ExternalPlayer,
			WatchedThresholdPercent: p.WatchedThresholdPercent,
			Shortcuts:               p.Shortcuts,
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
		if v, ok := s["skip_auto"].(bool); ok {
			p.SkipAuto = v
		}
		if v, ok := s["skip_use_online"].(bool); ok {
			p.SkipUseOnline = v
			// 关了再开(或者反过来)之后,上一轮的查询结果就不该再算数了
			segments.Clear()
		}
		// 键位表**整表替换**,不是逐条合并 —— 改键的界面每次送的就是完整的
		// 「改过的那几条」,合并的话用户把某一条改回默认之后它永远删不掉。
		if v, ok := s["shortcuts"].(map[string]any); ok {
			m := map[string]string{}
			for k, one := range v {
				if str, ok := one.(string); ok && str != "" {
					m[k] = str
				}
			}
			p.Shortcuts = m
		}
		if v, ok := s["preview_thumbs"].(bool); ok {
			p.PreviewThumbs = v
		}
		if v, ok := s["dolby_auto_sw"].(bool); ok {
			p.DolbyAutoSW = v
		}
		/* ★ 观看阈值。**拒而不是夹** —— 静默夹紧的话用户设 10% 看到的是
		   「已保存」,实际生效 50%。
		   ★ 下限 50 不是随手定的:再低就不是「看完」,看一半退出会被标已看完,
		     而那等于**把续播位置丢掉**(下次从头放)。 */
		if v, ok := s["watched_threshold_percent"].(float64); ok {
			n := int64(v)
			if n < config.WatchedMinPercent || n > 100 {
				return nil, bus.NewErr(bus.EInvalid,
					"观看阈值只支持 %d~100%%,实得 %d", config.WatchedMinPercent, n)
			}
			p.WatchedThresholdPercent = n
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
		// 服务端章节只是三层来源里的一层,手动设定和第三方库在 fillSkip 里补
		from := fillSkip(ctx, sess, id, runtime, info, pf)
		if !pf.SkipIntro {
			info.Intro = nil
		}
		if !pf.SkipOutro {
			info.Outro = nil
		}
		if info.Intro == nil && info.Outro == nil {
			from = ""
		}
		return map[string]any{
			"chapters": info.Chapters, "intro": info.Intro, "outro": info.Outro,
			// 数据出处。界面上要说得出「这一段是谁给的」——
			// 跳错了的时候用户第一个想知道的就是它
			"skip_source": from,
			// 自动跳还是弹按钮由核心层说了算,调用方不必再判一次开关
			"skip_auto": pf.SkipAuto,
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
	// server_id 压过 server/token:跨服起播 / 跨服上报时 UI 手上没有那台的 token,
	// 只报 id;拿着 A 的 token 打 B 的条目是 401 或者另一条片,而两边都不报错。
	if id := get("server_id"); id != "" {
		srv, tok, uid, dev, ok := config.Current().SessionOf(id)
		if !ok {
			return nil, bus.NewErr(bus.ENotFound, "没有这个服务器:"+id)
		}
		return &emby.Session{Server: srv, Token: tok, UserID: uid, DeviceID: dev}, nil
	}
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
