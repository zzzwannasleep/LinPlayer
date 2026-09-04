# LinPlayer 重构规划书 · Dart → Rust 核心 + React/TS 前端 + Tauri 壳

> ## 📦 历史文档(2026-09-04 归档)
>
> **本文描述的是已删除的 Rust + React/Tauri 栈**,其中的文件路径、命令、构建方式
> 在当前仓库里**都不存在了**。当前技术栈是 Go 核心层 + C#(Avalonia) Windows 外壳。
>
> 保留它是因为**决策理由**仍有参考价值(为什么这么选、当时排除了什么)。
> 要看它描述的代码:`git show rust-final:<路径>`。
>
> ⚠️ **别照着本文动手** —— 先对当前仓库的实际结构(见 `AGENTS.md` §1)。



> 生成日期：2026-07-14 · 承接 `docs/MIGRATION_RN_PLAN.md`(功能全清单 + RN 否决)
> 本文=**落地方案**:确定技术栈、Dart→Rust 核心迁移顺序、Windows 前端、mpv 集成、分阶段里程碑。
> 铁律:**先过 Phase 0 PoC 关,再正式动工。** 未验证的假设不许铺开。

---

## 0. 已锁定技术栈

| 层 | 选型 | 理由 |
|---|---|---|
| **前端 UI** | **React + TypeScript**(web,跑在 webview) | 华丽/动效/流畅生态之王;React ⟺ TS 不可分 |
| **桌面壳** | **Tauri v2** | 体积小(用系统 WebView2,Win10 ✅),后端就是 Rust |
| **后端/核心** | **Rust**(单一核心,桌面+安卓复用) | 原生无运行时=最小体积;交叉编译到各端;socket/mpv 强项 |
| **视频** | **libmpv-rs** 驱动**原生子窗口**,垫在透明 webview 下 | 真 mpv(PGS/Anime4K/硬解),结构性免闪屏 |
| **安卓/TV** | 待定(留 Flutter 或 webview UI);**Rust 核复用** via `flutter_rust_bridge` / `uniffi` | 逻辑一份两吃 |

**核心原则**:
- **TS 管脸,Rust 管里子**。UI 逻辑在 React;数据/网络/mpv/加密/插件在 Rust 核。
- **视频永不进 webview**——mpv 是原生一层,webview 只画透明 UI 盖在上面(Jellyfin Media Player / Plex 同架构,可参考其壳)。
- **Dart→Rust 是重写不是转译**。逻辑你都懂(你写的),但要逐模块解耦 Flutter 依赖再落 Rust。

---

## 1. 架构图

```
┌─────────────── React + TS (webview, 透明) ───────────────┐
│  首页/库/详情/播放OSD/设置/弹幕面板 …  华丽+动效           │
└───────────────┬─────────── Tauri IPC ────────────────────┘
                │ invoke / event
┌───────────────▼──────────── Rust 核心 ────────────────────┐
│  数据源(Emby/OpenList/夸克/ani-rss/飞牛)+ 302重签 + 聚合  │
│  播放控制(libmpv-rs)+ 字幕/音轨偏好 + 片头跳 + 上报        │
│  弹幕(签名/匹配/解析/缓存/过滤) 下载引擎(多线程Range)     │
│  网络(CF反代 钉IP+SNI / 预取本地server / SOCKS5 / UA)     │
│  同步(Trakt/Bangumi) 排行 日历 加密(备份/配置迁移) 插件   │
│  插件运行时 = rquickjs(Rust 绑定 QuickJS,沿用 JS 插件API) │
└───────────────┬──────────────────────────────────────────┘
                │ raw-window-handle
┌───────────────▼──────────── 原生子窗口 ───────────────────┐
│  libmpv 直出 D3D11(Win)/GL(Linux),DWM/合成器叠 UI → 不闪  │
└───────────────────────────────────────────────────────────┘

安卓/TV:同一份 Rust 核 → 交叉编译 .so → Flutter(flutter_rust_bridge)或 Kotlin(uniffi)
```

---

## 2. Dart → Rust 核心:模块映射与 crate 选型

> 参考功能清单见 `MIGRATION_RN_PLAN.md §1`。以下为"哪块 Dart 变成哪块 Rust"。

| Dart 现状 | Rust 落地 | 关键 crate |
|---|---|---|
| dio HTTP + 统一 UA | HTTP 客户端 + 默认头 | `reqwest` / `hyper` |
| Emby/OpenList/ani-rss/飞牛 鉴权(签名 md5/sha256) | 各源 client + 签名 | `sha2` `md-5` `hmac` `base64` |
| 夸克 Cookie 轮换 + 扫码 | Cookie jar + 设备码轮询 | `reqwest` cookie store + 持久化 |
| 302 重签 / TTL | 播放会话状态机 | 自写 |
| 聚合版本匹配 | 多服扇出 + 匹配 | `tokio` 并发 |
| media_kit/mpv 控制 | **libmpv-rs** | `libmpv2` / `libmpv-sys` |
| 字幕/音轨偏好正则 | 同逻辑 | `regex` |
| ASS→SRT / 时间偏移 | 文本处理 | 自写 |
| 弹幕 签名/匹配/解析/缓存/过滤 | 同逻辑 | `regex` `serde_json` `quick-xml` |
| 多线程 Range 下载 | 分段并发 + 断点 | `tokio` `reqwest` Range |
| **CF 反代 钉IP+SNI** | 自定义 connector | `hyper` + `rustls`(SNI/IP 完全可控,Rust 主场)|
| **预取本地 server** | 本地 HTTP server | `hyper` / `axum` |
| SOCKS5 代理 | 代理连接 | `tokio-socks` |
| 观看记录/续播指纹 | 匹配 + 本地库 | `rusqlite` / `redb` |
| Trakt(设备码 OAuth)/Bangumi | OAuth + API | `reqwest` `oauth2` |
| Emby 上报三件套(PlaySessionId 一致) | 会话贯穿 | 自写(注意 id 一致) |
| 排行(弹弹签名/TMDB AES) | 双源 + 解密 | `aes` `cbc` |
| 备份加密(PBKDF2+AES-GCM)/配置迁移(AES+gzip) | 同算法 | `pbkdf2` `aes-gcm` `flate2` |
| 凭据安全存储 | OS 钥匙串 | `keyring` |
| 便携化路径 | 目录重定向 | `dirs` / 自写 |
| Sentry 遥测 | 崩溃+活跃 | `sentry` (Rust) |
| **QuickJS 插件系统** | **rquickjs** 重建沙箱 + 权限 + 8s 超时 | `rquickjs`(Rust 绑 QuickJS)|
| 平台集成(文件选择/深链/通知) | Tauri 插件 | `tauri-plugin-*` |

**注意事项**
- **解耦 Flutter 依赖**:凡是 Dart 服务里用了 `flutter_secure_storage`/`path_provider`/`FilePicker` 的,落 Rust 时换成 `keyring`/`dirs`/Tauri 插件。
- **插件系统是最大重写块**:好在 `rquickjs` 让你能在 Rust 里继续跑 QuickJS,插件的 JS 侧 API(ctx.http/storage/player/…)可原样保留,只重写宿主桥。
- **PlaySessionId 一致性**:上报三件套必须同 id,这是续播落地的老坑,移植时首要保。

---

## 3. Windows 前端(React/TS)

- **框架**:React + TS;路由 React Router;状态 Zustand + TanStack Query。
- **动效**:Framer Motion / GSAP / CSS —— 华丽层就靠这里。
- **播放页**:React 画 OSD/面板(透明),视频是底下 mpv 原生窗口;进度/轨道/缓冲通过 Tauri event 从 Rust 核推上来。
- **弹幕渲染**:Web `<canvas>` / WebGL —— web 做高密度弹幕很强,是加分项。
- **与 Rust 通信**:`invoke`(命令)+ `event`(播放状态/进度/日志流)。
- **组件库**:可选 shadcn/Radix 等,自定义主题做"简洁+华丽"。

---

## 4. mpv 集成(#1 技术风险)

- `libmpv-rs` 在 Rust 核创建 mpv 实例,`--wid` 或 render API 绑定一个**原生子 HWND**(Win)/GL surface(Linux)。
- Tauri 窗口:webview 设透明,mpv 子窗口 z-order 在 webview 之下(或用 Tauri v2 多 webview / 原生层叠加)。
- **合成缝**(webview 与 mpv 窗口的位置/层级/缩放同步)= 全项目最大不确定点 → **Phase 0 必须先验**。
- 超分:Anime4K glsl-shaders 通过 mpv 属性喂(assets 运行时落地),沿用现有 6 个 CNN shader。

---

## 5. 分阶段里程碑(风险优先 → 价值优先)

> ### ⚠️ 打 ✅ 的规矩(2026-07-15 血的教训)
> Phase 2 曾被误打 ✅:文档只按**模块**粒度写了一句举例,我照它勾了,结果整个播放器
> **24 条草稿要求只落 9 条**,倍速/音量/截图/画面比例/延迟/字幕样式/超分全漏,UI 上是一排
> 「点了没反应」的死按钮 —— 用户一眼看穿,痛批「你根本就没有按草稿做」。
>
> **规矩:**
> 1. **本文档不是权威,旧 Dart 代码才是。** 每个模块动手前,先把对应 Dart 服务/抽象类的
>    **公开方法逐个列出来**当能力清单(如播放器 → `lib/core/services/video_player_service.dart`)。
>    文档里的一句话描述是**举例**,不是清单。
> 2. **能力粒度,不是模块粒度。** 每阶段必须有一张「能力 → Dart 契约 → Rust 命令 → 状态」表,
>    逐行核。**没有表就不许打 ✅。**
> 3. **UI 侧的权威是 `native-poc/docs/desktop-drafts.html`(14 页,每个橙色标注都是需求)**,
>    它会要求文档里没写的能力(桌面新交互)。**两边都得对。**
> 4. **✅ 只代表"逐条核过"**,不代表"写了代码"。核不动就标 ◑ 并列出缺口,别糊。
> 5. **禁止「摆控件不接线」**:没有后端就诚实占位,不许留空函数 `onClick={() => {}}`。
>    也**禁止把有后端的功能写成"待接"** —— 动手前 grep `#[tauri::command]` 全表核一遍。

### Phase 0 · PoC(硬门槛,不过不动工)
- Rust 核骨架 + Tauri + React 壳
- libmpv-rs 在原生子窗口放一段带 **PGS 字幕 + 一个 Anime4K shader** 的片
- React 画一个**带切换动效的面板**,弹出/收起验证**不闪**
- 同一份 Rust 核 `cargo build --target aarch64-linux-android` **编成 .so**(证明安卓可复用)
- ✅ 三条全过 → 继续;❌ 合成缝过不了 → 回头重估壳(Qt WebEngine 兜底)

### ◑ Phase 1 · 可播地基(Emby 打通)
Rust:HTTP+UA、Emby client、凭据存储、配置。React:服务器列表/登录/首页。**能登录并用 mpv 播一条 Emby 流。** ✅ 这条承诺达成。

> ⚠️ **但「配置」两字覆盖不到实情** —— 逐条核过(2026-07-15):
> `Account`(`crates/core/src/config.rs`)只有 4 字段(server/token/user_id/user_name);
> 旧 `ServerConfig`(`lib/core/providers/server_providers.dart:43-84`)有 **14 字段**
> (id/name/baseUrl/**iconUrl**/**remark**/**lines[]**/**activeLineIndex**/username/authToken/
> userId/password/**allowInsecureTls**/streamKind/**sourceKind**)。
> 缺的直接后果:草稿页 05 的备注/图标/类型徽标/多线路**全无处存**;
> **网盘源不进服务器列表**(`list_accounts` 只遍历 Emby accounts);
> **CF 优选没有 choke point 可挂**(旧栈靠 `activeLineUrl` 改写,新栈无 line 概念)。
> **这是服务器页 6 条 P0 的公共根因,补 Account 字段一次能解 6 条。**
>
> ✅ **2026-07-15 已补**:`Account` 4→14 字段,**且把浏览型源并进同一张账号表**(靠 `source_kind` 区分)
> —— 那本来就是旧 `ServerConfig` 的架构,新栈之前分裂成「Emby 账号表 + 一个内存里的孤儿 Option」。
> 逐条状态见 Phase 6.5 表。**2026-07-15 二批全部补完**:状态点三态 / 图标下载缓存 / TLS 放行接线 /
> 批量解析深链 / CF 改写挂载 —— Phase 6.5 表已无 ❌ 与 ◑。
>
> **另补(观看记录连带)**:`Item` 加了 `provider_ids`/`presentation_unique_key`/`path`/`series_id`
> 四个字段 + `emby::HISTORY_FIELDS` + `item_for_history()` + `series_tmdb_id()` —— 跨服强匹配的判据。

#### Emby 客户端能力清单(对齐 `lib/core/api/emby_api.dart`,35 个公开方法)

| 能力 | 旧 Dart | Rust 命令 | 状态 |
|---|---|---|---|
| 登录/会话 | login | `login` `current_session` | ✅ |
| 媒体库(Views) | getViews | `list_views` | ✅ |
| 条目详情 + 分集 | getItem/getEpisodes | `item_detail` | ✅ |
| 最新/继续观看/收藏 | getLatest/getResume | `list_latest` `list_resume` `list_favorites` `set_favorite` | ✅ |
| 随机推荐 | — | `list_random` | ✅ |
| 版本/流信息 | getPlaybackInfo | `item_media` | ✅ |
| 演职人员 | Fields=People | `item_detail.people` | ✅ |
| **列表分页/排序/筛选参数** | `emby_api.dart:571 getLibraryItems`(11 参数) | `list_items` **写死 `Limit=200&SortBy=SortName`** | ❌ **>200 项静默吞内容** |
| **`/Items/Filters` 分面** | `:638 getFilters`(5 分面并行) | — | ❌ 页 02 筛选无数据源 |
| **标记已看/未看** | `:355 markAsPlayed` `:361 markAsUnplayed` | — | ❌ 右键菜单缺项 |
| **多形态图片**(Backdrop/Thumb/Logo/tag) | `:1107 getImageUrl` 等 5 个 | 前端拼 URL,仅 Primary/Backdrop | ◑ |
| **合集 Collections** | `:662` | — | ❌ 页 01「合集」轨道 |
| **测试连接 / 公开信息** | `:422 testConnection` `:374 getPublicInfo` | — | ❌ 页 06「测试连接」按钮 |
| **NextUp** | `:480` | — | ❌ |
| **按 ProviderId 跨服找源** | `:829 findItemsByProviderIds` | — | ❌ 页 08 跨服找源只能模糊搜 |
| 搜索 | `:911 search` `:896 getSearchHints` | `aggregate_search` 写死 `Movie,Series&Limit=50` | ◑ 搜不到剧集/演员 |
| **logout / refreshToken** | `:318` `:334` | `remove_account` 只删本地,不调服务端 | ❌ token 过期无出路 |

### ◑ Phase 2 · 播放完整度

> ⚠️ **本阶段曾被误打 ✅ —— 教训写在这里,别再犯。**
> 原文只写了一句「轨道/字幕偏好匹配、ASS→SRT、片头跳、缓冲进度、PlaySessionId 上报、续播」,
> 那是**举例不是清单**。照它打勾的结果:倍速/音量/截图/画面比例/延迟/字幕样式/超分**全漏了**,
> UI 上就是一排「点了没反应」的死按钮;而它**自己列的「片头跳」当时也没做**。
> **根因 = 文档颗粒度停在「模块」,没到「能力」。** 下面按能力逐条列,状态必须逐条核过再改。
>
> **权威是旧代码不是本文档**:三端播放器契约 = `lib/core/services/video_player_service.dart`
> (实现 `mpv_player_adapter.dart` / `exo_player_adapter.dart`)。**任何"播放器做完了"的判断,
> 拿那个文件逐个方法对一遍再说。**

React 播放页成型 ✅ · 播放上报/续播 ✅

#### 播放器能力清单(对齐 `video_player_service.dart`)

| 能力 | Flutter 契约 | Rust 命令 | 状态 |
|---|---|---|---|
| 起播/暂停/seek | play/pause/seekTo/seekBy | `play` `set_pause` `seek` | ✅ |
| 状态/时长/缓冲 | position/duration/buffer | `status`(含 `demuxer-cache-time`) | ✅ |
| 音轨/字幕选择 | selectAudioTrack/selectSubtitleTrack | `tracks` `set_track` `apply_prefs` | ✅ |
| 轨道语言偏好 | — | `get_prefs` `set_prefs` | ✅ |
| PlaySessionId 三件套 | — | `play`/`report_progress`/`stop_playback` | ✅ |
| 逐流 headers/UA | — | `load_with_headers` | ✅ |
| 302 直链重签 | — | `source_watchdog` + `take_error_eof` | ✅ |
| **倍速** | setSpeed | `set_speed` | ✅ 补 |
| **音量 / 静音** | setVolume | `set_volume` `set_mute` | ✅ 补 |
| **截图** | screenshot | `screenshot`(screenshot-to-file) | ✅ 补 |
| **音画同步(音频延迟)** | setAudioDelay | `set_audio_delay` | ✅ 补 |
| **字幕延迟** | setSubtitleDelay | `set_sub_delay` | ✅ 补 |
| **画面比例** | setAspectRatio | `set_aspect_ratio` | ✅ 补 |
| **硬解/零拷贝/软解** | applyZeroCopyHwdec | `set_hwdec` | ✅ 补 |
| **字幕样式**(字体/字号/位置/背景/混合) | setSubtitleFont/Size/Position/Background/BlendMode | `set_sub_style` | ✅ 补 |
| **次字幕(双字幕)** | loadSecondarySubtitle/selectSecondary…/setSecondary…Delay/Position | `set_secondary_sub` `set_secondary_sub_opts` | ✅ 补 |
| **外挂字幕加载** | loadLibassSubtitle | `add_subtitle(secondary?)` | ✅ 补 |
| **超分 Anime4K** | applySuperResolution(Level) | `shader_levels` `set_shader_level` | ✅ 补 |
| **mpv 属性直通**(插件桥要) | mpvGetProperty/SetProperty/Command | `mpv_get` `mpv_set` `mpv_command` | ✅ 补 |
| 片头/片尾跳过 | `intro_skip_controller.dart` | — | ❌ **未做**(原文列了却没做) |
| ASS→SRT 转换 | — | — | ❌ 未做 |
| 画中画 (PiP) | — | — | ❌ 未做 |
| 定时关闭 | — | 前端 setTimeout 即可,不需核层 | ✅ 前端 |
| 字幕 cue 观测/内嵌字幕隐藏 | setSubtitleCueObservation/setNativeSubtitleHidden | — | ❌ 未做(弹幕/字幕翻译要用) |
| loadLibassSubtitleMemory | 内存挂字幕(字幕翻译用) | — | ❌ 未做 |

**超分实现要点**:7 个 `.glsl` 用 `include_str!` 编进二进制(`src-tauri/src/shaders.rs`),
首次用时落到 `config_dir/LinPlayer/shaders/`(mpv 的 `glsl-shaders` 只收路径不收内容)。
绿色版是 exe+dll 平铺、`bundle.active=false` **没有 resources 目录可用**,所以不能走 Tauri 资源。
档位表逐字对齐 `lib/core/services/anime4k_shaders.dart`(modeAA/BB 里同名 shader 出现两次是
双 Restore 特性,**别去重**)。`set_shader_level` **回读 shader 数校验**,非 off 却挂 0 个直接报错
—— 旧 Flutter 桌面端软件纹理根本不跑 glsl,不回读就会"以为开了其实没开"。

### ◑ Phase 3 · 数据源铺开
OpenList → ani-rss → 飞牛(authx)→ 夸克(Cookie+扫码)→ 聚合 + 302 重签。**浏览/播放面 5 源全通 ✅**,夸克扫码 ✅。

> ⚠️ **ani-rss 只搬了浏览面。** 旧 `lib/core/sources/anirss/anirss_api.dart` 有 **47 个公开方法**
> (addAni/setAni/deleteAni/refreshAni/refreshAll/batchEnable/config/setConfig/torrentsInfos/
> searchBgm/refreshCover/scrape/logs…),新栈 `source/anirss.rs` 只有 `login` + `MediaSourceBackend`
> (列目录/解析播放),**管理接口 0 个,0 个 tauri command** → 草稿页 13 除番剧列表外整页没后端。
> 撑起页 13 至少要八个:`listAni`/`config`/`setConfig`/`batchEnable`/`refreshAll`/`searchBgm`/`addAni`/`deleteAni`。
>
> ⚠️ **源服务器不持久化、且同时只能连一个**。`src-tauri/src/lib.rs` 的
> `*state.source.lock() = Some((kind, server))` 是**单个 Option、纯内存、不入 AppConfig**
> → **重启后网盘源全丢,必须重登**;页 05 也摆不出多源卡片。
>
> ✅ **2026-07-15 已修**。真正的物理根因不是「忘了写」:**`SourceServer` 连 `Serialize` 都没 derive**,
> 源在物理上就不可能落盘。已加 derive + 并入 `AppConfig.accounts`(`source_kind` 区分),
> `source_login` 落盘、启动按活跃账号形态恢复 session 或 source(两者互斥)。
>
> ✅ **Ani-RSS 管理已补齐**:core 侧 52 个方法全实现(`source/anirss.rs`,19 个测试)。
> 顺带修了两个原地真 bug:`rate` 用 `as_i64()` 对服务端回的 `8.5` 返回 None → **评分静默变 0**
> (Dart 是 `num?.toInt()`,含 double);`flatten_week_list` 把 `id:""` 的番剧**整条丢弃**
> (Dart 回退用 title 当 key)→ 浏览页少番剧,没人发现过。

### ◑ Phase 4 · 弹幕
Rust:签名 ✅ / 解析 ✅ / 搜番 ✅ / 取评论 ✅。React:canvas 渲染 ✅。

> ⚠️ **本行原文写的「匹配 / 缓存 / 过滤」三样,代码 0 行,却打了 ✅** —— 典型的照模块勾。
> **2026-07-15 已补齐**(core 16 个测试)。逐条见下表。

| 能力 | Dart 契约 | Rust | tauri 命令 | 状态 |
|---|---|---|---|---|
| 智能集数匹配 | `danmaku_matcher.dart` `_pickEpisode/_titleScore/_normalize` | `match_all` / `pick_episode` / `title_score` | `danmaku_match` + `danmaku_min_auto_score` | ✅ 分值逐字对齐 |
| 多源并行 + 用户挑源 | `danmaku_service.dart:50-141` `searchAllGrouped/matchAllGrouped` | `search_all_grouped` / `match_all_grouped` | `danmaku_search` | ✅ JoinSet 并行,单源失败进 `error` 不拖累别人 |
| 多源配置(enabled/priority) | `DanmakuConfigRepository` `List<DanmakuSourceConfig>` | `AppConfig.danmaku_sources: Vec<DanmakuServer>` + `enabled_danmaku_sources()` | `get/set_danmaku_config` | ✅ 老单源配置自动迁移(有测试) |
| 缓存(内存 LRU + 磁盘 TTL) | `danmaku_cache.dart` | `cache_get/put/clear` | `danmaku_cache_clear` / `danmaku_cache_size` | ✅ |
| 过滤 / 去重 | `danmaku_filter.dart` + `applyDanmakuFilterAndDedup` | `apply_filter_and_dedup` / `DanmakuFilter` | `danmaku_filter` | ✅ |
| 屏蔽词 XML 导入 | `importFromDandanplayXml` | `import_dandanplay_blocklist_xml` | `danmaku_import_blocklist` | ✅ 复用 `regex`,未加 XML 依赖 |
| AutoLoader 播放期自动挂 | `danmaku_auto_loader.dart` | 复用 `match_all`+`get_comments_from_all`+`apply_filter_and_dedup` | `danmaku_auto_load` | ✅ 含 episodeId 连号快路径(锚点在宿主内存);★ 官方源 id 是 `official` 不是 Dart 的 `dandanplay`,写错则快路径永不命中且不报错 |
| 本地弹幕文件(xml/json/ass) | `danmaku_local_parser.dart` | `danmaku::local::{parse,parse_xml,parse_json,parse_ass}` | `danmaku_load_local` | ✅ 内容嗅探优先于扩展名(Dart 只认扩展名,且把 ASS 的 `[` 当 JSON);整文件失败返 Err,不返空 Vec 假装成功 |

> **分工定论(已有代码证据,不再是判断)**:11 项显示参数(不透明度/速度/字号/显示区域/描边/密度…)
> 留前端。依据:旧 Dart 自己就这么分的 —— 渲染参数全在 `ui/widgets/common/danmaku_overlay.dart`
> 和 riverpod provider,`danmaku_filter.dart`/`danmaku_postprocess.dart` **从头到尾没碰过一个渲染参数**。
> 灰色地带 `mode`(1/4/5)和 `color` 留在 `DanmakuComment` 里 —— 它们是**服务端下发的数据**,不是用户偏好。
>
> ⚠️ **已知偏差**:`FilterOptions.blocked_modes`(按类型屏蔽)**Dart 无对应实现**,是新增能力;
> 默认空列表 = 不过滤,行为与 Dart 完全一致。

### ◑ Phase 5 · 网络重活(Rust 主场)
多线程下载引擎 ✅(分段/Range/断点/线程 1-4)、**CF 反代(钉 IP+SNI)** ✅、预取本地 server ✅、SOCKS5 ✅、代理 ✅。

> ⚠️ **引擎搬了,出口没接**:
> - ~~**播放已下载的本地文件**~~ → **2026-07-15 已补** `play_local(id, resume_secs)`,
>   顺带校验「索引说完成 ≠ 文件还在」(用户可能手删/挪走)。草稿页 11 的 ▶ 活了。
> - ~~**清除已完成**~~ → **2026-07-15 已补** `download_clear_completed()`(只清记录不删文件)。
> - ~~**预取线程数/缓存上限写死**~~ → **2026-07-15 已补** `Prefs.prefetch_{enabled,threads,cache_bytes}`
>   + `get/set_prefetch_settings`。引擎侧本就收参数,是**调用点写死了常量**。越界拒绝而非静默 clamp。
> - ~~**CF 优选挂不上 choke point**~~ → **2026-07-15 已挂**,见 Phase 6.5 表。

### ✅ Phase 6 · 同步/周边
Trakt/Bangumi、排行双源、追剧日历、爱发电、配置迁移扫码。(备份加密 GCM 刻意不港:Dart 标注 legacy 仅向后兼容导入,新端无历史可导。)

### ❌ Phase 6.5 · 服务器管理补完(文档原本漏了整块)

> **文档只在 Phase 1 用「配置」两字带过 → 实际 13 个能力没搬。**
> 权威:`lib/core/providers/server_providers.dart` + `utils/server_batch_parser.dart` +
> `utils/server_batch_adder.dart` + `services/deep_link_service.dart` + `services/server_icon_cache.dart`。

| 能力 | 旧 Dart | Rust / tauri 命令 | 状态 |
|---|---|---|---|
| Account 扩字段(name/remark/icon/lines/active_line/source_kind/allow_insecure_tls/password) | `server_providers.dart:43-84` | `config::Account`(4→14 字段) | ✅ **6 条 P0 的公共根因,一次解完** |
| 源服务器入 AppConfig(多源并存 + 持久化) | 同上 `:67 sourceKind` | `Account.source_kind` + `Account.source` 并进同一张表 | ✅ 根因是 `SourceServer` 连 `Serialize` 都没 derive,物理上不可能落盘 |
| 多线路 + 切线路 | `:140 ServerLine` `:410 setActiveLine` | `ServerLine` / `set_lines` / `set_active_line` / `probe_lines`(并发测速) | ✅ |
| `activeLineUrl` 改写点(CF 优选的 choke point) | `:92 activeLineUrl` | `Account::active_line_url()` + `net::cf::runtime`(全局改写表) / `cf_proxy_enable/disable/status` | ✅ 全部取基址处收敛到此;`direct_line_url()` 留给反代自身上游(否则自环) |
| 拖动排序 | `:399 reorderServers` | `AppConfig::reorder` / `reorder_accounts` | ✅ 活跃账号跟着走(有测试) |
| 列表返回全源(Emby + 网盘) | — | `list_accounts` → `AccountInfo`(含 `is_file_browse`) | ✅ |
| 切换服务器(Emby↔源双形态) | `currentServerProvider` | `set_active_server` / `current_source` | ✅ 两边状态互斥对齐 |
| 状态点三态(绿正常/黄需重登/灰未连) | `:154 authStateProvider` + `testConnection` | `AccountStatus{Ok,Reauth,Down,Unknown}` / `probe_accounts`(并发) | ✅ 走 `/System/Info`(**带鉴权**)才分得出黄;`/System/Info/Public` 不校验 token,黄灯会成摆设 |
| 服务器图标(内置/网络/本地上传) | `:295 _materializeNetworkIcons` + `server_icon_cache.dart` | `icon_cache::{get,set_from_file,clear}` / `account_icon` / `set_account_icon_file` / `clear_account_icon` | ✅ 吐 data URI(免开 assetProtocol);MIME 按字节嗅探(Emby 图标端点无扩展名);4MB 封顶 |
| 自签名 TLS 按 host 放行 | `:60 allowInsecureTls` `:324 _syncInsecureTlsHosts` | `http::{set_insecure_hosts,is_insecure_host}` + 自定义 rustls `ServerCertVerifier`;`AppConfig::sync_insecure_hosts()` 挂 load/save | ✅ **原本是全局 `danger_accept_invalid_certs(true)`** —— 不是「没接线」,是所有服务器的证书校验都关着,该字段纯装饰。真实握手测试已验(`tls_verification_is_real`,需 `--ignored`) |
| 批量解析添加 + `linplayer://` 深链 | `server_batch_parser.dart` / `deep_link_service.dart`(341 行) | `server_batch::{parse_share_text,parse_deep_link,server_lines,build_icon_url,danmaku_sources_of}` / `batch_parse` / `batch_add_servers` / `parse_deep_link` / `startup_deep_link` | ✅ 逐线路试登录,通的那条即生效线路;协议注册每次启动重写(绿色包挪目录后老路径即死)。**深链确认框是安全门,归前端**;单实例守卫未接(热启动深链会开第二个进程) |

> **顺带根治**:改 `Account` 波及 `config_transfer`(扫码搬服务器配置)。若用 `..Default::default()`
> 糊过去,**扫码搬家会静默丢线路和备注**。已按 CommonConfig 跨客户端约定挂在 `linplayer` 子对象
> (别家客户端读到未知键会忽略),两个方向都有测试。

### ◑ Phase 6.6 · 本地观看记录 / 跨服续播(文档原本漏了整块)

> **技术选型表提过一句「`rusqlite`/`redb`」,但 8 个 Phase 无一认领 → 代码 0 行。**
> **2026-07-15 已补齐核心**(`crates/core/src/watch_history.rs`,35 个测试)。
> 存储没上 sqlite/redb —— 单文件 JSON + 写锁够用(旧 Dart 也是 JSON),YAGNI。

| 能力 | Dart 契约 | Rust | tauri 命令 | 状态 |
|---|---|---|---|---|
| 4 级置信度指纹匹配 | `watch_history_matcher.dart` | `match_record_to_candidate` / `build_canonical_key` | — | ✅ 逐字对齐 |
| **跨 scope 取最大进度** | `_resolveCrossServerPositionTicks` | `cross_server_position_ticks` | 接在 `play` 里 | ✅ |
| 续播主入口 | `resolveResumePositionTicks` | `resolve_resume_position_ticks` | 接在 `play` 里 | ✅ |
| 播放期落记录(10s 节流) | `capturePlayback` | `capture_playback` | 接在 `report_progress`/`stop_playback` | ✅ stop 时 force 落地 |
| 本地存储 + 写队列 | `watch_history_store.dart` | `Store`(Mutex 串行读-改-写) | `watch_history_list/clear/delete` | ✅ |
| 跨服续播开关 | `crossServerResumeProvider` | `Prefs.cross_server_resume` | `get/set_cross_server_resume` | ✅ 默认关 |
| 剧 → TMDB id + 缓存 | `resolveSeriesTmdbId` + `_seriesTmdbCache` | `emby::series_tmdb_id` | 宿主 `series_tmdb_cached`(含负缓存) | ✅ |
| 恢复扫描 | `_needsRestore/_buildSearchQuery/_resolveCandidate` | `watch_history_sync::{scan_restore,restore_action,restore_write,restore_fallback_ticks}` | `watch_history_scan_restore` / `watch_history_restore_candidate` | ✅ 编排已接;possible 候选交前端确认后回传(`RestoreCandidate` 已补 `Deserialize`) |
| 跨服回传 | `writeback_service.propagate` 的选择段 | `watch_history_sync::{run_writeback,writeback_plan}` | 接在 `stop_playback` 里 | ✅ 编排已接;`Prefs.cross_server_writeback{,_range,_progress}` + `get/set_writeback_settings`,主开关**默认关**(会写别人服务器)。★ 比 Dart 收紧:按 scope(server+user)配对而非只按 server —— Dart 换过登录用户会把进度写进别人账号 |

> **根治的一个隐坑**:`emby::Item` 原本没有 `ProviderIds`/`PresentationUniqueKey`/`Path`/`SeriesId`,
> 而这四项正是强匹配判据。缺了**不崩、只是静默降级**到「剧名+季集号」—— 跨服续播的全部价值就在
> TMDB 强匹配,降级 = 功能还在效果没了,且没人会发现。已在 `From<RawItem>` 漏斗补齐 +
> `emby::HISTORY_FIELDS` + `item_for_history()`,并有测试钉住透传链。
>
> ⚠️ **存盘格式与旧 Dart 不兼容**(时间戳用 epoch ms 而非 ISO8601,免引 chrono)。
> 路径也不同(`config_dir()/LinPlayer/` vs `getApplicationSupportDirectory`),读不到旧文件。
> 判断是无所谓 —— 配置搬迁另有 config_transfer。要读旧文件另说。

### ◑ Phase 6.7 · 字幕翻译(文档原本漏了整块)

> **`RUST_MIGRATION_PLAN` 无任何 Phase 覆盖**;`MIGRATION_RN_PLAN.md` 提了功能,落地文档漏。
> **2026-07-15 core 已补齐**(`crates/core/src/translation.rs`,31 个测试,**零新增依赖**)。

| 能力 | Dart 契约 | Rust | 状态 |
|---|---|---|---|
| SRT/VTT/ASS 解析 + 双语排版 | `subtitle_document.dart` | `SubtitleDocument::parse_str/to_srt` | ✅ 含内容嗅探 |
| 整轨翻译(分块/有界并发/二分重试) | `translateDocument` / `_translateChunk` | `translate_document` / `translate_chunk` | ✅ |
| 整轨翻译入口(URL→SRT 路径,带缓存) | `translateSubtitleUrl` | `translate_subtitle_url` | ✅ |
| AI 引擎(OpenAI/Anthropic) | `engines/` 两个类 | `AiEngine{proto}` | ✅ 合一,协议差异走 match |
| 百度(通用 + LLM) | `BaiduTranslationEngine` / `BaiduLlmTranslationEngine` | `BaiduEngine` / `BaiduLlmEngine` | ✅ |
| 腾讯(TC3 签名) | `TencentTranslationEngine` | `TencentEngine` + `build_authorization` | ✅ HMAC 手写,RFC 4231 测试向量对标 |
| 实时预读翻译 | `streaming_subtitle_translator.dart` | `StreamingTranslator::on_cue/warm/compose` | `translate_live_start` / `translate_live_stop` | ✅ **已挂上播放器**:轮询 mpv `sub-text`,译好 emit `subtitle-translated` 给前端叠加层 |
| Whisper 离线转录 | `whisper/` | `whisper::{download_model,extract_segment,transcribe,WhisperStream}` | ✅ **能做**:旧 Dart 也是 `Process.run` 外部 exe,不是绑库 |
| 设置持久化 | `translation_providers.dart` | `TranslationSettings::load/save`(独立 `translation.json`) | ✅ |
| Linux ffmpeg 自动下载 | `downloadFfmpeg` | `whisper::download_ffmpeg` 的 linux 分支 | ✅ 调系统 `tar -xJf`(每个发行版自带),**不引 tar/xz2 两个 crate**;解到临时目录再找 ffmpeg(包内路径含版本号,写死会在上游发版时静默失效) |

> ✅ **2026-07-15 更正**:先前记的「缺字幕 cue 观测 + loadLibassSubtitleMemory 两个前置,
> 所以实时预读翻译接不上播放器」**是错的** —— 那是照搬 Dart 架构名词、没去核实播放器实际能力得出的结论。
> mpv 的 `sub-text`/`sub-start`/`sub-end` 就是普通属性,`Player::get_property` 直接读得到;
> 加载内存字幕也只是临时文件 + 已有的 `add_subtitle`。**播放器侧从来没有前置缺口**。
> 实时预读翻译已接:`translate_live_start/stop`,200ms 轮询 sub-text,换句即译,emit 给前端叠加层。
> 教训:「缺前置」这种结论必须落到具体函数上验一遍,否则就是给自己发免死金牌。
>
> ⚠️ **安全待决**:翻译引擎的 apiKey 明文落盘(`translation.json`),与 config.rs 里 token 同姿态。
> 建议与 config.rs 的 keyring 待决项**一起处理**,别在本模块单独造轮子。

### Phase 7 · 插件系统
rquickjs 重建引擎;JS 插件 API 保持兼容;**并借机重写实现形态**(不再走 Dart 的 `__lp_host` 字符串编组,改 Rust async 函数原生绑进 `ctx` 返回真 Promise,引导脚本 227 行→1 行)。

- **✅ Rust 引擎 + 命令(已证死)**:`crates/core/src/plugins/`——manifest/permission/storage(5MB)/extensions(注册表)/host(平台缝 trait,单一 `call(channel,method,args)`)/convert/state(权限门控+HTTPS 白名单+**30s 空转看门狗**:interrupt 只在 JS 真跑时触发,等宿主 await 期不触发)/ctx(原生绑 log/http/storage/player/ui/emby/extensions/cfproxy/sleep 九通道)/engine(AsyncRuntime+内存限 64MB+Drop 清 Persistent)/**worker(专用线程 actor:QuickJS 单线程,引擎钉线程永不跨线程)**/manager(Send+Sync 门面)。只支持 `runtime:js`(data/addon 是 iOS 合规专用,无 Apple 已砍)。src-tauri:`DesktopPluginHost` + 10 个 `plugin_*` 命令 + play/stop 钩 onPlay/onPlayEnd。单测 39 过(真 hello 插件逐字不改跑通全生命周期 + 权限拒绝),app release 绿。
- **⬜ React 宿主 UI(待接)**。对接契约已铺好:
  - **ctx.ui 渲染**:监听 Tauri 事件 `plugin://ui-request`(载荷 `{id,pluginId,method,args}`);`showForm/showDialog/showList/showProgress` 渲染后调命令 `plugin_ui_respond(id, value)` 回填(`value=null` 视为取消);`showToast/updateProgress/closeProgress/openPage` 是即发即忘(`id=0`)。
  - **扩展点渲染**:命令 `plugin_extensions(type_id)` 取某类型全部扩展(homeStats/sidebarItems/settingsPages…);触发 handler 用 `plugin_trigger(pluginId,type_id,ext_id,args?)`,具名字段(设置页 load/submit)用 `plugin_invoke_field(...,field,args?)`;注册表变化会发 `plugin://extensions-changed` 事件。
  - **管理页**:`plugin_list` / `plugin_install(path)` / `plugin_enable(id)` / `plugin_disable(id)` / `plugin_uninstall(id)`;启用前须自行弹权限同意弹窗(`plugin_list` 项含 `permissions`)。
  - 遗留:`getCredentials` 因 PoC 不存明文密码返 Err;cfproxy 重活未接(命令壳在)。

### Phase 8 · Linux + 安卓
- **✅ 安卓:一份 Rust 核交叉编译通过(证死)**。`cargo ndk -t arm64-v8a build --release -p linplayer-core` 产出 `target/aarch64-linux-android/release/liblinplayer_core.rlib`(8.6MB,`llvm-readobj` 验为 `EM_AARCH64` ELF64);**整核含 reqwest/rustls、tokio、数据源、网络、QuickJS 插件引擎全套**都过。可复现脚本:**`native-poc/scripts/build-android.sh [arm64-v8a|armeabi-v7a|...]`**。Windows 宿主特有的 bindgen 坑及解法(脚本已封装):
  - reqwest 从默认 native-tls **切 rustls-tls**(`default-features=false`),去掉 `openssl-sys`——安卓交叉编译免装 OpenSSL(桌面亦通用,`.resolve()`/`danger_accept_invalid_certs` 的 CF 钉 IP+SNI 在 rustls 下照常)。
  - rquickjs-sys 不随包发 android 的 FFI bindings → core/Cargo.toml 的 `[target.'cfg(target_os="android")']` 开 `bindgen` 现生成;`bindgen` 经 proc-macro `rquickjs-macro`(永远编 host)传导,**host+android 两个 bindgen 都要喂**。
  - 需一个**带 `libclang.dll` 的 NDK**(如 30.x;27.x 不带);libclang 当 DLL 加载 InstalledDir 为空 → 显式 `-resource-dir` 指 `lib/clang/<ver>`(补 stdbool.h);host(msvc)bindgen 还要从 `vcvars64.bat` 灌 `%INCLUDE%`(补 stdio.h);预置 `BINDGEN_EXTRA_CLANG_ARGS_<triple>` 后 cargo-ndk 不再补 sysroot,故自带 `--sysroot`。
- **⬜ 安卓 UI 未定**:Rust 核已就绪不阻塞;留 Flutter 走 flutter_rust_bridge 或 webview 走 uniffi;真出 `.so` 需一个 cdylib 绑定壳(core 是 rlib);TV 焦点方案另议。
- **⬜ Linux(需 Linux 机验)**:Tauri 跨平台;`.so`/GL 子窗口合成需 webkit2gtk + Linux target,Windows 宿主上无法验证,留到有 Linux 环境再证(风险低)。

---

## 6. 风险登记（开工前须知）

| 风险 | 级别 | 应对 |
|---|---|---|
| webview↔mpv 合成缝(位置/层级/缩放同步) | 🔴 | Phase 0 先验;兜底 Qt WebEngine(Jellyfin MP 架构) |
| Dart→Rust 是重写,工期以季度计 | 🟠 | 逻辑已知;按 Phase 切,先出可播 MVP |
| Rust 团队熟练度 | 🟠 | 核心只写一次,学习成本摊到各端;UI 仍是熟悉的 TS |
| 插件系统重写(QuickJS 宿主桥) | ✅ | Rust 引擎+宿主桥已落并证死(rquickjs 原生绑定,39 测过);剩 React 宿主 UI |
| 安卓 UI 未定 + TV 焦点 | 🟡 | Phase 8 再决;Rust 核先就绪不阻塞 |
| 夸克双鉴权/扫码 | 🟡 | 放 Phase 3 末;cookie store + 设备码 |

---

## 7. 立即下一步

1. **搭 Phase 0 PoC**(Tauri + React + Rust + libmpv-rs,验合成不闪 + 安卓可编)。
2. PoC 过 → 按 Phase 1 起 Emby 可播 MVP。
3. 每 Phase 结束回看 `MIGRATION_RN_PLAN.md §1` 勾功能,防遗漏。

> 一句话:**React/TS 画脸,Rust 当里子(libmpv-rs 驱动 mpv),Tauri 装成小体积原生壳,一份 Rust 核桌面安卓两吃。先 PoC 验合成缝,再逐 Phase 铺。**
