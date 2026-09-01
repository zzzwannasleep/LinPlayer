package plugin

import "testing"

func list(v ...string) []string { return v }

func grant(host string, http bool) SourceHostGrant {
	return SourceHostGrant{Host: host, AllowHTTP: http}
}

// ★★ 白名单是 fail-closed:**空 ≠ 放行**。
func TestHostAllowed_空白名单拒绝一切(t *testing.T) {
	if hostAllowed(nil, "www.example.com") {
		t.Fatal("空白名单放行了 —— fail-closed 破功")
	}
}

func TestHostAllowed_精确匹配且大小写不敏感(t *testing.T) {
	w := list("www.example.com")
	for _, h := range []string{"www.example.com", "WWW.EXAMPLE.COM"} {
		if !hostAllowed(w, h) {
			t.Fatalf("%s 应当命中", h)
		}
	}
	if hostAllowed(w, "example.com") {
		t.Fatal("裸主域不该被子域条目命中")
	}
}

// ★ 通配只认 `*.` 开头,而且必须点分隔 —— 否则 evil-example.com 会命中。
func TestHostAllowed_通配只匹配子域(t *testing.T) {
	w := list("*.example.com")
	for _, ok := range []string{"china-vod4.example.com", "a.b.example.com"} {
		if !hostAllowed(w, ok) {
			t.Fatalf("%s 应当命中", ok)
		}
	}
	for _, bad := range []string{"example.com", "evil-example.com", "example.com.evil.net"} {
		if hostAllowed(w, bad) {
			t.Fatalf("%s 不该命中", bad)
		}
	}
}

// ★★ 裸 `*` 若被当通配,**一个字符就把 fail-closed 击穿成放行全网**。
func TestHostAllowed_裸星号不是通配(t *testing.T) {
	if hostAllowed(list("*"), "attacker.com") || hostAllowed(list("*com"), "attacker.com") {
		t.Fatal("裸星号被当成了通配 —— 白名单等于没有")
	}
}

// ★★ 令牌**没声明**时,用户配了源也不该放行 —— 否则任何插件只要用户配过一个源
// 就能访问那台机器,而作者从没在 manifest 里申明过。
func TestCheckRequest_没声明令牌就不认用户配的源(t *testing.T) {
	g := []SourceHostGrant{grant("nas.lan", true)}
	if CheckRequest(list("api.example.com"), g, "https", "nas.lan") == nil {
		t.Fatal("没声明 $sourceServer 却放行了用户配的源")
	}
	if CheckRequest(nil, g, "https", "nas.lan") == nil {
		t.Fatal("空白名单 + 用户配了源,仍然不该放行")
	}
	if err := CheckRequest(list(TokenSourceServer), g, "https", "nas.lan"); err != nil {
		t.Fatalf("声明了令牌就该放行:%v", err)
	}
}

// ★ 没配任何源时令牌展开为空 = 拒绝一切。fail-closed 不能因为多了个令牌就破功。
func TestCheckRequest_令牌没展开时拒绝一切(t *testing.T) {
	w := list(TokenSourceServer)
	if CheckRequest(w, nil, "https", "anything.com") == nil ||
		CheckRequest(w, nil, "http", "nas.lan") == nil {
		t.Fatal("令牌没展开却放行了")
	}
}

// ★ 配了 A 服不等于能访问 B 服;令牌也不是通配,子域同样不放行。
func TestCheckRequest_令牌只对用户填的那台生效(t *testing.T) {
	w := list(TokenSourceServer)
	g := []SourceHostGrant{grant("a.example.com", false)}
	if err := CheckRequest(w, g, "https", "a.example.com"); err != nil {
		t.Fatalf("自己配的那台该通:%v", err)
	}
	for _, bad := range []string{"b.example.com", "sub.a.example.com"} {
		if CheckRequest(w, g, "https", bad) == nil {
			t.Fatalf("%s 不该放行", bad)
		}
	}
}

// ★★ 明文 http **只**对用户自己填过 http:// 的那个 origin 放行;
// manifest 里硬编码的域名永远 https-only。**这是整条设计的安全支点。**
func TestCheckRequest_明文只给用户亲手填的地址(t *testing.T) {
	w := list(TokenSourceServer, "cdn.example.com")
	g := []SourceHostGrant{grant("nas.lan", true), grant("secure.example.com", false)}

	if err := CheckRequest(w, g, "http", "nas.lan"); err != nil {
		t.Fatalf("局域网自建必须能用:%v", err)
	}
	if err := CheckRequest(w, g, "https", "nas.lan"); err != nil {
		t.Fatalf("升级到 https 当然也行:%v", err)
	}
	// 用户填的是 https 的源,插件不能偷偷降级成 http
	if err := CheckRequest(w, g, "http", "secure.example.com"); err == nil {
		t.Fatal("插件把用户填的 https 源降级成了 http")
	}
	// manifest 硬编码的域名不吃这套
	if err := CheckRequest(w, g, "https", "cdn.example.com"); err != nil {
		t.Fatalf("%v", err)
	}
	if CheckRequest(w, g, "http", "cdn.example.com") == nil {
		t.Fatal("硬编码域名必须 https")
	}
}

func TestCheckRequest_非http协议一律拒(t *testing.T) {
	w := list(TokenSourceServer)
	g := []SourceHostGrant{grant("nas.lan", true)}
	for _, s := range []string{"file", "ftp", "data", "javascript"} {
		if CheckRequest(w, g, s, "nas.lan") == nil {
			t.Fatalf("%s 不该被放行", s)
		}
	}
}

func TestGrantFromBaseURL(t *testing.T) {
	g, ok := GrantFromBaseURL("http://nas.lan:5244")
	if !ok || g != grant("nas.lan", true) {
		t.Fatalf("%#v %v", g, ok)
	}
	// 端口不参与匹配(白名单一贯按 host),host 要归一化成小写
	g, ok = GrantFromBaseURL("https://Alist.Example.COM:443/x")
	if !ok || g != grant("alist.example.com", false) {
		t.Fatalf("%#v %v", g, ok)
	}
	if _, ok := GrantFromBaseURL(""); ok {
		t.Fatal("空地址不该放行任何东西")
	}
}

// ★★ registry 决定「装哪个包」。明文 http 上被中间人改一行 packageUrl,
// 就等于让用户装上任意插件 —— 所以除本机外必须 https。
func TestCheckFetchURL_除本机外必须https(t *testing.T) {
	for _, ok := range []string{
		"https://example.com/registry.json",
		"http://127.0.0.1:8080/registry.json",
		"http://localhost/registry.json",
	} {
		if err := CheckFetchURL(ok); err != nil {
			t.Fatalf("%s 应当放行:%v", ok, err)
		}
	}
	for _, bad := range []string{
		"http://example.com/registry.json",
		// 靠子串判 loopback 会被这个骗过去
		"http://127.0.0.1.evil.com/r.json",
		"file:///etc/passwd",
		"不是 URL",
	} {
		if err := CheckFetchURL(bad); err == nil {
			t.Fatalf("%s 不该放行", bad)
		}
	}
}
