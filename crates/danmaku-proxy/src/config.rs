//! 运行时配置。**凭据不在这里** —— AppId/AppSecret/管理密码一律走环境变量,
//! 免得管理界面存盘时把密钥写进一个随手会被 tar 走的 JSON。
//!
//! 这份配置管理界面可以改、改完立刻生效并落盘,所以每一项都要能热更新:
//! 别把任何一项在启动时读进局部变量。

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::RwLock;

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(default)]
pub struct Config {
    /// 出站闸门:每分钟最多向弹弹Play 发多少次。
    ///
    /// ★ 这是整个服务**最重要**的一组数。代理的价值不在于抗打,而在于把
    ///   「我们收到多少请求」和「我们转发多少请求」解耦 —— 被刷爆的后果就退化成
    ///   「这段时间弹幕慢」,而配额一个不掉。没有这道闸,代理只是把攻击原样中继过去。
    pub upstream_per_minute: u32,
    /// 出站闸门:每天最多向弹弹Play 发多少次。按官方配额留 20% 余量填。
    pub upstream_per_day: u32,

    /// 单个来源 IP 每分钟最多请求数(含库命中)。防单机把本服务打满;
    /// 真正拦人的活交给 Cloudflare,这里只是最后一层自我保护。
    pub client_per_minute: u32,

    // ---- 弹幕库(长期持有)----
    /// 弹幕刷新间隔**下限**(秒)。默认 6 小时 —— 在播的番会稳定停在这个值上。
    pub refresh_min_secs: u64,
    /// 弹幕刷新间隔**上限**(秒)。默认 7 天 —— 不再长弹幕的老番会滑到这个值。
    ///
    /// 两个值之间怎么走是**自适应**的:一次刷新长了新弹幕就压回下限,
    /// 一条没长就翻倍。所以不需要去查"哪部是当季新番",也能处理老番翻红。
    pub refresh_max_secs: u64,
    /// 弹幕库磁盘上限(MB)。超了按「最久没人看」淘汰。
    pub store_max_mb: u64,

    // ---- 短期响应缓存(搜索/集表/排行榜)----
    pub ttl_search_secs: u64,
    pub ttl_trending_secs: u64,
    pub cache_max_mb: u64,

    /// 总开关。关掉后所有转发立即返回维护中。
    pub enabled: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            /* 默认值按「弹弹Play 个人开发者常见配额约 1000~5000/日」保守取。
               ★ 部署后**必须**照你自己的实际配额在管理界面改一次 ——
                 默认值只保证「不会一天之内烧光」,不保证用满。 */
            upstream_per_minute: 30,
            upstream_per_day: 3000,
            client_per_minute: 30,
            refresh_min_secs: 6 * 3600,
            refresh_max_secs: 7 * 86400,
            store_max_mb: 20 * 1024,
            ttl_search_secs: 24 * 3600,
            ttl_trending_secs: 3600,
            cache_max_mb: 512,
            enabled: true,
        }
    }
}

pub struct Store {
    path: PathBuf,
    cur: RwLock<Config>,
}

impl Store {
    pub fn load(dir: &PathBuf) -> Self {
        let path = dir.join("config.json");
        let cur = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        let s = Self { path, cur: RwLock::new(cur) };
        s.save(); // 首次启动就把默认值写出来,让人知道有哪些旋钮
        s
    }

    pub fn get(&self) -> Config {
        self.cur.read().unwrap().clone()
    }

    pub fn set(&self, c: Config) {
        *self.cur.write().unwrap() = c;
        self.save();
    }

    fn save(&self) {
        if let Some(p) = self.path.parent() {
            let _ = std::fs::create_dir_all(p);
        }
        if let Ok(j) = serde_json::to_string_pretty(&*self.cur.read().unwrap()) {
            let _ = std::fs::write(&self.path, format!("{j}\n"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /* 用户 2026-08-02 点名的两个数:当季新番 6 小时、其余 7 天。
       实现上它们是自适应区间的两端(见 crate::store),但**默认值必须就是这两个数** ——
       改默认值等于悄悄改掉用户定的策略。 */
    #[test]
    fn refresh_bounds_default_to_what_the_user_asked_for() {
        let c = Config::default();
        assert_eq!(c.refresh_min_secs, 6 * 3600, "在播的番:6 小时");
        assert_eq!(c.refresh_max_secs, 7 * 86400, "其余:7 天");
        assert!(c.refresh_min_secs < c.refresh_max_secs);
    }

    /// 旧配置文件不能因为多了/少了字段就整份读不出来(那会静默退回全部默认值,
    /// 包括把出站上限退回 3000 —— 用户改过的闸门悄悄失效)。
    #[test]
    fn partial_config_files_keep_the_fields_they_do_have() {
        let c: Config = serde_json::from_str(r#"{"upstream_per_day": 12345}"#).unwrap();
        assert_eq!(c.upstream_per_day, 12345, "认得的字段要保留");
        assert_eq!(c.refresh_min_secs, 6 * 3600, "缺的字段用默认值");
        let c2: Config = serde_json::from_str(r#"{"unknown_old_field": 1}"#).unwrap();
        assert_eq!(c2.upstream_per_day, Config::default().upstream_per_day, "多余字段不能让整份解析失败");
    }
}
