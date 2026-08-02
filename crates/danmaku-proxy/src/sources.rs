//! 按**来源 IP** 的用量统计。
//!
//! ## 为什么这里没有客户端令牌了
//! 原来的设计是一装一令牌。用户 2026-08-02 定的方向是不要凭据 —— 理由成立:
//! 真正保住弹弹配额的是[出站闸门](crate::upstream::Governor),它对谁来的都一样管用;
//! 拦人这件事 Cloudflare 的规则做得比我们好,在这儿再写一套只会写出更差的版本。
//! 去掉令牌顺带删掉了注册流程、令牌存储、和「令牌失效要重新注册」这个失败模式。
//!
//! 令牌唯一真正独有的能力是**归因** —— 谁在刷看得见。这一层把它换个方式补回来:
//! 按 CF-Connecting-IP 记用量,管理界面列出「用得最多的来源」。看见谁不对劲,
//! 去 CF 上封 —— 封禁本来就该在那一层做。
//!
//! ★ 这些计数**只作展示和自我保护**,不作鉴权:头是可伪造的,伪造者也就骗过一个
//!   本来就不拦人的统计表。真正的硬约束在出站闸门那边,那个伪造不了。

use serde::Serialize;
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Serialize, Clone, Default)]
pub struct Source {
    pub ip: String,
    /// 累计请求数(含库命中)。
    pub requests: u64,
    /// 累计**穿透到上游**的次数 —— 这才是它真正花掉的配额。
    pub upstream: u64,
    pub first_seen: i64,
    pub last_seen: i64,

    #[serde(skip)]
    minute: i64,
    #[serde(skip)]
    minute_used: u32,
}

pub struct Sources {
    st: Mutex<HashMap<String, Source>>,
}

/// 表里最多留多少个来源。不封顶的话被扫一遍就是几十万条,内存和管理界面一起垮。
/// 满了先丢最久没出现过的 —— 我们要看的是「现在谁在刷」。
const MAX_TRACKED: usize = 5000;

impl Sources {
    pub fn new() -> Self {
        Self { st: Mutex::new(HashMap::new()) }
    }

    /// 记一次请求。Err = 这个来源在本分钟内太频繁,该拒。
    ///
    /// `needs_upstream` 由调用方在**库里没有可用数据**时置 true —— 命中不花配额,
    /// 拿它计数会把正常追番的人误伤成滥用者。
    pub fn hit(
        &self,
        ip: &str,
        now: i64,
        per_minute: u32,
        needs_upstream: bool,
    ) -> Result<(), String> {
        let mut m = self.st.lock().unwrap();
        if m.len() >= MAX_TRACKED && !m.contains_key(ip) {
            if let Some(k) =
                m.iter().min_by_key(|(_, v)| v.last_seen).map(|(k, _)| k.clone())
            {
                m.remove(&k);
            }
        }
        let e = m.entry(ip.to_string()).or_insert_with(|| Source {
            ip: ip.to_string(),
            first_seen: now,
            ..Default::default()
        });
        let minute = now / 60;
        if e.minute != minute {
            e.minute = minute;
            e.minute_used = 0;
        }
        if e.minute_used >= per_minute {
            return Err(format!("请求太频繁(每分钟上限 {per_minute})"));
        }
        e.minute_used += 1;
        e.requests += 1;
        e.last_seen = now;
        if needs_upstream {
            e.upstream += 1;
        }
        Ok(())
    }

    /// 按「花掉的上游次数」降序 —— 管理界面要一眼看出谁在刷,
    /// 而按请求数排会把「一直命中缓存」的重度用户排在前面,那不是要抓的人。
    pub fn top(&self, n: usize) -> Vec<Source> {
        let mut v: Vec<Source> = self.st.lock().unwrap().values().cloned().collect();
        v.sort_by(|a, b| b.upstream.cmp(&a.upstream).then(b.requests.cmp(&a.requests)));
        v.truncate(n);
        v
    }

    pub fn len(&self) -> usize {
        self.st.lock().unwrap().len()
    }

    pub fn reset(&self) {
        self.st.lock().unwrap().clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /* ★ 排序必须按**上游消耗**,不是按请求数。
       按请求数排,榜首永远是「一直命中缓存」的重度用户 —— 他一次配额都没花,
       而真正在刷上游的人被埋在下面。这张表存在的意义就是抓后者。
       反向验证:把排序键换成 requests,本测试立刻红。 */
    #[test]
    fn top_talkers_are_ranked_by_quota_actually_burned() {
        let s = Sources::new();
        for _ in 0..100 {
            s.hit("重度但全命中", 1000, 1000, false).unwrap();
        }
        for _ in 0..5 {
            s.hit("在刷上游的", 1000, 1000, true).unwrap();
        }
        assert_eq!(s.top(2)[0].ip, "在刷上游的", "榜首该是花掉配额最多的那个");
    }

    #[test]
    fn per_minute_limit_is_enforced_and_resets() {
        let s = Sources::new();
        for _ in 0..3 {
            s.hit("1.1.1.1", 1000, 3, false).unwrap();
        }
        assert!(s.hit("1.1.1.1", 1000, 3, false).is_err(), "超了要拦");
        assert!(s.hit("2.2.2.2", 1000, 3, false).is_ok(), "别的来源不受影响");
        assert!(s.hit("1.1.1.1", 1060, 3, false).is_ok(), "下一分钟要重新计");
    }

    /* 被扫一遍就是几十万个来源,不封顶的话内存和管理界面一起垮。
       ★ 反向验证:把 MAX_TRACKED 那段删掉,本测试立刻红。 */
    #[test]
    fn tracked_sources_are_capped() {
        let s = Sources::new();
        for i in 0..(MAX_TRACKED + 500) {
            let _ = s.hit(&format!("ip-{i}"), 1000 + i as i64, 1000, false);
        }
        assert!(s.len() <= MAX_TRACKED, "来源表没封顶,实得 {}", s.len());
        assert!(
            s.top(MAX_TRACKED).iter().any(|x| x.ip == format!("ip-{}", MAX_TRACKED + 499)),
            "最近出现的必须留着(淘汰的应该是最久没出现的)"
        );
    }
}
