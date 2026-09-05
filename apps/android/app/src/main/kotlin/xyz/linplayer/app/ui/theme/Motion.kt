package xyz.linplayer.app.ui.theme

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember

/** M3 duration token(UI_MOBILE.md §2.1)。**只有这十档**,不许现场发明 90ms。 */
object T {
    const val T1 = 50; const val T2 = 100; const val T3 = 150; const val T4 = 200
    const val T5 = 250; const val T6 = 300; const val T7 = 350; const val T8 = 400
    const val T9 = 450; const val T10 = 500
}

object LpEasing {
    val standard = CubicBezierEasing(0.2f, 0f, 0f, 1f)
    val standardDecelerate = CubicBezierEasing(0f, 0f, 0f, 1f)
    val standardAccelerate = CubicBezierEasing(0.3f, 0f, 1f, 1f)
    val emphasizedDecelerate = CubicBezierEasing(0.05f, 0.7f, 0.1f, 1f)
    val emphasizedAccelerate = CubicBezierEasing(0.3f, 0f, 0.8f, 0.15f)

    /**
     * M3 的 emphasized。
     *
     * ★ **它不是一段 cubic-bezier。** 官方给的是两段贝塞尔路径
     * (`M 0,0 C .05,0 .133,.06 .167,.4 C .208,.82 .25,1 1,1`),Web 侧只能用
     * `linear()` 近似,而 Compose 的 Easing 是个函数接口 —— **可以把两段原样写进去**。
     *
     * 写成 `CubicBezierEasing(0.2f, 0f, 0f, 1f)` 的话你拿到的是 **standard**,
     * 那是最平淡的一条。这是「动效没质感」的根因之一。
     *
     * 前 16.7% 是「起步的迟疑」(慢慢走到 40%),之后猛冲、长收。
     */
    val emphasized = Easing { t ->
        if (t < 0.166666f) {
            // 第一段:控制点 (.05,0) (.1333,.06),终点 (.166666,.4)
            cubic(t / 0.166666f, 0.05f / 0.166666f, 0f, 0.133333f / 0.166666f, 0.06f / 0.4f) * 0.4f
        } else {
            // 第二段:起点 (.166666,.4),控制点 (.208333,.82) (.25,1),终点 (1,1)
            val u = (t - 0.166666f) / 0.833334f
            0.4f + cubic(
                u,
                (0.208333f - 0.166666f) / 0.833334f, (0.82f - 0.4f) / 0.6f,
                (0.25f - 0.166666f) / 0.833334f, (1f - 0.4f) / 0.6f,
            ) * 0.6f
        }
    }

    /**
     * 三次贝塞尔求值:给横坐标 x,解出纵坐标 y。
     * 牛顿法解 t 太啰嗦,这里用二分 —— 16 次迭代把误差压到 1e-5 以下,
     * 而它每帧只跑一次,不是热路径。
     */
    private fun cubic(x: Float, x1: Float, y1: Float, x2: Float, y2: Float): Float {
        if (x <= 0f) return 0f
        if (x >= 1f) return 1f
        var lo = 0f; var hi = 1f; var t = x
        repeat(16) {
            val cx = bez(t, x1, x2)
            if (cx < x) lo = t else hi = t
            t = (lo + hi) / 2f
        }
        return bez(t, y1, y2)
    }

    private fun bez(t: Float, a: Float, b: Float): Float {
        val mt = 1f - t
        return 3f * mt * mt * t * a + 3f * mt * t * t * b + t * t * t
    }
}

/** 弹簧三档(UI_MOBILE.md §2.1)。**bouncy 只给「要抢注意力」的两处,到处用会显得廉价。** */
object LpSpring {
    fun <T> snap(): FiniteAnimationSpec<T> =
        spring(dampingRatio = 0.9f, stiffness = Spring.StiffnessMedium)
    fun <T> main(): FiniteAnimationSpec<T> =
        spring(dampingRatio = 0.8f, stiffness = Spring.StiffnessMediumLow)
    fun <T> bouncy(): FiniteAnimationSpec<T> =
        spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMedium)
}

/**
 * 带系统「移除动画」倍率的 tween。**所有 tween 都要走它** ——
 * 散着写 `tween(250)` 的地方就是关不掉动画的地方。
 */
@Composable
fun <T> lpTween(durationMs: Int, easing: Easing = LpEasing.standard): FiniteAnimationSpec<T> {
    val scale = LocalMotionScale.current
    return remember(durationMs, easing, scale) {
        tween(durationMillis = (durationMs * scale).toInt().coerceAtLeast(0), easing = easing)
    }
}
