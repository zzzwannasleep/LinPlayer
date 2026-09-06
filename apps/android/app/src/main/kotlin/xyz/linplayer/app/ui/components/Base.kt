package xyz.linplayer.app.ui.components

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.BasicAlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import xyz.linplayer.app.ui.theme.Dim
import xyz.linplayer.app.ui.theme.LpEasing
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp
import xyz.linplayer.app.ui.theme.T

/*
 * 共用组件词汇(UI_MOBILE.md §4.2)。**页面只能用它拼,不许各页自造一套**
 * —— 散着写必然长出两套间距,这条在 PC 端和 TV 端都栽过。
 */

// ---------------------------------------------------------------- 按下反馈

/**
 * 按下 `scale .97`(UI_MOBILE.md §2.2)。
 *
 * ★ 用 `graphicsLayer` 的 lambda 版:它只在 draw 阶段读值,不触发重组(§2.3 第 3 条)。
 */
@Composable
fun Modifier.pressable(onClick: () -> Unit, enabled: Boolean = true): Modifier {
    val src = remember { MutableInteractionSource() }
    val pressed by src.collectIsPressedAsState()
    return this
        .graphicsLayer {
            val s = if (pressed) 0.97f else 1f
            scaleX = s; scaleY = s
        }
        .clickable(interactionSource = src, indication = null, enabled = enabled, onClick = onClick)
}

// ---------------------------------------------------------------- 文字

@Composable fun H1(t: String, m: Modifier = Modifier) =
    Text(t, m, color = Lp.colors.fg, fontSize = 20.sp, fontWeight = FontWeight.Bold)

@Composable fun H2(t: String, m: Modifier = Modifier) =
    Text(t, m, color = Lp.colors.fg, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)

@Composable fun Body(t: String, m: Modifier = Modifier, maxLines: Int = Int.MAX_VALUE) =
    Text(t, m, color = Lp.colors.fg, fontSize = 14.sp, lineHeight = 21.sp,
        maxLines = maxLines, overflow = TextOverflow.Ellipsis)

@Composable fun Dim2(t: String, m: Modifier = Modifier, maxLines: Int = Int.MAX_VALUE) =
    Text(t, m, color = Lp.colors.fg2, fontSize = 13.sp, lineHeight = 19.sp,
        maxLines = maxLines, overflow = TextOverflow.Ellipsis)

@Composable fun Dim3(t: String, m: Modifier = Modifier, maxLines: Int = 1) =
    Text(t, m, color = Lp.colors.fg3, fontSize = 12.sp,
        maxLines = maxLines, overflow = TextOverflow.Ellipsis)

// ---------------------------------------------------------------- 图标按钮

/** 图标按钮。**命中区恒 ≥48dp**,视觉大小由 `size` 定(UI_MOBILE.md §1.5)。 */
@Composable
fun LpIconButton(
    icon: ImageVector,
    desc: String?,
    m: Modifier = Modifier,
    size: Int = 22,
    tint: Color? = null,
    onClick: () -> Unit,
) {
    Box(
        m.sizeIn(minWidth = Dim.tap, minHeight = Dim.tap)
            .clip(RoundedCornerShape(R.pill))
            .pressable(onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, desc, Modifier.size(size.dp), tint = tint ?: Lp.colors.fg)
    }
}

// ---------------------------------------------------------------- 按钮

enum class BtnKind { Primary, Secondary, Danger, Ghost }

@Composable
fun LpButton(
    text: String,
    onClick: () -> Unit,
    m: Modifier = Modifier,
    kind: BtnKind = BtnKind.Primary,
    enabled: Boolean = true,
    /** 加载中:**保持原尺寸**(尺寸跳变比转圈更烦人)。 */
    loading: Boolean = false,
) {
    val c = Lp.colors
    val bg = when (kind) {
        BtnKind.Primary -> c.acc
        BtnKind.Secondary -> c.s2
        BtnKind.Danger -> c.bad
        BtnKind.Ghost -> Color.Transparent
    }
    val fg = when (kind) {
        BtnKind.Primary, BtnKind.Danger -> c.accFg
        else -> c.fg
    }
    val on = enabled && !loading
    Box(
        m.heightIn(min = Dim.tap)
            .clip(RoundedCornerShape(R.sm))
            .background(bg)
            .then(if (kind == BtnKind.Secondary) Modifier.border(Dim.hairline, c.line, RoundedCornerShape(R.sm)) else Modifier)
            .graphicsLayer { alpha = if (on) 1f else 0.45f }
            .pressable(onClick, on)
            .padding(horizontal = Sp.x20, vertical = Sp.x12),
        contentAlignment = Alignment.Center,
    ) {
        Text(if (loading) "…" else text, color = fg, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

// ---------------------------------------------------------------- 输入框

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LpField(
    value: String,
    onChange: (String) -> Unit,
    placeholder: String,
    m: Modifier = Modifier,
    password: Boolean = false,
    error: String? = null,
    label: String? = null,
) {
    val c = Lp.colors
    Column(m) {
        if (label != null) Dim3(label, Modifier.padding(bottom = Sp.x6))
        OutlinedTextField(
            value = value,
            onValueChange = onChange,
            placeholder = { Dim3(placeholder) },
            singleLine = true,
            isError = error != null,
            shape = RoundedCornerShape(R.sm),
            visualTransformation = if (password)
                androidx.compose.ui.text.input.PasswordVisualTransformation() else
                androidx.compose.ui.text.input.VisualTransformation.None,
            colors = TextFieldDefaults.colors(
                focusedContainerColor = c.s1, unfocusedContainerColor = c.s1,
                errorContainerColor = c.s1,
                focusedTextColor = c.fg, unfocusedTextColor = c.fg,
                focusedIndicatorColor = c.acc, unfocusedIndicatorColor = c.line,
                cursorColor = c.acc,
            ),
            modifier = Modifier.fillMaxWidth(),
        )
        // ★ 错误挂在字段下面,不弹 toast:行内错误才指得出是哪一项(§6.3 的 E_INVALID)
        if (error != null) Text(error, color = c.bad, fontSize = 11.sp, modifier = Modifier.padding(top = Sp.x4))
    }
}

// ---------------------------------------------------------------- 单元格

/**
 * 设置 / 列表里的一行。
 *
 * ☠☠ **`onClick` 必须是最后一个参数,别再挪。**
 *   它原来排在 `onSwitch` 前面,于是所有这样写的调用点:
 *
 *       LpCell("外观", icon = LpIcons.image) { nav.navigate(...) }
 *
 *   尾随 lambda 按 Kotlin 的规矩绑到**最后一个参数**,也就是 `onSwitch` ——
 *   而一个不声明参数的 lambda 完全可以当成 `(Boolean) -> Unit`(隐式 `it`),
 *   **所以它编译得过**。结果是 `onClick` 恒 null → 这一行根本没挂 `pressable`,
 *   而 `switch` 是 null 又不画开关,`onSwitch` 永远没人调 ——
 *   整张设置列表**一条都点不进去,一个警告都没有**。用户 2026-09-06 报的就是它。
 */
@Composable
fun LpCell(
    label: String,
    m: Modifier = Modifier,
    icon: ImageVector? = null,
    sub: String? = null,
    value: String? = null,
    switch: Boolean? = null,
    arrow: Boolean = switch == null,
    onSwitch: ((Boolean) -> Unit)? = null,
    onClick: (() -> Unit)? = null,
) {
    val c = Lp.colors
    Row(
        m.fillMaxWidth()
            .heightIn(min = Dim.tap + Sp.x8)
            .then(if (onClick != null) Modifier.pressable(onClick) else Modifier)
            .padding(horizontal = Sp.x16, vertical = Sp.x10),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, null, Modifier.size(21.dp), tint = c.fg2)
            Spacer(Modifier.width(Sp.x12))
        }
        Column(Modifier.weight(1f)) {
            Body(label, maxLines = 2)
            if (sub != null) Dim3(sub, Modifier.padding(top = Sp.x2), maxLines = 2)
        }
        if (value != null) Dim3(value, Modifier.padding(start = Sp.x8))
        when {
            switch != null -> Switch(
                checked = switch, onCheckedChange = onSwitch,
                colors = SwitchDefaults.colors(checkedTrackColor = c.acc, checkedThumbColor = c.accFg),
                modifier = Modifier.padding(start = Sp.x8),
            )
            arrow -> Icon(LpIcons.chevR, null, Modifier.padding(start = Sp.x6).size(18.dp), tint = c.fg3)
        }
    }
}

// ---------------------------------------------------------------- 就地调节三件套

/** 分段控件:2~4 个互斥选项,**就地生效不开弹窗**。 */
@Composable
fun SegRow(
    label: String,
    options: List<String>,
    current: String,
    onPick: (String) -> Unit,
    m: Modifier = Modifier,
    sub: String? = null,
    icon: ImageVector? = null,
) {
    val c = Lp.colors
    Column(m.fillMaxWidth().padding(horizontal = Sp.x16, vertical = Sp.x10)) {
        RowHead(label, sub, icon)
        Spacer(Modifier.height(Sp.x8))
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(R.sm)).background(c.s2).padding(Sp.x2),
            horizontalArrangement = Arrangement.spacedBy(Sp.x2),
        ) {
            options.forEach { o ->
                val on = o == current
                Box(
                    Modifier.weight(1f).heightIn(min = 36.dp)
                        .clip(RoundedCornerShape(R.sm - 2.dp))
                        .background(if (on) c.acc else Color.Transparent)
                        .pressable({ if (!on) onPick(o) })
                        .padding(vertical = Sp.x8),
                    contentAlignment = Alignment.Center,
                ) { Text(o, color = if (on) c.accFg else c.fg2, fontSize = 13.sp, maxLines = 1) }
            }
        }
    }
}

/** 步进器:有明确步长的数值。**到头把按钮禁掉** —— 不禁的话用户会一直点还以为没反应。 */
@Composable
fun StepperRow(
    label: String,
    value: Double,
    min: Double,
    max: Double,
    step: Double,
    onChange: (Double) -> Unit,
    m: Modifier = Modifier,
    sub: String? = null,
    fmt: (Double) -> String = { it.toString() },
) {
    val c = Lp.colors
    Row(
        m.fillMaxWidth().padding(horizontal = Sp.x16, vertical = Sp.x10),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) { RowHead(label, sub, null) }
        Row(
            Modifier.clip(RoundedCornerShape(R.pill)).background(c.s2),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            LpIconButton(LpIcons.minus, "减少", size = 18,
                tint = if (value <= min) c.fg3 else c.fg, onClick = {
                    // 浮点步长(0.25)直接加会攒出 1.7500000000000002,固定小数位收掉
                    onChange(kotlin.math.round((value - step).coerceIn(min, max) * 10000) / 10000)
                })
            Text(fmt(value), color = c.fg, fontSize = 14.sp, modifier = Modifier.width(56.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            LpIconButton(LpIcons.plus, "增加", size = 18,
                tint = if (value >= max) c.fg3 else c.fg, onClick = {
                    onChange(kotlin.math.round((value + step).coerceIn(min, max) * 10000) / 10000)
                })
        }
    }
}

/** 滑块:连续值。跟手期间只更新本地 float,松手才发命令(§2.3 第 3 条)。 */
@Composable
fun SliderRow(
    label: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    onCommit: (Float) -> Unit,
    m: Modifier = Modifier,
    sub: String? = null,
    fmt: (Float) -> String = { it.toInt().toString() },
) {
    val c = Lp.colors
    var live by remember(value) { mutableFloatStateOf(value) }
    Column(m.fillMaxWidth().padding(horizontal = Sp.x16, vertical = Sp.x10)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) { RowHead(label, sub, null) }
            Dim3(fmt(live))
        }
        Slider(
            value = live, onValueChange = { live = it }, onValueChangeFinished = { onCommit(live) },
            valueRange = range,
            colors = SliderDefaults.colors(thumbColor = c.acc, activeTrackColor = c.acc, inactiveTrackColor = c.s3),
        )
    }
}

@Composable
private fun RowHead(label: String, sub: String?, icon: ImageVector?) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) {
            Icon(icon, null, Modifier.size(21.dp), tint = Lp.colors.fg2)
            Spacer(Modifier.width(Sp.x12))
        }
        Column {
            Body(label)
            if (sub != null) Dim3(sub, Modifier.padding(top = Sp.x2), maxLines = 3)
        }
    }
}

/** 选项行(弹窗 / 播放器面板共用)。 */
@Composable
fun OptRow(
    label: String,
    onClick: () -> Unit,
    m: Modifier = Modifier,
    sub: String? = null,
    selected: Boolean = false,
    badge: String? = null,
) {
    val c = Lp.colors
    Row(
        m.fillMaxWidth().heightIn(min = Dim.tap)
            .clip(RoundedCornerShape(R.sm))
            .background(if (selected) c.accDim else Color.Transparent)
            .pressable(onClick)
            .padding(horizontal = Sp.x12, vertical = Sp.x10),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, color = if (selected) c.acc else c.fg, fontSize = 14.sp, maxLines = 2,
                overflow = TextOverflow.Ellipsis)
            if (sub != null) Dim3(sub, Modifier.padding(top = Sp.x2))
        }
        if (badge != null) LpTag(badge)
        if (selected) Icon(LpIcons.check, null, Modifier.padding(start = Sp.x8).size(18.dp), tint = c.acc)
    }
}

@Composable
fun LpTag(text: String, m: Modifier = Modifier, danger: Boolean = false) {
    val c = Lp.colors
    Text(
        text, m.clip(RoundedCornerShape(R.sm)).background(if (danger) c.bad.copy(alpha = .18f) else c.accDim)
            .padding(horizontal = Sp.x8, vertical = Sp.x2),
        color = if (danger) c.bad else c.acc, fontSize = 11.sp, maxLines = 1,
    )
}

// ---------------------------------------------------------------- 骨架

/**
 * 骨架。**形状必须和真实内容一致**(海报骨架就是 2:3 的块)。
 * 25 行自己写,不引 shimmer 库(UI_MOBILE.md §12)。
 */
@Composable
fun Skeleton(m: Modifier = Modifier, corner: androidx.compose.ui.unit.Dp = R.md) {
    val c = Lp.colors
    val t = rememberInfiniteTransition(label = "skel")
    val x by t.animateFloat(
        0f, 1f,
        infiniteRepeatable(tween(1200, easing = LpEasing.standard), RepeatMode.Restart),
        label = "skelX",
    )
    Box(
        m.clip(RoundedCornerShape(corner)).background(
            Brush.linearGradient(
                0f to c.s3, (x * 0.6f + 0.2f).coerceIn(0f, 1f) to c.s2, 1f to c.s3,
            )
        )
    )
}

@Composable
fun SkeletonLine(width: androidx.compose.ui.unit.Dp, m: Modifier = Modifier) =
    Skeleton(m.width(width).height(12.dp), R.sm)

// ---------------------------------------------------------------- 空态

/**
 * 空态。**说明必须说清是「没有」还是「没配置」还是「被筛掉了」**(UI_MOBILE.md §6.4)。
 *
 * ☠「排行榜整屏白板一个字都没有」的根因是代码落进了 `if (busy) "加载中…" else ""` 分支
 * —— 那不是空态,那是白板。
 */
@Composable
fun EmptyState(
    title: String,
    desc: String? = null,
    icon: ImageVector = LpIcons.inbox,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    m: Modifier = Modifier,
) {
    val c = Lp.colors
    Column(
        m.fillMaxWidth().padding(Sp.x34),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier.size(64.dp).clip(RoundedCornerShape(R.pill)).background(c.s2),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, Modifier.size(28.dp), tint = c.fg3) }
        Spacer(Modifier.height(Sp.x16))
        Text(title, color = c.fg, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        if (desc != null) {
            Spacer(Modifier.height(Sp.x8))
            Text(desc, color = c.fg2, fontSize = 13.sp, lineHeight = 20.sp,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        }
        if (actionLabel != null && onAction != null) {
            Spacer(Modifier.height(Sp.x16))
            LpButton(actionLabel, onAction, kind = BtnKind.Secondary)
        }
    }
}

/**
 * 行内错误态 + 重试。
 * ★ `E_NETWORK` **不弹 toast**(网络抖动时会刷屏),画在这里(UI_MOBILE.md §6.3)。
 */
@Composable
fun ErrorState(message: String, onRetry: (() -> Unit)? = null, m: Modifier = Modifier) {
    val c = Lp.colors
    Column(m.fillMaxWidth().padding(Sp.x20), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(LpIcons.info, null, Modifier.size(24.dp), tint = c.bad)
        Spacer(Modifier.height(Sp.x8))
        Text(message, color = c.fg2, fontSize = 13.sp, lineHeight = 20.sp,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        if (onRetry != null) {
            Spacer(Modifier.height(Sp.x12))
            LpButton("重试", onRetry, kind = BtnKind.Secondary)
        }
    }
}

// ---------------------------------------------------------------- 弹窗

/**
 * 居中弹窗。**全站没有 bottom sheet**(既有决定,UI_MOBILE.md §4.2)。
 *
 * ☠ **遮罩自己画,并且铺满整块屏(含状态栏 / 导航条)**【用户定 2026-09-06】。
 *   靠 `BasicAlertDialog` 自带的那层平台 dim 不行:它只盖 dialog 窗口那块,
 *   而我们整个应用是 edge-to-edge 的 —— 于是弹窗开着的时候,后面那一页的选项
 *   还在从上下两头露出来,用户会去点它们。
 *   做法是 `usePlatformDefaultWidth=false` + `decorFitsSystemWindows=false`
 *   把 dialog 窗撑满,再自己铺一块 scrim。
 * ★ 点遮罩关闭 —— 但**面板本身要拦住点击**,不然点面板空白处也会关掉。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LpDialog(onDismiss: () -> Unit, title: String? = null, content: @Composable () -> Unit) {
    val c = Lp.colors
    BasicAlertDialog(
        onDismissRequest = onDismiss,
        properties = androidx.compose.ui.window.DialogProperties(
            usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Box(
            Modifier.fillMaxSize()
                .background(c.bg.copy(alpha = if (c.isDark) 0.82f else 0.72f))
                .clickable(interactionSource = remember { MutableInteractionSource() },
                    indication = null, onClick = onDismiss)
                .padding(Sp.x20),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                Modifier.widthIn(max = 420.dp).fillMaxWidth()
                    // ★ 吞掉点击:不吞的话点面板里的空白也会走到上面那层的 onDismiss
                    .clickable(interactionSource = remember { MutableInteractionSource() },
                        indication = null, onClick = {})
                    .glass(R.lg, solid = 1.25f)
                    .padding(Sp.x20),
            ) {
                if (title != null) {
                    H2(title)
                    Spacer(Modifier.height(Sp.x12))
                }
                content()
            }
        }
    }
}

// ---------------------------------------------------------------- 分隔与容器

@Composable
fun Hairline(m: Modifier = Modifier) =
    Box(m.fillMaxWidth().height(Dim.hairline).background(Lp.colors.line))

/**
 * 卡片面板。设置组、服务器卡都用它。
 *
 * ★ 2026-09-06 从「s1 平铺 + 发丝边」换成 [glass]:扁平面在这套深底上读起来发闷,
 *   而玻璃只是**换了一层膜**,版式一个像素没动。
 * ★ [solid] 透给调用方:服务器卡要更实一点【用户定】。
 */
@Composable
fun Panel(m: Modifier = Modifier, solid: Float = 1f, content: @Composable () -> Unit) {
    Column(m.fillMaxWidth().glass(R.md, solid)) { content() }
}

/** 三态渲染的收口:一个区块自己管自己的 Loading / Ok / Fail。 */
@Composable
fun <T> BlockBox(
    block: xyz.linplayer.app.data.Block<T>,
    onRetry: (() -> Unit)? = null,
    skeleton: @Composable () -> Unit = { Skeleton(Modifier.fillMaxWidth().height(120.dp)) },
    ok: @Composable (T) -> Unit,
) {
    when (block) {
        is xyz.linplayer.app.data.Block.Loading -> skeleton()
        is xyz.linplayer.app.data.Block.Ok -> ok(block.value)
        is xyz.linplayer.app.data.Block.Fail ->
            // E_UNSUPPORTED 静默降级:整块不画,一个字都不显示(UI_MOBILE.md §6.3)
            if (!block.isSilent) ErrorState(block.message, onRetry)
    }
}

@Composable
fun FullScreenBox(content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalContentColor provides Lp.colors.fg) {
        Box(Modifier.fillMaxSize().background(Lp.colors.bg)) { content() }
    }
}

internal val ListPad = PaddingValues(horizontal = Sp.x16, vertical = Sp.x12)
internal const val SkelDur = T.T6
