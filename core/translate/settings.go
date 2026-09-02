package translate

// 翻译模块设置。**独立文件,不塞 config.json**。
//
// ⚠️ 内含用户填的 apiKey/secretKey:与 config.json 里的 token 同等姿态(明文落盘)。
// 加固与 config 那边的待决项一并处理,不在本模块单独造轮子。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"linplayer/core/paths"
)

// EngineKind 引擎种类。
type EngineKind string

// 五种引擎。**这些字面量是存盘键 + 线上串**,改了等于把用户的选择作废。
const (
	EngineOpenAI       EngineKind = "openai"
	EngineAnthropic    EngineKind = "anthropic"
	EngineBaiduGeneral EngineKind = "baiduGeneral"
	EngineBaiduLLM     EngineKind = "baiduLlm"
	EngineTencent      EngineKind = "tencent"
)

// AllEngineKinds 顺序即设置页展示顺序。
var AllEngineKinds = []EngineKind{
	EngineOpenAI, EngineAnthropic, EngineBaiduGeneral, EngineBaiduLLM, EngineTencent,
}

// EngineKindFromKey 认一个引擎键。认不出回默认档。
func EngineKindFromKey(k string) EngineKind {
	for _, e := range AllEngineKinds {
		if string(e) == k {
			return e
		}
	}
	return EngineOpenAI
}

// Label 引擎的人话名字。
func (k EngineKind) Label() string {
	switch k {
	case EngineAnthropic:
		return "AI · Anthropic 格式"
	case EngineBaiduGeneral:
		return "百度通用翻译"
	case EngineBaiduLLM:
		return "百度大模型翻译"
	case EngineTencent:
		return "腾讯机器翻译"
	}
	return "AI · OpenAI 格式"
}

// IsAI 是不是大模型类引擎。
func (k EngineKind) IsAI() bool { return k == EngineOpenAI || k == EngineAnthropic }

// AiConfig AI 引擎配置(OpenAI / Anthropic 通用)。
type AiConfig struct {
	BaseURL string `json:"baseUrl"`
	APIKey  string `json:"apiKey"`
	Model   string `json:"model"`
}

// IsConfigured 配全了没。
func (c AiConfig) IsConfigured() bool { return c.APIKey != "" && c.BaseURL != "" }

// 两家的默认地址与默认模型。
//
// ★ 这两个是**厂商公开的 API 基址**,而且在设置页里是用户可改的输入框默认值 ——
// 和端口号一个性质,不是任何人的服务器地址,所以照黄金实现留在源码里。
func openAIDefault() AiConfig {
	return AiConfig{BaseURL: "https://api.openai.com/v1", Model: "gpt-4o-mini"}
}

func anthropicDefault() AiConfig {
	return AiConfig{BaseURL: "https://api.anthropic.com/v1", Model: "claude-haiku-4-5-20251001"}
}

// BaiduConfig 百度翻译配置(通用 / 大模型共用,endpoint 可改)。
type BaiduConfig struct {
	Endpoint  string `json:"endpoint"`
	AppID     string `json:"appId"`
	SecretKey string `json:"secretKey"`
	// APIKey 大模型接口的 Bearer API Key(通用接口不用)。
	APIKey string `json:"apiKey"`
}

// IsConfigured 配全了没。两种鉴权任意一种齐了就算。
func (c BaiduConfig) IsConfigured() bool {
	return c.AppID != "" && (c.SecretKey != "" || c.APIKey != "")
}

// 百度两个接口地址。
const (
	// BaiduGeneralEndpoint 通用翻译(q/from/to/appid/salt/sign,sign=MD5(appid+q+salt+密钥))。
	BaiduGeneralEndpoint = "https://fanyi-api.baidu.com/api/trans/vip/translate"
	// BaiduLLMEndpoint 大模型文本翻译(POST JSON + Bearer API Key,model_type=llm)。
	BaiduLLMEndpoint = "https://fanyi-api.baidu.com/ait/api/aiTextTranslate"
)

// TencentConfig 腾讯机器翻译配置。
type TencentConfig struct {
	SecretID  string `json:"secretId"`
	SecretKey string `json:"secretKey"`
	Region    string `json:"region"`
	ProjectID int64  `json:"projectId"`
}

// IsConfigured 配全了没。
func (c TencentConfig) IsConfigured() bool { return c.SecretID != "" && c.SecretKey != "" }

// TencentEndpoint 腾讯机器翻译的 host。
const TencentEndpoint = "tmt.tencentcloudapi.com"

// Settings 翻译模块设置。
type Settings struct {
	// Engine 当前选用的翻译引擎。
	Engine EngineKind `json:"engine"`
	// TargetLang 翻译目标语言(默认简体中文)。
	TargetLang string `json:"targetLang"`
	// Layout 双语排版方式。
	Layout Layout `json:"layout"`

	OpenAI       AiConfig      `json:"openai"`
	Anthropic    AiConfig      `json:"anthropic"`
	BaiduGeneral BaiduConfig   `json:"baiduGeneral"`
	BaiduLLM     BaiduConfig   `json:"baiduLlm"`
	Tencent      TencentConfig `json:"tencent"`

	// WhisperEnabled 是否启用 Whisper 本地转写(默认关闭,用户手动开启后再下载模型)。
	WhisperEnabled bool `json:"whisperEnabled"`
	// WhisperModel 选用的模型规格。
	WhisperModel string `json:"whisperModel"`
	// WhisperMirror 模型下载镜像(留空用官方源)。
	WhisperMirror string `json:"whisperMirror"`
	// WhisperBinary whisper-cli 可执行文件路径(用户指定,空 = 自动定位)。
	WhisperBinary string `json:"whisperBinary"`
	// FFmpegPath ffmpeg 可执行文件路径(音频抽取用,空 = 自动定位)。
	FFmpegPath string `json:"ffmpegPath"`
}

// DefaultSettings 全新的一份设置。
func DefaultSettings() Settings {
	return Settings{
		Engine:       EngineOpenAI,
		TargetLang:   LangTargetChinese,
		Layout:       LayoutTranslatedFirst,
		OpenAI:       openAIDefault(),
		Anthropic:    anthropicDefault(),
		Tencent:      TencentConfig{Region: "ap-beijing"},
		WhisperModel: string(WhisperBase),
	}
}

// settingsPath 与 config.json **并排放在数据根**:它俩都是「设置」,
// 用户打开数据目录一眼就该看见。
func settingsPath() string { return filepath.Join(paths.Root(), "translation.json") }

var settingsMu sync.Mutex

// LoadSettings 读设置。文件不在或读坏了都回默认档(设置读不出来不该让功能整体不可用)。
//
// ★ 缺字段要**逐个补默认值**,不能整份回默认:老配置里没有 whisperModel 这种新键,
// 整份回默认会把用户填的 API Key 一起冲掉。
func LoadSettings() Settings {
	settingsMu.Lock()
	defer settingsMu.Unlock()
	s := DefaultSettings()
	raw, err := os.ReadFile(settingsPath())
	if err != nil {
		return s
	}
	if json.Unmarshal(raw, &s) != nil {
		return DefaultSettings()
	}
	// 反序列化会把没写的字段清成零值,这里把「零值等于没配」的几项补回默认。
	d := DefaultSettings()
	if s.Engine == "" {
		s.Engine = d.Engine
	}
	if s.TargetLang == "" {
		s.TargetLang = d.TargetLang
	}
	if s.Layout == "" {
		s.Layout = d.Layout
	}
	if s.OpenAI.BaseURL == "" {
		s.OpenAI.BaseURL = d.OpenAI.BaseURL
	}
	if s.OpenAI.Model == "" {
		s.OpenAI.Model = d.OpenAI.Model
	}
	if s.Anthropic.BaseURL == "" {
		s.Anthropic.BaseURL = d.Anthropic.BaseURL
	}
	if s.Anthropic.Model == "" {
		s.Anthropic.Model = d.Anthropic.Model
	}
	if s.Tencent.Region == "" {
		s.Tencent.Region = d.Tencent.Region
	}
	if s.WhisperModel == "" {
		s.WhisperModel = d.WhisperModel
	}
	return s
}

// SaveSettings 落盘。
func (s Settings) SaveSettings() error {
	settingsMu.Lock()
	defer settingsMu.Unlock()
	path := settingsPath()
	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("建设置目录失败: %w", err)
		}
	}
	raw, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, raw, 0o644)
}
