package xyz.linplayer.app.ui.player

import android.app.Activity
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.basicMarquee
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavController
import androidx.navigation.toRoute
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.ToastKind
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.boolOrNull
import xyz.linplayer.app.data.dbl
import xyz.linplayer.app.data.long
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.GlassIcon
import xyz.linplayer.app.ui.components.LpIconButton
import xyz.linplayer.app.ui.components.pressable
import xyz.linplayer.app.ui.pages.args
import xyz.linplayer.app.ui.pages.fmtTime
import xyz.linplayer.app.ui.theme.Dim
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp

private const val OSD_HIDE_MS = 5000L

/**
 * 定方向要攒够的距离。
 *
 * ★ 比系统的 touchSlop(约 8dp,那是「算不算拖动」的阈值)大得多 ——
 *   这里要判的是「往哪个方向拖」,而人起手的那一小段几乎必然是斜的。
 */
private val DRAG_SLOP = 28.dp

/**
 * 竖滑走完整个量程要划几屏。1.4 = 比一屏还多划四成。
 *
 * ★ 1.0(上一版)意味着划过半屏音量就从 0 到满,而看片时手是搭在屏幕上的,
 *   稍微一动就是一大格 —— 用户说的「太敏感、拖泥带水」有一半是这个数。
 */
private const val VERTICAL_TRAVEL = 1.4f

/** 手势方向。定下来就不再改。 */
internal enum class DragAxis { H, V }

/**
 * 这一次手势往哪个方向走。`null` = 还没攒够,继续攒。
 *
 * ☠ 判据是「**累计**位移谁先攒够」,不是「这一帧谁大」。后者每帧重判,
 *   手指稍斜就在两个方向之间来回跳 —— 那正是「左右滑顺带把音量也调了」。
 * ★ [ratio] 要求主方向比副方向多出一截:45° 斜划什么都不该触发,
 *   而不是随机落到其中一边。
 */
internal fun lockAxis(dx: Float, dy: Float, slop: Float, ratio: Float = 1.7f): DragAxis? {
    val ax = kotlin.math.abs(dx)
    val ay = kotlin.math.abs(dy)
    return when {
        ax >= slop && ax >= ay * ratio -> DragAxis.H
        ay >= slop && ay >= ax * ratio -> DragAxis.V
        else -> null
    }
}

/** 转屏没落定就一直黑着不行,这是上限。分屏 / 折叠屏上方向请求可能根本不生效。 */
private const val TurnGiveUpMs = 900L

/** 退场时给系统转屏留的那一下。它只要够系统拍下「转之前那一帧」就行。 */
private const val TurnSettleMs = 150L

/**
 * 现在这个方向和想要的方向对不上,也就是「正在转 / 马上要转」。
 *
 * `want == null` 是**不知道**(strm / 网盘源拿不到宽高),那时什么都不做 ——
 * 不知道方向却把界面黑起来,是拿一个猜测去换一段黑屏。
 */
internal fun turningTo(want: Boolean?, portrait: Boolean): Boolean =
    want != null && want != !portrait

/**
 * 整机下行网速,一秒一采,采到就回调。
 *
 * ★ 口径是**整机**(TrafficStats 全设备计数),不是这一条流 —— 用户要看的是
 *   「现在到底还有没有在下东西」,而播放中同时还有封面、弹幕、上报在跑。
 * ★ 取不到(有的 ROM 返回 UNSUPPORTED)就一直不回调,界面上那一格整个不画。
 *   摆一个恒为 0 的读数比不摆更糟。
 */
internal suspend fun sampleNetSpeed(onText: (String) -> Unit) {
    var last = android.net.TrafficStats.getTotalRxBytes()
    var lastAt = System.nanoTime()
    if (last == android.net.TrafficStats.UNSUPPORTED.toLong()) return
    while (true) {
        delay(1000)
        val now = android.net.TrafficStats.getTotalRxBytes()
        val at = System.nanoTime()
        if (now == android.net.TrafficStats.UNSUPPORTED.toLong()) return
        onText(fmtSpeed(now - last, at - lastAt))
        last = now
        lastAt = at
    }
}

/** 网速读数的格式【用户定 2026-09-08】。量不出来返回空串,那一格就整个不画。 */
internal fun fmtSpeed(bytes: Long, nanos: Long): String {
    if (nanos <= 0L || bytes < 0L) return ""
    val bps = bytes * 1_000_000_000.0 / nanos
    return when {
        bps >= 1024 * 1024 -> "%.1f MB/s".format(bps / 1024 / 1024)
        bps >= 1024 -> "%.0f KB/s".format(bps / 1024)
        else -> "0 KB/s"
    }
}

/** 和 ExoEngine 里那个是同一件事:libass 的字体目录。两处各写一遍早晚会漂。 */
private const val LIBASS_FONTS_DIR = "/system/fonts"
private const val SP_MIN = 0.25
private const val SP_MAX = 4.0

/**
 * 播放页 + OSD(U1.6)。
 *
 * 横屏走**九宫格**【用户定 2026-07-28】,竖屏走「视频占顶部 16:9 + 下面内容区」——
 * 两套布局不是一套的缩放。
 *
 * ☠ 面板打开期间**上下栏一动不动**:「点出去闪一下」的根因是 scrim 盖在了 OSD 上面
 * (层级问题),不是显隐逻辑。OSD 必须抬到 scrim 之上。
 *
 * ★ **两个内核**【用户定 2026-09-06】:mpv(核心层里的 libmpv)与 ExoPlayer。
 *   分叉点**只有「谁去解码渲染」这一处** —— 取流、续播位置、上报全都还走核心层的
 *   `player.play`(带 `engine`)。整页只有三处 if:视频层、状态从哪来、控制发给谁。
 *   各写一个播放页的下场是「换个内核续播就不对了」。
 */
@Composable
fun PlayerPage(nav: NavController, entry: NavBackStackEntry) {
    val route = entry.toRoute<Route.Player>()
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current
    val activity = ctx as? Activity
    val portrait = LocalConfiguration.current.orientation == Configuration.ORIENTATION_PORTRAIT

    var position by remember { mutableStateOf(0.0) }
    var duration by remember { mutableStateOf(0.0) }
    var paused by remember { mutableStateOf(false) }
    var buffering by remember { mutableStateOf(true) }
    /** ☠ 「时间真的往前走了」才撤黑幕,不是 `position > 0`。 */
    var everMoved by remember { mutableStateOf(false) }
    var speed by remember { mutableStateOf(1.0) }
    var osd by remember { mutableStateOf(true) }
    var locked by remember { mutableStateOf(false) }
    var panel by remember { mutableStateOf<String?>(null) }
    var dmSearch by remember { mutableStateOf(false) }
    /** 弹幕密度。空表 = 不画(关了热力图、或者这一集没弹幕)。 */
    var heat by remember { mutableStateOf<List<Float>>(emptyList()) }
    /* 语料换了要重取一次。**跟着弹幕开关和热力图开关走**,不做轮询 ——
       密度是一集一份的静态数据,每秒问一次纯属白烧。 */
    LaunchedEffect(DanmakuStyle.enabled.value, DanmakuStyle.heatmap.value, duration) {
        heat = if (!DanmakuStyle.enabled.value || !DanmakuStyle.heatmap.value) emptyList()
        else runCatching {
            app.call("player.danmakuHeatmap", args("buckets" to 120, "duration" to duration))
        }.getOrNull().arr().mapNotNull {
            (it as? kotlinx.serialization.json.JsonPrimitive)?.content?.toFloatOrNull()
        }
    }
    /* ☠ **弹幕要自己加载,不能等用户去拨那个开关。**
       上一版只有「拨开关」和「重新匹配」两条路会去匹配 —— 而开关是**落库**的:
       用户上一集打开过,这一集进来面板上写着「已打开」,却一条弹幕都没取。
       表现就是「不会自动加载弹幕」,而且看上去还像是开着的。
       ★ 挂在 itemId 上:换一集就重来一遍。匹配不上不弹错(九成片子没弹幕)。 */
    LaunchedEffect(route.itemId) { startDanmakuFor(app, route.itemId) }
    /** 跟手 seek 的预览值。**松手才发命令** —— 跟着滑发是每帧一条,把核心层的 seek 闩打乱。 */
    var seekPreview by remember { mutableStateOf<Double?>(null) }
    var volume by remember { mutableFloatStateOf(1f) }
    /* 亮度自己存一份。**不能每次去读 `window.attributes`** —— 没设过时它是 -1
       (「跟随系统」),拿 -1 当起点算增量的话第一下会直接跳到最暗。 */
    var brightness by remember { mutableFloatStateOf(-1f) }
    /** 正在调的是什么、调到几成。空 = 不显示【用户定 2026-09-08:调节时屏幕中间要有标志】。 */
    var hud by remember { mutableStateOf<Pair<Boolean, Float>?>(null) }
    /** 起播失败(一次都没出画就 eof)。**不许静默退回去**。 */
    var openFailed by remember { mutableStateOf(false) }
    /** 失败时给用户看的**具体原因**,不是「原因在日志里」。见 [failureDiag]。 */
    var failReason by remember { mutableStateOf<String?>(null) }

    /* 退场:**先松方向锁、等屏幕转回去,再 pop**。
       直接 pop 的话系统拍到的是详情页横着的第一帧,转过来就是用户说的「反之也有」;
       在这儿转,拍到的是播放页那块黑幕。等的这一下顺带把 OSD 撤了(见 [leaving])。 */
    var leaving by remember { mutableStateOf(false) }
    val leave: () -> Unit = { leaving = true }
    LaunchedEffect(leaving) {
        if (!leaving) return@LaunchedEffect
        activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        delay(TurnSettleMs)
        nav.popBackStack()
    }

    /* 内核。★ 进播放页时读一次就**钉住**(`remember` 不带 key):
       播到一半用户去设置里改了内核,回来时这一片的状态机会当场换一套
       —— 位置、时长、暂停三个值来源全变,而 ExoPlayer 手里根本没有这一片。
       所以设置页那一行明说「退出当前播放再进才生效」。 */
    val engine = remember { route.engine ?: xyz.linplayer.app.data.UiPrefs.engine.value }
    /* 字幕样式要在**画第一句字幕之前**就位。晚一步的表现是「进来先按默认样式画几句,
       打开一次面板才变过来」—— 而用户明明上一集就调好了。
       只读一次:它落在核心层配置里,一次会话内不会自己变。 */
    LaunchedEffect(Unit) { if (!SubStyle.loaded.value) SubStyle.load(app) }
    /* 字幕语言偏好。**要在建 ExoPlayer 之前读到** —— ExoPlayer 的轨道选择是
       「参数变了才重选」,建完再补一次也行,但首帧那几秒会没有字幕。
       `null` = 还没读到,`""` = 没有语言偏好(那是**默认状态**,不是「关了字幕」)。 */
    var subLangPref by remember { mutableStateOf<String?>(null) }
    /* ☠ **「关字幕」的开关是 `sub_enabled`,不是「语言偏好为空」。**
       核心层的 `sub_lang` 是 `*string`、默认 null,含义是「没偏好,随便挑一条」;
       上一版拿它是不是空串当关闭判据,于是**从没设过语言的人**(绝大多数)
       整条字幕链被关死:libass 不开、兜底选轨不选、外挂 ASS 不取。
       真机日志里就是那句 `libass 不走这条路: available=true subOff=true`。 */
    var subOff by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        val p = runCatching { app.call("prefs.getPrefs") }.getOrNull().obj()
        subLangPref = p.str("sub_lang") ?: ""
        subOff = p.boolOrNull("sub_enabled") == false
    }
    val exo = rememberExoPlayer(engine == "exo", subLangPref)
    /* 画面比例【用户定 2026-09-07】。★ **不持久化** —— 和画面增强档位同一条口径:
       它是「这一片这一次这么看」,记住的话下一片莫名其妙就是 4:3。 */
    var videoFit by remember { mutableStateOf(VideoFit.Source) }
    /* 片源比例。**起手就是详情页带过来的那一份**(`Route.Player.ar`),
       0 = 详情页也不知道(strm / 网盘源常见),那时下面那个 LaunchedEffect 去问一次。 */
    var srcAr by remember(route.itemId) { mutableFloatStateOf(route.ar) }
    /** 有没有「同一季的其它集」。**电影没有,所以电影不该有那颗「选集」**【用户定 2026-09-07】。 */
    var hasEpisodes by remember(route.itemId) { mutableStateOf(false) }
    LaunchedEffect(route.itemId) {
        hasEpisodes = runCatching { app.call("emby.itemDetail", args("item_id" to route.itemId)) }
            .getOrNull().obj().str("season_id") != null
    }

    /* 沉浸式:**两个内核都要**【用户报 2026-09-07】。
       ☠ 隐藏的是 `systemBars()`,不能只隐藏 statusBars —— 手势条(navigationBars)
         压在底排按钮上,而且它那条白杠在深色画面上比状态栏还显眼。
       ★ `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE`:用户从边缘划一下还能把它们叫回来,
         叫回来之后过几秒自己走。锁死的话用户连返回手势都不知道还在不在。
       ★ 退出播放页必须 `show` 回去 —— 整个 App 只有这一页要沉浸,不还原的话
         回到首页也是没有状态栏,而那看起来就像界面画崩了。 */
    DisposableEffect(activity) {
        val w = activity?.window
        val ctl = w?.let { androidx.core.view.WindowInsetsControllerCompat(it, it.decorView) }
        ctl?.systemBarsBehavior =
            androidx.core.view.WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        ctl?.hide(androidx.core.view.WindowInsetsCompat.Type.systemBars())
        onDispose { ctl?.show(androidx.core.view.WindowInsetsCompat.Type.systemBars()) }
    }

    // 屏幕常亮(U1.24):播放中不息屏,暂停 / 退出后恢复
    DisposableEffect(paused) {
        val w = activity?.window
        if (!paused) w?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else w?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { w?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }

    // 起播。★ 换片时**先立「未就绪」再发命令**,不能排在两个 await 之后
    LaunchedEffect(route.itemId) {
        everMoved = false; buffering = true; position = 0.0; duration = 0.0; openFailed = false
        // ☠ 换片必须连 libass 的事件缓存一起清:留着就是把上一集的字幕画给这一集
        Libass.reset()
        // 通知权限在**这里**要,不在冷启动时要(U1.27):它只在后台播放挂通知栏时有意义
        (activity as? xyz.linplayer.app.MainActivity)?.askNotificationPermission()
        app.wantsPip = true
        runCatching {
            // 详情页选了版本就带上。没选就传空 —— **不许自己回落 versions[0]**,
            // 那会把核心层的版本正则整个跳过
            val a = buildMap<String, Any> {
                put("item_id", route.itemId)
                put("engine", engine)
                route.versionId?.let { put("media_source_id", it) }
            }
            val r = app.call("player.play", args(*a.toList().toTypedArray())).obj()
            /* engine=exo 时核心层**只算不播**:它把该播的那条地址和续播位置回给这里,
               由 ExoPlayer 去 loadfile。地址一律用它回的这个 —— 在 UI 里自己拼
               是明令禁止的(反代只在 /emby/ 下处理 Range,拼错的表现是
               「跳到没缓冲的位置就卡死」,而且查不出来)。 */
            val url = r.str("play_url")
            if (exo != null && url != null) exo.load(url, r.dbl("resume_secs") ?: 0.0)
            /* 外挂 ASS。**压制组单独发的那种字幕才是「特效字幕」的大头** ——
               内封 ASS 走 media3 的解析器那条路(ExoSurface 里按选中轨切),
               外挂的核心层根本不交给 ExoPlayer,得自己取回来喂 libass。
               ★ fire-and-forget:取不到就没有特效字幕,不该挡住播放。 */
            if (exo != null && !subOff) loadExternalAss(app, r?.get("external_subs"))
            /* 内嵌字体(MKV 附件)。**特效字幕的字形全靠它** ——
               ExoPlayer 不解析 Attachments,不自己抠的话 libass 只能回落系统字体。
               ★ 和上面那条一样是 fire-and-forget:抠不到只是字形不对,不该挡住播放。 */
            if (exo != null && url != null) loadEmbeddedFonts(url)
        }.onFailure { app.report(it) }
    }

    /* ExoPlayer 那条路的状态:**轮询 4 Hz**,和 mpv 的 `player.status` 同频。
       ★ 只能在主线程读 ExoPlayer(它是单线程模型),`LaunchedEffect` 正好跑在
         composition 的调度器上,也就是主线程 —— 挪到别的 dispatcher 会当场抛
         「Player is accessed on the wrong thread」。 */
    LaunchedEffect(exo, route.itemId) {
        val e = exo ?: return@LaunchedEffect
        while (true) {
            val p = e.currentPosition / 1000.0
            if (p > position + 0.05) everMoved = true
            position = p
            e.duration.takeIf { it > 0 }?.let { duration = it / 1000.0 }
            paused = !e.playWhenReady
            buffering = e.playbackState == androidx.media3.common.Player.STATE_BUFFERING
            // 起播失败要**说出来**,不许静默退回去 —— 和 mpv 那条同一条口径
            e.playerError?.let { err ->
                failReason = "ExoPlayer:" + (err.errorCodeName) + " " + (err.message ?: "")
                openFailed = true
                return@LaunchedEffect
            }
            if (e.playbackState == androidx.media3.common.Player.STATE_ENDED) {
                if (everMoved) leave() else openFailed = true
                return@LaunchedEffect
            }
            delay(250)
        }
    }

    // 订阅 player.status(4 Hz)。**不轮询**
    LaunchedEffect(engine) {
        if (exo != null) return@LaunchedEffect
        app.core.events.collect { ev ->
            if (ev.name != "player.status") return@collect
            val o = ev.data as? JsonObject
            val p = o.dbl("position") ?: 0.0
            if (p > position + 0.05) everMoved = true
            position = p
            duration = o.dbl("duration") ?: duration
            paused = o.bool("paused")
            buffering = o.bool("buffering")
            /* ☠ 判播完必须读 eof —— keep-open 下 END_FILE 永远不发。
               ★ 但「时间一次都没往前走过就 eof」不是播完,是**起播失败**:
                 直接 popBackStack 会让用户看到「点了播放,闪一下就回来了」,
                 什么都没说。这种时候把 mpv 报的原因显示出来。 */
            if (o.bool("eof")) {
                if (everMoved) leave() else {
                    failReason = failureDiag(app)
                    openFailed = true
                }
            }
        }
    }

    // 4 秒兜底放行:但**放行前必须先确认不在等缓冲**
    LaunchedEffect(route.itemId) {
        delay(4000)
        if (!buffering) everMoved = true
    }
    /* 12 秒**无条件**撤黑幕。
       ☠ 上面那条兜底带着 `!buffering` 这个前提,而前提本身可能是假的
       (状态事件根本没来的时候 buffering 停在初值 true)—— 于是兜底不兜。
       这一条不带任何前提:真没画面的话用户看到的是黑画面 + 一个缓冲提示,
       和现在一样;而画面其实在的话,他至少看得见。 */
    LaunchedEffect(route.itemId) {
        delay(12_000)
        everMoved = true
    }

    // OSD 自动收起 5000ms。两条例外:**面板开着不收**、**暂停时不收**
    LaunchedEffect(osd, panel, paused) {
        if (!osd || panel != null || paused) return@LaunchedEffect
        delay(OSD_HIDE_MS)
        osd = false
    }

    // 进度上报:播放中每 10s 一次 + 暂停 / 退出各一次
    LaunchedEffect(route.itemId) {
        while (true) {
            delay(10_000)
            if (!paused && position > 0) runCatching {
                // ★ 不传 item_id:核心层从**当前播放目标**取(连同 PlaySessionId)。
                //   让调用方传 = 传错一次就是「看一半退出进度不落地」,而且查不出来
                app.call("emby.reportProgress", args("pos" to position, "paused" to paused))
            }
        }
    }
    DisposableEffect(route.itemId) {
        onDispose {
            app.wantsPip = false
            Libass.reset()
            // ★ 走 app.bg 不走 scope:后者正在被取消,launch 出去的活一件都不跑
            app.bg.launch {
                runCatching {
                    val p = if (duration > 0 && position >= duration - 2) duration else position
                    // ★ 收尾**只发 player.stopPlayback**:它内部就带了 Stopped 上报,
                    //   PlaySessionId 从当前播放目标取 —— 三次上报共用一个。
                    //   不贯穿的话服务器当成三次互不相干的播放,进度就丢了。
                    // ☠ 播完传**总时长**不是当前时间:差最后零点几秒 = 服务端不算看完
                    app.call("player.stopPlayback", args("pos" to p))
                }
            }
        }
    }

    /* 控制分派:整页只有这四个动作要认内核。
       ★ 写成四个具名函数而不是在八个调用点各写一个 if —— 漏一个的表现是
         「换成 ExoPlayer 之后快进不动」,而其它按钮都好使,看着像手势坏了。 */
    fun doSeek(t: Double) {
        if (exo != null) exo.seekTo((t * 1000).toLong())
        else scope.launch { runCatching { app.call("player.seek", args("pos" to t)) } }
    }
    fun doPause(want: Boolean) {
        if (exo != null) exo.playWhenReady = !want
        else scope.launch { runCatching { app.call("player.setPause", args("paused" to want)) } }
    }
    fun doSpeed(v: Double) {
        if (exo != null) exo.setPlaybackSpeed(v.toFloat())
        else scope.launch { runCatching { app.call("player.setSpeed", args("speed" to v)) } }
    }
    fun doVolume(v: Float) {
        if (exo != null) exo.volume = v
        else scope.launch {
            runCatching { app.call("player.setVolume", args("volume" to (v * 100).toInt())) }
        }
    }

    // 返回键四级:小浮层 → 面板 → OSD → 才退出播放
    BackHandler {
        when {
            panel != null -> panel = null
            osd -> osd = false
            else -> leave()
        }
    }

    /* ☠ **方向跟着视频比例走,不让用户自己转**【用户定 2026-09-06】。
       横片点播放就自动横过来,竖片保持竖屏 —— 「竖屏起播、横屏观看」是脱裤子放屁。

       ★ 判据在**进这一页之前**就拿得到:详情页手里的 Version 带着 width / height,
         经 `Route.Player.ar` 送过来。上一版是进来之后自己再问一次 `emby.itemMedia` ——
         一次网络往返之后才转,用户看到的就是「竖屏的播放页画好了,再整块转过去」
         (用户 2026-09-12:「有一段从竖屏转向横屏的画面…只会觉得卡」)。
       ★ 拿不到宽高(strm / 网盘源常见)就**什么都不做**,按当前方向起播,
         首帧到了再纠正一次 —— 不许瞎猜一个方向锁上去。
       ★ 用户手动转了就交还系统:锁死会变成「我想竖着看都不行」。 */
    var wantLandscape by remember(route.itemId) {
        mutableStateOf(if (route.ar > 0f) route.ar > 1f else null)
    }
    LaunchedEffect(route.itemId) {
        if (route.ar > 0f) return@LaunchedEffect   // 详情页已经告诉我们了,不必再问一次
        val v = runCatching { app.call("emby.itemMedia", args("item_id" to route.itemId)) }
            .getOrNull().arr().firstOrNull().obj()
        val vid = v?.get("streams").arr().map { it.obj() }
            .firstOrNull { it.str("type_") == "Video" }
        val w = vid.long("width") ?: return@LaunchedEffect
        val h = vid.long("height") ?: return@LaunchedEffect
        if (w > 0 && h > 0) {
            wantLandscape = w > h
            /* ★ 同一次请求顺手把比例留下来交给 [ExoSurface]。
               它自己那两条(`videoSize` 事件 / 轮询)都要等首帧,而这里在**起播之前**
               就已经拿到了 —— 用户报了三轮的「哪怕选原始比例也还是拉伸」,
               根子就是首帧之前 ratio 恒 0,而 0 只能铺满。 */
            srcAr = w.toFloat() / h
        }
    }
    DisposableEffect(wantLandscape) {
        val a = activity
        val want = wantLandscape
        if (a != null && want != null) {
            // SENSOR_* 而不是 *_LANDSCAPE:锁的是「横着」,不锁是哪一头朝上
            a.requestedOrientation = if (want)
                ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            else ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        }
        onDispose {
            // 退出播放页恢复原方向。留着锁的话整个 App 都跟着横过来了
            a?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

    /* ☠ **转屏这一下不许让用户看见。**
       系统转屏动画拍的是**转之前那一帧**,再把那张图转过去。所以只要那一帧是
       一整块黑,转屏就等于黑转黑 —— 看不见。黑幕本来就铺着,差的只是 OSD:
       竖版排布先画出来再整块转,正是用户报的「那一段从竖屏转向横屏的画面」。
       转不动的场合(分屏 / 折叠屏 / 无视方向请求的 ROM)最多黑 [TurnGiveUpMs] 就照常画,
       不然那台设备上顶栏永远出不来。 */
    val turning = turningTo(wantLandscape, portrait)
    var turnGaveUp by remember(route.itemId) { mutableStateOf(false) }
    LaunchedEffect(turning) { if (turning) { delay(TurnGiveUpMs); turnGaveUp = true } }

    /* 网速读数。**在这一层数,不在 OSD 里数**【用户定 2026-09-12:「网速显示要常驻,
       不需要打开再统计再显示,跟随状态栏显隐就行了」】。
       原来它长在 [Osd] 里,而 OSD 是 `AnimatedVisibility` —— 收起来整个退出组合,
       协程被取消;每叫出一次顶栏都是从零开始数一秒,先空着再跳出一个数。 */
    var netSpeed by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { sampleNetSpeed { netSpeed = it } }

    val c = Lp.colors
    /* ☠☠ **这一层不许有不透明底色。**
       `SurfaceView`(非 ZOrderOnTop)的画面是从**窗口下面**透上来的,靠它自己在
       View 树上按 `PorterDuff.CLEAR` 抠一个洞。在它上面刷一层
       `background(Color.Black)` 就是把那个洞重新填死 —— 表现是
       **有声音、没画面、一条错都不报**,和旧栈「透出链四层」记的是同一件事
       (docs/lessons/android.md)。黑底由 Activity 的 windowBackground 承担,
       它在整棵 View 树**下面**,不挡洞。
       这一条是 MP 内核「只有声音没有画面」的第一嫌疑。 */
    Box(Modifier.fillMaxSize()) {
        // 视频层:SurfaceView。Compose 内容天然画在它上面
        // ☠ 两条**互斥**:同时挂的话 mpv 和 ExoPlayer 会各画各的,上面那层赢
        if (exo != null)
            ExoSurface(exo, subOff = subOff, fit = videoFit, hintAr = srcAr,
                m = Modifier.fillMaxSize())
        else VideoSurface(app.core, Modifier.fillMaxSize())

        /* 弹幕层。**画在这儿而不是交给 mpv** —— 两个内核下都要有,
           而 mpv 的 osd-overlay 在 Exo 那条路上根本不存在(见 DanmakuLayer 顶上那段)。 */
        if (DanmakuStyle.enabled.value) DanmakuLayer(
            DanmakuStyle.layout.value, position, paused, speed, Modifier.fillMaxSize())


        /* 未出画时的黑幕。**判据是「时间真的往前走了」**。
           ☠☠ **这块布必须有一个撤不掉就自己撤的死线**(见 everMoved 那两个兜底)。
              它是不透明的,一旦「时间不往前走」这个判据被别的 bug 卡住,用户看到的
              就是「有声音、没画面、一直正在缓冲」—— 而画面其实一直在下面好好画着。
              2026-09-07 真出过这一次:安卓上 player.status 一条都发不出去
              (闸用错了标志,见 core/player/player.go 的 pumpStatus),
              位置永远是 0,这块布就永远撤不掉。修好了根因,死线也得留。 */
        if (!everMoved) Box(Modifier.fillMaxSize().background(Color.Black),
            contentAlignment = Alignment.Center) {
            if (openFailed) Column(
                Modifier.padding(horizontal = Sp.x26),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("这一片没能播起来", color = Color.White, fontSize = 16.sp)
                Spacer(Modifier.height(Sp.x8))
                /* ★ **把真正的原因摆在这里**,不是一句「原因在日志里」。
                   上一版那句话等于让用户去导诊断包,而他只想知道是不是自己的问题;
                   对我们这边也一样 —— 「有声音没画面」这类报告拿不到 vo / 解码器
                   的实际取值就只能靠猜,一来一回好几轮。 */
                Dim3(failReason ?: "原因还没拿到。设置 → 存储与数据目录 → 导出日志。", maxLines = 6)
                Spacer(Modifier.height(Sp.x16))
                xyz.linplayer.app.ui.components.LpButton("返回", leave,
                    kind = xyz.linplayer.app.ui.components.BtnKind.Secondary)
            } else Dim3(if (buffering) "正在缓冲…" else "正在打开…")
        }

        /* 三区手势(UI_MOBILE.md §8.4)。锁屏后只有解锁按钮响应。
           ☠☠ **方向要锁死,不能每帧重判**【用户定 2026-09-08:「上下滑动和左右滑动
              区分不开…做的不敏感」】。上一版的判据是「这一帧 |dx| 和 |dy| 谁大」——
              手指稍微斜一点,两个分量就在每一帧上互相超过,于是一次左右滑里夹着几十帧
              被判成上下:表现正是「左右滑顺带把音量也调了」。
              现在:攒够 [DRAG_SLOP] 再定方向,定了这一次手势就不再改;而且主方向要比
              副方向多出一截([lockAxis] 的 ratio),斜着划的那一下什么都不触发。 */
        if (!locked) Box(
            Modifier.fillMaxSize().pointerInput(Unit) {
                detectTapGestures(
                    onTap = { osd = !osd },
                    onDoubleTap = { doPause(!paused) },
                )
            }.pointerInput(duration) {
                val slop = DRAG_SLOP.toPx()
                var ax = 0f            // 这一次手势的累计位移
                var ay = 0f
                var axis: DragAxis? = null
                var startX = 0f
                var vol0 = 0f
                var bri0 = 0f
                fun reset() { ax = 0f; ay = 0f; axis = null }
                detectDragGestures(
                    onDragStart = { p ->
                        reset()
                        startX = p.x
                        vol0 = volume
                        bri0 = if (brightness >= 0f) brightness else 0.5f
                    },
                    onDragEnd = {
                        // ★ 松手才真 seek
                        seekPreview?.let { t -> doSeek(t) }
                        seekPreview = null
                        reset()
                    },
                    onDragCancel = { seekPreview = null; reset() },
                ) { change, drag ->
                    change.consume()
                    ax += drag.x
                    ay += drag.y
                    if (axis == null) {
                        axis = lockAxis(ax, ay, slop) ?: return@detectDragGestures
                    }
                    /* 攒够那一段 slop **不算进调节量**:算进去的话方向刚定下来的
                       那一瞬间进度/音量会跳一格,手感上就是「一碰就窜」。 */
                    if (axis == DragAxis.H) {
                        if (duration > 0) {
                            val d = ax - slop * kotlin.math.sign(ax)
                            seekPreview = (position + d / size.width * duration * 0.6)
                                .coerceIn(0.0, duration)
                            osd = true
                        }
                    } else {
                        val d = (ay - slop * kotlin.math.sign(ay)) / (size.height * VERTICAL_TRAVEL)
                        if (startX > size.width / 2) {
                            // 右半屏 = 音量。**不用系统音量条**
                            volume = (vol0 - d).coerceIn(0f, 1f)
                            doVolume(volume)
                            hud = false to volume
                        } else {
                            // 左半屏 = 亮度。**不改系统亮度**,只改本窗口
                            brightness = (bri0 - d).coerceIn(0.01f, 1f)
                            activity?.window?.attributes = activity?.window?.attributes?.apply {
                                screenBrightness = brightness
                            }
                            hud = true to brightness
                        }
                    }
                }
            }
        )

        /* 出画之后的缓冲提示。黑幕撤了但流还没跟上时,得有个东西说明在等 ——
           没有它的话画面卡住和播放器死了长得一模一样。 */
        if (everMoved && buffering) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("正在缓冲…", Modifier.clip(RoundedCornerShape(R.pill)).background(c.chip)
                .padding(horizontal = Sp.x12, vertical = Sp.x6),
                color = Color.White, fontSize = 13.sp)
        }

        // seek 预览:滑动中显示目标时间与差值
        seekPreview?.let { t ->
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    "${fmtTime(t)}  ${if (t >= position) "+" else "−"}${fmtTime(kotlin.math.abs(t - position))}",
                    Modifier.clip(RoundedCornerShape(R.sm)).background(c.chip).padding(Sp.x12),
                    color = Color.White, fontSize = 18.sp,
                )
            }
        }

        /* 音量 / 亮度指示【用户定 2026-09-08:「屏幕中间要有一个标志显示当前进度」】。
           ★ 它**不跟 OSD 走**:调音量时 OSD 多半是收着的,挂在 OSD 上等于没有。 */
        hud?.let { (isBrightness, v) -> AdjustHud(isBrightness, v) }
        LaunchedEffect(hud) {
            if (hud != null) { delay(900); hud = null }
        }

        // ★ OSD 抬在 scrim 之上:面板开关期间上下栏**一动不动**
        AnimatedVisibility(
            (osd && !locked || panel != null) && !(leaving || turning && !turnGaveUp),
            enter = fadeIn(), exit = fadeOut(),
        ) {
            Osd(
                portrait = portrait, netSpeed = netSpeed,
                title = route.title, position = seekPreview ?: position, duration = duration,
                paused = paused, speed = speed, hasEpisodes = hasEpisodes, heat = heat,
                onBack = leave,
                onToggle = { doPause(!paused) },
                onSeek = { t -> doSeek(t) },
                onSpeed = { v -> speed = v; doSpeed(v) },
                onLock = { locked = true },
                onShot = {
                    /* ☠ **截屏不开面板、不弹窗**【用户定 2026-09-07:「截屏就截屏,
                       出现弹窗干什么呢」】。它是一个动作,不是一个要人回答的问题。 */
                    scope.launch {
                        val where = Shot.take(ctx, app, route.itemId)
                        if (where != null) app.toast("已截屏 · $where", ToastKind.Ok)
                        else app.toast("这一帧截不下来", ToastKind.Error)
                    }
                },
                onPanel = { panel = it },
            )
        }

        // 锁屏后只有解锁按钮 —— 它就长在锁屏钮刚才那个位置上
        if (locked) Box(Modifier.align(Alignment.CenterStart).padding(start = Sp.x12)) {
            GlassIcon(LpIcons.lock, "解锁") { locked = false }
        }

        panel?.let {
            PlayerPanel(
                it, route.itemId, exo,
                fit = videoFit,
                onOpen = { k -> panel = k },
                onSearch = { dmSearch = true },
                /* mpv 那条路的比例在核心层改(keepaspect / video-aspect-override / panscan);
                   Exo 那条路在 Compose 侧改尺寸。**同一个档位表**,不给用户两套说法。 */
                onFit = { f ->
                    videoFit = f
                    if (exo == null) scope.launch {
                        runCatching { app.call("player.setAspectRatio", args("ratio" to f.mpvRatio)) }
                    }
                },
            ) { panel = null }
        }

        // 弹幕搜索是**居中模态**,所以挂在整页最上面,不在那个 236dp 的小面板里
        if (dmSearch) DanmakuSearchDialog(route.itemId, route.title) { dmSearch = false }
    }
}

/* ── OSD ────────────────────────────────────────────────────────────────────
   ☠☠ **控件和进度条必须在同一个 Column 里,不能各自 align 到底边。**
   上一版就是各自 align 的:进度条 `fillMaxWidth` 贴底、又是最后一个子节点(在最上层),
   而下排那些按钮 `padding(bottom = 44.dp)` 正好落在 Slider 那 48dp 的命中区里 ——
   表现是「下面一整排按钮点不到」,而按钮本身看得见、也没禁用。
   叠成 Column 之后这类事**结构上就不可能再发生**,不是靠调数值躲开。   */

/** 两条渐变幕布:白字压在亮画面上看不清,而一整块不透明底又把画面切掉一条。 */
private val TopVeil = Brush.verticalGradient(
    listOf(Color.Black.copy(alpha = .58f), Color.Transparent),
)
private val BottomVeil = Brush.verticalGradient(
    listOf(Color.Transparent, Color.Black.copy(alpha = .74f)),
)

/**
 * OSD。竖横一套,差别只在**底排放几颗按钮**。
 *
 * 上一版是竖横两个函数各写一遍布局,九宫格那套把控件摊到八个角落。
 * 摊开确实少挡画面,但代价是「每颗按钮都得自己算 padding 去躲开别人」——
 * 那笔账最后是用户替我们还的(点不到)。现在只剩上下两条:
 * 上条只有返回和标题,下条一列到底,中间**整片是画面**。
 */
@Composable
private fun Osd(
    portrait: Boolean, netSpeed: String,
    title: String, position: Double, duration: Double, paused: Boolean, speed: Double,
    hasEpisodes: Boolean, heat: List<Float>,
    onBack: () -> Unit, onToggle: () -> Unit, onSeek: (Double) -> Unit,
    onSpeed: (Double) -> Unit, onLock: () -> Unit, onShot: () -> Unit,
    onPanel: (String) -> Unit,
) {
    Box(Modifier.fillMaxSize()) {
        Row(
            Modifier.align(Alignment.TopCenter).fillMaxWidth().background(TopVeil)
                .safeDrawingPadding().padding(bottom = Sp.x10),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            LpIconButton(LpIcons.back, "返回", tint = Color.White, onClick = onBack)
            Marquee(title, Modifier.weight(1f))
            // 网速在「更多」左边 —— 右上角这一片本来就是这一页的读数区
            NetSpeed(netSpeed)
            // ★ 「更多」在**右上角**【用户定 2026-09-07】。它是这一页的抽屉,
            //   抽屉该在角上,不该混在底排那串常用动作里
            Chip("更多") { onPanel("more") }
        }

        /* ★★ **锁屏和截屏回到左侧中间**【用户定 2026-09-07:「原本在屏幕左侧中间的
           两个按钮…被放到别的地方了,放回去」】。它们是「随时可能按一下」的两颗,
           不是「看完这一段再说」的那一类 —— 摆在拇指够得到、又不压住任何读数的地方。 */
        Column(
            Modifier.align(Alignment.CenterStart).padding(start = Sp.x12),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            GlassIcon(LpIcons.unlock, "锁屏", onClick = onLock)
            Spacer(Modifier.height(Sp.x12))
            GlassIcon(LpIcons.camera, "截屏", onClick = onShot)
        }

        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(BottomVeil)
                .safeDrawingPadding().padding(top = Sp.x12),
        ) {
            ProgressRow(position, duration, heat, onSeek)
            Row(
                Modifier.fillMaxWidth().padding(start = Sp.x6, end = Sp.x6, bottom = Sp.x2),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                LpIconButton(LpIcons.rewind, "后退 10 秒", size = 22, tint = Color.White,
                    onClick = { onSeek((position - 10).coerceAtLeast(0.0)) })
                /* 播放键带辉光【用户定 2026-09-07】。整排里**只有它**发光 ——
                   它是这一页唯一的主动作,别的都在发光就等于谁都不突出。 */
                LpIconButton(
                    if (paused) LpIcons.play else LpIcons.pause, if (paused) "播放" else "暂停",
                    size = 30, tint = Color.White, glow = true, onClick = onToggle,
                )
                LpIconButton(LpIcons.forward, "前进 10 秒", size = 22, tint = Color.White,
                    onClick = { onSeek(position + 10) })
                Spacer(Modifier.weight(1f))
                SpeedGroup(speed, onSpeed)
                if (!portrait) Chip("音轨") { onPanel("audio") }
                // 横屏给「比例」一个自己的位置:埋在「更多」里用户找不到(报过一次)
                if (!portrait) Chip("比例") { onPanel("ratio") }
                Chip("字幕") { onPanel("subtitle") }
                /* ☠ **电影不画「选集」**【用户定 2026-09-07】。它点开必然是一张空表 ——
                   而一个「点开永远是空的」按钮比没有它更让人怀疑是不是坏了。 */
                if (hasEpisodes) Chip("选集") { onPanel("episodes") }
            }
        }
    }
}

/**
 * 音量 / 亮度指示。**屏幕正中**,一格一格的条比一根连续的线好读。
 *
 * ★ 只在调的那一刻出现,900ms 不动就自己走 —— 它是反馈,不是常驻读数。
 */
@Composable
private fun AdjustHud(brightness: Boolean, value: Float) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            Modifier.clip(RoundedCornerShape(R.md)).background(Color.Black.copy(alpha = .62f))
                .padding(horizontal = Sp.x20, vertical = Sp.x16),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(
                if (brightness) LpIcons.sun else LpIcons.audio,
                if (brightness) "亮度" else "音量",
                Modifier.size(26.dp), tint = Color.White,
            )
            Spacer(Modifier.height(Sp.x10))
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                // 12 格。刻度比百分数好读 —— 调的时候眼睛在画面上,读不了两位数字
                repeat(12) { i ->
                    Box(
                        Modifier.size(width = 6.dp, height = 14.dp)
                            .clip(RoundedCornerShape(R.none))
                            .background(
                                if (i < (value * 12).toInt().coerceAtLeast(if (value > 0f) 1 else 0))
                                    Color.White else Color.White.copy(alpha = .26f)
                            ),
                    )
                }
            }
            Spacer(Modifier.height(Sp.x8))
            Text("${(value * 100).toInt()}%", color = Color.White, fontSize = 12.sp)
        }
    }
}

/** 右上角的网速读数,只管画。数在哪儿数见 [sampleNetSpeed]。 */
@Composable
private fun NetSpeed(text: String) {
    if (text.isEmpty()) return
    Text(
        text, Modifier.padding(end = Sp.x6),
        color = Color.White.copy(alpha = .82f), fontSize = 12.sp, maxLines = 1,
    )
}

/** 倍速:**连续不是档位**。点一下走 0.25。 */
private fun step(cur: Double, dir: Int) =
    ((cur + dir * 0.25).coerceIn(SP_MIN, SP_MAX) * 100).toInt() / 100.0

/** `− 1.5× +`。三件一组,中间那个数**不是按钮**,只是读数。 */
@Composable
private fun SpeedGroup(speed: Double, onSpeed: (Double) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        LpIconButton(LpIcons.minus, "减速", size = 16, tint = Color.White,
            onClick = { onSpeed(step(speed, -1)) })
        Text(
            "%.2f×".format(speed).replace(".00", ""),
            color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium,
        )
        LpIconButton(LpIcons.plus, "加速", size = 16, tint = Color.White,
            onClick = { onSpeed(step(speed, +1)) })
    }
}

/**
 * OSD 上的一颗功能钮。
 *
 * ★ **拆掉灰底,只剩字**:画面才是这一页的主角,常态的按钮不该在上面盖出几块补丁。
 * ☠ 命中区**必须靠 `heightIn` 撑到 44dp**,不能靠外边距 —— 外边距在 `pressable`
 *   外面,撑大的是间隙不是命中区。上一版就是这么写的,实测可点高度只有 28dp。
 */
@Composable
private fun Chip(label: String, onClick: () -> Unit) {
    Box(
        Modifier.heightIn(min = Dim.tap).clip(RoundedCornerShape(R.pill))
            .pressable(onClick).padding(horizontal = Sp.x10),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = Color.White, fontSize = 13.sp, maxLines = 1)
    }
}

/**
 * 进度条。左右是读数,中间是滑杆 —— 一行搞定,比上下两行省一截高度。
 *
 * ☠ **`duration == 0` 时禁用**,并且不许用 0 盖掉已知时长 ——
 * 真服加载窗口实测 6~7 秒,这期间点中间会跳到 0.5 秒,用户看到的是「画面不变」。
 */
@Composable
private fun ProgressRow(
    position: Double, duration: Double, heat: List<Float>, onSeek: (Double) -> Unit,
) {
    val enabled = duration > 0
    var live by remember(position) { mutableFloatStateOf(position.toFloat()) }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Sp.x12),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(fmtTime(position), color = Color.White, fontSize = 11.sp)
        /* 热力图画在滑杆**上方**那 10dp 里,不叠进轨道 ——
           叠进去的话它和已播那半截互相染色,两个都读不出来。
           空表就整块不占位:关掉热力图之后进度条要回到原来的高度。 */
        Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
        if (heat.isNotEmpty()) androidx.compose.foundation.Canvas(
            Modifier.fillMaxWidth().height(10.dp)
                .align(Alignment.TopCenter).padding(horizontal = Sp.x10),
        ) {
            val cw = size.width / heat.size
            heat.forEachIndexed { i, v ->
                val h = v.coerceIn(0f, 1f) * size.height
                if (h > 0.5f) drawRect(
                    Color(0xFFFF9D3F).copy(alpha = .4f),
                    topLeft = androidx.compose.ui.geometry.Offset(i * cw, size.height - h),
                    size = androidx.compose.ui.geometry.Size(cw + .5f, h),
                )
            }
        }
        Slider(
            value = if (enabled) live.coerceIn(0f, duration.toFloat()) else 0f,
            onValueChange = { live = it },
            onValueChangeFinished = { if (enabled) onSeek(live.toDouble()) },
            valueRange = 0f..(if (enabled) duration.toFloat() else 1f),
            enabled = enabled,
            modifier = Modifier.fillMaxWidth().padding(horizontal = Sp.x10),
            colors = SliderDefaults.colors(thumbColor = Lp.colors.acc,
                activeTrackColor = Lp.colors.acc, inactiveTrackColor = Color.White.copy(alpha = .3f)),
        )
        }
        // 右边写**剩余**不写总长:看片的时候关心的是「还有多久」
        Text(
            if (enabled) "-" + fmtTime((duration - position).coerceAtLeast(0.0)) else "--:--",
            color = Color.White, fontSize = 11.sp,
        )
    }
}

/**
 * 标题跑马灯。
 * ① 放得下就不滚 ② 速度 **30 dp/s**,**不写死总时长**(写死 = 标题越长划得越快)
 * ③ 完整滚一圈**不来回弹** ④ 两头各留停顿。
 */
@Composable
private fun Marquee(text: String, m: Modifier = Modifier) {
    Text(
        text,
        m.basicMarqueeCompat(),
        color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium,
        maxLines = 1, overflow = TextOverflow.Clip,
    )
}

/**
 * 跑马灯。**速度写成 dp/s,不写死总时长** —— 写死的话标题越长划得越快,
 * 长剧名根本来不及看清。放得下时 basicMarquee 自己不滚。
 */
private fun Modifier.basicMarqueeCompat(): Modifier =
    this.basicMarquee(iterations = Int.MAX_VALUE, repeatDelayMillis = 2000, velocity = 30.dp)

/**
 * 起播失败时回读一次播放器的真实状态。
 *
 * ☠☠ **「有声音没画面」和「什么都没打开」在界面上长得一模一样**,而两者的根因
 * 完全不同(前者是 vo 没起来 / 画面被挡住,后者是流没打开)。不回读的话这类报告
 * 只能靠猜 —— 上一版那句「原因在日志里」实测白烧过好几轮。
 *
 * 用的是既有的 `player.opts`(它回读的是 mpv 的**当前值**,不是我们设进去的值),
 * 不新开命令:命令名是字符串,新增一条要同时动 COMMANDS.md 和三端绑定,
 * 而这里要的东西那条命令已经全有了。
 *
 * ★ 取不到就说取不到,**不编**。
 */
private suspend fun failureDiag(app: xyz.linplayer.app.data.AppState): String {
    val d = runCatching { app.call("player.opts") }.getOrNull().obj()
        ?: return "播放器没给出原因(诊断也没读到)。"
    val vo = d.str("current-vo").orEmpty().ifBlank { d.str("vo").orEmpty() }
    val w = d.str("dwidth")?.toIntOrNull() ?: 0
    val h = d.str("dheight")?.toIntOrNull() ?: 0
    val head = when {
        vo.isBlank() -> "视频输出没能建起来(vo 是空的)"
        w <= 0 || h <= 0 -> "视频输出建起来了,但一帧都没解出来"
        else -> "画面有 " + w + "×" + h + ",但没能上屏"
    }
    val tail = listOfNotNull(
        vo.takeIf { it.isNotBlank() }?.let { "vo=" + it },
        d.str("hwdec-current")?.takeIf { it.isNotBlank() }?.let { "解码=" + it },
        d.str("video-codec")?.takeIf { it.isNotBlank() },
        d.str("last_error")?.takeIf { it.isNotBlank() },
    ).joinToString(" · ")
    return if (tail.isEmpty()) head else head + "\n" + tail
}

/**
 * 取回外挂 ASS 并交给 libass。
 *
 * ★ 判据是**内容**不是扩展名:Emby 的 `Stream.{ext}` 在有的 fork 上会转格式,
 *   而 `.ass` 结尾的地址回一份 SRT 是真会发生的。看头两百字节有没有
 *   `[Script Info]` / `[V4+ Styles]` —— 这一条比信文件名稳。
 * ★ 只取**第一份能用的**:同时挂两份 ASS 等于两层字压在一起。
 *   默认轨优先,没有默认就取第一份。
 * ★ UA 走 `LinPlayer/<版本>`(UA 三分口径)。地址里已经带着鉴权,不另附凭据。
 */
private suspend fun loadExternalAss(
    app: xyz.linplayer.app.data.AppState,
    subs: kotlinx.serialization.json.JsonElement?,
) = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
    if (!Libass.available) return@withContext
    val list = subs.arr().mapNotNull { it.obj() }
    val ordered = list.sortedByDescending { it.bool("is_default") }
    for (o in ordered) {
        val u = o.str("url")?.takeIf { it.isNotBlank() } ?: continue
        val bytes = runCatching {
            val c = java.net.URL(u).openConnection() as java.net.HttpURLConnection
            c.connectTimeout = 8000
            c.readTimeout = 15000
            c.setRequestProperty("User-Agent",
                "LinPlayer/" + xyz.linplayer.app.BuildConfig.VERSION_NAME)
            c.inputStream.use { st -> st.readBytes() }
        }.getOrNull() ?: continue
        // 4MB 封顶:字幕再长也到不了,到了多半是取回了一部片
        if (bytes.isEmpty() || bytes.size > (4 shl 20)) continue
        val head = String(bytes, 0, minOf(bytes.size, 512), Charsets.UTF_8)
        if (!head.contains("[Script Info]") && !head.contains("[V4+ Styles]") &&
            !head.contains("[V4 Styles]")) continue
        if (Libass.activateFile(u, bytes, LIBASS_FONTS_DIR)) return@withContext
    }
}

/**
 * 抠出内嵌字体交给 libass。
 *
 * ★ 放在 IO 上跑,**不等它**:一次 Range 往返几百毫秒起,挡在起播前面就是
 *   每一集都多等半秒,而它失败的代价只是字形回落。
 */
private suspend fun loadEmbeddedFonts(url: String) =
    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
        if (!Libass.available) return@withContext
        val ua = "LinPlayer/" + xyz.linplayer.app.BuildConfig.VERSION_NAME
        val fonts = runCatching { MkvFonts.extract(MkvFonts.ranged(url, ua)) }
            .getOrDefault(emptyList())
        if (fonts.isNotEmpty()) Libass.addFonts(fonts)
    }
