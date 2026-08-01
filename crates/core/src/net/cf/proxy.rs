// 本地 CF 反代 —— 迁自 Dart cf_reverse_proxy.dart。
//
// 监听 127.0.0.1:<随机端口>,把明文 HTTP 桥接成到**优选 CF IP** 的 HTTPS。
// Dart 手写了 TLS 隧道 + 连接池 + chunked 解析,只因 Dart HttpClient 难同时"钉 IP + 保 SNI
// + 复用连接";Rust 里 reqwest `.resolve(host, ip:443)` 一步到位——钉 IP、SNI/Host 仍是真实
// 域名、keep-alive 连接池自带。故这里只手写入站解析 + 出站转发,省掉整个 ByteReader/chunked。
//
// 切 IP:重建 reqwest 客户端(旧连接自然淘汰);切 IP 属低频(重测速后),重建成本可忽略。

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;

fn logw(msg: &str) {
    eprintln!("[CfProxy] {msg}");
}

/// 运行中的反代句柄;Drop 即停服。
pub struct CfProxyHandle {
    pub port: u16,
    proxy: Arc<CfReverseProxy>,
}

impl CfProxyHandle {
    /// 切换优选 IP(端口不变)。
    pub async fn update_ip(&self, ip: String) {
        self.proxy.update_ip(ip).await;
    }
    pub async fn pinned_ip(&self) -> String {
        self.proxy.ip.lock().await.clone()
    }
}

impl Drop for CfProxyHandle {
    fn drop(&mut self) {
        self.proxy.closed.store(true, Ordering::SeqCst);
    }
}

struct CfReverseProxy {
    scheme: String,
    host: String,
    port: u16,
    allow_insecure: bool,
    client: Mutex<reqwest::Client>,
    ip: Mutex<String>,
    closed: AtomicBool,
}

/// 启动反代,返回本地端口(本地基址 http://127.0.0.1:<port>)。失败 None。
pub async fn start(
    scheme: String,
    host: String,
    port: u16,
    ip: String,
    allow_insecure: bool,
) -> Option<CfProxyHandle> {
    let client = build_client(&host, &ip, port, allow_insecure)?;
    let proxy = Arc::new(CfReverseProxy {
        scheme,
        host,
        port,
        allow_insecure,
        client: Mutex::new(client),
        ip: Mutex::new(ip),
        closed: AtomicBool::new(false),
    });

    let listener = TcpListener::bind(("127.0.0.1", 0)).await.ok()?;
    let local_port = listener.local_addr().ok()?.port();

    let p = proxy.clone();
    tokio::spawn(async move {
        loop {
            if p.closed.load(Ordering::SeqCst) {
                break;
            }
            match listener.accept().await {
                Ok((stream, _)) => {
                    let pc = p.clone();
                    tokio::spawn(async move {
                        let _ = pc.handle(stream).await;
                    });
                }
                Err(e) => {
                    logw(&format!("本地反代监听异常: {e}"));
                    break;
                }
            }
        }
    });

    logw(&format!(
        "反代已启动 127.0.0.1:{local_port} -> {}://{}:{} via {}",
        proxy.scheme,
        proxy.host,
        proxy.port,
        proxy.ip.try_lock().map(|g| g.clone()).unwrap_or_default()
    ));
    Some(CfProxyHandle {
        port: local_port,
        proxy,
    })
}

/// reqwest 客户端:把 host 的 DNS 钉到 ip:port,TLS SNI/Host 仍是 host,keep-alive 连接池自带。
fn build_client(host: &str, ip: &str, port: u16, allow_insecure: bool) -> Option<reqwest::Client> {
    let addr: SocketAddr = if ip.contains(':') {
        format!("[{ip}]:{port}").parse().ok()?
    } else {
        format!("{ip}:{port}").parse().ok()?
    };
    reqwest::Client::builder()
        .resolve(host, addr)
        .danger_accept_invalid_certs(allow_insecure)
        .redirect(reqwest::redirect::Policy::none()) // 反代忠实透传,不代客户端跟跳
        .connect_timeout(Duration::from_secs(15))
        .build()
        .ok()
}

fn is_hop_by_hop(name: &str) -> bool {
    matches!(
        name.to_ascii_lowercase().as_str(),
        "host" | "connection" | "proxy-connection" | "keep-alive" | "upgrade" | "transfer-encoding"
    )
}

impl CfReverseProxy {
    async fn update_ip(&self, ip: String) {
        {
            let mut cur = self.ip.lock().await;
            if *cur == ip {
                return;
            }
            *cur = ip.clone();
        }
        if let Some(c) = build_client(&self.host, &ip, self.port, self.allow_insecure) {
            *self.client.lock().await = c;
            logw(&format!("反代上游切换到 {ip}(端口不变)"));
        }
    }

    async fn handle(&self, mut stream: TcpStream) -> std::io::Result<()> {
        let req = match read_request(&mut stream).await? {
            Some(r) => r,
            None => return Ok(()),
        };

        // 构造上游请求:改写为 https://host:port + 原 target。
        let url = format!(
            "{}://{}:{}{}",
            self.scheme, self.host, self.port, req.target
        );
        let method = reqwest::Method::from_bytes(req.method.as_bytes())
            .unwrap_or(reqwest::Method::GET);
        let is_head = method == reqwest::Method::HEAD;

        let client = self.client.lock().await.clone();
        let mut rb = client.request(method, &url);
        for (k, v) in &req.headers {
            if !is_hop_by_hop(k) {
                rb = rb.header(k, v);
            }
        }
        if !req.body.is_empty() {
            rb = rb.body(req.body);
        }

        let resp = match rb.send().await {
            Ok(r) => r,
            Err(e) => {
                logw(&format!("代理请求失败: {e}"));
                let _ = stream
                    .write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                    .await;
                return Ok(());
            }
        };

        let code = resp.status().as_u16();
        let reason = resp.status().canonical_reason().unwrap_or("");
        let clen = resp.content_length();
        let bodyless = is_head || code == 204 || code == 304 || (100..200).contains(&code);

        // 头:透传上游头,剔除逐跳头与长度/编码(由本端重新框定)。
        let mut head = format!("HTTP/1.1 {code} {reason}\r\n");
        /* ★ 必须显式 `Connection: close` —— 与 [[prefetch-keepalive-swallows-seek]] 同一个坑,
           那边 2026-07-19 修了,**这份同构代码漏了**(用户 2026-08-01:「没有画面也没有声音…
           即便有时候显示有流量,也依然加载不出来」,和当年一字不差)。

           handle() 每条 TCP 只 read_request 一次,喂完 body 就返回、socket 随之 drop。
           可 HTTP/1.1 默认长连接 —— 不写这头就是在对播放器承诺「这条连接还能再发请求」。
           mpv/ffmpeg 起播必 seek(MKV 索引在末尾),它会把下一个 `Range:` **管线化发在
           同一条 socket 上**,而那头已经没人读了:请求进黑洞、响应永不来 → 播放器干等,
           超时后重连从头线性读 = 有流量、黑屏无声、慢得离谱。
           声明 close 后每次 seek 老老实实新开连接,正合本代理「一请求一连接」的实现。 */
        head.push_str("Connection: close\r\n");
        for (name, val) in resp.headers().iter() {
            let n = name.as_str();
            if is_hop_by_hop(n) || n.eq_ignore_ascii_case("content-length") {
                continue;
            }
            if let Ok(v) = val.to_str() {
                head.push_str(&format!("{n}: {v}\r\n"));
            }
        }

        if bodyless {
            // HEAD 如实回报资源长度(mpv 用 HEAD 探大小);其余无实体状态置 0。
            let n = if is_head { clen.unwrap_or(0) } else { 0 };
            head.push_str(&format!("Content-Length: {n}\r\n\r\n"));
            stream.write_all(head.as_bytes()).await?;
            return Ok(());
        }

        match clen {
            Some(n) => {
                head.push_str(&format!("Content-Length: {n}\r\n\r\n"));
                stream.write_all(head.as_bytes()).await?;
                self.stream_body(&mut stream, resp, false).await
            }
            None => {
                // 上游 chunked/读到关闭:对客户端用 chunked 重新框定。
                head.push_str("Transfer-Encoding: chunked\r\n\r\n");
                stream.write_all(head.as_bytes()).await?;
                self.stream_body(&mut stream, resp, true).await
            }
        }
    }

    // 透传响应体;chunked=true 时按 HTTP/1.1 chunked 框定。write_all 天然背压。
    async fn stream_body(
        &self,
        stream: &mut TcpStream,
        mut resp: reqwest::Response,
        chunked: bool,
    ) -> std::io::Result<()> {
        loop {
            match resp.chunk().await {
                Ok(Some(bytes)) => {
                    if bytes.is_empty() {
                        continue;
                    }
                    if chunked {
                        stream
                            .write_all(format!("{:x}\r\n", bytes.len()).as_bytes())
                            .await?;
                        stream.write_all(&bytes).await?;
                        stream.write_all(b"\r\n").await?;
                    } else {
                        stream.write_all(&bytes).await?;
                    }
                }
                Ok(None) => break,
                Err(_) => break, // 上游中断:停止透传(客户端会重连/回退)
            }
        }
        if chunked {
            stream.write_all(b"0\r\n\r\n").await?;
        }
        Ok(())
    }
}

struct ParsedReq {
    method: String,
    target: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

/// 读入站 HTTP 请求(头至 \r\n\r\n,再按 Content-Length 读体)。Emby POST 体是小 JSON。
async fn read_request(stream: &mut TcpStream) -> std::io::Result<Option<ParsedReq>> {
    let mut buf = Vec::with_capacity(1024);
    let mut tmp = [0u8; 4096];
    let head_end;
    loop {
        let n = stream.read(&mut tmp).await?;
        if n == 0 {
            return Ok(None);
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(i) = find_head_end(&buf) {
            head_end = i;
            break;
        }
        if buf.len() > 64 * 1024 {
            return Ok(None); // 头过大,拒
        }
    }

    let header_text = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut lines = header_text.split("\r\n");
    let first = lines.next().unwrap_or("");
    let mut parts = first.split(' ');
    let method = parts.next().unwrap_or("GET").to_string();
    let target = {
        let t = parts.next().unwrap_or("/");
        if t.is_empty() { "/".to_string() } else { t.to_string() }
    };

    let mut headers = Vec::new();
    let mut content_length = 0usize;
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            let (k, v) = (k.trim(), v.trim());
            if k.eq_ignore_ascii_case("content-length") {
                content_length = v.parse().unwrap_or(0);
            }
            headers.push((k.to_string(), v.to_string()));
        }
    }

    // 头缓冲里可能已含部分/全部 body。
    let mut body = buf[head_end + 4..].to_vec();
    while body.len() < content_length {
        let n = stream.read(&mut tmp).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    body.truncate(content_length);

    Ok(Some(ParsedReq {
        method,
        target,
        headers,
        body,
    }))
}

fn find_head_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hop_by_hop_detection() {
        assert!(is_hop_by_hop("Connection"));
        assert!(is_hop_by_hop("transfer-encoding"));
        assert!(!is_hop_by_hop("Content-Type"));
        assert!(!is_hop_by_hop("Range"));
    }

    #[test]
    fn finds_header_boundary() {
        assert_eq!(find_head_end(b"GET / HTTP/1.1\r\nHost: x\r\n\r\nBODY"), Some(23));
        assert_eq!(find_head_end(b"incomplete\r\n"), None);
    }

    /// 极简上游:回一条固定的 200,带 Content-Length。返回它的端口。
    async fn fake_upstream() -> u16 {
        let l = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = l.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = l.accept().await {
                tokio::spawn(async move {
                    // 读到头结束就够了,不关心内容。
                    let mut buf = [0u8; 2048];
                    let _ = s.read(&mut buf).await;
                    let _ = s
                        .write_all(b"HTTP/1.1 200 OK\r\nContent-Type: video/x-matroska\r\nContent-Length: 4\r\n\r\nDATA")
                        .await;
                });
            }
        });
        port
    }

    /* 回归:反代的响应必须声明 `Connection: close`。

       本代理每条 TCP 只处理**一个**请求(handle 里 read_request 一次,回完就返回、socket drop),
       而 HTTP/1.1 默认长连接。不声明 close = 骗播放器「还能再发」,ffmpeg 一 seek 就把
       下一个 Range 管线化到同一条已死的连接上,响应永远不来 →
       用户报的「有流量、没画面没声音、加载巨慢」。

       这条 bug 在预取代理上 2026-07-19 修过并留了同名测试(prefetch.rs
       `response_declares_connection_close`),**这份同构代码当时漏了**。两边都得有护栏。
       反向验证:把 handle() 里那行 `head.push_str("Connection: close\r\n")` 删掉,本测试立刻红。 */
    #[tokio::test]
    async fn response_declares_connection_close() {
        let up = fake_upstream().await;
        // scheme=http + host=localhost + ip=127.0.0.1:上游端口 → reqwest 的 .resolve 钉过去。
        let h = start("http".into(), "localhost".into(), up, "127.0.0.1".into(), false)
            .await
            .expect("反代应能起来");

        let mut c = TcpStream::connect(("127.0.0.1", h.port)).await.unwrap();
        c.write_all(b"GET /x.mkv HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-\r\n\r\n")
            .await
            .unwrap();

        let mut buf = Vec::new();
        let mut tmp = [0u8; 1024];
        // 读到头结束即可;上游是本机,不会慢。
        loop {
            let n = c.read(&mut tmp).await.unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n]);
            if find_head_end(&buf).is_some() {
                break;
            }
        }
        let head = String::from_utf8_lossy(&buf).to_ascii_lowercase();
        assert!(
            head.contains("connection: close"),
            "CF 反代没声明 Connection: close —— 播放器会把 seek 管线化到同一条连接上永远等不到响应\n{head}"
        );
    }
}
