package xyz.linplayer.app.ui.pages

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateDpAsState
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
import androidx.compose.foundation.lazy.LazyListState
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import xyz.linplayer.app.data.Account
import xyz.linplayer.app.data.Block
import xyz.linplayer.app.data.Item
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.View
import xyz.linplayer.app.data.block
import xyz.linplayer.app.data.keepState
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.CardAction
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.ErrorState
import xyz.linplayer.app.ui.components.GlassIcon
import xyz.linplayer.app.ui.components.LpImmersive
import xyz.linplayer.app.ui.components.LpRow
import xyz.linplayer.app.ui.components.LpRowSkeleton
import xyz.linplayer.app.ui.components.NetImage
import xyz.linplayer.app.ui.components.SectionTitle
import xyz.linplayer.app.ui.components.Skeleton
import xyz.linplayer.app.ui.components.pressable
import xyz.linplayer.app.ui.theme.Dim
import xyz.linplayer.app.ui.theme.LpEasing
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp
import xyz.linplayer.app.ui.theme.T
import xyz.linplayer.app.ui.theme.lpTween

/**
 * 首页(U1.3)。版式照草稿 01:**Hero 从 y=0 起铺,状态栏浮在图上**。
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

    /* ☠ 这几份数据以前是 `remember`,而 `remember` 的寿命是 composition ——
       点进任何一页再返回,首页**整个重拉一遍**(骨架闪一次、Hero 从第一张重来)。
       底栏的 saveState/restoreState 保得住滚动位置(rememberSaveable),保不住它们。 */
    var hero by keepState<Block<List<Item>>>("home.hero") { Block.Loading }
    var resume by keepState<Block<List<Item>>>("home.resume") { Block.Loading }
    var nextUp by keepState<Block<List<Item>>>("home.nextUp") { Block.Loading }
    var views by keepState<Block<List<View>>>("home.views") { Block.Loading }
    var latest by keepState<Map<String, List<Item>>>("home.latest") { emptyMap() }
    var collections by keepState<Block<List<Item>>>("home.collections") { Block.Loading }
    var serverName by keepState<String?>("home.server") { null }
    var reload by remember { mutableStateOf(0) }

    // 每一块自己一个 launch:一块回来就画一块,谁也不等谁。
    LaunchedEffect(reload) {
        if (reload == 0 && views is Block.Ok) return@LaunchedEffect
        launch { hero = app.block("emby.listRandom", args("limit" to 5)).map { Item.list(it) } }
        launch { resume = app.block("emby.listResume", args("limit" to 12)).map { Item.list(it) } }
        launch { nextUp = app.block("emby.listNextUp", args("limit" to 20)).map { Item.list(it) } }
        launch { collections = app.block("emby.listCollections").map { Item.list(it) } }
        // 顶栏那颗服务器 chip 上的名字。**本地账号表,不走网络**
        launch {
            serverName = Account.list(app.block("account.listAccounts").valueOrNull)
                .firstOrNull { it.isActive }?.name
        }
        launch {
            val v = app.block("emby.views").map { View.list(it) }
            views = v
            // 每个库一条「最新」轨,**并发**
            v.valueOrNull?.forEach { view ->
                launch {
                    val r = app.block("emby.listLatest", args("parent_id" to view.id, "limit" to 16))
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

    LpImmersive(bar = {
        ServerChip(serverName) { nav.navigate(Route.Servers) }
        Spacer(Modifier.weight(1f))
        GlassIcon(LpIcons.search, "搜索") { nav.navigate(Route.Search()) }
        GlassIcon(LpIcons.settings, "设置") { nav.navigate(Route.Settings) }
    }) { pad ->
        // 地基块失败才整页报错:只有 emby.views 是地基
        val v = views
        if (v is Block.Fail && !v.isSilent) {
            ErrorState(v.message, { reload++ }, Modifier.fillMaxSize())
            return@LpImmersive
        }

        LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
            item("hero") { Hero(hero, list, open) }

            // 顺序照 PC 端首页:Hero → 继续观看 → 接下来看 → 合集 → 各库最新
            item("resume") {
                RowBlock("继续观看", resume, thumb = true, app = app, open = open, menu = menu)
            }
            item("nextup") {
                RowBlock("接下来看", nextUp, thumb = false, app = app, open = open, menu = menu)
            }
            item("collections") {
                RowBlock("合集", collections, thumb = false, app = app, open = open, menu = menu)
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
                    /* ☠ 影片轨道用 **2:3 竖版海报**,`thumb` 是「16:9 剧照卡」的开关,
                       只有分集(继续观看)才该开。传成 true 的话首页下半整片变横图,
                       而 Emby 给的 Primary 本来就是竖的,横过来是被 Crop 裁掉一条。 */
                    val items = latest[view.id]
                    if (items == null) LpRowSkeleton("${view.name} · 最新", thumb = false)
                    else if (items.isNotEmpty()) LpRow(
                        "${view.name} · 最新", items,
                        { app.imageUrl(it.id, "Primary", 330) }, open, thumb = false, menu = menu,
                        onMore = { nav.navigate(Route.Library(view.id, view.name)) },
                    )
                }
            }
            item("tail") { Spacer(Modifier.height(Sp.x26)) }
        }
    }
}

/** 顶栏那颗服务器胶囊。名字没到之前写「服务器」,**不画骨架** —— 一颗抖动的小胶囊比一个静字更吵。 */
@Composable
private fun ServerChip(name: String?, onClick: () -> Unit) {
    val c = Lp.colors
    Row(
        Modifier.clip(RoundedCornerShape(R.pill))
            .background(Color.Black.copy(alpha = .34f))
            .pressable(onClick)
            .padding(start = 5.dp, end = Sp.x10, top = 5.dp, bottom = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(24.dp).clip(RoundedCornerShape(R.pill)).background(
                Brush.linearGradient(listOf(c.acc, Color(0xFFE0553F)))
            )
        )
        Spacer(Modifier.width(Sp.x8))
        Text(
            name ?: "服务器", color = Color.White, fontSize = 12.5.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        Icon(LpIcons.chevD, null, Modifier.padding(start = Sp.x4).size(13.dp),
            tint = Color.White.copy(alpha = .75f))
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
            { app.imageUrl(it.id, "Primary", if (thumb) 220 else 330) },
            open, thumb = thumb, menu = menu,
        )
        // 各块各自 catch:一个区块失败不整页报错
        is Block.Fail -> Unit
    }
}

/**
 * Hero(草稿 01):**铺到屏幕物理顶端**,状态栏浮在它上面。
 *
 * ★ **上面没有播放按钮**【用户定 2026-09-06】—— 整块可点,进详情页。
 * ★ 动效三层:Ken Burns 恒速缓推 + 换片交叉淡入 + 随滚动的视差与淡出。
 * ★ 元信息只有「评分 · 年份 · 类型」—— **画质标签整个去掉**【用户定 2026-07-28】。
 */
@Composable
private fun Hero(block: Block<List<Item>>, list: LazyListState, open: (Item) -> Unit) {
    val c = Lp.colors
    val h = Dim.heroHome
    when (block) {
        is Block.Loading -> Skeleton(Modifier.fillMaxWidth().height(h), R.none)
        is Block.Fail -> Unit
        is Block.Ok -> {
            val items = block.value
            if (items.isEmpty()) return
            var idx by remember { mutableStateOf(0) }
            val cur = items[idx % items.size]
            val app = LocalApp.current

            // Ken Burns:恒速缓推。**只动 scale**
            val t = rememberInfiniteTransition(label = "ken")
            val z by t.animateFloat(
                1f, 1.10f,
                infiniteRepeatable(tween(14000, easing = LinearEasing), RepeatMode.Reverse),
                label = "kenZ",
            )

            /* 视差:往下滚时图跟着走一半、并且淡出。
               ★ 读滚动位置只能在 `graphicsLayer` 的 lambda 里读 —— 它在 draw 阶段求值,
                 每帧只是重画;写在外面读就是**每帧重组整条首页**。 */
            Box(
                Modifier.fillMaxWidth().height(h)
                    .graphicsLayer {
                        val off = if (list.firstVisibleItemIndex == 0)
                            list.firstVisibleItemScrollOffset.toFloat() else h.toPx()
                        translationY = off * 0.42f
                        alpha = (1f - off / (h.toPx() * 0.85f)).coerceIn(0f, 1f)
                    }
                    .clipToBounds()
                    .pressable({ open(cur) })
            ) {
                // 换片交叉淡入:两张图不是「换」而是「化」
                Crossfade(cur.id, animationSpec = lpTween(T.T10), label = "heroImg") { id ->
                    NetImage(
                        app.imageUrl(id, "Backdrop", 720), null,
                        Modifier.fillMaxSize().graphicsLayer { scaleX = z; scaleY = z },
                        corner = 0.dp, scale = ContentScale.Crop,
                    )
                }
                /* 上下两头压暗:上头是给状态栏的时间和信号留可读性(**不是给它留黑底**),
                   下头是把图化进页面底色 —— 中间那 26% 完全不压,画面要露出来 */
                Box(
                    Modifier.fillMaxSize().background(
                        Brush.verticalGradient(
                            0.00f to c.bg.copy(alpha = .60f),
                            0.14f to c.bg.copy(alpha = .30f),
                            0.40f to Color.Transparent,
                            0.72f to c.bg.copy(alpha = .62f),
                            0.99f to c.bg,
                        )
                    )
                )
                Column(
                    Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                        .padding(horizontal = Sp.x20, vertical = Sp.x10),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        cur.cardTitle, color = c.fg, fontSize = 29.sp,
                        fontWeight = FontWeight.Bold, lineHeight = 33.sp,
                        textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.height(Sp.x8))
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(Sp.x8),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        cur.rating?.takeIf { it > 0 }?.let {
                            Text("★ %.1f".format(it), color = c.acc, fontSize = 12.sp,
                                fontWeight = FontWeight.Bold)
                        }
                        listOfNotNull(
                            cur.year?.toString(),
                            cur.genres.take(2).joinToString(" ").takeIf { it.isNotEmpty() },
                        ).forEach { Text(it, color = c.fg2, fontSize = 12.sp, maxLines = 1) }
                    }
                    Spacer(Modifier.height(Sp.x12))
                    // 点位:选中那颗**长成一条**,不是换个颜色
                    Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        items.indices.forEach { i ->
                            val on = i == idx % items.size
                            val w by animateDpAsState(
                                if (on) 17.dp else 5.dp,
                                lpTween(T.T6, LpEasing.emphasizedDecelerate), label = "dotW",
                            )
                            Box(
                                Modifier.size(w, 5.dp).clip(RoundedCornerShape(R.pill))
                                    .background(if (on) c.fg else c.fg.copy(alpha = .38f))
                                    .pressable({ idx = i })
                            )
                        }
                    }
                }
            }
            // 自动换条目
            LaunchedEffect(items) {
                while (true) { kotlinx.coroutines.delay(7000); idx++ }
            }
        }
    }
}

/** 媒体库入口条。**图标那格是琥珀圆底**,一排卡看下来有个落点。 */
@Composable
private fun ViewsRow(views: List<View>, nav: NavController) {
    val c = Lp.colors
    Column(Modifier.fillMaxWidth()) {
        SectionTitle("媒体库")
        LazyRow(
            Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = Sp.x16),
            horizontalArrangement = Arrangement.spacedBy(Sp.x10),
        ) {
            items(views, key = { it.id }) { v ->
                Row(
                    Modifier.width(150.dp).clip(RoundedCornerShape(R.md)).background(c.s1)
                        .pressable({ nav.navigate(Route.Library(v.id, v.name)) })
                        .padding(Sp.x10),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        Modifier.size(30.dp).clip(RoundedCornerShape(R.sm)).background(c.accDim),
                        contentAlignment = Alignment.Center,
                    ) { Icon(iconFor(v.collectionType), null, Modifier.size(16.dp), tint = c.acc) }
                    Spacer(Modifier.width(Sp.x10))
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

internal fun <T, Rn> Block<T>.map(f: (T) -> Rn): Block<Rn> = when (this) {
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
                app.call("emby.setFavorite", args("item_id" to item.id, "fav" to true))
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
                    args("id" to item.id, "name" to item.name, "blocked" to true))
            }.onFailure { app.report(it) }
        }
    },
)
