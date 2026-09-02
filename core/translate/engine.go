package translate

// 引擎抽象 + 四家实现(OpenAI/Anthropic 走同一套 AI 引擎,百度通用/大模型,腾讯)。

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"linplayer/core/httpx"
)

// Engine 翻译引擎接口。
//
// ★★ 实现须保证**返回列表与输入等长、顺序一致** —— 服务层靠这个把译文贴回 cue,
// 长度对不上会静默串行(第 3 句的译文贴到第 2 句上)。所以各实现都在长度不符时报错,
// 交给服务层二分重试。
type Engine interface {
	ID() string
	// MaxBatchSize 单批可处理的最大条数(服务层据此分块)。
	MaxBatchSize() int
	// MaxBatchChars 单批文本字符数上限(0 = 不限制)。
	MaxBatchChars() int
	// MaxConcurrency 并发批次上限(API 限流敏感的引擎取 1)。
	MaxConcurrency() int
	// Translate 翻译一批文本,返回与输入等长的译文列表。
	Translate(ctx context.Context, texts []string, sourceLang, targetLang string) ([]string, error)
}

// engErr 带引擎名前缀的错误,便于日志/UI 定位。
func engErr(engine string, format string, a ...any) error {
	return fmt.Errorf("[%s] %s", engine, fmt.Sprintf(format, a...))
}

func md5Hex(s string) string {
	sum := md5.Sum([]byte(s))
	return hex.EncodeToString(sum[:])
}

// postJSON 发一条 JSON 请求并解析回包。所有引擎共用。
func postJSON(ctx context.Context, id, url string, body any, headers map[string]string) (map[string]any, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return nil, engErr(id, "编码失败: %v", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(raw))
	if err != nil {
		return nil, engErr(id, "请求构造失败: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	return doAndDecode(id, req)
}

func doAndDecode(id string, req *http.Request) (map[string]any, error) {
	resp, err := httpx.Client().Do(req)
	if err != nil {
		return nil, engErr(id, "请求失败: %v", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, engErr(id, "读响应失败: %v", err)
	}
	var data map[string]any
	if err := json.Unmarshal(raw, &data); err != nil {
		return nil, engErr(id, "响应非 JSON (HTTP %d): %v", resp.StatusCode, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, engErr(id, "请求失败: HTTP %d (%s)", resp.StatusCode, string(raw))
	}
	return data, nil
}

// ---------------------------------------------------------------------------
// AI 引擎(OpenAI / Anthropic)
// ---------------------------------------------------------------------------

// AiEngine 把一批字幕作为 JSON 数组交给大模型整体翻译。
//
// ★ 整批翻译相比逐条能让模型看到上下文,质量更好也更省请求数。
// 两种协议只在请求/回包形状上有别。
type AiEngine struct {
	Anthropic bool
	Config    AiConfig
}

// ID 引擎标识。
func (e *AiEngine) ID() string {
	if e.Anthropic {
		return "anthropic"
	}
	return "openai"
}

// AI 单批可承载较多条目,但要控制 token;按条数 + 字符数双限制。
func (e *AiEngine) MaxBatchSize() int   { return 40 }
func (e *AiEngine) MaxBatchChars() int  { return 4000 }
func (e *AiEngine) MaxConcurrency() int { return 3 }

func aiSystemPrompt(targetName string) string {
	return "You are a professional subtitle translator. " +
		"Translate every item of the input JSON array into " + targetName + ". " +
		"Rules: (1) Return ONLY a JSON array of strings, same length and order as the input. " +
		`(2) Keep line breaks inside an item as \n. ` +
		"(3) Do not merge or split items, add numbering, notes, or romanization. " +
		"(4) Keep proper nouns natural. Output must be valid JSON, nothing else."
}

func (e *AiEngine) complete(ctx context.Context, systemPrompt, userContent string) (string, error) {
	base := strings.TrimRight(e.Config.BaseURL, "/")
	var u string
	var body map[string]any
	headers := map[string]string{}
	if e.Anthropic {
		u = base + "/messages"
		body = map[string]any{
			"model": e.Config.Model, "max_tokens": 8192, "temperature": 0.2,
			"system":   systemPrompt,
			"messages": []any{map[string]any{"role": "user", "content": userContent}},
		}
		headers["x-api-key"] = e.Config.APIKey
		headers["anthropic-version"] = "2023-06-01"
	} else {
		u = base + "/chat/completions"
		body = map[string]any{
			"model": e.Config.Model, "temperature": 0.2,
			"messages": []any{
				map[string]any{"role": "system", "content": systemPrompt},
				map[string]any{"role": "user", "content": userContent},
			},
		}
		headers["Authorization"] = "Bearer " + e.Config.APIKey
	}

	data, err := postJSON(ctx, e.ID(), u, body, headers)
	if err != nil {
		return "", err
	}
	text := ""
	if e.Anthropic {
		if arr, ok := data["content"].([]any); ok && len(arr) > 0 {
			if m, ok := arr[0].(map[string]any); ok {
				text, _ = m["text"].(string)
			}
		}
	} else {
		if arr, ok := data["choices"].([]any); ok && len(arr) > 0 {
			if m, ok := arr[0].(map[string]any); ok {
				if msg, ok := m["message"].(map[string]any); ok {
					text, _ = msg["content"].(string)
				}
			}
		}
	}
	if text == "" {
		raw, _ := json.Marshal(data)
		return "", engErr(e.ID(), "响应为空: %s", string(raw))
	}
	return text, nil
}

// parseJSONArray 从模型回复里抠出 JSON 数组;**长度对不上视为失败**
// (交给服务层二分重试)。
func parseJSONArray(raw string, expected int) ([]string, bool) {
	start := strings.Index(raw, "[")
	end := strings.LastIndex(raw, "]")
	if start < 0 || end <= start {
		return nil, false
	}
	var arr []any
	if json.Unmarshal([]byte(raw[start:end+1]), &arr) != nil {
		return nil, false
	}
	if len(arr) != expected {
		return nil, false
	}
	out := make([]string, 0, len(arr))
	for _, v := range arr {
		switch t := v.(type) {
		case string:
			out = append(out, t)
		case nil:
			out = append(out, "")
		default:
			b, _ := json.Marshal(t)
			out = append(out, string(b))
		}
	}
	return out, true
}

// Translate 整批翻译。
func (e *AiEngine) Translate(ctx context.Context, texts []string, _, targetLang string) ([]string, error) {
	if len(texts) == 0 {
		return []string{}, nil
	}
	userContent, err := json.Marshal(texts)
	if err != nil {
		return nil, engErr(e.ID(), "编码失败: %v", err)
	}
	raw, err := e.complete(ctx, aiSystemPrompt(HumanLangName(targetLang)), string(userContent))
	if err != nil {
		return nil, err
	}
	out, ok := parseJSONArray(raw, len(texts))
	if !ok {
		return nil, engErr(e.ID(), "AI 返回无法解析为等长 JSON 数组")
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// 百度
// ---------------------------------------------------------------------------

// baiduSalt salt 为任意随机串即可(参与签名)。条数 + 长度 + 内容哈希,
// 足够避免重放碰撞。
func baiduSalt(count int, q string) string {
	h := fnv.New64a()
	_, _ = h.Write([]byte(q))
	return fmt.Sprintf("%d%d%d", count, len(q), h.Sum64())
}

// flattenLines 把每条内部换行压成空格 —— 避免破坏「一行一条」的回包对齐。
func flattenLines(texts []string) []string {
	out := make([]string, 0, len(texts))
	for _, t := range texts {
		out = append(out, strings.TrimSpace(strings.ReplaceAll(t, "\n", " ")))
	}
	return out
}

// parseBaiduResponse 解析百度回包(通用/大模型同构)。
func parseBaiduResponse(id string, data map[string]any, expected int) ([]string, error) {
	if code, has := data["error_code"]; has && code != nil {
		return nil, engErr(id, "百度翻译错误 %v: %v", code, data["error_msg"])
	}
	dst := []string{}
	if arr, ok := data["trans_result"].([]any); ok {
		for _, e := range arr {
			m, _ := e.(map[string]any)
			s, _ := m["dst"].(string)
			dst = append(dst, s)
		}
	}
	if len(dst) != expected {
		// 行数对不齐(百度偶发合并空行),交给服务层缩小批次重试。
		return nil, engErr(id, "回包行数(%d)与请求(%d)不一致", len(dst), expected)
	}
	return dst, nil
}

// BaiduEngine 百度通用翻译。
//
// sign = MD5(appid + q + salt + 密钥)。多条字幕用 `\n` 拼成单个 q 一次提交,
// trans_result 按行回包,从而批量翻译。
type BaiduEngine struct{ Config BaiduConfig }

// ID 引擎标识。
func (e *BaiduEngine) ID() string { return "baidu_general" }

// 百度免费版 QPS=1,必须串行;单条 q 上限 6000 字节,按行数与字符双限。
func (e *BaiduEngine) MaxBatchSize() int   { return 50 }
func (e *BaiduEngine) MaxBatchChars() int  { return 2000 }
func (e *BaiduEngine) MaxConcurrency() int { return 1 }

func (e *BaiduEngine) endpoint() string {
	if e.Config.Endpoint != "" {
		return e.Config.Endpoint
	}
	return BaiduGeneralEndpoint
}

// Translate 一批翻译。
func (e *BaiduEngine) Translate(ctx context.Context, texts []string, sourceLang, targetLang string) ([]string, error) {
	if len(texts) == 0 {
		return []string{}, nil
	}
	q := strings.Join(flattenLines(texts), "\n")
	salt := baiduSalt(len(texts), q)
	sign := md5Hex(e.Config.AppID + q + salt + e.Config.SecretKey)

	form := url.Values{}
	form.Set("q", q)
	form.Set("from", ToBaidu(sourceLang))
	form.Set("to", ToBaidu(targetLang))
	form.Set("appid", e.Config.AppID)
	form.Set("salt", salt)
	form.Set("sign", sign)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, e.endpoint(),
		strings.NewReader(form.Encode()))
	if err != nil {
		return nil, engErr(e.ID(), "请求构造失败: %v", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	data, err := doAndDecode(e.ID(), req)
	if err != nil {
		return nil, err
	}
	return parseBaiduResponse(e.ID(), data, len(texts))
}

// BaiduLLMEngine 百度大模型文本翻译(POST JSON + Bearer API Key)。
//
// 推荐 Bearer 鉴权,未填 apiKey 时回退 appid+salt+sign。回包结构与通用接口一致。
type BaiduLLMEngine struct{ Config BaiduConfig }

// ID 引擎标识。
func (e *BaiduLLMEngine) ID() string { return "baidu_llm" }

func (e *BaiduLLMEngine) MaxBatchSize() int { return 40 }

// MaxBatchChars 单次 q 上限 6000 字符,留余量。
func (e *BaiduLLMEngine) MaxBatchChars() int  { return 2000 }
func (e *BaiduLLMEngine) MaxConcurrency() int { return 1 }

func (e *BaiduLLMEngine) endpoint() string {
	if e.Config.Endpoint != "" {
		return e.Config.Endpoint
	}
	return BaiduLLMEndpoint
}

// Translate 一批翻译。
func (e *BaiduLLMEngine) Translate(ctx context.Context, texts []string, sourceLang, targetLang string) ([]string, error) {
	if len(texts) == 0 {
		return []string{}, nil
	}
	q := strings.Join(flattenLines(texts), "\n")
	body := map[string]any{
		"appid": e.Config.AppID, "q": q,
		"from": ToBaidu(sourceLang), "to": ToBaidu(targetLang),
		"model_type": "llm",
	}
	headers := map[string]string{}
	if e.Config.APIKey != "" {
		headers["Authorization"] = "Bearer " + e.Config.APIKey
	} else {
		// 回退签名鉴权:appid+q+salt+密钥 的 MD5。
		salt := baiduSalt(len(texts), q)
		body["salt"] = salt
		body["sign"] = md5Hex(e.Config.AppID + q + salt + e.Config.SecretKey)
	}
	data, err := postJSON(ctx, e.ID(), e.endpoint(), body, headers)
	if err != nil {
		return nil, err
	}
	return parseBaiduResponse(e.ID(), data, len(texts))
}

// ---------------------------------------------------------------------------
// 腾讯机器翻译(TC3-HMAC-SHA256)
// ---------------------------------------------------------------------------

const (
	tencentService = "tmt"
	tencentVersion = "2018-03-21"
)

// TencentEngine 腾讯机器翻译(TextTranslateBatch)。
type TencentEngine struct{ Config TencentConfig }

// ID 引擎标识。
func (e *TencentEngine) ID() string { return "tencent" }

// 腾讯批量接口单次条数有限制,保守取 50;免费 QPS 较低,串行更稳。
func (e *TencentEngine) MaxBatchSize() int   { return 50 }
func (e *TencentEngine) MaxBatchChars() int  { return 4000 }
func (e *TencentEngine) MaxConcurrency() int { return 1 }

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func hmacSHA256(key, msg []byte) []byte {
	m := hmac.New(sha256.New, key)
	_, _ = m.Write(msg)
	return m.Sum(nil)
}

// buildAuthorization TC3-HMAC-SHA256 Authorization 头。
// 签名头固定 content-type;host;x-tc-action。
func (e *TencentEngine) buildAuthorization(action, payload string, ts int64, date string) string {
	const algorithm = "TC3-HMAC-SHA256"
	const signedHeaders = "content-type;host;x-tc-action"
	host := TencentEndpoint
	canonicalHeaders := "content-type:application/json; charset=utf-8\nhost:" + host +
		"\nx-tc-action:" + strings.ToLower(action) + "\n"
	canonicalRequest := "POST\n/\n\n" + canonicalHeaders + "\n" + signedHeaders + "\n" +
		sha256Hex([]byte(payload))
	credentialScope := date + "/" + tencentService + "/tc3_request"
	stringToSign := algorithm + "\n" + strconv.FormatInt(ts, 10) + "\n" + credentialScope + "\n" +
		sha256Hex([]byte(canonicalRequest))

	secretDate := hmacSHA256([]byte("TC3"+e.Config.SecretKey), []byte(date))
	secretService := hmacSHA256(secretDate, []byte(tencentService))
	secretSigning := hmacSHA256(secretService, []byte("tc3_request"))
	signature := hex.EncodeToString(hmacSHA256(secretSigning, []byte(stringToSign)))

	return fmt.Sprintf("%s Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		algorithm, e.Config.SecretID, credentialScope, signedHeaders, signature)
}

func (e *TencentEngine) call(ctx context.Context, action string, payloadMap map[string]any) (map[string]any, error) {
	raw, err := json.Marshal(payloadMap)
	if err != nil {
		return nil, engErr(e.ID(), "编码失败: %v", err)
	}
	payload := string(raw)
	now := time.Now().UTC()
	ts := now.Unix()
	date := now.Format("2006-01-02")

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://"+TencentEndpoint, strings.NewReader(payload))
	if err != nil {
		return nil, engErr(e.ID(), "请求构造失败: %v", err)
	}
	req.Header.Set("Authorization", e.buildAuthorization(action, payload, ts, date))
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	req.Host = TencentEndpoint
	req.Header.Set("X-TC-Action", action)
	req.Header.Set("X-TC-Timestamp", strconv.FormatInt(ts, 10))
	req.Header.Set("X-TC-Version", tencentVersion)
	req.Header.Set("X-TC-Region", e.Config.Region)

	data, err := doAndDecode(e.ID(), req)
	if err != nil {
		return nil, err
	}
	response, ok := data["Response"].(map[string]any)
	if !ok {
		return nil, engErr(e.ID(), "腾讯翻译响应缺少 Response 字段")
	}
	if errObj, ok := response["Error"].(map[string]any); ok && errObj != nil {
		return nil, engErr(e.ID(), "腾讯翻译错误 %v: %v", errObj["Code"], errObj["Message"])
	}
	return response, nil
}

// Translate 一批翻译。
func (e *TencentEngine) Translate(ctx context.Context, texts []string, sourceLang, targetLang string) ([]string, error) {
	if len(texts) == 0 {
		return []string{}, nil
	}
	source := ToTencent(sourceLang)
	target := ToTencent(targetLang)

	// ★ TextTranslateBatch **不支持源语言 auto**;源语言未知时退回支持 auto 的单条接口。
	if source == "auto" {
		out := make([]string, 0, len(texts))
		for _, t := range texts {
			r, err := e.call(ctx, "TextTranslate", map[string]any{
				"SourceText": t, "Source": source, "Target": target,
				"ProjectId": e.Config.ProjectID,
			})
			if err != nil {
				return nil, err
			}
			s, _ := r["TargetText"].(string)
			out = append(out, s)
		}
		return out, nil
	}

	r, err := e.call(ctx, "TextTranslateBatch", map[string]any{
		"Source": source, "Target": target,
		"ProjectId": e.Config.ProjectID, "SourceTextList": texts,
	})
	if err != nil {
		return nil, err
	}
	out := []string{}
	if arr, ok := r["TargetTextList"].([]any); ok {
		for _, v := range arr {
			s, _ := v.(string)
			out = append(out, s)
		}
	}
	if len(out) != len(texts) {
		return nil, engErr(e.ID(), "回包条数(%d)与请求(%d)不一致", len(out), len(texts))
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// 引擎工厂
// ---------------------------------------------------------------------------

// BuildEngine 按种类与配置构造引擎;**未配置返回 nil**(UI 据此禁用「翻译」入口)。
func BuildEngine(kind EngineKind, s Settings) Engine {
	switch kind {
	case EngineOpenAI:
		if s.OpenAI.IsConfigured() {
			return &AiEngine{Config: s.OpenAI}
		}
	case EngineAnthropic:
		if s.Anthropic.IsConfigured() {
			return &AiEngine{Anthropic: true, Config: s.Anthropic}
		}
	case EngineBaiduGeneral:
		if s.BaiduGeneral.IsConfigured() {
			return &BaiduEngine{Config: s.BaiduGeneral}
		}
	case EngineBaiduLLM:
		if s.BaiduLLM.IsConfigured() {
			return &BaiduLLMEngine{Config: s.BaiduLLM}
		}
	case EngineTencent:
		if s.Tencent.IsConfigured() {
			return &TencentEngine{Config: s.Tencent}
		}
	}
	return nil
}

// ActiveEngine 按当前设置里选中的引擎构造;未配置返回 nil。
func ActiveEngine(s Settings) Engine { return BuildEngine(s.Engine, s) }
