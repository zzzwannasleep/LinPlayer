# 预取代理 / 下载 / 线路 / HTTP / 超时 / UA

**这个领域最容易踩的坑:**
1. **「有流量、黑屏、永远缓冲」这一个症状在预取代理里已经有过五个不同根因**(自锁死锁 / 共用取数游标 / 短包挂死 / keep-alive 吞 seek / 分段粒度)。查到一个别就收工。
2. **自己手写 HTTP 就必须回 `Connection: close`** —— 不回等于向播放器承诺可以复用连接,seek 会被管线化到同一条 socket 上吞掉。
3. **超时要用「空闲超时」不是「整体超时」**:慢链路拉一个 4MB 分段合法地要 29~62 秒。
4. **reqwest 不设 UA = 一个 UA 头都不发**(不是发默认值),带 WAF 的公开 API 会 403 并伪装成鉴权失败;curl 自带 UA,手测永远复现不出来。
5. **同步 `#[tauri::command]` 里裸 `tokio::spawn` 会 panic 打死整个进程**,而 `#[tokio::test]` 永远复现不出来。

> 本文件共 **14** 条。每条都标了它的原记忆文件名与类型;正文按原样搬运,未做压缩或改写。

## 本页条目

- Multi-thread loading prefetch proxy — `multithread-loading-prefetch-proxy.md`
- 预取代理死锁(已修) — `prefetch-proxy-deadlock.md`
- 预取代理吞 seek(已修) — `prefetch-keepalive-swallows-seek.md`
- 预取落盘环形缓存+302一次 — `prefetch-disk-ring-cache.md`
- 预取环形缓存并发竞态(已修) — `prefetch-ring-cache-race.md`
- 预取分段粒度 vs 慢链路 — `prefetch-chunk-granularity-on-slow-links.md`
- 取数要空闲超时不是整体超时 — `prefetch-fetch-needs-idle-timeout.md`
- 预加载必须留下字节 — `preload-must-keep-its-bytes.md`
- Download architecture — `download-architecture.md`
- 同步命令里裸 tokio::spawn — `sync-command-bare-tokio-spawn.md`
- 不发 UA 就吃 403 — `no-ua-gets-403.md`
- UA 三分口径 — `ua-policy-three-lanes.md`
- 同步线路=emby_ext_domains — `sync-lines-ext-domains.md`
- 跨服请求生命周期 — `cross-server-request-lifecycle.md`
- 预取代理多了一条**只读缓存端点** `/cached` — 2026-09-03
- 环形缓存必须钉住文件头和文件尾 — 2026-09-03
- 残段不落盘 = 文件索引永远进不了缓存 — 2026-09-03
- 直链落点的寿命写在 302 自己身上(`Cache-Control: max-age`)— 2026-09-04
- 下载的重试预算按「有没有前进」扣,不按「失败了几次」— 2026-09-04

---

### Multi-thread loading prefetch proxy

> 原记忆:`multithread-loading-prefetch-proxy.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

「多线程加载」最终落地为**宿主功能**(不是插件)：本地缓存预取代理。
`lib/core/network/prefetch_proxy/prefetch_proxy.dart` `PrefetchProxy.instance.start(upstreamUrl, threads:2-4, cacheLimitBytes)`：
在 `127.0.0.1:<随机端口>` 起 HttpServer 当播放源；用 2-4 个并发 Range 连接(Dio,
kAppUserAgent, applyProxyToDio)对真实流**超前**拉取，内存里有界读前缓冲(上限
`_maxReadAheadBytes`=128MB,且不超用户视频缓存上限),再**顺序**喂播放器；mpv 自身
`cache-on-disk` 把读到的落盘到 video_cache。失败返回 null → 调用方回退在线直链。

**为什么不是插件**:沙盒插件无文件系统、不能改播放器读取的 URL,所以只能预热服务端缓存
(丢弃字节,浪费)。真正"下载到本地磁盘+播放器从本地读"必须在宿主。先前为插件加的
`ctx.emby.apiRequest` 的 `headers`/`discardBody` 与 `ctx.player.getCacheLimitBytes`
(plugin_context_bridge.dart)是那条废弃路线的残留,通用但当前无人用。

**接线现状**：三端播放器均已接(各自 `_maybeStartPrefetch` + dispose 里 stop)——
桌面 desktop_player_screen_state.dart、移动 ui/screens/player/player_screen_state.dart、
TV tv/screens/player/tv_player_screen.dart。门控=**按服务器白名单**(非全局开关):`multiThreadLoadingServersProvider`(允许的 server id 列表,
StringList 持久化)+`multiThreadLoadingThreadsProvider`(2-4,用户可调),都在 playback_providers.dart。
播放器仅当 `currentServerProvider.id ∈ 白名单` 才起代理。UI:移动/桌面 settings_player.dart
(ListTile→对话框:线程数 Dropdown + 每服务器 SwitchListTile,加入前 consent 弹窗);
TV tv_settings_screen.dart(`_mtlItems`:`_choiceItem` 选线程 + 每服务器 `_toggleItem`,
加入前 showTvConfirm)。
**只代理 Emby 服务端直传流**:STRM/网盘直链(hasDirect)与转码/HLS(探测无 size)自动跳过,
避免逐流 headers 冲突。自检:test/prefetch_proxy_test.dart。

**seek/续播卡十几秒的坑(已修)**:`_Session._reset()`(seek 重定位)原来只 `_generation++`
作废结果,却不取消在途上游下载 → 2-4 worker 得先把 seek 前超前预取的旧 4MB 分段下载完
(弱网跨境最坏熬到 30s receiveTimeout)才转拉新位置。起播(位置0)没在途旧块要排空所以快,
seek 满手旧块+空预取窗口惩罚全暴露。修法=`_Session` 持每代 `CancelToken _fetchToken`,
`_fetchChunk` 的 dio.get 带上,`_reset`/`dispose` 里 cancel 旧 token 换新 → 秒 abort 无用在途
下载。`_fetchChunk` 遇 `CancelToken.isCancel` 直接 rethrow 不重试,worker 不把取消记 warn。
残留:seek 首字节仍要等一整块 4MB 下完(`_chunkSize`=4MB,`_awaitChunk` 整块才交付);
若还嫌慢再上「目标块 ResponseType.stream 边收边吐」或降 chunk。同 CancelToken 离页杀思路见
[跨服请求生命周期](network.md)。

**Rust/PC 新栈(2026-07-17 补齐)**:`crates/core/src/net/prefetch.rs`。移植时**丢了 Dart 的
按服务器白名单**,退化成一个全局 `prefetch_enabled: bool`,又因并发连接共用取数游标而
「开了放不了」(见 [预取代理死锁(已修)](network.md) 的第二个根因)→ 用户体感就是「这功能用不了」。
现已对齐 Dart 的门控口径:`Prefs.prefetch_servers: Vec<String>`(存 `Account.server` 身份键,
空表=全关,默认空)。**粒度是服务器不是线路**——一台服的多条线路是同一个源的入口,选中即全线路生效;
删账号时 `Config::remove` 顺手 retain 掉,否则重新加同地址的服会「自己就开着」。
`play()` 里查的是 `active_account().server`,**不是** `session.server`(后者是 active_line_url,
还可能被 CF 反代改写成 127.0.0.1)。设置页 PrefetchPane 只列 Emby 账号(预取只对直传流生效)。
**为什么不给全开入口**:它是优化不是功能,对局域网/NAS 本就跑满带宽,多开 Range 只是白占连接。

关联 「cache-architecture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废) 「unified-ua-and-prefs」(该条不在本库,多为 Flutter 时代的旧记忆,已作废) 「plugin-system」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)。
插件仓库里那个 com.linplayer.multithread-loader 已被本功能取代(仅预热服务端,较弱)。

---

### 预取代理死锁(已修)

> 原记忆:`prefetch-proxy-deadlock.md` · 类型:`project`

2026-07-15 用户真机首测就报「播放不了,一直缓冲,有流量但黑屏无声音」。
根因是 `crates/core/src/net/prefetch.rs` 里的一行(commit `f3c8a72c` 已修):

```rust
self.gen_tx.send(self.gen_tx.borrow().wrapping_add(1));   // 死锁
```

tokio `watch::Sender::borrow()` 返回的 `Ref` 持**读锁**,是临时量、**活到整条语句结束**
→ `send()` 在读锁未释放时拿写锁 → **同线程自我死锁**。改用 `send_modify` 修。

**Why 这个 bug 值得单独记**:
- **症状与病灶完全不像**。看起来像网络/mpv/解码问题,实际是我们自家代理卡死。
- `reset()` 在**写完响应头之后**才调 → mpv 拿到合法 206 + Content-Length,
  然后 body 永不到来 → 「一直缓冲」;「有流量」是 worker 在死锁前预取了 128MB 窗口。
  **全程零错误日志** —— 又一例「不报错,只是静默不干活」。
- `prefetch_enabled` **默认 true**,且 `play()` 对所有 DirectStream 都套代理
  → 一行死锁 = Emby 直传流全线播不了,发行版级阻断。

**How to apply(下次这类症状怎么查)**:
1. 先看 `%TEMP%\linplayer_poc.log`(poclog)——会打印
   `PLAY ... url=… method=DirectStream` 与 `prefetch 代理起服 http://127.0.0.1:<port>/play`。
   看到「代理起服」就说明 mpv 走的是本地代理,**先怀疑代理,别怀疑网络**。
2. mpv 自己有详细日志,但 **2026-07-15 起默认关**(`log-file` 会把 mpv+ffmpeg 钉在 debug 级
   并同步写盘,光 init 就 24KB,发行版不能背这个税)。要用先设环境变量:
   `set LP_MPV_LOG=1 && LinPlayer.exe` → 日志仍落 `%TEMP%\linplayer_mpv.log`。比猜快得多。
3. **用 curl 打真实 URL 分清网络 vs 自家设置**(本项目老规矩,见
   [Windows 无画无声"加载不出来"](player-mpv.md))。上游 200/206 + `Accept-Ranges: bytes` 正常
   = 问题在自家。
4. 端到端测试(已入库,`#[ignore]`,需真网络):
   ```
   LP_TEST_STREAM='<真实直传URL>' cargo test -p linplayer-core prefetch_serves -- --ignored --nocapture
   ```
   起代理 + 取样头部/跨4MB边界/深处seek,与上游**逐字节**比对。
   修复前它挂死被 timeout 杀(exit 143),修复后 15s 绿 —— 先红后绿见 [测试必须先红](methodology.md)。
   **签名 URL 走环境变量,别写进仓库。**

##### 第二个根因(2026-07-17 修):并发连接共用一份取数游标 —— 症状一模一样

死锁修完**症状还在**,当时归因写进了 config.rs 注释:「seek 的 reset() 会 ready.clear()
丢缓存反复重下」。那是表象,真根因是 `Session` 只有**一份**全局窗口
(serve_chunk/fetch_cursor/ready)却要服务 mpv 的**多条**连接:每个 `handle()` 进来都
`reset(start)` 把游标拽到自己起点。mpv 探 MKV(大字体附件、索引在末尾)会在旧连接没关时
就新开一条 → 后来者一 reset,前一条 `await_chunk` 等的那段再没人去拉 → 头发了 body 不来
= 有流量、黑屏无声、永远缓冲。**和死锁的症状完全一致**,所以第一次修完以为没修好。

修法:窗口从 Session 提到**每连接**(`Origin` 只留探测结果/上游地址,每条连接自持
`Stream`:独立窗口 + 独立 worker),`reset()`/`bump_gen()`/watch 作废机制整套删掉 ——
每条连接只向前顺序取数,跳转 = mpv 开新连接,不再冲掉别人的缓存。

**教训**:一个症状可以有两个独立根因;第一个修完症状不消失,别默认「修得不够」,
要重新独立诊断。当时那句「已修掉其中一个死锁,但那只是一环」是对的,可惜后面归因归错了。
回归测试 `concurrent_connections_do_not_starve_each_other`(假上游 + 两条错位连接交替读,
不需真网络)已入库,反向注入旧行为验证过必红(10s 超时)。

##### 第三/第四个根因(2026-07-18):短包挂死 + 每连接内存翻倍

**「永远缓冲」这个症状在本文件里已经有三个不同根因了**,查到一个别就收工。

3. **上游返回短于请求量的分段 → 永久挂死。** `fetch_chunk` 原来只要 body 非空就收下。
   分段按 `pos / CHUNK_SIZE` 定位,收下短包后 serve 写完那几字节就 `advance_serve(c+1)`
   把它从 ready 删掉,而 `pos` 仍落在分段 c 内 → 下一轮又 `await_chunk(c)`,
   可 `fetch_cursor` 早过了 c,**永远没人重拉**。触发源:CDN 截断,以及我们自家
   CF 反代在 chunked 路径上遇错 break 后仍补合法结束块(net/cf/proxy.rs 的 stream_body)
   → 产出「格式合法但短」的响应。修法:长度必须**正好**等于请求量,否则重试/标失败断流。
   测试 `short_upstream_chunk_breaks_stream_instead_of_hanging`(假上游只给 1/4),
   修前 20s 超时红,修后 0.94s 绿。

4. **读前缓冲从全局变每连接后,内存翻倍(这是修根因2时自己引入的)。**
   且原公式 `MAX.min((CHUNK*t*2).max(cache_limit))` 把用户的缓存上限当**下限**用,
   默认 1GB 直接把窗口顶到硬上限 128MB × 活跃连接数。改:`read_ahead_bytes()` 纯函数
   = cache_limit clamp 进 [每 worker 一段, 32MB];段数只由字节预算换算,不再 `.max(threads*2)`
   (那会反过来突破预算)。硬上限从 128MB 降到 32MB —— 大缓冲本就该 mpv 的 demuxer cache 扛。

   ★ **连带的升级坑**:旧配置存的 `prefetch_cache_bytes` 是 1GB,新校验只收 16~32MB。
   若 `get_prefetch_settings` 原样透出旧值,设置页一保存就被拒 —— 用户连"给某台服开多线程"
   都点不动(前端 commit 整个结构体)。故读出时必须 clamp 进合法区间;
   区间常量 `PREFETCH_CACHE_MIN/MAX` 放 config.rs 供两边共用。有回归测试。

**顺序加载已钉死**:`fetches_sequentially_without_duplicates` 断言上游收到的分段请求
恰好是 0..=末段各一次、且超前量不超过窗口。反向注入(认领时 +3 跳着取)必红。

相关:[Multi-thread loading prefetch proxy](network.md)(代理本身的设计)、[「待接」多半是谎](methodology.md)

---

### 预取代理吞 seek(已修)

> 原记忆:`prefetch-keepalive-swallows-seek.md` · 类型:`project`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

多线程加载代理(`native-poc/crates/core/src/net/prefetch.rs`)每条 TCP 只读**一个**请求
(`read_request` 只调一次),然后在 `serve()` 里把 body 一直喂完。但 HTTP/1.1 **默认长连接** ——
不显式回 `Connection: close`,就是在对播放器承诺「这条连接还能再发请求」。

后果:ffmpeg/mpv 一 seek(MKV 索引在末尾,起播必 seek;有续播进度还要再跳一次)就把
`Range: bytes=<末尾>-` **管线化发在同一条 socket 上**,那个请求没人读、响应永远不来 →
seek 静默失败 → 退化成**从头线性读完整个文件**。用户看到:有流量(整片在下)、黑屏无声。

2026-07-19 实测(<用户主力 Emby 服(UHD fork)> 一部 289MB MKV,resume=1157s):

| | connections | seeks | bytes read | 耗时 |
|---|---|---|---|---|
| 修前(经代理) | 1 | **0** | **289MB 全下** | 69.5s |
| 修后(经代理) | 3 | 2 | 3.4MB | 6.7s |
| 直连上游 | — | 2 | 3.4MB | 7.3s |

**Why:** 这是继 [预取代理死锁(已修)](network.md) 之后同症状的**第二根因**。症状一样,别看到
「有流量没画面」就以为又是那个死锁。声明 close 后 ffmpeg 每次 seek 老实新开连接,
正好落进「每连接独立窗口」的设计(真做长连接要在 handle 里循环收请求,代码多得多、收益为零)。

**How to apply:**
- 查法(比读代码快得多,别再靠推理):`ffprobe -v trace -i <url>` 对**代理**和**直连上游**各跑一次,
  比 `Statistics: N bytes read, M seeks` 和 `N connections, N requests`。seeks=0 + 字节数≈整片 = 本 bug。
  代码里挂 `logw` 打 CONN/FETCH 也能立刻看出「1 条连接却拉了全部段」。
- 自己手写 HTTP 响应的地方,只要不打算复用连接,就必须回 `Connection: close`。
- 同批修掉的死代码:越界 Range 的 416 分支判定写在 `s.min(total-1)` **之后**,永远进不去,
  越界请求会被挪回最后一字节回一个假 206。判定要用**钳位前**的原始 start。
- 回归测试:`response_declares_connection_close` / `out_of_range_start_gets_416_not_bogus_206`
  (均已按 [测试必须先红](methodology.md) 反向验证过真的会红)。
- 注意本文件里直接写 `\r\n` 转义会被工具链吃掉反斜杠,测试里用 `[13u8,10,13,10]` 字节构造
  (文件内已有先例注释)。

---

### 预取落盘环形缓存+302一次

> 原记忆:`prefetch-disk-ring-cache.md` · 类型:`project`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

`native-poc/crates/core/src/net/prefetch.rs` 2026-07-19 两项改造(用户拍板)。

##### 1. 302 只跟随一次(`UpstreamState.resolved`)
UHD 那类服务端(<用户主力 Emby 服(UHD fork)>)直传流是 302 跳 CDN,而 `fetch_chunk` 每段一次独立请求
→ **每 4MB 重走一遍 302**(实测 0.67s,占单段 TTFB 1.4s 的一半)。
探测时顺手记下 `resp.url()` 落点,worker 直接打 CDN;失效则清空回退原址重解析
(**先怪 CDN 链再怪签名链**,别一上来就调重签回调压服务端)。

A/B 三轮中位数(真实 UHD 流,24MB):

| | 修前(每段302) | 修后(302一次) |
|---|---|---|
| 吞吐 | 3.26 MB/s | **4.92 MB/s** |
| vs 单连接基线 4.33 | 0.75x **负优化** | 1.14x 正收益 |

原版 Emby 无 302(实测 `redirect=0.000000`),该字段恒 None,零影响。

##### 2. 分段落盘 + 环形复用(`DiskCache`)
原来分段全在内存 `HashMap<u64, Arc<Vec<u8>>>`,峰值 = 窗口 × 存活连接数。
实测:播放器 seek 就丢下旧连接新开一条,**被丢下的连接还会把整个窗口填满才停**
(断开后 3 秒内又拉 6 段)→ 快速拖 N 次进度条 = 32MB × N 瞬时,内存不足闪退。
因为不敢放大,设置项被硬钳在 16~32MB,「缓存上限」形同虚设。

改法:
- **全会话共享一个文件**(不是每连接一份)→ seek 回看命中磁盘不重下(省流量)。
- **环形复用**:槽位 = `chunk % ring`,`ring = cache_bytes / CHUNK_SIZE`。
  磁盘占用**恒定等于用户设的上限** —— 整片直存的话测试服那部 29.6GB 会把硬盘吃光,
  那是「内存爆掉」换了个介质。
- `slots: HashMap<slot, chunk>`,`has(c) = slots[c%ring] == c`;`get` 读完**复核槽位
  没被并发覆盖**,被覆盖就当 miss 重下。
- 内存只剩传输中的段(threads × 4MB)。上限随之从 16~32MB 放开到 **64MB~4GB**
  (`config.rs` 的 PREFETCH_CACHE_MIN/MAX + 设置页 Stepper + lib.rs 校验文案 三处同步)。
- 会话结束 Drop 删文件(不跨会话),落点走 `paths::cache_dir("prefetch")`(单一数据根红线)。

##### 3. 跳进度条不再白烧流量(两层)
被播放器丢下的连接原本会**照着预取窗口把量拉满才停**(实测断开后 3 秒又拉 24MB)。
- **serve 层**:等分段时 `tokio::select!` 上 `peer_gone(stream)` —— 光靠 `write_all` 报错不够及时,
  等分段的那段时间根本没在写,而那恰恰是浪费发生的时段。已声明 `Connection: close`,
  故「可读」只可能是对端关闭。
- **worker 层**:`done_notify` + select 取消**在飞**的 fetch(drop future = 断上游连接)。
  `notified()` 必须在 `over()` 检查**之前**注册,否则丢唤醒。

###### ★ 顺手拆掉一个自己埋的雷:预取窗口 ≠ 缓存上限
`read_ahead` 一个值兼了「预取超前量」和「磁盘缓存容量」。缓存上限放开到 GB 级后,
**预取窗口跟着变 GB 级** → 跳一次进度条白烧几个 G。已拆:
`MAX_READ_AHEAD=64MB`(超前量,大缓冲交给 mpv 自己的 demuxer cache),
`DiskCache::create` 收**用户设的 cache_bytes**(容量)。启动日志两个值分开打。

**How to apply / 坑:**
- 用户否掉过「收益自检」:开关本来就在用户手里(按服务器开),系统别自作主张。
- 多线程收益**高度依赖服务端**:原版 Emby 1.78x(8.10→14.44 MB/s),UHD 因 302 曾是 0.93x。
  评估前先量 `redirect` 耗时和并发加速比,别默认多线程一定更快。
- 该服网络抖动大,**单次测量不可作数**(同一配置测出过 1.25 和 4.92)。必须 A/B 同时刻多轮取中位数。
- 回归测试(均已反向注入验证会红):`follows_redirect_once_not_per_chunk`(302 重走 11 次 vs 1 次)、
  `seek_back_hits_disk_cache_without_refetching`(段 0 被下两遍)、
  `disk_cache_is_capped_not_proportional_to_file_size`(30GB 片子占 30720MB)、
  `upstream_without_range_support_refuses_to_start`。
- 原 e2e 测试硬编码 300MB seek 点,对 289MB 的片越界 → 已改成按 `total_size/2` 取。
- **验「省流量」必须按字节计,不能按请求数**:在飞取消发生在请求已发出**之后**,省的是剩余传输;
  按请求数计的话 worker 那层怎么改测试都是绿的(踩过)。两层各自反向注入:
  去 serve 层漏 12544KB / 去 worker 层漏 12288KB(=3 worker 各一段在飞)。
  测试 `abandoned_connection_stops_fetching_immediately`。
- 见 [预取代理吞 seek(已修)](network.md)(Connection: close)与 [预取代理死锁(已修)](network.md)。

##### ★ 4. 缓存文件名必须**每实例唯一**(2026-07-20 修,CI 偶发红的真凶)
原名 `s{pid}_{total}.part`,注释写着「同一进程内多次起播不会互相踩(旧的先 Drop 删掉)」——
**这个前提是错的**,两个会话完全可能并存(孤儿播放器没 Drop、新播放器已起播,
见 [桌面双声音/孤儿播放器](player-mpv.md);同一部片 total 当然相同)。撞名后:
1. 后来者 `truncate(true)` 把前者数据整个清零;
2. 前者的 `slots` 表在**内存**里,仍认为那些段就绪(`has()` 复核也通过,槽号没变);
3. 后来者写个高位槽把文件撑长 → 前者读低位槽读回**一整块稀疏零**,当成视频流发给播放器。

修法:文件名加进程内自增序号。

**这条同时是 `concurrent_connections_do_not_starve_each_other` 在 CI 上偶发红的根因** ——
cargo test 是**同进程多线程并行**,好几个预取测试的 `TOTAL` 都是 40MB,互相 truncate。
**判据(很好用)**:孤立跑 30 次全绿、`--workspace` 约 1/5 翻车 = 问题出在「同进程还有别的
会话活着」,不是调度运气。别把这种当 flaky 测试去 retry/ignore —— 它报的是真发错数据。
**症状反查法**:测试数据是 `byte_at(i)=(i%251)`、CHUNK=4MB;若读到的是别的段,首字节应为
`(k*94)%251`,251 是质数 → 只有 k=0 才为 0。实到 0 ⇒ 不是别段数据,是**稀疏零**。
回归测试 `two_live_sessions_never_share_one_cache_file`(确定性,不靠调度),
按「测试必须先红」两段验过:退回旧名撞路径断言;再摘掉路径断言,数据断言自己报「全零?true」。

**还剩两处已读出但未修的隐患**(没有复现证据,没敢盲改,盲改有挂死风险):
1. `await_chunk` 里 `disk.get()` 返回 `None` 时**直接 return None → serve 断流**,
   而 `get` 自己的注释写的是「那就当没命中**重下**」。语义和注释相反。
   改成 loop 重试的风险:该段若已被环形覆盖且 `fetch_cursor` 早已越过它,就没人会再取 → 挂死。
2. `DiskCache::put` 先写盘、**后** `slots.insert` 发布。写到一半时读旧段的人
   `has()` 仍为真 → 可能读到新段字节却通过复核。修法是写前先 `remove` 槽映射,
   但同样会把等待方推向上面那个「没人重取」的挂死风险。
   ⇒ 要动这两处,先补一个能确定性复现的测试再说。

---

### 预取环形缓存并发竞态(已修)

> 原记忆:`prefetch-ring-cache-race.md` · 类型:`project`

`crates/core/src/net/prefetch.rs` 的磁盘环形缓存是**全连接共享**的，槽位 = `chunk % ring`。
两条连接的分段号只要模 ring 同余就落同一个槽 —— 多连接下必然撞上，不是理论风险。
2026-07-21 从「CI 上 concurrent_connections 5~20% 偶发红」挖出**两个真 bug**：

**1. TOCTOU 串数据（最危险，因为它不报错）**
`put` 原来「先写盘、后更新 slots」，`get` 是「先 has() 查表、再读盘」，中间没互斥 →
读者查表命中后开始读，另一条流正把别的段覆盖进同一个槽 → **读到别人的数据**。
线上表现 = 播放器拿到错帧，画面坏掉但没有任何错误。
修：`put` 全程持 slots 锁且**先失效再写**；`get` 把「校验槽位 + 读盘」放进同一把锁。
⚠️ 改完必须删掉 `get` 结尾那句「读完再 has() 复核」—— 锁覆盖全程后它就是对同一把
`tokio::Mutex` 重入的**自锁**。

**2. 段被挤掉后无人重拉 → 连接饿死**
worker 的 `fetch_cursor` 早已越过那段，`await_chunk` 无限空转（`has()` 永远 false，
又不在 `failed` 里）= 线上的黑屏/永远缓冲。
修：`await_chunk` 发现「没人在拉、游标又已越过」就把 `fetch_cursor` 倒回去重拉。
为此加了 `ChunkState.in_flight` —— **必须把「在飞」和「被挤掉」分开**，两者 `has()` 都是 false，
分不开就会重复下载在飞的段（`fetches_sequentially_without_duplicates` 当场抓到）。

**写这类测试的坑（我全踩了一遍）**：
- **只在一段之内读是测不出来的**：`await_chunk` 整段返回并留在内存，根本不会再问磁盘。
  必须让每条连接**跨段**读（chunk = 4MB，所以要读 >4MB）。
- `start(url, threads, ...)` 内部 `clamp(2,4)`，传 1 会被**悄悄抬成 2**，ring 跟着变，
  参数和注释就对不上。ring 的算法是 `want = max(cache/CHUNK, threads*2)`。
- 批量改测试参数时 `assert s != o` 只能证明「有东西变了」，不能证明「每处都变了」——
  要**逐处断言**并回读确认，否则就是 [测试必须先红](methodology.md) 说的「注入不忠实」。

验证口径：全量套件连跑 30 次 0 失败（修复前 20 次红 1~2 次）。
同族历史问题：[预取代理死锁(已修)](network.md)、[预取代理吞 seek(已修)](network.md)、
[预取落盘环形缓存+302一次](network.md)。

---

### 预取分段粒度 vs 慢链路

> 原记忆:`prefetch-chunk-granularity-on-slow-links.md` · 类型:`project`

2026-08-01 实测(用户的 Emby 测试服 + 其 CDN 落点),**A/B 硬数据**:

| 多线程加载 | 起播 | duration | 轨道 |
|---|---|---|---|
| 开(旧) | 115 秒仍不动 | 0 | 0 |
| 开(新,边收边吐) | 8.8 秒 | 3846.9s | 4 |
| 关(对照) | 7.7 秒 | 3846.9s | 4 |

链路实测:TTFB 1.3~1.8s **正常**,吞吐只有 **56~143 KB/s**;三条并发合计
~220 KB/s(并发只有 1.5x → 基本是带宽上限,多线程在这台服本就没多少收益)。

**根因:把「预取的粒度」当成了「供给的粒度」。** `CHUNK_SIZE = 4MB` 是给预取用的
(TTFB 1.5s,分段太小会被建连吃光),但 serve 原来必须等**整段落盘**才吐第一个字节。
mpv 起播只要文件头 ~200KB + 尾部 cues(MKV,ffmpeg 开容器第一跳就 seek 到尾)。
150KB/s 下一段 4MB = 30~80 秒,头/尾各一次。直连时 mpv 只拉它真要的那几百 KB,所以反而能播。

##### 修法(2026-08-02,两刀)
1. **边收边吐**:worker 收到的每块字节挂进 `Live` 载体并唤醒供给端,有多少给多少;
   落盘照旧但不挡在播放器前面。重试靠 `Live::feed` 的 `skip` 从断点续 ——
   上一轮的字节**可能已经吐出去了**,收不回来,既不能重复追加(错帧)也不能从头重来。
2. **seek 不回退到边界**:响应声明 `Connection: close` → 每次 seek 都是新连接,
   起点几乎不落在 4MB 边界上。原来从边界开拉 = 白拉平均 2MB(150KB/s 下 13 秒画面不动)。
   首段改成从请求起点拉;**残段绝不能落盘** —— 会把它前面那截垃圾一起标成就绪,
   别的连接读同一段拿到脏数据(不报错,只坏画面)。实测 seek 落位 0.27~0.29s。

**Why:** 我上一轮把它定性成「结构性缺陷、这次不修」并让用户关掉多线程加载 ——
那是**欠账不是判断**。定性对了就该修完,留着等用户再提一遍是最差的交付。

**How to apply:**
- **别再靠调小 `CHUNK_SIZE` 绕**:好几个测试的前提是
  `ring = max(cache/CHUNK, threads*2)` 算出的具体槽位数(如
  `concurrent_connections_do_not_starve_each_other` 靠 4 槽制造同槽碰撞),
  改常数会让它们**假绿**(断言还在,碰撞不再发生)。而且 TTFB 1.5s 下小分段本就更慢。
- 三条门禁测试都反向注入验过必红,改这块之前先看它们的注入说明。
- 相关:[预取落盘环形缓存+302一次](network.md)、[预取代理吞 seek(已修)](network.md)、
  [取数要空闲超时不是整体超时](network.md)、[测试必须先红](methodology.md)

---

### 取数要空闲超时不是整体超时

> 原记忆:`prefetch-fetch-needs-idle-timeout.md` · 类型:`feedback`

`http.rs` 的三个 reqwest client(`client`/`emby_client`/`preload_client`)
**一个 timeout 都没设**。预取代理 `fetch_chunk` 的 `send()`/`bytes()` 因此是
无限期等待:上游一黑洞(CDN 落点失效/中间设备吞包),worker 永远吊着 ——
不重试、不重签、**连一行日志都没有**,供给端跟着一起等。
mpv 侧形态:`Stream opened successfully` → duration=0、一帧不出、0 条轨道。
`curl` 直接打本地代理:`206, size=0`,头发了、body 一个字节没有。

**Why:** 我第一版修成了**整体超时**(15s),差点当成修复发出去。
实测慢链路(56~143KB/s)拉满一个 4MB 分段**合法地要 29~62 秒** ——
整体超时会把「慢但完全能用」的链路当故障掐掉,还一路重试放大负载。
修一个静默卡死换来一个更响的故障,比不修还糟。

**How to apply:**
- 判据只能是「一段时间**一个字节都不来**」:建连/等响应头用整体超时,
  收体改成 `r.chunk()` 循环,**每收到一块就重置计时**。
- 两条回归测试都要有,而且都反向注入验过:
  黑洞上游必须放弃(不吊死)/ 慢速但持续吐字节的上游**不许**被掐。
- 这两条测试共用一个全局超时覆盖值,**必须加锁串行** —— 并行时互相把对方的值
  清回真值,后跑的那条按真值等直接超时红,看起来像真 bug(同 http.rs 三个全局 client 的账)。
- 相关:[预取分段粒度 vs 慢链路](network.md)、[测试必须先红](methodology.md)

---

### 预加载必须留下字节

> 原记忆:`preload-must-keep-its-bytes.md` · 类型:`feedback`

用户 2026-08-02 原话:「预加载和多线程加载一个道理,**预加载了多少就吐多少出来**,
不需要等加载完才放。」

我第一版 `net::preload` 是 fire-and-forget:发 Range、读完即丢,只图把路跑热
(TCP/TLS、服务端页缓存、CDN 边缘)。**那在慢链路上是白烧带宽** ——
150KB/s 下热 32MB 要 3.5 分钟,起播还得从头再下一遍。

**Why:** 「跑热路」只在链路快的时候够用;链路一慢,唯一值钱的就是**字节已经在本地**。
这条和上一刀(prefetch 边收边吐)是同一个道理的两个位置,用户自己点破了这层类比。

**How to apply:**
- 做法:详情页就把 `prefetch` 代理起起来,预热的**头部**流经它落进环形缓存;
  起播时**上游地址一致就复用同一个 `ProxyHandle`** —— 换成新起一个,
  旧句柄 Drop 会把缓存文件删掉,预热全白做。实测 8MB 预热后起播 1.16s(不预热 7.7~8.8s)。
- **尾部必须走直连、只跑热不留存**:环形缓存按 `chunk % ring` 定位,尾部段号和头部段号
  有约一半概率同槽 —— 热完尾巴正好把头顶掉。尾巴 2MB,重拉便宜。
  (我们自家代理的 `parse_range` 也不认后缀 Range `bytes=-N`,直接当全量,这是第二个理由。)
- 行为变化要**明说**:开着预加载则起播一律经本地代理,哪怕「多线程加载」关着(那时用 2 条连接)。
  「已经在本地的字节要不要用」和「播放中并发拉多凶」是两件事,设置页写清楚。
- 门禁钉在「一条连接拉过的字节下一条白拿」这条契约上:缓存要是变成每连接一份,
  预加载会**静默白做**(编译绿/单测绿/界面无异样)。
- 相关:[预取分段粒度 vs 慢链路](network.md)、[预取落盘环形缓存+302一次](network.md)、
  [别过度解读需求](methodology.md)(这次相反:用户点名要的功能语义,必须照做到底)

---

### Download architecture

> 原记忆:`download-architecture.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

离线下载功能（2026-06-19 重构，弃用 flutter_downloader，改自建引擎）。

**核心引擎**：`lib/core/services/download/`
- `download_manager.dart` — Dio + HTTP Range 分段下载，1–4 线程可调（`threads`）。同一时刻只下一个文件，单文件内分段并发以约束服务器压力。每段写 `${file}.partN`，全部完成后按序拼接为最终文件 → 天然断点续传（重启按 part 文件长度恢复）。`ChangeNotifier`，UI 用 `ListenableBuilder` 监听。
- `download_models.dart` — `DownloadItem`/`DownloadSegment`/`DownloadStatus`，JSON 持久化。
- `download_grouping.dart` — 把扁平任务整理成「电影各自成组 / 剧集按剧名聚合」，含 `formatBytes`/`episodeLabel` 等。
- `download_helper.dart` — `startMediaDownload()`(单条) / `startSeriesDownload()`(整剧:遍历 getSeasons+getEpisodes 逐集入队,已存在自动跳过) / `mediaItemFromDownload()`(离线兜底还原 MediaItem)。
- 去重键 = itemId（单集/整剧入队收敛到同一记录）。

**下载源**：Emby 原生 `GET /Items/{id}/Download`（`PlaybackApi.getDownloadUrl`，emby_api.dart），服务端按下载权限放行原始文件。

**权限门控**：`User.policy`（`UserPolicy`，解析 `Policy.EnableContentDownloading`/`EnableDownloading`/`IsAdministrator`）。`downloadPermissionProvider`（download_providers.dart）综合判断；下载入口先查策略再看条目级 `CanDownload`。

**Providers**：`lib/core/providers/download_providers.dart` — `downloadManagerProvider`(单例 plain Provider)、`downloadThreadsProvider`(偏好 1–4)、`downloadPermissionProvider`。

**存储位置**：桌面便携用 `{exe目录}/downloads/`，移动/mac 用 `getApplicationSupportDirectory()/downloads/`，索引 `index.json`。参见 「cache-architecture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)。

**UI 入口**：
- 移动端下载页 `lib/ui/screens/download/download_screen.dart`（路由 `/downloads`，从 server_list_screen 进入）。
- 桌面端新增「下载」栏目：`desktopNavItems` 第 4 项 + desktop_router 分支3 + `lib/desktop/screens/download/desktop_download_screen.dart`。三端外壳(fluent/macos/material)都遍历 desktopNavItems 自动渲染。参见 「desktop-native-ui-architecture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)。
- 单条下载触发：media_detail_screen `_addToDownload`、season_detail_screen、desktop_media_detail_screen_header `_handleDownload`。
- **整剧下载按钮**（右上角，仅 Series/Season）：移动端 media_detail_screen `_DetailHeaderState._downloadWholeSeries`（返回按钮对侧）；桌面端 desktop_media_detail_screen_header 顶部工具栏 `_downloadEntireSeries`（_GlassButton）。

**离线本地播放**（已接入）：两端播放器 `_initializePlayer` 先查 `downloadManager.completedFilePath(itemId)`，有则用 `Uri.file()` 覆盖播放源，在线地址作回退；元数据拉取失败且有本地文件时用 `mediaItemFromDownload` + `buildOfflinePlaybackSelection`(playback_url_resolver.dart) 兜底，实现完全离线播放。改了 player_screen_state.dart / desktop_player_screen_state.dart。

`flutter_downloader` 依赖已从 pubspec 移除（GeneratedPluginRegistrant 由 pub get 自动重生；iOS 的 `@import` 受 `__has_include` 守卫不影响构建）。

---

### 同步命令里裸 tokio::spawn

> 原记忆:`sync-command-bare-tokio-spawn.md` · 类型:`project`

**同步 `#[tauri::command] fn`(非 async)跑在 IPC 线程上,那里没有 tokio 上下文。**
出处:tauri-2.11.5 `src/webview/mod.rs:1909` —— `on_message` 直接 `run_invoke_handler(invoke)`,
在调用线程内联执行,Windows 上就是 WebView2 的消息线程。

裸 `tokio::spawn` 在那里 panic `"there is no reactor running"`,panic 穿过 FFI 边界
= **进程无声消失**(用户看到的是「卡死然后闪退」)。

2026-08-01 实例:`DownloadManager` 的 enqueue/pause/resume/remove/forget 内部三处裸 spawn,
桌面 + 安卓两端的下载写路径**全废**;`list()` 不 spawn,所以下载页打得开、一动就死。

**Why:** 编译绿、单测绿(`#[tokio::test]` 宏自带上下文,bug 永远复现不出来)。
只有从**裸 std 线程**调才现形。

**How to apply:**
- 长驻管理器在 `new()`(async)里抓一个 `tokio::runtime::Handle::current()` 存成字段,
  写路径全走 `self.rt.spawn` —— 修一处,两端 + 将来新加的命令一起覆盖,不用逐个改 async。
- 写这类回归测试**绝不能**用 `#[tokio::test]`,必须 `#[test]` + `std::thread::spawn` 里调。
- `tauri::async_runtime::block_on` **会**进上下文(`Runtime::Tokio(r).block_on`),
  所以在 setup 里构造管理器抓句柄是成立的。
- 相关:[测试必须先红](methodology.md)、[挂真机 CDP 调试](methodology.md)(真机 CDP invoke 一条同步命令即可判活)

---

### 不发 UA 就吃 403

> 原记忆:`no-ua-gets-403.md` · 类型:`project`

**`reqwest::Client::builder()` 不调 `.user_agent()`,发出去的请求里是「一个 UA 头都没有」,
不是「发个默认的」。** 带 WAF 的公开 API 会把它当脚本流量掐掉。

2026-07-21 实测(`api.bgm.tv/v0/me`,同一个有效 Access Token):

```
带 UA   → HTTP 200
不带 UA → HTTP 403 (Server: cloudflare)
```

`crates/core/src/http.rs::client()` 原本就是 `cached(&CLIENT, None)`,
而它正是 **Bangumi / Trakt / 弹弹Play / 翻译 / 排行榜** 共用的客户端。
表现:**「Bangumi Access Token 明明有效,App 却提示无效或已过期」** ——
因为 `fetch_profile` 拿不到 `/v0/me` 就返回 None,错误信息只会说 token 不行。
弹幕之所以一直没事:它走的是 `state.http` = `emby_client()`,那条**有** UA。

**为什么 curl 手测永远复现不出来**:curl 自己会发 `curl/8.x`。
要复现必须显式清掉:`curl -H "User-Agent:" ...`。
这类「客户端里坏、手测好」的 bug,第一件事就是把两边的**实际请求头**对齐了看。

**已修**:新增 `api_user_agent()` = `LinPlayer/{版本} (+项目地址)`,`client()` 用它。
三条 UA 道仍然互相区分(Emby / Preload / 第三方),这是 [UA 三分口径](network.md)
原口径的目的;改掉的只是"第三方走匿名"那一条 —— 那条是 2026-07-19 用户定的,
**推翻用户定的口径必须当面说明,不能默默改**。
`each_client_sends_its_own_user_agent` 已改成断言第三方 UA 非空且不与另两条相撞,
反向注入验证过(摘回 `None` 立刻红)。

**没被证实的**:弹弹Play 排行榜 403 是否同因。反例——本机不带 UA 也能拿到 50 条,
只有 CI(数据中心 IP)403。见 [Ranking architecture](danmaku-sync.md)。

---

### UA 三分口径

> 原记忆:`ua-policy-three-lanes.md` · 类型:`project`

用户 2026-07-19 定的 UA 口径,`crates/core/src/http.rs` 是唯一出口:

| 路径 | 客户端 | UA |
|---|---|---|
| 访问 Emby(API/图片/下载/mpv 直连取流) | `emby_client()` | `LinPlayer/{版本}` |
| 多线程加载 + 以后的预加载(预取代理拉上游) | `preload_client()` | `LinPlayerPreload/{版本}` |
| 其它一切(弹幕/Bangumi/Trakt/翻译/排行/图标) | `client()` | **不设**,走 reqwest 默认 |

理由:预取是**替 mpv 提前拉流**的旁路请求,和用户真在看的那一路必须能在服主日志里分开,
否则看着像"一个客户端开了四五路并发",容易被当盗刷限速。

**改动前的旧状态**:只有一个全局 `client()` 给所有请求挂 `LinPlayer/版本`,而 **mpv 直连取流
反而没带**(用的是 mpv 自带默认 UA)—— 要求最强的那一路恰恰是漏的。

顺带修掉的静默 bug:mpv 的 `user-agent` / `http-header-fields` 是**实例级属性,设了就一直在**。
原先只有 `load_with_headers`(网盘源)会设、谁都不复位 → 放过一次网盘源再放 Emby,
会把网盘的 UA **和 Authorization/Cookie 一起发给 Emby 服务器**。现已收敛到 `load_inner`,
每次 loadfile 无条件重设。

守卫测试 `each_client_sends_its_own_user_agent`(http.rs):**真起 TcpListener 读实际请求头**,
不比对字符串常量 —— 比常量只能证明 `format!` 没写错,证明不了 `.user_agent()` 真挂上了。
三条注入(preload 用错 UA / 通用 client 又挂 UA / emby 不设 UA)全部验过会红。
`set_proxy` 必须清三个缓存,漏一个那条路就还用旧代理。

---

### 同步线路=emby_ext_domains

> 原记忆:`sync-lines-ext-domains.md` · 类型:`reference`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。

上游:https://github.com/UHD/emby_ext_domains(2026-07-15 实读源码,不是猜的)

**它是什么**:**不是**中心化域名列表,是**服主自己部署**的一个 Go 小服务(Gin,~180 行),
用仓库自带 nginx 片段挂在**自己 Emby 域名的同一 origin** 下:
`location = /emby/System/Ext/ServerDomains { proxy_pass http://127.0.0.1:52143; }`

- **端点**:`GET {baseUrl}/emby/System/Ext/ServerDomains`(相对 origin;用户地址若已带 `/emby` 要先削掉,否则 `/emby/emby/…` 404)
- **鉴权**:现有 `X-Emby-Token` / `X-Emby-Authorization` **原样透传,零改造**。服务端拿 token 回打 `{Emby}/System/Info` 校验(3s 超时)
- **返回**:`{"data":[{"name":"...","url":"..."}],"ok":true}`;401 是 `{"error":"...","ok":false}`
- **匹配**:没有 key/ID/分组 —— **同源即匹配**。别去设计匹配逻辑,不存在
- **限流**:没有,但它每次请求都回源校验 token(不缓存)→ 客户端别轮询,点一次拉一次

**Why(三个必须记住的坑)**:
1. **404 是常态**,绝大多数 Emby 服务器没装 → `Ok(vec![])` + UI 静默说明,**不能弹红错**。只有 401 才 Err。
2. 服主自填的 `url` 上游**零校验** → 是信任边界。我们会拿它当 baseUrl 带 token 请求,必须只放行 http(s) 且能 `Url::parse`。
3. 合并**只增不删、按归一化 url 去重**;`active_line` 是**下标**,必须按 url 找回 ——
   用户点同步往往正是当前线路不通的时候,这时把生效线路悄悄挪走是最坏的。
   空线路表要先把 `server` 裸地址落成「主线」,否则用户原地址凭空消失。

**How to apply**:实现在 `crates/core/src/emby.rs::ext_domains` + `config.rs::merge_lines`
+ 命令 `sync_lines`。merge 的四个坑都有反向注入验红过的测试。
**「同步线路」≠「测延迟」** —— 那是 `probe_lines`,两个独立按钮(此前是同一个按钮,名不副实)。

---

### 跨服请求生命周期

> 原记忆:`cross-server-request-lifecycle.md` · 类型:`feedback`

跨服务器聚合/搜索(集详情聚合、聚合搜索、排行榜匹配)的正确工程做法,用户明确纠正过:

- **不要加并发上限**。这些请求只查条目元数据(文本 JSON,非图片/音视频),并发吃不了多少带宽,限流是累赘、且解决不了真正问题。三个 provider 都用无上限 `Stream.fromFutures` 按完成顺序逐台 emit。
- **靠 CancelToken 离页即杀**才是真省资源。每个跨服 `StreamProvider.autoDispose` 挂一个 `CancelToken`,`ref.onDispose` 里 `cancel()`;切页/关弹窗即中止在飞 HTTP,不让服务器白算、不占连接。已给 `EmbyApiClient.get/post` + `MediaApi/SearchApi` 的 search/findItemsByProviderIds/getItemMediaSources/getSeasons/getEpisodes/getItemDetails 加可选 `cancelToken`(cancel 属非瞬时错误,`_withRetry` 不重试)。
- **展示媒体信息不开 ffprobe**。`playbackInfoProvider`(详情页版本信息/播放器设置面板轨道列表)改用 `getItemMediaSources`(GET Fields=MediaSources,MediaStreams),不带 IsPlayback/AutoOpenLiveStream。服务端返回什么就展示什么,没返回就没有。真正播放走播放页直接调的 `getPlaybackInfo`,不经该 provider。

**Why:** 用户对服务器性能敏感,反感"为了展示就让服务端开流探测"和"无意义的限流"。
**How to apply:** 新增任何跨服/后台联网 provider,默认套这套:无上限+CancelToken离页杀+展示走轻量元数据。参见 File-browse sources(本地 sources.md,未入公开库) [网盘/strm 播放两大坑](player-mpv.md)。

---

### 预取代理多了一条**只读缓存端点** `/cached`

`prefetch.Handle` 现在给两个地址:

| | 用途 | 行为 |
|---|---|---|
| `URL`(`/stream`) | 播放器取流 | 缺哪段拉哪段,起 worker,会往环形缓存里写 |
| `CachedURL`(`/cached`) | 进度条缩略图 | **只吐盘上已有的**,缺了直接 416,**不起 worker、不碰上游** |

为什么必须分成两条路,而不是给普通端点加个开关:第二个读者一旦走普通端点,
它会自己开一条 stream + 一组 worker 顺序拉数据 —— 而环形缓存是**全连接共享**的,
它拉进来的段会**把正在播的段挤掉**。表现是「拖一下进度条看预览,正片开始卡」,
而且不报错。所以这条路是一条**没有 worker 的**路。

配套:`Handle.CachedSpans()` 报「哪几段已经在盘上」(按占全片的比例),
UI 拿它画「这一段有缩略图」。**宁可报少不可报多** —— 报多了是「看见有却出不来」,
那是坏了;报少了只是保守。所以只认**整段就绪**,在飞的段一律不算。

☠ 既有用例的 `testTotal = 8 * ChunkSize` **永远整除**,
「最后一段是残段」这条路一次都没被走过 —— 而真实视频文件几乎不可能整除。
已补 `TestC26_总长不是整段倍数也要一字不差`(9 段零 12345 字节,全量 + 尾部各校验一次)。

### 环形缓存必须钉住文件头和文件尾 — 2026-09-03

槽位原来是纯 `chunk % ring`,于是环转一圈之后文件头被覆盖。
后果只有一种形态,而且完全静默:**任何要重新打开这条流的人都打不开了**。

撞上的是进度条缩略图(它用第二个 mpv 从只读缓存端点开同一条流)。
而 **mp4 的 moov 原子常常在文件末尾**(没跑过 faststart 的片子),mkv 的索引也在末尾 ——
头和尾少一个,`avformat_open_input` 就直接失败,日志里只有一句「打不开」。

做法(`cache.go` 的 `slotOf`):环有 5 个槽以上时,末尾三个槽分给
`chunk 0` / `last-1` / `last`,其余的段落在 `c % (ring-3)` 上。

- ★ 尾巴钉**两段**不是一段:moov 的大小跟帧数走,两小时的片子常有 5~10MB,
  只钉最后 4MB 的话大 moov 会被腰斩,而症状和完全没钉一模一样。
- ★ 代价是三个槽(12MB)。它换掉的是上一版那个绕法:让缩略图实例
  **从起播就一直开着别关**,拿一个常驻解码器去躲这个 bug。

### 残段不落盘 = 文件索引永远进不了缓存 — 2026-09-03

供给端有一条优化:「首段若不对齐,只拉播放器真正要的那截(残段),挂在本连接上,**不落盘**」。
看着很合理 —— 用户 seek 到块中间,没必要为此拉整块。

**但播放器读 moov 时发的正是从块中间开始的 `Range`。**
于是文件索引那一段**从来没进过环形缓存**,每次打开都要重下,
更要命的是别人再也打不开这条流了。

做法:钉住的那几段(见上一条)**例外** —— 残读到它们就整段拉、整段落盘。
代价是这一次读多拉不到 4MB,而且只发生在文件头/尾那两三段上。

★ 一般规律:**一条「只拉需要的那部分」的优化,遇上「这部分是别人的入场券」就会变成 bug。**
判据不是「省了多少字节」,而是「这段字节之后还有没有人要」。


### 直链落点的寿命写在 302 自己身上 — 2026-09-04

前后端分离的 Emby(115 / 123 那类网盘后端)取流是 302 跳一条**带时效签名**的直链,
而那个 302 会用 `Cache-Control: max-age=<秒>` 把签名的剩余寿命告诉客户端 ——
**115 默认 30 分钟,123 明显更短**(服主原话)。

我们原来把落点(`origin.resolved`)缓存成**永不过期**,只在请求真的失败时才丢掉它。
也就是说「签名到期」这件事,我们是**靠撞墙才知道**的,而撞墙的代价是乘出来的:

    2~4 个 worker 在同一瞬间全拿着已经死掉的落点去请求
      → 每个各自重试 3 次(fetchChunk 那三轮)
      → 每次失败都清一次 resolved、回头再打一遍 Emby 直链
      = **一次签名到期,后端瞬间挨上十几次直链解析**

而后端每解析一次,源站(网盘)就要为它付出一次真实请求。服主看到的形态是
「这个客户端每隔半小时抽一次风」。

做法(`core/net/prefetch/resolve.go`):`http.Client.CheckRedirect` 上装一个钩子,
跟跳转的同时把 302 的 `Cache-Control` 收下来,落点连同到期时刻一起存。
到点前 `resolveMargin`(30s)就主动换 —— 过期从**意外**变成**预定事件**,
一次到期只换一个新落点。

★ **能拿到 302 的响应头,靠的是 `req.Response`** —— Go 只在客户端跟跳转时填这个字段。
  不知道它就得改成手动跟一跳(`ErrUseLastResponse`),那要把 probe 和 fetchOnce
  两处都拆成两段式。

★ **收集槽必须挂在请求上下文里,不能挂在共享结构上。**
  `CheckRedirect` 是在别人的 goroutine 里被调的,而同一时刻有 2~4 个 worker 各自在跟
  自己的跳转 —— 写共享字段就是「偶尔把 A 请求的有效期安到 B 的落点上」,
  不报错、只是偶尔提前换一次。

★★ **上游没给 max-age 时行为必须一个字不变**(落点永不过期,失败再换)。
  少了这条兜底,不吐这个头的服务器会从「永不重解析」变成「每段都重解析」——
  **减压做成了加压**。门禁里为它单独留了一条用例,反向注入(把过期判定写成无条件生效)
  会让它当场红。

★ 余量 `resolveMargin` 必须 ≥ 单段取数的空闲上限(`chunkTimeout`,20s):
  在余量里发起的那一段要能在签名真正失效**之前**读完。留 0 的话边界上必然有一段
  撞在过期那一刻,表现是每隔 max-age 卡一下 —— 修了失败风暴,换来一个准点的小卡顿。
  而声明的寿命比余量还短时不减(减了是负数),那种链路照旧靠失败兜底。

`core/download` 那侧是同一个病根、另一套解法 —— 见下一条。


### 下载的重试预算按「有没有前进」扣,不按「失败了几次」 — 2026-09-04

`core/download` 老代码**一次重试都没有**:一段出错就 `stopAll()`,整条任务失败。
而它是 1~4 条**长连接**,一个分段一条 —— 于是带时效签名的直链(115 默认 30 分钟)
遇上一部要下几小时的原盘,签名**必然**在中途失效,任务必死。
用户看到的是「下到 37% 失败了,重下又从 37% 失败」。

做法(`core/download/retry.go` + `runSegment` 改成重试循环):

##### 1. 预算按「有没有前进」扣

    这一轮真写下了字节 → 重试计数清零
    一个字节都没写下  → 计数 +1,满 10 次放弃

★★ 按次数硬扣是错的:一部下 5 小时的片,每 30 分钟换一次签名 = 10 次,
第 10 次预算就烧光了 —— **而它每一次其实都下成了**。判据必须是「有没有前进」。

★ 配一个总轮数上限(200)兜底:防「每轮吐一点点字节就断」的病态上游让
「有进展就清零」这条规则永远转下去,而每一轮都是一次打在源站上的真实请求。

##### 2. 重试打的是 `it.URL`,不是上一轮跟到的落点
前后端分离的服会在这里重新发一次 302,换回一条**新签名**的直链。
「签名过期 → 整段死掉」就是这么修好的。续传点每轮重新按 **part 文件的实际大小**定,
不信上一轮自己记的数(它是被掐断的,记到哪儿不一定等于盘上真躺着多少)。

##### 3. 必须分出「重试也不会变对」的那一类
401/403、其余 4xx(除 408/429)、写盘失败、用户暂停/取消 → `permanentErr`,当场返回。
不分的下场是**把 401 重试十遍**:用户等一分钟才看到「无下载权限」,服务器白挨十次。
退避 1s 起翻倍、封顶 30s —— 太密只是给源站加压,而做这块的初衷正是给它减压。

##### ★★ 4. 干净的 EOF **不等于这一段下完了**
反代无视 Range 回一个更短的 Content-Length、CDN 提前收尾,都会产出
「读到头了但字节不够」的响应。老代码在这里直接 `return nil` ——
而 `assemble` 只按序拼接,**一个长度都不校验**(连 `os.Open` 失败都是 `continue`)。
结果是一个**短了却报「已完成」**的文件,播到一半就没了,一句错都不报。
有确定长度就自己核对,核不上按可重试的错抛出去,下一轮从断点续。

##### ★ 5. 反向注入撞出来的一个自己埋的雷
`!SupportsRange` 时重试要先 `os.Truncate(part, 0)`(续不上只能从头来,而 part 是
`O_APPEND` 打开的,不清就是把第二遍接在第一遍屁股后面)。但**文件还没建出来是正常情况**
—— 上一轮在建连阶段就挂了。不放过 ENOENT 的话,用户看到的错误会变成一句
"The system cannot find the file specified.",把真正的网络错误整个盖掉。

这条不是想出来的,是做「401 不许重试」那条用例的**反向注入**时,失败信息里冒出个
ENOENT 才发现的 —— 反向注入除了验门禁有效,还会顺路把新代码里的错误路径走一遍。


## 跨域交叉引用

这些条目和本领域强相关,但正文放在别的文件里(一条经验只存一份正文):

- [网盘/strm 播放两大坑](player-mpv.md) — 302 跳转流必须删 multiple_requests=1,否则分段 Range 慢 15 倍
- [跳到未缓冲位置卡死=我们拼错API根](emby.md) — 反代只在 /emby/ 下处理 Range
- [UHD fork 无视收藏 SortBy](emby.md) — fork 服会静默忽略参数,评估网络行为前先分清是哪台
- [CI 漏传编译期凭据](build-release.md) — 编译期凭据漏配也会表现成「网络功能不工作」
