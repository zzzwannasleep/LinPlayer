//! 客户端注册表:一装一令牌 + 每客户端限额 + 封禁。
//!
//! ## 为什么不是「所有客户端共用一个令牌」
//! 共用令牌 = 又一个「编译进产物、谁都能抠出来」的东西,今天这个洞原样搬家。
//! 一装一令牌解决不了「攻击者也能注册」,但解决了**归因**和**围堵**:
//! 谁在刷看得见,封掉他不影响别人,而全局出站闸门是最后那道保险。
//!
//! ## 只存哈希
//! `clients.json` 里存的是令牌的 sha256,不是令牌本身。这份文件会被备份、被 tar 走、
//! 被贴进工单 —— 存明文的话每一次都是一批令牌泄漏。

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Serialize, Deserialize, Clone, Default)]
pub struct Client {
    /// 令牌的 sha256(hex)。**不存明文**。
    pub id: String,
    /// 令牌前 8 位,只为了管理界面上能和用户对得上号(「你那台的编号是 3f2a…」)。
    pub hint: String,
    /// 客户端自报的名字(设备型号/主机名),纯展示,不可信。
    pub label: String,
    pub created: i64,
    pub last_seen: i64,
    /// 最近一次来源 IP(经反代时取 X-Forwarded-For 最右侧可信段,见 main.rs)。
    pub ip: String,
    /// 累计请求数(含缓存命中)。
    pub requests: u64,
    /// 累计**穿透到上游**的次数 —— 这才是它真正花掉的配额。
    pub upstream: u64,
    pub banned: bool,

    #[serde(skip)]
    minute: i64,
    #[serde(skip)]
    minute_used: u32,
    #[serde(skip)]
    day: i64,
    #[serde(skip)]
    day_upstream: u32,
}

#[derive(Serialize, Deserialize, Default)]
struct Document {
    #[serde(default)]
    clients: Vec<Client>,
    /// ip -> (天序号, 当天注册数)
    #[serde(default)]
    reg: HashMap<String, (i64, u32)>,
}

pub struct Registry {
    path: PathBuf,
    st: Mutex<Document>,
}

pub fn hash(token: &str) -> String {
    let mut h = Sha256::new();
    h.update(token.as_bytes());
    format!("{:x}", h.finalize())
}

/// 32 字节随机 → hex(64 字符)。
/// `rand::rng()` 是从系统熵播种的 CSPRNG(ChaCha),**不是**时间种子 ——
/// 令牌可猜等于这层鉴权不存在。与 core 里 aliyundrive/baidu 的用法一致。
pub fn new_token() -> String {
    use rand::RngCore;
    let mut b = [0u8; 32];
    rand::rng().fill_bytes(&mut b);
    b.iter().map(|x| format!("{x:02x}")).collect()
}

impl Registry {
    pub fn load(dir: &PathBuf) -> Self {
        let path = dir.join("clients.json");
        let st = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        Self { path, st: Mutex::new(st) }
    }

    fn save_locked(&self, d: &Document) {
        if let Some(p) = self.path.parent() {
            let _ = std::fs::create_dir_all(p);
        }
        if let Ok(j) = serde_json::to_string(d) {
            let _ = std::fs::write(&self.path, j);
        }
    }

    /// 注册一台新设备。返回明文令牌 —— **这是它唯一一次以明文出现**。
    pub fn register(
        &self,
        label: &str,
        ip: &str,
        now: i64,
        per_ip_per_day: u32,
    ) -> Result<String, String> {
        let day = now / 86400;
        let mut d = self.st.lock().unwrap();
        let e = d.reg.entry(ip.to_string()).or_insert((day, 0));
        if e.0 != day {
            *e = (day, 0);
        }
        if e.1 >= per_ip_per_day {
            return Err(format!("这个地址今天注册得太多了(上限 {per_ip_per_day})"));
        }
        e.1 += 1;

        let token = new_token();
        d.clients.push(Client {
            id: hash(&token),
            hint: token[..8].to_string(),
            label: label.chars().take(64).collect(),
            created: now,
            last_seen: now,
            ip: ip.to_string(),
            ..Default::default()
        });
        self.save_locked(&d);
        Ok(token)
    }

    /// 校验令牌并计一次请求。Err = 该拒。
    ///
    /// `needs_upstream` 由调用方在**缓存未命中**时置 true —— 缓存命中不花配额,
    /// 拿它计数会把正常追番的用户误伤成滥用者。
    pub fn check(
        &self,
        token: &str,
        ip: &str,
        now: i64,
        per_minute: u32,
        upstream_per_day: u32,
        needs_upstream: bool,
    ) -> Result<(), String> {
        let id = hash(token);
        let mut d = self.st.lock().unwrap();
        let Some(c) = d.clients.iter_mut().find(|c| c.id == id) else {
            return Err("令牌无效,请重新注册".into());
        };
        if c.banned {
            return Err("这个客户端已被封禁".into());
        }
        let (m, day) = (now / 60, now / 86400);
        if c.minute != m {
            c.minute = m;
            c.minute_used = 0;
        }
        if c.day != day {
            c.day = day;
            c.day_upstream = 0;
        }
        if c.minute_used >= per_minute {
            return Err(format!("请求太频繁(每分钟上限 {per_minute})"));
        }
        if needs_upstream && c.day_upstream >= upstream_per_day {
            return Err(format!("今天的弹幕查询次数用完了(上限 {upstream_per_day})"));
        }
        c.minute_used += 1;
        c.requests += 1;
        c.last_seen = now;
        c.ip = ip.to_string();
        if needs_upstream {
            c.day_upstream += 1;
            c.upstream += 1;
        }
        Ok(())
    }

    pub fn list(&self) -> Vec<Client> {
        let mut v = self.st.lock().unwrap().clients.clone();
        v.sort_by(|a, b| b.last_seen.cmp(&a.last_seen));
        v
    }

    pub fn set_banned(&self, id: &str, banned: bool) {
        let mut d = self.st.lock().unwrap();
        if let Some(c) = d.clients.iter_mut().find(|c| c.id == id) {
            c.banned = banned;
        }
        self.save_locked(&d);
    }

    pub fn remove(&self, id: &str) {
        let mut d = self.st.lock().unwrap();
        d.clients.retain(|c| c.id != id);
        self.save_locked(&d);
    }

    /// 定期落盘(计数器是热路,不能每次请求都写文件)。
    pub fn flush(&self) {
        let d = self.st.lock().unwrap();
        self.save_locked(&d);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reg(name: &str) -> Registry {
        let dir = std::env::temp_dir().join(format!("lp-dmproxy-cl-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Registry::load(&dir)
    }

    /* 令牌绝不能以明文落盘。clients.json 会被备份/打包/贴工单,
       存明文等于每一次都是一批令牌泄漏 —— 而这个服务存在的**全部理由**
       就是「别再把可复用的凭据交出去」。
       ★ 反向验证:把 register 里的 hash(&token) 换成 token.clone(),本测试立刻红。 */
    #[test]
    fn tokens_are_never_stored_in_clear() {
        let r = reg("hash");
        let t = r.register("测试机", "1.1.1.1", 1000, 5).unwrap();
        let raw = std::fs::read_to_string(&r.path).unwrap();
        assert!(!raw.contains(&t), "clients.json 里出现了明文令牌");
        assert!(raw.contains(&hash(&t)), "应当存哈希");
        assert!(r.check(&t, "1.1.1.1", 1000, 100, 100, false).is_ok(), "哈希对得上就该放行");
        assert!(r.check("乱填的", "1.1.1.1", 1000, 100, 100, false).is_err());
    }

    /// 批量注册要挡住,否则「一装一令牌」等于没有。
    #[test]
    fn registration_is_capped_per_ip_per_day() {
        let r = reg("ipcap");
        for i in 0..3 {
            r.register("x", "9.9.9.9", 1000, 3).unwrap_or_else(|e| panic!("第 {i} 次:{e}"));
        }
        assert!(r.register("x", "9.9.9.9", 1000, 3).is_err(), "超过每日上限必须拦");
        assert!(r.register("x", "8.8.8.8", 1000, 3).is_ok(), "换个地址不该受影响");
        // 第二天要放开
        assert!(r.register("x", "9.9.9.9", 1000 + 86400, 3).is_ok(), "跨天必须重置");
    }

    /* ★ 缓存命中**不**计上游配额。计了的话正常追番的人(一集反复开关)
       会被自己的缓存命中顶到上限,而他一次上游都没花。 */
    #[test]
    fn cache_hits_do_not_burn_the_clients_daily_upstream_quota() {
        let r = reg("nohit");
        let t = r.register("x", "1.1.1.1", 1000, 5).unwrap();
        for _ in 0..50 {
            r.check(&t, "1.1.1.1", 1000, 1000, 2, false).expect("命中缓存不该消耗上游额度");
        }
        r.check(&t, "1.1.1.1", 1000, 1000, 2, true).unwrap();
        r.check(&t, "1.1.1.1", 1000, 1000, 2, true).unwrap();
        assert!(
            r.check(&t, "1.1.1.1", 1000, 1000, 2, true).is_err(),
            "第三次穿透必须被上游日限拦住"
        );
    }

    #[test]
    fn banning_takes_effect_immediately() {
        let r = reg("ban");
        let t = r.register("x", "1.1.1.1", 1000, 5).unwrap();
        r.set_banned(&hash(&t), true);
        assert!(r.check(&t, "1.1.1.1", 1000, 100, 100, false).is_err(), "封禁后必须立刻拒");
        r.set_banned(&hash(&t), false);
        assert!(r.check(&t, "1.1.1.1", 1000, 100, 100, false).is_ok(), "解封要能恢复");
    }
}
