package xyz.linplayer.app.ui.pages

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavController
import androidx.navigation.toRoute
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.launch
import xyz.linplayer.app.data.Block
import xyz.linplayer.app.data.Item
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.Page
import xyz.linplayer.app.data.block
import xyz.linplayer.app.data.str
import xyz.linplayer.app.data.strList
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.ErrorState
import xyz.linplayer.app.ui.components.H2
import xyz.linplayer.app.ui.components.LpField
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.components.MediaCard
import xyz.linplayer.app.ui.components.LpRow
import xyz.linplayer.app.ui.components.Skeleton
import xyz.linplayer.app.ui.components.pressable
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp

/**
 * 搜索(U1.7)。三个入口共用这一页:首页右上角 / 聚合页顶部 / 库内搜索(带 `viewId`)。
 *
 * 三条开关规则【用户定】:
 * 1. **「包括集」默认关。** 搜「凡人」应该先看到那部剧,不是被 200 集分集淹掉。
 * 2. **「包括集」一拨就重搜;「聚合」一拨不重搜。** 聚合一次打 N 台,来回拨两下就是 2N 个请求;
 *    而「包括集」只多打一次当前服,**不重搜才是坏的**。
 * 3. **库内搜索与聚合互斥。** 有搜索范围时聚合开关**整个不出现**。
 */
@OptIn(FlowPreview::class)
@Composable
fun SearchPage(nav: NavController, entry: NavBackStackEntry) {
    val route = entry.toRoute<Route.Search>()
    val app = LocalApp.current
    val scope = rememberCoroutineScope()

    var q by remember { mutableStateOf("") }
    var includeEpisodes by remember { mutableStateOf(false) }
    var aggregate by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<Block<List<Item>>?>(null) }
    /** 聚合的分组结果:服务器名 → 条目。流式来的,**收到 partial 就画**。 */
    var groups by remember { mutableStateOf<Map<String, List<Item>>>(emptyMap()) }
    var failedServers by remember { mutableStateOf<List<String>>(emptyList()) }
    var history by remember { mutableStateOf<List<String>>(emptyList()) }
    val focus = remember { FocusRequester() }

    LaunchedEffect(Unit) { focus.requestFocus() }

    // 防抖 250ms 后打**服务端**搜索。**不许**「拉全部库 → 全量拉条目 → 本地过滤」
    LaunchedEffect(Unit) {
        snapshotFlow { Triple(q.trim(), includeEpisodes, aggregate) }
            .debounce(250)
            .collect { (text, eps, agg) ->
                if (text.length < 1) { result = null; groups = emptyMap(); return@collect }
                result = Block.Loading; groups = emptyMap(); failedServers = emptyList()
                if (agg && route.viewId == null) {
                    // 聚合是**流式**的:每台服务器各自回各自渲染
                    val r = runCatching {
                        app.call("emby.aggregateSearch", args(
                            "query" to text,
                            // ★ 类型必须显式传:不传时服务端默认包含分集 =「永远包括集」
                            "types" to if (eps) "Series,Movie,Episode" else "Series,Movie",
                        ), onPartial = { p ->
                            val o = (p as? kotlinx.serialization.json.JsonObject)
                            val name = o.str("server") ?: "服务器"
                            groups = groups + (name to Item.list(o?.get("items")))
                        })
                    }
                    result = r.fold({ v ->
                        // result 携带的是汇总(失败哪些),不是数据的重复
                        failedServers = (v as? kotlinx.serialization.json.JsonObject).strList("failed")
                        Block.Ok(emptyList())
                    }, { Block.Fail("E_INTERNAL", it.message ?: "搜索失败") })
                } else {
                    val a = buildMap<String, Any> {
                        put("query", text)
                        put("types", if (eps) "Series,Movie,Episode" else "Series,Movie")
                        route.viewId?.let { put("view_id", it) }
                    }
                    result = when (val r = app.block("emby.search", args(*a.toList().toTypedArray()))) {
                        is Block.Ok -> Block.Ok(Page.from(r.value).items)
                        is Block.Fail -> r
                        else -> Block.Loading
                    }
                }
            }
    }

    LpScaffold(onBack = { nav.popBackStack() }, scrolled = true, title = " ") { pad ->
        Column(Modifier.fillMaxSize().imePadding()) {
            LpField(q, { q = it }, if (route.viewId != null) "在这个库里搜" else "搜片名、剧名或演员",
                Modifier.padding(horizontal = Sp.x16).focusRequester(focus))

            Row(Modifier.padding(horizontal = Sp.x16, vertical = Sp.x8),
                horizontalArrangement = Arrangement.spacedBy(Sp.x8)) {
                Toggle("包括集", includeEpisodes) { includeEpisodes = it }
                // 库内搜索与聚合互斥:有搜索范围时这个开关**整个不出现**
                if (route.viewId == null) Toggle("聚合跨服", aggregate) { aggregate = it }
            }

            val r = result
            when {
                r == null -> if (history.isEmpty()) EmptyState(
                    "搜片名、剧名或演员", "会搜当前服务器;打开「聚合跨服」可以一次搜所有已登录的服务器。",
                    LpIcons.search,
                ) else HistoryList(history) { q = it }

                r is Block.Loading -> Column(Modifier.padding(Sp.x16)) {
                    repeat(3) {
                        Skeleton(Modifier.fillMaxWidth().height(72.dp))
                        Spacer(Modifier.height(Sp.x10))
                    }
                }

                r is Block.Fail -> ErrorState(r.message)

                aggregate && route.viewId == null -> LazyColumn(Modifier.fillMaxSize(),
                    contentPadding = pad) {
                    groups.forEach { (server, items) ->
                        item(server) {
                            // ★ 跨服结果**不给长按菜单** —— 收藏 / 标已看是对当前活跃服务器写的,
                            //   对着别的服的条目按下去会写错地方,而且不报错
                            LpRow(server, items, { app.imageUrl(it.id, "Primary", 330) },
                                { nav.navigate(Route.Detail(it.id, it.type)); remember0(history) { history = it } },
                                menu = null)
                        }
                    }
                    // 半失败(一路 429、一路回空)**不能吞成「没搜到」**,要说清哪台失败了
                    if (failedServers.isNotEmpty()) item("failed") {
                        Dim3("这些服务器没搜成:${failedServers.joinToString("、")}",
                            Modifier.padding(Sp.x16), maxLines = 3)
                    }
                    if (groups.isEmpty()) item("none") {
                        EmptyState("「${q.trim()}」没搜到东西", "换个关键词试试 —— 有些片源用的是英文原名。")
                    }
                }

                else -> {
                    val items = (r as Block.Ok).value
                    if (items.isEmpty()) EmptyState(
                        "「${q.trim()}」没搜到东西",
                        "检查一下有没有打错字,或者换个关键词 —— 有些片源用的是英文原名。",
                    ) else {
                        // 分集**单独一栏横版**;剧和影走网格
                        val eps = items.filter { it.isEpisode }
                        val rest = items.filterNot { it.isEpisode }
                        LazyColumn(Modifier.fillMaxSize(), contentPadding = pad) {
                            if (rest.isNotEmpty()) item("grid") {
                                LazyVerticalGridInline(rest) { picked ->
                                    // 历史只在**用户真的点开了某个结果**时才记 ——
                                    // 跟着防抖记会把「阿」「阿凡」「阿凡达」全记进去
                                    val t = q.trim()
                                    if (t.isNotEmpty()) history = (listOf(t) + history).distinct().take(8)
                                    nav.navigate(Route.Detail(picked.id, picked.type))
                                }
                            }
                            if (eps.isNotEmpty()) item("eps") {
                                LpRow("分集", eps, { app.imageUrl(it.id, "Primary", 220) },
                                    { nav.navigate(Route.Detail(it.id, "Episode")) }, thumb = true,
                                    menu = { cardActions(app, scope, it) })
                            }
                        }
                    }
                }
            }
        }
    }
}

private inline fun remember0(list: List<String>, set: (List<String>) -> Unit) = Unit

@Composable
private fun LazyVerticalGridInline(items: List<Item>, onOpen: (Item) -> Unit) {
    val app = LocalApp.current
    val rows = (items.size + 2) / 3
    Column(Modifier.fillMaxWidth().padding(horizontal = Sp.x16),
        verticalArrangement = Arrangement.spacedBy(Sp.x16)) {
        repeat(rows) { r ->
            Row(horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
                (0 until 3).forEach { cIdx ->
                    val i = r * 3 + cIdx
                    if (i < items.size) {
                        val it2 = items[i]
                        MediaCard(it2, app.imageUrl(it2.id, "Primary", 330), { onOpen(it2) },
                            Modifier.weight(1f), menu = null)
                    } else Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun HistoryList(history: List<String>, onPick: (String) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(Sp.x16)) {
        H2("最近搜过")
        Spacer(Modifier.height(Sp.x8))
        history.forEach {
            Text(it, Modifier.fillMaxWidth().pressable({ onPick(it) }).padding(vertical = Sp.x12),
                color = Lp.colors.fg2, fontSize = 14.sp)
        }
    }
}

@Composable
private fun Toggle(label: String, on: Boolean, onChange: (Boolean) -> Unit) {
    val c = Lp.colors
    Text(
        label,
        Modifier.clip(RoundedCornerShape(R.pill))
            .background(if (on) c.accDim else c.s2)
            .pressable({ onChange(!on) })
            .padding(horizontal = Sp.x12, vertical = Sp.x8),
        color = if (on) c.acc else c.fg2, fontSize = 12.sp,
    )
}
