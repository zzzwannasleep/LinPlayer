package config

// 播放与全局偏好。移植自 `crates/core/src/config.rs` 的 `Prefs`。
//
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
)

// Prefs 播放与全局偏好。
type Prefs struct {
	// ---- 选轨 ----
	AudioLang  *string `json:"audio_lang"`
	SubLang    *string `json:"sub_lang"`
	SubEnabled bool    `json:"sub_enabled"` // 默认 true

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
	// 自动跳过片头 / 片尾。依赖**服务端章节**,没刮削章节的库自动静默不工作。
	//
	// ★ 片头片尾是**两个**开关:播放页「更多」面板里就是两行,
	// 一个字段喂两行会出现「点片头把片尾也翻了」。设置页也照这个粒度给两行。
	SkipIntro bool `json:"skip_intro"`
	SkipOutro bool `json:"skip_outro"`
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
	// 启动时自动检查更新。关掉之后只剩设置页里的手动检查。默认 true。
	UpdateAutoCheck bool `json:"update_auto_check"`

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

	// 详情页背景图的模糊强度,0~100。默认 40。
	// 归 Prefs 是因为它是**观感偏好**不是主题 —— 换主题不该把它重置。
	DetailBlur int `json:"detail_blur"`

	// rest 这份偏好里我们还没接的键,原样透传。
	rest map[string]json.RawMessage
}

// DefaultPrefs 全新安装的默认偏好。
//
// ★ **解析必须从这里起手。** 见文件头:Go 的缺字段是零值,不是 Rust 的 serde default。
func DefaultPrefs() Prefs {
	return Prefs{
		SubEnabled:                   true,
		CrossServerWritebackRange:    "all",
		CrossServerWritebackProgress: true,
		PrefetchThreads:              3,
		PrefetchCacheBytes:           512 * 1024 * 1024,
		PreloadEnabled:               true,
		PreloadHeadMB:                32,
		Hwdec:                        "auto-safe",
		DefaultSpeed:                 1.0,
		PreviewThumbs:                true,
		DolbyAutoSW:                  true,
		UpdateChannel:                "stable",
		UpdateAutoCheck:              true,
		DetailBlur:                   40,
		WatchedThresholdPercent:      90,
		PrefetchServers:              []string{},
		HideCollectionServers:        []string{},
		rest:                         map[string]json.RawMessage{},
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
