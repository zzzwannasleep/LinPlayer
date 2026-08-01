// 预加载(preload)—— 迁自 Dart `preload_service`。
//
// 进详情页就对**即将要播的那个流**发 Range 请求,预热「头 32MB + 尾 2MB」,fire-and-forget。
// 两件事同时在办:
//   1. **把字节留下来**(头部)。宿主把头部的 URL 指向本地预取代理,字节流经代理时
//      顺手进它的环形缓存;起播时 mpv 连同一个代理,**预热了多少就当场吐多少**,
//      没热完的部分接着拉(边收边吐)。这是用户 2026-08-02 定的口径 ——
//      光把路跑热、把字节丢掉,在慢链路上等于白烧几分钟带宽,起播还得从头再下一遍。
//   2. **把路跑热**(头尾都算):TCP + TLS 握手、HTTP/2 连接已建好(远程 Emby 一次往返
//      100~300ms);服务端把文件页缓存拉进内存(机械盘/NAS 上这项最值钱);
//      中间有 CDN / CF 优选反代时边缘节点把这两段收进缓存。
//      尾部 2MB 是**为 MKV 准备的**:cues 索引在文件末尾,ffmpeg 打开容器的第一件事
//      就是 seek 到尾巴读索引;不预热尾巴,起播必然多一次冷 seek。
//
// ★ 这和「多线程加载(net::prefetch)」仍然是两个功能,别合并:
//     prefetch = 播放**中**超前拉 Range 喂给 mpv,管「喂得满」;
//     preload  = 播放**前**在详情页把头段搬到本地 + 把路跑热,管「起得快」。
//   它们**共用**同一个本地代理和同一份环形缓存 —— 那正是预热能被起播直接吃到的原因。
//
// 同一时刻只预热一个条目:进了新详情页就把上一个掐掉(用户已经走了,再拉就是白费流量)。
// 起播时也要掐 —— 那时候带宽该全给播放器。

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// 默认头部预热量。32MB ≈ 1080p 直传流的头一两分钟,够盖住起播 + 前几秒的解码。
pub const DEFAULT_HEAD_BYTES: u64 = 32 * 1024 * 1024;
/// 默认尾部预热量。MKV 的 cues 索引在末尾,2MB 足够覆盖绝大多数片子的索引块。
pub const DEFAULT_TAIL_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Default)]
struct Job {
    cancel: Arc<AtomicBool>,
    /// 这一轮已经读了多少字节(读完即丢,只用来给界面/日志一个交代)。
    got: Arc<AtomicU64>,
    /// 正在预热谁(URL 太长且含 token,只留一个条目 id 供展示)。
    item: String,
}

/// 预加载器。宿主持一个,详情页进出各调一次。
#[derive(Clone, Default)]
pub struct Preloader {
    cur: Arc<Mutex<Job>>,
}

/// 一轮预热的结果(纯统计,失败也不是错误 —— 预热本来就是尽力而为)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PreloadStats {
    pub head_bytes: u64,
    pub tail_bytes: u64,
    pub canceled: bool,
}

impl Preloader {
    /// 掐掉当前这一轮(换条目 / 离开详情页 / 起播时调)。
    pub fn cancel(&self) {
        let j = self.cur.lock().unwrap();
        j.cancel.store(true, Ordering::SeqCst);
    }

    /// 当前正在预热的条目 id(空串 = 没在预热)。
    pub fn current(&self) -> String {
        self.cur.lock().unwrap().item.clone()
    }

    /// 已经预热到的字节数(供设置页/日志展示)。
    pub fn bytes(&self) -> u64 {
        self.cur.lock().unwrap().got.load(Ordering::SeqCst)
    }

    /// 开一轮预热。**会先掐掉上一轮**。返回本轮的取消旗标与计数器。
    fn begin(&self, item: &str) -> (Arc<AtomicBool>, Arc<AtomicU64>) {
        let mut j = self.cur.lock().unwrap();
        j.cancel.store(true, Ordering::SeqCst); // 上一轮:走人
        let cancel = Arc::new(AtomicBool::new(false));
        let got = Arc::new(AtomicU64::new(0));
        *j = Job { cancel: cancel.clone(), got: got.clone(), item: item.to_string() };
        (cancel, got)
    }

    /// 预热头 `head` 字节 + 尾 `tail` 字节。本函数自己**读完即丢**;
    /// 字节留不留得下来,取决于调用方把 `head_url` 指到哪儿(见下)。
    ///
    /// ## 头尾为什么可以是两个地址(2026-08-02)
    /// 用户定的口径:**预加载了多少就吐多少出来,不需要等加载完才放**。
    /// 光把路跑热、把字节丢掉是不够的 —— 慢链路上那是白烧几分钟带宽,
    /// 起播时还得从头再下一遍。所以宿主把 `head_url` 指向**本地预取代理**:
    /// 字节流经代理时顺手进它的环形缓存,起播时 mpv 连同一个代理,
    /// 已经预热的部分**当场就吐**,没预热完的部分接着拉(边收边吐)。
    ///
    /// 尾部仍然打**直连地址**:代理的环形缓存按 `chunk % ring` 定位,
    /// 尾部段号和头部段号模 ring 有约一半的概率同槽 —— 那样预热完尾巴正好把头顶掉。
    /// 尾巴只有 2MB,重拉便宜;把路(CDN 边缘 / 服务端页缓存)跑热就够本了。
    ///
    /// 任何失败都只是「没热成」,不是错误 —— 服务器不支持 Range、网络抖、条目没权限,
    /// 统统按 0 字节收场,绝不能把详情页拦下来。
    pub async fn warm(
        &self,
        item_id: &str,
        head_url: &str,
        head: u64,
        tail_url: &str,
        tail: u64,
    ) -> PreloadStats {
        let (cancel, got) = self.begin(item_id);
        let client = crate::http::preload_client();

        let head_bytes = if head > 0 {
            pull(&client, head_url, &format!("bytes=0-{}", head - 1), head, &cancel, &got).await
        } else {
            0
        };
        /* 尾部用**后缀 Range**(`bytes=-N`),不用先 HEAD 探总长度:少一次往返,
           而且对「不给 Content-Length 的分块响应」也成立。服务端不认后缀 Range 就拿不到
           数据 —— 那正好,它多半也不支持 Range,预热本来就无从谈起。
           (我们自家的预取代理也不认后缀 Range,这正是尾部必须走直连的第二个理由。) */
        let tail_bytes = if tail > 0 && !cancel.load(Ordering::SeqCst) {
            pull(&client, tail_url, &format!("bytes=-{tail}"), tail, &cancel, &got).await
        } else {
            0
        };

        PreloadStats { head_bytes, tail_bytes, canceled: cancel.load(Ordering::SeqCst) }
    }
}

/// 拉一段并**丢弃**。`limit` 是硬上限:服务端无视 Range 回整片时(见
/// [[server-ignores-http-range]],这事真发生过)不能把整部片子拉下来。
async fn pull(
    client: &reqwest::Client,
    url: &str,
    range: &str,
    limit: u64,
    cancel: &Arc<AtomicBool>,
    got: &Arc<AtomicU64>,
) -> u64 {
    let Ok(mut resp) = client.get(url).header("Range", range).send().await else {
        return 0;
    };
    if !resp.status().is_success() {
        return 0;
    }
    let mut n = 0u64;
    while n < limit {
        if cancel.load(Ordering::SeqCst) {
            break;
        }
        match resp.chunk().await {
            Ok(Some(b)) => {
                n += b.len() as u64;
                got.fetch_add(b.len() as u64, Ordering::SeqCst);
                // b 在这里 drop —— 预热不留数据,这是它和 prefetch 的根本区别。
            }
            _ => break,
        }
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    /// 记录收到的 Range 头,并回等量的零字节。返回 (端口, 收到的 Range 列表)。
    async fn range_echo_server(body_len: usize) -> (u16, Arc<Mutex<Vec<String>>>) {
        let seen: Arc<Mutex<Vec<String>>> = Default::default();
        let l = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = l.local_addr().unwrap().port();
        let s2 = seen.clone();
        tokio::spawn(async move {
            while let Ok((mut sock, _)) = l.accept().await {
                let s3 = s2.clone();
                tokio::spawn(async move {
                    let mut buf = [0u8; 4096];
                    let n = sock.read(&mut buf).await.unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]).to_string();
                    // hyper 在 HTTP/1 线上把头名写成**小写**,别按 "Range: " 大小写敏感地找。
                    for line in req.split("\r\n") {
                        let low = line.to_ascii_lowercase();
                        if let Some(v) = low.strip_prefix("range:") {
                            s3.lock().unwrap().push(v.trim().to_string());
                        }
                    }
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Length: {body_len}\r\nConnection: close\r\n\r\n"
                    );
                    let _ = sock.write_all(head.as_bytes()).await;
                    let _ = sock.write_all(&vec![0u8; body_len]).await;
                });
            }
        });
        (port, seen)
    }

    /* 预热必须打**两段**:头一段正向 Range,尾一段后缀 Range。
       只热头部的话 MKV 起播仍要冷 seek 去文件末尾读 cues 索引 —— 那正是起播最慢的一跳,
       预热了个寂寞。反向验证:把 warm() 里的 tail 那段删掉,本测试立刻红。 */
    #[tokio::test]
    async fn warms_both_head_and_tail() {
        let (port, seen) = range_echo_server(64).await;
        let p = Preloader::default();
        let u = format!("http://127.0.0.1:{port}/x.mkv");
        let st = p.warm("it1", &u, 64, &u, 32).await;

        let ranges = seen.lock().unwrap().clone();
        assert_eq!(ranges.len(), 2, "该打两段(头 + 尾),实得:{ranges:?}");
        assert_eq!(ranges[0], "bytes=0-63", "头段该是正向 Range");
        assert!(ranges[1].starts_with("bytes=-"), "尾段必须是后缀 Range(MKV 索引在末尾),实得 {}", ranges[1]);
        assert!(st.head_bytes > 0 && st.tail_bytes > 0);
    }

    /* 服务端无视 Range 回整片是**真发生过**的事(见 [[server-ignores-http-range]])。
       预热必须自己封顶,否则「热一下」会变成把整部片子偷偷下下来。
       反向验证:把 pull() 的 `while n < limit` 改成 `loop`,本测试立刻红。 */
    #[tokio::test]
    async fn stops_at_the_limit_even_if_server_ignores_range() {
        // 服务端不管你要多少,一律回 4096 字节。
        let (port, _) = range_echo_server(4096).await;
        let p = Preloader::default();
        let u = format!("http://127.0.0.1:{port}/x.mkv");
        let st = p.warm("it2", &u, 128, &u, 0).await;
        assert!(
            st.head_bytes <= 128 + 4096,
            "没封顶:服务端无视 Range 时预热会把整片拉下来,实读 {}",
            st.head_bytes
        );
        assert!(st.head_bytes >= 128, "该至少读到要的量,实读 {}", st.head_bytes);
    }

    /* 换条目/离开详情页要能立刻掐掉上一轮 —— 否则用户在列表里快速点几下,
       后台会挂着好几轮预热同时抢带宽,而他要看的那部反而更慢了。 */
    #[test]
    fn starting_a_new_job_cancels_the_previous_one() {
        let p = Preloader::default();
        let (c1, _) = p.begin("a");
        assert!(!c1.load(Ordering::SeqCst));
        let (c2, _) = p.begin("b");
        assert!(c1.load(Ordering::SeqCst), "开新一轮没掐掉上一轮");
        assert!(!c2.load(Ordering::SeqCst));
        assert_eq!(p.current(), "b");
        p.cancel();
        assert!(c2.load(Ordering::SeqCst));
    }
}
