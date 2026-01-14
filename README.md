# LinPlayer

跨平台（Windows / macOS / Linux / Android / Android TV）本地与 Emby 媒体播放器。支持继续观看、最新电影/剧集推荐、媒体库分层浏览、在线播放与本地播放。

## 特性
- 登录 Emby：支持 http/https 与自定义端口；未部署扩展线路服务也能正常使用（线路列表为空但播放/浏览可用）。
- 首页（类似 Emby）：继续观看 / 最新电影 / 最新剧集 横向卡片流，点击即播或进入详情。
- 媒体库浏览：库 → Series/Season → Episode，电影直接播放；搜索框+无限下拉懒加载，防内存暴涨。
- 封面与简介：库/剧集/季/集均展示海报和概要。播放链接自动携带 MediaSourceId，避免 404。
- 双主题：Material 3，跟随系统明/暗色；桌面/手机卡片带轻量毛玻璃；Android TV 自动关闭毛玻璃，使用简洁卡片防卡顿。
- 本地播放器：原生文件选择与播放功能保留。
- 构建：Android 同时支持 32 位和 64 位；Windows 打包附带运行时与 DLL。

## 快速上手
1. 启动应用，进入「连接服务器」页：
   - 选择协议：http / https（默认 https）。
   - 填写服务器地址（域名或 IP）。
   - 端口：留空自动 80/443，或手动填写如 8096/8920。
   - 输入账号密码，点击「连接」。未部署扩展线路服务时，只是“线路”页为空，其它功能正常。
2. 登录后默认进入首页：继续观看、最新电影/剧集；点击卡片可播放（电影/剧集）或下钻（剧集/合集）。
3. 媒体库页：显示库海报；点库进入分层列表，可搜索并无限滚动；Episode / Movie 直接播放，Series / Season / Folder 继续下钻。
4. 本地播放器：底部导航「本地」进入，选择本地文件播放。

## 构建与运行
```bash
# 依赖
flutter pub get

# 生成应用图标（仅当你替换了 assets/app_icon.jpg）
dart run flutter_launcher_icons

# 分析与测试
flutter analyze
flutter test

# Android（含 32 位）
flutter build apk --split-per-abi

# Windows
flutter build windows --release
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
- `lib/library_page.dart` 媒体库列表
- `lib/library_items_page.dart` 分层/搜索/播放列表
- `lib/show_detail_page.dart` 详情页（季/集、相似推荐、播放入口）
- `lib/play_network_page.dart` Emby 在线播放
- `lib/player_screen.dart` 本地播放器
- `lib/player_service.dart` 播放器封装（mpv 参数、硬解/软解）
- `lib/services/emby_api.dart` Emby API 封装
- `lib/state/app_state.dart` 状态/登录/缓存

## 鸣谢
- Emby 项目与文档：https://dev.emby.media/doc/restapi/index.html
