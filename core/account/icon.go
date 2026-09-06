package account

// 服务器图标:下载 / 本地缓存 / 用户本地上传。
//
// ★ 为什么吐 data URI 而不是本地路径:壳读不了任意本地文件(各端的资源协议
// 默认都是关着的)。为一张几十 KB 的图去开资源协议 + 配 scope,
// 不如直接把字节 base64 给它。

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"linplayer/core/bus"
	"linplayer/core/config"
	"linplayer/core/httpx"
	"linplayer/core/paths"
)

// maxIconBytes 单张图标上限。
//
// ★ 防的是「图标地址被填成一部电影的直链」:不设限就会把整部片读进内存
// 再 base64,内存直接翻三倍。
const maxIconBytes = 4 << 20

func iconDir() string { return filepath.Join(paths.CacheDir(), "icons") }

// iconKey server_id 是个 URL,不能直接当文件名 —— 里面有 `:` 和 `/`,
// Windows 上直接建不了。
func iconKey(serverID string) string {
	b := make([]rune, 0, len(serverID))
	for _, c := range serverID {
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
			b = append(b, c)
		} else {
			b = append(b, '_')
		}
	}
	return string(b)
}

func iconPath(serverID string) string { return filepath.Join(iconDir(), iconKey(serverID)) }

// sniffMime 按**内容**嗅探 MIME。
//
// ★★ 不能信扩展名或 Content-Type:Emby 的 `/Users/x/Images/Primary` 不带扩展名,
// 而有些反代会把 Content-Type 抹成 application/octet-stream —— 那样拼出来的
// data URI 浏览器不认,图标变成一个碎图标,**不报错,只是不显示**。
func sniffMime(b []byte) string {
	if m, ok := sniffImage(b); ok {
		return m
	}
	return "image/png"
}

// sniffImage 认得出来才算数。第二个返回值 = **这确实是一张图**。
//
// ☠☠ 原来这里认不出就一律返回 image/png,而调用方只看 MIME —— 于是:
// 反代 / SPA 对 `/web/touchicon.png` 回一份 200 的 index.html,
// 我们把那坨 HTML **当成 png 落进缓存**,而 `IconGetAny` 是先查缓存的,
// 从此**所有候选地址都不会再试**,图标永远出不来。
// 两端的表现都是「一个字都不报,就是没有图标」:
// Avalonia 的 Bitmap 和安卓的 BitmapFactory 解不开,各自 catch 掉。
// 用户原话:「确认站点是有图标的」—— 对,坏在我们把错的那份缓存住了。
func sniffImage(b []byte) (string, bool) {
	switch {
	case len(b) >= 4 && b[0] == 0x89 && string(b[1:4]) == "PNG":
		return "image/png", true
	case len(b) >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF:
		return "image/jpeg", true
	case len(b) >= 4 && string(b[:4]) == "GIF8":
		return "image/gif", true
	case len(b) >= 12 && string(b[:4]) == "RIFF" && string(b[8:12]) == "WEBP":
		return "image/webp", true
	case len(b) >= 4 && b[0] == 0 && b[1] == 0 && b[2] == 1 && b[3] == 0:
		return "image/x-icon", true
	case len(b) >= 8 && b[0] == 'B' && b[1] == 'M':
		return "image/bmp", true
	}
	// SVG 的头可能是 `<?xml …?>` 也可能直接 `<svg`,只看前 256 字节就够分辨
	if h := strings.TrimSpace(string(head(b, 256))); strings.HasPrefix(h, "<svg") ||
		(strings.HasPrefix(h, "<?xml") && strings.Contains(h, "<svg")) {
		return "image/svg+xml", true
	}
	return "", false
}

func head(b []byte, n int) []byte {
	if len(b) < n {
		return b
	}
	return b[:n]
}

// decodable 两端解得开吗。
//
// ★ **SVG 解不开** —— Avalonia 的 Bitmap 和安卓的 BitmapFactory 都不认,
// 各自 catch 掉,界面上一个字都不报。既然如此就别把它当成「拿到了」:
// 判失败,让候选列表继续往下试(官方 touchicon.png 多半是能用的那一条)。
func decodable(mime string) bool { return mime != "image/svg+xml" }

func toDataURI(b []byte) string {
	return "data:" + sniffMime(b) + ";base64," + base64.StdEncoding.EncodeToString(b)
}

// IconGetAny 按顺序试多条地址，头一条拿到图就算。
//
// ★★ 为什么是多条（用户 2026-09-03）：“获取服务器图标，
// 一个是官方 API，一个是从用户头像获取”。
// 登录那一刻算出来的 icon_url 只能二选一，而它会**后来失效** ——
// 用户把头像删了，icon_url 还指着旧头像地址，一个 404 之后就再没有图标，
// 而官方那条明明还好好的。只试一条是把“两种方式”写成了“一次选择”。
//
// ★ 全部不通才报错，报的是**最后一条**的原因 ——
// 回一句“都不行”等于没说。
func IconGetAny(ctx context.Context, serverID string, urls ...string) (string, error) {
	// ★ 缓存命中就不必试任何一条
	if b, err := os.ReadFile(iconPath(serverID)); err == nil && len(b) > 0 {
		return toDataURI(b), nil
	}
	var last error
	for _, u := range urls {
		if strings.TrimSpace(u) == "" {
			continue
		}
		uri, err := IconGet(ctx, serverID, u)
		if err == nil {
			bus.Logf("info", "服务器图标取到了:%s", u)
			return uri, nil
		}
		/* ★ **每一条都记一句**。「站点明明有图标却取不到」查不下去的原因就是这里静默:
		   五条候选全试过了,日志里一个字都没有,分不清是 404、是回了 HTML、
		   还是格式解不开。值不敏感(全是公开静态地址),照原样记。 */
		bus.Logf("warn", "服务器图标候选失败 %s: %v", u, err)
		last = err
	}
	if last == nil {
		return "", fmt.Errorf("该服务器没有图标地址")
	}
	return "", last
}

// OfficialIconURLs 官方图标的候选地址（Emby / Jellyfin 都是这几条）。
//
// ★ 不只一条：各 fork 的 web 目录不一样，有的只有 favicon。
// 它们都是**免登录**的静态文件，不需要 api_key。
func OfficialIconURLs(server string) []string {
	b := strings.TrimRight(strings.TrimSpace(server), "/")
	if b == "" {
		return nil
	}
	/* ★ 顺序 = 「大而清晰」在前、「小而一定有」在后。
	   ★ **根上那两条不能省**:反代常把 Emby 挂在子路径下、或者站点自己换过 web 目录,
	     这时候 `/web/...` 全 404 而 `/favicon.ico` 好好的 —— 用户看到的就是
	     「站点明明有图标,软件就是取不到」。 */
	return []string{
		b + "/web/touchicon.png",
		b + "/web/touchicon144.png",
		b + "/web/apple-touch-icon.png",
		b + "/apple-touch-icon.png",
		b + "/web/favicon.ico",
		b + "/favicon.ico",
	}
}

// IconGet 取图标：缓存命中直接返回；未命中则从 url 下载并缓存。
//
// ★ 取不到返回 error —— 由 UI 决定回退内置图标。在这儿假装成功返回空串的话，
// UI 会显示成碎图标，而且查都没处查。
func IconGet(ctx context.Context, serverID, url string) (string, error) {
	p := iconPath(serverID)
	if b, err := os.ReadFile(p); err == nil && len(b) > 0 {
		return toDataURI(b), nil
	}
	url = strings.TrimSpace(url)
	if url == "" {
		return "", fmt.Errorf("该服务器没有图标地址")
	}
	// 本地路径也走这条(用户上传后 icon_url 存的就是本地路径):按文件读。
	if !strings.HasPrefix(url, "http://") && !strings.HasPrefix(url, "https://") {
		return IconSetFromFile(serverID, url)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", fmt.Errorf("图标地址不合法: %w", err)
	}
	// ★ 服务器图标是用户填的**任意外链**,不是 Emby —— 走默认那条 UA 口径。
	resp, err := httpx.Client().Do(req)
	if err != nil {
		return "", fmt.Errorf("下载图标失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("下载图标失败: HTTP %d", resp.StatusCode)
	}
	if resp.ContentLength > maxIconBytes {
		return "", fmt.Errorf("图标过大(%d 字节)", resp.ContentLength)
	}
	// ★ Content-Length 可以缺席也可以撒谎 —— 读的时候就**卡死上限**,
	//   多读一个字节就判过大,而不是读完再看有多大。
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxIconBytes+1))
	if err != nil {
		return "", fmt.Errorf("读图标失败: %w", err)
	}
	if len(b) > maxIconBytes {
		return "", fmt.Errorf("图标过大(超过 %d 字节)", maxIconBytes)
	}
	if len(b) == 0 {
		return "", fmt.Errorf("图标是空文件")
	}
	/* ☠☠ **落盘之前先确认它真的是一张图。** 缺了这一关的代价见 sniffImage 上面那段:
	   一份 200 的 HTML 会被当成 png 缓存住,而缓存是 IconGetAny 的第一道判断 ——
	   之后所有候选地址一条都不会再试,图标永远出不来且不报错。 */
	mime, ok := sniffImage(b)
	if !ok {
		return "", fmt.Errorf("这个地址回的不是图片(多半是反代把 404 变成了首页 HTML): %s", url)
	}
	if !decodable(mime) {
		return "", fmt.Errorf("图标是 %s,客户端解不开", mime)
	}
	if err := os.MkdirAll(iconDir(), 0o755); err != nil {
		return "", fmt.Errorf("建图标缓存目录失败: %w", err)
	}
	if err := os.WriteFile(p, b, 0o644); err != nil {
		return "", fmt.Errorf("写图标缓存失败: %w", err)
	}
	return toDataURI(b), nil
}

// IconSetFromFile 用户从本地挑一张图当服务器图标:拷进缓存,返回 data URI。
func IconSetFromFile(serverID, filePath string) (string, error) {
	st, err := os.Stat(filePath)
	if err != nil {
		return "", fmt.Errorf("读不到该文件: %w", err)
	}
	if st.Size() > maxIconBytes {
		return "", fmt.Errorf("图片过大(%d 字节),上限 4MB", st.Size())
	}
	b, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("读图片失败: %w", err)
	}
	// ★ 空文件必须报错:返回一个 `data:image/png;base64,` 空串的话,
	//   UI 会显示成碎图标,查都没处查。
	if len(b) == 0 {
		return "", fmt.Errorf("图片是空文件")
	}
	// 和下载那条同一把尺:解不开的格式当场说清楚,别让它变成「上传成功但没图标」
	mime, ok := sniffImage(b)
	if !ok {
		return "", fmt.Errorf("这不是一张图片")
	}
	if !decodable(mime) {
		return "", fmt.Errorf("暂不支持 SVG 图标,换一张 PNG / JPG")
	}
	if err := os.MkdirAll(iconDir(), 0o755); err != nil {
		return "", fmt.Errorf("建图标缓存目录失败: %w", err)
	}
	if err := os.WriteFile(iconPath(serverID), b, 0o644); err != nil {
		return "", fmt.Errorf("写图标缓存失败: %w", err)
	}
	return toDataURI(b), nil
}

// IconClear 清掉某服的图标缓存(服务器换了 logo 时用)。
func IconClear(serverID string) { _ = os.Remove(iconPath(serverID)) }

func registerIconCommands() {
	bus.Register("account.icon", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		id := str(a, "server_id")
		if id == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 server_id")
		}
		/* ★★ 两条路一起给（用户 2026-09-03 点名）：
		   ① icon_url —— 登录时算好的，通常就是**用户头像**
		     （很多 Emby 服把品牌 logo 直接设成用户头像），
		     用户上传过本地图的话这里是一个本地路径；
		   ② 官方静态图标 —— /web/touchicon.png 那几条。
		   原来只试①，而①会后来失效（头像被删）—— 那之后就永远没图标了。 */
		var cands []string
		if acc := config.Current().Find(id); acc != nil && acc.IconURL != nil {
			cands = append(cands, *acc.IconURL)
		}
		cands = append(cands, OfficialIconURLs(id)...)
		uri, err := IconGetAny(ctx, id, cands...)
		if err != nil {
			return nil, bus.NewErr(bus.ENotFound, "%v", err)
		}
		return map[string]any{"data_uri": uri}, nil
	})

	bus.Register("account.setAccountIconFile", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		id, path := str(a, "server_id"), str(a, "file_path")
		if id == "" || path == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 server_id 或 file_path")
		}
		uri, err := IconSetFromFile(id, path)
		if err != nil {
			return nil, bus.NewErr(bus.EInvalid, "%v", err)
		}
		c := config.Current()
		acc := c.Find(id)
		if acc == nil {
			return nil, bus.NewErr(bus.ENotFound, "找不到该服务器: %s", id)
		}
		// ★ icon_url 记成**本地路径**:清了缓存或换台机器后还能从原文件重建,
		//   不用让用户再挑一次。
		a2 := *acc
		a2.IconURL = &path
		c.Upsert(a2)
		if err := commit(c); err != nil {
			return nil, err
		}
		return map[string]any{"data_uri": uri}, nil
	})

	bus.Register("account.clearAccountIcon", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		id := str(a, "server_id")
		if id == "" {
			return nil, bus.NewErr(bus.EInvalid, "缺少 server_id")
		}
		IconClear(id)
		return map[string]any{"cleared": true}, nil
	})
}
