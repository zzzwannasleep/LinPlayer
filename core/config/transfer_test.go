package config

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func ta(server, user string) Account {
	return Account{Server: server, Token: "tok-secret", UserID: "uid1", UserName: user}
}

// ★★ 载荷里**不能出现明文凭据**。
//
// 这条码用户会截图、会发群里 —— 明文 token 躺在里面等于把服务器送人。
// (口径是混淆级:密钥随载荷走,挡的是随手一看,不防提取密钥后解密。)
func TestTransfer_往返且不含明文token(t *testing.T) {
	in := []Account{ta("https://a.example", "小明"), ta("https://b.example", "Bob")}
	payload := EncodeTransfer(in, 1_700_000_000)
	if !strings.HasPrefix(payload, transferPrefix) {
		t.Fatalf("前缀不对: %.20s", payload)
	}
	if strings.Contains(payload, "tok-secret") {
		t.Fatal("载荷里出现了明文 token —— 这张码用户会截图发出去")
	}
	out, err := DecodeTransfer(payload)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 2 {
		t.Fatalf("解出 %d 条", len(out))
	}
	if out[0].Server != "https://a.example" || out[0].Token != "tok-secret" ||
		out[0].UserName != "小明" || out[1].UserName != "Bob" {
		t.Fatalf("%+v / %+v", out[0], out[1])
	}
}

// ★ LinPlayer 独有的那些设置(线路 / 备注 / 图标 / 源类型)必须一起搬过去,
// 否则用户扫完码发现线路全没了,还得一条条重新加。
func TestTransfer_带上独有字段(t *testing.T) {
	a := ta("https://a.example", "小明")
	remark := "家里那台"
	a.Remark = &remark
	a.Lines = []ServerLine{{ID: "l1", Name: "直连", URL: "https://a.example"}}
	a.ActiveLine = 0
	a.AllowInsecureTLS = true
	a.SetRestValue("source_kind", "local")

	out, err := DecodeTransfer(EncodeTransfer([]Account{a}, 1))
	if err != nil || len(out) != 1 {
		t.Fatalf("%v %d", err, len(out))
	}
	g := out[0]
	if g.Remark == nil || *g.Remark != "家里那台" {
		t.Fatalf("备注丢了: %v", g.Remark)
	}
	if len(g.Lines) != 1 || g.Lines[0].Name != "直连" {
		t.Fatalf("线路丢了: %+v", g.Lines)
	}
	if !g.AllowInsecureTLS {
		t.Fatal("自签名开关丢了 —— 搬过去之后那台服务器直接连不上")
	}
	if g.SourceKind() != "local" {
		t.Fatalf("源类型丢了(%q)—— 网盘账号会变成一个连不上的空壳", g.SourceKind())
	}
}

// ★★ **导入是合并不是覆盖**(UI_PC §7.15)。
//
// 覆盖的话用户在新机器上已经加好的那台会被静默抹掉,而他以为只是「把老的搬过来」。
func TestMergeAccounts_合并不是覆盖(t *testing.T) {
	existing := []Account{ta("https://keep.example", "本机"), ta("https://a.example", "旧的")}
	incoming := []Account{ta("https://a.example", "新的"), ta("https://new.example", "新增")}
	got := MergeAccounts(existing, incoming)
	if len(got) != 3 {
		t.Fatalf("合并后应当 3 台,实得 %d:%+v", len(got), got)
	}
	if got[0].Server != "https://keep.example" {
		t.Fatalf("新机器上原有的那台被抹了:%+v", got)
	}
	for _, a := range got {
		if a.Server == "https://a.example" && a.UserName != "新的" {
			t.Fatal("同 server 的应当被导入项覆盖")
		}
	}
}

// ★ 不是本 App 的载荷要**明说**,别解成空表让用户以为「扫了但是没内容」。
func TestDecodeTransfer_垃圾载荷要报错(t *testing.T) {
	for _, s := range []string{"", "随便一段文字", "https://example.com", "LPSYNC1:@@@不是base64"} {
		if _, err := DecodeTransfer(s); err == nil {
			t.Fatalf("%q 应当报错", s)
		}
	}
}

// ★★ 单条解不开要**跳过而不是整次失败**:用户扫的那张码里可能混着别家客户端的条目。
func TestDecodeTransfer_坏条目跳过好条目留下(t *testing.T) {
	good := EncodeTransfer([]Account{ta("https://a.example", "小明")}, 1)
	// 拆开容器,往 configs 里塞一条解不开的
	body, _ := strings.CutPrefix(good, transferPrefix)
	gzb, _ := base64.URLEncoding.DecodeString(body)
	raw := gunzipForTest(t, gzb)
	var c map[string]any
	if json.Unmarshal(raw, &c) != nil {
		t.Fatal("夹具本身就坏了")
	}
	arr := c["configs"].([]any)
	c["configs"] = append(arr, base64.StdEncoding.EncodeToString([]byte("0123456789abcdef")))
	out, err := DecodeTransfer(reencodeForTest(t, c))
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 1 || out[0].UserName != "小明" {
		t.Fatalf("坏条目应当被跳过、好条目留下,实得 %+v", out)
	}
}

// ★★ PKCS#7 的**每一个**填充字节都要校验。
//
// 只看最后一个的话,随便一段乱码有 1/16 的概率被当成合法明文 ——
// 解出来的是垃圾账号,而且一步都不报错。
func TestPkcs7Unpad_每个填充字节都要校验(t *testing.T) {
	// 末字节说「填了 3 个」,但前两个不是 3 —— 必须拒
	bad := make([]byte, 16)
	copy(bad[13:], []byte{1, 2, 3})
	if _, ok := pkcs7Unpad(bad); ok {
		t.Fatal("填充字节不一致却收下了 —— 乱码会被当成合法明文")
	}
	good := pkcs7Pad([]byte("hello"))
	if out, ok := pkcs7Unpad(good); !ok || string(out) != "hello" {
		t.Fatalf("正常填充解不开:%q %v", out, ok)
	}
}
