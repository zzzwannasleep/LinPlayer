// 观看记录「恢复扫描 + 跨服回传」的 HTTP 编排。
//
// 旧 Dart 的等价移植:
//   - lib/core/services/watch_history/watch_history_restore_service.dart  → scan_restore / restore_candidate
//   - lib/core/services/watch_history/watch_history_writeback_service.dart → run_writeback
//
// ★ 分层:所有判定(匹配/挑候选/该不该回写/去重键)都在 watch_history.rs,已单测。
//   这里只回答三个问题:**打哪些请求 / 打给谁 / 失败了算什么**。凡是能不带 HTTP 说清的决定,
//   都抽成了纯函数([`restore_action`] / [`restore_write`] / [`restore_fallback_ticks`] /
//   [`writeback_plan`]),async 壳子只剩「按计划发请求」。
//
// ★ 不读全局配置、不碰存盘路径:session / scope / 开关全从参数进来,宿主(lib.rs)负责编排。
use crate::emby;
use crate::watch_history::{
    match_record_to_candidate, needs_restore, pick_restore_candidate, restore_search_query,
    scope_key, writeback_dedup_key, writeback_targets, Candidate, MatchConfidence, MatchResult,
    MediaKind, Record, RestoreCandidate, WatchHistory, WritebackRange, MAX_SCAN_RECORDS,
    TICKS_PER_SEC,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn ticks_to_secs(ticks: i64) -> f64 {
    ticks as f64 / TICKS_PER_SEC as f64
}

// ---------- 对外报告 ----------
//
// ★ 只 Serialize:内嵌的 watch_history::RestoreCandidate / MatchResult 目前没有 Deserialize
//   (见最终回复里给宿主的改动清单)。报告是**返回值**,当 tauri 命令的返回不需要 Deserialize。

/// 一轮恢复扫描的结果。
/// ★ errors 存在的意义:单条记录/单个请求失败不能毁掉整轮,但**必须留痕** ——
/// 这个模块最危险的 bug 是「不崩,只是悄悄少恢复了几条」。
#[derive(Serialize, Clone, Debug, Default)]
pub struct RestoreReport {
    /// 实际过了一遍的记录数(≤ MAX_SCAN_RECORDS)。
    pub scanned: usize,
    /// strong 匹配且自动回写成功的条数。
    pub auto_restored: usize,
    /// possible 匹配,需要用户确认后再调 [`restore_candidate`] 的。
    pub prompt_candidates: Vec<RestoreCandidate>,
    /// 本轮落盘更新的记录数(补 last_emby_item_id / match_confidence / restored_at)。
    pub updated_records: usize,
    /// 失败但已隔离的请求。非空 = 本轮结果不完整。
    pub errors: Vec<String>,
}

/// 一次跨服回传的结果。
#[derive(Serialize, Clone, Debug, Default)]
pub struct WritebackReport {
    /// [`writeback_targets`] 选出的目标服务器数。
    pub targets: usize,
    /// 真正写成功的数。
    pub written: usize,
    /// 有目标但没发请求的,带原因(缺登录会话 / 已去重 / 无可写内容)。
    pub skipped: Vec<WritebackSkip>,
    /// 发了请求但失败的。单台失败不影响其它台。
    pub errors: Vec<String>,
}

// ---------- 纯决策(可测,不带 HTTP)----------

/// 一条记录解析出候选后该干什么。逐字对齐 Dart scanAndRestore 的循环体分支。
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum RestoreAction {
    /// 服务器上的现状已经够好 → 只把 itemId/置信度补进本地记录,不发写请求。
    UpdateOnly,
    /// strong 匹配 → 直接回写。
    AutoRestore,
    /// possible 匹配 → 交给用户确认。
    Prompt,
    /// 置信度不够(weak/none)→ 什么都不做。★ 绝不把不可信的匹配当成匹配上。
    Ignore,
}

pub fn restore_action(record: &Record, item: &Candidate, confidence: MatchConfidence) -> RestoreAction {
    if !needs_restore(record, item) {
        return RestoreAction::UpdateOnly;
    }
    match confidence {
        MatchConfidence::Strong => RestoreAction::AutoRestore,
        MatchConfidence::Possible => RestoreAction::Prompt,
        MatchConfidence::Weak | MatchConfidence::None => RestoreAction::Ignore,
    }
}

/// 恢复时往服务器写什么。
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum RestoreWrite {
    /// 本地已看完 → POST /PlayedItems。
    MarkPlayed,
    /// 本地有进度 → start/progress/stopped 三连(ticks)。
    Progress(i64),
    /// 没看完也没进度 → 无可写。
    Nothing,
}

pub fn restore_write(record: &Record) -> RestoreWrite {
    if record.played {
        RestoreWrite::MarkPlayed
    } else if record.last_position_ticks > 0 {
        RestoreWrite::Progress(record.last_position_ticks)
    } else {
        RestoreWrite::Nothing
    }
}

/// 标记已看失败后的兜底进度:走一遍 start+stopped(定位到片尾)让服务器自己判已看。
/// 仅对「本地已看完」的记录成立;拿不到时长就没法兜底(Dart 同款)。
pub fn restore_fallback_ticks(record: &Record, item: &Candidate) -> Option<i64> {
    if !record.played {
        return None;
    }
    item.run_time_ticks.or(record.run_time_ticks).filter(|r| *r > 0)
}

/// 一次要发的回传请求。
#[derive(Serialize, Clone, Debug)]
pub struct WritebackStep {
    /// 在传入 `sessions` 里的下标。
    pub session_index: usize,
    /// 在传入 `targets` 里的下标。
    pub record_index: usize,
    pub item_id: String,
    pub dedup_key: String,
}

#[derive(Serialize, Clone, Debug)]
pub struct WritebackSkip {
    pub scope_key: String,
    pub reason: String,
}

/// 「该给谁发、发不发」的全部决定。抽出来是因为剩下的 async 壳子无从测起。
///
/// ★ 与 Dart 的一处**故意的**差异:Dart 只按 serverId 找服务器,再拿该服**当前配置的** userId
/// 发请求 —— 换过登录用户就会把进度写到别人账号上。这里按整个 scope(server+user)配对。
/// 配不上的会进 skipped,不是静默丢弃。
pub fn writeback_plan(
    targets: &[Record],
    sessions: &[emby::Session],
    done: &HashSet<String>,
    played: bool,
    include_progress: bool,
    position_ticks: i64,
) -> (Vec<WritebackStep>, Vec<WritebackSkip>) {
    let mut steps = Vec::new();
    let mut skips = Vec::new();
    let skip = |r: &Record, reason: &str| WritebackSkip {
        scope_key: r.scope_key.clone(),
        reason: reason.to_string(),
    };
    for (record_index, target) in targets.iter().enumerate() {
        let item_id = target.last_emby_item_id.as_deref().unwrap_or("");
        if item_id.is_empty() {
            // writeback_targets 已经滤过;留着防御,别在这悄悄少一台。
            skips.push(skip(target, "记录没有条目 id"));
            continue;
        }
        // Dart 循环里的 `else { continue }`:既没看完、又不带进度 → 没什么可写。
        if !played && (!include_progress || position_ticks <= 0) {
            skips.push(skip(target, "未看完且不回传进度"));
            continue;
        }
        let Some(session_index) = sessions
            .iter()
            .position(|s| scope_key(&s.server, &s.user_id) == target.scope_key)
        else {
            skips.push(skip(target, "没有该服务器/用户的登录会话"));
            continue;
        };
        let dedup_key = writeback_dedup_key(&target.scope_key, item_id, played, position_ticks);
        if done.contains(&dedup_key) {
            skips.push(skip(target, "本次会话已回传过"));
            continue;
        }
        steps.push(WritebackStep {
            session_index,
            record_index,
            item_id: item_id.to_string(),
            dedup_key,
        });
    }
    (steps, skips)
}

// ---------- HTTP 小工具 ----------

/// 恢复/回传用的上报目标。没有真实取流会话,但 **start/progress/stopped 三次必须同一个
/// PlaySessionId**,否则服务器不认这次上报(续播不落地的老坑)—— 所以这里一次造好传三遍。
/// 格式沿用 emby::resolve_stream 的兜底(device_id + item_id)。
fn report_target(s: &emby::Session, item_id: &str) -> emby::PlaybackTarget {
    emby::PlaybackTarget {
        url: String::new(),
        item_id: item_id.to_string(),
        // Dart 同款:没有单独的 mediaSourceId 时用 itemId。
        media_source_id: item_id.to_string(),
        play_session_id: format!("{}-wh-{item_id}", s.device_id),
        play_method: "DirectStream".to_string(),
        is_dolby_vision: false, // 纯上报,不解码,这个字段对它没有意义
        external_subs: Vec::new(),
    }
}

/// start(0) → progress(pos, 已暂停) → stopped(pos)。任一步失败即整体失败(Dart 是一串 await)。
async fn report_progress_triplet(
    http: &reqwest::Client,
    s: &emby::Session,
    t: &emby::PlaybackTarget,
    position_ticks: i64,
) -> Result<(), String> {
    let secs = ticks_to_secs(position_ticks);
    emby::report_start(http, s, t, 0.0).await?;
    emby::report_progress(http, s, t, secs, true).await?;
    emby::report_stopped(http, s, t, secs).await?;
    Ok(())
}

/// 剧集所属剧的 TMDB id,按 series_id 缓存(Dart _seriesTmdbCache)。
/// 非剧集 / 没 series_id → None(不是错误:电影本就没有)。
async fn series_tmdb(
    http: &reqwest::Client,
    s: &emby::Session,
    c: &Candidate,
    cache: &mut HashMap<String, Option<String>>,
) -> Option<String> {
    if !c.type_.eq_ignore_ascii_case("episode") {
        return None;
    }
    let sid = c.series_id.clone().filter(|x| !x.is_empty())?;
    if let Some(v) = cache.get(&sid) {
        return v.clone();
    }
    let v = emby::series_tmdb_id(http, s, &sid).await;
    cache.insert(sid, v.clone());
    v
}

// ---------- 恢复扫描 ----------

/// 换服/重装后,把本地记录推回服务器。
///
/// 流程(= Dart scanAndRestore):load_scope → 取前 MAX_SCAN_RECORDS 条 → 逐条解析出本服条目
/// → [`restore_action`] 决定 → strong 自动回写、possible 进 prompt_candidates → 统一落盘。
///
/// ponytail: 逐条串行(与 Dart 一致)。15 条 × 数个请求,后台跑得起;真嫌慢再按记录 tokio::spawn
/// 并发,但那样 series_tmdb 缓存要换成共享的 Mutex<HashMap>。
pub async fn scan_restore(
    http: &reqwest::Client,
    s: &emby::Session,
    wh: &WatchHistory,
    scope_key: &str,
) -> Result<RestoreReport, String> {
    let mut report = RestoreReport::default();
    let records = wh.load_scope(scope_key);
    if records.is_empty() {
        return Ok(report);
    }

    let mut cache: HashMap<String, Option<String>> = HashMap::new();
    // 按 recordId 覆盖(Dart pendingUpdates 是个 Map)。
    let mut pending: HashMap<String, Record> = HashMap::new();

    for record in records.iter().take(MAX_SCAN_RECORDS) {
        report.scanned += 1;
        let Some((item, m)) = resolve_candidate(http, s, record, &mut cache, &mut report.errors).await
        else {
            continue;
        };

        let mut update = record.clone();
        update.last_emby_item_id = Some(item.id.clone());
        update.match_confidence = m.confidence;

        match restore_action(record, &item, m.confidence) {
            RestoreAction::UpdateOnly => {
                pending.insert(record.record_id.clone(), update);
            }
            RestoreAction::AutoRestore => {
                let candidate = RestoreCandidate {
                    record: update.clone(),
                    matched_item: item,
                    confidence: m.confidence,
                    reason: m.reason,
                };
                match restore_candidate(http, s, wh, &candidate).await {
                    Ok(true) => {
                        report.auto_restored += 1;
                        update.restored_at = Some(now_ms());
                        update.match_confidence = MatchConfidence::Strong;
                        pending.insert(record.record_id.clone(), update);
                    }
                    // 没什么可写(进度为 0)。Dart 同样不记 pendingUpdate。
                    Ok(false) => {}
                    Err(e) => report.errors.push(format!("恢复「{}」失败: {e}", record.title)),
                }
            }
            RestoreAction::Prompt => {
                report.prompt_candidates.push(RestoreCandidate {
                    record: update.clone(),
                    matched_item: item,
                    confidence: m.confidence,
                    reason: m.reason,
                });
                pending.insert(record.record_id.clone(), update);
            }
            RestoreAction::Ignore => {}
        }
    }

    if !pending.is_empty() {
        report.updated_records = pending.len();
        wh.store().save_records(pending.into_values().collect());
    }
    Ok(report)
}

/// 把一条候选真的回写到服务器,成功则更新本地记录。
/// scan_restore 对 strong 自动调它;possible 由宿主拿 prompt_candidates 问过用户再调。
///
/// 返回 Ok(false) = 没什么可写(不算失败);Err = 请求失败。
/// ★ 与 Dart 的差异:Dart 这里一律返回 false 把失败吞了;这里让失败冒出来给 Report。
pub async fn restore_candidate(
    http: &reqwest::Client,
    s: &emby::Session,
    wh: &WatchHistory,
    candidate: &RestoreCandidate,
) -> Result<bool, String> {
    let record = &candidate.record;
    let item = &candidate.matched_item;
    let target = report_target(s, &item.id);

    let primary = match restore_write(record) {
        RestoreWrite::MarkPlayed => emby::set_played(http, s, &item.id, true).await,
        RestoreWrite::Progress(ticks) => report_progress_triplet(http, s, &target, ticks).await,
        RestoreWrite::Nothing => return Ok(false),
    };
    if let Err(primary_err) = primary {
        // 兜底只对「已看完」有意义:定位到片尾再 stopped,让服务器自己判已看。
        let Some(runtime) = restore_fallback_ticks(record, item) else {
            return Err(primary_err);
        };
        let wrap = |e: String| format!("{primary_err};兜底上报也失败: {e}");
        emby::report_start(http, s, &target, 0.0).await.map_err(wrap)?;
        emby::report_stopped(http, s, &target, ticks_to_secs(runtime))
            .await
            .map_err(|e| format!("{primary_err};兜底上报也失败: {e}"))?;
    }

    let mut updated = record.clone();
    updated.last_emby_item_id = Some(item.id.clone());
    updated.restored_at = Some(now_ms());
    updated.match_confidence = candidate.confidence;
    wh.store().save_record(updated, &[]);
    Ok(true)
}

/// 一条记录 → 本服上的条目。先试上次记下的 itemId,不行再按剧名/片名搜。
/// 返回 None = 没找到可信候选(**不是**「随便挑一个」)。
async fn resolve_candidate(
    http: &reqwest::Client,
    s: &emby::Session,
    record: &Record,
    cache: &mut HashMap<String, Option<String>>,
    errors: &mut Vec<String>,
) -> Option<(Candidate, MatchResult)> {
    // 1) 上次的条目 id 还在不在。item_for_history 带 HISTORY_FIELDS,强匹配判据才齐。
    if let Some(id) = record.last_emby_item_id.as_deref().filter(|i| !i.is_empty()) {
        match emby::item_for_history(http, s, id).await {
            Ok(item) => {
                let c = Candidate::from(&item);
                let st = series_tmdb(http, s, &c, cache).await;
                let m = match_record_to_candidate(record, &c, st.as_deref(), true);
                if m.confidence != MatchConfidence::None {
                    return Some((c, m));
                }
            }
            // 条目被删/换库很正常 → 不算错,继续走搜索。但留痕,免得整轮静默变空。
            Err(e) => errors.push(format!("取条目 {id} 失败(改走搜索): {e}")),
        }
    }

    // 2) 搜索。emby::search 的 URL 自带 HISTORY_FIELDS,搜出来的候选也有强匹配判据。
    let query = restore_search_query(record)?;
    let items = match emby::search(http, s, query, None, None, None).await {
        Ok(v) => v,
        Err(e) => {
            errors.push(format!("搜索「{query}」失败: {e}"));
            return None;
        }
    };

    // 先按类型过滤 + 取前 10 再查 TMDB —— 否则 50 条结果就是 50 个请求。
    // 这一步与 pick_restore_candidate 内部的 filter/take 同规则,所以下标对得上。
    let mut cands: Vec<(Candidate, Option<String>)> = Vec::new();
    for c in items
        .iter()
        .map(Candidate::from)
        .filter(|c| MediaKind::from_item_type(&c.type_) == Some(record.media_kind))
        .take(10)
    {
        let st = series_tmdb(http, s, &c, cache).await;
        cands.push((c, st));
    }

    let (i, m) = pick_restore_candidate(record, &cands)?;
    Some((cands.into_iter().nth(i)?.0, m))
}

// ---------- 跨服回传 ----------

/// 把当前服的「已看完 / 进度」回传到其它服务器上的同一内容(= Dart propagate)。
///
/// `sessions` 是宿主手上所有已登录会话(含当前服也无妨,scope 对不上自然跳过)。
/// `done` 由宿主跨调用持有(Dart 的 _done),用于会话内去重。
///
/// ponytail: 逐台串行。目标最多就是服务器台数,且每台失败已隔离进 report.errors;
/// 真要并发就 tokio::spawn(Session/Client 都 Clone),但 wh 的写必须留在这个任务里。
#[allow(clippy::too_many_arguments)]
pub async fn run_writeback(
    http: &reqwest::Client,
    current: &emby::Session,
    sessions: &[emby::Session],
    wh: &WatchHistory,
    current_scope_key: &str,
    item: &Candidate,
    position_ticks: i64,
    played: bool,
    range: WritebackRange,
    include_progress: bool,
    done: &mut HashSet<String>,
) -> Result<WritebackReport, String> {
    let mut report = WritebackReport::default();
    if !played && (!include_progress || position_ticks <= 0) {
        return Ok(report);
    }
    let all = wh.load_all();
    if all.is_empty() {
        return Ok(report);
    }

    let mut cache: HashMap<String, Option<String>> = HashMap::new();
    let st = series_tmdb(http, current, item, &mut cache).await;

    let targets = writeback_targets(
        &all,
        current_scope_key,
        item,
        st.as_deref(),
        range,
        played,
        include_progress,
        position_ticks,
    );
    report.targets = targets.len();
    if targets.is_empty() {
        return Ok(report);
    }

    let (steps, skips) = writeback_plan(&targets, sessions, done, played, include_progress, position_ticks);
    report.skipped = skips;

    for step in steps {
        let s = &sessions[step.session_index];
        let target = &targets[step.record_index];
        let result = if played {
            emby::set_played(http, s, &step.item_id, true).await
        } else {
            report_progress_triplet(http, s, &report_target(s, &step.item_id), position_ticks).await
        };
        match result {
            Ok(()) => {
                done.insert(step.dedup_key);
                // 本地目标记录同步跟上,避免下次又当成没回传过。
                wh.record_writeback_result(target, played, position_ticks);
                report.written += 1;
            }
            // 单台挂掉不毁整轮,但必须在报告里看得见。
            Err(e) => report.errors.push(format!("回传到 {} 失败: {e}", target.scope_key)),
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::watch_history::{build_fingerprint_from_candidate, build_record_id, WriteSource};

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

    fn session(server: &str, user: &str) -> emby::Session {
        emby::Session {
            server: server.into(),
            token: "tok".into(),
            user_id: user.into(),
            device_id: "dev-1".into(),
        }
    }

    // ===== restore_action:什么时候才真的发写请求 =====

    #[test]
    fn restore_action_only_writes_on_trusted_and_needed() {
        let ep = episode("a-ep", "凡人修仙传", 1, 35);
        let rec = record_from("https://a:u1", &ep, Some("95479"), 600 * TICKS_PER_SEC);

        // 服务器上进度落后很多 → 按置信度分流。
        let behind = Candidate { position_ticks: 0, ..ep.clone() };
        assert_eq!(restore_action(&rec, &behind, MatchConfidence::Strong), RestoreAction::AutoRestore);
        assert_eq!(restore_action(&rec, &behind, MatchConfidence::Possible), RestoreAction::Prompt);
        // ★ 不可信的匹配绝不能当成匹配上 —— 静默乱写别人条目的进度比不写糟得多。
        assert_eq!(restore_action(&rec, &behind, MatchConfidence::Weak), RestoreAction::Ignore);
        assert_eq!(restore_action(&rec, &behind, MatchConfidence::None), RestoreAction::Ignore);

        // 服务器上已经差不多了(容差内)→ 只补本地字段,一个写请求都不发。
        let close = Candidate { position_ticks: 590 * TICKS_PER_SEC, ..ep.clone() };
        assert_eq!(restore_action(&rec, &close, MatchConfidence::Strong), RestoreAction::UpdateOnly);
        assert_eq!(restore_action(&rec, &close, MatchConfidence::Weak), RestoreAction::UpdateOnly);
    }

    // ===== restore_write / 兜底 =====

    #[test]
    fn restore_write_picks_endpoint() {
        let ep = episode("a-ep", "凡人修仙传", 1, 35);
        let mut rec = record_from("https://a:u1", &ep, None, 600 * TICKS_PER_SEC);
        assert_eq!(restore_write(&rec), RestoreWrite::Progress(600 * TICKS_PER_SEC));

        rec.played = true;
        assert_eq!(restore_write(&rec), RestoreWrite::MarkPlayed, "已看完走 PlayedItems,不走三连");

        rec.played = false;
        rec.last_position_ticks = 0;
        assert_eq!(restore_write(&rec), RestoreWrite::Nothing, "没进度就别打服务器");
    }

    #[test]
    fn restore_fallback_only_for_played_with_runtime() {
        let ep = episode("a-ep", "凡人修仙传", 1, 35);
        let mut rec = record_from("https://a:u1", &ep, None, 600 * TICKS_PER_SEC);

        // 没看完 → 没有兜底(Dart:markAsPlayed 之外的失败直接放弃)。
        assert_eq!(restore_fallback_ticks(&rec, &ep), None);

        rec.played = true;
        assert_eq!(restore_fallback_ticks(&rec, &ep), Some(2400 * TICKS_PER_SEC));

        // 条目没时长 → 退回记录里的时长。
        let no_rt = Candidate { run_time_ticks: None, ..ep.clone() };
        assert_eq!(restore_fallback_ticks(&rec, &no_rt), Some(2400 * TICKS_PER_SEC));
        // 两边都没时长 → 兜不了,别瞎发。
        rec.run_time_ticks = None;
        assert_eq!(restore_fallback_ticks(&rec, &no_rt), None);
        // 时长为 0 也不算。
        rec.run_time_ticks = Some(0);
        assert_eq!(restore_fallback_ticks(&rec, &no_rt), None);
    }

    // ===== writeback_plan:给谁发 =====

    fn wb_fixture() -> (Vec<Record>, Vec<emby::Session>) {
        let b = episode("b-ep", "凡人修仙传", 1, 35);
        let c = episode("c-ep", "凡人修仙传", 1, 35);
        let targets = vec![
            record_from("https://b:u2", &b, Some("95479"), 100),
            record_from("https://c:u3", &c, Some("95479"), 200),
        ];
        let sessions = vec![session("https://b", "u2"), session("https://c", "u3")];
        (targets, sessions)
    }

    #[test]
    fn writeback_plan_pairs_targets_with_sessions() {
        let (targets, sessions) = wb_fixture();
        let done = HashSet::new();
        let (steps, skips) = writeback_plan(&targets, &sessions, &done, true, false, 0);
        assert_eq!(steps.len(), 2);
        assert!(skips.is_empty());
        assert_eq!(steps[0].session_index, 0);
        assert_eq!(steps[0].item_id, "b-ep");
        assert_eq!(steps[1].session_index, 1);
        assert_eq!(steps[1].item_id, "c-ep");
        assert_eq!(steps[0].dedup_key, writeback_dedup_key("https://b:u2", "b-ep", true, 0));
    }

    /// 没有对应登录会话的服务器 → 跳过,但**必须在 skipped 里看得见**(不是静默少写一台)。
    #[test]
    fn writeback_plan_skips_unknown_session_visibly() {
        let (targets, _) = wb_fixture();
        let done = HashSet::new();
        let only_b = vec![session("https://b", "u2")];
        let (steps, skips) = writeback_plan(&targets, &only_b, &done, true, false, 0);
        assert_eq!(steps.len(), 1);
        assert_eq!(skips.len(), 1);
        assert_eq!(skips[0].scope_key, "https://c:u3");
        assert!(skips[0].reason.contains("登录会话"));
    }

    /// scope 是 server+user:同一台服务器换了用户不能配对(否则把进度写到别人账号上)。
    #[test]
    fn writeback_plan_requires_matching_user() {
        let (targets, _) = wb_fixture();
        let done = HashSet::new();
        let wrong_user = vec![session("https://b", "someone-else"), session("https://c", "u3")];
        let (steps, skips) = writeback_plan(&targets, &wrong_user, &done, true, false, 0);
        assert_eq!(steps.len(), 1);
        assert_eq!(steps[0].item_id, "c-ep");
        assert_eq!(skips.len(), 1);
        assert_eq!(skips[0].scope_key, "https://b:u2");
    }

    #[test]
    fn writeback_plan_honours_dedup_set() {
        let (targets, sessions) = wb_fixture();
        let mut done = HashSet::new();
        done.insert(writeback_dedup_key("https://b:u2", "b-ep", false, 90 * TICKS_PER_SEC));
        let (steps, skips) = writeback_plan(&targets, &sessions, &done, false, true, 90 * TICKS_PER_SEC);
        assert_eq!(steps.len(), 1, "B 服这一分钟已回传过");
        assert_eq!(steps[0].item_id, "c-ep");
        assert_eq!(skips.len(), 1);
        assert!(skips[0].reason.contains("已回传过"));

        // 跨到下一分钟 → 又该发了。
        let (steps, _) = writeback_plan(&targets, &sessions, &done, false, true, 150 * TICKS_PER_SEC);
        assert_eq!(steps.len(), 2);
    }

    #[test]
    fn writeback_plan_needs_something_to_write() {
        let (targets, sessions) = wb_fixture();
        let done = HashSet::new();
        // 没看完 + 不带进度 → 全跳。
        let (steps, skips) = writeback_plan(&targets, &sessions, &done, false, false, 999 * TICKS_PER_SEC);
        assert!(steps.is_empty());
        assert_eq!(skips.len(), 2);
        // 没看完 + 带进度但进度为 0 → 全跳。
        let (steps, _) = writeback_plan(&targets, &sessions, &done, false, true, 0);
        assert!(steps.is_empty());
    }

    #[test]
    fn writeback_plan_skips_records_without_item_id() {
        let (mut targets, sessions) = wb_fixture();
        targets[0].last_emby_item_id = None;
        let done = HashSet::new();
        let (steps, skips) = writeback_plan(&targets, &sessions, &done, true, false, 0);
        assert_eq!(steps.len(), 1);
        assert_eq!(skips.len(), 1);
        assert!(skips[0].reason.contains("条目 id"));
    }

    // ===== 上报三件套 =====

    /// PlaySessionId 必须三次一致 —— 这是「看一半退出续播不落地」的老坑。
    #[test]
    fn report_target_reuses_one_play_session_id() {
        let s = session("https://b", "u2");
        let t1 = report_target(&s, "it1");
        let t2 = report_target(&s, "it1");
        assert_eq!(t1.play_session_id, t2.play_session_id);
        assert!(!t1.play_session_id.is_empty());
        assert_eq!(t1.media_source_id, "it1");
        assert_ne!(t1.play_session_id, report_target(&s, "it2").play_session_id);
    }

    #[test]
    fn ticks_to_secs_roundtrips_through_reporting() {
        // emby::report_* 收秒、内部再 *1e7 转回 ticks,别在这丢精度。
        assert_eq!(ticks_to_secs(600 * TICKS_PER_SEC), 600.0);
        assert_eq!((ticks_to_secs(27_390_000_000) * 1e7) as i64, 27_390_000_000);
    }
}
