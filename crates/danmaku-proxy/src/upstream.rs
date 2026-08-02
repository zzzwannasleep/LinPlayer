//! 出站:签名 + 调弹弹Play + **出站闸门**。
//!
//! 闸门是这个服务存在的理由。客户端限流只能管住守规矩的人;把签名挪到服务端之后,
//! 真正保住配额的是「无论收到多少请求,每天最多往上游转发 N 次」这条硬约束。

use base64::Engine;
use sha2::{Digest, Sha256};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// 弹弹Play 官方签名:`base64(sha256(AppId + Timestamp + Path + AppSecret))`。
///
/// ★ 与 `crates/core/src/danmaku/mod.rs::signature` 必须逐字节一致 ——
///   那边是客户端历史实现,这边是现在真正发出去的那份。故意抄一份而不是共享 core:
///   为这 5 行拖进整个播放器核心库不划算(见 Cargo.toml 的说明)。
///   下面的测试用的是**同一组向量**,两边同时改才不会漂。
pub fn signature(app_id: &str, path: &str, ts: i64, secret: &str) -> String {
    let mut h = Sha256::new();
    h.update(format!("{app_id}{ts}{path}{secret}").as_bytes());
    base64::engine::general_purpose::STANDARD.encode(h.finalize())
}

pub fn now_secs() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// 出站闸门。分钟桶 + 天桶,两个都过才放行。
///
/// ★ 天界按 UTC 切(`now/86400`)。不按本地时区是因为容器里的时区经常是 UTC 而
///   管理员以为是本地,「配额几点重置」对不上会让人以为闸门坏了。管理界面里写明。
pub struct Governor {
    st: Mutex<State>,
}

struct State {
    minute: i64,
    minute_used: u32,
    day: i64,
    day_used: u32,
    /// 累计放行/拒绝,只给管理界面看,不参与判定。
    pub total_allowed: u64,
    pub total_denied: u64,
}

/// 闸门当前状态快照(管理界面用)。
#[derive(serde::Serialize, Clone, Copy)]
pub struct GovernorStats {
    pub minute_used: u32,
    pub day_used: u32,
    pub total_allowed: u64,
    pub total_denied: u64,
    /// 距离天桶重置还有多少秒。
    pub day_resets_in: i64,
}

impl Governor {
    pub fn new() -> Self {
        Self {
            st: Mutex::new(State {
                minute: 0,
                minute_used: 0,
                day: 0,
                day_used: 0,
                total_allowed: 0,
                total_denied: 0,
            }),
        }
    }

    /// 试着取一个出站名额。Err(原因) = 这次不能发。
    ///
    /// ★ 名额是**取了就算用掉**,即使上游随后失败。看着亏,但反过来更糟:
    ///   上游正在 5xx 或超时的时候,「失败不计数」会让我们对着一个坏掉的上游
    ///   全速重试,把当天配额在几分钟内烧光 —— 那正是要防的场景。
    pub fn acquire(&self, per_minute: u32, per_day: u32) -> Result<(), String> {
        let now = now_secs();
        let (m, d) = (now / 60, now / 86400);
        let mut s = self.st.lock().unwrap();
        if s.minute != m {
            s.minute = m;
            s.minute_used = 0;
        }
        if s.day != d {
            s.day = d;
            s.day_used = 0;
        }
        if s.day_used >= per_day {
            s.total_denied += 1;
            return Err(format!("今日上游配额已用完({per_day} 次),明日 UTC 00:00 重置"));
        }
        if s.minute_used >= per_minute {
            s.total_denied += 1;
            return Err(format!("上游限速中(每分钟 {per_minute} 次),请稍后重试"));
        }
        s.minute_used += 1;
        s.day_used += 1;
        s.total_allowed += 1;
        Ok(())
    }

    pub fn stats(&self) -> GovernorStats {
        let now = now_secs();
        let (m, d) = (now / 60, now / 86400);
        let s = self.st.lock().unwrap();
        GovernorStats {
            minute_used: if s.minute == m { s.minute_used } else { 0 },
            day_used: if s.day == d { s.day_used } else { 0 },
            total_allowed: s.total_allowed,
            total_denied: s.total_denied,
            day_resets_in: (d + 1) * 86400 - now,
        }
    }
}

const DEFAULT_BASE: &str = "https://api.dandanplay.net";

/// 上游地址。可用 `UPSTREAM_BASE` 覆盖 —— 端到端测试要拿一个假上游顶上去,
/// 否则每跑一次自检就是在刷自己的配额(那正是这个服务要防的事)。
pub fn official_base() -> String {
    std::env::var("UPSTREAM_BASE")
        .ok()
        .map(|s| s.trim().trim_end_matches('/').to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| DEFAULT_BASE.to_string())
}

/// 编译期不注入任何凭据 —— 服务端的密钥只能来自环境变量,不进仓库也不进镜像层。
pub struct Creds {
    pub app_id: String,
    pub app_secret: String,
}

impl Creds {
    pub fn from_env() -> Result<Self, String> {
        let app_id = std::env::var("DANDANPLAY_APP_ID").unwrap_or_default().trim().to_string();
        let raw = std::env::var("DANDANPLAY_APP_SECRET").unwrap_or_default();
        /* ★ AppSecret 可能是**多串换行分隔**的(同一 AppId 配多个密钥做配额轮换)。
           整坨拿去 sha256 必然签错,而弹弹只回 403,看起来像「密钥无效」。
           客户端那边 2026-07-21 因为这个白查了一天,别在服务端重演。 */
        let app_secret =
            raw.split('\n').map(str::trim).find(|s| !s.is_empty()).unwrap_or("").to_string();
        if app_id.is_empty() || app_secret.is_empty() {
            return Err("缺少 DANDANPLAY_APP_ID / DANDANPLAY_APP_SECRET 环境变量".into());
        }
        Ok(Self { app_id, app_secret })
    }

    /// 给某条 `/api/v2/...` 路径算出鉴权头。
    pub fn headers(&self, api_path: &str) -> [(&'static str, String); 3] {
        let ts = now_secs();
        [
            ("X-AppId", self.app_id.clone()),
            ("X-Timestamp", ts.to_string()),
            ("X-Signature", signature(&self.app_id, api_path, ts, &self.app_secret)),
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 与 core 侧 `danmaku::tests::parse_and_sign` 同一组向量 —— 两边同时改才不会漂。
    /// 签名算错的表现是上游一律 403,而 403 长得跟「凭据过期」一模一样。
    #[test]
    fn signature_matches_the_client_implementation() {
        assert_eq!(signature("appid", "/api/v2/x", 0, "secret").len(), 44);
        // 固定向量:base64(sha256("appid0/api/v2/xsecret"))
        let mut h = Sha256::new();
        h.update(b"appid0/api/v2/xsecret");
        let want = base64::engine::general_purpose::STANDARD.encode(h.finalize());
        assert_eq!(signature("appid", "/api/v2/x", 0, "secret"), want);
    }

    /* 闸门必须在**两个**维度上都拦得住。
       ★ 反向验证:把 `s.minute_used >= per_minute` 那条去掉,本测试立刻红。 */
    #[test]
    fn governor_stops_at_both_limits() {
        let g = Governor::new();
        for i in 0..5 {
            assert!(g.acquire(5, 100).is_ok(), "第 {i} 次应放行");
        }
        let e = g.acquire(5, 100).expect_err("超过每分钟上限必须拦住");
        assert!(e.contains("每分钟"), "要说清是哪道闸拦的,实得:{e}");

        let g2 = Governor::new();
        for _ in 0..3 {
            assert!(g2.acquire(100, 3).is_ok());
        }
        let e2 = g2.acquire(100, 3).expect_err("超过每日上限必须拦住");
        assert!(e2.contains("今日"), "实得:{e2}");
        assert_eq!(g2.stats().day_used, 3, "拒绝的那次不该计进已用量");
        assert_eq!(g2.stats().total_denied, 1);
    }

    /// 多串轮换密钥只能取第一串(客户端踩过,服务端别再踩一次)。
    #[test]
    fn multi_secret_rotation_takes_only_the_first() {
        std::env::set_var("DANDANPLAY_APP_ID", "id1");
        std::env::set_var("DANDANPLAY_APP_SECRET", "  s1  \ns2\n");
        let c = Creds::from_env().expect("应当能读出凭据");
        assert_eq!(c.app_secret, "s1", "整坨拿去签名必然 403");
        std::env::set_var("DANDANPLAY_APP_SECRET", "");
        assert!(Creds::from_env().is_err(), "凭据缺失要报错,不能静默跑起来");
        std::env::remove_var("DANDANPLAY_APP_ID");
        std::env::remove_var("DANDANPLAY_APP_SECRET");
    }
}
