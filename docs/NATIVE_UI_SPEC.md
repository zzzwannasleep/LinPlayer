# 桌面播放页 UI 施工清单（用于 mpv Lua 1:1 复刻）

> **⚠️ 这个方案没有采用（2026-07-26 复核）。**
>
> 「让 mpv 用 Lua 自绘播放页 UI」是原生渲染改造期间评估过的一条路，**最终没走**。
> 现在的做法是：mpv 只画视频，UI 全部由**透明 Tauri 窗口里的 React** 承担
> （见 [NATIVE_RENDERING.md](NATIVE_RENDERING.md)）。文中的 Flutter↔Lua 桥、
> `user-data/linplayer/*` 约定、`lib/**` 路径**全部不存在**。
>
> 留档只为一件事：**它逐条列出了桌面播放页当年有哪些交互**，可当功能对照表用。
>
> 原生渲染 v2：mpv 自绘 UI（自研 Lua，非 uosc），复刻现有桌面播放页。
> Flutter↔Lua 桥：Lua 写 `user-data/linplayer/cmd` → Dart 轮询执行 → 清空；
> Dart 写 `user-data/linplayer/<key>`(JSON) → Lua observe 读取刷新菜单。
> 所有动作最终落到 `_playerService`(VideoPlayerService) 或 Riverpod provider。
> 源：`lib/desktop/screens/player/desktop_player_screen_state.dart`（除非另注）。

## A. 顶栏 `_buildTopBar` (:3652)
1. 返回 `arrow_back` → `_handleExit` (:1740)：还原窗口外壳+两段 pop。
2. 标题 `_MarqueeText` = `_displayTitle`/`item.name`/itemId。
3. Anime4K `hd`（isMpv，亮色=非 off）→ `_showAnime4KMenu`。
4. 跳过片头设置 `skip_next` → `_showSkipDialog` (:4033)。
5. 硬解开关 `memory`/`slow_motion_video` → `_toggleHardwareDecoding` (:4061，重建 service)。
6. 更多 `more_vert` → `_showMoreMenu` (:2098)。

## B. 底栏
### 进度条 `_buildProgressBar` (:3715)
`[当前]  [Slider]  [总]`；时间 `_formatDuration` HH:MM:SS/MM:SS；显示已缓冲(secondaryTrackValue=bufferedProgress)；拖动预览+`onChangeEnd → seekTo`。活动色 0xFF5B8DEF。
### 按钮行 `_buildBottomBar` (:3803)
- 左 音量 `_buildVolumeControl` (:3821)：图标 volume_off/down/up → `_toggleMute`；悬停出 100px 滑块 → `setVolume`。
- 中 `_buildPlaybackControls` (:3872)：上一集 `skip_previous`→`_playPrevious`(:1937)；播放/暂停 48px 圆(hourglass/pause/play)→`togglePlay`；下一集 `skip_next`→`_playNext`(:1969)。
- 右 `_buildFunctionControls` (:3918)：弹幕 PopupMenu(toggle/搜索`_openDanmakuSearch`/设置`_openDanmakuSettings`)；字幕 `subtitles`→`_showSubtitleSelector`；音轨 `audiotrack`→`_showAudioSelector`；全屏 `fullscreen`→`_toggleFullscreen`；选集 `playlist_play`(有 seriesId)→`_showEpisodeSelector`。

## C. 侧边浮动 `_buildControlsOverlay` (:3491)
- 左列：截图 `camera_alt`→`_takeScreenshot`(:1842)；锁定 `lock`→`toggleLock`。
- 右列 速度簇：`add` 加速(tap+0.25/长按+0.05)；速度文字；`remove` 减速。

## D. 其它叠加
- 跳过片头按钮(:3438) `_onSkipOpeningPressed`；Intro/Outro 自动跳(:3594) `_onIntroSkipPressed`；源画质(:3473) `SourceQualityButton`→`_switchSourceQuality`；锁定指示(:3462)。

## E. 设置面板（`showPlayerSettingsPanel`，右侧栏≤1/3）
1. Anime4K `_showAnime4KMenu`(:2003)：静态 7 档(off/modeA/B/C/AA/BB/AC)→`anime4KLevelProvider`+`applySuperResolutionLevel`。SW纹理仅存+下次生效。链在 `anime4k_shaders.dart kAnime4KShaderPresets`(:27)。
2. 字幕 `_showSubtitleSelector`(:2274)→`_showTrackSelectorDialog`(:2677)：动态 `_subtitleStreamsFromCurrentSource`(:755)。顶部动作：翻译字幕/停止/Whisper。选→`subtitleTrackProvider`→监听器(:105)`_onSubtitleSelectionChanged`→`selectSubtitleTrack`。
3. 次字幕 `_showSecondarySubtitleSelector`(:2323，isMpv)→`secondarySubtitleTrackProvider`→`selectSecondarySubtitleTrack`。
4. 音轨 `_showAudioSelector`(:2301)：动态 `_audioStreamsFromCurrentSource`(:748)→`audioTrackProvider`→`_applyAudioStreamSelection`→`selectAudioTrack`。
5. 画面比例 `_showAspectRatioDialog`(:2212)：静态 自动/16:9/4:3/21:9/全屏/原始→`aspectRatioProvider`+`setAspectRatio`。
6. 选集 `_showEpisodeSelector`(:2238)：动态 `episodesProvider((seriesId,null))`；切集=`context.replace('/player/{id}?mediaSourceId=...')`。
7. 更多 `_showMoreMenu`(:2098)：截图/字幕/次字幕/音轨/选集/画面比例/硬解/Anime4K/零拷贝/原生渲染/统计/全屏。
8. 跳过片头设置 `_showSkipDialog`(:4033)：开始/结束秒 + 自动跳开关。
9. 选翻译字幕轨 `_pickStreamToTranslate`(:2500)。
10. 源画质：bottom sheet(SourceQualityButton)。

## F. 键盘 `_handleKeyEvent` (:1557)
Esc 退全屏/返回；Space/K 播放暂停；←/→ ∓15s(Shift 60)；J/L ∓15s；↑/↓ 音量±0.05；[/] 速度∓0.25；Backspace 速度1.0；F 全屏；S 循环字幕；A 循环音轨；M 静音；N 切原生(Win)；0-6 超分档(`_superresDigitLevels` :1662)；Ctrl+H 控件显隐；Ctrl+S 截图。鼠标：滚轮音量；点左25%−15/右25%+15/中间 togglePlay；双击全屏。

## G. 状态显示
缓冲(全屏暗幕+转圈+「正在缓冲…」)；错误(`friendlyPlaybackError`+重试)；统计OSD(:3397，`_buildStatsRows`:2760，文件/大小/分辨率/帧率/码率/编码/像素/音频/硬解/速度)；流式翻译(bottom:72 双语)；弹幕层；标题=`_displayTitle`。

## H. 数据来源
- item=`currentPlayingItemProvider`(name/seriesId/seasonId/indexNumber/cover)。
- 剧集=`episodesProvider`；prev/next=`_playPrevious`/`_playNext` 走 `context.replace`。
- 轨道两层：服务端 `_currentMediaSource.mediaStreams`(菜单，index 为键) + 运行时 `_playerService.tracksInfo`(mpv 轨)；`_matchAudioTrackId`(:1040)/`_matchSubtitleTrackId`(:1087) 映射→`select*Track`；外挂/位图下载后 loadLibass。选择流经 provider→initState 监听器(:92-121)落到播放器。
- 超分 6 档在 `anime4k_shaders.dart`(:27)；`applySuperResolutionLevel` 解析路径喂 glsl-shaders，仅硬件纹理实时。

## 桥接实现要点
- C++ 已做：鼠标转发(WndProc→mpv mouse/keydown MBTN)，config-dir 指 exe/mpv-config，脚本自加载。
- 待做 Dart：轮询 `user-data/linplayer/cmd` 执行动作；把 item/tracks/episodes/superres 状态写 `user-data/linplayer/*` 给 Lua。
- 待做 Lua：控制栏(A/B/C) + 菜单(E) + 键盘(F 部分可留 Flutter) + 状态(G)；osc=no 顶替内置。
