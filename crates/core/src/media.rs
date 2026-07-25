// 媒体轨道类型 + 选轨偏好(正则优先,语言兜底)。桌面/安卓共用。
//
// 「正则优先选择」是 2026-06 就有的功能(Dart lib/core/utils/track_preference.dart),
// 重构时随 Flutter 一起删掉了,但 wiki 的 regex-filters 页一直挂着 —— 文档在描述一个
// 不存在的功能。这里按那份文档的口径重新实现,**文档即契约**:
//   版本 = 名称 + 容器 + 分辨率 + 编码 + 显示名   (在 emby.rs 的 source_match_text)
//   字幕 = 显示名/标题 + 语言 + 编码
//   音频 = 显示名/标题 + 语言 + 编码 + 声道(如 `6ch`)
//
// ★ 与 Dart 版的一处**真实差异**:Dart 用的是 JS 系正则(支持前后瞻/反向引用),
//   这里是 Rust 的 regex crate(线性时间保证,故**不支持** `(?=)` `(?!)` `\1`)。
//   所以设置页的合法性校验必须问 Rust(validate_track_regex),不能用浏览器的 RegExp ——
//   否则 JS 说合法、存进去 Rust 编译不过,表现是「设了没反应」而且一声不吭。
use regex::{Regex, RegexBuilder};
use serde::Serialize;

#[derive(Serialize, Clone)]
pub struct Track {
    pub kind: String, // "audio" | "sub"
    pub id: String,
    pub title: String,
    pub lang: String,
    pub selected: bool,
    /// 编码(mpv `track-list/N/codec`)。正则筛选要匹配它,见上面的文档口径。
    pub codec: String,
    /// 声道数,0 = 未知/非音轨。拼进匹配文本时写成 `6ch`。
    pub channels: i64,
}

impl Track {
    /// 这条轨道的**可匹配文本**。正则命中其中任意一处即算匹配。
    pub fn match_text(&self) -> String {
        let mut s = format!("{} {} {}", self.title, self.lang, self.codec);
        if self.channels > 0 {
            s.push_str(&format!(" {}ch", self.channels));
        }
        s
    }
}

/// 编译一条偏好正则。空串或非法 → `None`,调用方据此**回退到默认行为**(语言匹配/第一条)。
///
/// 大小写不敏感;Rust regex 天生 unicode-aware,所以中文可以直接写(`简` `繁` `日`)。
pub fn compile_preference(pattern: &str) -> Option<Regex> {
    let p = pattern.trim();
    if p.is_empty() {
        return None;
    }
    RegexBuilder::new(p).case_insensitive(true).build().ok()
}

/// 设置页用的合法性校验。空串算合法(= 关闭该筛选)。
pub fn validate_track_regex(pattern: &str) -> Result<(), String> {
    let p = pattern.trim();
    if p.is_empty() {
        return Ok(());
    }
    RegexBuilder::new(p).case_insensitive(true).build().map(|_| ()).map_err(|e| e.to_string())
}

/// 在一组「可匹配文本」里找第一条命中正则的,返回下标。
/// 正则空/非法 → `None`(不是「没匹配上」,是「没启用」,两者对调用方都是回退默认)。
pub fn pick_index<S: AsRef<str>>(texts: &[S], pattern: &str) -> Option<usize> {
    let re = compile_preference(pattern)?;
    texts.iter().position(|t| re.is_match(t.as_ref()))
}

/// 选轨偏好。正则优先于语言 —— 对齐 wiki 写明的优先级:
/// 「手动切过的轨 ＞ 正则命中 ＞ 首选语言/服务端默认」(手动那层在前端,不在这)。
#[derive(Default, Clone, Copy)]
pub struct TrackPrefs<'a> {
    pub audio_lang: Option<&'a str>,
    pub sub_lang: Option<&'a str>,
    pub sub_enabled: bool,
    pub audio_regex: &'a str,
    pub sub_regex: &'a str,
}

/// 按偏好挑音轨/字幕轨。
/// 返回 (aid, sid):`Some(id)` = 切到该轨;`Some("no")` = 关字幕;`None` = 保持不变。
pub fn pick_tracks(tracks: &[Track], p: TrackPrefs<'_>) -> (Option<String>, Option<String>) {
    let aid = pick_one(tracks, "audio", p.audio_regex, p.audio_lang);
    let sid = if !p.sub_enabled {
        Some("no".to_string())
    } else {
        pick_one(tracks, "sub", p.sub_regex, p.sub_lang)
    };
    (aid, sid)
}

fn pick_one(tracks: &[Track], kind: &str, regex: &str, lang: Option<&str>) -> Option<String> {
    let of_kind: Vec<&Track> = tracks.iter().filter(|t| t.kind == kind).collect();
    if of_kind.is_empty() {
        return None;
    }
    // 1) 正则
    let texts: Vec<String> = of_kind.iter().map(|t| t.match_text()).collect();
    if let Some(i) = pick_index(&texts, regex) {
        return Some(of_kind[i].id.clone());
    }
    // 2) 语言/标题包含匹配(旧行为)
    let want = lang?.trim().to_lowercase();
    if want.is_empty() {
        return None;
    }
    of_kind
        .iter()
        .find(|t| t.lang.to_lowercase().contains(&want) || t.title.to_lowercase().contains(&want))
        .map(|t| t.id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn t(kind: &str, id: &str, lang: &str, title: &str) -> Track {
        Track {
            kind: kind.into(),
            id: id.into(),
            title: title.into(),
            lang: lang.into(),
            selected: false,
            codec: String::new(),
            channels: 0,
        }
    }
    fn full(kind: &str, id: &str, lang: &str, title: &str, codec: &str, ch: i64) -> Track {
        Track { codec: codec.into(), channels: ch, ..t(kind, id, lang, title) }
    }

    #[test]
    fn picks_by_lang_and_respects_sub_toggle() {
        let tracks = vec![
            t("audio", "1", "jpn", "日本語"),
            t("audio", "2", "eng", "English"),
            t("sub", "3", "chi", "简体中文"),
        ];
        let p = TrackPrefs {
            audio_lang: Some("eng"),
            sub_lang: Some("chi"),
            sub_enabled: true,
            ..Default::default()
        };
        let (aid, sid) = pick_tracks(&tracks, p);
        assert_eq!(aid.as_deref(), Some("2"));
        assert_eq!(sid.as_deref(), Some("3"));
        // 关字幕
        let (_, sid_off) = pick_tracks(&tracks, TrackPrefs { sub_enabled: false, ..p });
        assert_eq!(sid_off.as_deref(), Some("no"));
        // 无匹配 -> 保持不变
        let (aid_none, _) =
            pick_tracks(&tracks, TrackPrefs { audio_lang: Some("kor"), ..Default::default() });
        assert_eq!(aid_none, None);
    }

    /// ★ 这条测的是「正则**赢过**语言」——不是「正则能匹配」。
    /// 故意让语言偏好指向另一条轨:如果哪天有人把正则挪到语言之后,这条会红。
    #[test]
    fn regex_beats_lang() {
        let tracks = vec![
            full("audio", "1", "jpn", "日本語 2.0", "aac", 2),
            full("audio", "2", "jpn", "日本語 FLAC", "flac", 6),
            full("sub", "3", "chi", "简体", "ass", 0),
            full("sub", "4", "chi", "繁體", "ass", 0),
        ];
        let (aid, sid) = pick_tracks(
            &tracks,
            TrackPrefs {
                audio_lang: Some("jpn"), // 单看语言会选中 "1"
                sub_lang: Some("chi"),   // 单看语言会选中 "3"
                sub_enabled: true,
                audio_regex: r"flac|truehd",
                sub_regex: r"繁|cht|big5",
            },
        );
        assert_eq!(aid.as_deref(), Some("2"), "正则应盖过语言偏好");
        assert_eq!(sid.as_deref(), Some("4"), "正则应盖过语言偏好");
    }

    #[test]
    fn matches_codec_and_channels_per_wiki() {
        // wiki 承诺音频筛选能匹配「编码」和「声道(如 6ch)」——Track 早先没这两个字段,
        // 补上了才对得起文档。这条测的就是那份承诺。
        let tracks = vec![
            full("audio", "1", "eng", "English", "aac", 2),
            full("audio", "2", "eng", "English", "truehd", 8),
        ];
        let by_ch = pick_tracks(&tracks, TrackPrefs { audio_regex: "8ch", ..Default::default() });
        assert_eq!(by_ch.0.as_deref(), Some("2"));
        let by_codec =
            pick_tracks(&tracks, TrackPrefs { audio_regex: "truehd", ..Default::default() });
        assert_eq!(by_codec.0.as_deref(), Some("2"));
    }

    #[test]
    fn illegal_and_empty_regex_fall_back_not_crash() {
        let tracks = vec![t("audio", "1", "jpn", "日本語"), t("audio", "2", "eng", "English")];
        // 非法正则 = 当作没设,回退语言
        let (aid, _) = pick_tracks(
            &tracks,
            TrackPrefs { audio_lang: Some("eng"), audio_regex: "[unclosed", ..Default::default() },
        );
        assert_eq!(aid.as_deref(), Some("2"));
        assert!(validate_track_regex("[unclosed").is_err());
        assert!(validate_track_regex("").is_ok());
        assert!(validate_track_regex(r"中文|简|繁|chi|zh").is_ok());
        // Rust regex 不支持前后瞻:必须**报错**而不是静默吞掉,否则用户抄了 JS 的写法
        // 会得到一个「存下了但永不命中」的设置。
        assert!(validate_track_regex(r"(?=chi)").is_err());
    }

    #[test]
    fn case_insensitive_and_unicode() {
        let tracks = vec![t("sub", "1", "zh-CN", "简体中文")];
        for pat in [r"ZH", r"简", r"zh-cn"] {
            let (_, sid) = pick_tracks(
                &tracks,
                TrackPrefs { sub_enabled: true, sub_regex: pat, ..Default::default() },
            );
            assert_eq!(sid.as_deref(), Some("1"), "pattern {pat} 应命中");
        }
    }

    #[test]
    fn pick_index_returns_first_match_in_order() {
        let texts = ["1080p x264", "2160p HEVC", "2160p AV1"];
        assert_eq!(pick_index(&texts, "2160|4K"), Some(1), "按列表顺序取第一条命中的");
        assert_eq!(pick_index(&texts, "8K"), None);
        assert_eq!(pick_index(&texts, ""), None, "空 = 未启用");
    }
}
