package xyz.linplayer.app.ui.theme

import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 设计 token(UI_MOBILE.md §1)。**刻度是枚举不是区间** ——
 * 要用第五种圆角,先改 UI_MOBILE.md §1.3 那张表,别就地写新值。
 */
@Immutable
data class LpColors(
    val bg: Color, val s1: Color, val s2: Color, val s3: Color,
    val line: Color, val line2: Color,
    val fg: Color, val fg2: Color, val fg3: Color,
    val acc: Color, val accDim: Color, val accFg: Color,
    val ok: Color, val warn: Color, val bad: Color,
    val scrim: Color,
    /** 叠在画面上的玻璃底。**写死色号必须带 alpha** —— 不透明的一律进上面那些 token */
    val chip: Color,
    val isDark: Boolean,
)

private val Dark = LpColors(
    bg = Color(0xFF0E0E13), s1 = Color(0xFF17171E), s2 = Color(0xFF1E1E27), s3 = Color(0xFF262630),
    line = Color(0xFF26262F), line2 = Color(0xFF383843),
    fg = Color(0xFFF4F4F8), fg2 = Color(0xFFA3A3B4), fg3 = Color(0xFF6B6B7C),
    acc = Color(0xFF5B8CFF), accDim = Color(0x295B8CFF), accFg = Color(0xFFFFFFFF),
    ok = Color(0xFF37C26A), warn = Color(0xFFE0A95B), bad = Color(0xFFFF5F56),
    scrim = Color(0xB30E0E13), chip = Color(0x8C17171E), isDark = true,
)

// 浅色不是纯白:墨色带暖偏、底色是米黄护眼纸(语义与 UI_PC.md §1.1 对齐)
private val Light = LpColors(
    bg = Color(0xFFF1ECE2), s1 = Color(0xFFFBF8F1), s2 = Color(0xFFF5F0E6), s3 = Color(0xFFEAE2D2),
    line = Color(0xFFE4DCCC), line2 = Color(0xFFD6CCB6),
    fg = Color(0xFF2A2622), fg2 = Color(0xFF6E6559), fg3 = Color(0xFF9C9284),
    acc = Color(0xFF3F73D6), accDim = Color(0x213F73D6), accFg = Color(0xFFFFFFFF),
    ok = Color(0xFF3E9E6E), warn = Color(0xFFC98A2E), bad = Color(0xFFC7554E),
    scrim = Color(0xB3F1ECE2), chip = Color(0xBDFFFFFF), isDark = false,
)

/** 间距刻度。**允许的值只有这些** */
object Sp {
    val x0 = 0.dp; val x2 = 2.dp; val x4 = 4.dp; val x6 = 6.dp; val x8 = 8.dp
    val x10 = 10.dp; val x12 = 12.dp; val x16 = 16.dp; val x20 = 20.dp
    val x26 = 26.dp; val x34 = 34.dp; val x48 = 48.dp
}

/** 圆角刻度。8=小件 · 12=卡片 · 18=弹窗面板 · 999=胶囊 */
object R {
    val none = 0.dp; val sm = 8.dp; val md = 12.dp; val lg = 18.dp; val pill = 999.dp
}

/** 固定尺寸。超过 48 的偏移不许写字面数字,抽成这里的具名常量 */
object Dim {
    val topBar = 52.dp
    val tabBar = 58.dp
    val tap = 48.dp
    val hairline = 1.dp
    val posterRow = 214.dp   // 海报轨总高(卡 2:3 + 两行字)。★ LazyRow 嵌在 LazyColumn 里必须给定高
    val thumbRow = 148.dp
}

val LocalLpColors = staticCompositionLocalOf { Dark }

/**
 * 动效倍率。跟随系统的「移除动画」设置(UI_MOBILE.md §2.4)。
 * 每个动画都要乘它 —— 散着判会漏,所以挂在 CompositionLocal 上。
 */
val LocalMotionScale: ProvidableCompositionLocal<Float> = compositionLocalOf { 1f }

private val LpTypography = Typography(
    displayLarge = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold),
    titleLarge = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.Bold),
    titleMedium = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold),
    bodyLarge = TextStyle(fontSize = 14.sp, lineHeight = 21.sp),
    bodyMedium = TextStyle(fontSize = 13.sp),
    labelLarge = TextStyle(fontSize = 12.sp),
    labelSmall = TextStyle(fontSize = 11.sp),
)

/**
 * 主题三态:跟随系统 / 强制深色 / 强制浅色。
 *
 * ★ **不用 Material You 动态取色。** 它会把整个界面染成用户壁纸的颜色,
 * 而本产品的底色是「影院沉浸」的一部分。这是主动放弃 M3 的默认能力(UI_MOBILE.md §1.1)。
 */
@Composable
fun LpTheme(
    darkOverride: Boolean? = null,
    content: @Composable () -> Unit,
) {
    val dark = darkOverride ?: isSystemInDarkTheme()
    val c = if (dark) Dark else Light
    val ctx = LocalContext.current
    val motion = remember(ctx) { animatorScale(ctx) }

    // M3 的 ColorScheme 仍然要给:M3 组件(Slider / Switch / Chip)读的是它。
    // 我们自己的组件读 LocalLpColors,两套值必须一致,否则同一屏上会出现两种蓝
    val scheme = if (dark) darkColorScheme(
        primary = c.acc, onPrimary = c.accFg, background = c.bg, onBackground = c.fg,
        surface = c.s1, onSurface = c.fg, surfaceVariant = c.s2, onSurfaceVariant = c.fg2,
        outline = c.line2, error = c.bad,
    ) else lightColorScheme(
        primary = c.acc, onPrimary = c.accFg, background = c.bg, onBackground = c.fg,
        surface = c.s1, onSurface = c.fg, surfaceVariant = c.s2, onSurfaceVariant = c.fg2,
        outline = c.line2, error = c.bad,
    )

    CompositionLocalProvider(LocalLpColors provides c, LocalMotionScale provides motion) {
        MaterialTheme(colorScheme = scheme, typography = LpTypography, content = content)
    }
}

/** 系统的动画时长倍率。开发者选项里关掉动画时是 0f。 */
private fun animatorScale(ctx: android.content.Context): Float = runCatching {
    Settings.Global.getFloat(ctx.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
}.getOrDefault(1f)

/** 本项目自己的 token 入口。写 `Lp.colors.acc` 而不是 `MaterialTheme.colorScheme.primary`。 */
object Lp {
    val colors: LpColors
        @Composable get() = LocalLpColors.current
}

@Suppress("unused")
internal val sdkAtLeast31 = Build.VERSION.SDK_INT >= 31
