package xyz.linplayer.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import xyz.linplayer.app.ui.theme.Dim
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp

/*
 * 「去边界」工具箱(草稿 Draft 04)。
 *
 * ☠ **边界感是要极力避免的**【用户定 2026-09-06】。这不是审美偏好,是版式契约:
 *   凡是「一块图 + 一条硬边 + 下面另一种颜色」的地方,都要换成图自己化进背景色。
 *
 * ★ 做法上有两条路,**只有一条是对的**:
 *   ① 在图上盖一层「透明 → 背景色」的渐变 —— 错。背景色是**从封面取的色**,
 *     而遮罩色是现调的,两者永远差一点;结果边界不但没消失,还从一条硬边
 *     变成一块隐约的深色矩形,更难看。
 *   ② 直接把图自己的 **alpha** 推到 0([dissolve]) —— 对。图没了之后露出来的
 *     就是页面的底,不存在「差一点」这回事。
 */

// ---------------------------------------------------------------- 溶解

/**
 * 把这一层的下沿溶掉:[from] 处开始变淡,[to] 处彻底透明(比例,0~1)。
 *
 * ☠ 必须配 `CompositingStrategy.Offscreen`。`DstIn` 是拿画笔的 alpha 去乘目标层,
 *   不离屏合成的话它乘的是**整个已经画好的窗口** —— 表现是屏幕被挖了个洞。
 */
fun Modifier.dissolve(from: Float = 0.55f, to: Float = 1f): Modifier = this
    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
    .drawWithContent {
        drawContent()
        drawRect(
            brush = Brush.verticalGradient(
                from to Color.Black, to to Color.Transparent,
                startY = 0f, endY = size.height,
            ),
            blendMode = BlendMode.DstIn,
        )
    }

/**
 * 页面底色:从封面取的色在顶上最浓,到 [depth] 处收干净回底色。
 *
 * ★ 每部片进来颜色都不一样 —— 这一条比任何动效都更让页面「活」。
 */
fun toneScene(tone: Color, bg: Color, depth: Float = 0.78f): Brush = Brush.verticalGradient(
    0.00f to tone.copy(alpha = .40f),
    0.30f * depth to tone.copy(alpha = .18f),
    0.62f * depth to tone.copy(alpha = .05f),
    depth to bg,
    1.00f to bg,
)

/**
 * 一团散在角上的辉光(草稿 06 / 07 的顶部色斑)。
 *
 * ★ **不用 `Modifier.blur`**:它要 API 31,低版本上静默不生效 —— 那正是
 *   「浅色修好了深色没修」那一类只在部分机型现形的坑。径向渐变本身就是软的。
 */
fun Modifier.glow(color: Color, alpha: Float = .34f): Modifier = this.background(
    Brush.radialGradient(
        listOf(color.copy(alpha = alpha), color.copy(alpha = alpha * .3f), Color.Transparent)
    )
)

/**
 * 让这一项**无视父容器的左右内边距**,铺满整宽。
 *
 * ★ 网格里那块「铺到屏幕边」的库头就靠它:格子要 16dp 的内边距,而库头一格都不能留 ——
 *   否则图的两侧各露一条底色,那就是又一条边界。
 */
fun Modifier.bleed(horizontal: androidx.compose.ui.unit.Dp): Modifier = this.layout { m, cs ->
    val pad = horizontal.roundToPx()
    val p = m.measure(cs.copy(minWidth = 0, maxWidth = cs.maxWidth + pad * 2))
    layout(cs.maxWidth, p.height) { p.place(-pad, 0) }
}

// ---------------------------------------------------------------- 分层替代描边

/**
 * 一块浮起来的面。**没有 border** —— 靠一层更亮的膜 + 顶沿一道内发丝线分层。
 *
 * 和 [Panel] 的分工:那个是设置页的表单分组(该有框);这个是内容页的卡。
 */
@Composable
fun Layer(
    m: Modifier = Modifier,
    strong: Boolean = false,
    corner: androidx.compose.ui.unit.Dp = R.md,
    content: @Composable () -> Unit,
) {
    val c = Lp.colors
    Box(
        m.clip(RoundedCornerShape(corner))
            .background(if (strong) c.s2 else c.s1)
            // 顶沿一道内发丝:光从上面来,这一道就是「它比底下高一点」的全部证据
            .background(
                Brush.verticalGradient(
                    0f to c.line, 0.02f to Color.Transparent, 1f to Color.Transparent
                )
            )
    ) { content() }
}

// ---------------------------------------------------------------- 版式零件

/** 章节标题:左边一条 3dp 琥珀竖条。**首页轨道标题用同一个** —— 一页的手法整站要跟上。 */
@Composable
fun SectionTitle(
    text: String,
    m: Modifier = Modifier,
    trailing: @Composable (() -> Unit)? = null,
) {
    val c = Lp.colors
    Row(
        m.fillMaxWidth().padding(start = Sp.x16, end = Sp.x8, top = Sp.x16, bottom = Sp.x10),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(3.dp, 15.dp).clip(RoundedCornerShape(R.pill)).background(
                Brush.verticalGradient(listOf(c.acc, c.acc.copy(alpha = .3f)))
            )
        )
        Spacer(Modifier.width(Sp.x8))
        Text(text, color = c.fg, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        if (trailing != null) {
            Spacer(Modifier.weight(1f))
            trailing()
        }
    }
}

/** 眉标:小字 + 字距。三级标题的第一级(草稿 03/04 的 kicker)。 */
@Composable
fun Kicker(text: String, m: Modifier = Modifier, color: Color? = null) =
    Text(
        text, m, color = color ?: Lp.colors.fg2, fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold, letterSpacing = 1.4.sp, maxLines = 1,
    )

/** 无边框 chip。**未选中是一层填充,不是一个空心框** —— 一排空心框是方寸感最重的地方。 */
@Composable
fun ToneChip(
    label: String,
    on: Boolean,
    m: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val c = Lp.colors
    Text(
        label,
        m.clip(RoundedCornerShape(R.pill))
            .background(if (on) c.acc else c.s2)
            .pressable(onClick)
            .padding(horizontal = Sp.x16, vertical = Sp.x8),
        color = if (on) c.accFg else c.fg2, fontSize = 13.sp, maxLines = 1,
        fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
    )
}

/**
 * 主按钮:整页**唯一一处渐变**。
 * ★ 卡片和背景一律不铺渐变 —— 满页渐变会立刻变廉价。
 */
@Composable
fun PrimaryAction(
    text: String,
    m: Modifier = Modifier,
    icon: ImageVector? = null,
    onClick: () -> Unit,
) {
    val c = Lp.colors
    Row(
        m.fillMaxWidth().heightIn(min = Dim.tap)
            .clip(RoundedCornerShape(R.pill))
            .background(Brush.horizontalGradient(listOf(c.acc, Color(0xFFFFC145), c.acc)))
            .pressable(onClick)
            .padding(horizontal = Sp.x20, vertical = Sp.x12),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, null, Modifier.size(17.dp), tint = c.accFg)
            Spacer(Modifier.width(Sp.x8))
        }
        Text(
            text, color = c.accFg, fontSize = 15.sp, fontWeight = FontWeight.Bold,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * 图标动作:一颗圆钮 + 一行字。
 * ★ **没有「分享」**【用户定 2026-09-06】—— 我们本来就分享不了,那颗按钮是纯装饰。
 */
@Composable
fun IconAction(
    icon: ImageVector,
    label: String,
    m: Modifier = Modifier,
    on: Boolean = false,
    onClick: () -> Unit,
) {
    val c = Lp.colors
    Column(
        m.clip(RoundedCornerShape(R.md)).pressable(onClick)
            .padding(horizontal = Sp.x12, vertical = Sp.x6),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier.size(38.dp).clip(RoundedCornerShape(R.pill))
                .background(if (on) c.accDim else c.s1),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, Modifier.size(19.dp), tint = if (on) c.acc else c.fg2) }
        Spacer(Modifier.height(Sp.x6))
        Text(label, color = if (on) c.acc else c.fg3, fontSize = 11.sp, maxLines = 1)
    }
}

/** 浮在图上的毛玻璃圆钮。**顶栏不占一行** —— 它整个飘在 Hero 上。 */
@Composable
fun GlassIcon(
    icon: ImageVector,
    desc: String,
    m: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        m.size(36.dp).clip(RoundedCornerShape(R.pill))
            .background(Color.Black.copy(alpha = .34f))
            .pressable(onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, desc, Modifier.size(18.dp), tint = Color.White) }
}

/**
 * 一行数据(评分 / 年份 / 集数 / 时长),中间发丝竖线。
 * **不是用「·」串起来的一行灰字** —— 那是上一稿最明显的塌陷点。
 */
@Composable
fun DataStrip(cells: List<Pair<String, String>>, m: Modifier = Modifier) {
    val c = Lp.colors
    if (cells.isEmpty()) return
    Row(m.padding(horizontal = Sp.x16), verticalAlignment = Alignment.CenterVertically) {
        cells.forEachIndexed { i, (value, label) ->
            if (i > 0) Box(
                Modifier.padding(horizontal = Sp.x12).size(1.dp, 22.dp).background(c.line2)
            )
            Column {
                Text(
                    value, color = if (i == 0) c.acc else c.fg,
                    fontSize = if (i == 0) 21.sp else 17.sp, fontWeight = FontWeight.Bold,
                )
                Text(label, color = c.fg3, fontSize = 10.5.sp, letterSpacing = 0.6.sp)
            }
        }
    }
}
