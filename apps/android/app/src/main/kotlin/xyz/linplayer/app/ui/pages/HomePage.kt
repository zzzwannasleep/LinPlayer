package xyz.linplayer.app.ui.pages

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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
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
import coil3.compose.AsyncImagePainter
import coil3.compose.rememberAsyncImagePainter
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
import xyz.linplayer.app.data.ToastKind
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.switchTab
import xyz.linplayer.app.ui.components.CardAction
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.ErrorState
import xyz.linplayer.app.ui.components.GlassIcon
import xyz.linplayer.app.ui.components.Hairline
import xyz.linplayer.app.ui.components.LpDialog
import xyz.linplayer.app.ui.components.OptRow
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
    var accounts by keepState<List<Account>>("home.accounts") { emptyList() }
    var reload by remember { mutableStateOf(0) }
    /** 顶栏那颗胶囊点开的**服务器选择弹窗**。全站没有 bottom sheet,一律居中弹窗。 */
    var pickServer by remember { mutableStateOf(false) }

    // 每一块自己一个 launch:一块回来就画一块,谁也不等谁。
    LaunchedEffect(reload) {
        if (reload == 0 && views is Block.Ok) return@LaunchedEffect
        launch { hero = app.block("emby.listRandom", args("limit" to 5)).map { Item.list(it) } }
        launch { resume = app.block("emby.listResume", args("limit" to 12)).map { Item.list(it) } }
        launch { nextUp = app.block("emby.listNextUp", args("limit" to 20)).map { Item.list(it) } }
        launch { collections = app.block("emby.listCollections").map { Item.list(it) } }
        // 顶栏那颗服务器 chip。**本地账号表,不走网络** —— 整张表都要,
        // 因为点它弹的是「换一台」的列表,不是只显示当前这台的名字
        launch { accounts = Account.list(app.block("account.listAccounts").valueOrNull) }
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
        app.invalidate.collect { if (it == "library" || it == "accounts" || it == "all") reload++ }
    }

    val open: (Item) -> Unit = { nav.navigate(Route.Detail(it.id, it.type)) }
    val menu: (Item) -> List<CardAction> = { cardActions(app, scope, it) }

    LpImmersive(bar = {
        ServerChip(accounts.firstOrNull { it.isActive }?.name) { pickServer = true }
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
                    /* ★ 轨道标题就是**库名本身**,不缀「· 最新」【用户定 2026-09-06】:
                       首页从上到下五六条轨全带同一个后缀,那个词一个字的信息都不提供,
                       只是把每条标题拉长、把库名挤窄。 */
                    val items = latest[view.id]
                    if (items == null) LpRowSkeleton(view.name, thumb = false)
                    else if (items.isNotEmpty()) LpRow(
                        view.name, items,
                        { app.imageUrl(it.id, "Primary", 330) }, open, thumb = false, menu = menu,
                        onMore = { nav.navigate(Route.Library(view.id, view.name)) },
                    )
                }
            }
            item("tail") { Spacer(Modifier.height(Sp.x26)) }
        }
    }

    /* ★★ 顶栏胶囊 = **就地换服务器**【用户定 2026-09-06】。
       原来它 `navigate(Route.Servers)` —— 那是把「换一台」做成了一次页面跳转,
       而服务器页是底栏的第三个 Tab,跳过去之后返回栈和 Tab 栈对不上,
       用户原话:「无法点回首页」。
       换成弹窗之后这件事根本不需要离开首页,顺带把那条返回路径整个消掉。 */
    if (pickServer) LpDialog({ pickServer = false }, "切换服务器") {
        Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
            accounts.forEach { a ->
                OptRow(
                    a.name, sub = a.remark?.takeIf { it.isNotBlank() } ?: a.userName,
                    selected = a.isActive,
                    onClick = {
                        pickServer = false
                        // 已经是这一台就什么都不做:再打一次 setActiveServer 会让整页白重拉
                        if (a.isActive) return@OptRow
                        scope.launch {
                            runCatching { app.call("account.setActiveServer", args("server_id" to a.id)) }
                                .onSuccess {
                                    /* ☠ 先把各块打回骨架。`PageCache.clear()`(在 boot 里)
                                       清的是那张哈希表,**清不掉当前 composition 手里的
                                       那几个 MutableState** —— 不打回去的话,新服务器的数据
                                       到位之前,屏幕上摆的是上一台的媒体库。那是界面在撒谎。 */
                                    hero = Block.Loading; resume = Block.Loading
                                    nextUp = Block.Loading; collections = Block.Loading
                                    views = Block.Loading; latest = emptyMap()
                                    // ★ **必须等 refreshSession**:首页各块读的是新会话,
                                    //   不等的话它们拿旧服务器的凭据去拉内容
                                    app.refreshSession()
                                    reload++
                                    app.toast("已切到「${a.name}」", ToastKind.Ok)
                                }
                                .onFailure { app.report(it) }
                        }
                    },
                )
            }
            Spacer(Modifier.height(Sp.x10))
            Hairline()
            Spacer(Modifier.height(Sp.x10))
            OptRow("管理服务器…", onClick = { pickServer = false; nav.switchTab(Route.Servers) })
            OptRow("添加服务器…", onClick = { pickServer = false; nav.navigate(Route.AddServer) })
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
 * ★ **手指能左右翻**【用户定 2026-09-06】。轮播不给手是「看得见摸不着」——
 *   自动换片留着,但手一碰就停:抢走用户正在看的那一张比不自动播更糟。
 * ★ 标题走 **TMDB 艺术字**(Emby 的 `Logo` 图),取不到才回落成排版字。
 * ★ **上面没有播放按钮**【用户定 2026-09-06】—— 整块可点,进详情页。
 * ★ 动效三层:Ken Burns 恒速缓推 + 翻页视差 + 随滚动的整块上移淡出。
 * ★ 元信息只有「评分 · 年份 · 类型」——**画质标签整个去掉**【用户定 2026-07-28】。
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
            val app = LocalApp.current
            val scope = rememberCoroutineScope()
            val pager = rememberPagerState(pageCount = { items.size })
            /* 手动翻过就不再自动轮播。**一次就够,不设「几秒后恢复」**——
               定时恢复的表现是:用户翻到想看的那张、看了两眼,它又自己走掉。 */
            var manual by remember { mutableStateOf(false) }

            // Ken Burns:恒速缓推。**只动 scale**
            val t = rememberInfiniteTransition(label = "ken")
            val z by t.animateFloat(
                1f, 1.10f,
                infiniteRepeatable(tween(14000, easing = LinearEasing), RepeatMode.Reverse),
                label = "kenZ",
            )

            /* 视差:往下滚时整块跟着走一半、并且淡出。
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
            ) {
                HorizontalPager(pager, Modifier.fillMaxSize()) { page ->
                    val cur = items[page]
                    Box(Modifier.fillMaxSize().pressable({ open(cur) })) {
                        // 翻页视差:图比页面慢一拍地跟过来。位移同样在 draw 阶段读
                        NetImage(
                            app.imageUrl(cur.id, "Backdrop", 720), null,
                            Modifier.fillMaxSize().graphicsLayer {
                                scaleX = z; scaleY = z
                                val d = (pager.currentPage - page) + pager.currentPageOffsetFraction
                                translationX = d * size.width * 0.35f
                            },
                            corner = 0.dp, scale = ContentScale.Crop,
                        )
                        /* 上下两头压暗:上头给状态栏的时间和信号留可读性(**不是给它留黑底**),
                           下头把图化进页面底色 —— 中间那 26% 完全不压,画面要露出来 */
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
                                .padding(start = Sp.x20, end = Sp.x20, top = Sp.x10, bottom = 38.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            ArtTitle(app.imageUrl(cur.id, "Logo", 240), cur.cardTitle)
                            Spacer(Modifier.height(Sp.x8))
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(Sp.x8),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                cur.rating?.takeIf { r -> r > 0 }?.let { r ->
                                    Text("★ %.1f".format(r), color = c.acc, fontSize = 12.sp,
                                        fontWeight = FontWeight.Bold)
                                }
                                listOfNotNull(
                                    cur.year?.toString(),
                                    cur.genres.take(2).joinToString(" ").takeIf { g -> g.isNotEmpty() },
                                ).forEach { Text(it, color = c.fg2, fontSize = 12.sp, maxLines = 1) }
                            }
                        }
                    }
                }
                // 点位:选中那颗**长成一条**。★ 画在 pager 外面 —— 跟着翻页一起滑走就没人看得见
                Row(
                    Modifier.align(Alignment.BottomCenter).padding(bottom = Sp.x16),
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    items.indices.forEach { i ->
                        val on = i == pager.currentPage
                        val w by animateDpAsState(
                            if (on) 17.dp else 5.dp,
                            lpTween(T.T6, LpEasing.emphasizedDecelerate), label = "dotW",
                        )
                        Box(
                            Modifier.size(w, 5.dp).clip(RoundedCornerShape(R.pill))
                                .background(if (on) c.fg else c.fg.copy(alpha = .38f))
                                .pressable({ manual = true; scope.launch { pager.animateScrollToPage(i) } })
                        )
                    }
                }
            }
            /* 手指一碰就停自动轮播。
               ☠ 判据是 **interactionSource(只有真手势才发)**,不是 `isScrollInProgress` ——
                 后者对 `animateScrollToPage` 也是 true,于是**第一次自动换片就把自己关掉了**,
                 表现是「轮播只走一格然后再也不动」,而且看起来像自动播压根没做。 */
            LaunchedEffect(pager) {
                pager.interactionSource.interactions.collect { manual = true }
            }
            LaunchedEffect(items, manual) {
                if (manual) return@LaunchedEffect
                while (true) {
                    kotlinx.coroutines.delay(7000)
                    pager.animateScrollToPage((pager.currentPage + 1) % items.size)
                }
            }
        }
    }
}

/**
 * 艺术字标题。
 *
 * ★ TMDB 的片名艺术字在 Emby 里是 `Logo` 图。**不是每部片都有** ——
 *   没有的那些回落成排版字,而不是留一块空白或者一个碎图标。
 * ★ 判据是**图真的解出来了**,不是「地址拼得出来」:地址永远拼得出来,
 *   拼出来的那条 404 才是常态。
 * ★ 按**高度**定尺寸、宽度随原图 —— 按宽度定会把横长的片名压成一条。
 */
@Composable
private fun ArtTitle(logoUrl: String?, fallback: String) {
    val c = Lp.colors
    val painter = rememberAsyncImagePainter(logoUrl)
    val st by painter.state.collectAsState()
    if (st is AsyncImagePainter.State.Success) androidx.compose.foundation.Image(
        painter, fallback,
        Modifier.heightIn(max = 92.dp).widthIn(max = 320.dp),
        contentScale = ContentScale.Fit,
    ) else Text(
        fallback, color = c.fg, fontSize = 29.sp,
        fontWeight = FontWeight.Bold, lineHeight = 33.sp,
        textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis,
    )
}

/**
 * 媒体库入口条(照 PC 端:**封面卡,不是一行图标加一行字**)。
 *
 * ☠ **封面严禁裁剪**【用户定 2026-09-06】:各家库的封面比例五花八门(方的、16:9 的、
 *   海报比例的),`Crop` 会把库名的字直接切掉半边。所以是 `Fit` + 一块底色垫底,
 *   宁可两侧留边也不切。
 * ★ 没有封面的库回落成图标 —— 一块灰底比一张碎图好。
 */
@Composable
private fun ViewsRow(views: List<View>, nav: NavController) {
    val c = Lp.colors
    val app = LocalApp.current
    Column(Modifier.fillMaxWidth()) {
        SectionTitle("媒体库")
        LazyRow(
            Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = Sp.x16),
            horizontalArrangement = Arrangement.spacedBy(Sp.x10),
        ) {
            items(views, key = { it.id }) { v ->
                Column(
                    Modifier.width(158.dp).pressable({ nav.navigate(Route.Library(v.id, v.name)) }),
                ) {
                    Box(
                        Modifier.fillMaxWidth().height(90.dp)
                            .clip(RoundedCornerShape(R.md)).background(c.s1),
                        contentAlignment = Alignment.Center,
                    ) {
                        // 垫一层图标:图没到 / 这个库压根没封面时,看到的是它而不是一块空
                        Icon(iconFor(v.collectionType), null, Modifier.size(26.dp), tint = c.fg3)
                        NetImage(
                            app.imageUrl(v.id, "Primary", 260), v.name,
                            Modifier.fillMaxSize(), R.md, ContentScale.Fit,
                        )
                    }
                    Spacer(Modifier.height(Sp.x6))
                    Text(v.name, color = c.fg, fontSize = 13.sp, lineHeight = 17.sp, maxLines = 1,
                        overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium)
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
