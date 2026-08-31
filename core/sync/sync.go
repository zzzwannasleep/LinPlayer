// Package sync 是 Trakt / Bangumi 同步的基座:账号存储、凭据、代理配置、日期工具。
//
// 移植自 `crates/core/src/sync/mod.rs`。**Rust 版是黄金实现。**
//
// ★★ **一处有意偏离,而且是必须偏离的**:
//
// 黄金实现把 `SYNC_PROXY_KEY`(访问自建 OAuth 代理的共享密钥)和代理地址
// **明文写在源码里**,并且已经进了版本库。那条密钥能让任何拿到源码的人
// 用我们的代理去换 OAuth token —— 而仓库随时可能被 fork / 转公开。
//
// Go 侧改成**编译期注入**(和 core/secrets 一套机制),源码里只留空默认值。
// 没注入时,需要代理的那几条路(Trakt 换 token / Bangumi 换 token / 爱发电校验)
// 明说「这个构建没有配同步服务」—— 和排行榜没凭据一个套路,不假装成功。
//
// ⚠️ 现网那条明文密钥**仍然躺在 git 历史里**,换语言不会让它消失:
//
//	要轮换那把 key,并按红线改写历史。这条记在迁移必带清单里。
package sync

import (
	"crypto/sha256"
	"encoding/json"
	"os"
	"strings"
	"time"

	"linplayer/core/config"
)

// 代理配置。由 `-ldflags -X` 注入(见 core/cmd/sealsecrets)。
//
// ★ 地址也注入:它是**我们自己的中转地址**,同样不该出现在提交里。
var (
	proxyBase string
	proxyKey  string
)

// ProxyBase 同步代理基址。空 = 这个构建没配。
func ProxyBase() string { return strings.TrimRight(strings.TrimSpace(proxyBase), "/") }

// UseProxy 这个构建能不能用需要 client_secret 的那几条路。
func UseProxy() bool { return ProxyBase() != "" }

// ProxyHeaders 代理请求要附带的共享密钥头。
func ProxyHeaders() map[string]string {
	if proxyKey == "" {
		return map[string]string{}
	}
	return map[string]string{"X-LinPlayer-Key": proxyKey}
}

// 第三方公开端点。这些是**别人的**服务地址,不是我们的中转,照留。
//
// ★ 做成变量而不是常量,是为了让测试能指向假上游 —— 这一块的判据
// (0 分要滤掉 / 中文名优先 / 只看我追的)只有拿真形状的响应才验得到。
var (
	BangumiAPIOfficial   = "https://api.bgm.tv"
	BangumiAPIMirror     = "https://bgmapi.anibt.net"
	BangumiOAuthOfficial = "https://bgm.tv"
	// BangumiImgMirror 图片反代。
	//
	// ★ API 走官方、图片单独改写到反代:实测 anibt 的 API 反代过不了 CF,
	// 但图片反代没问题;而官方图片 lain.bgm.tv 国内常不通。两边各取其长。
	BangumiImgMirror = "https://bgmimg.anibt.net"

	TraktAPI = "https://api.trakt.tv"
)

// 环境变量覆盖:给**真机自检**用(scripts/selfcheck-win.sh)。
//
// ★ 日历页有数据时长什么样,是单测验不到的:那要真 exe 跑起来才现形
// (今天居中、列宽、标题不截、封面不裁)。而真上游要网络、要账号、还会变。
// ★ 只认环境变量,不进配置、不进命令 —— 用户点不到。
func init() {
	if v := os.Getenv("LP_BANGUMI_API"); v != "" {
		BangumiAPIOfficial = v
	}
	if v := os.Getenv("LP_TRAKT_API"); v != "" {
		TraktAPI = v
	}
}

// setBangumiBaseForTest 只给本包测试用,返回还原函数。
func setBangumiBaseForTest(api string) func() {
	old := BangumiAPIOfficial
	BangumiAPIOfficial = api
	return func() { BangumiAPIOfficial = old }
}

// ---------- OAuth 公开标识符的轻混淆 ----------
//
// ★ client_id / app_id 是**公开标识符**(OAuth 规范里它们本来就要发给服务端),
// 混淆只是抬高「strings 一下就抄走」的门槛,不是保密。真正的 secret 在代理那边。

const obfPassphrase = "LinPlayer::oauth::keystream::v1"

func reveal(cipher []byte) string {
	key := sha256.Sum256([]byte(obfPassphrase))
	out := make([]byte, len(cipher))
	for i, b := range cipher {
		out[i] = b ^ key[i%len(key)]
	}
	return string(out)
}

// traktIDCipher / bangumiIDCipher 与 Rust 侧逐字节一致(同一把 keystream)。
var (
	traktIDCipher = []byte{
		94, 64, 7, 107, 88, 45, 161, 24, 109, 207, 251, 44, 74, 86, 128, 57, 28, 25, 181, 219, 228,
		246, 2, 118, 33, 9, 178, 128, 140, 203, 179, 119, 12, 30, 3, 103, 92, 36, 250, 79, 111, 206,
		250, 40, 27, 0, 140, 56, 26, 76, 182, 143, 229, 240, 82, 115, 44, 95, 184, 208, 142, 157, 230,
		39,
	}
	bangumiIDCipher = []byte{
		8, 31, 88, 107, 89, 35, 247, 29, 50, 150, 245, 40, 76, 85, 220, 59, 28, 72, 179, 139,
	}
)

// TraktClientID Trakt 的公开 client_id。
func TraktClientID() string { return reveal(traktIDCipher) }

// BangumiAppID Bangumi 的公开 app_id。
func BangumiAppID() string { return reveal(bangumiIDCipher) }

// ---------- 已连接账号 ----------

// Account 一个已连接的同步账号。
type Account struct {
	Service      string  `json:"service"` // trakt | bangumi
	AccessToken  string  `json:"access_token"`
	RefreshToken *string `json:"refresh_token"`
	// ExpiresAt 过期时刻 epoch ms;nil = 未知 / 不过期。
	ExpiresAt *int64  `json:"expires_at"`
	Username  *string `json:"username"`
	UserID    *string `json:"user_id"`
}

// IsExpired 是否已过期。
//
// ★ 带 60 秒安全余量:正好卡在过期那一刻发出去的请求,到服务端就已经过期了。
func (a *Account) IsExpired(nowMs int64) bool {
	if a.ExpiresAt == nil {
		return false
	}
	return nowMs > *a.ExpiresAt-60_000
}

// Load 从配置里读一个服务的账号。没有返回 nil。
func Load(service string) *Account {
	c := config.Current()
	var raw json.RawMessage
	switch service {
	case "trakt":
		raw = c.SyncTrakt
	case "bangumi":
		raw = c.SyncBangumi
	default:
		return nil
	}
	if len(raw) == 0 {
		return nil
	}
	var a Account
	if json.Unmarshal(raw, &a) != nil || a.AccessToken == "" {
		return nil
	}
	a.Service = service
	return &a
}

// Save 落盘一个服务的账号。传 nil = 退出登录。
func Save(service string, a *Account) error {
	c := config.Current()
	var raw json.RawMessage
	if a != nil {
		b, err := json.Marshal(a)
		if err != nil {
			return err
		}
		raw = b
	}
	switch service {
	case "trakt":
		c.SyncTrakt = raw
	case "bangumi":
		c.SyncBangumi = raw
	}
	return c.Save()
}

// NowMs 当前 epoch 毫秒。
func NowMs() int64 { return time.Now().UnixMilli() }
