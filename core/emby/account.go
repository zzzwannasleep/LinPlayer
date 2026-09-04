package emby

// 登录 / 登出 / 收藏 / 已看 / 管理员动作。
//
// 注释是从那边逐字搬来的。

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
)

// ClientName 是 X-Emby-Authorization 里的 Client 字段。
// ★ 用真实应用标识 —— 服主在会话列表里按它认客户端,改名等于换了个客户端。
const ClientName = "LinPlayer"

// deviceName 本机设备名(X-Emby-Authorization 的 Device 字段)。
func deviceName() string {
	for _, k := range []string{"COMPUTERNAME", "HOSTNAME"} {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	return "PC"
}

// authHeader 组 X-Emby-Authorization。DeviceId 用**持久化**的设备 ID:
// 每次换一个的话服务器的「设备」列表会被我们刷满,而且续播会话对不上。
func (c *Client) authHeader(deviceID string) string {
	return fmt.Sprintf(`MediaBrowser Client="%s", Device="%s", DeviceId="%s", Version="%s"`,
		ClientName, deviceName(), deviceID, c.Version)
}

// LoginResult 登录成功后交给调用方存进配置的那份。
type LoginResult struct {
	Server   string `json:"server"`
	Token    string `json:"token"`
	UserID   string `json:"user_id"`
	UserName string `json:"user_name"`
	// 登录用户的头像 tag(建服务器图标用)。无头像则 nil。
	// ★ 很多 Emby 服把品牌 logo 设成用户头像,服务器图标优先用它;
	//   不解这个字段的话图标只能退 /web/touchicon.png —— 能用,但悄悄降级。
	PrimaryImageTag *string `json:"primary_image_tag"`
}

// NormServer 归一化服务器地址:去空白 + 去尾斜杠。
//
// ★ 尾斜杠不去掉的话后面每一处 `server + "/Users/..."` 都会拼出 `//Users`。
// 大多数反代能忍,**有的会 404**,而且只在那台上出问题 —— 最难查的那类。
func NormServer(server string) string {
	return strings.TrimRight(strings.TrimSpace(server), "/")
}

// Login 用户名密码登录。
func (c *Client) Login(ctx context.Context, server, username, password, deviceID string) (*Session, *LoginResult, error) {
	server = NormServer(server)
	body, _ := json.Marshal(map[string]string{"Username": username, "Pw": password})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		server+"/Users/AuthenticateByName", bytes.NewReader(body))
	if err != nil {
		return nil, nil, fmt.Errorf("请求构造失败: %w", err)
	}
	req.Header.Set("X-Emby-Authorization", c.authHeader(deviceID))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", c.UA)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, nil, fmt.Errorf("网络错误: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// ★ 带上状态码,别只留一句话 —— 命令层要靠它把「密码不对」和「没网」分开
		return nil, nil, &StatusError{Status: resp.StatusCode, What: "登录"}
	}
	var auth struct {
		AccessToken string `json:"AccessToken"`
		User        struct {
			ID              string  `json:"Id"`
			Name            string  `json:"Name"`
			PrimaryImageTag *string `json:"PrimaryImageTag"`
		} `json:"User"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&auth); err != nil {
		return nil, nil, fmt.Errorf("解析失败: %w", err)
	}
	s := &Session{Server: server, Token: auth.AccessToken, UserID: auth.User.ID, DeviceID: deviceID}
	return s, &LoginResult{
		Server:          server,
		Token:           auth.AccessToken,
		UserID:          auth.User.ID,
		UserName:        auth.User.Name,
		PrimaryImageTag: auth.User.PrimaryImageTag,
	}, nil
}

// Logout 服务端登出。
//
// ★ **尽力而为**:实测某 fork 该端点 404 且 token 登出后仍可用,
// 所以**不能**让它的失败挡住本地删账号 —— 调用方忽略返回值即可。
func (c *Client) Logout(ctx context.Context, s *Session) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.Server+"/Sessions/Logout", nil)
	if err != nil {
		return fmt.Errorf("请求构造失败: %w", err)
	}
	req.Header.Set("X-Emby-Token", s.Token)
	req.Header.Set("X-Emby-Authorization", c.authHeader(s.DeviceID))
	req.Header.Set("User-Agent", c.UA)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("网络错误: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("登出失败: HTTP %d", resp.StatusCode)
	}
	return nil
}

// toggle 是「POST 开 / DELETE 关」这一对端点的共用发送。
// 收藏和已看在 Emby 里是同一个形状,只有路径段不同。
func (c *Client) toggle(ctx context.Context, s *Session, u string, on bool) error {
	method := http.MethodDelete
	if on {
		method = http.MethodPost
	}
	req, err := http.NewRequestWithContext(ctx, method, u, nil)
	if err != nil {
		return fmt.Errorf("请求构造失败: %w", err)
	}
	req.Header.Set("X-Emby-Token", s.Token)
	req.Header.Set("User-Agent", c.UA)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("网络错误: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("请求失败: HTTP %d", resp.StatusCode)
	}
	return nil
}

// SetFavorite 收藏 / 取消收藏。
func (c *Client) SetFavorite(ctx context.Context, s *Session, itemID string, fav bool) error {
	return c.toggle(ctx, s, fmt.Sprintf("%s/Users/%s/FavoriteItems/%s",
		s.Server, url.PathEscape(s.UserID), url.PathEscape(itemID)), fav)
}

// SetPlayed 标记已看 / 未看。
func (c *Client) SetPlayed(ctx context.Context, s *Session, itemID string, played bool) error {
	return c.toggle(ctx, s, fmt.Sprintf("%s/Users/%s/PlayedItems/%s",
		s.Server, url.PathEscape(s.UserID), url.PathEscape(itemID)), played)
}

/* ---------------- 管理员(admin)动作 ----------------
   对标 Emby web。名字容易混,这里把每一项打的**真实端点**钉死:

     刷新媒体库  → POST /Items/{id}/Refresh  Default 模式(只补缺失,不覆盖已有)
     扫描媒体库  → POST /Library/Refresh     整台服务器找新文件(Emby 的「扫描所有媒体库」)
     刷新元数据  → POST /Items/{id}/Refresh  FullRefresh + ReplaceAllMetadata(强制重刮)

   所以前两项**不是**一回事:一个作用于选中的库/条目,一个作用于整台服务器。 */

// IsAdmin 当前登录用户是不是管理员。
//
// ★ **不从登录响应里取**:配置里存下来的老账号根本不会再走一次 login,
// 那样升级后老账号会永远判成非管理员(菜单静默不出现,还以为是权限没给)。
func (c *Client) IsAdmin(ctx context.Context, s *Session) (bool, error) {
	b, err := c.getBytes(ctx, s, fmt.Sprintf("%s/Users/%s", s.Server, url.PathEscape(s.UserID)))
	if err != nil {
		return false, err
	}
	var j map[string]any
	if err := json.Unmarshal(b, &j); err != nil {
		return false, fmt.Errorf("解析失败: %w", err)
	}
	return adminFlag(j), nil
}

// adminFlag 从 /Users/{id} 响应里读管理员位。
// ★ 缺 Policy / 缺字段一律判**否** —— 宁可少给按钮。
func adminFlag(user map[string]any) bool {
	p, _ := user["Policy"].(map[string]any)
	if p == nil {
		return false
	}
	v, _ := p["IsAdministrator"].(bool)
	return v
}

// RefreshItem 刷新某个库/条目。full=false 只补缺失,full=true 强制重刮(替换已有元数据)。
//
// ★ Recursive=true:对库卡片来说不递归**等于什么都没做**(库本身没有元数据可刮)。
// ★ ReplaceAllImages 恒 false —— 用户自己换过的封面不该被一次「刷新元数据」抹掉。
func (c *Client) RefreshItem(ctx context.Context, s *Session, itemID string, full bool) error {
	return c.postAdmin(ctx, s, refreshURL(s.Server, itemID, full))
}

func refreshURL(server, itemID string, full bool) string {
	mode := "Default"
	if full {
		mode = "FullRefresh"
	}
	return fmt.Sprintf("%s/Items/%s/Refresh?Recursive=true&MetadataRefreshMode=%s&ImageRefreshMode=%s&ReplaceAllMetadata=%t&ReplaceAllImages=false",
		server, url.PathEscape(itemID), mode, mode, full)
}

// ScanAllLibraries 扫描整台服务器的媒体库文件(Emby web 的「扫描所有媒体库」)。
func (c *Client) ScanAllLibraries(ctx context.Context, s *Session) error {
	return c.postAdmin(ctx, s, s.Server+"/Library/Refresh")
}

func (c *Client) postAdmin(ctx context.Context, s *Session, u string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, nil)
	if err != nil {
		return fmt.Errorf("请求构造失败: %w", err)
	}
	req.Header.Set("X-Emby-Token", s.Token)
	// 无 body 的 POST,少了这个有的反代直接 411
	req.Header.Set("Content-Length", "0")
	req.Header.Set("User-Agent", c.UA)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("网络错误: %w", err)
	}
	defer resp.Body.Close()
	// 403 = 服务端说你不是管理员。菜单本不该出现,出现了就把真话说出来。
	if resp.StatusCode == 403 {
		return fmt.Errorf("服务器拒绝:当前账号没有管理员权限")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("请求失败: HTTP %d", resp.StatusCode)
	}
	return nil
}
