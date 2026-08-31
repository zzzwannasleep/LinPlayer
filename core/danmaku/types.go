package danmaku

// 弹幕的公共类型 + 源配置。
//
// 移植自 `crates/core/src/danmaku/mod.rs`。

import (
	"encoding/json"
	"strings"

	"linplayer/core/config"
)

// AuthType 一条自建弹幕源的鉴权方式。
type AuthType string

const (
	AuthNone        AuthType = "none"
	AuthSignature   AuthType = "dandanplaySignature"
	AuthPathToken   AuthType = "pathToken"
	AuthHeaderToken AuthType = "headerToken"
	AuthQueryToken  AuthType = "queryToken"
)

// SourceConfig 一条弹幕源。
type SourceConfig struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	APIURL string `json:"api_url"`
	// Official 弹弹Play 官方源(固定 base + 强制签名)。
	Official  bool     `json:"official"`
	AuthType  AuthType `json:"auth_type,omitempty"`
	Token     string   `json:"token,omitempty"`
	AppID     string   `json:"app_id,omitempty"`
	AppSecret string   `json:"app_secret,omitempty"`
}

// Comment 一条弹幕(归一化)。
type Comment struct {
	Time   float64 `json:"time"`
	Text   string  `json:"text"`
	Mode   int     `json:"mode"`  // 1=滚动 4=底 5=顶
	Color  int     `json:"color"` // RGB int
	Source string  `json:"source"`
	CID    *string `json:"cid"`
	UserID *string `json:"user_id"`
	// Count 去重后同一弹幕出现的次数,未去重恒为 1。
	Count int `json:"count"`
}

// Episode 一集。
type Episode struct {
	EpisodeID     string  `json:"episode_id"`
	EpisodeTitle  string  `json:"episode_title"`
	EpisodeNumber *string `json:"episode_number"`
}

// Anime 一部作品。
type Anime struct {
	AnimeID         string    `json:"anime_id"`
	AnimeTitle      string    `json:"anime_title"`
	Type            *string   `json:"type_"`
	TypeDescription *string   `json:"type_description"`
	ImageURL        *string   `json:"image_url"`
	Year            *int64    `json:"year"`
	EpisodeCount    *int64    `json:"episode_count"`
	Episodes        []Episode `json:"episodes"`
}

// MatchItem 文件识别命中项。
type MatchItem struct {
	EpisodeID       string  `json:"episode_id"`
	AnimeID         string  `json:"anime_id"`
	AnimeTitle      string  `json:"anime_title"`
	EpisodeTitle    string  `json:"episode_title"`
	Type            *string `json:"type_"`
	TypeDescription *string `json:"type_description"`
	Shift           *int64  `json:"shift"`
	SourceID        string  `json:"source_id"`
	SourceName      string  `json:"source_name"`
}

// MatchResult /match 的返回。
type MatchResult struct {
	IsMatched bool        `json:"is_matched"`
	Matches   []MatchItem `json:"matches"`
}

// MatchCandidate 一条匹配候选(某源的某作品的某一集)。
type MatchCandidate struct {
	SourceID     string `json:"source_id"`
	SourceName   string `json:"source_name"`
	AnimeID      string `json:"anime_id"`
	AnimeTitle   string `json:"anime_title"`
	EpisodeID    string `json:"episode_id"`
	EpisodeTitle string `json:"episode_title"`
	// Score 排序分(越大越可信)。
	Score float64 `json:"score"`
}

// MatchInput 匹配输入。
//
// ★ 核心层不认 Emby Item(它没有 path 字段,而且网盘 / 聚合源没有 Emby 上下文),
// 由宿主用 ResolveTitle / ResolveFileName 装好再传进来。
type MatchInput struct {
	// Title 作品标题(剧集用 seriesName,否则条目名)。
	Title string `json:"title"`
	// AltTitles 同一部作品的**其它写法**:原名(日文 / 罗马音)、真实发布文件名、条目名……
	// 见 TitleScore 的注释。空表 = 只用 Title。
	AltTitles []string `json:"alt_titles"`
	// EpisodeNo 集号(剧集才有)。
	EpisodeNo *int64 `json:"episode_no"`
	// SeasonNo 季号(剧集才有)。见 SeasonTerm。
	SeasonNo *int64 `json:"season_no"`
	// FileName 真实文件名(文件识别用)。
	FileName     string   `json:"file_name"`
	FileHash     *string  `json:"file_hash"`
	FileSize     *int64   `json:"file_size"`
	DurationSecs *float64 `json:"duration_secs"`
	// Genres 条目的类型 / 标签(Emby Genres + Tags)。**只用来决定官方源参不参与**,
	// 不参与评分 —— 见 AllowOfficialFor。空表 = 不知道,按「允许」处理。
	Genres []string `json:"genres"`
}

// SourceGroup 一个源下的搜索结果。
type SourceGroup struct {
	SourceID   string  `json:"source_id"`
	SourceName string  `json:"source_name"`
	Animes     []Anime `json:"animes"`
	// Error 这个源自己挂了。**其它源照出** —— 一个源挂了不该让整页空白。
	Error *string `json:"error"`
}

// ResolveTitle 剧集用 seriesName,否则用条目名。
func ResolveTitle(seriesName, name string) string {
	if s := strings.TrimSpace(seriesName); s != "" {
		return s
	}
	return strings.TrimSpace(name)
}

// ResolveFileName 真实文件名:优先 path 的 basename,无则退条目名。
//
// ★ Emby 存的是**发布文件名**,文件识别最准 —— 条目名往往是刮削后的中文名,
// 拿它去做 hash 匹配一条都对不上。
func ResolveFileName(path, name string) string {
	if path != "" {
		norm := strings.ReplaceAll(path, `\`, "/")
		if i := strings.LastIndex(norm, "/"); i >= 0 {
			if base := norm[i+1:]; base != "" {
				return base
			}
		} else if norm != "" {
			return norm
		}
	}
	return name
}

// DurationSecsFromTicks 时长 ticks → 秒。
func DurationSecsFromTicks(ticks int64) *float64 {
	if ticks <= 0 {
		return nil
	}
	s := float64(ticks) / 10_000_000.0
	return &s
}

// ---------- 源配置的读写 ----------

// LoadSources 从配置里读弹幕源表。
func LoadSources() []SourceConfig {
	raw := config.Current().DanmakuSources
	if len(raw) == 0 {
		return []SourceConfig{}
	}
	var out []SourceConfig
	if json.Unmarshal(raw, &out) != nil || out == nil {
		return []SourceConfig{}
	}
	return out
}

// SaveSources 写回弹幕源表。
func SaveSources(list []SourceConfig) error {
	c := config.Current()
	b, err := json.Marshal(list)
	if err != nil {
		return err
	}
	c.DanmakuSources = b
	return c.Save()
}
