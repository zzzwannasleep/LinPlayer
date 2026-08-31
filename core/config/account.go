package config

// 服务器账号。移植自 `crates/core/src/config.rs`(ServerLine / Account / merge_lines
// 以及 AppConfig 上那几个账号方法)。**Rust 版是黄金实现。**

import (
	"encoding/json"
	"errors"
	"strings"

	"linplayer/core/net/cf"
)

// ServerLine 一条备用线路(同一服务器的不同入口:直连 / CDN / 内网)。
type ServerLine struct {
	ID     string  `json:"id"`
	Name   string  `json:"name"`
	URL    string  `json:"url"`
	Remark *string `json:"remark"`
}

// Account 一个已登录的服务器账号。
//
// ★ **统一承载 Emby 与浏览型源**(靠 source_kind 区分)—— 旧栈只有一张服务器表,
// 新栈也只能有一张。身份键是 `server`(归一化后不带尾斜杠):三端既有的
// `server_id` 参数就是它,**别换**。
//
// ★ 没接的字段(source_kind / source / 以后新加的)走 `rest` **原样透传**。
// 丢了的表现是「升级之后我配的网盘源没了」,而且不报错。
type Account struct {
	Server   string `json:"server"` // 归一化后不带尾斜杠
	Token    string `json:"token"`
	UserID   string `json:"user_id"`
	UserName string `json:"user_name"`

	// 显示名;空则由 DisplayName() 回落到 host。
	Name    string  `json:"name"`
	Remark  *string `json:"remark"`
	IconURL *string `json:"icon_url"`
	// 登录密码(可选)。重新登录的场景 + 插件 emby.credentials 权限要用。
	Password *string `json:"password"`

	// 备用线路;空表示只用 server 本身。
	Lines      []ServerLine `json:"lines"`
	ActiveLine int          `json:"active_line"`

	// 是否信任该服务器的自签名 / 无效 TLS 证书(不安全)。默认 false = 严格校验。
	// **仅对本服务器主机放行**,不影响更新下载 / WebDAV / 其它主机。
	AllowInsecureTLS bool `json:"allow_insecure_tls"`

	// rest 是这条账号里我们还没接的键(source_kind / source / …)。
	// ★ 一定要有:少了它,一次保存就把用户配的网盘源抹掉。
	rest map[string]json.RawMessage
}

// 这几个键由上面的强类型字段负责,不进 rest(否则保存时会双写)。
var accountTypedKeys = map[string]bool{
	"server": true, "token": true, "user_id": true, "user_name": true,
	"name": true, "remark": true, "icon_url": true, "password": true,
	"lines": true, "active_line": true, "allow_insecure_tls": true,
}

// UnmarshalJSON 解强类型字段,同时把其余键原样兜住。
func (a *Account) UnmarshalJSON(b []byte) error {
	type plain Account // 避免递归
	var p plain
	if err := json.Unmarshal(b, &p); err != nil {
		return err
	}
	*a = Account(p)
	raw := map[string]json.RawMessage{}
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	a.rest = map[string]json.RawMessage{}
	for k, v := range raw {
		if !accountTypedKeys[k] {
			a.rest[k] = v
		}
	}
	return nil
}

// MarshalJSON 把强类型字段和没接的键合回一个对象。
func (a Account) MarshalJSON() ([]byte, error) {
	type plain Account
	b, err := json.Marshal(plain(a))
	if err != nil {
		return nil, err
	}
	out := map[string]json.RawMessage{}
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, err
	}
	for k, v := range a.rest {
		if _, taken := out[k]; !taken {
			out[k] = v
		}
	}
	return json.Marshal(out)
}

// SourceKind 这个账号的源类型。
//
// ★ **线上一律小写**(`emby` / `quark` / `smb` / `plugin:<id>/<源id>`)。
// 前端曾整套写成首字母大写:每处比较恒 false、登录送错值,**两边都不报错**。
// 空 = emby(默认值就是它,老配置里根本没有这个键)。
func (a Account) SourceKind() string {
	v, ok := a.rest["source_kind"]
	if !ok {
		return "emby"
	}
	var s string
	if json.Unmarshal(v, &s) != nil || strings.TrimSpace(s) == "" {
		return "emby"
	}
	return s
}

// RestValue 取一个「还没接强类型」的键的原始 JSON。没有返回 nil。
//
// ★ 给命令层读 `source` 这类整块结构用。**不要**因此把 rest 变成公共读写口 ——
// 强类型字段永远优先,rest 只是「我们还没接的那部分」。
func (a Account) RestValue(key string) json.RawMessage {
	if a.rest == nil {
		return nil
	}
	return a.rest[key]
}

// SetRestValue 写一个还没接强类型的键。v 会被序列化成 JSON。
//
// ★ 写进 rest 而不是加字段:加字段就要同步 accountTypedKeys、三端绑定、
// 差分对账口径 —— 而这些键(source / source_kind)在迁移完成前形状还会变。
func (a *Account) SetRestValue(key string, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	if a.rest == nil {
		a.rest = map[string]json.RawMessage{}
	}
	a.rest[key] = b
}

// IsFileBrowse 是不是浏览型源(网盘 / 局域网 / 资源站)。
func (a Account) IsFileBrowse() bool { return a.SourceKind() != "emby" }

// DirectLineURL 当前生效的线路地址(原始上游)。
//
// ★ 越界下标**钳回合法区间**,不 panic —— 线路表被外部改短过。
func (a Account) DirectLineURL() string {
	if len(a.Lines) == 0 {
		return a.Server
	}
	i := a.ActiveLine
	if i >= len(a.Lines) {
		i = len(a.Lines) - 1
	}
	if i < 0 {
		i = 0
	}
	return a.Lines[i].URL
}

// ActiveLineURL 当前生效的线路地址。**会被线路优选反代改写**。
//
// ★★ 这是线路优选的**唯一 choke point** —— 取基址一律走这里,
// 新增取流路径绕开它就会出现「API 走优选、取流仍走原线」这种一半生效的静默故障。
//
// ★★ 查表用的是 **DirectLineURL()(当前那条线)**,不是 a.Server(整台服)。
// 按服务器查等于把这台服的每条线都劫持到同一个反代上,而反代的上游 host 是开启时
// 那条线定死的 —— 切到没走优选的线路后,请求会被送去「A 线的域名 + 钉死的 IP」,
// **连得上但拿不到数据,且不报错**。
func (a Account) ActiveLineURL() string {
	direct := a.DirectLineURL()
	if local := cf.LocalURLFor(direct); local != "" {
		return local
	}
	return direct
}

// DisplayName 显示名:优先用户起的名,否则回落 host,再否则整个 URL。
func (a Account) DisplayName() string {
	if strings.TrimSpace(a.Name) != "" {
		return a.Name
	}
	_, after, ok := strings.Cut(a.Server, "://")
	if !ok {
		return a.Server
	}
	host, _, _ := strings.Cut(after, "/")
	if host == "" {
		return a.Server
	}
	return host
}

// NormLineURL 线路 url 归一化(去空白 + 去尾斜杠)。
//
// ★ **去重必须用它**:服主表里写 `https://a.com/`、用户手填 `https://a.com`,
// 不归一化就会重复加一条,每点一次「同步线路」表就长一截。
func NormLineURL(u string) string {
	return strings.TrimRight(strings.TrimSpace(u), "/")
}

// RemoteLine 服主下发的一条线路(对应 Emby 侧的 ExtDomain)。
type RemoteLine struct {
	Name string
	URL  string
}

// MergeLines 把服主下发的线路并入账号的线路表,返回**新增**条数。
//
// # 只增不删
//
// 用户手填的内网 / 自建线路服主表里没有,整表覆写等于删用户配置 ——
// 而他多半正是在「线路连不上」时点的同步。
//
// # active_line 跟着 url 走,不跟着下标走
//
// active_line 是**下标**。空表时 DirectLineURL 回落 server 本身,一旦同步进来 N 条,
// 下标 0 就从「server」变成了「服主的第一条线路」—— 用户点个同步,生效线路被悄悄换掉。
// 所以:合并前先记下当前生效的 url,合并后按 url 找回下标。
func MergeLines(a *Account, remote []RemoteLine) int {
	// ★ 先记住「现在实际在用哪个地址」。空表时它是 server 本身,不是任何一条 lines。
	activeURL := NormLineURL(a.DirectLineURL())

	/* 表为空 = 一直在用 server 裸地址。必须先把它显式落成第一条线路,
	   否则同步完 lines[0] 变成服主的线路,用户原来那条就从表里消失了。 */
	if len(a.Lines) == 0 {
		a.Lines = append(a.Lines, ServerLine{ID: "origin", Name: "主线", URL: a.Server})
	}

	added := 0
	for _, d := range remote {
		u := NormLineURL(d.URL)
		if u == "" || hasLine(a.Lines, u) {
			continue // 已有,跳过(名字以本地为准:用户可能改过备注)
		}
		name := strings.TrimSpace(d.Name)
		if name == "" {
			name = u
		}
		remark := "服务器下发"
		a.Lines = append(a.Lines, ServerLine{
			// id 用 url 而非序号:序号会随表变动,url 是这条线路的天然身份
			ID: u, Name: name, URL: strings.TrimSpace(d.URL), Remark: &remark,
		})
		added++
	}

	// 按 url 找回原来那条的下标;找不到(理论上不会)就保守钳回合法区间
	a.ActiveLine = len(a.Lines) - 1
	if a.ActiveLine < 0 {
		a.ActiveLine = 0
	}
	for i, l := range a.Lines {
		if NormLineURL(l.URL) == activeURL {
			a.ActiveLine = i
			break
		}
	}
	return added
}

func hasLine(lines []ServerLine, normURL string) bool {
	for _, l := range lines {
		if NormLineURL(l.URL) == normURL {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------- AppConfig 上的账号操作

// ErrIndexOOB 排序下标越界。
var ErrIndexOOB = errors.New("排序下标越界")

// ActiveAccount 当前活跃账号。没有则 nil。
func (c *AppConfig) ActiveAccount() *Account {
	if c.Active == nil || *c.Active < 0 || *c.Active >= len(c.AccountList) {
		return nil
	}
	return &c.AccountList[*c.Active]
}

// Find 按 server 找账号。
func (c *AppConfig) Find(serverID string) *Account {
	for i := range c.AccountList {
		if c.AccountList[i].Server == serverID {
			return &c.AccountList[i]
		}
	}
	return nil
}

// Upsert 按 server 去重写入(同服重登刷新 token),并设为活跃账号。
//
// ★ 重登**保留用户侧编辑**(名称 / 备注 / 图标 / 线路 / TLS 开关)——
// 那些不该被一次登录冲掉。用户改过的服务器名在重新登录后变回默认,
// 是那种「说不上哪里不对但就是不对」的退步。
func (c *AppConfig) Upsert(acc Account) {
	for i := range c.AccountList {
		if c.AccountList[i].Server != acc.Server {
			continue
		}
		old := c.AccountList[i]
		merged := acc
		if merged.Name == "" {
			merged.Name = old.Name
		}
		if merged.Remark == nil {
			merged.Remark = old.Remark
		}
		if merged.IconURL == nil {
			merged.IconURL = old.IconURL
		}
		if len(merged.Lines) == 0 {
			merged.Lines = old.Lines
		}
		merged.ActiveLine = old.ActiveLine
		merged.AllowInsecureTLS = old.AllowInsecureTLS
		// 没接的键也以旧的为准 —— 一次 Emby 重登不该把网盘源的凭据冲掉
		if len(merged.rest) == 0 {
			merged.rest = old.rest
		}
		c.AccountList[i] = merged
		c.setActive(i)
		return
	}
	c.AccountList = append(c.AccountList, acc)
	c.setActive(len(c.AccountList) - 1)
}

func (c *AppConfig) setActive(i int) { c.Active = &i }

// SetActive 把第 i 个账号设为活跃。下标由调用方保证合法。
func (c *AppConfig) SetActive(i int) { c.setActive(i) }

// Reorder 拖拽排序。
//
// ★ 移动后按 server 修正 active 下标,让活跃账号**跟着走**而不是指向别人。
func (c *AppConfig) Reorder(from, to int) error {
	n := len(c.AccountList)
	if from < 0 || to < 0 || from >= n || to >= n {
		return ErrIndexOOB
	}
	var activeServer string
	if a := c.ActiveAccount(); a != nil {
		activeServer = a.Server
	}
	acc := c.AccountList[from]
	rest := append(c.AccountList[:from:from], c.AccountList[from+1:]...)
	c.AccountList = append(rest[:to:to], append([]Account{acc}, rest[to:]...)...)
	if activeServer != "" {
		for i := range c.AccountList {
			if c.AccountList[i].Server == activeServer {
				c.setActive(i)
				return nil
			}
		}
	}
	return nil
}

// Remove 删账号。活跃账号被删则回落到第一个(空表则清空活跃)。
func (c *AppConfig) Remove(serverID string) bool {
	idx := -1
	for i := range c.AccountList {
		if c.AccountList[i].Server == serverID {
			idx = i
			break
		}
	}
	if idx < 0 {
		return false
	}
	wasActive := c.Active != nil && *c.Active == idx
	var activeServer string
	if a := c.ActiveAccount(); a != nil {
		activeServer = a.Server
	}
	c.AccountList = append(c.AccountList[:idx], c.AccountList[idx+1:]...)

	// ★ 按服务器存的开关要跟着账号走。留着的话,重新加同一地址的服会「自己就开着」——
	//   用户没开过多线程加载,它却是开的,而且没有任何地方解释为什么。
	if p := c.PrefsOf(); len(p.PrefetchServers) > 0 {
		kept := p.PrefetchServers[:0]
		for _, s := range p.PrefetchServers {
			if s != serverID {
				kept = append(kept, s)
			}
		}
		p.PrefetchServers = kept
		_ = c.SetPrefs(p)
	}

	switch {
	case len(c.AccountList) == 0:
		c.Active = nil
	case wasActive:
		c.setActive(0)
	default:
		// 删的是别人:**靠 server 重新定位**,别让下标漂移串台
		c.setActive(0)
		for i := range c.AccountList {
			if c.AccountList[i].Server == activeServer {
				c.setActive(i)
				break
			}
		}
	}
	return true
}

// InsecureHosts 「允许自签名」的账号 host(含它们的每一条线路)。
//
// ★ 一个账号可能配多条线路,每条都可能是不同 host,**得全放进去**。
// 漏了的后果是用户勾了「允许自签名」却连不上、或取消了勾选却还在放行,两头都不响。
//
// ponytail: Rust 版把它挂在 load/save 上自动同步。Go 侧的 HTTP 层还没有这个白名单,
// 先只把值算出来 —— 接 net 层时**必须**同样挂在每条改账号的路径末尾,否则会漏。
func (c *AppConfig) InsecureHosts() []string {
	var out []string
	for _, a := range c.AccountList {
		if !a.AllowInsecureTLS {
			continue
		}
		out = append(out, a.Server)
		for _, l := range a.Lines {
			out = append(out, l.URL)
		}
	}
	return out
}
