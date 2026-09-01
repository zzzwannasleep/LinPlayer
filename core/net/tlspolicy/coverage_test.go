package tlspolicy_test

// ★★ 出网口**全都**要走 tlspolicy,漏一个就是一处静默失败:
//
//	emby 客户端漏 → 登录/列表连不上(至少还报错)
//	localserve 漏 → **一张封面都没有,而命令全都正常**(和白名单没同步长得一模一样)
//	prefetch 漏   → 「多线程加载」一开就取不到流
//	preload 漏    → 预热永远失败,而且是静默的
//
// 这条测试扫源码而不是跑行为:新加一个出网口时,人不会记得来改这里,
// 但**扫不到就会红**,红了就会想起来。

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

var newClient = regexp.MustCompile(`&http\.Client\{`)

func TestAllHTTPClients_都必须走tlspolicy(t *testing.T) {
	root := filepath.Join("..", "..")
	var bad []string
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".go") {
			return nil
		}
		if strings.HasSuffix(path, "_test.go") || strings.Contains(path, string(os.PathSeparator)+"cmd"+string(os.PathSeparator)) {
			return nil // 测试和自检小工具不算产品出网口
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		lines := strings.Split(string(b), "\n")
		for i, line := range lines {
			if !newClient.MatchString(line) {
				continue
			}
			if strings.Contains(path, "tlspolicy") {
				continue
			}
			/* ★ 看的是**整个字面量**,不是这一行:`&http.Client{` 之后换行写
			   Transport 是完全正常的写法,只看一行会把它误报成漏网 ——
			   而误报久了这条门禁就会被人关掉(长期红的门禁 = 没有门禁)。
			   往后扫到闭合大括号,最多 24 行。 */
			ok := false
			for j := i; j < len(lines) && j < i+24; j++ {
				if strings.Contains(lines[j], "Transport") {
					ok = true
					break
				}
				if j > i && strings.TrimSpace(lines[j]) == "}" {
					break
				}
			}
			if !ok {
				bad = append(bad, path+": "+strings.TrimSpace(line))
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(bad) > 0 {
		t.Fatalf("这些 http.Client 没给 Transport —— 自签名服务器上会静默失败:\n  %s",
			strings.Join(bad, "\n  "))
	}
}
