# 网络层知识

> 面向 Go 重写。行号对应 2026-08-30 的 `main`(85b47417)。
> 所有结论都带 `文件:行号`。读不出来的写「未确认」并说明查了哪里。
> **黄金实现原则**:Go 版验收标准是「和 Rust 版输出一致」,不是「跑起来了」。

涉及文件:

| 文件 | 行数 | 干什么 |
|---|---|---|
| `crates/core/src/net/prefetch.rs` | 2586 | 多线程加载 = 本地预取代理(环形磁盘缓存 + 多连接 Range) |
| `crates/core/src/net/preload.rs` | 246 | 预加载 = 详情页预热头/尾 |
| `crates/core/src/net/cf/{mod,proxy,ranges,runtime,speedtest}.rs` | 1178 | CF 优选:IP 抽样 / 测速 / 钉 IP 反代 / 路由改写表 |
| `crates/core/src/net/localserve.rs` | 268 | 把「能按偏移读字节的东西」变成 mpv 打得开的 http:// (只给 SMB 用) |
| `crates/core/src/http.rs` | 557 | 三个 reqwest 客户端、UA 三分、TLS 白名单、代理 |
| `crates/core/src/download.rs` | 839 | 多线程分段下载 |
| `crates/core/src/image_cache.rs` / `icon_cache.rs` | 473 / 172 | 图片两层缓存 / 服务器图标 |
| `crates/core/src/companion.rs` | 280 | 电视端局域网小网页(手机遥控器) |
| `apps/desktop/src/imgcache.rs` | ~250 | `lpimg` 自定义 scheme + **回源并发闸** |

---

## 0. 一句话

网络层是**三层本地 HTTP 服务 + 三个 reqwest 客户端**:预取代理(prefetch)、CF 优选反代(cf/proxy)、SMB 桥(localserve)都在 `127.0.0.1` 上起服把字节喂给 mpv;三个客户端按 UA 分成 Emby / 预取 / 第三方三条道;而这一层里几乎每一个看起来奇怪的决定 —— `Connection: close`、空闲超时、环形槽位、302 只跟一次、回环不走代理 —— 都是一次「有流量、没画面、不报错」的线上故障换来的。

---

## 1. 预取代理

### 1.0 它是什么、不是什么

- 起播时(或**详情页预热时**)在 `127.0.0.1:<随机端口>/play` 起一个本地 HTTP 服务当播放源交给 mpv;代理用 2~4 个并发 Range 连接对真实流「超前」拉取,顺序喂给播放器(`prefetch.rs:1-7`)。
- 收益三条:多连接聚合带宽 / localhost 读抖动被缓冲吸收 / 代理对上游自带重试,mpv 只面对始终在线的 localhost(`prefetch.rs:5-7`)。
- **只代理 Emby 直传流**;直链、转码由调用方跳过。因此代理只带全局 UA,不带逐流鉴权头(`prefetch.rs:18`;调用点判据 `apps/desktop/src/lib.rs:1714` `target.play_method == "DirectStream"`)。
- 取不到文件大小 / 起服失败 → `start()` 返回 `None`,调用方回退直连(`prefetch.rs:19`、`prefetch.rs:565-567`、`prefetch.rs:575-578`)。
- **和 preload 是两件事,别合并**:prefetch 管「喂得满」(播放中),preload 管「起得快」(播放前)。两者**共用同一个代理句柄和同一份环形缓存**,那正是预热能被起播吃到的原因(`net/mod.rs:3-5`、`preload.rs:15-18`)。
- 开关粒度是**服务器**不是线路,默认关。理由:它是优化不是功能,局域网/NAS 本来就跑满,多开几条 Range 只是白占连接(`config.rs:196-207`)。
- **Android 端没有接**。`grep -rn "net::prefetch\|net::preload" apps/android/src/*.rs` 零命中;Android 只用了 `net::cf` 和 `companion`(`apps/android/src/lib.rs:86`、`:101`)。

### 1.1 数据流时序

```
   ┌──── 详情页(可选,预加载)────────────────────────────────────────────┐
   │ preload_item                     lib.rs:4793                        │
   │   resolve_stream → 只处理 DirectStream   lib.rs:4831-4834            │
   │   prefetch_proxy_for(upstream)  ← 起代理并**记住句柄** lib.rs:4733    │
   │   warm(head_url = 本地代理, tail_url = 直连)  lib.rs:4846-4864        │
   │       head: GET 代理 Range: bytes=0-(32MB-1)  preload.rs:108-109     │
   │             字节流经代理 → 落进环形缓存(读完即丢)  preload.rs:152     │
   │       tail: GET **直连** Range: bytes=-2MB    preload.rs:117-118     │
   └──────────────────────────────────────────────────────────────────────┘

   起播  play()  lib.rs:1696-1735
     warm_hit = 已有句柄且上游地址一致  lib.rs:1710-1713
     if (开关开 || warm_hit) && DirectStream:
         prefetch_proxy_for → **复用同一个句柄**(不新起)lib.rs:4740-4754
     mpv ← play_url = http://127.0.0.1:PORT/play
     若 play_url 是回环 → 不给 mpv 挂用户代理  lib.rs:1750-1755

   ──────────────── 每一次 mpv 打开/seek 都是一条新 TCP ────────────────

   mpv ──GET /play  Range: bytes=S-  ──► accept 循环 prefetch.rs:129-149
                                        handle()   prefetch.rs:749
     ① read_request(逐字节读到 \r\n\r\n)          prefetch.rs:1076-1111
     ② 越界判定(**用原始 start**)→ 416          prefetch.rs:761-771
     ③ 写响应头 206/200 + Accept-Ranges
        + **Connection: close** + Content-Type + Content-Length
                                                   prefetch.rs:774-798
     ④ HEAD 到此为止                               prefetch.rs:800-802
     ⑤ 建**本连接自己**的 Stream(独立窗口 + 独立 worker)prefetch.rs:804-826
        first_chunk = S/4MB, head_within = S%4MB
     ⑥ spawn threads 个 worker;主协程跑 serve()

   worker(每条连接 2~4 个)  prefetch.rs:842-933
     loop:
       认领:fetch_cursor <= last_chunk 且 <= serve_chunk + read_ahead_chunks-1
             已在盘上(disk.has)→ 跳过不重下           prefetch.rs:854-857
             否则 in_flight.insert(c)                   prefetch.rs:858
       窗口满 → 等 window_notify,250ms 兜底             prefetch.rs:864-872
       载体:首段不对齐 → Live::based(head_within, …) 挂本连接(**不进共享登记处**)
             其余 → origin.live_begin(c) 挂共享登记处   prefetch.rs:881-893
       select { fetch_chunk(c, live)  |  done_notify → 取消 }  prefetch.rs:907-915
       落盘 disk.put(c, data)(残段不落盘)              prefetch.rs:918-922
       live_end(**必须在 put 之后**)                    prefetch.rs:923
       in_flight.remove;失败则 failed.insert            prefetch.rs:924-930

   fetch_chunk  prefetch.rs:605-708(单段,最多 3 attempt)
     start = c*4MB + live.base ← **不是段边界**          prefetch.rs:610
     URL:优先 resolved(302 落点),否则 up.url          prefetch.rs:615-621
     ┌ timeout(20s) send()  ← 建连+响应头               prefetch.rs:639-646
     └ loop timeout(20s) r.chunk() → live.feed(&mut skip, b)
       **每收到一块就重置计时**(空闲超时)               prefetch.rs:657-664
     收完:len == want 才收下,短了重试                   prefetch.rs:670-675
     4xx/5xx/超时:先清 resolved,清过了才 refresh_upstream  prefetch.rs:687-701
     退避 300ms / 600ms                                  prefetch.rs:702-704

   serve  prefetch.rs:1046-1072
     while pos <= end:
       select { next_bytes(c, within)  |  peer_gone(stream) → break }
       write_all(piece) ← **mpv 读慢时自然阻塞 = 端到端背压** prefetch.rs:1063-1064
       整段消费完 → advance_serve(c+1) → 腾窗口 + 唤醒 worker prefetch.rs:1066-1069

   next_bytes  prefetch.rs:961-1022(「有多少给多少」)
     ① disk.has && disk.get 命中 → 直接返回 b[within..]  prefetch.rs:966-973
        (get 返回 None = 被挤掉,**不能当失败**,落到自愈)prefetch.rs:968-969
     ② 首段先看 head_live,再看共享 live 登记处          prefetch.rs:977-980
        live.slice_from(within) 有货就立刻返回            prefetch.rs:981-983
        还在喂 → 等 live.notify,250ms 兜底                prefetch.rs:984-990
     ③ failed 里有它 → None(断流)                       prefetch.rs:992-994
     ④ **自愈**:fetch_cursor > c 且不在 in_flight → 把游标倒回 c  prefetch.rs:1010-1017
     ⑤ 等 data_notify,250ms 兜底重查                     prefetch.rs:1018-1020

   连接结束(serve 返回)prefetch.rs:828-832
     done = true → worker 退出;window_notify + **done_notify 取消在飞的 fetch**
```

### 1.2 环形磁盘缓存

| 项 | 值 / 做法 | 出处 |
|---|---|---|
| 段大小 | `CHUNK_SIZE = 4MB` | `prefetch.rs:33` |
| 文件位置 | `cache_dir("prefetch")/s{pid}_{total}_{seq}.part` | `prefetch.rs:332-347` |
| 槽位数 | `ring = min( max(cache_bytes/4MB, threads*2), ceil(total/4MB) )`,再 `.max(1)` | `prefetch.rs:355-360` |
| 槽位定位 | `off(c) = (c % ring) * CHUNK_SIZE` | `prefetch.rs:366-368` |
| 索引 | `slots: HashMap<槽位, 段号>`;`slots[c%ring] == Some(c)` 才算命中 | `prefetch.rs:295-301`、`:371-373` |
| 淘汰 | 无 LRU,纯环形覆盖:段号模 ring 同余就同槽,后写盖先写 | `prefetch.rs:296-300` |
| 生命周期 | `DiskCache::drop` 删文件;起服时 `sweep_orphans` 扫别的进程的残留 | `prefetch.rs:436-440`、`:306-326`、`:344` |
| 共享范围 | **全会话共享**,不是每连接一份 | `prefetch.rs:277`、`:287-289` |

**为什么占用恒等于上限**:环形复用而不是无限增长。测试服里随手就有 29.6GB 的片子,整片直存 = 顺序看完一遍吃掉用户 29.6GB 硬盘,「和内存爆掉是同一个错误换了介质」(`prefetch.rs:296-300`)。护栏测试 `disk_cache_is_capped_not_proportional_to_file_size`(`prefetch.rs:1198-1214`)。

**为什么必须落盘**(2026-07-19 用户定):原来分段全在内存 `HashMap<u64, Arc<Vec<u8>>>`,峰值 = 单连接窗口 × 存活连接数。播放器一 seek 就丢下旧连接新开一条,而被丢下的连接**还会把整个窗口填满才罢休** —— 快速拖 N 次进度条就是 32MB×N 瞬时占用,内存不足直接闪退。因为不敢放大,用户设置项被硬钳在 16~32MB,「视频缓存上限」形同虚设(`prefetch.rs:279-285`;上限放开到 64MB~4GB 见 `config.rs:314-320`)。

**为什么共享而不是每连接一份**:共享才有「缓存」的意义 —— seek 回看命中磁盘不重下。每连接一份只是「缓冲」不是「缓存」(`prefetch.rs:287-289`)。这条也是**预加载能被起播吃到**的唯一原因(`prefetch.rs:1932-1940`)。

**并发读写怎么防 TOCTOU**(两处,必须一起看):

1. `put`:**全程持 `slots` 锁,且先把槽标失效再写**(`prefetch.rs:384-404`)。
   原来是「写完盘再更新 slots」→ 读者可以:查 slots 命中 → 开始读 → 另一条流正把**别的段**覆盖进同一个槽 → 读到半新半旧的脏数据。表现是播放器拿到错帧(实测:B 连接在自己的起始位置读到 A 的字节),**比饿死更隐蔽,它不报错,只是画面坏掉**(`prefetch.rs:377-383`)。
2. `get`:**槽位校验和读盘在同一把锁里**(`prefetch.rs:410-433`)。先 `has()` 再 `get()` 的两段式有 TOCTOU。
   ★ 这里原来还有一句「读完再 has() 复核一次」,**现在不能留** —— slots 锁已经持到读完,再调 `has()` 就是对同一把 `tokio::Mutex` 重入 = 死锁(`prefetch.rs:427-430`)。

**文件名必须每个实例唯一**,不能是 `(pid, total)`(`prefetch.rs:334-343`):
两个会话完全可能并存(孤儿播放器还没 Drop、新播放器已起来;同一部片 total 当然相同)。重名 → 后来者的 `truncate(true)` 把前者数据整个清零,而前者的 `slots` 表在内存里仍认为「就绪」→ 后来者再写一个高位槽把文件撑长 → 前者读低位槽读回一整块**稀疏零**并当作有效数据发给播放器。这也是 CI 上 `concurrent_connections_do_not_starve_each_other` 偶发红的真凶(cargo test 同进程并行,几个测试 TOTAL 都是 40MB,互相 truncate)。护栏:`two_live_sessions_never_share_one_cache_file`(`prefetch.rs:1144-1168`)。

**孤儿清扫**(`prefetch.rs:306-326`):缓存文件靠 Drop 删,进程被杀时 Drop 不跑 —— 实测用户机器上躺着一周前的 33MB 残留。2026-08-02 预加载改成在**详情页**就起代理之后,逛一圈详情页就能攒一堆。只删文件名前缀不是本进程 pid 的;删不掉一律忽略(打扫,不是关键路径)。

### 1.3 Range 与 seek

**请求怎么切**
- 播放器的一次请求 → `first_chunk = start/4MB`,`last_chunk = end/4MB`,`head_within = start % 4MB`(`prefetch.rs:805-817`)。
- worker 只**向前顺序**认领 `[fetch_cursor, serve_chunk + read_ahead_chunks - 1]`(`prefetch.rs:845-861`)。
- 预取超前窗口 `read_ahead_bytes(threads, cache_limit) = clamp(cache_limit, min(4MB*threads, 64MB), 64MB)`(`prefetch.rs:82-85`)。
  - `MAX_READ_AHEAD = 64MB`,2026-07-19 从「缓存上限」里**拆出来** —— 这两件事以前共用一个值:缓存放开到 GB 级后预取窗口跟着变 GB 级,而被丢下的连接**正是照着这个窗口拉满才停**,于是「跳一次进度条」的代价从白拉 32MB 升级成白拉几 GB(`prefetch.rs:35-44`)。
  - 超前量不需要大:真正的大缓冲由 mpv 自己的 demuxer cache 扛。64MB 在最慢实测链路(~1.3MB/s)上也有 ~45 秒余量(`prefetch.rs:42-43`)。
  - 旧公式 `MAX.min((CHUNK*t*2).max(cache_limit))` 把用户的上限当**下限**用了,默认 1GB 直接顶到硬上限(`prefetch.rs:80-81`)。
- 段数换算 `read_ahead_chunks = (read_ahead_bytes/4MB).max(1)`,**不再** `.max(threads*2)`(那会反过来突破字节预算:16MB/4 线程会算出 8 段 = 32MB)(`prefetch.rs:569-572`)。

**seek 怎么处理**
- 响应声明 `Connection: close`,所以**每 seek 一次就是一条新连接**;跳转 = 开新窗口,而不是把别人下好的缓存冲掉(`prefetch.rs:14-16`、`:785-795`)。
- 旧连接立刻停:`serve` 用 `peer_gone` 感知对端关闭(`prefetch.rs:1030-1043`、`:1056`),worker 用 `done_notify` 取消**在飞**的 fetch(`prefetch.rs:875-879`、`:907-915`、`:831`)。
  - 光靠 `write_all` 报错**不够及时**:等分段的那段时间里我们根本没在写,而那恰恰是浪费发生的时段(`prefetch.rs:1026-1029`)。
  - `notified()` 必须在检查 `over()` **之前**注册,否则 done 恰好在两者之间置位就会丢唤醒(`prefetch.rs:878-879`、`:902-906`)。

**为什么 seek 不能回退边界**(2026-08-02 第二刀,`prefetch.rs:606-609`、`:1829-1840`)
连接起点几乎不可能正好落在 4MB 边界上。从边界开拉 = 在播放器要的第一个字节前面先白拉平均 2MB;用户那条链 150KB/s → 每拖一次进度条画面 13 秒不动。所以首段的 fetch 起点由载体的 `base` 决定(`start = c*4MB + live.base`)。
这个「残段」载体 `head_live`:
- **不进 `Origin::live` 也不落盘** —— 它是残的。写进环形缓存会把 `[0, head_within)` 那截垃圾一起标成就绪,别的连接读同一段就拿到脏数据,「不报错、只坏画面」(`prefetch.rs:459-465`)。
- 代价:这一小段不进缓存(seek 回来要重下),换每次 seek 少等平均 2MB。
- 首段消费完就把它释放,别让那几 MB 挂到连接结束(`prefetch.rs:947-952`)。

**尾部为什么必须走直连**(preload 的尾段,两条理由都写在 `preload.rs:91-93` 和 `:113-116`)
1. 代理的环形缓存按 `chunk % ring` 定位,**尾部段号和头部段号模 ring 有约一半概率同槽** —— 预热完尾巴正好把头顶掉。尾巴只有 2MB,重拉便宜;把路(CDN 边缘 / 服务端页缓存)跑热就够本。
2. **我们自家的代理不认后缀 Range**:`parse_range("bytes=-500") == None`(`prefetch.rs:1116-1122`、断言 `:1220`),而 `handle` 对 `range == None` 走的是 `(0, total-1)` + `200 OK`(`prefetch.rs:758`、`:781-783`)—— 也就是说把 `bytes=-2MB` 打给代理会拿到**整片从 0 开始**。

**为什么 302 只跟随一次**(`prefetch.rs:166-179`、`:535-539`、`:615-621`)
UHD 那类服务端(服务端A)的直传流是 302 跳 CDN,而 `fetch_chunk` 每段都是一次独立请求 —— 不缓存最终地址就是**每 4MB 重走一遍 302**。实测 0.67s/段,占单段 TTFB(1.4s)的一半,并行省下的时间全赔在建连上:3 线程 4.0MB/s **反而慢于**单连接 4.3MB/s,多线程加载成了负优化。
做法:probe 那次本来就跟完了 302,把 `resp.url()` 存进 `UpstreamState.resolved`(只在真跳转时存);worker 优先打它。原版 Emby 无重定向(实测 redirect=0.000000),此字段恒为 None,零影响。
CDN 直链自带时效签名,过期即失效 → 失败时清空 `resolved` 回退 `url` 重新解析(`prefetch.rs:696-698`)。护栏:`follows_redirect_once_not_per_chunk`(`prefetch.rs:2240-2325`)。

**边收边吐 vs 攒齐再吐**(2026-08-02,`prefetch.rs:198-221`、`:956-960`)
> 分段粒度是给**预取**用的,不该成为**供给**的粒度。

在这之前,供给端必须等**整段 4MB 落盘**才吐第一个字节。而 mpv 起播只要文件头 ~200KB + 尾部 cues 索引(MKV,ffmpeg 开容器第一跳就 seek 到尾)。实测用户那条链(2026-08-01)吞吐只有 56~143KB/s → **一段 4MB 合法地要 29~62 秒**,头/尾各一次,于是「开了多线程加载就没画面没声音」;直连反而能播,正是因为 mpv 只拉它真正要的那几百 KB。
现在:worker 收到的每一块字节立刻 `live.feed()` 并唤醒供给端(`prefetch.rs:659`),供给端 `next_bytes` 要多少给多少(`prefetch.rs:980-990`)。落盘照旧(缓存/回看要它),但不再挡在播放器前面。
`Live.cap` = 本段应有长度,多出来的字节直接丢(上游给超长包时不能污染供给);「短了必须重试」的判据靠 `len() == want` 原样保留(`prefetch.rs:210-211`、`:670-675`)。

**重试续接**(边收边吐带来的新风险,`prefetch.rs:241-263`)
改造前每次 attempt 用全新 buf,重试天然干净。改造后 buf 是「直播缓冲」,上一轮收到的字节**可能已经吐给播放器了**,收不回来。所以 `feed(&mut skip, b)` 里的 `skip = live.len()`(`prefetch.rs:656`)让重试从断点续:既不重复追加(那是错帧),也不从头重来(那是重复吐)。
前提:**同 URL 同 Range 返回同样的字节** —— 这是这份缓存从一开始就依赖的假设(`prefetch.rs:245-246`)。

**超时策略**(`prefetch.rs:46-55`、`:622-636`)

| 位置 | 值 | 语义 |
|---|---|---|
| `probe` 探大小 | 8s | 整体超时,`prefetch.rs:525-526` |
| `fetch_chunk` 建连+响应头 | `chunk_timeout()` = 20s | 整体(本来就该几秒内完成),`prefetch.rs:639-646` |
| `fetch_chunk` 收体 | `chunk_timeout()` = 20s | **空闲超时**:每收到一块重置,`prefetch.rs:657-664` |
| `http.rs` 三个 client | **一个都没设** | `grep -n timeout crates/core/src/http.rs` 零命中 |
| `cf/proxy` build_client | connect 15s | `cf/proxy.rs:122` |
| `cf/speedtest` pinned_client | 整体 10s | `cf/speedtest.rs:185` |
| `imgcache` 单张回源 | 20s 墙钟 | `apps/desktop/src/imgcache.rs:49`、`:188` |

- **为什么非有不可**:http.rs 三个 client 一个 timeout 都没设,上游只要不回(CDN 落点失效、对端黑洞、中间设备吞包),worker 就永远吊在这儿:不重试、不重签、不报错、连一行日志都没有。供给端跟着永远等,mpv 侧表现为「206 头收到了、`Stream opened successfully`,然后 duration=0 / 一帧不出 / 一条轨道都没有」。curl 打本地代理实测:`206, size=0, 25s 仍在等`(`prefetch.rs:48-51`、`:624-629`、`:2411-2422`)。
- **为什么不能用整体超时**:第一版写的就是整体超时(15s),**是错的,差点当成修复发出去**。实测用户那条链 TTFB 1.3~1.8s 正常但吞吐只有 56~143KB/s,拉满一个 4MB 分段**合法地就要 29~62 秒**。整体超时会把「慢但完全能用」的链路当故障掐掉,还会一路重试放大负载 —— 修一个静默卡死,换来一个更响的(`prefetch.rs:52-54`、`:631-636`、`:2486-2496`)。
- 判据只能是「**一段时间一个字节都不来**」。

**长度校验必须有**(`prefetch.rs:598-604`)
分段按 `pos / CHUNK_SIZE` 定位,收下一个短包会让供给端写完这几字节后 `advance_serve(c+1)` 把它清掉,而 `pos` 仍落在分段 c 内 → 下一轮又去 `next_bytes(c)`,可 `fetch_cursor` 早过了 c,**永远没人重拉 → 永远缓冲**。
产出这种「格式合法但短」响应的两个真实来源:上游/CDN 截断;**我们自家 CF 反代在 chunked 路径上遇错 break 后仍补上合法结束块**(`cf/proxy.rs:260-266`)。

**重签(refresh_upstream)**(`prefetch.rs:710-746`)
- 只有回调拿不到地址(`None`/空串)才 `resign_disabled = true`。
- 「重签回来的地址和旧的一样」**不能**停用:开了 CF 优选时上游是本机反代,它一个 502(CF 那头抖一下,`cf/proxy.rs:177-184`)就会走到这里,而重签当然还解析出同一个 127.0.0.1 地址 —— 于是**一次网关抖动就把重签永久关掉**,等这部片真播到签名过期(长片常见)时已经没人能换地址了 → 断流。
- 并发合并:`resign_in_flight` 防多个 worker 同时刷接口。
- 换了签名链要把 `resolved` 一并作废(`prefetch.rs:735`)。
- 顺序:**先怪 CDN 直链,再怪签名链**。清空 `resolved` 只需重走一次 302;直接调重签(重走 PlaybackInfo)是杀鸡用牛刀还给服务端加压(`prefetch.rs:692-695`)。
- 宿主侧回调必须带 `media_source_id`,否则过期重签会悄悄退回默认版本 —— 用户选的 4K 播到一半变 1080p 且无提示(`apps/desktop/src/lib.rs:4709-4723`)。

**预热与起播的句柄复用**(`apps/desktop/src/lib.rs:4728-4755`、`:1707-1731`)
> 复用是关键,不是优化。

预加载在详情页起代理并往环形缓存里灌头部;起播时只要上游地址一致就必须拿回**同一个句柄** —— 换成新起一个,旧句柄 Drop 会把缓存文件删掉(`prefetch.rs:436-440`),预热的几十 MB 全白做。
判据是**上游地址一致**,和「这台服开没开多线程加载」无关:开关管的是播放中并发拉多凶,而不是「已经在本地的字节要不要用」(`lib.rs:1707-1714`)。
预加载时即使开关关着也仍起代理,只是用最低的 2 条连接(`lib.rs:4802-4814`、`:4849`)。
★ `prefetch_proxy_for` 里查句柄的锁必须放在**显式作用域**里,绝不能活到 `await`(`lib.rs:4741-4748`,对应记忆 `[[prefetch-proxy-deadlock]]`)。

**并发数 clamp**
- `threads.clamp(2, 4)`(`prefetch.rs:118`);设置页默认 3(`config.rs:301-303`)。
- 下限 2:窗口和槽位算法都假设至少两条(`DiskCache::create` 的 `want = max(cache/CHUNK, threads*2)`,`prefetch.rs:355`)。
- 上限 4:再多只是白占连接,收益取决于对端(`config.rs:199-200`)。
- ⚠️ 写测试时注意 clamp 会**悄悄把 1 抬成 2**,参数和注释就对不上了(`prefetch.rs:1322-1323`,踩过)。

**已修的两个竞态**

| # | 表现 | 真因 | 修法 | 护栏 |
|---|---|---|---|---|
| 1 · TOCTOU 串数据 | 播放器拿到错帧,**不报错、只是画面坏掉**(实测 B 连接在自己的起始位置读到 A 的字节) | 「写完盘再更新 slots」+ 读侧两段式 `has()`→`get()`;环形槽位全连接共享,段号模 ring 同余必然同槽 | `put` 全程持锁且**先失效再写**;`get` 校验+读盘同一把锁 | `two_live_sessions_never_share_one_cache_file`(`prefetch.rs:1144`);字节校验散在 `evicted_chunk_…`(`:1358-1368`) |
| 2 · 段被挤掉无人重拉(饿死) | 有流量、黑屏 / 永远缓冲;或对端超时后客户端读到 early eof。CI 上 `concurrent_connections_do_not_starve_each_other` 约 5~20% 概率红 | 段被别的连接挤出槽位后 `disk.has()` 恒 false,而 `fetch_cursor` 已越过 c,**再没人会去重拉**,`next_bytes` 无限空转 | `next_bytes` 自愈:`fetch_cursor > c && !in_flight.contains(c)` → 把游标倒回 c 并唤醒 worker(倒回幂等) | `evicted_chunk_is_refetched_not_awaited_forever`(`prefetch.rs:1285-1373`) |

第 2 条还需要 `in_flight` 集合才能把「在飞」和「被挤掉」分开 —— 两者的 `disk.has()` 都是 false,分不开就会把在飞的段又拉一遍 = 烧用户流量(`prefetch.rs:448-451`、`:1012-1013`)。

### 1.4 关键不变量

> **Go 版重写时,每一条都要对应一个测试。** 「违反后的症状」一栏就是这条不变量存在的理由。

| # | 不变量 | 违反了会怎样(用户可见) | 出处 | 现有护栏 |
|---|---|---|---|---|
| **N1** | 响应必须显式 `Connection: close` | ffmpeg 一 seek 就把下个 Range 管线化到同一条 socket,没人读、响应永不来 → seek 静默失败,退化成**从头线性读完整片**(实测 289MB 全下、73 段全拉),播放器干等 = **有流量、黑屏无声、慢得离谱** | `prefetch.rs:785-795` | `response_declares_connection_close`(`:2177`);CF 反代同名(`cf/proxy.rs:390`);SMB 桥(`localserve.rs:234`) |
| **N2** | 每条 TCP 只处理一个请求,**每条连接持有自己的取数窗口** | 旧版全局窗口 + 每请求 reset:mpv 探 MKV 时新连接一进来就把旧连接正在等的分段从计划里抹掉 → 响应头已发、body 一字节不来 = 黑屏无声、永远缓冲 | `prefetch.rs:9-16` | `concurrent_connections_do_not_starve_each_other`(`:1380`) |
| **N3** | 越界 Range 判定必须用**钳位前**的原始 start,回 416 | 旧写法分支永远进不去(死代码),越界请求被悄悄挪回最后一字节回 206 → 播放器拿到「有效但错位」的数据 | `prefetch.rs:761-771` | `out_of_range_start_gets_416_not_bogus_206`(`:2190`);SMB 桥同款(`localserve.rs:82-91`、测试 `:225`) |
| **N4** | 上游不支持 Range(拿不到 Content-Range/total)→ **起服失败返 None**,让调用方回退直连 | 没有 total 就分段定位全错,喂给播放器就是黑屏 | `prefetch.rs:565-567` | `upstream_without_range_support_refuses_to_start`(`:2204`) |
| **N5** | 分段长度必须**正好**等于请求量;短了重试,3 次用尽标 failed 断流 | 收下短包 → `pos` 仍在段内但 `fetch_cursor` 已越过 → 永远没人重拉 → **永远缓冲** | `prefetch.rs:598-604`、`:670-675` | `short_upstream_chunk_breaks_stream_instead_of_hanging`(`:1591`) |
| **N6** | 取数必须有超时,且必须是**空闲超时** | 无超时:206 头收到、duration=0、一帧不出、零日志。整体超时:56~143KB/s 的慢链路被误杀 + 重试放大负载 | `prefetch.rs:46-55`、`:622-636` | `black_hole_upstream_gives_up_instead_of_hanging_forever`(`:2423`)+ `slow_but_progressing_upstream_is_not_killed`(`:2497`),**两条缺一不可** |
| **N7** | 供给粒度 ≠ 预取粒度:收到多少吐多少,不等整段落盘 | 一段 4MB 在 56~143KB/s 下合法要 29~62 秒 → 「开了多线程加载就加载不出来」,直连反而秒开 | `prefetch.rs:198-208`、`:956-960` | `first_bytes_reach_the_player_before_the_whole_chunk_arrives`(`:1665`,断言前 256KB < 2.5s) |
| **N8** | 重试必须从**断点续**(skip),不重复追加也不从头重来 | 错帧。**不报错,只是画面坏掉** —— 最难查的一类 | `prefetch.rs:241-246`、`:656` | `retry_after_partial_body_resumes_instead_of_duplicating`(`:1761`) |
| **N9** | 连接首段从**请求起点**拉,不回退到 4MB 边界 | 每次 seek 白拉平均 2MB;150KB/s 下拖一次进度条画面 13 秒不动 | `prefetch.rs:606-609` | `seek_does_not_wait_for_the_bytes_before_it`(`:1841`,同时断言上游收到的 Range 起点 + 端到端耗时) |
| **N10** | 首段残段载体**不进共享登记处、不落盘** | `[0, head_within)` 那截垃圾会被标成就绪,别的连接读到脏数据(不报错、坏画面) | `prefetch.rs:459-465` | 无独立测试(**缺口**,见 §9) |
| **N11** | 环形缓存**全会话共享**,一条连接拉过的字节下一条连接白拿 | 预加载静默白做:编译绿、单测绿、界面无异样,只有用户觉得「还是慢」 | `prefetch.rs:287-289`、`:1932-1937` | `bytes_pulled_by_one_connection_are_free_for_the_next`(`:1941`) |
| **N12** | 磁盘占用封顶 = 用户设的上限,不随片子大小涨 | 29.6GB 的片顺序看完一遍吃掉用户 29.6GB 硬盘 | `prefetch.rs:296-300` | `disk_cache_is_capped_not_proportional_to_file_size`(`:1198`) |
| **N13** | 预取窗口独立于缓存上限,硬顶 64MB | 缓存放开到 GB 级 → 窗口跟着 GB 级 → 跳一次进度条白烧几 GB 流量 | `prefetch.rs:35-44`、`:82-85` | `read_ahead_is_capped_and_respects_user_limit`(`:1175`) |
| **N14** | 缓存写入:**先把槽标失效再写**,校验+读盘同一把锁 | 读到半新半旧的脏数据 = 错帧,不报错 | `prefetch.rs:377-383`、`:406-409` | `two_live_sessions_never_share_one_cache_file`(`:1144`) |
| **N15** | 锁不可重入:`get` 里读完**不许**再调 `has()` 复核 | 死锁,那条连接彻底不动 | `prefetch.rs:427-430` | 无独立测试(死锁会让别的测试超时) |
| **N16** | 被挤掉的段必须**重拉**,不能干等;要靠 `in_flight` 区分「在飞」和「被挤掉」 | 连接饿死 = 有流量、黑屏/永远缓冲;或 early eof。分不开则重复下载烧流量 | `prefetch.rs:995-1017`、`:448-451` | `evicted_chunk_is_refetched_not_awaited_forever`(`:1285`) |
| **N17** | `disk.get` 返回 None **不是失败**,要落自愈路径 | 当失败断流 = 给播放器一个 early eof | `prefetch.rs:968-969` | 同 N16 |
| **N18** | `live_end` 必须排在落盘**之后** | 留出一个「两边都查不到」的空档,供给端在那一瞬只能干等 250ms 兜底 | `prefetch.rs:496`、`:923` | 无独立测试(**缺口**) |
| **N19** | 同一段被两条连接同时拉时,登记处只认先到的;后到者拿一个**没登记**的载体 | 两个 worker 往同一个 buffer 交错喂字节 = 直接出错帧 | `prefetch.rs:484-486`、`:487-493`、`:500-505` | 无独立测试(**缺口**) |
| **N20** | 取数必须**向前顺序、不重复、不跳跃**;超前量不超过窗口 | 有重复 = 白费用户流量/服务器压力;有缺口/乱序 = 不是顺序加载 | `prefetch.rs:1468-1473` | `fetches_sequentially_without_duplicates`(`:1474`) |
| **N21** | 播放器抛弃连接后必须**立刻**停止拉取(serve 侧 peer_gone + worker 侧 done_notify,两层缺一不可) | 修前:断开后 3 秒内还继续取 6 段(24MB);窗口放开到 GB 级后同一个洞 = 跳一次进度条烧掉几 GB | `prefetch.rs:875-879`、`:1024-1029` | `abandoned_connection_stops_fetching_immediately`(`:2336`)。★ **口径必须按字节不是请求数** —— 按请求数计的话 worker 那层怎么改都是绿的 |
| **N22** | 302 落点缓存下来,每段不重走重定向 | 每 4MB 一次 0.67s 重定向:3 线程 4.0MB/s **慢于**单连接 4.3MB/s,多线程加载变负优化 | `prefetch.rs:166-179` | `follows_redirect_once_not_per_chunk`(`:2240`) |
| **N23** | 重签只在回调**拿不到地址**时停用;地址没变 = 抖动,不许自废武功 | 一次 CF 网关 502 就把重签永久关掉;长片播到签名过期时断流 | `prefetch.rs:711-716` | `same_url_does_not_disable_resign`(`:2096`)+ `new_url_is_adopted_and_none_disables`(`:2105`) |
| **N24** | 缓存文件名**每实例唯一**;起服时清扫别的进程的残留 | 重名:后者 truncate 把前者数据清零,前者读回一整块稀疏零**当作有效视频发出去**。不清扫:用户硬盘上残留越攒越多(实测一周前的 33MB) | `prefetch.rs:334-343`、`:306-315` | `two_live_sessions_never_share_one_cache_file`(`:1144`)、`stale_cache_files_from_dead_processes_are_swept`(`:2053`) |
| **N25** | `ProxyHandle` Drop = 停服 + 删缓存文件;起播必须**复用**预热时的句柄 | 新起一个 → 旧句柄 Drop 删缓存 → 预热的几十 MB 白做,用户从头再下一遍 | `prefetch.rs:102-106`、`lib.rs:4730-4732` | `bytes_pulled_by_one_connection_are_free_for_the_next`(`:1941`,核层侧) |
| **N26** | 代理**不接受后缀 Range**(`bytes=-N`);preload 的尾段必须打直连 | 打给代理会拿到整片从 0 开始;且尾段落缓存会把头部顶掉 | `prefetch.rs:1113-1122`、`preload.rs:91-93`、`:113-116` | `parses_range_forms`(`:1216`)+ `warms_both_head_and_tail`(`preload.rs:200`) |
| **N27** | 预热必须**自己封顶**读取量 | 服务端无视 Range 回整片是真发生过的事(`[[server-ignores-http-range]]`);「热一下」会变成把整部片偷偷下下来 | `preload.rs:127-128`、`:144` | `stops_at_the_limit_even_if_server_ignores_range`(`preload.rs:217`) |
| **N28** | 开新一轮预热必须掐掉上一轮 | 用户在列表里快速点几下,后台挂着好几轮预热抢带宽,他要看的那部反而更慢 | `preload.rs:72-79` | `starting_a_new_job_cancels_the_previous_one`(`preload.rs:234`) |
| **N29** | `write_all` 提供端到端背压,预取停在窗口内 | 没有背压 = worker 一路狂拉,窗口失效 | `prefetch.rs:1063-1064` | `fetches_sequentially_without_duplicates` 的窗口断言(`:1558-1566`) |
| **N30** | 所有等待都要有 250ms 兜底轮询,防丢唤醒 | 丢一次 notify = 那条连接卡住不动 | `prefetch.rs:865-871`、`:984-990`、`:1018-1020` | 无独立测试(**缺口**;它是「不会挂死」的保险丝) |

---

## 2. HTTP 客户端策略

### 2.1 UA 三分口径(用户 2026-07-19 定,`http.rs:7-15`)

| 客户端 | UA | 用在哪 | 出处 |
|---|---|---|---|
| `emby_client()` | `LinPlayer/{版本}` | Emby API、mpv 直连取流、下载引擎 | `http.rs:18-20`、`:232-235`;`download.rs:197` |
| `preload_client()` | `LinPlayerPreload/{版本}` | 预取代理拉上游 + 预加载 | `http.rs:22-25`、`:237-240`;`prefetch.rs:519-521`;`preload.rs:106` |
| `client()` | `LinPlayer/{版本} (+https://github.com/zzzwannasleep/LinPlayer)` | 第三方公开 API(Bangumi/Trakt/弹弹Play/翻译/排行) | `http.rs:27-36`、`:217-230` |

**为什么不能串**:预取代理是**我们替 mpv 提前拉流**的旁路请求,和用户真正在看的那一路在服务端日志/风控里必须能区分开。糊成一个 UA,服主看到的就是「一个客户端同时开了四五路并发」,最容易被当成盗刷限速(`http.rs:13-15`)。
护栏 `each_client_sends_its_own_user_agent`(`http.rs:433-482`):**真起一个服务器读实际发出的请求头**,不比对字符串常量 —— 比对常量只能证明 `format!` 没写错,证明不了 `.user_agent()` 真挂到了那个 client 上(`http.rs:424-426`)。

### 2.2 不设 UA 会怎样

reqwest 不设 UA = **一个 User-Agent 头都不发**,不是「发个默认的」。带 WAF 的公开 API 直接判成脚本流量:
2026-07-21 实测 `api.bgm.tv/v0/me`,同一个 Access Token,带 UA → **200**,不带 → **403(Cloudflare)**。
现象伪装成「Bangumi Access Token 明明有效却提示无效或已过期」,而 **curl 手测永远复现不出来** —— curl 自己会发 `curl/8.x`(`http.rs:29-33`、`:220-227`、`:429-432`)。
第三方那条 UA 按 bgm.tv 开发指引带上项目地址,方便对方风控找到人(`http.rs:33`)。

### 2.3 Accept-Encoding / 压缩(`http.rs:242-253`)

**分客户端,不能一把全开**:

- API 两条(`client` / `emby_client`)拉的是 JSON,`gzip(true).brotli(true)`。媒体库列表动辄几百 KB 到几 MB 的重复结构,gzip 后常剩 10~20%。
  原来 reqwest 是 `default-features = false` 且没勾 gzip/brotli —— 等于 **Accept-Encoding 一个字节都不发**,Emby 只好原样吐明文。
- 预取那条(`preload_client`)拉的是**视频字节流**,显式 `gzip(false).brotli(false)`。它靠 Content-Length 和 Range 语义对齐分段偏移,而**透明解压会把 Content-Length 变成解压后长度甚至直接抹掉 → 分段错位**。视频容器本来也压不动,开了纯亏。**这条是显式关掉,不是忘了开。**

护栏 `api_clients_negotiate_compression_but_media_client_does_not`(`http.rs:509-556`)。
为什么必须端到端发一次真请求:reqwest 的 `gzip(true)` 只有在 **crate feature 也勾了** 的前提下才真发 Accept-Encoding —— 少勾一个 feature,代码照编、测试照过、请求里一个字节都没有,而这正是改动前的状态(`http.rs:500-508`)。
features 现状:`reqwest = { default-features = false, features = ["json","socks","rustls-tls","charset","http2","gzip","brotli"] }`(`crates/core/Cargo.toml:14`)。

### 2.4 TLS

- rustls + ring provider + `webpki_roots`,自定义校验器 `HostAllowlistVerifier`(`http.rs:135-209`)。
- **自签名放行按 host 白名单,不是全局开关**(`http.rs:88-99`):
  之前是 `.danger_accept_invalid_certs(true)` —— 全局。后果不是「少了个功能」,而是**每台服务器的证书校验都是关的**,`Account::allow_insecure_tls` 纯属装饰:为了连自家 LAN 上那台自签名 Emby,顺带把公网所有 HTTPS 的中间人防护一起关了,且不报任何错。
  修法与 CF 改写点同构:收敛到唯一 choke point,88 个 http 调用点一个都不用改,以后新增的调用点也**绕不过去** —— 这是「加个 `client_insecure()` 让大家自觉选」做不到的。
- 白名单命中才跳过链校验和主机名校验(自签名证书 CN 通常也对不上);握手签名校验(`verify_tls12/13_signature`)**一律委派,不开后门** —— 它只验「对方确实持有该证书私钥」,不涉信任链(`http.rs:150-181`)。
- **ALPN 必须自己补**:`use_preconfigured_tls` 会让 reqwest 用我们这份 config,它自己那套 ALPN 设置不再生效 —— 不补 `cfg.alpn_protocols = ["h2","http/1.1"]`,h2 协商不上,所有请求悄悄降级 HTTP/1.1(不报错,只是慢)(`http.rs:205-207`,测试 `:325-329`)。
- rustls 版本**必须与 reqwest 内部同版(0.23)**,否则 `use_preconfigured_tls` 的 downcast 落空 → build() 报错(`Cargo.toml:17`)。
- 真握手护栏 `tls_verification_is_real`(`http.rs:344-368`,`#[ignore]` 需外网):四条断言 —— 有效证书通 / 自签名被拒 / 白名单内放行 / 放行 A 站不能顺带放行 B 站。
  「上面那些单测只证明白名单查表对,**证明不了 TLS 真的在校验**」(`http.rs:338-340`)。

### 2.5 代理

- 全局代理写在静态 `PROXY_URL`(`http.rs:45-47`),因为同步工厂 `client()` 读不到配置。
- 配置形状 `ProxyConfig { type_: none|http|https|socks5|socks4, host, port, username, password, proxy_media }`(`config.rs:376-407`)。
  - `proxy_url()`:http/https → `http://`,socks5 → `socks5://`,socks4 → `socks4a://`;用户名密码 `urlencoding::encode`(`config.rs:415-436`)。
  - `mpv_http_proxy()`:**仅 HTTP 系列 + 开启 `proxy_media`** 才返回。libmpv 只支持 `http-proxy`,SOCKS 只对 API/图片/字幕/下载生效(`config.rs:378`、`:437-444`)。
- **`set_proxy` 必须弃用三个缓存客户端**(`http.rs:54-60`):不清的话改完代理要**重启才生效** —— 用户在设置页切代理、点了保存、没反应,只会以为代理功能坏了。★ 三个都要清,漏一个那条路就还在用旧代理设置。护栏 `set_proxy_invalidates_cached_client`(`http.rs:485-498`)。
- **回环永不走用户代理**(`http.rs:63-76`):
  reqwest 的 `Proxy::all` 是**字面意义上的 all** —— 实测连 `http://127.0.0.1:<port>` 都会被塞给那个代理,代理再去连**它自己那边**的 127.0.0.1,本机的服务根本不在那头。
  - 代理在远端 → 直接连不上,「开了 CF 优选反而全挂」;
  - 代理在本机 → 侥幸能通,但每个分段都白绕一圈。
  修法:`no_proxy("localhost,127.0.0.1,::1")`(`http.rs:274`)。护栏 `loopback_never_goes_through_proxy`(`http.rs:375-421`,反向验证实测响应体变成 `PROXY`)。
- **mpv 不是我们的 reqwest**,它自己带 `http-proxy` 选项 —— 播放地址是回环时不给 mpv 挂代理(`http.rs:78-86` `is_loopback_url`;调用点 `apps/desktop/src/lib.rs:1745-1755`)。
- 客户端缓存(`http.rs:211-215`、`:255-282`):`reqwest::Client` 内部是 Arc,clone 极廉价,但 `build()` 要解析根证书 + 建连接池,每次请求重建等于**扔掉 keep-alive**。

### 2.6 图片回源并发闸(容易被漏掉的一条)

`apps/desktop/src/imgcache.rs:30-43`:同时最多 **6** 张图在回源。

> 这是「整个 App 都很慢」的一个真因,不只是图慢。封面和 `item_detail`/`views`/`list_latest` 这些 JSON 走的是**同一个 reqwest 客户端、同一个连接池、同一台服务器**。首页一屏三十几张封面同时回源时,后面点进详情页要的那条 JSON 排在它们后头 —— 用户看到的是「简介也加载得很慢」,而简介本身只有几 KB。反代(Nginx/CF)那边通常还有每 IP 并发上限。

- 6 是折中:小了首屏封面填得肉眼可见地慢,大了又开始和 API 抢。
- **缓存命中不占名额**(先查缓存再 `acquire`,`imgcache.rs:183-186`)。
- **有闸就必须有超时**:一条卡死的连接会把名额**永久**占住,六条卡死 = 整个应用再也加载不出任何一张图,而且一声不吭(`imgcache.rs:45-49`,20s)。
- 依赖 reqwest 默认跟 301:实测 UHD 那台的 `/Items/{id}/Images/Backdrop/0` 会 **301 跳静态文件**;不跟跳只会拿到 79 字节 HTML 被 sniff 判成 octet-stream —— 「图不显示但也不报错」(`imgcache.rs:178-182`)。**别给这个 client 关掉 redirect。**

---

## 3. 线路优选(cf)

### 3.1 三块拼图

| 模块 | 职责 |
|---|---|
| `cf/ranges.rs` | CF 官方 IP 段 + xorshift64 抽样 |
| `cf/speedtest.rs` | 三阶段测速,返回排序后的候选 IP |
| `cf/proxy.rs` | 本地 `127.0.0.1:<随机端口>` 明文 HTTP → 钉 IP 的 HTTPS 反代 |
| `cf/runtime.rs` | **全局路由改写表**:线路地址 → 本地反代基址 |

### 3.2 优选原理与抽样

CF anycast 按 SNI+Host 调度回源 —— 连到哪个 CF 边缘 IP 都能正确回源,只要 TLS SNI / HTTP Host 仍是你的域名。于是从官方段随机抽样、就近测速挑最快边缘(`cf/ranges.rs:1-5`)。
- IPv4:15 个官方 CIDR,按段大小**加权**随机;>/24 的段跳过头尾各 1 个;`max_guard = count*12+64` 防死循环(`cf/ranges.rs:11-27`、`:129-167`)。
- IPv6:取自 XIU2/CloudflareSpeedTest 的已优选活跃 /48 块,各前缀等概率,**只随机化低 32 位**(贴合真实 CF v6 优选 IP 形态 `<前缀>::xxxx:xxxx`)(`cf/ranges.rs:5`、`:29-66`、`:181-204`)。
- PRNG 是轻量 xorshift64,非密码学(`cf/ranges.rs:68-96`)。

### 3.3 speedtest 三阶段(`cf/speedtest.rs:259-341`)

默认参数(`cf/speedtest.rs:65-87`):`sample_count 256` / `latency_concurrency 64` / `ping_samples 4` / `ping_timeout 1s` / `max_loss_rate 0.5` / `max_latency_ms 500` / `latency_keep_top 24` / `download_wanted 8` / `download_duration 4s` / `min_download_kbps 2000`。

1. **握手延迟 + 丢包**:对每个 IP 做 `ping_samples` 次 TCP connect 到 `:443`,成功次数均值当延迟,失败率当丢包;`success == 0` 直接丢弃。分波并发(每波 `latency_concurrency` 个,等齐再下一波)(`cf/speedtest.rs:144-172`、`:240-257`)。筛掉 `loss_rate > 0.5` 或 `latency > 500ms`,排序取前 24。
2. **HTTP 校验**(可选,传 Emby 域名才做,并发 16):`https://<host>/cdn-cgi/trace`,2xx/3xx 算过 —— trace 由 CF 边缘直接应答不回源,能证明这个边缘确实在为该域名服务。剔除「TCP 通但 HTTP 死」的边缘。**校验结果为空直接返回空**(该域名可能压根不走 CF)(`cf/speedtest.rs:190-204`、`:279-306`)。
3. **下载测速**(顺序跑,命中 `download_wanted` 个即停):钉 IP、SNI = 测速域名,GET 100MB 测速文件,在 4s 窗内统计吞吐;要求 200 且至少下到 64KB(`cf/speedtest.rs:206-238`、`:308-322`)。
   最后:满足 `min_download_kbps` 的优先返回;都不满足按速度取最快;下载全失败(测速文件被墙)→ **退回已过 HTTP 校验的 IP 按延迟排**(`cf/speedtest.rs:324-340`)。

**排名综合分**(用户 2026-07-16:「别光看延迟,带宽也很重要 —— 延迟极低的一般带宽也极低」,`cf/speedtest.rs:89-103`):
`分 = 延迟(ms) − min(带宽Mbps,100) × 3`,越低越靠前。每 Mbps 抵约 3ms,带宽封顶 100Mbps(≈300ms 奖励)—— 既让带宽真正参与排序,又不至于让一个 480ms 的远端高带宽 IP 通吃。
旧版是硬分档(50ms 一档,同档才比带宽),一个延迟低但带宽差的 IP 仍能排在延迟略高、带宽高得多的前面。`tier_ms` 参数保留但新算法不用。护栏 `ranking_blends_latency_and_bandwidth`(`cf/speedtest.rs:347-362`)。
同批改动:`download_wanted` 4→8、`download_duration` 6→4s —— 否则只有最低延迟那几个被测带宽(`cf/speedtest.rs:76-77`)。

⚠️ `pinned_client` 用了 `danger_accept_invalid_certs(true)`(`cf/speedtest.rs:183`)。测速阶段合理(就是要用别人的 IP 打你的域名),但这条**不走** `http.rs` 的白名单校验器,Go 侧移植时别顺手复用成通用客户端。

### 3.4 反代(`cf/proxy.rs`)

- Rust 里 `reqwest .resolve(host, ip:443)` 一步到位:钉 IP、SNI/Host 仍是真实域名、keep-alive 连接池自带。Dart 版手写 TLS 隧道 + 连接池 + chunked 解析那一整套全省掉(`cf/proxy.rs:1-6`)。
- `redirect::Policy::none()` —— **反代忠实透传,不代客户端跟跳**(`cf/proxy.rs:121`)。
- 切 IP = **重建 client**(旧连接自然淘汰),端口不变,对进行中的会话无感;低频操作,重建成本可忽略(`cf/proxy.rs:8`、`:135-147`)。
- 逐跳头剔除:`host / connection / proxy-connection / keep-alive / upgrade / transfer-encoding`(`cf/proxy.rs:127-132`),`content-length` 也剔掉由本端重新框定(`cf/proxy.rs:206`)。
- 上游有 Content-Length → 原样;没有(chunked / 读到关闭)→ 对客户端用 chunked 重新框定(`cf/proxy.rs:222-234`、`:250-266`)。
  ⚠️ `stream_body` 出错时 `break` 但仍补 `0\r\n\r\n` 合法结束块 —— 这正是 prefetch 的「格式合法但短」响应来源之一(`cf/proxy.rs:260-266`,交叉引用 `prefetch.rs:603-604`)。
- 连不上上游 → 自造 `502 Bad Gateway`(`cf/proxy.rs:177-184`)。**这就是 prefetch 重签逻辑里「5xx 不一定是链到期」的来源**(`prefetch.rs:689-691`)。
- HEAD / 204 / 304 / 1xx 无实体;HEAD **如实回报资源长度**(mpv 用 HEAD 探大小)(`cf/proxy.rs:189`、`:214-220`)。
- **`Connection: close` 同样必须有**(`cf/proxy.rs:193-203`)。这条 bug 在预取代理上 2026-07-19 修过并留了同名测试,**这份同构代码当时漏了**,于是 2026-08-01 用户报了一字不差的症状。护栏 `response_declares_connection_close`(`cf/proxy.rs:390-421`)。

### 3.5 路由改写表(`cf/runtime.rs`)

**这是整套 CF 优选的唯一改写点**:登记 `线路地址 → http://127.0.0.1:port/<原路径前缀>`;`Account::active_line_url()` 拿当前生效线路的地址来查,命中则返回本地基址,于是 Emby API、封面图、mpv 取流 URL 全自动改走优选 IP,**与播放器实现无关**(`cf/runtime.rs:1-6`)。

- **键是线路,不是服务器**(2026-08-01 改,`cf/runtime.rs:8-14`):
  一台服有很多条线路,而用户明确说过「有些线路并没有使用 Cloudflare」。按服务器登记 = 只要这台服开过一次优选,**它的每一条线路**都被劫持到那个反代;而反代的上游 host 是开启时那条线定死的(`cf/proxy.rs` 的 `host` 只在 start 时取一次)—— 切到别的线路后请求被送到「A 线的域名 + 钉死的 CF IP」,**连得上、拿不到东西、全程不报错**,表现为加载极慢 / 没画面没声音。
- **键必须归一化**(去尾斜杠):线路地址是用户手填的,`https://a.com/` 与 `https://a.com` 必须同键 —— 不归一化就是「明明开了优选,`active_line_url` 却查不到」的静默失效(`cf/runtime.rs:25-30`,测试 `:137-144`)。宿主侧 `norm_line` 必须同口径,否则句柄表和改写表会错开(`apps/desktop/src/lib.rs:4323-4327`)。
- **`local_base` 必须保留上游路径前缀**:Emby 挂在 `https://h/emby` 子路径下时,丢掉 `/emby` 会让之后所有 API 打到 404 —— 「连得上但全 404」的静默故障(`cf/runtime.rs:69-77`,测试 `:105-111`)。
- `split_upstream` 的 IPv6 处理:`:` 出现在地址内部时不能当端口分隔符切(`cf/runtime.rs:85-97`,测试 `:114-121`)。
- 为什么是全局静态而不是塞进 AppState:改写点必须能被 `Account` 这个纯数据类型看见,而 Account 在平台无关核里拿不到宿主 State(`cf/runtime.rs:16-18`)。
- 宿主侧两条配套(`apps/desktop/src/lib.rs`):
  - 开关反代后必须 `refresh_session_base`,否则改写只对**之后**新建的会话生效,当前这条还打老地址 —— 「开了优选没反应,重启才生效」(`:4307-4321`)。
  - 起反代的上游必须用**线路原始地址**,绝不能用 `active_line_url` —— 反代已开时会把反代自己当上游,打成 127.0.0.1 → 127.0.0.1 的自环(`:4375-4377`)。
  - 「已开 → 只热切 IP」;注意别在持锁期间 await(先把句柄摘出来问完再放回,`:4355-4368`、`:4418-4427`)。

---

## 4. 下载引擎

`crates/core/src/download.rs`。同一时刻只下**一个文件**,单文件内 1–4 分段并发。

| 项 | 做法 | 出处 |
|---|---|---|
| 客户端 | `emby_client()`(UA = `LinPlayer/{版本}`) | `download.rs:197` |
| 探测 | `Range: bytes=0-0` → 206 + Content-Range 拿 total 且 `supports_range=true`;否则退回读 `Content-Length` + `Accept-Ranges: bytes`;探测失败 → `(0, false)` 单段整流 | `download.rs:569-599` |
| 分段 | 小文件(<2MB)不分段;否则 `threads.clamp(1,4)` 均分,末段吃余数;无 Range/未知大小 → 单段 `end = -1` | `download.rs:601-621` |
| 并发 | `JoinSet` 跑所有分段;**任一段出错立即 `cancel` 其余** | `download.rs:433-453` |
| 断点续传 | 每段独立 `${file}.partN` 追加写;重启按 part 文件实际大小恢复;`Downloading` 状态在加载索引时改回 `Paused` | `download.rs:4`、`:174-186`、`:466-482` |
| 僵尸截断 | part 文件超出区间长度 → `set_len` 截断,避免拼接错位 | `download.rs:557-563` |
| 拼接 | 全部完成后按序 1MB 缓冲拼接,然后删 part | `download.rs:623-645` |
| 索引持久化 | `dir/index.json`,全量 `serde_json` 覆写;`persist_blocking` = `rt.spawn(persist())` | `download.rs:172`、`:533-544` |
| 线程数 | `set_threads(n.clamp(1,4))` | `download.rs:205-207` |
| 进度 | **不主动推送**,前端轮询 `list()`;`recompute()` 派生 `received_bytes` / `progress` | `download.rs:7`、`:120-129` |
| 排队 | `process_queue` 取 `added_at` 最小的 Queued;`active_id` 非空直接返回 | `download.rs:326-342` |
| 文件名 | `safe_name(title)_{item_id}.{container}`;非法字符换 `_`,截 60 字符,空则 `video` | `download.rs:243`、`:671-685` |

**权限门控**:客户端**不做**权限判断。入队 URL 是 `{server}/Items/{id}/Download?api_key={token}`,由 **Emby 服务端按下载权限放行**(`apps/desktop/src/lib.rs:4450-4466`);401/403 翻译成「无下载权限」(`download.rs:664-668`)。
`grep -rn "EnableContentDownloading\|can_download"` 在 `apps/`/`crates/`/`ui/` 全仓零命中 —— 前端也没有基于 policy 的隐藏逻辑。

**`forget` vs `remove` 是一条契约线,别合并**(`download.rs:283-322`):
- `forget` 只清记录、**保留已下好的文件**(下载页「清除已完成」用它);正在下的条目交给 remove,不在这里半路截胡。
- `remove` 连文件一起删。
- `download_clear_completed` 必须调 `forget` 而不是 `remove`,否则和命令契约相反(`apps/desktop/src/lib.rs:4495-4511`)。
- 护栏:`forget_drops_record_but_keeps_file`(`download.rs:731`)/ `remove_deletes_file`(`:747`)。
  ★ `forget` 那条**必须先 sleep 300ms 再断言** —— `delete_files` 是 spawn 出去的,立刻断言 `exists()` 会在 bug 存在时也「赢下竞态」而假绿。**这个 sleep 才是这条测试有效的原因**(`download.rs:741-744`)。

**最要命的一条:同步命令里不能裸 `tokio::spawn`**(`download.rs:154-163`)
管理器的写路径被**同步** `#[tauri::command]` 调用,tauri 在收到 IPC 的那条线程上内联执行(tauri-2.11.5 `webview/mod.rs:1909 run_invoke_handler`),那是 **WebView2 的消息线程,没有任何 tokio 上下文**。裸 spawn 在那里 `panic("no reactor running")`,panic 穿过 FFI 边界 = 整个进程消失 —— 用户报的「一点下载就卡死然后闪退」。(`list()` 不 spawn,所以下载页打得开、一动就死。)
修法:`new()` 里抓一次 `tokio::runtime::Handle::current()` 存起来,之后全走 `rt.spawn`。
护栏 `write_path_survives_outside_tokio_context`(`download.rs:767-803`):**故意不放在 `#[tokio::test]` 里** —— 那个宏会给测试线程建好上下文,bug 就永远复现不出来;必须是裸 `std::thread`。运行时留到最后才 drop,提前 drop 会把 spawn 出去的 persist 掐死测出假绿。

---

## 5. 本地服务

### 5.1 localserve —— SMB 的 HTTP Range 桥(`net/localserve.rs`)

**为什么需要**:实测本仓打包的 libmpv **没有 smb 协议**(桌面 DLL 用 ctypes 读 `protocol-list`,68 个协议里没有 `smb`/`cifs`;安卓 .so 依赖符号反查也不含 libsmbclient 符号)。所以 SMB 上的片子必须由我们读字节、用 HTTP 喂过去。WebDAV 本来就是 HTTP,FTP mpv 自带,都不走这里(`localserve.rs:3-8`)。

**为什么不复用 prefetch 那个代理**(`localserve.rs:10-15`):那个代理的取数**焊死在 HTTP Range 上**(自己发 reqwest、跟 302、读 Content-Range 探大小,外面还套着磁盘环形缓存和多线程预取窗口)。改成可插拔上游要动 fetch/probe/重签三处核心,而那三处正是播放链路最不该乱碰的地方。这里要的只是「一个请求一段字节」。

- 抽象:`trait RangeSource { fn size() -> u64; async fn read_at(offset, len) -> Vec<u8> }`(`localserve.rs:24-32`),唯一实现在 `crates/core/src/source/smb.rs:236`。
- **一片一个端口**,换片就丢 handle;省掉「按路径路由 + 会话表 + 过期回收」那一整套(`localserve.rs:47-50`)。`Drop` → `task.abort()`(`:41-45`,测试 `:255-267`)。
- **只听 127.0.0.1**:这条流带着用户 NAS 的内容,不该出网卡(`localserve.rs:52-53`)。
- URL 路径给 `/stream` 带扩展名:ffmpeg 会拿 URL 尾巴猜容器格式(`localserve.rs:71-73`)。
- 每条连接一个 task:mpv 会为 seek 另开连接(我们回 close),串行处理的话新连接要等旧连接把整段喂完 = seek 卡死(`localserve.rs:62-63`)。
- 复用 `prefetch::read_request`(`localserve.rs:80`)。**416 判定、`Connection: close`、分块读发(512KB)三条全是照 prefetch 抄的踩坑结论**(`localserve.rs:16-18`、`:82-91`、`:110-114`、`:123-127`)。
- 一次性把整段(可能几百 MB)读进内存会直接把手机撑爆 → 512KB 一块(`localserve.rs:123-124`)。

### 5.2 companion —— 电视端局域网小网页(`crates/core/src/companion.rs`)

电视没摄像头,只能「电视出码、手机扫」;手机扫到的必须是它自己能打开的东西 → 电视自己当一小台 HTTP 服务器。走局域网不走云中转:不花服务器钱、断外网也能用、什么都不出家门(`companion.rs:4-7`)。
本模块**只做传输**(监听、路由、发那一页 HTML);业务由宿主壳注入的 `Handler` 处理(`companion.rs:9-12`、`:34-41`)。只有 Android/TV 壳接了(`apps/android/src/lib.rs:1430-1448`);desktop 零引用(`grep -c companion apps/desktop/src/lib.rs` = 0)。

**安全边界**(`companion.rs:15-21`):
- 路径带**一次性 token**(SHA256(纳秒) 前 6 字节 = 12 位十六进制,`companion.rs:197-205`),只在二维码和电视屏幕上出现,同局域网其它设备猜不到。token 不对或路径不认 → **一律 404,不透露任何别的信息**(`companion.rs:124-127`)。
- 只监听局域网(`0.0.0.0` 随机端口),**不做任何 UPnP/端口映射**,出不了家门(`companion.rs:68`)。
- 用户能在设置里整个关掉(默认开,否则遥控器每次要先去电视上打开 = 等于没有)。
- API 只收 POST(`companion.rs:128-130`);请求头 8KB 封顶、body 64KB 封顶(`:110-112`、`:132`)。
- 响应带 `Cache-Control: no-store` + `Connection: close`(`companion.rs:145-154`)。
- ⚠️ **明文 HTTP**。局域网内能抓包的人能看到密码 —— 和「在同一 Wi-Fi 下用 http:// 访问自建 Emby」同一档风险;不引 TLS(自签证书在手机浏览器上只会弹警告,反而把用户教成无视警告)(`companion.rs:19-21`)。
- 页面不引任何外部资源(局域网里没外网也要能开)(`companion.rs:207-208`)。

**拿不到局域网 IP 不算失败**(`companion.rs:61-66`):服务照起(0.0.0.0 上谁都能连),只是二维码里写不出地址 —— 此时 `url = None`、`ip_error` 说明原因,界面照样能显示端口和排查提示。上一版把这两件事捆在一起,IP 探测一失手整个手机遥控就「不存在」,界面只说「未开启」完全查不下去。
`lan_ip()` 用 **UDP connect 不发包**让内核挑一条出口路由,取其源地址,不枚举网卡;**试 5 个目标不是 1 个**(223.5.5.5 / 114.114.114.114 / 8.8.8.8 / 192.168.1.1 / 10.0.0.1)—— 「哪条路由存在」各家网络不一样,上一版只打一个目标,一失手整个功能就消失(`companion.rs:167-195`)。

### 5.3 lpimg 自定义 scheme(`apps/desktop/src/imgcache.rs`,Android 同款)

严格说不是「网络服务」,但它是图片这条网络路径的入口,一并记:
- 前端只给 `lpimg://…/i/{itemId}/Primary?h=480`,**URL 里没有 token**;上游地址由 Rust 从会话里现拼(`imgcache.rs:1-9`)。此前是把 `?api_key={token}` 直接塞进 `<img src>`,token 进 DOM、进 webview 网络日志、进 Emby access log(`image_cache.rs:10`)。
- 路径是**从 webview 来的、可被页面内容影响的字符串,当它不可信**:kind 走白名单,itemId 只放行 `[0-9a-zA-Z-]`(堵死 `../` 和 `? &`),query 只放行 `h`/`w` 且值必须全数字(`imgcache.rs:102-127`、`:165-176`)。
- 缓存键用**账号主键**(`a.server`)而不是当前线路地址,更不能用完整上游 URL(里面有 api_key,重登一次 token 变了缓存全废)(`imgcache.rs:145-148`;同一条口径写在 `image_cache.rs:15-18`)。
- 失败必须回 **404 而不是 200+空体**:空体会被当成一张坏图,前端 `onError` 也不触发 —— 又一个「不报错,只是不显示」(`imgcache.rs:87-88`)。
- `Access-Control-Allow-Origin: *` 是给**取主色**用的:`lpimg` 和页面不同源,没有这个头 canvas 被污染,`getImageData` 抛 SecurityError → 「渐变永远不出现」且错误被 try 吞掉(`imgcache.rs:76-83`)。
- MIME **按魔数嗅,不信上游 Content-Type**:反代经常抹成 `application/octet-stream`,那样浏览器不认,图就是不显示且不报错(`imgcache.rs:214-215`;`icon_cache.rs:30-32` 同款教训)。
- `image_cache` 是**同步阻塞 IO**,在 async 里必须 `spawn_blocking` —— 一屏几十张图并发时会把整个 tokio 运行时按住(`imgcache.rs:150-153`、`image_cache.rs:143-146`)。

### 5.4 图片缓存本体(`image_cache.rs` / `icon_cache.rs`)

- 两层:L1 内存 128MB + L2 磁盘 2GB / 30 天 TTL(`image_cache.rs:26-31`)。「只有磁盘 = 每次重挂 `<img>` 都是一次 open+read+解码;只有内存 = 关了程序全没」(`:59-62`)。
- 内存淘汰 = HashMap + 自增计数当时间戳,线性扫;条目约 1300,「为这点规模引 lru crate 不值当(而且它还得进依赖树、进安卓交叉编译)」(`image_cache.rs:63-65`)。
- 单张 > `MEM_MAX/8` 不进内存(超大 backdrop 会把整个缓存挤空,换来它自己一张命中);磁盘照存(`:97-100`)。
- 淘汰留 10% 余量而不是卡着上限,否则「每存一张就得淘汰一张」把扫描成本摊到每次写入(`:91-94`、`:212-215`)。
- 写盘**先写 tmp 再 rename**:直接写目标文件的话写到一半进程被杀,半张图会被后续 `get()` 当成有效缓存 —— 「封面永远是坏的,删缓存才好」(`:193-195`)。
- 攒够 64MB 新字节才扫一次(`SWEEP_EVERY`):每次写入都扫 = 每存一张封面就 readdir 几万个文件,比不缓存还慢(`:34-36`)。
- 命中且 age > 1 天才 touch mtime:不 touch 会退化成 FIFO,常看的封面照样被淘汰 = 白缓存;每次命中都 touch 是拿磁盘 IO 换空气(`:162-166`)。
- 清缓存**必须连内存层一起清**,否则用户看着占用变 0 却还是旧封面 = 在骗他(`:134-135`;调用点 `apps/desktop/src/lib.rs:2876`)。
- 键名哈希成定长十六进制:键里有 `/` `:` 在 Windows 上建不出文件名,而且可能超长(`:44-52`)。
- `icon_cache` 单独一套,吐 **base64 data URI**(Tauri 的 assetProtocol 默认关着,为一张几十 KB 的图去开 asset 协议+配 scope 不值)(`icon_cache.rs:1-5`);封面走 lpimg 不走 base64(33% 膨胀 + IPC JSON 序列化,给主线程加活)(`imgcache.rs:11-14`)。
- 两处都有单张上限,防「图标/图片地址被填成一部电影的直链」把内存吃穿(`icon_cache.rs:10-12` 4MB;`image_cache.rs:32-33` 32MB)。`Content-Length` 可以缺席或撒谎,拿到实际字节后**再判一次**(`icon_cache.rs:81-84`)。

---

## 6. 踩坑清单

> 格式:症状 / 真因 / 现在怎么处理 / Go 侧怎么落 / 出处

### P1 · 「有流量、没画面没声音、加载不出来」— 长连接吞 seek
- **症状**:mpv 收到 206 头,有网络流量,但一帧不出;有时慢到离谱。ffprobe 实测 `1 connection, 1 request, 0 seeks`,退化成从头线性读完整片(289MB 全下、73 段全拉)。
- **真因**:我们每条 TCP 只读**一个**请求,而 HTTP/1.1 默认长连接。不写 `Connection: close` 就是在对播放器承诺「这条连接还能再发请求」。ffmpeg 一 seek(MKV 索引在末尾,起播必 seek)就把 `Range:` **管线化发在同一条 socket 上**,那个请求没人读,响应永远不来。
- **现在**:三处本地服务全部显式 `Connection: close`。
- **Go 侧**:即使用 `net/http.Server`,pipelining 也只会**串行**处理 —— 第二个请求的 handler 要等第一个 handler 返回,而我们的 handler 会一直流到文件尾,所以**症状完全一样**。必须 `w.Header().Set("Connection","close")`(Go 的 `net/http` 会认这个头并关连接),或全局 `srv.SetKeepAlivesEnabled(false)`。
- `prefetch.rs:785-795` / `cf/proxy.rs:193-203` / `localserve.rs:110-114`

### P2 · 「开了黑屏、永远缓冲」— 并发连接共用取数游标
- **症状**:响应头已发出、body 一个字节不来。
- **真因**:旧版把取数窗口(serve_chunk/fetch_cursor/ready)放在 Session 上**全局共用**,每条进来的 HTTP 请求都 `reset()` 把游标拽到自己的起点并 `ready.clear()`。mpv 探 MKV(带大字体附件、索引在末尾)会在旧连接没关时就新开一条 —— 后来者一 reset,前一条正在 await 的分段就再也没人去拉了。
- **现在**:每条连接持有自己的 `Stream`(独立窗口 + 独立 worker);共享的只有探测结果、上游地址和磁盘缓存。
- **Go 侧**:每个 handler goroutine 持有自己的窗口结构体,`Origin` 只放共享只读态 + 磁盘缓存 + live 登记表。
- `prefetch.rs:9-16`

### P3 · 「有流量没画面」第二根因 — worker 无超时,吊死
- **症状**:`Stream opened successfully` → duration=0、一帧不出、0 条轨道、**零日志**。curl 打本地代理:`206, size=0, 25s 仍在等`。
- **真因**:`send()`/`bytes()` 无限期等待,而 `http.rs` 三个 client 一个 timeout 都没设。上游黑洞 → worker 永远等,不重试、不重签、不报错;供给端跟着一起等。
- **现在**:建连+响应头 20s 整体;收体 20s **空闲**(每收一块重置)。
- **Go 侧**:**绝对不要用 `http.Client.Timeout`** —— 它是包含 body 读取的**整体**超时,正是这里踩过的那个错。用 `Transport.ResponseHeaderTimeout` 管头阶段,body 阶段自己包一层「每次 Read 前重置的计时器」(或用底层 conn 的 `SetReadDeadline`)。
- `prefetch.rs:46-55`、`:622-636`;`http.rs` 全文无 timeout

### P4 · 「慢但能用的链路被掐死」— 整体超时是错的修法
- **症状**:修完 P3 之后,56~143KB/s 的真实链路一路重试、放大负载。
- **真因**:第一版写成整体超时(15s),而拉满一个 4MB 分段在那条链上**合法地要 29~62 秒**。
- **现在**:判据只能是「一段时间**一个字节都不来**」。
- **Go 侧**:两条测试必须都有 —— 只有「黑洞会放弃」会诱导你写整体超时,只有「慢链路不被掐」会诱导你去掉超时。
- `prefetch.rs:52-54`、`:2486-2496`

### P5 · 「开了多线程加载就播不出来」— 把预取粒度当成供给粒度
- **症状**:开多线程加载没画面没声音,直连反而秒开(直连时 mpv 只拉它真正要的那几百 KB)。
- **真因**:供给端等**整段 4MB 落盘**才吐第一个字节;而 mpv 起播只要头几百 KB + 尾部 cues。
- **现在**:边收边吐(`Live` 载体 + `notify`),落盘照旧但不挡在播放器前面。
- **Go 侧**:`Live` = `[]byte` + `sync.Mutex` + `chan struct{}` 广播(或 `sync.Cond`)。**别靠调小 CHUNK_SIZE 绕**(几个测试会假绿)。
- `prefetch.rs:198-208`、`:1653-1664`

### P6 · 「拖一次进度条画面 13 秒不动」— 首段从边界开拉
- **症状**:seek 后长时间黑屏。
- **真因**:每次 seek 是新连接,起点几乎不落在 4MB 边界上;从边界拉 = 在播放器要的第一个字节前先白拉平均 2MB。
- **现在**:首段用残段载体 `Live::based(head_within, …)`,fetch 起点 = `c*4MB + base`;残段不进共享登记处也不落盘。
- **Go 侧**:测试断言要**同时**看「上游实际收到的 Range 起点」(确定性)和端到端耗时(受机器负载影响)。
- `prefetch.rs:606-609`、`:459-465`、`:1829-1840`

### P7 · 「跳一次进度条烧掉几 GB 流量」— 被抛弃的连接照着窗口拉满
- **症状**:快速拖进度条,流量暴涨;窗口 GB 级时更夸张。
- **真因**:被丢下的连接**还会把整个预取窗口填满才罢休**;而窗口一度跟着缓存上限放开到 GB 级。
- **现在**:两刀 —— ①窗口独立于缓存上限,硬顶 64MB;②serve 侧 `peer_gone` + worker 侧 `done_notify` 取消在飞请求。
- **Go 侧**:①handler 的 `r.Context()` 在客户端断开时会 Done,直接把它当 `done_notify`,传给每个 worker 的 upstream request;②测试**必须按字节计**,按请求数计的话 worker 那层怎么改都是绿的。
- `prefetch.rs:35-44`、`:875-879`、`:2327-2335`

### P8 · 「画面坏掉但不报错」— 环形缓存 TOCTOU 串数据
- **症状**:错帧;实测 B 连接在自己的起始位置读到 A 的字节。
- **真因**:「写完盘再更新 slots」+ 读侧两段式 `has()`→`get()`;环形槽位全连接共享,段号模 ring 同余必然同槽,多连接下**必然会撞**。
- **现在**:`put` 全程持锁且先失效再写;`get` 校验+读盘同一把锁;读完**不许**再复核(会自锁)。
- **Go 侧**:一把 `sync.Mutex` 护住 slots map,`get` 在锁内做 `ReadAt`。Go 的 `sync.Mutex` 同样**不可重入**,同一个自锁陷阱照样存在。
- `prefetch.rs:377-383`、`:406-409`、`:427-430`

### P9 · 「连接饿死」— 段被挤掉无人重拉
- **症状**:有流量、黑屏/永远缓冲,或 early eof;CI 上 5~20% 概率红。
- **真因**:段被别的连接挤出槽位后 `disk.has()` 恒 false,而 `fetch_cursor` 已越过它,再没人会重拉 → `next_bytes` 无限空转。
- **现在**:自愈把 `fetch_cursor` 倒回 c(幂等),并用 `in_flight` 把「在飞」和「被挤掉」分开。
- **Go 侧**:测试**必须跨段读** —— 只在一段之内读根本测不出来(供给端要么在直播载体上现读、要么一次把整段从盘上取回,压根不会再问磁盘第二次)。
- `prefetch.rs:995-1017`、`:1353-1356`

### P10 · 「读回一整块稀疏零并当作视频发出去」— 缓存文件重名
- **症状**:确定性数据损坏;CI 上表现为并发测试偶发红。
- **真因**:文件名是 `s{pid}_{total}.part`,而两个会话可以并存(孤儿播放器未 Drop + 新播放器已起);后者 `truncate(true)` 清零前者数据,前者 slots 表仍说「就绪」。
- **现在**:名字加进程内自增 `seq`;起服时 `sweep_orphans` 清别的 pid 的残留。
- **Go 侧**:直接用 `os.CreateTemp` 或加 UUID/自增序号。清扫时只删前缀不是自己 pid 的,删不掉一律忽略。
- `prefetch.rs:334-347`、`:306-326`

### P11 · 「一次网关抖动把重签永久关掉」
- **症状**:长片播到签名过期时断流。
- **真因**:旧逻辑把「重签回来的地址和旧的一样」也当失败并永久停用;而开了 CF 优选时上游是本机反代,它一个 502 就会触发重签,重签当然还解析出同一个 127.0.0.1。
- **现在**:只有回调返回 `None`/空串才停用。
- **Go 侧**:5xx **不能**默认等于「链到期」,因为 502 可能是我们自己的反代造的。
- `prefetch.rs:711-716`、`cf/proxy.rs:177-184`

### P12 · 「多线程加载成了负优化」— 每段重走 302
- **症状**:3 线程 4.0MB/s **慢于**单连接 4.3MB/s。
- **真因**:UHD 那类服务端 302 跳 CDN,每 4MB 一次独立请求就重走一次 302,实测 0.67s/段(占单段 TTFB 1.4s 的一半)。
- **现在**:probe 那次跟完 302 把 `resp.url()` 存下来,worker 优先打它;失败时清空回落。
- **Go 侧**:`resp.Request.URL` 拿最终 URL。**注意**:Go 默认最多跟 10 跳,和 reqwest 默认一致,不用改;但 CF 反代和测速客户端必须 `CheckRedirect: func(...) error { return http.ErrUseLastResponse }`。
- `prefetch.rs:166-179`、`:535-539`

### P13 · 「Bangumi Access Token 明明有效却提示无效」— 一个 UA 头都没发
- **症状**:403,伪装成 token 失效;**curl 手测永远复现不出来**(curl 自带 UA)。
- **真因**:reqwest 不设 UA = 一个 User-Agent 头都不发;Bangumi 的 Cloudflare 直接判脚本流量。
- **现在**:第三方那条改成 `LinPlayer/{版本} (+项目地址)`,三条道仍然分得开。
- **Go 侧**:**方向相反的坑** —— Go 的 `http.Client` 不设时会发 `User-Agent: Go-http-client/1.1`。403 不会发生,但会**把 Go 的默认 UA 泄给服主**,三条道也分不开。必须三条都显式设置。(真要不发 UA 得写 `req.Header["User-Agent"] = nil`。)
- `http.rs:29-33`、`:220-227`

### P14 · 「Emby 的列表 JSON 全程明文传」+ 「预取分段错位」
- **症状**:前者只是慢(几百 KB~几 MB 的重复结构没压缩);后者是黑屏。
- **真因**:reqwest `default-features = false` 且没勾 gzip/brotli → Accept-Encoding 一个字节都不发;而如果反过来给预取客户端也开压缩,透明解压会把 Content-Length 变成解压后长度甚至抹掉。
- **现在**:API 两条开,预取那条显式关。
- **Go 侧**:**Go 的默认行为更危险** —— `http.Transport` 默认自动加 `Accept-Encoding: gzip` 并透明解压,且**此时把 `resp.ContentLength` 置为 -1、删掉 `Content-Encoding`**。预取/下载/CF 反代的 transport 必须 `DisableCompression: true`。API 那条反而白送。
- `http.rs:242-253`、`Cargo.toml:14`

### P15 · 「开了 CF 优选反而全挂」— 回环被塞进用户代理
- **症状**:用户配了代理之后,CF 优选/预取代理连不上。
- **真因**:`reqwest::Proxy::all` 是字面意义上的 all,连 `http://127.0.0.1:<port>` 都会递给代理,代理再去连**它自己那边**的 127.0.0.1。
- **现在**:`no_proxy("localhost,127.0.0.1,::1")`;mpv 那边用 `is_loopback_url` 单独判。
- **Go 侧**:`Transport.Proxy` 是 `func(*http.Request) (*url.URL, error)` —— **必须在这个函数里对回环 host 返回 `nil, nil`**。`http.ProxyURL(u)` 和 reqwest 一样是无条件全代理。(`http.ProxyFromEnvironment` 会读 `NO_PROXY`,但我们的代理是配置来的不是环境变量来的。)
- `http.rs:63-76`、`:271-276`

### P16 · 「改了代理没反应,重启才生效」
- **真因**:三个 client 有进程级缓存,`set_proxy` 没弃用它们(`set_insecure_hosts` 一直有做,这里漏了)。
- **现在**:`set_proxy` 清三个槽。
- **Go 侧**:同样的坑 —— Go 里 `http.Client`/`Transport` 也是要复用的(每次新建 = 扔掉连接池)。配置变更时必须换掉 Transport 并 `CloseIdleConnections()`。
- `http.rs:54-60`

### P17 · 「为了连自家自签名 NAS,把公网所有 HTTPS 的中间人防护一起关了」
- **真因**:`.danger_accept_invalid_certs(true)` 是全局的,`allow_insecure_tls` 字段纯属装饰,且不报任何错。
- **现在**:自定义校验器 + 按 host 白名单,收敛到唯一 choke point,88 个调用点绕不过去。
- **Go 侧**:`tls.Config{ InsecureSkipVerify: true, VerifyPeerCertificate: func(rawCerts, _) error { 白名单命中 → nil;否则手工 x509.Verify } }`。**注意 Go 的 `VerifyPeerCertificate` 在 `InsecureSkipVerify=true` 时 `verifiedChains` 是空的,必须自己建链验证。**
- `http.rs:88-99`、`:135-185`

### P18 · 「h2 协商不上,所有请求悄悄降级 HTTP/1.1」
- **真因**:`use_preconfigured_tls` 让 reqwest 用我们的 config,它自己那套 ALPN 设置不再生效。
- **现在**:手动 `cfg.alpn_protocols = ["h2","http/1.1"]`。
- **Go 侧**:**一模一样的坑**。给 `http.Transport` 设了自定义 `TLSClientConfig` 之后,HTTP/2 自动升级会失效 —— 必须 `ForceAttemptHTTP2: true`(或手动 `NextProtos = []string{"h2","http/1.1"}` + `http2.ConfigureTransport`)。不报错,只是慢。
- `http.rs:205-207`

### P19 · 「一点下载就卡死然后闪退」
- **真因**:同步 `#[tauri::command]` 跑在 WebView2 消息线程,没有 tokio 上下文;裸 `tokio::spawn` 当场 panic,穿过 FFI 边界 = 进程消失。
- **现在**:管理器里抓 `Handle` 存起来。
- **Go 侧**:Go 的 `go func(){}` 没有这个问题(goroutine 不需要「运行时上下文」)。**但同构的坑仍在**:从 C ABI 边界回调进 Go 时 panic 一样会杀进程 —— FFI 入口必须 `defer recover()`。
- `download.rs:154-163`、`:767-803`

### P20 · 「预热白做」— 起播新起句柄
- **真因**:`ProxyHandle` Drop 会删缓存文件;起播时不复用就等于把预热的几十 MB 扔了。
- **现在**:`prefetch_proxy_for` 按上游地址查已有句柄;判据和「这台服开没开多线程加载」无关。
- **Go 侧**:句柄表的锁**绝不能跨 await/阻塞调用**(Rust 侧为此专门加了显式作用域)。
- `lib.rs:4728-4755`、`:1707-1713`

### P21 · 「热一下变成把整部片偷偷下下来」
- **真因**:服务端无视 Range 回整片(真发生过,`[[server-ignores-http-range]]`)。
- **现在**:`pull()` 自己 `while n < limit` 封顶。
- **Go 侧**:`io.LimitReader` 一行搞定,但**别忘了这条约束存在的理由**。
- `preload.rs:127-128`、`:214-216`

### P22 · 「开了优选没生效 / 关不掉」— 键没归一化
- **真因**:线路地址用户手填,尾斜杠有无算两个键;改写表和句柄表两处口径必须一致。
- **现在**:`key()` 去尾斜杠;宿主侧 `norm_line` 同口径。
- `cf/runtime.rs:25-30`、`lib.rs:4323-4327`

### P23 · 「连得上但全 404」— 反代丢了子路径前缀
- **真因**:Emby 挂在 `https://h/emby` 子路径下时,`local_base` 不带 `/emby`。
- **现在**:`local_base` 保留上游 path。
- `cf/runtime.rs:69-77`

### P24 · 「切了线路就加载极慢/没画面,且不报错」— 优选按服务器登记
- **真因**:一台服有多条线路,而反代的上游 host 在 start 时就定死了;按服务器登记 = 把非 CF 线路也劫持到「A 线域名 + 钉死的 CF IP」。
- **现在**:键是线路。
- `cf/runtime.rs:8-14`

### P25 · 「简介也加载得很慢」— 封面把连接池占满
- **真因**:封面和详情 JSON 共用同一个 client / 连接池 / 服务器;一屏三十几张封面同时回源把 JSON 排到后头,反代还有每 IP 并发上限。
- **现在**:回源并发闸 6 + 单张 20s 超时;缓存命中不占名额。
- **Go 侧**:`chan struct{}` 当信号量。**有闸必须有超时** —— 六条卡死 = 整个应用再也加载不出任何一张图,且一声不吭。
- `imgcache.rs:30-49`、`:183-186`

### P26 · 「封面永远是坏的,删缓存才好」
- **真因**:直接写目标文件,写到一半进程被杀留下半张图,后续 `get()` 当成有效缓存。
- **现在**:先写 `.tmp` 再 `rename`(同分区原子)。
- `image_cache.rs:193-204`

### P27 · 「重登一次整盘图片缓存全废」
- **真因**:拿带 `api_key` 的上游 URL 当缓存键。
- **现在**:键 = 账号主键 + 条目 + 图种 + 尺寸;**也不能用当前线路地址**(切线路会全落空)。
- `image_cache.rs:15-18`、`imgcache.rs:145-148`

### P28 · 「图不显示但也不报错」×2
- 不跟 301 → 拿到 79 字节 HTML 被 sniff 判成 octet-stream(`imgcache.rs:178-182`)。
- 信上游 Content-Type → 反代抹成 octet-stream,浏览器不认(`imgcache.rs:214-215`、`icon_cache.rs:30-32`)。
- **现在**:保留 redirect;MIME 按魔数嗅。

### P29 · 「手机遥控整个不存在」— IP 探测失手就当服务没起来
- **真因**:把「拿不到局域网 IP」和「服务没起来」捆在一起,界面只说「未开启」;而 `lan_ip` 只打一个探测目标。
- **现在**:两件事分开(`url: Option` + `ip_error`);探 5 个目标。
- `companion.rs:61-66`、`:167-195`

---

## 7. Go 侧移植要点

### 7.1 Go 天然更好的地方

| 点 | 说明 |
|---|---|
| 客户端断开检测 | `r.Context()` 在客户端断开时自动 Done,直接替掉手写的 `peer_gone`(`prefetch.rs:1030-1043`)。把它当 worker 的取消信号传下去,P7 那两层修法合成一层。 |
| 稀疏文件读写 | `os.File.ReadAt/WriteAt` 天然并发安全、免 seek,可以去掉 Rust 侧那把 `file` 互斥锁(`prefetch.rs:389-399`)。**但 slots 表那把锁不能去**(N14)。 |
| 阻塞 IO | goroutine 里直接同步读盘,不需要 `spawn_blocking`;`image_cache` 那条「同步阻塞 IO 必须包 spawn_blocking」的告诫自动消失(`image_cache.rs:143-146`)。 |
| Range 服务 | `http.ServeContent` 会处理 Range/416/If-Range,如果把环形缓存包装成 `io.ReadSeeker`。**但它默认支持 keep-alive 和 multi-range**,要谨慎(见下)。 |
| 分段下载 | `errgroup.Group` + `WithContext` 比 `JoinSet` + 手动 `cancel.store(true)` 干净(`download.rs:433-453`)。 |
| 局域网 IP | `net.Dial("udp", target)` 拿 `LocalAddr` 和 Rust 版一模一样,零依赖(`companion.rs:167-195`)。 |
| 测速并发 | `golang.org/x/sync/semaphore` 或 buffered chan 替掉「分波并发」(`cf/speedtest.rs:240-257`)。 |

### 7.2 Go 的默认行为会咬人的地方

**① `http.Client.Timeout` 是整体超时(含 body)**
这正是 P4 踩过的那个错。预取/下载/CF 反代**一律不设** `Client.Timeout`。
分开设:`Transport.DialContext` 里的 dial timeout、`Transport.TLSHandshakeTimeout`、`Transport.ResponseHeaderTimeout`(对应 `prefetch.rs:639-646`),body 阶段自己做**空闲超时**。

**② `Transport` 默认自动 gzip 并把 `ContentLength` 置为 -1**
Go 的 transport 在你没自己写 `Accept-Encoding` 时会加 `gzip` 并透明解压,此时 `resp.ContentLength == -1`、`Content-Encoding` 被删。预取靠 Content-Length 和 Range 对齐分段偏移 → **必须 `DisableCompression: true`**(对应 `http.rs:242-253` 的 `Compress::No`)。
反过来,API 那两条什么都不用做就有压缩。

**③ keep-alive 默认开(两个方向)**
- 客户端方向:好事,worker 复用连接。但 `MaxIdleConnsPerHost` 默认只有 **2**,而我们对同一个 host 开 2~4 条并发 Range —— 应设成 `>= threads`,否则每段结束都会关连接重连(等于把 P12 的建连成本换个形式赔回来)。
- 服务端方向:**必须关**。见 P1 —— Go 的 `http.Server` 虽然能正确读第二个 pipelined 请求,但会**等第一个 handler 返回**才处理,而我们的 handler 一直流到文件尾 → 症状和 Rust 版完全一样。用 `Connection: close` 响应头,或 `srv.SetKeepAlivesEnabled(false)`。

**④ `resp.Body` 必须 drain + Close 才能复用连接**
取消/提前放弃时只 `Close()` 不 drain,连接会被丢弃(不算错,但会退化成每段重连)。取消路径用 `context` 取消而不是直接 Close,让 transport 自己处理。

**⑤ 重定向策略默认跟 10 跳**
和 reqwest 默认一致 → 预取/预加载/图片这几条**保持默认**(P12、P28)。
但 **CF 反代和 speedtest 必须 `CheckRedirect: 返回 http.ErrUseLastResponse`**(对应 `cf/proxy.rs:121`、`cf/speedtest.rs:184`)—— 反代要忠实透传 302 给客户端,不能代跳。

**⑥ `Transport.Proxy` 无条件代理**
和 `reqwest::Proxy::all` 同样的坑(P15)。Proxy 函数里必须先判回环返回 `nil, nil`。

**⑦ 自定义 `TLSClientConfig` 会关掉 HTTP/2 自动升级**
和 `use_preconfigured_tls` 吃掉 ALPN 是同一个形状(P18)。`ForceAttemptHTTP2: true`。

**⑧ `InsecureSkipVerify=true` 时 `VerifyPeerCertificate` 的 `verifiedChains` 是空的**
按 host 白名单放行必须自己 `x509.Certificate.Verify` 建链(P17)。

**⑨ Go 默认发 `User-Agent: Go-http-client/1.1`**
方向和 P13 相反,但同样必须三条都显式设(否则服主日志里全是 Go 默认 UA,三条道分不开)。

**⑩ `net/http` 没有导出的 Range 解析器**
`http.ParseRange` 是未导出的(`net/http/fs.go` 里的 `parseRange`)。要么用 `http.ServeContent` 让它自己处理,要么照 `prefetch.rs:1113-1130` 手抄一份 —— 注意保留「后缀 Range `bytes=-N` 返回 nil 走全量」这个行为(N26),以及**416 判定用钳位前的 start**(N3)。

**⑪ `sync.Mutex` 不可重入**
P8 那个自锁陷阱(`prefetch.rs:427-430`)在 Go 里一字不差地存在,而且 Go 的死锁检测只在**所有** goroutine 都睡死时才报。

**⑫ Windows 上的稀疏文件**
Rust 侧注释说「稀疏文件,实际占用只有已下载的部分」(`prefetch.rs:291`),但代码里没有任何标记稀疏的调用。Linux/macOS 上写高位偏移天然稀疏,**Windows NTFS 默认不稀疏**(需要 `FSCTL_SET_SPARSE`)。因为 ring 已经把文件长度封顶在用户设的上限,实际影响有限,但 Go 版别把这句注释原样抄过去 —— 见 §9。

**⑬ 别用 `http.ServeContent` 直接顶掉 handle()**
它支持 multi-range(会发 `multipart/byteranges`)、支持 keep-alive、会自己发 `Last-Modified`/ETag,还会在 `If-Range` 上做决定。我们的语义是「一请求一连接、单区间、顺序流」。用它就得把这些全关掉,不如手写 —— Rust 版手写的那 50 行(`prefetch.rs:749-833`)已经把踩过的坑都编码进去了。

### 7.3 移植顺序建议

1. `http`(三客户端 + UA + TLS 白名单 + 代理 + 回环豁免)—— 所有人都依赖它,且护栏测试最好写。
2. `localserve`(最小的那个 Range 服务)—— 先把 `Connection: close` / 416 / 分块读发这套 HTTP 应答骨架跑通,它是 prefetch 的子集。
3. `download`(纯客户端,无本地服务)。
4. `cf`(runtime → proxy → speedtest → ranges)。
5. `prefetch`(最后,且要求 §1.4 的 30 条不变量各有测试)。
6. `preload`(依赖 prefetch 的句柄复用契约)。

---

## 8. 现有测试的价值

### 8.1 真门禁(每条都写明了反向验证方式)

`prefetch.rs` 共 23 条测试(1 条 `#[ignore]`)。**每条注释里都写了「反向注入什么会让它红」** —— Go 版重写时按那个注入方式验一遍,是最省事的「测试必须先红」。

| 测试 | 钉住的不变量 | 反向验证 | 行号 |
|---|---|---|---|
| `two_live_sessions_never_share_one_cache_file` | N24/N14 | 文件名改回 `s{pid}_{total}.part` → `a.get(0)` 返回全零 | `:1144` |
| `read_ahead_is_capped_and_respects_user_limit` | N13 | 公式改回 `MAX.min((CHUNK*t*2).max(limit))` | `:1175` |
| `disk_cache_is_capped_not_proportional_to_file_size` | N12 | `ring` 改成 `total.div_ceil(CHUNK)` | `:1198` |
| `parses_range_forms` | N26 | — | `:1216` |
| `prefetch_serves_bytes_identical_to_upstream` **(ignored)** | 端到端字节一致 | 需 `LP_TEST_STREAM` 真流 | `:1230` |
| `evicted_chunk_is_refetched_not_awaited_forever` | N16/N17 | 删掉 `next_bytes` 里「倒回 fetch_cursor」→ 必然超时 | `:1285` |
| `concurrent_connections_do_not_starve_each_other` | N2 | 窗口换回全局共享 + 每请求 reset | `:1380` |
| `fetches_sequentially_without_duplicates` | N20/N29 | — | `:1474` |
| `short_upstream_chunk_breaks_stream_instead_of_hanging` | N5 | 去掉 `fetch_chunk` 的长度校验 → 挂死超时 | `:1591` |
| `first_bytes_reach_the_player_before_the_whole_chunk_arrives` | N7 | `next_bytes` 改回只认 `disk.has` | `:1665` |
| `retry_after_partial_body_resumes_instead_of_duplicating` | N8 | 删掉 `Live::feed` 的 skip | `:1761` |
| `seek_does_not_wait_for_the_bytes_before_it` | N9 | worker 里 `partial` 判定改成恒 false | `:1841` |
| `bytes_pulled_by_one_connection_are_free_for_the_next` | N11/N25 | 删掉 `next_bytes` 里 `disk.has/get` 那段 | `:1941` |
| `stale_cache_files_from_dead_processes_are_swept` | N24 | 删掉 `create()` 里的 `sweep_orphans` | `:2053` |
| `same_url_does_not_disable_resign` / `new_url_is_adopted_and_none_disables` | N23 | 删掉 `Some(f) if !f.is_empty() => {}` 那条 | `:2096` / `:2105` |
| `response_declares_connection_close` | **N1** | 删掉那行 `Connection: close` | `:2177` |
| `out_of_range_start_gets_416_not_bogus_206` | N3 | 越界判定改回用钳位后的 start | `:2190` |
| `upstream_without_range_support_refuses_to_start` | N4 | 去掉 `if total <= CHUNK_SIZE { return None }` | `:2204` |
| `follows_redirect_once_not_per_chunk` | N22 | 去掉 `up.resolved` 分支 | `:2240` |
| `abandoned_connection_stops_fetching_immediately` | N21 | 去 `peer_gone` → 漏 12544KB;去 worker `stop` → 漏 12288KB | `:2336` |
| `black_hole_upstream_gives_up_instead_of_hanging_forever` | N6 | 摘掉 `fetch_chunk` 的 timeout → 整体超时红 | `:2423` |
| `slow_but_progressing_upstream_is_not_killed` | N6(反向) | 收体循环换回 `r.bytes()` 外套整体 timeout | `:2497` |

其余:
- `preload.rs` 3 条:`warms_both_head_and_tail`(N26,断言尾段必须是后缀 Range)、`stops_at_the_limit_even_if_server_ignores_range`(N27)、`starting_a_new_job_cancels_the_previous_one`(N28)。
- `http.rs` 9 条:`host_of_*` / `insecure_allowlist_is_per_host_not_global` / `tls_config_builds_with_alpn` / `client_builds_and_is_cached` / `tls_verification_is_real`(ignored,需外网)/ `loopback_never_goes_through_proxy` / `each_client_sends_its_own_user_agent` / `set_proxy_invalidates_cached_client` / `api_clients_negotiate_compression_but_media_client_does_not`。
- `cf/proxy.rs` 3 条(含 `response_declares_connection_close`)、`cf/runtime.rs` 4 条、`cf/speedtest.rs` 1 条、`cf/ranges.rs` 3 条。
- `localserve.rs` 7 条(含 416、close、跨内部分块、drop 关端口)。
- `download.rs` 7 条(含 `write_path_survives_outside_tokio_context`)。
- `companion.rs` 3 条(含错 token 必须 404 且处理器一次都不能被调到)。

### 8.2 ⚠️ 用了全局覆盖值,**必须加锁串行**

cargo test 是**同进程多线程并行**。以下测试碰的是进程级全局态,不串行就会互踩,而「测试互踩」读起来像真 bug,最费排查时间:

| 全局态 | 锁 | 谁必须拿 | 出处 |
|---|---|---|---|
| `CHUNK_TIMEOUT_OVERRIDE_MS` | `CHUNK_TIMEOUT_TEST_LOCK` | `black_hole_upstream_gives_up_instead_of_hanging_forever`(`:2425`)、`slow_but_progressing_upstream_is_not_killed`(`:2499`) | `prefetch.rs:61-66` |
| `CLIENT` / `EMBY_CLIENT` / `PRELOAD_CLIENT` / `PROXY_URL` / `INSECURE_HOSTS` | `GLOBAL_CLIENT_LOCK` | http.rs 里**所有**读写这三个全局或调 `set_proxy`/`set_insecure_hosts` 的测试 | `http.rs:286-297` |
| `image_cache::MEM` | `MEM_TEST` | 所有内存层测试 | `image_cache.rs:290-300` |

细节:
- 两个测试各设各的超时覆盖值,谁先跑完谁就把对方的值清回真值 → 后者按 20s 真值等,**直接超时红,而它自己毫无问题**(`prefetch.rs:61-64`)。
- 实测:http.rs 全量套件连跑 20 次红 1 次,报 `assertion failed: CLIENT.read().unwrap().is_some()` —— A 刚 `client()` 填上缓存,B 调 `set_proxy` 把它清了(`http.rs:290`)。
- 锁一律用 `unwrap_or_else(|e| e.into_inner())` 而不是 `unwrap`:上一个测试 panic 会毒化锁,那时候让后面所有测试跟着红只会把真正的失败埋掉(`prefetch.rs:2425`、`http.rs:296`、`image_cache.rs:299`)。
- `image_cache` 的「各测各的 key」在内存层**不管用**:它的断言是全局用量和淘汰行为,天然全局,隔离不开,只能串行(`image_cache.rs:293-295`)。

**Go 侧对应**:Go 的 `go test` 同包内测试**默认串行**(除非 `t.Parallel()`),所以这类互踩不会自动发生 —— 但只要有人加了 `t.Parallel()` 就会回来。更好的做法是**别用全局**:把超时、client、mem 缓存都做成结构体字段依赖注入,让测试各持一份。这是 Go 版可以真正修掉的一类债。

### 8.3 测试自身踩过的坑(写 Go 测试时会再遇上)

| 坑 | 说明 | 出处 |
|---|---|---|
| 只在一段之内读 → 摘掉修复照样绿 | 槽位冲突需要**跨段**才碰得到 | `prefetch.rs:1353-1356` |
| `threads` 被 clamp(2,4) 悄悄抬高 | 参数和注释对不上,ring 算错,白跑一轮 | `prefetch.rs:1322-1323` |
| 按请求数计而不是按字节计 | 在飞取消发生在请求已发出之后,省的是剩余传输;按请求数计 worker 那层怎么改都是绿的 | `prefetch.rs:2334-2335` |
| `Err(_) => break` 吞掉读错误 | 「流被提前掐断」和「正常读完」结果长得一模一样,查都没法查 | `prefetch.rs:1526-1528` |
| 先做减法再断言 | 收短了就是 u64 下溢 panic,只剩一句 `attempt to subtract with overflow`,把「实收多少、错在哪」全毁了 | `prefetch.rs:1567-1571` |
| 黑洞上游测试里 probe 也不回 | `start()` 拿不到 total 返 None,测试退化成「代理没起来」,压根测不到 worker 那条路 | `prefetch.rs:2440-2442` |
| 挤牙膏上游最后一块没吃余数 | body 比 Content-Length 短,reqwest 一直等 → 测出来是「拉取失败」而不是想验的东西 | `prefetch.rs:2524-2525` |
| 深处 seek 位置硬编码 | 片子比它小就越界,红的是测试自己不是代理 | `prefetch.rs:1248-1249` |
| `delete_files` 是 spawn 出去的,不 sleep 就假绿 | 「这个 sleep 才是这条测试有效的原因」 | `download.rs:741-744` |
| `#[tokio::test]` 会给测试线程建好上下文 | 「没有 tokio 上下文」这类 bug 永远复现不出来,必须裸 `std::thread` | `download.rs:773-775` |
| 缓存目录测试共用真实目录 | 上一次跑残留的文件会让测试**一直红**,看起来像「莫名其妙的偶发失败」 | `image_cache.rs:278-283` |
| `read_exact` 挂死等于没测试 | 超时要包在读上,不靠 cargo 的整体超时 —— 挂死的测试不告诉你哪儿坏了,只是让 CI 变慢 | `prefetch.rs:2014-2016` |
| 本文件里写 `\r\n` 转义会被工具链吃掉反斜杠 | 测试里用 `String::from_utf8(vec![13,10])` 构造 CRLF | `prefetch.rs:1611`、`:2159` |
| hyper 在 HTTP/1 线上把头名写成**小写** | 别按 `"Range: "` 大小写敏感地找 | `preload.rs:179` |

---

## 9. 已知未解决 / 存疑

| # | 项 | 状态 |
|---|---|---|
| 1 | **N10 / N18 / N19 / N30 没有独立测试** —— 残段不进共享登记处、`live_end` 排在落盘之后、同段双连接只认先到者、250ms 兜底轮询。这四条都是「违反了会出错帧或卡住」的不变量,现在只靠别的测试间接覆盖。Go 版应补齐。 | 缺口,已确认(逐条对过 23 个测试的断言) |
| 2 | **Windows 上环形缓存文件是否真稀疏**:`prefetch.rs:291` 注释说「稀疏文件,实际占用只有已下载的部分」,但代码里没有 `FSCTL_SET_SPARSE` 之类调用。Linux/macOS 天然稀疏,NTFS 默认不稀疏。因为 ring 把文件长度封顶在用户上限,最坏情况就是「一开始就占满上限」而不是「涨到片子大小」。 | **未确认** —— 查了 `prefetch.rs:328-363` 全部创建逻辑和 `crates/core/src/paths.rs` 无相关调用;没有实测数据 |
| 3 | **Android 端完全没有 prefetch / preload**。`grep -rn "net::prefetch\|net::preload" apps/android/src/*.rs` 零命中。所以「多线程加载」「预加载」两个功能在手机/TV 上不存在,设置页若显示了就是假开关。 | 已确认(grep);**没查**前端是否仍渲染这两个开关 |
| 4 | **下载没有客户端侧权限门控**。`grep -rn "EnableContentDownloading\|can_download\|EnableDownloading"` 在 `apps/`/`crates/`/`ui/` 全仓零命中。门控完全靠 Emby 服务端对 `/Items/{id}/Download` 的放行 + 401/403 文案。用户会先看到「下载」按钮、点了才知道没权限。 | 已确认(grep);是否算 bug 未定 |
| 5 | **`cf/speedtest.rs:183` 的 `danger_accept_invalid_certs(true)`** 绕开了 `http.rs` 那套按 host 白名单的校验器。测速阶段合理(用别人的 IP 打你的域名,证书必然对不上),但它是全仓唯一还留着全局关校验的地方。 | 已确认(读代码);Go 侧移植时**别复用成通用客户端** |
| 6 | **`prefetch` 只带全局 UA,无逐流鉴权头**(`prefetch.rs:18`)。这限制了它只能代理「URL 里自带 token 的直传流」。网盘/插件源的逐流 headers 走不了预取代理。 | 已确认(读代码);是设计约束不是 bug |
| 7 | **`fetch_chunk` 的 3 次 attempt 之间没有区分「可重试」和「不可重试」的状态码**:4xx 和 5xx 都走同一条「作废地址 + 重签」路径(`prefetch.rs:687-701`)。401/403 这类重签也救不了的,仍会白试 3 次。 | 已确认(读代码);影响是多两次无用请求 |
| 8 | **`live` 登记表用 `std::sync::Mutex`**,理由是「临界区只有 HashMap 的 get/insert/remove,里面没有 await」(`prefetch.rs:194-195`)。这条约束是**注释保证的,不是类型保证的** —— 以后有人在临界区里加 await 就会阻塞 runtime。Go 里同理。 | 已确认;移植时保留这条注释 |
| 9 | **预取代理没有任何鉴权**:`127.0.0.1:<随机端口>/play` 任何本机进程都能打。同机其它程序理论上可以扫端口拿到用户的视频流。localserve(`localserve.rs:52-53`)和 companion(token,`companion.rs:197-205`)各有各的边界,prefetch 是三者里最松的。 | 已确认(读 `prefetch.rs:749-833`,`handle` 不校验任何东西);风险等级未评估 |
| 10 | **`read_ahead_bytes` 的下限 `floor.min(MAX_READ_AHEAD)`**(`prefetch.rs:84`):threads=4 时 floor = 16MB < 64MB,永远走 floor。这个 `.min()` 只有在 CHUNK_SIZE 或 threads 大幅变大时才起作用,目前是死代码但是有意的防御。 | 已确认(算过);移植时保留 |

---

## 附:速查表

```
CHUNK_SIZE            4 MB              prefetch.rs:33
MAX_READ_AHEAD        64 MB             prefetch.rs:44
CHUNK_TIMEOUT_MS      20 s(空闲)       prefetch.rs:55
threads               clamp(2,4),默认 3  prefetch.rs:118 / config.rs:301
PREFETCH_CACHE        64 MB ~ 4 GB,默认 512 MB   config.rs:304-320
probe 超时            8 s               prefetch.rs:525
兜底轮询              250 ms            prefetch.rs:867 / :987 / :1019
重试退避              300 / 600 ms      prefetch.rs:703
DEFAULT_HEAD_BYTES    32 MB(上限 512)  preload.rs:27 / config.rs:313
DEFAULT_TAIL_BYTES    2 MB              preload.rs:29
下载分段              1~4,<2MB 不分段   download.rs:608
图片缓存              内存 128MB / 磁盘 2GB / TTL 30 天 / 单张 32MB   image_cache.rs:27-33
图片回源并发闸        6,单张 20s        imgcache.rs:39 / :49
图标单张上限          4 MB              icon_cache.rs:12
CF 测速               256 抽样 / 并发 64 / 保留 24 / 测速 8 个 × 4s / 下限 2Mbps   cf/speedtest.rs:65-87
CF 排名               latency_ms − min(Mbps,100)×3   cf/speedtest.rs:96-99
CF 反代 connect 超时  15 s              cf/proxy.rs:122
SMB 桥分块            512 KB            localserve.rs:124
companion token       12 位十六进制      companion.rs:198-205
```
