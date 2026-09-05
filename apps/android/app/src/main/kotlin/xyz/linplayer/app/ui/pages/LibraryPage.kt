package xyz.linplayer.app.ui.pages

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
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavController
import androidx.navigation.toRoute
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import xyz.linplayer.app.data.Block
import xyz.linplayer.app.data.Item
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.Page
import xyz.linplayer.app.data.block
import xyz.linplayer.app.data.strList
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.BlockBox
import xyz.linplayer.app.ui.components.Dim2
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.LpButton
import xyz.linplayer.app.ui.components.BtnKind
import xyz.linplayer.app.ui.components.LpDialog
import xyz.linplayer.app.ui.components.LpIconButton
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.components.MediaCard
import xyz.linplayer.app.ui.components.OptRow
import xyz.linplayer.app.ui.components.Skeleton
import xyz.linplayer.app.ui.components.rememberScrolled
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.Sp

/** 排序档位。「更新时间」≠「加入时间」—— 前者是这部剧**最近一集**入库的时间,追更要的是它。 */
private val SORTS = listOf(
    "加入时间" to "DateCreated",
    "更新时间" to "DateLastContentAdded",
    "上映日期" to "PremiereDate",
    "名称 A→Z" to "SortName",
    "年份" to "ProductionYear",
    "评分" to "CommunityRating",
)

/** 评分下限固定四档:服务端给的分级不是评分,**没有分面可列**。 */
private val RATINGS = listOf("不限" to 0, "9 分以上" to 9, "8 分以上" to 8, "7 分以上" to 7, "6 分以上" to 6)

private const val PAGE = 120

/**
 * 媒体库 + 筛选(U1.4)。
 *
 * ★ **排序一律走服务端。** 本地排只能排到已加载的那一页,翻页后顺序就乱了。
 * ★ 分页在核心层(offset/limit),UI 只负责**什么时候要下一页**(§10.2)。
 */
@Composable
fun LibraryPage(nav: NavController, entry: NavBackStackEntry) {
    val route = entry.toRoute<Route.Library>()
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val grid = rememberLazyGridState()

    var items by remember { mutableStateOf<List<Item>>(emptyList()) }
    var total by remember { mutableStateOf<Long?>(null) }
    var first by remember { mutableStateOf<Block<Unit>>(Block.Loading) }
    var loadingMore by remember { mutableStateOf(false) }
    var sort by remember { mutableStateOf(SORTS[0]) }
    var minRating by remember { mutableStateOf(RATINGS[0]) }
    var genre by remember { mutableStateOf<String?>(null) }
    var showFilter by remember { mutableStateOf(false) }
    var filters by remember { mutableStateOf<Block<List<String>>>(Block.Loading) }

    val hasFilter = genre != null || minRating.second > 0

    suspend fun fetch(offset: Int) {
        val a = buildMap<String, Any> {
            put("view_id", route.viewId)
            put("offset", offset); put("limit", PAGE)
            put("sort_by", sort.second)
            put("sort_order", if (sort.second == "SortName") "Ascending" else "Descending")
            if (minRating.second > 0) put("min_rating", minRating.second)
            genre?.let { put("genres", it) }
        }
        val r = app.block("emby.listItemsPage", args(*a.toList().toTypedArray()))
        when (r) {
            is Block.Ok -> {
                val p = Page.from(r.value)
                items = if (offset == 0) p.items else items + p.items
                total = p.total
                first = Block.Ok(Unit)
            }
            is Block.Fail -> if (offset == 0) first = r
            else -> Unit
        }
    }

    // 进库时**并发**拉分面与第一页条目
    LaunchedEffect(route.viewId, sort, minRating, genre) {
        first = Block.Loading; items = emptyList()
        coroutineScope {
            launch { fetch(0) }
            launch {
                filters = when (val r = app.block("emby.getFilters", args("parent_id" to route.viewId))) {
                    is Block.Ok -> Block.Ok(r.value.obj().strList("genres"))
                    is Block.Fail -> r
                    else -> Block.Loading
                }
            }
        }
    }

    // 分页触发:**不用 Paging 3**(分页在核心层)。看 layoutInfo + 一个防重入的闩
    val needMore by remember {
        derivedStateOf {
            val last = grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            items.isNotEmpty() && last >= items.size - 6
        }
    }
    LaunchedEffect(Unit) {
        snapshotFlow { needMore }.collect { want ->
            if (!want || loadingMore) return@collect
            if (total != null && items.size >= (total ?: 0)) return@collect
            loadingMore = true
            fetch(items.size)
            loadingMore = false
        }
    }

    LpScaffold(
        title = route.title,
        subtitle = total?.let { "$it 项" },
        onBack = { nav.popBackStack() },
        scrolled = rememberScrolled(grid),
        actions = {
            LpIconButton(LpIcons.search, "在这个库里搜") { nav.navigate(Route.Search(route.viewId)) }
            LpIconButton(LpIcons.filter, "筛选与排序") { showFilter = true }
        },
    ) { pad ->
        Column(Modifier.fillMaxSize()) {
            // 筛选条:当前生效的筛选画成 chip,**保留着让用户能退回去**
            if (hasFilter) Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                    .padding(horizontal = Sp.x16, vertical = Sp.x8),
                horizontalArrangement = Arrangement.spacedBy(Sp.x8),
            ) {
                genre?.let { Chip(it, true) { genre = null } }
                if (minRating.second > 0) Chip(minRating.first, true) { minRating = RATINGS[0] }
            }

            BlockBox(first, onRetry = { scope.launch { fetch(0) } },
                skeleton = { GridSkeleton(pad) }) {
                if (items.isEmpty()) {
                    // 空态区分三种:这里是「被筛掉了」
                    EmptyState(
                        if (hasFilter) "当前筛选没有结果" else "这个库还没有内容",
                        if (hasFilter) "把条件放宽一点,或者清除筛选。" else "服务器上这个库是空的。",
                        actionLabel = if (hasFilter) "清除筛选" else null,
                        onAction = if (hasFilter) ({ genre = null; minRating = RATINGS[0] }) else null,
                    )
                } else LazyVerticalGrid(
                    GridCells.Adaptive(112.dp), Modifier.fillMaxSize(), grid,
                    contentPadding = PaddingValues(
                        start = Sp.x16, end = Sp.x16, top = Sp.x8,
                        bottom = pad.calculateBottomPadding() + Sp.x12,
                    ),
                    horizontalArrangement = Arrangement.spacedBy(Sp.x10),
                    verticalArrangement = Arrangement.spacedBy(Sp.x16),
                ) {
                    items(items, key = { it.id }, contentType = { "poster" }) { it2 ->
                        MediaCard(
                            it2, app.imageUrl(it2.id, "Primary", 330),
                            { nav.navigate(Route.Detail(it2.id, it2.type)) },
                            Modifier.fillMaxWidth(),
                            menu = cardActions(app, scope, it2),
                        )
                    }
                }
            }
        }
    }

    if (showFilter) LpDialog({ showFilter = false }, "筛选与排序") {
        Column(Modifier.heightIn(max = 460.dp).verticalScroll(rememberScrollState())) {
            SectionLabel("排序")
            SORTS.forEach { s ->
                OptRow(s.first, { sort = s; showFilter = false }, selected = s == sort)
            }
            SectionLabel("评分下限")
            RATINGS.forEach { r ->
                OptRow(r.first, { minRating = r; showFilter = false }, selected = r == minRating)
            }
            SectionLabel("类型")
            when (val f = filters) {
                is Block.Loading -> Dim2("正在取分面…", Modifier.padding(Sp.x12))
                // 分面拉不到要**在筛选面板里明说**,不能静默变成「此库没有分面」
                is Block.Fail -> if (!f.isSilent) Dim2("分面取不到:${f.message}", Modifier.padding(Sp.x12))
                is Block.Ok -> if (f.value.isEmpty()) Dim2("这个库没有类型分面", Modifier.padding(Sp.x12))
                else f.value.forEach { g ->
                    OptRow(g, { genre = if (genre == g) null else g; showFilter = false },
                        selected = genre == g)
                }
            }
            Spacer(Modifier.height(Sp.x12))
            LpButton("关闭", { showFilter = false }, Modifier.fillMaxWidth(), BtnKind.Secondary)
        }
    }
}

@Composable
private fun SectionLabel(t: String) =
    Text(t, color = Lp.colors.fg3, fontSize = 12.sp,
        modifier = Modifier.padding(start = Sp.x12, top = Sp.x12, bottom = Sp.x4))

@Composable
private fun Chip(label: String, selected: Boolean, onClear: () -> Unit) {
    FilterChip(
        selected = selected, onClick = onClear, label = { Text(label, fontSize = 12.sp) },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = Lp.colors.accDim, selectedLabelColor = Lp.colors.acc,
        ),
    )
}

@Composable
private fun GridSkeleton(pad: PaddingValues) {
    LazyVerticalGrid(
        GridCells.Adaptive(112.dp), Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = Sp.x16, end = Sp.x16, top = Sp.x8,
            bottom = pad.calculateBottomPadding()),
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
