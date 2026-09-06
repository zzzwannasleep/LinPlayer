package xyz.linplayer.app.ui.pages

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import xyz.linplayer.app.data.Block
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.block
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.dbl
import xyz.linplayer.app.data.long
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.BlockBox
import xyz.linplayer.app.ui.components.Body
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.GlassIcon
import xyz.linplayer.app.ui.components.LpImmersive
import xyz.linplayer.app.ui.components.NetImage
import xyz.linplayer.app.ui.components.ToneChip
import xyz.linplayer.app.ui.components.glow
import xyz.linplayer.app.ui.components.pressable
import xyz.linplayer.app.ui.theme.Dim
import xyz.linplayer.app.ui.theme.LpEasing
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp
import xyz.linplayer.app.ui.theme.T
import xyz.linplayer.app.ui.theme.lpTween

/*
 * 发现族两页:排行榜 · 追剧日历。版式照草稿 06 / 07。
 *
 * ☠ 这两页 2026-09-06 之前**整页是空的**,而且不报错 —— 界面按
 * `name` / `items` / `air_time` 取值,核心层发的是 `label` / 平铺数组 /
 * `broadcast_at`;排行榜更把 `ranking.Entry` 当成 Emby 的 `Item` 去解析。
 * 同一类错由 `scripts/check-android-fields.py` 守着。
 *
 * ★ 榜单条目**不是本地库里的条目**:它的 id 是 TMDB / 弹弹Play 的 id,
 *   拿去开详情页必然 404。点击一律走**站内搜标题**。
 *
 * ★ 两页共用一套「辉光 + 大标题 + 无边框」的手法,**只有色相不同**
 *   (榜单金 / 日历紫)—— 它们在同一个 Tab 下,得能一眼分开又看得出是一家。
 */

private val GOLD = Color(0xFFFFC94D)
private val EMBER = Color(0xFFE0553F)
private val VIOLET = Color(0xFF6D4BD1)

/** 页面顶上那一块调子:渐变底 + 散在角上的辉光。**不铺一整层渐变** —— 那会闷。 */
@Composable
private fun ToneStage(hue: Color, second: Color?, content: @Composable () -> Unit) {
    val c = Lp.colors
    Box(
        Modifier.fillMaxSize().background(
            Brush.verticalGradient(
                0.00f to hue.copy(alpha = .16f),
                0.26f to hue.copy(alpha = .05f),
                0.54f to c.bg,
                1.00f to c.bg,
            )
        )
    ) {
        Box(Modifier.offset(x = (-70).dp, y = (-40).dp).size(250.dp).glow(hue, .34f))
        if (second != null) Box(
            Modifier.align(Alignment.TopEnd).offset(x = 90.dp, y = 60.dp).size(220.dp)
                .glow(second, .30f)
        )
        content()
    }
}

/** 大标题。**压在辉光上**,不放进顶栏 —— 顶栏那一行只留返回和一个入口。 */
@Composable
private fun BigTitle(text: String, sub: String? = null) {
    val c = Lp.colors
    Column(Modifier.fillMaxWidth().padding(horizontal = Sp.x16)) {
        Spacer(Modifier.height(
            WindowInsets.statusBars.asPaddingValues().calculateTopPadding() + Dim.topBar))
        Text(text, color = c.fg, fontSize = 29.sp, fontWeight = FontWeight.Bold, lineHeight = 33.sp)
        if (sub != null) {
            Spacer(Modifier.height(Sp.x6))
            Text(sub, color = c.fg2, fontSize = 12.sp)
        }
    }
}

// ---------------------------------------------------------------- 排行榜

/** 一条榜单。字段名照 `core/ranking/ranking.go` 的 `Entry`。 */
@androidx.compose.runtime.Immutable
private data class Rank(
    val id: String,
    val rank: Int,
    val title: String,
    val image: String?,
    val rating: Double?,
    val subtitle: String?,
    val favorited: Boolean,
) {
    companion object {
        fun list(e: kotlinx.serialization.json.JsonElement?): List<Rank> =
            e.arr().mapNotNull {
                val o = it.obj() ?: return@mapNotNull null
                Rank(
                    id = o.str("id") ?: return@mapNotNull null,
                    rank = (o.long("rank") ?: 0).toInt(),
                    title = o.str("title") ?: return@mapNotNull null,
                    image = o.str("image_url"),
                    rating = o.dbl("rating"),
                    subtitle = o.str("subtitle"),
                    favorited = o.bool("is_favorited"),
                )
            }
    }
}

/**
 * 排行榜(U1.14a)。版式照草稿 06。
 *
 * ★ **名次是这一页的主视觉**:大数字压在海报**后面**,海报反倒是配角 ——
 *   排行榜卖的就是名次。三张卡不在同一条线上,错落本身就是动势。
 * ★ 列表**零分隔线**:奇数行铺一层从左往右淡出的白 5%,右侧自然消失,不会在行尾切一刀。
 * ★ 取数失败必须**向上报错,不许吞成空表** —— 空表和失败在界面上长得一样,
 *   但一个该重试一个不该。
 * ★ 分类为空 = 这个构建**没注入榜单凭据**(本地 build 恒空),不是「加载中」。
 *   卡在骨架上是最坏的表现:用户会一直等下去。
 */
@Composable
fun RankingPage(nav: NavController) {
    val app = LocalApp.current
    val list = rememberLazyListState()
    var cats by remember { mutableStateOf<List<Pair<String, String>>?>(null) }
    var cur by remember { mutableStateOf<String?>(null) }
    var block by remember { mutableStateOf<Block<List<Rank>>>(Block.Loading) }

    LaunchedEffect(Unit) {
        cats = runCatching { app.call("emby.rankingCategories") }.getOrNull().arr()
            .mapNotNull {
                val o = it.obj() ?: return@mapNotNull null
                // ★ 分类名的字段是 label,不是 name —— 取错了每个芯片都叫「榜单」
                (o.str("id") ?: return@mapNotNull null) to (o.str("label") ?: "榜单")
            }
        cur = cats?.firstOrNull()?.first
    }
    LaunchedEffect(cur) {
        val id = cur ?: return@LaunchedEffect
        block = Block.Loading
        block = when (val r = app.block("emby.rankingFetch", args("category_id" to id))) {
            is Block.Ok -> Block.Ok(Rank.list(r.value))
            is Block.Fail -> r
            else -> Block.Loading
        }
    }

    val open: (Rank) -> Unit = { nav.navigate(Route.Search(q = it.title)) }

    LpImmersive(bar = {
        GlassIcon(LpIcons.back, "返回") { nav.popBackStack() }
        Spacer(Modifier.weight(1f))
        GlassIcon(LpIcons.search, "搜索") { nav.navigate(Route.Search()) }
    }) { pad ->
        ToneStage(GOLD, EMBER) {
            val cs = cats
            if (cs != null && cs.isEmpty()) {
                Column {
                    BigTitle("排行榜")
                    EmptyState("这个版本没有可用的榜单",
                        "榜单要靠弹弹Play / TMDB 的凭据,本地构建里没有它们。", LpIcons.trophy)
                }
                return@ToneStage
            }
            // 切榜单是**平级切换**:左右滑入,不做纵向位移
            // ★ 动画规格在**外面**算好再传进去:transitionSpec 里不是 @Composable 上下文
            val inFade = lpTween<Float>(T.T5)
            val inSlide = lpTween<androidx.compose.ui.unit.IntOffset>(T.T6, LpEasing.emphasizedDecelerate)
            val outFade = lpTween<Float>(T.T3)
            LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
                item("title") { BigTitle("排行榜") }
                item("chips") {
                    if (cs != null && cs.size > 1) Row(
                        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                            .padding(horizontal = Sp.x16, vertical = Sp.x12),
                        horizontalArrangement = Arrangement.spacedBy(Sp.x8),
                    ) {
                        cs.forEach { (id, name) -> ToneChip(name, id == cur) { cur = id } }
                    }
                }
                item("body") {
                    AnimatedContent(
                        targetState = block,
                        transitionSpec = {
                            (fadeIn(inFade) + slideInHorizontally(inSlide) { it / 12 }) togetherWith
                                fadeOut(outFade)
                        },
                        label = "rank",
                    ) { b ->
                        BlockBox(b, { cur = cur }) { rows ->
                            if (rows.isEmpty()) EmptyState("暂无榜单数据", "这个榜单现在是空的。",
                                LpIcons.trophy)
                            else Column {
                                if (rows.size >= 3) Podium(rows.take(3), open)
                                rows.drop(if (rows.size >= 3) 3 else 0)
                                    .forEachIndexed { i, r -> RankRow(r, i, open) }
                            }
                        }
                    }
                }
                item("tail") { Spacer(Modifier.height(Sp.x26)) }
            }
        }
    }
}

/** 金银铜。**只有这三个色号写死** —— 它们是奖牌不是主题色,跟着主题变就没意义了。 */
private val medals = listOf(GOLD, Color(0xFFD8DEE9), Color(0xFFD08B5B))

/**
 * 领奖台。第二名 · 第一名 · 第三名,**第一名整体上浮 14dp** 并且金色辉光 6 秒一次呼吸。
 * ★ 整页唯一的循环动效,慢到不会烦。
 */
@Composable
private fun Podium(top3: List<Rank>, open: (Rank) -> Unit) {
    // 排成 2 · 1 · 3
    val ordered = listOfNotNull(
        top3.getOrNull(1), top3.getOrNull(0), top3.getOrNull(2))
    Row(
        Modifier.fillMaxWidth().padding(start = Sp.x16, end = Sp.x16, top = Sp.x20, bottom = Sp.x16),
        horizontalArrangement = Arrangement.spacedBy(Sp.x10),
        verticalAlignment = Alignment.Bottom,
    ) {
        ordered.forEach { r -> Pod(r, Modifier.weight(1f), open) }
    }
}

@Composable
private fun Pod(r: Rank, m: Modifier, open: (Rank) -> Unit) {
    val c = Lp.colors
    val first = r.rank == 1
    val medal = medals.getOrElse(r.rank - 1) { medals[2] }

    val t = rememberInfiniteTransition(label = "pod")
    val breathe by t.animateFloat(
        0.55f, 1f,
        infiniteRepeatable(tween(6000, easing = LpEasing.standard), RepeatMode.Reverse),
        label = "breathe",
    )

    // 第一名整体上浮半层 —— 三张卡不在同一条线上,**错落本身就是动势**
    Column(m.offset(y = if (first) (-14).dp else 0.dp)) {
        Box {
            // 金色辉光只给第一名,6 秒一次呼吸。**整页唯一的循环动效**,慢到不会烦
            if (first) Box(
                Modifier.matchParentSize().graphicsLayer { alpha = breathe }.glow(GOLD, .45f)
            )
            Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).pressable({ open(r) })) {
                NetImage(r.image, r.title, Modifier.fillMaxSize(), 12.dp)
            }
            /* 名次数字压在海报左下角、往左探出一截。
               ★ 它是这一页的**主视觉**,海报反而是配角 —— 排行榜卖的就是名次。
               ★ 用 offset 不用 padding:offset 不参与布局,数字探到卡外面去也不会把行撑宽。 */
            Text(
                r.rank.toString(),
                Modifier.align(Alignment.BottomStart).offset(x = (-8).dp, y = 6.dp),
                color = medal, fontSize = if (first) 62.sp else 52.sp,
                fontWeight = FontWeight.Black, lineHeight = if (first) 56.sp else 47.sp,
            )
        }
        Spacer(Modifier.height(Sp.x8))
        Text(
            r.title, color = c.fg, fontSize = 12.sp,
            maxLines = 2, overflow = TextOverflow.Ellipsis, lineHeight = 16.sp,
        )
        r.rating?.takeIf { it > 0 }?.let {
            Text("%.1f".format(it), color = c.acc, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        }
    }
}

/**
 * 榜单一行。
 * ★ **零分隔线**:奇数行一层从左往右淡出的白 5% —— 斑马纹用渐变做,右侧自然消失。
 * ★ 4 名以后名次**越靠后越淡**:信息权重直接写进颜色里。
 * ★ 逐条错开 24ms 上浮进场,**只在首次组合时跑一次**。
 */
@Composable
private fun RankRow(r: Rank, index: Int, open: (Rank) -> Unit) {
    val c = Lp.colors
    var shown by remember(r.id) { mutableStateOf(false) }
    LaunchedEffect(r.id) {
        kotlinx.coroutines.delay((index.coerceAtMost(8) * 24).toLong()); shown = true
    }
    val a by animateFloatAsState(
        if (shown) 1f else 0f, lpTween(T.T5, LpEasing.emphasizedDecelerate), label = "rowIn")
    // 名次越靠后越淡,到第 20 名收在 12%
    val fade = (0.30f - index * 0.009f).coerceAtLeast(0.12f)

    Row(
        Modifier.fillMaxWidth()
            .graphicsLayer { alpha = a; translationY = (1f - a) * 24f }
            .then(
                if (index % 2 == 0) Modifier.background(
                    Brush.horizontalGradient(
                        0f to Color.White.copy(alpha = .05f),
                        0.82f to Color.Transparent,
                    )
                ) else Modifier
            )
            .pressable({ open(r) }).padding(horizontal = Sp.x16, vertical = Sp.x6),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            r.rank.toString(), Modifier.width(34.dp),
            color = c.fg.copy(alpha = fade), fontSize = 19.sp, fontWeight = FontWeight.Black,
        )
        NetImage(r.image, null, Modifier.size(56.dp, 84.dp), 10.dp)
        Spacer(Modifier.width(Sp.x12))
        Column(Modifier.weight(1f)) {
            Body(r.title, maxLines = 2)
            r.subtitle?.let { Dim3(it, Modifier.padding(top = 2.dp)) }
        }
        r.rating?.takeIf { it > 0 }?.let {
            Text("%.1f".format(it), color = c.acc, fontSize = 14.sp, fontWeight = FontWeight.Bold)
        }
    }
}

// ---------------------------------------------------------------- 追剧日历

/** 一条放送。字段名照 `core/sync/calendar.go` 的 `CalendarEntry`。 */
@androidx.compose.runtime.Immutable
private data class Air(
    val title: String,
    val subtitle: String?,
    val weekday: Int,          // 1=周一 … 7=周日
    val hhmm: String?,         // 本地时刻;取不到就是 null(**不编一个时间出来**)
    val at: java.time.Instant?,
    val image: String?,
    val rating: Double?,
)

private val weekLabels = listOf("一", "二", "三", "四", "五", "六", "日")

/**
 * 追剧日历(U1.14b · 付费)。版式照草稿 07。
 *
 * ☠ **赞助地址必须来自 `system.afdianSponsorUrl`,不许硬编。**
 * 2026-07-19 就栽在这:UI 里写死了一个凭空猜的主页,功能看着完全正常,
 * 而**赞助收益是零**。收款地址只能有一份。
 *
 * ★ 核心层发的是**平铺数组**,不是按天分组 —— 分组在这里做。
 * ★ 主轴是**时间不是番剧**:左边一条渐隐的光,同一时段的几部挂在同一个节点上。
 *   上一稿那条线是一根等粗的灰杠,太像表格了。
 */
@Composable
fun CalendarPage(nav: NavController) {
    val app = LocalApp.current
    var all by remember { mutableStateOf<Block<List<Air>>>(Block.Loading) }
    var sponsorUrl by remember { mutableStateOf<String?>(null) }
    // 默认落在今天。java.time 的 DayOfWeek 就是 1=周一,和核心层同口径
    val today = java.time.LocalDate.now().dayOfWeek.value
    var day by remember { mutableStateOf(today) }

    LaunchedEffect(Unit) {
        sponsorUrl = runCatching { app.call("system.afdianSponsorUrl") }
            .getOrNull().obj().str("url")
        all = when (val r = app.block("sync.bangumiCalendar")) {
            is Block.Ok -> Block.Ok(
                r.value.arr().mapNotNull {
                    val o = it.obj() ?: return@mapNotNull null
                    val at = parseIso(o.str("broadcast_at") ?: o.str("air_date"))
                    Air(
                        title = o.str("title") ?: return@mapNotNull null,
                        subtitle = o.str("subtitle"),
                        weekday = (o.long("weekday") ?: 0).toInt(),
                        hhmm = at?.let { i ->
                            i.atZone(java.time.ZoneId.systemDefault())
                                .format(java.time.format.DateTimeFormatter.ofPattern("HH:mm"))
                        },
                        at = at,
                        image = o.str("image_url"),
                        rating = o.dbl("rating"),
                    )
                }
            )
            is Block.Fail -> r
            else -> Block.Loading
        }
    }

    LpImmersive(bar = {
        GlassIcon(LpIcons.back, "返回") { nav.popBackStack() }
        Spacer(Modifier.weight(1f))
    }) { pad ->
        ToneStage(VIOLET, null) {
            BlockBox(all, null) { rows ->
                Column(Modifier.fillMaxSize()) {
                    BigTitle("追剧日历", "本周 ${rows.size} 集")
                    WeekBar(day, today, rows.groupingBy { it.weekday }.eachCount()) { day = it }

                    val dIn = lpTween<androidx.compose.ui.unit.IntOffset>(
                        T.T5, LpEasing.emphasizedDecelerate)
                    val dInFade = lpTween<Float>(T.T4)
                    val dOut = lpTween<androidx.compose.ui.unit.IntOffset>(T.T4)
                    val dOutFade = lpTween<Float>(T.T3)
                    AnimatedContent(
                        targetState = day,
                        transitionSpec = {
                            val fwd = targetState > initialState
                            (slideInHorizontally(dIn) { if (fwd) it / 6 else -it / 6 } +
                                fadeIn(dInFade)) togetherWith
                                (slideOutHorizontally(dOut) { if (fwd) -it / 10 else it / 10 } +
                                    fadeOut(dOutFade))
                        },
                        label = "day",
                    ) { d ->
                        Timeline(rows.filter { it.weekday == d }, isToday = d == today, pad = pad,
                            sponsor = sponsorUrl)
                    }
                }
            }
        }
    }
}

/**
 * 周条:**七颗胶囊**,今天/选中那颗是琥珀渐变。
 * ★ 上一稿是七个圆角方块 —— 方块并排 = 表格感。
 * ★ 那天 0 部画一个点,**不写「0」** —— 写 0 会被读成「今天停播」。
 */
@Composable
private fun WeekBar(cur: Int, today: Int, counts: Map<Int, Int>, onPick: (Int) -> Unit) {
    val c = Lp.colors
    val monday = java.time.LocalDate.now().minusDays((today - 1).toLong())
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Sp.x12, vertical = Sp.x12),
        horizontalArrangement = Arrangement.spacedBy(Sp.x6),
    ) {
        (1..7).forEach { d ->
            val on = d == cur
            val z by animateFloatAsState(if (on) 1f else 0f, lpTween(T.T5), label = "wd")
            Column(
                Modifier.weight(1f).clip(RoundedCornerShape(R.pill))
                    .then(
                        if (on) Modifier.background(
                            Brush.verticalGradient(listOf(c.acc, Color(0xFFD98A12)))
                        ) else Modifier.background(c.s1)
                    )
                    .pressable({ onPick(d) })
                    .padding(vertical = Sp.x10),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    weekLabels[d - 1],
                    color = if (on) c.accFg else if (d == today) c.acc else c.fg2,
                    fontSize = 11.sp,
                )
                Text(
                    "%02d".format(monday.plusDays((d - 1).toLong()).dayOfMonth),
                    color = if (on) c.accFg else c.fg, fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.graphicsLayer { val s = 1f + z * .06f; scaleX = s; scaleY = s },
                )
                val n = counts[d] ?: 0
                Text(
                    if (n > 0) n.toString() else "—",
                    color = (if (on) c.accFg else c.fg3).copy(alpha = if (n > 0) .85f else .5f),
                    fontSize = 10.sp,
                )
            }
        }
    }
}

/**
 * 时间轴。同一时刻的几部挂同一个节点。
 * ★ 节点往下是一道**由强到无的光**,时段之间不画横线 —— 线自己淡完就是分界。
 * ★ 下一个时段的节点是一颗 2.6 秒一次的脉冲点:「26 分钟后」那几部在页面上是活的。
 */
@Composable
private fun Timeline(rows: List<Air>, isToday: Boolean, pad: PaddingValues, sponsor: String?) {
    if (rows.isEmpty()) {
        EmptyState("这一天没有放送", "放送表按上游时区分组,这一栏是空的。", LpIcons.calendar)
        return
    }
    val slots = rows.groupBy { it.hhmm ?: "待定" }.toSortedMap()
    val now = java.time.Instant.now()
    // 「下一个时段」= 今天里第一个还没到的时刻。不是今天就没有这颗脉冲点
    val nextSlot = if (!isToday) null else slots.entries
        .firstOrNull { e -> e.value.any { it.at != null && it.at.isAfter(now) } }?.key

    LazyColumn(Modifier.fillMaxSize(), contentPadding = pad) {
        slots.forEach { (hhmm, list) ->
            item(hhmm) { Slot(hhmm, list, hhmm == nextSlot, now) }
        }
        if (sponsor != null) item("sponsor") {
            Dim3("追剧日历是付费功能。赞助后可解锁「我追的番」过滤。",
                Modifier.padding(Sp.x16), maxLines = 3)
        }
        item("tail") { Spacer(Modifier.height(Sp.x26)) }
    }
}

@Composable
private fun Slot(hhmm: String, list: List<Air>, isNext: Boolean, now: java.time.Instant) {
    val c = Lp.colors
    val t = rememberInfiniteTransition(label = "pulse")
    val p by t.animateFloat(
        0f, 1f,
        infiniteRepeatable(tween(2600, easing = LpEasing.standardDecelerate), RepeatMode.Restart),
        label = "pulseP",
    )
    /* ★ 高度走 `IntrinsicSize.Min` 让那道光自己撑满整段。
       写成「卡片数 × 猜一个高度」的话,标题换行多一行就露出一截或短一截 ——
       而那种错位只有在真机上、恰好那一部片名字长的时候才看得见。 */
    Row(
        Modifier.fillMaxWidth().height(androidx.compose.foundation.layout.IntrinsicSize.Min)
            .padding(start = Sp.x16, end = Sp.x16),
    ) {
        Column(
            Modifier.width(52.dp).fillMaxHeight(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                hhmm, color = if (isNext) c.acc else c.fg2, fontSize = 13.sp,
                fontWeight = if (isNext) FontWeight.Bold else FontWeight.Medium,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(Sp.x6))
            Box(contentAlignment = Alignment.Center) {
                // 脉冲:一圈从节点扩出去再化掉
                if (isNext) Box(
                    Modifier.size(26.dp).graphicsLayer {
                        val s = 0.3f + p * 0.7f
                        scaleX = s; scaleY = s; alpha = (1f - p) * 0.55f
                    }.clip(RoundedCornerShape(R.pill)).background(c.acc)
                )
                Box(
                    Modifier.size(8.dp).clip(RoundedCornerShape(R.pill))
                        .background(if (isNext) c.acc else c.line2)
                )
            }
            // 节点往下那道**渐隐的光**:从强到无。时段之间不画横线 —— 线自己淡完就是分界
            Box(
                Modifier.width(2.dp).weight(1f).background(
                    Brush.verticalGradient(
                        listOf(
                            (if (isNext) c.acc else c.fg2).copy(alpha = .55f),
                            Color.Transparent,
                        )
                    )
                )
            )
        }
        Spacer(Modifier.width(Sp.x12))
        Column(Modifier.weight(1f).padding(top = Sp.x2)) {
            list.forEachIndexed { i, a -> AirCard(a, i, now) }
        }
    }
}

/** 番剧卡。**去掉描边**,白 6% 填充 + 16 圆角。 */
@Composable
private fun AirCard(a: Air, index: Int, now: java.time.Instant) {
    val c = Lp.colors
    var shown by remember(a.title) { mutableStateOf(false) }
    LaunchedEffect(a.title) {
        kotlinx.coroutines.delay((index.coerceAtMost(8) * 28).toLong()); shown = true
    }
    val t by animateFloatAsState(
        if (shown) 1f else 0f, lpTween(T.T6, LpEasing.emphasizedDecelerate), label = "airIn")

    Row(
        Modifier.fillMaxWidth().padding(bottom = Sp.x10)
            .graphicsLayer { alpha = t; translationY = (1f - t) * 28f }
            .clip(RoundedCornerShape(16.dp)).background(c.s1)
            .padding(Sp.x8),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        NetImage(a.image, null, Modifier.size(44.dp, 62.dp), 10.dp)
        Spacer(Modifier.width(Sp.x10))
        Column(Modifier.weight(1f)) {
            // ★ 标题不许单行截断(截成「…」= 显示不全),放开完整换行
            Body(a.title, maxLines = 2)
            a.subtitle?.let { Dim3(it, Modifier.padding(top = 2.dp)) }
            countdown(a.at, now)?.let { (label, soon) ->
                Spacer(Modifier.height(Sp.x6))
                Text(
                    label,
                    Modifier.clip(RoundedCornerShape(R.pill))
                        .background(if (soon) c.accDim else c.ok.copy(alpha = .18f))
                        .padding(horizontal = Sp.x8, vertical = 2.dp),
                    color = if (soon) c.acc else c.ok, fontSize = 10.5.sp,
                )
            }
        }
        a.rating?.takeIf { it > 0 }?.let {
            Text("%.1f".format(it), Modifier.padding(end = Sp.x6), color = c.acc,
                fontSize = 13.sp, fontWeight = FontWeight.Bold)
        }
    }
}

/**
 * 「26 分钟后」/「已更新」。返回 null 表示**算不出来** —— 时刻缺失时不编一个出来。
 *
 * ★ Bangumi 官方 API 不给时刻,靠 bangumi-data 补;补不到的条目核心层发的就是 null。
 */
private fun countdown(at: java.time.Instant?, now: java.time.Instant): Pair<String, Boolean>? {
    if (at == null) return null
    val mins = java.time.Duration.between(now, at).toMinutes()
    return when {
        mins < 0 -> "已更新" to false
        mins < 60 -> "$mins 分钟后" to true
        mins < 24 * 60 -> "${mins / 60} 小时后" to true
        else -> null
    }
}

private fun parseIso(iso: String?): java.time.Instant? {
    if (iso.isNullOrBlank()) return null
    return runCatching { java.time.Instant.parse(iso) }.getOrNull()
}
