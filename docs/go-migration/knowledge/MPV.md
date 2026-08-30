# libmpv 控制层知识

> 来源:`crates/mpv/src/lib.rs`(2245 行,逐行读完)、`crates/mpv/build.rs`、`crates/mpv/Cargo.toml`、
> `apps/desktop/src/lib.rs`(播放器相关全部命令)、`apps/desktop/build.rs`、`apps/desktop/src/shaders.rs`、
> `apps/android/src/lib.rs`(播放器部分 + JNI)、`apps/android/gen/android/.../MainActivity.kt`、
> `crates/core/src/media.rs`、`ui/desktop/App.tsx`(轮询/黑屏时序那一段),
> 并用仓库自带的 `crates/mpv/libmpv/client.h`(`MPV_CLIENT_API_VERSION` = 2.1,见 `client.h:251`)交叉核验了所有常量。
>
> **每条结论都带 `文件:行号`。** 读不出来的一律写「未确认」并说明查了哪里。
>
> 全文用两个标签区分知识性质:
> - **【mpv 事实】** —— libmpv 自身的行为约束。换成 Go + cgo 依然成立,必须原样继承。
> - **【本架构产物】** —— 由「Tauri 透明窗 + 独立顶层视频窗 / WebView」这套合成方案生出来的复杂度。
>   Go + 原生 UI 下会被整段删掉,**照抄就是白白继承一堆不必要的复杂度**。

---

## 0. 一句话

libmpv 控制层的全部难点不在 API,而在**时序**:`loadfile` 只排队就返回,
`FILE_LOADED` 之前发出的 `sub-add` / `seek` 会被静默丢弃;`keep-open=yes` 下 `END_FILE` 永远不发,
判播完只能读 `eof-reached`;`time-pos` 是「时有时无」的属性,把读不到当成 0 会毁掉整条进度链 ——
这一层的每一行代码几乎都在为某个「不报错、只是静默不干活」的真实故障买单。

---

## 1. 初始化参数全表

全部在 `Player::new()` 里、`mpv_initialize` **之前**用 `mpv_set_option_string` 设,
统一走一个闭包 `set`(`crates/mpv/src/lib.rs:1226-1230`)。

> ★ **这个 `set` 闭包吞掉 mpv 的返回码**(`crates/mpv/src/lib.rs:1229` 没有取 `mpv_set_option_string` 的返回值)。
> 选项名写错 / 该版 mpv 不认 = **静默无效**。这正是下面 `gpu-shader-cache-dir` 要单独回读校验的原因
> (`crates/mpv/src/lib.rs:1336-1357`)。**Go 侧必须把返回码收上来**,别再复制这个坑。

| 参数 | 值 | 作用 | 不设会怎样 | 平台 | 出处 |
|---|---|---|---|---|---|
| `wid` | 视频窗句柄(HWND / XID / ANativeWindow) | 指定 mpv 的渲染面 | 【本架构产物】mpv 认为「没给嵌入目标」,配合 `force-window=yes` **自己弹一个独立播放器窗口**,不受 UI 控制 | 三端 | `lib.rs:1231`;为 0 时提前报错见 `lib.rs:1192-1205` |
| `vo` | `gpu-next`(桌面)/ `gpu`(安卓) | 视频输出 | 【mpv 事实】安卓上 `gpu-next` 要 Vulkan / 更新的 libplacebo,机顶盒 GPU 驱动参差不齐,**起不来是黑屏不是报错** | 三端分岔 | `lib.rs:1232-1235` |
| `gpu-context` | `d3d11` | 走 D3D11 才能吃到独显钉定那条链 | 【本架构产物 + mpv 事实】不钉 d3d11 独显切换链路不成立(§6) | **仅 Windows** | `lib.rs:1241-1243` |
| `gpu-context` | `android` | 安卓没有 X11/Wayland,自动挑选挑不出东西 | 【mpv 事实】起不来 | 仅 Android | `lib.rs:1245-1246` |
| `gpu-context` | **故意不设** | 让 mpv 自己在 x11egl / x11vk / wayland 之间挑 | 【mpv 事实】写死任何一个都会在缺对应驱动/会话类型的机器上「起不来且不报错」 | **仅 Linux** | `lib.rs:1236-1240` 的注释 |
| `android-surface-size` | `"<w>x<h>"`(壳报的实际像素) | 视口尺寸 | 【mpv 事实】mpv 的 `vo_android_surface_size()`(`video/out/android_common.c`)**先读这个选项,没设才回退 `ANativeWindow_getWidth/Height`**,而后者只在 `android_reconfig()` 里调一次 —— 安卓没有 resize 事件通道,视口被冻在 EGL 初始化那一刻的尺寸,**画面四周留一圈没画到** | 仅 Android | `lib.rs:1247-1252`;来源链条与出处 `lib.rs:897-914` |
| `ao` | `audiotrack` | 音频输出 | 【mpv 事实】自动列表里 pulse/alsa 全试不通,最后落到 **`null` 而 `null` 是成功的** → 既不报错也没声音 | 仅 Android | `lib.rs:1253-1257` |
| `hwdec` | `mediacodec-copy` | 硬解 | 【mpv 事实】不带 `-copy` 是直出 Surface 的零拷贝路径,和我们自己的 SurfaceView 抢同一块面 → 花屏/黑屏 | 仅 Android | `lib.rs:1258-1261` |
| `sub-fonts-dir` | `/system/fonts` | libass 字体目录 | 【mpv 事实】安卓没有 fontconfig,不指这条 = **静默不画文本字幕**(SRT/ASS) | 仅 Android | `lib.rs:1262-1266` |
| `hwdec` | `auto-safe` | 硬解 | Win 挑 d3d11va,Linux 挑 vaapi/nvdec,挑不到就软解 | 桌面两端 | `lib.rs:1267-1269` |
| `keep-open` | `yes` | 播完不卸载文件,停在最后一帧 | 【mpv 事实】它是**一切换片/判播完问题的源头**:开着 → `END_FILE` 不发(§4)、上一片最后一帧留在画面上(§4) | 三端 | `lib.rs:1271` |
| `force-window` | `yes` | 没有视频也强制建窗 | 缓冲期间 mpv 自己画黑底(和 `stop` 配合,见 §4) | 三端 | `lib.rs:1272` |
| `idle` | `yes` | 播放列表空时核心不退出 | 【mpv 事实】libmpv 本来就默认开,但**显式钉死**:`load_inner` 换片前会发 `stop`,`idle=no` 时 `stop` 会让核心直接退出 = 「播第二个视频整个播放器没了」 | 三端 | `lib.rs:1273-1277` |
| `osc` | `no` | 关 mpv 自带 OSD 控制条 | UI 上会多出一条我们不控制的控制条 | 三端 | `lib.rs:1278` |
| `terminal` | `no` | 关终端输出 | | 三端 | `lib.rs:1279` |
| `input-default-bindings` | `no` | 关 mpv 默认键位 | 会和我们自己的快捷键打架 | 三端 | `lib.rs:1280` |
| `input-vo-keyboard` | `no` | 视频窗不吃键盘 | 【本架构产物】视频窗是我们自己建的顶层窗,吃键盘会抢走 UI 的输入 | 三端 | `lib.rs:1281` |
| `gpu-shader-cache` | `yes` | 开 shader 编译产物缓存 | 见下一行 | 三端 | `lib.rs:1290` |
| `gpu-shader-cache-dir` | `<数据根>/cache/shader-cache` | **必须显式给** | 【mpv 事实】libmpv 没有配置目录(日志里 `cache path: '' -> '-'`),不显式给 = **没有任何缓存**:每次起播把整条 Anime4K 链(最重档 6 pass、VL 模型 143K)重新 glsl→SPIR-V(shaderc)→HLSL(spirv-cross)→D3D 编译一遍,首帧干等一整轮。同时打「起播慢」和「一开超分就卡」 | 三端 | `lib.rs:1283-1291`;目录选址理由 `lib.rs:248-252` |
| `msg-level` | `all=v` | 日志级别 | **仅当环境变量 `LP_MPV_LOG` 存在时才设**,见 §11 | 三端 | `lib.rs:1301-1304` |
| `log-file` | `<logs>/mpv.log` | 日志落点 | 同上,**默认关**,理由见 §11 | 三端 | `lib.rs:1301-1304` |
| `config` | `yes` | 允许读配置文件 | 【mpv 事实】libmpv 默认 `config=no`:**一个配置文件都不读**(这是 libmpv 和 mpv 命令行最大的行为差异) | 三端,**仅当 `mpv.conf` 真存在** | `lib.rs:1306-1314`;设计说明 `lib.rs:254-265` |
| `config-dir` | `<数据根>/data/mpv/` | 用户配置目录 | 设上后 mpv 自己解析 `mpv.conf` / `input.conf` / `scripts/` —— **我们一行 ini 解析器都不用写** | 同上 | `lib.rs:1313` |

### 1.1 关于用户 `mpv.conf` 的三条硬约束

1. **必须在 `mpv_initialize` 之前设**:配置文件正是在 `mpv_initialize` 里解析的,晚一步完全不生效且不报错(`lib.rs:1306-1308`)。
2. **用户写的同名选项会盖掉我们上面那一整张表**(因为解析发生在 `mpv_initialize`,晚于所有 `set_option`)。
   这是「自定义内置 mpv」要的效果,代价是写坏了真能把播放搞挂(比如 `vo=null`)。故只在文件真存在时才开这条路(`lib.rs:254-265`, `lib.rs:1310-1311`)。
3. **`mpv_initialize` 失败时的错误串要点名 mpv.conf**:用户配置里一个非法选项就能让 initialize 直接失败,而错误串通常只有 `options/…` 这类天书(`lib.rs:1317-1331`)。

### 1.2 当前**没有设**的参数(和历史相比是回退)

以下四组在 Flutter 时代设过,Rust 重写后**全部丢失**,现在代码里一个都没有(全仓 grep `stream-lavf-o|multiple_requests|vd=|vd-lavc|hdr-compute|framedrop` 零命中,仅 `docs/go-migration/TODO.md:246` 挂着一条待办):

| 丢失项 | 原值 | 原因 | 证据 |
|---|---|---|---|
| `vd=-magicyuv` | 拉黑 magicyuv 解码器(CVE-2026-8461 / PixelSmash,libavcodec 堆越界写) | 见 §10-K | 引入 `fb5d3a5d`(Dart `mpv_player_adapter.dart`),随 `0dd295fe` 删 Flutter 一起没了 |
| `stream-lavf-o` 的 reconnect 组 | `reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=30` | 网络瞬断时 libavformat 透明重连 | `4d5837cd` 的 Kotlin 侧;当前 Rust 侧不设任何 `stream-lavf-o` |
| **不许**加 `multiple_requests=1` | —— | 见 §8,这是一条**负向**知识:加了会 ×15~×130 慢 | `4d5837cd` commit message + diff |
| 安卓软解调优 | `vd-lavc-threads`(铺满核心)/ `vd-lavc-skiploopfilter=nonref` / `vd-lavc-fast=yes` / `vd-lavc-dr=yes` / `framedrop=vo`;软解路径 `hdr-compute-peak=no` | 4K HEVC 纯软解在移动端严重卡顿 | `88757f17` 的 `MpvPlayerPlugin.kt` |

**Go 侧:这四组要不要恢复,是决策不是移植。** 但必须**显式决策**,不能像这次一样在重写中静默丢掉。

---

## 2. 事件与线程模型

### 2.1 线程结构

| 线程 | 干什么 | 出处 |
|---|---|---|
| 事件线程(每个 Player 一条) | `mpv_wait_event(ctx, 0.5)` 死循环,排空事件;**在这条线程上挂外挂字幕、补发 seek** | `lib.rs:1373-1435` |
| 宿主命令线程(Tauri worker / 主线程) | 所有 `set_property` / `get_property` / `command`;由 `Mutex<Option<Player>>` 串行化 | 桌面 `apps/desktop/src/lib.rs:5771`;安卓 `apps/android/src/lib.rs:138-148` |
| 主线程(仅桌面) | 【本架构产物】窗口几何 / z 序;`pin_below` **必须在宿主窗所属线程调**,`SetWindowLongPtr` 对别的线程拥有的窗口会**失败且不报错** | `crates/mpv/src/lib.rs:584-588` |

`mpv_command` 是线程安全的(官方文档明示),所以从事件线程发命令合法 —— `cmd_raw` 就是为此存在的自由函数(不依赖 `&Player`,`lib.rs:1056-1064`)。

### 2.2 监听的事件(只有两个)

| 事件 | 常量 | 什么时机发 | 我们做什么 | 出处 |
|---|---|---|---|---|
| `MPV_EVENT_FILE_LOADED` | 8 | **文件真正打开完毕**,此刻才有「当前文件」 | ① 置 `SubState.loaded=true` ② 取走并**发出**排队的 `seek`(并重置闩计时) ③ 逐条 `sub-add` 排队的外挂字幕 | 常量 `lib.rs:37`(核对 `client.h:1282`);处理 `lib.rs:1383-1423` |
| `MPV_EVENT_END_FILE` | 7 | 文件被卸载时 | `reason==ERROR(4)` → 置 `error_eof`(直链失效 → 302 重签);`reason==EOF(0)` → 置 `eof` | 常量 `lib.rs:28-32`(核对 `client.h:1277,1463,1479`);处理 `lib.rs:1424-1433` |

> ★ **`END_FILE_REASON_EOF` 原来根本没人 latch**,只 latch 了 ERROR。后果:自然放完时 Trakt/Bangumi 的「看完」
> 全靠用户手动退出播放页才触发,**看完走人 = 什么都没同步**(`lib.rs:30-32`)。
> 但即便补了它也不够 —— `keep-open=yes` 下这个事件压根不发,见 §4-C。

### 2.3 必须在事件线程做的操作

| 操作 | 为什么必须在事件线程 | 出处 |
|---|---|---|
| `sub-add`(排队的外挂字幕) | ① 只有 `FILE_LOADED` 之后才不会拿 -12;② **不能另开线程**:`Drop` 的顺序是 `running=false → join(事件线程) → mpv_terminate_destroy`,只有跑在这根线程上才被 join 保护住。另开线程会绕过它 —— 用户在字幕下载途中关播放器就是 **ctx 悬垂(use-after-free)** | `lib.rs:1404-1410`;Drop 顺序 `lib.rs:1950-1959` |
| 补发排队的 `seek` | 同上,必须等 `FILE_LOADED` | `lib.rs:1392-1403` |
| **不能**让调用方阻塞等 `FILE_LOADED` | 两端的调用点都在播放器锁内,在那儿等 = 拿着锁卡住整个 UI | `lib.rs:1380-1382` |

代价已被明确接受:`sub-add` 会**同步拉取字幕文件**(真服实测两条相隔 4s),这期间 `END_FILE` 只是**延迟** latch
(事件在 mpv 队列里不丢)——「拿几秒的延迟换掉一个 use-after-free,划算」(`lib.rs:1408-1410`)。

### 2.4 关闭序列

```
running.store(false)  →  event_thread.join()  →  mpv_terminate_destroy(ctx)
```
`lib.rs:1950-1959`。事件线程内的字幕挂载循环每轮都查 `running`,正在关闭就 break,让 join 早点回来(`lib.rs:1412-1415`)。

---

## 3. 属性全表

`get_str` / `set_str` 走 `mpv_get_property_string` / `mpv_set_property_string`(`lib.rs:1466-1481`);
数值走 `mpv_get_property(MPV_FORMAT_DOUBLE=5)`(`lib.rs:1487-1495`,常量核对 `client.h:702`)。

### 3.1 读取三档语义(**这是本层最容易写错的地方**)

| helper | 语义 | 用在哪 | 出处 |
|---|---|---|---|
| `try_f64` | `rc>=0 && 有限` 才 `Some`;**NaN 也当读不到**(mpv 在换片瞬间会给 NaN,直接吐前端会变 JSON `null`) | seek 闩的输入 | `lib.rs:1487-1495` |
| `get_f64` | `try_f64().unwrap_or(0.0)` | speed / volume / delay 这类「0 是合法值」的 | `lib.rs:1497-1499` |
| `sticky_f64` | 读到就更新记账格,**读不到就沿用上一次** | `time-pos` / `duration` / `demuxer-cache-time` | `lib.rs:1501-1511` |

> ★ 老代码的 `get_f64` **不看返回值**,`mpv_get_property` 失败时**不写 out**,于是把栈上初值 `0.0` 当成「位置=0」交出去。
> `time-pos` / `duration` 在 seek 中、换片解码就绪前、缓冲饥饿时都会返回 `MPV_ERROR_PROPERTY_UNAVAILABLE`(-10,`client.h:335`),
> **属于常态而非异常**。表现:进度条每隔几拍抽回开头再弹回来,和画面完全对不上(`lib.rs:1103-1108`, `lib.rs:1483-1486`)。

### 3.2 属性总表

| 属性 | 类型 | 读/写 | 用途与时机 | 陷阱 | 出处 |
|---|---|---|---|---|---|
| `time-pos` | double | 读(`try_f64` + 粘性) | 播放位置,前端每 250ms 轮询 | **不可用是常态**;seek 后、mpv 真跳过去之前它仍**报得出旧位置**(不是读不到) | `lib.rs:1656`;粘性格 `lib.rs:1103-1109` |
| `duration` | double | 读(粘性) | 总时长 | 换片后到 `FILE_LOADED` 之间读不到;前端**不许**用 0 盖掉已知时长,否则量程塌成 1 秒 | `lib.rs:1678`;前端护栏 `ui/desktop/App.tsx:1021-1027` |
| `pause` | string yes/no | 读+写 | 暂停 | 和 `paused-for-cache` **读数一样**,必须分开读才能区分「用户暂停」和「在缓冲」 | 写 `lib.rs:1593-1595`;读 `lib.rs:1679` |
| `paused-for-cache` | string yes/no | 读 | 「正在缓冲」 | 同上 | `lib.rs:1689-1691` |
| `seeking` | string yes/no | 读 | seek 闩的**权威信号**;见过 yes 再回 no = 确定落地 | 比「位置和目标差多少」可靠得多 —— 关键帧落点可以离目标好几秒 | `lib.rs:1657`;语义 `lib.rs:1122-1125` |
| `demuxer-cache-time` | double | 读(粘性) | 缓冲条 | 【易错】它是**已缓冲数据的最后一个时间戳(绝对位置)**,不是时长(那是 `demuxer-cache-duration`)。别顺手改成 duration 版 | `lib.rs:1680-1683` |
| `cache-speed` | string→f64 | 读 | 缓冲速度(字节/秒) | **故意不走粘性**:速度就该跟着实况抖,粘住旧值等于骗人。本地文件/缓存喂饱时是 0,界面据此不显示 | `lib.rs:1684-1688` |
| `eof-reached` | string yes/no | 读 | **判播完的唯一可靠途径**(`keep-open=yes` 下 `END_FILE` 不发) | 见 §4-C | `lib.rs:1692-1698` |
| `current-vo` | string | 读 | 「有声音没画面」自诊断:**空 = vo 没起来** | 空串 ≠ 没有这个属性 | `lib.rs:1717` |
| `dwidth` / `dheight` | string→i64/f64 | 读 | **显示**尺寸(已算进非方像素/裁剪)= shader 里的 `MAIN` | 不是 `width/height` | `lib.rs:1718-1719`, `lib.rs:1926-1932` |
| `video-codec` | string | 读 | 有没有视频轨(纯音频文件黑屏是对的,不该报错) | | `lib.rs:1720` |
| `hwdec-current` | string | 读 | **实际生效**的硬解 | `hwdec()` 先读 current 再回落 `hwdec`(设定值) | `lib.rs:1721`, `lib.rs:1834-1838` |
| `osd-width` / `osd-height` | string→f64 | 读 | mpv 输出区尺寸 = shader 里的 `OUTPUT` | **是窗口大小,不是屏幕大小** | `lib.rs:1933-1938` |
| `track-list/count` | string→usize | 读 | 轨道枚举 | | `lib.rs:1725` |
| `track-list/N/{type,id,title,lang,selected,codec,demux-channel-count}` | string | 读 | 轨道明细;`codec`+`channels` 是**正则筛选**要匹配的(wiki regex-filters 口径) | 只收 `audio`/`sub` | `lib.rs:1727-1743`;字段契约 `crates/core/src/media.rs:17-38` |
| `aid` / `sid` | string | 写 | 选音轨/字幕轨;`sid="no"` = 关字幕 | | `lib.rs:1746-1758`;`"no"` 来源 `crates/core/src/media.rs:83-87` |
| `secondary-sid` | string | 写 | 次字幕;空串映射成 `"no"` | 次字幕位**只有一个** | `lib.rs:1882-1884` |
| `speed` | double(写 string) | 读+写 | 倍速,clamp `0.1..=6.0` | mpv 的 speed 同时变调,靠 `audio-pitch-correction`(默认开)保音高 | `lib.rs:1778-1785` |
| `volume` | double | 读+写 | 音量,clamp `0..=130`(130 是软增益) | | `lib.rs:1787-1793` |
| `mute` | yes/no | 读+写 | | | `lib.rs:1794-1799` |
| `audio-delay` / `sub-delay` | double | 读+写 | 音画/字幕同步,可负 | | `lib.rs:1808-1821` |
| `secondary-sub-delay` | double | 写 | | | `lib.rs:1893-1895` |
| `video-aspect-override` | string | 写 | 画面比例;`""`/`auto` → `-1` 复位 | | `lib.rs:1823-1827` |
| `hwdec` | string | 写 | 硬解档位;`"no"` = 软解 | | `lib.rs:1829-1833` |
| `sub-font` | string | 写 | 字幕字体 | **必须守卫 UI 占位「默认」**,不该塞给 libass | `lib.rs:1841-1847` |
| `sub-scale` | double | 写 | **这才是「字幕大小」该拧的旋钮**,clamp `0.2..=4.0` | 见 §10-F:ASS 字幕**完全忽略 `sub-font-size`** | `lib.rs:1848-1860` |
| `sub-pos` | **整数** | 写 | 字幕竖直位置 0(顶)~100(底) | **mpv 只收整数**,给小数会拒 | `lib.rs:1869-1872` |
| `sub-back-color` | `#AARRGGBB` | 写 | 字幕背景:`#80000000` / `#00000000` | ASS 自带样式的字幕不受影响 | `lib.rs:1873-1876` |
| `blend-subtitles` | string | 写 | 字幕混合模式 | | `lib.rs:1877-1879` |
| `secondary-sub-pos` | 整数 | 写 | 次字幕位置 | **mpv 真默认是 0(顶部)**,前端曾写死 100 → 面板读数和画面对不上 | `lib.rs:1896-1898`;前端修正 `ui/desktop/App.tsx:346-348` |
| `secondary-sub-ass-override` | 枚举 `no\|scale\|force\|strip` | 写 | 次字幕 ASS 处理 | **mpv 默认 `strip`**(剥成纯文本);传非法值 mpv 只会**静默拒绝**,所以这里先挡一道 | `lib.rs:1861-1868` |
| `http-proxy` | string | 写 | media 走代理;空串 = 直连 | **SOCKS 不被 mpv 支持**,只传 `http://` | `lib.rs:1513-1516`;调用点 `apps/desktop/src/lib.rs:1750-1755` |
| `http-header-fields` | string | 写 | 逐流 headers,逗号分隔 `"Key: Value"` | **实例级粘连属性**,见 §8;含逗号的值会串味(已知限制,当前源不涉及) | `lib.rs:1524-1538`, `lib.rs:1581` |
| `user-agent` | string | 写 | | **实例级粘连属性**,见 §8 | `lib.rs:1582-1586` |
| `start` | string | 写 | 续播起点;`<=1.0` 时写 `"none"` | 下一次 `loadfile` 才生效 —— **故意用它而不是起播后 seek** | `lib.rs:1587-1590`, `lib.rs:1518-1522` |
| `glsl-shaders` | `;` 分隔路径 | 读+写 | 超分 shader 链;空串 = 关 | **收下 ≠ 会跑**,见 §7 | `lib.rs:1908-1917`, `lib.rs:1940-1947` |
| `glsl-shader-opts` | `K=V,K=V` | 写+**回读** | shader 参数 | 参数名写错 mpv **拒掉整条 opts 且无任何提示** → 强度静默回默认。故 `set_shader_opts` 返回「是否设上了」 | `lib.rs:1918-1924` |

### 3.3 命令(`mpv_command`)

| 命令 | 用途 | 出处 |
|---|---|---|
| `loadfile <url>` | 起播。**异步**,只排队 | `lib.rs:1591` |
| `stop` | 换片前清掉上一片最后一帧 | `lib.rs:1554-1561` |
| `seek <t> absolute` | 绝对跳转。**排队命令** | `lib.rs:1640`;补发路径 `lib.rs:1396` |
| `sub-add <url> auto <title>` | 挂外挂字幕;`flags=auto` = 挂上但不自动切 | `lib.rs:1611`, `lib.rs:1417` |
| `screenshot-to-file <path> video` | 截图。用它而非 `screenshot-raw`(后者要走 `mpv_node` 取原始像素再自己编码);`"video"` = 不带 OSD/字幕 | `lib.rs:1801-1806` |

---

## 4. 时序约束清单 ★ 本文档最重要的一节

### A. `loadfile` 是异步的,只排队就返回

【mpv 事实】`loadfile` 只把条目排进 playlist 就返回,**此刻并没有「当前文件」**
(`lib.rs:33-37`)。ctypes 实跑 libmpv v0.41 复现:立刻挂字幕 → 字幕轨 0 条;等到 `FILE_LOADED` 再挂 → 成功 1 条。

### B. `FILE_LOADED` 之前会被静默丢弃的操作

| 操作 | 拿到什么 | 症状 | 解法 | 出处 |
|---|---|---|---|---|
| `sub-add` | `-12 error running command` | 详情页看得见字幕(那是 Emby 的 MediaStreams),播放页字幕列表却是空的。而旧代码是 `let _ = self.cmd(...)`,错误被吞掉,日志里还照打「挂载外挂字幕 N 条」 | 锁内判 `loaded`:没开好就排队,`FILE_LOADED` 由事件线程挂 | `lib.rs:1596-1616`;回归测试 `lib.rs:2060-2105` |
| `seek` | 命令错误(那会儿没有文件可跳) | 而**闩在发命令之前就设上了** → 进度条压着用户拖到的位置 2.5s,然后弹回 `start=` 的续播点,画面从头到尾没跳过 | 同一个解法:`queue_seek` 排队,`FILE_LOADED` 补发 | `lib.rs:1074-1092`, `lib.rs:1634-1638`;回归测试 `lib.rs:2222-2244` |

**排队的两条状态必须在同一把锁里**(`SubState { loaded, pending, pending_seek }`,`lib.rs:1066-1081`)。
拆成 `AtomicBool + Mutex<Vec>` 会有 TOCTOU:调用方读到 `loaded=false` 正准备写 pending,
事件线程恰好收到 `FILE_LOADED` 并取走(空的)pending,字幕就永远没人挂了,**而且一声不吭**。

**补发 seek 时必须重置闩的计时起点**(`lib.rs:1389-1395`):闩是用户拖的那一刻设的,
加载花掉的几秒会让它一进来就判超时,真正的 seek 还没落地进度条就弹回去了。

**起播途中连点几下只留最后一条**(`lib.rs:1090`),和 seek 的语义一致 —— 排成队会跳一串。

### C. `keep-open=yes` 下 `END_FILE` 永远不发

【mpv 事实】mpv 到结尾时是「暂停在最后一帧」而**不卸载文件**,`END_FILE` 压根不发 ——
**只监听事件就是个永远不触发的死分支**(`lib.rs:1692-1698`)。

判播完必须读 `eof-reached` 属性(mpv 文档里它正是为 `keep-open` 场景准备的)。
事件那条线仍保留(`reason=EOF` 时置位),两者**取或**,谁先到算谁:
```rust
eof: self.get_str("eof-reached").as_deref() == Some("yes") || self.eof.load(...)
```
`lib.rs:1697-1698`。`take_eof()` 取一次即清零,保证同一次播放只触发一次同步(`lib.rs:1453-1457`)。

前端侧还要再上一道锁(`ended` ref):`eof` 会一直是 true,轮询每 250ms 跑一次,不锁就重复 stop
(`ui/desktop/App.tsx:1054-1063`);`duration` 拿不到时退回 `time` —— 传 0 会把刚看完的片记成「没看」。

### D. seek 闩的设计

**为什么需要闩**(`lib.rs:1617-1622`, `lib.rs:1647-1650`):
mpv 的 seek 是排队命令,`cmd` 返回只代表「收到」;`time-pos` 要等解码器真跳过去才更新(网络流 50~500ms)。
前端每 250ms 轮询必然打进这个窗口,读到**旧位置** → 界面把刚拖到的位置弹回原处,而画面已经跳走了。

**记账放在发命令之前**(`lib.rs:1623-1633`):seek 失败最坏是记了个没到达的位置,下一拍被真值盖掉;
放在之后则会和「命令已生效、属性已更新」的那一拍抢写,把新值又盖回旧值。
同时 `last_buf` 也要跟着跳(seek 重开 demuxer,旧 buffered 是跳之前那一段的末端;往回拖时它比新位置大一大截,
粘性值再兜住 → 缓冲条停在用户跳走的地方不动,`lib.rs:1626-1628`)。

**发 `t` 不是 `secs`**:负数被 `max(0.0)` 夹过,闩记 0 而命令送 -30,两边对不上(`lib.rs:1639`)。
命令发失败要立刻清闩,否则只是把进度条钉在一个到不了的位置上 2.5s(`lib.rs:1641-1644`)。

#### ★★ 为什么不能拿粘性值和目标比

`apply_seek_latch` 的 `reported` 参数**必须是这一拍真读到的 `time-pos`**(`try_f64`,读不到就是 `None`),
**绝对不能传「读不到就沿用上次」的粘性值**(`lib.rs:1152-1161`, `lib.rs:1651-1656`)。

原因:粘性值在 seek 期间**恰好等于闩的目标位** —— 因为 `latched_time` 每拍都把目标写回 `last_pos`
(`lib.rs:1663-1669`)。于是 `|reported - target| == 0`,闩在**第一次 `time-pos` 读不到时就自解除**。

- 本地文件 seek 一拍就完事,`time-pos` 从不缺席 → 看不出问题;
- 网络流 seek 中 `time-pos` 频繁不可用 → 闩当场松掉,下一拍 mpv 报的还是**旧位置** → 进度条跳回去/跳到别处。

这就是用户报的「本地跟手、服务器上一拖就乱」的根因。

#### 松闩的三条路(任一成立,`lib.rs:1175-1185`)

1. `saw_seeking` —— 见过一整轮 `seeking=yes` 又回到 `no`,mpv 确定落地了(**最可靠**,因为关键帧落点可以离目标好几秒);
2. `|r - target| <= SEEK_SETTLE_SECS`(1.5s,比一个 GOP 略宽)—— seek 快到一拍都没抓到 `seeking=yes`,本地文件常见;
3. `elapsed >= SEEK_LATCH_TIMEOUT`(2500ms)—— 命令多半压根没生效,继续压着只会变成「进度条永远不动」(拿一个 bug 换另一个)。

超时**只在 mpv 说自己没在 seek 时计时**(`seeking=true` 直接 return,不走到超时判断,`lib.rs:1168-1172`)——
它管的是「命令根本没被执行」,而不是「网络慢、seek 做得久」。后者由 `seeking` 属性负责,爱做多久做多久。

常量:`SEEK_SETTLE_SECS = 1.5`(`lib.rs:1128-1130`)、`SEEK_LATCH_TIMEOUT = 2500ms`(`lib.rs:1131-1134`)。

#### seek 卡死上报

`SEEK_STALL_TIMEOUT = 12s`(`lib.rs:1135-1144`)。判据只有一条:**mpv 亲口说还在 seek,且这已经是很久以前发出的了**
(`lib.rs:1146-1150`)。不看位置差 —— 卡住的时候 `time-pos` 通常压根读不到。
必须**先判卡死再套闩**,因为 `apply_seek_latch` 可能把闩清掉,清掉之后就无从判断了(`lib.rs:1659-1661`)。

门槛 12s 的由来(2026-07-27 用户两台服务器实测):服务器**宣称** `Accept-Ranges: bytes` 却对任何 `Range:` 回 `200 OK` + 完整 Content-Length,
ffmpeg 只能从当前位置**顺读丢弃**到目标字节(往前跳 9 分钟 = 370MB)。同一台上跳 3 秒实测要 7s 才落地,
12s 才能把「慢」和「这辈子到不了」分开。**这不是播放器的问题,但不能让用户对着不动的进度条干等。**

### E. 换片时的复位顺序(`load_inner`,`lib.rs:1547-1592`)

严格按这个顺序,每一步都有对应的真实故障:

| # | 动作 | 不做会怎样 | 行号 |
|---|---|---|---|
| 1 | `cmd(["stop"])` | `keep-open=yes` 让上一片停在最后一帧不卸载;视频窗一露脸、新片还在缓冲的几秒里,用户看到**上一部片的画面当背景**。`stop` 卸载文件 → `force-window` 下 mpv 自己画黑底 | `lib.rs:1554-1561` |
| 2 | `eof.store(false)` | 上一集播完的标志被下一集第一次轮询读到,**刚起播就被判成「已看完」** | `lib.rs:1562-1564` |
| 3 | `last_pos = start_secs`、`last_dur = 0`、`last_buf = 0` | 新片 `time-pos` 就绪前那几拍把**上一集的位置**当本集位置吐出去(进度条一起播就停在别人的进度上)。起点直接落 `start_secs`,续播第一拍就是对的 | `lib.rs:1565-1570` |
| 4 | `seek_latch = None` | 上一集没落地的 seek 会压制新片的位置 | `lib.rs:1571` |
| 5 | `subs.loaded=false; pending.clear(); pending_seek=None` | `loaded` 不清 → 下一集的 `set_external_subs` 以为文件已开好而立刻 `sub-add`(又回到 -12);`pending` 不清 → 上一集没挂成的字幕漏到这一集;`pending_seek` 不清 → 上一集的 seek 落到新片头上 | `lib.rs:1572-1580` |
| 6 | `set("http-header-fields", ...)`、`set("user-agent", ...)` —— **无条件重设,不是「有才设」** | 见 §8 的属性粘连 | `lib.rs:1581-1586` |
| 7 | `set("start", ...)` | 用 `start` 而不是起播后 seek,避免 seek 早于解码就绪失败 | `lib.rs:1587-1590`, `lib.rs:1518` |
| 8 | `cmd(["loadfile", url])` | | `lib.rs:1591` |

> `stop` 必须在记账**之前**发:它是异步命令,但 mpv 按序处理,它和紧跟的 `loadfile` 之间不会插进别的播放(`lib.rs:1558-1560`)。

### F. 换片时 `ready` 复位的顺序(前端侧,同一根因的另一半)

【本架构产物,但**规格要保留**】`setReady(false)` **必须在任何 `await` 之前**
(`ui/desktop/App.tsx:685-697`)。

根因**不是**「没人复位 ready」(`afterStart` 里一直有一句),而是**那一句太晚了**:
它排在 `getPlaybackPrefs()` 和 `play()` 两个 await 后面,而 `play()` 要走 PlaybackInfo → 取流地址 → 起预取代理,
慢服务器上是**好几秒**。那几秒里 `playing` 还是上一集、`ready` 还是 true → 黑屏层不渲染,
而 mpv 那边 `keep-open=yes` 让上一集停在最后一帧没卸载 —— 用户看到的就是上一个视频的画面。

**两道都要**:核层的 `stop`(管 mpv 自己的画布)和前端的 ready 复位(管我们的遮罩),它们盖的是不同的时间段(`App.tsx:694-695`)。

还有第三个坑:**上一片的轮询在起播期间还在跑**,每 250ms 把 `ready` 拍回 true。
所以要一面 `starting` 旗子让轮询闭嘴(`App.tsx:278-281`, `App.tsx:1035`)。

### G. 撤黑屏的判据

不是 `st.time > 0`,而是**时间真的往前走了**(`st.time > startPos + 0.05`):
续播时核层一 `loadfile` 就把位置记账成 `start_secs`,第一拍读到的就已经 > 0 ——
旧判据在续播路径上等于「起播即放行」,缓冲还没出画就把上一片的残帧亮了出来(`App.tsx:1030-1036`)。
4s 兜底放行,但**必须先不在等缓冲**(`!st.buffering`)。

### H. `duration == 0` 时进度条量程会塌成 1 秒

前端轮询里 `st.duration > 0 ? st : {...st, duration: 已知值}`(`App.tsx:1021-1027`)。
不做:量程 `Math.max(1, 0)` = 1 秒,用户点条中间 → 目标 0.5 秒而不是片长一半 → 「点了跳转、画面没动」。
**塌了的量程比没有量程更危险。**

### I. 起播 → 露出视频窗的顺序

【本架构产物】`show_video(&state, true)` **必须在播放器锁之外**(它自己要拿这把锁)——
`apps/desktop/src/lib.rs:1770-1771`。凡是把新文件塞给 mpv 的命令都必须自己开这一下,
有源码级契约测试钉住(`apps/desktop/src/lib.rs:6683-6738`)。
2026-08-16 就漏在 `source_play` 上:mpv 在放、有声音、进度在走,**画面窗口从头到尾没露过面**。

---

## 5. 硬解与 GPU

### 5.1 各平台默认值

| 平台 | vo | gpu-context | hwdec 默认 | 出处 |
|---|---|---|---|---|
| Windows | `gpu-next` | `d3d11`(写死) | `auto-safe` → 实际挑 `d3d11va`(零拷贝) | `lib.rs:1235,1242,1269`;`d3d11va` 结论 `lib.rs:1829-1830` |
| Linux | `gpu-next` | **不设**(mpv 自己在 x11egl/x11vk/wayland 里挑) | `auto-safe` → vaapi/nvdec | `lib.rs:1236-1240,1269` |
| Android | `gpu` | `android` | `mediacodec-copy`(写死,不是 auto) | `lib.rs:1235,1246,1261` |

用户可选值只有两个:`"auto-safe"`(硬解,默认)/ `"no"`(软解)。
**值直接喂 mpv,不在配置里存 "hw"/"sw" 再到处翻译**(`crates/core/src/config.rs:249-252`);
安卓设置命令对这两个值做白名单校验(`apps/android/src/lib.rs:2126-2128`)。

### 5.2 `dxva2-egl` 是红鲱鱼

`hwdec()` 读 `hwdec-current` 优先(`lib.rs:1834-1838`)。
历史结论(`lib.rs:1829-1830` 引 `[[desktop-double-audio-orphan-player]]`):Win 默认改 `d3d11va` 零拷贝,
**`dxva2-egl` 的 EGL 报错是无害红鲱鱼**(`GL_RENDERER` 正常)。

### 5.3 杜比视界自动切软解

`apply_playback_defaults`(`apps/desktop/src/lib.rs:1608-1627`):

```rust
let effective = if dolby_auto && is_dolby_vision { "no" } else { hwdec.as_str() };
p.set_hwdec(effective);
p.set_speed(speed);
```

- **每次 `loadfile` 之前调一次**,不是初始化时设一次:用户改完设置不重启也得生效,而且 DV 是**逐片**判定的 ——
  上一部是 DV 切了软解,下一部普通片必须切回硬解,否则白白吃一部片的 CPU(`apps/desktop/src/lib.rs:1608-1612`)。
- 理由:DV 走硬解在多数 Windows 显卡上出色偏移(发绿/发紫),软解画面才是对的(`lib.rs:1618-1620`;默认开,`crates/core/src/config.rs:267-270`)。
- DV 判定在核层:`crates/core/src/emby.rs:330`(`is_dolby_vision`),来源是 `MediaStream.VideoRangeType`,老服务器不发时靠 codec/profile 兜底(测试 `emby.rs:2542-2546`)。
- 三条调用点:`play`(`lib.rs:1756`,带真 DV 标志)、`source_play`(`lib.rs:3772`,传 `false` —— 源播放没有 Emby 的 MediaStreams,判不出 DV)、`play_local`(`lib.rs:5087`,同理)。
- 前端要照实反映:`PlayerOpts.dolby_vision` 存在的理由就是「核层已经自动切了软解,前端不能还把开关画成关着」(`apps/desktop/src/lib.rs:2254-2259`)。

> ⚠️ **安卓端完全没有这一段。** 全仓 grep `apply_playback_defaults` 只有 `apps/desktop`,
> 安卓的注释明确写着「桌面那边多做两件安卓没有的事:`apply_playback_defaults`」
> (`apps/android/src/lib.rs:259-261`, `298-299`)。
> 后果:安卓上**用户设的 hwdec 偏好、默认倍速、杜比自动软解三项全部落库但没人读**。
> 而设置命令还在校验 `settings.hwdec`(`apps/android/src/lib.rs:2126`)—— 典型的「假落地」。

### 5.4 安卓软解调优

**当前 Rust 版一条都没有**(见 §1.2)。Flutter 时代的那一套(`88757f17`):
`vd-lavc-threads` 铺满核心 / `vd-lavc-skiploopfilter=nonref` / `vd-lavc-fast=yes` / `vd-lavc-dr=yes` / `framedrop=vo`,
以及**软解路径关 `hdr-compute-peak`**(逐帧 GPU 直方图 compute shader,移动 GPU 上开销很大;
软解时 CPU 已被解码吃满,再叠 per-frame 峰值检测就明显卡顿)。

---

## 6. 渲染面与窗口

> **本节 90% 是【本架构产物】。** `docs/go-migration/SPEC.md:993` 已经写明:
> 「独立顶层窗口的对齐逻辑**整段删除**」,`TODO.md:250-252` 列了删除清单。
> 下面逐段标注,并把**会保留下来的那几条**单独拎出来。

### 6.1 三端渲染面对照

| 平台 | 渲染面 | 建法 | 时机 | 出处 |
|---|---|---|---|---|
| Windows | **独立顶层**无边框窗(类名 `lpvid`,`WS_POPUP \| WS_EX_TOOLWINDOW \| WS_EX_NOACTIVATE`) | `CreateWindowExW`,**不带 `WS_VISIBLE`** | 同步,App 启动时 | `lib.rs:299-366` |
| Linux(X11) | **独立顶层** override-redirect 窗 | `XCreateWindow` + `override_redirect=True`,**建完不 map** | 同步 | `lib.rs:652-731` |
| Android | SurfaceView 的 `Surface`(**全局引用**) | 系统在 `surfaceCreated` 回调里给;`create()` 只是**取**壳先前存进来的 | **异步,不由我们定** | `lib.rs:837-889` |
| 其它 | 兜底桩,全 no-op | | | `lib.rs:964-981` |

**为什么不能用子窗口**(`lib.rs:292-297`):Windows 上子窗口进不了逐像素透明的分层窗口;
X11 上兄弟窗口之间根本不做 alpha 混合(合成器只合成顶层窗口)。两边都只有「顶层垫顶层」这一条路。

### 6.2 Windows:wndproc 子类化 + z 序钉住 【整段删除】

| 机制 | 干什么 | 为什么这么写 | 行号 |
|---|---|---|---|
| `pin_below` 子类化宿主窗 | 接管 `WM_WINDOWPOSCHANGED` | 位置/尺寸/z 序**任一变化都发它**,不用枚举「还有哪些路径没覆盖」 | `lib.rs:528-620` |
| **重入闸 `IN_SYNC`** | 防爆栈 | 回调里调 `SetWindowPos/ShowWindow` 会改主窗相对 z 序 → Windows 又发一条 `WM_WINDOWPOSCHANGED` → 递归到栈溢出,**进程无声消失**(日志停在最后一行,没有 panic)。实测:装上钩子后鼠标挪一下窗口 App 就没了 | `lib.rs:554-558,582` |
| **可改挂**(先卸旧再装新) | 播放页独立成窗口后视频窗要在主窗/播放窗之间改挂 | `PREV_PROC` 只有一个槽:不卸就装第二个,旧宿主的原 wndproc 被永久覆盖,**那个窗口从此收不到自己的消息** | `lib.rs:539-544,596-604` |
| 重复装守卫 | `HOOKED_HWND == tauri` 直接 return | 重复装会把自己的 `host_proc` 存进 `PREV_PROC` → 无限递归 | `lib.rs:593-595` |
| `prev == 0` 时**不装** | 拿不到原 wndproc 就降级 | 装了却全喂 `DefWindowProcW` = 把 Tauri 窗口过程整个换掉,窗口彻底不响应。降级成「只靠事件重排」远比这个好 | `lib.rs:608-615` |
| `IsWindow(v)` 校验 | 句柄可能已失效 | Player 在 `Mutex<Option<Player>>` 里,替换/销毁时视频窗没了而 static 还留着旧 HWND;拿失效句柄 `SetWindowPos` 是典型「无声死亡」 | `lib.rs:568-571` |
| **必须在宿主窗所属线程调** | `SetWindowLongPtr` 对别的线程拥有的窗口**失败且不报错** | 表现:「改挂了但 z 序还跟着老窗口」 | `lib.rs:584-588` |

### 6.3 几何:两个入口共用一份算术 【整段删除】

**这是全节最容易漏的一条。** 几何有**两个**入口:

1. `sync()` ← Tauri 的 `Resized / Moved / Focused(true)` 事件(`lib.rs:515-526`;桌面侧 `apps/desktop/src/lib.rs:244-288`);
2. `align_to_host()` ← `WM_WINDOWPOSCHANGED` 钩子,**它自己 `GetClientRect` 重新算,根本看不到调用方算过什么**(`lib.rs:391-433`)。

「全屏后一圈白边、必须窗口化再全屏才消失」的根治点(`lib.rs:393-404`):
Alt-Tab 回来、点任务栏回来、DPI 变化、别的全屏应用切走再切回……**都不产生**那三个 Tauri 事件,
视频窗停在上一次的矩形上 → 四周露出一圈。**症状能被一个特定手势稳定治好,就说明缺的不是计算,是触发。**

顶部让位(播放窗自绘标题栏 36px)因此做成**进程级的一个值** `OVERLAY_TOP_INSET`,两条路径读同一个数(`lib.rs:988-1024`)。
放在 `cfg` 之外也是刻意的:做成每个 overlay 变体各一份 `set_top_inset` 就是「桌面绿、别的变体忘了补」的形状(`lib.rs:1000-1003`)。

`align_target` 抽成纯函数是为了**能测**(Win32 那半测不了,这半是唯一会算错的地方,`lib.rs:435-463`),三条守则:
- 客户区 0×0(最小化)→ **不动**。照摆会把视频窗缩成 0×0,**之后再也长不回来**(mpv 视口跟着塌了)→「最小化再恢复就没画面」;
- 已经对上了 → 不动(重入闸:`SetWindowPos` 哪怕没改任何东西也会再发一条消息);
- 顶部让位必须在**这里**也减掉(`lib.rs:443-445`);
- **0×0 守则要先于让位**,顺序反了的话最小化时 `h` 会被 `max(1)` 兜成 1,守则失效(`lib.rs:456-457`)。
- `h` 恒留至少 1px:窗口拖到只剩标题栏高时,让位不能把视频窗压成 0 高(`lib.rs:1016-1024`)。

### 6.4 显隐:两个条件的与 【整段删除】

`show = WANT_VISIBLE && !IsIconic(host) && IsWindowVisible(host)`(`lib.rs:368-384`)。
收敛成一个函数是因为它有三个调用点(`sync` / `host_proc` / `set_visible`)—— 散着写必然出现「A 把它藏了 B 又把它亮出来」。
**状态已经对就别调 `ShowWindow`**:它会动 z 序,而我们正挂在 z 序变化的回调里。

建窗时**不带 `WS_VISIBLE`**(`lib.rs:345-349`):老代码可见 + `sync()` 每次带 `SWP_SHOWWINDOW`,
于是这个黑窗从 App 启动那一刻就一直挂在桌面上,主窗一最小化就露出来 —— 用户报的
「反复最小化能看到后面层级窗口正在播放」。X11 那半是同一个 bug 的镜像(建完就 map,`lib.rs:725-727`)。

### 6.5 Linux / X11 复刻 【整段删除】

| 点 | 内容 | 行号 |
|---|---|---|
| Xlib 错误处理器**必须换掉** | 默认处理器**直接 abort 整个进程**;我们干的正是最容易撞 BadWindow/BadMatch 的活(窗口可能刚被 reparent 或已销毁,错误异步回来)。不换 = 一次竞态 = 一次「播放中无故崩溃」 | `lib.rs:666-674` |
| 自己开一条 Display 连接 | 不蹭 GTK 那条(GTK 的连接由它自己的主循环独占,从别处塞请求是竞态);mpv 拿到 wid 后也会自己开连接,这是 `--wid` 的常规用法 | `lib.rs:681-683` |
| `toplevel_frame` 上溯 | **不能直接拿 Tauri 的 client window 当层叠兄弟**:重定向式 WM(绝大多数)会把它 reparent 进装饰框,于是它和我们的 root 直属 override-redirect 窗**不是兄弟**,`XConfigureWindow` 会 BadMatch —— 而错误被上面的处理器吞掉,表现是**静默不排序**(视频盖在 UI 上,或干脆看不见) | `lib.rs:733-757` |
| 宽高夹到 ≥1 | 宽高为 0 在 X11 上是 BadValue(Win32 只是忽略) | `lib.rs:820-821` |
| 最小化判据不同 | X11 上没有 `IsIconic` 那种便宜的查法;主窗最小化时 Tauri 报 `Resized(0,0)`,`sync` 据此不再 map(`w>1 && h>1`) | `lib.rs:759-760, 809-816` |
| **`pin_below` 是 no-op** | X11 上没有 `WM_WINDOWPOSCHANGED` 的等价消息;要等价效果得 `XSelectInput(StructureNotify)` 主窗 frame 再自己跑事件循环,而那个 frame 会被 WM 换掉(reparent),得跟着重挂。**已知的能力差,不是忘了写** | `lib.rs:788-793` |
| `is_host` 恒真 | 没有钩子就没有「当前宿主」概念;返 false 会把 Linux 上的对齐整个关掉 | `lib.rs:795-800` |
| 强制 `GDK_BACKEND=x11` | **Wayland 协议上就不允许应用定位自己的顶层窗口**,mpv 的 `wid` 在 Wayland 上也不受支持。必须在 GTK 初始化之前设(`set_var` 多线程下是 UB) | `apps/desktop/src/lib.rs:5662-5673, 5695-5697`;拿不到 Xlib 句柄时如实报错 `lib.rs:313-331` |
| `$ORIGIN` rpath | 让 exe 同级目录优先于系统库,绿色包能自带一份 libmpv.so.2 | `apps/desktop/build.rs:12-18` |

### 6.6 Android Surface 【**保留**,但形态要改】

这一段是**真正会活到 Go 版**的部分:

| 点 | 内容 | 行号 |
|---|---|---|
| `create()` 只是**取**,不建 | Surface 由系统在 `surfaceCreated` 给,时机不由我们定。没准备好返回 0 → `Player::new` 报「视频渲染面未就绪」,正是要的行为 | `lib.rs:837-845, 876-878, 1197-1205` |
| jobject **必须是全局引用** | 局部引用出了那次 native 调用就失效,mpv 之后拿它去 `ANativeWindow_fromSurface` 会**崩在一个和这里毫无关系的地方** | `lib.rs:843-846`;JNI 侧 `apps/android/src/lib.rs:5369-5415` |
| 旧全局引用要显式释放 | 用 `GlobalRef`(Drop 自动 `DeleteGlobalRef`),否则每次转屏/回前台漏一个 Surface。jni 0.21 **没有** `delete_global_ref` 方法(手工管裸指针那版交叉编译时才报出来) | `apps/android/src/lib.rs:5384-5388, 5411-5414` |
| **`av_jni_set_java_vm` 必须自己调** | 实测 `llvm-nm -D`(media-kit/libmpv-android-video-build v1.1.11 full-arm64-v8a):**没有导出 `JNI_OnLoad`**,只导出 `av_jni_set_java_vm`。不调的表现是最难查的那种:库加载成功、`mpv_create` 成功、`loadfile` 也成功,然后 mediacodec 解码器和 `gpu-context=android` 拿不到 JNI 环境 → **黑屏,不报错**。换 libmpv 版本要重新 `llvm-nm -D` 确认 | `lib.rs:927-962`;调用点 `apps/android/src/lib.rs:5402-5409`;Kotlin 侧说明 `MainActivity.kt:51-73` |
| `std::mem::forget(lib)` | drop = dlclose,会把刚登记好的东西一起卸掉 | `lib.rs:959-961` |
| `set_size` 必须由壳报 | 见 §1 的 `android-surface-size` | `lib.rs:897-921`;Kotlin `MainActivity.kt:185-194` |
| 只在起播时读一次尺寸 | 标了 `ponytail:` —— SurfaceView 开机就建好、起播远在其后,拿到的已是定稿尺寸。播放**中途**改面(分屏/画中画)才需要推给活着的 mpv,TV 上没有这些入口 | `lib.rs:908-910` |
| **不要 `setZOrderOnTop(true)`** | 默认模式下 SurfaceView 在自己那块区域给窗口「打个洞」,视频从窗口**下面**透上来,WebView 照常画在上面。设成 OnTop 会盖住 WebView:有画面但所有 UI 都点不到也看不见 | `MainActivity.kt:179-182` |
| `sync` / `set_visible` / `pin_below` 全是 no-op | SurfaceView 铺满 Activity,层级归 Android View 树管 | `lib.rs:880-888` |

### 6.7 Go + 原生 UI 下的删除清单

**整段删掉(约 700 行,`TODO.md:250-252` 已列):**
- `mod overlay` 的 Windows 分支全部(`lib.rs:299-650`):`create` / `sync` / `pin_below` / `host_proc` / `align_to_host` / `align_target` / `apply_visibility` / `restack` / `set_visible` / `is_host`;
- `mod overlay` 的 Linux 分支全部(`lib.rs:652-835`);
- `OVERLAY_TOP_INSET` / `set_overlay_top_inset` / `apply_top_inset` / `overlay_top_inset`(`lib.rs:988-1024`);
- 对外的 `sync_overlay` / `pin_overlay_below` / `set_overlay_visible` / `is_overlay_host`(`lib.rs:1026-1052`);
- 桌面壳的 `video_top_inset` / `sync_video` / `install_video_host_events` / `attach_video_host` / `show_video` / `hwnd_of`(`apps/desktop/src/lib.rs:194-331`);
- 桌面壳的独立播放窗那一整套(`apps/desktop/src/lib.rs:4571-4706`),含 Alt+F4 拦截、`QUIT_AFTER_PLAYER` 接力棒;
- `Player::video_hwnd` 字段(`lib.rs:1097`);
- 契约测试 `every_play_command_reveals_the_video_window`(`apps/desktop/src/lib.rs:6683-6738`)—— 它守的问题在新架构里不存在。

**保留:**
- Android Surface 的取/交/全局引用/`av_jni_set_java_vm`/`android-surface-size`(§6.6);
- 「解绑必须同步阻塞」这条**当前还没实现**的约束(见 §13)。

**替换:**
- Windows/Linux 改走 SPEC §7.3 的路径 B(mpv render API + 纹理互操作),四个 overlay 变体归一成
  `lp_set_surface(kind, handle, w, h)` 一个入口(`SPEC.md:507-546`)。

---

## 7. 着色器与画质

### 7.1 落盘与路径

`.glsl` 用 `include_str!` **编进二进制**(`apps/desktop/src/shaders.rs:29-31`):
绿色版是 `app.exe + libmpv-2.dll` 平铺,没有 resources 目录可用;首次用时落盘到 cache
(`apps/desktop/src/lib.rs:2921-2923`,`linplayer_core::paths::cache_dir("shaders")`)。
mpv 的 `glsl-shaders` **只收文件路径**,所以必须落盘。

落盘用「长度一致即认为是当前版本」判新旧,避免每次起播重写(`shaders.rs:373-388`)。

安卓那份 `shaders.rs` 是**逐字复制**,但 `include_str!` 指向 `../../desktop/shaders/` ——
shader 有几百 KB,仓库里放两份等于以后改一份忘一份(`apps/android/src/shaders.rs:1-4`)。

### 7.2 `gpu-shader-cache-dir` 为什么必须显式给

见 §1 表格那行。补充**回读校验**的理由(`lib.rs:1336-1339`):
`set()` 吞掉返回码,选项名写错/该版 mpv 不认是**静默无效**,而「起播慢」这种症状根本看不出是它。
所以 `Player::new` 末尾用 `mpv_get_property_string("gpu-shader-cache-dir")` 回读比对,不一致就告警(`lib.rs:1340-1357`)。

缓存目录放**数据根的 cache/** 而不是 `%TEMP%`(`lib.rs:248-252`):它就是要跨次启动活着才有意义,被临时目录清理掉等于没缓存;能重建,故归 cache。

### 7.3 ★ 锐化/去噪 vs 放大 —— 是两件事,别糅成一坨

**核心事实**(`shaders.rs:7-17`):Anime4K 每个 CNN pass 都带门槛
```
//!WHEN OUTPUT.w MAIN.w / 1.200 > OUTPUT.h MAIN.h / 1.200 > *
```
**输出没比源大 1.2 倍就一帧都不跑。** 于是窗口里播 1080p(输出 1770×1080 < 源 1920×1080)点什么档位都毫无变化,
而旧 UI 还在报「超分已生效 · 挂载 6 个 shader」——**那就是在撒谎,正是本项目最贵的那类 bug**(`apps/desktop/src/lib.rs:2903-2906`)。

对照 hooke007/mpv_PlayKit 的正确做法:
```
AMD_CAS_luma_RT   //!WHEN STR            ← 参数门槛,窗口模式照跑
AMD_FSR1_RCAS_RT  //!WHEN SHARP 4.0 <    ← 参数门槛,窗口模式照跑
Denoise_Bilateral //!WHEN 无             ← 永远跑
AMD_FSR1_EASU     //!WHEN OUTPUT.w ...   ← 放大器,才看尺寸
```

`is_upscale_gated()` **从 shader 源里现算**这件事(看 `//!WHEN` 里有没有拿 `OUTPUT.` 比尺寸),
**不手工维护名单** —— 换 shader 文件时结论自动跟着变(`shaders.rs:139-145`)。

`works_at_any_size()` 的语义是「**有效果**」不是「全部 pass 都跑」:
FSR 档在窗口下 EASU 会被跳过、RCAS 锐化照跑 → 判 true,即「退化成只锐化」(`shaders.rs:147-160`)。

`will_run(level, video, output)` 三态返回(`shaders.rs:162-178`):`None` = 尺寸未知/off 不下结论;
判据是 `ow/vw > 1.2 && oh/vh > 1.2`(`>` 不是 `>=`,测试 `shaders.rs:723-724`)。

`WHEN_RATIO = 1.2` 有测试**从嵌入的 shader 源里抠出真实阈值比对**(`shaders.rs:130-133, 735-759`)。

### 7.4 档位映射(28 档 / 4 家族)

`preset(level) -> Preset { files: &[&str], opts: &str }`(`shaders.rs:180-320`),
UI 清单 `levels() -> (id, 显示名, 家族)`(`shaders.rs:322-365`)。

| 家族 | 档位 id | 特征 |
|---|---|---|
| **Anime4K** | `ak_denoise_l/h`(双边去噪 Mean/Mode)、`ak_sharp`、`ak_up_m`、`ak_up_dn`、`ak_up_vl`、`ak_up_artcnn`、`ak_up_artcnn_sh` | 去噪档无 `//!PARAM`,强度靠换算法(Mean 温和 / Mode 更狠);CNN 权重写死在模型里,强度不可调,只能换模型大小 |
| **FSR** | `fsr_sharp_l/m/h`、`fsr_up`、`fsr_up_h`、`fsr_up_dn` | CAS 挂 LUMA、RCAS 挂 MAIN,不同阶段可叠 |
| **NVIDIA(NIS)** | `nv_sharp_l/m/h`、`nv_up`、`nv_up_h`、`nv_up_dn` | NVSharpen 纯锐化(参数门槛),NVScaler 放大(尺寸门槛) |
| **Sharpen(锐化专精)** | `sh_ada_l/m/h`、`sh_fine_m/h`、`sh_warp`、`sh_bcas` | **整族窗口模式就生效**,全 luma-only(不碰色度,便宜) |

**强度是档位设计的一部分,不是用户的活**(用户 2026-07-15 原话:「强度不是靠用户调的 是让你设计挡位的…用户又不会调」)——
参数在 `preset()` 里调死,UI 上没有任何数字可拧(`shaders.rs:194-197`)。
`//!PARAM` 的自带默认都很保守(CAS STR=0.5 只开一半 / Adaptive STR=1.0 / FineSharp SSTR=0.5 / aWarpSharp2 STR=4.0),
**那正是「开到最大档也只有一点点变清晰」的病根**(`shaders.rs:56-59, 199-203`)。

参数方向不统一,别拍脑袋改(`shaders.rs:199-203`):
- `STR`(CAS,0~1,**越大越锐**):`peak = -1.0/mix(8.0, 5.0, STR)`;**0 = 不跑**(`//!WHEN STR`)。
- `SHARP`(RCAS,0~4,**越小越锐**):`sharp = exp2(-SHARP)`;**4.0 = 不跑**(`//!WHEN SHARP 4.0 <`)。

**Restore CNN 永远不要**:用户 2026-07-11(`a5e21885`)明确否掉(动态画面边缘振铃/拖影,且最吃显卡),
2026-07-15 又问了一遍。有测试钉住(`shaders.rs:24-27, 681-694`)。

### 7.5 `glsl-shader-opts` 是**全局**的一张表

【mpv 事实,Go 版必须继承】(`shaders.rs:533-538`):
它不区分参数是给哪个 shader 的。把两个都叫 `STR` 的锐化器叠进同一档,它们会共用同一个值,
而量纲根本不同(Adaptive 0~2 / aWarpSharp2 -20~20 / BCAS 0~1)——
结果是其中一个被喂了荒谬的强度,**mpv 不报错**,只是画面不对劲。有测试钉住(`shaders.rs:539-555`)。

同理:opts 里写了本档 shader 里不存在的 `//!PARAM`,**mpv 会拒掉整条 opts**(`shaders.rs:185-188, 434-455`)。
所以 `set_shader_opts` 写完必须回读(`lib.rs:1918-1924`),宿主侧不一致就告警(`apps/desktop/src/lib.rs:2930-2932`)。

### 7.6 双重回读

`set_shader_level` 的完整流程(`apps/desktop/src/lib.rs:2919-2955`,安卓同构 `apps/android/src/lib.rs:3342-3378`):
1. `set_shader_opts(opts)` → 回读校验(不一致告警,不阻断);
2. `set_shaders(paths)` → `shader_count()` 回读(`count==0` 而 `paths` 非空 → **返回 Err**「超分未生效」);
3. `will_run(level, video_size(), output_size())` → 尺寸校验,`false` 时给一段**带真实数字**的人话解释直接显示给用户。

> `shader_count()` 只说明 mpv **收下了**路径,**不代表 shader 会跑**(`lib.rs:1940-1947`)。这两件事必须分开报。

---

## 8. 网络流

### 8.1 属性粘连(★ 最贵的一条)

【mpv 事实】`user-agent` / `http-header-fields` 是**实例级属性,设了就一直在**(`lib.rs:1541-1546`)。

原先只有 `load_with_headers` 会设、谁都不复位,于是放过一次网盘源之后再放 Emby:
1. 还顶着网盘的 UA,并把网盘的 `Authorization`/`Cookie` **发给 Emby 服务器**;
2. Emby 直连取流从来没带过 `LinPlayer/{版本}`,用的是 mpv 自带默认 UA。

**两个都是静默的** —— 画面照放,只有服务端日志里看得出来。

解法:`load_inner` **每次 loadfile 都无条件重设**,不是「有才设」(`lib.rs:1581-1586`)。
源没指定 UA 就用访问 Emby 的那个(`linplayer_core::http::user_agent()` = `LinPlayer/{版本}`,`crates/core/src/http.rs:18-20`)。

UA 三分口径(`crates/core/src/http.rs:18-36`):
| 用途 | UA |
|---|---|
| Emby / mpv 取流 | `LinPlayer/{版本}` |
| 预取代理拉上游 | `LinPlayerPreload/{版本}` |
| 第三方公开 API(Bangumi/Trakt/弹弹/翻译) | `LinPlayer/{版本} (+https://github.com/...)` —— **reqwest 不设 = 一个 UA 头都不发**,`api.bgm.tv` 实测带 UA→200、不带→403(Cloudflare) |

`http-header-fields` 用逗号分隔 `"Key: Value"`;**含逗号的值会串味**,已标 `ponytail:` 记为当前源不涉及的已知限制(`lib.rs:1525`)。

### 8.2 `stream-lavf-o` 与 `multiple_requests=1`

【mpv/ffmpeg 事实,**负向知识**】当前 Rust 版**不设 `stream-lavf-o`**(全仓 grep 零命中)。

历史结论(`4d5837cd`,Kotlin 侧注释原文):
> ⚠️ **绝不加 `multiple_requests=1`**(大电影卡顿真凶,桌面早已删除,Android 之前漏同步):
> 本意是 keep-alive 复用连接,但对 302 跳转的网盘流(strm→115 CDN)会诱发大量分段 Range 请求,
> 每段重走 302 + 重连 + TLS 握手。**curl 实测:连续流 28MB/s,分段 1.8MB/s(×15 慢);
> 桌面 ffprobe 实测同一 MKV 默认 1.6s、加该参数 3m35s(×130)。**

同批被删掉的还有 reconnect 组(见 §1.2)——**这一组是有用的,属于误伤**:
`reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=30`。
注意原注释明确:**只开 `reconnect_on_network_error`,不开 `http_error`** ——
网盘 302 过期的 4xx/5xx 要上抛交给上层重解析重签,不能让 ffmpeg 死磕过期链把错误吞掉。

### 8.3 http proxy

`set_http_proxy(Option<&str>)`(`lib.rs:1513-1516`),空串 = 直连。**SOCKS 不被 mpv 支持**,只传 `http://`
(核层 `crates/core/src/config.rs:438` 的 `mpv_http_proxy()` 负责过滤)。

★ **播放地址是本机回环时不给 mpv 挂代理**(`apps/desktop/src/lib.rs:1745-1755`):
mpv 会把 `127.0.0.1` 的请求递给用户代理,代理再去连**它自己那头**的 `127.0.0.1`,我们的本地服务根本不在那儿。
真正出网的那一跳由 CF 反代/预取代理自己完成,代理设置在那一层已经生效过了。

### 8.4 302 直链失效 → 重签

`error_eof` 由事件线程在 `END_FILE reason=ERROR` 时置位(`lib.rs:1428`),
`take_error_eof()` 取走即清(`lib.rs:1458-1460`)。
前端播放中每轮轮询调 `source_watchdog`(`apps/desktop/src/lib.rs:3845-3897`):
- 只对**源播放**生效(Emby 直链稳定,不重签);
- 连续 3 次仍失败就放弃,以免死循环(`lib.rs:3864-3869`);
- 重签走 `load_with_headers(url, pos, ...)` 从原位置续播;
- **这条路是 `show_video` 的唯一豁免**(播放中换直链,窗早就开着,`apps/desktop/src/lib.rs:6705-6707`)。

Emby 侧的重签回调必须带 `media_source_id`,不带的话 URL 过期重签会悄悄退回默认版本 ——
**用户选的 4K 播到一半变 1080p,且无任何提示**(`apps/desktop/src/lib.rs:4709-4712`)。

### 8.5 给 mpv 吃的 URL,token 只能在路径里

这是 `SPEC.md:491-503` 已冻结的决策,根因正是 §8.1 的属性粘连:
给 mpv 加请求头只能改 `http-header-fields`,而那是全局粘连属性。
代价:URL 里的 token 会进 mpv 日志 → token 每次启动重新随机生成,不落盘。

---

## 9. 平台差异表(4 个 cfg 变体)

### 9.1 `mod ffi` 两个变体

| | Windows(`lib.rs:65-84`) | 非 Windows(`lib.rs:86-216`) |
|---|---|---|
| 绑定方式 | **链接期**。`#[link(name="mpv")]`,仓库自带 `libmpv/mpv.lib`,运行时找同目录 `libmpv-2.dll` | **运行时 `dlopen`,编译期不绑任何 soname** |
| 为什么 | 版本由我们自己说了算 | 发行版之间 soname 分裂:Ubuntu 22.04 → `libmpv.so.1`(mpv 0.34);Ubuntu 24.04/Fedora/Arch → `libmpv.so.2`(0.36+)。**链接期绑哪个都是错的**:绑 .so.1 新系统起不来;绑 .so.2 要换更新的构建机,glibc 抬到 2.39 又砍掉一批老系统。**两条路都堵死** |
| 候选名顺序 | —— | `["libmpv.so.2", "libmpv.so.1", "libmpv.so"]`,**新的在前**(同时装了两代库的系统要用新的)。不写绝对路径,交给 ld.so 按标准规则搜索 —— 含 build.rs 写进 ELF 的 `$ORIGIN`(`lib.rs:119-123`) |
| 关键约束 | `link-search` **必须由 `crates/mpv` 自己发**(`#[link]` 在这个 crate 里)。留在 apps/desktop 的话,任何不依赖它的包(如 apps/android)在 Windows 上一链接就 LNK1181(`crates/mpv/build.rs:11-16`) | **`Library` 必须留在结构里**:一 drop 就 `dlclose`,所有函数指针**全部悬垂**(`lib.rs:104`)。少一个符号就整体放弃 —— **半套 API 比没有更危险**(`lib.rs:131-132`) |
| 失败降级 | —— | `mpv_create` 返回 null → `Player::new` 当场报错,不会带着半死不活的状态往下走;其余函数返 `MPV_ERROR_GENERIC(-20)`(`lib.rs:162-215`) |
| build.rs | 发 `link-search` + `link-lib`,并把 DLL 拷到 `target/<profile>/`(**这是 DLL 进发行包的唯一机制**)。**别在 tauri.conf.json 加 `resources`**:`bundle.active=false` 不走 bundler,但 `tauri_build` **仍会校验路径存在**,在没有该 DLL 的 Linux 构建机上直接把 build.rs 干失败 | **故意什么都不发**:发了 link-lib 就把 libmpv 变成链接期硬依赖,ELF 里留死 soname,dlopen 那套「一个包适配所有发行版」当场归零。安卓同理(`.so` 是 CI 现拉进 jniLibs 的,链接期根本没有它)(`crates/mpv/build.rs:3-16, 24-41`) |

Android 走的是**非 Windows 那条**,与 Linux 一字不差 —— 这正是安卓能白捡这份实现的原因(`crates/mpv/Cargo.toml:17-20`)。

### 9.2 `mod overlay` 四个变体

| 函数 | Windows `lib.rs:299-650` | Linux `lib.rs:652-835` | Android `lib.rs:847-889` | 兜底桩 `lib.rs:970-981` |
|---|---|---|---|---|
| `create()` | ✅ 真实现:`CreateWindowExW`,同步建窗 | ✅ 真实现:`XCreateWindow` override-redirect | ⚠️ **只是取**壳存进来的 Surface;没有就返 0 | ❌ 恒返 0 |
| `sync(v,t,x,y,w,h)` | ✅ 几何 + 显隐 + z 序 | ✅ `XMoveResizeWindow` + `XConfigureWindow(Below)` | ❌ **no-op**(SurfaceView 铺满 Activity) | ❌ no-op |
| `set_visible(v,on)` | ✅ `WANT_VISIBLE` && 主窗在屏 | ✅ `XMapWindow`/`XUnmapWindow` | ❌ **no-op**(层级归 View 树管) | ❌ no-op |
| `pin_below(v,t)` | ✅ wndproc 子类化,可改挂 | ❌ **no-op**(已知能力差,`lib.rs:788-793`) | ❌ no-op | ❌ no-op |
| `is_host(hwnd)` | ✅ 真判断(`HOST_HWND==0 \|\| ==hwnd`) | ❌ 恒 `true`(返 false 会把对齐整个关掉) | ❌ 恒 `true`(只有一个 Activity) | ❌ 恒 `true` |
| `set_surface` / `set_size` / `size_str` | — | — | ✅ **仅 Android 有** | — |

### 9.3 兜底桩是个**会静默烂掉的洞**

`lib.rs:964-969` 明说:这个桩**任何 CI 目标都编不到**(三个 cfg 把它全挡掉),
2026-08-02 发现它已经缺了三个函数。**加新函数时必须四个变体一起加。**
配套的 30 秒自检脚本见 `scripts/check-android.sh`(记忆条目 `[[desktop-check-misses-android]]`,连红三个提交的流程漏洞)。

### 9.4 两个宿主壳的差异

| 维度 | 桌面 `apps/desktop` | 安卓 `apps/android` |
|---|---|---|
| Player 生命周期 | **启动时建一次**(`setup` 里,`lib.rs:5831-5837`),失败只记日志继续跑 | **懒创建**(`ensure_player`,`lib.rs:150-160`):Surface 在 App 启动那刻还不存在,启动时建必然拿到 wid=0。**失败不缓存**,下次重试 |
| Player 销毁 | 进程退出时 | **`stop_playback` 里显式 `take()` 掉**(`lib.rs:445-447`):留着 = 一直占着 Surface 和 MediaCodec 实例,下次起播要么黑屏要么拿不到解码器(**硬件解码器数量有限**) |
| State 归属 | `AppState.player: Mutex<Option<Player>>`(`lib.rs:5771`) | **独立的 `PlayerState`**(生命周期跟 Surface 走,不跟 AppState 一起建,`lib.rs:4734-4735`) |
| `apply_playback_defaults` | ✅ 三条起播路径都调 | ❌ **完全没有**(见 §5.3 的告警) |
| `show_video` | ✅ 起播开 / 停播关 | ❌ 不需要(SurfaceView 一直在) |
| 日志出口 | `mpv::set_logger(poclog)` → `logs/app.log`(`lib.rs:5679`) | `linplayer_mpv::set_logger(\|m\| log::info!("[mpv] {m}"))` → logcat(`lib.rs:4738`) |
| 独立播放窗 | ✅ 有(`PLAYER_LABEL="player"`,同包 `#player` 分流) | ❌ 无 |
| `mpv.conf` 编辑命令 | ✅ `get_mpv_conf` / `set_mpv_conf`(`lib.rs:4966-4975`) | ❌ 未注册 |

> `set_logger` 是 `OnceLock<fn(&str)>`(`lib.rs:235-246`),**不插也能跑(默认丢弃)**——
> 但那些「静默失效」告警就看不见了,而本文件反复强调那类问题只能靠回读日志发现。**两个壳都记得插。**

---

## 10. 踩坑清单

> 格式:症状 / 真因 / 现在怎么处理 / Go 侧怎么落 / 出处

### A. 外挂字幕「挂了等于没挂」
- **症状**:详情页看得见字幕,播放页字幕列表是空的;日志里还照打「挂载外挂字幕 N 条」。
- **真因**:`loadfile` 异步,只排队;紧跟的 `sub-add` 必拿 `-12`,而旧代码 `let _ = self.cmd(...)` 把错误吞得一干二净。
- **现在**:`SubState` 单锁排队 + 事件线程在 `FILE_LOADED` 挂;`sub-add` 失败必须 `poclog`。
- **Go 侧**:同一设计。**`sub-add` 的返回值绝不许丢**;挂载 goroutine 必须被关闭序列 join 住(不能是裸 `go`)。
- `crates/mpv/src/lib.rs:33-37, 1066-1081, 1404-1422, 1596-1616`;回归测试 `lib.rs:2060-2105`

### B. 没加载完就点进度条 → 「调进度画面不变」
- **症状**:起播途中拖进度条,条压着用户拖的位置 2.5s 然后弹回续播点,画面从头到尾没动过。
- **真因**:`FILE_LOADED` 之前 `seek` 拿命令错误,而闩在发命令**之前**就设上了。
- **现在**:`queue_seek` 排队,`FILE_LOADED` 补发并**重置闩计时**;只留最后一条。
- **Go 侧**:同 A,共用同一把锁。
- `lib.rs:1074-1092, 1389-1403, 1634-1638`;测试 `lib.rs:2222-2244`

### C. 播完不同步 Trakt/Bangumi
- **症状**:看完走人,什么都没同步。
- **真因**:两层。① 只 latch 了 `END_FILE reason=ERROR`,没 latch `EOF`;② 补了也没用 —— `keep-open=yes` 下 `END_FILE` **压根不发**。
- **现在**:读 `eof-reached` 属性,与事件标志**取或**;`take_eof()` 取一次即清;前端再上一道 `ended` 锁。
- **Go 侧**:判播完**必须**以 `eof-reached` 为主。别写只监听事件的死分支。
- `lib.rs:30-32, 1424-1433, 1692-1698, 1453-1457`;前端 `ui/desktop/App.tsx:1054-1063`

### D. 「服务器上一拖就乱 / 本地跟手」
- **症状**:网络流上拖完进度条自己跳回去,条和画面对不上;本地文件完全正常。
- **真因**:seek 闩拿**粘性值**和目标比,而粘性值在 seek 期间恰好等于目标 → 一比就相等 → 第一次 `time-pos` 读不到时闩就自解除。
- **现在**:`apply_seek_latch` 只吃**这一拍真读到的** `time-pos`(`try_f64`,读不到 = `None` = 继续压制);三条松闩路。
- **Go 侧**:把这个纯函数**原样搬过去**并带上全部 6 条单测 —— 它是唯一会算错的地方,且能脱离 libmpv 测。
- `lib.rs:1152-1187, 1651-1671`;测试 `lib.rs:2107-2220`

### E. 进度条「抽回 0」/ 缓冲条整条闪没
- **症状**:进度条每隔几拍抽回开头再弹回来;缓冲条突然消失。
- **真因**:`get_f64` 不看 `mpv_get_property` 返回值,失败时不写 out,把栈上 `0.0` 当成「位置=0」交出去。
- **现在**:`try_f64` 检查 rc **和 `is_finite`**;`sticky_f64` 读不到就沿用上次。
- **Go 侧**:cgo 里同样要判返回码,并且**NaN 要当读不到**(mpv 换片瞬间会给 NaN,直接吐 JSON 会变 `null`)。
- `lib.rs:1483-1511`;字段说明 `lib.rs:1103-1113`

### F. 「只能调次字幕的字体大小,主字幕的调不动」
- **症状**:同一个 `sub-font-size`,对主字幕无效、对次字幕有效。
- **真因**(2026-07-16 ctypes 直问 libmpv v0.41.0-744 实测):`sub-ass-override` 默认 = `scale`,
  这个模式下 ASS 字幕**只认 `sub-scale`,完全忽略 `sub-font-size`**;而 `secondary-sub-ass-override` 默认 = `strip`,
  ASS 被剥成纯文本,于是它**反过来只认 `sub-font-size`**。内封字幕(尤其番剧)绝大多数是 ASS。
- **现在**:大小统一走 `sub-scale`;`set_sub_scale` clamp `0.2..=4.0`。
- **Go 侧**:**别再拿 `sub-font-size` 当大小旋钮。**
- `lib.rs:1848-1860`;前端默认值对齐 `ui/desktop/App.tsx:334-342`

### F2. 次字幕没有独立字号/字体属性
- **真因**:同一次 ctypes 实测 `property-list`,`secondary-*` 名下只有
  `sid / ass-override / delay / pos / visibility / text / start / end / lines`,
  **不存在 `secondary-sub-font-size` / `-font` / `-color`**(set 回 `-8 property not found`)。
- **现在**:UI 如实标成「主次共用」,不造假的次字幕字号 stepper。
- `apps/desktop/src/lib.rs:2331-2338`

### G. 「第二个视频先露出上一片的画面」
- **症状**:换片时缓冲期间的背景不是黑色,是上一部片的画面。
- **真因**:两条,**都要修**。① `keep-open=yes` 让上一片停在最后一帧不卸载;
  ② 前端 `setReady(false)` 排在两个 `await` 之后,而 `play()` 慢服上要好几秒,那期间上一片的轮询每 250ms 把 ready 拍回 true。
- **现在**:核层 `load_inner` 开头发 `stop`(mpv 自己画黑底);前端复位提到第一行 + `starting` 旗子让轮询闭嘴。
- **Go 侧**:核层那道保留;UI 那道写进 `player.status` 的规格(`SPEC.md:592-594` 已有)。
- `lib.rs:1554-1561`;`ui/desktop/App.tsx:685-697, 278-281, 1035`

### H. 「跳到没缓存的地方就卡死」
- **症状**:seek 到未缓冲位置,画面和进度条都不动,永远。
- **真因**:**服务器**宣称 `Accept-Ranges: bytes` 却对任何 `Range:` 回 `200 OK` + 完整 Content-Length,
  ffmpeg 只能顺读丢弃到目标字节(跳 9 分钟 = 370MB)。mpv 日志:`https: Unexpected offset: expected N, got 0` + `Seek failed`。
- **现在**:改不了服务器,但**不能让用户干等** —— `seek_stalled`(`seeking=yes` 且已过 12s)如实上报,前端说人话。
- **Go 侧**:保留这条上报;门槛必须**明显大于**近距离 seek 耗时(同服跳 3 秒实测要 7s)。
- `lib.rs:1135-1150, 1651-1671`;测试 `lib.rs:2197-2220`;前端 `ui/desktop/App.tsx:1037-1045`

### I. 「关掉程序还有残留进程」/ 孤儿播放器
- **症状**:关闭 App 后任务管理器里还有进程;或有声音没窗口。
- **真因**:【本架构产物】播放窗是「藏起来不销毁」的,主窗销毁后进程里还剩一个窗口,tao 永远等不到「最后一个窗口关闭」。
- **现在**:主窗 `CloseRequested` 时,不在播就 `app.exit(0)`;在播则拦下来广播正规退出流程(落库 → 藏窗 → 退),**3 秒兜底硬退**。
  Alt+F4 关播放窗也必须 `prevent_close`,否则 mpv 还在放而 `closePlayer` 再也跑不了。
- **Go 侧**:**整段删掉**(没有 WebView 窗口生命周期问题)。但「退出前必须让进度落库」的规格要保留。
- `apps/desktop/src/lib.rs:5857-5892, 4663-4676, 4701-4704`

### J. 「5060 超分非常卡」—— 见 §6.8 双显卡(下节单列)

### K. ⚠️ CVE-2026-8461(magicyuv)的防护在重写中丢失
- **症状**:无(这是个安全洞,不是功能 bug)。
- **真因**:libavcodec 的 magicyuv 解码器存在堆越界写(攻击者构造的 `slice_height` 多写一行 chroma 越界),
  恶意 AVI/MKV/MOV 即可触发崩溃乃至 RCE。修复随 FFmpeg 8.1.2(2026-06-17)发布,
  但预编译 libmpv(Windows shinchiro 完整版 / Linux 系统库)仍可能内置旧版 ffmpeg。
  MagicYUV 是冷门无损录屏编码,正常影视/番剧绝不会用到。
- **现在**:**没有任何防护。** 全仓 grep `magicyuv` 零命中(源码),仅 `docs/go-migration/TODO.md:246` 挂着待办。
  该防护由 `fb5d3a5d` 引入 Dart 侧 `vd=-magicyuv`,随 `0dd295fe`(删 Flutter)一起消失。
- **Go 侧**:`mpv_set_option_string("vd", "-magicyuv")`。前缀 `-` 只黑名单这一个,其余编码仍走自动选择,
  无需等各平台 libmpv 重新打包即可消除攻击面。
- 证据:`git show fb5d3a5d`;当前缺失见 `docs/go-migration/TODO.md:246`

### L. 弹幕的 ASS 路径**已经被删掉了**(文档与代码不一致)
- **事实**:`SPEC.md:585-586` 写「现有实现主路是生成 ASS 交 mpv 的 `secondary-sid`,另有网页层作为 fallback」,
  并据此决定「新架构删掉 fallback」。**但代码里正好相反** ——
  `ui/desktop/App.tsx:141-149` 明确:「弹幕渲染:**只有网页 Canvas 层这一种**,不给用户选(用户 2026-07-27)」,
  理由是次字幕位只有一个,开了弹幕就没法开双语字幕;
  而当初改用 mpv 是为了治「倍速下弹幕一顿一顿」,**那个 bug 的真因是网页层墙钟插值里漏了倍速因子,已经修好**。
  核层 `crates/core/src/danmaku/local.rs` 只**解析** ASS(当导入格式),**不生成**。
- **Go 侧**:`SPEC.md §7.5` 的决策(只走 ASS)在**方向上是对的**(三端原生 UI 没有 WebView 覆盖在视频上),
  但它的前提描述是错的 —— **ASS 生成器是要新写的,不是「保留主路删掉 fallback」**。
  必须带上:插值带倍速、颜色按 BGR、走 `secondary-sid`(`TODO.md:265-267` 已列)。

### M. Xlib 默认错误处理器 abort 进程
- **症状**:播放中无故崩溃(Linux)。
- **真因**:Xlib 默认错误处理器**直接 abort**,而我们干的正是最容易撞 BadWindow/BadMatch 的活,且错误是异步回来的。
- **现在**:`XSetErrorHandler(ignore_x_error)`。
- **Go 侧**:【本架构产物】如果 Windows/Linux 走 render API 就不再直接碰 Xlib,整条消失。
- `lib.rs:666-680`

### N. wndproc 钩子重入爆栈 —— 见 §6.2。【本架构产物,整段删除】

### O. 安卓「一切成功但黑屏」
- **真因**:这个 libmpv 二进制**没有导出 `JNI_OnLoad`**,不调 `av_jni_set_java_vm` 就没人登记 JavaVM。
- **现在**:在 `nativeSetSurface` 里顺手登记(唯一天然带 `JNIEnv` 又必定早于起播的入口)。
- **Go 侧**:保留。换 libmpv 版本时**重新 `llvm-nm -D` 确认再改,别照抄结论**。
- `lib.rs:927-962`;`apps/android/src/lib.rs:5402-5409`

### P. 安卓「播放页四周一圈没画到」
- **真因**:mpv 的 android gpu-context 只在 reconfig 时取一次视口;安卓没有 resize 事件通道。
- **现在**:三段链 `surfaceChanged → nativeSetSurfaceSize → android-surface-size`,有测试逐段钉住。
- **Go 侧**:保留,三段一个都不能少。
- `lib.rs:897-921`;`MainActivity.kt:185-194`;测试 `apps/android/src/lib.rs:5132-5166`

### Q. 安卓「有声音没画面」的四层透出链
- **真因**:视频垫在 WebView 底下,**任何一层不透明**都是黑屏且完全不报错。
  2026-07-21 栽在第 3 层(Activity `windowBackground` 跟着 DayNight 走);
  2026-08-02 栽在前端 `.pg` 容器自带 `background: var(--bg)`。
  **`-night` 限定符优先级排在 `-vXX` 前面**,所以「深色 + Android 12 以上」命中的是 `values-night-v31`。
- **Go 侧**:【本架构产物】原生 Compose UI 后 WebView 那几层消失,但 **Activity 主题 `windowBackground` 必须透明**这条保留,
  且四份主题文件(`values` / `values-night` / `values-v31` / `values-night-v31`)一份都不能漏。
- 测试 `apps/android/src/lib.rs:5015-5083`

### R. 「超分已生效 · 挂载 6 个 shader」但画面一点没变
- **真因**:Anime4K 的 `//!WHEN OUTPUT.w MAIN.w / 1.200 >` 门槛;窗口 1770×1080 播 1920×1080 时六个 pass 全被跳过。
- **现在**:`will_run()` 三态 + 带真实数字的人话解释;`shader_count()` 的语义注释明写「收下 ≠ 会跑」。
- **Go 侧**:保留这套双重回读。**别把 `count>0` 当成「生效」。**
- `apps/desktop/src/shaders.rs:162-178`;`apps/desktop/src/lib.rs:2903-2954`

### S. `glsl-shader-opts` 参数名写错 → 整条被拒,强度静默回默认
- **现在**:`set_shader_opts` 写完回读;加了两条源码级测试(参数名必须属于本档 shader、值必须在 MIN/MAX 内且不等于「不跑」的端点)。
- **Go 侧**:保留回读 + 那几条测试(它们纯读 shader 源,不需要 libmpv)。
- `lib.rs:1918-1924`;`shaders.rs:434-455, 499-531`

### T. `demuxer-cache-time` 被当成「缓冲时长」
- **真因**:它是**已缓冲数据的最后一个时间戳(绝对)**,时长是 `demuxer-cache-duration`。
- **现在**:界面按 `buffered/duration` 画缓冲条,口径正是绝对位置。注释写死「别顺手改成 duration 版」。
- `lib.rs:1680-1683`

---

### §6.8 双显卡钉独显 —— 两半缺一不可

**症状**:用户真机(Intel UHD + RTX 5060 Laptop)mpv 日志里
`Device Name: Intel(R) UHD Graphics` —— Anime4K 整条 CNN 链跑在**核显**上,5060 全程没参与,于是「5060 超分非常卡」。

**真因**:D3D11 默认适配器在混合显卡本上是接显示器的那块(核显),而 `LinPlayer.exe` 是个新面孔,
NVIDIA 驱动的程序配置库里没有它 → 落到默认的「集显」档。

**解法两半**:

| 半 | 内容 | 出处 |
|---|---|---|
| ① 导出符号本体 | `#[cfg(windows)] #[used] #[no_mangle] pub static NvOptimusEnablement: u32 = 1;` 和 `AmdPowerXpressRequestHighPerformance: u32 = 1;` | `apps/desktop/src/lib.rs:14-27` |
| ② 链接器 `/EXPORT` | `cargo:rustc-link-arg-bins=/EXPORT:NvOptimusEnablement` + 同款 AMD 那条,仅 `CARGO_CFG_TARGET_ENV == "msvc"` | `apps/desktop/build.rs:20-35` |

**为什么缺一不可**:
- **缺 ②**:Rust exe **默认没有导出表**,只写 `#[no_mangle]` 驱动是看不见的。
- **缺 `#[used]`**:静态量没人读,**LTO 会把它整个丢掉**,导出表里就空了。
- **缺了会怎样**:**不报错,只是继续用核显。** 这就是它最危险的地方。

**为什么用导出符号而不是 `d3d11-adapter=NVIDIA`**:这两个是 NVIDIA Optimus / AMD Enduro **官方的**进程级切卡开关,
驱动在加载进程时读主 exe 的导出表;不认厂商名字,单显卡机器上天然是空操作。

**验证方式**:改动后**必须回读 mpv 日志的 `Device Name:` 确认**,别默认它生效了(`apps/desktop/build.rs:30-31`)。

**Go 侧**:Go 的 c-shared 库 **不是主 exe**,驱动读的是**主 exe 的导出表**。
所以这两个符号必须由**各端 UI 宿主的可执行文件**导出(Windows 上是 Avalonia 那个 exe),
**不能留在 Go 核心里**。这是本条在新架构下最容易漏的一点。
`gpu-context=d3d11` 那条(`lib.rs:1241-1243`)也要跟着保留,否则这条链走不通。

---

## 11. 日志

【mpv 事实】**`log-file` 一旦给了路径,mpv 就把日志目标钉在 `MSGL_DEBUG`,`msg-level=all=v` 管不住它**
(证据:日志里全是 `[d]` 行),而且会连带把 ffmpeg 的 `av_log_set_level` 一起拉到 debug →
解码器逐 packet 打日志并**同步写盘**。实测:一个文件都没加载、光 mpv 初始化就写了 **247 行 / 24KB**。
(`crates/mpv/src/lib.rs:1293-1300`)

**所以 mpv 日志默认关**,由环境变量 `LP_MPV_LOG` 门控:
```
set LP_MPV_LOG=1 && LinPlayer.exe
```
(`lib.rs:1301-1304`)。日志落 `linplayer_core::paths::logs_dir()/mpv.log`(`lib.rs:227-229`),
每次启动先删上一次的(`apps/desktop/src/lib.rs:5760-5761`)。

crate 自己的告警走 `set_logger` 注入的钩子(`lib.rs:231-246`),两个壳各接各的落点(§9.4)。
**不插也能跑但告警全丢** —— 而本文件反复强调那类问题只能靠回读日志发现。

`SPEC.md:861` 已把这条写进 Go 版规格。

---

## 12. 现有测试的价值

| 测试 | 位置 | 能脱离 libmpv 跑? | Go 侧怎么办 |
|---|---|---|---|
| `align_target_moves_only_when_it_must` | `crates/mpv/src/lib.rs:469-493` | ✅ 纯函数 | **删**(几何逻辑整段消失) |
| `top_inset_leaves_room_for_the_player_titlebar` | `lib.rs:499-512` | ✅ | **删** |
| `video_diag_tells_the_three_failures_apart` | `lib.rs:2029-2058` | ✅ 纯数据 | **搬**。它的注释里记了一次**假绿**:只把 `has_video_track` 翻 false 却留着 `vo=gpu/1920x1080`,守卫删掉照样过 |
| `external_subtitle_survives_async_loadfile` | `lib.rs:2073-2105` | ❌ `#[ignore]`,要真 libmpv + 桌面会话 | **搬**。用 `av://lavfi:testsrc` 造源,不依赖任何服务器;复刻真实时序(load 之后**立刻**挂,不等待) |
| `seek_latch_*` 五条 | `lib.rs:2122-2220` | ✅ 自由函数 `apply_seek_latch` / `seek_stalled` | **原样搬**。这是全层最有价值的一组 —— 它们钉住的 4 个 bug 都是「本地看不出、网络流才现形」 |
| `seek_before_file_loaded_is_queued_not_sent` | `lib.rs:2229-2244` | ✅ `SubState` 纯逻辑 | **搬** |
| shaders 的 10 条 | `apps/desktop/src/shaders.rs:407-792` | ✅ 全部纯读 shader 源 | **全搬**。含「参数名必须属于本档」「同档不许两个同名 `//!PARAM`」「梯度单调且高于自带默认」「`WHEN_RATIO` 必须等于源里真写的数」「不许用 Restore」 |
| `every_play_command_reveals_the_video_window` | `apps/desktop/src/lib.rs:6683-6738` | ✅ 源码级解析 | **删**(视频窗概念消失) |
| `video_transparency_chain_is_intact` | `apps/android/src/lib.rs:5025-5083` | ✅ 源码级 | **改**:WebView 那几层删掉,Activity 主题四份保留 |
| `surface_size_reaches_mpv` | `apps/android/src/lib.rs:5140-5166` | ✅ 源码级三段链 | **搬**(改成新的三段名字) |

**每条测试的注释都写了反向验证方法**(改哪一行会让它红)——
这是 `[[test-must-fail-first]]` 的落地形式,Go 版的测试也必须带这个。

⚠️ **两条 Windows 特有的解析陷阱**,搬测试时会原样撞上(`apps/desktop/src/lib.rs:6596-6603`):
源码级测试按 `\n}\n` 这类字面量解析自身源码,而 Windows 上 git 的 autocrlf 会把文件整份变成 CRLF
(实测 6789 个 CRLF、0 个裸 LF)→ 所有 needle 落空 → 要么 panic,**要么更糟:静默匹配到 0 处而断言恒真**。
表现是 Linux CI 全绿、Windows CI 恒红。必须先 `.replace("\r\n", "\n")`。

---

## 13. Go 侧移植要点

### 13.1 cgo 绑定的形状

**必须绑的 11 个符号**(现有 FFI 的全集,`lib.rs:72-83`):
`mpv_create` / `mpv_initialize` / `mpv_terminate_destroy` / `mpv_set_option_string` /
`mpv_set_property_string` / `mpv_get_property` / `mpv_get_property_string` / `mpv_free` /
`mpv_command` / `mpv_error_string` / `mpv_wait_event`。

**故意没绑的**:`mpv_request_log_messages`(为一条诊断不值当在两套 FFI 里各加一份声明,`lib.rs:1711-1712`)、
`mpv_observe_property`(整层是**轮询**模型,不是事件驱动)、
`mpv_render_context_*`(现在走 `wid`,Go 版走 render API 的话这一组是**新增**,SPIKE-1 的产出)。

**结构体只需两个**,且都可以按前缀截断(核对 `client.h:1580-1621, 1499-1530`):
```go
type mpvEvent struct { EventID C.int; Error C.int; ReplyUserdata C.uint64_t; Data unsafe.Pointer }
type mpvEventEndFile struct { Reason C.int; Error C.int } // 后面还有 playlist_entry_id 等,不读
```

**常量**(全部已用 `client.h` 核对):
`MPV_FORMAT_DOUBLE=5`(`client.h:702`)、`MPV_EVENT_END_FILE=7`(`:1277`)、`MPV_EVENT_FILE_LOADED=8`(`:1282`)、
`MPV_END_FILE_REASON_EOF=0`(`:1463`)、`MPV_END_FILE_REASON_ERROR=4`(`:1479`)、
`MPV_ERROR_PROPERTY_UNAVAILABLE=-10`(`:335`)、`MPV_ERROR_GENERIC=-20`(`:379`)。

**加载方式**:
- Windows:cgo `#cgo LDFLAGS: -lmpv` 链接期绑(仓库自带 `mpv.lib` + `libmpv-2.dll`);
- Linux / Android:**必须 `dlopen` + 三个候选名**(理由见 §9.1,soname 分裂)。
  cgo 下写法是 `#include <dlfcn.h>` + 手工取符号表,**不能用 `#cgo LDFLAGS: -lmpv`** ——
  那会往 ELF 里写死 DT_NEEDED,一个包适配所有发行版当场归零。
  句柄**必须全程持有**,别 `dlclose`。
- Android 还需 Java 侧 `System.loadLibrary("mpv")` 先加载(Rust/Go 侧 dlopen 拿到的是同一个句柄)。

### 13.2 必须串行化的

【mpv 事实】`mpv_command` 官方文档明示线程安全(`lib.rs:1056-1057`),
`mpv_set_property_string` / `mpv_get_property_string` 同理。**但本层的状态不是线程安全的**:

| 必须串行 | 为什么 |
|---|---|
| `SubState { loaded, pending, pending_seek }` | 一把锁,**不能拆**:拆了就是 TOCTOU,字幕永远没人挂且一声不吭(`lib.rs:1066-1069`) |
| `seek_latch` | 与 `SubState` 是**两把独立的锁**,但 `queue_seek` 与设闩必须在同一逻辑事务里(`lib.rs:1629-1638`) |
| 整个 Player 的对外接口 | 两个壳都用 `Mutex<Option<Player>>` 把所有命令串起来(`apps/desktop/src/lib.rs:5771`;`apps/android/src/lib.rs:138-148`) |

`SPEC.md:189` 已定:「需要顺序的地方(播放器控制)由 `player` 包内部串行化:一个 goroutine 持有 mpv handle」。
**这个设计比现状好**:现状是「多个调用线程 + 一把大锁」,Go 版是「单 goroutine + channel」,
天然消掉 `unsafe impl Send for Player`(`lib.rs:1188`)那种手工保证。

**但事件 goroutine 仍要单独一条**:`mpv_wait_event` 是阻塞调用,不能和命令共用一条 goroutine。
关闭序列必须是 `running=false → 等事件 goroutine 退出 → mpv_terminate_destroy`(`lib.rs:1950-1959`),
**用 `sync.WaitGroup` 或 done channel 显式等,不能靠 GC**。

### 13.3 render API 怎么接

现状是 `wid`(`lib.rs:1231`),四个 overlay 变体全是为它服务的。
`SPEC.md:552-568` 已把这件事列为 **SPIKE-1 / P0 风险**,三条路径 A/B/C,**默认赌 B(render API + 纹理互操作)**。

从本层的角度,切到 render API 会**改动这些**:
- `create_overlay()` / `Player::video_hwnd` / 四个 overlay 变体 → 全删,换成 `lp_set_surface(kind, handle, w, h)`;
- `set("wid", ...)` → 不设,改为 `mpv_render_context_create` + `MPV_RENDER_PARAM_API_TYPE`;
- 新增:`mpv_render_context_render` 要在 UI 的渲染线程调,`MPV_RENDER_UPDATE_FRAME` 回调要跨线程唤醒 UI;
- **`gpu-context=d3d11` 那条要重新评估**:render API 走 OpenGL/ANGLE 时它可能不再适用,
  但 §6.8 的独显钉定链依赖 D3D11 —— **这两件事的耦合必须在 SPIKE-1 里一起验**,别分开做结论。

**不变的**:除渲染面之外的一切 —— §1 的选项表、§2 的事件模型、§3 的属性表、§4 的全部时序约束。

### 13.4 解绑必须同步阻塞(现在没有,新架构必须有)

`SPEC.md:544-546`:「Android 的 `surfaceDestroyed` 回调返回后 Surface 立即失效,mpv 还在往里画就是 use-after-free。
这是安卓端最容易漏的一条。」

**现状确实漏了**:`surfaceDestroyed` → `nativeSetSurface(null)` → `overlay::set_surface(0)`
(`MainActivity.kt:197`;`apps/android/src/lib.rs:5390-5414`),
但**活着的 `Player` 里 mpv 仍持着那个 ANativeWindow,没有任何解绑动作**。
唯一的兜底是 `stop_playback` 会 `take()` 掉 Player(`apps/android/src/lib.rs:445-447`)——
可 `surfaceDestroyed` 和 `stop_playback` 没有任何顺序保证。见 §14。

### 13.5 别继承的东西

| 别继承 | 理由 |
|---|---|
| `set()` 闭包吞返回码 | `lib.rs:1229`。Go 侧应该收上来,至少 log。现在只能靠对个别选项手工回读来打补丁 |
| 四个 overlay cfg 变体 | 归一成一个 surface 入口。兜底桩「任何 CI 目标都编不到」的洞(`lib.rs:964-969`)随之消失 |
| 桌面/安卓两份几乎相同的命令实现 | Go 核心一份,三端 UI 只发命令。现在 `apply_playback_defaults` 只有桌面有(§5.3)就是两份实现漂移的直接证据 |
| 轮询模型 | 现在 250ms 轮 `status()`,每次读 9 个属性(`lib.rs:1673-1701`)。Go 版可以考虑 `mpv_observe_property` + 推事件,但**这是优化不是移植**,先原样跑通 |

---

## 14. 已知未解决 / 存疑

| # | 事项 | 状态 | 查了哪里 |
|---|---|---|---|
| 1 | **CVE-2026-8461 防护丢失** | 🔴 当前版本**没有** `vd=-magicyuv`。Flutter 时代有(`fb5d3a5d`),重写时静默丢失 | 全仓 grep `magicyuv`(排除 target/gen/二进制)只命中 `docs/go-migration/TODO.md:246`;`git log -S magicyuv -- '*.rs'` 零结果 |
| 2 | **安卓完全没有 `apply_playback_defaults`** | 🔴 hwdec 偏好 / 默认倍速 / 杜比自动软解**三项落库但没人读**,而设置命令还在校验它们 | 全仓 grep `apply_playback_defaults` 只在 `apps/desktop`;`apps/android/src/lib.rs:259-261, 298-299` 的注释自认 |
| 3 | **安卓软解调优参数全丢** | 🔴 `vd-lavc-*` / `framedrop` / `hdr-compute-peak` 一个都没有 | 全仓 grep 零命中;`git show 88757f17` 证明它们只存在于 Flutter 时代的 Kotlin 侧 |
| 4 | **`stream-lavf-o` reconnect 组全丢** | 🟡 网络瞬断不再透明重连(`multiple_requests=1` 的**不加**是对的) | `git show 4d5837cd`;当前 grep 零命中 |
| 5 | **Android Surface 解绑无同步屏障** | 🔴 `surfaceDestroyed` 后 mpv 仍可能往已销毁的 Surface 上画 | `MainActivity.kt:195-197`;`apps/android/src/lib.rs:5390-5414`;`crates/mpv/src/lib.rs:855-858` 只存指针,无解绑;`SPEC.md:544-546` 已把它列为必须做对的一条 |
| 6 | **Linux 上 `pin_below` 是 no-op** | 🟡 **已知能力差,不是忘了写**。真在 X11 上遇到层级掉队再补事件循环 | `crates/mpv/src/lib.rs:788-793` |
| 7 | **兜底 overlay 桩会静默烂掉** | 🟡 任何 CI 目标都编不到;2026-08-02 发现已缺三个函数 | `crates/mpv/src/lib.rs:964-969` |
| 8 | **`SPEC.md §7.5` 对弹幕现状的描述与代码不符** | 🟡 SPEC 说「主路 ASS + 网页 fallback」,代码是「**只有网页 Canvas**,ASS 路径已删」 | `ui/desktop/App.tsx:141-149`;`crates/core/src/danmaku/local.rs` 只解析不生成;`SPEC.md:585-586` |
| 9 | **`http-header-fields` 含逗号的值会串味** | 🟢 已标 `ponytail:`,当前源(OpenList Authorization)不涉及 | `crates/mpv/src/lib.rs:1525` |
| 10 | **安卓 `set_android_surface_size` 只在起播时读一次** | 🟢 已标 `ponytail:`,TV 上没有分屏/画中画入口 | `crates/mpv/src/lib.rs:908-910` |
| 11 | 当前 libmpv 版本 | Windows 侧 `crates/mpv/libmpv/libmpv-2.dll`(112MB,2026-07-14),`client.h` 报 `MPV_CLIENT_API_VERSION = 2.1`;代码注释里的实测版本是 **v0.41.0-744**(2026-07-16 用 ctypes 直问) | `crates/mpv/libmpv/client.h:251`;`crates/mpv/src/lib.rs:1850` |
| 12 | 安卓 libmpv 来源 | media-kit/libmpv-android-video-build **v1.1.11**(full-arm64-v8a);`.so` 走 Git LFS,CI 必须 `lfs: true` 并校验 ELF 魔数 | `crates/mpv/src/lib.rs:931-933`;`SPEC.md:898-902` |
| 13 | **未确认**:`gpu-next` 在 Linux 各发行版上的实际可用率 | 桌面两端都写死 `gpu-next`(`lib.rs:1235`),但 Linux 的 `gpu-context` 是让 mpv 自己挑。`gpu-next` 在老 Mesa 上起不起得来,仓库里**没有任何实测记录**。查了:`crates/mpv/src/lib.rs` 全文、`docs/go-migration/*`、git log 关键词 `gpu-next` | —— |
| 14 | **未确认**:`Player::new` 失败后桌面壳的降级行为 | `setup` 里失败只 `poclog`(`apps/desktop/src/lib.rs:5831-5837`),之后所有播放命令返回「播放器未就绪」。**没有重试路径**(安卓有)。是不是有意为之,注释里没写 | 查了 `apps/desktop/src/lib.rs:5831-5853` 及周边注释 |

---

## 附:一页速查

**Go 版必须原样继承的 12 条(全是 mpv 事实):**
1. `loadfile` 异步,只排队 → `FILE_LOADED` 之前 `sub-add` / `seek` 全丢
2. 排队状态必须**单锁**(TOCTOU)
3. 挂载/补发**必须在事件线程**(Drop 靠 join 保护)
4. `keep-open=yes` → `END_FILE` 不发 → 判播完读 `eof-reached`
5. `keep-open=yes` → 换片前必须 `stop`(否则露上一片最后一帧)
6. `idle=yes` 必须显式设(否则 `stop` 会让核心退出)
7. `time-pos`/`duration` 是「时有时无」的属性 → 必须判返回码 + NaN
8. seek 闩**只能吃这一拍真读到的值**,不能吃粘性值
9. ASS 字幕只认 `sub-scale`,不认 `sub-font-size`;次字幕没有独立字号/字体属性
10. `user-agent` / `http-header-fields` 是**实例级粘连属性**,每次 loadfile 无条件重设
11. `gpu-shader-cache-dir` 必须显式给(libmpv 没有配置目录)
12. `glsl-shader-opts` 是**全局**表,同档不许两个同名 `//!PARAM`;参数名写错整条被拒

**Go 版会整段删掉的(约 700 行,全是本架构产物):**
独立顶层窗建/毁、几何对齐(两个入口 + `align_target`)、wndproc 子类化 + 重入闸 + 可改挂、
z 序钉住、显隐两条件与、`OVERLAY_TOP_INSET` 全套、X11 复刻全套、`GDK_BACKEND=x11` 强制、
独立播放窗 + Alt+F4 拦截 + `QUIT_AFTER_PLAYER`、`show_video` 及其契约测试。

**Go 版必须新做的:**
`vd=-magicyuv`(补回丢失的 CVE 防护)、Android Surface 同步解绑、
安卓的 `apply_playback_defaults` 等价物、弹幕 ASS 生成器(SPEC 以为它存在,其实已删)、
render API 接入(SPIKE-1)、独显钉定符号挪到各端 UI 宿主 exe。
