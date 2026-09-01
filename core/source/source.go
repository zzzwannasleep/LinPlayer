// Package source 是文件浏览型数据源的后端抽象(网盘 / 局域网 / 聚合 / 资源站)。
//
// 移植自 `crates/core/src/source/mod.rs`。**Rust 版是黄金实现。**
//
// 三件事:列目录 / 搜索(可降级)/ 把文件解析成可播 URL(含逐流 headers)。
//
// ★★ **网盘是文件树,资源站是影视目录,这是两种东西。**
// 文件树一行只要「名字 + 是不是文件夹 + 多大」;影视目录一张卡要海报、标题、
// 「更新至 17 集」、年份、评分,还要分类和无限翻页。所以是两套类型、两套页面,
// `Entry` 一个字段都不为影视目录让路。
package source

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
)

// Kind 源类型标识。
//
// ★★ **开放键**,不是封闭枚举:内置源是固定小写字面量,插件贡献的源是
// `plugin:<插件id>/<源id>`。封闭枚举意味着加一个源就得改核心层重新编译,
// 插件永远塞不进分派表。
//
// ★ 线上表示是**裸小写字符串**。前端曾整套写成首字母大写,结果是每处比较恒 false、
// 登录送错值,而**两边都不报错**(见 docs/lessons)。
type Kind string

// 内置源。**顺序即枚举顺序**,给需要穷举的地方(跨语言契约测试)用。
const (
	KindEmby        Kind = "emby"
	KindOpenList    Kind = "openlist"
	KindQuark       Kind = "quark"
	KindAniRSS      Kind = "anirss"
	KindFeiniu      Kind = "feiniu"
	KindAliyunDrive Kind = "aliyundrive"
	KindBaidu       Kind = "baidu"
	KindPan115      Kind = "pan115"
	KindPan189      Kind = "pan189"
	KindPan139      Kind = "pan139"
	// 局域网 / 自建文件源。这三个**不是网盘**:没有厂商 API、没有账号体系,
	// 只有一个地址加一对账号密码,连的是用户自己那台 NAS 或路由器上的硬盘。
	KindSMB    Kind = "smb"
	KindWebDAV Kind = "webdav"
	KindFTP    Kind = "ftp"
	// KindLocal 本机文件夹(用户用系统选择器挑的那个目录)。
	KindLocal Kind = "local"
)

// Builtin 全部内置源,顺序固定。
var Builtin = []Kind{
	KindEmby, KindOpenList, KindQuark,
	KindAniRSS, KindFeiniu,
	KindAliyunDrive, KindBaidu, KindPan115,
	KindPan189, KindPan139,
	KindSMB, KindWebDAV, KindFTP, KindLocal,
}

// pluginPrefix 插件贡献的源统一形如 `plugin:com.example.foo/mysrc`。
const pluginPrefix = "plugin:"

// IsBuiltin 是不是内置源。
func (k Kind) IsBuiltin() bool {
	for _, b := range Builtin {
		if b == k {
			return true
		}
	}
	return false
}

// IsPlugin 是不是插件贡献的源。
func (k Kind) IsPlugin() bool { return strings.HasPrefix(string(k), pluginPrefix) }

// PluginKind 拼一个插件源的 Kind。
func PluginKind(pluginID, srcID string) Kind { return Kind(pluginPrefix + pluginID + "/" + srcID) }

// SplitPlugin 把插件源的 Kind 拆回 (插件id, 源id)。不是插件源就返回 false。
func SplitPlugin(k Kind) (string, string, bool) {
	rest, ok := strings.CutPrefix(string(k), pluginPrefix)
	if !ok {
		return "", "", false
	}
	i := strings.Index(rest, "/")
	if i <= 0 || i == len(rest)-1 {
		return "", "", false
	}
	return rest[:i], rest[i+1:], true
}

// LegacyDebugLabel 逐字复刻 Rust 早期 `format!("{kind:?}")` 的输出(首字母大写)。
//
// ★ 这个方法看起来毫无道理,但**不能删**:那些字符串已经躺在用户的配置文件里了
// (无 base_url 的源 —— 夸克 Cookie 模式 —— 拿它当账号 id 和用户名)。
// 换个写法会让老账号在 upsert 时匹配不上、变成重复项,旧账号成孤儿。
func (k Kind) LegacyDebugLabel() string {
	s := string(k)
	if s == "" {
		return ""
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

// Entry 浏览返回的一行:文件夹或文件。
type Entry struct {
	// ID 继续浏览 / 取流的标识:OpenList = 完整路径,夸克 = fid,Ani-rss = filename。
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	IsDir    bool    `json:"is_dir"`
	IsVideo  bool    `json:"is_video"`
	Size     *int64  `json:"size"`
	ThumbURL *string `json:"thumb_url"`
	// Raw 源原始数据,供 ResolvePlay 复用(避免二次请求)。
	Raw json.RawMessage `json:"raw"`
}

// PlayQuality 一档可选清晰度(转码源如夸克提供多档)。
type PlayQuality struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Rank  int    `json:"rank"`
}

// Subtitle 外挂字幕轨。
type Subtitle struct {
	URL         string            `json:"url"`
	Title       *string           `json:"title"`
	Language    *string           `json:"language"`
	HTTPHeaders map[string]string `json:"http_headers"`
}

// ResolvedPlay 交给播放器的最小可播单元:URL + 逐流 headers。
type ResolvedPlay struct {
	URL               string            `json:"url"`
	Title             string            `json:"title"`
	HTTPHeaders       map[string]string `json:"http_headers"`
	UserAgentOverride *string           `json:"user_agent_override"`
	Subtitles         []Subtitle        `json:"subtitles"`
	Qualities         []PlayQuality     `json:"qualities"`
	SelectedQualityID *string           `json:"selected_quality_id"`
}

// Simple 构造一个只有地址和头的可播单元。
//
// ★ 列表字段给**空切片不是 nil**:序列化成 JSON 时 nil 是 null,
// 前端 `.map()` 直接抛,而透明窗口下渲染抛错 = 一片黑且不报错。
func Simple(url, title string, headers map[string]string) ResolvedPlay {
	if headers == nil {
		headers = map[string]string{}
	}
	return ResolvedPlay{URL: url, Title: title, HTTPHeaders: headers,
		Subtitles: []Subtitle{}, Qualities: []PlayQuality{}}
}

// ---------------------------------------------------------------------------
// 影视目录能力(catalog)—— 可选,只有资源站这类源实现
// ---------------------------------------------------------------------------

// UnsupportedPrefix 「不支持这个能力」的稳定前缀。
//
// ★ 命令层把错误拍成字符串交给前端,前端只能靠文案判断 ——
// 靠中文提示语判断会在改文案时**静默失效**,所以给个机器认得的标记。
const UnsupportedPrefix = "__LP_UNSUPPORTED__"

// MediaCategory 分类。资源站的分类树只有两级,再深也照收,前端自己决定画几级。
type MediaCategory struct {
	ID       string          `json:"id"`
	Name     string          `json:"name"`
	Children []MediaCategory `json:"children"`
}

// MediaCard 目录里的一张卡。
type MediaCard struct {
	ID     string  `json:"id"`
	Title  string  `json:"title"`
	Poster *string `json:"poster"`
	// Badge 右下角角标:资源站的 vod_remarks(「更新至17集」/「HD」/「全24集」)。
	//
	// ★ 它必须是**独立字段**。没有它的时候只能拼进标题,卡片下面就变成
	//   「神之水滴 · 更新至17集 · 2026」—— 那不是标题,是把三样东西塞进一个格子。
	Badge    *string `json:"badge"`
	Year     *string `json:"year"`
	Score    *string `json:"score"`
	IsSeries bool    `json:"is_series"`
}

// MediaPage 目录的一页。
//
// ★ HasMore 决定前端还要不要继续往下拉 —— 「下一页」不该是列表里的一个条目,
// 那是把翻页伪装成内容。
type MediaPage struct {
	Items   []MediaCard `json:"items"`
	Page    uint32      `json:"page"`
	HasMore bool        `json:"has_more"`
	Total   *uint32     `json:"total"`
}

// MediaEpisode 一集。Raw 原样回传给 ResolvePlay,所以播放链路一行都不用改。
type MediaEpisode struct {
	ID   string          `json:"id"`
	Name string          `json:"name"`
	Raw  json.RawMessage `json:"raw"`
}

// MediaLine 一条播放线路。
type MediaLine struct {
	ID       string         `json:"id"`
	Name     string         `json:"name"`
	Episodes []MediaEpisode `json:"episodes"`
}

// MediaDetail 一部片的详情页数据。
type MediaDetail struct {
	ID       string      `json:"id"`
	Title    string      `json:"title"`
	Poster   *string     `json:"poster"`
	Badge    *string     `json:"badge"`
	Year     *string     `json:"year"`
	Area     *string     `json:"area"`
	Lang     *string     `json:"lang"`
	Genre    *string     `json:"genre"`
	Score    *string     `json:"score"`
	Overview *string     `json:"overview"`
	Actors   *string     `json:"actors"`
	Director *string     `json:"director"`
	Lines    []MediaLine `json:"lines"`
}

// ---------------------------------------------------------------------------
// 扫码登录
// ---------------------------------------------------------------------------

// QrStart 扫码登录:开始。
//
// Image 既可能是 data URI(自己画的二维码 PNG),也可能是一个图片 URL(网盘直接给图)。
type QrStart struct {
	Image string `json:"image"`
	// Ctx 轮询要用的上下文(uuid/sign/sid…),JSON 字符串,前端不解读只回传。
	Ctx string `json:"ctx"`
}

// QrPoll 扫码登录:轮询一次的结果。state = pending | confirmed | expired。
type QrPoll struct {
	State string `json:"state"`
	// Credentials 只在 confirmed 时有。直接并进新建 Server 的 Extra 后落盘。
	Credentials map[string]string `json:"credentials,omitempty"`
}

// QrPending / QrExpired / QrConfirmed 三个构造。
func QrPending() QrPoll { return QrPoll{State: "pending"} }
func QrExpired() QrPoll { return QrPoll{State: "expired"} }
func QrConfirmed(creds map[string]string) QrPoll {
	return QrPoll{State: "confirmed", Credentials: creds}
}

// ---------------------------------------------------------------------------
// 错误
// ---------------------------------------------------------------------------

// Error 源后端统一错误。
//
// ★★ 两个布尔位都是**结构化**的,不靠文案判断。
// 黄金实现那边「不支持」只有一句中文,调用方靠字符串比对认它 ——
// 改一次文案就静默失效,而失效的表现是「搜索返回空,用户以为没搜到」。
type Error struct {
	Message string `json:"message"`
	// IsAuth 鉴权失效(UI 可引导重登)。
	IsAuth bool `json:"is_auth"`
	// Unsupported 这个源没有这个能力。调用方据此**静默退回**另一条路径,
	// 而不是把它当成一条真错误弹给用户。
	Unsupported bool `json:"unsupported,omitempty"`
}

func (e *Error) Error() string { return e.Message }

// Msg 一条普通错误。
func Msg(format string, a ...any) *Error { return &Error{Message: fmt.Sprintf(format, a...)} }

// Auth 鉴权失效。
func Auth(format string, a ...any) *Error {
	return &Error{Message: fmt.Sprintf(format, a...), IsAuth: true}
}

// Unsupported 「这个源不支持搜索」。
func Unsupported() *Error { return &Error{Message: "该源不支持搜索", Unsupported: true} }

// UnsupportedFeature 「这个源没有这个能力」。
//
// 带稳定前缀,前端据此**静默退回**另一条路径,而不是把它当成一条真错误弹给用户。
func UnsupportedFeature(what string) *Error {
	return &Error{Message: UnsupportedPrefix + what, Unsupported: true}
}

// IsUnsupported 是不是「没这个能力」。
//
// ★ 先看**结构位**;文案前缀只作为跨语言兼容的兜底 ——
// 插件贡献的源是从 JS 那边把错误对象拍过来的,它只有文案这一条路。
func IsUnsupported(err error) bool {
	if err == nil {
		return false
	}
	var e *Error
	if errors.As(err, &e) && e.Unsupported {
		return true
	}
	return strings.Contains(err.Error(), UnsupportedPrefix)
}

// IsAuthErr 是不是鉴权失效。
func IsAuthErr(err error) bool {
	var e *Error
	if errors.As(err, &e) {
		return e.IsAuth
	}
	return false
}

// ---------------------------------------------------------------------------
// 服务器与后端
// ---------------------------------------------------------------------------

// Server 一个浏览型源服务器的连接凭据。随 AppConfig 落盘(重启免登 + 多源并存)。
type Server struct {
	ID       string            `json:"id"`
	BaseURL  string            `json:"base_url"` // = ActiveLineURL,后端内部 normalize
	Username *string           `json:"username"`
	Password *string           `json:"password"`
	Token    *string           `json:"token"`           // 账密型主令牌
	Extra    map[string]string `json:"extra,omitempty"` // 夸克等多凭据(cookie / refresh_token…)
}

// Backend 文件浏览型源后端的最小抽象(三端复用,纯逻辑)。
//
// ★ 影视目录那三个方法(Categories / Catalog / MediaDetail)是**可选能力**:
// 用单独的接口表达,不实现就是没有。硬塞进本接口会让十几个网盘后端
// 全得写三个「返回不支持」的空方法。
type Backend interface {
	Kind() Kind

	// ListDir 列目录。dirID 为空表示根目录。
	ListDir(ctx context.Context, c *http.Client, s *Server, dirID string) ([]Entry, error)

	// ResolvePlay 把文件解析成可播单元(含取流所需 headers)。
	// 短效直链过期后播放层回调重解析。
	ResolvePlay(ctx context.Context, c *http.Client, s *Server, e *Entry, qualityID string) (*ResolvedPlay, error)
}

// Searcher 源内搜索。没有源端搜索能力的后端不实现它,UI 退回本地过滤。
type Searcher interface {
	Search(ctx context.Context, c *http.Client, s *Server, query string) ([]Entry, error)
}

// ProgressReporter 播放进度上报。有服务端观看记录的源(飞牛等)实现它。
//
// ★ 失败一律吞掉不打断播放 —— 进度没记上是小事,把正在看的片子打断是大事。
type ProgressReporter interface {
	ReportProgress(ctx context.Context, c *http.Client, s *Server, e *Entry,
		positionSecs, durationSecs float64, finished bool) error
}

// CredentialRotator **凭据轮换回写通道**。
//
// ★★ 存在的理由:后端只拿得到只读的 *Server,而 oplist 系与阿里云盘的
// refresh_token 是**一次性的** —— 刷新一次旧值当场作废。不回写的话内存里能用,
// 一重启就拿着死 token 去刷,表现为「用得好好的,重开就要重新授权」,且不报错。
//
// 调用方在每次 ListDir / Search / ResolvePlay 之后取一次;返回的 map 并入
// Server.Extra 后存盘。
type CredentialRotator interface {
	TakeRotatedCredentials(serverID string) map[string]string
}

// Cataloger 影视目录能力。只有资源站这类源实现。
type Cataloger interface {
	Categories(ctx context.Context, c *http.Client, s *Server) ([]MediaCategory, error)
	Catalog(ctx context.Context, c *http.Client, s *Server, categoryID, keyword string, page uint32) (*MediaPage, error)
	MediaDetailOf(ctx context.Context, c *http.Client, s *Server, id string) (*MediaDetail, error)
}

// ---------------------------------------------------------------------------
// 公共辅助
// ---------------------------------------------------------------------------

// videoExtensions 认得的视频后缀。和黄金实现逐条一致。
var videoExtensions = map[string]bool{
	"mp4": true, "mkv": true, "avi": true, "mov": true, "wmv": true, "flv": true,
	"webm": true, "m4v": true, "mpg": true, "mpeg": true, "ts": true, "m2ts": true,
	"mts": true, "rmvb": true, "rm": true, "vob": true, "3gp": true, "f4v": true,
	"ogv": true, "m3u8": true, "iso": true, "divx": true, "asf": true, "mxf": true,
}

// IsVideoFileName 按后缀判断是不是视频。
func IsVideoFileName(name string) bool {
	i := strings.LastIndex(name, ".")
	if i < 0 {
		return false
	}
	return videoExtensions[strings.ToLower(name[i+1:])]
}

// SortEntries 文件夹在前、各自按名排序(大小写不敏感)。
func SortEntries(entries []Entry) {
	sort.SliceStable(entries, func(i, j int) bool {
		a, b := entries[i], entries[j]
		if a.IsDir != b.IsDir {
			return a.IsDir
		}
		return strings.ToLower(a.Name) < strings.ToLower(b.Name)
	})
}

// NormalizeBaseURL 去掉首尾空白与结尾斜杠。
func NormalizeBaseURL(raw string) string {
	return strings.TrimRight(strings.TrimSpace(raw), "/")
}

// ProbeBackend 「添加服务器」时验证这个源确实能用。
//
// ★★ **不能只试 ListDir。** 影视目录型的源(资源站)根本不实现它 —— 它有分类、
// 有分页、有分集,不是文件树。只探 ListDir 的话那一整类源在添加这一步就被判死,
// 报的还是一句莫名其妙的话,完全看不出是探测方式选错了(2026-08-01 真踩到:
// 插件装好了、目录也能列,就是加不进服务器表)。
//
// 两条能力通任意一条,就算这个源能用。
//
// ★ 放在核心层而不是各端命令里:桌面和安卓的 source.login 曾是两份手工拷贝,
// 这种「探测口径」放在两边迟早只改一边。
func ProbeBackend(ctx context.Context, b Backend, c *http.Client, s *Server) error {
	filesErr := func() error {
		_, err := b.ListDir(ctx, c, s, "")
		return err
	}()
	if filesErr == nil {
		return nil
	}
	cat, ok := b.(Cataloger)
	if !ok {
		return filesErr
	}
	if _, err := cat.Categories(ctx, c, s); err == nil {
		return nil
	} else if IsUnsupported(err) {
		// 两条都不通:报**文件树**那条的错。用户填错地址时那句通常更具体
		// (「返回的不是采集接口 JSON」之类),而目录那条往往只是句「不支持」。
		return filesErr
	} else {
		return err
	}
}
