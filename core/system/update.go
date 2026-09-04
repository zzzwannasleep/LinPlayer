package system

//
// 应用内更新检查。
// 这一版**只查不装**:查到新版本给下载地址,安装还是用户自己来
// (设置页那句「这一版还不能自动安装更新」说的就是这个)。
//
// ★★ 版本比较为什么不能用标准 semver:
// CI 的版本串形如 `1.2.0-build91`,同一个 x.y.z 会出无数次预览版迭代。
// semver 会把 `1.2.0-build88` 和 `1.2.0-build91` 的核心部分都规约成 1.2.0 判等,
// 于是**预览版渠道永远检测不到新版本**。所以按 major>minor>patch>build 逐级比,
// 最后再用「同构建号下稳定版 > 预览版」表达晋升关系。

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"strings"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/httpx"
)

// repo 发布仓库。
const repo = "zzzwannasleep/LinPlayer"

// githubAPI GitHub API 基址。做成变量是为了让测试指向假上游 ——
// check() 要联网,不换基址就只测得到「查不动」那一半。
var githubAPI = "https://api.github.com"

func init() {
	if v := strings.TrimSpace(os.Getenv("LP_UPDATE_API")); v != "" {
		githubAPI = strings.TrimRight(v, "/")
	}
}

// parsed 一个版本串拆出来的四段 + 是不是预览版。
type parsed struct {
	major, minor, patch, build int64
	isPre                      bool
}

var (
	reCore  = regexp.MustCompile(`(\d+)\.(\d+)\.(\d+)`)
	reBuild = regexp.MustCompile(`(?i)-build(\d+)`)
	// `\b` 让 `-pre` 后面必须是非单词字符或结尾 —— 免得 `-preview-x` 这种被误判。
	rePre = regexp.MustCompile(`(?i)-pre\b`)
)

func atoi(s string) int64 { n, _ := strconv.ParseInt(s, 10, 64); return n }

func parseVersion(raw string) parsed {
	p := parsed{}
	if m := reCore.FindStringSubmatch(raw); m != nil {
		p.major, p.minor, p.patch = atoi(m[1]), atoi(m[2]), atoi(m[3])
	}
	if m := reBuild.FindStringSubmatch(raw); m != nil {
		p.build = atoi(m[1])
	}
	p.isPre = rePre.MatchString(raw) || strings.HasSuffix(strings.ToLower(raw), "-pre")
	return p
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// CompareVersions a 比 b 新返回 1,旧返回 -1,一样返回 0。
// 两边都吃原始 tag(可带 `v` 前缀、`-buildN`、`-pre`)。
func CompareVersions(a, b string) int {
	pa, pb := parseVersion(a), parseVersion(b)
	for _, d := range []int64{
		pa.major - pb.major, pa.minor - pb.minor,
		pa.patch - pb.patch, pa.build - pb.build,
		// 同号同构建:稳定版 > 预览版。表达「预览版晋升为正式版」这层关系,
		// 免得装了正式版的人被劝回同号的 -pre。
		int64(b2i(pb.isPre) - b2i(pa.isPre)),
	} {
		if d > 0 {
			return 1
		}
		if d < 0 {
			return -1
		}
	}
	return 0
}

// NormalizeVersion 规约成 x.y.z,**只给界面显示,不参与比较**(理由见文件头)。
func NormalizeVersion(raw string) string {
	p := parseVersion(raw)
	return fmt.Sprintf("%d.%d.%d", p.major, p.minor, p.patch)
}

// release GitHub 发布的形状,只取我们用得到的字段。
type release struct {
	TagName    string `json:"tag_name"`
	Name       string `json:"name"`
	Body       string `json:"body"`
	HTMLURL    string `json:"html_url"`
	Draft      bool   `json:"draft"`
	Prerelease bool   `json:"prerelease"`
	Assets     []struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
		Size int64  `json:"size"`
	} `json:"assets"`
}

// PickNewestRelease 从发布列表里挑**版本号最大**的非草稿发布,**不是列表里的第一个**。
//
// ★★ 原先的实现是「取第一个」,理由写的是「GitHub 按时间倒序返回」——
// 那句话是错的。2026-07-19 实测反证:
//
//	v1.0.0-build557-pre  id=356263112  created=05:05  ← 排第 1
//	v0.1.0-build566-pre  id=356398423  created=17:35  ← 排第 2
//
// id、created_at、published_at **三个键都是后者更大/更晚**,却排在后面。
// 这个顺序没写进文档、也不可依赖。
//
// 照抄列表顺序的后果是「**降级伪装成升级**」:把代码更旧、版本号更大的包
// 当最新版推给用户。抽成纯函数是为了能测 —— check() 要联网,测不动。
func PickNewestRelease(list []release) *release {
	var best *release
	for i := range list {
		if list[i].Draft {
			continue
		}
		if best == nil || CompareVersions(list[i].TagName, best.TagName) > 0 {
			best = &list[i]
		}
	}
	return best
}

// assetKeywords 本平台资产名里必须**全部命中**的小写子串。
func assetKeywords() []string {
	if runtime.GOOS == "windows" {
		return []string{"windows"}
	}
	return []string{"linux"}
}

// Info 查到的新版本。
type Info struct {
	// Tag 原始 tag(如 `v1.2.0-build91-pre`)—— 比较**用它**,不是下面那个 Version。
	Tag string `json:"tag"`
	// Version 规约成 x.y.z,只给界面显示用。
	Version    string `json:"version"`
	Name       string `json:"name"`
	Notes      string `json:"notes"`
	HTMLURL    string `json:"html_url"`
	Prerelease bool   `json:"prerelease"`
	// AssetName 本平台该下载的那个资产;挑不出来就是空串 → 界面引导去网页手动下。
	AssetName string `json:"asset_name"`
	AssetURL  string `json:"asset_url"`
	AssetSize int64  `json:"asset_size"`
}

// getJSON 打 GitHub。
//
// ★ 走共享 client(httpx.Client(),第三方公开 API 那条 UA 口径)。
// **不要**为了「干净」另建一个:共享 client 带着用户配的代理,而 GitHub 在
// 目标市场是被墙的 —— 自建 client 等于让所有靠代理上网的用户更新检查必然超时,
// 还查不出原因。
//
// ★ GitHub 强制要求 User-Agent,不发就是 403(见 [[no-ua-gets-403]])。
func getJSON(ctx context.Context, url string, out any) error {
	hdr := http.Header{"Accept": {"application/vnd.github+json"}}
	body, code, err := httpx.GetJSON(ctx, httpx.Client(), url, hdr)
	if err != nil {
		return fmt.Errorf("检查更新失败: %w", err)
	}
	if code < 200 || code >= 300 {
		// 403 基本都是未认证的限流(60 次/小时/IP)。把状态码带出去,
		// 免得用户看到笼统的「检查失败」以为是自己网的问题。
		return fmt.Errorf("检查更新失败: GitHub 返回 %d", code)
	}
	if err := json.Unmarshal(body, out); err != nil {
		return fmt.Errorf("解析发布信息失败: %w", err)
	}
	return nil
}

// CheckUpdate 查有没有比 currentTag 新的版本。
//
// ★★ 「没有更新」和「没查成」必须分开:返回 (nil, nil) 是**确实**没有,
// 返回 error 是断网 / 限流。混成一个的话「查不动」会被说成「已是最新」——
// 那是最坏的一种沉默失败,用户永远等不到更新还以为自己是最新的。
func CheckUpdate(ctx context.Context, channel, currentTag string) (*Info, error) {
	base := githubAPI + "/repos/" + repo

	var rel release
	if channel == "prerelease" {
		var list []release
		if err := getJSON(ctx, base+"/releases?per_page=10", &list); err != nil {
			return nil, err
		}
		newest := PickNewestRelease(list)
		if newest == nil {
			return nil, nil
		}
		rel = *newest
	} else {
		if err := getJSON(ctx, base+"/releases/latest", &rel); err != nil {
			return nil, err
		}
	}

	if rel.TagName == "" {
		return nil, fmt.Errorf("发布信息里没有 tag_name")
	}
	if CompareVersions(rel.TagName, currentTag) <= 0 {
		return nil, nil
	}

	info := &Info{
		Tag:        rel.TagName,
		Version:    NormalizeVersion(rel.TagName),
		Name:       rel.Name,
		Notes:      prettifyNotes(rel.Body),
		HTMLURL:    rel.HTMLURL,
		Prerelease: rel.Prerelease,
	}
	if info.Name == "" {
		info.Name = rel.TagName
	}
	kw := assetKeywords()
	for _, a := range rel.Assets {
		lower := strings.ToLower(a.Name)
		hit := true
		for _, k := range kw {
			if !strings.Contains(lower, k) {
				hit = false
				break
			}
		}
		if hit {
			info.AssetName, info.AssetURL, info.AssetSize = a.Name, a.URL, a.Size
			break
		}
	}
	return info, nil
}

var (
	reLink   = regexp.MustCompile(`\[([^\]]*)\]\([^)]*\)`)
	reHead   = regexp.MustCompile(`(?m)^#{1,6}\s*`)
	reBullet = regexp.MustCompile(`(?m)^\s*[-*+]\s+`)
)

// prettifyNotes GitHub Markdown → 纯文本。更新对话框不跑 Markdown 渲染器,
// 原样贴过去满屏 `##` 和 `**`。
func prettifyNotes(body string) string {
	s := reLink.ReplaceAllString(body, "$1")
	s = reHead.ReplaceAllString(s, "")
	s = reBullet.ReplaceAllString(s, "• ")
	s = strings.ReplaceAll(s, "**", "")
	s = strings.ReplaceAll(s, "__", "")
	s = strings.ReplaceAll(s, "`", "")
	return strings.TrimSpace(s)
}

func registerUpdateCommands() {
	bus.Register("system.checkUpdate", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		ch := config.Current().PrefsOf().UpdateChannel
		info, err := CheckUpdate(ctx, ch, Version)
		if err != nil {
			return nil, bus.NewErr(bus.ENetwork, "%v", err)
		}
		if info == nil {
			// ★ 「已是最新」要**明说**。返回 null 的话界面分不清它和「查不动」,
			//   而这两件事对用户的下一步动作完全不同。
			return map[string]any{"has_update": false, "current": Version}, nil
		}
		return map[string]any{"has_update": true, "current": Version, "update": info}, nil
	})
}
