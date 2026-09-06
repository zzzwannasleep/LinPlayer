package xyz.linplayer.app.ui.pages

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.sp
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import xyz.linplayer.app.core.Logs
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavController
import androidx.navigation.toRoute
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.ToastKind
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.strList
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.long
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.Hairline
import xyz.linplayer.app.ui.components.LpCell
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.components.Panel
import xyz.linplayer.app.ui.components.SegRow
import xyz.linplayer.app.ui.components.StepperRow
import xyz.linplayer.app.ui.components.rememberScrolled
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.Sp

/**
 * 设置(U1.15)。**一级列表 + 二级页**(手机没有主从两栏的宽度)。
 *
 * ★ 交互口径:**改完即生效、零保存按钮、越界让核心层拒绝、失败回滚**(UI_MOBILE.md §6.2)。
 * ★ 手机端比 PC 少一项:**快捷键**(没有键盘)。多的没有。
 * ★ **`unsupported` 里的命令,对应入口在启动时就不画** —— 不要等点了才 E_UNSUPPORTED。
 * ☠ **只列已经做好的**【用户定 2026-09-06】。原来还有弹幕 / 预加载 / 代理 /
 *   跨服续播 / Trakt·Bangumi 五条,点进去是一张「把核心层返回的键原样列出来」的表 ——
 *   开关拨了不落库、数值不能改。那不是「做了一半」,那是**一个装成功能的入口**:
 *   用户点进去、拨一下、以为设上了。宁可不列。要做的时候各自补一个真面板再挂回来。
 */
@Composable
fun SettingsPage(nav: NavController) {
    val list = rememberLazyListState()

    LpScaffold("设置", onBack = { nav.popBackStack() }, scrolled = rememberScrolled(list)) { pad ->
        LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
            item("g1") { GroupLabel("通用") }
            item("p1") {
                Panel(Modifier.padding(horizontal = Sp.x16)) {
                    LpCell("外观", icon = LpIcons.image) { nav.navigate(Route.SettingsSub("appearance")) }
                    Hairline()
                    LpCell("播放器", icon = LpIcons.play) { nav.navigate(Route.SettingsSub("player")) }
                }
            }
            item("g2") { GroupLabel("网络") }
            item("p2") {
                Panel(Modifier.padding(horizontal = Sp.x16)) {
                    LpCell("多线程加载", icon = LpIcons.cloud) { nav.navigate(Route.SettingsSub("prefetch")) }
                }
            }
            item("g4") { GroupLabel("其它") }
            item("p4") {
                Panel(Modifier.padding(horizontal = Sp.x16)) {
                    // 「已屏蔽的内容」是**隐藏类功能的集中解除列表** ——
                    // 没有它的话屏蔽了就再也解除不了
                    LpCell("已屏蔽的内容", icon = LpIcons.lock) {
                        nav.navigate(Route.SettingsSub("blocked"))
                    }
                    Hairline()
                    LpCell("插件", icon = LpIcons.plugin) { nav.navigate(Route.Plugins) }
                    Hairline()
                    LpCell("文件浏览", icon = LpIcons.folder) { nav.navigate(Route.Browse) }
                    Hairline()
                    LpCell("存储与数据目录", icon = LpIcons.file) { nav.navigate(Route.SettingsSub("storage")) }
                    Hairline()
                    LpCell("关于", icon = LpIcons.info) { nav.navigate(Route.SettingsSub("about")) }
                }
            }
            item("tail") { Spacer(Modifier.height(Sp.x34)) }
        }
    }
}

@Composable
private fun GroupLabel(t: String) =
    Text(t, Modifier.padding(start = Sp.x26, top = Sp.x20, bottom = Sp.x8),
        color = Lp.colors.fg3, fontSize = 12.sp)

/** 设置二级页。各面板**进入时各自拉自己的配置**;同一面板里的多个请求**必须并发**。 */
@Composable
fun SettingsSubPage(nav: NavController, entry: NavBackStackEntry) {
    val route = entry.toRoute<Route.SettingsSub>()
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()

    val title = when (route.group) {
        "appearance" -> "外观"; "player" -> "播放器"; "prefetch" -> "多线程加载"
        "blocked" -> "已屏蔽的内容"; "storage" -> "存储与数据目录"; else -> "关于"
    }

    LpScaffold(title, subtitle = "设置", onBack = { nav.popBackStack() },
        scrolled = rememberScrolled(list)) { pad ->
        LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
            item("body") {
                when (route.group) {
                    "appearance" -> AppearancePanel()
                    "player" -> PlayerPrefsPanel()
                    "prefetch" -> PrefetchPanel()
                    "blocked" -> BlockedPanel()
                    "storage" -> StoragePanel()
                    else -> AboutPanel()
                }
            }
            item("tail") { Spacer(Modifier.height(Sp.x34)) }
        }
    }
}

/**
 * 外观。
 *
 * ★ 主题走 [UiPrefs](本机 SharedPreferences),**不走核心层** ——
 *   `prefs.setPrefs` 只认 `audio_lang` / `sub_lang` / `sub_enabled`,
 *   根本没有 theme 这一项。原来往它塞 `theme` 的写法是**一个永远不生效的开关**:
 *   核心层照常返回成功,配置里什么都没变。这类「设了没反应」是本仓库最难查的一种。
 *   而且深浅色本来就不该跨设备同步 —— 手机上强制深色不代表电视上也要。
 */
@Composable
private fun AppearancePanel() {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val theme = when (xyz.linplayer.app.data.UiPrefs.theme.value) {
        "dark" -> "深色"; "light" -> "浅色"; else -> "跟随系统"
    }
    Panel(Modifier.padding(Sp.x16)) {
        SegRow("主题", listOf("跟随系统", "深色", "浅色"), theme, { v ->
            xyz.linplayer.app.data.UiPrefs.setTheme(ctx, when (v) {
                "深色" -> "dark"; "浅色" -> "light"; else -> "system"
            })
        }, sub = "深浅两套都调过。跟随系统时晚上自动变暗;这一项只影响这台设备")
    }
}

@Composable
private fun PlayerPrefsPanel() {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    var prefs by remember { mutableStateOf<JsonObject?>(null) }
    LaunchedEffect(Unit) {
        prefs = runCatching { app.call("player.getPlaybackPrefs") }.getOrNull().obj()
    }
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val engine = if (xyz.linplayer.app.data.UiPrefs.engine.value == "exo") "ExoPlayer" else "mpv"
    Panel(Modifier.padding(Sp.x16)) {
        /* 内核切换【用户定 2026-09-06】。
           ★ 换内核**要退出播放页重进才生效** —— 正在播的那一片不会当场换过去。
             当场换等于中途拆掉解码器再重建,seek 位置、上报会话、Surface 三样都要重来,
             为一个一年按一次的开关背这套复杂度不值。这句话必须写在界面上,
             不写的话用户会以为开关没生效。 */
        SegRow("播放内核", listOf("mpv", "ExoPlayer"), engine, { v ->
            xyz.linplayer.app.data.UiPrefs.setEngine(ctx, if (v == "ExoPlayer") "exo" else "mpv")
        }, sub = "mpv 认的格式多、字幕全;ExoPlayer 走安卓自带解码,更省电也更稳。" +
            "换完要退出当前播放再进才生效")
        Hairline()
        LpCell("后台播放", sub = "切到别的应用时音频继续,通知栏可以控制",
            switch = prefs.bool("background_play"),
            onSwitch = { v -> setPref(app, scope, "player.setPlaybackPrefs", "background_play", v) })
        Hairline()
        LpCell("播完自动下一集", switch = prefs.bool("auto_next"),
            onSwitch = { v -> setPref(app, scope, "player.setPlaybackPrefs", "auto_next", v) })
        Hairline()
        LpCell("跳过片头片尾", switch = prefs.bool("skip_intro"),
            onSwitch = { v -> setPref(app, scope, "player.setPlaybackPrefs", "skip_intro", v) })
    }
}

/**
 * 多线程加载。
 *
 * ★ 它**不是一个全局开关**:核心层存的是一张「对哪几台服务器开」的清单
 *   (`settings.servers`)。所以这里的开关 = 把**当前服务器**放进 / 移出那张表。
 *   原来传的 `enabled` 核心层根本不读 —— 又一个永远不生效的开关。
 * ★ 线程数下限是 **2**:核心层对 <2 或 >4 直接回 `E_INVALID`
 *   (它故意不静默夹紧 —— 夹紧会让用户以为设了 8 生效了)。
 */
@Composable
private fun PrefetchPanel() {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val session by app.session.collectAsStateWithLifecycle()
    var servers by remember { mutableStateOf<List<String>>(emptyList()) }
    var threads by remember { mutableStateOf(2.0) }
    var cacheBytes by remember { mutableStateOf(0L) }

    suspend fun push(newServers: List<String>, newThreads: Int) {
        val payload = JsonObject(mapOf("settings" to JsonObject(mapOf(
            "servers" to kotlinx.serialization.json.JsonArray(
                newServers.map { kotlinx.serialization.json.JsonPrimitive(it) }),
            "threads" to kotlinx.serialization.json.JsonPrimitive(newThreads),
            "cache_bytes" to kotlinx.serialization.json.JsonPrimitive(cacheBytes),
        ))))
        app.call("prefs.setPrefetchSettings", payload)
    }

    LaunchedEffect(Unit) {
        val o = runCatching { app.call("prefs.getPrefetchSettings") }.getOrNull().obj()
        servers = o.strList("servers")
        threads = (o.long("threads") ?: 2L).toDouble()
        cacheBytes = o.long("cache_bytes") ?: 0L
    }

    val cur = session?.server
    val on = cur != null && cur in servers
    Panel(Modifier.padding(Sp.x16)) {
        LpCell("对这台服务器开启", sub = "开着不一定更快 —— 收益看服务端给不给多连接",
            switch = on, onSwitch = { v ->
                val srv = cur ?: return@LpCell
                val before = servers
                servers = if (v) servers + srv else servers - srv   // 乐观更新
                scope.launch {
                    runCatching { push(servers, threads.toInt()) }
                        .onFailure { servers = before; app.report(it) }   // ☠ 失败必须回滚
                }
            })
        Hairline()
        StepperRow("并发连接数", threads, 2.0, 4.0, 1.0, { v ->
            val before = threads
            threads = v
            scope.launch {
                runCatching { push(servers, v.toInt()) }
                    .onFailure { threads = before; app.report(it) }
            }
        }, sub = "只支持 2~4;超出核心层会拒绝并回滚", fmt = { it.toInt().toString() })
    }
}

@Composable
private fun BlockedPanel() {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    var items by remember { mutableStateOf<List<Pair<String, String>>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var reload by remember { mutableStateOf(0) }
    LaunchedEffect(reload) {
        items = runCatching { app.call("emby.blockedList") }.getOrNull().arr().mapNotNull {
            val o = it.obj() ?: return@mapNotNull null
            (o.str("id") ?: return@mapNotNull null) to (o.str("name") ?: "(没有名字)")
        }
        loaded = true
    }
    if (loaded && items.isEmpty()) EmptyState("没有屏蔽过任何东西", "在封面上长按可以屏蔽一个条目或整个库。")
    else Panel(Modifier.padding(Sp.x16)) {
        items.forEachIndexed { i, (id, name) ->
            if (i > 0) Hairline()
            LpCell(name, value = "解除", arrow = false, onClick = {
                scope.launch {
                    runCatching {
                        app.call("emby.setBlocked",
                            args("id" to id, "name" to name, "blocked" to false))
                    }.onSuccess { reload++ }.onFailure { app.report(it) }
                }
            })
        }
    }
}

@Composable
private fun StoragePanel() {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    var paths by remember { mutableStateOf<String?>(null) }
    var size by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        // 同一面板里的多个请求**必须并发**:串行 await 会把后端本身的卡放大 N 倍
        launch { paths = runCatching { app.call("system.dataPaths") }.getOrNull().obj().str("dataRoot") }
        launch {
            size = runCatching { app.call("system.cacheSize") }.getOrNull().obj()
                .long("bytes")?.let { "%.1f MB".format(it / 1024.0 / 1024.0) }
        }
    }
    /* 导出日志。**必须让用户自己挑位置** —— 上一版写进应用私有目录然后弹一句
       「已导出到数据目录」,而那个目录任何文件管理器都进不去:
       用户点了、看见成功提示、然后什么也拿不到。那不是导出,是安慰剂。 */
    val ctx = LocalContext.current
    val save = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("text/plain")
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            runCatching {
                val diag = runCatching { app.call("system.exportDiagnostics") }.getOrNull()
                val text = "== 诊断 ==\n" + (diag?.toString() ?: "取不到") + "\n\n" + Logs.dump()
                withContext(Dispatchers.IO) {
                    ctx.contentResolver.openOutputStream(uri)?.use { it.write(text.toByteArray()) }
                }
            }.onSuccess { app.toast("日志已导出", ToastKind.Ok) }.onFailure { app.report(it) }
        }
    }

    Panel(Modifier.padding(Sp.x16)) {
        // 安卓的数据根是应用私有目录:**展示但不可点开** ——
        // 没有文件管理器能进去,给一个打不开的按钮比不给更糟
        LpCell("数据目录", sub = paths ?: "读取中…", arrow = false)
        Hairline()
        // 这个目录**是**能进去的(Android/data/<包名>/files/logs),所以照实写出来
        LpCell("日志目录", sub = Logs.dirPath.ifEmpty { "未初始化" }, arrow = false)
        Hairline()
        LpCell("导出日志", sub = "选个位置存下来,连 logcat 一起", onClick = {
            save.launch("linplayer-" + System.currentTimeMillis() + ".log")
        })
        Hairline()
        LpCell("缓存占用", value = size ?: "…", arrow = false)
        Hairline()
        LpCell("清理缓存", onClick = {
            scope.launch {
                runCatching { app.call("system.clearCache") }
                    .onSuccess { app.toast("缓存已清理", ToastKind.Ok); size = "0.0 MB" }
                    .onFailure { app.report(it) }
            }
        })
    }
}

@Composable
private fun AboutPanel() {
    val app = LocalApp.current
    val caps by app.caps.collectAsStateWithLifecycle()
    var update by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        update = runCatching { app.call("system.checkUpdate") }.getOrNull()
            .obj().str("version")
    }
    Panel(Modifier.padding(Sp.x16)) {
        LpCell("版本", value = caps.version, arrow = false)
        Hairline()
        // 安卓端**不做应用内更新**:安装权限对一个第三方播放器是过重的要求,
        // 而且各厂商 ROM 拦法各不相同。只提示,跳发布页
        LpCell("检查更新", value = update?.let { "有新版 $it" } ?: "已是最新", arrow = false)
    }
}

private fun setPref(
    app: xyz.linplayer.app.data.AppState,
    scope: kotlinx.coroutines.CoroutineScope,
    cmd: String, key: String, value: Boolean,
) {
    scope.launch {
        runCatching { app.call(cmd, args(key to value)) }.onFailure { app.report(it) }
    }
}
