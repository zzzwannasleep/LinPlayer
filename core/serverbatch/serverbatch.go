// Package serverbatch 把「分享文本」和 `linplayer://` 深链解析成结构化账号块。
//
// 本包是**平台无关纯逻辑**:不碰配置存盘、不发网络请求、不弹确认框。
// 登录(逐线路试)/落盘/用户确认全归调用方(core/account)编排。
//
// 机场 / Emby 分享出来的开通信息通常长这样(一次可能包含多个账号块):
//
// ⚠️ 下面这段样例与测试夹具里的值**全部是编造的占位符**,不是真实账号。
//
//	仓库红线:任何真实域名 / 账号 / 密码都不许进版本控制 —— 包括「只是个测试夹具」。
//	改这段时保持**结构**不变即可(CJK 用户名 / 两个不同的密码字段 / 括号备注 /
//	带端口的 URL / 带路径的弹幕 URL),值随便编。
//
//	▎创建用户成功🎉
//	· 用户名称 | 示例用户
//	· 用户密码 | Ab3xKp9Q
//	· 安全密码 | 1234(仅发送一次)
//	· 到期时间 | 2026-06-30 23:34:28
//	主线路(可尝试直连)
//	https://line1.example.com:443
//	海外备用(国际优化 CDN)
//	https://cdn.example.net:443
//	弹幕 API
//	https://danmu.example.org/api-danmu
package serverbatch

import (
	"net/url"
	"regexp"
	"strings"
)

// Line 一条带名字的线路(服务器线路或弹幕线路通用)。
type Line struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

// Block 一个账号块:一台服务器(可能多线路) + 该账号的弹幕线路 + 用户名/密码。
//
// ★ 用户名和密码是指针:**「没有这个键」和「键在但是空串」是两件事**。
// 深链里 `?user=` 显式给空串意味着「链接缺用户名」,不能回落到文本里解出来的那个。
type Block struct {
	Username     *string `json:"username"`
	Password     *string `json:"password"`
	Lines        []Line  `json:"lines"`
	DanmakuLines []Line  `json:"danmaku_lines"`
}

// IsEmpty 一条线路都没有 = 这个块没用。
func (b *Block) IsEmpty() bool { return len(b.Lines) == 0 && len(b.DanmakuLines) == 0 }

// DeepLink 深链 `linplayer://add-server?...` 的解析结果。
//
// 比裸 Block 多一个 Name:那是链接里的 `?name=`(服务器显示名),登录后取不到
// Emby SystemInfo.serverName 时的回退名。丢了它 = 静默降级成用户名。
type DeepLink struct {
	Name  *string `json:"name"`
	Block Block   `json:"block"`
}

var (
	// 行内「标签 <分隔符> URL」。分隔符:`|` `:` `:`。
	reKVSameLineURL = regexp.MustCompile(`(?i)^(.{1,40}?)\s*[\|:：]\s*((?:https?://)\S+)`)
	// 行内「键 <分隔符> 值」(值不含 URL)。
	reKVField        = regexp.MustCompile(`^([^\|:：]{1,16})\s*[\|:：]\s*(.+)$`)
	reURL            = regexp.MustCompile(`(?i)https?://[^\s|，,\)）；;]+`)
	reLeadingBullets = regexp.MustCompile(`^[\s·•\-\*▎▍►>《　]+`)
	// 行首形如「创建用户成功」的块头。
	reBlockHeader   = regexp.MustCompile(`创建用户|【\s*服务器\s*】|账号信息|开通成功`)
	reParenNote     = regexp.MustCompile(`[（(].*$`)
	reTrailingPunct = regexp.MustCompile(`[，,。；;、\)）】\]]+$`)
)

var userKeys = []string{
	"用户名称", "用户名", "账户名", "账号名", "账户", "账号", "帐号", "用户",
	"username", "user", "account", "name",
}

var passKeys = []string{
	"用户密码", "登录密码", "登陆密码", "密码", "password", "passwd", "pwd", "pass",
}

// ignoreKeys 这些键即便带「密码 / 时间」字样也不是登录凭据,忽略。
//
// ★ 「安全密码」不忽略的话会被 passKeys 里的「密码」吃掉,而它常常排在
// 真密码后面 —— 表现是登录时用了一串一次性验证码,永远登不进去。
var ignoreKeys = []string{
	"安全密码", "安全密碼", "到期时间", "到期時間", "过期时间", "有效期", "expire",
	"expiry", "到期", "剩余", "当前线路", "当前線路",
}

func sptr(s string) *string { return &s }

// ParseShareText 解析整段分享文本为多个账号块。
func ParseShareText(text string) []Block {
	blocks := []Block{}
	var current Block
	var pendingLabel *string

	// 按 '\n' 切:CRLF 文本残留的 '\r' 由下面的 TrimSpace 吃掉。
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(reLeadingBullets.ReplaceAllString(raw, ""))
		if line == "" {
			continue
		}

		// 显式块头:开启新块。
		// ★ current 为空时**不跳过**,该行会掉到 ④ 变成 pendingLabel。
		if reBlockHeader.MatchString(line) && !current.IsEmpty() {
			flush(&blocks, &current, &pendingLabel)
			continue
		}

		// ① 同一行「标签: URL」
		if c := reKVSameLineURL.FindStringSubmatch(line); c != nil {
			label := strings.TrimSpace(c[1])
			// ★ 这里必须再用 reURL 收一次口:`\S+` 会把 "https://a.com,备注" 的
			//   ",备注" 也吞进 URL,而分支 ② 走 reURL 就不会 —— 同一段文本
			//   两种写法解出两个不同的 URL,那是最难查的一类不一致。
			rawURL := c[2]
			if m := reURL.FindString(c[2]); m != "" {
				rawURL = m
			}
			u := cleanURL(rawURL)
			lbl := pendingLabel
			if label != "" {
				lbl = &label
			}
			addURL(&current, lbl, u)
			pendingLabel = nil
			continue
		}

		// ② 行内直接含 URL(标签在上一行)
		if urls := reURL.FindAllString(line, -1); len(urls) > 0 {
			for _, u := range urls {
				addURL(&current, pendingLabel, cleanURL(u))
			}
			pendingLabel = nil
			continue
		}

		// ③ 无 URL:键值字段(用户名 / 密码)或纯标签。
		if c := reKVField.FindStringSubmatch(line); c != nil {
			key := strings.ToLower(strings.TrimSpace(c[1]))
			value := strings.TrimSpace(c[2])
			label := strings.TrimSpace(c[1])
			if matchesAny(key, ignoreKeys) {
				continue
			}
			// ★★ **先判密码**:「用户密码」同时含「用户」和「密码」字样,
			//   先判用户名的话它会被用户名那条吞掉 —— 表现是用户名变成了密码,
			//   而且看起来像是分享文本自己写错了。
			if matchesAny(key, passKeys) {
				if current.Password == nil {
					current.Password = sptr(stripNote(value))
				}
				continue
			}
			if matchesAny(key, userKeys) {
				// 新用户名 → 当前块已有内容就开新块(一段文本里多个账号)。
				if current.Username != nil || len(current.Lines) > 0 || len(current.DanmakuLines) > 0 {
					flush(&blocks, &current, &pendingLabel)
				}
				current.Username = sptr(stripNote(value))
				continue
			}
			// 未知键值 → 当作标签(键名)。
			pendingLabel = &label
			continue
		}

		// ④ 纯文本行 → 作为下一条 URL 的标签(取最靠近 URL 的那一行)。
		l := line
		pendingLabel = &l
	}
	flush(&blocks, &current, &pendingLabel)

	out := blocks[:0]
	for _, b := range blocks {
		if !b.IsEmpty() {
			out = append(out, b)
		}
	}
	return out
}

func flush(blocks *[]Block, current *Block, pending **string) {
	done := *current
	*current = Block{}
	if !done.IsEmpty() || done.Username != nil {
		*blocks = append(*blocks, done)
	}
	*pending = nil
}

func addURL(b *Block, label *string, u string) {
	if u == "" {
		return
	}
	name := ""
	if label != nil && *label != "" {
		name = stripNote(*label)
	} else {
		name = hostOf(u)
	}
	isDanmaku := looksDanmaku(label) || looksDanmaku(&u)
	target := &b.Lines
	if isDanmaku {
		target = &b.DanmakuLines
	}
	for _, l := range *target {
		if l.URL == u {
			return // 去重
		}
	}
	*target = append(*target, Line{Name: name, URL: u})
}

func looksDanmaku(s *string) bool {
	if s == nil {
		return false
	}
	t := strings.ToLower(*s)
	return strings.Contains(t, "danmu") || strings.Contains(t, "danmaku") || strings.Contains(t, "弹幕")
}

// matchesAny key 已小写。判的是**包含**不是相等:分享文本里的键名前后常带修饰字。
func matchesAny(key string, keys []string) bool {
	for _, k := range keys {
		if strings.Contains(key, strings.ToLower(k)) {
			return true
		}
	}
	return false
}

// stripNote 去掉值里的括号备注,如 "1234(仅发送一次)" → "1234"。
func stripNote(v string) string {
	return strings.TrimSpace(reParenNote.ReplaceAllString(strings.TrimSpace(v), ""))
}

func cleanURL(u string) string {
	return reTrailingPunct.ReplaceAllString(strings.TrimSpace(u), "")
}

func hostOf(raw string) string {
	if u, err := url.Parse(raw); err == nil && u.Hostname() != "" {
		return u.Hostname()
	}
	return "线路"
}

// NormalizeURL 规范化服务器地址:缺协议时补 https://。
func NormalizeURL(raw string) string {
	u := strings.TrimSpace(raw)
	if u == "" {
		return ""
	}
	lower := strings.ToLower(u)
	if strings.HasPrefix(lower, "http://") || strings.HasPrefix(lower, "https://") {
		return u
	}
	return "https://" + u
}

// BuildIconURL 服务器图标地址。
//
// ★ 优先用**登录用户的头像**:很多 Emby 服把品牌 logo 直接设成用户头像,
// 且用户头像在 Emby 是公开资源(登录选人界面免登录就显示),不需要 api_key。
// 该用户没头像时退回 `/web/touchicon.png`;两者都取不到由 UI 回退内置图标。
func BuildIconURL(baseURL, userID, primaryImageTag string) string {
	b := strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if userID != "" && primaryImageTag != "" {
		return b + "/Users/" + userID + "/Images/Primary?tag=" + primaryImageTag
	}
	return b + "/web/touchicon.png"
}

// ---------- 深链 ----------

// queryParams 深链查询串。
//
// ★ 重复键取**最后一个**(`last`),取全部用 `all`。别改成第一个:
// `?user=a&user=b` 在旧栈里一直是后者胜,换掉会让老链接解出不同的账号。
type queryParams struct{ pairs [][2]string }

func newQuery(u *url.URL) queryParams {
	var q queryParams
	// ★ 自己切,不用 url.Values:Values 是 map,**丢掉了键的出现顺序**,
	//   而「重复键取最后一个」正好要靠顺序。
	for _, kv := range strings.Split(u.RawQuery, "&") {
		if kv == "" {
			continue
		}
		k, v, _ := strings.Cut(kv, "=")
		dk, err1 := url.QueryUnescape(k)
		dv, err2 := url.QueryUnescape(v)
		if err1 != nil || err2 != nil {
			continue
		}
		q.pairs = append(q.pairs, [2]string{dk, dv})
	}
	return q
}

func (q queryParams) last(k string) *string {
	for i := len(q.pairs) - 1; i >= 0; i-- {
		if q.pairs[i][0] == k {
			v := q.pairs[i][1]
			return &v
		}
	}
	return nil
}

func (q queryParams) all(k string) []string {
	var out []string
	for _, p := range q.pairs {
		if p[0] == k {
			out = append(out, p[1])
		}
	}
	return out
}

// deepLinkTarget 认链:scheme 必须是 linplayer,host 或 path 命中 want。
func deepLinkTarget(raw, want string) (queryParams, bool) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "linplayer" {
		return queryParams{}, false
	}
	// ★ 非特殊 scheme 的 host 不会被自动小写化,这里补上 —— 不补的话
	//   `linplayer://Add-Server?...` 会被判成不认识的链接,而且一声不吭。
	host := strings.ToLower(u.Host)
	if host != want && !strings.Contains(u.Path, want) {
		return queryParams{}, false
	}
	return newQuery(u), true
}

// ParseDeepLink 解析 `linplayer://add-server?...`。
//
// 形式一(结构化):`?name=&user=&pwd=&line=&line=&danmaku=`
// 形式二(整段分享文本):`?text=<urlencoded>`,此时仍可用 `?user=`/`?pwd=`
// 覆盖文本里解出的凭据。
//
// 返回 nil = 不是本 App 的 add-server 链接 / 链接里没有任何可用线路。
//
// ★★ **返回非 nil ≠ 可以直接登录**。深链可能来自任何网页或聊天窗口,
// 调用方必须先弹确认框(展示 host / 用户名 / 弹幕源数量 + 明文 HTTP 警告),
// 用户点了头才登录、添加、设为当前。
func ParseDeepLink(raw string) *DeepLink {
	q, ok := deepLinkTarget(raw, "add-server")
	if !ok {
		return nil
	}
	block := blockFromQuery(q)
	if block == nil || block.IsEmpty() {
		return nil
	}
	// 查询参数优先于 text 里解析出来的凭据。
	if u := q.last("user"); u != nil {
		block.Username = sptr(strings.TrimSpace(*u))
	}
	if p := q.last("pwd"); p != nil {
		// ★ 密码**不 trim**:可能真的含空格。
		block.Password = p
	}
	return &DeepLink{Name: q.last("name"), Block: *block}
}

// ParseBangumiCode 解析 `linplayer://sync-bangumi?code=...`。
//
// ★ 同样不可信:调用方必须先弹确认框再拿去换令牌 ——
// 否则一个网页就能把用户绑到攻击者的 Bangumi 账号上。
func ParseBangumiCode(raw string) string {
	q, ok := deepLinkTarget(raw, "sync-bangumi")
	if !ok {
		return ""
	}
	c := q.last("code")
	if c == nil {
		return ""
	}
	return strings.TrimSpace(*c)
}

// blockFromQuery 优先用结构化参数,否则回退解析 `text` 整段分享文本。
func blockFromQuery(q queryParams) *Block {
	if t := q.last("text"); t != nil && strings.TrimSpace(*t) != "" {
		bs := ParseShareText(*t)
		if len(bs) == 0 {
			return nil
		}
		return &bs[0]
	}
	lineURLs, danmakuURLs := q.all("line"), q.all("danmaku")
	if len(lineURLs) == 0 && len(danmakuURLs) == 0 {
		return nil
	}
	b := &Block{Username: q.last("user"), Password: q.last("pwd")}
	for _, u := range lineURLs {
		if u = strings.TrimSpace(u); u != "" {
			b.Lines = append(b.Lines, Line{Name: hostOf(NormalizeURL(u)), URL: u})
		}
	}
	for _, u := range danmakuURLs {
		if u = strings.TrimSpace(u); u != "" {
			b.DanmakuLines = append(b.DanmakuLines, Line{Name: "弹幕", URL: u})
		}
	}
	return b
}
