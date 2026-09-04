// Package ranking 排行榜双源:动漫 = 弹弹Play,影视 = TMDB。
//
// **Rust 版是黄金实现。**
// ★★ 这个模块的全部教训是一句话:**错误必须说人话地冒出去,不许吞成空数组。**
//
// 2026-07-21 用户报「榜单没数据」,当时 fetch 里有 6 条 `return vec![]`:
// 缺凭据 / 请求失败 / 非 JSON / success=false / 缺字段 —— 全部长得一模一样(空榜)。
// 排查时根本分不清是「构建没注入密钥」还是「服务端拒签」,只能靠猜。
// 实际根因之一是安卓 CI 压根没传 DANDANPLAY_*。
package ranking

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"linplayer/core/danmaku"
	"linplayer/core/httpx"
	"linplayer/core/paths"
	"linplayer/core/secrets"
)

// Source 榜单来源。
type Source string

const (
	SourceDandan Source = "dandan"
	SourceTMDB   Source = "tmdb"
)

// Group 榜单分组。
type Group string

const (
	GroupAnime Group = "anime"
	GroupMovie Group = "movie"
	GroupTV    Group = "tv"
)

// Entry 一条榜单条目。两源的字段收敛到这里。
type Entry struct {
	Source      Source   `json:"source"`
	ID          string   `json:"id"`
	Title       string   `json:"title"`
	Rank        int      `json:"rank"`
	ImageURL    *string  `json:"image_url"`
	Rating      *float64 `json:"rating"`
	Subtitle    *string  `json:"subtitle"`
	IsFavorited bool     `json:"is_favorited"`
	MediaType   *string  `json:"media_type"` // tmdb: movie | tv
}

// Category 一个榜单分类。
type Category struct {
	ID         string  `json:"id"`
	Group      Group   `json:"group"`
	Source     Source  `json:"source"`
	Label      string  `json:"label"`
	DandanPath *string `json:"dandan_path"`
	TMDBPath   *string `json:"tmdb_path"`
}

func sp(s string) *string { return &s }

// Categories 内置榜单清单。动漫走弹弹Play,电影 / 剧集走 TMDB。
var Categories = []Category{
	{"anime_hot_week", GroupAnime, SourceDandan, "本周热门", sp("all/hot/week"), nil},
	{"anime_hot_month", GroupAnime, SourceDandan, "本月热门", sp("all/hot/month"), nil},
	{"anime_rising_week", GroupAnime, SourceDandan, "本周飙升", sp("all/rising/week"), nil},
	{"anime_new_current", GroupAnime, SourceDandan, "当季新番", sp("new-anime/hot/current-season"), nil},
	{"anime_new_previous", GroupAnime, SourceDandan, "上季新番", sp("new-anime/hot/previous-season"), nil},
	{"movie_trending_week", GroupMovie, SourceTMDB, "本周趋势", nil, sp("/trending/movie/week")},
	{"movie_popular", GroupMovie, SourceTMDB, "流行", nil, sp("/movie/popular")},
	{"movie_top_rated", GroupMovie, SourceTMDB, "高分", nil, sp("/movie/top_rated")},
	{"movie_now_playing", GroupMovie, SourceTMDB, "正在上映", nil, sp("/movie/now_playing")},
	{"tv_trending_week", GroupTV, SourceTMDB, "本周趋势", nil, sp("/trending/tv/week")},
	{"tv_popular", GroupTV, SourceTMDB, "流行", nil, sp("/tv/popular")},
	{"tv_top_rated", GroupTV, SourceTMDB, "高分", nil, sp("/tv/top_rated")},
	{"tv_on_the_air", GroupTV, SourceTMDB, "正在播出", nil, sp("/tv/on_the_air")},
}

// AnimeConfigured 这个构建有没有弹弹Play 凭据。
func AnimeConfigured() bool { return secrets.DandanConfigured() }

// VideoConfigured 这个构建有没有 TMDB 密钥。
func VideoConfigured() bool { return secrets.TMDBConfigured() }

// Available 当前构建可用的分类。
//
// ★ 没凭据就不亮那一族,这是**诚实**:亮出来点进去必然是空的,
// 用户只会以为「这个播放器的排行榜坏了」。
func Available() []Category {
	// ★ 不能是 nil:序列化成 JSON 是 null,前端 .map() 直接抛,
	//   而透明窗口下渲染抛错 = 一片黑且不报错。
	out := make([]Category, 0, len(Categories))
	for _, c := range Categories {
		if (c.Source == SourceDandan && AnimeConfigured()) || (c.Source == SourceTMDB && VideoConfigured()) {
			out = append(out, c)
		}
	}
	return out
}

func byID(id string) *Category {
	for i := range Categories {
		if Categories[i].ID == id {
			return &Categories[i]
		}
	}
	return nil
}

// ---------- 拉取 ----------

// fetchDandanWithCreds 凭据由调用方给。
//
// ★ 拆出来不是为了好看:凭据是**编译期**注入的,测试进程里永远是空的。
// 不拆的话,「服务端拒绝时说不说得清」这一族判据一条都跑不到 ——
// 每次都停在「此构建没有凭据」那道门上,而那正是最不重要的一条。
func fetchDandanWithCreds(ctx context.Context, cat *Category, appID, secret string) ([]Entry, error) {
	if cat.DandanPath == nil {
		return nil, fmt.Errorf("分类 %s 没有弹弹Play 路径", cat.ID)
	}
	path := "/api/v2/trending/" + *cat.DandanPath
	ts := time.Now().Unix()
	u := dandanBase + path + "?filterAdultContent=true&limit=50"
	body, status, err := httpx.GetJSON(ctx, httpx.Client(), u, map[string][]string{
		"X-AppId":     {appID},
		"X-Timestamp": {strconv.FormatInt(ts, 10)},
		"X-Signature": {danmaku.Signature(appID, path, ts, secret)},
	})
	if err != nil {
		return nil, fmt.Errorf("请求弹弹Play 失败: %w", err)
	}
	var j struct {
		Success      *bool  `json:"success"`
		ErrorCode    int64  `json:"errorCode"`
		ErrorMessage string `json:"errorMessage"`
		BangumiList  *[]struct {
			AnimeID         json.RawMessage `json:"animeId"`
			AnimeTitle      string          `json:"animeTitle"`
			ImageURL        string          `json:"imageUrl"`
			Rating          *float64        `json:"rating"`
			TypeDescription string          `json:"typeDescription"`
			IsFavorited     bool            `json:"isFavorited"`
		} `json:"bangumiList"`
	}
	if err := json.Unmarshal(body, &j); err != nil {
		return nil, fmt.Errorf("弹弹Play 返回不是 JSON(HTTP %d): %w", status, err)
	}
	// errorCode / errorMessage 是官方 ResponseBase 的字段,签名错 / 无权限都在这儿说明原因。
	if j.Success == nil || !*j.Success {
		msg := j.ErrorMessage
		if msg == "" {
			msg = "(无错误信息)"
		}
		return nil, fmt.Errorf("弹弹Play 拒绝请求(HTTP %d / errorCode %d): %s", status, j.ErrorCode, msg)
	}
	if j.BangumiList == nil {
		return nil, fmt.Errorf("弹弹Play 响应缺少 bangumiList 字段(HTTP %d)", status)
	}
	out := make([]Entry, 0, len(*j.BangumiList))
	rank := 0
	for _, m := range *j.BangumiList {
		title := strings.TrimSpace(m.AnimeTitle)
		if title == "" {
			continue
		}
		rank++
		e := Entry{Source: SourceDandan, ID: valToStr(m.AnimeID), Title: title, Rank: rank,
			Rating: m.Rating, IsFavorited: m.IsFavorited}
		if img := strings.TrimSpace(m.ImageURL); img != "" {
			e.ImageURL = &img
		}
		if sub := strings.TrimSpace(m.TypeDescription); sub != "" {
			e.Subtitle = &sub
		}
		out = append(out, e)
	}
	return out, nil
}

// fetchTMDBWithKey 密钥由调用方给(理由同 fetchDandanWithCreds)。
func fetchTMDBWithKey(ctx context.Context, cat *Category, key string) ([]Entry, error) {
	if cat.TMDBPath == nil {
		return nil, fmt.Errorf("分类 %s 没有 TMDB 路径", cat.ID)
	}
	mediaType := "movie"
	if strings.Contains(*cat.TMDBPath, "/tv") {
		mediaType = "tv"
	}
	u := tmdbBase + *cat.TMDBPath + "?language=zh-CN&page=1"
	hdr := map[string][]string{}
	// v4 JWT 含点走 Bearer;v3 是 32 位十六进制,走 query。
	if strings.Contains(key, ".") {
		hdr["Authorization"] = []string{"Bearer " + key}
	} else {
		u += "&api_key=" + key
	}
	body, status, err := httpx.GetJSON(ctx, httpx.Client(), u, hdr)
	if err != nil {
		return nil, fmt.Errorf("请求 TMDB 失败: %w", err)
	}
	var j struct {
		Results *[]struct {
			ID           json.RawMessage `json:"id"`
			Title        string          `json:"title"`
			Name         string          `json:"name"`
			PosterPath   string          `json:"poster_path"`
			VoteAverage  *float64        `json:"vote_average"`
			ReleaseDate  string          `json:"release_date"`
			FirstAirDate string          `json:"first_air_date"`
		} `json:"results"`
		StatusMessage string `json:"status_message"`
	}
	if err := json.Unmarshal(body, &j); err != nil {
		return nil, fmt.Errorf("TMDB 返回不是 JSON(HTTP %d): %w", status, err)
	}
	if j.Results == nil {
		// TMDB 用 status_message 说明密钥无效 / 超配额。
		msg := j.StatusMessage
		if msg == "" {
			msg = "响应缺少 results 字段"
		}
		return nil, fmt.Errorf("TMDB 拒绝请求(HTTP %d): %s", status, msg)
	}
	out := make([]Entry, 0, len(*j.Results))
	rank := 0
	for _, m := range *j.Results {
		title := strings.TrimSpace(m.Title)
		if title == "" {
			title = strings.TrimSpace(m.Name)
		}
		if title == "" {
			continue
		}
		rank++
		mt := mediaType
		e := Entry{Source: SourceTMDB, ID: valToStr(m.ID), Title: title, Rank: rank,
			Rating: m.VoteAverage, MediaType: &mt}
		if p := strings.TrimSpace(m.PosterPath); p != "" {
			full := tmdbImgBase + p
			e.ImageURL = &full
		}
		date := m.ReleaseDate
		if date == "" {
			date = m.FirstAirDate
		}
		if len(date) >= 4 {
			y := date[:4]
			e.Subtitle = &y
		}
		out = append(out, e)
	}
	return out, nil
}

// valToStr id 可能是数字也可能是字符串,两边都得吃得下。
func valToStr(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var f float64
	if json.Unmarshal(raw, &f) == nil {
		return strconv.FormatInt(int64(f), 10)
	}
	return ""
}

// ---------- 6h 文件缓存 ----------

const cacheTTL = 6 * time.Hour

func cacheDir() string { return filepath.Join(paths.CacheDir(), "ranking") }

type cached struct {
	At      int64   `json:"at"`
	Entries []Entry `json:"entries"`
}

func cacheGet(id string) []Entry {
	raw, err := os.ReadFile(filepath.Join(cacheDir(), id+".json"))
	if err != nil {
		return nil
	}
	var c cached
	if json.Unmarshal(raw, &c) != nil {
		return nil
	}
	if time.Since(time.Unix(c.At, 0)) > cacheTTL {
		return nil
	}
	return c.Entries
}

func cachePut(id string, entries []Entry) {
	dir := cacheDir()
	if os.MkdirAll(dir, 0o755) != nil {
		return
	}
	if b, err := json.Marshal(cached{At: time.Now().Unix(), Entries: entries}); err == nil {
		_ = os.WriteFile(filepath.Join(dir, id+".json"), b, 0o644)
	}
}

// Fetch 拉取某分类榜单。默认命中 6h 缓存;forceRefresh 绕过。
func Fetch(ctx context.Context, categoryID string, forceRefresh bool) ([]Entry, error) {
	appID, secret, _ := secrets.DandanCreds()
	return fetchWith(ctx, categoryID, forceRefresh, appID, secret, secrets.TMDBKey())
}

// fetchWith 是 Fetch 的可注入凭据版本(见 fetchDandanWithCreds 的注释)。
func fetchWith(ctx context.Context, categoryID string, forceRefresh bool, dandanID, dandanSecret, tmdbKey string) ([]Entry, error) {
	cat := byID(categoryID)
	if cat == nil {
		return nil, fmt.Errorf("未知榜单分类: %s", categoryID)
	}
	if !forceRefresh {
		if c := cacheGet(categoryID); c != nil {
			return c, nil
		}
	}
	var (
		list []Entry
		err  error
	)
	switch cat.Source {
	case SourceDandan:
		if dandanID == "" || dandanSecret == "" {
			return nil, fmt.Errorf("此构建未注入弹弹Play 凭据(DANDANPLAY_APP_ID/APP_SECRET)")
		}
		list, err = fetchDandanWithCreds(ctx, cat, dandanID, dandanSecret)
	default:
		if tmdbKey == "" {
			return nil, fmt.Errorf("此构建未注入 TMDB 密钥(TMDB_API_KEY)")
		}
		list, err = fetchTMDBWithKey(ctx, cat, tmdbKey)
	}
	if err != nil {
		return nil, err
	}
	if len(list) > 0 {
		cachePut(categoryID, list)
	}
	return list, nil
}
