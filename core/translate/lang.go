package translate

// 语言码映射。各家翻译服务的语言码互不相同,统一先归一到内部基准码再转。

import "strings"

// LangAuto 自动检测源语言。
const LangAuto = "auto"

// LangTargetChinese 通用目标默认中文。
const LangTargetChinese = "zh"

// threeLetter 三字母码 → 两字母码。
var threeLetter = map[string]string{
	"eng": "en", "jpn": "ja", "kor": "ko", "fre": "fr", "fra": "fr",
	"ger": "de", "deu": "de", "rus": "ru", "spa": "es", "ita": "it",
	"por": "pt", "tha": "th", "vie": "vi", "ara": "ar", "hin": "hi",
	"ind": "id", "msa": "ms", "may": "ms", "tur": "tr", "nld": "nl",
	"dut": "nl", "pol": "pl",
}

// NormLang 把各式语言码归一为内部基准码(剥离地区后缀、三字母转两字母、繁简区分)。
//
// 例:`en-GB`→`en`、`zh-TW`→`zh-hant`、`jpn`→`ja`、`fre`→`fr`。
func NormLang(code string) string {
	c := strings.ReplaceAll(strings.ToLower(strings.TrimSpace(code)), "_", "-")
	if c == "" || c == "auto" || c == "und" {
		return "auto"
	}
	// 繁体中文家族。
	switch c {
	case "cht", "zh-tw", "zh-hant", "zh-hk", "zh-mo", "big5":
		return "zh-hant"
	}
	// 简体/泛中文家族。
	switch c {
	case "chs", "chi", "zho", "gb":
		return "zh-hans"
	}
	if strings.HasPrefix(c, "zh") {
		return "zh-hans"
	}
	base := strings.SplitN(c, "-", 2)[0]
	if v, ok := threeLetter[base]; ok {
		return v
	}
	return base
}

// ToBaidu 内部基准码 → 百度码(日语 jp,中文 zh/cht,未知回退 auto)。
func ToBaidu(code string) string {
	switch NormLang(code) {
	case "zh-hans":
		return "zh"
	case "zh-hant":
		return "cht"
	case "en":
		return "en"
	case "ja":
		return "jp"
	case "ko":
		return "kor"
	case "fr":
		return "fra"
	case "de":
		return "de"
	case "ru":
		return "ru"
	case "es":
		return "spa"
	case "it":
		return "it"
	case "pt":
		return "pt"
	case "th":
		return "th"
	case "vi":
		return "vie"
	case "ar":
		return "ara"
	case "nl":
		return "nl"
	case "pl":
		return "pl"
	}
	return "auto"
}

// ToTencent 内部基准码 → 腾讯码(日语 ja,中文 zh/zh-TW,未知回退 auto)。
func ToTencent(code string) string {
	switch n := NormLang(code); n {
	case "zh-hans":
		return "zh"
	case "zh-hant":
		return "zh-TW"
	case "en", "ja", "ko", "fr", "de", "ru", "es", "it", "pt",
		"th", "vi", "ar", "id", "ms", "tr", "hi":
		return n
	}
	return "auto"
}

// humanNames 内部基准码 → 人类可读语言名(喂给 AI 提示词)。
var humanNames = map[string]string{
	"auto": "the source language", "zh-hans": "Simplified Chinese",
	"zh-hant": "Traditional Chinese", "en": "English", "ja": "Japanese",
	"ko": "Korean", "fr": "French", "de": "German", "ru": "Russian",
	"es": "Spanish", "it": "Italian", "pt": "Portuguese", "th": "Thai",
	"vi": "Vietnamese", "ar": "Arabic",
}

// HumanLangName 语言的人话名字。
//
// ★ 未知码**原样喂给模型**(返回传入的 code 而不是归一码)——
// 归一码里剥掉的地区后缀对模型可能是有意义的。
func HumanLangName(code string) string {
	if name, ok := humanNames[NormLang(code)]; ok {
		return name
	}
	return code
}
