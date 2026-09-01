# 命令契约 · COMMANDS

> 状态:**自动生成**,勿手改表格段 · 源:`apps/desktop/src/lib.rs` 与 `apps/android/src/lib.rs` 的注册表
> 重新生成:`python scripts/gen-commands.py` · 校验:`python scripts/gen-commands.py --check`
> 架构见 `SPEC.md` §5.6。

## 这份文档怎么用

1. **它是四方比对的基准。** `COMMANDS.md` ↔ Go 注册表 ↔ 三端生成的绑定,任何一方缺一条即 CI 红。
2. **三端的绑定层从这里生成,不许手写。** 266 × 3 = 798 次抄写机会,错的那几次全是运行时才发现。
3. **「移植」列是阶段 3 的进度表。** 一条命令的 Go 实现 + 单测 + 差分对账全通过,才允许打勾。

## 规范

- 新命令名统一 `<域>.<动作>`,动作用 camelCase。理由:三端各写一遍绑定时,
  `views` 这种无前缀的名字会被三个人理解成三件事。
- **命令表全平台一致。** 「安卓已注册」列标 ❌ 的,在新契约里**仍然存在**,
  只是在该平台返回 `E_UNSUPPORTED`。UI 启动时调 `system.capabilities` 拿支持集来隐藏入口。
  > 现状是安卓少注册 29 条(文件选择器 / mpv.conf / 翻译 / 预加载设置 / 播放窗控制)。
  > 两份不同的命令表 = 两份不同的契约测试,而漏的那份就是「安卓上点了没反应」。
- 参数与返回类型列的是**现有 Rust 签名**,是移植时的对账基准,**不是**新契约的最终类型。
  新契约的 JSON 形状在各模块移植时定稿并回填。
- 现有签名里的 `state` / `app` / `window` 参数已隐去(Tauri 注入的,新架构没有)。

## 待办:本文档自身

- [x] 生成器脚本 `scripts/gen-commands.py`
- [ ] 生成器接进 CI(`--check`)
- [ ] 每条命令补一句语义说明(现在只有签名)
- [ ] 新契约的 JSON 形状随移植回填
- [ ] `system.capabilities` 的返回结构定稿(见 `SPEC.md` §5.6)

---

<!-- BEGIN GENERATED -->
| 域 | 前缀 | 条数 | 安卓已有 |
|---|---|--:|--:|
| Emby 浏览与详情 | `emby.*` | 40 | 38 |
| 账号与线路 | `account.*` | 21 | 21 |
| 播放器 | `player.*` | 39 | 32 |
| 媒体源(浏览型 / 影视目录) | `source.*` | 14 | 14 |
| Ani-RSS 管理 | `anirss.*` | 51 | 51 |
| 弹幕 | `danmaku.*` | 14 | 14 |
| 插件 | `plugin.*` | 22 | 20 |
| 下载 | `download.*` | 8 | 7 |
| 同步(Trakt / Bangumi / 日历) | `sync.*` | 15 | 15 |
| 字幕翻译 / Whisper(桌面独占) | `translate.*` | 9 | 0 |
| 设置与偏好 | `prefs.*` | 25 | 19 |
| 系统 | `system.*` | 13 | 6 |
| **合计** | | **271** | **237** |

### Emby 浏览与详情 · `emby.*` — 40 条

| 移植 | 新命令名 | 现有名 | 参数 | 返回 | 安卓已注册 |
|:--:|---|---|---|---|:--:|
| [x] | `emby.aggregateOverview` | `aggregate_overview` | `—` | `Result<Vec<SourceOverview>, String>` | ✅ |
| [x] | `emby.aggregateSearch` | `aggregate_search` | `query: String, include_episodes: Option<bool>` | `Result<Vec<ServerGroup>, String>` | ✅ |
| [x] | `emby.blockedList` | `blocked_list` | `—` | `Vec<linplayer_core::blocklist::BlockedItem>` | ✅ |
| [x] | `emby.counts` | **新增** | `server, token, user_id` | `Counts` | — | <!-- 媒体库规模统计。Rust 版里 emby::counts 只被 aggregate_overview 内部调用,没单独成命令 -->
| [x] | `emby.currentSession` | `current_session` | `—` | `Option<LoginResult>` | ✅ |
| [x] | `emby.getFilters` | `get_filters` | `parent_id: String` | `Result<emby::Filters, String>` | ✅ |
| [x] | `emby.isAdmin` | `is_admin` | `—` | `Result<bool, String>` | ✅ |
| [x] | `emby.itemDetail` | `item_detail` | `item_id: String, // 缺省 = true（桌面/TV 的旧调用点不传，行为不变）。 // 手机端传 false：它按季分页拉集，不需要这一坨。 with_children: Option<bool>` | `Result<emby::ItemDetail, String>` | ✅ |
| [x] | `emby.itemMedia` | `item_media` | `item_id: String` | `Result<Vec<emby::MediaVersion>, String>` | ✅ |
| [x] | `emby.listCollections` | `list_collections` | `—` | `Result<Vec<Item>, String>` | ✅ |
| [x] | `emby.listFavorites` | `list_favorites` | `—` | `Result<Vec<Item>, String>` | ✅ |
| [x] | `emby.listItems` | `list_items` | `parent_id: String` | `Result<Vec<Item>, String>` | ✅ |
| [x] | `emby.listItemsPage` | `list_items_page` | `parent_id: String, start_index: Option<u32>, limit: Option<u32>, sort_by: Option<String>, sort_order: Option<String>, genres: Option<Vec<String>>, tags: Option<Vec<String>>, years: Option<Vec<i32>>, studios: Option<Vec<String>>, rating_min: Option<f64>, rating_max: Option<f64>` | `Result<emby::ItemPage, String>` | ✅ |
| [x] | `emby.listLatest` | `list_latest` | `parent_id: String, limit: u32` | `Result<Vec<Item>, String>` | ✅ |
| [x] | `emby.listNextUp` | `list_next_up` | `limit: u32` | `Result<Vec<Item>, String>` | ✅ |
| [x] | `emby.listRandom` | `list_random` | `limit: u32` | `Result<Vec<Item>, String>` | ✅ |
| [x] | `emby.listResume` | `list_resume` | `limit: u32` | `Result<Vec<Item>, String>` | ✅ |
| [x] | `emby.login` | `login` | `server: String, username: String, password: String` | `Result<LoginResult, String>` | ✅ |
| [x] | `emby.logout` | **新增** | `server, token, user_id, device_id` | `{ server_ok: bool }` | — | <!-- 服务端登出。尽力而为:某 fork 该端点 404 且 token 仍可用,失败不挡本地删账号 -->
| [x] | `emby.personDetail` | `person_detail` | `person_id: String` | `Result<emby::PersonDetail, String>` | ✅ |
| [x] | `emby.personItems` | `person_items` | `person_id: String, limit: Option<u32>` | `Result<Vec<Item>, String>` | ✅ |
| [x] | `emby.rankingCategories` | `ranking_categories` | `—` | `Vec<linplayer_core::ranking::RankingCategory>` | ✅ |
| [x] | `emby.rankingFetch` | `ranking_fetch` | `category_id: String, force_refresh: Option<bool>` | `Result<Vec<linplayer_core::ranking::RankingEntry>, String>` | ✅ |
| [x] | `emby.refreshItem` | `refresh_item` | `item_id: String, full: bool` | `Result<(), String>` | ✅ |
| [x] | `emby.relogin` | `relogin` | `server_id: String, username: String, password: String` | `Result<(), String>` | ✅ |
| [x] | `emby.reportProgress` | `report_progress` | `pos: f64, paused: bool` | `Result<(), String>` | ✅ |
| [x] | `emby.scanLibraries` | `scan_libraries` | `—` | `Result<(), String>` | ✅ |
| [x] | `emby.search` | `search` | `query: String, types: Option<Vec<String>>, limit: Option<u32>, parent_id: Option<String>` | `Result<Vec<Item>, String>` | ✅ |
| [x] | `emby.seasonEpisodes` | `season_episodes` | `parent_id: String, start_index: Option<i64>, limit: Option<i64>` | `Result<emby::ItemPage, String>` | ✅ |
| [x] | `emby.seriesSeasons` | `series_seasons` | `series_id: String` | `Result<Vec<emby::SeasonInfo>, String>` | ✅ |
| [x] | `emby.setBlocked` | `set_blocked` | `item_id: String, name: String, blocked: bool` | `()` | ✅ |
| [x] | `emby.setFavorite` | `set_favorite` | `item_id: String, fav: bool` | `Result<(), String>` | ✅ |
| [x] | `emby.setPlayed` | `set_played` | `item_id: String, played: bool` | `Result<(), String>` | ✅ |
| [x] | `emby.similarItems` | `similar_items` | `item_id: String` | `Result<Vec<Item>, String>` | ✅ |
| [x] | `emby.views` | `views` | `include_blocked: Option<bool>` | `Result<Vec<Item>, String>` | ✅ |
| [x] | `emby.watchHistoryClear` | `watch_history_clear` | `—` | `()` | ✅ |
| [x] | `emby.watchHistoryDelete` | `watch_history_delete` | `record_id: String` | `()` | ✅ |
| [x] | `emby.watchHistoryList` | `watch_history_list` | `current_only: bool` | `Vec<wh::Record>` | ✅ |
| [ ] | `emby.watchHistoryRestoreCandidate` | `watch_history_restore_candidate` | `candidate: wh::RestoreCandidate` | `Result<bool, String>` | ✅ |
| [ ] | `emby.watchHistoryScanRestore` | `watch_history_scan_restore` | `—` | `Result<linplayer_core::watch_history_sync::RestoreReport, String>` | ✅ |

### 账号与线路 · `account.*` — 21 条

| 移植 | 新命令名 | 现有名 | 参数 | 返回 | 安卓已注册 |
|:--:|---|---|---|---|:--:|
| [x] | `account.batchAddServers` | `batch_add_servers` | `blocks: Vec<linplayer_core::server_batch::ParsedServerBlock>, fallback_username: Option<String>, fallback_password: Option<String>, fallback_name: Option<String>` | `Result<Vec<BatchAddResult>, String>` | ✅ |
| [x] | `account.batchParse` | `batch_parse` | `text: String` | `Vec<linplayer_core::server_batch::ParsedServerBlock>` | ✅ |
| [x] | `account.clearAccountIcon` | `clear_account_icon` | `server_id: String` | `()` | ✅ |
| [x] | `account.getCrossServerResume` | `get_cross_server_resume` | `—` | `bool` | ✅ |
| [x] | `account.icon` | `account_icon` | `server_id: String` | `Result<String, String>` | ✅ |
| [x] | `account.listAccounts` | `list_accounts` | `—` | `Vec<AccountInfo>` | ✅ |
| [x] | `account.parseDeepLink` | `parse_deep_link` | `url: String` | `Option<linplayer_core::server_batch::DeepLinkAddServer>` | ✅ |
| [x] | `account.probeAccounts` | `probe_accounts` | `—` | `Result<Vec<AccountInfo>, String>` | ✅ |
| [x] | `account.probeLine` | `probe_line` | `server_id: String, index: usize` | `Result<LineProbe, String>` | ✅ |
| [x] | `account.probeLines` | `probe_lines` | `server_id: String` | `Result<Vec<LineProbe>, String>` | ✅ |
| [x] | `account.removeAccount` | `remove_account` | `server_id: String` | `Result<(), String>` | ✅ |
| [x] | `account.reorderAccounts` | `reorder_accounts` | `from: usize, to: usize` | `Result<(), String>` | ✅ |
| [x] | `account.setAccountIconFile` | `set_account_icon_file` | `server_id: String, file_path: String` | `Result<String, String>` | ✅ |
| [x] | `account.setActiveLine` | `set_active_line` | `server_id: String, index: usize` | `Result<(), String>` | ✅ |
| [x] | `account.setActiveServer` | `set_active_server` | `server_id: String` | `Result<(), String>` | ✅ |
| [x] | `account.setCrossServerResume` | `set_cross_server_resume` | `enabled: bool` | `Result<(), String>` | ✅ |
| [x] | `account.setLines` | `set_lines` | `server_id: String, lines: Vec<linplayer_core::config::ServerLine>` | `Result<(), String>` | ✅ |
| [x] | `account.startupDeepLink` | `startup_deep_link` | `—` | `Option<String>` | ✅ |
| [x] | `account.syncLines` | `sync_lines` | `server_id: String` | `Result<SyncedLines, String>` | ✅ |
| [x] | `account.testConnection` | `test_connection` | `server: String` | `Result<emby::ServerInfo, String>` | ✅ |
| [x] | `account.updateAccount` | `update_account` | `server_id: String, name: Option<String>, remark: Option<String>, icon_url: Option<String>, allow_insecure_tls: Option<bool>, password: Option<String>` | `Result<(), String>` | ✅ |

### 播放器 · `player.*` — 39 条

| 移植 | 新命令名 | 现有名 | 参数 | 返回 | 安卓已注册 |
|:--:|---|---|---|---|:--:|
| [x] | `player.addSubtitle` | `add_subtitle` | `url: String, title: Option<String>, secondary: Option<bool>` | `Result<(), String>` | ✅ |
| [x] | `player.chapterInfo` | `chapter_info` | `item_id: String, runtime_secs: f64` | `Result<ChapterInfo, String>` | ✅ |
| [x] | `player.getMpvConf` | `get_mpv_conf` | `—` | `MpvConf` | ❌ |
| [x] | `player.getPlaybackPrefs` | `get_playback_prefs` | `—` | `PlaybackPrefs` | ✅ |
| [x] | `player.getScreenshotDir` | `get_screenshot_dir` | `—` | `ScreenshotDir` | ❌ |
| [x] | `player.mpvCommand` | `mpv_command` | `args: Vec<String>` | `Result<(), String>` | ✅ |
| [x] | `player.mpvGet` | `mpv_get` | `name: String` | `Result<Option<String>, String>` | ✅ |
| [x] | `player.mpvSet` | `mpv_set` | `name: String, value: String` | `Result<(), String>` | ✅ |
| [x] | `player.opts` | `player_opts` | `—` | `Result<PlayerOpts, String>` | ✅ |
| [x] | `player.play` | `play` | `item_id: String, resume_secs: f64, media_source_id: Option<String>` | `Result<f64, String>` | ✅ |
| [x] | `player.playExternal` | `play_external` | `item_id: String, resume_secs: f64, media_source_id: Option<String>` | `Result<String, String>` | ✅ |
| [x] | `player.playLocal` | `play_local` | `id: String, resume_secs: f64` | `Result<f64, String>` | ✅ |
| [x] | `player.screenshot` | `screenshot` | `dir: Option<String>` | `Result<String, String>` | ✅ |
| [x] | `player.seek` | `seek` | `pos: f64` | `Result<(), String>` | ✅ |
| [x] | `player.setAspectRatio` | `set_aspect_ratio` | `ratio: String` | `Result<(), String>` | ✅ |
| [x] | `player.setAudioDelay` | `set_audio_delay` | `secs: f64` | `Result<(), String>` | ✅ |
| [x] | `player.setHwdec` | `set_hwdec` | `mode: String` | `Result<(), String>` | ✅ |
| [x] | `player.setMpvConf` | `set_mpv_conf` | `text: String` | `Result<MpvConf, String>` | ❌ |
| [x] | `player.setMute` | `set_mute` | `mute: bool` | `Result<(), String>` | ✅ |
| [x] | `player.setPause` | `set_pause` | `paused: bool` | `Result<(), String>` | ✅ |
| [x] | `player.setPlaybackPrefs` | `set_playback_prefs` | `settings: PlaybackPrefs` | `Result<(), String>` | ✅ |
| [x] | `player.setScreenshotDir` | `set_screenshot_dir` | `dir: Option<String>` | `Result<ScreenshotDir, String>` | ❌ |
| [x] | `player.setSecondarySub` | `set_secondary_sub` | `id: String` | `Result<(), String>` | ✅ |
| [x] | `player.setSecondarySubOpts` | `set_secondary_sub_opts` | `delay: Option<f64>, position: Option<f64>, ass_override: Option<String>` | `Result<(), String>` | ✅ |
| [x] | `player.setShaderLevel` | `set_shader_level` | `level: String` | `Result<ShaderApplied, String>` | ✅ |
| [x] | `player.setSpeed` | `set_speed` | `speed: f64` | `Result<(), String>` | ✅ |
| [x] | `player.setSubDelay` | `set_sub_delay` | `secs: f64` | `Result<(), String>` | ✅ |
| [x] | `player.setSubStyle` | `set_sub_style` | `font: Option<String>, scale: Option<f64>, position: Option<f64>, background: Option<bool>, blend_mode: Option<String>` | `Result<(), String>` | ✅ |
| [x] | `player.setTrack` | `set_track` | `kind: String, id: String` | `Result<(), String>` | ✅ |
| [x] | `player.setTrackRegexes` | `set_track_regexes` | `version_regex: String, sub_regex: String, audio_regex: String` | `Result<(), String>` | ✅ |
| [x] | `player.setVolume` | `set_volume` | `volume: f64` | `Result<(), String>` | ✅ |
| [x] | `player.shaderLevels` | `shader_levels` | `—` | `Vec<(&'static str, &'static str, &'static str)>` | ✅ |
| [x] | `player.status` | `status` | `—` | `Result<Status, String>` | ✅ |
| [x] | `player.stopPlayback` | `stop_playback` | `pos: f64` | `Result<(), String>` | ✅ |
| [x] | `player.takePending` | `player_take_pending` | `—` | `Option<serde_json::Value>` | ❌ |
| [x] | `player.tracks` | `tracks` | `—` | `Result<Vec<Track>, String>` | ✅ |
| [x] | `player.validateTrackRegex` | `validate_track_regex` | `pattern: String` | `Result<(), String>` | ✅ |
| [x] | `player.windowClose` | `player_window_close` | `—` | `Result<(), String>` | ❌ |
| [x] | `player.windowOpen` | `player_window_open` | `payload: serde_json::Value` | `Result<(), String>` | ❌ |

### 媒体源(浏览型 / 影视目录) · `source.*` — 14 条

| 移植 | 新命令名 | 现有名 | 参数 | 返回 | 安卓已注册 |
|:--:|---|---|---|---|:--:|
| [x] | `source.catalog` | `source_catalog` | `category_id: Option<String>, keyword: Option<String>, page: u32` | `Result<linplayer_core::source::MediaPage, String>` | ✅ |
| [x] | `source.categories` | `source_categories` | `—` | `Result<Vec<linplayer_core::source::MediaCategory>, String>` | ✅ |
| [x] | `source.currentSource` | `current_source` | `—` | `Option<AccountInfo>` | ✅ |
| [x] | `source.listDir` | `source_list_dir` | `dir_id: Option<String>` | `Result<Vec<SourceEntry>, String>` | ✅ |
| [x] | `source.login` | `source_login` | `kind: SourceKind, base_url: String, username: String, password: String, cookie: Option<String>, // 令牌系源用它带 refresh_token(也可走 cookie)与可选的 oplist 地址/driver 覆盖。 // additive:老调用不传即空, 行为不变。 extra: Option<HashMap<String, String>>` | `Result<(), String>` | ✅ |
| [x] | `source.mediaDetail` | `source_media_detail` | `id: String` | `Result<linplayer_core::source::MediaDetail, String>` | ✅ |
| [x] | `source.passwordLogin` | `source_password_login` | `kind: SourceKind, username: String, password: String` | `Result<HashMap<String, String>, String>` | ✅ |
| [x] | `source.play` | `source_play` | `entry_id: String, entry_name: String, resume_secs: f64, raw: Option<serde_json::Value>` | `Result<f64, String>` | ✅ |
| [x] | `source.qrPoll` | `source_qr_poll` | `kind: SourceKind, ctx: String` | `Result<QrPoll, String>` | ✅ |
| [x] | `source.qrStart` | `source_qr_start` | `kind: SourceKind` | `Result<QrStart, String>` | ✅ |
| [x] | `source.quarkScanPoll` | `quark_scan_poll` | `device_id: String, query_token: String` | `Result<bool, String>` | ✅ |
| [x] | `source.quarkScanStart` | `quark_scan_start` | `—` | `Result<QuarkScan, String>` | ✅ |
| [x] | `source.search` | `source_search` | `query: String` | `Result<Vec<SourceEntry>, String>` | ✅ |
| [x] | `source.watchdog` | `source_watchdog` | `pos: f64` | `Result<bool, String>` | ✅ |

### Ani-RSS 管理 · `anirss.*` — 51 条

| 移植 | 新命令名 | 现有名 | 参数 | 返回 | 安卓已注册 |
|:--:|---|---|---|---|:--:|
| [ ] | `anirss.about` | `anirss_about` | `—` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.addAni` | `anirss_add_ani` | `ani: Json` | `Result<(), String>` | ✅ |
| [ ] | `anirss.aniBt` | `anirss_ani_bt` | `—` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.aniBtGroup` | `anirss_ani_bt_group` | `bgm_id: String` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.animeGardenGroup` | `anirss_anime_garden_group` | `bgm_id: String` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.animeGardenList` | `anirss_anime_garden_list` | `—` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.batchEnable` | `anirss_batch_enable` | `ids: Vec<String>, value: bool` | `Result<(), String>` | ✅ |
| [ ] | `anirss.batchScrape` | `anirss_batch_scrape` | `ids: Vec<String>, force: bool` | `Result<(), String>` | ✅ |
| [ ] | `anirss.clearCache` | `anirss_clear_cache` | `—` | `Result<(), String>` | ✅ |
| [ ] | `anirss.clearLogs` | `anirss_clear_logs` | `—` | `Result<(), String>` | ✅ |
| [ ] | `anirss.clearToken` | `anirss_clear_token` | `server_id: String` | `()` | ✅ |
| [ ] | `anirss.deleteAni` | `anirss_delete_ani` | `ids: Vec<String>, delete_files: bool` | `Result<(), String>` | ✅ |
| [ ] | `anirss.downloadLoginTest` | `anirss_download_login_test` | `config: Json` | `Result<(), String>` | ✅ |
| [ ] | `anirss.downloadLogs` | `anirss_download_logs` | `—` | `Result<String, String>` | ✅ |
| [ ] | `anirss.downloadPath` | `anirss_download_path` | `ani: Json` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.exportConfigUrl` | `anirss_export_config_url` | `—` | `Result<String, String>` | ✅ |
| [ ] | `anirss.getAniBySubjectId` | `anirss_get_ani_by_subject_id` | `id: String` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.getBgmTitle` | `anirss_get_bgm_title` | `ani: Json` | `Result<String, String>` | ✅ |
| [ ] | `anirss.getConfig` | `anirss_get_config` | `—` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.getEmbyViews` | `anirss_get_emby_views` | `notification_config: Json` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.getSubtitles` | `anirss_get_subtitles` | `filename: String` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.getThemoviedbGroup` | `anirss_get_themoviedb_group` | `ani: Json` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.getThemoviedbName` | `anirss_get_themoviedb_name` | `ani: Json` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.importConfig` | `anirss_import_config` | `bytes: Vec<u8>, filename: String` | `Result<(), String>` | ✅ |
| [ ] | `anirss.listAni` | `anirss_list_ani` | `—` | `Result<Vec<Json>, String>` | ✅ |
| [ ] | `anirss.logs` | `anirss_logs` | `—` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.meBgm` | `anirss_me_bgm` | `—` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.mikan` | `anirss_mikan` | `text: String, season: Option<Json>` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.mikanGroup` | `anirss_mikan_group` | `url: String` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.newNotification` | `anirss_new_notification` | `—` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.ping` | `anirss_ping` | `—` | `Result<(), String>` | ✅ |
| [ ] | `anirss.playList` | `anirss_play_list` | `ani: Json` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.previewAni` | `anirss_preview_ani` | `ani: Json` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.previewItems` | `anirss_preview_items` | `preview: Json` | `Vec<Json>` | ✅ |
| [ ] | `anirss.proxyImageUrl` | `anirss_proxy_image_url` | `img_url: String` | `Result<String, String>` | ✅ |
| [ ] | `anirss.rate` | `anirss_rate` | `ani: Json` | `Result<i64, String>` | ✅ |
| [ ] | `anirss.refreshAll` | `anirss_refresh_all` | `—` | `Result<(), String>` | ✅ |
| [ ] | `anirss.refreshAni` | `anirss_refresh_ani` | `id: String` | `Result<(), String>` | ✅ |
| [ ] | `anirss.refreshCover` | `anirss_refresh_cover` | `ani: Json` | `Result<String, String>` | ✅ |
| [ ] | `anirss.rssToAni` | `anirss_rss_to_ani` | `url: String, kind: String, bgm_url: Option<String>, subgroup: String, enable: bool` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.scrape` | `anirss_scrape` | `ani: Json, force: bool` | `Result<(), String>` | ✅ |
| [ ] | `anirss.searchBgm` | `anirss_search_bgm` | `name: String` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.serverUpdate` | `anirss_server_update` | `—` | `Result<(), String>` | ✅ |
| [ ] | `anirss.setAni` | `anirss_set_ani` | `ani: Json` | `Result<(), String>` | ✅ |
| [ ] | `anirss.setConfig` | `anirss_set_config` | `config: Json` | `Result<(), String>` | ✅ |
| [ ] | `anirss.setRate` | `anirss_set_rate` | `ani: Json` | `Result<i64, String>` | ✅ |
| [ ] | `anirss.stop` | `anirss_stop` | `status: i64` | `Result<(), String>` | ✅ |
| [ ] | `anirss.testIpWhitelist` | `anirss_test_ip_whitelist` | `—` | `Result<(), String>` | ✅ |
| [ ] | `anirss.testProxy` | `anirss_test_proxy` | `url: String, config: Json` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.torrentsInfos` | `anirss_torrents_infos` | `—` | `Result<Json, String>` | ✅ |
| [ ] | `anirss.updateTotalEpisodeNumber` | `anirss_update_total_episode_number` | `ids: Vec<String>, force: bool` | `Result<(), String>` | ✅ |

### 弹幕 · `danmaku.*` — 14 条

| 移植 | 新命令名 | 现有名 | 参数 | 返回 | 安卓已注册 |
|:--:|---|---|---|---|:--:|
| [x] | `danmaku.autoLoad` | `danmaku_auto_load` | `input: danmaku::MatchInput, options: danmaku::FilterOptions, ch_convert: Option<i32>, anchor_key: Option<String>` | `Result<Option<Vec<DanmakuComment>>, String>` | ✅ |
| [x] | `danmaku.cacheClear` | `danmaku_cache_clear` | `—` | `usize` | ✅ |
| [x] | `danmaku.cacheSize` | `danmaku_cache_size` | `—` | `u64` | ✅ |
| [x] | `danmaku.episodes` | `danmaku_episodes` | `source_id: String, anime_id: String, anime_title: String` | `Result<Vec<danmaku::DanmakuEpisode>, String>` | ✅ |
| [x] | `danmaku.filter` | `danmaku_filter` | `comments: Vec<DanmakuComment>, options: danmaku::FilterOptions` | `Vec<DanmakuComment>` | ✅ |
| [x] | `danmaku.getDanmakuConfig` | `get_danmaku_config` | `—` | `Vec<DanmakuServer>` | ✅ |
| [x] | `danmaku.getOfficialDanmaku` | `get_official_danmaku` | `—` | `OfficialDanmaku` | ✅ |
| [x] | `danmaku.importBlocklist` | `danmaku_import_blocklist` | `xml: String` | `danmaku::DanmakuFilterImportResult` | ✅ |
| [x] | `danmaku.load` | `danmaku_load` | `episode_id: String, source_id: Option<String>, ch_convert: Option<i32>` | `Result<Vec<DanmakuComment>, String>` | ✅ |
| [x] | `danmaku.loadLocal` | `danmaku_load_local` | `path: String` | `Result<Vec<DanmakuComment>, String>` | ✅ |
| [x] | `danmaku.match` | `danmaku_match` | `input: danmaku::MatchInput` | `Result<Vec<danmaku::DanmakuMatchCandidate>, String>` | ✅ |
| [x] | `danmaku.minAutoScore` | `danmaku_min_auto_score` | `—` | `f64` | ✅ |
| [x] | `danmaku.search` | `danmaku_search` | `keyword: String` | `Result<Vec<danmaku::DanmakuSourceGroup>, String>` | ✅ |
| [x] | `danmaku.setDanmakuConfig` | `set_danmaku_config` | `sources: Vec<DanmakuServer>` | `Result<(), String>` | ✅ |

### 插件 · `plugin.*` — 22 条

| 移植 | 新命令名 | 现有名 | 参数 | 返回 | 安卓已注册 |
|:--:|---|---|---|---|:--:|
| [ ] | `plugin.devPoll` | `plugin_dev_poll` | `—` | `Result<Vec<String>, String>` | ✅ |
| [ ] | `plugin.disable` | `plugin_disable` | `id: String` | `Result<(), String>` | ✅ |
| [ ] | `plugin.enable` | `plugin_enable` | `id: String` | `Result<(), String>` | ✅ |
| [ ] | `plugin.extensions` | `plugin_extensions` | `type_id: String` | `Result<Vec<serde_json::Value>, String>` | ✅ |
| [ ] | `plugin.install` | `plugin_install` | `path: String` | `Result<serde_json::Value, String>` | ✅ |
| [ ] | `plugin.invokeField` | `plugin_invoke_field` | `plugin_id: String, type_id: String, ext_id: String, field: String, args: Option<serde_json::Value>` | `Result<serde_json::Value, String>` | ✅ |
| [ ] | `plugin.list` | `plugin_list` | `—` | `Result<Vec<serde_json::Value>, String>` | ✅ |
| [ ] | `plugin.marketAddSource` | `plugin_market_add_source` | `name: String, url: String` | `Result<Vec<PluginSource>, String>` | ✅ |
| [ ] | `plugin.marketInstall` | `plugin_market_install` | `id: String, version: Option<String>` | `Result<Json, String>` | ✅ |
| [ ] | `plugin.marketList` | `plugin_market_list` | `refresh: Option<bool>` | `Result<Json, String>` | ✅ |
| [ ] | `plugin.marketRemoveSource` | `plugin_market_remove_source` | `id: String` | `Result<Vec<PluginSource>, String>` | ✅ |
| [ ] | `plugin.marketSources` | `plugin_market_sources` | `—` | `Vec<PluginSource>` | ✅ |
| [ ] | `plugin.marketToggleSource` | `plugin_market_toggle_source` | `id: String, enabled: bool` | `Result<Vec<PluginSource>, String>` | ✅ |
| [ ] | `plugin.panels` | `plugin_panels` | `slot: String` | `Result<Vec<serde_json::Value>, String>` | ✅ |
| [ ] | `plugin.permissionCatalog` | `plugin_permission_catalog` | `—` | `Vec<Json>` | ✅ |
| [ ] | `plugin.pickDevDir` | `plugin_pick_dev_dir` | `—` | `Result<Option<serde_json::Value>, String>` | ❌ |
| [ ] | `plugin.pickInstall` | `plugin_pick_install` | `—` | `Result<Option<serde_json::Value>, String>` | ❌ |
| [ ] | `plugin.reload` | `plugin_reload` | `id: String` | `Result<(), String>` | ✅ |
| [ ] | `plugin.sources` | `plugin_sources` | `—` | `Result<Vec<serde_json::Value>, String>` | ✅ |
| [ ] | `plugin.trigger` | `plugin_trigger` | `plugin_id: String, type_id: String, ext_id: String, args: Option<serde_json::Value>` | `Result<serde_json::Value, String>` | ✅ |
| [ ] | `plugin.uiRespond` | `plugin_ui_respond` | `id: u64, value: Option<serde_json::Value>` | `()` | ✅ |
| [ ] | `plugin.uninstall` | `plugin_uninstall` | `id: String` | `Result<(), String>` | ✅ |

### 下载 · `download.*` — 8 条

| 移植 | 新命令名 | 现有名 | 参数 | 返回 | 安卓已注册 |
|:--:|---|---|---|---|:--:|
| [x] | `download.andApplyUpdate` | `download_and_apply_update` | `—` | `Result<(), String>` | ❌ |
| [x] | `download.clearCompleted` | `download_clear_completed` | `—` | `usize` | ✅ |
| [x] | `download.enqueue` | `download_enqueue` | `item_id: String, type_: String, title: String, container: String, poster_url: Option<String>` | `Result<String, String>` | ✅ |
| [x] | `download.list` | `download_list` | `—` | `Vec<linplayer_core::download::DownloadItem>` | ✅ |
| [x] | `download.pause` | `download_pause` | `id: String` | `()` | ✅ |
| [x] | `download.remove` | `download_remove` | `id: String` | `()` | ✅ |
| [x] | `download.resume` | `download_resume` | `id: String` | `()` | ✅ |
| [x] | `download.setThreads` | `download_set_threads` | `threads: usize` | `()` | ✅ |

### 同步(Trakt / Bangumi / 日历) · `sync.*` — 15 条

| 移植 | 新命令名 | 现有名 | 参数 | 返回 | 安卓已注册 |
|:--:|---|---|---|---|:--:|
| [x] | `sync.bangumiAccount` | `bangumi_account` | `—` | `Option<linplayer_core::sync::SyncAccount>` | ✅ |
| [x] | `sync.bangumiAuthorizeUrl` | `bangumi_authorize_url` | `redirect_uri: Option<String>` | `String` | ✅ |
| [x] | `sync.bangumiCalendar` | `bangumi_calendar` | `only_mine: Option<bool>` | `Result<Vec<linplayer_core::sync::calendar::CalendarEntry>, String>` | ✅ |
| [x] | `sync.bangumiExchange` | `bangumi_exchange` | `code: String, redirect_uri: Option<String>` | `Result<linplayer_core::sync::SyncAccount, String>` | ✅ |
| [x] | `sync.bangumiLoginToken` | `bangumi_login_token` | `token: String` | `Result<linplayer_core::sync::SyncAccount, String>` | ✅ |
| [x] | `sync.bangumiLogout` | `bangumi_logout` | `—` | `()` | ✅ |
| [x] | `sync.bangumiSetCollection` | `bangumi_set_collection` | `subject_id: i64, type_: i32` | `Result<bool, String>` | ✅ |
| [x] | `sync.bangumiSummary` | `bangumi_summary` | `subject_id: i64` | `Result<Option<String>, String>` | ✅ |
| [x] | `sync.bangumiUpdateEpisode` | `bangumi_update_episode` | `subject_id: i64, episode_id: i64, type_: Option<i32>` | `Result<bool, String>` | ✅ |
| [x] | `sync.traktAccount` | `trakt_account` | `—` | `Option<linplayer_core::sync::SyncAccount>` | ✅ |
| [x] | `sync.traktCalendar` | `trakt_calendar` | `only_mine: Option<bool>` | `Result<Vec<linplayer_core::sync::calendar::CalendarEntry>, String>` | ✅ |
| [x] | `sync.traktDeviceCode` | `trakt_device_code` | `—` | `Result<trakt::TraktDeviceCode, String>` | ✅ |
| [x] | `sync.traktLogout` | `trakt_logout` | `—` | `()` | ✅ |
| [x] | `sync.traktPoll` | `trakt_poll` | `device_code: String` | `Result<trakt::TraktPollResult, String>` | ✅ |
| [x] | `sync.traktScrobble` | `trakt_scrobble` | `type_: String, ids: serde_json::Value, progress: f64, action: String` | `Result<bool, String>` | ✅ |

### 字幕翻译 / Whisper(桌面独占) · `translate.*` — 9 条

| 移植 | 新命令名 | 现有名 | 参数 | 返回 | 安卓已注册 |
|:--:|---|---|---|---|:--:|
| [ ] | `translate.liveStart` | `translate_live_start` | `source_lang: Option<String>` | `Result<(), String>` | ❌ |
| [ ] | `translate.liveStop` | `translate_live_stop` | `—` | `()` | ❌ |
| [ ] | `translate.subtitle` | `translate_subtitle` | `item_id: String, media_source_id: String, index: i64, delivery_url: Option<String>, source_lang: Option<String>, secondary: Option<bool>` | `Result<String, String>` | ❌ |
| [ ] | `translate.translationEngineStatus` | `translation_engine_status` | `—` | `HashMap<String, bool>` | ❌ |
| [ ] | `translate.whisperDelete` | `whisper_delete` | `model: String` | `Result<(), String>` | ❌ |
| [ ] | `translate.whisperDeps` | `whisper_deps` | `—` | `WhisperDeps` | ❌ |
| [ ] | `translate.whisperDownload` | `whisper_download` | `model: String` | `Result<String, String>` | ❌ |
| [ ] | `translate.whisperDownloadFfmpeg` | `whisper_download_ffmpeg` | `—` | `Result<String, String>` | ❌ |
| [ ] | `translate.whisperModels` | `whisper_models` | `—` | `Vec<WhisperModelInfo>` | ❌ |

### 设置与偏好 · `prefs.*` — 25 条

| 移植 | 新命令名 | 现有名 | 参数 | 返回 | 安卓已注册 |
|:--:|---|---|---|---|:--:|
| [x] | `prefs.applyPrefs` | `apply_prefs` | `—` | `Result<(Option<String>, Option<String>), String>` | ✅ |
| [x] | `prefs.cfProxyDisable` | `cf_proxy_disable` | `line_url: String` | `Result<(), String>` | ✅ |
| [x] | `prefs.cfProxyEnable` | `cf_proxy_enable` | `line_url: String, ip: String` | `Result<String, String>` | ✅ |
| [x] | `prefs.cfProxyStatus` | `cf_proxy_status` | `—` | `Result<Vec<CfProxyStatus>, String>` | ✅ |
| [x] | `prefs.cfSpeedTest` | `cf_speed_test` | `validate_host: Option<String>, test_url: Option<String>` | `Result<Vec<linplayer_core::net::cf::CfTestResult>, String>` | ✅ |
| [x] | `prefs.configExportQr` | `config_export_qr` | `—` | `String` | ✅ |
| [x] | `prefs.configImportQr` | `config_import_qr` | `payload: String` | `Result<usize, String>` | ✅ |
| [x] | `prefs.getPrefetchSettings` | `get_prefetch_settings` | `—` | `PrefetchSettings` | ✅ |
| [x] | `prefs.getPrefs` | `get_prefs` | `—` | `Prefs` | ✅ |
| [x] | `prefs.getPreloadSettings` | `get_preload_settings` | `—` | `PreloadSettings` | ❌ |
| [x] | `prefs.getProxy` | `get_proxy` | `—` | `linplayer_core::ProxyConfig` | ✅ |
| [ ] | `prefs.getTranslationSettings` | `get_translation_settings` | `—` | `tr::TranslationSettings` | ❌ |
| [x] | `prefs.getUpdateSettings` | `get_update_settings` | `—` | `UpdateSettings` | ✅ |
| [x] | `prefs.getWritebackSettings` | `get_writeback_settings` | `—` | `WritebackSettings` | ✅ |
| [x] | `prefs.iconLibrary` | `icon_library` | `—` | `()` | ✅ |
| [x] | `prefs.preloadCancel` | `preload_cancel` | `—` | `()` | ❌ |
| [x] | `prefs.preloadItem` | `preload_item` | `item_id: String, media_source_id: Option<String>` | `Result<(), String>` | ❌ |
| [x] | `prefs.setDetailBlur` | `set_detail_blur` | `value: u8` | `Result<(), String>` | ✅ |
| [x] | `prefs.setPrefetchSettings` | `set_prefetch_settings` | `settings: PrefetchSettings` | `Result<(), String>` | ✅ |
| [x] | `prefs.setPrefs` | `set_prefs` | `audio_lang: Option<String>, sub_lang: Option<String>, sub_enabled: bool` | `Result<(), String>` | ✅ |
| [x] | `prefs.setPreloadSettings` | `set_preload_settings` | `settings: PreloadSettings` | `Result<(), String>` | ❌ |
| [x] | `prefs.setProxy` | `set_proxy` | `config: linplayer_core::ProxyConfig` | `Result<(), String>` | ✅ |
| [ ] | `prefs.setTranslationSettings` | `set_translation_settings` | `settings: tr::TranslationSettings` | `Result<(), String>` | ❌ |
| [x] | `prefs.setUpdateSettings` | `set_update_settings` | `channel: linplayer_core::update::UpdateChannel, auto_check: bool` | `Result<(), String>` | ✅ |
| [x] | `prefs.setWritebackSettings` | `set_writeback_settings` | `settings: WritebackSettings` | `Result<(), String>` | ✅ |

### 系统 · `system.*` — 13 条

| 移植 | 新命令名 | 现有名 | 参数 | 返回 | 安卓已注册 |
|:--:|---|---|---|---|:--:|
| [x] | `system.afdianSponsorUrl` | `afdian_sponsor_url` | `—` | `String` | ✅ |
| [x] | `system.afdianVerify` | `afdian_verify` | `order_no: String` | `Result<linplayer_core::sync::AfdianVerifyResult, String>` | ✅ |
| [x] | `system.cacheSize` | `cache_size` | `—` | `Result<u64, String>` | ✅ |
| [x] | `system.capabilities` | **新增** | `-` | `{ commands: string[], ... }` | — | <!-- 本平台支持哪些命令。UI 启动时拿它隐藏入口(SPEC 5.6) -->
| [x] | `system.checkUpdate` | `check_update` | `—` | `Result<Option<linplayer_core::update::UpdateInfo>, String>` | ✅ |
| [x] | `system.clearCache` | `clear_cache` | `—` | `Result<(), String>` | ✅ |
| [x] | `system.dataPaths` | `data_paths` | `—` | `DataPaths` | ✅ |
| [x] | `system.exportDiagnostics` | **新增** | `-` | `{ ... }` | — | <!-- 诊断导出(SPEC 5.6)。**不许带凭据** -->
| [x] | `system.openDataDir` | `open_data_dir` | `sub: Option<String>` | `Result<(), String>` | ❌ |
| [x] | `system.pickDirectory` | `pick_directory` | `start: Option<String>` | `Result<Option<String>, String>` | ❌ |
| [x] | `system.pickFile` | `pick_file` | `start: Option<String>, filter_name: Option<String>, extensions: Option<Vec<String>>` | `Result<Option<String>, String>` | ❌ |
| [x] | `system.pickLocalFolder` | `pick_local_folder` | `—` | `Result<Option<String>, String>` | ❌ |
| [x] | `system.ping` | **新增** | `-` | `{ pong: true, ... }` | — | <!-- 核心层活着吗。契约测试的第一条 -->
<!-- END GENERATED -->
