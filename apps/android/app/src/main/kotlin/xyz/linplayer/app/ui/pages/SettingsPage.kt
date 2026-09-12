package xyz.linplayer.app.ui.pages

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.core.content.FileProvider
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import xyz.linplayer.app.core.Logs
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavController
import androidx.navigation.toRoute
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import xyz.linplayer.app.data.AppState
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.ToastKind
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.strList
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.long
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.ui.Route
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.ui.graphics.graphicsLayer
import xyz.linplayer.app.ui.components.BtnKind
import xyz.linplayer.app.ui.components.LpDialog
import xyz.linplayer.app.ui.components.LpIconButton
import xyz.linplayer.app.ui.components.LongShotTarget
import xyz.linplayer.app.ui.components.Dim2
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.Hairline
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.width
import xyz.linplayer.app.ui.components.LpButton
import xyz.linplayer.app.ui.components.LpField
import xyz.linplayer.app.ui.components.LpCell
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.components.Panel
import xyz.linplayer.app.ui.components.SegRow
import xyz.linplayer.app.ui.components.ToneChip
import xyz.linplayer.app.ui.components.StepperRow
import xyz.linplayer.app.ui.components.rememberScrolled
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.Sp
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.unit.dp

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
    // 截长屏认的就是这个滚动容器(设置里开了才画按钮,见 LongShot)
    LongShotTarget(list)


    LpScaffold("设置", onBack = { nav.popBackStack() }, scrolled = rememberScrolled(list)) { pad ->
        LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
            item("g1") { GroupLabel("通用") }
            item("p1") {
                Panel(Modifier.padding(horizontal = Sp.x16)) {
                    LpCell("外观", icon = LpIcons.image) { nav.navigate(Route.SettingsSub("appearance")) }
                    Hairline()
                    LpCell("播放器", icon = LpIcons.play) { nav.navigate(Route.SettingsSub("player")) }
                    Hairline()
                    LpCell("mpv 配置", icon = LpIcons.file) { nav.navigate(Route.SettingsSub("mpvconf")) }
                    Hairline()
                    // 弹幕源和屏蔽词跟内核无关,Exo 下也照样能加(播放页那个入口才分内核)
                    LpCell("弹幕", icon = LpIcons.danmaku) { nav.navigate(Route.SettingsSub("danmaku")) }
                    Hairline()
                    LpCell("截屏", icon = LpIcons.camera) { nav.navigate(Route.SettingsSub("shot")) }
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
                    // 和 PC 端读写同一份文件格式(docs/backup-format.md)
                    LpCell("备份与还原", icon = LpIcons.folder) {
                        nav.navigate(Route.SettingsSub("backup"))
                    }
                    Hairline()
                    LpCell("插件", icon = LpIcons.plugin) { nav.navigate(Route.Plugins) }
                    Hairline()
                    LpCell("文件浏览", icon = LpIcons.folder) { nav.navigate(Route.Browse) }
                    Hairline()
                    LpCell("存储与数据目录", icon = LpIcons.file) { nav.navigate(Route.SettingsSub("storage")) }
                    Hairline()
                    LpCell("更新", icon = LpIcons.version) { nav.navigate(Route.SettingsSub("update")) }
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
    // 截长屏认的就是这个滚动容器(设置里开了才画按钮,见 LongShot)
    LongShotTarget(list)


    val title = when (route.group) {
        "appearance" -> "外观"; "player" -> "播放器"; "shot" -> "截屏"
        "mpvconf" -> "mpv 配置"; "danmaku" -> "弹幕"
        "backup" -> "备份与还原"
        "prefetch" -> "多线程加载"
        "blocked" -> "已屏蔽的内容"; "storage" -> "存储与数据目录"
        "update" -> "更新"; else -> "关于"
    }

    LpScaffold(title, subtitle = "设置", onBack = { nav.popBackStack() },
        scrolled = rememberScrolled(list)) { pad ->
        LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
            item("body") {
                when (route.group) {
                    "appearance" -> AppearancePanel()
                    "player" -> PlayerPrefsPanel()
                    "shot" -> ShotPanel()
                    "mpvconf" -> MpvConfPanel()
                    "danmaku" -> DanmakuSettingsPanel()
                    "backup" -> BackupPanel()
                    "prefetch" -> PrefetchPanel()
                    "blocked" -> BlockedPanel()
                    "storage" -> StoragePanel()
                    "update" -> UpdatePanel()
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
    val app = LocalApp.current
    val font = xyz.linplayer.app.data.UiPrefs.uiFont.value
    /* 字体导入【用户定 2026-09-08】。
       ★ 文件类型过滤放到最宽,不按字体 MIME 筛:实测各家文件管理器给 .ttf 的
         MIME 五花八门(application/octet-stream 最常见),按字体类型筛的表现是
         「文件选择器里一个字体都看不见」—— 一个打不开的入口。
         是不是真字体由复制完那次 createFromFile 判。 */
    val pick = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        val path = importFont(ctx, uri)
        if (path == null) app.toast("这个文件不是能用的字体", ToastKind.Error)
        else {
            xyz.linplayer.app.data.UiPrefs.setFont(ctx, path)
            app.toast("字体已换", ToastKind.Ok)
        }
    }
    Panel(Modifier.padding(Sp.x16)) {
        SegRow("主题", listOf("跟随系统", "深色", "浅色"), theme, { v ->
            xyz.linplayer.app.data.UiPrefs.setTheme(ctx, when (v) {
                "深色" -> "dark"; "浅色" -> "light"; else -> "system"
            })
        }, sub = "深浅两套都调过。跟随系统时晚上自动变暗;这一项只影响这台设备")
        Hairline()
        LpCell(
            "界面字体",
            sub = if (font.isBlank()) "系统默认。选一个 .ttf / .otf 换掉全局字体"
            else "已换成 " + font.substringAfterLast('/'),
            onClick = { pick.launch(arrayOf("*/*")) },
        )
        // ★ 没换过就不画「恢复默认」—— 一个点了什么都不会发生的按钮
        if (font.isNotBlank()) {
            Hairline()
            LpCell("恢复默认字体", arrow = false, onClick = {
                xyz.linplayer.app.data.UiPrefs.setFont(ctx, "")
                clearFonts(ctx)
            })
        }
    }
}

/**
 * 把选中的字体复制进应用私有目录并返回落点。不是字体就返回 null。
 *
 * ☠ **必须复制一份。** SAF 给的 Uri 重启之后多半就没权限了,而字体是每次冷启动
 *   第一帧就要读的东西 —— 存 Uri 的表现是「今天好好的,明天开机字体没了」。
 * ☠ 文件名带时间戳:覆盖同一个路径的话,偏好里那个字符串没变,
 *   界面上那层 `remember(path)` 不会重算 —— 换了字体却一点变化都没有。
 * ★ 复制完当场 `createFromFile` 验一次。不验的话用户选了张图片进来,
 *   得到的是「设置显示已换、界面还是老样子」。
 */
private fun importFont(ctx: android.content.Context, uri: android.net.Uri): String? = runCatching {
    clearFonts(ctx)
    val dst = java.io.File(ctx.filesDir, "ui-font-" + System.currentTimeMillis() + ".ttf")
    ctx.contentResolver.openInputStream(uri)!!.use { i -> dst.outputStream().use { o -> i.copyTo(o) } }
    if (android.graphics.Typeface.createFromFile(dst) == null) {
        dst.delete()
        return null
    }
    dst.absolutePath
}.getOrNull()

/** 旧字体不留 —— 每换一次留一份的话,私有目录里会攒一堆几十 MB 的中文字体。 */
private fun clearFonts(ctx: android.content.Context) {
    ctx.filesDir.listFiles { f -> f.name.startsWith("ui-font-") }?.forEach { it.delete() }
}

@Composable
private fun PlayerPrefsPanel() {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    var prefs by remember { mutableStateOf<JsonObject?>(null) }
    LaunchedEffect(Unit) {
        prefs = runCatching { app.call("player.getPlaybackPrefs") }.getOrNull().obj()
    }
    /* ☠☠ **改完必须把新值写回本地这份 `prefs`。** 开关是**受控**控件 ——
       它显示的永远是 `prefs` 里的那个值。上一版只发命令不回填,于是每个开关
       拨过去又弹回来,用户看到的就是「三个按钮点不开」(2026-09-07 原话)。
       乐观更新 + 失败回滚,和多线程加载那一页同一套写法。 */
    fun flip(key: String, v: Boolean) {
        val before = prefs
        prefs = patch(before, key, JsonPrimitive(v))
        scope.launch {
            runCatching { app.call("player.setPlaybackPrefs", args(key to v)) }
                .onSuccess { r -> r.obj()?.let { prefs = it } }
                .onFailure { prefs = before; app.report(it) }
        }
    }
    fun pick(key: String, v: String) {
        val before = prefs
        prefs = patch(before, key, JsonPrimitive(v))
        scope.launch {
            runCatching { app.call("player.setPlaybackPrefs", args(key to v)) }
                .onSuccess { r -> r.obj()?.let { prefs = it } }
                .onFailure { prefs = before; app.report(it) }
        }
    }

    val ctx = androidx.compose.ui.platform.LocalContext.current
    val short = if (xyz.linplayer.app.data.UiPrefs.engine.value == "exo") "ExoPlayer" else "mpv"
    val long = if (short == "mpv") "ExoPlayer" else "mpv"
    Panel(Modifier.padding(Sp.x16)) {
        /* 播放键【用户定 2026-09-08:「短按 MPV、长按 EXO,允许调换位置」】。
           ★ 只给**短按**一个开关,长按恒是另一个 —— 两个各自能选的话会出现
             「短按长按都是 mpv」,那时长按就是坏的,而界面上看不出来。
           ★ 内核跟着**这一次起播**走,不改全局:长按试一次不该把设置也改掉。
           ★ 播放中不换内核 —— 当场换等于拆掉解码器再重建,seek 位置、上报会话、
             Surface 三样全要重来,为一个一年按一次的开关背这套复杂度不值。 */
        SegRow("播放键短按", listOf("mpv", "ExoPlayer"), short, { v ->
            xyz.linplayer.app.data.UiPrefs.setEngine(ctx, if (v == "ExoPlayer") "exo" else "mpv")
        }, sub = "长按播放键用另一个内核(现在是 " + long + ")。" +
            "mpv 认的格式多、字幕全;ExoPlayer 走安卓自带解码,更省电也更稳")
        Hairline()
        /* ★ 这一栏只放**核心层真的读**的那几项。上一版的「后台播放」「播完自动下一集」
           在核心层里连字段都没有:拨了返回成功、配置一个字没变,而且下次进来还是关着。
           不生效的选项直接删,不摆在界面上(用户 2026-09-04 的口径)。 */
        SegRow("硬件解码", listOf("自动", "关闭"),
            if (prefs.str("hwdec") == "no") "关闭" else "自动",
            { v -> pick("hwdec", if (v == "关闭") "no" else "auto-safe") },
            sub = "关掉更费电,但少数机型的花屏、绿屏只能靠它")
        Hairline()
        LpCell("杜比视界自动软解", sub = "DoVi 片源走硬解常见偏色,自动切软解画面才是对的",
            switch = prefs.bool("dolby_auto_sw"), onSwitch = { v -> flip("dolby_auto_sw", v) })
        Hairline()
        LpCell("跳过片头", switch = prefs.bool("skip_intro"),
            onSwitch = { v -> flip("skip_intro", v) })
        Hairline()
        LpCell("跳过片尾", switch = prefs.bool("skip_outro"),
            onSwitch = { v -> flip("skip_outro", v) })
        Hairline()
        LpCell("到了就自己跳", sub = "关着的话只弹一个「跳过」按钮,由你点",
            switch = prefs.bool("skip_auto"), onSwitch = { v -> flip("skip_auto", v) })
    }
}

/** 把一个键就地换掉,别的原样留着。乐观更新要的就是这一步。 */
private fun patch(o: JsonObject?, key: String, v: JsonPrimitive): JsonObject =
    JsonObject((o ?: JsonObject(emptyMap())).toMutableMap().apply { put(key, v) })

/**
 * mpv 配置【用户定 2026-09-08:「允许导入用户自己的 mpv.conf」】。
 *
 * ★ **只对 mpv 内核有效**,这句话必须写在界面上 —— 用 ExoPlayer 的人导入完
 *   什么都不会发生,不说清就是一个「设了没反应」的入口。
 * ★ 里面几行会被我们摘掉(vo / wid / config-dir 那几个:它们决定画面往哪儿画,
 *   放过去就是一片黑还不报错)。核心层会把摘掉的行写进日志。
 */
/**
 * 备份与还原(用户 2026-09-08)。
 *
 * ★ 和 PC 端**读写同一份文件**:格式、加密、合并规则全在核心层
 * (`prefs.backupExport` / `backupImport`),两端只负责挑文件。
 * 各写一份的话「互通」这件事就没有验收点了。
 * ★ 文件也能交给第三方播放器 —— 容器就是 Richasy/Rodel 的 CommonConfig,
 * 说明在 `docs/backup-format.md`。
 *
 * ☠ **导出必须让用户自己挑位置。** 写进应用私有目录再弹一句「已导出」的话,
 * 那个目录任何文件管理器都进不去 —— 用户看见成功提示、然后什么也拿不到
 * (导出日志那一栏踩过这一跤)。
 */
@Composable
private fun BackupPanel() {
    val app = LocalApp.current
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var withAccounts by remember { mutableStateOf(true) }
    var withSettings by remember { mutableStateOf(true) }
    var note by remember { mutableStateOf<String?>(null) }

    val save = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream")
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            runCatching {
                val r = app.call("prefs.backupExport", args(
                    "accounts" to withAccounts, "settings" to withSettings)).obj()
                val text = r.str("content") ?: error("核心层没有给出内容")
                withContext(Dispatchers.IO) {
                    ctx.contentResolver.openOutputStream(uri)?.use { it.write(text.toByteArray()) }
                }
                note = "已导出 ${r.long("bytes") ?: 0} 字节。" + (r.str("warning") ?: "")
            }.onSuccess { app.toast("备份已导出", ToastKind.Ok) }.onFailure { app.report(it) }
        }
    }

    val open = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            runCatching {
                /* 备份文件几十 KB 量级,整份读进来没问题;但还是要设上限 ——
                   用户选错一个几百 MB 的文件时,不该是 OOM 崩掉。 */
                val text = withContext(Dispatchers.IO) {
                    ctx.contentResolver.openInputStream(uri)?.use {
                        String(it.readBytes().let { b ->
                            if (b.size > 4 * 1024 * 1024) error("这个文件太大,不像备份文件") else b
                        })
                    }
                } ?: error("读不出这个文件")
                // 先看清楚再写:还原是不可逆的,选错一个文件只能一台一台删回去
                val pv = app.call("prefs.backupPreview", args("content" to text)).obj()
                val r = app.call("prefs.backupImport", args(
                    "content" to text,
                    "accounts" to withAccounts, "settings" to withSettings)).obj()
                note = "这份备份来自 ${pv.str("from") ?: "?"};还原 ${r.long("imported") ?: 0} 台," +
                    "现在共 ${r.long("total") ?: 0} 台。" +
                    if (r.bool("settings_restored")) "软件设置已还原,重启后全部生效。"
                    else "这份备份里没有软件设置。"
            }.onSuccess { app.toast("已还原", ToastKind.Ok) }.onFailure { app.report(it) }
        }
    }

    Panel(Modifier.padding(Sp.x16)) {
        LpCell("包含服务器地址与账号密码", value = if (withAccounts) "是" else "否",
            onClick = { withAccounts = !withAccounts })
        Hairline()
        LpCell("包含软件设置", value = if (withSettings) "是" else "否",
            onClick = { withSettings = !withSettings })
        Hairline()
        LpCell("导出到文件", sub = "选个位置存下来,PC 端能直接读", onClick = {
            save.launch("LinPlayer-备份-" + System.currentTimeMillis() + ".lpbak")
        })
        Hairline()
        LpCell("从文件还原", sub = "合并:这台机器上原有的服务器保留", onClick = {
            open.launch(arrayOf("*/*"))
        })
        Hairline()
        // ☠ 这句必须显眼:备份文件里带着 token 和密码,加密只是混淆级(密钥随文件走)
        LpCell("勾了账号的备份文件里有你所有服务器的登录凭据,只做了混淆,别公开分享。",
            arrow = false)
        note?.let { Hairline(); LpCell(it, arrow = false) }
    }
}

/**
 * 弹幕源与屏蔽词。
 *
 * ★ **极简**【用户 2026-09-10:「丑死了,一堆文字一堆说明」】——
 *   加源是一颗按钮 + 一个只有两格的弹窗,屏蔽词收进弹窗,说明文字全删。
 *   一屏之内看到的只有「有哪些源、什么顺序」。
 * ★ **顺序有用**:搜索结果按这张表的顺序分组(核心层 searchAllGrouped),
 *   常用的源排第一位就排在最上面。没有这一条的话排序就是个摆设。
 * ★ 屏蔽词落在核心层而不是各端各存一份:它跟着「备份与还原」走,
 *   而且自动加载和手动搜索必须用同一份。
 */
@Composable
private fun DanmakuSettingsPanel() {
    val app = LocalApp.current
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var official by remember { mutableStateOf<JsonObject?>(null) }
    var sources by remember { mutableStateOf<List<JsonObject>>(emptyList()) }
    var words by remember { mutableStateOf("") }
    var userCount by remember { mutableStateOf(0) }
    var adding by remember { mutableStateOf(false) }
    var editWords by remember { mutableStateOf(false) }
    var reload by remember { mutableStateOf(0) }

    LaunchedEffect(reload) {
        // 三个请求互不依赖 —— 串起来的话这一页要等三个往返才画得出来
        official = runCatching { app.call("danmaku.getOfficialDanmaku") }.getOrNull().obj()
        sources = runCatching { app.call("danmaku.getDanmakuConfig") }.getOrNull().arr()
            .mapNotNull { it.obj() }.filter { !it.bool("official") }
        val bw = runCatching { app.call("danmaku.getBlockwords") }.getOrNull().obj()
        words = bw?.strList("words").orEmpty().joinToString("\n")
        userCount = bw?.strList("users").orEmpty().size
    }

    suspend fun saveSources(list: List<JsonObject>) {
        runCatching {
            app.call("danmaku.setDanmakuConfig",
                JsonObject(mapOf("sources" to kotlinx.serialization.json.JsonArray(list))))
        }.onFailure { app.report(it) }
        reload++
    }

    val importXml = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            runCatching {
                val xml = withContext(Dispatchers.IO) {
                    ctx.contentResolver.openInputStream(uri)?.use {
                        val b = it.readBytes()
                        if (b.size > 8 * 1024 * 1024) error("这个文件太大,不像屏蔽表") else String(b)
                    }
                } ?: error("读不出这个文件")
                // 合并落库由核心层做 —— 两端各写一份合并逻辑,漏掉去重的那边会越导越长
                val r = app.call("danmaku.importBlocklist", args("xml" to xml)).obj()
                app.toast("导入 ${r.long("total_words") ?: 0} 个词、${r.long("total_users") ?: 0} 个用户",
                    ToastKind.Ok)
                reload++
            }.onFailure { app.report(it) }
        }
    }

    Column {
        Panel(Modifier.padding(Sp.x16)) {
            // 「没有」和「坏了」是两件事:不可用时才把核心层给的原因摊开
            LpCell("弹弹Play 官方源", arrow = false,
                value = if (official.bool("enabled")) "可用" else "不可用",
                sub = if (official.bool("enabled")) null else official.str("reason"))
        }
        GroupLabel("自建源")
        Panel(Modifier.padding(horizontal = Sp.x16)) {
            if (sources.isEmpty()) LpCell("还没有自建源", arrow = false)
            sources.forEachIndexed { i, src ->
                if (i > 0) Hairline()
                SourceRow(
                    name = src.str("name") ?: "(没名字)",
                    url = src.str("api_url") ?: "",
                    canUp = i > 0, canDown = i < sources.lastIndex,
                    onMove = { d -> scope.launch { saveSources(sources.moved(i, i + d)) } },
                    onDelete = {
                        scope.launch { saveSources(sources.filterIndexed { j, _ -> j != i }) }
                    },
                )
            }
        }
        Column(Modifier.padding(Sp.x16)) {
            LpButton("添加源", onClick = { adding = true })
        }
        GroupLabel("屏蔽")
        Panel(Modifier.padding(horizontal = Sp.x16)) {
            LpCell("屏蔽词", value = "${words.split("\n").count { it.isNotBlank() }} 个",
                onClick = { editWords = true })
            Hairline()
            LpCell("屏蔽用户", value = "$userCount 个", sub = "从弹弹Play 屏蔽表导入",
                onClick = { importXml.launch(arrayOf("*/*")) })
        }
        Spacer(Modifier.height(Sp.x20))
    }

    if (adding) AddSourceDialog({ adding = false }) { name, url ->
        scope.launch {
            saveSources(sources + JsonObject(mapOf(
                "id" to JsonPrimitive("u" + System.currentTimeMillis()),
                "name" to JsonPrimitive(name.ifBlank { "自建源" }),
                "api_url" to JsonPrimitive(url.trim()),
            )))
        }
        adding = false
    }

    if (editWords) BlockwordsDialog(words, { editWords = false }) { ws ->
        scope.launch {
            runCatching {
                app.call("danmaku.setBlockwords", JsonObject(mapOf(
                    "words" to kotlinx.serialization.json.JsonArray(ws.map { JsonPrimitive(it) }))))
            }.onSuccess { words = ws.joinToString("\n"); editWords = false }
                .onFailure { app.report(it) }
        }
    }
}

/** 把第 [from] 项挪到第 [to] 位。越界原样返回 —— 箭头到头了不该把表打乱。 */
internal fun <T> List<T>.moved(from: Int, to: Int): List<T> {
    if (from !in indices || to !in indices || from == to) return this
    val out = toMutableList()
    out.add(to, out.removeAt(from))
    return out
}

/** 一条自建源:名字 + 地址 + 上移 / 下移 / 删除。 */
@Composable
private fun SourceRow(
    name: String, url: String, canUp: Boolean, canDown: Boolean,
    onMove: (Int) -> Unit, onDelete: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(start = Sp.x16, end = Sp.x6, top = Sp.x6, bottom = Sp.x6),
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(name, color = Lp.colors.fg, fontSize = 14.sp, maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
            Dim3(url)
        }
        // 只有一个「向下」的箭头,向上那颗把它转过来 —— 不为一个方向再画一个图标
        if (canUp) Box(Modifier.graphicsLayer { rotationZ = 180f }) {
            LpIconButton(LpIcons.chevD, "上移", size = 18) { onMove(-1) }
        }
        if (canDown) LpIconButton(LpIcons.chevD, "下移", size = 18) { onMove(1) }
        LpIconButton(LpIcons.trash, "删除", size = 18) { onDelete() }
    }
}

/**
 * 加一条源:**只问名字和地址**【用户 2026-09-10】。
 *
 * ★ 鉴权方式不让用户选 —— 他也不知道什么是 pathToken。核心层从地址里推
 *   (setDanmakuConfig 的 DeriveAuth),推错了也比给一个四选一的下拉框强:
 *   那个框选错了同样不报错,只是搜不到。
 */
@Composable
private fun AddSourceDialog(onClose: () -> Unit, onAdd: (String, String) -> Unit) {
    var name by remember { mutableStateOf("") }
    var url by remember { mutableStateOf("") }
    LpDialog(onClose, "添加弹幕源") {
        LpField(name, { name = it }, "弹幕源名字")
        Spacer(Modifier.height(Sp.x10))
        LpField(url, { url = it }, "弹幕源链接")
        Spacer(Modifier.height(Sp.x16))
        Row(horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
            LpButton("取消", onClose, Modifier.weight(1f), BtnKind.Secondary)
            LpButton("添加", { if (url.isNotBlank()) onAdd(name, url) }, Modifier.weight(1f))
        }
    }
}

/** 屏蔽词编辑。收进弹窗 —— 设置页里摊着一个八行的文本框,整页就只剩它了。 */
@Composable
private fun BlockwordsDialog(init: String, onClose: () -> Unit, onSave: (List<String>) -> Unit) {
    var draft by remember { mutableStateOf(init) }
    LpDialog(onClose, "屏蔽词") {
        LpField(draft, { draft = it }, "一行一个", lines = 8)
        Spacer(Modifier.height(Sp.x16))
        Row(horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
            LpButton("取消", onClose, Modifier.weight(1f), BtnKind.Secondary)
            LpButton("保存", {
                onSave(draft.split("\n").map { it.trim() }.filter { it.isNotEmpty() }.distinct())
            }, Modifier.weight(1f))
        }
    }
}

@Composable
private fun MpvConfPanel() {
    val app = LocalApp.current
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var conf by remember { mutableStateOf<JsonObject?>(null) }
    var reload by remember { mutableStateOf(0) }
    LaunchedEffect(reload) {
        conf = runCatching { app.call("player.getMpvConf") }.getOrNull().obj()
    }
    val text = conf.str("text").orEmpty()
    val active = conf.bool("active")

    suspend fun push(body: String) {
        runCatching { app.call("player.setMpvConf", args("text" to body)) }
            .onSuccess { r -> conf = r.obj() }
            .onFailure { app.report(it) }
    }

    val pick = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val body = withContext(Dispatchers.IO) {
                runCatching {
                    ctx.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
                }.getOrNull()
            }
            // 256KB 封顶:mpv.conf 再长也到不了,到了多半是选错了文件
            if (body == null || body.size > (256 shl 10)) {
                app.toast("这个文件读不了,或者根本不是配置文件", ToastKind.Error)
                return@launch
            }
            push(String(body, Charsets.UTF_8))
            app.toast("已导入,下次起播生效", ToastKind.Ok)
        }
    }

    Panel(Modifier.padding(Sp.x16)) {
        LpCell(
            "当前配置",
            sub = if (active) "已导入 · " + text.lineSequence().count() + " 行" else "没有导入过",
            arrow = false,
        )
        Hairline()
        LpCell("导入 mpv.conf", sub = "选一个文本文件;换成新的会整份覆盖",
            onClick = { pick.launch(arrayOf("*/*")) })
        if (active) {
            Hairline()
            LpCell("清除", sub = "删掉配置,回到出厂状态", arrow = false, onClick = {
                scope.launch { push("") }
            })
        }
        Hairline()
        LpCell("只对 mpv 内核有效", sub = "ExoPlayer 走安卓自带解码,不读这份配置;" +
            "改动要退出当前播放再进才生效", arrow = false)
    }
    if (active && text.isNotBlank()) Panel(Modifier.padding(horizontal = Sp.x16)) {
        Text(text.lineSequence().take(20).joinToString("\n"),
            Modifier.padding(Sp.x12), color = Lp.colors.fg2, fontSize = 12.sp)
    }
}

/**
 * 截屏【用户定 2026-09-07】。
 *
 * ★ 这四项都存在 [UiPrefs](本机 SharedPreferences),**不走核心层** ——
 *   截屏整条路(PixelCopy 读回当前帧 → 叠字 → 写相册)都在 Kotlin 这一侧,
 *   核心层没有消费点。往 `prefs.setPrefs` 里塞它们只会得到一个永远不生效的开关,
 *   而那是本仓库最难查的一类 bug(外观页那一条就是这么栽的)。
 * ★ 位置只给四个角,不给自由坐标:一个能拖的水印会被拖到画面正中间。
 */
@Composable
private fun ShotPanel() {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val p = xyz.linplayer.app.data.UiPrefs
    Panel(Modifier.padding(Sp.x16)) {
        LpCell("截屏保存到", sub = "相册的 Pictures/LinPlayer;安卓 9 及以下落到应用目录",
            arrow = false)
        Hairline()
        LpCell("叠加系统时间", switch = p.shotTime.value,
            onSwitch = { v -> p.setShotFlag(ctx, xyz.linplayer.app.data.UiPrefs.K_SHOT_TIME, v) })
        if (p.shotTime.value) SegRow("时间的位置", CORNER_LABELS, cornerLabel(p.shotTimePos.value),
            { v -> p.setShotPos(ctx, xyz.linplayer.app.data.UiPrefs.K_SHOT_TIME_POS, cornerCode(v)) })
        Hairline()
        LpCell("叠加条目艺术字", sub = "这部片的片名艺术字(Emby 的 Logo 图),没有就不叠",
            switch = p.shotLogo.value,
            onSwitch = { v -> p.setShotFlag(ctx, xyz.linplayer.app.data.UiPrefs.K_SHOT_LOGO, v) })
        if (p.shotLogo.value) SegRow("艺术字的位置", CORNER_LABELS, cornerLabel(p.shotLogoPos.value),
            { v -> p.setShotPos(ctx, xyz.linplayer.app.data.UiPrefs.K_SHOT_LOGO_POS, cornerCode(v)) })
        Hairline()
        LpCell("截长屏按钮", sub = "可滚动的页面右下角出现一颗按钮,按一下把整页拼成长图",
            switch = p.longShot.value, onSwitch = { v -> p.setLongShot(ctx, v) })
    }
}

/**
 * 四个角。**存的是字母码,显示的是中文** —— 存中文的话改一次文案就把用户已有的设置弄丢了。
 *
 * ☠ 两个方向必须**互为反函数**。错开一格的表现是:用户选「右下」,存进去的是别的角,
 *   下次进设置页显示回「左上」—— 而这两个 `when` 各自看都完全正常,一句错都不报。
 *   `LogicTest` 拿这四个标签来回走一遍钉住它。
 */
internal val CORNER_LABELS = listOf("左上", "右上", "左下", "右下")

internal fun cornerLabel(code: String) = when (code) {
    "tr" -> "右上"; "bl" -> "左下"; "br" -> "右下"; else -> "左上"
}

internal fun cornerCode(label: String) = when (label) {
    "右上" -> "tr"; "左下" -> "bl"; "右下" -> "br"; else -> "tl"
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
        launch { paths = runCatching { app.call("system.dataPaths") }.getOrNull().obj().str("root") }
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

/**
 * 应用内一条龙更新:查 → 下 → 交给系统装包器。
 *
 * ☠ 原先这里**两处都是坏的**:`system.checkUpdate` 的版本号在 `update` 子对象里,
 * 直接 `.str("version")` 永远取到 null,于是不管有没有新版都显示「已是最新」;
 * 而核心层挑资产用的关键词在安卓上是 `linux`,APK 名里没有,**永远挑不出包**。
 * 两个都不报错 —— 这就是用户说的「检查更新也没啥用」。
 */
/** 更新说明最多占这么高。再长弹窗就比屏幕还高,底下两颗键点不到。 */
private val UpdateNotesMaxHeight = 320.dp

@Composable
private fun AboutPanel() {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val caps by app.caps.collectAsStateWithLifecycle()
    var newest by remember { mutableStateOf<JsonObject?>(null) }
    var checked by remember { mutableStateOf(false) }
    // 点一下直接开下载是不对的:手机上多半是流量,而且用户没看见这一版改了什么
    var offer by remember { mutableStateOf<JsonObject?>(null) }

    suspend fun check(): JsonObject? {
        val r = runCatching { app.call("system.checkUpdate") }.getOrNull().obj()
        checked = true
        newest = if (r.bool("has_update")) r?.get("update").obj() else null
        return newest
    }
    LaunchedEffect(Unit) { check() }

    Panel(Modifier.padding(Sp.x16)) {
        LpCell("版本", value = caps.version, arrow = false)
        Hairline()
        LpCell(
            "检查更新",
            value = newest.str("version")?.let { "有新版 $it" } ?: if (checked) "已是最新" else "…",
            sub = newest?.let { "点一下就下载并安装" },
            onClick = {
                scope.launch {
                    val u = check()
                    // 版本号报全(带 -buildN):下次又弹更新时用户才有东西可以对照
                    if (u == null) app.toast("已经是最新版本(${caps.version})") else offer = u
                }
            },
        )
    }

    UpdateFlow(offer) { offer = null }
}

/**
 * 有新版之后的两个弹窗:先给说明让人决定,再给进度。
 *
 * ★ 抽成顶层有两个各自成立的理由:两个入口(关于页手动查、启动自动查)各写一份的话,
 *   自动查那份迟早掉队 —— 而它恰恰是用户最少点到、最不容易发现坏掉的那条路;
 *   另一个是字段名门禁按「调用点往下 30 行」判响应字段,挤在 AboutPanel 里
 *   它会把进度条那几行算到 `system.checkUpdate` 头上,报一片假红。
 * ★ 下载跑在 [AppState.bg] 上,不是 `rememberCoroutineScope()`:后者随页面一起死,
 *   用户退出设置页就再也等不到那句「跳到系统安装界面」。
 */
@Composable
internal fun UpdateFlow(u: JsonObject?, onClose: () -> Unit) {
    if (u == null) return
    val app = LocalApp.current
    val ctx = LocalContext.current
    // 按 u 记忆:换了个新版本这两格要从头开始,否则上一次的进度会串到这一次
    var prog by remember(u) { mutableStateOf<JsonObject?>(null) }
    var downloading by remember(u) { mutableStateOf(false) }

    /* 更新说明在这儿是**第一次**被显示出来 —— 之前安卓端从头到尾没有任何地方
       读过 notes,点一下就开始下。说明本身也刚从「每次都一样的下载指引」换成
       这一版真实的提交清单(scripts/release-notes.sh)。 */
    if (!downloading) {
        val mb = (u.long("asset_size") ?: 0L) / 1048576.0
        LpDialog(onClose, "新版本 " + (u.str("version") ?: "")) {
            Column(
                Modifier
                    .heightIn(max = UpdateNotesMaxHeight)
                    .verticalScroll(rememberScrollState()),
            ) { Dim2(u.str("notes")?.takeIf { it.isNotBlank() } ?: "这一版没有更新说明。") }
            Spacer(Modifier.height(Sp.x12))
            Dim2(if (mb > 0) "安装包 %.1f MB,下完会跳到系统安装界面。".format(mb)
                 else "下完会跳到系统安装界面。")
            Spacer(Modifier.height(Sp.x16))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                LpButton("取消", onClose)
                Spacer(Modifier.width(Sp.x10))
                LpButton("下载并安装", {
                    downloading = true
                    app.bg.launch { runUpdate(app, ctx) { prog = it }; onClose() }
                })
            }
        }
        return
    }

    val got = prog.long("downloaded") ?: 0L
    val total = prog.long("total") ?: 0L
    LpDialog({ }, "正在更新") {
        if (total > 0) LinearProgressIndicator(
            progress = { (got.toFloat() / total).coerceIn(0f, 1f) },
            modifier = Modifier.fillMaxWidth(),
        ) else LinearProgressIndicator(Modifier.fillMaxWidth())
        Spacer(Modifier.height(Sp.x12))
        Dim2(if (total > 0) "%.1f MB / %.1f MB".format(got / 1048576.0, total / 1048576.0)
             else "%.1f MB".format(got / 1048576.0))
        Spacer(Modifier.height(Sp.x16))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            // 只发取消,不在这儿关窗:核心层把档位改成 idle 之后,轮询那一头会自己
            // 收尾并调 onClose。抢先关窗的话,关掉的是一个还在下载的任务
            LpButton("取消", { app.bg.launch { runCatching { app.call("system.cancelUpdate") } } })
        }
    }
}

/**
 * 下载 → 轮询进度 → 交给系统装包器。
 *
 * 抽成顶层函数不只是为了短:字段名门禁按「调用点往下 30 行」判响应字段,
 * 挤在 Composable 里的话它会把下面画进度条那几行也算进这条命令的读取范围。
 * 轮询而不订阅事件,和下载管理器同一个口径 —— 一个活跃任务不值得开一条事件流。
 */
private suspend fun runUpdate(app: AppState, ctx: Context, onProgress: (JsonObject?) -> Unit) {
    if (runCatching { app.call("system.downloadUpdate") }.onFailure { app.report(it) }.isFailure) return
    while (true) {
        delay(400)
        val p = runCatching { app.call("system.updateProgress") }.getOrNull().obj() ?: continue
        onProgress(p)
        when (p.str("phase")) {
            "downloading" -> continue
            "failed" -> { onProgress(null); app.toast(p.str("error") ?: "下载失败", ToastKind.Error); return }
            "ready" -> Unit
            else -> { onProgress(null); return }
        }
        break
    }
    val f = runCatching { app.call("system.installUpdate") }.getOrNull().obj().str("file")
    onProgress(null)
    if (f == null) app.toast("安装包没准备好", ToastKind.Error)
    else openInstaller(ctx, f) { app.toast(it, ToastKind.Info) }
}

/**
 * 把 APK 交给系统装包器。
 *
 * ☠ 两道闸缺一不可:`REQUEST_INSTALL_PACKAGES` 只是「允许申请」,用户还得在系统设置里
 * 给本应用开「安装未知应用」。没开就直接发意图的表现是**什么都不发生** ——
 * 那正是「点了没反应」这一类最难查的形态,所以先问再发,没开就把人送过去。
 */
private fun openInstaller(ctx: Context, path: String, say: (String) -> Unit) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !ctx.packageManager.canRequestPackageInstalls()) {
        say("请先允许本应用安装未知应用,然后再点一次更新")
        runCatching {
            ctx.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:" + ctx.packageName)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        return
    }
    // file:// 从 Android 7 起会当场 FileUriExposedException,必须过 FileProvider
    val uri = FileProvider.getUriForFile(ctx, ctx.packageName + ".fileprovider", File(path))
    runCatching {
        ctx.startActivity(Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
    }.onFailure { say("装不起来:" + it.message) }
}

// ---------------------------------------------------------------- 更新

/**
 * 更新渠道:**存字母码,显示中文**。
 *
 * 线上值是 `prerelease` 不是 `preview` —— 写错的那一版核心层会顶回
 * 「未知的更新渠道」,渠道从来就切不过去。两个方向必须互为反函数,
 * 错开一格的表现是「选了预览版,回来还显示正式版」而一句错都不报。
 */
internal val CHANNEL_LABELS = listOf("正式版", "预览版")

internal fun channelLabel(code: String) = if (code == "prerelease") "预览版" else "正式版"

internal fun channelCode(label: String) = if (label == "预览版") "prerelease" else "stable"

/** chip 上只放主机名 —— 一整条 `https://…` 在手机上会把这一排撑出屏幕。 */
internal fun proxyLabel(url: String) =
    url.substringAfter("://").trimEnd('/').ifEmpty { "直连" }

/**
 * 更新设置。
 *
 * ☠ 这三项此前**只有桌面端有**:安卓能查能下能装,但渠道、自动检查、GitHub 代理
 *   一个都改不了 —— 也就是安卓用户只能走正式版直连 GitHub,而直连 GitHub
 *   恰恰是这条链路在国内最常断的一段。核心层的命令从落地那天起就在,没人接。
 */
@Composable
private fun UpdatePanel() {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    var channel by remember { mutableStateOf("stable") }
    var auto by remember { mutableStateOf(false) }
    var proxy by remember { mutableStateOf("") }
    var proxies by remember { mutableStateOf<List<String>>(emptyList()) }
    var version by remember { mutableStateOf("") }
    var editing by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        val o = runCatching { app.call("prefs.getUpdateSettings") }.getOrNull().obj()
        channel = o.str("channel") ?: "stable"
        auto = o.bool("auto_check")
        proxy = o.str("proxy") ?: ""
        proxies = o.strList("proxies")
        version = o.str("current_version") ?: ""
    }

    /** 改完即生效。**失败必须回滚** —— 不回滚的话界面显示的是一个没落盘的值。 */
    fun push(ch: String, on: Boolean, px: String) {
        val undo = Triple(channel, auto, proxy)
        channel = ch; auto = on; proxy = px
        scope.launch {
            runCatching {
                app.call("prefs.setUpdateSettings",
                    args("channel" to ch, "auto_check" to on, "proxy" to px))
            }.onFailure {
                channel = undo.first; auto = undo.second; proxy = undo.third
                app.report(it)
            }
        }
    }

    Panel(Modifier.padding(Sp.x16)) {
        SegRow("更新渠道", CHANNEL_LABELS, channelLabel(channel),
            { v -> push(channelCode(v), auto, proxy) },
            sub = "预览版一天可能出好几个构建")
        Hairline()
        LpCell("启动时自动检查更新", sub = "默认关着 —— 这是个会自己联网的行为",
            switch = auto, onSwitch = { v -> push(channel, v, proxy) })
        Hairline()
        LpCell("GitHub 代理", value = proxyLabel(proxy),
            sub = "GitHub 连不上时填一个,查版本和下载都走它",
            onClick = { editing = true })
        Hairline()
        LpCell("当前版本", value = version.ifEmpty { "…" }, arrow = false)
    }

    if (editing) ProxyDialog(proxy, proxies, { editing = false }) { px ->
        editing = false
        push(channel, auto, px)
    }
}

/**
 * 代理编辑。
 *
 * ★ 输入框 + 几颗快填,不是一个下拉:用户点名要「支持用户自定义」,而这类公共代理
 *   今天能用明天就 404 —— 只给下拉等于把人锁死在坏掉的那几个上。
 * ★ 档位表来自核心层,这儿不抄一份:抄的下场是改一处漏一处,漏掉的那端不报错。
 */
@Composable
private fun ProxyDialog(
    init: String,
    picks: List<String>,
    onClose: () -> Unit,
    onSave: (String) -> Unit,
) {
    var draft by remember { mutableStateOf(init) }
    LpDialog(onClose, "GitHub 代理") {
        LpField(draft, { draft = it }, "留空 = 直连 GitHub")
        Spacer(Modifier.height(Sp.x10))
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(Sp.x6),
        ) {
            ToneChip("直连", on = draft.isBlank()) { draft = "" }
            picks.forEach { u ->
                ToneChip(proxyLabel(u), on = draft.trimEnd('/') == u.trimEnd('/')) { draft = u }
            }
        }
        Spacer(Modifier.height(Sp.x16))
        Row(horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
            LpButton("取消", onClose, Modifier.weight(1f), BtnKind.Secondary)
            LpButton("保存", { onSave(draft.trim()) }, Modifier.weight(1f))
        }
    }
}

/**
 * 「启动时自动检查更新」真正生效的地方。
 *
 * ☠ 这个偏好在安卓端**从来没有任何人读过** —— 界面上根本没有它,
 *   核心层存着一个谁都改不了、改了也没人看的值。桌面端六秒后查一次,
 *   安卓端此前一次都不查。
 * ★ 延后 6 秒:首屏那几条请求才是用户在等的,更新检查排在它们后面。
 */
internal suspend fun autoCheckUpdate(app: AppState): JsonObject? {
    delay(6000)
    val s = runCatching { app.call("prefs.getUpdateSettings") }.getOrNull().obj()
    if (!s.bool("auto_check")) return null
    // 查不动就安静走开:这不是用户点出来的动作,不该弹错
    val r = runCatching { app.call("system.checkUpdate") }.getOrNull().obj()
    return if (r.bool("has_update")) r?.get("update").obj() else null
}
