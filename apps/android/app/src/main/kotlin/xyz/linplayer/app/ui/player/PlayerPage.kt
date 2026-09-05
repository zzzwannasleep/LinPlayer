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
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.dbl
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.LpIconButton
import xyz.linplayer.app.ui.components.OptRow
import xyz.linplayer.app.ui.components.pressable
import xyz.linplayer.app.ui.pages.args
import xyz.linplayer.app.ui.pages.fmtTime
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp

private const val OSD_HIDE_MS = 5000L
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
    /** 跟手 seek 的预览值。**松手才发命令** —— 跟着滑发是每帧一条,把核心层的 seek 闩打乱。 */
    var seekPreview by remember { mutableStateOf<Double?>(null) }
    var volume by remember { mutableFloatStateOf(1f) }

    // 屏幕常亮(U1.24):播放中不息屏,暂停 / 退出后恢复
    DisposableEffect(paused) {
        val w = activity?.window
        if (!paused) w?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else w?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { w?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }

    // 起播。★ 换片时**先立「未就绪」再发命令**,不能排在两个 await 之后
    LaunchedEffect(route.itemId) {
        everMoved = false; buffering = true; position = 0.0; duration = 0.0
        // 通知权限在**这里**要,不在冷启动时要(U1.27):它只在后台播放挂通知栏时有意义
        (activity as? xyz.linplayer.app.MainActivity)?.askNotificationPermission()
        app.wantsPip = true
        runCatching { app.call("player.play", args("item_id" to route.itemId)) }
            .onFailure { app.report(it) }
    }

    // 订阅 player.status(4 Hz)。**不轮询**
    LaunchedEffect(Unit) {
        app.core.events.collect { ev ->
            if (ev.name != "player.status") return@collect
            val o = ev.data as? JsonObject
            val p = o.dbl("position") ?: 0.0
            if (p > position + 0.05) everMoved = true
            position = p
            duration = o.dbl("duration") ?: duration
            paused = o.bool("paused")
            buffering = o.bool("buffering")
            // ☠ 判播完必须读 eof —— keep-open 下 END_FILE 永远不发
            if (o.bool("eof")) nav.popBackStack()
        }
    }

    // 4 秒兜底放行:但**放行前必须先确认不在等缓冲**
    LaunchedEffect(route.itemId) {
        delay(4000)
        if (!buffering) everMoved = true
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
                app.call("emby.reportProgress",
                    args("item_id" to route.itemId, "position_secs" to position))
            }
        }
    }
    DisposableEffect(route.itemId) {
        onDispose {
            app.wantsPip = false
            scope.launch {
                runCatching {
                    // ☠ 播完收尾传**总时长**不是当前时间 —— 差最后零点几秒 =
                    //   服务端不算看完,Trakt / Bangumi 一次都不触发
                    val p = if (duration > 0 && position >= duration - 2) duration else position
                    app.call("emby.reportProgress",
                        args("item_id" to route.itemId, "position_secs" to p, "stopped" to true))
                    app.call("player.stopPlayback")
                }
            }
        }
    }

    // 返回键四级:小浮层 → 面板 → OSD → 才退出播放
    BackHandler {
        when {
            panel != null -> panel = null
            osd -> osd = false
            else -> nav.popBackStack()
        }
    }

    // 横屏时锁掉系统栏。竖屏保留(下面是内容区)
    DisposableEffect(portrait) {
        activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        onDispose { }
    }

    val c = Lp.colors
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        // 视频层:SurfaceView。Compose 内容天然画在它上面
        VideoSurface(app.core, Modifier.fillMaxSize())

        // 未出画时的黑幕 + 转圈。**判据是「时间真的往前走了」**
        if (!everMoved) Box(Modifier.fillMaxSize().background(Color.Black),
            contentAlignment = Alignment.Center) {
            Dim3(if (buffering) "正在缓冲…" else "正在打开…")
        }

        // 三区手势(UI_MOBILE.md §8.4)。锁屏后只有解锁按钮响应
        if (!locked) Box(
            Modifier.fillMaxSize().pointerInput(Unit) {
                detectTapGestures(
                    onTap = { osd = !osd },
                    onDoubleTap = {
                        scope.launch {
                            runCatching { app.call("player.setPause", args("paused" to !paused)) }
                        }
                    },
                )
            }.pointerInput(duration) {
                var acc = 0f
                detectDragGestures(
                    onDragEnd = {
                        // ★ 松手才真 seek
                        seekPreview?.let { t ->
                            scope.launch {
                                runCatching { app.call("player.seek", args("position_secs" to t)) }
                            }
                        }
                        seekPreview = null; acc = 0f
                    },
                ) { change, drag ->
                    change.consume()
                    if (kotlin.math.abs(drag.x) > kotlin.math.abs(drag.y)) {
                        if (duration > 0) {
                            acc += drag.x
                            seekPreview = (position + acc / size.width * duration * 0.6)
                                .coerceIn(0.0, duration)
                            osd = true
                        }
                    } else if (change.position.x > size.width / 2) {
                        // 右 1/3 竖滑 = 音量。**不用系统音量条**
                        volume = (volume - drag.y / size.height).coerceIn(0f, 1f)
                        scope.launch {
                            runCatching {
                                app.call("player.setVolume",
                                    args("volume" to (volume * 100).toInt()))
                            }
                        }
                        osd = true
                    } else {
                        // 左 1/3 竖滑 = 亮度。**不改系统亮度**,只改本窗口
                        activity?.window?.attributes = activity?.window?.attributes?.apply {
                            screenBrightness = (screenBrightness.takeIf { it >= 0 } ?: 0.5f)
                                .minus(drag.y / size.height).coerceIn(0.01f, 1f)
                        }
                        osd = true
                    }
                }
            }
        )

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

        // ★ OSD 抬在 scrim 之上:面板开关期间上下栏**一动不动**
        AnimatedVisibility(osd || panel != null, enter = fadeIn(), exit = fadeOut()) {
            if (portrait) PortraitOsd(
                title = route.title, position = seekPreview ?: position, duration = duration,
                paused = paused, onBack = { nav.popBackStack() },
                onToggle = {
                    scope.launch { runCatching { app.call("player.setPause", args("paused" to !paused)) } }
                },
                onSeek = { t -> scope.launch { runCatching { app.call("player.seek", args("position_secs" to t)) } } },
            ) else LandscapeOsd(
                title = route.title, position = seekPreview ?: position, duration = duration,
                paused = paused, speed = speed, locked = locked,
                onBack = { nav.popBackStack() },
                onToggle = {
                    scope.launch { runCatching { app.call("player.setPause", args("paused" to !paused)) } }
                },
                onSeek = { t -> scope.launch { runCatching { app.call("player.seek", args("position_secs" to t)) } } },
                onSpeed = { v ->
                    speed = v
                    scope.launch { runCatching { app.call("player.setSpeed", args("speed" to v)) } }
                },
                onLock = { locked = !locked },
                onPanel = { panel = it },
            )
        }

        // 锁屏后只有解锁按钮
        if (locked) LpIconButton(LpIcons.lock, "解锁",
            Modifier.align(Alignment.CenterStart).padding(Sp.x16),
            tint = Color.White, onClick = { locked = false })

        panel?.let { PlayerPanel(it, route.itemId) { panel = null } }
    }
}

/** 竖屏 OSD:三层(顶部返回+标题、中间三键、底部进度条)。**九宫格是横屏专属。** */
@Composable
private fun PortraitOsd(
    title: String, position: Double, duration: Double, paused: Boolean,
    onBack: () -> Unit, onToggle: () -> Unit, onSeek: (Double) -> Unit,
) {
    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        Row(Modifier.align(Alignment.TopStart).fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            LpIconButton(LpIcons.back, "返回", tint = Color.White, onClick = onBack)
            Marquee(title, Modifier.weight(1f))
        }
        Row(Modifier.align(Alignment.Center), horizontalArrangement = Arrangement.spacedBy(Sp.x26),
            verticalAlignment = Alignment.CenterVertically) {
            LpIconButton(LpIcons.rewind, "快退", size = 28, tint = Color.White,
                onClick = { onSeek((position - 10).coerceAtLeast(0.0)) })
            LpIconButton(if (paused) LpIcons.play else LpIcons.pause,
                if (paused) "播放" else "暂停", size = 36, tint = Color.White, onClick = onToggle)
            LpIconButton(LpIcons.forward, "快进", size = 28, tint = Color.White, onClick = { onSeek(position + 10) })
        }
        ProgressBar(position, duration, onSeek, Modifier.align(Alignment.BottomCenter))
    }
}

/**
 * 横屏 OSD · 九宫格【用户定 2026-07-28】。
 *
 * 上一版把东西全堆在上下两条栏里,**屏幕两侧和中间全空着** —— 那是没把屏幕用完。
 * 遮挡率从 83.6% 降到 38.5% 量级靠的是把控件摊到九个角落,不是把控件做小。
 */
@Composable
private fun LandscapeOsd(
    title: String, position: Double, duration: Double, paused: Boolean, speed: Double,
    locked: Boolean, onBack: () -> Unit, onToggle: () -> Unit, onSeek: (Double) -> Unit,
    onSpeed: (Double) -> Unit, onLock: () -> Unit, onPanel: (String) -> Unit,
) {
    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        // 左上:返回 + 标题(过长慢速滚)
        Row(Modifier.align(Alignment.TopStart).fillMaxWidth(0.6f),
            verticalAlignment = Alignment.CenterVertically) {
            LpIconButton(LpIcons.back, "返回", tint = Color.White, onClick = onBack)
            Marquee(title, Modifier.weight(1f))
        }
        // 右上:版本·线路 / 超分 / 更多。★ 版本与线路合成一个「源」面板
        Row(Modifier.align(Alignment.TopEnd), horizontalArrangement = Arrangement.spacedBy(Sp.x2)) {
            Chip32("源", { onPanel("source") })
            Chip32("画质", { onPanel("quality") })
            Chip32("更多", { onPanel("more") })
        }
        // 左中:截图 / 锁屏
        Column(Modifier.align(Alignment.CenterStart), horizontalAlignment = Alignment.CenterHorizontally) {
            LpIconButton(LpIcons.camera, "截图", tint = Color.White, onClick = { onPanel("shot") })
            LpIconButton(if (locked) LpIcons.lock else LpIcons.unlock,
                if (locked) "解锁" else "锁屏", tint = Color.White, onClick = onLock)
        }
        // 右中:倍速条(上加 中显示 下减)
        Column(Modifier.align(Alignment.CenterEnd), horizontalAlignment = Alignment.CenterHorizontally) {
            LpIconButton(LpIcons.plus, "加速", tint = Color.White, onClick = { onSpeed(step(speed, +1)) })
            Text("%.2f×".format(speed).replace(".00", ""), color = Color.White, fontSize = 13.sp)
            LpIconButton(LpIcons.minus, "减速", tint = Color.White, onClick = { onSpeed(step(speed, -1)) })
        }
        // 左下:上一集 / 下一集
        Row(Modifier.align(Alignment.BottomStart).padding(bottom = 44.dp)) {
            Chip32("上一集", { onPanel("episodes") })
            Chip32("下一集", { onPanel("episodes") })
        }
        // 右下:音轨 / 弹幕 / 选集
        Row(Modifier.align(Alignment.BottomEnd).padding(bottom = 44.dp)) {
            Chip32("音轨", { onPanel("audio") })
            Chip32("弹幕", { onPanel("danmaku") })
            Chip32("选集", { onPanel("episodes") })
        }
        // 中下:快退 / 播放暂停 / 快进
        Row(Modifier.align(Alignment.BottomCenter).padding(bottom = 44.dp),
            horizontalArrangement = Arrangement.spacedBy(Sp.x20),
            verticalAlignment = Alignment.CenterVertically) {
            LpIconButton(LpIcons.rewind, "快退", size = 24, tint = Color.White,
                onClick = { onSeek((position - 10).coerceAtLeast(0.0)) })
            LpIconButton(if (paused) LpIcons.play else LpIcons.pause,
                if (paused) "播放" else "暂停", size = 30, tint = Color.White, onClick = onToggle)
            LpIconButton(LpIcons.forward, "快进", size = 24, tint = Color.White, onClick = { onSeek(position + 10) })
        }
        ProgressBar(position, duration, onSeek, Modifier.align(Alignment.BottomCenter))
    }
}

/** 倍速:**连续不是档位**。点一下走 0.25(长按走 0.05 由 StepperRow 那套承担)。 */
private fun step(cur: Double, dir: Int) =
    ((cur + dir * 0.25).coerceIn(SP_MIN, SP_MAX) * 100).toInt() / 100.0

/** 横屏 chip:视觉 32dp,**命中区靠外边距撑到 44dp**(UI_MOBILE.md §1.5 的唯一例外)。 */
@Composable
private fun Chip32(label: String, onClick: () -> Unit) {
    Box(
        Modifier.padding(6.dp).clip(RoundedCornerShape(R.pill))
            .background(Lp.colors.chip).pressable(onClick)
            .padding(horizontal = Sp.x12, vertical = Sp.x6),
        contentAlignment = Alignment.Center,
    ) { Text(label, color = Color.White, fontSize = 12.sp, maxLines = 1) }
}

/**
 * 进度条。
 * ☠ **`duration == 0` 时禁用**,并且不许用 0 盖掉已知时长 ——
 * 真服加载窗口实测 6~7 秒,这期间点中间会跳到 0.5 秒,用户看到的是「画面不变」。
 */
@Composable
private fun ProgressBar(position: Double, duration: Double, onSeek: (Double) -> Unit, m: Modifier) {
    val enabled = duration > 0
    var live by remember(position) { mutableFloatStateOf(position.toFloat()) }
    Column(m.fillMaxWidth().padding(horizontal = Sp.x12)) {
        Slider(
            value = if (enabled) live.coerceIn(0f, duration.toFloat()) else 0f,
            onValueChange = { live = it },
            onValueChangeFinished = { if (enabled) onSeek(live.toDouble()) },
            valueRange = 0f..(if (enabled) duration.toFloat() else 1f),
            enabled = enabled,
            colors = SliderDefaults.colors(thumbColor = Lp.colors.acc,
                activeTrackColor = Lp.colors.acc, inactiveTrackColor = Color.White.copy(alpha = .3f)),
        )
        Row(Modifier.fillMaxWidth().padding(bottom = Sp.x6)) {
            Text(fmtTime(position), color = Color.White, fontSize = 11.sp)
            Spacer(Modifier.weight(1f))
            Text(if (enabled) fmtTime(duration) else "--:--", color = Color.White, fontSize = 11.sp)
        }
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
