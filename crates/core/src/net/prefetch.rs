// 多线程加载(本地缓存预取代理)—— 迁自 Dart lib/core/network/prefetch_proxy/prefetch_proxy.dart。
//
// 起播时在 127.0.0.1:<随机端口> 起本地 HTTP 服务当播放源交给 mpv。代理用 2~4 个并发
// Range 连接对真实播放流"超前"拉取,在内存里维护有界读前缓冲,再"顺序"喂给播放器:
//   - 多连接聚合带宽 → 弱网也能喂满,少卡顿;
//   - 播放器从 localhost 读 → 抖动被缓冲吸收;
//   - 代理对上游网络错误自带重试,mpv 只面对始终在线的 localhost,弱网瞬断不冒泡。
//
// ## 窗口是「每连接」的,不是全局的(2026-07-17 修:这就是「开了放不了」的根因)
// 旧版把取数窗口(serve_chunk/fetch_cursor/ready)放在 Session 上全局**共用**,每条进来的
// HTTP 请求都 reset() 把游标拽到自己的起点并 ready.clear()。mpv 探测 MKV(带大字体附件、
// 索引在末尾的片子)会在旧连接没关时就新开一条 —— 后来者一 reset,前一条正在 await 的分段
// 就再也没人去拉了:响应头已发出、body 一个字节不来 = 有流量、黑屏无声、永远缓冲。
// 现在每条连接持有自己的 Stream(独立窗口 + 独立 worker),连接之间互不干扰;
// 每条连接只**向前顺序**取数(观影场景本就是顺序的),跳转 = mpv 开新连接,而不是把
// 别人下好的缓存冲掉。共享的只有探测结果与上游地址(Origin)。
//
// 只代理 Emby 直传流(直链/转码由调用方跳过);故只带全局 UA,无逐流鉴权头。
// 取不到文件大小 / 起服失败 → start() 返回 None,调用方回退直连在线地址。

use std::collections::HashSet;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, Notify};
use tokio::task::JoinHandle;

const CHUNK_SIZE: u64 = 4 * 1024 * 1024; // 每段 4MB

/// **预取超前窗口**上限:一条连接最多比播放位置提前拉这么多。
///
/// ★ 2026-07-19 从「缓存上限」里**拆出来** —— 这两件事以前共用一个值,是个真雷:
/// 缓存上限放开到 GB 级后,预取窗口跟着变成 GB 级,一条连接会一路狂拉几个 G。
/// 而被播放器丢下的连接**正是照着这个窗口把量拉满才停**(见 abandoned_connection 测试),
/// 于是「跳一次进度条」的代价从白拉 32MB 升级成白拉几 GB。
///
/// 超前量本来也不需要大:真正的大缓冲由 mpv 自己的 demuxer cache 扛,代理这层
/// 只要能把它喂满就行。64MB 在最慢的实测链路(~1.3MB/s)上也有 ~45 秒余量。
const MAX_READ_AHEAD: u64 = 64 * 1024 * 1024;

/// 单次取数(建连 + 收完 4MB 分段)的上限。超了就当这个地址不灵,作废重试。
///
/// ★ 存在的理由不是"调优",是**兜底**:http.rs 的三个 reqwest client 一个 timeout 都没设,
/// 上游不回话时 `send().await` 会**永远**等下去 —— 没重试、没日志、没回退,
/// 而供给端跟着一起等,mpv 收到 206 头之后一帧不出。用户报的「没画面没声音、
/// 完全看不到流量」就是这个形态。宁可慢,不可吊死。
/// 20s:**空闲**上限,不是整体上限 —— 每收到一块字节就重置。
/// 实测最慢的链路(2026-08-01 用户那台,56~143KB/s)拉满一个 4MB 分段要 29~62 秒,
/// 但块与块之间从不空闲 20 秒。整体超时会把这种「慢但能用」的链路误杀,别改回去。
const CHUNK_TIMEOUT_MS: u64 = 20_000;

/// 可覆盖的实际值。**只为测试存在** —— 回归测试要验「上游只连不回时不吊死」,
/// 按真值跑一遍要一分钟,那种测试没人愿意留在门禁里(而没门禁的修复迟早退化)。
static CHUNK_TIMEOUT_OVERRIDE_MS: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);
/// 改上面那个覆盖值的测试**必须**先拿这把锁。cargo test 是同进程多线程并行,
/// 两个测试各设各的值、谁先跑完谁就把对方的值清回真值 —— 于是后者按 20s 真值等,
/// 直接超时红,而它自己毫无问题。这类"测试互踩"读起来像真 bug,最费排查时间
/// (http.rs 的三个全局 client 上记过同一笔账)。
#[cfg(test)]
static CHUNK_TIMEOUT_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
fn chunk_timeout() -> Duration {
    match CHUNK_TIMEOUT_OVERRIDE_MS.load(Ordering::Relaxed) {
        0 => Duration::from_millis(CHUNK_TIMEOUT_MS),
        ms => Duration::from_millis(ms),
    }
}

/// 预取超前窗口字节数,钳进 [每 worker 一段, MAX_READ_AHEAD]。
///
/// ★ 入参是用户设的**缓存上限**,但它在这里只当天花板用(用户把缓存调得很小时,
/// 超前量不该超过缓存本身,否则刚拉回来的段立刻被环形覆盖掉)。
/// 缓存上限本身有多大是 [`DiskCache`] 的事,不由这里决定。
///
/// ★ 原来写的是 `MAX_READ_AHEAD.min((CHUNK*threads*2).max(cache_limit))` —— `max` 用反了:
/// 用户的缓存上限本该是**天花板**,那样写却成了下限,默认 1GB 直接把窗口顶到硬上限。
fn read_ahead_bytes(threads: usize, cache_limit_bytes: u64) -> u64 {
    let floor = CHUNK_SIZE * threads as u64; // 每个 worker 至少能有一段在手
    cache_limit_bytes.clamp(floor.min(MAX_READ_AHEAD), MAX_READ_AHEAD)
}

/// 上游签名链失效时的重签回调:重走 PlaybackInfo 拿新直传流地址;None=不支持重签。
pub type ResignFn =
    Arc<dyn Fn() -> Pin<Box<dyn Future<Output = Option<String>> + Send>> + Send + Sync>;

fn logw(msg: &str) {
    eprintln!("[Prefetch] {msg}");
}

/// 一个运行中的代理句柄;Drop 即停服、放行所有连接的 worker 退出。
pub struct ProxyHandle {
    pub url: String,
    origin: Arc<Origin>,
    _accept: JoinHandle<()>,
}

impl Drop for ProxyHandle {
    fn drop(&mut self) {
        self.origin.closed.store(true, Ordering::SeqCst);
    }
}

/// 启动预取代理并返回本地播放 URL;失败返回 None(调用方回退在线直链)。
///
/// `threads` 限定 2~4(每条播放连接各起这么多 worker);`cache_limit_bytes` 为用户视频
/// 缓存上限(给单连接读前缓冲封顶);`on_invalid` 为上游失效重签回调(可 None)。
pub async fn start(
    upstream_url: String,
    threads: usize,
    cache_limit_bytes: u64,
    on_invalid: Option<ResignFn>,
) -> Option<ProxyHandle> {
    let t = threads.clamp(2, 4);
    let read_ahead = read_ahead_bytes(t, cache_limit_bytes);

    let origin =
        Origin::probe(upstream_url.clone(), t, read_ahead, cache_limit_bytes, on_invalid).await?;

    let listener = TcpListener::bind(("127.0.0.1", 0)).await.ok()?;
    let port = listener.local_addr().ok()?.port();

    let accept = {
        let o = origin.clone();
        tokio::spawn(async move {
            loop {
                if o.closed.load(Ordering::SeqCst) {
                    break;
                }
                match listener.accept().await {
                    Ok((stream, _)) => {
                        let oc = o.clone();
                        tokio::spawn(async move {
                            if let Err(e) = oc.handle(stream).await {
                                let _ = e; // 播放器断开(seek/退出)属正常,静默
                            }
                        });
                    }
                    Err(e) => {
                        logw(&format!("本地服务监听异常: {e}"));
                        break;
                    }
                }
            }
        })
    };

    let url = format!("http://127.0.0.1:{port}/play");
    eprintln!(
        "[Prefetch] 多线程预取代理启动 {url} <- {upstream_url} ({}MB, 每连接 {t} 线程, 预取窗口 {}MB, 磁盘缓存 {}MB)",
        origin.total_size / (1024 * 1024),
        read_ahead / (1024 * 1024),
        origin.disk.ring * CHUNK_SIZE / (1024 * 1024),
    );
    Some(ProxyHandle {
        url,
        origin,
        _accept: accept,
    })
}

struct UpstreamState {
    url: String,
    /// 跟随 302 后的**最终**地址(CDN 直链);worker 优先打它,省掉每段一次重定向。
    ///
    /// ★ 为什么值得单独存:UHD 那类服务端(v1.uhdnow.com)的直传流是 302 跳 CDN,
    /// 而 `fetch_chunk` 每段都是一次独立请求 —— 不缓存最终地址,就是**每 4MB 重走一遍
    /// 302**。实测 0.67s/段,占单段 TTFB(1.4s)的一半,并行省下的时间全赔在建连上:
    /// 3 线程 4.0MB/s 反而**慢于**单连接 4.3MB/s,多线程加载成了负优化。
    /// 原版 Emby 无重定向(实测 redirect=0.000000),此字段恒为 None,零影响。
    ///
    /// CDN 直链通常自带时效签名,过期即失效 → 失败时清空回退 `url` 重新解析(见 fetch_chunk)。
    resolved: Option<String>,
    resign_disabled: bool,
    resign_in_flight: bool,
}

/// 全代理共享:探测结果 + 上游地址 + HTTP 客户端。**不含取数游标**(那是每连接的)。
struct Origin {
    upstream: Mutex<UpstreamState>,
    total_size: u64,
    content_type: String,
    threads: usize,
    read_ahead_chunks: u64,
    closed: AtomicBool,
    client: reqwest::Client,
    on_invalid: Option<ResignFn>,
    disk: Arc<DiskCache>,
    /// 正在拉取中的分段(段号 -> 载体)。**「边收边吐」的登记处**,见 [`Live`]。
    /// 用 std 锁不用 tokio 锁:临界区只有 HashMap 的 get/insert/remove,里面没有 await。
    live: std::sync::Mutex<std::collections::HashMap<u64, Arc<Live>>>,
}

/// 正在拉取中的一个分段 —— **边收边吐**的载体(2026-08-02)。
///
/// ## 为什么非要有它
/// 在这之前,供给端 `serve` 必须等**整段 4MB 落盘**才吐第一个字节。
/// 而 mpv 起播只要文件头 ~200KB + 尾部 cues 索引(MKV,ffmpeg 开容器第一跳就 seek 到尾)。
/// 实测用户那条链(2026-08-01)吞吐只有 56~143KB/s → 一段 4MB **合法地要 29~62 秒**,
/// 头/尾各一次,于是「开了多线程加载就没画面没声音」。直连反而能播,正是因为
/// mpv 只拉它真正要的那几百 KB。分段粒度是给**预取**用的,不该成为**供给**的粒度。
///
/// 所以 worker 收到的每一块字节都立刻挂到这里并唤醒供给端,供给端要多少给多少 ——
/// 落盘照旧(缓存/回看要它),但不再挡在播放器前面。
///
/// `cap` = 本段的应有长度,多出来的字节直接丢:上游给超长包时不能污染供给,
/// 而「短了必须重试」的判据(见 `fetch_chunk` 头部)靠 `len() == want` 原样保留。
#[derive(Default)]
struct Live {
    data: std::sync::Mutex<Vec<u8>>,
    notify: Notify,
    /// 喂食结束(成功/失败/被取消)。置位后供给端不再干等,回落到磁盘/重拉路径。
    done: AtomicBool,
    /// 本载体覆盖的是段内 `[base, base+cap)`。`base > 0` 只出现在**连接首段**,见 [`Stream::head_live`]。
    base: usize,
    cap: usize,
}

impl Live {
    fn new(cap: usize) -> Arc<Live> {
        Self::based(0, cap)
    }

    fn based(base: usize, cap: usize) -> Arc<Live> {
        Arc::new(Live {
            data: std::sync::Mutex::new(Vec::with_capacity(cap.min(CHUNK_SIZE as usize))),
            base,
            cap,
            ..Default::default()
        })
    }

    fn len(&self) -> usize {
        self.data.lock().map(|d| d.len()).unwrap_or(0)
    }

    /// 并进新到的一块。
    ///
    /// ★ `skip` 是**重试**用的:第 2 次 attempt 打的是同一个 Range,前面那几 MB
    /// 上一轮已经收下、而且很可能**已经吐给播放器了**,不能再追加一遍。
    /// 同 URL 同 Range 返回同样的字节,是这份缓存从一开始就依赖的前提;
    /// 靠这个 skip,重试的健壮性和改造前完全一致(既能续上,也不会重复)。
    fn feed(&self, skip: &mut usize, b: &[u8]) {
        if *skip >= b.len() {
            *skip -= b.len();
            return;
        }
        let b = &b[*skip..];
        *skip = 0;
        {
            let Ok(mut d) = self.data.lock() else { return };
            let room = self.cap.saturating_sub(d.len());
            if room == 0 {
                return;
            }
            d.extend_from_slice(&b[..room.min(b.len())]);
        }
        self.notify.notify_waiters();
    }

    /// 从**段内**偏移 `at` 起、当前已到货的部分;还没到(或压根不在本载体覆盖范围内)就是 None。
    fn slice_from(&self, at: usize) -> Option<Vec<u8>> {
        let i = at.checked_sub(self.base)?;
        let d = self.data.lock().ok()?;
        (d.len() > i).then(|| d[i..].to_vec())
    }

    fn snapshot(&self) -> Vec<u8> {
        self.data.lock().map(|d| d.clone()).unwrap_or_default()
    }
}

/// 落盘的分段缓存 —— **全会话共享**(所有连接共用一份),不是每连接一份。
///
/// ## 为什么必须落盘(2026-07-19 用户定)
/// 原来分段全存在内存 `HashMap<u64, Arc<Vec<u8>>>` 里,峰值 = 单连接窗口 × 存活连接数。
/// 实测(见 `abandoned_connection_keeps_fetching_after_client_disconnect`):播放器一 seek
/// 就丢下旧连接新开一条,而被丢下的连接**还会把整个窗口填满才罢休** —— 快速拖 N 次进度条
/// 就是 32MB × N 瞬时占用,内存不足直接闪退。因为不敢放大,用户设置项被硬钳在 16~32MB,
/// 「视频缓存上限」这个设置形同虚设。
/// 落盘后内存只剩**正在传输的那几段**(threads × 4MB),窗口上限才敢跟着用户设置走。
///
/// ## 为什么共享而不是每连接一份
/// 共享才有"缓存"的意义:seek 回看过的区域直接命中磁盘,不重新下载(省用户流量/服务器压力)。
/// 每连接一份的话,拖回去一次就得重下一次,那只是"缓冲"不是"缓存"。
///
/// 稀疏文件:按 `chunk * CHUNK_SIZE` 定位写入,实际占用只有已下载的部分。
/// 会话结束(ProxyHandle Drop)即删除,不跨会话保留。
struct DiskCache {
    file: std::sync::Mutex<std::fs::File>,
    /// 槽位 -> 当前存的分段号。`slots[c % n] == Some(c)` 才算命中。
    ///
    /// ★ 环形复用而不是无限增长:磁盘占用恒定 = 用户设的缓存上限。整片直存看着简单,
    /// 但测试服里随手就有 29.6GB 的片子 —— 顺序看完一遍就把用户硬盘吃掉 29.6GB,
    /// 这和「内存爆掉」是同一个错误换了个介质。环形写下来,旧段被新段覆盖,
    /// 上限内的回看照样命中。
    slots: Mutex<std::collections::HashMap<u64, u64>>,
    ring: u64, // 槽位数
    path: std::path::PathBuf,
}

impl DiskCache {
    /// `cache_bytes` = 用户设的缓存上限,决定环形槽位数(磁盘占用封顶就是它)。
    /// 槽位至少要比并发 worker 多,否则 worker 之间会互相覆盖对方刚写的段。
    fn create(total: u64, cache_bytes: u64, threads: usize) -> Option<Arc<DiskCache>> {
        let dir = crate::paths::cache_dir("prefetch");
        std::fs::create_dir_all(&dir).ok()?;
        /* 文件名必须**每个实例唯一**,不能是 (pid, total)。
           旧名 `s{pid}_{total}.part` 的前提是「同一进程内起播是串行的,旧的先 Drop 删掉」——
           这个前提不成立:两个会话完全可能并存(孤儿播放器还没 Drop、新播放器已起来,
           见 [[desktop-double-audio-orphan-player]];同一部片 total 当然相同)。
           一旦重名,后来者的 `truncate(true)` 会把前者的数据**整个清零**,而前者的 `slots`
           表在内存里,仍然认为那些段「就绪」→ 后来者再写一个高位槽把文件撑长 →
           前者读低位槽读回一整块**稀疏零**,并当作有效数据发给播放器。
           这就是 CI 上 `concurrent_connections_do_not_starve_each_other` 偶发红的真凶:
           cargo test 是同进程多线程并行,几个预取测试的 TOTAL 都是 40MB,互相 truncate。
           (孤立跑 30 次全绿、全量并行约 1/5 翻车,差别正是「有没有别的会话同时在」。) */
        static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = dir.join(format!("s{}_{}_{}.part", std::process::id(), total, seq));
        let file = std::fs::OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(true)
            .open(&path)
            .ok()?;
        let want = (cache_bytes / CHUNK_SIZE).max(threads as u64 * 2);
        let ring = want.min(total.div_ceil(CHUNK_SIZE)); // 比整片还大就没必要 // 比整片还大就没必要
        Some(Arc::new(DiskCache {
            file: std::sync::Mutex::new(file),
            slots: Mutex::new(std::collections::HashMap::new()),
            ring: ring.max(1),
            path,
        }))
    }

    /// 分段 c 在盘上的槽位偏移。
    fn off(&self, c: u64) -> u64 {
        (c % self.ring) * CHUNK_SIZE
    }

    /// 该段是否就绪(槽位没被别的段覆盖掉)。
    async fn has(&self, c: u64) -> bool {
        self.slots.lock().await.get(&(c % self.ring)) == Some(&c)
    }

    /// 写入一段并标记就绪。写盘走 spawn_blocking,不阻塞 runtime。
    ///
    /// ★ 全程持 `slots` 锁,且**先把槽标失效再写**。
    /// 原来是「写完盘再更新 slots」,于是读者可以:查 slots 命中 → 开始读 →
    /// 另一条流正把**别的段**覆盖进同一个槽 → 读到半新半旧的脏数据。
    /// 表现是播放器拿到错帧(实测:B 连接在自己的起始位置读到 A 的字节),
    /// 比饿死更隐蔽 —— 它不报错,只是画面坏掉。
    /// 环形缓存是全连接共享的(槽位 = chunk % ring),两条连接的段号模 ring 同余就同槽,
    /// 所以这个竞态在多连接下是必然会撞上的,不是理论风险。
    async fn put(self: &Arc<Self>, c: u64, data: Vec<u8>) -> bool {
        let me = self.clone();
        let slot = c % self.ring;
        let mut slots = self.slots.lock().await;
        slots.remove(&slot); // 写到一半被读走 = 脏数据,先失效
        let ok = tokio::task::spawn_blocking(move || {
            use std::io::{Seek, SeekFrom, Write};
            let mut f = me.file.lock().ok()?;
            f.seek(SeekFrom::Start(me.off(c))).ok()?;
            f.write_all(&data).ok()?;
            Some(())
        })
        .await
        .ok()
        .flatten()
        .is_some();
        if ok {
            slots.insert(slot, c);
        }
        ok
    }

    /// 读回一段。**返回 None = 这一段已经被别的连接挤出槽位**,调用方要重拉而不是当失败。
    ///
    /// 槽位校验必须和读盘在**同一把锁**里完成:先 has() 再 get() 的两段式有 TOCTOU,
    /// 中间那一瞬别人把槽覆盖了就会读到别人的数据(见 put 上的说明)。
    async fn get(self: &Arc<Self>, c: u64, len: usize) -> Option<Vec<u8>> {
        let me = self.clone();
        let slots = self.slots.lock().await;
        if slots.get(&(c % self.ring)) != Some(&c) {
            return None; // 已被挤掉
        }
        let buf = tokio::task::spawn_blocking(move || {
            use std::io::{Read, Seek, SeekFrom};
            let mut f = me.file.lock().ok()?;
            f.seek(SeekFrom::Start(me.off(c))).ok()?;
            let mut buf = vec![0u8; len];
            f.read_exact(&mut buf).ok()?;
            Some(buf)
        })
        .await
        .ok()
        .flatten();
        /* 这里原来还有一句「读完再 has() 复核一次」。现在**不能留**:
           slots 锁已经被本函数持到读完,再调 has() 就是对同一把 tokio::Mutex 重入 —— 死锁。
           而且也不需要了:锁覆盖了「校验 + 读盘」全程,put 又是在同一把锁里先失效再写,
           两边不可能交错。复核是两段式时代的补丁,协议改对之后它就是纯粹的自锁陷阱。 */
        drop(slots);
        buf
    }
}

impl Drop for DiskCache {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path); // 会话内缓存,退出即清,不留垃圾
    }
}

/// 每连接的顺序取数窗口。连接结束即 done,它的 worker 随之退出。
/// **不再持有分段数据**(数据在 [`DiskCache`] 里,全连接共享)。
struct ChunkState {
    failed: HashSet<u64>, // 永久失败(供给端遇到即断流)
    serve_chunk: u64,     // 下一个要供给的分段
    fetch_cursor: u64,    // 下一个要分配给 worker 的分段
    /// 已被 worker 认领、还没落盘的分段。
    /// ★ 必须有它才能把「在飞」和「被环形缓存挤掉」分开:两者的 disk.has() 都是 false,
    /// 但前者只需等,后者必须重拉。分不开就会把在飞的段又拉一遍(重复下载 = 烧用户流量)。
    in_flight: HashSet<u64>,
}

struct Stream {
    origin: Arc<Origin>,
    last_chunk: u64,  // 本次请求 Range 的末段(含),取到这儿就收工
    first_chunk: u64, // 本次请求 Range 的首段
    /// 请求起点在首段内的偏移。0 = 正好对齐,没有下面那档事。
    head_within: usize,
    /// 首段的**残段**载体(只覆盖 `[head_within, 段尾)`)。
    ///
    /// ★ 为什么它不进 `Origin::live` 也不落盘:它是**残的**。写进环形缓存会把
    /// `[0, head_within)` 那截垃圾一起标成就绪,别的连接读同一段就拿到脏数据 ——
    /// 那是不报错、只坏画面的一类。挂在本连接上、随连接消亡,最省事也最安全。
    /// 代价是这一小段不进缓存(seek 回来要重下),换来每次 seek 少等平均 2MB。
    head_live: std::sync::Mutex<Option<Arc<Live>>>,
    state: Mutex<ChunkState>,
    data_notify: Notify,   // worker -> serve:某段就绪/失败
    window_notify: Notify, // serve -> worker:窗口推进
    /// 连接结束(播放器断开/跳转)-> 立刻叫停正在飞的 fetch,别再烧用户流量。
    done_notify: Notify,
    done: AtomicBool,
}

impl Origin {
    /// 分段 c 的真实长度(末段可能不足 CHUNK_SIZE)。
    fn chunk_len(&self, c: u64) -> usize {
        let start = c * CHUNK_SIZE;
        ((start + CHUNK_SIZE).min(self.total_size) - start) as usize
    }

    /// 开一个「正在拉取」的载体给 worker 喂。
    ///
    /// ★ 同一段可能被**两条连接**同时拉(`in_flight` 是每连接的),但登记处只认先到的那个:
    /// 后到者拿回一个**没登记**的载体,自己拉自己的,绝不能两个 worker 往同一个载体里喂
    /// —— 那是把两份字节流交错拼进一个 buffer,直接出错帧。
    fn live_begin(&self, c: u64) -> Arc<Live> {
        let live = Live::new(self.chunk_len(c));
        if let Ok(mut m) = self.live.lock() {
            m.entry(c).or_insert_with(|| live.clone());
        }
        live
    }

    /// 喂食结束。**必须在落盘之后调** —— 先摘牌再落盘会留出一个「两边都查不到」的空档,
    /// 供给端在那一瞬只能干等 250ms 兜底。
    fn live_end(&self, c: u64, me: &Arc<Live>) {
        me.done.store(true, Ordering::SeqCst);
        me.notify.notify_waiters();
        if let Ok(mut m) = self.live.lock() {
            // 只摘自己挂上去的那块牌(见 live_begin:后到者的载体压根没登记)。
            if m.get(&c).is_some_and(|x| Arc::ptr_eq(x, me)) {
                m.remove(&c);
            }
        }
    }

    fn live_get(&self, c: u64) -> Option<Arc<Live>> {
        self.live.lock().ok()?.get(&c).cloned()
    }

    async fn probe(
        upstream_url: String,
        threads: usize,
        read_ahead_bytes: u64,
        cache_limit_bytes: u64,
        on_invalid: Option<ResignFn>,
    ) -> Option<Arc<Origin>> {
        // 预取拉上游用 LinPlayerPreload UA(用户 2026-07-19 定):服主要能把「替 mpv
        // 提前拉的旁路请求」和「用户正在看的那一路」在日志里分开。
        let client = crate::http::preload_client();
        let mut resolved: Option<String> = None;

        // 探总大小 + Content-Type:Range bytes=0-0 -> 206 Content-Range: bytes 0-0/<total>。
        let (total, ctype) = match tokio::time::timeout(
            Duration::from_secs(8),
            client
                .get(&upstream_url)
                .header("Range", "bytes=0-0")
                .send(),
        )
        .await
        {
            Ok(Ok(resp)) => {
                // 探测本来就跟完了 302,顺手把落点记下来给 worker 用(只在真发生跳转时存)。
                let final_url = resp.url().as_str().to_string();
                if final_url != upstream_url {
                    resolved = Some(final_url);
                }
                let total = resp
                    .headers()
                    .get("content-range")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|s| s.rsplit('/').next())
                    .and_then(|s| s.trim().parse::<u64>().ok())
                    .unwrap_or(0);
                let ct = resp
                    .headers()
                    .get("content-type")
                    .and_then(|v| v.to_str().ok())
                    .filter(|s| !s.is_empty())
                    .unwrap_or("video/mp4")
                    .to_string();
                (total, ct)
            }
            Ok(Err(e)) => {
                logw(&format!("探测文件大小失败: {e}"));
                (0, "video/mp4".to_string())
            }
            Err(_) => {
                logw("探测文件大小超时");
                (0, "video/mp4".to_string())
            }
        };
        if total <= CHUNK_SIZE {
            return None; // 太小或未知,没必要代理
        }

        // 段数只由字节预算换算,**不再** .max(threads*2) —— 那会反过来突破预算
        // (预算 16MB / 4 线程时会算出 8 段 = 32MB)。.max(1) 只是防
        // worker 里 `serve_chunk + read_ahead_chunks - 1` 下溢。
        let read_ahead_chunks = (read_ahead_bytes / CHUNK_SIZE).max(1);
        // ★ 给磁盘缓存的是**用户设的缓存上限**,不是预取窗口 —— 两者已拆开(见 MAX_READ_AHEAD)。
        //   传错的话缓存会被压回 64MB,用户设的 GB 级上限又变成摆设。
        let disk = DiskCache::create(total, cache_limit_bytes, threads).or_else(|| {
            logw("建不了磁盘缓存文件(权限/空间?),不启用多线程加载,回退直连");
            None
        })?;
        Some(Arc::new(Origin {
            upstream: Mutex::new(UpstreamState {
                url: upstream_url,
                resolved,
                resign_disabled: false,
                resign_in_flight: false,
            }),
            total_size: total,
            content_type: ctype,
            threads,
            read_ahead_chunks,
            closed: AtomicBool::new(false),
            client,
            on_invalid,
            disk,
            live: Default::default(),
        }))
    }

    /// 拉一段(带重试 + 上游失效重签)。返回 None 表示永久失败。
    ///
    /// ★ **必须校验长度**:分段是按 `pos / CHUNK_SIZE` 定位的,收下一个短包会让供给端
    /// 写完这几字节后 `advance_serve(c+1)` 把它清掉,而 `pos` 仍落在分段 c 内 →
    /// 下一轮又去 `next_bytes(c)`,可 `fetch_cursor` 早过了 c,永远没人重拉 → **永远缓冲**。
    /// 上游/CDN 截断、以及我们自家 CF 反代在 chunked 路径上遇错 break 后仍补上合法结束块
    /// (见 net/cf/proxy.rs 的 stream_body),都会产出这种「格式合法但短」的响应。
    async fn fetch_chunk(&self, c: u64, live: &Arc<Live>) -> Option<Vec<u8>> {
        /* ★ 起点由载体的 `base` 决定,**不是**分段边界(2026-08-02)。
           连接首段的 base = 播放器请求的 Range 起点在段内的偏移:每次 seek 都是一条新连接
           (响应声明 Connection: close),从边界拉就等于在播放器要的第一个字节前面
           先白拉平均 2MB —— 150KB/s 下 = 拖一次进度条画面 13 秒不动。 */
        let start = c * CHUNK_SIZE + live.base as u64;
        let end = c * CHUNK_SIZE + self.chunk_len(c) as u64 - 1;
        let want = live.cap;
        for attempt in 0..3 {
            // 优先打 302 落点(CDN 直链),省掉每段一次重定向;没跳转过就还是原地址。
            let (url, used_resolved) = {
                let up = self.upstream.lock().await;
                match &up.resolved {
                    Some(r) => (r.clone(), true),
                    None => (up.url.clone(), false),
                }
            };
            /* ★ 每次取数都必须有超时,而且必须是**空闲超时**,不是整体超时(2026-08-01)。

               ## 为什么非有不可
               在这之前 `send()`/`bytes()` 是**无限期**等待,而 http.rs 的三个 client
               一个 timeout 都没设 —— 上游只要不回(CDN 落点失效、对端黑洞、中间设备吞包),
               这条 worker 就永远吊在这儿:不重试、不重签、不报错、连一行日志都没有。
               供给端 next_bytes 于是也永远等,mpv 那边表现成:206 头收到了、
               `Stream opened successfully`,然后 duration=0 / 一帧不出 / 一条轨道都没有。

               ## 为什么不能用「整体超时」
               我第一版写的就是整体超时(15s),那是**错的**,差点当成修复发出去。
               实测用户那条链(2026-08-01):TTFB 1.3~1.8s 正常,但吞吐只有 56~143KB/s,
               拉满一个 4MB 分段**合法地就要 29~62 秒**。整体超时会把「慢但完全能用」的
               链路当成故障掐掉,还会一路重试放大负载 —— 修一个静默卡死,换来一个更响的。
               只有「**一段时间一个字节都不来**」才是真死。所以计时器每收到一块就重置。 */
            let outcome: Result<Result<bool, u16>, ()> = async {
                // 建连 + 等响应头:这一段可以用整体超时,它本来就该在几秒内完成。
                let sent = tokio::time::timeout(
                    chunk_timeout(),
                    self.client
                        .get(&url)
                        .header("Range", format!("bytes={start}-{end}"))
                        .send(),
                )
                .await;
                let mut r = match sent {
                    Ok(Ok(r)) if r.status().is_success() || r.status().as_u16() == 206 => r,
                    Ok(Ok(r)) => return Ok(Err(r.status().as_u16())),
                    Ok(Err(_)) => return Ok(Ok(false)), // 纯网络抖动,重试同一 URL
                    Err(_) => return Err(()),           // 连响应头都等不到 = 这个地址不灵
                };
                /* 收体:**每来一块就重置计时**,只有真的停止吐字节才判死。
                   ★ 收到就 feed —— 这就是「边收边吐」:供给端不再等整段落盘。
                     `skip` 让重试从上一轮的断点续上,详见 Live::feed。 */
                let mut skip = live.len();
                loop {
                    match tokio::time::timeout(chunk_timeout(), r.chunk()).await {
                        Ok(Ok(Some(b))) => live.feed(&mut skip, &b),
                        Ok(Ok(None)) => return Ok(Ok(true)), // 正常读完
                        Ok(Err(_)) => return Ok(Ok(false)),  // 读体出错,重试
                        Err(_) => return Err(()),            // 停吐了
                    }
                }
            }
            .await;

            // Ok(()) = 这个地址还行,重试它;Err(状态码) = 地址不灵,作废/重签。
            let resp: Result<(), u16> = match outcome {
                Ok(Ok(true)) if live.len() == want => return Some(live.snapshot()),
                // 长度必须**正好**是请求量,短了不能收(见函数头说明;超长由 Live 的 cap 截掉)。
                Ok(Ok(true)) => {
                    logw(&format!("段 {c} 长度不符(要 {want} 得 {}),重试", live.len()));
                    Ok(())
                }
                Ok(Ok(false)) => Ok(()), // 读体失败/网络抖动,重试同一 URL
                Ok(Err(code)) => Err(code),
                Err(_) => {
                    logw(&format!(
                        "段 {c} 空闲超时({:.1}s 没有任何字节){} —— 作废当前地址重试",
                        chunk_timeout().as_secs_f32(),
                        if used_resolved { "(打的是 302 落点)" } else { "" }
                    ));
                    Err(0) // 当成「这个地址不灵」,走下面的作废/重签分支
                }
            };
            if resp.is_err() {
                /* 4xx/5xx / 超时 = 这个地址不灵(短效签名链到期最常见)。
                   ★ 5xx **不一定**是链到期:开了 CF 优选时我们的上游就是本机反代,
                     它连不上 CF 时会自己造一个 502(见 net/cf/proxy.rs 的 Bad Gateway 分支)。
                     所以重签拿回同一个地址是常态,不能据此停用重签 —— 见 refresh_upstream。
                   ★ 先怪 CDN 直链,再怪签名链。CDN 落点通常自带时效签名,过期后只需重走
                     一次 302 就能拿到新落点 —— 这时候去调重签回调(重走 PlaybackInfo)
                     是杀鸡用牛刀,还平白给服务端加一次接口压力。
                     清空 resolved 后下一 attempt 自动回落 url 并重新跟随重定向。 */
                if used_resolved {
                    self.upstream.lock().await.resolved = None;
                } else {
                    self.refresh_upstream().await;
                }
            }
            if attempt < 2 {
                tokio::time::sleep(Duration::from_millis(300 * (attempt + 1))).await;
            }
        }
        logw(&format!("段 {c} 拉取失败"));
        None
    }

    /// 上游签名链失效 → 调用注入的重签回调换新地址(并发合并)。
    ///
    /// **只有回调拿不到地址(None)才停用重签**。原来「重签回来的地址和旧的一样」也停用,
    /// 那是错的:开了 CF 优选时上游是本机反代,它一个 502(CF 那头抖一下)就会走到这里,
    /// 而重签当然还是解析出同一个 127.0.0.1 地址 —— 于是**一次网关抖动就把重签永久关掉**,
    /// 等这部片真的播到签名过期(长片常见)时,已经没人能换地址了 → 断流。
    /// 地址没变 = 这条链还是它,纯属对端/网络抖动,retry 就好,别自废武功。
    async fn refresh_upstream(&self) {
        let cb = match &self.on_invalid {
            Some(cb) => cb.clone(),
            None => return,
        };
        {
            let mut up = self.upstream.lock().await;
            if up.resign_disabled || up.resign_in_flight {
                return;
            }
            up.resign_in_flight = true;
        }
        let fresh = cb().await;
        let mut up = self.upstream.lock().await;
        up.resign_in_flight = false;
        match fresh {
            Some(f) if !f.is_empty() && f != up.url => {
                up.url = f;
                up.resolved = None; // 换了签名链,旧的 302 落点一并作废,下次重新跟随
                eprintln!("[Prefetch] 上游链接失效,已重签换新地址继续拉流");
            }
            // 地址没变:链还有效,是对端/网关抖动(CF 反代 502 就长这样)。retry 即可,不停用。
            Some(f) if !f.is_empty() => {}
            // None / 空串 = 回调压根拿不到地址,停用避免刷接口。
            _ => {
                up.resign_disabled = true;
                logw("重签未拿到新地址,停用重签");
            }
        }
    }

    // 处理播放器的一次 HTTP 请求(GET/HEAD,可带 Range)。mpv 是唯一受控客户端,手写最小 HTTP/1.1。
    async fn handle(self: &Arc<Self>, mut stream: TcpStream) -> std::io::Result<()> {
        let (method, range) = read_request(&mut stream).await?;

        let (start, end) = match range {
            Some((s, e)) => {
                let s = s.min(self.total_size - 1);
                let e = e.unwrap_or(self.total_size - 1).clamp(s, self.total_size - 1);
                (s, e)
            }
            None => (0, self.total_size - 1),
        };

        // ★ 越界判定必须在**钳位之前**用原始 start:原来先 `s.min(total-1)` 再判
        // `start >= total_size`,这个分支就永远进不去(死代码),越界请求会被悄悄
        // 挪回最后一字节回一个 206 —— 播放器拿到的是"有效但错位"的数据。
        if range.is_some_and(|(s, _)| s >= self.total_size) {
            stream
                .write_all(
                    b"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await?;
            return Ok(());
        }

        let len = end - start + 1;
        let mut head = String::new();
        if range.is_some() {
            head.push_str("HTTP/1.1 206 Partial Content\r\n");
            head.push_str(&format!(
                "Content-Range: bytes {start}-{end}/{}\r\n",
                self.total_size
            ));
        } else {
            head.push_str("HTTP/1.1 200 OK\r\n");
        }
        head.push_str("Accept-Ranges: bytes\r\n");
        /* ★ 必须显式 `Connection: close`(2026-07-19 修:这就是「有流量、没画面没声音」的根因)。
           我们每条 TCP 只读**一个**请求(read_request 一次),然后在 serve() 里把 body 一直
           喂到结束。可 HTTP/1.1 默认是**长连接**,不写这个头就是在对播放器承诺"这条连接还能
           再发请求"。ffmpeg 一 seek(MKV 索引在末尾,起播必 seek;续播还要再跳一次)就把
           `Range: bytes=<末尾>-` **管线化发在同一条 socket 上** —— 那个请求没人读,响应永远
           不来。实测 ffprobe:`1 connection, 1 request, 0 seeks`,seek 静默失败后退化成**从头
           线性读完整个文件**(289MB 全下,73 段全拉),而播放器在干等 → 有流量、黑屏无声。
           声明 close 后 ffmpeg 每次 seek 老老实实新开一条连接,正好落进「每连接独立窗口」的设计。
           (真做长连接得在 handle 里循环收请求 + 复用 socket,代码多得多,而收益为零:
            seek 本来就要换窗口,换连接反而正是我们想要的语义。) */
        head.push_str("Connection: close\r\n");
        head.push_str(&format!("Content-Type: {}\r\n", self.content_type));
        head.push_str(&format!("Content-Length: {len}\r\n\r\n"));
        stream.write_all(head.as_bytes()).await?;

        if method == "HEAD" {
            return Ok(());
        }

        // 本连接自己的窗口:从本次请求起点向前顺序取,不碰其它连接。
        let first = start / CHUNK_SIZE;
        let st = Arc::new(Stream {
            origin: self.clone(),
            last_chunk: end / CHUNK_SIZE,
            first_chunk: first,
            head_within: (start - first * CHUNK_SIZE) as usize,
            head_live: std::sync::Mutex::new(None),
            state: Mutex::new(ChunkState {
                failed: HashSet::new(),
                serve_chunk: first,
                fetch_cursor: first,
                in_flight: HashSet::new(),
            }),
            data_notify: Notify::new(),
            window_notify: Notify::new(),
            done_notify: Notify::new(),
            done: AtomicBool::new(false),
        });
        for _ in 0..self.threads {
            let w = st.clone();
            tokio::spawn(async move { w.worker().await });
        }

        let r = st.serve(&mut stream, start, end).await;
        st.done.store(true, Ordering::SeqCst); // 供给结束 -> 本连接 worker 退出
        st.window_notify.notify_waiters();
        st.done_notify.notify_waiters(); // 取消在飞的 fetch(跳进度条时省流量的关键)
        r
    }
}

impl Stream {
    fn over(&self) -> bool {
        self.done.load(Ordering::SeqCst) || self.origin.closed.load(Ordering::SeqCst)
    }

    // worker:在窗口内顺序认领分段并拉取,写入就绪表。
    async fn worker(self: Arc<Self>) {
        while !self.over() {
            // 认领:窗口未满且未到本次请求末段才取下一段。
            let claim = {
                let mut st = self.state.lock().await;
                if st.fetch_cursor > self.last_chunk
                    || st.fetch_cursor > st.serve_chunk + self.origin.read_ahead_chunks - 1
                {
                    None
                } else {
                    let c = st.fetch_cursor;
                    st.fetch_cursor += 1;
                    // 已在盘上就别再下一遍(seek 回看/两条连接区间重叠时命中)。
                    if self.origin.disk.has(c).await {
                        continue;
                    }
                    st.in_flight.insert(c);
                    Some(c)
                }
            };
            let c = match claim {
                Some(c) => c,
                None => {
                    // 窗口满(mpv 读得慢 = 背压)或已取到末段:等推进,250ms 兜底防丢唤醒。
                    let _ = tokio::time::timeout(
                        Duration::from_millis(250),
                        self.window_notify.notified(),
                    )
                    .await;
                    continue;
                }
            };

            /* ★ 在飞的请求也要能取消。只靠循环顶部的 over() 判断,是「这一段拉完了才发现
               连接早没了」—— 播放器跳一次进度条,每条被丢下的连接还要把 threads 段
               (12MB)拉完才罢休,纯烧用户流量。
               notified() 必须在检查 over() **之前**注册,否则 done 恰好在两者之间置位
               就会丢掉这次唤醒,worker 卡到 fetch 自然结束。 */
            // 首段若不对齐,只拉播放器真正要的那截(残段),挂在本连接上不进共享登记处。
            let partial = c == self.first_chunk && self.head_within > 0;
            let live = if partial {
                let l = Live::based(
                    self.head_within,
                    self.origin.chunk_len(c) - self.head_within,
                );
                if let Ok(mut g) = self.head_live.lock() {
                    *g = Some(l.clone());
                }
                l
            } else {
                self.origin.live_begin(c) // 边收边吐的载体,供给端可以现读
            };
            let end_live = |live: &Arc<Live>| {
                if partial {
                    live.done.store(true, Ordering::SeqCst);
                    live.notify.notify_waiters();
                } else {
                    self.origin.live_end(c, live);
                }
            };
            let stop = self.done_notify.notified();
            if self.over() {
                end_live(&live);
                break;
            }
            let fetched = tokio::select! {
                f = self.origin.fetch_chunk(c, &live) => f,
                _ = stop => {
                    // 连接已走,注销在飞标记 + 摘牌再退出,免得残留把后来者挡住。
                    end_live(&live);
                    self.state.lock().await.in_flight.remove(&c);
                    break;
                }
            };
            // 落盘成功才算就绪;写盘失败(磁盘满/被删)等同取数失败,断流回退直连。
            // 残段**不落盘**(见 head_live 说明),取到即算成功,供给端从载体里读。
            let ok = match fetched {
                Some(_) if partial => true,
                Some(d) => self.origin.disk.put(c, d).await,
                None => false,
            };
            end_live(&live); // ★ 必须在 put 之后,别留查不到的空档
            {
                let mut st = self.state.lock().await;
                st.in_flight.remove(&c);
                if !ok {
                    st.failed.insert(c);
                }
            }
            self.data_notify.notify_waiters();
        }
    }

    // 供给推进:腾出窗口、清除已消费分段。
    async fn advance_serve(&self, next: u64) {
        {
            let mut st = self.state.lock().await;
            if next <= st.serve_chunk {
                return;
            }
            for c in st.serve_chunk..next {
                st.failed.remove(&c); // 分段数据留在盘上,seek 回看可直接命中
            }
            st.serve_chunk = next;
        }
        if next > self.first_chunk {
            // 首段已消费完,残段载体没人再读了,别让那几 MB 挂到连接结束。
            if let Ok(mut g) = self.head_live.lock() {
                *g = None;
            }
        }
        self.window_notify.notify_waiters();
    }

    /// 取分段 `c` 内、从段内偏移 `within` 起**当前拿得到**的字节(至少 1 字节)。
    /// 返回 None = 失败/停服,供给端据此断流。
    ///
    /// ★ 2026-08-02 从「等整段就绪」改成「有多少给多少」。整段就绪是**预取**该有的粒度,
    /// 不是**供给**该有的粒度 —— 见 [`Live`] 头部那笔 56~143KB/s 的账。
    async fn next_bytes(&self, c: u64, within: usize) -> Option<Vec<u8>> {
        loop {
            if self.over() {
                return None;
            }
            if self.origin.disk.has(c).await {
                let len = self.origin.chunk_len(c);
                // get 返回 None = 刚好被别的连接挤出槽位(不是取数失败),
                // 落到下面的自愈分支重拉,**不能**当失败断流 —— 那就是给播放器一个 early eof。
                if let Some(b) = self.origin.disk.get(c, len).await {
                    return b.get(within..).filter(|s| !s.is_empty()).map(<[u8]>::to_vec);
                }
            }
            /* 整段还没落盘,但它可能**正在飞** —— 已经到货的那部分立刻给播放器。
               起播只需要头几百 KB,等满 4MB 是纯粹的白等。
               先看本连接首段的残段载体(那是专为这条连接的起点拉的),再看共享登记处。 */
            let head = (c == self.first_chunk)
                .then(|| self.head_live.lock().ok().and_then(|g| g.clone()))
                .flatten();
            if let Some(live) = head.or_else(|| self.origin.live_get(c)) {
                if let Some(part) = live.slice_from(within) {
                    return Some(part);
                }
                if !live.done.load(Ordering::SeqCst) {
                    // 还在喂,等下一块到货(250ms 兜底防丢唤醒,同 data_notify 的处理)。
                    let _ =
                        tokio::time::timeout(Duration::from_millis(250), live.notify.notified())
                            .await;
                    continue;
                }
            }
            if self.state.lock().await.failed.contains(&c) {
                return None;
            }
            /* ★ 自愈:我要的这段**曾经拉过、但被挤掉了**,得重拉,不能干等。

               环形缓存是**全连接共享**的(占用恒 = 用户设的上限),槽位 = chunk % ring。
               两条连接的分段号只要模 ring 同余就落同一个槽,后写的直接盖掉先写的。
               实测口径:cache=16MB → ring=4 槽;两条连接相距 20MB = 5 段,
               A 的 chunk1 与 B 的 chunk5 同槽(5%4==1),B 一落盘 A 那段就没了。

               而 worker 认领时 `fetch_cursor` 已经自增越过 c,**再没有人会去重拉它** ——
               于是 next_bytes 在这里无限空转:has() 永远 false,又不在 failed 里。
               表现就是那条连接彻底饿死(播放器侧 = 有流量、黑屏/永远缓冲),
               或者对端超时后我们把连接关掉,客户端读到 early eof。
               这正是 concurrent_connections_do_not_starve_each_other 偶发红的真凶。

               把游标倒回 c 让 worker 重新认领即可。倒回是幂等的:已经 <= c 就不动,
               所以不会和正在飞的那次 fetch 打架;重拉一次的代价远小于饿死。 */
            {
                let mut st = self.state.lock().await;
                // 只有「没人在拉、游标又已越过」才是真被挤掉了。在飞的段老实等着。
                if st.fetch_cursor > c && !st.in_flight.contains(&c) {
                    st.fetch_cursor = c;
                    self.window_notify.notify_waiters();
                }
            }
            // 250ms 兜底重查:防丢失 notify 唤醒,无需逐段 oneshot 记账。
            let _ = tokio::time::timeout(Duration::from_millis(250), self.data_notify.notified())
                .await;
        }
    }

    /// 播放器是不是已经走了(跳进度条/退出)。
    ///
    /// ★ 光靠 `write_all` 报错是**不够及时**的:等分段的那段时间里我们根本没在写,
    /// 而那恰恰是浪费发生的时段 —— worker 正照着预取窗口一路拉。响应已声明
    /// `Connection: close`,播放器不会再往这条连接上发东西,所以「可读」只可能是
    /// 对端关闭(EOF/RST)。读到就立刻收摊。
    async fn peer_gone(stream: &TcpStream) {
        loop {
            if stream.readable().await.is_err() {
                return;
            }
            let mut b = [0u8; 1];
            match stream.try_read(&mut b) {
                Ok(0) => return,  // EOF = 对端关了
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
                Err(_) => return, // RST 等
                Ok(_) => continue, // 已声明 close,不该有;丢弃继续等
            }
        }
    }

    // 顺序把 [start,end] 喂给播放器。
    async fn serve(&self, stream: &mut TcpStream, start: u64, end: u64) -> std::io::Result<()> {
        let mut pos = start;
        while pos <= end && !self.over() {
            let c = pos / CHUNK_SIZE;
            let within = (pos - c * CHUNK_SIZE) as usize;
            let piece = tokio::select! {
                b = self.next_bytes(c, within) => match b {
                    Some(b) => b,
                    None => break, // 失败/停服 -> 断流,播放器回退 fallback
                },
                _ = Self::peer_gone(stream) => break, // 播放器跳走了,别再等也别再拉
            };
            if piece.is_empty() {
                break; // 兜底:next_bytes 保证非空,真空了也绝不能在这儿空转
            }
            let need = (end - pos + 1) as usize;
            let n = piece.len().min(need);
            // write_all 在 mpv 读慢时自然阻塞 → 端到端背压,预取停在窗口内。
            stream.write_all(&piece[..n]).await?;
            pos += n as u64;
            // 整段消费完才推进窗口(拿到的可能只是这一段的一部分)。
            if within + n >= self.origin.chunk_len(c) {
                self.advance_serve(c + 1).await;
            }
        }
        Ok(())
    }
}

/// 读 HTTP 请求头至 \r\n\r\n,返回 (method, range)。mpv 客户端行为可控,只解析所需。
async fn read_request(stream: &mut TcpStream) -> std::io::Result<(String, Option<(u64, Option<u64>)>)> {
    let mut buf = Vec::with_capacity(512);
    let mut byte = [0u8; 1];
    // 逐字节读到头尾(请求头很小),避免误吞后续连接数据。
    loop {
        let n = stream.read(&mut byte).await?;
        if n == 0 {
            break;
        }
        buf.push(byte[0]);
        if buf.len() >= 4 && &buf[buf.len() - 4..] == b"\r\n\r\n" {
            break;
        }
        if buf.len() > 16 * 1024 {
            break; // 防御:头过大直接截断
        }
    }
    let text = String::from_utf8_lossy(&buf);
    let mut lines = text.split("\r\n");
    let method = lines
        .next()
        .and_then(|l| l.split(' ').next())
        .unwrap_or("GET")
        .to_string();
    let mut range = None;
    for line in lines {
        if let Some(v) = line
            .split_once(':')
            .filter(|(k, _)| k.trim().eq_ignore_ascii_case("range"))
            .map(|(_, v)| v.trim())
        {
            range = parse_range(v);
        }
    }
    Ok((method, range))
}

/// 解析 `bytes=start-end` / `bytes=start-` / `bytes=-suffix`。这里 total 未知,-suffix 交给调用侧。
/// 返回 (start, end?);后缀范围 bytes=-N 用 u64::MAX 占位 start 由 handle 结合 total 处理不了,
/// 故此处直接对后缀返回 None 让其走全量(mpv 基本不发后缀范围)。
fn parse_range(header: &str) -> Option<(u64, Option<u64>)> {
    let spec = header.strip_prefix("bytes=")?.split(',').next()?.trim();
    let (s, e) = spec.split_once('-')?;
    let (s, e) = (s.trim(), e.trim());
    if s.is_empty() {
        return None; // 后缀范围 bytes=-N:mpv 不用,交给全量
    }
    let start = s.parse::<u64>().ok()?;
    let end = if e.is_empty() {
        None
    } else {
        Some(e.parse::<u64>().ok()?)
    };
    Some((start, end))
}

#[cfg(test)]
mod tests {
    use super::*;

    /* 两个并存的会话**绝不能共用同一个磁盘缓存文件**。
       旧名是 `s{pid}_{total}.part` —— 同一部片(total 相同)开两个会话就撞名,
       后者 `truncate(true)` 把前者的数据清零,而前者的 slots 表在内存里仍说「就绪」;
       后者再写个高位槽把文件撑长,前者读低位槽就读回一整块**稀疏零**当成有效数据发出去。

       这条是确定性的(不靠调度运气):按旧代码 `a.get(0)` 会返回一块全零并断言失败。
       线上对应场景:孤儿播放器还没 Drop、新播放器已起播(见 [[desktop-double-audio-orphan-player]]);
       CI 上对应的是 cargo test 同进程并行跑多个 TOTAL=40MB 的预取测试。 */
    #[tokio::test]
    async fn two_live_sessions_never_share_one_cache_file() {
        const TOTAL: u64 = 40 * 1024 * 1024;
        let len = CHUNK_SIZE as usize;

        let a = DiskCache::create(TOTAL, 16 * 1024 * 1024, 2).expect("建缓存 A");
        assert!(a.put(0, vec![1u8; len]).await, "A 写第 0 段");

        // 第二个会话:同一部片、同一进程,紧接着起来(旧代码在这里就把 A 的文件截断了)
        let b = DiskCache::create(TOTAL, 16 * 1024 * 1024, 2).expect("建缓存 B");
        assert_ne!(a.path, b.path, "两个并存会话拿到了同一个缓存文件名");
        // 写一个**高位**槽:把文件撑长,于是 A 的低位槽变成可读的稀疏空洞(零)
        assert!(b.put(3, vec![2u8; len]).await, "B 写第 3 段");

        // A 仍认为第 0 段就绪 —— 那它读回来的就必须是 A 自己写的那份,不能是零、更不能是 B 的
        assert!(a.has(0).await, "A 的第 0 段本来就该还在");
        let got = a.get(0, len).await.expect("A 的第 0 段读不回来");
        assert!(
            got.iter().all(|v| *v == 1),
            "A 读回的第 0 段被另一个会话污染了:全零?{} / 含 B 的字节?{} —— \
             这块数据会被原样当作视频流发给播放器",
            got.iter().all(|v| *v == 0),
            got.contains(&2)
        );
    }

    /* 预取超前窗口必须**独立于**缓存上限被兜住(2026-07-19 拆分)。
       这两件事一度共用一个值:缓存上限放开到 GB 级后,预取窗口跟着变 GB 级,
       一条连接一路狂拉几个 G,而被播放器丢下的连接正是照着这个窗口拉满才停 ——
       跳一次进度条白烧几 G 流量。缓存要多大是 DiskCache 的事,和超前量无关。
       旧公式 `MAX.min((CHUNK*t*2).max(cache_limit))` 还把上限当**下限**用,一并修掉。 */
    #[test]
    fn read_ahead_is_capped_and_respects_user_limit() {
        // 用户把缓存设成 1GB,预取窗口**不能**跟着变 1GB —— 被 MAX_READ_AHEAD 兜住。
        assert_eq!(read_ahead_bytes(3, 1024 * 1024 * 1024), MAX_READ_AHEAD);
        assert!(MAX_READ_AHEAD <= 64 * 1024 * 1024, "超前量别再往上放,大缓冲交给 mpv 自己");
        // 用户调小,就要真的小(它是天花板,不是地板)。
        assert_eq!(read_ahead_bytes(2, 16 * 1024 * 1024), 16 * 1024 * 1024);
        // 但至少给每个 worker 一段,否则 worker 抢不到活。
        assert_eq!(read_ahead_bytes(4, 1024), CHUNK_SIZE * 4);
        // 段数换算不得突破字节预算。
        for t in 2..=4 {
            for limit in [1024u64, 16 << 20, 64 << 20, 1 << 30] {
                let b = read_ahead_bytes(t, limit);
                assert!((b / CHUNK_SIZE).max(1) * CHUNK_SIZE <= MAX_READ_AHEAD, "t={t} limit={limit}");
            }
        }
    }

    /* 磁盘占用必须**封顶在用户设的上限**,不能跟着片子大小涨。
       测试服里随手就有 29.6GB 的片子,整片直存 = 把用户硬盘吃光,
       这和「内存爆掉」是同一个错误换了介质。环形复用:槽位数 = 上限/段大小。
       反向验证:把 DiskCache::create 里的 `ring` 改成 `total.div_ceil(CHUNK_SIZE)`
       (即整片直存),本测试立刻红。 */
    #[test]
    fn disk_cache_is_capped_not_proportional_to_file_size() {
        let huge = 30 * 1024 * 1024 * 1024u64; // 30GB 的片子
        let limit = 256 * 1024 * 1024; // 用户只给 256MB
        let d = DiskCache::create(huge, limit, 3).expect("该建得出");
        let on_disk = d.ring * CHUNK_SIZE;
        assert!(
            on_disk <= limit,
            "30GB 的片子占了 {}MB 盘,超出用户设的 {}MB 上限",
            on_disk / 1048576,
            limit / 1048576
        );
        // 小片子不该白占:环形不超过整片本身。
        let small = 20 * 1024 * 1024u64;
        let d2 = DiskCache::create(small, limit, 3).expect("该建得出");
        assert!(d2.ring * CHUNK_SIZE <= small + CHUNK_SIZE, "小片子不该按上限撑大");
    }

    #[test]
    fn parses_range_forms() {
        assert_eq!(parse_range("bytes=0-1023"), Some((0, Some(1023))));
        assert_eq!(parse_range("bytes=4194304-"), Some((4194304, None)));
        assert_eq!(parse_range("bytes=-500"), None); // 后缀范围走全量
        assert_eq!(parse_range("junk"), None);
        // 多区间取第一段
        assert_eq!(parse_range("bytes=0-99,200-299"), Some((0, Some(99))));
    }

    /* 端到端:代理吐的字节必须与上游逐字节相同 —— 差一个字节 mpv 就是黑屏。
       需要真网络 + 一条真实直传流,故 #[ignore],手动:
         cargo test -p linplayer-core prefetch_serves -- --ignored --nocapture
       URL 从 LP_TEST_STREAM 环境变量取(别把签名链写进仓库)。 */
    #[tokio::test]
    #[ignore]
    async fn prefetch_serves_bytes_identical_to_upstream() {
        let url = match std::env::var("LP_TEST_STREAM") {
            Ok(u) if !u.is_empty() => u,
            _ => {
                eprintln!("跳过:未设置 LP_TEST_STREAM");
                return;
            }
        };

        let h = start(url.clone(), 3, 1024 * 1024 * 1024, None)
            .await
            .expect("代理该起得来(总长 > 4MB 的真实流)");
        eprintln!("代理地址: {}", h.url);

        let cli = crate::http::client();
        // 三处取样:头部(mpv 先读头)、跨 chunk 边界、深处 seek。
        // ★ 深处 seek 的位置必须**按总长算**,不能硬编码 300MB —— 片子比它小的话
        //   (实测那部 289MB)就越界了,上游返 0 字节,测试红的是它自己不是代理。
        let deep = h.origin.total_size / 2;
        for (name, s, e) in [
            ("头部", 0u64, 65_535u64),
            ("跨4MB边界", CHUNK_SIZE - 1024, CHUNK_SIZE + 1023),
            ("深处seek", deep, deep + 65_535),
        ] {
            let rg = format!("bytes={s}-{e}");
            let up = cli.get(&url).header("Range", &rg).send().await.unwrap();
            let up_b = up.bytes().await.unwrap();
            let lo = cli.get(&h.url).header("Range", &rg).send().await.unwrap();
            let lo_status = lo.status();
            let lo_b = lo.bytes().await.unwrap();

            eprintln!("{name}: 上游 {} 字节 / 代理 {} 字节 (状态 {lo_status})", up_b.len(), lo_b.len());
            assert_eq!(lo_status.as_u16(), 206, "{name}: 代理该回 206");
            assert_eq!(lo_b.len(), up_b.len(), "{name}: 长度不一致");
            assert_eq!(lo_b, up_b, "{name}: 字节不一致 —— mpv 会黑屏");
        }
    }


    /* 回归:环形缓存把别人正在用的段挤掉后,必须**重拉**,不能干等。

       环形缓存是全连接共享的(占用恒 = 用户设的上限),槽位 = chunk % ring。
       两条连接的分段号只要模 ring 同余就落同一个槽,后写的直接盖掉先写的。
       而 worker 认领时 fetch_cursor 已经自增越过那一段,**再没人会去重拉** ——
       next_bytes 于是无限空转(has() 永远 false,又不在 failed 里),那条连接彻底饿死。
       线上表现 = 有流量、黑屏/永远缓冲;CI 上表现 = concurrent_connections_
       do_not_starve_each_other 约 5~20% 概率红(early eof 或超时)。

       这里把冲突**做成必然**而不是碰运气:
         total 16MB = 4 段;cache 8MB + threads=1 → ring = 2 槽;
         A 从 chunk0 起、B 从 chunk2 起 —— 2 % 2 == 0 % 2,
         两条连接**正在供给的那一段**直接同槽,谁后落盘谁就把对方挤掉。
       反向验证:把 next_bytes 里那段「倒回 fetch_cursor」删掉,本测试必然超时红。 */
    #[tokio::test]
    async fn evicted_chunk_is_refetched_not_awaited_forever() {
        const TOTAL: u64 = 48 * 1024 * 1024; // 12 段
        let byte_at = |i: u64| (i % 251) as u8;

        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        tokio::spawn(async move {
            loop {
                let (mut c, _) = match up.accept().await {
                    Ok(v) => v,
                    Err(_) => break,
                };
                tokio::spawn(async move {
                    let (_m, rg) = match read_request(&mut c).await {
                        Ok(v) => v,
                        Err(_) => return,
                    };
                    let (s, e) = match rg {
                        Some((s, e)) => (s, e.unwrap_or(TOTAL - 1).min(TOTAL - 1)),
                        None => (0, TOTAL - 1),
                    };
                    let body: Vec<u8> = (s..=e).map(byte_at).collect();
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {s}-{e}/{TOTAL}\r\n\
                         Content-Type: video/x-matroska\r\nContent-Length: {}\r\n\r\n",
                        body.len()
                    );
                    let _ = c.write_all(head.as_bytes()).await;
                    let _ = c.write_all(&body).await;
                });
            }
        });

        /* ring 的算法:want = max(cache/CHUNK, threads*2) = max(2, 4) = 4 槽。
           两条连接相距 4 段 → 4 % 4 == 0,B 的 chunk4 与 A 的 chunk0 直接同槽,
           往后 A(1,2) 与 B(5,6) 也各自同槽 —— 互相挤兑是**必然**,不看运气。
           ⚠️ threads 会被 start() clamp(2,4),这里写 1 会被悄悄抬成 2 而 ring 变 4,
           参数和注释就对不上了 —— 我第一版正是这样,测试拿错 ring 白跑一轮。 */
        let h = start(format!("http://127.0.0.1:{up_port}/f"), 2, 8 * 1024 * 1024, None)
            .await
            .expect("假上游给了 Content-Range,代理该起得来");

        let mut a = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        let mut b = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        a.write_all(b"GET /play HTTP/1.1\r\nRange: bytes=0-\r\n\r\n").await.unwrap();
        // B 从 chunk4(16MB)起。
        b.write_all(format!("GET /play HTTP/1.1\r\nRange: bytes={}-\r\n\r\n", 16 * 1024 * 1024).as_bytes())
            .await
            .unwrap();

        async fn skip_head(s: &mut TcpStream) {
            let mut one = [0u8; 1];
            let mut w = Vec::new();
            loop {
                s.read_exact(&mut one).await.unwrap();
                w.push(one[0]);
                if w.len() >= 4 && &w[w.len() - 4..] == b"\r\n\r\n" {
                    return;
                }
            }
        }

        tokio::time::timeout(Duration::from_secs(20), async {
            skip_head(&mut a).await;
            skip_head(&mut b).await;
            let (mut pa, mut pb) = (0u64, 16 * 1024 * 1024u64);
            let mut buf = vec![0u8; 512 * 1024];
            /* ★ 必须**跨段**读:每条连接读 12MB = 3 段。
               只在一段之内读是测不出来的 —— 一段之内供给端要么在直播载体上现读、
               要么一次就把整段从盘上取回,根本不会再去问磁盘第二次,
               槽位冲突压根碰不到(我第一版就这么写,摘掉修复照样绿)。 */
            for _ in 0..24 {
                a.read_exact(&mut buf).await.expect("A 被挤掉后没重拉 = 饿死");
                for (k, v) in buf.iter().enumerate() {
                    assert_eq!(*v, byte_at(pa + k as u64), "A 字节错位 @{}", pa + k as u64);
                }
                pa += buf.len() as u64;

                b.read_exact(&mut buf).await.expect("B 被挤掉后没重拉 = 饿死");
                for (k, v) in buf.iter().enumerate() {
                    assert_eq!(*v, byte_at(pb + k as u64), "B 字节错位 @{}", pb + k as u64);
                }
                pb += buf.len() as u64;
            }
        })
        .await
        .expect("段被环形缓存挤掉后没有重拉,连接饿死(= 线上的黑屏/永远缓冲)");
    }

    /* 回归:并发连接互不干扰 —— 这就是旧版「开了黑屏永远缓冲」的根因。
       旧版共用全局窗口 + 每请求 reset(),第二条连接一进来就把第一条正在等的分段
       从取数计划里抹掉,第一条永远等不到 body。这里起一个假上游(本地 TCP,
       按 Range 吐确定性字节),开两条错位的连接**交替**读,旧版必挂在第二次读上。
       反向验证方式:把 Stream 的窗口换回全局共享 + 每请求 reset,此测试会超时红。 */
    #[tokio::test]
    async fn concurrent_connections_do_not_starve_each_other() {
        // 确定性内容:第 i 个字节 = (i % 251)。
        const TOTAL: u64 = 40 * 1024 * 1024;
        let byte_at = |i: u64| (i % 251) as u8;

        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        tokio::spawn(async move {
            loop {
                let (mut c, _) = match up.accept().await {
                    Ok(v) => v,
                    Err(_) => break,
                };
                tokio::spawn(async move {
                    let (_m, rg) = match read_request(&mut c).await {
                        Ok(v) => v,
                        Err(_) => return,
                    };
                    let (s, e) = match rg {
                        Some((s, e)) => (s, e.unwrap_or(TOTAL - 1).min(TOTAL - 1)),
                        None => (0, TOTAL - 1),
                    };
                    let body: Vec<u8> = (s..=e).map(byte_at).collect();
                    let head = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {s}-{e}/{TOTAL}\r\n\
                         Content-Type: video/x-matroska\r\nContent-Length: {}\r\n\r\n",
                        body.len()
                    );
                    let _ = c.write_all(head.as_bytes()).await;
                    let _ = c.write_all(&body).await;
                });
            }
        });

        let h = start(format!("http://127.0.0.1:{up_port}/f"), 2, 16 * 1024 * 1024, None)
            .await
            .expect("假上游给了 Content-Range,代理该起得来");

        // 两条连接错位并存:A 从 0 起,B 从 20MB 起(模拟 mpv 探 MKV 时旧连接没关就新开)。
        let mut a = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        let mut b = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        a.write_all(b"GET /play HTTP/1.1\r\nRange: bytes=0-\r\n\r\n").await.unwrap();
        b.write_all(format!("GET /play HTTP/1.1\r\nRange: bytes={}-\r\n\r\n", 20 * 1024 * 1024).as_bytes())
            .await
            .unwrap();

        // 交替读:每条都必须能持续拿到**自己**位置的正确字节。
        async fn skip_head(s: &mut TcpStream) {
            let mut one = [0u8; 1];
            let mut w = Vec::new();
            loop {
                s.read_exact(&mut one).await.unwrap();
                w.push(one[0]);
                if w.len() >= 4 && &w[w.len() - 4..] == b"\r\n\r\n" {
                    return;
                }
            }
        }
        tokio::time::timeout(Duration::from_secs(10), async {
            skip_head(&mut a).await;
            skip_head(&mut b).await;
            let (mut pa, mut pb) = (0u64, 20 * 1024 * 1024u64);
            let mut buf = vec![0u8; 64 * 1024];
            for _ in 0..24 {
                a.read_exact(&mut buf).await.unwrap();
                for (k, v) in buf.iter().enumerate() {
                    assert_eq!(*v, byte_at(pa + k as u64), "A 连接字节错位 @{}", pa + k as u64);
                }
                pa += buf.len() as u64;

                b.read_exact(&mut buf).await.unwrap();
                for (k, v) in buf.iter().enumerate() {
                    assert_eq!(*v, byte_at(pb + k as u64), "B 连接字节错位 @{}", pb + k as u64);
                }
                pb += buf.len() as u64;
            }
        })
        .await
        .expect("并发连接互相饿死 = 旧版的黑屏/永远缓冲");
    }

    /* 重签策略：只有「回调拿不到地址」才能停用重签。
       开了 CF 优选时上游是本机反代，它一个 502（CF 那头抖一下）就会触发重签，
       而重签当然还是解析出同一个 127.0.0.1 地址。旧逻辑把这当成失败并永久停用重签，
       等真的签名过期时就没人能换地址了 → 断流。
       反向验证：把 `Some(f) if !f.is_empty() => {}` 这条删掉（回到旧的 `_ =>`），
       same_url_does_not_disable_resign 立刻红。 */
    /* 顺序加载(观影软件的硬要求):并发只用来把**窗口内**的段提前拉回来,
       取数本身必须是向前顺序的 —— 不跳着下、不重复下。
       本测试跑完整一遍读取,断言上游收到的分段请求**恰好**是 0..=末段、每段一次:
         - 有重复 → 白费带宽(用户流量/服务器压力);
         - 有缺口/乱序覆盖 → 就不是顺序加载了。
       同时断言任一时刻的取数超前量不超过读前窗口(靠 serve 消费推进,而非无限狂拉)。 */
    #[tokio::test]
    async fn fetches_sequentially_without_duplicates() {
        use std::collections::BTreeSet;
        use std::sync::Mutex as StdMutex;

        const TOTAL: u64 = 40 * 1024 * 1024; // 10 段
        let seen: Arc<StdMutex<Vec<u64>>> = Arc::new(StdMutex::new(Vec::new()));

        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        let seen_srv = seen.clone();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = up.accept().await {
                let seen_c = seen_srv.clone();
                tokio::spawn(async move {
                    let (_m, rg) = match read_request(&mut c).await {
                        Ok(v) => v,
                        Err(_) => return,
                    };
                    let (s, e) = match rg {
                        Some((s, e)) => (s, e.unwrap_or(TOTAL - 1).min(TOTAL - 1)),
                        None => (0, TOTAL - 1),
                    };
                    // 只记真正的取数请求,探大小的 bytes=0-0 不算。
                    if e > s {
                        seen_c.lock().unwrap().push(s / CHUNK_SIZE);
                    }
                    let body = vec![0u8; (e - s + 1) as usize];
                    let nl = String::from_utf8(vec![13, 10]).unwrap();
                    let head = format!(
                        "HTTP/1.1 206 Partial Content{nl}\
                         Content-Range: bytes {s}-{e}/{TOTAL}{nl}\
                         Content-Type: video/mp4{nl}\
                         Content-Length: {}{nl}{nl}",
                        body.len()
                    );
                    let _ = c.write_all(head.as_bytes()).await;
                    let _ = c.write_all(&body).await;
                });
            }
        });

        let h = start(format!("http://127.0.0.1:{up_port}/f"), 3, 16 * 1024 * 1024, None)
            .await
            .expect("代理该起得来");

        let mut cli = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        let nl = String::from_utf8(vec![13, 10]).unwrap();
        cli.write_all(format!("GET /play HTTP/1.1{nl}Range: bytes=0-{nl}{nl}").as_bytes())
            .await
            .unwrap();

        /* ★ 读错误必须**带出来**,不能 `Err(_) => break`。
           吞掉它的话,「流被提前掐断」和「正常读完」在结果上长得一模一样,
           只剩一个短掉的字节数,查都没法查。2026-07-19 CI 上就是这么栽的。 */
        let (got, read_err) = tokio::time::timeout(Duration::from_secs(30), async {
            let mut total = 0usize;
            let mut buf = vec![0u8; 64 * 1024];
            let mut err = None;
            loop {
                match cli.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => total += n,
                    Err(e) => {
                        err = Some(e.to_string());
                        break;
                    }
                }
            }
            (total, err)
        })
        .await
        .expect("整片读完不该超时");

        let v = seen.lock().unwrap().clone();
        let uniq: BTreeSet<u64> = v.iter().copied().collect();
        let last = (TOTAL - 1) / CHUNK_SIZE;

        assert_eq!(v.len(), uniq.len(), "有分段被重复下载:{v:?}");
        assert_eq!(
            uniq,
            (0..=last).collect::<BTreeSet<u64>>(),
            "取数不是覆盖 0..={last} 的顺序全集:{uniq:?}"
        );
        // 认领顺序必须单调向前(fetch_cursor 只增)。并发下到达顺序可能微乱,
        // 故按「任意时刻的超前量」判定:任一请求都不该超出窗口太多。
        let window = read_ahead_bytes(3, 16 * 1024 * 1024) / CHUNK_SIZE;
        for (i, c) in v.iter().enumerate() {
            assert!(
                *c <= i as u64 + window,
                "第 {i} 个请求跳到了段 {c},超出窗口 {window} = 不是顺序预取"
            );
        }
        /* got 是裸 socket 收到的字节,含响应头(约 150 字节),故比对时留出头部余量。
           ★ 先断言再做减法。反过来写(`let body = got - TOTAL;` 放在断言前)的话,
             收短了就是 u64 下溢 panic —— debug 下只剩一句
             `attempt to subtract with overflow`,把「实收多少、错在哪」全毁了。
             断言的价值在于失败时说人话,不是在于它存在。 */
        let short_by = TOTAL.saturating_sub(got as u64);
        assert!(
            got as u64 > TOTAL,
            "流被提前掐断:实收 {got} 字节,比整片 {TOTAL} 少了 {short_by};\
             读取错误={read_err:?};已取分段={uniq:?}"
        );
        assert!(
            got as u64 - TOTAL < 1024,
            "多收了 {} 字节,响应头不该这么大",
            got as u64 - TOTAL
        );
    }

    /* 上游返回【短于请求量】的分段时，绝不能挂死。
       旧逻辑：fetch_chunk 只要 body 非空就收下 → serve 写完这 L 字节后 advance_serve(c+1)
       把它从 ready 删掉，可 pos 仍在分段 c 内 → 下一轮又去 next_bytes(c)，
       而 fetch_cursor 早过了 c，永远没人重拉 → **永远缓冲**（和用户报的症状一模一样）。
       修后：长度对不上 = 可重试，重试用尽就标失败 → 断流，播放器回退直连。
       反向验证：把 fetch_chunk 里的长度校验去掉，本测试立刻挂死超时红。 */
    #[tokio::test]
    async fn short_upstream_chunk_breaks_stream_instead_of_hanging() {
        const TOTAL: u64 = 40 * 1024 * 1024;
        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = up.accept().await {
                tokio::spawn(async move {
                    let (_m, rg) = match read_request(&mut c).await {
                        Ok(v) => v,
                        Err(_) => return,
                    };
                    let (s, e) = match rg {
                        Some((s, e)) => (s, e.unwrap_or(TOTAL - 1).min(TOTAL - 1)),
                        None => (0, TOTAL - 1),
                    };
                    // 探大小的 bytes=0-0 必须诚实，否则代理压根起不来。
                    let full = e - s + 1;
                    let n = if full <= 1 { full } else { full / 4 }; // 其余一律只给 1/4
                    let body = vec![7u8; n as usize];
                    // CRLF 用字节构造:本文件里直接写转义序列会被工具链吃掉反斜杠。
                    let nl = String::from_utf8(vec![13, 10]).unwrap();
                    let head = format!(
                        "HTTP/1.1 206 Partial Content{nl}\
                         Content-Range: bytes {s}-{e}/{TOTAL}{nl}\
                         Content-Type: video/mp4{nl}\
                         Content-Length: {}{nl}{nl}",
                        body.len()
                    );
                    let _ = c.write_all(head.as_bytes()).await;
                    let _ = c.write_all(&body).await;
                });
            }
        });

        let h = start(format!("http://127.0.0.1:{up_port}/f"), 2, 16 * 1024 * 1024, None)
            .await
            .expect("探测阶段拿得到 Content-Range，代理该起得来");

        let mut cli = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        let nl = String::from_utf8(vec![13, 10]).unwrap();
        cli.write_all(format!("GET /play HTTP/1.1{nl}Range: bytes=0-{nl}{nl}").as_bytes())
            .await
            .unwrap();

        // 不论成功与否，必须在有限时间内**结束**（EOF），不能无限挂住。
        let r = tokio::time::timeout(Duration::from_secs(20), async {
            let mut sink = Vec::new();
            let mut buf = vec![0u8; 32 * 1024];
            loop {
                match cli.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => sink.extend_from_slice(&buf[..n]),
                    Err(_) => break,
                }
            }
            sink.len()
        })
        .await;
        assert!(r.is_ok(), "上游给短包时挂死了 = 用户报的「永远缓冲」");
    }

    /* ★ 这次改造(2026-08-02「边收边吐」)的唯一验收判据。

       用户症状:开了多线程加载就没画面没声音,直连反而秒开。根因不是 bug 是粒度 ——
       供给端要等**整段 4MB** 落盘才吐第一个字节,而 mpv 起播只要头几百 KB。
       实测那条链 56~143KB/s,一段 4MB 合法地要 29~62 秒,于是「永远加载不出来」。

       这里的假上游把每个分段**匀速滴**出来(40 块 × 150ms = 一段要 6 秒),
       断言前 256KB 必须在 2.5 秒内到 —— 也就是「还没收满一段就得开始吐」。
       反向注入(把 next_bytes 改回只认 disk.has、删掉 live 分支)此测试必红:
       第一个字节要等满 6 秒。
       顺带**逐字节校验内容**:边收边吐最容易错的地方就是重试续接(Live::feed 的 skip),
       错了就是错帧,而错帧不报错、只是画面坏掉。 */
    #[tokio::test]
    async fn first_bytes_reach_the_player_before_the_whole_chunk_arrives() {
        const TOTAL: u64 = 40 * 1024 * 1024;
        const PIECES: usize = 40;
        const GAP_MS: u64 = 150; // 一段 4MB 要 40*150ms = 6 秒
        let byte_at = |i: u64| (i % 251) as u8;

        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = up.accept().await {
                tokio::spawn(async move {
                    let (_m, rg) = match read_request(&mut c).await {
                        Ok(v) => v,
                        Err(_) => return,
                    };
                    let (s, e) = match rg {
                        Some((s, e)) => (s, e.unwrap_or(TOTAL - 1).min(TOTAL - 1)),
                        None => (0, TOTAL - 1),
                    };
                    let len = e - s + 1;
                    let nl = String::from_utf8(vec![13, 10]).unwrap();
                    let head = format!(
                        "HTTP/1.1 206 Partial Content{nl}\
                         Content-Range: bytes {s}-{e}/{TOTAL}{nl}\
                         Content-Type: video/mp4{nl}\
                         Content-Length: {len}{nl}{nl}"
                    );
                    if c.write_all(head.as_bytes()).await.is_err() {
                        return;
                    }
                    // 探大小的 bytes=0-0 不用滴,一次给完(否则代理起不来)。
                    let pieces = if len <= 1 { 1 } else { PIECES };
                    let per = len.div_ceil(pieces as u64);
                    let mut off = 0u64;
                    while off < len {
                        let n = per.min(len - off);
                        let body: Vec<u8> =
                            (0..n).map(|k| byte_at(s + off + k)).collect();
                        if c.write_all(&body).await.is_err() {
                            return;
                        }
                        off += n;
                        if off < len {
                            tokio::time::sleep(Duration::from_millis(GAP_MS)).await;
                        }
                    }
                });
            }
        });

        let h = start(format!("http://127.0.0.1:{up_port}/f"), 2, 32 * 1024 * 1024, None)
            .await
            .expect("探测该成功");

        let mut cli = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        let t0 = std::time::Instant::now();
        cli.write_all(b"GET /play HTTP/1.1\r\nRange: bytes=0-\r\n\r\n")
            .await
            .unwrap();

        let mut one = [0u8; 1];
        let mut w = Vec::new();
        loop {
            cli.read_exact(&mut one).await.unwrap();
            w.push(one[0]);
            if w.len() >= 4 && &w[w.len() - 4..] == b"\r\n\r\n" {
                break;
            }
        }
        let mut got = vec![0u8; 256 * 1024];
        cli.read_exact(&mut got).await.expect("前 256KB 该读得到");
        let dt = t0.elapsed();

        for (k, v) in got.iter().enumerate() {
            assert_eq!(*v, byte_at(k as u64), "边收边吐把字节喂错位了 @{k}");
        }
        assert!(
            dt < Duration::from_millis(2500),
            "前 256KB 花了 {:.1}s —— 供给端还在等整段 4MB(要 {:.1}s)才吐,\
             这正是用户报的「开了多线程加载就加载不出来」",
            dt.as_secs_f32(),
            (PIECES as u64 * GAP_MS) as f32 / 1000.0
        );
    }

    /* ★ 边收边吐带来的**新风险**,必须有门禁:重试时的字节续接。

       改造前每次 attempt 都用一个全新的 buf,重试天然干净。改造后 buf 是「直播缓冲」,
       上一轮收到的字节**可能已经吐给播放器了**,收不回来 —— 所以重试必须从断点续,
       既不能重复追加(那是错帧),也不能从头重来(那是重复吐)。

       这里的假上游对 chunk 0 的**第一次**请求只吐一半就断,之后正常。
       反向注入(把 Live::feed 里的 skip 逻辑删掉,来的字节一律 extend)此测试必红:
       第 2MB 之后会变成「第 0MB 起的内容又来一遍」—— 而错帧**不报错**,只是画面坏掉,
       正是最难查的那一类。 */
    #[tokio::test]
    async fn retry_after_partial_body_resumes_instead_of_duplicating() {
        const TOTAL: u64 = 40 * 1024 * 1024;
        let byte_at = |i: u64| (i % 251) as u8;
        let truncated = Arc::new(AtomicBool::new(false));

        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = up.accept().await {
                let flag = truncated.clone();
                tokio::spawn(async move {
                    let (_m, rg) = match read_request(&mut c).await {
                        Ok(v) => v,
                        Err(_) => return,
                    };
                    let (s, e) = match rg {
                        Some((s, e)) => (s, e.unwrap_or(TOTAL - 1).min(TOTAL - 1)),
                        None => (0, TOTAL - 1),
                    };
                    let len = e - s + 1;
                    let nl = String::from_utf8(vec![13, 10]).unwrap();
                    let head = format!(
                        "HTTP/1.1 206 Partial Content{nl}\
                         Content-Range: bytes {s}-{e}/{TOTAL}{nl}\
                         Content-Type: video/mp4{nl}\
                         Content-Length: {len}{nl}{nl}"
                    );
                    if c.write_all(head.as_bytes()).await.is_err() {
                        return;
                    }
                    let body: Vec<u8> = (0..len).map(|k| byte_at(s + k)).collect();
                    // 第 0 段的第一次请求:只吐一半就断(声明的长度不变 = 半截身子)。
                    let cut = s == 0 && len > 1 && !flag.swap(true, Ordering::SeqCst);
                    let n = if cut { body.len() / 2 } else { body.len() };
                    let _ = c.write_all(&body[..n]).await;
                });
            }
        });

        let h = start(format!("http://127.0.0.1:{up_port}/f"), 2, 32 * 1024 * 1024, None)
            .await
            .expect("探测该成功");

        let mut cli = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        cli.write_all(b"GET /play HTTP/1.1\r\nRange: bytes=0-\r\n\r\n")
            .await
            .unwrap();
        let mut one = [0u8; 1];
        let mut w = Vec::new();
        loop {
            cli.read_exact(&mut one).await.unwrap();
            w.push(one[0]);
            if w.len() >= 4 && &w[w.len() - 4..] == b"\r\n\r\n" {
                break;
            }
        }
        // 跨过被截断的那一段(4MB)再多读 2MB,确保续接点前后都验到。
        let mut got = vec![0u8; 6 * 1024 * 1024];
        tokio::time::timeout(Duration::from_secs(30), cli.read_exact(&mut got))
            .await
            .expect("半截身子后没能续上 = 卡死")
            .expect("半截身子后没能续上 = 断流");
        for (k, v) in got.iter().enumerate() {
            assert_eq!(*v, byte_at(k as u64), "重试没有从断点续,字节错位 @{k}");
        }
    }

    /* ★ seek 之后的白等(2026-08-02 第二刀)。

       响应声明 Connection: close,所以播放器**每 seek 一次就是一条新连接**
       (MKV 起播必跳尾部 cues,换集/拖进度条同理)。而连接起点几乎不可能正好落在
       4MB 边界上:从边界开拉 = 在播放器要的第一个字节前面先白拉平均 2MB。
       用户那条链 150KB/s → 每拖一次进度条画面 13 秒不动。

       这里假上游**恒速**滴(128KB / 150ms ≈ 850KB/s),客户端从 3MB 处开读:
       - 修好了:上游只被要 [3MB, 4MB),2 块就够吐出 256KB → 约 0.3 秒;
       - 没修:上游被要 [0, 4MB),得先滴过 3MB(24 块 ≈ 3.6 秒)播放器才见到第一个字节。
       断言分两条:上游**实际收到的 Range 起点**(确定性,不看机器负载)+ 端到端耗时。
       反向注入(worker 里把 partial 判定改成恒 false)两条都红。 */
    #[tokio::test]
    async fn seek_does_not_wait_for_the_bytes_before_it() {
        const TOTAL: u64 = 40 * 1024 * 1024;
        const AT: u64 = 3 * 1024 * 1024; // 落在 chunk 0 的 3/4 处
        let byte_at = |i: u64| (i % 251) as u8;
        let seen: Arc<Mutex<Vec<u64>>> = Arc::new(Mutex::new(Vec::new()));

        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        let seen_srv = seen.clone();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = up.accept().await {
                let seen = seen_srv.clone();
                tokio::spawn(async move {
                    let (_m, rg) = match read_request(&mut c).await {
                        Ok(v) => v,
                        Err(_) => return,
                    };
                    let (s, e) = match rg {
                        Some((s, e)) => (s, e.unwrap_or(TOTAL - 1).min(TOTAL - 1)),
                        None => (0, TOTAL - 1),
                    };
                    let len = e - s + 1;
                    if len > 1 {
                        seen.lock().await.push(s); // 探大小的 bytes=0-0 不计
                    }
                    let nl = String::from_utf8(vec![13, 10]).unwrap();
                    let head = format!(
                        "HTTP/1.1 206 Partial Content{nl}\
                         Content-Range: bytes {s}-{e}/{TOTAL}{nl}\
                         Content-Type: video/mp4{nl}\
                         Content-Length: {len}{nl}{nl}"
                    );
                    if c.write_all(head.as_bytes()).await.is_err() {
                        return;
                    }
                    // 恒速:每块 128KB,块间 150ms —— 耗时正比于**字节数**,才测得出白等。
                    let mut off = 0u64;
                    while off < len {
                        let n = (128 * 1024u64).min(len - off);
                        let body: Vec<u8> = (0..n).map(|k| byte_at(s + off + k)).collect();
                        if c.write_all(&body).await.is_err() {
                            return;
                        }
                        off += n;
                        if off < len {
                            tokio::time::sleep(Duration::from_millis(150)).await;
                        }
                    }
                });
            }
        });

        let h = start(format!("http://127.0.0.1:{up_port}/f"), 2, 32 * 1024 * 1024, None)
            .await
            .expect("探测该成功");

        let mut cli = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        let t0 = std::time::Instant::now();
        cli.write_all(format!("GET /play HTTP/1.1\r\nRange: bytes={AT}-\r\n\r\n").as_bytes())
            .await
            .unwrap();
        let mut one = [0u8; 1];
        let mut w = Vec::new();
        loop {
            cli.read_exact(&mut one).await.unwrap();
            w.push(one[0]);
            if w.len() >= 4 && &w[w.len() - 4..] == b"\r\n\r\n" {
                break;
            }
        }
        let mut got = vec![0u8; 256 * 1024];
        cli.read_exact(&mut got).await.expect("该读得到");
        let dt = t0.elapsed();

        for (k, v) in got.iter().enumerate() {
            assert_eq!(*v, byte_at(AT + k as u64), "seek 后字节错位 @{}", AT + k as u64);
        }
        let starts = seen.lock().await.clone();
        assert!(
            starts.contains(&AT),
            "上游从没被要过 {AT} 起的数据(实际:{starts:?}) —— \
             说明首段还是从 4MB 边界开拉,播放器要的字节前面压着 3MB 白拉的量"
        );
        assert!(
            dt < Duration::from_millis(2000),
            "seek 后首批 256KB 花了 {:.1}s —— 白等了它前面那 3MB",
            dt.as_secs_f32()
        );
    }

    fn origin_with(cb: Option<ResignFn>) -> Origin {
        Origin {
            upstream: Mutex::new(UpstreamState {
                url: "http://127.0.0.1:1/s".into(),
                resolved: None,
                resign_disabled: false,
                resign_in_flight: false,
            }),
            total_size: 100 * CHUNK_SIZE,
            content_type: "video/mp4".into(),
            threads: 2,
            read_ahead_chunks: 4,
            closed: AtomicBool::new(false),
            client: crate::http::preload_client(),
            on_invalid: cb,
            live: Default::default(),
            disk: DiskCache::create(100 * CHUNK_SIZE, 32 * 1024 * 1024, 2)
                .expect("测试环境该建得出缓存文件"),
        }
    }

    fn resign_returning(v: Option<&'static str>) -> ResignFn {
        Arc::new(move || Box::pin(async move { v.map(|s| s.to_string()) }))
    }

    #[tokio::test]
    async fn same_url_does_not_disable_resign() {
        let o = origin_with(Some(resign_returning(Some("http://127.0.0.1:1/s"))));
        o.refresh_upstream().await;
        let up = o.upstream.lock().await;
        assert!(!up.resign_disabled, "same url = gateway hiccup (CF 502); must NOT disable resign");
        assert_eq!(up.url, "http://127.0.0.1:1/s");
    }

    #[tokio::test]
    async fn new_url_is_adopted_and_none_disables() {
        let o = origin_with(Some(resign_returning(Some("http://127.0.0.1:2/fresh"))));
        o.refresh_upstream().await;
        assert_eq!(o.upstream.lock().await.url, "http://127.0.0.1:2/fresh");

        let o2 = origin_with(Some(resign_returning(None)));
        o2.refresh_upstream().await;
        assert!(o2.upstream.lock().await.resign_disabled, "no url from callback = disable resign");
    }

    /* 起一个假上游 + 一条真连接,返回响应头文本。 */
    async fn head_of_first_response(range: &str) -> String {
        const TOTAL: u64 = 40 * 1024 * 1024;
        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = up.accept().await {
                tokio::spawn(async move {
                    let (_m, rg) = match read_request(&mut c).await {
                        Ok(v) => v,
                        Err(_) => return,
                    };
                    let (s, e) = match rg {
                        Some((s, e)) => (s, e.unwrap_or(TOTAL - 1).min(TOTAL - 1)),
                        None => (0, TOTAL - 1),
                    };
                    let body = vec![0u8; (e - s + 1) as usize];
                    let nl = String::from_utf8(vec![13, 10]).unwrap();
                    let head = format!(
                        "HTTP/1.1 206 Partial Content{nl}Content-Range: bytes {s}-{e}/{TOTAL}{nl}Content-Type: video/x-matroska{nl}Content-Length: {}{nl}{nl}",
                        body.len()
                    );
                    let _ = c.write_all(head.as_bytes()).await;
                    let _ = c.write_all(&body).await;
                });
            }
        });
        let h = start(format!("http://127.0.0.1:{up_port}/f"), 2, 16 * 1024 * 1024, None)
            .await
            .expect("代理该起得来");
        let mut cli = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        let nl = String::from_utf8(vec![13, 10]).unwrap();
        cli.write_all(format!("GET /play HTTP/1.1{nl}Range: {range}{nl}{nl}").as_bytes())
            .await
            .unwrap();
        let mut w = Vec::new();
        let mut one = [0u8; 1];
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if cli.read_exact(&mut one).await.is_err() {
                    return;
                }
                w.push(one[0]);
                // CRLFCRLF 用字节构造:本文件里直接写转义序列会被工具链吃掉反斜杠。
                if w.len() >= 4 && w[w.len() - 4..] == [13u8, 10, 13, 10] {
                    return;
                }
            }
        })
        .await
        .expect("读响应头不该超时");
        String::from_utf8_lossy(&w).to_string()
    }

    /* 回归:响应必须声明 `Connection: close`。
       我们每条 TCP 只读一个请求,而 HTTP/1.1 默认长连接 —— 不声明 close 就是在骗播放器
       "还能再发"。ffmpeg 一 seek 就把下一个 Range 管线化发在同一条 socket 上,没人读、
       响应不来 → seek 静默失败,退化成从头线性读完整个文件 = 用户报的「有流量没画面没声音」。
       反向验证:把 handle() 里那行 `head.push_str("Connection: close

")` 删掉,本测试立刻红。 */
    #[tokio::test]
    async fn response_declares_connection_close() {
        let head = head_of_first_response("bytes=0-").await;
        assert!(
            head.to_ascii_lowercase().contains("connection: close"),
            "没声明 Connection: close,播放器会把 seek 请求管线化到同一条连接上永远等不到响应
{head}"
        );
    }

    /* 回归:越界 Range 必须回 416,不能钳回最后一字节假装 206。
       原来先 `s.min(total-1)` 再判 `start >= total_size`,判定永远为假 = 死代码。
       反向验证:把 handle() 里的越界判定改回用钳位后的 start,本测试立刻红。 */
    #[tokio::test]
    async fn out_of_range_start_gets_416_not_bogus_206() {
        let head = head_of_first_response("bytes=99999999999-").await;
        assert!(head.starts_with("HTTP/1.1 416"), "越界 Range 该回 416,实得:
{head}");
    }

    /* 回归:上游**不支持 Range** 时必须起服失败(返 None),让调用方回退直连。
       实测(2026-07-19)原版 Emby(mecf.mebimmer.de)对 Static=true 直传流完整支持 Range:
       206 + Content-Range + Accept-Ranges,4MB 分段一字不差 —— 所以这条路本身是普适的。
       但万一碰上忽略 Range 的服务端(自建反代/某些 fork),代理**绝不能**硬上:
       没有 Content-Range 就拿不到 total,分段定位全错,喂给播放器就是黑屏。
       此处用「回 200 且不给 Content-Range」的假上游守住这个降级。
       反向验证:把 probe 里的 `if total <= CHUNK_SIZE { return None }` 去掉,本测试立刻红。 */
    #[tokio::test]
    async fn upstream_without_range_support_refuses_to_start() {
        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = up.accept().await {
                tokio::spawn(async move {
                    if read_request(&mut c).await.is_err() {
                        return;
                    }
                    // 忽略 Range:回 200 全量,**不给 Content-Range**(不支持 Range 的服务端就长这样)。
                    let body = vec![0u8; 4096];
                    let nl = String::from_utf8(vec![13, 10]).unwrap();
                    let head = format!(
                        "HTTP/1.1 200 OK{nl}Content-Type: video/mp4{nl}Content-Length: {}{nl}{nl}",
                        body.len()
                    );
                    let _ = c.write_all(head.as_bytes()).await;
                    let _ = c.write_all(&body).await;
                });
            }
        });
        let h = start(format!("http://127.0.0.1:{up_port}/f"), 3, 16 * 1024 * 1024, None).await;
        assert!(
            h.is_none(),
            "上游不支持 Range 却把代理起起来了 —— 分段定位必然错位,播放器直接黑屏;             正确行为是返 None 让调用方回退直连在线地址"
        );
    }

    /* 回归:上游 302 跳 CDN 时,重定向**只能走一次**(探测那次),不能每段重走。
       UHD 那类服务端(v1.uhdnow.com)的直传流就是 302 跳 CDN,实测每次重定向 0.67s,
       占单段 TTFB 的一半 —— 每 4MB 重走一遍的话,3 线程(4.0MB/s)反而慢于
       单连接(4.3MB/s),多线程加载直接变负优化。
       此处假上游:/redir 一律 302 到 /real,统计 /redir 被打的次数。
       反向验证:把 fetch_chunk 里的 `up.resolved` 分支去掉(恒用 up.url),
       /redir 会被打成「段数+1」次,本测试立刻红。 */
    #[tokio::test]
    async fn follows_redirect_once_not_per_chunk() {
        use std::sync::atomic::AtomicUsize;

        const TOTAL: u64 = 40 * 1024 * 1024; // 10 段
        let redir_hits = Arc::new(AtomicUsize::new(0));

        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        let hits = redir_hits.clone();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = up.accept().await {
                let hits = hits.clone();
                tokio::spawn(async move {
                    // 需要看路径,自己读一遍请求行(read_request 只回 method/range)。
                    let mut buf = Vec::new();
                    let mut one = [0u8; 1];
                    loop {
                        match c.read(&mut one).await {
                            Ok(0) | Err(_) => return,
                            Ok(_) => {}
                        }
                        buf.push(one[0]);
                        if buf.len() >= 4 && buf[buf.len() - 4..] == [13u8, 10, 13, 10] {
                            break;
                        }
                    }
                    let text = String::from_utf8_lossy(&buf).to_string();
                    let path = text.split(' ').nth(1).unwrap_or("/").to_string();
                    let nl = String::from_utf8(vec![13, 10]).unwrap();

                    if path.starts_with("/redir") {
                        hits.fetch_add(1, Ordering::SeqCst);
                        let loc = format!("http://127.0.0.1:{up_port}/real");
                        let head = format!(
                            "HTTP/1.1 302 Found{nl}Location: {loc}{nl}Content-Length: 0{nl}{nl}"
                        );
                        let _ = c.write_all(head.as_bytes()).await;
                        return;
                    }
                    // /real:正常 206
                    let rg = text
                        .lines()
                        .find(|l| l.to_ascii_lowercase().starts_with("range:"))
                        .and_then(|l| parse_range(l[6..].trim()));
                    let (s, e) = match rg {
                        Some((s, e)) => (s, e.unwrap_or(TOTAL - 1).min(TOTAL - 1)),
                        None => (0, TOTAL - 1),
                    };
                    let body = vec![0u8; (e - s + 1) as usize];
                    let head = format!(
                        "HTTP/1.1 206 Partial Content{nl}Content-Range: bytes {s}-{e}/{TOTAL}{nl}Content-Type: video/mp4{nl}Content-Length: {}{nl}{nl}",
                        body.len()
                    );
                    let _ = c.write_all(head.as_bytes()).await;
                    let _ = c.write_all(&body).await;
                });
            }
        });

        let h = start(format!("http://127.0.0.1:{up_port}/redir"), 3, 16 * 1024 * 1024, None)
            .await
            .expect("跟随 302 后拿得到 Content-Range,代理该起得来");

        let mut cli = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        let nl = String::from_utf8(vec![13, 10]).unwrap();
        cli.write_all(format!("GET /play HTTP/1.1{nl}Range: bytes=0-{nl}{nl}").as_bytes())
            .await
            .unwrap();
        let _ = tokio::time::timeout(Duration::from_secs(30), async {
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                match cli.read(&mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
            }
        })
        .await;

        let n = redir_hits.load(Ordering::SeqCst);
        assert_eq!(
            n, 1,
            "302 被重走了 {n} 次(该只有探测那一次)—— 每段重定向会把多线程的收益全部赔光"
        );
    }

    /* 回归:播放器**抛弃连接**(跳进度条 = 每次 seek 开新连接、丢旧连接)后,
       旧连接必须**立刻停止拉取**,不能照着预取窗口把量拉满。
       修之前:断开后 3 秒内还会继续取 6 段(24MB);而预取窗口跟着缓存上限
       放开到 GB 级之后,同一个洞会变成白拉几个 G —— 跳一次进度条烧掉用户几 G 流量。
       修法两层:serve 等分段时用 peer_gone 感知断开;worker 用 done_notify 取消在飞的请求。
       反向验证(两层缺一都红,已各自验过):去掉 serve 的 peer_gone 分支 -> 漏 12544KB;
       去掉 worker 的 stop 分支 -> 漏 12288KB(正好 3 个 worker 各一段在飞)。
       ★ 口径必须按**字节**而不是请求数:在飞取消发生在请求已发出之后,省的是剩余传输,
       按请求数计的话 worker 那层怎么改都是绿的(踩过这个坑)。 */
    #[tokio::test]
    async fn abandoned_connection_stops_fetching_immediately() {
        use std::sync::atomic::AtomicUsize;
        const TOTAL: u64 = 400 * 1024 * 1024;
        let fetches = Arc::new(AtomicUsize::new(0));

        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        let f = fetches.clone();
        tokio::spawn(async move {
            while let Ok((mut c, _)) = up.accept().await {
                let f = f.clone();
                tokio::spawn(async move {
                    let (_m, rg) = match read_request(&mut c).await {
                        Ok(v) => v,
                        Err(_) => return,
                    };
                    let (s, e) = match rg {
                        Some((s, e)) => (s, e.unwrap_or(TOTAL - 1).min(TOTAL - 1)),
                        None => (0, TOTAL - 1),
                    };
                    let len = (e - s + 1) as usize;
                    let nl = String::from_utf8(vec![13, 10]).unwrap();
                    let head = format!(
                        "HTTP/1.1 206 Partial Content{nl}Content-Range: bytes {s}-{e}/{TOTAL}{nl}Content-Type: video/mp4{nl}Content-Length: {len}{nl}{nl}"
                    );
                    if c.write_all(head.as_bytes()).await.is_err() {
                        return;
                    }
                    // 分块慢写,统计**真正流出去的字节** —— 这才是用户的流量。
                    // 代理一取消,连接断开,这里的写就失败,计数随即停住。
                    let block = vec![0u8; 64 * 1024];
                    let mut sent = 0usize;
                    while sent < len {
                        let n = block.len().min(len - sent);
                        if c.write_all(&block[..n]).await.is_err() {
                            return;
                        }
                        sent += n;
                        f.fetch_add(n, Ordering::SeqCst);
                        tokio::time::sleep(Duration::from_millis(20)).await;
                    }
                });
            }
        });

        // 缓存上限给大(GB 级),预取窗口就是被 MAX_READ_AHEAD 兜住的那个值。
        let h = start(format!("http://127.0.0.1:{up_port}/f"), 3, 1024 * 1024 * 1024, None)
            .await
            .unwrap();

        {
            let mut cli = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
            let nl = String::from_utf8(vec![13, 10]).unwrap();
            cli.write_all(format!("GET /play HTTP/1.1{nl}Range: bytes=0-{nl}{nl}").as_bytes())
                .await.unwrap();
            let mut buf = vec![0u8; 4096];
            let _ = cli.read(&mut buf).await;
        } // drop = 播放器跳走

        let at_disconnect = fetches.load(Ordering::SeqCst);
        tokio::time::sleep(Duration::from_secs(3)).await;
        let leaked = fetches.load(Ordering::SeqCst) - at_disconnect;

        // 按**字节**算才是用户的流量。取消有竞态,允许各 worker 收尾少量数据,
        // 但绝不能照着预取窗口继续拉满。
        let window = read_ahead_bytes(3, 1024 * 1024 * 1024);
        assert!(
            leaked as u64 <= 2 * 1024 * 1024,
            "断开后又流出 {}KB —— 预取窗口 {}MB,跳一次进度条就白烧这么多用户流量",
            leaked / 1024,
            window / 1048576
        );
    }

    /* 回归:上游**只连不回**时,代理必须放弃并断流,**不能吊死**。

       用户 2026-08-01 报的「播放没画面没声音、完全看不到流量」的真因就在这:
       fetch_chunk 里的 `send()/bytes()` 一个超时都没有(http.rs 三个 reqwest client
       也都没设 timeout),上游一黑洞,worker 就永远等下去 —— 不重试、不重签、
       没有任何日志,供给端跟着一起等。mpv 侧的形态是:
         [ffmpeg] Stream opened successfully  →  然后 duration=0、一帧不出、0 条轨道。
       curl 直接打本地代理的实测:`206, size=0, 25s 仍在等`,头发了、body 一个字节没有。

       测的是「**会结束**」,不是「会成功」—— 上游是黑洞,失败才是正确结果,
       吊死才是 bug。反向验证:把 fetch_chunk 里的 tokio::time::timeout 摘掉,
       本测试直接超时红(而不是断言失败)。 */
    #[tokio::test]
    async fn black_hole_upstream_gives_up_instead_of_hanging_forever() {
        let _g = CHUNK_TIMEOUT_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // 15s×3 次跑真值要 45 秒,没人会把那种测试留在门禁里。压到 200ms。
        CHUNK_TIMEOUT_OVERRIDE_MS.store(200, Ordering::Relaxed);

        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        let total: u64 = 64 * 1024 * 1024;
        tokio::spawn(async move {
            let mut first = true;
            while let Ok((mut s, _)) = up.accept().await {
                let hold = std::mem::replace(&mut first, false);
                tokio::spawn(async move {
                    let mut b = [0u8; 2048];
                    let _ = s.read(&mut b).await;
                    if hold {
                        /* 第一条是 probe(Range: bytes=0-0)—— 必须正常回,否则 start()
                           拿不到 total 直接返 None,测试就退化成「代理没起来」,
                           压根测不到 worker 那条路(这类「测了个寂寞」最难发现)。 */
                        let _ = s
                            .write_all(
                                format!(
                                    "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/{total}\r\nContent-Type: video/x-matroska\r\nContent-Length: 1\r\n\r\nX"
                                )
                                .as_bytes(),
                            )
                            .await;
                    }
                    // 之后所有分段请求:收下,**永不回应**,也不关连接 —— 就是黑洞。
                    std::future::pending::<()>().await;
                });
            }
        });

        let h = start(format!("http://127.0.0.1:{up_port}/f"), 2, 16 * 1024 * 1024, None)
            .await
            .expect("probe 回了 Content-Range,代理该起得来");

        let mut c = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        c.write_all(b"GET /play HTTP/1.1\r\nRange: bytes=0-\r\n\r\n").await.unwrap();

        /* 读到连接结束(代理放弃 → 断流关连接)。给 10 秒:200ms×3 次 + 退避 + 收尾,
           远远够;而缺超时的旧代码在这儿会一直读不到 EOF,测试整体超时。 */
        let ended = tokio::time::timeout(Duration::from_secs(10), async {
            let mut buf = [0u8; 8192];
            loop {
                match c.read(&mut buf).await {
                    Ok(0) | Err(_) => return true, // 连接断了 = 代理放弃了,正确
                    Ok(_) => {}                    // 头 + 可能的零星字节,继续读
                }
            }
        })
        .await;

        CHUNK_TIMEOUT_OVERRIDE_MS.store(0, Ordering::Relaxed);
        assert!(
            ended.is_ok(),
            "上游只连不回时代理没有放弃 —— 没有超时的话 worker 会永远等下去,\
             播放器收到 206 头之后一帧不出、也没有任何日志"
        );
    }

    /* 回归:**慢但一直在吐字节**的上游不许被掐。

       这条是给我自己立的护栏。修「上游黑洞吊死」时我第一版写的是**整体超时**(15s),
       而实测用户那条链(2026-08-01)TTFB 正常、吞吐只有 56~143KB/s,拉满一个 4MB 分段
       合法地要 29~62 秒 —— 整体超时会把「慢但完全能用」的链路当故障掐掉,还会一路重试
       放大负载。修一个静默卡死,换来一个更响的故障,这种"修复"比不修还糟。
       判据只能是「一段时间**一个字节都不来**」。

       本测试:每 60ms 吐一小块,总耗时远超空闲上限(120ms)。
       反向验证:把 fetch_chunk 的收体循环换回 `r.bytes().await` 外面套一个整体
       `timeout(chunk_timeout(), ...)`,本测试立刻红。 */
    #[tokio::test]
    async fn slow_but_progressing_upstream_is_not_killed() {
        let _g = CHUNK_TIMEOUT_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        CHUNK_TIMEOUT_OVERRIDE_MS.store(120, Ordering::Relaxed);

        let total: u64 = 16 * 1024 * 1024;
        let up = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let up_port = up.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = up.accept().await {
                tokio::spawn(async move {
                    let mut b = [0u8; 2048];
                    let n = s.read(&mut b).await.unwrap_or(0);
                    let req = String::from_utf8_lossy(&b[..n]).to_string();
                    // probe:Range: bytes=0-0
                    if req.contains("bytes=0-0") {
                        let _ = s.write_all(format!("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/{total}\r\nContent-Type: video/x-matroska\r\nContent-Length: 1\r\n\r\nX").as_bytes()).await;
                        return;
                    }
                    // 分段:头先发,体分 10 次挤牙膏 —— 每次间隔 < 空闲上限,总时长 > 空闲上限。
                    let want = CHUNK_SIZE as usize;
                    let _ = s
                        .write_all(
                            format!("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-{}/{total}\r\nContent-Length: {want}\r\n\r\n", want - 1)
                                .as_bytes(),
                        )
                        .await;
                    // ⚠️ 最后一块要吃掉余数。整除少几个字节 = body 比 Content-Length 短,
                    //    reqwest 会一直等那几个字节,测出来是「拉取失败」而不是本测试想验的东西。
                    let piece = want / 10;
                    for i in 0..10 {
                        tokio::time::sleep(Duration::from_millis(60)).await;
                        let n = if i == 9 { want - piece * 9 } else { piece };
                        if s.write_all(&vec![7u8; n]).await.is_err() {
                            return;
                        }
                    }
                });
            }
        });

        let h = start(format!("http://127.0.0.1:{up_port}/f"), 2, 16 * 1024 * 1024, None)
            .await
            .expect("probe 正常,代理该起得来");
        let mut c = TcpStream::connect(("127.0.0.1", url_port(&h.url))).await.unwrap();
        c.write_all(b"GET /play HTTP/1.1\r\nRange: bytes=0-1023\r\n\r\n").await.unwrap();

        // 读满「头 + 1024 字节」就算通过:说明第一段被完整收下并供了出来。
        let got = tokio::time::timeout(Duration::from_secs(10), async {
            let mut buf = Vec::new();
            let mut one = [0u8; 4096];
            loop {
                match c.read(&mut one).await {
                    Ok(0) | Err(_) => return buf.len(),
                    Ok(n) => {
                        buf.extend_from_slice(&one[..n]);
                        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                            if buf.len() - (i + 4) >= 1024 {
                                return 1024;
                            }
                        }
                    }
                }
            }
        })
        .await;

        CHUNK_TIMEOUT_OVERRIDE_MS.store(0, Ordering::Relaxed);
        assert_eq!(
            got.ok(),
            Some(1024),
            "慢速但持续吐字节的上游被掐了 —— 空闲超时被写成了整体超时,\
             真实链路(56~143KB/s)拉一个 4MB 分段本来就要半分钟"
        );
    }

    fn url_port(u: &str) -> u16 {
        u.rsplit(':')
            .next()
            .and_then(|s| s.split('/').next())
            .unwrap()
            .parse()
            .unwrap()
    }
}





