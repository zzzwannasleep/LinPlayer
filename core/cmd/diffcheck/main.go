// diffcheck 是差分对账器(SPEC §12.1,TODO 阶段 2)。
//
// **Rust 版是黄金实现。** Go 版的验收不是「跑起来了」,是「输出和 Rust 版一致」。
// 单元测试只能证明 Go 版自洽,证明不了它和 Rust 版一致 ——
// 这个工具是防「看起来对了」的唯一手段。
//
//	用法:  go run ./cmd/diffcheck [-corpus 目录] [-v]
//	退出码 = 对不上的用例数
//
// # 一条用例长什么样
//
// 语料是一份 JSON:上游会怎么答 + 调哪条命令 + 期望输出。跑的时候:
//
//	起一个 mock 上游(明文 HTTP,两边都连得上)
//	  -> 把 session.server 指向它
//	  -> 调 Go 侧实现
//	  -> 归一化后与 expect 逐字段 diff
//
// # 期望值从哪来(provenance)
//
// 每条用例**必须**写清 `provenance`。现在的来源是 Rust 版自己的测试语料
// (`crates/core/src/emby.rs` 里那些带 mock server 的用例)—— 也就是黄金实现的行为,
// 只是手工搬过来的。D1 做完之后改成从 Rust 侧自动生成。
//
// **没有 provenance 的用例等于没有对账** —— 那只是在断言「Go 等于我以为的 Go」。
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"time"

	"linplayer/core/emby"
)

// upstreamResp 一条 mock 上游应答。按 path 精确匹配(带 query 时也比 query)。
type upstreamResp struct {
	Path   string `json:"path"`
	Status int    `json:"status"`
	Body   string `json:"body"`
}

// knownDiff 已知差异白名单(D5)。
//
// ★ 每条**必须**带 issue 与到期日。没有到期日的白名单会变成永久遮羞布 ——
// 到期之后本工具会把它当成失败,逼人回来看一眼。
type knownDiff struct {
	Path    string `json:"path"`
	Issue   string `json:"issue"`
	Expires string `json:"expires"` // YYYY-MM-DD
	Why     string `json:"why"`
}

type testCase struct {
	Name       string          `json:"name"`
	Note       string          `json:"note"`
	Provenance string          `json:"provenance"`
	Upstream   []upstreamResp  `json:"upstream"`
	Command    string          `json:"command"`
	Args       map[string]any  `json:"args"`
	Expect     json.RawMessage `json:"expect"`
	KnownDiffs []knownDiff     `json:"knownDiffs"`

	file string
}

// runner 一条命令的 Go 侧入口。server 是 mock 上游的地址。
type runner func(ctx context.Context, server string, args map[string]any) (any, error)

var runners = map[string]runner{
	"emby.views": func(ctx context.Context, server string, args map[string]any) (any, error) {
		c := emby.NewClient("diffcheck")
		s := &emby.Session{Server: server, Token: "t", UserID: "u", DeviceID: "d"}
		if v, ok := args["user_id"].(string); ok && v != "" {
			s.UserID = v
		}
		return c.Views(ctx, s)
	},
}

func main() {
	corpus := flag.String("corpus", "", "语料目录(默认:本文件同级的 corpus/)")
	verbose := flag.Bool("v", false, "把每条用例的实际输出也打出来")
	flag.Parse()

	dir := *corpus
	if dir == "" {
		dir = defaultCorpusDir()
	}
	cases, err := loadCorpus(dir)
	if err != nil {
		fmt.Println("!!", err)
		os.Exit(2)
	}
	fmt.Printf("======== 差分对账 ========\n语料目录:%s\n用例 %d 条\n\n", dir, len(cases))

	fail := 0
	for _, tc := range cases {
		if !runCase(tc, *verbose) {
			fail++
		}
	}
	fmt.Println("==========================")
	if fail == 0 {
		fmt.Println("全部对得上。")
	} else {
		fmt.Printf("有 %d 条对不上。\n", fail)
	}
	os.Exit(fail)
}

func defaultCorpusDir() string {
	// 相对于工作目录找,方便 `go run ./cmd/diffcheck` 直接跑
	for _, p := range []string{"cmd/diffcheck/corpus", "corpus", "core/cmd/diffcheck/corpus"} {
		if st, err := os.Stat(p); err == nil && st.IsDir() {
			return p
		}
	}
	return "corpus"
}

func loadCorpus(dir string) ([]testCase, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("读语料目录失败: %w", err)
	}
	var out []testCase
	for _, e := range ents {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			return nil, err
		}
		var tc testCase
		if err := json.Unmarshal(b, &tc); err != nil {
			return nil, fmt.Errorf("%s 不是合法 JSON: %w", e.Name(), err)
		}
		tc.file = e.Name()
		out = append(out, tc)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].file < out[j].file })
	return out, nil
}

func runCase(tc testCase, verbose bool) bool {
	fmt.Printf("---- %s\n", tc.Name)
	if tc.Provenance == "" {
		// 没有 provenance 的用例只是在断言「Go 等于我以为的 Go」
		fmt.Println("  [不通过] 缺 provenance —— 期望值从哪来没写,这条不算对账")
		return false
	}
	fn, ok := runners[tc.Command]
	if !ok {
		fmt.Printf("  [不通过] 没有 %s 的 Go 侧 runner\n", tc.Command)
		return false
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		want := r.URL.Path
		if r.URL.RawQuery != "" {
			want += "?" + r.URL.RawQuery
		}
		for _, u := range tc.Upstream {
			if u.Path == want || u.Path == r.URL.Path {
				st := u.Status
				if st == 0 {
					st = 200
				}
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(st)
				_, _ = w.Write([]byte(u.Body))
				return
			}
		}
		// 语料里没写的路径 = 用例不完整。回 599 让它显式失败,
		// 不要回 404 —— 404 是业务里合法的状态,会被当成「上游说没有」
		w.WriteHeader(599)
		_, _ = w.Write([]byte(`{"error":"语料里没有这个路径: ` + want + `"}`))
	}))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	got, err := fn(ctx, srv.URL, tc.Args)
	if err != nil {
		fmt.Printf("  [不通过] Go 侧报错: %v\n", err)
		return false
	}

	gotN, err := normalize(got)
	if err != nil {
		fmt.Printf("  [不通过] 归一化失败: %v\n", err)
		return false
	}
	var wantAny any
	if err := json.Unmarshal(tc.Expect, &wantAny); err != nil {
		fmt.Printf("  [不通过] expect 不是合法 JSON: %v\n", err)
		return false
	}
	wantN, _ := normalize(wantAny)

	diffs := diff("", wantN, gotN)
	diffs = applyWhitelist(tc, diffs)

	if verbose {
		b, _ := json.MarshalIndent(gotN, "  ", "  ")
		fmt.Printf("  实际输出:\n  %s\n", b)
	}
	if len(diffs) == 0 {
		fmt.Println("  [通过] 与黄金实现一致")
		return true
	}
	for _, d := range diffs {
		fmt.Printf("  [不通过] %s\n", d)
	}
	return false
}

// normalize 把任意值折成「只有 map[string]any / []any / float64 / string / bool / nil」
// 的形状 —— 这样 diff 只需要处理这几种,而且 map 的键序不影响结果(D4)。
func normalize(v any) (any, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// diff 逐路径比。路径形如 `[0].series_name`,报告里能直接定位。
func diff(path string, want, got any) []string {
	if reflect.DeepEqual(want, got) {
		return nil
	}
	switch w := want.(type) {
	case map[string]any:
		g, ok := got.(map[string]any)
		if !ok {
			return []string{fmt.Sprintf("%s 类型不同:期望对象,实得 %T", at(path), got)}
		}
		var out []string
		keys := map[string]bool{}
		for k := range w {
			keys[k] = true
		}
		for k := range g {
			keys[k] = true
		}
		var sorted []string
		for k := range keys {
			sorted = append(sorted, k)
		}
		sort.Strings(sorted)
		for _, k := range sorted {
			wv, wok := w[k]
			gv, gok := g[k]
			switch {
			case wok && !gok:
				out = append(out, fmt.Sprintf("%s 缺字段 %q(黄金实现里有)", at(path), k))
			case !wok && gok:
				out = append(out, fmt.Sprintf("%s 多出字段 %q(黄金实现里没有)", at(path), k))
			default:
				out = append(out, diff(path+"."+k, wv, gv)...)
			}
		}
		return out
	case []any:
		g, ok := got.([]any)
		if !ok {
			return []string{fmt.Sprintf("%s 类型不同:期望数组,实得 %T", at(path), got)}
		}
		if len(w) != len(g) {
			return []string{fmt.Sprintf("%s 长度不同:期望 %d,实得 %d", at(path), len(w), len(g))}
		}
		var out []string
		for i := range w {
			out = append(out, diff(fmt.Sprintf("%s[%d]", path, i), w[i], g[i])...)
		}
		return out
	default:
		return []string{fmt.Sprintf("%s 值不同:期望 %s,实得 %s", at(path), show(want), show(got))}
	}
}

func at(p string) string {
	if p == "" {
		return "(根)"
	}
	return strings.TrimPrefix(p, ".")
}

func show(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprint(v)
	}
	return string(b)
}

// applyWhitelist 滤掉已知差异。**过期的白名单不再生效** ——
// 那正是它存在的意义:逼人到期回来看一眼,而不是永久遮着。
func applyWhitelist(tc testCase, diffs []string) []string {
	if len(tc.KnownDiffs) == 0 {
		return diffs
	}
	today := time.Now().Format("2006-01-02")
	var out []string
	for _, d := range diffs {
		skip := false
		for _, k := range tc.KnownDiffs {
			if k.Path == "" || !strings.Contains(d, k.Path) {
				continue
			}
			if k.Issue == "" || k.Expires == "" {
				fmt.Printf("  [不通过] 白名单条目缺 issue 或 expires:%q —— 不生效\n", k.Path)
				continue
			}
			if k.Expires < today {
				fmt.Printf("  [不通过] 白名单 %q 已于 %s 到期(%s),不再生效\n", k.Path, k.Expires, k.Issue)
				continue
			}
			fmt.Printf("  [白名单] %s —— %s(%s,到期 %s)\n", k.Path, k.Why, k.Issue, k.Expires)
			skip = true
			break
		}
		if !skip {
			out = append(out, d)
		}
	}
	return out
}
