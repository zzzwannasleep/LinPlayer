//! 共享响应缓存 —— **本服务省配额的主力,收益比限流大一个数量级**。
//!
//! 一百个人看同一集,弹幕是同一份;搜同一部番,结果是同一份。没有这层,上游调用量
//! 等于「播放次数」;有了这层,塌成「不同集数 × TTL 窗口」。热门番第二个人开始零成本。
//!
//! 落磁盘不落内存:单集弹幕几 MB 很常见,几百集就把内存吃穿了。索引在内存、正文在盘上。

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use sha2::{Digest, Sha256};

pub struct Cache {
    dir: PathBuf,
    max_bytes: u64,
    st: Mutex<State>,
}

struct State {
    /// key -> (过期时刻, 字节数, 上次命中时刻)
    idx: HashMap<String, (i64, u64, i64)>,
    bytes: u64,
    hits: u64,
    misses: u64,
}

#[derive(serde::Serialize, Clone, Copy)]
pub struct CacheStats {
    pub entries: u64,
    pub bytes: u64,
    pub hits: u64,
    pub misses: u64,
}

/// 缓存键。★ 必须**排除**鉴权相关的一切(客户端令牌、我们发给上游的签名头):
/// 带上它们就等于每个客户端各存一份,缓存命中率归零,而症状只是「配额还是在掉」。
pub fn key(method: &str, path: &str, query: &str, body: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(method.as_bytes());
    h.update(b"\0");
    h.update(path.as_bytes());
    h.update(b"\0");
    h.update(canonical_query(query).as_bytes());
    h.update(b"\0");
    h.update(body);
    format!("{:x}", h.finalize())
}

/// query 参数排序后重组 —— `?a=1&b=2` 和 `?b=2&a=1` 是同一个请求,
/// 不归一化的话客户端换个参数顺序就多打一次上游。
fn canonical_query(query: &str) -> String {
    let mut parts: Vec<&str> = query.split('&').filter(|s| !s.is_empty()).collect();
    parts.sort_unstable();
    parts.join("&")
}

impl Cache {
    pub fn open(dir: PathBuf, max_mb: u64) -> Self {
        let _ = std::fs::create_dir_all(&dir);
        let mut idx = HashMap::new();
        let mut bytes = 0u64;
        // 重建索引。不扫的话重启后容量统计归零,盘会一直涨到写满。
        if let Ok(rd) = std::fs::read_dir(&dir) {
            for e in rd.flatten() {
                let Ok(md) = e.metadata() else { continue };
                if !md.is_file() {
                    continue;
                }
                let name = e.file_name().to_string_lossy().to_string();
                let exp = read_expiry(&e.path()).unwrap_or(0);
                idx.insert(name, (exp, md.len(), 0));
                bytes += md.len();
            }
        }
        Self {
            dir,
            max_bytes: max_mb.saturating_mul(1024 * 1024),
            st: Mutex::new(State { idx, bytes, hits: 0, misses: 0 }),
        }
    }

    pub fn get(&self, key: &str, now: i64) -> Option<Vec<u8>> {
        {
            let mut s = self.st.lock().unwrap();
            match s.idx.get(key) {
                Some(&(exp, _, _)) if exp > now => {
                    if let Some(v) = s.idx.get_mut(key) {
                        v.2 = now;
                    }
                }
                Some(_) => {
                    // 过期:当场删掉,别留着占容量
                    if let Some((_, n, _)) = s.idx.remove(key) {
                        s.bytes = s.bytes.saturating_sub(n);
                    }
                    let _ = std::fs::remove_file(self.dir.join(key));
                    s.misses += 1;
                    return None;
                }
                None => {
                    s.misses += 1;
                    return None;
                }
            }
        }
        match std::fs::read(self.dir.join(key)) {
            Ok(raw) => {
                let body = strip_header(&raw)?.to_vec();
                self.st.lock().unwrap().hits += 1;
                Some(body)
            }
            Err(_) => {
                // 盘上没了(被人手删/掉盘)——索引跟着清掉,别一直报命中却读不出来
                let mut s = self.st.lock().unwrap();
                if let Some((_, n, _)) = s.idx.remove(key) {
                    s.bytes = s.bytes.saturating_sub(n);
                }
                s.misses += 1;
                None
            }
        }
    }

    pub fn put(&self, key: &str, body: &[u8], ttl_secs: u64, now: i64) {
        let exp = now + ttl_secs as i64;
        let mut buf = format!("{exp}\n").into_bytes();
        buf.extend_from_slice(body);
        if std::fs::write(self.dir.join(key), &buf).is_err() {
            return;
        }
        let n = buf.len() as u64;
        let mut s = self.st.lock().unwrap();
        if let Some((_, old, _)) = s.idx.insert(key.to_string(), (exp, n, now)) {
            s.bytes = s.bytes.saturating_sub(old);
        }
        s.bytes += n;
        self.evict_locked(&mut s, now);
    }

    /// 超容量就按「最久未用」淘汰。先淘汰已过期的 —— 它们本来就是死的。
    ///
    /// ★ `now` 必须由调用方传进来,**不能在这里自己读系统时钟**:
    ///   get/put 收的是参数里的 now,这里再读一次就是两个时钟源。
    ///   两者一旦不同步(测试注入时间、或跨了闰秒/改过系统时间),
    ///   全部条目会被判成"已过期"→ 排序键全相等 → 退化成按哈希表顺序乱删,
    ///   刚写进去的热数据当场被淘汰。这条是本地测试真抓出来的,不是假想。
    fn evict_locked(&self, s: &mut State, now: i64) {
        if s.bytes <= self.max_bytes {
            return;
        }
        let mut all: Vec<(String, i64, u64, i64)> =
            s.idx.iter().map(|(k, &(e, n, u))| (k.clone(), e, n, u)).collect();
        // 排序键:已过期的排最前(exp<=now → 0),其余按上次命中时刻升序
        all.sort_by_key(|(_, exp, _, used)| if *exp <= now { i64::MIN } else { *used });
        for (k, _, n, _) in all {
            if s.bytes <= self.max_bytes {
                break;
            }
            s.idx.remove(&k);
            s.bytes = s.bytes.saturating_sub(n);
            let _ = std::fs::remove_file(self.dir.join(&k));
        }
    }

    pub fn stats(&self) -> CacheStats {
        let s = self.st.lock().unwrap();
        CacheStats { entries: s.idx.len() as u64, bytes: s.bytes, hits: s.hits, misses: s.misses }
    }

    pub fn clear(&self) {
        let mut s = self.st.lock().unwrap();
        for k in s.idx.keys() {
            let _ = std::fs::remove_file(self.dir.join(k));
        }
        s.idx.clear();
        s.bytes = 0;
    }
}

fn strip_header(raw: &[u8]) -> Option<&[u8]> {
    let i = raw.iter().position(|&b| b == b'\n')?;
    Some(&raw[i + 1..])
}

fn read_expiry(p: &std::path::Path) -> Option<i64> {
    let raw = std::fs::read(p).ok()?;
    let i = raw.iter().position(|&b| b == b'\n')?;
    std::str::from_utf8(&raw[..i]).ok()?.trim().parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("lp-dmproxy-test-{name}"));
        let _ = std::fs::remove_dir_all(&p);
        p
    }

    /* 缓存键必须**排除鉴权**,否则每个客户端各存一份 = 命中率恒 0,
       而症状只是「上了代理配额还是在掉」,查起来极难。
       ★ 反向验证:把 key() 里加进一个 token 参数,本测试立刻红。 */
    #[test]
    fn key_ignores_param_order_and_separates_real_differences() {
        assert_eq!(
            key("GET", "/api/v2/search/anime", "keyword=x&v2=true", b""),
            key("GET", "/api/v2/search/anime", "v2=true&keyword=x", b""),
            "参数顺序不同是同一个请求,不归一化就多打一次上游"
        );
        assert_ne!(
            key("GET", "/api/v2/search/anime", "keyword=x", b""),
            key("GET", "/api/v2/search/anime", "keyword=y", b""),
            "关键词不同必须是不同的键"
        );
        assert_ne!(
            key("POST", "/api/v2/match", "", b"{\"fileName\":\"a\"}"),
            key("POST", "/api/v2/match", "", b"{\"fileName\":\"b\"}"),
            "POST 的正文必须参与键 —— 不然所有 /match 共用一份结果"
        );
    }

    #[test]
    fn expired_entries_are_a_miss_and_get_dropped() {
        let c = Cache::open(tmp("exp"), 64);
        let now = 1_000_000;
        c.put("k1", b"hello", 10, now);
        assert_eq!(c.get("k1", now + 5).as_deref(), Some(&b"hello"[..]), "没过期要命中");
        assert!(c.get("k1", now + 11).is_none(), "过期必须算未命中");
        assert_eq!(c.stats().entries, 0, "过期条目要当场清掉,不能一直占容量");
    }

    /* 超容量必须真的淘汰。不淘汰的表现是盘一直涨到写满,而服务看起来一切正常。
       ★ 反向验证:把 evict_locked 的循环体注释掉,本测试立刻红。 */
    #[test]
    fn eviction_keeps_disk_under_the_cap() {
        let dir = tmp("evict");
        let c = Cache::open(dir.clone(), 1); // 1MB
        let blob = vec![b'x'; 300 * 1024];
        let now = 2_000_000;
        for i in 0..8 {
            c.put(&format!("k{i}"), &blob, 3600, now + i);
        }
        let st = c.stats();
        assert!(st.bytes <= 1024 * 1024, "超了上限没淘汰:{} 字节", st.bytes);
        assert!(st.entries >= 2, "别一超容量就清空,实得 {} 条", st.entries);
        // 最早写入的应该先被淘汰
        assert!(c.get("k0", now + 10).is_none(), "最久未用的应当先出局");
        assert!(c.get("k7", now + 10).is_some(), "最新的不该被淘汰");
    }

    /// 重启后要能把磁盘上的东西认回来 —— 不认的话容量统计归零,盘会一直涨。
    #[test]
    fn index_is_rebuilt_from_disk_on_restart() {
        let dir = tmp("restart");
        let now = 3_000_000;
        {
            let c = Cache::open(dir.clone(), 64);
            c.put("kA", b"payload", 9999, now);
        }
        let c2 = Cache::open(dir, 64);
        assert_eq!(c2.stats().entries, 1, "重启后没扫回磁盘上的条目");
        assert_eq!(c2.get("kA", now + 1).as_deref(), Some(&b"payload"[..]));
    }
}
