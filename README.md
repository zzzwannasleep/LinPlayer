<div align="center">
  <img src="assets/app_icon.jpg" width="120" alt="LinPlayer" />
  <h1>LinPlayer （半成品 没有完工！ 不建议现在下载！）
  如果想要体验可以去releases里面的nightly找最新的安装包体验！</h1>
  <p>跨平台（Windows / macOS / Linux / Android / Android TV）本地 + Emby/Jellyfin + WebDAV 媒体播放器（含 Plex PIN 登录）</p>
  <p>
    <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white" />
    <img alt="Platforms" src="https://img.shields.io/badge/Platforms-Windows%20%7C%20macOS%20%7C%20Android%20%7C%20Android%20TV-informational" />
    <img alt="Sources" src="https://img.shields.io/badge/Sources-Local%20%7C%20Emby%2FJellyfin%20%7C%20WebDAV-informational" />
    <img alt="Player" src="https://img.shields.io/badge/Player-MPV%20%7C%20Exo-informational" />
    <img alt="Danmaku" src="https://img.shields.io/badge/Danmaku-Local%20XML%20%7C%20Dandanplay-informational" />
  </p>
  <p>
    <a href="#download">下载</a> ·
    <a href="#features">特性</a> ·
    <a href="#quickstart">快速上手</a> ·
    <a href="#build">构建与运行</a> ·
    <a href="docs/ARCHITECTURE.md">源码导览</a>
  </p>
</div>

A cross-platform local & Emby/Jellyfin & WebDAV media player built with Flutter (with Plex PIN flow for adding servers).

---

## <a id="download"></a>下载

从 GitHub Releases 下载：
- **latest**：稳定版
- **nightly**：每日构建（产物会覆盖同名资产）

下载入口：[latest](../../releases/latest) / [nightly](../../releases/tag/nightly) / [Releases](../../releases)

| 平台 | 产物文件（Release Assets） | 备注 |
| --- | --- | --- |
| Android / Android TV | `LinPlayer-Android.apk`（通用）<br/>`LinPlayer-Android-arm64-v8a.apk`<br/>`LinPlayer-Android-armeabi-v7a.apk` | TV 可直接安装通用版或对应 ABI 版本 |
| Windows (x64) | `LinPlayer-Windows-Setup-x64.exe` | Inno Setup 安装包 |
| macOS | `LinPlayer-macOS-arm64.dmg`<br/>`LinPlayer-macOS-x86_64.dmg` | Apple Silicon / Intel |
| iOS | `LinPlayer-iOS-unsigned.ipa` | 未签名 IPA，需要自行签名/侧载 |
| Linux (x86_64) | `LinPlayer-Linux-x86_64.tar.gz` | 解压后：`cd LinPlayer && ./LinPlayer` |

> 说明：本项目为非官方客户端，与 Emby / Jellyfin / Plex / 弹弹play 无官方隶属关系。

## <a id="features"></a>特性

- Emby/Jellyfin 登录：支持 http/https 与自定义端口；若未部署（可选的）线路扩展服务，线路列表可能为空，但播放/浏览可用。
- WebDAV（只读）：支持“像服务器一样”添加与切换；支持目录浏览 + 播放（含 Range），兼容 Basic/Digest 等常见鉴权；无需登录 Emby/Jellyfin 也可使用。
- Plex 登录（PIN）：支持浏览器授权获取 Token，并从账号资源列表中选择服务器保存（当前仅保存登录信息，暂不支持浏览/播放）。
- 首页推荐（类似 Emby）：继续观看 / 最新电影 / 最新剧集 横向卡片流，点击即播或进详情。
- 首页媒体库：进入服务器后自动刷新媒体库并缓存，减少偶发不显示；后续打开更快，同时在浏览首页时后台渐进更新。
- 首页媒体统计：底部统计卡片三项同排；进入服务器后仅首次自动刷新一次，滚动不会重复刷新（仍可手动刷新）。
- 剧集集数徽标：剧集海报右上角展示全季总集数（与评分徽标同尺寸）。
- 单集详情增强：从「继续观看」进入集详情页时，会展示该剧其它季/其它集（支持选季 / 选集 / 查看全部）。
- 媒体库分层：库 → Series/Season → Episode；电影可直接播放；搜索支持无限下拉懒加载。
- 搜索页：支持历史搜索记录（本地持久化），默认显示前 6 条，点击「更多」展开全部。
- 播放链接更稳：自动携带 `MediaSourceId`，减少 404。
- 播放缓冲：总缓冲大小可调（200-2048MB）+ 预设（拖动秒开/均衡/稳定优先）+ 自定义回退比例（0-30%）+ 跳转时清空旧缓冲。
- 响应式缩放：竖屏平板/手机自动放大 UI（文本/图标/间距），避免 UI 过小。
- Material 3 双主题：跟随系统明/暗色；桌面/手机轻量毛玻璃；Android TV 默认关闭毛玻璃，减少卡顿。
- 本地播放：保留原生文件选择与播放。
- Anime4K（MPV shader）：内置 Anime4K GLSL 预设，播放页一键开关/切换（仅 MPV 内核有效）。
- 弹幕：支持本地 XML 与在线弹幕（兼容弹弹play API v2），支持样式调节。
- 构建产物：Android 同时支持 32 位与 64 位；Windows 打包附带运行时与 DLL。

## <a id="quickstart"></a>快速上手
1. 启动应用，进入「连接服务器」页（未登录也可用）：
   - 点「本地播放」：直接进入本地播放器，选择本地文件播放。
   - 右上角 `+` 添加服务器：可选 Emby / Jellyfin / WebDAV / Plex（仅保存）。
2. 添加 Emby / Jellyfin：
   - 选择服务器类型：Emby / Jellyfin（默认 Emby）。
   - 选择协议：http / https（默认 https）。
   - 填写服务器地址（域名或 IP）。
   - 端口：留空自动 80/443，或手动填写如 8096/8920。
   - 输入账号密码，点击「连接」。未部署扩展线路服务时，只是“线路”页为空，其它功能正常。
3. 添加 WebDAV（只读）：
   - 选择服务器类型：WebDAV。
   - 填写 WebDAV 地址（支持带路径/端口），可选填写账号/密码。
   - 点击「连接并保存」后进入 WebDAV 首页，目录浏览点文件即可播放。
4. 登录 Emby / Jellyfin 后默认进入首页：继续观看、最新电影/剧集；点击卡片可播放（电影/剧集）或下钻（剧集/合集）；从继续观看进入单集详情也可选季/选集快速跳转。
5. 搜索页：首页右上角点「搜索」进入搜索页；搜索框为空时显示历史搜索（前 6 条 +「更多」展开全部）。
6. 媒体库页：显示库海报；点库进入分层列表，可搜索并无限滚动；Episode / Movie 直接播放，Series / Season / Folder 继续下钻。
7. 本地播放器：底部导航「本地」进入，选择本地文件播放。

> Plex：在「连接服务器」页选择 Plex，可用「账号登录（推荐）」走浏览器 PIN 授权并选择服务器；或切换到「手动添加」填写服务器地址/端口（默认 32400）+ Plex Token。当前版本仅保存登录信息，暂不支持浏览/播放。

## WebDAV（只读）说明
- 只支持浏览 + 播放（不支持上传/删除/移动）。
- 为了兼容更多 NAS/服务器的鉴权与 Range 请求，播放时会通过本地回环代理 `127.0.0.1` 转发到真实 WebDAV 地址。
- 若服务器不支持 Range（或被反代/网关禁用），可能无法拖动进度条/仅支持顺序播放。

## 播放器内核（MPV / Exo）

- 默认：MPV（`media_kit`），跨平台可用。
- Android 可选：Exo（Media3 / ExoPlayer，基于 `video_player`），在「设置 → 播放 → 播放器内核」切换。
- Exo 更适合部分杜比视界 P8 片源（在 MPV 下可能出现偏紫/偏绿问题），并默认使用 `VideoViewType.platformView` 渲染。
- Exo 内核支持音轨切换与字幕选择/关闭（本地播放与 Emby 在线播放均支持）。
- 如遇到 Exo/platformView 兼容性或性能问题，可切回 MPV。

### 播放缓冲策略（统一）
设置入口：设置 → 播放 → 播放缓冲大小 / 缓冲策略 / 跳转时清空旧缓冲

- 「播放缓冲大小」是总预算（200-2048MB）：MPV/Exo 都会参考该值（Exo 会按设备内存做安全上限）。
- 「缓冲策略」把总预算拆成「回退缓冲 + 前向缓冲」：回退用于保留已播放内容，前向用于预取后续内容；可选预设或手动调回退比例（0-30%）。
  - 拖动秒开：回退 5% / 前向 95%（默认）
  - 均衡：回退 15% / 前向 85%
  - 稳定优先：回退 25% / 前向 75%
- 「跳转时清空旧缓冲」开启后，快进/快退/拖动进度会优先清掉旧位置缓冲，让新位置更快起播（MPV 会做额外 flush；Exo seek 本身会丢弃旧缓冲）。
- 「不限制视频流缓存」仅影响 MPV 在线播放：会尽量把网络流缓存在磁盘（可能被服务器误判为下载）；可在同页「清理视频流缓存」删除。

## 弹幕（本地 / 在线）

设置入口：设置 → 播放 → 弹幕

### 本地弹幕
- 播放时点击右上角「弹幕」按钮 → 「本地」加载 XML。
- 当前解析器支持 Bilibili 弹幕 XML 格式（常见 `<d p="...">文本</d>`）。

### 在线弹幕（弹弹play）
- 在「设置 → 播放 → 弹幕」中把「弹幕来源」切换为「在线」，并配置一个或多个「弹幕 API URL」（可拖动调整优先级）。
- 默认弹幕源：`https://api.dandanplay.net`
- 重要：使用官方弹弹play源通常需要配置开放平台 `AppId` / `AppSecret`（文档：`https://doc.dandanplay.com/open/`）。
- 播放时会自动尝试匹配并加载；也可以在播放页「弹幕」面板中点击「在线加载」手动触发。

### 样式设置
- 支持：弹幕缩放、透明度、滚动速度、最大行数、粗体。

### 说明与限制
- 本地播放：使用「文件名前 16MB 的 MD5」+ 文件名进行匹配，准确率更高。
- Emby 在线播放：无法获取文件 Hash 时默认仅用标题/文件名匹配，可能需要更准确的命名。
- Web 端暂不支持在线弹幕匹配。
- 目前在线弹幕按「弹弹play API v2」实现；其它弹幕服务器仅当实现了同样的接口（如 `/api/v2/match`、`/api/v2/comment/{episodeId}`）才能直接作为弹幕源使用。
  - 示例（自建/第三方服务）：`https://github.com/huangxd-/danmu_api`、`https://github.com/l429609201/misaka_danmu_server`

## <a id="build"></a>构建与运行

```bash
# 依赖
flutter pub get

# 运行（当前平台）
flutter run

# 生成应用图标（仅当你替换了 assets/app_icon.jpg）
dart run flutter_launcher_icons

# 分析与测试
flutter analyze
flutter test

# Android（含 32 位）
flutter build apk --split-per-abi

# Windows
flutter build windows --release

# macOS
flutter build macos --release

# iOS（无签名）
flutter build ios --release --no-codesign

# Linux
flutter build linux --release
```

> Windows 本地构建如果提示 “Building with plugins requires symlink support”，请先在系统设置中开启「开发者模式」。

## 应用名称与图标

### 名称（为什么会看到 `lin_player`）
- `pubspec.yaml` 的 `name: lin_player` 是 **Flutter/Dart 包名**（依赖导入、构建目录等会用到），不等同于各平台桌面/桌面图标上显示的应用名。
- 各平台“展示名 / 窗口标题”在平台工程里配置，例如：
  - Android：`android/app/src/main/AndroidManifest.xml`（`android:label`）
  - iOS：`ios/Runner/Info.plist`（`CFBundleDisplayName`）
  - macOS：`macos/Runner/Configs/AppInfo.xcconfig`（`PRODUCT_NAME`）
  - Windows：`windows/CMakeLists.txt`（`BINARY_NAME`）与 `windows/runner/main.cpp`（窗口标题）
  - Linux：`linux/runner/my_application.cc`（窗口标题）

### 图标
- 图标源文件：`assets/app_icon.jpg`（建议至少 1024×1024）。
- 生成各平台图标：`dart run flutter_launcher_icons`（见 `assets/README.md`）。
- CI（GitHub Actions）构建前会自动生成图标；如果你在本地替换了图标，建议同样运行一次以保证仓库内各平台图标文件同步。

## CI / 发布（GitHub Actions）
- Nightly 构建：`.github/workflows/build-all.yml`
  - 手动触发（`workflow_dispatch`），需要输入 `build_name` 与 `build_number`。
  - 产物会上传到 GitHub Release 的 `nightly`（覆盖同名资产）。
- 稳定版发布：`.github/workflows/release-latest.yml`
  - 将 `nightly` 的产物“提升”为 `latest`。
  - 如果 nightly 的资产文件名与预期不同（例如 Android 可能是 `app-release.apk`），工作流会自动兼容并上传到 `latest`。

## 源码导览
- 目录结构、核心模块、Emby 接口与播放链路：`docs/ARCHITECTURE.md`

## UI 自适应（开发者）
- 全局缩放逻辑在 `lib/src/ui/ui_scale.dart`；应用入口通过 `MaterialApp.builder` 统一应用缩放（文本/图标/部分组件尺寸）。
- 如果你新增了包含“固定尺寸”的页面（尤其是 `GridView` 的 `maxCrossAxisExtent`），建议显式乘上 `context.uiScale`，避免竖屏/小屏出现卡片过小。

## 自定义 mpv 参数（进阶）
- 工程内已内置 `packages/media_kit_patched`，在 `pubspec.yaml` 通过 `dependency_overrides` 覆盖原包。
- `PlayerConfiguration` 新增 `extraMpvOptions` 列表，可直接传入 mpv 的原生参数（形如 `key=value`，无 `=` 时默认视为 `key=yes`）。示例：
  ```dart
  PlayerConfiguration(
    extraMpvOptions: [
      'gpu-context=d3d11',
      'hwdec=auto-safe',
      'video-sync=audio',
      'scale=lanczos',
    ],
  )
  ```
- TV 和桌面可按需分别传入不同配置，现有播放器创建处已支持该字段。
- 播放页右上角提供“硬解/软解”切换，切换后会重新初始化播放器并应用 `hwdec` 参数。

## 常见问题
- DNS 解析失败 / Host lookup：请确认域名在设备浏览器可访问；必要时改填 IP 或切换 http/端口（如 8096/8920）。
- 电影或剧集 404：已使用 MediaSourceId 的播放 URL；若仍异常，请确认服务器对应条目可在网页端播放。
- 线路列表为空：未部署 `emby_ext_domains` 时属正常，不影响媒体库与播放。

## 目录导航
- `lib/main.dart` 应用入口（初始化、主题、路由）
- `lib/server_page.dart` 服务器管理/登录入口
- `lib/home_page.dart` 首页（继续观看、最新电影/剧集）
- `lib/search_page.dart` 搜索页（历史搜索/搜索结果）
- `lib/webdav_home_page.dart` WebDAV 首页（WebDAV / 本地 / 设置）
- `lib/webdav_browser_page.dart` WebDAV 浏览页（目录列表/点播入口）
- `lib/library_page.dart` 媒体库列表
- `lib/library_items_page.dart` 分层/搜索/播放列表
- `lib/show_detail_page.dart` 详情页（Series/Season/Episode；单集详情含选季/选集与同剧剧集栏）
- `lib/danmaku_settings_page.dart` 弹幕设置页（本地/在线、样式、在线源管理）
- `lib/play_network_page.dart` Emby 在线播放
- `lib/player_screen.dart` 本地播放器
- `lib/player_service.dart` 播放器封装（mpv 参数、硬解/软解）
- `lib/services/emby_api.dart` Emby API 封装
- `lib/services/webdav_api.dart` WebDAV API（PROPFIND/鉴权解析）
- `lib/services/webdav_proxy.dart` WebDAV 本地回环代理（Range 转发）
- `lib/services/plex_api.dart` Plex PIN 登录/资源列表 API 封装
- `lib/services/dandanplay_api.dart` 在线弹幕（弹弹play API v2）封装
- `lib/src/player/danmaku.dart` 弹幕解析（本地 XML / 在线列表）
- `lib/src/player/danmaku_stage.dart` 弹幕渲染（覆盖层）
- `lib/state/app_state.dart` 状态/登录/缓存

## 鸣谢与参考

### 引用 / 上游
- Anime4K：https://github.com/bloc97/Anime4K（本项目内置部分 GLSL shader：`assets/shaders/anime4k/`，用于 MPV 内核的 Anime4K 预设）

### 参考 / 灵感
- Playboy Player：https://github.com/Playboy-Player/Playboy
- NipaPlay Reload：https://github.com/MCDFsteve/NipaPlay-Reload

### 可配合使用的服务
- Emby 扩展线路：`emby_ext_domains`（参考/服务实现：`https://github.com/uhdnow/emby_ext_domains`）
- 在线弹幕兼容服务：`https://github.com/huangxd-/danmu_api`、`https://github.com/l429609201/misaka_danmu_server`

### 文档
- Emby 项目与文档：https://dev.emby.media/doc/restapi/index.html
- Jellyfin API 文档：https://api.jellyfin.org/
- Plex 开发者文档：https://developer.plex.tv/pms/
