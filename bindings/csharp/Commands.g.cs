// 本文件由 scripts/gen-bindings.py 从 docs/go-migration/COMMANDS.md 生成。
// 不要手改 —— 改了会在下一次生成时被覆盖,而且四方比对会红。
#nullable enable

using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace LinPlayer.Core;

/// <summary>
/// 核心层命令的类型化包装。**生成的,不要手写。**
/// </summary>
/// <remarks>
/// 参数与返回暂时是弱类型(<c>object?</c> / <see cref="JsonElement"/>):
/// COMMANDS.md 的参数列现在装的是现有 Rust 签名,不是新契约的 JSON 形状。
/// 形状回填之后这里会换成 record。
///
/// <para>
/// ⚠️ <c>lp_next_event</c> 不在这里暴露:有且仅有一个消费者线程能调它。
/// 两个线程同时调不会崩,而是事件被<b>随机分给两个线程</b> ——
/// 表现为「有时候收得到有时候收不到」。事件请走 <c>CoreClient</c> 的事件流。
/// </para>
/// </remarks>
public partial interface ILinPlayerCommands
{
    /// <summary>发一条命令,等它的 result 事件。</summary>
    Task<JsonElement> CallAsync(string command, object? args, CancellationToken ct = default);
}

public static class LinPlayerAbi
{
    /// <summary>ABI 版本。真值在 core/ffi/abi.go,这里是生成出来的副本。</summary>
    public const int Version = 1;
}

/// <summary>全部命令名。四方比对(COMMANDS.md ↔ Go 注册表 ↔ 三端绑定)用这份。</summary>
public static class LinPlayerCommandNames
{
    public static readonly string[] All =
    [
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
        "player.thumbnail",
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
    ];
}

public static class LinPlayerCommandsExtensions
{
    // ---- Emby 浏览与详情 · emby.* (40 条) ----
    public static Task<JsonElement> EmbyAggregateOverview(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.aggregateOverview", args, ct);
    public static Task<JsonElement> EmbyAggregateSearch(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.aggregateSearch", args, ct);
    public static Task<JsonElement> EmbyBlockedList(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.blockedList", args, ct);
    public static Task<JsonElement> EmbyCounts(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.counts", args, ct);
    public static Task<JsonElement> EmbyCurrentSession(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.currentSession", args, ct);
    public static Task<JsonElement> EmbyGetFilters(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.getFilters", args, ct);
    public static Task<JsonElement> EmbyIsAdmin(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.isAdmin", args, ct);
    public static Task<JsonElement> EmbyItemDetail(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.itemDetail", args, ct);
    public static Task<JsonElement> EmbyItemMedia(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.itemMedia", args, ct);
    public static Task<JsonElement> EmbyListCollections(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.listCollections", args, ct);
    public static Task<JsonElement> EmbyListFavorites(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.listFavorites", args, ct);
    public static Task<JsonElement> EmbyListItems(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.listItems", args, ct);
    public static Task<JsonElement> EmbyListItemsPage(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.listItemsPage", args, ct);
    public static Task<JsonElement> EmbyListLatest(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.listLatest", args, ct);
    public static Task<JsonElement> EmbyListNextUp(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.listNextUp", args, ct);
    public static Task<JsonElement> EmbyListRandom(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.listRandom", args, ct);
    public static Task<JsonElement> EmbyListResume(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.listResume", args, ct);
    public static Task<JsonElement> EmbyLogin(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.login", args, ct);
    public static Task<JsonElement> EmbyLogout(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.logout", args, ct);
    public static Task<JsonElement> EmbyPersonDetail(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.personDetail", args, ct);
    public static Task<JsonElement> EmbyPersonItems(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.personItems", args, ct);
    public static Task<JsonElement> EmbyRankingCategories(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.rankingCategories", args, ct);
    public static Task<JsonElement> EmbyRankingFetch(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.rankingFetch", args, ct);
    public static Task<JsonElement> EmbyRefreshItem(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.refreshItem", args, ct);
    public static Task<JsonElement> EmbyRelogin(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.relogin", args, ct);
    public static Task<JsonElement> EmbyReportProgress(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.reportProgress", args, ct);
    public static Task<JsonElement> EmbyScanLibraries(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.scanLibraries", args, ct);
    public static Task<JsonElement> EmbySearch(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.search", args, ct);
    public static Task<JsonElement> EmbySeasonEpisodes(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.seasonEpisodes", args, ct);
    public static Task<JsonElement> EmbySeriesSeasons(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.seriesSeasons", args, ct);
    public static Task<JsonElement> EmbySetBlocked(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.setBlocked", args, ct);
    public static Task<JsonElement> EmbySetFavorite(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.setFavorite", args, ct);
    public static Task<JsonElement> EmbySetPlayed(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.setPlayed", args, ct);
    public static Task<JsonElement> EmbySimilarItems(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.similarItems", args, ct);
    public static Task<JsonElement> EmbyViews(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.views", args, ct);
    public static Task<JsonElement> EmbyWatchHistoryClear(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.watchHistoryClear", args, ct);
    public static Task<JsonElement> EmbyWatchHistoryDelete(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.watchHistoryDelete", args, ct);
    public static Task<JsonElement> EmbyWatchHistoryList(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.watchHistoryList", args, ct);
    public static Task<JsonElement> EmbyWatchHistoryRestoreCandidate(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.watchHistoryRestoreCandidate", args, ct);
    public static Task<JsonElement> EmbyWatchHistoryScanRestore(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("emby.watchHistoryScanRestore", args, ct);

    // ---- 账号与线路 · account.* (21 条) ----
    public static Task<JsonElement> AccountBatchAddServers(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.batchAddServers", args, ct);
    public static Task<JsonElement> AccountBatchParse(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.batchParse", args, ct);
    public static Task<JsonElement> AccountClearAccountIcon(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.clearAccountIcon", args, ct);
    public static Task<JsonElement> AccountGetCrossServerResume(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.getCrossServerResume", args, ct);
    public static Task<JsonElement> AccountIcon(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.icon", args, ct);
    public static Task<JsonElement> AccountListAccounts(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.listAccounts", args, ct);
    public static Task<JsonElement> AccountParseDeepLink(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.parseDeepLink", args, ct);
    public static Task<JsonElement> AccountProbeAccounts(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.probeAccounts", args, ct);
    public static Task<JsonElement> AccountProbeLine(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.probeLine", args, ct);
    public static Task<JsonElement> AccountProbeLines(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.probeLines", args, ct);
    public static Task<JsonElement> AccountRemoveAccount(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.removeAccount", args, ct);
    public static Task<JsonElement> AccountReorderAccounts(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.reorderAccounts", args, ct);
    public static Task<JsonElement> AccountSetAccountIconFile(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.setAccountIconFile", args, ct);
    public static Task<JsonElement> AccountSetActiveLine(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.setActiveLine", args, ct);
    public static Task<JsonElement> AccountSetActiveServer(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.setActiveServer", args, ct);
    public static Task<JsonElement> AccountSetCrossServerResume(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.setCrossServerResume", args, ct);
    public static Task<JsonElement> AccountSetLines(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.setLines", args, ct);
    public static Task<JsonElement> AccountStartupDeepLink(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.startupDeepLink", args, ct);
    public static Task<JsonElement> AccountSyncLines(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.syncLines", args, ct);
    public static Task<JsonElement> AccountTestConnection(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.testConnection", args, ct);
    public static Task<JsonElement> AccountUpdateAccount(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("account.updateAccount", args, ct);

    // ---- 播放器 · player.* (40 条) ----
    public static Task<JsonElement> PlayerAddSubtitle(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.addSubtitle", args, ct);
    public static Task<JsonElement> PlayerChapterInfo(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.chapterInfo", args, ct);
    public static Task<JsonElement> PlayerGetMpvConf(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.getMpvConf", args, ct);
    public static Task<JsonElement> PlayerGetPlaybackPrefs(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.getPlaybackPrefs", args, ct);
    public static Task<JsonElement> PlayerGetScreenshotDir(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.getScreenshotDir", args, ct);
    public static Task<JsonElement> PlayerMpvCommand(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.mpvCommand", args, ct);
    public static Task<JsonElement> PlayerMpvGet(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.mpvGet", args, ct);
    public static Task<JsonElement> PlayerMpvSet(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.mpvSet", args, ct);
    public static Task<JsonElement> PlayerOpts(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.opts", args, ct);
    public static Task<JsonElement> PlayerPlay(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.play", args, ct);
    public static Task<JsonElement> PlayerPlayExternal(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.playExternal", args, ct);
    public static Task<JsonElement> PlayerPlayLocal(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.playLocal", args, ct);
    public static Task<JsonElement> PlayerScreenshot(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.screenshot", args, ct);
    public static Task<JsonElement> PlayerSeek(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.seek", args, ct);
    public static Task<JsonElement> PlayerSetAspectRatio(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setAspectRatio", args, ct);
    public static Task<JsonElement> PlayerSetAudioDelay(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setAudioDelay", args, ct);
    public static Task<JsonElement> PlayerSetHwdec(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setHwdec", args, ct);
    public static Task<JsonElement> PlayerSetMpvConf(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setMpvConf", args, ct);
    public static Task<JsonElement> PlayerSetMute(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setMute", args, ct);
    public static Task<JsonElement> PlayerSetPause(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setPause", args, ct);
    public static Task<JsonElement> PlayerSetPlaybackPrefs(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setPlaybackPrefs", args, ct);
    public static Task<JsonElement> PlayerSetScreenshotDir(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setScreenshotDir", args, ct);
    public static Task<JsonElement> PlayerSetSecondarySub(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setSecondarySub", args, ct);
    public static Task<JsonElement> PlayerSetSecondarySubOpts(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setSecondarySubOpts", args, ct);
    public static Task<JsonElement> PlayerSetShaderLevel(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setShaderLevel", args, ct);
    public static Task<JsonElement> PlayerSetSpeed(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setSpeed", args, ct);
    public static Task<JsonElement> PlayerSetSubDelay(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setSubDelay", args, ct);
    public static Task<JsonElement> PlayerSetSubStyle(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setSubStyle", args, ct);
    public static Task<JsonElement> PlayerSetTrack(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setTrack", args, ct);
    public static Task<JsonElement> PlayerSetTrackRegexes(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setTrackRegexes", args, ct);
    public static Task<JsonElement> PlayerSetVolume(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.setVolume", args, ct);
    public static Task<JsonElement> PlayerShaderLevels(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.shaderLevels", args, ct);
    public static Task<JsonElement> PlayerStatus(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.status", args, ct);
    public static Task<JsonElement> PlayerStopPlayback(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.stopPlayback", args, ct);
    public static Task<JsonElement> PlayerTakePending(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.takePending", args, ct);
    public static Task<JsonElement> PlayerThumbnail(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.thumbnail", args, ct);
    public static Task<JsonElement> PlayerTracks(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.tracks", args, ct);
    public static Task<JsonElement> PlayerValidateTrackRegex(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.validateTrackRegex", args, ct);
    public static Task<JsonElement> PlayerWindowClose(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.windowClose", args, ct);
    public static Task<JsonElement> PlayerWindowOpen(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("player.windowOpen", args, ct);

    // ---- 媒体源(浏览型 / 影视目录) · source.* (14 条) ----
    public static Task<JsonElement> SourceCatalog(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.catalog", args, ct);
    public static Task<JsonElement> SourceCategories(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.categories", args, ct);
    public static Task<JsonElement> SourceCurrentSource(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.currentSource", args, ct);
    public static Task<JsonElement> SourceListDir(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.listDir", args, ct);
    public static Task<JsonElement> SourceLogin(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.login", args, ct);
    public static Task<JsonElement> SourceMediaDetail(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.mediaDetail", args, ct);
    public static Task<JsonElement> SourcePasswordLogin(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.passwordLogin", args, ct);
    public static Task<JsonElement> SourcePlay(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.play", args, ct);
    public static Task<JsonElement> SourceQrPoll(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.qrPoll", args, ct);
    public static Task<JsonElement> SourceQrStart(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.qrStart", args, ct);
    public static Task<JsonElement> SourceQuarkScanPoll(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.quarkScanPoll", args, ct);
    public static Task<JsonElement> SourceQuarkScanStart(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.quarkScanStart", args, ct);
    public static Task<JsonElement> SourceSearch(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.search", args, ct);
    public static Task<JsonElement> SourceWatchdog(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("source.watchdog", args, ct);

    // ---- Ani-RSS 管理 · anirss.* (51 条) ----
    public static Task<JsonElement> AnirssAbout(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.about", args, ct);
    public static Task<JsonElement> AnirssAddAni(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.addAni", args, ct);
    public static Task<JsonElement> AnirssAniBt(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.aniBt", args, ct);
    public static Task<JsonElement> AnirssAniBtGroup(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.aniBtGroup", args, ct);
    public static Task<JsonElement> AnirssAnimeGardenGroup(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.animeGardenGroup", args, ct);
    public static Task<JsonElement> AnirssAnimeGardenList(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.animeGardenList", args, ct);
    public static Task<JsonElement> AnirssBatchEnable(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.batchEnable", args, ct);
    public static Task<JsonElement> AnirssBatchScrape(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.batchScrape", args, ct);
    public static Task<JsonElement> AnirssClearCache(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.clearCache", args, ct);
    public static Task<JsonElement> AnirssClearLogs(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.clearLogs", args, ct);
    public static Task<JsonElement> AnirssClearToken(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.clearToken", args, ct);
    public static Task<JsonElement> AnirssDeleteAni(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.deleteAni", args, ct);
    public static Task<JsonElement> AnirssDownloadLoginTest(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.downloadLoginTest", args, ct);
    public static Task<JsonElement> AnirssDownloadLogs(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.downloadLogs", args, ct);
    public static Task<JsonElement> AnirssDownloadPath(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.downloadPath", args, ct);
    public static Task<JsonElement> AnirssExportConfigUrl(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.exportConfigUrl", args, ct);
    public static Task<JsonElement> AnirssGetAniBySubjectId(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.getAniBySubjectId", args, ct);
    public static Task<JsonElement> AnirssGetBgmTitle(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.getBgmTitle", args, ct);
    public static Task<JsonElement> AnirssGetConfig(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.getConfig", args, ct);
    public static Task<JsonElement> AnirssGetEmbyViews(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.getEmbyViews", args, ct);
    public static Task<JsonElement> AnirssGetSubtitles(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.getSubtitles", args, ct);
    public static Task<JsonElement> AnirssGetThemoviedbGroup(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.getThemoviedbGroup", args, ct);
    public static Task<JsonElement> AnirssGetThemoviedbName(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.getThemoviedbName", args, ct);
    public static Task<JsonElement> AnirssImportConfig(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.importConfig", args, ct);
    public static Task<JsonElement> AnirssListAni(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.listAni", args, ct);
    public static Task<JsonElement> AnirssLogs(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.logs", args, ct);
    public static Task<JsonElement> AnirssMeBgm(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.meBgm", args, ct);
    public static Task<JsonElement> AnirssMikan(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.mikan", args, ct);
    public static Task<JsonElement> AnirssMikanGroup(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.mikanGroup", args, ct);
    public static Task<JsonElement> AnirssNewNotification(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.newNotification", args, ct);
    public static Task<JsonElement> AnirssPing(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.ping", args, ct);
    public static Task<JsonElement> AnirssPlayList(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.playList", args, ct);
    public static Task<JsonElement> AnirssPreviewAni(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.previewAni", args, ct);
    public static Task<JsonElement> AnirssPreviewItems(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.previewItems", args, ct);
    public static Task<JsonElement> AnirssProxyImageUrl(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.proxyImageUrl", args, ct);
    public static Task<JsonElement> AnirssRate(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.rate", args, ct);
    public static Task<JsonElement> AnirssRefreshAll(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.refreshAll", args, ct);
    public static Task<JsonElement> AnirssRefreshAni(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.refreshAni", args, ct);
    public static Task<JsonElement> AnirssRefreshCover(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.refreshCover", args, ct);
    public static Task<JsonElement> AnirssRssToAni(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.rssToAni", args, ct);
    public static Task<JsonElement> AnirssScrape(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.scrape", args, ct);
    public static Task<JsonElement> AnirssSearchBgm(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.searchBgm", args, ct);
    public static Task<JsonElement> AnirssServerUpdate(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.serverUpdate", args, ct);
    public static Task<JsonElement> AnirssSetAni(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.setAni", args, ct);
    public static Task<JsonElement> AnirssSetConfig(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.setConfig", args, ct);
    public static Task<JsonElement> AnirssSetRate(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.setRate", args, ct);
    public static Task<JsonElement> AnirssStop(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.stop", args, ct);
    public static Task<JsonElement> AnirssTestIpWhitelist(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.testIpWhitelist", args, ct);
    public static Task<JsonElement> AnirssTestProxy(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.testProxy", args, ct);
    public static Task<JsonElement> AnirssTorrentsInfos(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.torrentsInfos", args, ct);
    public static Task<JsonElement> AnirssUpdateTotalEpisodeNumber(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("anirss.updateTotalEpisodeNumber", args, ct);

    // ---- 弹幕 · danmaku.* (14 条) ----
    public static Task<JsonElement> DanmakuAutoLoad(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.autoLoad", args, ct);
    public static Task<JsonElement> DanmakuCacheClear(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.cacheClear", args, ct);
    public static Task<JsonElement> DanmakuCacheSize(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.cacheSize", args, ct);
    public static Task<JsonElement> DanmakuEpisodes(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.episodes", args, ct);
    public static Task<JsonElement> DanmakuFilter(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.filter", args, ct);
    public static Task<JsonElement> DanmakuGetDanmakuConfig(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.getDanmakuConfig", args, ct);
    public static Task<JsonElement> DanmakuGetOfficialDanmaku(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.getOfficialDanmaku", args, ct);
    public static Task<JsonElement> DanmakuImportBlocklist(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.importBlocklist", args, ct);
    public static Task<JsonElement> DanmakuLoad(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.load", args, ct);
    public static Task<JsonElement> DanmakuLoadLocal(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.loadLocal", args, ct);
    public static Task<JsonElement> DanmakuMatch(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.match", args, ct);
    public static Task<JsonElement> DanmakuMinAutoScore(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.minAutoScore", args, ct);
    public static Task<JsonElement> DanmakuSearch(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.search", args, ct);
    public static Task<JsonElement> DanmakuSetDanmakuConfig(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("danmaku.setDanmakuConfig", args, ct);

    // ---- 插件 · plugin.* (22 条) ----
    public static Task<JsonElement> PluginDevPoll(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.devPoll", args, ct);
    public static Task<JsonElement> PluginDisable(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.disable", args, ct);
    public static Task<JsonElement> PluginEnable(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.enable", args, ct);
    public static Task<JsonElement> PluginExtensions(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.extensions", args, ct);
    public static Task<JsonElement> PluginInstall(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.install", args, ct);
    public static Task<JsonElement> PluginInvokeField(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.invokeField", args, ct);
    public static Task<JsonElement> PluginList(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.list", args, ct);
    public static Task<JsonElement> PluginMarketAddSource(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.marketAddSource", args, ct);
    public static Task<JsonElement> PluginMarketInstall(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.marketInstall", args, ct);
    public static Task<JsonElement> PluginMarketList(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.marketList", args, ct);
    public static Task<JsonElement> PluginMarketRemoveSource(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.marketRemoveSource", args, ct);
    public static Task<JsonElement> PluginMarketSources(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.marketSources", args, ct);
    public static Task<JsonElement> PluginMarketToggleSource(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.marketToggleSource", args, ct);
    public static Task<JsonElement> PluginPanels(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.panels", args, ct);
    public static Task<JsonElement> PluginPermissionCatalog(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.permissionCatalog", args, ct);
    public static Task<JsonElement> PluginPickDevDir(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.pickDevDir", args, ct);
    public static Task<JsonElement> PluginPickInstall(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.pickInstall", args, ct);
    public static Task<JsonElement> PluginReload(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.reload", args, ct);
    public static Task<JsonElement> PluginSources(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.sources", args, ct);
    public static Task<JsonElement> PluginTrigger(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.trigger", args, ct);
    public static Task<JsonElement> PluginUiRespond(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.uiRespond", args, ct);
    public static Task<JsonElement> PluginUninstall(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("plugin.uninstall", args, ct);

    // ---- 下载 · download.* (8 条) ----
    public static Task<JsonElement> DownloadAndApplyUpdate(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("download.andApplyUpdate", args, ct);
    public static Task<JsonElement> DownloadClearCompleted(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("download.clearCompleted", args, ct);
    public static Task<JsonElement> DownloadEnqueue(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("download.enqueue", args, ct);
    public static Task<JsonElement> DownloadList(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("download.list", args, ct);
    public static Task<JsonElement> DownloadPause(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("download.pause", args, ct);
    public static Task<JsonElement> DownloadRemove(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("download.remove", args, ct);
    public static Task<JsonElement> DownloadResume(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("download.resume", args, ct);
    public static Task<JsonElement> DownloadSetThreads(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("download.setThreads", args, ct);

    // ---- 同步(Trakt / Bangumi / 日历) · sync.* (15 条) ----
    public static Task<JsonElement> SyncBangumiAccount(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.bangumiAccount", args, ct);
    public static Task<JsonElement> SyncBangumiAuthorizeUrl(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.bangumiAuthorizeUrl", args, ct);
    public static Task<JsonElement> SyncBangumiCalendar(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.bangumiCalendar", args, ct);
    public static Task<JsonElement> SyncBangumiExchange(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.bangumiExchange", args, ct);
    public static Task<JsonElement> SyncBangumiLoginToken(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.bangumiLoginToken", args, ct);
    public static Task<JsonElement> SyncBangumiLogout(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.bangumiLogout", args, ct);
    public static Task<JsonElement> SyncBangumiSetCollection(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.bangumiSetCollection", args, ct);
    public static Task<JsonElement> SyncBangumiSummary(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.bangumiSummary", args, ct);
    public static Task<JsonElement> SyncBangumiUpdateEpisode(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.bangumiUpdateEpisode", args, ct);
    public static Task<JsonElement> SyncTraktAccount(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.traktAccount", args, ct);
    public static Task<JsonElement> SyncTraktCalendar(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.traktCalendar", args, ct);
    public static Task<JsonElement> SyncTraktDeviceCode(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.traktDeviceCode", args, ct);
    public static Task<JsonElement> SyncTraktLogout(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.traktLogout", args, ct);
    public static Task<JsonElement> SyncTraktPoll(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.traktPoll", args, ct);
    public static Task<JsonElement> SyncTraktScrobble(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("sync.traktScrobble", args, ct);

    // ---- 字幕翻译 / Whisper(桌面独占) · translate.* (9 条) ----
    public static Task<JsonElement> TranslateLiveStart(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("translate.liveStart", args, ct);
    public static Task<JsonElement> TranslateLiveStop(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("translate.liveStop", args, ct);
    public static Task<JsonElement> TranslateSubtitle(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("translate.subtitle", args, ct);
    public static Task<JsonElement> TranslateTranslationEngineStatus(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("translate.translationEngineStatus", args, ct);
    public static Task<JsonElement> TranslateWhisperDelete(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("translate.whisperDelete", args, ct);
    public static Task<JsonElement> TranslateWhisperDeps(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("translate.whisperDeps", args, ct);
    public static Task<JsonElement> TranslateWhisperDownload(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("translate.whisperDownload", args, ct);
    public static Task<JsonElement> TranslateWhisperDownloadFfmpeg(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("translate.whisperDownloadFfmpeg", args, ct);
    public static Task<JsonElement> TranslateWhisperModels(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("translate.whisperModels", args, ct);

    // ---- 设置与偏好 · prefs.* (25 条) ----
    public static Task<JsonElement> PrefsApplyPrefs(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.applyPrefs", args, ct);
    public static Task<JsonElement> PrefsCfProxyDisable(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.cfProxyDisable", args, ct);
    public static Task<JsonElement> PrefsCfProxyEnable(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.cfProxyEnable", args, ct);
    public static Task<JsonElement> PrefsCfProxyStatus(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.cfProxyStatus", args, ct);
    public static Task<JsonElement> PrefsCfSpeedTest(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.cfSpeedTest", args, ct);
    public static Task<JsonElement> PrefsConfigExportQr(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.configExportQr", args, ct);
    public static Task<JsonElement> PrefsConfigImportQr(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.configImportQr", args, ct);
    public static Task<JsonElement> PrefsGetPrefetchSettings(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.getPrefetchSettings", args, ct);
    public static Task<JsonElement> PrefsGetPrefs(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.getPrefs", args, ct);
    public static Task<JsonElement> PrefsGetPreloadSettings(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.getPreloadSettings", args, ct);
    public static Task<JsonElement> PrefsGetProxy(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.getProxy", args, ct);
    public static Task<JsonElement> PrefsGetTranslationSettings(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.getTranslationSettings", args, ct);
    public static Task<JsonElement> PrefsGetUpdateSettings(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.getUpdateSettings", args, ct);
    public static Task<JsonElement> PrefsGetWritebackSettings(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.getWritebackSettings", args, ct);
    public static Task<JsonElement> PrefsIconLibrary(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.iconLibrary", args, ct);
    public static Task<JsonElement> PrefsPreloadCancel(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.preloadCancel", args, ct);
    public static Task<JsonElement> PrefsPreloadItem(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.preloadItem", args, ct);
    public static Task<JsonElement> PrefsSetDetailBlur(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.setDetailBlur", args, ct);
    public static Task<JsonElement> PrefsSetPrefetchSettings(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.setPrefetchSettings", args, ct);
    public static Task<JsonElement> PrefsSetPrefs(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.setPrefs", args, ct);
    public static Task<JsonElement> PrefsSetPreloadSettings(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.setPreloadSettings", args, ct);
    public static Task<JsonElement> PrefsSetProxy(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.setProxy", args, ct);
    public static Task<JsonElement> PrefsSetTranslationSettings(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.setTranslationSettings", args, ct);
    public static Task<JsonElement> PrefsSetUpdateSettings(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.setUpdateSettings", args, ct);
    public static Task<JsonElement> PrefsSetWritebackSettings(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("prefs.setWritebackSettings", args, ct);

    // ---- 系统 · system.* (13 条) ----
    public static Task<JsonElement> SystemAfdianSponsorUrl(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("system.afdianSponsorUrl", args, ct);
    public static Task<JsonElement> SystemAfdianVerify(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("system.afdianVerify", args, ct);
    public static Task<JsonElement> SystemCacheSize(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("system.cacheSize", args, ct);
    public static Task<JsonElement> SystemCapabilities(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("system.capabilities", args, ct);
    public static Task<JsonElement> SystemCheckUpdate(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("system.checkUpdate", args, ct);
    public static Task<JsonElement> SystemClearCache(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("system.clearCache", args, ct);
    public static Task<JsonElement> SystemDataPaths(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("system.dataPaths", args, ct);
    public static Task<JsonElement> SystemExportDiagnostics(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("system.exportDiagnostics", args, ct);
    public static Task<JsonElement> SystemOpenDataDir(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("system.openDataDir", args, ct);
    public static Task<JsonElement> SystemPickDirectory(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("system.pickDirectory", args, ct);
    public static Task<JsonElement> SystemPickFile(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("system.pickFile", args, ct);
    public static Task<JsonElement> SystemPickLocalFolder(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("system.pickLocalFolder", args, ct);
    public static Task<JsonElement> SystemPing(this ILinPlayerCommands c, object? args = null, CancellationToken ct = default)
        => c.CallAsync("system.ping", args, ct);
}
