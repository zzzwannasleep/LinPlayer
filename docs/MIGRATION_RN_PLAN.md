# LinPlayer → TypeScript + React Native 迁移规划书

> ## 📦 历史文档(2026-09-04 归档)
>
> **本文描述的是已删除的 Rust + React/Tauri 栈**,其中的文件路径、命令、构建方式
> 在当前仓库里**都不存在了**。当前技术栈是 Go 核心层 + C#(Avalonia) Windows 外壳。
>
> 保留它是因为**决策理由**仍有参考价值(为什么这么选、当时排除了什么)。
> 要看它描述的代码:`git show rust-final:<路径>`。
>
> ⚠️ **别照着本文动手** —— 先对当前仓库的实际结构(见 `AGENTS.md` §1)。



> **⚠️ 这份是 2026-07-14 的可行性评估，结论已被推翻（2026-07-26 复核）**
>
> - **React Native 方案已否决**，最终选的是 **Rust 核 + React/TS + Tauri**。落地记录见
>   [RUST_MIGRATION_PLAN.md](RUST_MIGRATION_PLAN.md)，当前架构见 [DEVELOPMENT.md](DEVELOPMENT.md)。
> - **端范围已收窄**：只做 Android 手机 / Android TV / Windows / Linux。**苹果全线不做**，
>   下文里的 iOS / macOS / tvOS 一律作废。
> - **这份文档现在唯一还算数的东西**：第 1~N 节那份**「已实现功能全清单」**——
>   它是防止重写时漏功能的对照表，仍在用。**技术选型、工作量估算、路线图部分全部作废。**
>
> 生成日期：2026-07-14 · 基线：Flutter/Dart 版本(main 分支，355 个 dart 文件 / 约 11.4 万行 / 7 平台)
> 用途：① **已实现功能全清单**(防止重写遗漏) ② RN/TS 迁移可行性评估 ③ 分阶段路线图 ④ 待拍板决策点
> 调研方式：8 个子 agent 逐域清点源码 + RN 生态可行性 web 调研，交叉验证。

---

## 0. 执行摘要 · 先看这一节

### 0.1 现状规模
- **7 个平台目标**：Android / iOS / Windows / macOS / Linux / Android TV / tvOS(apple_tv)
- **5 类媒体源**：Emby/Jellyfin、OpenList、夸克网盘、Ani-rss、飞牛 fnOS
- **4 套播放内核**：media_kit(libmpv) / ExoPlayer(Android) / 原生 mpv(Android) / Windows 原生 D3D11 直出
- 一套 QuickJS 沙箱插件系统、Canvas 弹幕引擎、多线程下载引擎、CF 优选反代、字幕翻译+Whisper、TV 遥控焦点系统、扫码遥控/配置迁移……

### 0.2 诚实的可行性判断(必须先决策：**要不要迁**)

8 个域的独立清点 + RN 生态调研,给出一个**方向一致、需要你正视**的结论:

> **这个项目的全部核心价值 = 「深度原生播放能力(mpv/PGS/Anime4K/硬解/直出渲染) + 含 Linux 的全平台统一」。而这两点恰恰是 React Native 生态目前最薄弱的地方。全量迁 RN 大概率是负收益。**

关键事实(均已核实):

| 维度 | Flutter 现状 | RN 生态现状(2026-07) | 结论 |
|---|---|---|---|
| **Linux 桌面** | 一等公民 | **无官方支持**,仅社区 Qt 老 fork(react-native-desktop-qt / react-native-linux),基本停更 | 🔴 事实上不可行 |
| Windows 桌面 | 原生 | RN-Windows(微软官方,WinUI3/WPF)较成熟,但无 `fluent_ui` 级组件库、无低层 D3D11 直出钩子 | 🟡 可行需重写 |
| macOS 桌面 | 原生 | RN-macOS(微软)存在,成熟度低于 Win,`macos_ui` 无等价物 | 🟡 勉强 |
| **mpv 播放内核** | media_kit 跨端统一 | `react-native-mpv`/`react-native-video-mpv` 存在但小众非大厂维护;主流 `react-native-video` 只有 ExoPlayer/AVPlayer | ⚠️ PGS/超分/次字幕/缓冲反馈全部缺失,需自建原生模块 |
| CF 反代 / 预取代理 | dart:io HttpServer + HttpClient 钉 IP+SNI | RN 无套接字级能力,需三端各写原生 socket/TLS | 🔴 极高成本 |
| TV 遥控焦点 | 自研 `_EdgeEscape` 已彻底解决边界跳转 | `react-native-tvos` + TVFocusGuideView 可用,但自定义边界跳转要重写 | 🟡 可行需重投入 |
| 弹幕高密度渲染 | Flutter CustomPaint/Canvas | React Native Skia 需 PoC 验证 500+ 条帧率 | 🟠 需验证 |

**多个域的清点报告独立地得出同一建议**:桌面端改 Flutter 保留或 Electron,不要用 RN。

### 0.3 三条候选路线(供拍板)

| 路线 | 描述 | 适用前提 |
|---|---|---|
| **A. 不迁,继续 Flutter** | 承认 Flutter 是这类"重原生播放 + 全平台"应用当下的最优解;把精力投在功能而非重写 | 若迁移动机是"技术栈偏好"而非硬需求 → **推荐** |
| **B. 混合:移动端 RN + 桌面 Flutter/Electron + TV 谨慎评估** | 只有明确要 RN 移动端时才做,桌面绝不迁 RN;两套代码库并存 | 若你有强烈的 RN 移动端理由(团队/复用 Web 生态) |
| **C. 全量迁 RN** | 逐平台重写,自建大量原生模块 | **不推荐**;Linux 桌面基本要放弃,工期以季度计,且换来功能缩水 |

> 下面 **第 1 节是不受路线选择影响的资产** —— 无论迁不迁,这份「已实现功能全清单」都是你要的"防遗忘"底账。第 2~5 节服务于"若决定迁移"。

---

## 1. 已实现功能全清单(核心交付 · 防遗漏底账)

> 按 8 个域组织。每条 = 功能 / 关键文件 / 依赖 / 备注坑点。

### 1.1 数据源与服务器接入(`lib/core/sources`, `lib/core/api`)

**抽象层**
- `MediaSourceBackend` —— listDir / search / resolvePlay 统一接口,三端复用
- `SourceBrowseController` —— UI 无关浏览状态机(面包屑 / 排序 / 搜索降级)
- `SourcePlayback` —— 直链播放载荷(清晰度档 / 外挂字幕 / **逐流 headers**)
- `SourceLoginService`(登录工厂:账密/扫码/Cookie 路由)、`SourceCredentialStore`(加密附加凭据)

**5 类媒体源**
| 源 | 鉴权 | 特性 | 关键坑 |
|---|---|---|---|
| **Emby/Jellyfin** | X-Emby-Token + api_key | 传统媒体服务器 | `X-Emby-Authorization` 必须从 query 剔除(防 WAF),仅 api_key |
| **OpenList** | JWT 账密 + 自动重登 | 文件网关 | 401 透明重试 |
| **夸克网盘** | Cookie 轮换(`__puus/__pus` 需实时回写) + TV 扫码 | 两套独立鉴权 + 302 签名链 + 清晰度档 | `device_id` 生成一次须持久化,不能重生成 |
| **Ani-rss** | Token(header/query) | 追番 + 三层树浏览 | **api-key 头禁用**(恒判失败),必须 Authorization/s 参数 |
| **飞牛 fnOS** | authx 签名(md5 拼接) + 账密 | 全媒体库 + Range 直传 | 每请求重生签名(nonce/timestamp) |

**跨源机制**
- **聚合版本**：同集在多台 Emby 的版本聚合,精确/模糊身份匹配 + 版本偏好正则(`episode_aggregation_provider`)
- **302 重签**：`StreamServerKind` 标记网盘短链;暂停超 TTL 断流后重调 `resolvePlay()` 重解析重签(与播放内核深度协作)
- **多线路**：`activeLineUrl` 被 CF 优选反代改写,`directLineUrl` 为原始上游
- **源端搜索降级**：`UnsupportedError` 时 UI 本地按名过滤

### 1.2 播放器内核 / 字幕 / 超分 / 投屏(`lib/core/services`)

**四核架构**(`VideoPlayerService._createAdapter` 按平台/设置动态选,非热切,切换需重建)
- ExoPlayer(Android 默认,`exo_player_adapter`,Kotlin MethodChannel)
- libmpv/media_kit(桌面/iOS,`mpv_player_adapter`,libmpv FFI + ANGLE)
- 原生 mpv(Android,`native_mpv_player_adapter`,libmpv JNI)
- **Windows 原生 D3D11 直出**(`windows_native_mpv_adapter` + `native_mpv_render.cpp`,绕 ANGLE,`WindowsNativeRender` 跨进程静态开关)

**字幕(三段)**
- 内封轨选(`player_subtitle_loader`,Emby index → 内核轨 ID)
- 正则偏好匹配(`track_preference`,纯算法易迁)
- MPV 轨匹配(`subtitle_track_matcher`,按类型/编码/标题分 PGS/ASS/文本)
- ASS→SRT 转码 + 时间偏移(`subtitle_processor`)
- libass 渲染(Android,`libass_bridge`,Kotlin JNI)
- **图形字幕 PGS/SUP**：mpv 原生位图渲染(带描边/位置偏移),`_subtitleBlendMode` 三档(no/video/yes);ExoPlayer 无 PGS,转码软渲
- 次字幕(secondary-sub,mpv 0.41+：选轨/位置/延迟)

**超分 Anime4K**(`anime4k_shaders`)
- 7 档预设(off/modeA/B/C/AA/BB/AC)→ GLSL 链;6 个 CNN 片段着色器打包 assets 运行时落地
- **血泪坑**:绝不用 compute shader(ANGLE 蓝屏)、绝不 setSize(dxva2-egl 交互蓝屏);软件纹理模式 GLSL 下次播放才生效

**硬解/HDR**
- 杜比视界自动软解(`MediaStream.isDolbyVision` → gpu-next,三端默认开)
- 硬解:Windows 默认 d3d11va 零拷贝 / Android/Linux auto;`_zeroCopyHwdec` 会话级开关,EGL 失败降 d3d11-copy
- 已缓冲进度三后端齐全(mpv state.buffer / Exo getBufferedPosition / 原生 demuxer-cache-time)

**辅助**
- 片头片尾自动跳(`intro_skip_service`,TheIntroDB/introdb.app 多源 + 缓存)
- DLNA 投屏(`cast_service`,HTTP 扫描 + UPnP + XML)
- 外部播放器(系统 intent/xdg-open)
- 预加载(`preload_service`,详情页进入 Range 预取头 32MB+尾 2MB,fire-and-forget)
- 网盘 302 过期恢复(video_player_service L2/L2.5,失败 3 次暂停重试)
- mpv 配置管理(`mpv_config_manager`,写 mpv.conf 记录用,media_kit config=no)

**Windows 原生渲染(技术债档案见 `docs/NATIVE_RENDERING.md`)**
- M1(已验)：mpv 子 HWND 直接 D3D11 + mpv 自带 OSC 控制栏,缺陷=Flutter 控件被盖
- M2(待真机)：`SetWindowRgn` 挖洞法,`nativeRenderPanelFraction` 动态 cutout;**未验证致命假设**:ANGLE flip-model swapchain 能否被 SetWindowRgn 透穿

### 1.3 弹幕系统(`lib/core/api/danmaku`, `lib/core/utils/danmaku_*`)

- **并行多源 + 三种鉴权**(签名/路径 token/header token);弹弹 Play SHA256 签名 `Base64(SHA256(AppId+Ts+Path+Secret))`
- **智能集数匹配**(`danmaku_matcher`)：文件识别 `/match` + 名字 `/search/episodes` 双路径,可信度排序(文件唯一命中 1.5 / 标题相似 + 集号)
- **连续集快路径**(`danmaku_auto_loader` 锚点表：追下一集直接 episodeId+1)
- 本地弹幕解析(XML B站 / JSON 弹弹 / ASS Aegisub)
- 缓存(内存 LRU 40 + 磁盘 JSON TTL 7 天,key `sourceId:episodeId`)
- 过滤(屏蔽词 + 用户 ID) + 后处理(时间窗去重,默认 10s)
- **渲染引擎(最高难点)**：Flutter CustomPaint+Canvas,`DanmakuPainter` 逐帧 + `DanmakuLayoutCache` 跨帧缓存 + 轨道分配 + 碰撞检测;三类(滚动/顶/底);参数:透明度/字号/速度/密度/显示区域/延迟(-5~+5s)/自定义 TTF;可见窗口 ±30s
- 播放集成:开播 `run()`、Ticker 帧同步 `_smoothPosition`
- 弹弹 Ranking 复用同一签名器

### 1.4 QuickJS 插件系统(`lib/plugins`)

**5 层架构**
1. 引擎：IsolateQjs(每插件独立 isolate)+ 64MB 堆/插件 + **8 秒空转看门狗**
2. 权限：11 个权限,启用前同意 + 运行时每次调用检查
3. **上下文桥(宿主暴露给 JS 的 API 面)**：
   ```
   ctx.log.{info,warn,error}                 // 始终
   ctx.http.{get,post,delete}                // 权限 http(HTTPS + 白名单,支持 *.example.com 通配子域)
   ctx.storage.{get,set,delete,keys,clear}   // 权限 storage(5MB)
   ctx.player.{play,pause,seek,on}           // 权限 player.{control,read}
   ctx.ui.{showToast,showDialog,showForm}    // 权限 ui
   ctx.emby.{apiRequest,getCredentials}      // 权限 emby.{api,credentials}
   ctx.extensions.{register,unregister}      // 权限 extensions
   ctx.cfproxy.{listServers,speedTest}       // 权限 cfproxy
   ```
4. 生命周期：扫描→安装→启用(需授权)→禁用/卸载;**覆盖升级在权限未扩张时保留启用态**
5. 扩展点(8 类)：sidebarItems / mediaSources / actions / eventListeners / settingsPages / homeStats / playerOverlays / contextMenus
- .lpk 打包(zip archive)

### 1.5 同步 / 观看记录 / 遥测 / 排行 / 日历 / 付费(`lib/core/services/{sync,watch_history,telemetry}`)

- **观看记录 + 跨服续播**(`watch_history_*`)：本地存储 + 4 级置信度指纹匹配,跨 scope 取最大进度
- **Trakt Scrobble**(设备码 OAuth + 生命周期上报,状态码 400/409/410/418/429 各有语义)
- **Bangumi 同步**(授权码粘贴 + 单集进度 + 番剧三级反查:providerId→弹弹→Bangumi API;失败 silent skip)
- **Emby 播放上报三件套**(start/progress/stop,**PlaySessionId 三端点必须一致**,否则续播不落地)
- **Sentry 遥测**(匿名崩溃 + Release Health 活跃用户,不采 PII;Android SIGSEGV 检测)
- **排行榜双源**(动漫榜弹弹签名 + 影视榜 TMDB;TMDB 密钥 CI `dart run tmdb_encrypt` AES 加密 → dart-define 注入 → 运行时解密)
- **追剧日历**(Trakt/Bangumi 当季当周 + "仅我追"过滤)
- **爱发电付费解锁**(`afdian_service`,订单号 → CF 代理 verify 软锁)

### 1.6 下载 / 缓存 / 网络代理(`lib/core/services/download`, `lib/core/network`)

- **多线程 Range 下载引擎**(自建 1-4 线程分段 + 断点续传 + 权限门控 + 进度落盘;`DownloadItem` 状态机 + 分组显示)
- **三类缓存**(`cache_service`)：图片(6GB/14d/LRU,内存按平台分级)、视频流(mpv on-disk 300MB-8GB 档)、下载;本地缓存目录(非 OneDrive)
- **CF 优选反代**(`cf_proxy`)：优选 IP 测速 + 本地反代;`HttpClient.connectionFactory` **钉 IP + 改 SNI**;`activeLineUrl` 唯一改写点
- **预取代理**(`prefetch_proxy`)：本地 HTTP server,mpv 走 127.0.0.1,2-4 并发 Range 超前拉流喂播放器(只代理 Emby 直传流,直链/转码跳过)
- 自定义代理(HTTP/HTTPS/SOCKS5,`socks5_proxy`)
- 统一 UA(`app_identity`,含图片/播放流修复 CDN 空白)
- TLS 自签名放行白名单

### 1.7 移动端 UI(`lib/ui`)

**14 功能区 + 11 设置子页 + 15 顶级路由(go_router)**,Riverpod 20+ Provider

| 功能区 | 关键特性 |
|---|---|
| 首页 | 轮播 + 沉浸取色 + 媒体库速览 + 续看 + 推荐 + 下拉刷新 |
| 媒体库+筛选 | 网格/列表双视图 + 三维筛选(类型/标签/时间,Emby /Items/Filters facet) + 屏蔽管理 |
| 详情页 | 视差 AppBar + 跨服聚合 + 集列表懒加载 + 未看集数角标(UnplayedItemCount) |
| **播放页** | 三内核 + 四层手势(竖滑亮度/音量·横滑快进·双指 zoom·长按加速) + OSD + 弹幕 + 字幕翻译 + 续播同步 + Anime4K |
| 搜索 | 聚合搜索 + 历史 + 服务器分组 |
| 设置(11 页) | 通用/播放/交互/弹幕/翻译/同步/聚合/网络/备份/迁移/日历 |
| 收藏·下载·排行 | 网格 + 进度实时更新 |
| 追剧日历 | 付费门控 + 多源 + 日期分组 |
| Ani-rss | 迷你应用 3-Tab 自治导航 |
| 网盘浏览 | 面包屑 + 路径栈 + 源内搜索 + 直链播放 |
| 服务器管理 | 手动/批量/导入三模式 + 线路测速 + 深链 |

- 动效系统(`flutter_animate`：AppMotion/appEntrance/ShimmerBox/AppLoadingIndicator)
- 主题/壁纸(DynamicBackground 亮度自适应 + 自定义静态壁纸 InteractiveViewer 裁剪)

### 1.8 桌面 / TV / 跨端基础设施

**桌面(`lib/desktop`)**
- 三平台原生外壳(fluent_ui/Windows · macos_ui/macOS · Material/Linux,`desktopUiStyle` 枚举),220px 侧栏 + indexedStack 保活
- 无边框窗口 + 自绘标题栏(window_manager,`WM_GETMINMAXINFO` 钉 rcWork 修最大化溢出;macOS 交通灯预留 72px)
- 桌面播放器(鼠标自动隐显 + 快捷键 + 统计浮层 + Whisper 语音转字幕 `desktop_binary_manager` 下载 executable)
- 平滑滚动(自研 `DesktopSmoothScrollBuilder`)、下载栏目、快捷键绑定

**TV(`lib/tv`)**
- **焦点管理核心**(`tv_shell` 的 `_EdgeEscape`：侧栏/内容双 FocusScope + 显式边界跳转,根治 Flutter 几何"就近"焦点卡死)
- `tv_focusable`(1.05x 放大 + 品牌蓝环 + 遥控键映射 + 长按菜单)
- 响应式(`tv_metrics` 1920×1080 基准 `s()/fs()` 缩放)
- TV 播放页(LAN 遥控总线 + 弹幕 + 字幕翻译 + 看完自动下一集)
- TV 设置(配置二维码 + WebDAV 备份 + zashboard WebView + CF 代理 + 插件管理)

**跨端基础设施(`lib/core/services`)**
- 配置迁移扫码(`config_transfer`,CommonConfig AES-256-CBC + gzip + base64url,前缀 `LPSYNC1:`,QR 容量 2200)
- 深链(`deep_link_service`,`linplayer://add-server` / `sync-bangumi`,需显式确认防 drive-by;Windows `.reg` import 注册协议)
- 备份口令加密(`backup_crypto`,PBKDF2-HMAC-SHA256 120K + AES-256-GCM,向后兼容)
- 凭据安全存储(`secure_credential_store`,flutter_secure_storage;回退 SharedPreferences+XOR)
- 自定义字体运行时加载(`font_service`,App/弹幕两家族,持久化到 app_support/fonts)
- 便携化路径重定向(`portable_paths`,userdata/ 收纳全部数据,解压即用)
- 应用更新(`update/*`,GitHub Releases + 预发布通道 + 应用内覆盖更新 open_filex + Windows 自更新 + AppUpdateGate)
- 翻译引擎多后端(`translation/*`,AI/Baidu/Tencent + Whisper 离线 binary)
- 批量解析添加服务器(`server_batch_parser/adder`,正则解析机场分享文本)
- LAN 遥控服务(`tv/services/lan_remote`,dart:io HttpServer + Web 控制页 + 命令总线)
- TV 内置 mihomo/zashboard(webview_flutter 指向 127.0.0.1:9090)

---

## 2. RN/TS 迁移可行性矩阵(逐功能难度)

> 难度：🟢易 · 🟡中 · 🟠难 · 🔴极难/需自建原生模块

| 功能 | 难度 | RN 方案 / 障碍 |
|---|---|---|
| 数据源鉴权(Emby/OpenList/飞牛签名/ani-rss) | 🟢🟡 | 纯算法 + fetch,Node crypto 重写签名 |
| 夸克 Cookie 轮换 + 扫码 + token 刷新 | 🟠 | Cookie jar 需原生模块,三套逻辑互联 |
| 302 重签 + TTL | 🟡 | 逻辑可复用,与播放器容错协作 |
| 聚合版本匹配 | 🟡 | 初版建议先做单服 |
| **mpv 播放内核(桌面/iOS)** | 🔴 | 无成熟 RN 绑定,需自维护 libmpv-{ios,android,windows} 三份 binding |
| PGS/SUP 图形字幕 | 🔴 | react-native-video 完全不支持位图字幕 |
| Anime4K 超分 | 🔴 | RN 视频库无 GLSL shader hook |
| 次字幕 / 字幕位置延迟字体 | 🟠 | 依赖 mpv 原生版本 |
| 硬解 d3d11va 零拷贝 / 缓冲进度反馈 | 🟠🔴 | RN 视频库多缺 bufferedPosition,需 fork |
| 多内核热切换 | 🟠 | RN 无内核切换概念,退化为需重启播放 |
| Windows 原生 D3D11 直出 | 🔴 | RN-Windows 无低层 D3D11 钩子,建议放弃 |
| 弹幕鉴权/匹配/解析/缓存/过滤 | 🟢🟡 | 纯逻辑可移植 |
| 弹幕高密度渲染 | 🟠 | React Native Skia,需 PoC 验证 500+ 条帧率 |
| 插件系统(数据/权限/生命周期) | 🟢🟡 | 高复用 |
| 插件强隔离 + 超时看门狗 | 🔴 | RN 单 JS VM,失控插件卡整个 app;需 Native 线程池 |
| 观看记录/续播指纹 | 🟡 | DB 改 SQLite/MMKV |
| Trakt/Bangumi/Emby 上报 | 🟢🟡 | PlaySessionId 一致性是关键风险 |
| Sentry | 🟢 | 换 @sentry/react-native |
| TMDB 密钥 AES | 🟡 | 无 dart-define,改 CI 生成 JS 常量 |
| 多线程 Range 下载 | 🟠 | 需 Android/iOS 各建原生模块 |
| 图片/视频缓存 | 🟢🟡 | Fresco/SDWebImage/ExoPlayer Cache 配置 |
| **CF 反代(钉 IP+SNI)** | 🔴 | RN 无套接字级能力,原生 socket+TLS 自实现(4-5 周) |
| **预取代理(本地 HttpServer)** | 🔴 | 需原生 HttpServer 或 Node 子进程 |
| 自定义代理 HTTP/SOCKS5 | 🟠 | 原生代理模块 + SOCKS 库 |
| 移动端各页面 UI | 🟡 | React Navigation + Zustand + Reanimated/Skia |
| 播放页四层手势 | 🔴 | Gesture Handler + 自建状态机(2 周单测) |
| Riverpod → 状态管理 | 🟠 | 声明式→命令式范式跨越 |
| **桌面三平台原生 UI** | 🔴 | fluent_ui/macos_ui 无等价物;RN-Linux 不可行 |
| 无边框窗口控制 | 🟠🔴 | RN-Windows 无 titleBarStyle API |
| **TV 焦点边界跳转** | 🟠🔴 | react-native-tvos 可用但自定义边界要重写 |
| 配置迁移/深链/备份加密/批量添加 | 🟢🟡 | 纯 TS 可移植 |
| 凭据安全存储 | 🟡 | react-native-keychain;Linux 缺原生库 |
| 应用内覆盖更新 | 🟠 | 完全应用内更新 RN 侧难度倍增,Windows 自更新需 native |
| Whisper 离线字幕 | 🔴 | RN 无 subprocess,改 WASM/云端/ONNX native |
| LAN 遥控服务 | 🟠 | 后端改 express/Node,前端 React |
| zashboard WebView | 🟢 | react-native-webview |

---

## 3. 迁移风险总表(按严重度)

### 🔴 红(阻断级 / 需自建原生模块 / 建议放弃)
1. **Linux 桌面** —— RN 无官方支持,近乎放弃
2. **mpv 内核 + PGS + Anime4K + 次字幕链路** —— 主流 RN 视频库全缺,自建成本极高
3. **Windows 原生 D3D11 直出** —— RN-Windows 无此能力
4. **CF 反代 + 预取代理** —— 底层 socket/TLS/HttpServer,RN/TS 层做不了
5. **桌面三平台原生 UI** —— fluent_ui/macos_ui 无等价物
6. **插件强隔离 + 超时** —— RN 单 VM,失控插件卡死全 app

### 🟠 橙(高成本 / 体验退化 / 需专项攻关)
- 播放页四层手势状态机、多内核热切换退化为重启、弹幕高密度渲染 PoC、TV 焦点边界跳转、iOS 后台下载、Whisper 离线、无边框窗口、Riverpod 范式跨越、应用内覆盖更新

### 🟡 黄(可控 / 需重构但风险中等)
- 夸克双鉴权、302 重签、聚合匹配、凭据存储、TMDB 密钥、Bangumi 反查、下载引擎、LAN 遥控、便携化

### 🟢 绿(近乎无损直译)
- 各源签名鉴权、弹幕逻辑、插件数据层、Sentry、统一 UA、配置迁移/深链/备份/批量添加、缓存配置、zashboard

---

## 4. 若决定迁移 · 分阶段路线图(仅对路线 B/C)

> 前提:桌面端**不进 RN**(保留 Flutter 或 Electron)。以下针对移动端(+ 可选 TV)。

**P0 · 决策与 PoC(1-2 周)** —— 先验证再投入
- PoC1：react-native-video-mpv/react-native-mpv 真机验 PGS + Anime4K + 缓冲反馈是否可行
- PoC2：React Native Skia 500+ 弹幕帧率
- PoC3：多线程 Range 下载原生模块最小验证
- **门槛**:若 PoC1 失败 → 播放能力必然缩水,回到路线 A/B 重新决策

**P1 · 基础 UI + 数据层(2-3 周)** —— 首页/搜索/媒体库/详情/收藏/下载 + 数据源抽象(先 OpenList/Emby) + Zustand/TanStack Query + React Navigation + MMKV

**P2 · 播放页(2-3 周)** —— 先用播放器自带 UI 保证功能完整,后迭代四层手势;PlaySessionId 贯穿

**P3 · 设置与辅助(1-2 周)** —— 11 设置页 + 服务器管理 + 日历 + 配置迁移/深链/备份

**P4 · 高级功能(2-3 周)** —— 弹幕引擎 + 字幕翻译 + Ani-rss + 网盘浏览 + 插件系统(先弱隔离试点)

**P5 · TV(若做,4-6 周)** —— react-native-tvos + 焦点模块 + LAN 遥控

**推荐移动端技术栈**
- 状态:Zustand + TanStack Query(避免 Redux)
- 导航:React Navigation(对应 go_router 模型)
- 动效:Reanimated 2 + React Native Skia
- 播放:react-native-video 或 mpv 绑定(取决于 PoC1)
- 存储:react-native-mmkv;安全:react-native-keychain
- 崩溃:@sentry/react-native

---

## 5. 待你拍板的决策点

1. **要不要迁?**(路线 A/B/C) —— 这是前置问题,决定后面一切
2. **桌面端如何处理?** 保留 Flutter / 改 Electron / 放弃桌面 —— RN 桌面(尤其 Linux)不建议
3. **Linux 是否仍是目标平台?** 若是 → 几乎排除全量 RN
4. **播放能力可否缩水?**(PGS/Anime4K/多核/直出) —— 若不可缩水,RN 需巨额原生模块投入
5. **CF 反代 / 预取代理是否核心?** 若可降级为可选 → 大幅降低风险
6. **插件系统是否需要强隔离?** 可接受弱隔离 → 省 2-3 倍工程

---

## 附:各域详细报告落盘位置(scratchpad)
- `source-integration-inventory.md`(数据源)
- `download-cache-network-domain-audit.md`(下载/缓存/网络)
- `QuickJS_Plugin_System_Audit.md`(插件)
- `mobile-ui-inventory.md`(移动端 UI)
- 播放器内核 / 弹幕 / 同步遥测 / 桌面TV基础设施 报告见对应子 agent 输出

> **一句话总结**:这份文档最大的价值是第 1 节的"功能全清单"——无论最终迁不迁,它都是你防遗忘的底账。而迁移决策上,证据强烈指向"Flutter 仍是这类重原生播放器的最优解,全量 RN 是负收益,最多考虑移动端混合"。
