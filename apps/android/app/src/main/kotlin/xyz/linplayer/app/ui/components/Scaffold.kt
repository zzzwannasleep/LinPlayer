package xyz.linplayer.app.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
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
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import xyz.linplayer.app.ui.theme.Dim
import xyz.linplayer.app.ui.theme.LpEasing
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.Sp
import xyz.linplayer.app.ui.theme.T

/**
 * 每一页的外壳(UI_MOBILE.md §3.1)。
 *
 * ★ **topbar 随滚动实体化**:一上来不画线,滚了才出底和线 ——
 *   一上来就画会把首屏切一刀。
 * ★ 安全区:内容画到底,只给列表的 contentPadding 加导航条高度 ——
 *   整体 `safeDrawing` 会让内容在导航条上方戛然而止(§3.2)。
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
            // ★ 没有标题**不等于没有 topbar**:首页就是「无标题但右上角有两个入口」。
            //   原来这里用 `title != null` 判要不要画整条栏,结果首页的搜索与设置
            //   两个入口一个都没画出来 —— 而且不报错,只是「点不到」。
            LpTopBar(title, subtitle, onBack, scrolled, actions)
            Box(Modifier.weight(1f)) {
                content(PaddingValues(bottom = WindowInsets.navigationBars.asPaddingValues()
                    .calculateBottomPadding() + Sp.x12))
            }
            bottomBar()
        }
    }
}

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
        // 实体化时才画那条发丝线
        if (scrolled) Hairline()
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

/** 底栏三个 Tab。**只有三个**【用户定】—— 不加第四个。 */
@Composable
fun LpTabBar(current: Int, onPick: (Int) -> Unit) {
    val c = Lp.colors
    Column(Modifier.fillMaxWidth().background(c.bg)) {
        Hairline()
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

@Composable
private fun Tab(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    on: Boolean,
    m: Modifier,
    onClick: () -> Unit,
) {
    val c = Lp.colors
    Column(
        m.fillMaxSize().pressable(onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
    ) {
        Icon(icon, label, Modifier.size(22.dp), tint = if (on) c.acc else c.fg3)
        Spacer(Modifier.height(2.dp))
        Text(label, color = if (on) c.acc else c.fg3, fontSize = 11.sp)
    }
}
