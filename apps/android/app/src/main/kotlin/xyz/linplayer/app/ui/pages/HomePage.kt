package xyz.linplayer.app.ui.pages

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
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
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import xyz.linplayer.app.data.Block
import xyz.linplayer.app.data.Item
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.Page
import xyz.linplayer.app.data.View
import xyz.linplayer.app.data.block
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.CardAction
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.ErrorState
import xyz.linplayer.app.ui.components.LpIconButton
import xyz.linplayer.app.ui.components.LpRow
import xyz.linplayer.app.ui.components.LpRowSkeleton
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.components.NetImage
import xyz.linplayer.app.ui.components.Skeleton
import xyz.linplayer.app.ui.components.pressable
import xyz.linplayer.app.ui.components.rememberScrolled
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp

/**
 * 首页(U1.3)。
 *
 * ☠ **各块并发拉取、各自渲染,不设屏障**(SPEC §8.0 第 6 步)——
 * 这是**契约不是优化**。实测串行等待比并发慢 5.5 倍,而用户会把它描述成
 * 「不秒加载」并归咎于动画。
 *
 * ☠ 媒体库最新轨**并发不串行**:八个库串行 = 八次往返。
 */
@Composable
fun HomePage(nav: NavController) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()

    var hero by remember { mutableStateOf<Block<List<Item>>>(Block.Loading) }
    var resume by remember { mutableStateOf<Block<List<Item>>>(Block.Loading) }
    var nextUp by remember { mutableStateOf<Block<List<Item>>>(Block.Loading) }
    var views by remember { mutableStateOf<Block<List<View>>>(Block.Loading) }
    var latest by remember { mutableStateOf<Map<String, List<Item>>>(emptyMap()) }
    var collections by remember { mutableStateOf<Block<List<Item>>>(Block.Loading) }
    var reload by remember { mutableStateOf(0) }

    // 每一块自己一个 launch:一块回来就画一块,谁也不等谁
    LaunchedEffect(reload) {
        launch { hero = app.block("emby.listRandom", args("limit" to 5)).map { Item.list(it) } }
        launch { resume = app.block("emby.listResume", args("limit" to 12)).map { Item.list(it) } }
        launch { nextUp = app.block("emby.listNextUp", args("limit" to 20)).map { Item.list(it) } }
        launch { collections = app.block("emby.listCollections").map { Item.list(it) } }
        launch {
            val v = app.block("emby.views").map { View.list(it) }
            views = v
            // 每个库一条「最新」轨,**并发**
            v.valueOrNull?.forEach { view ->
                launch {
                    val r = app.block("emby.listLatest", args("view_id" to view.id, "limit" to 16))
                    r.valueOrNull?.let { latest = latest + (view.id to Item.list(it)) }
                }
            }
        }
    }

    // 屏蔽条目后**整页重拉,不在 UI 逐个过滤** —— 首页手里有六份互不相干的列表副本,
    // 挨个过滤 = 把核心层的规则在 UI 再抄一遍,抄错还不报错
    LaunchedEffect(Unit) {
        app.invalidate.collect { if (it == "library" || it == "all") reload++ }
    }

    val open: (Item) -> Unit = { nav.navigate(Route.Detail(it.id, it.type)) }
    val menu: (Item) -> List<CardAction> = { cardActions(app, scope, it) }

    LpScaffold(scrolled = rememberScrolled(list), actions = {
        // 右上角两个入口:搜索与设置。底栏没有它们的位置(只有三个 Tab)
        LpIconButton(LpIcons.search, "搜索") { nav.navigate(Route.Search()) }
        LpIconButton(LpIcons.settings, "设置") { nav.navigate(Route.Settings) }
    }) { pad ->
        // 地基块失败才整页报错:只有 emby.views 是地基
        val v = views
        if (v is Block.Fail && !v.isSilent) {
            ErrorState(v.message, { reload++ }, Modifier.fillMaxSize())
            return@LpScaffold
        }

        LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
            item("hero") { Hero(hero, open) }

            item("resume") {
                RowBlock("继续观看", resume, thumb = true, app = app, open = open, menu = menu)
            }
            item("nextup") {
                RowBlock("接下来看", nextUp, thumb = false, app = app, open = open, menu = menu)
            }

            item("views") {
                when (v) {
                    is Block.Loading -> LpRowSkeleton("媒体库")
                    is Block.Ok -> if (v.value.isEmpty()) EmptyState(
                        "这个账号下没有媒体库", "在服务器上建一个库,或者换一台服务器试试。",
                    ) else ViewsRow(v.value, nav)
                    is Block.Fail -> Unit
                }
            }

            // 每个媒体库一条「最新」轨。未到的画骨架 —— 否则首屏下半是空的
            v.valueOrNull.orEmpty().forEach { view ->
                item("latest-${view.id}") {
                    val items = latest[view.id]
                    if (items == null) LpRowSkeleton("${view.name} · 最新", thumb = true)
                    else if (items.isNotEmpty()) LpRow(
                        "${view.name} · 最新", items,
                        { app.imageUrl(it.id, "Primary", 220) }, open, thumb = true, menu = menu,
                        onMore = { nav.navigate(Route.Library(view.id, view.name)) },
                    )
                }
            }

            item("collections") {
                RowBlock("合集", collections, thumb = false, app = app, open = open, menu = menu)
            }
            item("tail") { Spacer(Modifier.height(Sp.x26)) }
        }
    }
}

@Composable
private fun RowBlock(
    title: String,
    block: Block<List<Item>>,
    thumb: Boolean,
    app: xyz.linplayer.app.data.AppState,
    open: (Item) -> Unit,
    menu: (Item) -> List<CardAction>,
) {
    when (block) {
        is Block.Loading -> LpRowSkeleton(title, thumb)
        // 空轨整条不画:一条只有标题的空轨比没有它更让人困惑
        is Block.Ok -> if (block.value.isNotEmpty()) LpRow(
            title, block.value,
            { app.imageUrl(it.id, if (thumb) "Primary" else "Primary", if (thumb) 220 else 330) },
            open, thumb = thumb, menu = menu,
        )
        // 各块各自 catch:一个区块失败不整页报错
        is Block.Fail -> Unit
    }
}

/**
 * Hero:随机 5 条,两层图交叉淡入 + **Ken Burns 恒速缓推**。
 *
 * ★ 元信息只有「年份 · 评分 · 类型」—— **画质标签整个去掉**【用户定 2026-07-28】:
 *   「没人会为了参数去看一部烂片」。
 */
@Composable
private fun Hero(block: Block<List<Item>>, open: (Item) -> Unit) {
    val c = Lp.colors
    val h = 340.dp
    when (block) {
        is Block.Loading -> Skeleton(Modifier.fillMaxWidth().height(h).padding(Sp.x16))
        is Block.Fail -> Unit
        is Block.Ok -> {
            val items = block.value
            if (items.isEmpty()) return
            var idx by remember { mutableStateOf(0) }
            val it = items[idx % items.size]
            val app = LocalApp.current

            // Ken Burns:恒速缓推。**只动 scale**(§2.3 第 2 条)
            val t = rememberInfiniteTransition(label = "ken")
            val z by t.animateFloat(
                1f, 1.08f,
                infiniteRepeatable(tween(12000, easing = LinearEasing), RepeatMode.Reverse),
                label = "kenZ",
            )

            // ☠ 必须 clipToBounds:Ken Burns 把图放大到 1.08,而 NetImage 里的 clip
            //   排在 graphicsLayer **之后** —— 缩放先发生、裁剪后发生,放大出来的那一圈
            //   会溢出 Hero 的下边,在渐变之下露出一条硬边。
            Box(Modifier.fillMaxWidth().height(h).clipToBounds().pressable({ open(it) })) {
                NetImage(
                    app.imageUrl(it.id, "Backdrop", 720), null,
                    Modifier.fillMaxSize().graphicsLayer { scaleX = z; scaleY = z },
                    corner = 0.dp, scale = ContentScale.Crop,
                )
                Box(Modifier.fillMaxSize().background(
                    Brush.verticalGradient(0f to Color.Transparent, 0.55f to c.bg.copy(alpha = .55f), 1f to c.bg)
                ))
                Column(
                    Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(Sp.x16),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(it.name, color = c.fg, fontSize = 24.sp, fontWeight = FontWeight.Bold,
                        maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Spacer(Modifier.height(Sp.x6))
                    Dim3(listOfNotNull(
                        it.year?.toString(),
                        it.rating?.let { r -> "★ %.1f".format(r) },
                        it.genres.take(2).joinToString(" · ").takeIf { g -> g.isNotEmpty() },
                    ).joinToString("  ·  "))
                    Spacer(Modifier.height(Sp.x10))
                    Row(horizontalArrangement = Arrangement.spacedBy(Sp.x6)) {
                        items.indices.forEach { i ->
                            Box(Modifier.size(if (i == idx % items.size) 16.dp else 6.dp, 4.dp)
                                .clip(RoundedCornerShape(R.pill))
                                .background(if (i == idx % items.size) c.acc else c.line2)
                                .pressable({ idx = i }))
                        }
                    }
                }
            }
            // 自动换条目。交叉淡入靠 NetImage 自己的淡入(§2.2)
            LaunchedEffect(items) {
                while (true) { kotlinx.coroutines.delay(7000); idx++ }
            }
        }
    }
}

@Composable
private fun ViewsRow(views: List<View>, nav: NavController) {
    val c = Lp.colors
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().padding(start = Sp.x16, top = Sp.x12, bottom = Sp.x8)) {
            Text("媒体库", color = c.fg, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        }
        LazyRow(
            Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = Sp.x16),
            horizontalArrangement = Arrangement.spacedBy(Sp.x10),
        ) {
            items(views, key = { it.id }) { v ->
                Row(
                    Modifier.width(150.dp).clip(RoundedCornerShape(R.md)).background(c.s1)
                        .pressable({ nav.navigate(Route.Library(v.id, v.name)) })
                        .padding(Sp.x12),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(iconFor(v.collectionType), null, Modifier.size(20.dp), tint = c.acc)
                    Spacer(Modifier.width(Sp.x8))
                    Text(v.name, color = c.fg, fontSize = 13.sp, maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

private fun iconFor(type: String?) = when (type) {
    "movies" -> LpIcons.file
    "tvshows" -> LpIcons.version
    "boxsets" -> LpIcons.folder
    "music" -> LpIcons.audio
    else -> LpIcons.grid
}

internal fun args(vararg pairs: Pair<String, Any>): JsonObject =
    JsonObject(pairs.associate { (k, v) ->
        k to when (v) {
            is Number -> JsonPrimitive(v)
            is Boolean -> JsonPrimitive(v)
            else -> JsonPrimitive(v.toString())
        }
    })

private fun <T, Rn> Block<T>.map(f: (T) -> Rn): Block<Rn> = when (this) {
    is Block.Loading -> Block.Loading
    is Block.Fail -> this
    is Block.Ok -> Block.Ok(f(value))
}

/**
 * 卡片长按菜单。**这份定义是全站唯一的**(UI_MOBILE.md §4.3)——
 * 各页自己拼一套会长出「A 页有『标记已看』B 页没有」这种不一致。
 */
internal fun cardActions(
    app: xyz.linplayer.app.data.AppState,
    scope: kotlinx.coroutines.CoroutineScope,
    item: Item,
): List<CardAction> = listOf(
    CardAction(if (item.played) "标为未看" else "标为已看") {
        scope.launch {
            runCatching {
                app.call("emby.setPlayed", args("item_id" to item.id, "played" to !item.played))
            }.onFailure { app.report(it) }
        }
    },
    CardAction("收藏") {
        scope.launch {
            runCatching {
                app.call("emby.setFavorite", args("item_id" to item.id, "favorite" to true))
            }.onSuccess { app.toast("已加入收藏", xyz.linplayer.app.data.ToastKind.Ok) }
                .onFailure { app.report(it) }
        }
    },
    CardAction("下载") {
        scope.launch {
            runCatching { app.call("download.enqueue", args("item_id" to item.id)) }
                .onSuccess { app.toast("已加入下载队列", xyz.linplayer.app.data.ToastKind.Ok) }
                .onFailure { app.report(it) }
        }
    },
    CardAction("屏蔽这个条目", danger = true) {
        scope.launch {
            runCatching {
                app.call("emby.setBlocked",
                    args("item_id" to item.id, "name" to item.name, "blocked" to true))
            }.onFailure { app.report(it) }
        }
    },
)
