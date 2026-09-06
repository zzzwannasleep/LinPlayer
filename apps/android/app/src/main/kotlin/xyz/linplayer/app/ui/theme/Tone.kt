package xyz.linplayer.app.ui.theme

import android.graphics.Bitmap
import android.util.LruCache
import androidx.compose.animation.animateColorAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import coil3.BitmapImage
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/*
 * 封面取色(草稿 03/04:「背景色就用封面取色」)。
 *
 * ★ **不引 androidx.palette。** 它给的是「Vibrant / Muted」六个槽,而我们只要一个
 *   「能当整页底色」的值 —— 那要求比 Palette 的目标更窄:必须够艳(灰了就等于没取色)、
 *   又必须够暗(亮了压不住白字)。这两条 clamp 才是关键,聚类反而不是。
 * ★ 算法**全是纯 Kotlin**,不碰 android.graphics.Color 的静态方法 ——
 *   那些在 JVM 单测里是「not mocked」直接抛,写进去就等于这段逻辑永远测不了。
 */

// ---------------------------------------------------------------- 纯逻辑(可单测)

/** RGB(0~255) → HSV。h 单位是度(0~360),s/v 是 0~1。 */
internal fun rgbToHsv(r: Int, g: Int, b: Int): FloatArray {
    val rf = r / 255f; val gf = g / 255f; val bf = b / 255f
    val mx = maxOf(rf, gf, bf); val mn = minOf(rf, gf, bf)
    val d = mx - mn
    val h = when {
        d < 1e-6f -> 0f
        mx == rf -> (60f * ((gf - bf) / d) + 360f) % 360f
        mx == gf -> 60f * ((bf - rf) / d) + 120f
        else -> 60f * ((rf - gf) / d) + 240f
    }
    return floatArrayOf(h, if (mx <= 0f) 0f else d / mx, mx)
}

/** HSV → 0xRRGGBB。 */
internal fun hsvToRgb(h: Float, s: Float, v: Float): Int {
    val c = v * s
    val hp = ((h % 360f) + 360f) % 360f / 60f
    val x = c * (1f - kotlin.math.abs(hp % 2f - 1f))
    val (r1, g1, b1) = when (hp.toInt()) {
        0 -> Triple(c, x, 0f); 1 -> Triple(x, c, 0f); 2 -> Triple(0f, c, x)
        3 -> Triple(0f, x, c); 4 -> Triple(x, 0f, c); else -> Triple(c, 0f, x)
    }
    val m = v - c
    fun q(f: Float) = ((f + m) * 255f + 0.5f).toInt().coerceIn(0, 255)
    return (q(r1) shl 16) or (q(g1) shl 8) or q(b1)
}

/**
 * 从缩略图像素里挑一个能当页面底色的色。全是灰 / 全是黑白时返回 null。
 *
 * ★ **色相按圆周平均,不按算术平均。** 红色跨 0°/360°,算术平均会把
 *   「一堆红」平均成青色 —— 而那正好是最刺眼的补色,谁看都知道错了但查不出原因。
 * ★ 出来的 s/v 一律 clamp:艳到能看出是「这部片的颜色」,暗到白字压得住。
 */
internal fun pickTone(pixels: IntArray): Int? {
    val bins = 12
    val w = FloatArray(bins); val sinH = FloatArray(bins); val cosH = FloatArray(bins)
    val sumS = FloatArray(bins); val sumV = FloatArray(bins)
    var used = 0
    for (p in pixels) {
        val hsv = rgbToHsv((p shr 16) and 0xFF, (p shr 8) and 0xFF, p and 0xFF)
        val h = hsv[0]; val s = hsv[1]; val v = hsv[2]
        /* 太黑 / 太灰的像素不参与:它们决定不了「这部片是什么颜色」。

           ☠ **明度不设上限。** 写过 `v > 0.96f` 一版,当场被单测打红:
             纯亮色(荧光绿 #00FF00)的 v 就是 1.0,那一版把整张鲜艳海报全滤空,
             取色恒回落主题色 —— 而界面上只表现为「底色一直是默认的」,不报错。
             「接近白」的判据是**饱和度低**,不是明度高,而 s 那一条已经在管了。 */
        if (v < 0.12f || s < 0.18f) continue
        val i = ((h / 360f) * bins).toInt().coerceIn(0, bins - 1)
        val weight = s * v
        val rad = h * (Math.PI.toFloat() / 180f)
        w[i] += weight
        sinH[i] += kotlin.math.sin(rad) * weight
        cosH[i] += kotlin.math.cos(rad) * weight
        sumS[i] += s * weight; sumV[i] += v * weight
        used++
    }
    // 有效像素太少 = 这是一张灰图/黑白图,取色只会取出噪点
    if (used < pixels.size / 20) return null
    var best = 0
    for (i in 1 until bins) if (w[i] > w[best]) best = i
    if (w[best] <= 0f) return null

    val h = (kotlin.math.atan2(sinH[best], cosH[best]) * (180f / Math.PI.toFloat()) + 360f) % 360f
    val s = (sumS[best] / w[best]).coerceIn(0.42f, 0.80f)
    val v = (sumV[best] / w[best]).coerceIn(0.42f, 0.68f)
    return hsvToRgb(h, s, v)
}

// ---------------------------------------------------------------- Compose 侧

/** 取过的色留一份。翻回上一页时不该再解一次图。 */
private val toneCache = LruCache<String, Color>(64)

/**
 * 这张封面的主色。取不到就回落 [fallback](调用方一般传 `Lp.colors.acc`)。
 *
 * ★ 颜色是**渐变过去的**,不是跳过去的:图先到、色后到,跳变会在详情页开场闪一下。
 */
@Composable
fun rememberTone(url: String?, fallback: Color): Color {
    val ctx = LocalContext.current
    var raw by remember(url) { mutableStateOf(url?.let { toneCache[it] }) }

    LaunchedEffect(url) {
        if (url.isNullOrEmpty() || raw != null) return@LaunchedEffect
        val got = withContext(Dispatchers.Default) {
            runCatching {
                val req = ImageRequest.Builder(ctx)
                    .data(url)
                    // ☠ 硬件位图**读不到像素**(getPixels 直接抛)。这一行漏了的话
                    //   取色恒失败,而表现只是「底色一直是默认的」,不报错
                    .allowHardware(false)
                    .size(72, 72)
                    .build()
                val img = (SingletonImageLoader.get(ctx).execute(req) as? SuccessResult)?.image
                val bmp = (img as? BitmapImage)?.bitmap ?: return@runCatching null
                val small = if (bmp.width > 72 || bmp.height > 72)
                    Bitmap.createScaledBitmap(bmp, 48, 48, true) else bmp
                val px = IntArray(small.width * small.height)
                small.getPixels(px, 0, small.width, 0, 0, small.width, small.height)
                pickTone(px)?.let { Color(0xFF000000.toInt() or it) }
            }.getOrNull()
        }
        if (got != null) { toneCache.put(url, got); raw = got }
    }

    val target = raw ?: fallback
    val animated by animateColorAsState(target, lpTween(T.T10), label = "tone")
    return animated
}
