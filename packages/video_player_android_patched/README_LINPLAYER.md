# LinPlayer 补丁说明（`video_player_android_patched`）

该目录是对 Flutter 官方包 `video_player_android` 的 **本地改造版本**（目前基于 `2.9.1`），用于 LinPlayer 的 **Exo 播放内核（Android）**。

## 目标

- 在 Exo 内核下支持 **字幕轨道枚举 / 选择 / 关闭**（类似 MPV 的字幕切换体验）。
- 在 `VideoViewType.platformView` 渲染模式下，把 ExoPlayer 的字幕 cue **直接叠到画面上显示**。
- 避免 App 侧直接 `import package:video_player_android/src/...`（触发 `implementation_imports`），提供稳定的导出入口。

## 做了哪些改动？

### 1) 新增字幕相关的 Pigeon API（Dart ⇄ Android）

改动文件：
- `pigeons/messages.dart`

新增：
- `getSubtitleTracks()`：获取字幕轨道列表
- `selectSubtitleTrack(groupIndex, trackIndex)`：选择字幕轨道
- `deselectSubtitleTrack()`：关闭字幕

生成文件（由 Pigeon 生成，不建议手改）：
- `lib/src/messages.g.dart`
- `android/src/main/kotlin/io/flutter/plugins/videoplayer/Messages.kt`

### 2) Android 侧实现字幕轨道选择

改动文件：
- `android/src/main/java/io/flutter/plugins/videoplayer/VideoPlayer.java`

要点：
- 使用 Media3 `Tracks` 枚举 `C.TRACK_TYPE_TEXT` 轨道。
- 通过 `DefaultTrackSelector` 的 override + `setTrackTypeDisabled` 实现选择/关闭字幕。

### 3) platformView 模式字幕渲染

改动文件：
- `android/src/main/java/io/flutter/plugins/videoplayer/platformview/PlatformVideoView.java`

要点：
- 使用 `FrameLayout` 包裹 `SurfaceView`。
- 监听 `Player.Listener.onCues`，把 cue 文本写入底部 `TextView`，从而在 platformView 模式也能显示字幕。

### 4) 对外导出（给 App 调用）

新增文件：
- `lib/exo_tracks.dart`

用途：
- 统一导出 Pigeon 生成的字幕相关类型与 `VideoPlayerInstanceApi`，避免 App 侧依赖 `lib/src`。

## 如何重新生成 Pigeon 代码？

在仓库根目录执行：

```bash
cd packages/video_player_android_patched
dart pub get
dart run pigeon --input pigeons/messages.dart
```

## 如何升级到新的 `video_player_android` 版本？

建议流程：
1. 用新版本的 `video_player_android` 覆盖该目录（保留本文件）。
2. 重新应用上述改动（Pigeon + Java）。
3. 重新生成 Pigeon 代码。
4. 在仓库根目录验证：`flutter test`、`flutter build apk --debug`。

## 备注

- 音轨切换使用 `video_player_platform_interface` 的 `getAudioTracks/selectAudioTrack`（Android 官方已支持）。
- Exo 内核仅在 Android 可用；其它平台依旧使用 MPV（`media_kit`）。
