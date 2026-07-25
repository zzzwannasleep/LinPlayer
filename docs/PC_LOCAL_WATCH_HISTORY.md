# LinPlayer PC 端本地观看记录设计文档

> 状态：方案收敛，待实现  
> 目标：为 Windows / macOS / Linux 桌面端补充本地观看记录能力，解决 Emby 记录缺失、删库重扫后 `itemId` 变化导致的历史丢失，以及外部 MPV 绕过应用内播放上报的问题。

## 一、背景

当前桌面端已经有一部分观看记录能力，但它主要依赖 Emby 服务端：

- 内置桌面播放器已经会读取 `userData.playbackPositionTicks` 做续播，并向 Emby 上报开始、进度、停止。
- 桌面首页“继续观看”直接读取 Emby 的 `/Users/{UserId}/Items/Resume`。
- 外部 MPV 当前由桌面详情页直接 `Process.start(..., detached)` 拉起，没有可靠的会话跟踪和进度回传。
- 当前 `MediaItem` 模型里还没有完整承接跨重扫更稳定的标识字段，例如 `ProviderIds`、`PresentationUniqueKey`、媒体路径等。

这意味着现在的桌面端有两个明显空白：

1. 外部 MPV 会绕过应用内播放上报链路。
2. Emby 删库重扫后，如果同一内容被重新识别成新的 `itemId`，旧观看记录可能丢失。

因此，本方案不是替换 Emby，而是在 Emby 之上补一层“本地观看记录 + 本地恢复回填”。

## 二、目标与非目标

### 2.1 目标

- 补充 Emby 的观看记录能力，而不是自建一套完全独立的历史系统。
- 为每个媒体项建立尽量稳定、跨重扫仍可识别的本地身份。
- 在 Emby 记录缺失时，将本地观看记录恢复回 Emby。
- 覆盖桌面内置播放器与外部 MPV 两条播放路径。
- 支持 Windows、macOS、Linux 三端桌面。
- 将恢复提示限制在首页，避免在详情页、播放页、列表页打扰用户。

### 2.2 非目标

- 第一阶段不做单独的“本地观看历史列表页”。
- 不记录用户自行在系统里单独启动的 MPV 进程。
- 不把海报、简介、演员等展示性字段塞进本地历史文件。
- 不在首页之外的页面弹恢复提示。

## 三、已确认的产品决策

### 3.1 功能定位

- 本地观看记录的定位是“补 Emby 的空白”，不是“替换 Emby”。

### 3.2 记录粒度

- 电影按单条记录保存。
- 剧集按单集保存，不按整剧保存。
- 剧集恢复优先按 `series tmdbId + seasonNumber + episodeNumber` 识别。

### 3.3 存储方式

- 不使用 `SharedPreferences` 直接存整份历史。
- 使用独立 JSON 文件持久化，建议文件名为 `watch_history.json`。
- 文件放在应用数据目录中，后续可接入导出、备份、WebDAV 同步。

### 3.4 隔离维度

- 本地记录至少按 `serverId + userId` 分桶。
- 不允许不同服务器、不同账号共享同一份观看记录。

### 3.5 匹配与恢复策略

- 强匹配：自动恢复，不提示。
- 可能匹配：只在首页提示用户处理。
- 弱匹配：不恢复。
- 原则是“宁可漏恢复，也不要串记录”。

### 3.6 提示与交互

- 恢复提示只在首页出现。
- 一次只展示 1 条候选，不做长列表轰炸。
- 交互按钮为：`恢复` / `跳过` / `不要记录`。
- `跳过`：本次启动内不再提示，下次启动再提示。
- `不要记录`：只删除当前这条旧记录，不做永久拉黑。

### 3.7 写入时机

- 周期保存：每 `10-15s` 保存一次本地进度。
- 事件保存：`暂停`、`停止`、`切集`、`播放完成` 时立刻保存。
- 退出兜底：窗口关闭、页面 `dispose`、应用生命周期离开前强制保存一次。

### 3.8 已看阈值

- 已看判定阈值做成播放器设置项。
- 范围：`75%-95%`。
- 默认值：`90%`。
- 放在播放器设置里的“播放行为”下。

### 3.9 范围

- 第一阶段包含外部 MPV。
- 第一阶段覆盖 Windows、macOS、Linux 三端桌面。

## 四、当前代码现状

以下现状会直接影响实现方式：

- `apps/desktop/src/lib.rs` + `ui/desktop/` (Tauri 壳 + React 前端)
  - 桌面内置播放器已经会根据 `resume_secs` 字段做续播(emby.rs 层回传)。
  - 也已经通过 `play / reportProgress / reportStopped` 命令向 Emby 上报播放状态(lib.rs 的 #[tauri::command])。

- `ui/shared/api.ts`
  - `listResume()` 直接读 Emby 的续播列表(核层 /Users/{UserId}/Items/Resume)。

- `ui/desktop/pages/HomePage.tsx`
  - 首页在初始化、恢复前台时会刷新 `listResume()` 等首页摘要数据。
  - 这里很适合作为“恢复扫描”的触发入口。

- `ui/desktop/pages/DetailPage.tsx` + `apps/desktop/src/lib.rs`
  - 外部 MPV 当前由前端通过 `play_external()` 命令拉起(Tauri invoke)。
  - 实现在 `apps/desktop/src/lib.rs` 中,目前只传 `--start` 和播放地址,没有 IPC、没有进度跟踪、没有会话回传。

- `ui/shared/api.ts` (类型 Item)
  - 当前 `Item` 已承接标题、年份、剧集号、用户播放进度等字段。
  - 已补进跨重扫关键字段: `provider_ids`、`presentation_unique_key`、`path`、`series_id`。

- `crates/core/src/emby.rs`
  - 已存在 Emby 播放状态上报能力(Sessions/Playing/Progress/Stopped 端点)。
  - 已存在 `setPlayed()` / 标记已看能力。

- `crates/core/src/config.rs` (Prefs 结构体)
  - 已有偏好持久化体系(Prefs 字段),适合直接承接”已看阈值”等新增播放偏好。
  - UI 层通过 `ui/shared/api.ts` 中的 `getPrefs/setPrefs` 命令与核层通信。

## 五、总体方案

### 5.1 核心原则

本方案分成两条主线：

1. 本地记录主线  
   在桌面播放链路中持续写入一份本地观看记录，确保即使 Emby 暂时不可用、或者后续重扫改了 `itemId`，本地仍保留观看事实。

2. 恢复回填主线  
   在桌面首页启动或刷新时，扫描当前用户的本地历史，并尝试把可确认的记录恢复回 Emby。

### 5.2 本地记录不是“另一个首页”

本地观看记录的职责只有两个：

- 保存足够恢复历史的最小必要信息。
- 在 Emby 缺失时帮助恢复播放进度或已看状态。

它不负责替代 Emby 的“继续观看”产品体验，也不负责成为第一阶段的独立历史中心。

## 六、数据模型

### 6.1 文件位置

- 建议路径：应用数据目录下的 `watch_history.json`
- 建议通过 `path_provider` 获取目录
- 建议保留 `schemaVersion`，为后续字段扩展和迁移留口

### 6.2 顶层结构

```json
{
  "schemaVersion": 1,
  "updatedAt": "2026-06-14T00:00:00Z",
  "records": []
}
```

### 6.3 单条记录字段

在讨论稿基础上，建议每条记录至少包含以下字段：

| 字段 | 说明 |
| --- | --- |
| `recordId` | 本地记录唯一 ID，工程字段 |
| `scopeKey` | `serverId:userId` |
| `mediaKind` | `movie` / `episode` |
| `canonicalKey` | 本地稳定身份键 |
| `tmdbId` | 电影或条目级 TMDB ID |
| `seriesTmdbId` | 剧集所属剧的 TMDB ID，剧集恢复时建议单独保存 |
| `title` | 标题 |
| `seriesTitle` | 剧名 |
| `seasonNumber` | 季号 |
| `episodeNumber` | 集号 |
| `year` | 年份 |
| `lastPositionTicks` | 最后播放位置 |
| `played` | 是否已看完 |
| `playCount` | 播放次数 |
| `lastPlayedAt` | 最后观看时间 |
| `lastEmbyItemId` | 最近一次对应的 Emby `itemId` |
| `matchConfidence` | 最近一次匹配置信度 |
| `restoredAt` | 最近一次恢复回填时间 |
| `lastWriteSource` | `internal_player` / `external_mpv`，工程字段 |

### 6.4 示例

```json
{
  "recordId": "serverA:userA:episode:series-12345-s01e03",
  "scopeKey": "serverA:userA",
  "mediaKind": "episode",
  "canonicalKey": "series:tmdb:12345:s01:e03",
  "tmdbId": null,
  "seriesTmdbId": "12345",
  "title": "第 3 集",
  "seriesTitle": "某剧",
  "seasonNumber": 1,
  "episodeNumber": 3,
  "year": 2024,
  "lastPositionTicks": 6543000000,
  "played": false,
  "playCount": 1,
  "lastPlayedAt": "2026-06-14T09:30:00Z",
  "lastEmbyItemId": "old-item-id",
  "matchConfidence": "strong",
  "restoredAt": null,
  "lastWriteSource": "external_mpv"
}
```

## 七、稳定身份与匹配规则

### 7.1 为什么需要稳定身份

真正要跨重扫恢复的不是“某个 Emby `itemId`”，而是“同一部电影 / 同一集内容本身”。

因此本地记录必须围绕“内容身份”建模，而不是围绕“当前服务器里这一次扫描出来的条目 ID”建模。

### 7.2 需要补强的 Emby 字段

当前模型不足以稳定完成跨重扫恢复，建议在 `MediaItem` 解析中补进这些字段：

- `ProviderIds`
- `PresentationUniqueKey`
- 媒体路径相关字段
- 如有必要，补进更完整的剧集关联字段

其中：

- `ProviderIds.Tmdb` 是首选内容身份信号。
- `PresentationUniqueKey` 可作为次强信号。
- 路径只适合作为辅助信号，不适合作为跨洗版、跨改名后的主键。

### 7.3 `canonicalKey` 生成建议

电影建议优先级：

1. `movie:tmdb:{tmdbId}`
2. `movie:puk:{presentationUniqueKey}`
3. `movie:title:{normalizedTitle}:year:{year}`

剧集建议优先级：

1. `series:tmdb:{seriesTmdbId}:s{season}:e{episode}`
2. `episode:tmdb:{tmdbId}:s{season}:e{episode}`
3. `episode:puk:{presentationUniqueKey}`
4. `episode:title:{normalizedSeriesTitle}:s{season}:e{episode}`

说明：

- 标题归一化建议去掉分隔符、大小写差异、常见版本噪音。
- 路径可以提高置信度，但不要作为唯一自动恢复依据。

### 7.4 匹配分档

#### 强匹配

- 电影：`tmdbId` 一致，且规范化标题一致。
- 剧集：`seriesTmdbId` 一致，且 `seasonNumber + episodeNumber` 一致。
- `PresentationUniqueKey` 完全一致时也可直接作为强匹配辅助。

行为：

- 自动恢复。
- 不提示用户。

#### 可能匹配

- 没有 `tmdbId`，但只有唯一候选。
- 标题高度相似，且年份或剧集位置信息能辅助收敛。

行为：

- 进入首页提示队列。
- 一次只提示一条。

#### 弱匹配

- 只有标题像。
- 候选不唯一。
- 关键信息冲突。

行为：

- 不恢复。
- 不提示。

## 八、本地写入方案

### 8.1 内置播放器

直接复用桌面播放器现有生命周期：

- `onStart`
- `onProgress`
- `onStop`

在现有上报 Emby 的同时，新增本地写入：

- 启播后建立或更新本地记录。
- 每 `10-15s` 刷新 `lastPositionTicks`。
- 暂停、停止、切集、播放完成时立即写入。
- 页面释放和应用离开前补一次兜底写入。

### 8.2 外部 MPV

外部 MPV 第一阶段也纳入方案，但不能继续沿用“纯 detached 启动”。

建议改为：

- LinPlayer 启动 MPV 时生成 `sessionId`
- 启动参数中附带官方 `mpv JSON IPC` 地址
- LinPlayer 维护这一会话的生命周期与进度采样

建议能力拆分为：

- `ExternalPlayerSessionService`
- `MpvIpcBridge`
- `WatchHistoryStore`

其中：

- Windows 走命名管道
- macOS / Linux 走 Unix socket
- Dart 业务层只依赖统一桥接接口，不直接耦合平台细节

### 8.3 外部 MPV 记录边界

当前文档采用默认建议：

- 只记录由 LinPlayer 拉起的外部 MPV 会话。
- 不追踪用户自行在系统中打开的 MPV 进程。

这是一个合理默认，但它仍属于“待最终确认”的边界项。

### 8.4 IPC 不可用时的降级策略

如果 MPV 启动成功但 IPC 建连失败：

- 不伪造进度记录。
- 只记录一次“会话启动失败”的日志。
- 不写入不可靠的恢复数据。

原则仍然是：宁可少记，也不要写脏数据。

## 九、恢复回填方案

### 9.1 触发时机

恢复扫描只在桌面首页触发：

- 首页首次进入
- 首页手动刷新
- 应用从后台回到前台后刷新首页

不在详情页、播放页、列表页后台偷偷触发。

### 9.2 扫描方式

恢复扫描不能只依赖“首页当前可见的那些条目”，否则很多历史永远撞不上。

因此建议流程是：

1. 读取当前 `scopeKey` 下的本地记录
2. 按 `lastPlayedAt` 倒序扫描
3. 主动向 Emby 查询候选条目
4. 对候选条目做匹配分档
5. 根据分档决定自动恢复、加入首页提示队列或忽略

候选查询可优先复用现有搜索能力，再按类型、年份、剧集信息做二次过滤。

### 9.3 恢复回填策略

#### 已看状态恢复

- 对 `played = true` 的记录，优先调用现有 `markAsPlayed`。

#### 进度恢复

- 对 `played = false` 且有有效 `lastPositionTicks` 的记录，调用现有播放状态回填链路。
- 建议实现上按“开始 -> 进度/停止”方式回填，而不是直接改本地 UI。

说明：

- 这里需要实测确认 Emby 对“非真实播放会话”的回填接受度。
- 若只调用 `Stopped` 不稳定，应补一轮 `Start + Progress + Stopped`。

### 9.4 恢复成功后的行为

- 更新本地记录的 `lastEmbyItemId`
- 写入 `restoredAt`
- 更新 `matchConfidence`
- 重新刷新 `resumeItemsProvider`

## 十、首页提示方案

### 10.1 形态

- 不做首页卡片。
- 不做列表轰炸。
- 做成首页顶部浮出的轻量提示，视觉上像 toast，但可以承载三个操作。

### 10.2 展示规则

- 只在首页展示。
- 一次只展示 1 条。
- 多条候选顺序处理。

### 10.3 文案信息

建议最少展示：

- 标题
- 旧进度或“已看完”
- 匹配依据，例如“标题 + TMDB 匹配”

### 10.4 操作语义

- `恢复`：立即回填 Emby，并处理下一条。
- `跳过`：本次启动内不再提示这条记录，下次启动再提示。
- `不要记录`：删除这条本地记录，并处理下一条。

## 十一、已看阈值设置

### 11.1 设置项

- 名称：`已看判定阈值`
- 范围：`75%-95%`
- 默认值：`90%`
- 位置：播放器设置 -> 播放行为

### 11.2 行为

- 播放进度达到阈值后，记录可标记为 `played=true`
- 恢复时：
  - `played=true` 回填已看状态
  - `played=false` 只回填进度

### 11.3 实现建议

- 直接沿用现有 `PreferenceNotifier<int>` 体系
- 例如新增键：`linplayer_watched_threshold`

## 十二、代码接入点建议

建议新增或调整以下模块：

### 12.1 数据与存储

- `crates/core/src/watch_history.rs` — 本地观看记录主模块(已落地)
- `crates/core/src/watch_history_sync.rs` — 跨服续播与恢复匹配(已落地)
- 相关 Tauri 命令在 `apps/desktop/src/lib.rs`

### 12.2 外部播放器

- `apps/desktop/src/lib.rs` — 外部 MPV 启动与会话管理
- `crates/mpv/src/lib.rs` — libmpv 原生绑定(含 IPC 接口)
- IPC 机制:Windows 命名管道、Linux/macOS Unix socket(cross-platform 待补)

### 12.3 Provider 与前端状态

- `ui/shared/api.ts` 中的命令: `listResume()`, `getWatchHistory()`, `setPlayed()`
- 前端 React 组件中的局部 useState 副本(无全局 store,参见 [[frontend-state-copies-need-broadcast]])
- `ui/desktop/pages/HomePage.tsx` 中集成首页恢复扫描与提示队列

### 12.4 现有文件改动点

- `crates/core/src/emby.rs`
  - 确保已解析 `ProviderIds`、`PresentationUniqueKey` 等标识字段(已补)

- `apps/desktop/src/lib.rs`
  - 接入播放器生命周期回调到 `watch_history` 模块
  - 改造外部 MPV 启动参数与会话跟踪
  - 新增已看阈值偏好相关命令

- `ui/desktop/pages/HomePage.tsx`
  - 集成首页恢复扫描与提示队列

- `ui/desktop/pages/SettingsPage.tsx`
  - 新增已看阈值设置 UI

- `crates/core/src/config.rs` (Prefs)
  - 新增已看阈值字段

## 十三、建议实施顺序

### Phase 1：基础数据层

- 建立 `watch_history.json` 读写能力
- 增加数据模型和迁移能力
- 补强 `MediaItem` 标识字段

### Phase 2：内置播放器写入

- 内置播放器周期写入
- 事件写入
- 退出兜底
- 已看阈值设置接入

### Phase 3：首页恢复

- 首页触发恢复扫描
- 强匹配自动恢复
- 可能匹配进入提示队列
- 首页单条提示交互

### Phase 4：外部 MPV

- 外部 MPV 会话化启动
- IPC 桥接
- 进度采集
- 本地写入与恢复接入

### Phase 5：验证与收尾

- 删库重扫恢复验证
- 三端桌面验证
- Emby 回填稳定性验证
- 异常降级与日志补齐

## 十四、风险与待确认事项

### 14.1 已知风险

- 当前 `MediaItem` 标识字段不足，不补字段就很难做稳跨重扫恢复。
- 外部 MPV 三端统一支持意味着必须新增平台 IPC 桥接层。
- 首页恢复扫描如果批量过大，可能影响首页初次打开速度。
- Emby 对“非真实播放会话”的进度回填需要实测验证。

### 14.2 待确认

- 是否最终明确只跟踪“LinPlayer 启动的外部 MPV 会话”。
- 恢复扫描的单次批量上限和超时策略。
- `可能匹配` 的标题相似度阈值具体取值。

## 十五、结论

这套方案的核心不是“存历史”，而是：

- 给每条媒体内容建立稳定身份
- 在桌面播放链路里持续写下本地观看事实
- 在 Emby 记录缺失时保守地恢复回去

只要这个主线守住，LinPlayer 的桌面端就能同时解决：

- 外部 MPV 不回传记录
- Emby 临时不可用时的本地兜底
- 删库重扫后观看记录丢失

并且不会把首页交互打碎，也不会把本地记录做成另一套失控的历史系统。

## 附录：接口参考

- Emby Playstate `POST /Sessions/Playing`
  - https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlaying.html
- Emby Playstate `POST /Sessions/Playing/Progress`
  - https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingProgress.html
- Emby Playstate `POST /Sessions/Playing/Stopped`
  - https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingStopped.html
