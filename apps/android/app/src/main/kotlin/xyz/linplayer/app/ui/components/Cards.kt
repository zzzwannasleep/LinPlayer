package xyz.linplayer.app.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImagePainter
import coil3.compose.rememberAsyncImagePainter
import xyz.linplayer.app.data.Item
import xyz.linplayer.app.ui.theme.Dim
import xyz.linplayer.app.ui.theme.LpEasing
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp
import xyz.linplayer.app.ui.theme.T

/**
 * 网络图。
 *
 * ☠ **必须看 `painter.state`。** 只画 `AsyncImage` 不看 state 的话,骨架要么永不消失
 * 要么永不出现 —— 那正是历史故障「封面隐身」在 Compose 上的等价漏法
 * (旧栈是手抄卡片时漏了「解码完成 → 加就绪标记」这一步)。
 */
@Composable
fun NetImage(
    url: String?,
    desc: String?,
    m: Modifier = Modifier,
    corner: androidx.compose.ui.unit.Dp = R.md,
    scale: ContentScale = ContentScale.Crop,
) {
    Box(m.clip(RoundedCornerShape(corner))) {
        if (url.isNullOrEmpty()) {
            // 没有地址就画一块占位底。**不画骨架** —— 骨架的意思是「在路上」,
            // 而这里是「压根没有」,两者在界面上必须能分开
            Box(Modifier.fillMaxSize().background(Lp.colors.s3))
            if (xyz.linplayer.app.BuildConfig.DEBUG) {
                android.util.Log.w("LinPlayer", "图片地址为空(数据通道没就绪?)desc=$desc")
            }
            return@Box
        }
        val painter = rememberAsyncImagePainter(url)
        val state by painter.state.collectAsState()
        val ready = state is AsyncImagePainter.State.Success
        val alpha by animateFloatAsState(
            if (ready) 1f else 0f,
            androidx.compose.animation.core.tween(T.T5, easing = LpEasing.standard),
            label = "imgIn",
        )
        if (!ready) Skeleton(Modifier.fillMaxSize(), corner)
        if (xyz.linplayer.app.BuildConfig.DEBUG) {
            val st = state
            if (st is AsyncImagePainter.State.Error) android.util.Log.w(
                "LinPlayer", "图片加载失败 $url", st.result.throwable)
        }
        androidx.compose.foundation.Image(
            painter = painter, contentDescription = desc, contentScale = scale,
            modifier = Modifier.fillMaxSize().graphicsLayer { this.alpha = alpha },
        )
    }
}

/**
 * 海报卡 / 横版卡(UI_MOBILE.md §4.3)。
 *
 * 一张卡最多同时表达五件事:封面 / 角标 / 观看进度 / 标题 / 副标题。
 * ★ **画质标签(4K/DV)整个去掉**【用户定 2026-07-28】——「没人会为了参数去看一部烂片」。
 */
@Composable
fun MediaCard(
    item: Item,
    imageUrl: String?,
    onOpen: () -> Unit,
    m: Modifier = Modifier,
    thumb: Boolean = false,
    /** 长按菜单项。**null = 这一处不给长按菜单**(跨服结果就是这样,理由见 §7.5)。 */
    menu: List<CardAction>? = null,
    showCaption: Boolean = true,
) {
    val c = Lp.colors
    val haptic = LocalHapticFeedback.current
    var menuOpen by remember { mutableStateOf(false) }
    val width = if (thumb) 186.dp else 104.dp

    // 整卡读成一条:TalkBack 逐个念「图片」「标题」「年份」是噪音
    Column(m.width(width).semantics(mergeDescendants = true) { }) {
        Box {
            Box(
                Modifier.fillMaxWidth().aspectRatio(if (thumb) 16f / 9f else 2f / 3f)
                    .combinedClickable(
                        onClick = onOpen,
                        onLongClick = if (menu != null) {
                            { haptic.performHapticFeedback(HapticFeedbackType.LongPress); menuOpen = true }
                        } else null,
                    )
            ) {
                NetImage(imageUrl, item.name, Modifier.fillMaxSize())

                // 角标:剧集 → 未看集数,全看完 → 打勾;电影 → 评分。**角标要小**,它压在封面上
                Badge(item, Modifier.align(Alignment.TopEnd).padding(Sp.x6))

                // 播放进度:仅在有进度时出现
                if (item.progress > 0f) Box(
                    Modifier.align(Alignment.BottomStart).fillMaxWidth().height(2.dp)
                        .background(c.line2)
                ) {
                    Box(Modifier.fillMaxWidth(item.progress).fillMaxSize().background(c.acc))
                }
            }
            if (menu != null) CardMenu(menuOpen, { menuOpen = false }, menu)
        }
        if (showCaption) {
            Spacer(Modifier.height(Sp.x6))
            // 一行 + 省略号:片名长短差别极大,不收会把行高撑成两三行,整条轨道高度乱跳
            Text(item.cardTitle, color = c.fg, fontSize = 13.sp, maxLines = 1,
                overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium)
            item.cardSub?.let {
                Text(it, color = c.fg3, fontSize = 11.sp, maxLines = 1,
                    modifier = Modifier.padding(top = 1.dp))
            }
        }
    }
}

@Composable
private fun Badge(item: Item, m: Modifier) {
    val c = Lp.colors
    when {
        item.isSeries && item.unplayed > 0 -> Box(
            m.clip(RoundedCornerShape(R.pill)).background(Color(0xFF2C7BE5)).padding(horizontal = 6.dp, vertical = 1.dp),
        ) { Text(item.unplayed.toString(), color = Color.White, fontSize = 10.sp) }

        item.played -> Box(
            m.size(18.dp).clip(RoundedCornerShape(R.pill)).background(c.ok),
            contentAlignment = Alignment.Center,
        ) { Icon(LpIcons.check, "已看完", Modifier.size(11.dp), tint = Color(0xFF062418)) }

        !item.isSeries && item.rating != null -> Box(
            m.clip(RoundedCornerShape(R.pill)).background(c.chip).padding(horizontal = 6.dp, vertical = 1.dp),
        ) { Text(String.format("%.1f", item.rating), color = c.fg, fontSize = 10.sp) }
    }
}

/** 长按菜单一项。**这份定义是全站唯一的** —— 各页自己拼一套会长出不一致。 */
data class CardAction(val label: String, val danger: Boolean = false, val onClick: () -> Unit)

@Composable
private fun CardMenu(open: Boolean, onDismiss: () -> Unit, actions: List<CardAction>) {
    val c = Lp.colors
    DropdownMenu(expanded = open, onDismissRequest = onDismiss,
        modifier = Modifier.background(c.s3)) {
        actions.forEach { a ->
            DropdownMenuItem(
                text = { Text(a.label, color = if (a.danger) c.bad else c.fg, fontSize = 14.sp) },
                onClick = { onDismiss(); a.onClick() },
            )
        }
    }
}

/**
 * 横滑轨道。
 *
 * ☠ **高度必须是常量。** `LazyRow` 嵌在 `LazyColumn` 里而不给固定高度,
 * 会在每次测量时重新布局整列 —— 那是「首页滑不动」在 Compose 上的等价形态。
 */
@Composable
fun LpRow(
    title: String,
    items: List<Item>,
    imageUrl: (Item) -> String?,
    onOpen: (Item) -> Unit,
    m: Modifier = Modifier,
    thumb: Boolean = false,
    menu: ((Item) -> List<CardAction>)? = null,
    onMore: (() -> Unit)? = null,
) {
    Column(m.fillMaxWidth()) {
        RowHeader(title, onMore)
        LazyRow(
            Modifier.fillMaxWidth().height(if (thumb) Dim.thumbRow else Dim.posterRow),
            contentPadding = PaddingValues(horizontal = Sp.x16),
            horizontalArrangement = Arrangement.spacedBy(Sp.x10),
        ) {
            // key + contentType:不给的话滚动时 item 复用会让 Coil 重复发请求
            items(items, key = { it.id }, contentType = { if (thumb) "thumb" else "poster" }) {
                MediaCard(it, imageUrl(it), { onOpen(it) }, thumb = thumb, menu = menu?.invoke(it))
            }
        }
    }
}

/** 骨架轨道:4 张空卡。**形状和真卡一致**。 */
@Composable
fun LpRowSkeleton(title: String? = null, thumb: Boolean = false, m: Modifier = Modifier) {
    Column(m.fillMaxWidth()) {
        if (title != null) RowHeader(title, null) else Box(Modifier.padding(Sp.x16)) {
            SkeletonLine(104.dp)
        }
        Row(
            Modifier.fillMaxWidth().height(if (thumb) Dim.thumbRow else Dim.posterRow)
                .padding(horizontal = Sp.x16),
            horizontalArrangement = Arrangement.spacedBy(Sp.x10),
        ) {
            repeat(4) {
                Column(Modifier.width(if (thumb) 186.dp else 104.dp)) {
                    Skeleton(Modifier.fillMaxWidth().aspectRatio(if (thumb) 16f / 9f else 2f / 3f))
                    Spacer(Modifier.height(Sp.x8))
                    SkeletonLine(78.dp)
                }
            }
        }
    }
}

/** 轨道标题。**和详情页的章节标题同一个手法**(左边一条琥珀竖条)—— 一页的手法整站要跟上。 */
@Composable
private fun RowHeader(title: String, onMore: (() -> Unit)?) {
    SectionTitle(title, trailing = if (onMore == null) null else ({
        Row(
            Modifier.pressable(onMore).padding(horizontal = Sp.x8, vertical = Sp.x6),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Dim3("更多")
            Icon(LpIcons.chevR, null, Modifier.size(15.dp), tint = Lp.colors.fg3)
        }
    }))
}
