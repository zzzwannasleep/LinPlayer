package xyz.linplayer.app.ui.drafts

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import xyz.linplayer.app.ui.components.pressable
import xyz.linplayer.app.ui.theme.LpEasing
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.Sp
import xyz.linplayer.app.ui.theme.T
import xyz.linplayer.app.ui.theme.lpTween

/*
 * 手机端 UI 第二版的**草稿画廊**。
 *
 * 用途:出草稿图给人看。`am start ... -e lp_page 'drafts:<n>'` 直达第 n 张。
 *
 * ★ 为什么草稿是**真 Compose** 而不是画的图 / 网页原型:
 *   上一版的草稿是 Web 原型,照着它写出来的 Compose 就长着网页的样子 ——
 *   共享元素、折叠大标题、squircle、错峰进场,这些在 Web 原型里根本表达不出来,
 *   于是也就没人去做。草稿用什么技术写,成品就会长成什么样。
 *
 * ★ 草稿**不连网**:图一律用色块占位。这里要评的是版式和动效,不是图好不好看,
 *   而且连网会让「服务器没配好」变成「草稿打不开」。
 */

// ---------------------------------------------------------------- 第二版新增 token

/** 形状三分(UI_MOBILE_V2 §1.1)。**只有这三种**,别就地写第四种。 */
object S2 {
    val pill = RoundedCornerShape(999.dp)
    val card = RoundedCornerShape(16.dp)

    /** squircle 的连续曲率近似。**只给三处**:库入口、榜单前三、设置头像。 */
    val squircle = RoundedCornerShape(22.dp)
}

/** 字阶五档(UI_MOBILE_V2 §1.3)。全站只有这五档。 */
object F2 {
    val display = 44.sp
    val title = 22.sp
    val section = 17.sp
    val body = 14.sp
    val meta = 12.sp
}

/** 草稿里的假色块 —— 代替海报。同一个 id 恒定同一个色,换页不会跳。 */
private fun swatch(seed: Int): Brush {
    val hues = listOf(
        0xFF3B4A6B to 0xFF1C2233, 0xFF6B3B4A to 0xFF331C22,
        0xFF3B6B4A to 0xFF1C3322, 0xFF6B5A3B to 0xFF33291C,
        0xFF5A3B6B to 0xFF291C33, 0xFF3B6B6B to 0xFF1C3333,
    )
    val (a, b) = hues[seed.mod(hues.size)]
    return Brush.linearGradient(listOf(Color(a), Color(b)))
}

@Composable
private fun Poster(seed: Int, m: Modifier, shape: RoundedCornerShape = S2.card) {
    Box(m.clip(shape).background(swatch(seed)))
}

/** 错峰进场(§2.3)。**封顶第 9 项** —— 不封顶第 40 项要等 960ms。 */
@Composable
private fun Modifier.stagger(index: Int): Modifier {
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        kotlinx.coroutines.delay((index.coerceAtMost(8) * 24).toLong())
        shown = true
    }
    val t by animateFloatAsState(
        if (shown) 1f else 0f, lpTween(T.T5, LpEasing.emphasizedDecelerate), label = "stagger")
    return this.graphicsLayer { alpha = t; translationY = (1f - t) * 12.dp.toPx() }
}

// ---------------------------------------------------------------- 入口

/** `lp_page drafts:<n>` 的 n。0=目录 1=首页 2=媒体库 3=剧详情 4=集详情 5=播放页 6=组件表 */
@Composable
fun DraftGallery(start: Int = 0) {
    var page by remember { mutableIntStateOf(start) }
    Box(Modifier.fillMaxSize().background(Lp.colors.bg)) {
        when (page) {
            1 -> DraftHome()
            2 -> DraftLibrary()
            3 -> DraftSeriesDetail()
            4 -> DraftEpisodeDetail()
            5 -> DraftPlayer()
            6 -> DraftComponents()
            else -> DraftIndex { page = it }
        }
        if (page != 0) Text(
            "← 目录",
            Modifier.align(Alignment.BottomStart).padding(Sp.x12)
                .clip(S2.pill).background(Lp.colors.chip)
                .pressable({ page = 0 }).padding(horizontal = Sp.x12, vertical = Sp.x6),
            color = Lp.colors.fg2, fontSize = F2.meta,
        )
    }
}

@Composable
private fun DraftIndex(go: (Int) -> Unit) {
    val names = listOf(
        1 to "首页", 2 to "媒体库页", 3 to "剧 / 电影详情页",
        4 to "集详情页", 5 to "播放页", 6 to "组件表",
    )
    Column(Modifier.fillMaxSize().padding(Sp.x16)) {
        Spacer(Modifier.height(Sp.x48))
        Text("UI 第二版", color = Lp.colors.fg, fontSize = F2.display,
            fontWeight = FontWeight.Black)
        Text("草稿画廊 · 真 Compose 渲染", color = Lp.colors.fg2, fontSize = F2.meta)
        Spacer(Modifier.height(Sp.x26))
        names.forEachIndexed { i, (n, label) ->
            Row(
                Modifier.fillMaxWidth().stagger(i).padding(vertical = Sp.x6)
                    .clip(S2.card).background(Lp.colors.s1)
                    .pressable({ go(n) }).padding(Sp.x16),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("$n", Modifier.width(28.dp), color = Lp.colors.acc,
                    fontSize = F2.section, fontWeight = FontWeight.Bold)
                Text(label, color = Lp.colors.fg, fontSize = F2.body)
            }
        }
    }
}

// ---------------------------------------------------------------- 1 · 首页

@Composable
private fun DraftHome() {
    val c = Lp.colors
    // 大图取色 → 强调色(§1.2)。草稿里直接给一个,成品从核心层取
    val accent = Color(0xFF7FA6FF)
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            // ★ 大图占屏 52% 且**顶到状态栏**:第一版把它压在一条顶栏下面,
            //   既不沉浸也不整齐
            Box(Modifier.fillMaxWidth().height(430.dp)) {
                Box(Modifier.fillMaxSize().background(swatch(0)))
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(
                    0.35f to Color.Transparent, 1f to c.bg)))
                // 右上角两个入口浮在图上,不占一条独立的栏
                Row(Modifier.align(Alignment.TopEnd).padding(top = 44.dp, end = Sp.x12),
                    horizontalArrangement = Arrangement.spacedBy(Sp.x8)) {
                    GlassIcon(LpIcons.search); GlassIcon(LpIcons.settings)
                }
                Column(Modifier.align(Alignment.BottomStart).padding(Sp.x16)) {
                    Text("寂静的星河", color = c.fg, fontSize = F2.display,
                        fontWeight = FontWeight.Black, maxLines = 2,
                        overflow = TextOverflow.Ellipsis)
                    Text("2024 · ★ 8.6 · 科幻 · 悬疑", color = c.fg2, fontSize = F2.meta)
                    Spacer(Modifier.height(Sp.x12))
                    // ★ 起播按钮直接放在大图上 —— 第一版要滚到第二条轨道才能继续看
                    PillButton("继续观看 S2E4", accent)
                    Spacer(Modifier.height(Sp.x12))
                    Row(horizontalArrangement = Arrangement.spacedBy(Sp.x6)) {
                        repeat(5) { i ->
                            Box(Modifier.size(if (i == 0) 18.dp else 6.dp, 4.dp)
                                .clip(S2.pill)
                                .background(if (i == 0) accent else c.line2))
                        }
                    }
                }
            }
        }
        item { SectionHead("继续观看") }
        item {
            LazyRow(contentPadding = PaddingValues(horizontal = Sp.x16),
                horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
                items((1..6).toList()) { i ->
                    Column(Modifier.width(190.dp).stagger(i)) {
                        Box {
                            Poster(i, Modifier.fillMaxWidth().aspectRatio(16f / 9f))
                            // 进度条压在缩略图底边,跟着强调色
                            Box(Modifier.align(Alignment.BottomStart).fillMaxWidth()
                                .height(3.dp).background(c.line2))
                            Box(Modifier.align(Alignment.BottomStart)
                                .fillMaxWidth(0.35f + i * .08f).height(3.dp).background(accent))
                        }
                        Spacer(Modifier.height(Sp.x6))
                        Text("寂静的星河", color = c.fg, fontSize = F2.body, maxLines = 1)
                        Text("S2E$i · 剩 18 分钟", color = c.fg2, fontSize = F2.meta)
                    }
                }
            }
        }
        item {
            // ★ 媒体库入口:一行四个 squircle,不横滑 —— 库通常就 3~6 个,
            //   横滑意味着有看不见的东西,而这里没有
            Row(Modifier.fillMaxWidth().padding(Sp.x16),
                horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
                listOf("电影" to LpIcons.file, "剧集" to LpIcons.version,
                    "动漫" to LpIcons.grid, "纪录" to LpIcons.folder)
                    .forEachIndexed { i, (name, icon) ->
                        Column(
                            Modifier.weight(1f).stagger(i).clip(S2.squircle)
                                .background(c.s1).pressable({}).padding(vertical = Sp.x16),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Icon(icon, null, Modifier.size(22.dp), tint = accent)
                            Spacer(Modifier.height(Sp.x6))
                            Text(name, color = c.fg2, fontSize = F2.meta)
                        }
                    }
            }
        }
        item { SectionHead("电影 · 最新", more = true) }
        item { PosterRow(10) }
        item { SectionHead("剧集 · 最新", more = true) }
        item { PosterRow(20) }
        item { Spacer(Modifier.height(Sp.x48)) }
    }
}

@Composable
private fun PosterRow(seed: Int) {
    LazyRow(contentPadding = PaddingValues(horizontal = Sp.x16),
        horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
        items((0..6).toList()) { i ->
            Column(Modifier.width(120.dp).stagger(i)) {
                Poster(seed + i, Modifier.fillMaxWidth().aspectRatio(2f / 3f))
                Spacer(Modifier.height(Sp.x6))
                Text("片名 ${i + 1}", color = Lp.colors.fg, fontSize = F2.body, maxLines = 1)
                Text("2024", color = Lp.colors.fg2, fontSize = F2.meta)
            }
        }
    }
}

@Composable
private fun SectionHead(title: String, more: Boolean = false) {
    Row(
        Modifier.fillMaxWidth().padding(start = Sp.x16, end = Sp.x16, top = Sp.x20, bottom = Sp.x8),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, color = Lp.colors.fg, fontSize = F2.section, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.weight(1f))
        if (more) Text("更多", color = Lp.colors.fg2, fontSize = F2.meta)
    }
}

@Composable
private fun GlassIcon(icon: androidx.compose.ui.graphics.vector.ImageVector) {
    Box(Modifier.size(36.dp).clip(S2.pill).background(Lp.colors.chip),
        contentAlignment = Alignment.Center) {
        Icon(icon, null, Modifier.size(18.dp), tint = Lp.colors.fg)
    }
}

@Composable
private fun PillButton(label: String, accent: Color) {
    Row(
        Modifier.clip(S2.pill).background(accent).pressable({})
            .padding(horizontal = Sp.x20, vertical = Sp.x12),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(LpIcons.play, null, Modifier.size(18.dp), tint = Color.White)
        Spacer(Modifier.width(Sp.x8))
        Text(label, color = Color.White, fontSize = F2.body, fontWeight = FontWeight.SemiBold)
    }
}

// ---------------------------------------------------------------- 2 · 媒体库页

@Composable
private fun DraftLibrary() {
    val c = Lp.colors
    val list = rememberLazyListState()
    // 折叠大标题:滚过 120px 就收起(成品用 exitUntilCollapsedScrollBehavior)
    val collapsed = list.firstVisibleItemIndex > 0 || list.firstVisibleItemScrollOffset > 120
    val h by animateFloatAsState(if (collapsed) 0f else 1f,
        lpTween(T.T5, LpEasing.emphasized), label = "collapse")

    Column(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxWidth().background(c.bg).padding(top = 40.dp)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = Sp.x12),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(LpIcons.back, null, Modifier.size(22.dp), tint = c.fg)
                if (collapsed) {
                    Spacer(Modifier.weight(1f))
                    Text("电影", color = c.fg, fontSize = F2.title, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.weight(1f))
                    Spacer(Modifier.size(22.dp))
                }
            }
            // 展开态:左下大标题 + 计数
            Box(Modifier.fillMaxWidth().height((88 * h).dp).graphicsLayer { alpha = h }) {
                Column(Modifier.align(Alignment.BottomStart).padding(start = Sp.x16)) {
                    Text("电影", color = c.fg, fontSize = F2.display, fontWeight = FontWeight.Black)
                    Text("1,284 部", color = c.fg2, fontSize = F2.meta)
                }
            }
            Spacer(Modifier.height(Sp.x12))
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                .padding(horizontal = Sp.x16),
                horizontalArrangement = Arrangement.spacedBy(Sp.x8)) {
                listOf("全部" to true, "未看" to false, "已看" to false, "收藏" to false)
                    .forEach { (n, on) -> Chip(n, on) }
            }
            Row(Modifier.fillMaxWidth().padding(Sp.x16),
                verticalAlignment = Alignment.CenterVertically) {
                Text("⇅  最近添加", color = c.fg2, fontSize = F2.meta)
                Spacer(Modifier.weight(1f))
                // 筛选生效时挂计数徽标 —— 第一版筛完之后界面上看不出「现在是筛过的」
                Row(Modifier.clip(S2.pill).background(c.accDim)
                    .padding(horizontal = Sp.x12, vertical = Sp.x6),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text("筛选", color = c.acc, fontSize = F2.meta)
                    Spacer(Modifier.width(Sp.x6))
                    Box(Modifier.size(16.dp).clip(S2.pill).background(c.acc),
                        contentAlignment = Alignment.Center) {
                        Text("2", color = Color.White, fontSize = 10.sp)
                    }
                }
            }
        }
        // ★ 固定三列,不用自适应:自适应在窄屏上会塌成两列大卡,一屏只剩四部片
        LazyVerticalGrid(
            GridCells.Fixed(3), Modifier.fillMaxSize(),
            contentPadding = PaddingValues(Sp.x16, 0.dp, Sp.x16, Sp.x48),
            horizontalArrangement = Arrangement.spacedBy(Sp.x10),
            verticalArrangement = Arrangement.spacedBy(Sp.x16),
        ) {
            gridItems((0..17).toList()) { i ->
                Column(Modifier.stagger(i)) {
                    Box {
                        Poster(i, Modifier.fillMaxWidth().aspectRatio(2f / 3f))
                        if (i % 4 == 0) Box(
                            Modifier.align(Alignment.TopEnd).padding(Sp.x6).size(18.dp)
                                .clip(S2.pill).background(c.ok),
                            contentAlignment = Alignment.Center,
                        ) { Text("✓", color = Color.White, fontSize = 10.sp) }
                    }
                    Spacer(Modifier.height(Sp.x6))
                    Text("片名 ${i + 1}", color = c.fg, fontSize = F2.body, maxLines = 1)
                    Text("2024", color = c.fg2, fontSize = F2.meta)
                }
            }
        }
    }
}

@Composable
private fun Chip(label: String, on: Boolean) {
    Text(
        label,
        Modifier.clip(S2.pill)
            .background(if (on) Lp.colors.acc else Lp.colors.s2)
            .pressable({}).padding(horizontal = Sp.x16, vertical = Sp.x8),
        color = if (on) Color.White else Lp.colors.fg2, fontSize = 13.sp,
        fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
    )
}

// ---------------------------------------------------------------- 3 · 剧详情页

@Composable
private fun DraftSeriesDetail() {
    val c = Lp.colors
    val accent = Color(0xFFE2A15C)   // 从海报取的色(草稿里给死)
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Box(Modifier.fillMaxWidth().height(360.dp)) {
                Box(Modifier.fillMaxSize().background(swatch(3)))
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(
                    0.3f to Color.Transparent, 1f to c.bg)))
                Icon(LpIcons.back, null,
                    Modifier.align(Alignment.TopStart).padding(top = 44.dp, start = Sp.x16)
                        .size(24.dp), tint = c.fg)
                Row(Modifier.align(Alignment.BottomStart).padding(Sp.x16),
                    verticalAlignment = Alignment.Bottom) {
                    // 共享元素飞过来的就是这张海报
                    Poster(3, Modifier.width(96.dp).aspectRatio(2f / 3f))
                    Spacer(Modifier.width(Sp.x12))
                    Column(Modifier.padding(bottom = Sp.x6)) {
                        Text("寂静的星河", color = c.fg, fontSize = F2.title,
                            fontWeight = FontWeight.Bold)
                        Text("2024 · 3 季 · ★ 8.6", color = c.fg2, fontSize = F2.meta)
                    }
                }
            }
        }
        item {
            // ★ 起播抬到大图正下方的固定位置 —— 90% 情况下用户唯一想点的东西
            Row(Modifier.fillMaxWidth().padding(horizontal = Sp.x16),
                verticalAlignment = Alignment.CenterVertically) {
                PillButton("继续 S2E4", accent)
                Spacer(Modifier.weight(1f))
                listOf(LpIcons.heart, LpIcons.download, LpIcons.more).forEach {
                    Box(Modifier.size(40.dp).clip(S2.pill)
                        .border(1.dp, c.line2, S2.pill).pressable({}),
                        contentAlignment = Alignment.Center) {
                        Icon(it, null, Modifier.size(18.dp), tint = c.fg2)
                    }
                    Spacer(Modifier.width(Sp.x8))
                }
            }
        }
        item {
            Column(Modifier.padding(Sp.x16)) {
                Text("一支勘探队在柯伊伯带外沿收到一段重复的信号。信号的内容,是他们自己三年后发出的求救。",
                    color = c.fg2, fontSize = F2.body, maxLines = 2,
                    overflow = TextOverflow.Ellipsis)
                Text("展开", color = accent, fontSize = F2.meta,
                    modifier = Modifier.padding(top = Sp.x6))
            }
        }
        item {
            LazyRow(contentPadding = PaddingValues(horizontal = Sp.x16),
                horizontalArrangement = Arrangement.spacedBy(Sp.x12)) {
                items((0..5).toList()) { i ->
                    Column(Modifier.width(64.dp).stagger(i),
                        horizontalAlignment = Alignment.CenterHorizontally) {
                        Poster(i + 30, Modifier.size(56.dp), S2.pill)
                        Spacer(Modifier.height(Sp.x6))
                        Text("演员名", color = c.fg2, fontSize = F2.meta, maxLines = 1)
                    }
                }
            }
        }
        item {
            Row(Modifier.padding(start = Sp.x16, top = Sp.x20, bottom = Sp.x8)) {
                Text("第 1 季  ▾", color = c.fg, fontSize = F2.section,
                    fontWeight = FontWeight.SemiBold)
            }
        }
        // ★ 分集用横条不用网格:集名在网格卡下面必然被截断
        items((1..6).toList()) { i ->
            Row(
                Modifier.fillMaxWidth().stagger(i)
                    .padding(horizontal = Sp.x16, vertical = Sp.x6),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box {
                    Poster(i + 40, Modifier.width(112.dp).aspectRatio(16f / 9f))
                    if (i == 4) {
                        Box(Modifier.align(Alignment.BottomStart).fillMaxWidth()
                            .height(3.dp).background(Color.Black.copy(alpha = .4f)))
                        Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(.62f)
                            .height(3.dp).background(accent))
                    }
                }
                Spacer(Modifier.width(Sp.x12))
                Column(Modifier.weight(1f)) {
                    Text("$i. 谎言的代价", color = c.fg, fontSize = F2.body, maxLines = 2)
                    Text(if (i == 4) "看到 62% · 剩 9 分钟" else "24:03",
                        color = if (i == 4) accent else c.fg2, fontSize = F2.meta)
                }
            }
        }
        item { Spacer(Modifier.height(Sp.x48)) }
    }
}

// ---------------------------------------------------------------- 4 · 集详情页

@Composable
private fun DraftEpisodeDetail() {
    val c = Lp.colors
    val accent = Color(0xFF66C2A5)
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f)) {
                Box(Modifier.fillMaxSize().background(swatch(44)))
                Icon(LpIcons.back, null,
                    Modifier.align(Alignment.TopStart).padding(top = 44.dp, start = Sp.x16)
                        .size(24.dp), tint = c.fg)
                // 唯一的主动作,压在剧照中心 —— 集详情只回答「这一集现在看不看」
                Box(Modifier.align(Alignment.Center).size(64.dp).clip(S2.pill)
                    .background(accent), contentAlignment = Alignment.Center) {
                    Icon(LpIcons.play, null, Modifier.size(28.dp), tint = Color.White)
                }
            }
        }
        item {
            Column(Modifier.padding(Sp.x16)) {
                Text("S2E4 · 谎言的代价", color = c.fg, fontSize = F2.title,
                    fontWeight = FontWeight.Bold)
                Text("寂静的星河 · 2024-03-12 · 24:03", color = c.fg2, fontSize = F2.meta)
                Spacer(Modifier.height(Sp.x12))
                Box(Modifier.fillMaxWidth().height(4.dp).clip(S2.pill).background(c.line2)) {
                    Box(Modifier.fillMaxWidth(.62f).fillMaxHeight().clip(S2.pill)
                        .background(accent))
                }
                Text("已看 62% · 剩 9 分钟", color = c.fg2, fontSize = F2.meta,
                    modifier = Modifier.padding(top = Sp.x6))
            }
        }
        item {
            Text("勘探队决定隐瞒信号的真实来源。而信号里那个声音,开始叫出他们每个人的名字。",
                Modifier.padding(horizontal = Sp.x16), color = c.fg2, fontSize = F2.body)
        }
        item {
            // ★ 上一集 / 下一集是集详情**独有**的东西,第一版完全没有 ——
            //   看完一集回详情页再从列表里找下一集,是最常走又最难走的一条路
            Row(Modifier.fillMaxWidth().padding(Sp.x16),
                horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
                listOf("‹ 上一集" to 43, "下一集 ›" to 45).forEach { (label, seed) ->
                    Row(
                        Modifier.weight(1f).clip(S2.card).background(c.s1)
                            .pressable({}).padding(Sp.x8),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Poster(seed, Modifier.width(56.dp).aspectRatio(16f / 9f),
                            RoundedCornerShape(8.dp))
                        Spacer(Modifier.width(Sp.x8))
                        Text(label, color = c.fg2, fontSize = F2.meta, maxLines = 2)
                    }
                }
            }
        }
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = Sp.x16),
                horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
                listOf("收藏" to LpIcons.heart, "下载" to LpIcons.download,
                    "标为已看" to LpIcons.check).forEach { (n, ic) ->
                    Row(
                        Modifier.weight(1f).clip(S2.pill).border(1.dp, c.line2, S2.pill)
                            .pressable({}).padding(vertical = Sp.x10),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(ic, null, Modifier.size(16.dp), tint = c.fg2)
                        Spacer(Modifier.width(Sp.x6))
                        Text(n, color = c.fg2, fontSize = F2.meta, maxLines = 1)
                    }
                }
            }
        }
        item { Spacer(Modifier.height(Sp.x48)) }
    }
}

// ---------------------------------------------------------------- 5 · 播放页

@Composable
private fun DraftPlayer() {
    val c = Lp.colors
    val accent = Color(0xFF7FA6FF)
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        Box(Modifier.fillMaxSize().background(swatch(2)))
        // 顶栏
        Row(Modifier.align(Alignment.TopStart).fillMaxWidth()
            .background(Brush.verticalGradient(
                listOf(Color.Black.copy(alpha = .6f), Color.Transparent)))
            .padding(start = Sp.x16, end = Sp.x16, top = 34.dp, bottom = Sp.x16),
            verticalAlignment = Alignment.CenterVertically) {
            Icon(LpIcons.back, null, Modifier.size(22.dp), tint = Color.White)
            Spacer(Modifier.width(Sp.x12))
            Text("寂静的星河 · S2E4", color = Color.White, fontSize = F2.body)
            Spacer(Modifier.weight(1f))
            Icon(LpIcons.more, null, Modifier.size(22.dp), tint = Color.White)
        }
        // 中央三键
        Row(Modifier.align(Alignment.Center),
            horizontalArrangement = Arrangement.spacedBy(Sp.x26),
            verticalAlignment = Alignment.CenterVertically) {
            Icon(LpIcons.back, null, Modifier.size(30.dp), tint = Color.White)
            Box(Modifier.size(64.dp).clip(S2.pill).background(Color.White.copy(alpha = .18f)),
                contentAlignment = Alignment.Center) {
                Icon(LpIcons.pause, null, Modifier.size(30.dp), tint = Color.White)
            }
            Icon(LpIcons.forward, null, Modifier.size(30.dp), tint = Color.White)
        }
        // ★ 手势反馈:第一版调亮度时屏幕上什么都不显示
        Column(Modifier.align(Alignment.CenterStart).padding(start = Sp.x26)
            .clip(S2.pill).background(Color.Black.copy(alpha = .55f))
            .padding(horizontal = Sp.x10, vertical = Sp.x12),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(LpIcons.settings, null, Modifier.size(16.dp), tint = Color.White)
            Spacer(Modifier.height(Sp.x6))
            Box(Modifier.width(4.dp).height(80.dp).clip(S2.pill)
                .background(Color.White.copy(alpha = .25f))) {
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth()
                    .fillMaxHeight(.7f).clip(S2.pill).background(Color.White))
            }
        }
        // 底部:整宽进度条独占一行 + 一排 pill
        Column(Modifier.align(Alignment.BottomStart).fillMaxWidth()
            .background(Brush.verticalGradient(
                listOf(Color.Transparent, Color.Black.copy(alpha = .75f))))
            .padding(Sp.x16)) {
            Box(Modifier.fillMaxWidth().height(4.dp).clip(S2.pill)
                .background(Color.White.copy(alpha = .25f))) {
                // 片头 / 片尾在进度条上画成不同颜色的段
                Box(Modifier.fillMaxWidth(.08f).fillMaxHeight()
                    .background(Color(0x66FFC94D)))
                Box(Modifier.fillMaxWidth(.5f).fillMaxHeight().clip(S2.pill).background(accent))
            }
            Spacer(Modifier.height(Sp.x8))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("12:04", color = Color.White, fontSize = F2.meta)
                Spacer(Modifier.weight(1f))
                Text("24:03", color = Color.White.copy(alpha = .7f), fontSize = F2.meta)
            }
            Spacer(Modifier.height(Sp.x10))
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(Sp.x8)) {
                listOf("1.0x", "音轨", "字幕", "弹幕", "选集", "画质").forEach {
                    Text(it, Modifier.clip(S2.pill)
                        .background(Color.White.copy(alpha = .14f))
                        .padding(horizontal = Sp.x12, vertical = Sp.x6),
                        color = Color.White, fontSize = F2.meta)
                }
            }
        }
    }
}

// ---------------------------------------------------------------- 6 · 组件表

@Composable
private fun DraftComponents() {
    val c = Lp.colors
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = Sp.x16),
        contentPadding = PaddingValues(top = 48.dp, bottom = Sp.x48)) {
        item {
            Text("组件表", color = c.fg, fontSize = F2.display, fontWeight = FontWeight.Black)
            Spacer(Modifier.height(Sp.x20))
        }
        item { CompGroup("按钮") {
            PillButton("主按钮", c.acc)
            Spacer(Modifier.height(Sp.x8))
            Row(horizontalArrangement = Arrangement.spacedBy(Sp.x8)) {
                Text("次级", Modifier.clip(S2.pill).border(1.dp, c.line2, S2.pill)
                    .padding(horizontal = Sp.x16, vertical = Sp.x10),
                    color = c.fg2, fontSize = F2.body)
                Text("禁用", Modifier.clip(S2.pill).background(c.s2)
                    .padding(horizontal = Sp.x16, vertical = Sp.x10),
                    color = c.fg3, fontSize = F2.body)
                Box(Modifier.size(40.dp).clip(S2.pill).background(c.accDim),
                    contentAlignment = Alignment.Center) {
                    Icon(LpIcons.heart, null, Modifier.size(18.dp), tint = c.acc)
                }
            }
        } }
        item { CompGroup("芯片") {
            Row(horizontalArrangement = Arrangement.spacedBy(Sp.x8)) {
                Chip("全部", true); Chip("未看", false); Chip("已看", false)
            }
        } }
        item { CompGroup("卡片") {
            Row(horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
                Column(Modifier.width(96.dp)) {
                    Box {
                        Poster(1, Modifier.fillMaxWidth().aspectRatio(2f / 3f))
                        Box(Modifier.align(Alignment.TopEnd).padding(Sp.x6).size(18.dp)
                            .clip(S2.pill).background(c.ok),
                            contentAlignment = Alignment.Center) {
                            Text("✓", color = Color.White, fontSize = 10.sp)
                        }
                    }
                    Text("已看", color = c.fg2, fontSize = F2.meta)
                }
                Column(Modifier.width(96.dp)) {
                    Box {
                        Poster(2, Modifier.fillMaxWidth().aspectRatio(2f / 3f))
                        Box(Modifier.align(Alignment.TopEnd).padding(Sp.x6)
                            .clip(S2.pill).background(c.acc)
                            .padding(horizontal = Sp.x6, vertical = 2.dp)) {
                            Text("3", color = Color.White, fontSize = 10.sp)
                        }
                    }
                    Text("未看 3 集", color = c.fg2, fontSize = F2.meta)
                }
                Column(Modifier.width(96.dp)) {
                    Poster(4, Modifier.fillMaxWidth().aspectRatio(1f), S2.squircle)
                    Text("squircle", color = c.fg2, fontSize = F2.meta)
                }
            }
        } }
        item { CompGroup("反馈") {
            Column(verticalArrangement = Arrangement.spacedBy(Sp.x8)) {
                Text("已加入下载队列", Modifier.clip(S2.card).background(c.s3)
                    .padding(horizontal = Sp.x16, vertical = Sp.x12),
                    color = c.fg, fontSize = 13.sp)
                Text("连不上服务器", Modifier.clip(S2.card).background(c.bad)
                    .padding(horizontal = Sp.x16, vertical = Sp.x12),
                    color = Color.White, fontSize = 13.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(Sp.x8)) {
                    repeat(3) {
                        Box(Modifier.width(72.dp).height(96.dp).clip(S2.card).background(c.s2))
                    }
                }
            }
        } }
        item { CompGroup("底栏") {
            Row(Modifier.fillMaxWidth().clip(S2.card).background(c.s1)
                .padding(vertical = Sp.x10)) {
                listOf("首页" to LpIcons.grid, "聚合" to LpIcons.globe,
                    "服务器" to LpIcons.folder).forEachIndexed { i, (n, ic) ->
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        // 动画指示丸:选中项的图标坐在一颗胶囊里
                        Box(Modifier.clip(S2.pill)
                            .background(if (i == 0) c.accDim else Color.Transparent)
                            .padding(horizontal = Sp.x16, vertical = Sp.x2)) {
                            Icon(ic, null, Modifier.size(20.dp),
                                tint = if (i == 0) c.acc else c.fg3)
                        }
                        Spacer(Modifier.height(Sp.x2))
                        Text(n, color = if (i == 0) c.fg else c.fg3, fontSize = 10.sp)
                    }
                }
            }
        } }
    }
}

@Composable
private fun CompGroup(title: String, body: @Composable () -> Unit) {
    Column(Modifier.padding(bottom = Sp.x26)) {
        Text(title, color = Lp.colors.fg2, fontSize = F2.meta,
            fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(Sp.x10))
        body()
    }
}
