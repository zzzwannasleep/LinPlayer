//! 媒体库屏蔽名单。
//!
//! 用户 2026-08-02:「给媒体库加上屏蔽功能……屏蔽之后不在首页显示,详情、播放记录、
//! 不参与搜索」。
//!
//! ## 为什么过滤放在核层而不是各端页面
//! 「首页 / 详情推荐 / 播放记录 / 搜索」在三端各自是不同的页面、不同的组件,数一数
//! **十几个渲染点**。放前端就是十几份 `.filter()`,谁漏一处就是"屏蔽了还看得见",
//! 而且是静默的。屏蔽的语义是「这些条目对我不存在」——那就在**数据出核层的那一刻**
//! 让它们不存在:`emby::` 里那几个取列表的函数各收一句,三端一次都不用改。
//!
//! ## 为什么另存一个文件而不是塞进 config.json
//! config.json 里装着全部服务器账号和令牌。屏蔽名单是会频繁增删的用户数据,
//! 和账号表放一起意味着每次点「屏蔽」都要整份重写账号表 —— 写坏一次的代价差了两个量级。
//! 与 watch_history.json 同规矩:落 data/,不落 cache/(删了就真没了)。
//!
//! ## 为什么同时记 id 和名字
//! id 是**每台服务器各自的** GUID:同一部剧在 A 服和 B 服 id 不同。而观看记录本身
//! 就是跨服的(见 [`crate::watch_history`],它按剧名/TMDB 对齐而不是按 id),
//! 只存 id 的话「在 A 服屏蔽了某剧,播放记录里从 B 服看的那几集还在」。
//! 所以:条目列表按 id 过滤(准),观看记录按名字过滤(跨服才对得上)。

use crate::emby::Item;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock, RwLock};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct BlockedItem {
    /// Emby item id(屏蔽发起的那台服务器上的)。
    pub id: String,
    /// 条目名。剧集卡上是剧名,电影卡上是片名 —— 观看记录靠它跨服对齐。
    pub name: String,
    /// 屏蔽时间(毫秒)。设置页要按时间列出来给用户解除。
    #[serde(default)]
    pub at: i64,
}

#[derive(Serialize, Deserialize, Default)]
struct Document {
    #[serde(default)]
    items: Vec<BlockedItem>,
}

fn path() -> PathBuf {
    crate::paths::data_root().join("blocklist.json")
}

/// 读-改-写要串行:两次「屏蔽」并发会互相吃掉对方那条(与 watch_history::Store 同规矩)。
fn write_lock() -> &'static Mutex<()> {
    static L: OnceLock<Mutex<()>> = OnceLock::new();
    L.get_or_init(|| Mutex::new(()))
}

/* 内存缓存。★ 过滤是**热路**:首页一次刷新就要过好几百个条目,每个都去读一次盘
   等于把「屏蔽」这个功能的成本摊到所有人身上。首次读盘后常驻,写的时候一起更新。 */
fn cache() -> &'static RwLock<Option<Vec<BlockedItem>>> {
    static C: OnceLock<RwLock<Option<Vec<BlockedItem>>>> = OnceLock::new();
    C.get_or_init(|| RwLock::new(None))
}

fn read_disk() -> Vec<BlockedItem> {
    std::fs::read_to_string(path())
        .ok()
        .filter(|s| !s.trim().is_empty())
        .and_then(|s| serde_json::from_str::<Document>(&s).ok())
        .unwrap_or_default()
        .items
}

/// 当前屏蔽名单(按屏蔽时间倒序 —— 刚屏蔽的排最前,方便"点错了马上撤")。
pub fn list() -> Vec<BlockedItem> {
    if let Some(v) = cache().read().unwrap().as_ref() {
        return v.clone();
    }
    let mut v = read_disk();
    v.sort_by(|a, b| b.at.cmp(&a.at));
    *cache().write().unwrap() = Some(v.clone());
    v
}

/// 屏蔽 / 解除屏蔽。已在名单里再屏蔽一次是幂等的(不重复追加)。
pub fn set(id: &str, name: &str, blocked: bool) {
    let _g = write_lock().lock().unwrap_or_else(|e| e.into_inner());
    let mut items = read_disk();
    items.retain(|e| e.id != id);
    if blocked {
        items.push(BlockedItem { id: id.to_string(), name: name.trim().to_string(), at: now_ms() });
    }
    if let Some(parent) = path().parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(json) = serde_json::to_string_pretty(&Document { items: items.clone() }) {
        let _ = std::fs::write(path(), format!("{json}\n"));
    }
    items.sort_by(|a, b| b.at.cmp(&a.at));
    *cache().write().unwrap() = Some(items);
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// 这个条目被屏蔽了吗。
///
/// ★ 三条判据缺一不可:
///   1. 条目自己被屏蔽(在媒体库网格上右键屏蔽的那张卡);
///   2. 它所属的剧被屏蔽(`series_id`)—— 屏蔽一部剧却在"继续观看"里
///      看见它的分集,是用户第一眼就会发现的漏网;
///   3. 剧名对上(`series_name` / `name`)—— 跨服的同一部剧 id 不同,只有名字对得上。
pub fn is_blocked(item: &Item) -> bool {
    let list = list();
    if list.is_empty() {
        return false;
    }
    let series = item.series_id.as_deref().unwrap_or("");
    list.iter().any(|b| {
        b.id == item.id
            || (!series.is_empty() && b.id == series)
            || name_hit(&b.name, item.series_name.as_deref())
            || (item.series_name.is_none() && name_hit(&b.name, Some(&item.name)))
    })
}

/// 名字命中。空名字**永不命中** —— 否则一条脏数据能把整个库屏蔽掉。
fn name_hit(blocked_name: &str, candidate: Option<&str>) -> bool {
    !blocked_name.is_empty() && candidate.is_some_and(|c| c.eq_ignore_ascii_case(blocked_name))
}

/// 这个 id 在名单里吗。**给媒体库用** —— 库(CollectionFolder)没有 series_id
/// 也不参与跨服名字比对,只按 id 判就够,而且不能按名字判:
/// 两台服务器上都叫「电影」的库是两个不同的库,按名字会一屏两台一起屏蔽。
pub fn is_blocked_id(id: &str) -> bool {
    !id.is_empty() && list().iter().any(|b| b.id == id)
}

/// 观看记录用:按标题判。记录是跨服的,没有可靠的 item id 可比。
pub fn is_blocked_title(title: &str, series_title: Option<&str>) -> bool {
    let list = list();
    list.iter()
        .any(|b| name_hit(&b.name, series_title) || name_hit(&b.name, Some(title)))
}

/// 就地滤掉被屏蔽的条目。名单为空时**一个条目都不碰**(常见路径的零开销)。
pub fn filter(items: &mut Vec<Item>) {
    if list().is_empty() {
        return;
    }
    items.retain(|it| !is_blocked(it));
}

#[cfg(test)]
mod tests {
    use super::*;

    /* ★ 这些用例共用同一个进程级缓存(`cache()`),cargo test 默认多线程并跑 ——
       不串行的话 A 用例刚 with_list,B 用例的清理就把它抹了,表现是**随机红**。
       本项目在 [[prefetch-fetch-needs-idle-timeout]] 上栽过一模一样的坑。 */
    fn guard(v: Vec<BlockedItem>) -> impl Drop {
        static L: OnceLock<Mutex<()>> = OnceLock::new();
        struct G(std::sync::MutexGuard<'static, ()>);
        impl Drop for G {
            fn drop(&mut self) {
                *cache().write().unwrap() = None;
            }
        }
        let g = G(L.get_or_init(|| Mutex::new(())).lock().unwrap_or_else(|e| e.into_inner()));
        *cache().write().unwrap() = Some(v);
        g
    }

    fn item(id: &str, name: &str, series_id: Option<&str>, series_name: Option<&str>) -> Item {
        Item {
            id: id.into(),
            name: name.into(),
            series_id: series_id.map(String::from),
            series_name: series_name.map(String::from),
            ..Item::default()
        }
    }

    #[test]
    fn blocks_the_card_itself() {
        let _g = guard(vec![BlockedItem { id: "s1".into(), name: "某剧".into(), at: 1 }]);
        assert!(is_blocked(&item("s1", "某剧", None, None)));
        assert!(!is_blocked(&item("s2", "别的剧", None, None)));
    }

    /* ★ 这条是真 bug 的护栏:屏蔽整部剧,"继续观看"里的**分集**id 和剧 id 不同,
       只比 item.id 的话分集会全部漏出来 —— 而那正是首页最显眼的一行。

       ★ series_name 必须给 None。第一版写成 Some("某剧"),摘掉 series_id 那条判据
         测试**照样绿** —— 因为名字那条把它兜住了,这条护栏其实一个字节都没在守。
         分集也确实可能没有 SeriesName(Fields 没要就是 null),这才是真实的漏网形态。 */
    #[test]
    fn blocks_episodes_of_a_blocked_series() {
        let _g = guard(vec![BlockedItem { id: "s1".into(), name: "某剧".into(), at: 1 }]);
        assert!(is_blocked(&item("ep9", "第 9 集", Some("s1"), None)));
    }

    /// 跨服:另一台服务器上同名剧的 id 完全不同,只能靠名字。
    #[test]
    fn blocks_same_title_on_another_server() {
        let _g = guard(vec![BlockedItem { id: "A-s1".into(), name: "某剧".into(), at: 1 }]);
        assert!(is_blocked(&item("B-ep3", "第 3 集", Some("B-s1"), Some("某剧"))));
        assert!(is_blocked_title("第 3 集", Some("某剧")));
    }

    /// 空名字不能变成通配符。
    #[test]
    fn empty_name_never_matches() {
        let _g = guard(vec![BlockedItem { id: "x".into(), name: "".into(), at: 1 }]);
        assert!(!is_blocked(&item("y", "", None, Some(""))));
        assert!(!is_blocked_title("", Some("")));
    }

    /* 媒体库只能按 id 判,**不能**按名字。
       两台服务器上都有一个叫「电影」的库,按名字判 = 屏蔽了 A 服的,B 服的也一起没了,
       而且用户完全不知道为什么。这条钉住 is_blocked_id 不许退化成名字比较。 */
    #[test]
    fn library_matches_by_id_only_never_by_name() {
        let _g = guard(vec![BlockedItem { id: "A-lib".into(), name: "电影".into(), at: 1 }]);
        assert!(is_blocked_id("A-lib"));
        assert!(!is_blocked_id("B-lib"), "另一台服务器上的同名库不该跟着被屏蔽");
        assert!(!is_blocked_id(""), "空 id 永不命中");
    }

    #[test]
    fn filter_drops_only_blocked() {
        let _g = guard(vec![BlockedItem { id: "s1".into(), name: "某剧".into(), at: 1 }]);
        let mut v = vec![item("s1", "某剧", None, None), item("s2", "留下", None, None)];
        filter(&mut v);
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].id, "s2");
    }
}
