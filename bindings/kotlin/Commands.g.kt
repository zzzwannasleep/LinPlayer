// 本文件由 scripts/gen-bindings.py 从 docs/go-migration/COMMANDS.md 生成。
// 不要手改 —— 改了会在下一次生成时被覆盖,而且四方比对会红。

package xyz.linplayer.core

import kotlinx.serialization.json.JsonElement

/**
 * 核心层命令的类型化包装。**生成的,不要手写。**
 *
 * 参数与返回暂时是弱类型:COMMANDS.md 的参数列现在装的是现有 Rust 签名,
 * 不是新契约的 JSON 形状。形状回填之后这里会换成 data class。
 *
 * ⚠️ `lp_next_event` 不在这里暴露:有且仅有一个消费者线程能调它。
 * 两个线程同时调不会崩,而是事件被**随机分给两个线程** ——
 * 表现为「有时候收得到有时候收不到」。事件请走 `CoreClient` 的 Flow。
 */
interface LinPlayerCommands {
    /** 发一条命令,挂起到它的 result 事件回来。 */
    suspend fun call(command: String, args: Map<String, Any?>? = null): JsonElement
}

object LinPlayerAbi {
    /** ABI 版本。真值在 core/ffi/abi.go,这里是生成出来的副本。 */
    const val VERSION = 1
}

/** 全部命令名。四方比对(COMMANDS.md ↔ Go 注册表 ↔ 三端绑定)用这份。 */
object LinPlayerCommandNames {
    @JvmField
    val ALL: List<String> = listOf(
        "emby.aggregateOverview",
        "emby.aggregateSearch",
        "emby.blockedList",
        "emby.counts",
        "emby.currentSession",
        "emby.getFilters",
        "emby.isAdmin",
        "emby.itemDetail",
        "emby.itemMedia",
        "emby.listCollections",
        "emby.listFavorites",
        "emby.listItems",
        "emby.listItemsPage",
        "emby.listLatest",
        "emby.listNextUp",
        "emby.listRandom",
        "emby.listResume",
        "emby.login",
        "emby.logout",
        "emby.personDetail",
        "emby.personItems",
        "emby.rankingCategories",
        "emby.rankingFetch",
        "emby.refreshItem",
        "emby.relogin",
        "emby.reportProgress",
        "emby.scanLibraries",
        "emby.search",
        "emby.seasonEpisodes",
        "emby.seriesSeasons",
        "emby.setBlocked",
        "emby.setFavorite",
        "emby.setPlayed",
        "emby.similarItems",
        "emby.views",
        "emby.watchHistoryClear",
        "emby.watchHistoryDelete",
        "emby.watchHistoryList",
        "emby.watchHistoryRestoreCandidate",
        "emby.watchHistoryScanRestore",
        "account.batchAddServers",
        "account.batchParse",
        "account.clearAccountIcon",
        "account.getCrossServerResume",
        "account.icon",
        "account.listAccounts",
        "account.parseDeepLink",
        "account.probeAccounts",
        "account.probeLine",
        "account.probeLines",
        "account.removeAccount",
        "account.reorderAccounts",
        "account.setAccountIconFile",
        "account.setActiveLine",
        "account.setActiveServer",
        "account.setCrossServerResume",
        "account.setLines",
        "account.startupDeepLink",
        "account.syncLines",
        "account.testConnection",
        "account.updateAccount",
        "player.addSubtitle",
        "player.chapterInfo",
        "player.getMpvConf",
        "player.getPlaybackPrefs",
        "player.getScreenshotDir",
        "player.mpvCommand",
        "player.mpvGet",
        "player.mpvSet",
        "player.opts",
        "player.play",
        "player.playExternal",
        "player.playLocal",
        "player.screenshot",
        "player.seek",
        "player.setAspectRatio",
        "player.setAudioDelay",
        "player.setHwdec",
        "player.setMpvConf",
        "player.setMute",
        "player.setPause",
        "player.setPlaybackPrefs",
        "player.setScreenshotDir",
        "player.setSecondarySub",
        "player.setSecondarySubOpts",
        "player.setShaderLevel",
        "player.setSpeed",
        "player.setSubDelay",
        "player.setSubStyle",
        "player.setTrack",
        "player.setTrackRegexes",
        "player.setVolume",
        "player.shaderLevels",
        "player.status",
        "player.stopPlayback",
        "player.takePending",
        "player.tracks",
        "player.validateTrackRegex",
        "player.windowClose",
        "player.windowOpen",
        "source.catalog",
        "source.categories",
        "source.currentSource",
        "source.listDir",
        "source.login",
        "source.mediaDetail",
        "source.passwordLogin",
        "source.play",
        "source.qrPoll",
        "source.qrStart",
        "source.quarkScanPoll",
        "source.quarkScanStart",
        "source.search",
        "source.watchdog",
        "anirss.about",
        "anirss.addAni",
        "anirss.aniBt",
        "anirss.aniBtGroup",
        "anirss.animeGardenGroup",
        "anirss.animeGardenList",
        "anirss.batchEnable",
        "anirss.batchScrape",
        "anirss.clearCache",
        "anirss.clearLogs",
        "anirss.clearToken",
        "anirss.deleteAni",
        "anirss.downloadLoginTest",
        "anirss.downloadLogs",
        "anirss.downloadPath",
        "anirss.exportConfigUrl",
        "anirss.getAniBySubjectId",
        "anirss.getBgmTitle",
        "anirss.getConfig",
        "anirss.getEmbyViews",
        "anirss.getSubtitles",
        "anirss.getThemoviedbGroup",
        "anirss.getThemoviedbName",
        "anirss.importConfig",
        "anirss.listAni",
        "anirss.logs",
        "anirss.meBgm",
        "anirss.mikan",
        "anirss.mikanGroup",
        "anirss.newNotification",
        "anirss.ping",
        "anirss.playList",
        "anirss.previewAni",
        "anirss.previewItems",
        "anirss.proxyImageUrl",
        "anirss.rate",
        "anirss.refreshAll",
        "anirss.refreshAni",
        "anirss.refreshCover",
        "anirss.rssToAni",
        "anirss.scrape",
        "anirss.searchBgm",
        "anirss.serverUpdate",
        "anirss.setAni",
        "anirss.setConfig",
        "anirss.setRate",
        "anirss.stop",
        "anirss.testIpWhitelist",
        "anirss.testProxy",
        "anirss.torrentsInfos",
        "anirss.updateTotalEpisodeNumber",
        "danmaku.autoLoad",
        "danmaku.cacheClear",
        "danmaku.cacheSize",
        "danmaku.episodes",
        "danmaku.filter",
        "danmaku.getDanmakuConfig",
        "danmaku.getOfficialDanmaku",
        "danmaku.importBlocklist",
        "danmaku.load",
        "danmaku.loadLocal",
        "danmaku.match",
        "danmaku.minAutoScore",
        "danmaku.search",
        "danmaku.setDanmakuConfig",
        "plugin.devPoll",
        "plugin.disable",
        "plugin.enable",
        "plugin.extensions",
        "plugin.install",
        "plugin.invokeField",
        "plugin.list",
        "plugin.marketAddSource",
        "plugin.marketInstall",
        "plugin.marketList",
        "plugin.marketRemoveSource",
        "plugin.marketSources",
        "plugin.marketToggleSource",
        "plugin.panels",
        "plugin.permissionCatalog",
        "plugin.pickDevDir",
        "plugin.pickInstall",
        "plugin.reload",
        "plugin.sources",
        "plugin.trigger",
        "plugin.uiRespond",
        "plugin.uninstall",
        "download.andApplyUpdate",
        "download.clearCompleted",
        "download.enqueue",
        "download.list",
        "download.pause",
        "download.remove",
        "download.resume",
        "download.setThreads",
        "sync.bangumiAccount",
        "sync.bangumiAuthorizeUrl",
        "sync.bangumiCalendar",
        "sync.bangumiExchange",
        "sync.bangumiLoginToken",
        "sync.bangumiLogout",
        "sync.bangumiSetCollection",
        "sync.bangumiSummary",
        "sync.bangumiUpdateEpisode",
        "sync.traktAccount",
        "sync.traktCalendar",
        "sync.traktDeviceCode",
        "sync.traktLogout",
        "sync.traktPoll",
        "sync.traktScrobble",
        "translate.liveStart",
        "translate.liveStop",
        "translate.subtitle",
        "translate.translationEngineStatus",
        "translate.whisperDelete",
        "translate.whisperDeps",
        "translate.whisperDownload",
        "translate.whisperDownloadFfmpeg",
        "translate.whisperModels",
        "prefs.applyPrefs",
        "prefs.cfProxyDisable",
        "prefs.cfProxyEnable",
        "prefs.cfProxyStatus",
        "prefs.cfSpeedTest",
        "prefs.configExportQr",
        "prefs.configImportQr",
        "prefs.getPrefetchSettings",
        "prefs.getPrefs",
        "prefs.getPreloadSettings",
        "prefs.getProxy",
        "prefs.getTranslationSettings",
        "prefs.getUpdateSettings",
        "prefs.getWritebackSettings",
        "prefs.iconLibrary",
        "prefs.preloadCancel",
        "prefs.preloadItem",
        "prefs.setDetailBlur",
        "prefs.setPrefetchSettings",
        "prefs.setPrefs",
        "prefs.setPreloadSettings",
        "prefs.setProxy",
        "prefs.setTranslationSettings",
        "prefs.setUpdateSettings",
        "prefs.setWritebackSettings",
        "system.afdianSponsorUrl",
        "system.afdianVerify",
        "system.cacheSize",
        "system.capabilities",
        "system.checkUpdate",
        "system.clearCache",
        "system.dataPaths",
        "system.exportDiagnostics",
        "system.openDataDir",
        "system.pickDirectory",
        "system.pickFile",
        "system.pickLocalFolder",
        "system.ping",
    )
}

// ---- Emby 浏览与详情 · emby.* (40 条) ----
suspend fun LinPlayerCommands.embyAggregateOverview(args: Map<String, Any?>? = null): JsonElement =
    call("emby.aggregateOverview", args)
suspend fun LinPlayerCommands.embyAggregateSearch(args: Map<String, Any?>? = null): JsonElement =
    call("emby.aggregateSearch", args)
suspend fun LinPlayerCommands.embyBlockedList(args: Map<String, Any?>? = null): JsonElement =
    call("emby.blockedList", args)
suspend fun LinPlayerCommands.embyCounts(args: Map<String, Any?>? = null): JsonElement =
    call("emby.counts", args)
suspend fun LinPlayerCommands.embyCurrentSession(args: Map<String, Any?>? = null): JsonElement =
    call("emby.currentSession", args)
suspend fun LinPlayerCommands.embyGetFilters(args: Map<String, Any?>? = null): JsonElement =
    call("emby.getFilters", args)
suspend fun LinPlayerCommands.embyIsAdmin(args: Map<String, Any?>? = null): JsonElement =
    call("emby.isAdmin", args)
suspend fun LinPlayerCommands.embyItemDetail(args: Map<String, Any?>? = null): JsonElement =
    call("emby.itemDetail", args)
suspend fun LinPlayerCommands.embyItemMedia(args: Map<String, Any?>? = null): JsonElement =
    call("emby.itemMedia", args)
suspend fun LinPlayerCommands.embyListCollections(args: Map<String, Any?>? = null): JsonElement =
    call("emby.listCollections", args)
suspend fun LinPlayerCommands.embyListFavorites(args: Map<String, Any?>? = null): JsonElement =
    call("emby.listFavorites", args)
suspend fun LinPlayerCommands.embyListItems(args: Map<String, Any?>? = null): JsonElement =
    call("emby.listItems", args)
suspend fun LinPlayerCommands.embyListItemsPage(args: Map<String, Any?>? = null): JsonElement =
    call("emby.listItemsPage", args)
suspend fun LinPlayerCommands.embyListLatest(args: Map<String, Any?>? = null): JsonElement =
    call("emby.listLatest", args)
suspend fun LinPlayerCommands.embyListNextUp(args: Map<String, Any?>? = null): JsonElement =
    call("emby.listNextUp", args)
suspend fun LinPlayerCommands.embyListRandom(args: Map<String, Any?>? = null): JsonElement =
    call("emby.listRandom", args)
suspend fun LinPlayerCommands.embyListResume(args: Map<String, Any?>? = null): JsonElement =
    call("emby.listResume", args)
suspend fun LinPlayerCommands.embyLogin(args: Map<String, Any?>? = null): JsonElement =
    call("emby.login", args)
suspend fun LinPlayerCommands.embyLogout(args: Map<String, Any?>? = null): JsonElement =
    call("emby.logout", args)
suspend fun LinPlayerCommands.embyPersonDetail(args: Map<String, Any?>? = null): JsonElement =
    call("emby.personDetail", args)
suspend fun LinPlayerCommands.embyPersonItems(args: Map<String, Any?>? = null): JsonElement =
    call("emby.personItems", args)
suspend fun LinPlayerCommands.embyRankingCategories(args: Map<String, Any?>? = null): JsonElement =
    call("emby.rankingCategories", args)
suspend fun LinPlayerCommands.embyRankingFetch(args: Map<String, Any?>? = null): JsonElement =
    call("emby.rankingFetch", args)
suspend fun LinPlayerCommands.embyRefreshItem(args: Map<String, Any?>? = null): JsonElement =
    call("emby.refreshItem", args)
suspend fun LinPlayerCommands.embyRelogin(args: Map<String, Any?>? = null): JsonElement =
    call("emby.relogin", args)
suspend fun LinPlayerCommands.embyReportProgress(args: Map<String, Any?>? = null): JsonElement =
    call("emby.reportProgress", args)
suspend fun LinPlayerCommands.embyScanLibraries(args: Map<String, Any?>? = null): JsonElement =
    call("emby.scanLibraries", args)
suspend fun LinPlayerCommands.embySearch(args: Map<String, Any?>? = null): JsonElement =
    call("emby.search", args)
suspend fun LinPlayerCommands.embySeasonEpisodes(args: Map<String, Any?>? = null): JsonElement =
    call("emby.seasonEpisodes", args)
suspend fun LinPlayerCommands.embySeriesSeasons(args: Map<String, Any?>? = null): JsonElement =
    call("emby.seriesSeasons", args)
suspend fun LinPlayerCommands.embySetBlocked(args: Map<String, Any?>? = null): JsonElement =
    call("emby.setBlocked", args)
suspend fun LinPlayerCommands.embySetFavorite(args: Map<String, Any?>? = null): JsonElement =
    call("emby.setFavorite", args)
suspend fun LinPlayerCommands.embySetPlayed(args: Map<String, Any?>? = null): JsonElement =
    call("emby.setPlayed", args)
suspend fun LinPlayerCommands.embySimilarItems(args: Map<String, Any?>? = null): JsonElement =
    call("emby.similarItems", args)
suspend fun LinPlayerCommands.embyViews(args: Map<String, Any?>? = null): JsonElement =
    call("emby.views", args)
suspend fun LinPlayerCommands.embyWatchHistoryClear(args: Map<String, Any?>? = null): JsonElement =
    call("emby.watchHistoryClear", args)
suspend fun LinPlayerCommands.embyWatchHistoryDelete(args: Map<String, Any?>? = null): JsonElement =
    call("emby.watchHistoryDelete", args)
suspend fun LinPlayerCommands.embyWatchHistoryList(args: Map<String, Any?>? = null): JsonElement =
    call("emby.watchHistoryList", args)
suspend fun LinPlayerCommands.embyWatchHistoryRestoreCandidate(args: Map<String, Any?>? = null): JsonElement =
    call("emby.watchHistoryRestoreCandidate", args)
suspend fun LinPlayerCommands.embyWatchHistoryScanRestore(args: Map<String, Any?>? = null): JsonElement =
    call("emby.watchHistoryScanRestore", args)

// ---- 账号与线路 · account.* (21 条) ----
suspend fun LinPlayerCommands.accountBatchAddServers(args: Map<String, Any?>? = null): JsonElement =
    call("account.batchAddServers", args)
suspend fun LinPlayerCommands.accountBatchParse(args: Map<String, Any?>? = null): JsonElement =
    call("account.batchParse", args)
suspend fun LinPlayerCommands.accountClearAccountIcon(args: Map<String, Any?>? = null): JsonElement =
    call("account.clearAccountIcon", args)
suspend fun LinPlayerCommands.accountGetCrossServerResume(args: Map<String, Any?>? = null): JsonElement =
    call("account.getCrossServerResume", args)
suspend fun LinPlayerCommands.accountIcon(args: Map<String, Any?>? = null): JsonElement =
    call("account.icon", args)
suspend fun LinPlayerCommands.accountListAccounts(args: Map<String, Any?>? = null): JsonElement =
    call("account.listAccounts", args)
suspend fun LinPlayerCommands.accountParseDeepLink(args: Map<String, Any?>? = null): JsonElement =
    call("account.parseDeepLink", args)
suspend fun LinPlayerCommands.accountProbeAccounts(args: Map<String, Any?>? = null): JsonElement =
    call("account.probeAccounts", args)
suspend fun LinPlayerCommands.accountProbeLine(args: Map<String, Any?>? = null): JsonElement =
    call("account.probeLine", args)
suspend fun LinPlayerCommands.accountProbeLines(args: Map<String, Any?>? = null): JsonElement =
    call("account.probeLines", args)
suspend fun LinPlayerCommands.accountRemoveAccount(args: Map<String, Any?>? = null): JsonElement =
    call("account.removeAccount", args)
suspend fun LinPlayerCommands.accountReorderAccounts(args: Map<String, Any?>? = null): JsonElement =
    call("account.reorderAccounts", args)
suspend fun LinPlayerCommands.accountSetAccountIconFile(args: Map<String, Any?>? = null): JsonElement =
    call("account.setAccountIconFile", args)
suspend fun LinPlayerCommands.accountSetActiveLine(args: Map<String, Any?>? = null): JsonElement =
    call("account.setActiveLine", args)
suspend fun LinPlayerCommands.accountSetActiveServer(args: Map<String, Any?>? = null): JsonElement =
    call("account.setActiveServer", args)
suspend fun LinPlayerCommands.accountSetCrossServerResume(args: Map<String, Any?>? = null): JsonElement =
    call("account.setCrossServerResume", args)
suspend fun LinPlayerCommands.accountSetLines(args: Map<String, Any?>? = null): JsonElement =
    call("account.setLines", args)
suspend fun LinPlayerCommands.accountStartupDeepLink(args: Map<String, Any?>? = null): JsonElement =
    call("account.startupDeepLink", args)
suspend fun LinPlayerCommands.accountSyncLines(args: Map<String, Any?>? = null): JsonElement =
    call("account.syncLines", args)
suspend fun LinPlayerCommands.accountTestConnection(args: Map<String, Any?>? = null): JsonElement =
    call("account.testConnection", args)
suspend fun LinPlayerCommands.accountUpdateAccount(args: Map<String, Any?>? = null): JsonElement =
    call("account.updateAccount", args)

// ---- 播放器 · player.* (39 条) ----
suspend fun LinPlayerCommands.playerAddSubtitle(args: Map<String, Any?>? = null): JsonElement =
    call("player.addSubtitle", args)
suspend fun LinPlayerCommands.playerChapterInfo(args: Map<String, Any?>? = null): JsonElement =
    call("player.chapterInfo", args)
suspend fun LinPlayerCommands.playerGetMpvConf(args: Map<String, Any?>? = null): JsonElement =
    call("player.getMpvConf", args)
suspend fun LinPlayerCommands.playerGetPlaybackPrefs(args: Map<String, Any?>? = null): JsonElement =
    call("player.getPlaybackPrefs", args)
suspend fun LinPlayerCommands.playerGetScreenshotDir(args: Map<String, Any?>? = null): JsonElement =
    call("player.getScreenshotDir", args)
suspend fun LinPlayerCommands.playerMpvCommand(args: Map<String, Any?>? = null): JsonElement =
    call("player.mpvCommand", args)
suspend fun LinPlayerCommands.playerMpvGet(args: Map<String, Any?>? = null): JsonElement =
    call("player.mpvGet", args)
suspend fun LinPlayerCommands.playerMpvSet(args: Map<String, Any?>? = null): JsonElement =
    call("player.mpvSet", args)
suspend fun LinPlayerCommands.playerOpts(args: Map<String, Any?>? = null): JsonElement =
    call("player.opts", args)
suspend fun LinPlayerCommands.playerPlay(args: Map<String, Any?>? = null): JsonElement =
    call("player.play", args)
suspend fun LinPlayerCommands.playerPlayExternal(args: Map<String, Any?>? = null): JsonElement =
    call("player.playExternal", args)
suspend fun LinPlayerCommands.playerPlayLocal(args: Map<String, Any?>? = null): JsonElement =
    call("player.playLocal", args)
suspend fun LinPlayerCommands.playerScreenshot(args: Map<String, Any?>? = null): JsonElement =
    call("player.screenshot", args)
suspend fun LinPlayerCommands.playerSeek(args: Map<String, Any?>? = null): JsonElement =
    call("player.seek", args)
suspend fun LinPlayerCommands.playerSetAspectRatio(args: Map<String, Any?>? = null): JsonElement =
    call("player.setAspectRatio", args)
suspend fun LinPlayerCommands.playerSetAudioDelay(args: Map<String, Any?>? = null): JsonElement =
    call("player.setAudioDelay", args)
suspend fun LinPlayerCommands.playerSetHwdec(args: Map<String, Any?>? = null): JsonElement =
    call("player.setHwdec", args)
suspend fun LinPlayerCommands.playerSetMpvConf(args: Map<String, Any?>? = null): JsonElement =
    call("player.setMpvConf", args)
suspend fun LinPlayerCommands.playerSetMute(args: Map<String, Any?>? = null): JsonElement =
    call("player.setMute", args)
suspend fun LinPlayerCommands.playerSetPause(args: Map<String, Any?>? = null): JsonElement =
    call("player.setPause", args)
suspend fun LinPlayerCommands.playerSetPlaybackPrefs(args: Map<String, Any?>? = null): JsonElement =
    call("player.setPlaybackPrefs", args)
suspend fun LinPlayerCommands.playerSetScreenshotDir(args: Map<String, Any?>? = null): JsonElement =
    call("player.setScreenshotDir", args)
suspend fun LinPlayerCommands.playerSetSecondarySub(args: Map<String, Any?>? = null): JsonElement =
    call("player.setSecondarySub", args)
suspend fun LinPlayerCommands.playerSetSecondarySubOpts(args: Map<String, Any?>? = null): JsonElement =
    call("player.setSecondarySubOpts", args)
suspend fun LinPlayerCommands.playerSetShaderLevel(args: Map<String, Any?>? = null): JsonElement =
    call("player.setShaderLevel", args)
suspend fun LinPlayerCommands.playerSetSpeed(args: Map<String, Any?>? = null): JsonElement =
    call("player.setSpeed", args)
suspend fun LinPlayerCommands.playerSetSubDelay(args: Map<String, Any?>? = null): JsonElement =
    call("player.setSubDelay", args)
suspend fun LinPlayerCommands.playerSetSubStyle(args: Map<String, Any?>? = null): JsonElement =
    call("player.setSubStyle", args)
suspend fun LinPlayerCommands.playerSetTrack(args: Map<String, Any?>? = null): JsonElement =
    call("player.setTrack", args)
suspend fun LinPlayerCommands.playerSetTrackRegexes(args: Map<String, Any?>? = null): JsonElement =
    call("player.setTrackRegexes", args)
suspend fun LinPlayerCommands.playerSetVolume(args: Map<String, Any?>? = null): JsonElement =
    call("player.setVolume", args)
suspend fun LinPlayerCommands.playerShaderLevels(args: Map<String, Any?>? = null): JsonElement =
    call("player.shaderLevels", args)
suspend fun LinPlayerCommands.playerStatus(args: Map<String, Any?>? = null): JsonElement =
    call("player.status", args)
suspend fun LinPlayerCommands.playerStopPlayback(args: Map<String, Any?>? = null): JsonElement =
    call("player.stopPlayback", args)
suspend fun LinPlayerCommands.playerTakePending(args: Map<String, Any?>? = null): JsonElement =
    call("player.takePending", args)
suspend fun LinPlayerCommands.playerTracks(args: Map<String, Any?>? = null): JsonElement =
    call("player.tracks", args)
suspend fun LinPlayerCommands.playerValidateTrackRegex(args: Map<String, Any?>? = null): JsonElement =
    call("player.validateTrackRegex", args)
suspend fun LinPlayerCommands.playerWindowClose(args: Map<String, Any?>? = null): JsonElement =
    call("player.windowClose", args)
suspend fun LinPlayerCommands.playerWindowOpen(args: Map<String, Any?>? = null): JsonElement =
    call("player.windowOpen", args)

// ---- 媒体源(浏览型 / 影视目录) · source.* (14 条) ----
suspend fun LinPlayerCommands.sourceCatalog(args: Map<String, Any?>? = null): JsonElement =
    call("source.catalog", args)
suspend fun LinPlayerCommands.sourceCategories(args: Map<String, Any?>? = null): JsonElement =
    call("source.categories", args)
suspend fun LinPlayerCommands.sourceCurrentSource(args: Map<String, Any?>? = null): JsonElement =
    call("source.currentSource", args)
suspend fun LinPlayerCommands.sourceListDir(args: Map<String, Any?>? = null): JsonElement =
    call("source.listDir", args)
suspend fun LinPlayerCommands.sourceLogin(args: Map<String, Any?>? = null): JsonElement =
    call("source.login", args)
suspend fun LinPlayerCommands.sourceMediaDetail(args: Map<String, Any?>? = null): JsonElement =
    call("source.mediaDetail", args)
suspend fun LinPlayerCommands.sourcePasswordLogin(args: Map<String, Any?>? = null): JsonElement =
    call("source.passwordLogin", args)
suspend fun LinPlayerCommands.sourcePlay(args: Map<String, Any?>? = null): JsonElement =
    call("source.play", args)
suspend fun LinPlayerCommands.sourceQrPoll(args: Map<String, Any?>? = null): JsonElement =
    call("source.qrPoll", args)
suspend fun LinPlayerCommands.sourceQrStart(args: Map<String, Any?>? = null): JsonElement =
    call("source.qrStart", args)
suspend fun LinPlayerCommands.sourceQuarkScanPoll(args: Map<String, Any?>? = null): JsonElement =
    call("source.quarkScanPoll", args)
suspend fun LinPlayerCommands.sourceQuarkScanStart(args: Map<String, Any?>? = null): JsonElement =
    call("source.quarkScanStart", args)
suspend fun LinPlayerCommands.sourceSearch(args: Map<String, Any?>? = null): JsonElement =
    call("source.search", args)
suspend fun LinPlayerCommands.sourceWatchdog(args: Map<String, Any?>? = null): JsonElement =
    call("source.watchdog", args)

// ---- Ani-RSS 管理 · anirss.* (51 条) ----
suspend fun LinPlayerCommands.anirssAbout(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.about", args)
suspend fun LinPlayerCommands.anirssAddAni(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.addAni", args)
suspend fun LinPlayerCommands.anirssAniBt(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.aniBt", args)
suspend fun LinPlayerCommands.anirssAniBtGroup(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.aniBtGroup", args)
suspend fun LinPlayerCommands.anirssAnimeGardenGroup(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.animeGardenGroup", args)
suspend fun LinPlayerCommands.anirssAnimeGardenList(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.animeGardenList", args)
suspend fun LinPlayerCommands.anirssBatchEnable(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.batchEnable", args)
suspend fun LinPlayerCommands.anirssBatchScrape(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.batchScrape", args)
suspend fun LinPlayerCommands.anirssClearCache(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.clearCache", args)
suspend fun LinPlayerCommands.anirssClearLogs(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.clearLogs", args)
suspend fun LinPlayerCommands.anirssClearToken(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.clearToken", args)
suspend fun LinPlayerCommands.anirssDeleteAni(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.deleteAni", args)
suspend fun LinPlayerCommands.anirssDownloadLoginTest(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.downloadLoginTest", args)
suspend fun LinPlayerCommands.anirssDownloadLogs(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.downloadLogs", args)
suspend fun LinPlayerCommands.anirssDownloadPath(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.downloadPath", args)
suspend fun LinPlayerCommands.anirssExportConfigUrl(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.exportConfigUrl", args)
suspend fun LinPlayerCommands.anirssGetAniBySubjectId(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.getAniBySubjectId", args)
suspend fun LinPlayerCommands.anirssGetBgmTitle(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.getBgmTitle", args)
suspend fun LinPlayerCommands.anirssGetConfig(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.getConfig", args)
suspend fun LinPlayerCommands.anirssGetEmbyViews(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.getEmbyViews", args)
suspend fun LinPlayerCommands.anirssGetSubtitles(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.getSubtitles", args)
suspend fun LinPlayerCommands.anirssGetThemoviedbGroup(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.getThemoviedbGroup", args)
suspend fun LinPlayerCommands.anirssGetThemoviedbName(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.getThemoviedbName", args)
suspend fun LinPlayerCommands.anirssImportConfig(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.importConfig", args)
suspend fun LinPlayerCommands.anirssListAni(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.listAni", args)
suspend fun LinPlayerCommands.anirssLogs(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.logs", args)
suspend fun LinPlayerCommands.anirssMeBgm(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.meBgm", args)
suspend fun LinPlayerCommands.anirssMikan(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.mikan", args)
suspend fun LinPlayerCommands.anirssMikanGroup(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.mikanGroup", args)
suspend fun LinPlayerCommands.anirssNewNotification(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.newNotification", args)
suspend fun LinPlayerCommands.anirssPing(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.ping", args)
suspend fun LinPlayerCommands.anirssPlayList(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.playList", args)
suspend fun LinPlayerCommands.anirssPreviewAni(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.previewAni", args)
suspend fun LinPlayerCommands.anirssPreviewItems(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.previewItems", args)
suspend fun LinPlayerCommands.anirssProxyImageUrl(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.proxyImageUrl", args)
suspend fun LinPlayerCommands.anirssRate(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.rate", args)
suspend fun LinPlayerCommands.anirssRefreshAll(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.refreshAll", args)
suspend fun LinPlayerCommands.anirssRefreshAni(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.refreshAni", args)
suspend fun LinPlayerCommands.anirssRefreshCover(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.refreshCover", args)
suspend fun LinPlayerCommands.anirssRssToAni(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.rssToAni", args)
suspend fun LinPlayerCommands.anirssScrape(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.scrape", args)
suspend fun LinPlayerCommands.anirssSearchBgm(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.searchBgm", args)
suspend fun LinPlayerCommands.anirssServerUpdate(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.serverUpdate", args)
suspend fun LinPlayerCommands.anirssSetAni(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.setAni", args)
suspend fun LinPlayerCommands.anirssSetConfig(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.setConfig", args)
suspend fun LinPlayerCommands.anirssSetRate(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.setRate", args)
suspend fun LinPlayerCommands.anirssStop(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.stop", args)
suspend fun LinPlayerCommands.anirssTestIpWhitelist(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.testIpWhitelist", args)
suspend fun LinPlayerCommands.anirssTestProxy(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.testProxy", args)
suspend fun LinPlayerCommands.anirssTorrentsInfos(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.torrentsInfos", args)
suspend fun LinPlayerCommands.anirssUpdateTotalEpisodeNumber(args: Map<String, Any?>? = null): JsonElement =
    call("anirss.updateTotalEpisodeNumber", args)

// ---- 弹幕 · danmaku.* (14 条) ----
suspend fun LinPlayerCommands.danmakuAutoLoad(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.autoLoad", args)
suspend fun LinPlayerCommands.danmakuCacheClear(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.cacheClear", args)
suspend fun LinPlayerCommands.danmakuCacheSize(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.cacheSize", args)
suspend fun LinPlayerCommands.danmakuEpisodes(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.episodes", args)
suspend fun LinPlayerCommands.danmakuFilter(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.filter", args)
suspend fun LinPlayerCommands.danmakuGetDanmakuConfig(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.getDanmakuConfig", args)
suspend fun LinPlayerCommands.danmakuGetOfficialDanmaku(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.getOfficialDanmaku", args)
suspend fun LinPlayerCommands.danmakuImportBlocklist(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.importBlocklist", args)
suspend fun LinPlayerCommands.danmakuLoad(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.load", args)
suspend fun LinPlayerCommands.danmakuLoadLocal(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.loadLocal", args)
suspend fun LinPlayerCommands.danmakuMatch(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.match", args)
suspend fun LinPlayerCommands.danmakuMinAutoScore(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.minAutoScore", args)
suspend fun LinPlayerCommands.danmakuSearch(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.search", args)
suspend fun LinPlayerCommands.danmakuSetDanmakuConfig(args: Map<String, Any?>? = null): JsonElement =
    call("danmaku.setDanmakuConfig", args)

// ---- 插件 · plugin.* (22 条) ----
suspend fun LinPlayerCommands.pluginDevPoll(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.devPoll", args)
suspend fun LinPlayerCommands.pluginDisable(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.disable", args)
suspend fun LinPlayerCommands.pluginEnable(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.enable", args)
suspend fun LinPlayerCommands.pluginExtensions(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.extensions", args)
suspend fun LinPlayerCommands.pluginInstall(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.install", args)
suspend fun LinPlayerCommands.pluginInvokeField(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.invokeField", args)
suspend fun LinPlayerCommands.pluginList(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.list", args)
suspend fun LinPlayerCommands.pluginMarketAddSource(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.marketAddSource", args)
suspend fun LinPlayerCommands.pluginMarketInstall(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.marketInstall", args)
suspend fun LinPlayerCommands.pluginMarketList(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.marketList", args)
suspend fun LinPlayerCommands.pluginMarketRemoveSource(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.marketRemoveSource", args)
suspend fun LinPlayerCommands.pluginMarketSources(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.marketSources", args)
suspend fun LinPlayerCommands.pluginMarketToggleSource(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.marketToggleSource", args)
suspend fun LinPlayerCommands.pluginPanels(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.panels", args)
suspend fun LinPlayerCommands.pluginPermissionCatalog(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.permissionCatalog", args)
suspend fun LinPlayerCommands.pluginPickDevDir(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.pickDevDir", args)
suspend fun LinPlayerCommands.pluginPickInstall(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.pickInstall", args)
suspend fun LinPlayerCommands.pluginReload(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.reload", args)
suspend fun LinPlayerCommands.pluginSources(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.sources", args)
suspend fun LinPlayerCommands.pluginTrigger(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.trigger", args)
suspend fun LinPlayerCommands.pluginUiRespond(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.uiRespond", args)
suspend fun LinPlayerCommands.pluginUninstall(args: Map<String, Any?>? = null): JsonElement =
    call("plugin.uninstall", args)

// ---- 下载 · download.* (8 条) ----
suspend fun LinPlayerCommands.downloadAndApplyUpdate(args: Map<String, Any?>? = null): JsonElement =
    call("download.andApplyUpdate", args)
suspend fun LinPlayerCommands.downloadClearCompleted(args: Map<String, Any?>? = null): JsonElement =
    call("download.clearCompleted", args)
suspend fun LinPlayerCommands.downloadEnqueue(args: Map<String, Any?>? = null): JsonElement =
    call("download.enqueue", args)
suspend fun LinPlayerCommands.downloadList(args: Map<String, Any?>? = null): JsonElement =
    call("download.list", args)
suspend fun LinPlayerCommands.downloadPause(args: Map<String, Any?>? = null): JsonElement =
    call("download.pause", args)
suspend fun LinPlayerCommands.downloadRemove(args: Map<String, Any?>? = null): JsonElement =
    call("download.remove", args)
suspend fun LinPlayerCommands.downloadResume(args: Map<String, Any?>? = null): JsonElement =
    call("download.resume", args)
suspend fun LinPlayerCommands.downloadSetThreads(args: Map<String, Any?>? = null): JsonElement =
    call("download.setThreads", args)

// ---- 同步(Trakt / Bangumi / 日历) · sync.* (15 条) ----
suspend fun LinPlayerCommands.syncBangumiAccount(args: Map<String, Any?>? = null): JsonElement =
    call("sync.bangumiAccount", args)
suspend fun LinPlayerCommands.syncBangumiAuthorizeUrl(args: Map<String, Any?>? = null): JsonElement =
    call("sync.bangumiAuthorizeUrl", args)
suspend fun LinPlayerCommands.syncBangumiCalendar(args: Map<String, Any?>? = null): JsonElement =
    call("sync.bangumiCalendar", args)
suspend fun LinPlayerCommands.syncBangumiExchange(args: Map<String, Any?>? = null): JsonElement =
    call("sync.bangumiExchange", args)
suspend fun LinPlayerCommands.syncBangumiLoginToken(args: Map<String, Any?>? = null): JsonElement =
    call("sync.bangumiLoginToken", args)
suspend fun LinPlayerCommands.syncBangumiLogout(args: Map<String, Any?>? = null): JsonElement =
    call("sync.bangumiLogout", args)
suspend fun LinPlayerCommands.syncBangumiSetCollection(args: Map<String, Any?>? = null): JsonElement =
    call("sync.bangumiSetCollection", args)
suspend fun LinPlayerCommands.syncBangumiSummary(args: Map<String, Any?>? = null): JsonElement =
    call("sync.bangumiSummary", args)
suspend fun LinPlayerCommands.syncBangumiUpdateEpisode(args: Map<String, Any?>? = null): JsonElement =
    call("sync.bangumiUpdateEpisode", args)
suspend fun LinPlayerCommands.syncTraktAccount(args: Map<String, Any?>? = null): JsonElement =
    call("sync.traktAccount", args)
suspend fun LinPlayerCommands.syncTraktCalendar(args: Map<String, Any?>? = null): JsonElement =
    call("sync.traktCalendar", args)
suspend fun LinPlayerCommands.syncTraktDeviceCode(args: Map<String, Any?>? = null): JsonElement =
    call("sync.traktDeviceCode", args)
suspend fun LinPlayerCommands.syncTraktLogout(args: Map<String, Any?>? = null): JsonElement =
    call("sync.traktLogout", args)
suspend fun LinPlayerCommands.syncTraktPoll(args: Map<String, Any?>? = null): JsonElement =
    call("sync.traktPoll", args)
suspend fun LinPlayerCommands.syncTraktScrobble(args: Map<String, Any?>? = null): JsonElement =
    call("sync.traktScrobble", args)

// ---- 字幕翻译 / Whisper(桌面独占) · translate.* (9 条) ----
suspend fun LinPlayerCommands.translateLiveStart(args: Map<String, Any?>? = null): JsonElement =
    call("translate.liveStart", args)
suspend fun LinPlayerCommands.translateLiveStop(args: Map<String, Any?>? = null): JsonElement =
    call("translate.liveStop", args)
suspend fun LinPlayerCommands.translateSubtitle(args: Map<String, Any?>? = null): JsonElement =
    call("translate.subtitle", args)
suspend fun LinPlayerCommands.translateTranslationEngineStatus(args: Map<String, Any?>? = null): JsonElement =
    call("translate.translationEngineStatus", args)
suspend fun LinPlayerCommands.translateWhisperDelete(args: Map<String, Any?>? = null): JsonElement =
    call("translate.whisperDelete", args)
suspend fun LinPlayerCommands.translateWhisperDeps(args: Map<String, Any?>? = null): JsonElement =
    call("translate.whisperDeps", args)
suspend fun LinPlayerCommands.translateWhisperDownload(args: Map<String, Any?>? = null): JsonElement =
    call("translate.whisperDownload", args)
suspend fun LinPlayerCommands.translateWhisperDownloadFfmpeg(args: Map<String, Any?>? = null): JsonElement =
    call("translate.whisperDownloadFfmpeg", args)
suspend fun LinPlayerCommands.translateWhisperModels(args: Map<String, Any?>? = null): JsonElement =
    call("translate.whisperModels", args)

// ---- 设置与偏好 · prefs.* (25 条) ----
suspend fun LinPlayerCommands.prefsApplyPrefs(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.applyPrefs", args)
suspend fun LinPlayerCommands.prefsCfProxyDisable(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.cfProxyDisable", args)
suspend fun LinPlayerCommands.prefsCfProxyEnable(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.cfProxyEnable", args)
suspend fun LinPlayerCommands.prefsCfProxyStatus(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.cfProxyStatus", args)
suspend fun LinPlayerCommands.prefsCfSpeedTest(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.cfSpeedTest", args)
suspend fun LinPlayerCommands.prefsConfigExportQr(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.configExportQr", args)
suspend fun LinPlayerCommands.prefsConfigImportQr(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.configImportQr", args)
suspend fun LinPlayerCommands.prefsGetPrefetchSettings(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.getPrefetchSettings", args)
suspend fun LinPlayerCommands.prefsGetPrefs(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.getPrefs", args)
suspend fun LinPlayerCommands.prefsGetPreloadSettings(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.getPreloadSettings", args)
suspend fun LinPlayerCommands.prefsGetProxy(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.getProxy", args)
suspend fun LinPlayerCommands.prefsGetTranslationSettings(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.getTranslationSettings", args)
suspend fun LinPlayerCommands.prefsGetUpdateSettings(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.getUpdateSettings", args)
suspend fun LinPlayerCommands.prefsGetWritebackSettings(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.getWritebackSettings", args)
suspend fun LinPlayerCommands.prefsIconLibrary(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.iconLibrary", args)
suspend fun LinPlayerCommands.prefsPreloadCancel(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.preloadCancel", args)
suspend fun LinPlayerCommands.prefsPreloadItem(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.preloadItem", args)
suspend fun LinPlayerCommands.prefsSetDetailBlur(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.setDetailBlur", args)
suspend fun LinPlayerCommands.prefsSetPrefetchSettings(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.setPrefetchSettings", args)
suspend fun LinPlayerCommands.prefsSetPrefs(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.setPrefs", args)
suspend fun LinPlayerCommands.prefsSetPreloadSettings(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.setPreloadSettings", args)
suspend fun LinPlayerCommands.prefsSetProxy(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.setProxy", args)
suspend fun LinPlayerCommands.prefsSetTranslationSettings(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.setTranslationSettings", args)
suspend fun LinPlayerCommands.prefsSetUpdateSettings(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.setUpdateSettings", args)
suspend fun LinPlayerCommands.prefsSetWritebackSettings(args: Map<String, Any?>? = null): JsonElement =
    call("prefs.setWritebackSettings", args)

// ---- 系统 · system.* (13 条) ----
suspend fun LinPlayerCommands.systemAfdianSponsorUrl(args: Map<String, Any?>? = null): JsonElement =
    call("system.afdianSponsorUrl", args)
suspend fun LinPlayerCommands.systemAfdianVerify(args: Map<String, Any?>? = null): JsonElement =
    call("system.afdianVerify", args)
suspend fun LinPlayerCommands.systemCacheSize(args: Map<String, Any?>? = null): JsonElement =
    call("system.cacheSize", args)
suspend fun LinPlayerCommands.systemCapabilities(args: Map<String, Any?>? = null): JsonElement =
    call("system.capabilities", args)
suspend fun LinPlayerCommands.systemCheckUpdate(args: Map<String, Any?>? = null): JsonElement =
    call("system.checkUpdate", args)
suspend fun LinPlayerCommands.systemClearCache(args: Map<String, Any?>? = null): JsonElement =
    call("system.clearCache", args)
suspend fun LinPlayerCommands.systemDataPaths(args: Map<String, Any?>? = null): JsonElement =
    call("system.dataPaths", args)
suspend fun LinPlayerCommands.systemExportDiagnostics(args: Map<String, Any?>? = null): JsonElement =
    call("system.exportDiagnostics", args)
suspend fun LinPlayerCommands.systemOpenDataDir(args: Map<String, Any?>? = null): JsonElement =
    call("system.openDataDir", args)
suspend fun LinPlayerCommands.systemPickDirectory(args: Map<String, Any?>? = null): JsonElement =
    call("system.pickDirectory", args)
suspend fun LinPlayerCommands.systemPickFile(args: Map<String, Any?>? = null): JsonElement =
    call("system.pickFile", args)
suspend fun LinPlayerCommands.systemPickLocalFolder(args: Map<String, Any?>? = null): JsonElement =
    call("system.pickLocalFolder", args)
suspend fun LinPlayerCommands.systemPing(args: Map<String, Any?>? = null): JsonElement =
    call("system.ping", args)
