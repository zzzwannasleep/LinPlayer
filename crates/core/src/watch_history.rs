// 本地观看记录 + 跨服务器续播。旧 Dart(lib/core/services/watch_history/*.dart)的等价移植。
//
// 三件事:
//   1. 记录:每台服务器(scope)各存一条自己的观看记录,存 watch_history.json(独立于 config.json)。
//   2. 匹配:canonicalKey/指纹与服务器无关(TMDB / PresentationUniqueKey / 剧名+季集号),
//      所以同一影片在不同服务器之间能对上 —— 跨服续播与回传都建立在这上面。
//   3. 续播:候选进度 = 远端进度 ∪ 本服本地记录 ∪(可选)其它服务器记录,**取最大值**。
//
// ★ 分层:纯逻辑(匹配/选择/存盘)在这里;需要 HTTP 的那几步(查 Series 的 TMDB id、搜索候选、
//   往其它服务器写回)由宿主接线后把结果喂进来 —— 见文件末尾「宿主接线」注释。
use crate::emby::Item;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

/// Emby 的时间单位:1 tick = 100ns。
pub const TICKS_PER_SEC: i64 = 10_000_000;

/// 已看进度容差:远端进度比本地记录落后超过 30s 才值得回写(Dart _positionToleranceTicks)。
const POSITION_TOLERANCE_TICKS: i64 = 30 * TICKS_PER_SEC;

/// 扫描恢复时最多看几条记录(Dart _maxScanRecords)。
pub const MAX_SCAN_RECORDS: usize = 15;

/// 同一条记录的进度写盘最小间隔(秒);播放期每秒都调 capture 也只落一次。
const PROGRESS_WRITE_INTERVAL_SECS: i64 = 10;

// ---------- 枚举(wire 值与旧 Dart 逐字一致)----------

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum MediaKind {
    #[serde(rename = "movie")]
    Movie,
    #[serde(rename = "episode")]
    Episode,
}

impl MediaKind {
    pub fn wire(&self) -> &'static str {
        match self {
            MediaKind::Movie => "movie",
            MediaKind::Episode => "episode",
        }
    }
    /// Emby 的 Item.Type → 记录类型;其它类型(Series/Season/BoxSet…)不记录。
    pub fn from_item_type(type_: &str) -> Option<MediaKind> {
        match type_.to_lowercase().as_str() {
            "movie" => Some(MediaKind::Movie),
            "episode" => Some(MediaKind::Episode),
            _ => None,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum WriteSource {
    #[serde(rename = "internal_player")]
    InternalPlayer,
    #[serde(rename = "external_mpv")]
    ExternalMpv,
}
impl Default for WriteSource {
    fn default() -> Self {
        // Dart fromWire:未知/缺省一律当内置播放器。
        WriteSource::InternalPlayer
    }
}

/// 匹配置信度。★ 派生的 Ord 依赖变体顺序(None < Weak < Possible < Strong),别调换。
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Default)]
pub enum MatchConfidence {
    #[serde(rename = "none")]
    #[default]
    None,
    #[serde(rename = "weak")]
    Weak,
    #[serde(rename = "possible")]
    Possible,
    #[serde(rename = "strong")]
    Strong,
}

impl MatchConfidence {
    /// 可用于跨服续播/回传的置信度(Dart 里两处都只认 strong/possible,避免误续播)。
    pub fn is_trusted(&self) -> bool {
        matches!(self, MatchConfidence::Strong | MatchConfidence::Possible)
    }
}

/// 看完 / 进度回传到「其它服务器」的目标范围。
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum WritebackRange {
    /// 所有有本地记录的其它服务器。
    #[serde(rename = "all")]
    #[default]
    All,
    /// 仅最早看过该内容的那台服务器(通常是主库)。
    #[serde(rename = "first")]
    First,
    /// 仅除当前服外、最近看过该内容的那台服务器。
    #[serde(rename = "latest")]
    Latest,
}

impl WritebackRange {
    pub fn from_wire(value: &str) -> WritebackRange {
        match value {
            "first" => WritebackRange::First,
            "latest" => WritebackRange::Latest,
            _ => WritebackRange::All,
        }
    }
    pub fn wire(&self) -> &'static str {
        match self {
            WritebackRange::All => "all",
            WritebackRange::First => "first",
            WritebackRange::Latest => "latest",
        }
    }
    /// 设置页展示用。
    pub fn label(&self) -> &'static str {
        match self {
            WritebackRange::All => "所有看过的服务器",
            WritebackRange::First => "仅初次看过的服务器",
            WritebackRange::Latest => "仅最近看过的服务器",
        }
    }
}

// ---------- 记录 ----------

/// 一条观看记录。一个 scope(服务器+用户)× 一份内容 = 一条。
///
/// 时间戳用 epoch 毫秒(与 crate 内 download/sync/plugins 一致;crate 无 chrono,
/// 旧 Dart 存的是 ISO8601 —— 存盘目录本就不同,不存在读旧文件的兼容需求)。
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Record {
    pub record_id: String,
    /// `server:user_id`,见 [`scope_key`]。
    pub scope_key: String,
    pub media_kind: MediaKind,
    pub canonical_key: String,
    #[serde(default)]
    pub tmdb_id: Option<String>,
    #[serde(default)]
    pub series_tmdb_id: Option<String>,
    pub title: String,
    #[serde(default)]
    pub series_title: Option<String>,
    #[serde(default)]
    pub season_number: Option<i64>,
    #[serde(default)]
    pub episode_number: Option<i64>,
    #[serde(default)]
    pub year: Option<i64>,
    pub last_position_ticks: i64,
    #[serde(default)]
    pub run_time_ticks: Option<i64>,
    pub played: bool,
    pub play_count: i64,
    pub last_played_at: i64,
    /// 该 scope 首次记录此内容的时间。旧记录可能为 None,回退到 last_played_at
    /// (见 [`Record::effective_first_played_at`])。
    #[serde(default)]
    pub first_played_at: Option<i64>,
    #[serde(default)]
    pub last_emby_item_id: Option<String>,
    #[serde(default)]
    pub match_confidence: MatchConfidence,
    #[serde(default)]
    pub restored_at: Option<i64>,
    #[serde(default)]
    pub last_write_source: WriteSource,
    #[serde(default)]
    pub presentation_unique_key: Option<String>,
    #[serde(default)]
    pub media_path: Option<String>,
}

impl Record {
    /// 首次观看时间,旧记录缺失时回退到 last_played_at。
    pub fn effective_first_played_at(&self) -> i64 {
        self.first_played_at.unwrap_or(self.last_played_at)
    }
}

#[derive(Serialize, Deserialize)]
pub struct Document {
    #[serde(default = "one")]
    pub schema_version: i64,
    #[serde(default)]
    pub updated_at: i64,
    #[serde(default)]
    pub records: Vec<Record>,
}
fn one() -> i64 {
    1
}
impl Default for Document {
    fn default() -> Self {
        Document { schema_version: 1, updated_at: 0, records: Vec::new() }
    }
}

/// 待匹配的条目 = 旧 Dart `MediaItem` 里观看记录用得上的那部分字段。
///
/// ★ 为什么不直接用 [`Item`]:emby.rs 的 Item 没有 ProviderIds / PresentationUniqueKey / Path,
/// 而这三样正是 canonicalKey 与强匹配的判据。[`Candidate::from`] 负责把 Item 有的搬过来,
/// 缺的三项留 None,由宿主取详情后补(补不上就自动降级到「剧名+季集号」那条路径,不会崩)。
#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Candidate {
    pub id: String,
    pub name: String,
    /// Emby 的 Item.Type 原值(Movie / Episode / …)。
    pub type_: String,
    /// ProviderIds["Tmdb"],见 [`extract_provider_id`]。
    pub tmdb_id: Option<String>,
    /// 剧集所属剧的 id;宿主靠它去查剧的 TMDB id。
    pub series_id: Option<String>,
    pub series_name: Option<String>,
    pub presentation_unique_key: Option<String>,
    pub path: Option<String>,
    pub season_no: Option<i64>,
    pub episode_no: Option<i64>,
    pub year: Option<i64>,
    pub run_time_ticks: Option<i64>,
    /// 远端 UserData.Played。
    pub played: bool,
    /// 远端 UserData.PlaybackPositionTicks。
    pub position_ticks: i64,
}

impl From<&Item> for Candidate {
    fn from(it: &Item) -> Self {
        Candidate {
            id: it.id.clone(),
            name: it.name.clone(),
            type_: it.type_.clone(),
            // 这四项要请求带 Fields=ProviderIds,PresentationUniqueKey,Path,SeriesId
            // (见 emby::HISTORY_FIELDS / item_for_history);没带 Fields 的列表端点取到的
            // Item 这里就是 None,匹配自动降级到「剧名+季集号」——不崩,但强匹配失效。
            tmdb_id: extract_provider_id(&it.provider_ids, "Tmdb"),
            presentation_unique_key: it.presentation_unique_key.clone(),
            path: it.path.clone(),
            series_id: it.series_id.clone(),
            series_name: it.series_name.clone(),
            season_no: it.season_no,
            episode_no: it.episode_no,
            year: it.year,
            run_time_ticks: Some((it.runtime_secs * TICKS_PER_SEC as f64) as i64),
            played: it.played,
            position_ticks: (it.resume_secs * TICKS_PER_SEC as f64) as i64,
        }
    }
}

/// 指纹:归一化后的匹配判据。
#[derive(Clone, Debug)]
pub struct Fingerprint {
    pub media_kind: MediaKind,
    pub canonical_key: String,
    pub title: String,
    pub normalized_title: String,
    pub series_title: Option<String>,
    pub normalized_series_title: String,
    pub tmdb_id: Option<String>,
    pub series_tmdb_id: Option<String>,
    pub season_number: Option<i64>,
    pub episode_number: Option<i64>,
    pub year: Option<i64>,
    pub presentation_unique_key: Option<String>,
    pub normalized_presentation_unique_key: Option<String>,
    pub media_path: Option<String>,
    pub normalized_path_stem: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct MatchResult {
    pub confidence: MatchConfidence,
    pub reason: String,
}
impl MatchResult {
    fn new(confidence: MatchConfidence, reason: &str) -> Self {
        MatchResult { confidence, reason: reason.to_string() }
    }
}

/// 一条「可恢复」的候选:记录 + 在本服匹配到的条目。
/// 需要 Deserialize:possible 匹配要交给用户确认,确认后前端把这个候选原样传回来调
/// [`crate::watch_history_sync::restore_candidate`]。
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct RestoreCandidate {
    pub record: Record,
    pub matched_item: Candidate,
    pub confidence: MatchConfidence,
    pub reason: String,
}

// ---------- 归一化 / 键 ----------

/// ProviderIds 取值(键名大小写不敏感,空串当没有)。
pub fn extract_provider_id(provider_ids: &HashMap<String, String>, key: &str) -> Option<String> {
    provider_ids
        .iter()
        .find(|(k, _)| k.to_lowercase() == key.to_lowercase())
        .map(|(_, v)| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

fn re_brackets() -> &'static regex::Regex {
    static R: OnceLock<regex::Regex> = OnceLock::new();
    R.get_or_init(|| regex::Regex::new(r"\[[^\]]*\]").unwrap())
}
fn re_parens() -> &'static regex::Regex {
    static R: OnceLock<regex::Regex> = OnceLock::new();
    R.get_or_init(|| regex::Regex::new(r"\([^)]*\)").unwrap())
}
fn re_junk() -> &'static regex::Regex {
    static R: OnceLock<regex::Regex> = OnceLock::new();
    R.get_or_init(|| regex::Regex::new(r"[^a-z0-9\u{4e00}-\u{9fff}]+").unwrap())
}

/// 标题归一化:小写 → 去 [..]/(..) → 非「字母数字汉字」折成空格 → 压空白。
pub fn normalize_text(value: &str) -> String {
    let lowered = value.to_lowercase();
    let lowered = lowered.trim();
    if lowered.is_empty() {
        return String::new();
    }
    let s = re_brackets().replace_all(lowered, " ");
    let s = re_parens().replace_all(&s, " ");
    // re_junk 已把连续分隔符合成一个空格,等价于 Dart 的两步 replaceAll(\s+ → ' ')。
    re_junk().replace_all(&s, " ").trim().to_string()
}

pub fn normalize_presentation_unique_key(value: Option<&str>) -> Option<String> {
    value.map(|v| v.trim().to_lowercase()).filter(|v| !v.is_empty())
}

/// 取文件名(去扩展名)后再做标题归一化。
/// ★ 与 Dart 的一点差异:Dart 用宿主平台的 path 语义(Windows 上才认 `\`),
/// 这里两种分隔符都认 —— 记录里存的是**服务器端**路径,与客户端平台无关。
pub fn normalize_path_stem(value: Option<&str>) -> Option<String> {
    let text = value.map(str::trim).filter(|v| !v.is_empty())?;
    let base = text.rsplit(['/', '\\']).next().unwrap_or(text);
    // 末段是扩展名则去掉;`.hidden`(点在首位)不算扩展名,与 Dart basenameWithoutExtension 一致。
    let stem = match base.rfind('.') {
        Some(i) if i > 0 => &base[..i],
        _ => base,
    };
    Some(normalize_text(stem))
}

fn pad_index(value: i64) -> String {
    format!("{value:02}")
}

/// 与服务器无关的内容标识 —— 跨服匹配全靠它。优先级:TMDB > PUK > 标题(+年份/季集号)> itemId。
#[allow(clippy::too_many_arguments)]
pub fn build_canonical_key(
    media_kind: MediaKind,
    item_id: &str,
    tmdb_id: Option<&str>,
    series_tmdb_id: Option<&str>,
    presentation_unique_key: Option<&str>,
    normalized_title: &str,
    normalized_series_title: &str,
    season_number: Option<i64>,
    episode_number: Option<i64>,
    year: Option<i64>,
) -> String {
    let puk = normalize_presentation_unique_key(presentation_unique_key);
    let tmdb_id = tmdb_id.filter(|v| !v.is_empty());
    let series_tmdb_id = series_tmdb_id.filter(|v| !v.is_empty());

    if media_kind == MediaKind::Movie {
        if let Some(t) = tmdb_id {
            return format!("movie:tmdb:{t}");
        }
        if let Some(p) = puk.filter(|p| !p.is_empty()) {
            return format!("movie:puk:{p}");
        }
        if !normalized_title.is_empty() {
            let year_segment = year.map(|y| y.to_string()).unwrap_or_else(|| "unknown".into());
            return format!("movie:title:{normalized_title}:year:{year_segment}");
        }
        return format!("movie:item:{item_id}");
    }

    if let (Some(st), Some(s), Some(e)) = (series_tmdb_id, season_number, episode_number) {
        return format!("series:tmdb:{st}:s{}:e{}", pad_index(s), pad_index(e));
    }
    if let (Some(t), Some(s), Some(e)) = (tmdb_id, season_number, episode_number) {
        return format!("episode:tmdb:{t}:s{}:e{}", pad_index(s), pad_index(e));
    }
    if let Some(p) = puk.filter(|p| !p.is_empty()) {
        return format!("episode:puk:{p}");
    }
    if let (false, Some(s), Some(e)) =
        (normalized_series_title.is_empty(), season_number, episode_number)
    {
        return format!(
            "episode:title:{normalized_series_title}:s{}:e{}",
            pad_index(s),
            pad_index(e)
        );
    }
    format!("episode:item:{item_id}")
}

pub fn build_record_id(scope_key: &str, media_kind: MediaKind, canonical_key: &str) -> String {
    format!("{scope_key}:{}:{canonical_key}", media_kind.wire())
}

/// scopeKey = `server:user_id`(server 是归一化后的 URL)。
pub fn scope_key(server: &str, user_id: &str) -> String {
    format!("{server}:{user_id}")
}

/// 从 scopeKey 还原 server。★ server 是 URL(自带 `https://` 甚至 `:8096`),
/// 所以必须按**最后一个**冒号切,与 Dart _serverIdFromScope 同解法。
pub fn server_from_scope(scope_key: &str) -> &str {
    match scope_key.rfind(':') {
        Some(i) if i > 0 => &scope_key[..i],
        _ => scope_key,
    }
}

// ---------- 指纹 ----------

/// 候选条目 → 指纹。非 Movie/Episode 返回 None(不记录)。
/// `series_tmdb_id` 由宿主查剧详情后喂进来;只对 Episode 生效。
pub fn build_fingerprint_from_candidate(
    c: &Candidate,
    series_tmdb_id: Option<&str>,
) -> Option<Fingerprint> {
    let media_kind = MediaKind::from_item_type(&c.type_)?;
    let resolved_series_tmdb_id = if media_kind == MediaKind::Episode {
        series_tmdb_id.map(String::from)
    } else {
        None
    };
    let normalized_title = normalize_text(&c.name);
    let normalized_series_title = normalize_text(c.series_name.as_deref().unwrap_or(""));

    Some(Fingerprint {
        media_kind,
        canonical_key: build_canonical_key(
            media_kind,
            &c.id,
            c.tmdb_id.as_deref(),
            resolved_series_tmdb_id.as_deref(),
            c.presentation_unique_key.as_deref(),
            &normalized_title,
            &normalized_series_title,
            c.season_no,
            c.episode_no,
            c.year,
        ),
        title: c.name.clone(),
        normalized_title,
        series_title: c.series_name.clone(),
        normalized_series_title,
        tmdb_id: c.tmdb_id.clone(),
        series_tmdb_id: resolved_series_tmdb_id,
        season_number: c.season_no,
        episode_number: c.episode_no,
        year: c.year,
        presentation_unique_key: c.presentation_unique_key.clone(),
        normalized_presentation_unique_key: normalize_presentation_unique_key(
            c.presentation_unique_key.as_deref(),
        ),
        media_path: c.path.clone(),
        normalized_path_stem: normalize_path_stem(c.path.as_deref()),
    })
}

pub fn build_fingerprint_from_record(r: &Record) -> Fingerprint {
    Fingerprint {
        media_kind: r.media_kind,
        canonical_key: r.canonical_key.clone(),
        title: r.title.clone(),
        normalized_title: normalize_text(&r.title),
        series_title: r.series_title.clone(),
        normalized_series_title: normalize_text(r.series_title.as_deref().unwrap_or("")),
        tmdb_id: r.tmdb_id.clone(),
        series_tmdb_id: r.series_tmdb_id.clone(),
        season_number: r.season_number,
        episode_number: r.episode_number,
        year: r.year,
        presentation_unique_key: r.presentation_unique_key.clone(),
        normalized_presentation_unique_key: normalize_presentation_unique_key(
            r.presentation_unique_key.as_deref(),
        ),
        media_path: r.media_path.clone(),
        normalized_path_stem: normalize_path_stem(r.media_path.as_deref()),
    }
}

// ---------- 匹配(跨服的地基)----------

/// 记录 ↔ 候选条目的匹配。`unique_candidate=true` 表示「候选池里只有它」,
/// 此时把 weak 提升为 possible(Dart 同款:唯一候选下弱证据也够用)。
pub fn match_record_to_candidate(
    record: &Record,
    candidate: &Candidate,
    candidate_series_tmdb_id: Option<&str>,
    unique_candidate: bool,
) -> MatchResult {
    let record_print = build_fingerprint_from_record(record);
    let Some(candidate_print) = build_fingerprint_from_candidate(candidate, candidate_series_tmdb_id)
    else {
        return MatchResult::new(MatchConfidence::None, "类型不匹配");
    };
    if record_print.media_kind != candidate_print.media_kind {
        return MatchResult::new(MatchConfidence::None, "类型不匹配");
    }

    // PUK 一致 = 同一台服务器上的同一条目,最强证据。
    let record_puk = record_print.normalized_presentation_unique_key.as_deref();
    let candidate_puk = candidate_print.normalized_presentation_unique_key.as_deref();
    if let Some(rp) = record_puk.filter(|p| !p.is_empty()) {
        if Some(rp) == candidate_puk {
            return MatchResult::new(MatchConfidence::Strong, "PresentationUniqueKey 匹配");
        }
    }

    if record.media_kind == MediaKind::Movie {
        match_movie(&record_print, &candidate_print, unique_candidate)
    } else {
        match_episode(&record_print, &candidate_print, unique_candidate)
    }
}

/// 两个 Option<String> 都有值且相等。None == None 不算匹配(Dart 的 `x != null && x == y`)。
fn same_some(left: Option<&String>, right: Option<&String>) -> bool {
    matches!((left, right), (Some(l), Some(r)) if l == r)
}

fn match_movie(record: &Fingerprint, candidate: &Fingerprint, unique_candidate: bool) -> MatchResult {
    let same_tmdb = same_some(record.tmdb_id.as_ref(), candidate.tmdb_id.as_ref());
    let same_title =
        !record.normalized_title.is_empty() && record.normalized_title == candidate.normalized_title;
    let close_title = titles_close_enough(&record.normalized_title, &candidate.normalized_title);
    let same_year = matches!((record.year, candidate.year), (Some(l), Some(r)) if l == r);
    let same_path_stem =
        same_some(record.normalized_path_stem.as_ref(), candidate.normalized_path_stem.as_ref());

    let maybe = if unique_candidate { MatchConfidence::Possible } else { MatchConfidence::Weak };

    if same_tmdb && same_title {
        return MatchResult::new(MatchConfidence::Strong, "标题 + TMDB 匹配");
    }
    if same_title && same_year {
        return MatchResult::new(maybe, "标题 + 年份匹配");
    }
    if close_title && same_path_stem {
        return MatchResult::new(maybe, "标题 + 文件名匹配");
    }
    if close_title && unique_candidate {
        return MatchResult::new(MatchConfidence::Possible, "标题接近且候选唯一");
    }
    MatchResult::new(MatchConfidence::None, "电影关键信息不足")
}

fn match_episode(
    record: &Fingerprint,
    candidate: &Fingerprint,
    unique_candidate: bool,
) -> MatchResult {
    let same_series_tmdb = same_some(record.series_tmdb_id.as_ref(), candidate.series_tmdb_id.as_ref());
    let same_episode_tmdb = same_some(record.tmdb_id.as_ref(), candidate.tmdb_id.as_ref());
    let same_season_episode = record.season_number.is_some()
        && record.episode_number.is_some()
        && record.season_number == candidate.season_number
        && record.episode_number == candidate.episode_number;
    let same_series_title = !record.normalized_series_title.is_empty()
        && record.normalized_series_title == candidate.normalized_series_title;
    let same_path_stem =
        same_some(record.normalized_path_stem.as_ref(), candidate.normalized_path_stem.as_ref());

    let maybe = if unique_candidate { MatchConfidence::Possible } else { MatchConfidence::Weak };

    if same_series_tmdb && same_season_episode {
        return MatchResult::new(MatchConfidence::Strong, "剧集 TMDB + 季集号匹配");
    }
    if same_episode_tmdb && same_season_episode {
        return MatchResult::new(MatchConfidence::Strong, "单集 TMDB + 季集号匹配");
    }
    if same_season_episode && same_series_title {
        return MatchResult::new(maybe, "剧名 + 季集号匹配");
    }
    if same_season_episode && same_path_stem {
        return MatchResult::new(maybe, "文件名 + 季集号匹配");
    }
    MatchResult::new(MatchConfidence::None, "剧集关键信息不足")
}

fn titles_close_enough(left: &str, right: &str) -> bool {
    if left.is_empty() || right.is_empty() {
        return false;
    }
    left == right || left.contains(right) || right.contains(left)
}

// ---------- 存盘 ----------

fn default_history_path() -> PathBuf {
    // data/ 不是 cache/:观看记录删了就真没了,不能被"清理缓存"顺手带走。
    crate::paths::data_root().join("watch_history.json")
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// watch_history.json 的读写。★ 所有写都是「读-改-写」,必须整段串行
/// (对应 Dart 的 _enqueueWrite 队列),否则两次 capture 并发会互相吃掉对方的记录。
pub struct Store {
    path: PathBuf,
    write_lock: Mutex<()>,
}

impl Default for Store {
    fn default() -> Self {
        Store::new(default_history_path())
    }
}

impl Store {
    pub fn new(path: PathBuf) -> Self {
        Store { path, write_lock: Mutex::new(()) }
    }

    /// 读盘。文件不存在/空/损坏一律当空文档 —— 观看记录不值得为一次解析失败挡住播放。
    pub fn load_document(&self) -> Document {
        std::fs::read_to_string(&self.path)
            .ok()
            .filter(|s| !s.trim().is_empty())
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    /// 某服务器的记录,按最近播放倒序。
    pub fn load_scope(&self, scope_key: &str) -> Vec<Record> {
        let mut records: Vec<Record> = self
            .load_document()
            .records
            .into_iter()
            .filter(|r| r.scope_key == scope_key)
            .collect();
        sort_records(&mut records);
        records
    }

    /// 全部记录(跨服务器,不按 scope 过滤)。跨服续播匹配与设置页统计/清理用。
    pub fn load_all(&self) -> Vec<Record> {
        let mut records = self.load_document().records;
        sort_records(&mut records);
        records
    }

    pub fn clear_all(&self) {
        let _g = self.write_lock.lock().unwrap_or_else(|e| e.into_inner());
        self.write_document(Vec::new());
    }

    /// 写一条。`replace_record_ids` 里的旧记录一并删掉(canonicalKey 变了时换 id 用)。
    pub fn save_record(&self, record: Record, replace_record_ids: &[String]) {
        let _g = self.write_lock.lock().unwrap_or_else(|e| e.into_inner());
        let mut records: Vec<Record> = self
            .load_document()
            .records
            .into_iter()
            .filter(|e| {
                e.record_id != record.record_id
                    && !replace_record_ids.iter().any(|id| *id == e.record_id)
            })
            .collect();
        records.push(record);
        sort_records(&mut records);
        self.write_document(records);
    }

    pub fn save_records(&self, incoming: Vec<Record>) {
        let _g = self.write_lock.lock().unwrap_or_else(|e| e.into_inner());
        let mut merged: Vec<Record> = self
            .load_document()
            .records
            .into_iter()
            .filter(|e| !incoming.iter().any(|i| i.record_id == e.record_id))
            .collect();
        merged.extend(incoming);
        sort_records(&mut merged);
        self.write_document(merged);
    }

    pub fn delete_record(&self, record_id: &str) {
        let _g = self.write_lock.lock().unwrap_or_else(|e| e.into_inner());
        let records: Vec<Record> = self
            .load_document()
            .records
            .into_iter()
            .filter(|e| e.record_id != record_id)
            .collect();
        self.write_document(records);
    }

    fn write_document(&self, records: Vec<Record>) {
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let doc = Document { schema_version: 1, updated_at: now_ms(), records };
        if let Ok(json) = serde_json::to_string_pretty(&doc) {
            let _ = std::fs::write(&self.path, format!("{json}\n"));
        }
    }
}

fn sort_records(records: &mut [Record]) {
    records.sort_by(|l, r| r.last_played_at.cmp(&l.last_played_at));
}

// ---------- 服务:续播 / 记录 ----------

/// 观看记录服务。持 Store + 进度写盘节流表(对应 Dart 的 _lastProgressWriteAt)。
pub struct WatchHistory {
    store: Store,
    last_progress_write_at: Mutex<HashMap<String, i64>>,
}

impl Default for WatchHistory {
    fn default() -> Self {
        WatchHistory::new(Store::default())
    }
}

impl WatchHistory {
    pub fn new(store: Store) -> Self {
        WatchHistory { store, last_progress_write_at: Mutex::new(HashMap::new()) }
    }

    pub fn store(&self) -> &Store {
        &self.store
    }

    pub fn load_scope(&self, scope_key: &str) -> Vec<Record> {
        self.store.load_scope(scope_key)
    }

    pub fn load_all(&self) -> Vec<Record> {
        self.store.load_all()
    }

    pub fn clear_all(&self) {
        self.last_progress_write_at.lock().unwrap_or_else(|e| e.into_inner()).clear();
        self.store.clear_all();
    }

    pub fn delete_record(&self, record_id: &str) {
        self.last_progress_write_at.lock().unwrap_or_else(|e| e.into_inner()).remove(record_id);
        self.store.delete_record(record_id);
    }

    /// ★ 续播位置决策 —— 这个模块的主产出。
    ///
    /// 候选进度取**最大值**:远端进度、本服本地记录,外加(cross_server=true 时)其它服务器的记录。
    /// 已看完就不续播:远端 played 直接返回 None;本服本地记录 played 时只信远端
    /// (避免跨服记录覆盖用户在本服的「已看完」)。
    pub fn resolve_resume_position_ticks(
        &self,
        scope_key: &str,
        candidate: &Candidate,
        series_tmdb_id: Option<&str>,
        remote_position_ticks: Option<i64>,
        remote_played: bool,
        cross_server: bool,
    ) -> Option<i64> {
        if remote_played {
            return None;
        }
        let normalized_remote =
            normalize_position_ticks(remote_position_ticks, candidate.run_time_ticks);
        let Some(fingerprint) = build_fingerprint_from_candidate(candidate, series_tmdb_id) else {
            return normalized_remote;
        };

        let records = self.store.load_scope(scope_key);
        let existing = find_existing_record(&records, &fingerprint, &candidate.id);

        if existing.is_some_and(|e| e.played) {
            return normalized_remote;
        }

        let mut best = normalized_remote;
        best = max_position_ticks(
            best,
            normalize_position_ticks(
                existing.map(|e| e.last_position_ticks),
                candidate.run_time_ticks.or_else(|| existing.and_then(|e| e.run_time_ticks)),
            ),
        );

        if cross_server {
            best = max_position_ticks(
                best,
                self.cross_server_position_ticks(candidate, series_tmdb_id, scope_key),
            );
        }
        best
    }

    /// 扫描其它服务器(scope)下的记录,找与当前条目匹配的最远进度。
    /// 复用 [`match_record_to_candidate`]:canonicalKey/指纹与服务器无关,所以同一集能跨服对上。
    /// 仅采用 strong / possible,避免误续播。
    fn cross_server_position_ticks(
        &self,
        candidate: &Candidate,
        series_tmdb_id: Option<&str>,
        current_scope_key: &str,
    ) -> Option<i64> {
        let all = self.store.load_all();
        if all.is_empty() {
            return None;
        }
        let mut best: Option<i64> = None;
        for record in &all {
            // 本服记录已在上层处理。
            if record.scope_key == current_scope_key {
                continue;
            }
            if record.played || record.last_position_ticks <= 0 {
                continue;
            }
            let m = match_record_to_candidate(record, candidate, series_tmdb_id, true);
            if !m.confidence.is_trusted() {
                continue;
            }
            best = max_position_ticks(
                best,
                normalize_position_ticks(
                    Some(record.last_position_ticks),
                    candidate.run_time_ticks.or(record.run_time_ticks),
                ),
            );
        }
        best
    }

    /// 播放期落记录。返回落盘后的记录;非 Movie/Episode 返回 None(不记录)。
    ///
    /// 节流:同一条记录 10s 内重复调用直接返回既有记录(force / increment_play_count 例外)。
    #[allow(clippy::too_many_arguments)]
    pub fn capture_playback(
        &self,
        scope_key: &str,
        candidate: &Candidate,
        series_tmdb_id: Option<&str>,
        position_ticks: i64,
        source: WriteSource,
        watched_threshold_percent: i64,
        increment_play_count: bool,
        force: bool,
    ) -> Option<Record> {
        let fingerprint = build_fingerprint_from_candidate(candidate, series_tmdb_id)?;

        let records = self.store.load_scope(scope_key);
        let existing = find_existing_record(&records, &fingerprint, &candidate.id).cloned();
        let record_id =
            build_record_id(scope_key, fingerprint.media_kind, &fingerprint.canonical_key);

        if !force
            && existing.is_some()
            && !increment_play_count
            && !self.should_persist_progress(&record_id)
        {
            return existing;
        }

        let now = now_ms();
        let played = is_played(position_ticks, candidate.run_time_ticks, watched_threshold_percent);
        let next_play_count = existing.as_ref().map(|e| e.play_count).unwrap_or(0)
            + if increment_play_count || existing.is_none() { 1 } else { 0 };
        let hi = candidate.run_time_ticks.unwrap_or(position_ticks).max(0);

        let record = Record {
            record_id: record_id.clone(),
            scope_key: scope_key.to_string(),
            media_kind: fingerprint.media_kind,
            canonical_key: fingerprint.canonical_key.clone(),
            tmdb_id: fingerprint.tmdb_id.clone(),
            series_tmdb_id: fingerprint.series_tmdb_id.clone(),
            title: candidate.name.clone(),
            series_title: candidate.series_name.clone(),
            season_number: candidate.season_no,
            episode_number: candidate.episode_no,
            year: candidate.year,
            last_position_ticks: position_ticks.clamp(0, hi),
            run_time_ticks: candidate.run_time_ticks,
            played,
            play_count: next_play_count,
            last_played_at: now,
            first_played_at: Some(
                existing
                    .as_ref()
                    .and_then(|e| e.first_played_at)
                    .or_else(|| existing.as_ref().map(|e| e.last_played_at))
                    .unwrap_or(now),
            ),
            last_emby_item_id: Some(candidate.id.clone()),
            match_confidence: existing.as_ref().map(|e| e.match_confidence).unwrap_or_default(),
            restored_at: existing.as_ref().and_then(|e| e.restored_at),
            last_write_source: source,
            presentation_unique_key: candidate.presentation_unique_key.clone(),
            media_path: candidate.path.clone(),
        };

        // canonicalKey 变了(比如这次终于查到 TMDB id)→ 旧 id 的记录要删掉,不然一份内容两条。
        let replaced: Vec<String> = existing
            .as_ref()
            .filter(|e| e.record_id != record.record_id)
            .map(|e| vec![e.record_id.clone()])
            .unwrap_or_default();
        self.store.save_record(record.clone(), &replaced);
        {
            let mut m = self.last_progress_write_at.lock().unwrap_or_else(|e| e.into_inner());
            m.insert(record_id.clone(), now);
            for old in &replaced {
                m.remove(old);
            }
        }
        Some(record)
    }

    fn should_persist_progress(&self, record_id: &str) -> bool {
        let m = self.last_progress_write_at.lock().unwrap_or_else(|e| e.into_inner());
        match m.get(record_id) {
            None => true,
            Some(at) => (now_ms() - at) / 1000 >= PROGRESS_WRITE_INTERVAL_SECS,
        }
    }

    /// 回传成功后同步本地的目标记录,保持本地状态一致(Dart propagate 尾部那段 copyWith)。
    pub fn record_writeback_result(&self, target: &Record, played: bool, position_ticks: i64) {
        let mut updated = target.clone();
        updated.played = played || target.played;
        updated.last_position_ticks =
            if position_ticks > target.last_position_ticks && !target.played {
                position_ticks
            } else {
                target.last_position_ticks
            };
        self.store.save_record(updated, &[]);
    }
}

/// 已看判定:看过 watched_threshold_percent% 即算看完。无时长 → 判不了,不算看完。
fn is_played(position_ticks: i64, run_time_ticks: Option<i64>, watched_threshold_percent: i64) -> bool {
    match run_time_ticks {
        Some(rt) if rt > 0 => {
            position_ticks as f64 / rt as f64 >= watched_threshold_percent as f64 / 100.0
        }
        _ => false,
    }
}

/// 进度归一化:<=0 视为「没有进度」(None);有时长则夹到时长内。
fn normalize_position_ticks(position_ticks: Option<i64>, runtime_ticks: Option<i64>) -> Option<i64> {
    let p = position_ticks.filter(|p| *p > 0)?;
    match runtime_ticks {
        Some(rt) if rt > 0 => Some(p.clamp(0, rt)),
        _ => Some(p),
    }
}

pub fn max_position_ticks(left: Option<i64>, right: Option<i64>) -> Option<i64> {
    match (left, right) {
        (None, r) => r,
        (l, None) => l,
        (Some(l), Some(r)) => Some(l.max(r)),
    }
}

/// 本服里找同一份内容的既有记录:canonicalKey → lastEmbyItemId → PUK,三级兜底。
fn find_existing_record<'a>(
    records: &'a [Record],
    fingerprint: &Fingerprint,
    item_id: &str,
) -> Option<&'a Record> {
    if let Some(r) = records.iter().find(|r| r.canonical_key == fingerprint.canonical_key) {
        return Some(r);
    }
    if let Some(r) = records.iter().find(|r| r.last_emby_item_id.as_deref() == Some(item_id)) {
        return Some(r);
    }
    let candidate_puk = fingerprint.normalized_presentation_unique_key.as_deref()?;
    if candidate_puk.is_empty() {
        return None;
    }
    records.iter().find(|r| {
        normalize_presentation_unique_key(r.presentation_unique_key.as_deref()).as_deref()
            == Some(candidate_puk)
    })
}

// ---------- 恢复(换服/重装后把本地记录推回服务器)----------

/// 该记录相对服务器上的现状,是否值得回写。
pub fn needs_restore(record: &Record, item: &Candidate) -> bool {
    if record.played {
        return !item.played;
    }
    if item.played {
        return false;
    }
    let target_ticks = record.last_position_ticks;
    if target_ticks <= 0 {
        return false;
    }
    let current_ticks = item.position_ticks;
    if current_ticks <= 0 {
        return true;
    }
    // 差得不到 30s 就别折腾服务器。
    current_ticks + POSITION_TOLERANCE_TICKS < target_ticks
}

/// 恢复时用什么关键词去搜:电影用片名,剧集用剧名(退回片名)。全空 → 搜不了。
pub fn restore_search_query(record: &Record) -> Option<&str> {
    let query = match record.media_kind {
        MediaKind::Movie => record.title.as_str(),
        MediaKind::Episode => record.series_title.as_deref().unwrap_or(&record.title),
    };
    Some(query).filter(|q| !q.trim().is_empty())
}

/// 从搜索结果里挑出唯一可信的候选。`candidates` 每项 = (条目, 该条目所属剧的 TMDB id)。
///
/// 规则逐字对齐 Dart _resolveCandidate 的后半段:
///   同类型 → 取前 10 → 逐个 match(unique=false) → 留下非 none 的
///   恰好 1 个 strong → 选它;多个 strong → 放弃(分不清);
///   非 strong 且总共只剩 1 个 → 用 unique=true 重算置信度后选它;否则放弃。
/// 返回 (在 `candidates` 中的下标, 重算后的匹配结果)。
pub fn pick_restore_candidate(
    record: &Record,
    candidates: &[(Candidate, Option<String>)],
) -> Option<(usize, MatchResult)> {
    let matches: Vec<(usize, MatchResult)> = candidates
        .iter()
        .enumerate()
        .filter(|(_, (c, _))| MediaKind::from_item_type(&c.type_) == Some(record.media_kind))
        .take(10)
        .map(|(i, (c, series_tmdb))| {
            (i, match_record_to_candidate(record, c, series_tmdb.as_deref(), false))
        })
        .filter(|(_, m)| m.confidence != MatchConfidence::None)
        .collect();

    if matches.is_empty() {
        return None;
    }
    let strong: Vec<&(usize, MatchResult)> =
        matches.iter().filter(|(_, m)| m.confidence == MatchConfidence::Strong).collect();
    if strong.len() == 1 {
        let (i, m) = strong[0];
        return Some((*i, m.clone()));
    }
    if strong.len() > 1 {
        return None;
    }
    if matches.len() != 1 {
        return None;
    }
    // 只剩一个候选 → 它就是「唯一候选」,按 unique 重算(weak 会升成 possible)。
    let (i, _) = matches[0];
    let (c, series_tmdb) = &candidates[i];
    Some((i, match_record_to_candidate(record, c, series_tmdb.as_deref(), true)))
}

// ---------- 回传(把本服的看完/进度写到其它服务器)----------

/// 挑出要回传的目标记录(每台其它服务器最多一条,取该服最近看的那条)。
///
/// 返回空 = 无需回传(没看完且不带进度回传 / 没有匹配的其它服务器)。
/// 仅采用 strong / possible 匹配,且记录必须带 last_emby_item_id(否则不知道写到哪个条目)。
#[allow(clippy::too_many_arguments)]
pub fn writeback_targets(
    all: &[Record],
    current_scope_key: &str,
    candidate: &Candidate,
    series_tmdb_id: Option<&str>,
    range: WritebackRange,
    played: bool,
    include_progress: bool,
    position_ticks: i64,
) -> Vec<Record> {
    if !played && (!include_progress || position_ticks <= 0) {
        return Vec::new();
    }
    // 按 scope 去重,保留每台服务器最近的那条。
    let mut by_scope: HashMap<String, Record> = HashMap::new();
    for record in all {
        if record.scope_key == current_scope_key {
            continue;
        }
        if record.last_emby_item_id.as_deref().unwrap_or("").is_empty() {
            continue;
        }
        if !match_record_to_candidate(record, candidate, series_tmdb_id, true).confidence.is_trusted()
        {
            continue;
        }
        match by_scope.get(&record.scope_key) {
            Some(e) if e.last_played_at >= record.last_played_at => {}
            _ => {
                by_scope.insert(record.scope_key.clone(), record.clone());
            }
        }
    }
    let mut targets: Vec<Record> = by_scope.into_values().collect();
    match range {
        WritebackRange::All => {
            // HashMap 出来是乱序;定序只为结果稳定可测,Dart 里这一支不排序。
            targets.sort_by(|a, b| b.last_played_at.cmp(&a.last_played_at));
        }
        WritebackRange::First => {
            targets.sort_by_key(|r| r.effective_first_played_at());
            targets.truncate(1);
        }
        WritebackRange::Latest => {
            targets.sort_by(|a, b| b.last_played_at.cmp(&a.last_played_at));
            targets.truncate(1);
        }
    }
    targets
}

/// 会话内去重键:同一目标条目 + 同一看完状态 + 同一分钟进度只回传一次。
/// 宿主自持一个 HashSet<String> 即可(Dart 的 _done)。
pub fn writeback_dedup_key(scope_key: &str, item_id: &str, played: bool, position_ticks: i64) -> String {
    let bucket = position_ticks / (60 * TICKS_PER_SEC); // 1 分钟粒度
    format!("{}|{item_id}|{played}|{bucket}", server_from_scope(scope_key))
}

// ---------- 宿主接线 ----------
//
// 需要 HTTP 的三步在核心之外(core 不该自持第二套 Emby 客户端):
//   1. series_tmdb_id:GET /Users/{u}/Items/{seriesId}?Fields=ProviderIds → ProviderIds.Tmdb,
//      用 extract_provider_id() 取值,按 seriesId 缓存(Dart _seriesTmdbCache 就是这个)。
//   2. Candidate 的 tmdb_id / presentation_unique_key / path:同一次详情请求里带
//      Fields=ProviderIds,PresentationUniqueKey,Path 拿到后填进 Candidate(Item 里没有这三项)。
//   3. 恢复/回传的实际写入:emby::set_played / report_start+report_progress+report_stopped。
//
// 恢复扫描的宿主循环 = load_scope(scope).take(MAX_SCAN_RECORDS) → 先试 last_emby_item_id
// (取详情后 match_record_to_candidate(unique=true),none 则搜)→ restore_search_query()
// → emby::search → pick_restore_candidate() → needs_restore() → strong 自动恢复、
// possible 交给用户确认 → 写回后 save_records() 更新 last_emby_item_id/match_confidence/restored_at。

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试用 Store。路径必须带 pid —— 只带测试名的话,两个 cargo test 进程
    /// (如 `cargo test` 与 IDE 同时跑)会踩同一个文件,表现为随机 flaky。
    fn tmp_store(name: &str) -> Store {
        let p = std::env::temp_dir()
            .join(format!("linplayer_wh_test_{name}_{}.json", std::process::id()));
        let _ = std::fs::remove_file(&p);
        Store::new(p)
    }

    fn episode(id: &str, series: &str, s: i64, e: i64) -> Candidate {
        Candidate {
            id: id.into(),
            name: format!("第 {e} 集"),
            type_: "Episode".into(),
            series_name: Some(series.into()),
            season_no: Some(s),
            episode_no: Some(e),
            run_time_ticks: Some(2400 * TICKS_PER_SEC),
            ..Default::default()
        }
    }

    fn movie(id: &str, name: &str, year: i64) -> Candidate {
        Candidate {
            id: id.into(),
            name: name.into(),
            type_: "Movie".into(),
            year: Some(year),
            run_time_ticks: Some(7200 * TICKS_PER_SEC),
            ..Default::default()
        }
    }

    fn record_from(scope: &str, c: &Candidate, series_tmdb: Option<&str>, pos: i64) -> Record {
        let fp = build_fingerprint_from_candidate(c, series_tmdb).unwrap();
        Record {
            record_id: build_record_id(scope, fp.media_kind, &fp.canonical_key),
            scope_key: scope.into(),
            media_kind: fp.media_kind,
            canonical_key: fp.canonical_key.clone(),
            tmdb_id: fp.tmdb_id.clone(),
            series_tmdb_id: fp.series_tmdb_id.clone(),
            title: c.name.clone(),
            series_title: c.series_name.clone(),
            season_number: c.season_no,
            episode_number: c.episode_no,
            year: c.year,
            last_position_ticks: pos,
            run_time_ticks: c.run_time_ticks,
            played: false,
            play_count: 1,
            last_played_at: 1000,
            first_played_at: Some(1000),
            last_emby_item_id: Some(c.id.clone()),
            match_confidence: MatchConfidence::None,
            restored_at: None,
            last_write_source: WriteSource::InternalPlayer,
            presentation_unique_key: c.presentation_unique_key.clone(),
            media_path: c.path.clone(),
        }
    }

    // ===== 匹配 =====

    /// 剧集 TMDB + 季集号 = 强匹配,这是跨服的主路径(两台服务器 itemId/PUK 都不同)。
    #[test]
    fn episode_matches_across_servers_by_series_tmdb() {
        let here = episode("srvA-1", "凡人修仙传", 1, 35);
        let there = episode("srvB-9", "凡人修仙传", 1, 35);
        let rec = record_from("https://a:u1", &here, Some("95479"), 600 * TICKS_PER_SEC);
        let m = match_record_to_candidate(&rec, &there, Some("95479"), true);
        assert_eq!(m.confidence, MatchConfidence::Strong);
        assert_eq!(m.reason, "剧集 TMDB + 季集号匹配");
    }

    /// 没有 TMDB 时退到「剧名 + 季集号」:候选唯一才升到 possible,否则只是 weak。
    #[test]
    fn episode_title_and_index_depends_on_uniqueness() {
        let here = episode("a1", "凡人修仙传", 1, 35);
        let there = episode("b1", "凡人修仙传", 1, 35);
        let rec = record_from("https://a:u1", &here, None, 600 * TICKS_PER_SEC);
        assert_eq!(
            match_record_to_candidate(&rec, &there, None, false).confidence,
            MatchConfidence::Weak
        );
        assert_eq!(
            match_record_to_candidate(&rec, &there, None, true).confidence,
            MatchConfidence::Possible
        );
        // 集号不同 → 不匹配。
        let other = episode("b2", "凡人修仙传", 1, 36);
        assert_eq!(
            match_record_to_candidate(&rec, &other, None, true).confidence,
            MatchConfidence::None
        );
    }

    /// 电影 vs 剧集:类型不同一律 none(别把《沙丘》的进度续到某集上)。
    #[test]
    fn movie_and_episode_never_match() {
        let m = movie("a1", "沙丘", 2021);
        let e = episode("b1", "沙丘", 1, 1);
        let rec = record_from("https://a:u1", &m, None, 100);
        assert_eq!(match_record_to_candidate(&rec, &e, None, true).confidence, MatchConfidence::None);
        let rec_e = record_from("https://a:u1", &e, None, 100);
        assert_eq!(match_record_to_candidate(&rec_e, &m, None, true).confidence, MatchConfidence::None);
    }

    /// 电影:TMDB+标题=strong;标题+年份看唯一性;年份不同且无其它证据=none。
    #[test]
    fn movie_match_ladder() {
        let mut here = movie("a1", "沙丘", 2021);
        here.tmdb_id = Some("438631".into());
        let mut there = movie("b1", "沙丘", 2021);
        there.tmdb_id = Some("438631".into());
        let rec = record_from("https://a:u1", &here, None, 100);
        assert_eq!(match_record_to_candidate(&rec, &there, None, false).confidence, MatchConfidence::Strong);

        // 无 TMDB → 标题+年份。
        let plain = movie("a1", "沙丘", 2021);
        let rec2 = record_from("https://a:u1", &plain, None, 100);
        let other = movie("b1", "沙丘", 2021);
        assert_eq!(match_record_to_candidate(&rec2, &other, None, false).confidence, MatchConfidence::Weak);
        assert_eq!(match_record_to_candidate(&rec2, &other, None, true).confidence, MatchConfidence::Possible);

        // 年份不同 + 非唯一候选 → none(标题接近只在唯一候选下才够)。
        let remake = movie("b2", "沙丘", 1984);
        assert_eq!(match_record_to_candidate(&rec2, &remake, None, false).confidence, MatchConfidence::None);
        assert_eq!(match_record_to_candidate(&rec2, &remake, None, true).confidence, MatchConfidence::Possible);
    }

    /// PUK 一致 → 无视其它一切,strong。
    #[test]
    fn puk_wins_immediately() {
        let mut here = movie("a1", "沙丘", 2021);
        here.presentation_unique_key = Some("PUK-123".into());
        let mut there = movie("b1", "完全不同的名字", 1999);
        there.presentation_unique_key = Some("puk-123".into()); // 大小写不敏感
        let rec = record_from("https://a:u1", &here, None, 100);
        let m = match_record_to_candidate(&rec, &there, None, false);
        assert_eq!(m.confidence, MatchConfidence::Strong);
        assert_eq!(m.reason, "PresentationUniqueKey 匹配");
    }

    /// 两边都没 TMDB/PUK 时,None==None 不能算「相同」。
    #[test]
    fn missing_ids_are_not_a_match() {
        let a = movie("a1", "甲片", 2020);
        let b = movie("b1", "乙片", 2020);
        let rec = record_from("https://a:u1", &a, None, 100);
        // 标题不同 + 年份相同 → 仍不匹配(same_title 为假)。
        assert_eq!(match_record_to_candidate(&rec, &b, None, false).confidence, MatchConfidence::None);
    }

    // ===== 归一化 / 键 =====

    #[test]
    fn normalize_text_strips_brackets_and_junk() {
        assert_eq!(normalize_text("[Sub] 凡人修仙传 (2020) - S01E35!"), "凡人修仙传 s01e35");
        assert_eq!(normalize_text("  "), "");
        assert_eq!(normalize_text("Dune: Part Two"), "dune part two");
    }

    #[test]
    fn path_stem_handles_both_separators() {
        assert_eq!(normalize_path_stem(Some("/media/tv/Fanren.S01E35.mkv")).as_deref(), Some("fanren s01e35"));
        assert_eq!(normalize_path_stem(Some(r"D:\media\Dune.2021.mkv")).as_deref(), Some("dune 2021"));
        assert_eq!(normalize_path_stem(Some("")), None);
        assert_eq!(normalize_path_stem(None), None);
    }

    #[test]
    fn canonical_key_priority() {
        assert_eq!(
            build_canonical_key(MediaKind::Movie, "i1", Some("438631"), None, Some("puk"), "沙丘", "", None, None, Some(2021)),
            "movie:tmdb:438631"
        );
        assert_eq!(
            build_canonical_key(MediaKind::Movie, "i1", None, None, Some("PUK"), "沙丘", "", None, None, Some(2021)),
            "movie:puk:puk"
        );
        assert_eq!(
            build_canonical_key(MediaKind::Movie, "i1", None, None, None, "沙丘", "", None, None, None),
            "movie:title:沙丘:year:unknown"
        );
        assert_eq!(
            build_canonical_key(MediaKind::Movie, "i1", None, None, None, "", "", None, None, None),
            "movie:item:i1"
        );
        // 剧集:季集号补零到两位。
        assert_eq!(
            build_canonical_key(MediaKind::Episode, "i1", None, Some("95479"), None, "", "凡人", Some(1), Some(5), None),
            "series:tmdb:95479:s01:e05"
        );
        // 有 seriesTmdb 但缺季集号 → 落到下一档。
        assert_eq!(
            build_canonical_key(MediaKind::Episode, "i1", None, Some("95479"), None, "", "凡人", None, Some(5), None),
            "episode:item:i1"
        );
        assert_eq!(
            build_canonical_key(MediaKind::Episode, "i1", None, None, None, "", "凡人", Some(1), Some(5), None),
            "episode:title:凡人:s01:e05"
        );
    }

    /// scopeKey 里的 server 是 URL,自带冒号 —— 必须按最后一个冒号切。
    #[test]
    fn server_from_scope_handles_url_colons() {
        assert_eq!(server_from_scope("https://smart.uhdnow.com:8096:user1"), "https://smart.uhdnow.com:8096");
        assert_eq!(server_from_scope("https://a.com:u1"), "https://a.com");
        assert_eq!(server_from_scope("noscope"), "noscope");
    }

    // ===== 跨服续播:取最大进度 =====

    /// 核心场景:A 服看到 10 分钟,B 服看到 20 分钟,在 A 服播放时应续到 20 分钟。
    #[test]
    fn cross_server_takes_max_progress() {
        let wh = WatchHistory::new(tmp_store("cross_max"));
        let ep_a = episode("a-ep", "凡人修仙传", 1, 35);
        let ep_b = episode("b-ep", "凡人修仙传", 1, 35);
        let ten = 600 * TICKS_PER_SEC;
        let twenty = 1200 * TICKS_PER_SEC;
        wh.store().save_records(vec![
            record_from("https://a:u1", &ep_a, Some("95479"), ten),
            record_from("https://b:u2", &ep_b, Some("95479"), twenty),
        ]);

        // 开跨服 → 拿到 B 服的 20 分钟。
        let got = wh.resolve_resume_position_ticks("https://a:u1", &ep_a, Some("95479"), None, false, true);
        assert_eq!(got, Some(twenty));
        // 关跨服 → 只认本服的 10 分钟。
        let got = wh.resolve_resume_position_ticks("https://a:u1", &ep_a, Some("95479"), None, false, false);
        assert_eq!(got, Some(ten));
        // 远端进度更大 → 远端赢(三方取最大)。
        let thirty = 1800 * TICKS_PER_SEC;
        let got = wh.resolve_resume_position_ticks("https://a:u1", &ep_a, Some("95479"), Some(thirty), false, true);
        assert_eq!(got, Some(thirty));
    }

    /// 本服记录已标记看完 → 不续播(不让跨服记录覆盖用户在本服的"已看完")。
    #[test]
    fn played_in_current_scope_blocks_cross_server() {
        let wh = WatchHistory::new(tmp_store("played_blocks"));
        let ep_a = episode("a-ep", "凡人修仙传", 1, 35);
        let ep_b = episode("b-ep", "凡人修仙传", 1, 35);
        let mut rec_a = record_from("https://a:u1", &ep_a, Some("95479"), 600 * TICKS_PER_SEC);
        rec_a.played = true;
        wh.store().save_records(vec![
            rec_a,
            record_from("https://b:u2", &ep_b, Some("95479"), 1200 * TICKS_PER_SEC),
        ]);
        // 只剩远端进度(这里没有)→ None。
        assert_eq!(
            wh.resolve_resume_position_ticks("https://a:u1", &ep_a, Some("95479"), None, false, true),
            None
        );
        // 远端有进度 → 只返回远端的,不掺跨服的 20 分钟。
        let five = 300 * TICKS_PER_SEC;
        assert_eq!(
            wh.resolve_resume_position_ticks("https://a:u1", &ep_a, Some("95479"), Some(five), false, true),
            Some(five)
        );
    }

    /// 其它服的记录已看完 / 无进度 → 不参与跨服取值。
    #[test]
    fn cross_server_skips_played_and_zero_records() {
        let wh = WatchHistory::new(tmp_store("cross_skip"));
        let ep_a = episode("a-ep", "凡人修仙传", 1, 35);
        let ep_b = episode("b-ep", "凡人修仙传", 1, 35);
        let ep_c = episode("c-ep", "凡人修仙传", 1, 35);
        let mut played_b = record_from("https://b:u2", &ep_b, Some("95479"), 1200 * TICKS_PER_SEC);
        played_b.played = true;
        let zero_c = record_from("https://c:u3", &ep_c, Some("95479"), 0);
        wh.store().save_records(vec![played_b, zero_c]);
        assert_eq!(
            wh.resolve_resume_position_ticks("https://a:u1", &ep_a, Some("95479"), None, false, true),
            None
        );
    }

    /// 别的服看的是别的剧 → 不匹配 → 不续播。
    #[test]
    fn cross_server_ignores_unrelated_records() {
        let wh = WatchHistory::new(tmp_store("cross_unrelated"));
        let mine = episode("a-ep", "凡人修仙传", 1, 35);
        let other = episode("b-ep", "斗破苍穹", 1, 35);
        wh.store().save_records(vec![record_from("https://b:u2", &other, Some("11111"), 1200 * TICKS_PER_SEC)]);
        assert_eq!(
            wh.resolve_resume_position_ticks("https://a:u1", &mine, Some("95479"), None, false, true),
            None
        );
    }

    /// 远端已看完 → 直接不续播,连本地记录都不看。
    #[test]
    fn remote_played_short_circuits() {
        let wh = WatchHistory::new(tmp_store("remote_played"));
        let ep = episode("a-ep", "凡人修仙传", 1, 35);
        wh.store().save_records(vec![record_from("https://b:u2", &ep, Some("95479"), 1200 * TICKS_PER_SEC)]);
        assert_eq!(
            wh.resolve_resume_position_ticks("https://a:u1", &ep, Some("95479"), Some(999), true, true),
            None
        );
    }

    /// 完全没有记录、没有远端进度 → None(不是 Some(0))。
    #[test]
    fn no_history_no_resume() {
        let wh = WatchHistory::new(tmp_store("empty"));
        let ep = episode("a-ep", "凡人修仙传", 1, 35);
        assert_eq!(
            wh.resolve_resume_position_ticks("https://a:u1", &ep, None, None, false, true),
            None
        );
        // 0/负进度视为没有进度。
        assert_eq!(
            wh.resolve_resume_position_ticks("https://a:u1", &ep, None, Some(0), false, true),
            None
        );
    }

    /// 跨服进度超过本条目时长 → 夹到时长内(别 seek 到片尾之外)。
    #[test]
    fn cross_server_position_is_clamped_to_runtime() {
        let wh = WatchHistory::new(tmp_store("clamp"));
        let mut short_ep = episode("a-ep", "凡人修仙传", 1, 35);
        short_ep.run_time_ticks = Some(600 * TICKS_PER_SEC); // 本服这版只有 10 分钟
        let long_ep = episode("b-ep", "凡人修仙传", 1, 35); // 那服 40 分钟版看到 20 分钟
        wh.store().save_records(vec![record_from("https://b:u2", &long_ep, Some("95479"), 1200 * TICKS_PER_SEC)]);
        assert_eq!(
            wh.resolve_resume_position_ticks("https://a:u1", &short_ep, Some("95479"), None, false, true),
            Some(600 * TICKS_PER_SEC)
        );
    }

    /// 非 Movie/Episode(如 Series)→ 建不出指纹 → 只回远端进度。
    #[test]
    fn unsupported_kind_falls_back_to_remote() {
        let wh = WatchHistory::new(tmp_store("unsupported"));
        let series = Candidate { id: "s1".into(), name: "凡人".into(), type_: "Series".into(), ..Default::default() };
        assert_eq!(
            wh.resolve_resume_position_ticks("https://a:u1", &series, None, Some(500), false, true),
            Some(500)
        );
    }

    // ===== capture / store =====

    #[test]
    fn capture_writes_and_dedups_by_canonical_key() {
        let wh = WatchHistory::new(tmp_store("capture"));
        let ep = episode("a-ep", "凡人修仙传", 1, 35);
        let rec = wh
            .capture_playback("https://a:u1", &ep, Some("95479"), 600 * TICKS_PER_SEC, WriteSource::InternalPlayer, 90, false, false)
            .unwrap();
        assert_eq!(rec.canonical_key, "series:tmdb:95479:s01:e35");
        assert_eq!(rec.play_count, 1);
        assert!(!rec.played);
        assert_eq!(wh.load_scope("https://a:u1").len(), 1);

        // 同一内容再写(force 绕过 10s 节流)→ 仍只有一条,play_count 不涨。
        let rec2 = wh
            .capture_playback("https://a:u1", &ep, Some("95479"), 700 * TICKS_PER_SEC, WriteSource::InternalPlayer, 90, false, true)
            .unwrap();
        assert_eq!(rec2.play_count, 1);
        assert_eq!(rec2.last_position_ticks, 700 * TICKS_PER_SEC);
        assert_eq!(wh.load_scope("https://a:u1").len(), 1);

        // 过阈值 → played。
        let rec3 = wh
            .capture_playback("https://a:u1", &ep, Some("95479"), 2300 * TICKS_PER_SEC, WriteSource::InternalPlayer, 90, false, true)
            .unwrap();
        assert!(rec3.played);
    }

    /// 10s 内重复 capture 直接返回既有记录,不落盘(播放期每秒调用的保护)。
    #[test]
    fn capture_throttles_progress_writes() {
        let wh = WatchHistory::new(tmp_store("throttle"));
        let ep = episode("a-ep", "凡人修仙传", 1, 35);
        wh.capture_playback("https://a:u1", &ep, None, 100 * TICKS_PER_SEC, WriteSource::InternalPlayer, 90, false, false);
        let again = wh
            .capture_playback("https://a:u1", &ep, None, 200 * TICKS_PER_SEC, WriteSource::InternalPlayer, 90, false, false)
            .unwrap();
        assert_eq!(again.last_position_ticks, 100 * TICKS_PER_SEC, "10s 内不该更新进度");
    }

    /// canonicalKey 变了(补上了 TMDB)→ 旧记录被替换,不留双份。
    #[test]
    fn capture_replaces_record_when_canonical_key_changes() {
        let wh = WatchHistory::new(tmp_store("rekey"));
        let ep = episode("a-ep", "凡人修仙传", 1, 35);
        wh.capture_playback("https://a:u1", &ep, None, 100 * TICKS_PER_SEC, WriteSource::InternalPlayer, 90, false, true);
        // 这次查到了剧的 TMDB id → canonicalKey 从 episode:title:… 变成 series:tmdb:…
        let rec = wh
            .capture_playback("https://a:u1", &ep, Some("95479"), 200 * TICKS_PER_SEC, WriteSource::InternalPlayer, 90, false, true)
            .unwrap();
        assert!(rec.canonical_key.starts_with("series:tmdb:95479"));
        assert_eq!(wh.load_scope("https://a:u1").len(), 1, "旧 key 的记录必须被替换掉");
    }

    #[test]
    fn store_roundtrip_scope_and_delete() {
        let wh = WatchHistory::new(tmp_store("store"));
        let a = episode("a-ep", "剧甲", 1, 1);
        let b = episode("b-ep", "剧乙", 1, 1);
        wh.store().save_records(vec![
            record_from("https://a:u1", &a, None, 10),
            record_from("https://b:u2", &b, None, 20),
        ]);
        assert_eq!(wh.load_all().len(), 2);
        assert_eq!(wh.load_scope("https://a:u1").len(), 1);
        let id = wh.load_scope("https://a:u1")[0].record_id.clone();
        wh.delete_record(&id);
        assert_eq!(wh.load_all().len(), 1);
        wh.clear_all();
        assert!(wh.load_all().is_empty());
    }

    /// 损坏/空文件不该 panic,当空文档。
    #[test]
    fn corrupt_file_reads_as_empty() {
        let p = std::env::temp_dir()
            .join(format!("linplayer_wh_test_corrupt_{}.json", std::process::id()));
        std::fs::write(&p, "{ not json").unwrap();
        assert!(Store::new(p).load_all().is_empty());
    }

    // ===== 恢复 =====

    #[test]
    fn needs_restore_respects_played_and_tolerance() {
        let ep = episode("a-ep", "凡人修仙传", 1, 35);
        let mut rec = record_from("https://a:u1", &ep, None, 600 * TICKS_PER_SEC);

        // 本地已看完、远端没看 → 要回写。
        rec.played = true;
        assert!(needs_restore(&rec, &ep));
        let played_item = Candidate { played: true, ..ep.clone() };
        assert!(!needs_restore(&rec, &played_item));

        // 本地有进度、远端全新 → 要回写。
        rec.played = false;
        assert!(needs_restore(&rec, &ep));
        // 远端已看完 → 不动。
        assert!(!needs_restore(&rec, &played_item));
        // 远端只差 10s(< 30s 容差)→ 不折腾。
        let close = Candidate { position_ticks: 590 * TICKS_PER_SEC, ..ep.clone() };
        assert!(!needs_restore(&rec, &close));
        // 远端差 60s → 回写。
        let behind = Candidate { position_ticks: 540 * TICKS_PER_SEC, ..ep.clone() };
        assert!(needs_restore(&rec, &behind));
        // 本地没进度 → 没啥可回写。
        rec.last_position_ticks = 0;
        assert!(!needs_restore(&rec, &ep));
    }

    #[test]
    fn restore_search_query_uses_series_name_for_episodes() {
        let ep = episode("a-ep", "凡人修仙传", 1, 35);
        let rec = record_from("https://a:u1", &ep, None, 1);
        assert_eq!(restore_search_query(&rec), Some("凡人修仙传"));
        let m = movie("m1", "沙丘", 2021);
        let rec_m = record_from("https://a:u1", &m, None, 1);
        assert_eq!(restore_search_query(&rec_m), Some("沙丘"));
        // 剧名缺失 → 退回条目名。
        let mut no_series = rec.clone();
        no_series.series_title = None;
        assert_eq!(restore_search_query(&no_series), Some("第 35 集"));
    }

    #[test]
    fn pick_restore_candidate_rules() {
        let ep = episode("a-ep", "凡人修仙传", 1, 35);
        let rec = record_from("https://a:u1", &ep, Some("95479"), 600 * TICKS_PER_SEC);

        // 唯一 strong → 选它。
        let hit = episode("b-ep", "凡人修仙传", 1, 35);
        let noise = episode("b-x", "斗破苍穹", 1, 35);
        let list = vec![(noise.clone(), Some("111".into())), (hit.clone(), Some("95479".to_string()))];
        let (i, m) = pick_restore_candidate(&rec, &list).unwrap();
        assert_eq!(i, 1);
        assert_eq!(m.confidence, MatchConfidence::Strong);

        // 两个 strong → 分不清,放弃。
        let dup = episode("b-ep2", "凡人修仙传", 1, 35);
        let list = vec![(hit.clone(), Some("95479".to_string())), (dup, Some("95479".to_string()))];
        assert!(pick_restore_candidate(&rec, &list).is_none());

        // 无匹配 → None。
        assert!(pick_restore_candidate(&rec, &[(noise.clone(), None)]).is_none());
        assert!(pick_restore_candidate(&rec, &[]).is_none());

        // 单个非 strong 候选 → 按 unique 重算,weak 升 possible。
        let weak_only = vec![(hit.clone(), None)];
        let (_, m) = pick_restore_candidate(&rec, &weak_only).unwrap();
        assert_eq!(m.confidence, MatchConfidence::Possible);

        // 类型不符的候选被先滤掉。
        let mv = movie("b-m", "凡人修仙传", 2020);
        assert!(pick_restore_candidate(&rec, &[(mv, None)]).is_none());
    }

    // ===== 回传 =====

    #[test]
    fn writeback_targets_dedup_and_range() {
        let here = episode("a-ep", "凡人修仙传", 1, 35);
        let b_old = episode("b-old", "凡人修仙传", 1, 35);
        let b_new = episode("b-new", "凡人修仙传", 1, 35);
        let c = episode("c-ep", "凡人修仙传", 1, 35);

        // B 服两条(取最近的 b_new),C 服一条;A 服自己不算。
        let mut r_b_old = record_from("https://b:u2", &b_old, Some("95479"), 100);
        r_b_old.record_id = "b-old".into();
        r_b_old.last_played_at = 1000;
        r_b_old.first_played_at = Some(1000);
        let mut r_b_new = record_from("https://b:u2", &b_new, Some("95479"), 200);
        r_b_new.record_id = "b-new".into();
        r_b_new.last_played_at = 5000;
        r_b_new.first_played_at = Some(4000);
        let mut r_c = record_from("https://c:u3", &c, Some("95479"), 300);
        r_c.last_played_at = 3000;
        r_c.first_played_at = Some(500); // C 才是最早看的
        let r_a = record_from("https://a:u1", &here, Some("95479"), 400);
        let all = vec![r_a, r_b_old, r_b_new, r_c];

        let t = writeback_targets(&all, "https://a:u1", &here, Some("95479"), WritebackRange::All, true, false, 0);
        assert_eq!(t.len(), 2, "两台其它服务器,B 服只留最近那条");
        assert_eq!(t[0].last_emby_item_id.as_deref(), Some("b-new"));

        let t = writeback_targets(&all, "https://a:u1", &here, Some("95479"), WritebackRange::First, true, false, 0);
        assert_eq!(t.len(), 1);
        assert_eq!(t[0].scope_key, "https://c:u3", "first = 最早看过的那台");

        let t = writeback_targets(&all, "https://a:u1", &here, Some("95479"), WritebackRange::Latest, true, false, 0);
        assert_eq!(t.len(), 1);
        assert_eq!(t[0].scope_key, "https://b:u2", "latest = 最近看过的那台");

        // 没看完 + 不带进度回传 → 什么都不做。
        assert!(writeback_targets(&all, "https://a:u1", &here, Some("95479"), WritebackRange::All, false, false, 999).is_empty());
        // 没看完 + 带进度但进度为 0 → 什么都不做。
        assert!(writeback_targets(&all, "https://a:u1", &here, Some("95479"), WritebackRange::All, false, true, 0).is_empty());
        // 没看完 + 带进度 → 照做。
        assert_eq!(
            writeback_targets(&all, "https://a:u1", &here, Some("95479"), WritebackRange::All, false, true, 999).len(),
            2
        );
    }

    /// 没有 last_emby_item_id 的记录不能当回传目标(不知道写到哪个条目)。
    #[test]
    fn writeback_skips_records_without_item_id() {
        let here = episode("a-ep", "凡人修仙传", 1, 35);
        let b = episode("b-ep", "凡人修仙传", 1, 35);
        let mut r_b = record_from("https://b:u2", &b, Some("95479"), 100);
        r_b.last_emby_item_id = None;
        assert!(writeback_targets(&[r_b], "https://a:u1", &here, Some("95479"), WritebackRange::All, true, false, 0).is_empty());
    }

    #[test]
    fn writeback_dedup_key_buckets_by_minute() {
        let k1 = writeback_dedup_key("https://b.com:8096:u2", "it1", false, 90 * TICKS_PER_SEC);
        let k2 = writeback_dedup_key("https://b.com:8096:u2", "it1", false, 119 * TICKS_PER_SEC);
        let k3 = writeback_dedup_key("https://b.com:8096:u2", "it1", false, 120 * TICKS_PER_SEC);
        assert_eq!(k1, "https://b.com:8096|it1|false|1");
        assert_eq!(k1, k2, "同一分钟内只回传一次");
        assert_ne!(k1, k3);
        // 看完状态进键 → 「看完」能突破进度去重。
        assert_ne!(k1, writeback_dedup_key("https://b.com:8096:u2", "it1", true, 90 * TICKS_PER_SEC));
    }

    #[test]
    fn record_writeback_result_merges_state() {
        let wh = WatchHistory::new(tmp_store("wb_result"));
        let ep = episode("b-ep", "凡人修仙传", 1, 35);
        let target = record_from("https://b:u2", &ep, Some("95479"), 100 * TICKS_PER_SEC);
        wh.store().save_records(vec![target.clone()]);

        // 进度前进 → 更新。
        wh.record_writeback_result(&target, false, 300 * TICKS_PER_SEC);
        assert_eq!(wh.load_all()[0].last_position_ticks, 300 * TICKS_PER_SEC);
        // 进度倒退 → 不动。
        wh.record_writeback_result(&target, false, 50 * TICKS_PER_SEC);
        assert_eq!(wh.load_all()[0].last_position_ticks, 100 * TICKS_PER_SEC);
        // 看完 → played 置位,且已看完后进度不再被推进。
        wh.record_writeback_result(&target, true, 900 * TICKS_PER_SEC);
        let got = &wh.load_all()[0];
        assert!(got.played);
        assert_eq!(got.last_position_ticks, 900 * TICKS_PER_SEC);
        let played_target = Record { played: true, ..target.clone() };
        wh.record_writeback_result(&played_target, false, 900 * TICKS_PER_SEC);
        assert_eq!(wh.load_all()[0].last_position_ticks, 100 * TICKS_PER_SEC, "已看完的记录不推进度");
    }

    // ===== 杂项 =====

    #[test]
    fn extract_provider_id_is_case_insensitive() {
        let mut ids = HashMap::new();
        ids.insert("Tmdb".to_string(), " 438631 ".to_string());
        ids.insert("Imdb".to_string(), "".to_string());
        assert_eq!(extract_provider_id(&ids, "tmdb").as_deref(), Some("438631"));
        assert_eq!(extract_provider_id(&ids, "imdb"), None, "空串当没有");
        assert_eq!(extract_provider_id(&ids, "tvdb"), None);
    }

    /// Item → Candidate:emby.rs 存的是秒,这里要 ticks;匹配判据从 Item 的 Fields 透传。
    /// 数值取自 emby.rs 里那条实抓载荷(RunTimeTicks=27390000000 → 2739.0 秒)。
    #[test]
    fn candidate_from_item_maps_ticks() {
        let it = Item {
            id: "e01".into(),
            name: "第 35 集".into(),
            type_: "Episode".into(),
            is_folder: false,
            has_primary: true,
            runtime_secs: 2739.0,
            resume_secs: 12.0,
            sort_name: None,
            date_updated: None,
            series_name: Some("问心".into()),
            episode_no: Some(35),
            season_no: Some(1),
            video_height: None,
            bitrate: None,
            size_bytes: None,
            played: false,
            unplayed_item_count: 0,
            genres: vec![],
            year: None,
            rating: None,
            provider_ids: HashMap::from([("Tmdb".to_string(), "12345".to_string())]),
            presentation_unique_key: Some("puk-1".into()),
            path: Some("/media/问心/S01E35.mkv".into()),
            series_id: Some("s01".into()),
        };
        let c = Candidate::from(&it);
        assert_eq!(c.type_, "Episode");
        // ★ 强匹配判据必须真的从 Item 透传过来 —— 断在 None 上就等于跨服续播静默退化成猜剧名。
        assert_eq!(c.tmdb_id.as_deref(), Some("12345"));
        assert_eq!(c.presentation_unique_key.as_deref(), Some("puk-1"));
        assert_eq!(c.path.as_deref(), Some("/media/问心/S01E35.mkv"));
        assert_eq!(c.series_id.as_deref(), Some("s01"));
        assert_eq!(c.series_name.as_deref(), Some("问心"));
        assert_eq!(c.run_time_ticks, Some(27_390_000_000));
        assert_eq!(c.position_ticks, 120_000_000);
        assert_eq!(c.season_no, Some(1));
        assert_eq!(c.episode_no, Some(35));
        // 指纹能建出来 = Item 直转的候选可直接进匹配器。
        assert!(build_fingerprint_from_candidate(&c, Some("95479")).is_some());
    }

    /// 回归:没带 Fields 的列表端点(如 resume/latest)取到的 Item 没有匹配判据 ——
    /// 此时必须安静降级成 None 而不是崩,匹配器自会退到「剧名+季集号」。
    #[test]
    fn candidate_from_item_without_history_fields_degrades_quietly() {
        let it = Item {
            id: "e01".into(),
            name: "第 35 集".into(),
            type_: "Episode".into(),
            is_folder: false,
            has_primary: true,
            runtime_secs: 2739.0,
            resume_secs: 0.0,
            sort_name: None,
            date_updated: None,
            series_name: Some("问心".into()),
            episode_no: Some(35),
            season_no: Some(1),
            video_height: None,
            bitrate: None,
            size_bytes: None,
            played: false,
            unplayed_item_count: 0,
            genres: vec![],
            year: None,
            rating: None,
            provider_ids: HashMap::new(),
            presentation_unique_key: None,
            path: None,
            series_id: None,
        };
        let c = Candidate::from(&it);
        assert!(c.tmdb_id.is_none() && c.presentation_unique_key.is_none() && c.path.is_none());
        // 判据全缺也得能建指纹(靠剧名+季集号),否则整条续播链断在这。
        assert!(build_fingerprint_from_candidate(&c, None).is_some());
    }

    /// 置信度序:none < weak < possible < strong,且只有后两者可信。
    #[test]
    fn confidence_order_and_trust() {
        assert!(MatchConfidence::None < MatchConfidence::Weak);
        assert!(MatchConfidence::Weak < MatchConfidence::Possible);
        assert!(MatchConfidence::Possible < MatchConfidence::Strong);
        assert!(MatchConfidence::Strong.is_trusted() && MatchConfidence::Possible.is_trusted());
        assert!(!MatchConfidence::Weak.is_trusted() && !MatchConfidence::None.is_trusted());
    }

    #[test]
    fn wire_values_match_old_dart() {
        assert_eq!(serde_json::to_string(&MediaKind::Episode).unwrap(), "\"episode\"");
        assert_eq!(serde_json::to_string(&WriteSource::ExternalMpv).unwrap(), "\"external_mpv\"");
        assert_eq!(serde_json::to_string(&MatchConfidence::Possible).unwrap(), "\"possible\"");
        assert_eq!(WritebackRange::from_wire("first"), WritebackRange::First);
        assert_eq!(WritebackRange::from_wire("garbage"), WritebackRange::All);
        assert_eq!(WritebackRange::Latest.wire(), "latest");
        assert_eq!(WritebackRange::First.label(), "仅初次看过的服务器");
    }
}
