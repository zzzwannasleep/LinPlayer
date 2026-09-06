package xyz.linplayer.app.ui.pages

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
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
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import xyz.linplayer.app.data.Block
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.block
import xyz.linplayer.app.data.dbl
import xyz.linplayer.app.data.long
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.BlockBox
import xyz.linplayer.app.ui.components.Body
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.components.NetImage
import xyz.linplayer.app.ui.components.pressable
import xyz.linplayer.app.ui.components.rememberScrolled
import xyz.linplayer.app.ui.theme.LpEasing
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.LpSpring
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp
import xyz.linplayer.app.ui.theme.T
import xyz.linplayer.app.ui.theme.lpTween

/*
 * 发现族两页:排行榜 · 追剧日历。
 *
 * ☠ 这两页 2026-09-06 之前**整页是空的**,而且不报错 —— 界面按
 * `name` / `items` / `air_time` 取值,核心层发的是 `label` / 平铺数组 /
 * `broadcast_at`;排行榜更把 `ranking.Entry` 当成 Emby 的 `Item` 去解析。
 * 同一类错由 `scripts/check-android-fields.py` 守着。
 *
 * ★ 榜单条目**不是本地库里的条目**:它的 id 是 TMDB / 弹弹Play 的 id,
 *   拿去开详情页必然 404。点击一律走**站内搜标题**。
 */

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
                )
            }
    }
}

/**
 * 排行榜(U1.14a)。
 *
 * ★ 取数失败必须**向上报错,不许吞成空表** —— 空表和失败在界面上长得一样,
 *   但一个该重试一个不该。
 * ★ **根本没有「排行榜开关」这个东西** —— 别去找,也别加。
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

    LpScaffold("排行榜", onBack = { nav.popBackStack() }, scrolled = rememberScrolled(list)) { pad ->
        val cs = cats
        if (cs != null && cs.isEmpty()) {
            EmptyState("这个版本没有可用的榜单", "榜单要靠弹弹Play / TMDB 的凭据,本地构建里没有它们。",
                LpIcons.trophy)
            return@LpScaffold
        }
        Column(Modifier.fillMaxSize()) {
            if (cs != null && cs.size > 1) CategoryBar(cs, cur) { cur = it }
            // 切榜单是**平级切换**:左右滑入,不做纵向位移
            // ★ 动画规格在**外面**算好再传进去:transitionSpec 里不是 @Composable 上下文,
            //   lpTween(要读 LocalMotionScale)在里面调不了
            val inFade = lpTween<Float>(T.T5)
            val inSlide = lpTween<androidx.compose.ui.unit.IntOffset>(
                T.T6, LpEasing.emphasizedDecelerate)
            val outFade = lpTween<Float>(T.T3)
            AnimatedContent(
                targetState = block,
                transitionSpec = {
                    (fadeIn(inFade) + slideInHorizontally(inSlide) { it / 12 }) togetherWith
                        fadeOut(outFade)
                },
                label = "rank",
            ) { b ->
                BlockBox(b, { cur = cur }) { rows ->
                    if (rows.isEmpty()) EmptyState("暂无榜单数据", "这个榜单现在是空的。", LpIcons.trophy)
                    else LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
                        // 前三名做成一条横滑的领奖台,四名往后是行列表 ——
                        // 纯行列表看不出「榜」的意思,而前三是用户唯一真会细看的部分
                        if (rows.size >= 3) item("podium") { Podium(rows.take(3), open) }
                        itemsIndexed(
                            rows.drop(if (rows.size >= 3) 3 else 0),
                            key = { _, x -> x.id },
                        ) { i, r -> RankRow(r, i, open) }
                        item("tail") { Spacer(Modifier.height(Sp.x26)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun CategoryBar(cats: List<Pair<String, String>>, cur: String?, onPick: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .padding(horizontal = Sp.x16, vertical = Sp.x8),
        horizontalArrangement = Arrangement.spacedBy(Sp.x8),
    ) {
        cats.forEach { (id, name) ->
            val on = id == cur
            // 颜色渐变 + 轻微缩放:切换要有「落定」的手感,不是瞬切
            val bg by animateColorAsState(
                if (on) Lp.colors.acc else Lp.colors.s2, lpTween(T.T4), label = "chipBg")
            val fg by animateColorAsState(
                if (on) Lp.colors.accFg else Lp.colors.fg2, lpTween(T.T4), label = "chipFg")
            val z by animateFloatAsState(if (on) 1f else 0.96f, LpSpring.main(), label = "chipZ")
            Text(
                name,
                Modifier.graphicsLayer { scaleX = z; scaleY = z }
                    .clip(RoundedCornerShape(R.pill)).background(bg)
                    .pressable({ onPick(id) }).padding(horizontal = Sp.x16, vertical = Sp.x8),
                color = fg, fontSize = 13.sp,
                fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
            )
        }
    }
}

/** 金银铜。**只有这三个色号写死** —— 它们是奖牌不是主题色,跟着主题变就没意义了。 */
private val medals = listOf(Color(0xFFFFC94D), Color(0xFFD8DEE9), Color(0xFFD08B5B))

@Composable
private fun Podium(top3: List<Rank>, open: (Rank) -> Unit) {
    LazyRow(
        Modifier.fillMaxWidth().padding(top = Sp.x6, bottom = Sp.x10),
        contentPadding = PaddingValues(horizontal = Sp.x16),
        horizontalArrangement = Arrangement.spacedBy(Sp.x10),
    ) {
        items(top3, key = { it.id }) { r ->
            val medal = medals.getOrElse(r.rank - 1) { medals[2] }
            Column(Modifier.width(150.dp)) {
                Box(
                    Modifier.fillMaxWidth().aspectRatio(2f / 3f)
                        .clip(RoundedCornerShape(R.md)).pressable({ open(r) })
                ) {
                    NetImage(r.image, r.title, Modifier.fillMaxSize(), corner = 0.dp)
                    // 底部渐变:名次数字压在图上,不给它单独占一行
                    Box(
                        Modifier.fillMaxSize().background(
                            Brush.verticalGradient(
                                0.45f to Color.Transparent,
                                1f to Color.Black.copy(alpha = .78f),
                            )
                        )
                    )
                    Text(
                        "${r.rank}",
                        Modifier.align(Alignment.BottomStart).padding(start = Sp.x10, bottom = 2.dp),
                        color = medal, fontSize = 40.sp, fontWeight = FontWeight.Black,
                    )
                    r.rating?.takeIf { it > 0 }?.let {
                        Text(
                            "★ %.1f".format(it),
                            Modifier.align(Alignment.TopEnd).padding(Sp.x6)
                                .clip(RoundedCornerShape(R.sm))
                                .background(Color.Black.copy(alpha = .55f))
                                .padding(horizontal = Sp.x6, vertical = 2.dp),
                            color = Color.White, fontSize = 11.sp,
                        )
                    }
                }
                Spacer(Modifier.height(Sp.x6))
                Body(r.title, maxLines = 2)
            }
        }
    }
}

@Composable
private fun RankRow(r: Rank, index: Int, open: (Rank) -> Unit) {
    val c = Lp.colors
    // 进场:逐条错开 24ms 上浮。**只在首次组合时跑一次**,滚动不会重放
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(r.id) {
        kotlinx.coroutines.delay((index.coerceAtMost(8) * 24).toLong())
        shown = true
    }
    val a by animateFloatAsState(
        if (shown) 1f else 0f, lpTween(T.T5, LpEasing.emphasizedDecelerate), label = "rowIn")
    Row(
        Modifier.fillMaxWidth()
            .graphicsLayer { alpha = a; translationY = (1f - a) * 24f }
            .pressable({ open(r) }).padding(horizontal = Sp.x16, vertical = Sp.x6),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("${r.rank}", Modifier.width(34.dp), color = c.fg3, fontSize = 17.sp,
            fontWeight = FontWeight.Bold)
        NetImage(r.image, null, Modifier.size(56.dp, 84.dp))
        Spacer(Modifier.width(Sp.x12))
        Column(Modifier.weight(1f)) {
            Body(r.title, maxLines = 2)
            val sub = listOfNotNull(
                r.rating?.takeIf { it > 0 }?.let { "★ %.1f".format(it) },
                r.subtitle,
            ).joinToString("  ·  ")
            if (sub.isNotEmpty()) Dim3(sub, Modifier.padding(top = 2.dp))
        }
    }
}

// ---------------------------------------------------------------- 追剧日历

/** 一条放送。字段名照 `core/sync/calendar.go` 的 `CalendarEntry`。 */
@androidx.compose.runtime.Immutable
private data class Air(
    val title: String,
    val weekday: Int,          // 1=周一 … 7=周日
    val hhmm: String?,         // 本地时刻;取不到就是 null(**不编一个时间出来**)
    val image: String?,
    val rating: Double?,
)

private val weekLabels = listOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")

/**
 * 追剧日历(U1.14b · 付费)。
 *
 * ☠ **赞助地址必须来自 `system.afdianSponsorUrl`,不许硬编。**
 * 2026-07-19 就栽在这:UI 里写死了一个凭空猜的主页,功能看着完全正常,
 * 而**赞助收益是零**。收款地址只能有一份。
 *
 * ★ 核心层发的是**平铺数组**,不是按天分组 —— 分组在这里做。
 *   原来照「分组」去解析的结果是整页恒空。
 */
@Composable
fun CalendarPage(nav: NavController) {
    val app = LocalApp.current
    val list = rememberLazyListState()
    var all by remember { mutableStateOf<Block<List<Air>>>(Block.Loading) }
    var sponsorUrl by remember { mutableStateOf<String?>(null) }
    // 默认落在今天。java.time 的 DayOfWeek 就是 1=周一,和核心层同口径
    var day by remember { mutableStateOf(java.time.LocalDate.now().dayOfWeek.value) }

    LaunchedEffect(Unit) {
        sponsorUrl = runCatching { app.call("system.afdianSponsorUrl") }
            .getOrNull().obj().str("url")
        all = when (val r = app.block("sync.bangumiCalendar")) {
            is Block.Ok -> Block.Ok(
                r.value.arr().mapNotNull {
                    val o = it.obj() ?: return@mapNotNull null
                    Air(
                        title = o.str("title") ?: return@mapNotNull null,
                        weekday = (o.long("weekday") ?: 0).toInt(),
                        hhmm = localHhmm(o.str("broadcast_at") ?: o.str("air_date")),
                        image = o.str("image_url"),
                        rating = o.dbl("rating"),
                    )
                }
            )
            is Block.Fail -> r
            else -> Block.Loading
        }
    }

    LpScaffold("追剧日历", onBack = { nav.popBackStack() }, scrolled = rememberScrolled(list)) { pad ->
        BlockBox(all, null) { rows ->
            Column(Modifier.fillMaxSize()) {
                WeekBar(day, rows.groupingBy { it.weekday }.eachCount()) { day = it }
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
                    val rowsOfDay = rows.filter { it.weekday == d }.sortedBy { it.hhmm ?: "99:99" }
                    if (rowsOfDay.isEmpty()) EmptyState(
                        "这一天没有放送", "放送表按上游时区(JST)分组,这一栏是空的。", LpIcons.calendar)
                    else LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
                        itemsIndexed(rowsOfDay, key = { _, x -> x.title }) { i, a -> AirCard(a, i) }
                        if (sponsorUrl != null) item("sponsor") {
                            Dim3("追剧日历是付费功能。赞助后可解锁「我追的番」过滤。",
                                Modifier.padding(Sp.x16), maxLines = 3)
                        }
                        item("tail") { Spacer(Modifier.height(Sp.x26)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun WeekBar(cur: Int, counts: Map<Int, Int>, onPick: (Int) -> Unit) {
    val c = Lp.colors
    val today = java.time.LocalDate.now().dayOfWeek.value
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Sp.x10, vertical = Sp.x8),
        horizontalArrangement = Arrangement.spacedBy(Sp.x2),
    ) {
        (1..7).forEach { d ->
            val on = d == cur
            val bg by animateColorAsState(
                if (on) c.acc else Color.Transparent, lpTween(T.T4), label = "dayBg")
            val fg by animateColorAsState(
                when {
                    on -> c.accFg
                    d == today -> c.acc
                    else -> c.fg2
                },
                lpTween(T.T4), label = "dayFg",
            )
            Column(
                Modifier.weight(1f).clip(RoundedCornerShape(R.md)).background(bg)
                    .pressable({ onPick(d) }).padding(vertical = Sp.x8),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    weekLabels[d - 1], color = fg, fontSize = 12.sp,
                    fontWeight = if (on || d == today) FontWeight.SemiBold else FontWeight.Normal,
                )
                Spacer(Modifier.height(2.dp))
                // 当天有几部。**0 部画一个点,不写「0」** —— 写 0 会被读成「今天停播」
                val n = counts[d] ?: 0
                if (n > 0) Text("$n", color = fg.copy(alpha = .75f), fontSize = 10.sp)
                else Box(
                    Modifier.size(3.dp).clip(RoundedCornerShape(R.pill))
                        .background(fg.copy(alpha = .3f))
                )
            }
        }
    }
}

@Composable
private fun AirCard(a: Air, index: Int) {
    val c = Lp.colors
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(a.title) {
        kotlinx.coroutines.delay((index.coerceAtMost(8) * 28).toLong())
        shown = true
    }
    val t by animateFloatAsState(
        if (shown) 1f else 0f, lpTween(T.T6, LpEasing.emphasizedDecelerate), label = "airIn")
    Row(
        Modifier.fillMaxWidth()
            .graphicsLayer { alpha = t; translationY = (1f - t) * 28f }
            .padding(horizontal = Sp.x16, vertical = Sp.x6),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // 时刻单独一列:一列时间读起来是「时刻表」,混进标题行读起来只是个标签
        Text(
            a.hhmm ?: "待定", Modifier.width(52.dp),
            color = if (a.hhmm != null) c.acc else c.fg3,
            fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
        )
        NetImage(a.image, null, Modifier.size(56.dp, 78.dp))
        Spacer(Modifier.width(Sp.x12))
        Column(Modifier.weight(1f)) {
            // ★ 标题不许单行截断(截成「…」= 显示不全),放开完整换行
            Body(a.title)
            a.rating?.takeIf { it > 0 }?.let {
                Dim3("★ %.1f".format(it), Modifier.padding(top = 2.dp))
            }
        }
    }
}

/**
 * ISO8601 → 本地 `HH:MM`。取不到就是 null。
 *
 * ★ Bangumi 官方 API **不给时刻**,靠 bangumi-data 补;补不到的条目
 *   核心层发的就是 null —— 这里**不许编一个时间出来**。
 */
private fun localHhmm(iso: String?): String? {
    if (iso.isNullOrBlank()) return null
    return runCatching {
        java.time.Instant.parse(iso)
            .atZone(java.time.ZoneId.systemDefault())
            .format(java.time.format.DateTimeFormatter.ofPattern("HH:mm"))
    }.getOrNull()
}
