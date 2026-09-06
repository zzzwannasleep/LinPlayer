package xyz.linplayer.app.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsTopHeight
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import xyz.linplayer.app.ui.theme.Dim
import xyz.linplayer.app.ui.theme.LpEasing
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.LpSpring
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp
import xyz.linplayer.app.ui.theme.T

/**
 * 底栏占掉的高度。**内容从底栏下面穿过去**,所以每个列表都要按它留白。
 *
 * ★ 挂在 CompositionLocal 上而不是让每页自己判:漏一页的表现是
 *   「最后一张卡被底栏压住一半」—— 那种 bug 只有滚到底才看得见。
 */
val LocalTabClearance = compositionLocalOf { 0.dp }

/**
 * 每一页的外壳。
 *
 * ★ **topbar 随滚动实体化**:一上来不画线,滚了才出底 —— 一上来就画会把首屏切一刀。
 * ★ 安全区:内容画到底,只给列表的 contentPadding 加导航条 + 底栏高度 ——
 *   整体 `safeDrawing` 会让内容在导航条上方戛然而止。
 */
@Composable
fun LpScaffold(
    title: String? = null,
    m: Modifier = Modifier,
    subtitle: String? = null,
    onBack: (() -> Unit)? = null,
    scrolled: Boolean = false,
    actions: @Composable () -> Unit = {},
    bottomBar: @Composable () -> Unit = {},
    content: @Composable (PaddingValues) -> Unit,
) {
    val c = Lp.colors
    Box(m.fillMaxSize().background(c.bg)) {
        Column(Modifier.fillMaxSize()) {
            // ★ 没有标题**不等于没有 topbar**:首页就是「无标题但右上角有入口」。
            LpTopBar(title, subtitle, onBack, scrolled, actions)
            Box(Modifier.weight(1f)) { content(contentInsets()) }
            bottomBar()
        }
    }
}

/**
 * 沉浸外壳(草稿 01/02/03/04):**内容从 y=0 开始**,顶栏浮在图上。
 *
 * ☠ 这是「把状态栏那块黑顶飞」的做法【用户定 2026-09-06】。
 *   用 [LpScaffold] 的话状态栏是一条 `Spacer` 占位 —— 图只能从它下面开始,
 *   于是屏幕顶上永远留着一条纯色带,那就是用户说的「方寸感、边界感」。
 *   这里改成 `Box` 叠层:图铺满,顶栏连同状态栏高度一起浮在上面。
 */
@Composable
fun LpImmersive(
    m: Modifier = Modifier,
    bar: @Composable RowScope.() -> Unit = {},
    content: @Composable (PaddingValues) -> Unit,
) {
    val c = Lp.colors
    Box(m.fillMaxSize().background(c.bg)) {
        content(contentInsets())
        Column(Modifier.fillMaxWidth()) {
            Spacer(Modifier.windowInsetsTopHeight(WindowInsets.statusBars))
            Row(
                Modifier.fillMaxWidth().height(Dim.topBar).padding(horizontal = Sp.x12),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Sp.x8),
            ) { bar() }
        }
    }
}

/** 内容区该留的白:系统导航条 + 底栏。 */
@Composable
private fun contentInsets(): PaddingValues = PaddingValues(
    bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() +
        LocalTabClearance.current + Sp.x12
)

@Composable
fun LpTopBar(
    title: String?,
    subtitle: String? = null,
    onBack: (() -> Unit)? = null,
    scrolled: Boolean = false,
    actions: @Composable () -> Unit = {},
) {
    val c = Lp.colors
    val bg by animateColorAsState(
        if (scrolled) c.bg else Color.Transparent,
        androidx.compose.animation.core.tween(T.T4, easing = LpEasing.standard),
        label = "tbBg",
    )
    Column(Modifier.fillMaxWidth().background(bg)) {
        Spacer(Modifier.windowInsetsTopHeight(WindowInsets.statusBars))
        Row(
            Modifier.fillMaxWidth().height(Dim.topBar).padding(horizontal = Sp.x4),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (onBack != null) {
                LpIconButton(LpIcons.back, "返回", onClick = onBack)
            } else {
                Spacer(Modifier.width(Sp.x12))
            }
            Column(Modifier.weight(1f)) {
                if (title != null) Text(
                    title, color = c.fg, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (subtitle != null) Text(
                    subtitle, color = c.fg3, fontSize = 12.sp, maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            actions()
        }
        /* ★ 实体化时**不画发丝线**,改成从底色渐隐下来一小段。
           一条线是把页面切两半;一段渐隐是让内容化进栏里 —— 同一件事,后者没有边界。 */
        if (scrolled) Box(
            Modifier.fillMaxWidth().height(Sp.x12)
                .background(Brush.verticalGradient(listOf(c.bg, Color.Transparent)))
        )
    }
}

/** 滚了没有。**只看「有没有滚出第一项的顶」**,不看具体偏移 —— 每帧读偏移会每帧重组。 */
@Composable
fun rememberScrolled(state: LazyListState): Boolean {
    val v by remember(state) {
        derivedStateOf { state.firstVisibleItemIndex > 0 || state.firstVisibleItemScrollOffset > 4 }
    }
    return v
}

@Composable
fun rememberScrolled(state: androidx.compose.foundation.lazy.grid.LazyGridState): Boolean {
    val v by remember(state) {
        derivedStateOf { state.firstVisibleItemIndex > 0 || state.firstVisibleItemScrollOffset > 4 }
    }
    return v
}

/**
 * 底栏三个 Tab。**只有三个**【用户定】—— 不加第四个。
 *
 * ★ **没有那条上边线**(草稿 01 第 4 条):改成从底色渐隐上来。
 *   轨道从它下面穿过去,滚动时是渐渐化掉,而不是被一条线切断。
 */
@Composable
fun LpTabBar(current: Int, onPick: (Int) -> Unit) {
    val c = Lp.colors
    Column(
        Modifier.fillMaxWidth().background(
            Brush.verticalGradient(
                0f to Color.Transparent, 0.42f to c.bg.copy(alpha = .92f), 1f to c.bg
            )
        )
    ) {
        Spacer(Modifier.height(Sp.x12))
        Row(
            Modifier.fillMaxWidth().height(Dim.tabBar),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Tab("首页", if (current == 0) LpIcons.homeOn else LpIcons.home, current == 0,
                Modifier.weight(1f)) { onPick(0) }
            Tab("聚合视界", LpIcons.globe, current == 1, Modifier.weight(1f)) { onPick(1) }
            Tab("服务器", LpIcons.server, current == 2, Modifier.weight(1f)) { onPick(2) }
        }
        Spacer(Modifier.height(
            WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
        ))
    }
}

/**
 * 一个 Tab。选中态是**一颗琥珀药丸从图标底下长出来** + 图标弹一下。
 * ★ 弹簧用 bouncy:全站只有两处配得上它,Tab 切换是其中一处 —— 它是手指刚碰过的地方。
 */
@Composable
private fun Tab(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    on: Boolean,
    m: Modifier,
    onClick: () -> Unit,
) {
    val c = Lp.colors
    val z by animateFloatAsState(if (on) 1f else 0f, LpSpring.bouncy(), label = "tabOn")
    Column(
        m.fillMaxSize().pressable(onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(contentAlignment = Alignment.Center) {
            // 药丸底:宽度跟着 z 长出来,不是显隐切换
            Box(
                Modifier.graphicsLayer { scaleX = z; alpha = z }
                    .size(44.dp, 26.dp).clip(RoundedCornerShape(R.pill)).background(c.accDim)
            )
            Icon(
                icon, label,
                Modifier.size(21.dp).graphicsLayer { val s = 1f + z * .08f; scaleX = s; scaleY = s },
                tint = if (on) c.acc else c.fg3,
            )
        }
        Spacer(Modifier.height(3.dp))
        Text(
            label, color = if (on) c.acc else c.fg3, fontSize = 10.5.sp,
            fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
        )
    }
}

/** 让页面能拿到底栏高度做自己的留白(网格 / 自绘列表)。 */
@Composable
fun tabClearance(): Dp = LocalTabClearance.current
