package config

//
// 播放与全局偏好。
// ★★ **这个文件最大的坑是「默认值不是零值」。**
//
// Rust 那边一半字段带 `#[serde(default = "…")]`,缺字段时拿到的是 true / 1.0 /
// "auto-safe" / 512MB。Go 的 encoding/json 缺字段时**一律零值** ——
// 直接 `json.Unmarshal(b, &Prefs{})` 会把 sub_enabled / preview_thumbs /
// dolby_auto_sw / preload_enabled / update_auto_check 全部变成 false,
// hwdec 变成空串,倍速变成 0。
//
// 表现:老用户升级之后**字幕默认不开了、倍速是 0 放不出来、进度条预览没了**,
// 而且配置文件看上去一点问题都没有。
//
// 所以本文件的硬规矩:**解析一律从 DefaultPrefs() 起手,往上面盖**,
// 绝不 unmarshal 进一个零值结构体。

import (
	"encoding/json"
	"strings"
)

// 合法区间。**设置页与命令层共用** —— 别各写各的(Rust 侧的 prefetch_cache 就吃过这个亏:
// 设置页拿到 1GB、一保存就被核层按 16~32MB 拒掉,用户连「打开某台服务器」都点不动)。
const (
	SpeedMin = 0.25
	SpeedMax = 4.0

	// PrefetchCacheMin/Max 预取缓存上限的合法区间(字节)。
	//
	// ★ 2026-07-19 从 16~32MB 放开到 64MB~4GB:分段以前全在**内存**里,峰值还要乘
	// 活跃连接数,所以只敢给 32MB;现在是落盘环形缓存,内存只留传输中的那几段,
	// 这个值变成**磁盘占用上限**,GB 级才有意义。
	PrefetchCacheMin int64 = 64 * 1024 * 1024
	PrefetchCacheMax int64 = 4 * 1024 * 1024 * 1024

	// PreloadHeadMBMax 预热头部量上限(MB)。0 = 只热尾部索引;
	// 上限 512,再大就不是「预热」是「下载」了。
	PreloadHeadMBMax int64 = 512

	// WatchedMinPercent 观看阈值的下限。低于它就不是「看完」了 ——
	// 看一半退出会被标成已看完,而那意味着续播位置直接丢掉。
	WatchedMinPercent int64 = 50

	// 字幕样式的合法区间。**和 mpv 认的一致** —— 超出去 mpv 只会静默拒绝,
	// 表现是「拖到头就不动了」而没有任何提示。
	SubScaleMin = 0.2
	SubScaleMax = 4.0
	// SubPosMax 150 而不是 100:>100 是把字幕压到画面下面那条黑边上,
	// 宽银幕片子上这是最常用的一档(字不再挡画面)。
	SubPosMax    = 150
	SubBorderMax = 10.0

	// 弹幕显示的合法区间(用户 2026-09-09 点名的九项)。
	// ★ 缩放 / 透明度 / 速度三项**下限不是 0**:0 分别是「看不见」「全透明」
	//   「原地不动」,那三种状态用「关掉弹幕」表达就够了,不该占一档。
	DanmakuScaleMin   = 0.1
	DanmakuScaleMax   = 3.0
	DanmakuSpeedMin   = 0.1
	DanmakuSpeedMax   = 3.0
	DanmakuLinesMax   = 20
	// DanmakuAreaMin 滚动弹幕最少占四分之一屏。
	DanmakuAreaMin = 0.25
)

// Prefs 播放与全局偏好。
type Prefs struct {
	// ---- 选轨 ----
	AudioLang  *string `json:"audio_lang"`
	SubLang    *string `json:"sub_lang"`
	SubEnabled bool    `json:"sub_enabled"` // 默认 true

	// DanmakuEnabled 弹幕开关。**默认 false** —— 弹幕要先匹配上才有内容,
	// 默认开着的表现是每起播一次就往上游打一轮匹配请求,而九成片子匹配不上。
	DanmakuEnabled bool `json:"danmaku_enabled"`

	/* ---- 弹幕显示(播放页「弹幕」面板,用户 2026-09-09 点名的九项)----

	   ☠ 和字幕样式同理:这几项决定的是**每一帧怎么画**,而渲染器在核心层
	   (core/player/danmaku.go 每拍重算 \pos)。放在 UI 侧的话 PC 和安卓
	   各存一份,同一个账号在两端看到的弹幕长得不一样。 */

	// DanmakuArea 滚动弹幕占画面高度的比例:0.25 / 0.5 / 1.0。
	// 只有滚动层受它管 —— 置顶置底本来就贴着边,再限高等于把它们挤没。
	DanmakuArea float64 `json:"danmaku_area"`

	// DanmakuScale 弹幕字号倍率。**行高跟着一起缩** ——
	// 只缩字号的话字变小了行距没变,屏幕上会出现一条条空带。
	DanmakuScale float64 `json:"danmaku_scale"`

	// DanmakuOpacity 不透明度 0..1(1 = 全不透明)。
	DanmakuOpacity float64 `json:"danmaku_opacity"`

	// DanmakuSpeed 滚动速度倍率。1 = 一条弹幕横穿画面用 8 秒。
	DanmakuSpeed float64 `json:"danmaku_speed"`

	// DanmakuTopLines / DanmakuBottomLines 置顶 / 置底弹幕最多占几行。
	// **0 是合法值**(= 这一类不显示),所以 Clamped 不能把 0 当没设。
	DanmakuTopLines    int `json:"danmaku_top_lines"`
	DanmakuBottomLines int `json:"danmaku_bottom_lines"`

	// DanmakuMerge 合并重复弹幕(同文本同类型),合并后带 ×N。
	DanmakuMerge bool `json:"danmaku_merge"`

	DanmakuBold bool `json:"danmaku_bold"`

	// DanmakuHeatmap 进度条上画弹幕密度热力图。
	DanmakuHeatmap bool `json:"danmaku_heatmap"`

	// DanmakuBlockwords / DanmakuBlockUsers 屏蔽词与屏蔽用户。
	// ★ 落在这里而不是让每个调用点自己传:漏传的那条路径**不报错**,
	//   只是屏蔽词没生效 —— 而用户会以为是词写错了。见 core/danmaku 的 filterOptionsOf。
	DanmakuBlockwords []string `json:"danmaku_blockwords"`
	DanmakuBlockUsers []string `json:"danmaku_block_users"`

	// 正则优先选择。空 = 不启用,回退到上面的语言偏好。
	// 优先级:手动选过的 ＞ 正则命中 ＞ 语言/服务端默认。
	//
	// ★ 校验必须走 core/media 的正则编译(Go regexp),**不能**用前端的 JS RegExp:
	// 两套语法集不同(都不支持前后瞻,但边界情况仍有出入),
	// JS 放行而这边编译不过的表达式会**静默失效**。
	VersionRegex string `json:"version_regex"`
	SubRegex     string `json:"sub_regex"`
	AudioRegex   string `json:"audio_regex"`

	// ---- 跨服续播 / 回传 ----
	// 跨服务器续播:在别的服务器看过同一部片时,用本地记录里的最大进度起播。
	// ★ 默认关 —— 它会让「这台服上没看过的片」也从中间起播,得用户明确要才开。
	CrossServerResume bool `json:"cross_server_resume"`
	// 跨服回传主开关:看完/进度写回**其它**服务器。
	// ★ 默认关 —— 它会往别人的服务器写数据,必须用户主动开。
	CrossServerWriteback bool `json:"cross_server_writeback"`
	// 回传范围:"all" 所有看过的服 / "first" 仅初次 / "latest" 仅最近。
	// 存 wire 字符串而非枚举:免得 config 反过来依赖观看记录模块。
	CrossServerWritebackRange string `json:"cross_server_writeback_range"` // 默认 "all"
	// 回传时是否连播放进度一起同步(关掉则只同步「已看完」标记)。默认 true。
	CrossServerWritebackProgress bool `json:"cross_server_writeback_progress"`

	// ---- 多线程加载(本地预取代理)----
	// 开在**哪些服务器**上。存 Account.server(归一化身份键),空表 = 全部关闭。
	//
	// ★ 为什么是「按服务器」而不是一个全局开关:它是**优化**不是功能 ——
	// 能不能加速取决于对端(远程 Emby 有收益;局域网/NAS 本就跑满,
	// 多开几条 Range 只是白白多占连接)。所以只能由用户按服务器主动开,不给全开的入口。
	// ★ 粒度是**服务器不是线路**:一台服的多条线路是同一个源的不同入口。
	// ★ 默认关:它仍是拿风险换速度(2026-07-15 实测开着会放不出来,根因已修,
	//   但「修好了」不等于「该默认开」)。
	PrefetchServers []string `json:"prefetch_servers"`
	// 预取并发线程数。引擎内部 clamp(2,4),这里存原值。默认 3。
	PrefetchThreads int `json:"prefetch_threads"`
	// 读前缓冲上限(字节)。默认 512MB。
	//
	// ★ 旧配置里存的是 1GB(那时它被误当成下限用)。引擎会把超限值钳回,
	// 但**读出来给设置页时也要钳** —— 否则设置页拿到超限值、一保存就被核层拒。
	PrefetchCacheBytes int64 `json:"prefetch_cache_bytes"`

	// ---- 预加载(详情页预热)----
	// 和上面的多线程加载**不是一回事**:那个是播放中在本地起代理喂 mpv,
	// 这个是播放**前**把路跑通(头/尾两段跑热,读完即丢)。
	//
	// ★ 默认开:只花一次几十 MB 的流量,换掉起播时那几百毫秒的冷握手 + 冷 seek,
	// 而且不改播放地址、不落盘,没有 prefetch 那种「开了放不出来」的风险面。
	PreloadEnabled bool `json:"preload_enabled"`
	// 头部预热量(MB)。0 = 只热尾部索引。默认 32。
	// ★ 别随手改小:太小盖不住起播后头几秒的解码,预热就白做了。
	PreloadHeadMB int64 `json:"preload_head_mb"`

	// ---- 播放器默认行为 ----
	// 这几项归 Prefs 而不是按服务器:它们是**播放器**行为(解码器、倍速、外部程序),
	// 跟对端服务器无关 —— 与 prefetch_servers 那种「取决于对端」的优化不是一回事。

	// 默认解码方式:"auto-safe" 硬解(默认) / "no" 软解。
	// ★ 值**直接喂 mpv 的 hwdec**,别在这里存 "hw"/"sw" 再到处翻译。
	Hwdec string `json:"hwdec"`
	// 默认倍速。起播时应用一次,播放中用户再调**不回写**这里(那是临时调整)。
	DefaultSpeed float64 `json:"default_speed"`
	// ShaderLevel 画面增强档位,起播时自动挂回来。"" / "off" = 关。
	//
	// ★ 2026-08-31 那条「档位故意不持久化」的口径**已作废**
	//   (用户 2026-09-12:「画面增强需要支持记忆」)。当时的理由是「档位跟这一片的
	//   分辨率和窗口大小绑定」,而 2026-09-07 重排之后六档都带一个不挑尺寸的锐化 pass,
	//   那个理由本身也不成立了。挂不上的那一档核心层会自己退回关闭并明说。
	ShaderLevel string `json:"shader_level"`
	// 自动跳过片头 / 片尾。依赖**服务端章节**,没刮削章节的库自动静默不工作。
	//
	// ★ 片头片尾是**两个**开关:播放页「更多」面板里就是两行,
	// 一个字段喂两行会出现「点片头把片尾也翻了」。设置页也照这个粒度给两行。
	SkipIntro bool `json:"skip_intro"`
	SkipOutro bool `json:"skip_outro"`
	// SkipAuto 到了片头片尾**直接跳过去**,不等用户点那个按钮。
	//
	// ★ 和上面两个分开:上面两个决定「认不认这一段」,这个决定「要不要替用户按」。
	//   合成一个开关的话,想要按钮不想自动跳的人只能连按钮一起关掉。
	SkipAuto bool `json:"skip_auto"`
	// SkipUseOnline 服务端没刮章节时,允许联网去第三方片头片尾库查一次。
	//
	// ★ 单独一个开关而不是跟着 SkipIntro 走:那两个决定「跳不跳」,
	//   这个决定「要不要为此发一次外网请求」—— 后者是隐私口径,不该被前者顺带打开。
	SkipUseOnline bool `json:"skip_use_online"`
	// SkipOverrides 用户手动设定的片头片尾。键 = 服务器|剧 id(电影则是影片 id)。
	//
	// ★ 按**剧**存不按集存:一部剧的片头片尾在每一集上是同一段,
	//   按集存的话用户得为每一集设一遍,而那不是他要的。
	SkipOverrides map[string]SkipRange `json:"skip_overrides"`
	// 进度条悬停缩略图。数据来自服务端章节图,没有则退回纯时间气泡。默认 true。
	PreviewThumbs bool `json:"preview_thumbs"`
	// 杜比视界自动软解:识别到 DV 时强制 hwdec=no。默认 true ——
	// DV 走硬解在多数 Windows 显卡上出色偏移(发绿/发紫),软解画面才是对的。
	DolbyAutoSW bool `json:"dolby_auto_sw"`
	// 外部播放器可执行文件路径。非空 = 起播时交给它,不走内置 mpv。
	ExternalPlayer string `json:"external_player"`
	// 截图保存目录。nil = 系统图片文件夹下的 LinPlayer/。
	//
	// ★ 截图是**用户要拿去用的产物**,不是程序残留 —— 所以默认落系统图片文件夹(好找),
	// 而不是跟着下载一起塞进 userdata/(那儿翻起来费劲)。
	ScreenshotDir *string `json:"screenshot_dir"`

	// ---- 快捷键 ----
	// Shortcuts 用户改过的键位:动作 id → 键谱(如 "Ctrl+H"、"空格 或 鼠标左键")。
	//
	// ★ 只存**改过的**那几条,没改的不入表 —— 全量存下来的话,以后调整默认键位
	//   对所有老用户都不生效,而他们根本没动过那一条。
	// 键谱的文法与合法性由外壳定义,核心层只做透传:这是纯 UI 概念,
	// 核心层认识它反而会出现两套解释。
	Shortcuts map[string]string `json:"shortcuts"`

	// ---- 首页合集栏 ----
	// HideCollectionServers 哪几台服务器**不显示**首页的合集栏。
	// 存 Account.server(归一化身份键),空表 = 全部显示。
	//
	// ★★ 存的是**黑名单**而不是白名单。白名单的话新加的服务器默认不显示,
	// 而用户完全不知道有这个开关 —— 他只会看到「这台服没有合集」。
	// 默认开、想关才记一笔,是这类「隐藏某个栏目」开关唯一安全的存法。
	//
	// ★ 开着也不保证看得到:服务器上**没有**合集时那一栏整条不画
	// (用户 2026-09-03:「如果该 Emby 没有 那么就不显示」)。
	HideCollectionServers []string `json:"hide_collection_servers"`

	// ---- 更新 ----
	// 更新渠道。默认 "stable" —— 不能让普通用户默认吃到每次推 main 的构建。
	UpdateChannel string `json:"update_channel"`
	// UpdateProxy GitHub 代理基址,空 = 直连【用户定 2026-09-12】。
	//
	// ★ 用法是「代理基址 + / + 原始完整 URL」,查版本和下载包**两条都要走** ——
	//   只代理下载的话,墙内用户连「有没有新版」都问不出来。
	// ★ 存的是自由文本不是枚举:用户点名要「支持用户自定义」,
	//   而这类公共代理今天能用明天就 404,写死几个等于把用户锁死在坏掉的那几个上。
	UpdateProxy string `json:"update_proxy"`

	// IconSourcesExtra 用户自己加的图标源,和编译期注入的那几条**并存**
	// 【用户定 2026-09-12:「然后允许用户自己添加网络源」】。
	//
	// ★ 只存用户加的那几条。把内置的也存进来的话,编译期换了源,
	//   老用户盘上那份旧地址会一直盖着它 —— 而且没人会想起来去清。
	IconSourcesExtra []string `json:"icon_sources_extra"`
	// 启动时自动检查更新。**默认关**,用户到设置里勾上才会自动查
	// (用户 2026-09-12:「自动检查更新默认关,需用户打开自动更新再自动检查更新」)。
	//
	// ☠ JSON 键换过名(原来是 `update_auto_check`)。换名是**故意**的:
	// 这个开关从落库到 2026-09-11 之前一个消费者都没有,老配置里那个 true
	// 不是任何人的选择,只是当年的默认值被整体落了盘。沿用旧键的话,
	// 改默认值对所有存过设置的人一点用都没有 —— 他们的盘上写着 true。
	// 旧键会留在配置文件里没人读,那是死数据,不影响任何东西。
	UpdateAutoCheck bool `json:"update_auto_check_optin"`

	// ---- 窗口(只有 PC 壳用)----
	// 关掉时的窗口尺寸与最大化状态。**0 表示还没记过**,那时按 XAML 的默认值开。
	//
	// ★ 这三项是本文件里少数「零值就是正确默认值」的字段 —— 别照着文件头那条
	//   「默认值不是零值」给它们编一个 1280×800 的默认:编了的话用户拉小窗口、
	//   关掉、再打开,拿到的还是 1280×800,而他正是为这件事来提需求的。
	WindowW   int  `json:"window_w"`
	WindowH   int  `json:"window_h"`
	WindowMax bool `json:"window_max"`

	// WatchedThresholdPercent 看到百分之多少算「已观看」。默认 90。
	//
	// ★★ 它同时是**续播的上界**:进度越过这条线之后再点播放,
	// 从头开始而不是接着片尾放(用户 2026-09-03:「以后再看这集
	// 就直接从头开始播放即可」)。两件事用**同一个**阈值 ——
	// 分两个的话会出现「标了已看完却仍从 97% 续播」这种自相矛盾的状态。
	//
	// ★ 下限 50:再小就不是「看完」了，看一半退出会被当成看完，
	// 而那意味着**续播位置直接丢掉**。
	WatchedThresholdPercent int64 `json:"watched_threshold_percent"`

	// UiFont 界面字体文件的绝对路径(用户自己导入的 .ttf/.otf)。空 = 用系统默认字体。
	//
	// ★ 存**路径**不是字体名:用户导入的字体多半没装进系统,按名字找不到它。
	// ★ 它是**这台机器**的东西(路径在别的机器上不存在),但配置本来就是每份安装
	//   各一份、不跨设备同步 —— 所以放这里不会串。
	UiFont string `json:"ui_font"`

	/* ---- 字幕样式(播放页「字幕」面板,用户 2026-09-08 点名的五项)----

	   ☠ **必须存在核心层。** 这几项是 mpv 的运行时属性,而 mpv 每次冷启动
	   都是新的 —— 不落库的表现是「调好了,关掉软件再打开又回默认」,
	   用户会当成没生效。 */

	// SubScale 字幕大小。**这才是那颗旋钮**,不是 sub-font-size ——
	// ASS 字幕在 mpv 默认的 sub-ass-override=scale 下完全忽略 sub-font-size
	// (实测记在 core/player/subtitle.go 的 setSubScale 上面)。0 = 用 mpv 默认。
	SubScale float64 `json:"sub_scale"`

	// SubPos 字幕竖直位置 0(顶)..150(底,>100 是压到画面外的黑边上)。
	// -1 = 不动 mpv 的默认值(100)。
	SubPos int `json:"sub_pos"`

	// SubBorderSize 描边粗细(像素)。-1 = 不动。
	// ★ 不给颜色开关:描边的用处是「压在雪地上和压在夜景上一样清楚」,
	//   而能同时做到这两件事的只有黑边。给颜色等于给用户一个把它调坏的机会。
	SubBorderSize float64 `json:"sub_border_size"`

	// SubBold 粗体。
	SubBold bool `json:"sub_bold"`

	// SubScaleByWindow 字幕缩放:字号跟着**窗口**走(true,mpv 默认)还是跟着
	// **片源分辨率**走(false)。这两者在全屏时一样,窗口化时差得很远 ——
	// 关掉它,字幕在小窗里就不会大得盖住半个画面。
	// nil = 不动 mpv 的默认值。
	SubScaleByWindow *bool `json:"sub_scale_by_window"`

	// 详情页背景图的模糊强度,0~100。默认 40。
	// 归 Prefs 是因为它是**观感偏好**不是主题 —— 换主题不该把它重置。
	DetailBlur int `json:"detail_blur"`

	// rest 这份偏好里我们还没接的键,原样透传。
	rest map[string]json.RawMessage
}

// DefaultPrefs 全新安装的默认偏好。
//
// ★ **解析必须从这里起手。** 见文件头:Go 的缺字段是零值,不是 Rust 的 serde default。
// SkipRange 手动设定的片头片尾区间(秒)。某一段的两个值都是 0 表示这一段没设。
type SkipRange struct {
	IntroStart float64 `json:"intro_start"`
	IntroEnd   float64 `json:"intro_end"`
	OutroStart float64 `json:"outro_start"`
	OutroEnd   float64 `json:"outro_end"`
}

func DefaultPrefs() Prefs {
	return Prefs{
		SubEnabled:                   true,
		DanmakuEnabled:               false,
		DanmakuArea:                  1.0,
		DanmakuScale:                 1.0,
		DanmakuOpacity:               1.0,
		DanmakuSpeed:                 1.0,
		DanmakuTopLines:              10,
		DanmakuBottomLines:           10,
		DanmakuBlockwords:            []string{},
		DanmakuBlockUsers:            []string{},
		CrossServerWritebackRange:    "all",
		CrossServerWritebackProgress: true,
		PrefetchThreads:              3,
		PrefetchCacheBytes:           512 * 1024 * 1024,
		PreloadEnabled:               true,
		PreloadHeadMB:                32,
		Hwdec:                        "auto-safe",
		DefaultSpeed:                 1.0,
		PreviewThumbs:                true,
		SkipUseOnline:                true,
		DolbyAutoSW:                  true,
		UpdateChannel:                "stable",
		// 这里**不写** UpdateAutoCheck —— 零值 false 就是要的默认值(默认不自动查)
		DetailBlur:                   40,
		// ★ 三个哨兵都是「不动 mpv 的默认值」,不是 0 —— 0 在这三项上分别是
		//   「字幕缩到看不见」「字幕顶到画面最上沿」「一点描边都没有」。
		SubPos:                  -1,
		SubBorderSize:           -1,
		WatchedThresholdPercent: 90,
		PrefetchServers:         []string{},
		HideCollectionServers:   []string{},
		rest:                    map[string]json.RawMessage{},
	}
}

var prefsTypedKeys = func() map[string]bool {
	m := map[string]bool{}
	b, _ := json.Marshal(Prefs{})
	var raw map[string]json.RawMessage
	_ = json.Unmarshal(b, &raw)
	for k := range raw {
		m[k] = true
	}
	return m
}()

// ParsePrefs 从配置里的 prefs 段解出偏好。
//
// ★ **从默认值起手往上盖**,不是 unmarshal 进零值 —— 那会把一半开关静默关掉。
// 解不动时返回默认值:偏好坏了不该让整个应用起不来(和账号不同,偏好丢了是可恢复的)。
func ParsePrefs(raw json.RawMessage) Prefs {
	p := DefaultPrefs()
	if len(raw) == 0 {
		return p
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		return DefaultPrefs()
	}
	var all map[string]json.RawMessage
	if json.Unmarshal(raw, &all) == nil {
		p.rest = map[string]json.RawMessage{}
		for k, v := range all {
			if !prefsTypedKeys[k] {
				p.rest[k] = v
			}
		}
	}
	return p.Clamped()
}

// MarshalJSON 把强类型字段和没接的键合回一个对象。
func (p Prefs) MarshalJSON() ([]byte, error) {
	type plain Prefs
	b, err := json.Marshal(plain(p))
	if err != nil {
		return nil, err
	}
	out := map[string]json.RawMessage{}
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, err
	}
	for k, v := range p.rest {
		if _, taken := out[k]; !taken {
			out[k] = v
		}
	}
	return json.Marshal(out)
}

// Clamped 把越界值钳回合法区间。
//
// ★ **读出来给设置页时也要钳**,不只是保存时钳 —— 否则设置页拿到一个越界值,
// 用户什么都没改点一下保存就被核层拒,而他根本不知道哪儿不对。
func (p Prefs) Clamped() Prefs {
	if p.DefaultSpeed < SpeedMin || p.DefaultSpeed > SpeedMax {
		p.DefaultSpeed = 1.0
	}
	if p.PrefetchThreads < 2 {
		p.PrefetchThreads = 2
	}
	if p.PrefetchThreads > 4 {
		p.PrefetchThreads = 4
	}
	if p.PrefetchCacheBytes < PrefetchCacheMin {
		p.PrefetchCacheBytes = PrefetchCacheMin
	}
	if p.PrefetchCacheBytes > PrefetchCacheMax {
		p.PrefetchCacheBytes = PrefetchCacheMax
	}
	if p.PreloadHeadMB < 0 {
		p.PreloadHeadMB = 0
	}
	if p.PreloadHeadMB > PreloadHeadMBMax {
		p.PreloadHeadMB = PreloadHeadMBMax
	}
	if p.DetailBlur < 0 {
		p.DetailBlur = 0
	}
	if p.DetailBlur > 100 {
		p.DetailBlur = 100
	}
	switch strings.ToLower(strings.TrimSpace(p.CrossServerWritebackRange)) {
	case "all", "first", "latest":
	default:
		p.CrossServerWritebackRange = "all"
	}
	// hwdec 直接喂 mpv:空串会让 mpv 用它自己的默认(软解),
	// 用户看到的是「我没关硬解啊怎么这么卡」。空了就回默认值。
	if strings.TrimSpace(p.Hwdec) == "" {
		p.Hwdec = "auto-safe"
	}
	if p.UpdateChannel != "stable" && p.UpdateChannel != "prerelease" {
		p.UpdateChannel = "stable"
	}
	if p.PrefetchServers == nil {
		p.PrefetchServers = []string{} // 空切片不是 nil:前端 .map() 拿到 null 会抛错
	}
	if p.HideCollectionServers == nil {
		p.HideCollectionServers = []string{}
	}
	/* ★ 观看阈值。老配置里**没有这个键**,解出来是 0 ——
	   而 0 的含义是「放第一帧就算看完」:每一集刚起播就被标已看完,
	   续播位置全部作废。所以 0 必须回默认值,不能当成用户的选择。 */
	if p.WatchedThresholdPercent < WatchedMinPercent || p.WatchedThresholdPercent > 100 {
		p.WatchedThresholdPercent = 90
	}
	/* 字幕样式:**越界一律回哨兵**,不夹到边界。
	   夹的话老配置里那个不存在的键解出 0,会被当成用户选的「0 号字幕大小」——
	   那是一屏看不见的字幕,而用户什么都没设过。 */
	if p.SubScale != 0 && (p.SubScale < SubScaleMin || p.SubScale > SubScaleMax) {
		p.SubScale = 0
	}
	if p.SubPos < 0 || p.SubPos > SubPosMax {
		p.SubPos = -1
	}
	if p.SubBorderSize < 0 || p.SubBorderSize > SubBorderMax {
		p.SubBorderSize = -1
	}
	/* 弹幕显示:越界回**默认值**,不是回 0。
	   老配置里没有这几个键 —— 但 ParsePrefs 是从 DefaultPrefs 起手的,
	   所以走到这里的 0 只可能来自「前端算错了」或「手改配置改坏了」,
	   那两种情况都该回到能看的那一档,而不是一个看不见的画面。 */
	if p.DanmakuArea < DanmakuAreaMin || p.DanmakuArea > 1.0 {
		p.DanmakuArea = 1.0
	}
	if p.DanmakuScale < DanmakuScaleMin || p.DanmakuScale > DanmakuScaleMax {
		p.DanmakuScale = 1.0
	}
	if p.DanmakuOpacity <= 0 || p.DanmakuOpacity > 1.0 {
		p.DanmakuOpacity = 1.0
	}
	if p.DanmakuSpeed < DanmakuSpeedMin || p.DanmakuSpeed > DanmakuSpeedMax {
		p.DanmakuSpeed = 1.0
	}
	// ★ 这两项**只夹不回默认**:0 是「不显示这一类」,是用户真会选的一档。
	if p.DanmakuTopLines < 0 || p.DanmakuTopLines > DanmakuLinesMax {
		p.DanmakuTopLines = DanmakuLinesMax
	}
	if p.DanmakuBottomLines < 0 || p.DanmakuBottomLines > DanmakuLinesMax {
		p.DanmakuBottomLines = DanmakuLinesMax
	}
	if p.DanmakuBlockwords == nil {
		p.DanmakuBlockwords = []string{}
	}
	if p.DanmakuBlockUsers == nil {
		p.DanmakuBlockUsers = []string{}
	}
	return p
}

// PrefsOf 取当前偏好。
func (c *AppConfig) PrefsOf() Prefs { return ParsePrefs(c.Prefs) }

// SetPrefs 写回偏好(钳过区间)。调用方负责 Save。
func (c *AppConfig) SetPrefs(p Prefs) error {
	b, err := json.Marshal(p.Clamped())
	if err != nil {
		return err
	}
	c.Prefs = b
	return nil
}

// CollectionsEnabledFor 这台服务器的首页要不要画合集栏。
//
// ★ 默认**开**:表里记的是「关掉的那几台」。理由见 HideCollectionServers 的注释。
// ★ 它只管「用户想不想看」,不管「服务器有没有」—— 没有合集时那一栏由 UI 整条不画。
func (p Prefs) CollectionsEnabledFor(server string) bool {
	for _, s := range p.HideCollectionServers {
		if s == server {
			return false
		}
	}
	return true
}

// WatchedAt 位置 pos(秒)在片长 runtime(秒)里算不算「已经看完」。
//
// ★ 片长不知道时一律返回 false —— 猜一个的下场是「刚起播就被标已看完」。
func (p Prefs) WatchedAt(pos, runtime float64) bool {
	if runtime <= 0 || pos <= 0 {
		return false
	}
	return pos/runtime*100 >= float64(p.WatchedThresholdPercent)
}

// PrefetchEnabledFor 这台服务器开了多线程加载吗。
func (p Prefs) PrefetchEnabledFor(server string) bool {
	for _, s := range p.PrefetchServers {
		if s == server {
			return true
		}
	}
	return false
}
