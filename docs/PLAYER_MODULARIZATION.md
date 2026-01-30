# 播放器模块化指南（WIP）

目标：在**保证播放稳定/流畅**的前提下，把“播放内核/网络后端/功能特性”拆成可组合模块，避免在 UI 页面里堆满逻辑，方便：

- 以后适配不同播放内核（MPV / Exo / 其他）。
- 以后适配不同“网络播放后端”（Emby/Jellyfin/…）。
- 开发者在不改核心代码的情况下叠加功能（以模块/类的形式复用）。

> 说明：当前仓库是“逐步拆分”的过程，老页面仍然存在，但会不断把公共能力下沉到 `lib/src/player/**`。

---

## 1. 现有的“底层能力”拆分点

### 1.1 UI 共享工具

- `lib/src/player/shared/player_types.dart`
  - 时间格式化：`formatClock(...)`
  - seek 目标裁剪：`safeSeekTarget(...)`
  - UI 状态枚举：`OrientationMode` / `GestureMode`
- `lib/src/player/shared/system_ui.dart`
  - 统一判断是否支持系统 UI 控制：`canControlSystemUi(...)`
  - 进入/退出沉浸模式：`enterImmersiveMode(...)` / `exitImmersiveMode(...)`

### 1.2 网络播放后端抽象（Network Backend）

- `lib/src/player/network/network_playback_backend.dart`
  - `NetworkPlaybackBackend`：负责把“业务 itemId + 用户偏好”解析为：
    - 可播放 URL（`streamUrl`）
    - HTTP headers（`httpHeaders`）
    - 可选的版本列表（`mediaSources`，用于“切换版本/清晰度”UI）
    - 可选的会话信息（`playSessionId/mediaSourceId`，用于播放上报）
  - `EmbyLikeNetworkPlaybackBackend`：当前默认实现（Emby/Jellyfin）。
- `lib/src/player/network/emby_stream_resolver.dart`
  - Emby/Jellyfin 的 playbackInfo + mediaSource 选择逻辑：`resolveEmbyStreamUrl(...)`
- `lib/src/player/network/emby_http_headers.dart`
  - Emby/Jellyfin 鉴权 headers：`buildEmbyHeaders(...)`

### 1.3 播放上报（Network Reporting）

- `lib/src/player/network/network_playback_reporter.dart`
  - `NetworkPlaybackReporter`：把 start/progress/stop + updatePosition 做节流封装，页面只需提供 position/duration/paused。

---

## 2. 如何新增一个“网络播放后端”

以“非 Emby-like 的媒体服务”为例，你需要实现 `NetworkPlaybackBackend`：

1. 新建文件，例如：`lib/src/player/network/xxx_network_backend.dart`
2. 实现：
   - `resolveStream(...) -> NetworkStreamResolution`
   - 返回 `streamUrl` + `httpHeaders`
   - 若你的后端支持“多版本/多清晰度”，把版本列表映射为 `mediaSources`（结构可自定义，但需要 UI 能渲染标题/副标题）。
3. 在页面里注入：
   - `PlayNetworkPage(playbackBackend: YourBackend(...))`
   - `ExoPlayNetworkPage(playbackBackend: YourBackend(...))`

> 当前默认：页面会在 `playbackBackend == null` 时使用 `EmbyLikeNetworkPlaybackBackend`。

---

## 3. 下一步拆分建议（路线）

为了把“大页面”彻底拆开，推荐按顺序做：

1. **播放内核抽象**：把 MPV(media_kit) 与 Exo(video_player) 的差异封装成统一接口（open/play/pause/seek/state streams）。
2. **功能模块化**：把弹幕/手势/字幕样式/缩略图/倍速/选集/切核等拆成 `Feature`（模块挂载到一个 Player Host 上）。
3. **页面瘦身**：`PlayerHost` 只负责布局（视频层 + overlays + controls），所有能力都来自模块。

