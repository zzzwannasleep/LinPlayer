// Package media 是选轨 / 选版本的偏好匹配。
//
// 移植自 `crates/core/src/media.rs`。**Rust 版是黄金实现。**
//
// ★ Rust 用的是 regex crate,Go 用 regexp —— 两边都是 RE2 系(无反向引用、无前后瞻),
// 语法覆盖面基本一致。用户写得出来的偏好正则(`简|中文`、`4K`、`^(?!.*)`…)里
// **只有前后瞻两边都不支持**,所以「Rust 能编译 Go 不能」这种偏差不该出现;
// 真出现了它会走「编译失败 = 没启用」那条路,和 Rust 侧对非法正则的处置一致。
package media

import (
	"regexp"
	"strings"
)

// CompilePreference 编译一条偏好正则。
//
// 空串或非法 → nil,调用方据此**回退到默认行为**(语言匹配 / 第一条)。
// 大小写不敏感。中文可以直接写(`简` `繁` `日`)。
func CompilePreference(pattern string) *regexp.Regexp {
	p := strings.TrimSpace(pattern)
	if p == "" {
		return nil
	}
	re, err := regexp.Compile("(?i)" + p)
	if err != nil {
		return nil
	}
	return re
}

// ValidateTrackRegex 设置页用的合法性校验。**空串算合法**(= 关闭该筛选)。
func ValidateTrackRegex(pattern string) error {
	p := strings.TrimSpace(pattern)
	if p == "" {
		return nil
	}
	_, err := regexp.Compile("(?i)" + p)
	return err
}

// PickIndex 在一组「可匹配文本」里找第一条命中正则的,返回下标。
//
// ★ 正则空 / 非法 → -1。那**不是**「没匹配上」,是「没启用」——
// 对调用方而言两者都是回退默认,所以合成一个返回值。
func PickIndex(texts []string, pattern string) int {
	re := CompilePreference(pattern)
	if re == nil {
		return -1
	}
	for i, t := range texts {
		if re.MatchString(t) {
			return i
		}
	}
	return -1
}
