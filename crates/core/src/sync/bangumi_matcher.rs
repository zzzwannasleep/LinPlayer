// Bangumi 反查器 —— 迁自 Dart bangumi_matcher.dart。把 Emby 项目反查成 Bangumi subject/episode,
// 纯在线 API(不下载 bangumi-data 离线集):
// 1) /v0/search/subjects 按剧名搜 → 用开播日期(±180天)择优定位本体;
// 2) 多季沿「续集」关系链 /v0/subjects/{id}/subjects 走到目标季;
// 3) /v0/episodes 按集号取真实 ep id。

use serde_json::Value;

use super::calendar::parse_date_to_days;
use super::BANGUMI_API_OFFICIAL;
// 标题评分直接借弹幕那套(编辑距离 + 包含下限 + 季号硬信号 + 平行语料),别造第二套。
use crate::danmaku::{core_name, season_term, title_score, MatchInput};

// ★ 2026-07-21:原来这里挂的是 BANGUMI_API_MIRROR(bgmapi.anibt.net)。
// 那个反代过不了 CF —— 四个查询全部 `.ok()?` 静默返回 None,resolve_episode 永远失败,
// 于是 set_collection_type(3=在看) 一次都没被调到。这就是「在看不会加进来」的直接根因。
// bangumi.rs 早就换官方了,这个文件被漏掉。图片仍走 anibt 反代,与 mod.rs 的注释一致。
const API_BASE: &str = BANGUMI_API_OFFICIAL;
const MAX_SEQUEL_HOPS: i64 = 10;
const EPISODES_PAGE_LIMIT: i64 = 200;
const DATE_TOLERANCE_DAYS: i64 = 180;

/// 解析结果:subject_id + 该集真实 episode_id(非集号)。
#[derive(Clone, Copy, serde::Serialize)]
pub struct BangumiEpisodeRef {
    pub subject_id: i64,
    pub episode_id: i64,
    /// 这是本篇的最后一集吗。用来在看完最后一集时把整个条目从「在看」推到「看过」——
    /// 没有它,Bangumi 永远停在在看,用户说的「更不用说已看完的了」就是这个。
    pub is_last_episode: bool,
}

struct SubjectMatch {
    subject_id: i64,
    season_matched: bool,
}

fn client() -> reqwest::Client {
    crate::http::client()
}

/// 解析剧集 → (subject_id, episode_id)。Err 带失败原因(宿主会打日志)。
pub async fn resolve_episode(
    title: &str,
    original_title: Option<&str>,
    air_date: Option<&str>,
    season: i64,
    episode: i64,
) -> Result<BangumiEpisodeRef, String> {
    let m = search_subject(title, original_title, air_date, season).await?;
    let mut subject_id = m.subject_id;
    if season > 1 && !m.season_matched {
        subject_id = resolve_season_subject_id(m.subject_id, season)
            .await
            .ok_or_else(|| format!("条目 {} 的续集链走不到第 {season} 季", m.subject_id))?;
    }
    let (episode_id, is_last_episode) = find_episode_id_by_sort(subject_id, episode)
        .await
        .ok_or_else(|| format!("条目 {subject_id} 的分集表里没有第 {episode} 集"))?;
    Ok(BangumiEpisodeRef { subject_id, episode_id, is_last_episode })
}

/// 解析电影 → (subject_id, 主章节 episode_id)。
pub async fn resolve_movie(
    title: &str,
    original_title: Option<&str>,
    air_date: Option<&str>,
) -> Result<BangumiEpisodeRef, String> {
    let m = search_subject(title, original_title, air_date, 1).await?;
    let (episode_id, _) = find_episode_id_by_sort(m.subject_id, 1)
        .await
        .ok_or_else(|| format!("条目 {} 没有可标记的章节", m.subject_id))?;
    // 电影只有一「集」,看完即完结。
    Ok(BangumiEpisodeRef { subject_id: m.subject_id, episode_id, is_last_episode: true })
}

/* ============ 标题搜索 → subject ============

   ★ 2026-08-01 重写。旧实现挑候选的规则是:开播日期能对上就用日期最近的,
   **对不上就无条件拿 results[0]** —— 标题相似度一路信号都没有。后果两头都差:
     - 搜「孤独摇滚」回来一堆同名衍生/OVA/广播剧,第一条经常不是本体 → 标到别的条目上;
     - 库里是中文名而 Bangumi 收的是日文原名时,搜索本身就回不了东西 → 整条静默跳过。
   弹幕那边为这件事已经写过一套评分(编辑距离 + 包含下限 + 季号硬信号 + 平行语料 alt_titles,
   见 danmaku::title_score/season_term),那套是照 bangumi2anibt 重写并有测试钉住的。
   这里直接复用它,不再造第二套:MatchInput 本来就是 pub 的,装好就能用。 */

/// 标题相似度门槛。低于它就判「没匹配上」而不是硬塞一个 ——
/// 标错条目比不标更坏:那是往用户的 Bangumi 账号里写别人的番。
const MIN_TITLE_SCORE: f64 = 0.45;

/// 单个候选的评分,返回 (总分, 标题相似度, 开播日期是否吻合)。
///
/// 后两项是**两条独立的准入证据**,任一成立即可(见 search_subject 的 eligible)——
/// Bangumi 有些条目 name_cn 是空的,库里又是中文名,这时标题一路必然 0 分,
/// 但开播日期对得上仍是很硬的证据。只认标题会把这类本来能对上的条目误杀。
fn candidate_score(input: &MatchInput, air_days: Option<i64>, c: &Value) -> (f64, f64, bool) {
    let jp = c["name"].as_str().unwrap_or("");
    let cn = c["name_cn"].as_str().unwrap_or("");
    let title_s = title_score(input, jp).max(title_score(input, cn));
    // 季号判定用带季信息的那个写法(name_cn 常带「第二季」,name 常不带)。
    let season_s = season_term(input, cn).max(season_term(input, jp));
    // 开播日期:Bangumi 的 date 是这一**季/部**的首播日,和 Emby 的 PremiereDate 同口径。
    // 对得上是强证据,对不上是强反证 —— 但缺日期时不表态(新番/冷门条目常常没有)。
    let date_ok = matches!(
        (air_days, c["date"].as_str().and_then(parse_date_to_days)),
        (Some(a), Some(b)) if (a - b).abs() <= DATE_TOLERANCE_DAYS
    );
    let date_s = match (air_days, c["date"].as_str().and_then(parse_date_to_days)) {
        (Some(_), Some(_)) if date_ok => 0.3,
        (Some(_), Some(_)) => -0.3,
        _ => 0.0,
    };
    (title_s + season_s + date_s, title_s, date_ok)
}

async fn search_subject(
    title: &str,
    original_title: Option<&str>,
    air_date: Option<&str>,
    season: i64,
) -> Result<SubjectMatch, String> {
    // 平行语料:中文名 / 原名 / 剥掉季号和副标题的主名。哪个能对上事先不知道,全给评分器。
    let input = MatchInput {
        title: title.to_string(),
        alt_titles: [original_title.unwrap_or("").to_string(), core_name(title)]
            .into_iter()
            .filter(|s| !s.trim().is_empty())
            .collect(),
        season_no: Some(season.max(1)),
        ..Default::default()
    };

    // 召回查询:逐层放宽(与弹幕那边同序),命中即停 —— 后面几层只是救命稻草。
    let mut queries: Vec<String> = Vec::new();
    for q in [title.to_string(), strip_season_suffix(title), core_name(title)]
        .into_iter()
        .chain(original_title.map(str::to_string))
    {
        let q = q.trim().to_string();
        if !q.is_empty() && !queries.iter().any(|e| e.eq_ignore_ascii_case(&q)) {
            queries.push(q);
        }
    }

    let air_days = air_date.and_then(parse_date_to_days);
    // 门槛先筛、再按总分排:反过来(先按总分挑再看门槛)会让一个日期碰巧对上的
    // 无关条目把真本体挤掉,然后整条判失败 —— 明明本体就在候选里。
    let mut best: Option<(f64, i64, String)> = None; // 合格候选中总分最高
    let mut closest: Option<(f64, i64, String)> = None; // 全体中最像的,只用来解释失败原因
    for q in &queries {
        for r in &search_bgm(q).await {
            let Some(id) = r["id"].as_i64() else { continue };
            let (total, title_s, date_ok) = candidate_score(&input, air_days, r);
            // 两个名字都留着:季号可能只写在其中一个上(name_cn 常带「第二季」,name 常不带)。
            let names = format!(
                "{} {}",
                r["name_cn"].as_str().unwrap_or(""),
                r["name"].as_str().unwrap_or("")
            );
            let names = names.trim().to_string();
            // 标题够像 **或** 开播日期对得上,任一成立就算合格候选。
            if title_s >= MIN_TITLE_SCORE || date_ok {
                if best.as_ref().map_or(true, |(b, ..)| total > *b) {
                    best = Some((total, id, names));
                }
            } else if closest.as_ref().map_or(true, |(t, ..)| title_s > *t) {
                closest = Some((title_s, id, names));
            }
        }
        // 这一层已经捞出够像的了就不再往下打接口(每层都是一次 Bangumi 请求)。
        if best.is_some() {
            break;
        }
    }

    let Some((_total, id, name)) = best else {
        return Err(match closest {
            Some((t, cid, cname)) => format!(
                "最像的候选是「{cname}」(#{cid}),标题相似度只有 {t:.2}(门槛 {MIN_TITLE_SCORE}),开播日期也对不上 —— 判为没匹配上,不乱标"
            ),
            None => format!("搜「{title}」在 Bangumi 一条结果都没有"),
        });
    };
    // 候选标题自带「第 N 季」且正是要的那季 → 它本身就是季本体,不必再走续集链。
    let season_matched = season <= 1 || title_has_season_info(&name, season);
    Ok(SubjectMatch { subject_id: id, season_matched })
}

/// 调 Bangumi 搜索,返回候选(含 id/name/name_cn/date)。v0 POST 优先,回退旧 GET。
async fn search_bgm(keyword: &str) -> Vec<Value> {
    // 新版:POST /v0/search/subjects(type 2 = 动画)。
    let body = serde_json::json!({
        "keyword": keyword,
        "filter": { "type": [2], "nsfw": true }
    });
    if let Ok(resp) = client()
        .post(format!("{API_BASE}/v0/search/subjects?limit=10"))
        .json(&body)
        .send()
        .await
    {
        if resp.status().is_success() {
            if let Ok(j) = resp.json::<Value>().await {
                if let Some(arr) = j["data"].as_array() {
                    if !arr.is_empty() {
                        return arr.clone();
                    }
                }
            }
        }
    }
    // 回退旧版:GET /search/subject/{keyword}?type=2。
    let url = format!("{API_BASE}/search/subject/{}", urlencoding::encode(keyword));
    if let Ok(resp) = client().get(&url).query(&[("type", "2"), ("responseGroup", "small")]).send().await {
        if resp.status().is_success() {
            if let Ok(j) = resp.json::<Value>().await {
                if let Some(arr) = j["list"].as_array() {
                    return arr.clone();
                }
            }
        }
    }
    vec![]
}

/// 已知 subject_id,按集号取真实 ep id(供弹弹play 反查路径复用)。
pub async fn find_episode_id(subject_id: i64, episode: i64) -> Option<i64> {
    find_episode_id_by_sort(subject_id, episode).await.map(|(id, _)| id)
}

// ============ 续集链 / 集数解析 ============
async fn resolve_season_subject_id(root_id: i64, season: i64) -> Option<i64> {
    if season <= 1 {
        return Some(root_id);
    }
    if season - 1 > MAX_SEQUEL_HOPS {
        return None; // 防御异常季号狂刷接口
    }
    let mut current = root_id;
    for _ in 1..season {
        current = next_sequel_subject_id(current).await?;
    }
    Some(current)
}

async fn next_sequel_subject_id(subject_id: i64) -> Option<i64> {
    let resp = client().get(format!("{API_BASE}/v0/subjects/{subject_id}/subjects")).send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let j: Value = resp.json().await.ok()?;
    // 响应可能是数组或 {data:[...]}。
    let list = if j.is_array() { j.as_array() } else { j["data"].as_array() }?;
    for rel in list {
        if rel["relation"].as_str() == Some("续集") {
            // id 可能是数字或字符串。
            return rel["id"].as_i64().or_else(|| rel["id"].as_str().and_then(|s| s.parse().ok()));
        }
    }
    None
}

/// 返回 (episode_id, 是否为本篇最后一集)。
async fn find_episode_id_by_sort(subject_id: i64, target_sort: i64) -> Option<(i64, bool)> {
    let mut offset = 0;
    while offset < EPISODES_PAGE_LIMIT * 5 {
        let resp = client()
            .get(format!("{API_BASE}/v0/episodes"))
            .query(&[
                ("subject_id", subject_id.to_string()),
                ("type", "0".to_string()), // 本篇
                ("limit", EPISODES_PAGE_LIMIT.to_string()),
                ("offset", offset.to_string()),
            ])
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let j: Value = resp.json().await.ok()?;
        // total = 本篇总集数。响应按 sort 升序,故「第 offset+i 条」就是全局第 offset+i 集。
        let total = j["total"].as_i64().unwrap_or(0);
        let data = j["data"].as_array()?;
        if data.is_empty() {
            return None;
        }
        for (i, ep) in data.iter().enumerate() {
            let sort = ep["sort"].as_i64();
            let ep_no = ep["ep"].as_i64();
            if sort == Some(target_sort) || ep_no == Some(target_sort) {
                let id = ep["id"]
                    .as_i64()
                    .or_else(|| ep["id"].as_str().and_then(|s| s.parse().ok()))?;
                // total 缺失(=0)时保守判否:宁可不标完结,也别在没播完时误标。
                let is_last = total > 0 && offset + i as i64 + 1 == total;
                return Some((id, is_last));
            }
        }
        if (data.len() as i64) < EPISODES_PAGE_LIMIT {
            return None;
        }
        offset += EPISODES_PAGE_LIMIT;
    }
    None
}

// ============ 工具(纯逻辑,可测) ============
/// 标题是否含第 N 季信息(移植自 Bangumi-syncer)。
fn title_has_season_info(title: &str, season: i64) -> bool {
    let cn = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"];
    let mut keywords = vec![
        format!("第{season}季"),
        format!("第{season}期"),
        format!("{season}季"),
        format!("{season}期"),
        format!("Season {season}"),
        format!("S{season}"),
    ];
    if (1..=10).contains(&season) {
        let c = cn[season as usize];
        keywords.extend([format!("第{c}季"), format!("第{c}期"), format!("{c}季"), format!("{c}期")]);
    }
    keywords.iter().any(|k| title.contains(k.as_str()))
}

/// 去掉标题尾部的季度后缀(第N季/期/话/集、Season N、SN、罗马数字 II、尾部数字)。
fn strip_season_suffix(title: &str) -> String {
    use regex::Regex;
    // 逐条剥离(与 Dart 同序)。正则编译一次即可,这里为简明每调编译(匹配频率极低)。
    let pats = [
        r"\s*第?\s*\d+\s*[期季話话集]\s*$",
        r"(?i)\s*Season\s*\d+\s*$",
        r"(?i)\s*S\d+\s*$",
        r"\s+I I*\s*$", // 占位,下面单独处理罗马数字
        r"\s+\d+\s*$",
    ];
    let mut t = title.to_string();
    for (i, p) in pats.iter().enumerate() {
        if i == 3 {
            // 罗马数字 II/III...(至少两个 I)。
            if let Ok(re) = Regex::new(r"\s+II+\s*$") {
                t = re.replace(&t, "").to_string();
            }
            continue;
        }
        if let Ok(re) = Regex::new(p) {
            t = re.replace(&t, "").to_string();
        }
    }
    let trimmed = t.trim();
    if trimmed.is_empty() {
        title.to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn season_info_detection() {
        assert!(title_has_season_info("进击的巨人 第二季", 2));
        assert!(title_has_season_info("Re:Zero Season 2", 2));
        assert!(title_has_season_info("某番 S3", 3));
        assert!(!title_has_season_info("进击的巨人", 2));
    }

    fn input(title: &str, season: i64) -> MatchInput {
        MatchInput {
            title: title.into(),
            alt_titles: vec![core_name(title)],
            season_no: Some(season),
            ..Default::default()
        }
    }

    fn cand(cn: &str, jp: &str, date: &str) -> Value {
        serde_json::json!({ "id": 1, "name": jp, "name_cn": cn, "date": date })
    }

    /* 旧实现在日期对不上时**无条件拿 results[0]** —— 搜索回来的第一条经常是同名衍生/OVA。
       这两条断言就是那个行为的闸门:把 candidate_score 换回「谁先来谁赢」它立刻红。 */
    #[test]
    fn scoring_separates_the_real_subject_from_noise() {
        let want = input("孤独摇滚!", 1);
        let real = candidate_score(&want, parse_date_to_days("2022-10-08"), &cand("孤独摇滚!", "ぼっち・ざ・ろっく!", "2022-10-08"));
        let noise = candidate_score(&want, parse_date_to_days("2022-10-08"), &cand("派对浪客诸葛孔明", "パリピ孔明", "2022-04-05"));
        assert!(real.1 >= MIN_TITLE_SCORE, "本体标题分 {:.2} 该过门槛", real.1);
        assert!(noise.1 < MIN_TITLE_SCORE, "无关条目标题分 {:.2} 不该过门槛", noise.1);
        assert!(real.0 > noise.0);
    }

    /// 季号是硬信号:剥掉季号后两季标题一模一样,只有这一路能把它们分开。
    /// 旧实现连标题都不比,自然更分不开。
    #[test]
    fn season_beats_identical_titles() {
        let want = input("孤独摇滚!", 2);
        let s1 = candidate_score(&want, None, &cand("孤独摇滚!", "", ""));
        let s2 = candidate_score(&want, None, &cand("孤独摇滚! 第二季", "", ""));
        assert!(s2.0 > s1.0, "第二季 {:.2} 应当压过第一季 {:.2}", s2.0, s1.0);
    }

    /// 原名(日文)是平行语料:库里是中文名而 Bangumi 只收了日文名时,靠它才对得上。
    /// 去掉 MatchInput.alt_titles 这一路本测试红。
    #[test]
    fn original_title_carries_cross_language_match() {
        let mut want = input("孤独摇滚!", 1);
        want.alt_titles.push("ぼっち・ざ・ろっく!".into());
        let only_jp = candidate_score(&want, None, &cand("", "ぼっち・ざ・ろっく!", ""));
        assert!(only_jp.1 >= MIN_TITLE_SCORE, "只有日文名的候选拿到 {:.2}", only_jp.1);
    }

    /// 开播日期是第二条准入证据。Bangumi 有些条目 name_cn 为空、只有日文原名,
    /// 库里又只有中文名 —— 标题一路必然 0 分。只认标题会把这类误杀成「没匹配上」。
    #[test]
    fn air_date_alone_keeps_a_candidate_eligible() {
        let want = input("孤独摇滚!", 1);
        let (_, title_s, date_ok) =
            candidate_score(&want, parse_date_to_days("2022-10-08"), &cand("", "ぼっち・ざ・ろっく!", "2022-10-08"));
        assert!(title_s < MIN_TITLE_SCORE, "这条本来就该标题分低,实际 {title_s:.2}");
        assert!(date_ok, "日期同一天却判不吻合");
    }

    #[test]
    fn strip_season_suffix_cases() {
        // 与 Dart 同:只剥「数字」季度后缀(\d+),中文数字季不动(靠搜索+日期择优)。
        assert_eq!(strip_season_suffix("进击的巨人 第2季"), "进击的巨人");
        assert_eq!(strip_season_suffix("Re:Zero Season 2"), "Re:Zero");
        assert_eq!(strip_season_suffix("某番 II"), "某番");
        assert_eq!(strip_season_suffix("孤独摇滚 12"), "孤独摇滚");
        // 中文数字季不含 \d,保持不变。
        assert_eq!(strip_season_suffix("进击的巨人 第二季"), "进击的巨人 第二季");
    }
}
