package secrets

// 这个包的价值全在**失败方式**上:凭据不对时不会报错,只会静默拿到空串,
// 然后功能在很远的地方以「服务端拒绝」的面目出现。所以每条都要能反向注入。

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"strings"
	"testing"
)

// seal 复刻 core/cmd/sealsecrets 的加密,验证封装 → 解开往返一致。
// ★ 故意写成**独立实现**而不是 import 那个包:两边共用一份代码的话,
// 口令写错了往返照样一致,而 CI 里注入的密文全部解不开(测试还是绿的)。
func seal(t *testing.T, plain string) string {
	t.Helper()
	block, err := aes.NewCipher([]byte("LinPlayer-tmdb-ranking-key-v1!!!"))
	if err != nil {
		t.Fatal(err)
	}
	b := []byte(plain)
	n := aes.BlockSize - len(b)%aes.BlockSize
	for i := 0; i < n; i++ {
		b = append(b, byte(n))
	}
	out := make([]byte, len(b))
	cipher.NewCBCEncrypter(block, []byte("LinPlayer-tmdb-r")).CryptBlocks(out, b)
	return base64.StdEncoding.EncodeToString(out)
}

func TestDecrypt往返一致(t *testing.T) {
	for _, s := range []string{"", "abc123", "很长的密钥DANDAN_SECRET_🔑", strings.Repeat("a", 64)} {
		if got := decrypt(seal(t, s)); got != s {
			t.Fatalf("往返不一致:封 %q 解出 %q", s, got)
		}
	}
}

// ★★ 这条是本文件存在的最大理由。
//
// 多串轮换密钥必须只取第一串。整坨 "S1\nS2" 拿去 sha256 会签出一个谁也认不出的签名 ——
// 服务端回 403,而排行榜当时把错误吞成空数组,现象只剩「整页空白」。
func TestFirstSecret多串轮换只取第一串(t *testing.T) {
	cases := map[string]string{
		"s1\ns2":         "s1",
		"s1\r\ns2":       "s1",   // CRLF 也要能拆(GH Secret 网页粘贴常带 \r)
		"\n\n  s1  \ns2": "s1",   // 前导空行 / 空白要跳过并 trim
		"only":           "only", // 单串必须是恒等变换,不能改变现有行为
		"":               "",
		"   \n  ":        "",
	}
	for in, want := range cases {
		if got := firstSecret(in); got != want {
			t.Fatalf("firstSecret(%q) = %q,想要 %q —— 签名会错,服务端回 403 而我们只看到空榜", in, got, want)
		}
	}
}

// ★ 垃圾输入必须解成空串,不能 panic —— 这是个在 lp_init 早期就会被调到的包。
func TestDecrypt垃圾输入解成空串而不是崩(t *testing.T) {
	for _, s := range []string{"not-base64!!!", "", "   ", "YWJj" /* 长度不是 16 的倍数 */} {
		if got := decrypt(s); got != "" {
			t.Fatalf("decrypt(%q) 应当是空串,实得 %q", s, got)
		}
	}
}

// ★★ 填充必须**逐字节**校验。
//
// 只看最后一字节的话,一段乱码也会被当成合法明文截断 ——
// 于是「口令错了」伪装成「密钥是一串乱码」,而后者的报错发生在服务端,查起来远得多。
//
// ★ 夹具必须**能分辨**这件事。第一版拿「另一个口令封的密文」来测,
//
//	解出来的乱码最后一字节碰巧不在 1..16 里,长度检查就把它拦了 ——
//	逐字节那个循环压根没跑到,注入「只看最后一字节」测试照样绿。
//	现在改成**直接构造**一段末字节合法、但前面几字节对不上的明文:
//	n=3 而末三字节是 01 02 03 —— 只有逐字节校验才拦得住。
func TestUnpad填充必须逐字节校验(t *testing.T) {
	blob := []byte("AAAAAAAAAAAAA")       // 13 字节
	blob = append(blob, 0x01, 0x02, 0x03) // 凑满 16;末字节 3 = 一个**合法的**长度
	if len(blob) != aes.BlockSize {
		t.Fatalf("夹具长度不对: %d", len(blob))
	}

	if _, ok := unpad(blob); ok {
		t.Fatal("末字节说填充 3 字节,而那 3 字节是 01 02 03 —— 必须判非法。" +
			"只看最后一字节的话,这段乱码会被当成明文 \"AAAAAAAAAAAAA\" 交出去")
	}

	// 反面:真正合法的填充要放行,别修好一边坏另一边
	good := append([]byte("AAAAAAAAAAAAA"), 0x03, 0x03, 0x03)
	if got, ok := unpad(good); !ok || string(got) != "AAAAAAAAAAAAA" {
		t.Fatalf("合法填充被拦了: %q ok=%v", got, ok)
	}
}

// ★ 没注入凭据是**合法状态**,不是错误。上层要据此明说「此构建没有凭据」。
func TestNoCreds是合法状态(t *testing.T) {
	if dandanAppID == "" && DandanConfigured() {
		t.Fatal("没有 AppId 却说凭据齐备")
	}
	if id, sec, ok := DandanCreds(); ok && (id == "" || sec == "") {
		t.Fatal("说凭据齐备,却给了空的")
	}
}
