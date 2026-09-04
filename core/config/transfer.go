package config

//
// 设备间「扫码搬配置」。
// 复用 Richasy/Rodel 的 CommonConfig 容器:每个账号 snake_case JSON 各自
// AES-256-CBC/PKCS7 加密成 base64,装进 `{from,version,export_time,configs[],_key}`;
// 容器带 `_key` → 任意实现本格式的客户端免密可解。再 gzip + base64url 塞进
// 二维码,前缀 `LPSYNC1:` —— **全程离线,断网也能扫**。
//
// ★ 安全口径是**混淆级**:密钥随载荷分发,挡的是随手读明文凭据,
// 不防「提取密钥后解密」—— 那是离线免密的固有取舍,别当成加密。

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

const (
	transferPrefix  = "LPSYNC1:"
	transferClient  = "LinPlayer"
	transferVersion = "1.0"
)

// builtinKey LinPlayer 内置默认密钥(32B)。
//
// ★★ 必须与 Dart / Rust 侧 **逐字节一致** —— 差一个字节,老设备导出的码
// 新设备就扫不出来,而报的是「载荷 JSON 非法」这种指不到根因的话。
var builtinKey = [32]byte{
	0x4c, 0x69, 0x6e, 0x50, 0x6c, 0x61, 0x79, 0x65, // "LinPlaye"
	0x72, 0x2d, 0x63, 0x6f, 0x6d, 0x6d, 0x6f, 0x6e, // "r-common"
	0x2d, 0x63, 0x6f, 0x6e, 0x66, 0x69, 0x67, 0x2d, // "-config-"
	0x6b, 0x65, 0x79, 0x2d, 0x76, 0x31, 0x21, 0x00, // "key-v1!\0"
}

// pkcs7Pad / pkcs7Unpad —— IV 取密钥前 16 字节(Richasy 的约定)。
func pkcs7Pad(b []byte) []byte {
	n := aes.BlockSize - len(b)%aes.BlockSize
	return append(b, bytes.Repeat([]byte{byte(n)}, n)...)
}

func pkcs7Unpad(b []byte) ([]byte, bool) {
	if len(b) == 0 || len(b)%aes.BlockSize != 0 {
		return nil, false
	}
	n := int(b[len(b)-1])
	if n == 0 || n > aes.BlockSize || n > len(b) {
		return nil, false
	}
	// ★ **每一个**填充字节都要校验:只看最后一个的话,随便一段乱码有 1/16
	//   的概率被当成合法明文,解出来的是垃圾账号。
	for _, c := range b[len(b)-n:] {
		if int(c) != n {
			return nil, false
		}
	}
	return b[:len(b)-n], true
}

func encryptConfig(plain string, key [32]byte) string {
	blk, err := aes.NewCipher(key[:])
	if err != nil {
		return ""
	}
	src := pkcs7Pad([]byte(plain))
	dst := make([]byte, len(src))
	cipher.NewCBCEncrypter(blk, key[:16]).CryptBlocks(dst, src)
	return base64.StdEncoding.EncodeToString(dst)
}

func decryptConfig(s string, key [32]byte) (string, bool) {
	ct, err := base64.StdEncoding.DecodeString(strings.TrimSpace(s))
	if err != nil || len(ct) == 0 || len(ct)%aes.BlockSize != 0 {
		return "", false
	}
	blk, err := aes.NewCipher(key[:])
	if err != nil {
		return "", false
	}
	pt := make([]byte, len(ct))
	cipher.NewCBCDecrypter(blk, key[:16]).CryptBlocks(pt, ct)
	out, ok := pkcs7Unpad(pt)
	return string(out), ok
}

// accountToCommon Account → CommonServiceConfig(snake_case)。
//
// ★ CommonConfig 是**跨客户端**交换格式,所以通用字段(type/url/access_token…)
// 保持原样;LinPlayer 独有的服务器设置挂在 `linplayer` 子对象里 ——
// 别的客户端读到未知键会忽略,而我们扫码搬家时不丢用户攒的线路和备注。
func accountToCommon(a Account) map[string]any {
	return map[string]any{
		"type":         "emby",
		"id":           a.Server, // 以 server 为身份(Upsert 按 server 去重)
		"name":         a.UserName,
		"url":          a.Server,
		"username":     a.UserName,
		"user_id":      a.UserID,
		"access_token": a.Token,
		"linplayer": map[string]any{
			"name":               a.Name,
			"remark":             a.Remark,
			"icon_url":           a.IconURL,
			"password":           a.Password,
			"lines":              a.Lines,
			"active_line":        a.ActiveLine,
			"allow_insecure_tls": a.AllowInsecureTLS,
			// ★ 源类型和源配置在 rest 里(网盘 / 局域网账号靠它们才是完整的)。
			//   不带的话扫码搬过去的网盘账号会变成一个连不上的空壳。
			"source_kind": a.SourceKind(),
			"source":      a.RestValue("source"),
		},
	}
}

func commonToAccount(j map[string]any) (Account, bool) {
	url, _ := j["url"].(string)
	server := strings.TrimRight(strings.TrimSpace(url), "/")
	if server == "" {
		return Account{}, false
	}
	// ★ 别家客户端导出的配置没有 `linplayer` 段,整段缺失时全部走默认值。
	ext, _ := j["linplayer"].(map[string]any)
	s := func(m map[string]any, k string) string { v, _ := m[k].(string); return v }
	sp := func(m map[string]any, k string) *string {
		if v, ok := m[k].(string); ok && v != "" {
			return &v
		}
		return nil
	}
	a := Account{
		Server:   server,
		Token:    s(j, "access_token"),
		UserID:   s(j, "user_id"),
		UserName: s(j, "username"),
	}
	if a.UserName == "" {
		a.UserName = s(j, "name")
	}
	if ext == nil {
		return a, true
	}
	a.Name, a.Remark, a.IconURL, a.Password = s(ext, "name"), sp(ext, "remark"), sp(ext, "icon_url"), sp(ext, "password")
	if v, ok := ext["active_line"].(float64); ok {
		a.ActiveLine = int(v)
	}
	a.AllowInsecureTLS, _ = ext["allow_insecure_tls"].(bool)
	if raw, err := json.Marshal(ext["lines"]); err == nil {
		_ = json.Unmarshal(raw, &a.Lines)
	}
	if k := s(ext, "source_kind"); k != "" && k != "emby" {
		a.SetRestValue("source_kind", k)
	}
	if v, ok := ext["source"]; ok && v != nil {
		a.SetRestValue("source", v)
	}
	return a, true
}

// EncodeTransfer 把账号列表编码成可放进二维码的字符串。
func EncodeTransfer(accounts []Account, exportTimeUnix int64) string {
	configs := make([]string, 0, len(accounts))
	for _, a := range accounts {
		b, err := json.Marshal(accountToCommon(a))
		if err != nil {
			continue
		}
		configs = append(configs, encryptConfig(string(b), builtinKey))
	}
	container := map[string]any{
		"from": transferClient, "version": transferVersion,
		"export_time": exportTimeUnix, "configs": configs,
		"_key": base64.StdEncoding.EncodeToString(builtinKey[:]),
	}
	raw, err := json.Marshal(container)
	if err != nil {
		return ""
	}
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	_, _ = gz.Write(raw)
	_ = gz.Close()
	return transferPrefix + base64.URLEncoding.EncodeToString(buf.Bytes())
}

// DecodeTransfer 解码扫到的字符串。非本 App 载荷 / 损坏返回 error。
func DecodeTransfer(raw string) ([]Account, error) {
	s := strings.TrimSpace(raw)
	body, ok := strings.CutPrefix(s, transferPrefix)
	if !ok {
		return nil, fmt.Errorf("不是 LinPlayer 配置二维码")
	}
	gzb, err := base64.URLEncoding.DecodeString(body)
	if err != nil {
		return nil, fmt.Errorf("载荷 base64 解码失败")
	}
	zr, err := gzip.NewReader(bytes.NewReader(gzb))
	if err != nil {
		return nil, fmt.Errorf("载荷解压失败")
	}
	defer zr.Close()
	jsonb, err := io.ReadAll(zr)
	if err != nil {
		return nil, fmt.Errorf("载荷解压失败")
	}
	var container map[string]any
	if json.Unmarshal(jsonb, &container) != nil {
		return nil, fmt.Errorf("载荷 JSON 非法")
	}
	// 优先用容器里的 `_key`,否则回退内置密钥。
	key := builtinKey
	if ks, ok := container["_key"].(string); ok {
		if kb, err := base64.StdEncoding.DecodeString(ks); err == nil && len(kb) == 32 {
			copy(key[:], kb)
		}
	}
	arr, _ := container["configs"].([]any)
	out := []Account{}
	for _, c := range arr {
		cs, ok := c.(string)
		if !ok {
			continue
		}
		// ★ 解不开的**单条跳过**:一条坏了不该让整次导入失败 ——
		//   用户扫的那张码里可能混着别家客户端的条目。
		plain, ok := decryptConfig(cs, key)
		if !ok {
			continue
		}
		var j map[string]any
		if json.Unmarshal([]byte(plain), &j) != nil {
			continue
		}
		if a, ok := commonToAccount(j); ok {
			out = append(out, a)
		}
	}
	return out, nil
}

// MergeAccounts 按 server 合并:导入项覆盖同 server 的旧项,其余保留,新项追加。
//
// ★★ **导入是合并不是覆盖**(UI_PC §7.15)。覆盖的话用户在新机器上先加了一台服务器,
// 扫码导入就把它抹了 —— 而他以为只是「把老机器上的搬过来」。
func MergeAccounts(existing, incoming []Account) []Account {
	ids := map[string]bool{}
	for _, a := range incoming {
		ids[a.Server] = true
	}
	out := []Account{}
	for _, a := range existing {
		if !ids[a.Server] {
			out = append(out, a)
		}
	}
	return append(out, incoming...)
}
