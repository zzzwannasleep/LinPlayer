//! 弹幕库 —— 自托管的持久存储,不是缓存。
//!
//! 和 [`crate::cache`](那层管搜索/集表/排行榜的短期响应缓存)的区别是**语义**:
//! 缓存过期就丢,弹幕库过期只是「该去看看有没有新的」,本体一直留着。
//! 由此换来两件缓存做不到的事:
//!   * **弹幕只增不减**:每次拉回来按 cid 求并集,上游哪天返回残缺数据也毁不掉历史;
//!   * **配额烧光了照样有弹幕**:出站闸门关着的时候回存量,而不是回一个错误。
//!     这是「自己存」相对「每次问上游」最实在的收益。
//!
//! ## 刷新节奏:自适应,不查元数据
//! 用户的要求是「当季新番 6 小时拉一次,其余 7 天一次」。直接实现要先知道哪部是新番
//! (查当季榜、按 id 反推 animeId……),多一条上游依赖、多一个会过时的判断。
//!
//! 换一个等价但不需要任何元数据的信号:**这一集还在不在长弹幕**。
//!   * 一次刷新拿回了新弹幕 → 说明还在播/还在被看 → 间隔压回下限(6 小时);
//!   * 一次刷新一条新的都没有 → 间隔翻倍,直到上限(7 天)。
//! 在播的番自然停在 6 小时,老番自然滑到 7 天 —— 而且它还能处理「老番突然翻红」
//! 这种按季度判断永远判不出来的情况。
//!
//! 起始值取**下限**而不是上限:拉取是**惰性**的(只在用户真的要这一集时才发生),
//! 所以老番从 6 小时起步只是在有人反复重看时多拉几次,总量可以忽略;
//! 反过来从 7 天起步,新番第二天的观众就只能看到首日的弹幕 —— 那是看得见的坏。

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Serialize, Deserialize, Clone, Default)]
pub struct Entry {
    /// 弹幕条数(去重后)。
    pub count: u64,
    /// 落盘字节数。
    pub bytes: u64,
    /// 上次真正从上游拉取的时刻。
    pub fetched: i64,
    /// 当前刷新间隔(秒)。自适应,见模块文档。
    pub interval: u64,
    /// 上次被用户请求的时刻(容量淘汰按它排)。
    pub used: i64,
}

#[derive(Serialize, Deserialize, Default)]
struct Index {
    #[serde(default)]
    entries: HashMap<String, Entry>,
}

pub struct Store {
    dir: PathBuf,
    index_path: PathBuf,
    st: Mutex<Index>,
}

#[derive(Serialize, Clone, Copy, Default)]
pub struct StoreStats {
    /// 已存了多少集。
    pub episodes: u64,
    /// 弹幕总条数。
    pub comments: u64,
    /// 占用字节。
    pub bytes: u64,
    /// 其中「新鲜」(未到下次刷新时刻)的集数 —— 命中这些的请求一次上游都不发。
    pub fresh: u64,
}

/// 一集的取用结果。
pub enum Take {
    /// 有存量且还新鲜,直接用。
    Fresh(Vec<u8>),
    /// 有存量但过期了,该去上游看看有没有新的;拿不到就用这份。
    Stale(Vec<u8>),
    /// 一点存量都没有。
    Missing,
}

impl Store {
    pub fn open(dir: PathBuf) -> Self {
        let _ = std::fs::create_dir_all(&dir);
        let index_path = dir.join("index.json");
        let st = std::fs::read_to_string(&index_path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        Self { dir, index_path, st: Mutex::new(st) }
    }

    fn file(&self, episode_id: &str) -> PathBuf {
        // episodeId 直接来自 URL 路径,不能原样当文件名(`..`、`/`、盘符……)。
        let safe: String = episode_id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
            .take(64)
            .collect();
        self.dir.join(format!("{safe}.json"))
    }

    /// 取这一集。会顺手记一次「被用到」。
    ///
    /// ★ `min_i`/`max_i` 是**当前配置**的区间,存量条目的 interval 要按它夹一次再判。
    ///   不夹的话:条目的 interval 是写入那一刻定死的,管理员把上限从 7 天调到 1 天,
    ///   已经在库里的条目**要等满 7 天才会按新设置刷新** —— 改了设置看着没反应,
    ///   而且没有任何地方能看出为什么。(2026-08-02 端到端自检抓到的。)
    pub fn take(&self, episode_id: &str, now: i64, min_i: u64, max_i: u64) -> Take {
        let stale = {
            let mut s = self.st.lock().unwrap();
            let Some(e) = s.entries.get_mut(episode_id) else {
                return Take::Missing;
            };
            e.used = now;
            now - e.fetched >= e.interval.clamp(min_i, max_i) as i64
        };
        match std::fs::read(self.file(episode_id)) {
            Ok(b) if stale => Take::Stale(b),
            Ok(b) => Take::Fresh(b),
            Err(_) => {
                // 索引里有、盘上没了:清掉索引,当成没存过(否则永远报"有"但读不出来)
                self.st.lock().unwrap().entries.remove(episode_id);
                Take::Missing
            }
        }
    }

    /// 把上游这次拿回来的合并进去,返回(合并后的正文, 新增条数)。
    ///
    /// ★ 合并而不是替换。上游偶尔返回残缺数据(实测过 429 之外还有回空列表的),
    ///   替换的话用户这一集的弹幕当场清零,而且是永久的 —— 我们是最后一份拷贝。
    pub fn merge(&self, episode_id: &str, fresh: &[u8], now: i64, min_i: u64, max_i: u64) -> (Vec<u8>, u64) {
        let old = std::fs::read(self.file(episode_id)).unwrap_or_default();
        let (merged, total, added) = merge_comments(&old, fresh);

        /* 自适应间隔:有新弹幕就压回下限,一条都没有就翻倍。
           ★ 只在**确实发生了一次上游拉取**时调整 —— 拿缓存命中去调,间隔会在
             没有任何新信息的情况下乱走。 */
        let prev = self.st.lock().unwrap().entries.get(episode_id).map(|e| e.interval).unwrap_or(0);
        let interval = if added > 0 || prev == 0 {
            min_i
        } else {
            // prev 本身可能落在新区间之外(管理员刚调过设置),先夹再翻倍。
            prev.clamp(min_i, max_i).saturating_mul(2).clamp(min_i, max_i)
        };

        let _ = std::fs::write(self.file(episode_id), &merged);
        let mut s = self.st.lock().unwrap();
        s.entries.insert(
            episode_id.to_string(),
            Entry { count: total, bytes: merged.len() as u64, fetched: now, interval, used: now },
        );
        let snapshot = serde_json::to_string(&*s).unwrap_or_default();
        drop(s);
        let _ = std::fs::write(&self.index_path, snapshot);
        (merged, added)
    }

    /// 统计。`min_i`/`max_i` 同 [`Self::take`] —— 「新鲜」的判据必须和真实取用路径
    /// 用同一套,不然管理界面上显示的「还新鲜 N 集」和实际会不会去上游对不上。
    pub fn stats(&self, now: i64, min_i: u64, max_i: u64) -> StoreStats {
        let s = self.st.lock().unwrap();
        let mut st = StoreStats::default();
        for e in s.entries.values() {
            st.episodes += 1;
            st.comments += e.count;
            st.bytes += e.bytes;
            if now - e.fetched < e.interval.clamp(min_i, max_i) as i64 {
                st.fresh += 1;
            }
        }
        st
    }

    /// 超容量按「最久没人看」淘汰。弹幕库是要长期留的,但盘是有限的。
    pub fn evict(&self, max_bytes: u64) -> u64 {
        let mut s = self.st.lock().unwrap();
        let mut total: u64 = s.entries.values().map(|e| e.bytes).sum();
        if total <= max_bytes {
            return 0;
        }
        let mut order: Vec<(String, i64, u64)> =
            s.entries.iter().map(|(k, e)| (k.clone(), e.used, e.bytes)).collect();
        order.sort_by_key(|(_, used, _)| *used);
        let mut dropped = 0;
        for (k, _, b) in order {
            if total <= max_bytes {
                break;
            }
            s.entries.remove(&k);
            let _ = std::fs::remove_file(self.file(&k));
            total = total.saturating_sub(b);
            dropped += 1;
        }
        let snapshot = serde_json::to_string(&*s).unwrap_or_default();
        drop(s);
        let _ = std::fs::write(&self.index_path, snapshot);
        dropped
    }

    pub fn clear(&self) {
        let mut s = self.st.lock().unwrap();
        for k in s.entries.keys() {
            let _ = std::fs::remove_file(self.file(k));
        }
        s.entries.clear();
        let _ = std::fs::write(&self.index_path, "{}");
    }
}

/// 按 cid 求并集。返回(合并后的 JSON, 总条数, 新增条数)。
///
/// 上游的形状是 `{"count":N,"comments":[{"cid":..,"p":"..","m":".."}]}`;
/// 我们原样保持这个形状,客户端那边一个字都不用改。
fn merge_comments(old: &[u8], fresh: &[u8]) -> (Vec<u8>, u64, u64) {
    let take = |b: &[u8]| -> Vec<Value> {
        serde_json::from_slice::<Value>(b)
            .ok()
            .and_then(|v| v["comments"].as_array().cloned())
            .unwrap_or_default()
    };
    let (o, f) = (take(old), take(fresh));
    // 上游这次解不出来(网络截断/返回了错误页)→ 保住存量,别用它去覆盖。
    if f.is_empty() && !o.is_empty() {
        return (old.to_vec(), o.len() as u64, 0);
    }
    let mut seen: std::collections::HashSet<String> = o.iter().map(cid_of).collect();
    let before = o.len();
    let mut out = o;
    for c in f {
        if seen.insert(cid_of(&c)) {
            out.push(c);
        }
    }
    let added = (out.len() - before) as u64;
    let total = out.len() as u64;
    let body = serde_json::json!({ "count": total, "comments": out });
    (serde_json::to_vec(&body).unwrap_or_default(), total, added)
}

/// cid 可能是数字也可能是字符串(不同源不一样),统一成字符串比。
/// 没有 cid 的条目拿整条内容当身份 —— 总比全部判成同一条(只留一条)强。
fn cid_of(c: &Value) -> String {
    match &c["cid"] {
        Value::Null => c.to_string(),
        v => v.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(n: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("lp-dm-store-{n}"));
        let _ = std::fs::remove_dir_all(&p);
        p
    }
    fn body(cids: &[i64]) -> Vec<u8> {
        let c: Vec<Value> = cids
            .iter()
            .map(|i| serde_json::json!({"cid": i, "p": "1.0,1,16777215,u", "m": format!("弹幕{i}")}))
            .collect();
        serde_json::to_vec(&serde_json::json!({"count": c.len(), "comments": c})).unwrap()
    }
    fn cids(b: &[u8]) -> Vec<i64> {
        let v: Value = serde_json::from_slice(b).unwrap();
        let mut x: Vec<i64> =
            v["comments"].as_array().unwrap().iter().map(|c| c["cid"].as_i64().unwrap()).collect();
        x.sort();
        x
    }

    /* ★ 合并而不是替换。我们是弹幕的最后一份拷贝 —— 上游哪天回残缺数据,
       替换的写法会把用户这一集的弹幕永久清零。
       反向验证:把 merge 改成直接写 fresh,本测试立刻红。 */
    #[test]
    fn merging_only_ever_adds_never_loses() {
        let s = Store::open(tmp("merge"));
        let (b1, a1) = s.merge("ep1", &body(&[1, 2, 3]), 1000, 60, 600);
        assert_eq!(cids(&b1), vec![1, 2, 3]);
        assert_eq!(a1, 3);

        let (b2, a2) = s.merge("ep1", &body(&[3, 4]), 2000, 60, 600);
        assert_eq!(cids(&b2), vec![1, 2, 3, 4], "旧的必须留着,新的并进来");
        assert_eq!(a2, 1, "只有 cid=4 是新的");

        // 上游回了个空列表(实测发生过)—— 存量一条都不能少
        let (b3, a3) = s.merge("ep1", br#"{"count":0,"comments":[]}"#, 3000, 60, 600);
        assert_eq!(cids(&b3), vec![1, 2, 3, 4], "上游回空绝不能把存量清掉");
        assert_eq!(a3, 0);

        // 上游回了非 JSON(网络截断/错误页)
        let (b4, _) = s.merge("ep1", b"<html>502</html>", 4000, 60, 600);
        assert_eq!(cids(&b4), vec![1, 2, 3, 4], "解不出来更不能覆盖");
    }

    /* 自适应间隔:有新弹幕就压回下限,没有就翻倍到上限。
       这条替代了「查当季新番榜」那套元数据判断。
       ★ 反向验证:把 interval 恒设成 min_i,本测试立刻红。 */
    #[test]
    fn refresh_interval_tracks_whether_the_episode_is_still_growing() {
        let s = Store::open(tmp("interval"));
        const MIN: u64 = 6 * 3600;
        const MAX: u64 = 7 * 86400;
        let iv = |k: &str| s.st.lock().unwrap().entries.get(k).unwrap().interval;

        s.merge("ep", &body(&[1]), 0, MIN, MAX);
        assert_eq!(iv("ep"), MIN, "首次入库从下限起步(新番第二天的观众要看得到新弹幕)");

        s.merge("ep", &body(&[1]), 1, MIN, MAX);
        assert_eq!(iv("ep"), MIN * 2, "一条新的都没有 → 翻倍");
        s.merge("ep", &body(&[1]), 2, MIN, MAX);
        assert_eq!(iv("ep"), MIN * 4);

        s.merge("ep", &body(&[1, 2]), 3, MIN, MAX);
        assert_eq!(iv("ep"), MIN, "★ 又长弹幕了 → 压回下限(老番翻红也能跟上)");

        for _ in 0..20 {
            s.merge("ep", &body(&[1, 2]), 4, MIN, MAX);
        }
        assert_eq!(iv("ep"), MAX, "一直不长就停在上限,不会无限翻倍");
    }

    /// 新鲜/过期/没有,三种取用状态要分得清 —— 过期不等于没有(那是回存量的依据)。
    #[test]
    fn take_distinguishes_fresh_stale_and_missing() {
        let s = Store::open(tmp("take"));
        assert!(matches!(s.take("nope", 1000, 60, 600), Take::Missing));
        s.merge("ep", &body(&[1]), 1000, 60, 600);
        assert!(matches!(s.take("ep", 1030, 60, 600), Take::Fresh(_)), "间隔内是新鲜的");
        assert!(matches!(s.take("ep", 1061, 60, 600), Take::Stale(_)), "超过间隔是过期,但**有存量**");
    }

    /* ★ 管理员改了刷新区间,存量条目必须**立刻**按新区间判,不能等它下次刷新。
       不夹的话:上限从 7 天调到 1 天,已入库的条目要等满 7 天才生效 ——
       改了设置看着没反应,而且没有任何地方看得出为什么。
       反向验证:把 take 里的 .clamp(min_i, max_i) 去掉,本测试立刻红。 */
    #[test]
    fn changing_the_bounds_takes_effect_on_existing_entries_immediately() {
        let s = Store::open(tmp("rebound"));
        s.merge("ep", &body(&[1]), 0, 7 * 86400, 7 * 86400); // 存进去时间隔是 7 天
        assert!(matches!(s.take("ep", 3600, 7 * 86400, 7 * 86400), Take::Fresh(_)));
        assert!(
            matches!(s.take("ep", 3600, 60, 600), Take::Stale(_)),
            "管理员把上限调到 10 分钟,这条 1 小时前拉的必须立刻算过期"
        );
    }

    /// episodeId 来自 URL,不能原样当文件名。
    #[test]
    fn episode_id_never_escapes_the_store_directory() {
        let dir = tmp("path");
        let s = Store::open(dir.clone());
        s.merge("../../etc/passwd", &body(&[1]), 1000, 60, 600);
        let escaped = dir.parent().unwrap().parent().unwrap().join("etc");
        assert!(!escaped.exists(), "路径穿越:写到库目录外面去了");
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 2, "应当只有 index.json + 一个净化过的文件名");
    }

    #[test]
    fn eviction_drops_the_least_recently_watched() {
        let s = Store::open(tmp("evict"));
        let big: Vec<i64> = (0..400).collect();
        s.merge("old", &body(&big), 1000, 60, 600);
        s.merge("new", &body(&big), 2000, 60, 600);
        let before = s.stats(2000, 60, 600);
        assert_eq!(before.episodes, 2);
        let dropped = s.evict(before.bytes / 2);
        assert!(dropped >= 1, "超容量必须真的淘汰");
        assert!(matches!(s.take("old", 3000, 60, 600), Take::Missing), "最久没人看的先出局");
        assert!(!matches!(s.take("new", 3000, 60, 600), Take::Missing), "刚看过的要留着");
    }

    #[test]
    fn stats_report_what_the_admin_asked_for() {
        let s = Store::open(tmp("stats"));
        s.merge("a", &body(&[1, 2, 3]), 1000, 60, 600);
        s.merge("b", &body(&[4, 5]), 1000, 60, 600);
        let st = s.stats(1010, 60, 600);
        assert_eq!(st.episodes, 2, "已缓存集数");
        assert_eq!(st.comments, 5, "弹幕总条数");
        assert!(st.bytes > 0, "存储总大小");
        assert_eq!(st.fresh, 2, "都还在间隔内");
        assert_eq!(s.stats(1000 + 61, 60, 600).fresh, 0, "过了间隔就不算新鲜");
    }
}
