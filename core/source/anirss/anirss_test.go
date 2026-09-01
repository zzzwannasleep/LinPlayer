package anirss

import (
	"encoding/base64"
	"encoding/json"
	"testing"
)

// ★★★ C24 的 🔴 判据。
//
// 上游 v3.1.23(2026-05-08 a91b5b76)把 `PlayItem.filename` 从 base64 改成了
// **裸绝对路径**,编码责任移交客户端 —— 我们一直没跟(N15)。
// 按上游源码推演,在 v3.x 服务端上这个源**点任何一集都放不出来**。
//
// 判据是**内容嗅探**:明文进来要编码一次,base64 进来不能二次编码。
func TestEncodeFilename_明文要编码base64不能二次编码(t *testing.T) {
	plain := "/data/anime/某某番/S01E01.mkv"
	encoded := base64.StdEncoding.EncodeToString([]byte(plain))

	if got := EncodeFilename(plain); got != encoded {
		t.Fatalf("明文路径没被编码:\n 得到 %q\n 想要 %q\n"+
			"—— v3.x 服务端上这条路径直接解不开,表现是点任何一集都放不出来", got, encoded)
	}
	if got := EncodeFilename(encoded); got != encoded {
		t.Fatalf("已经是 base64 的被二次编码了:\n 得到 %q\n 想要 %q\n"+
			"—— 服务端解一次拿到的是另一串 base64,同样打不开", got, encoded)
	}
}

// ★★ **不能用「含 `/` 就是路径」判** —— 标准 Base64 字符集本身就含 `/`。
//
// 这个夹具是故意挑的:它编码后的串里带 `/`,按「含斜杠就是明文」判的话
// 会被当成明文再编一次。判据必须落在**解码之后**。
func TestEncodeFilename_base64里带斜杠也不能误判(t *testing.T) {
	// 找一条编码结果里含 '/' 的真实路径
	var plain, encoded string
	for _, p := range []string{
		"/mnt/media/番剧/测试/第01话 [1080p].mkv",
		"/data/anime/aaa?/bbb.mkv",
		"/srv/媒体库/某某/E02.mkv",
	} {
		e := base64.StdEncoding.EncodeToString([]byte(p))
		if containsSlash(e) {
			plain, encoded = p, e
			break
		}
	}
	if encoded == "" {
		t.Skip("这批夹具没编出带斜杠的 base64")
	}
	_ = plain
	if got := EncodeFilename(encoded); got != encoded {
		t.Fatalf("编码结果里带 `/` 的 base64 被当成明文又编了一次:%q", got)
	}
}

func containsSlash(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == '/' {
			return true
		}
	}
	return false
}

// ★★ **不要用 URL-safe Base64**:上游解的是标准字符集(`+/`),
// 而且它自己做了 `" " → "+"` 的兜底。用 `-_` 的话服务端解出来是乱码。
func TestEncodeFilename_必须是标准字符集(t *testing.T) {
	// 造一条编码后必然含 `+` 或 `/` 的路径
	plain := "/data/\xfb\xff\xfe/影片.mkv"
	got := EncodeFilename(plain)
	if _, err := base64.StdEncoding.DecodeString(got); err != nil {
		t.Fatalf("%q 不是标准 Base64:%v", got, err)
	}
	if _, err := base64.URLEncoding.DecodeString(got); err == nil && got != base64.StdEncoding.EncodeToString([]byte(plain)) {
		t.Fatalf("用了 URL-safe 字符集")
	}
}

// ★ 同一部番会出现在多个周里(改过播出日的)。不去重的话根目录里同一部番
// 出现两三次 —— 看着像数据坏了。
func TestFlattenWeekList_展平并去重(t *testing.T) {
	raw := json.RawMessage(`{"weekList":[
		{"items":[{"id":"a","title":"番一"},{"id":"b","title":"番二"}]},
		{"items":[{"id":"a","title":"番一"},{"id":"c","title":"番三"}]}
	]}`)
	got := flattenWeekList(raw)
	if len(got) != 3 {
		t.Fatalf("展平去重后应当 3 部,实得 %d:%v", len(got), got)
	}
	// 有的版本直接给裸数组
	if got := flattenWeekList(json.RawMessage(`[{"id":"x","title":"番 X"}]`)); len(got) != 1 {
		t.Fatalf("裸数组也要吃下,实得 %v", got)
	}
	// 坏数据不能 panic
	if got := flattenWeekList(json.RawMessage(`"不是对象"`)); len(got) != 0 {
		t.Fatalf("坏数据应当解出空,实得 %v", got)
	}
}

// ★ 显示名解不出来时**原样兜底**,别给用户一个空名字的条目。
func TestDecodeForDisplay(t *testing.T) {
	b64 := base64.StdEncoding.EncodeToString([]byte("/data/x/第01话.mkv"))
	if got := decodeForDisplay(b64); got != "第01话.mkv" {
		t.Fatalf("%q", got)
	}
	if got := decodeForDisplay("/data/x/第02话.mkv"); got != "第02话.mkv" {
		t.Fatalf("明文路径也要取文件名,实得 %q", got)
	}
	if got := decodeForDisplay("不知道是什么"); got != "不知道是什么" {
		t.Fatalf("解不出就原样返回,实得 %q", got)
	}
}
