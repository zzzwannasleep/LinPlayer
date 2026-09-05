package xyz.linplayer.app.ui.pages

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import xyz.linplayer.app.data.Block
import xyz.linplayer.app.data.Item
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.Page
import xyz.linplayer.app.data.ToastKind
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
import xyz.linplayer.app.ui.components.BtnKind
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.Hairline
import xyz.linplayer.app.ui.components.LpButton
import xyz.linplayer.app.ui.components.LpCell
import xyz.linplayer.app.ui.components.LpIconButton
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.components.LpTag
import xyz.linplayer.app.ui.components.MediaCard
import xyz.linplayer.app.ui.components.NetImage
import xyz.linplayer.app.ui.components.Panel
import xyz.linplayer.app.ui.components.Skeleton
import xyz.linplayer.app.ui.components.StepperRow
import xyz.linplayer.app.ui.components.pressable
import xyz.linplayer.app.ui.components.rememberScrolled
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp

/** 收藏(U1.9a)。 */
@Composable
fun FavoritesPage(nav: NavController) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val grid = rememberLazyGridState()
    var block by remember { mutableStateOf<Block<List<Item>>>(Block.Loading) }
    var reload by remember { mutableStateOf(0) }

    LaunchedEffect(reload) {
        block = when (val r = app.block("emby.listFavorites")) {
            is Block.Ok -> Block.Ok(Page.from(r.value).items)
            is Block.Fail -> r
            else -> Block.Loading
        }
    }
    LaunchedEffect(Unit) { app.invalidate.collect { if (it == "library" || it == "all") reload++ } }

    LpScaffold("收藏", onBack = { nav.popBackStack() }, scrolled = rememberScrolled(grid)) { pad ->
        BlockBox(block, { reload++ }, skeleton = { GridSkel(pad) }) { items ->
            if (items.isEmpty()) EmptyState(
                "还没有收藏任何内容",
                "在任意封面上长按 → 收藏,或者在详情页点右上角那颗心。收藏会跟着服务器走。",
                LpIcons.heart,
            ) else LazyVerticalGrid(
                GridCells.Adaptive(112.dp), Modifier.fillMaxSize(), grid,
                contentPadding = PaddingValues(Sp.x16, Sp.x8, Sp.x16, pad.calculateBottomPadding()),
                horizontalArrangement = Arrangement.spacedBy(Sp.x10),
                verticalArrangement = Arrangement.spacedBy(Sp.x16),
            ) {
                items(items, key = { it.id }) {
                    MediaCard(it, app.imageUrl(it.id, "Primary", 330),
                        { nav.navigate(Route.Detail(it.id, it.type)) },
                        Modifier.fillMaxWidth(), menu = cardActions(app, scope, it))
                }
            }
        }
    }
}

/**
 * 下载(U1.12)。
 *
 * ★ **「清除已完成」只清记录,不删文件**;每条右边那个 ✕ 才是删文件。
 *   两个语义正相反,**别合并成一个命令**。
 * ★ 并发数**只读不灌**:核心层持久化,UI 读回来显示。
 */
@Composable
fun DownloadsPage(nav: NavController) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()

    data class Task(val id: String, val title: String, val state: String,
                    val progress: Float, val speed: String)

    var tasks by remember { mutableStateOf<List<Task>>(emptyList()) }
    var threads by remember { mutableStateOf(2.0) }
    var loaded by remember { mutableStateOf(false) }

    fun parse(e: kotlinx.serialization.json.JsonElement?): List<Task> = e.arr().mapNotNull {
        val o = it.obj() ?: return@mapNotNull null
        val total = o.long("total_bytes") ?: 0
        val done = o.long("bytes") ?: 0
        Task(
            o.str("id") ?: return@mapNotNull null,
            o.str("title") ?: o.str("name") ?: "下载任务",
            o.str("state") ?: "running",
            if (total > 0) (done.toDouble() / total).toFloat().coerceIn(0f, 1f) else 0f,
            o.long("speed")?.let { s -> "%.1f MB/s".format(s / 1024.0 / 1024.0) } ?: "",
        )
    }

    LaunchedEffect(Unit) {
        val r = runCatching { app.call("download.list") }.getOrNull()
        tasks = parse(r)
        threads = (r.obj().long("threads") ?: 2L).toDouble()
        loaded = true
        // 订阅进度事件而不是轮询:轮询是「每秒一次全表」,事件是「变了才来」
        app.core.events.collect { ev ->
            if (ev.name == "download.progress") {
                tasks = parse(runCatching { app.call("download.list") }.getOrNull())
            }
        }
    }

    LpScaffold("下载", onBack = { nav.popBackStack() }, scrolled = rememberScrolled(list),
        actions = {
            LpIconButton(LpIcons.trash, "清除已完成") {
                scope.launch {
                    runCatching { app.call("download.clearCompleted") }
                        .onSuccess { app.toast("已清除完成的记录(文件保留)", ToastKind.Ok) }
                        .onFailure { app.report(it) }
                }
            }
        }) { pad ->
        Column(Modifier.fillMaxSize()) {
            Panel(Modifier.padding(Sp.x16)) {
                StepperRow("同时下载", threads, 1.0, 4.0, 1.0, { v ->
                    threads = v
                    scope.launch {
                        runCatching { app.call("download.setThreads", args("threads" to v.toInt())) }
                            .onFailure { app.report(it) }
                    }
                }, sub = "线程越多不一定越快,看服务端给不给", fmt = { it.toInt().toString() })
            }
            if (!loaded) Skeleton(Modifier.fillMaxWidth().height(72.dp).padding(Sp.x16))
            else if (tasks.isEmpty()) EmptyState(
                "下载队列是空的",
                "详情页的长按菜单里可以整部或单集入队。下好的文件离线也能播。",
                LpIcons.download,
            ) else LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
                items(tasks, key = { it.id }) { t ->
                    Panel(Modifier.padding(horizontal = Sp.x16, vertical = Sp.x6)) {
                        Column(Modifier.padding(Sp.x16)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Body(t.title, maxLines = 2)
                                    Dim3("${(t.progress * 100).toInt()}%  ${t.speed}",
                                        Modifier.padding(top = Sp.x2))
                                }
                                LpIconButton(
                                    if (t.state == "paused") LpIcons.play else LpIcons.pause,
                                    if (t.state == "paused") "继续" else "暂停",
                                ) {
                                    scope.launch {
                                        runCatching {
                                            app.call(
                                                if (t.state == "paused") "download.resume" else "download.pause",
                                                args("id" to t.id))
                                        }.onFailure { app.report(it) }
                                    }
                                }
                                LpIconButton(LpIcons.close, "删除任务与文件") {
                                    scope.launch {
                                        runCatching { app.call("download.remove", args("id" to t.id)) }
                                            .onFailure { app.report(it) }
                                    }
                                }
                            }
                            Spacer(Modifier.height(Sp.x8))
                            Box(Modifier.fillMaxWidth().height(3.dp)
                                .clip(RoundedCornerShape(R.pill)).background(Lp.colors.s3)) {
                                Box(Modifier.fillMaxWidth(t.progress).fillMaxSize()
                                    .background(Lp.colors.acc))
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * 排行榜(U1.14a)。
 *
 * ★ 取数失败必须**向上报错,不许吞成空表** —— 空表和失败在界面上长得一样,
 *   但一个该重试一个不该。
 * ★ **根本没有「排行榜开关」这个东西** —— 别去找,也别加。
 */
@Composable
fun RankingPage(nav: NavController) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()
    var cats by remember { mutableStateOf<List<Pair<String, String>>>(emptyList()) }
    var cur by remember { mutableStateOf<String?>(null) }
    var block by remember { mutableStateOf<Block<List<Item>>>(Block.Loading) }

    LaunchedEffect(Unit) {
        cats = runCatching { app.call("emby.rankingCategories") }.getOrNull().arr()
            .mapNotNull {
                val o = it.obj() ?: return@mapNotNull null
                (o.str("id") ?: return@mapNotNull null) to (o.str("name") ?: "榜单")
            }
        cur = cats.firstOrNull()?.first
    }
    LaunchedEffect(cur) {
        val id = cur ?: return@LaunchedEffect
        block = Block.Loading
        block = when (val r = app.block("emby.rankingFetch", args("category_id" to id))) {
            is Block.Ok -> Block.Ok(Page.from(r.value).items)
            is Block.Fail -> r
            else -> Block.Loading
        }
    }

    LpScaffold("排行榜", onBack = { nav.popBackStack() }, scrolled = rememberScrolled(list)) { pad ->
        Column(Modifier.fillMaxSize()) {
            if (cats.size > 1) Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                    .padding(horizontal = Sp.x16, vertical = Sp.x8),
                horizontalArrangement = Arrangement.spacedBy(Sp.x8),
            ) {
                cats.forEach { (id, name) ->
                    val on = id == cur
                    Text(name, Modifier.clip(RoundedCornerShape(R.pill))
                        .background(if (on) Lp.colors.acc else Lp.colors.s2)
                        .pressable({ cur = id }).padding(horizontal = Sp.x16, vertical = Sp.x8),
                        color = if (on) Lp.colors.accFg else Lp.colors.fg2, fontSize = 13.sp)
                }
            }
            BlockBox(block, { cur = cur }) { items ->
                if (items.isEmpty()) EmptyState("暂无榜单数据", "这个榜单现在是空的。", LpIcons.trophy)
                else LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
                    itemsIndexed(items, key = { _, x -> x.id }) { i, item ->
                        Row(Modifier.fillMaxWidth()
                            .pressable({ nav.navigate(Route.Detail(item.id, item.type)) })
                            .padding(horizontal = Sp.x16, vertical = Sp.x8),
                            verticalAlignment = Alignment.CenterVertically) {
                            Text("${i + 1}", Modifier.width(28.dp),
                                color = if (i < 3) Lp.colors.acc else Lp.colors.fg3, fontSize = 15.sp)
                            NetImage(app.imageUrl(item.id, "Primary", 220), null, Modifier.size(64.dp, 96.dp))
                            Spacer(Modifier.width(Sp.x12))
                            Column(Modifier.weight(1f)) {
                                Body(item.cardTitle, maxLines = 2)
                                item.cardSub?.let { s -> Dim3(s, Modifier.padding(top = Sp.x2)) }
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * 追剧日历(U1.14b · 付费)。手机竖屏默认「本日」视图。
 *
 * ☠ **赞助地址必须来自 `system.afdianSponsorUrl`,不许硬编。**
 * 2026-07-19 就栽在这:UI 里写死了一个凭空猜的主页,功能看着完全正常,
 * 而**赞助收益是零**。收款地址只能有一份。
 */
@Composable
fun CalendarPage(nav: NavController) {
    val app = LocalApp.current
    val list = rememberLazyListState()
    var today by remember { mutableStateOf<Block<List<Triple<String, String, String>>>>(Block.Loading) }
    var sponsorUrl by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        sponsorUrl = runCatching { app.call("system.afdianSponsorUrl") }
            .getOrNull().obj().str("url")
        today = when (val r = app.block("sync.bangumiCalendar")) {
            is Block.Ok -> Block.Ok(r.value.arr().flatMap { day ->
                val o = day.obj()
                o?.get("items").arr().mapNotNull {
                    val x = it.obj() ?: return@mapNotNull null
                    Triple(
                        x.str("name_cn")?.takeIf { s -> s.isNotBlank() } ?: x.str("name") ?: return@mapNotNull null,
                        x.str("air_time") ?: "待定",
                        o.str("weekday") ?: "",
                    )
                }
            })
            is Block.Fail -> r
            else -> Block.Loading
        }
    }

    LpScaffold("追剧日历", onBack = { nav.popBackStack() }, scrolled = rememberScrolled(list)) { pad ->
        BlockBox(today, null) { rows ->
            if (rows.isEmpty()) EmptyState("今天没有放送", "放送表按上游时区(JST)分组,今天这一栏是空的。",
                LpIcons.calendar)
            else LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
                // 一条一行、按时间从早到晚、**待定沉底**
                val sorted = rows.sortedBy { if (it.second == "待定") "99:99" else it.second }
                items(sorted, key = { it.first + it.second }) { (name, time, day) ->
                    Row(Modifier.fillMaxWidth().padding(horizontal = Sp.x16, vertical = Sp.x10),
                        verticalAlignment = Alignment.CenterVertically) {
                        Text(time, Modifier.width(56.dp), color = Lp.colors.fg3, fontSize = 12.sp)
                        Column(Modifier.weight(1f)) {
                            // ★ 标题不许单行截断(截成「…」= 显示不全),放开完整换行
                            Body(name)
                            if (day.isNotBlank()) Dim3(day, Modifier.padding(top = Sp.x2))
                        }
                    }
                    Hairline(Modifier.padding(start = Sp.x16 + 56.dp))
                }
                if (sponsorUrl != null) item("sponsor") {
                    Dim3("追剧日历是付费功能。赞助后可解锁「我追的番」过滤。",
                        Modifier.padding(Sp.x16), maxLines = 3)
                }
            }
        }
    }
}

@Composable
private fun GridSkel(pad: PaddingValues) {
    LazyVerticalGrid(
        GridCells.Adaptive(112.dp), Modifier.fillMaxSize(),
        contentPadding = PaddingValues(Sp.x16, Sp.x8, Sp.x16, pad.calculateBottomPadding()),
        horizontalArrangement = Arrangement.spacedBy(Sp.x10),
        verticalArrangement = Arrangement.spacedBy(Sp.x16),
    ) {
        items(List(12) { it }) {
            Column {
                Skeleton(Modifier.fillMaxWidth().height(168.dp))
                Spacer(Modifier.height(Sp.x6))
                Skeleton(Modifier.fillMaxWidth(0.8f).height(12.dp))
            }
        }
    }
}
