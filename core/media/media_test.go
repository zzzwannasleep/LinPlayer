package media

import "testing"

// 「正则空 = 没启用」和「正则非法 = 没启用」必须走同一条路 ——
// 这两条分开处理过一次,表现是设置页填错一个字符就静默变成「一条都不选」。
func TestPickIndex(t *testing.T) {
	texts := []string{"版本一 1080p h264", "版本二 2160p hevc 4K"}

	if got := PickIndex(texts, "4k"); got != 1 {
		t.Fatalf("大小写不敏感,4k 应命中第 2 条,实得 %d", got)
	}
	if got := PickIndex(texts, ""); got != -1 {
		t.Fatalf("空正则 = 没启用,应 -1,实得 %d", got)
	}
	if got := PickIndex(texts, "["); got != -1 {
		t.Fatalf("非法正则 = 没启用,应 -1,实得 %d", got)
	}
	if got := PickIndex(texts, "8K"); got != -1 {
		t.Fatalf("没命中也是 -1,实得 %d", got)
	}
	// 整条 pattern 先 trim 两端再编译 —— 用户从设置页粘进来的值常带首尾空格
	if got := PickIndex(texts, "  hevc  "); got != 1 {
		t.Fatalf("两端空白要 trim 掉,实得 %d", got)
	}
	// 但中间的空格是正则的一部分,照字面匹配(不是「按词切开各匹配一遍」)
	if got := PickIndex(texts, "hevc h264"); got != -1 {
		t.Fatalf("中间的空格按字面匹配,不该命中,实得 %d", got)
	}
	// 中文能直接写(用户的字幕偏好几乎都是「简」「繁」这种)
	if got := PickIndex([]string{"英文", "简体中文"}, "简"); got != 1 {
		t.Fatalf("中文正则应命中,实得 %d", got)
	}
}

func TestValidateTrackRegex(t *testing.T) {
	if err := ValidateTrackRegex(""); err != nil {
		t.Fatalf("空串是合法的(= 关闭该筛选),实得 %v", err)
	}
	if err := ValidateTrackRegex("["); err == nil {
		t.Fatal("非法正则必须报错,否则设置页会静默存一条永不生效的偏好")
	}
}
