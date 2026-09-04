package danmaku

// 本地弹幕文件解析:XML(B 站导出)/ JSON(弹弹Play 导出)。
//

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

const localSource = "local"

// white 默认颜色。
const white = 16777215

// normalizeMode 各家 mode 归一到弹弹Play 标准:1=滚动 4=底部 5=顶部。
//
// ★ B 站的 1/2/3 都是滚动,4=底 5=顶 6=逆向 7=高级 8=代码。
// 不归一的话「底部弹幕」会被当成滚动,一路飘过去。
func normalizeMode(m int) int {
	switch m {
	case 4:
		return 4
	case 5:
		return 5
	default:
		return 1
	}
}

// ParseLocal 解析一份本地弹幕文件。按**内容**嗅探格式,不看后缀。
//
// ★ 后缀会骗人:用户把 json 存成 .xml 的情况不少见,而报「XML 解析失败」
// 对他毫无帮助。
func ParseLocal(content string) ([]Comment, error) {
	trimmed := strings.TrimSpace(content)
	if trimmed == "" {
		return nil, fmt.Errorf("弹幕文件为空")
	}
	switch trimmed[0] {
	case '<':
		return parseXML(content)
	case '{', '[':
		return parseJSON(content)
	}
	return nil, fmt.Errorf("无法识别的弹幕文件格式(支持 xml / json)")
}

// parseXML B 站导出的 `<d p="time,mode,size,color,ts,pool,uid,rowid">文本</d>`。
func parseXML(content string) ([]Comment, error) {
	out := []Comment{}
	cur := content
	for {
		at := strings.Index(cur, "<d ")
		if at < 0 {
			break
		}
		after := cur[at:]
		gt := strings.Index(after, ">")
		if gt < 0 {
			break // 开标签未闭合 → 文件截断,停扫
		}
		attrs := after[2:gt]
		rest := after[gt+1:]
		// ★ 自闭合 <d p="..."/> 没有文本,跳过 —— 不跳的话会一路吞到下一个 </d>
		if strings.HasSuffix(strings.TrimRight(attrs, " \t"), "/") {
			cur = rest
			continue
		}
		end := strings.Index(rest, "</d>")
		if end < 0 {
			break
		}
		body := rest[:end]
		cur = rest[end+4:]

		text := strings.TrimSpace(unescapeXML(body))
		if text == "" {
			continue
		}
		p := strings.Split(attrP(attrs), ",")
		get := func(i int) string {
			if i < len(p) {
				return strings.TrimSpace(p[i])
			}
			return ""
		}
		// ★ 时间取不到就**跳过这一条**:退化成 0 秒等于把弹幕全堆在片头 —— 宁可少一条
		t, err := strconv.ParseFloat(get(0), 64)
		if err != nil {
			continue
		}
		c := Comment{Time: t, Text: text, Mode: 1, Color: white, Source: localSource, Count: 1}
		if n, err := strconv.Atoi(get(1)); err == nil {
			c.Mode = normalizeMode(n)
		}
		// ★ 字号在 index2、**颜色在 index3** —— 和弹弹Play JSON 的 p 下标不同,别抄串
		if n, err := strconv.Atoi(get(3)); err == nil {
			c.Color = n
		}
		if u := get(6); u != "" {
			c.UserID = &u
		}
		out = append(out, c)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("XML 里没找到弹幕(<d> 节点为空)")
	}
	return out, nil
}

// attrP 从属性串里抠出 p="..." 的值。
func attrP(attrs string) string {
	i := strings.Index(attrs, `p="`)
	if i < 0 {
		return ""
	}
	rest := attrs[i+3:]
	j := strings.Index(rest, `"`)
	if j < 0 {
		return ""
	}
	return rest[:j]
}

// parseJSON 弹弹Play 导出。三种外层形状都吃:
// `{"comments":[…]}` / 裸数组 / `{"data":[…]}`。
func parseJSON(content string) ([]Comment, error) {
	var any1 any
	if json.Unmarshal([]byte(content), &any1) != nil {
		return nil, fmt.Errorf("JSON 解析失败")
	}
	var arr []any
	switch v := any1.(type) {
	case []any:
		arr = v
	case map[string]any:
		for _, k := range []string{"comments", "data"} {
			if a, ok := v[k].([]any); ok {
				arr = a
				break
			}
		}
	}
	if arr == nil {
		return nil, fmt.Errorf("JSON 里没找到弹幕数组(comments / data / 裸数组)")
	}
	out := []Comment{}
	for _, it := range arr {
		m, ok := it.(map[string]any)
		if !ok {
			continue
		}
		c := parseComment(m, localSource)
		if strings.TrimSpace(c.Text) == "" {
			continue
		}
		c.Mode = normalizeMode(c.Mode)
		out = append(out, c)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("JSON 里的弹幕数组是空的")
	}
	return out, nil
}
