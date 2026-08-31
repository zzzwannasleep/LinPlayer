// Package secrets 是编译期注入凭据的运行时解密。
//
// 移植自 `crates/core/src/secrets.rs` + `crates/core/build.rs`。**Rust 版是黄金实现**,
// 加密方案(AES-256-CBC/PKCS7,IV = key[0:16],base64)与混淆口令**逐字节照抄** ——
// 换掉的话 CI 里现有的 Secret 全部作废,而且失败方式是「静默拿到空密钥」。
//
// ★ 安全边界说清楚:这是**混淆级**,不是加密级。口令就在同一个二进制里,
// 拿得到发行包就拿得到密钥(`docs/lessons` 里「弹弹配额被刷完」记的就是这件事)。
// 它挡的是「顺手 strings 一下就抄走」,挡不住有心人。真要防住只能挪到服务端。
//
// ★ Go 这边没有 build.rs,注入走 `-ldflags -X`(见 core/cmd/sealsecrets)。
// 密文而不是明文进 ldflags:明文会**原样出现在构建日志和进程命令行里**。
package secrets

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"strings"
)

// 这四个由 `-ldflags -X linplayer/core/secrets.xxx=...` 在链接期灌进来。
// 不注入时是空串 —— 那是**合法状态**(本地构建),对应的功能应当明说「此构建没有凭据」,
// 而不是装作没数据。
var (
	dandanAppID     string
	dandanSecretEnc string
	tmdbKeyEnc      string
)

// obfKey 与 core/cmd/sealsecrets 的同名常量必须逐字节一致。
const obfKey = "LinPlayer-tmdb-ranking-key-v1!!!"

// decrypt 解一段 base64(AES-256-CBC(明文))。任何一步不对都返回空串 ——
// 调用方本来就要处理「没配置」,多一个「解不开」的分支只会让调用点更啰嗦。
func decrypt(enc string) string {
	enc = strings.TrimSpace(enc)
	if enc == "" {
		return ""
	}
	ct, err := base64.StdEncoding.DecodeString(enc)
	if err != nil || len(ct) == 0 || len(ct)%aes.BlockSize != 0 {
		return ""
	}
	block, err := aes.NewCipher([]byte(obfKey))
	if err != nil {
		return ""
	}
	out := make([]byte, len(ct))
	cipher.NewCBCDecrypter(block, []byte(obfKey[:aes.BlockSize])).CryptBlocks(out, ct)
	pt, ok := unpad(out)
	if !ok {
		return ""
	}
	return strings.TrimSpace(string(pt))
}

// unpad 去 PKCS#7 填充。★ 必须校验每一个填充字节:
// 只看最后一字节的话,一段乱码解出来也会被当成合法明文截断,
// 于是「密钥错了」会伪装成「密钥是一串乱码」—— 后者的报错在服务端,查起来远得多。
func unpad(b []byte) ([]byte, bool) {
	if len(b) == 0 {
		return nil, false
	}
	n := int(b[len(b)-1])
	if n == 0 || n > aes.BlockSize || n > len(b) {
		return nil, false
	}
	for _, c := range b[len(b)-n:] {
		if int(c) != n {
			return nil, false
		}
	}
	return b[:len(b)-n], true
}

// firstSecret 取多串轮换密钥里的**第一串**。
//
// ★★ AppSecret 可能是**多串换行分隔的**(同一个 AppId 配多个 Secret 做配额轮换)。
// 签名只能用其中一串,把整坨 "S1\nS2" 拿去 sha256 必然签错。
//
// 2026-07-21 事故:弹幕那条路有拆分 → 正常;排行榜没有 → **HTTP 403,整页空白**。
// 表现极具误导性:「同一个 AppId、同一个密钥,弹幕好好的,就排行榜不行」,
// 看起来像平台不给排行榜权限,实际是我们自己少了一次拆分。
func firstSecret(raw string) string {
	for _, line := range strings.Split(raw, "\n") {
		if s := strings.TrimSpace(line); s != "" {
			return s
		}
	}
	return ""
}

// DandanAppID 弹弹Play 官方 AppId(公开标识符,明文注入)。
func DandanAppID() string { return strings.TrimSpace(dandanAppID) }

// DandanAppSecret 弹弹Play 官方 AppSecret(密文注入,运行时解密并取第一串)。
func DandanAppSecret() string { return firstSecret(decrypt(dandanSecretEnc)) }

// DandanCreds 凭据齐备则返回 (appID, secret, true)。
func DandanCreds() (string, string, bool) {
	id, sec := DandanAppID(), DandanAppSecret()
	if id == "" || sec == "" {
		return "", "", false
	}
	return id, sec, true
}

// TMDBKey TMDB 密钥(密文注入)。空 = 未配置。
func TMDBKey() string { return decrypt(tmdbKeyEnc) }

// TMDBConfigured 这个构建带没带 TMDB 密钥。
//
// ★ 这是**有意偏离黄金实现**的一处(Rust 侧判的是「密文非空」)。
// 判据改成**解得出明文**,是因为—— 密文非空但解不开时,
// Rust 侧那句 `option_env!(...).is_some()` 会说「配了」,然后请求带着空 key 出去,
// 拿回一句 TMDB 的鉴权失败。这里收紧成解得出才算配了。
func TMDBConfigured() bool { return TMDBKey() != "" }

// DandanConfigured 这个构建带没带弹弹Play 凭据。
func DandanConfigured() bool { _, _, ok := DandanCreds(); return ok }
