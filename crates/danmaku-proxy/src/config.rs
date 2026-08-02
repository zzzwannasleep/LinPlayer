//! 运行时配置。**凭据不在这里** —— AppId/AppSecret/管理密码一律走环境变量,
//! 免得管理界面存盘时把密钥写进一个随手会被 tar 走的 JSON([[全局红线]])。
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
    /// ★ 这是整个服务**最重要**的一个数。代理的价值不在于抗打,而在于把
    ///   「我们收到多少请求」和「我们转发多少请求」解耦 —— 被刷爆的后果就退化成
    ///   「这段时间弹幕慢」,而配额一个不掉。没有这道闸,代理只是把攻击原样中继过去。
    pub upstream_per_minute: u32,
    /// 出站闸门:每天最多向弹弹Play 发多少次。按官方配额留 20% 余量填。
    pub upstream_per_day: u32,

    /// 单个客户端每分钟最多请求数(含缓存命中,防单机刷爆本服务的 CPU/带宽)。
    pub client_per_minute: u32,
    /// 单个客户端每天最多**穿透到上游**的请求数。缓存命中不计 —— 命中不花配额,
    /// 拿它计数会把正常追番的用户误伤成滥用者。
    pub client_upstream_per_day: u32,

    /// 缓存 TTL(秒)。分三档是因为三类数据的新鲜度要求差一个数量级。
    /// 弹幕会随时间增加,但「少了最近半小时的几条」没人看得出来;
    /// 搜索结果几乎不变;排行榜每天变一次。
    pub ttl_comment_secs: u64,
    pub ttl_search_secs: u64,
    pub ttl_trending_secs: u64,

    /// 磁盘缓存上限(MB)。超了按最久未用淘汰。
    pub cache_max_mb: u64,

    /// 注册模式:open=任何人可注册 / invite=需邀请码 / closed=不再发新令牌。
    /// 被刷时把它切到 invite 或 closed 是最快的止血手段(存量用户不受影响)。
    pub register_mode: RegisterMode,
    /// 邀请码(register_mode=invite 时生效)。管理界面里改。
    pub invite_code: String,
    /// 同一 IP 每天最多注册几个客户端。挡「批量注册一万个令牌」。
    pub register_per_ip_per_day: u32,

    /// 总开关。关掉后所有转发立即 503(存量客户端会显示「弹幕服务暂不可用」)。
    pub enabled: bool,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum RegisterMode {
    Open,
    Invite,
    Closed,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            /* 默认值按「弹弹Play 个人开发者常见配额约 1000~5000/日」保守取。
               ★ 部署后**必须**照你自己的实际配额在管理界面改一次 ——
                 默认值只保证「不会一天之内烧光」,不保证用满。 */
            upstream_per_minute: 30,
            upstream_per_day: 3000,
            client_per_minute: 20,
            client_upstream_per_day: 60,
            ttl_comment_secs: 6 * 3600,
            ttl_search_secs: 24 * 3600,
            ttl_trending_secs: 3600,
            cache_max_mb: 2048,
            register_mode: RegisterMode::Open,
            invite_code: String::new(),
            register_per_ip_per_day: 5,
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
