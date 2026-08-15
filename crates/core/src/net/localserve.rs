//! 本地 HTTP Range 桥:把「能按偏移读字节的东西」变成一个 mpv 打得开的 http:// 地址。
//!
//! ## 为什么需要它
//! 实测本仓打包的 libmpv(桌面 DLL 用 ctypes 读 `protocol-list`,安卓 .so 用
//! 依赖符号反查)**没有 smb 协议**:desktop 68 个协议里没有 `smb`/`cifs`,
//! 两侧也都不含 libsmbclient 的符号。所以 SMB 上的片子没法把 `smb://…` 直接
//! 甩给播放器,必须由我们读字节、用 HTTP 喂过去。
//! (WebDAV 和 FTP 不走这里:前者本来就是 HTTP,后者 mpv 自带 `ftp` 协议。)
//!
//! ## 为什么不复用 net/prefetch.rs 那个代理
//! 那个代理的取数是**焊死在 HTTP Range 上**的:它自己发 reqwest 请求、跟 302、
//! 读 Content-Range 探大小,外面还套着磁盘环形缓存和多线程预取窗口。把它改成
//! 可插拔上游要动 fetch/probe/重签三处核心,而那三处正是播放链路最不该乱碰的地方
//! (「有流量没画面」那几个坑全在里面)。这里要的只是「一个请求一段字节」,
//! 独立一个小服务器反而互不牵连。
//!
//! 只有 HTTP 应答那半边是照着 prefetch 抄的 —— 那些头(206 / Content-Range /
//! **Connection: close**)是踩出来的,不是设计出来的,详见 prefetch.rs 里的长注释。
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};

/// 一个「可随机读的文件」。SMB 那边由 `smb2::FileReader` 实现。
#[async_trait::async_trait]
pub trait RangeSource: Send + Sync + 'static {
    /// 文件总长。开播前必须已知 —— HTTP 要在响应头里给 Content-Length,
    /// 而 mpv 拿不到总长就没法算进度条,更没法 seek。
    fn size(&self) -> u64;

    /// 读 `[offset, offset+len)`。允许短读(到文件尾自然截断)。
    async fn read_at(&self, offset: u64, len: u64) -> std::io::Result<Vec<u8>>;
}

/// 活着的桥。**drop 即关闭** —— accept 循环挂在这个 handle 的 task 上,
/// handle 一没人持有,端口和后面那条 SMB 连接一起收掉。
pub struct BridgeHandle {
    pub url: String,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for BridgeHandle {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// 起一个只服务**一个文件**的本地 HTTP 服务器,返回它的 URL。
///
/// 一片一个端口,换片就把上一个 handle 丢掉。省下了「按路径路由 + 会话表 + 过期回收」
/// 那一整套,而我们同一时刻本来就只放一片。
pub async fn start(src: Arc<dyn RangeSource>) -> std::io::Result<BridgeHandle> {
    // 只听回环:这条流带着用户 NAS 的内容,不该出网卡。端口交给系统挑(0)。
    let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
    let port = listener.local_addr()?.port();

    let task = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                break;
            };
            let src = src.clone();
            // 每条连接一个 task:mpv 会为 seek 另开连接(我们回的是 Connection: close),
            // 串行处理的话新连接要等旧连接把整段喂完 —— 那就是 seek 卡死。
            tokio::spawn(async move {
                let _ = serve_one(stream, src).await;
            });
        }
    });

    Ok(BridgeHandle {
        // 路径随便给一个带扩展名的:ffmpeg 会拿 URL 尾巴猜容器格式,
        // 光一个 `/` 会让它少一条线索(有 Content-Type 兜底,但白送的信息没理由不给)。
        url: format!("http://127.0.0.1:{port}/stream"),
        task,
    })
}

async fn serve_one(mut stream: TcpStream, src: Arc<dyn RangeSource>) -> std::io::Result<()> {
    let total = src.size();
    let (method, range) = crate::net::prefetch::read_request(&mut stream).await?;

    // 越界必须在钳位**之前**判(prefetch 那边踩过:先 min 再判,分支永远进不去,
    // 越界请求被悄悄挪回最后一字节回 206 —— 播放器拿到「有效但错位」的数据)。
    if range.is_some_and(|(s, _)| s >= total) {
        stream
            .write_all(
                b"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )
            .await?;
        return Ok(());
    }

    let (start, end) = match range {
        Some((s, e)) => {
            let s = s.min(total.saturating_sub(1));
            (s, e.unwrap_or(total - 1).clamp(s, total - 1))
        }
        None => (0, total.saturating_sub(1)),
    };
    let len = end - start + 1;

    let mut head = String::new();
    if range.is_some() {
        head.push_str("HTTP/1.1 206 Partial Content\r\n");
        head.push_str(&format!("Content-Range: bytes {start}-{end}/{total}\r\n"));
    } else {
        head.push_str("HTTP/1.1 200 OK\r\n");
    }
    head.push_str("Accept-Ranges: bytes\r\n");
    /* ★ `Connection: close` 不是可选项。我们每条连接只读一个请求,而 HTTP/1.1
       默认长连接 —— 不写这个头就是在向播放器承诺「还能再发」。ffmpeg 一 seek
       (MKV 索引在末尾,起播必 seek)就把下一个 Range 管线化到同一条 socket 上,
       那个请求没人读,响应永远不来 = 有流量、黑屏无声。prefetch 那边就是这么炸的。 */
    head.push_str("Connection: close\r\n");
    head.push_str("Content-Type: video/mp4\r\n");
    head.push_str(&format!("Content-Length: {len}\r\n\r\n"));
    stream.write_all(head.as_bytes()).await?;

    if method == "HEAD" {
        return Ok(());
    }

    // 分块读发。一次性把整段(可能是几百 MB)读进内存会直接把手机撑爆。
    const CHUNK: u64 = 512 * 1024;
    let mut pos = start;
    while pos <= end {
        let want = CHUNK.min(end - pos + 1);
        let data = match src.read_at(pos, want).await {
            Ok(d) => d,
            // 读不动就断开。硬撑着不回等于让播放器干等到超时,
            // 断开它至少会重试或报错,用户看得见。
            Err(_) => break,
        };
        if data.is_empty() {
            break; // 到头了(或对端认为到头了),别原地转圈
        }
        let n = data.len() as u64;
        stream.write_all(&data).await?;
        pos += n;
    }
    stream.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;

    /// 一段内存里的假文件,按偏移吐 `offset as u8`,好让测试能逐字节验位置对不对。
    struct Fake(Vec<u8>);

    #[async_trait::async_trait]
    impl RangeSource for Fake {
        fn size(&self) -> u64 {
            self.0.len() as u64
        }
        async fn read_at(&self, offset: u64, len: u64) -> std::io::Result<Vec<u8>> {
            let s = (offset as usize).min(self.0.len());
            let e = ((offset + len) as usize).min(self.0.len());
            Ok(self.0[s..e].to_vec())
        }
    }

    fn fake(n: usize) -> Arc<dyn RangeSource> {
        Arc::new(Fake((0..n).map(|i| i as u8).collect()))
    }

    /// 发一个原始请求,回 (状态行+头, body)
    async fn req(url: &str, extra: &str) -> (String, Vec<u8>) {
        let addr = url.trim_start_matches("http://");
        let (hostport, path) = addr.split_once('/').unwrap();
        let mut s = TcpStream::connect(hostport).await.unwrap();
        s.write_all(format!("GET /{path} HTTP/1.1\r\nHost: x\r\n{extra}\r\n").as_bytes())
            .await
            .unwrap();
        let mut buf = Vec::new();
        s.read_to_end(&mut buf).await.unwrap();
        let split = buf
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .expect("响应里没有头体分隔");
        (
            String::from_utf8_lossy(&buf[..split]).to_string(),
            buf[split + 4..].to_vec(),
        )
    }

    /// 不带 Range = 整个文件 + 200。
    #[tokio::test]
    async fn serves_whole_file_without_range() {
        let h = start(fake(1000)).await.unwrap();
        let (head, body) = req(&h.url, "").await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        assert!(head.contains("Content-Length: 1000"), "{head}");
        assert_eq!(body.len(), 1000);
        assert_eq!(body[0], 0);
    }

    /// Range 必须回 206 + 正确的 Content-Range,而且**字节要真的来自那个偏移**。
    /// 只断言长度的话,一个「忽略 offset 永远从头读」的实现照样能过。
    #[tokio::test]
    async fn range_returns_206_with_bytes_from_that_offset() {
        let h = start(fake(1000)).await.unwrap();
        let (head, body) = req(&h.url, "Range: bytes=100-199\r\n").await;
        assert!(head.starts_with("HTTP/1.1 206"), "{head}");
        assert!(head.contains("Content-Range: bytes 100-199/1000"), "{head}");
        assert_eq!(body.len(), 100);
        assert_eq!(body[0], 100u8, "起点不对 —— 说明 offset 被忽略了");
        assert_eq!(body[99], 199u8);
    }

    /// 开区间 `bytes=N-`:一直到文件尾。mpv 起播就爱发这个。
    #[tokio::test]
    async fn open_ended_range_runs_to_eof() {
        let h = start(fake(1000)).await.unwrap();
        let (head, body) = req(&h.url, "Range: bytes=900-\r\n").await;
        assert!(head.contains("Content-Range: bytes 900-999/1000"), "{head}");
        assert_eq!(body.len(), 100);
        assert_eq!(body[0], (900u64 % 256) as u8, "起点不对");
    }

    /// 越界要 416,**不能**悄悄挪回最后一字节回 206(那是给播放器喂错位数据)。
    #[tokio::test]
    async fn out_of_range_is_416_not_a_silently_clamped_206() {
        let h = start(fake(1000)).await.unwrap();
        let (head, body) = req(&h.url, "Range: bytes=5000-6000\r\n").await;
        assert!(head.starts_with("HTTP/1.1 416"), "越界被钳回去了: {head}");
        assert!(body.is_empty());
    }

    /// 少了 Connection: close,ffmpeg 会把 seek 管线化到同一条 socket 上然后永远等下去。
    #[tokio::test]
    async fn always_declares_connection_close() {
        let h = start(fake(1000)).await.unwrap();
        let (head, _) = req(&h.url, "Range: bytes=0-9\r\n").await;
        assert!(
            head.to_lowercase().contains("connection: close"),
            "没声明 close —— seek 会被管线化吞掉: {head}"
        );
    }

    /// 大于单次分块(512K)的区间要拼完整,不能只回第一块。
    #[tokio::test]
    async fn spans_multiple_internal_chunks() {
        let n = 1_500_000;
        let h = start(fake(n)).await.unwrap();
        let (head, body) = req(&h.url, "Range: bytes=0-1499999\r\n").await;
        assert!(head.contains(&format!("Content-Length: {n}")), "{head}");
        assert_eq!(body.len(), n, "分块循环提前退出了,只回了第一块");
        assert_eq!(body[1_000_000], (1_000_000u64 as u8));
    }

    /// handle 一 drop,端口就该关 —— 否则换一片就漏一个监听端口和一条 SMB 连接。
    #[tokio::test]
    async fn dropping_the_handle_closes_the_port() {
        let h = start(fake(10)).await.unwrap();
        let addr = h.url.trim_start_matches("http://").trim_end_matches("/stream").to_string();
        assert!(TcpStream::connect(&addr).await.is_ok());
        drop(h);
        // abort 不是同步的,给调度器一拍
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        assert!(
            TcpStream::connect(&addr).await.is_err(),
            "handle 已经 drop,端口还开着 —— 每换一片漏一个"
        );
    }
}
