package xyz.linplayer.app.ui.pages

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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
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
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.strList
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.BlockBox
import xyz.linplayer.app.ui.components.BtnKind
import xyz.linplayer.app.ui.components.Dim2
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.GlassIcon
import xyz.linplayer.app.ui.components.Kicker
import xyz.linplayer.app.ui.components.LpButton
import xyz.linplayer.app.ui.components.LpDialog
import xyz.linplayer.app.ui.components.LpImmersive
import xyz.linplayer.app.ui.components.MediaCard
import xyz.linplayer.app.ui.components.NetImage
import xyz.linplayer.app.ui.components.OptRow
import xyz.linplayer.app.ui.components.Skeleton
import xyz.linplayer.app.ui.components.ToneChip
import xyz.linplayer.app.ui.components.bleed
import xyz.linplayer.app.ui.components.dissolve
import xyz.linplayer.app.ui.components.toneScene
import xyz.linplayer.app.ui.theme.Dim
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.Sp
import xyz.linplayer.app.ui.theme.rememberTone

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
 * 媒体库 + 筛选(U1.4)。版式照草稿 02:**库头也取色**。
 *
 * ★ 「动画」和「电影」两个库进去颜色就不一样 —— 库有了身份,而这只要一张图和一次取色。
 * ★ **排序一律走服务端。** 本地排只能排到已加载的那一页,翻页后顺序就乱了。
 * ★ 分页在核心层(offset/limit),UI 只负责**什么时候要下一页**(§10.2)。
 */
@Composable
fun LibraryPage(nav: NavController, entry: NavBackStackEntry) {
    val route = entry.toRoute<Route.Library>()
    val app = LocalApp.current
    val c = Lp.colors
    val scope = rememberCoroutineScope()
    val grid = rememberLazyGridState()

    // ★ 键必须带 viewId —— 库 A 和库 B 是两页,共用一个键会串数据
    val ck = "lib.${route.viewId}"
    var items by xyz.linplayer.app.data.keepState<List<Item>>("$ck.items") { emptyList() }
    var total by xyz.linplayer.app.data.keepState<Long?>("$ck.total") { null }
    var first by xyz.linplayer.app.data.keepState<Block<Unit>>("$ck.first") { Block.Loading }
    var loadingMore by remember { mutableStateOf(false) }
    // 排序/筛选也留住:返回后筛选条被重置回默认,和「白重拉一次」一样恼人
    var sort by xyz.linplayer.app.data.keepState("$ck.sort") { SORTS[0] }
    var minRating by xyz.linplayer.app.data.keepState("$ck.rating") { RATINGS[0] }
    var genre by xyz.linplayer.app.data.keepState<String?>("$ck.genre") { null }
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
        when (val r = app.block("emby.listItemsPage", args(*a.toList().toTypedArray()))) {
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
        // 已经有这一页的结果就别重拉(筛选变了会带着新的 key 重进这里)
        if (items.isNotEmpty() && first is Block.Ok) return@LaunchedEffect
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

    // 库头那张图和整页的底色都取自**这个库里最新的一部**
    val face = items.firstOrNull()
    val tone = rememberTone(app.imageUrl(face?.id, "Primary", 330), c.acc.copy(alpha = .9f))

    LpImmersive(bar = {
        GlassIcon(LpIcons.back, "返回") { nav.popBackStack() }
        Spacer(Modifier.weight(1f))
        GlassIcon(LpIcons.search, "在这个库里搜") { nav.navigate(Route.Search(route.viewId)) }
        GlassIcon(LpIcons.sort, "筛选与排序") { showFilter = true }
    }) { pad ->
        Box(Modifier.fillMaxSize().background(toneScene(tone, c.bg, depth = 0.62f))) {
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
                    GridCells.Fixed(3), Modifier.fillMaxSize(), grid,
                    contentPadding = PaddingValues(
                        start = Sp.x16, end = Sp.x16, bottom = pad.calculateBottomPadding()),
                    horizontalArrangement = Arrangement.spacedBy(Sp.x10),
                    verticalArrangement = Arrangement.spacedBy(Sp.x12),
                ) {
                    // ★ 库头要**铺到屏幕两边**,所以得钻出网格的 16dp 内边距
                    item("head", span = { GridItemSpan(maxLineSpan) }) {
                        Box(Modifier.bleed(Sp.x16)) {
                            LibraryHead(app, route.title, face, total, grid)
                        }
                    }
                    item("chips", span = { GridItemSpan(maxLineSpan) }) {
                        FilterBar(
                            sort = sort.first, genre = genre, rating = minRating,
                            onOpen = { showFilter = true },
                            onClearGenre = { genre = null },
                            onClearRating = { minRating = RATINGS[0] },
                        )
                    }
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

/**
 * 库头(草稿 02)。
 *
 * ★ 图从 y=0 铺起,下沿溶进取色底 —— 和详情页同一套手法。
 * ★ 三级标题:眉标「媒体库」→ 库名 31sp → 统计一行。
 * ★ 往下滚时整块图上移淡出(M3 的折叠大标题,但折的是**一整块图**不是一行字)。
 */
@Composable
private fun LibraryHead(
    app: xyz.linplayer.app.data.AppState,
    title: String,
    face: Item?,
    total: Long?,
    grid: androidx.compose.foundation.lazy.grid.LazyGridState,
) {
    val c = Lp.colors
    val h = Dim.coverLib
    Box(Modifier.fillMaxWidth().height(h)) {
        Box(
            Modifier.fillMaxSize()
                .graphicsLayer {
                    val off = if (grid.firstVisibleItemIndex == 0)
                        grid.firstVisibleItemScrollOffset.toFloat() else h.toPx()
                    translationY = off * 0.40f
                    alpha = (1f - off / (h.toPx() * 0.9f)).coerceIn(0f, 1f)
                }
                .dissolve(0.52f, 0.99f)
        ) {
            NetImage(app.imageUrl(face?.id, "Backdrop", 720), null, Modifier.fillMaxSize(), 0.dp)
            Box(
                Modifier.fillMaxSize().background(
                    Brush.verticalGradient(
                        0.00f to Color.Black.copy(alpha = .50f),
                        0.34f to Color.Transparent,
                        1.00f to Color.Black.copy(alpha = .45f),
                    )
                )
            )
        }
        Column(
            Modifier.align(Alignment.BottomStart)
                .padding(start = Sp.x16, end = Sp.x16, bottom = Sp.x12)
        ) {
            Kicker("媒体库", color = c.fg2)
            Spacer(Modifier.height(Sp.x4))
            Text(title, color = c.fg, fontSize = 31.sp, fontWeight = FontWeight.Bold,
                lineHeight = 34.sp, maxLines = 2)
            // ☠ 只写服务端真给了的数。**「已看 132 / 未看 286」算不出来就不写** ——
            //    拿已加载那一页去算,翻页之后数字会自己变,那是界面在撒谎
            if (total != null) {
                Spacer(Modifier.height(Sp.x6))
                Text("$total 部", color = c.fg.copy(alpha = .72f), fontSize = 12.sp)
            }
        }
    }
}

/** 筛选条。**chip 没有描边**:未选中是一层白 10% 填充,选中才是琥珀。 */
@Composable
private fun FilterBar(
    sort: String,
    genre: String?,
    rating: Pair<String, Int>,
    onOpen: () -> Unit,
    onClearGenre: () -> Unit,
    onClearRating: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .padding(top = Sp.x12, bottom = Sp.x4),
        horizontalArrangement = Arrangement.spacedBy(Sp.x8),
    ) {
        ToneChip(sort, on = false, onClick = onOpen)
        genre?.let { ToneChip("$it ×", on = true, onClick = onClearGenre) }
        if (rating.second > 0) ToneChip("${rating.first} ×", on = true, onClick = onClearRating)
        ToneChip("筛选", on = false, onClick = onOpen)
    }
}

@Composable
private fun SectionLabel(t: String) =
    Text(t, color = Lp.colors.fg3, fontSize = 12.sp,
        modifier = Modifier.padding(start = Sp.x12, top = Sp.x12, bottom = Sp.x4))

@Composable
private fun GridSkeleton(pad: PaddingValues) {
    LazyVerticalGrid(
        GridCells.Fixed(3), Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = Sp.x16, end = Sp.x16, top = Dim.coverLib,
            bottom = pad.calculateBottomPadding()),
        horizontalArrangement = Arrangement.spacedBy(Sp.x10),
        verticalArrangement = Arrangement.spacedBy(Sp.x12),
    ) {
        items(List(12) { it }) {
            Column {
                Skeleton(Modifier.fillMaxWidth().aspectRatio(2f / 3f))
                Spacer(Modifier.height(Sp.x6))
                Skeleton(Modifier.fillMaxWidth(0.8f).height(12.dp))
            }
        }
    }
}
