package xyz.linplayer.app.ui.player

import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import kotlin.math.abs
import kotlinx.serialization.json.JsonObject
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.dbl
import xyz.linplayer.app.data.long
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str

/**
 * 弹幕绘制层。
 *
 * ☠☠ **弹幕以前是交给 mpv 的 `osd-overlay` 画的,那条路整段废掉了。**
 * 它有三个各自致命的毛病:Exo 内核下 mpv 手里没有这一片(而命令照样返回成功);
 * 位置从 `time-pos` 插出来,而 time-pos 只在**视频帧边界**更新,24fps 片源上
 * 弹幕就跟着 24Hz 一顿一顿;每秒 120 条 overlay 命令全压在 mpv 的核心线程上,
 * 而那条线程同时在解封装和解图形字幕。
 *
 * 画在 View 层这三条一条都不存在:帧回调是 Compose 自己的,和内核无关。
 *
 * ★ 排版(哪条排第几轨、排不下丢哪条)仍在核心层,这里只做两件事:
 *   按帧把 x 插出来、把字画上去。见 `core/player/danmakustyle.go`。
 */

/** 一条排好版的弹幕。字段名照 `player.danmakuLayout` 的单字母键。 */
class DmItem(
    val t: Double,
    val mode: Int,
    val lane: Int,
    /** 核心层估的文本宽,单位是 1920×1080 画布的像素。 */
    val w: Double,
    val color: Int,
    val text: String,
)

/** 一整份排版结果 + 已经把缩放和速度折算进去的几何量。 */
class DmLayout(
    val resX: Double,
    val resY: Double,
    val laneHeight: Double,
    val rollSeconds: Double,
    val fixSeconds: Double,
    val fontSize: Double,
    val opacity: Double,
    val bold: Boolean,
    /** 按时刻升序 —— 每帧靠二分找起点,不遍历全表。 */
    val items: List<DmItem>,
)

fun parseDmLayout(r: JsonObject?): DmLayout? {
    r ?: return null
    val items = r["items"].arr().mapNotNull { e ->
        val o = e.obj() ?: return@mapNotNull null
        DmItem(
            t = o.dbl("t") ?: return@mapNotNull null,
            mode = (o.long("m") ?: 1).toInt(),
            lane = (o.long("l") ?: 0).toInt(),
            w = o.dbl("w") ?: 0.0,
            color = (o.long("c") ?: 0xFFFFFF).toInt(),
            text = o.str("u") ?: return@mapNotNull null,
        )
    }
    return DmLayout(
        resX = r.dbl("res_x") ?: 1920.0,
        resY = r.dbl("res_y") ?: 1080.0,
        laneHeight = r.dbl("lane_height") ?: 54.0,
        rollSeconds = r.dbl("roll_seconds") ?: 8.0,
        fixSeconds = r.dbl("fix_seconds") ?: 5.0,
        fontSize = r.dbl("font_size") ?: 40.0,
        opacity = r.dbl("opacity") ?: 1.0,
        bold = r.bool("bold"),
        items = items,
    )
}

/**
 * 弹幕钟走一帧。`target` 是轮询报回来的播放位置,`dt` 是这一帧过了多少秒。
 *
 * 软对表而不是硬赋值:轮询一秒来 4~10 拍,每拍都把钟拽到轮询值上的话,
 * 整屏弹幕会跟着一起跳 —— 那正是用户说的「抽帧」。
 */
fun dmTick(clock: Double, target: Double, dt: Double, speed: Double): Double {
    val next = clock + dt * speed
    val drift = target - next
    // 差过一秒就是 seek / 换片,直接对齐;否则每帧只追 8% ——
    // 硬对表会让整屏弹幕在每一拍轮询上一起跳一下,那正是「抽帧」的样子
    return if (abs(drift) > 1.0) target else next + drift * 0.08
}

/**
 * 一条滚动弹幕在 `now` 时刻的左边缘。
 *
 * 从右沿出发,走到整条完全离开左边为止 —— 走的距离是 `width + w`,不是 `width`。
 * 少算这一截的表现是长弹幕还没走完就在左边被瞬间抹掉。
 */
fun dmRollX(width: Double, w: Double, age: Double, roll: Double): Double =
    width - age / roll * (width + w)

/** 二分找第一条 `t >= from` 的下标。列表按 t 升序。 */
fun dmFirstAtOrAfter(items: List<DmItem>, from: Double): Int {
    var lo = 0
    var hi = items.size
    while (lo < hi) {
        val mid = (lo + hi) ushr 1
        if (items[mid].t < from) lo = mid + 1 else hi = mid
    }
    return lo
}

/**
 * @param position 播放位置(秒)。4Hz~10Hz 来一次就够 —— 两次之间用帧时钟往前推。
 */
@Composable
fun DanmakuLayer(
    layout: DmLayout?,
    position: Double,
    paused: Boolean,
    speed: Double,
    modifier: Modifier = Modifier,
) {
    if (layout == null || layout.items.isEmpty()) return

    /* ★ 每收到一次 position 就**对表**,两次之间自己按帧往前推。
       直接拿 position 画的表现是弹幕每秒只动 4 下(或者 Exo 那边 10 下)—— 一格一格地跳。

       ☠ **position 不能进 LaunchedEffect 的 key。** 进了的话每来一拍轮询就
       重启一次帧循环:硬对一次表 + 起手那句 `withFrameNanos` 白丢一帧,
       一秒 4~10 次,看上去正是用户说的「弹幕滚动像抽帧」(2026-09-12)。
       改成一条长命的循环 + 每帧软对表,见 [dmTick]。 */
    val clock = remember { mutableDoubleStateOf(position) }
    val target = rememberUpdatedState(position)
    LaunchedEffect(paused, speed) {
        if (paused) return@LaunchedEffect
        var last = withFrameNanos { it }
        while (true) {
            withFrameNanos { n ->
                clock.doubleValue = dmTick(
                    clock.doubleValue, target.value, (n - last) / 1_000_000_000.0, speed)
                last = n
            }
        }
    }
    // 暂停时钟停了,而这期间用户可能拖了进度条 —— 那时只能硬对
    LaunchedEffect(position, paused) { if (paused) clock.doubleValue = position }

    // 两支笔跨帧复用:每帧新建 Paint 会把 GC 拖进渲染帧里
    val fill = remember { Paint(Paint.ANTI_ALIAS_FLAG) }
    val shadow = remember { Paint(Paint.ANTI_ALIAS_FLAG) }

    Canvas(modifier) { drawDanmaku(layout, clock.doubleValue, fill, shadow) }
}

/**
 * ☠☠ **描边不用 `Paint.Style.STROKE`。**
 *
 * 描边文字在 Android 上走的是**轮廓路径**那条路:每个字形要取 Path 再填,
 * 绕开了字形缓存,而缓存正是普通 `drawText` 快的全部原因。屏幕上四十条弹幕
 * 每帧各描一遍,一帧就烧掉十几毫秒 —— 用户报的「弹幕移动起来很掉帧」是这个。
 * 换成「先画一层深色偏一点,再压上正文」:两次都吃字形缓存,代价接近零,
 * 而看上去是同一回事(PC 那层一直就是这么画的)。
 */
private fun DrawScope.drawDanmaku(l: DmLayout, now: Double, fill: Paint, shadow: Paint) {
    if (size.height <= 0f || size.width <= 0f) return
    /* 按**高度**换算比例:弹幕的行数和字号是相对画面高度定的。
       宽高各自缩会把字压扁,而横向扫过多远本来就该用整块宽度。 */
    val sy = size.height / l.resY.toFloat()
    val fontPx = (l.fontSize * sy).toFloat()
    val laneH = (l.laneHeight * sy).toFloat()
    val alpha = (l.opacity.coerceIn(0.0, 1.0) * 255).toInt()
    fill.textSize = fontPx
    shadow.textSize = fontPx
    fill.isFakeBoldText = l.bold
    shadow.isFakeBoldText = l.bold
    shadow.color = 0x000000 or (alpha * 3 / 4 shl 24)
    val off = (fontPx * 0.05f).coerceAtLeast(1f)

    val life = maxOf(l.rollSeconds, l.fixSeconds)
    var i = dmFirstAtOrAfter(l.items, now - life)
    drawIntoCanvas { c ->
        val nc = c.nativeCanvas
        while (i < l.items.size) {
            val d = l.items[i]
            i++
            if (d.t > now) break
            val age = now - d.t
            val span = if (d.mode == 1) l.rollSeconds else l.fixSeconds
            if (age > span) continue
            val wPx = (d.w * sy).toFloat()
            val x: Float
            val topPx: Float
            when (d.mode) {
                1 -> {
                    // 直接按**实际像素**插:横向铺满整块画面,不经过 1920 画布那一道
                    x = dmRollX(size.width.toDouble(), wPx.toDouble(), age, l.rollSeconds).toFloat()
                    topPx = 4 * sy + d.lane * laneH
                }
                5 -> {
                    x = (size.width - wPx) / 2
                    topPx = 4 * sy + d.lane * laneH
                }
                else -> {
                    x = (size.width - wPx) / 2
                    topPx = size.height - 4 * sy - (d.lane + 1) * laneH
                }
            }
            if (x > size.width || x + wPx < 0) continue
            // 基线在字框顶下方约 0.8 个字高 —— Paint 的 textSize 是字框高不是基线高
            val baseline = topPx + fontPx * 0.8f
            fill.color = (alpha shl 24) or (d.color and 0xFFFFFF)
            nc.drawText(d.text, x + off, baseline + off, shadow)
            nc.drawText(d.text, x, baseline, fill)
        }
    }
}
