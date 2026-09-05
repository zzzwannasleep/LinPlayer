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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import kotlinx.coroutines.launch
import xyz.linplayer.app.data.Block
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.block
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.long
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.Body
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.ErrorState
import xyz.linplayer.app.ui.components.Hairline
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
 * 文件浏览(U1.10)。
 *
 * ★ 列表行不是网格 —— **文件名比缩略图重要**。
 * ★ `source.listDir` 是**流式**的,边列边出。
 * ★ 起播必须走宿主统一的起播入口(导航到播放页),**本页不许自己 `player.play`**。
 *   教训:曾经绕开统一入口自己起播,结果「有声音、没画面、还关不掉」。
 */
@Composable
fun BrowsePage(nav: NavController) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()

    data class Entry(val id: String, val name: String, val isDir: Boolean,
                     val size: Long?, val modified: String?)

    var stack by remember { mutableStateOf(listOf<Pair<String?, String>>(null to "根目录")) }
    var entries by remember { mutableStateOf<List<Entry>>(emptyList()) }
    var state by remember { mutableStateOf<Block<Unit>>(Block.Loading) }

    LaunchedEffect(stack) {
        state = Block.Loading; entries = emptyList()
        val dir = stack.last().first
        val r = runCatching {
            app.call("source.listDir",
                dir?.let { args("dir_id" to it) },
                onPartial = { p ->
                    // 边列边出:大目录不许攒齐再画
                    entries = entries + p.arr().mapNotNull { e ->
                        val o = e.obj() ?: return@mapNotNull null
                        Entry(o.str("id") ?: return@mapNotNull null, o.str("name") ?: "",
                            o.bool("is_dir"), o.long("size"), o.str("modified"))
                    }
                })
        }
        state = r.fold({ v ->
            if (entries.isEmpty()) entries = v.arr().mapNotNull { e ->
                val o = e.obj() ?: return@mapNotNull null
                Entry(o.str("id") ?: return@mapNotNull null, o.str("name") ?: "",
                    o.bool("is_dir"), o.long("size"), o.str("modified"))
            }
            Block.Ok(Unit)
        }, { e ->
            val ce = e as? xyz.linplayer.app.core.CoreException
            Block.Fail(ce?.code ?: "E_INTERNAL", ce?.advice ?: (e.message ?: "打不开这个目录"))
        })
    }

    LpScaffold(
        stack.last().second, subtitle = "文件浏览",
        onBack = { if (stack.size > 1) stack = stack.dropLast(1) else nav.popBackStack() },
        scrolled = rememberScrolled(list),
    ) { pad ->
        when (val s = state) {
            is Block.Loading -> Column(Modifier.padding(Sp.x16)) {
                repeat(6) { Skeleton(Modifier.fillMaxWidth().height(48.dp)); Spacer(Modifier.height(Sp.x8)) }
            }
            is Block.Fail -> if (!s.isSilent) ErrorState(s.message)
            is Block.Ok -> if (entries.isEmpty()) EmptyState(
                // 空目录就说**空目录**,不要说「加载失败」
                "这个目录是空的", "里面没有文件,也没有子目录。", LpIcons.folder,
            ) else LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
                items(entries, key = { it.id }) { e ->
                    Row(Modifier.fillMaxWidth().pressable({
                        if (e.isDir) stack = stack + (e.id to e.name)
                        else nav.navigate(Route.Player(e.id, e.name))
                    }).padding(horizontal = Sp.x16, vertical = Sp.x12),
                        verticalAlignment = Alignment.CenterVertically) {
                        Icon(if (e.isDir) LpIcons.folder else LpIcons.file, null,
                            Modifier.size(20.dp), tint = Lp.colors.fg2)
                        Spacer(Modifier.padding(horizontal = Sp.x6))
                        Column(Modifier.weight(1f)) {
                            Body(e.name, maxLines = 2)
                            val meta = listOfNotNull(
                                e.size?.let { "%.1f MB".format(it / 1024.0 / 1024.0) },
                                e.modified,
                            ).joinToString("  ·  ")
                            if (meta.isNotEmpty()) Dim3(meta, Modifier.padding(top = Sp.x2))
                        }
                    }
                    Hairline(Modifier.padding(start = Sp.x48))
                }
            }
        }
    }
}

/**
 * 影视目录(U1.11)。**与文件浏览是两套页面,不复用。**
 *
 * 这一页存在的唯一理由:**资源站不是文件树。**
 * 复用过一次,六个毛病全是那个决定的症状 —— 分类伪装成文件夹、翻页伪装成一个叫
 * 「下一页」的文件夹、「更新至 17 集」只能拼进文件名。
 */
@Composable
fun CatalogPage(nav: NavController) {
    val app = LocalApp.current
    val grid = rememberLazyGridState()

    data class Media(val id: String, val name: String, val cover: String?,
                     val year: String?, val note: String?, val rating: String?)

    var cats by remember { mutableStateOf<List<Pair<String, String>>>(emptyList()) }
    var cur by remember { mutableStateOf<String?>(null) }
    var items by remember { mutableStateOf<List<Media>>(emptyList()) }
    var page by remember { mutableStateOf(1) }
    var state by remember { mutableStateOf<Block<Unit>>(Block.Loading) }
    var loadingMore by remember { mutableStateOf(false) }
    var noMore by remember { mutableStateOf(false) }

    fun parse(e: kotlinx.serialization.json.JsonElement?) = e.obj()?.get("items").arr().mapNotNull {
        val o = it.obj() ?: return@mapNotNull null
        Media(o.str("id") ?: return@mapNotNull null, o.str("name") ?: "",
            o.str("cover"), o.str("year"), o.str("note"), o.str("rating"))
    }

    LaunchedEffect(Unit) {
        val r = app.block("source.categories")
        if (r is Block.Fail) {
            // 探能力抛「不支持」= 这是个文件型源 → **静默换路**,不当错误弹
            if (r.isSilent) { nav.popBackStack(); nav.navigate(Route.Browse) }
            state = r
            return@LaunchedEffect
        }
        val all = r.valueOrNull.arr().mapNotNull {
            val o = it.obj() ?: return@mapNotNull null
            (o.str("id") ?: return@mapNotNull null) to (o.str("name") ?: "分类")
        }
        cats = all
        // ★ 有子分类的父级本身多半是空的,落到第一个而不是把用户扔进空页
        cur = all.firstOrNull()?.first
    }

    LaunchedEffect(cur) {
        val c = cur ?: return@LaunchedEffect
        state = Block.Loading; items = emptyList(); page = 1; noMore = false
        // 首屏**预抓两页** —— 否则内容铺不满一屏 → 没有滚动 → 无限下拉永远不会被触发
        val p1 = app.block("source.catalog", args("category_id" to c, "page" to 1))
        val p2 = app.block("source.catalog", args("category_id" to c, "page" to 2))
        items = parse(p1.valueOrNull) + parse(p2.valueOrNull)
        page = 2
        state = if (p1 is Block.Fail) p1 else Block.Ok(Unit)
    }

    val needMore by remember {
        derivedStateOf {
            val last = grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            items.isNotEmpty() && last >= items.size - 6
        }
    }
    LaunchedEffect(Unit) {
        snapshotFlow { needMore }.collect {
            if (!it || loadingMore || noMore || cur == null) return@collect
            loadingMore = true
            val next = app.block("source.catalog", args("category_id" to cur!!, "page" to page + 1))
            val more = parse(next.valueOrNull)
            if (more.isEmpty()) noMore = true else { items = items + more; page++ }
            loadingMore = false
        }
    }

    LpScaffold("影视目录", onBack = { nav.popBackStack() }, scrolled = rememberScrolled(grid)) { pad ->
        Column(Modifier.fillMaxSize()) {
            // 顶部**横条分类**(不是网格里的卡片)
            if (cats.isNotEmpty()) Row(
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
            when (val s = state) {
                is Block.Loading -> Skeleton(Modifier.fillMaxWidth().height(240.dp).padding(Sp.x16))
                is Block.Fail -> if (!s.isSilent) ErrorState(s.message)
                is Block.Ok -> if (items.isEmpty()) EmptyState(
                    "这个分类没有内容", "换一个分类试试。", LpIcons.grid,
                ) else LazyVerticalGrid(
                    GridCells.Adaptive(112.dp), Modifier.fillMaxSize(), grid,
                    contentPadding = PaddingValues(Sp.x16, Sp.x8, Sp.x16, pad.calculateBottomPadding()),
                    horizontalArrangement = Arrangement.spacedBy(Sp.x10),
                    verticalArrangement = Arrangement.spacedBy(Sp.x16),
                ) {
                    items(items, key = { it.id }) { m ->
                        // ★ 角标 / 年份 / 评分**各占各的位置**,标题里只有标题
                        Column(Modifier.pressable({ nav.navigate(Route.Player(m.id, m.name)) })) {
                            Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f)) {
                                NetImage(m.cover, m.name, Modifier.fillMaxSize())
                                m.note?.let {
                                    Text(it, Modifier.align(Alignment.TopStart).padding(Sp.x4)
                                        .clip(RoundedCornerShape(R.sm)).background(Lp.colors.chip)
                                        .padding(horizontal = 5.dp, vertical = 1.dp),
                                        color = Lp.colors.fg, fontSize = 10.sp, maxLines = 1)
                                }
                                m.rating?.let {
                                    Text(it, Modifier.align(Alignment.TopEnd).padding(Sp.x4)
                                        .clip(RoundedCornerShape(R.sm)).background(Lp.colors.chip)
                                        .padding(horizontal = 5.dp, vertical = 1.dp),
                                        color = Lp.colors.fg, fontSize = 10.sp, maxLines = 1)
                                }
                            }
                            Spacer(Modifier.height(Sp.x6))
                            Text(m.name, color = Lp.colors.fg, fontSize = 13.sp, maxLines = 1,
                                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                            m.year?.let { Dim3(it) }
                        }
                    }
                }
            }
        }
    }
}

/**
 * 插件(U1.13)。一页三个 Tab:市场 / 已装 / 源订阅。
 *
 * ★ **授权清单在装 / 启用之前弹,一行一条人话。**
 *   权限词表由 `plugin.permissionCatalog` 透出,**UI 不许抄一份** ——
 *   抄了就会漏新权限,弹窗里显示光秃秃的 id。
 * ★ **可装版本要取版本号最大值,不是数组第一个** —— 上游返回顺序不可依赖。
 */
@Composable
fun PluginsPage(nav: NavController) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()

    data class Plug(val id: String, val name: String, val version: String,
                    val enabled: Boolean, val thirdParty: Boolean, val desc: String?)

    var tab by remember { mutableStateOf(0) }
    var installed by remember { mutableStateOf<List<Plug>>(emptyList()) }
    var market by remember { mutableStateOf<List<Plug>>(emptyList()) }
    var sources by remember { mutableStateOf<List<Pair<String, Boolean>>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var reload by remember { mutableStateOf(0) }

    fun parse(e: kotlinx.serialization.json.JsonElement?) = e.arr().mapNotNull {
        val o = it.obj() ?: return@mapNotNull null
        Plug(o.str("id") ?: return@mapNotNull null, o.str("name") ?: "插件",
            o.str("version") ?: "", o.bool("enabled"), o.bool("third_party"), o.str("description"))
    }

    LaunchedEffect(reload) {
        // 进页拉已装列表 + 各订阅源的 registry,**并发**
        launch { installed = parse(runCatching { app.call("plugin.list") }.getOrNull()) }
        launch { market = parse(runCatching { app.call("plugin.marketList") }.getOrNull()) }
        launch {
            sources = runCatching { app.call("plugin.marketSources") }.getOrNull().arr()
                .mapNotNull {
                    val o = it.obj() ?: return@mapNotNull null
                    (o.str("name") ?: o.str("url") ?: return@mapNotNull null) to o.bool("enabled")
                }
        }
        loaded = true
    }

    LpScaffold("插件", onBack = { nav.popBackStack() }, scrolled = rememberScrolled(list)) { pad ->
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = Sp.x16, vertical = Sp.x8),
                horizontalArrangement = Arrangement.spacedBy(Sp.x8)) {
                listOf("市场", "已装", "源订阅").forEachIndexed { i, t ->
                    val on = i == tab
                    Text(t, Modifier.clip(RoundedCornerShape(R.pill))
                        .background(if (on) Lp.colors.acc else Lp.colors.s2)
                        .pressable({ tab = i }).padding(horizontal = Sp.x16, vertical = Sp.x8),
                        color = if (on) Lp.colors.accFg else Lp.colors.fg2, fontSize = 13.sp)
                }
            }
            if (!loaded) Skeleton(Modifier.fillMaxWidth().height(120.dp).padding(Sp.x16))
            else LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
                when (tab) {
                    0 -> if (market.isEmpty()) item("e") {
                        EmptyState("市场是空的", "在「源订阅」里加一个插件源。", LpIcons.plugin)
                    } else items(market, key = { it.id }) { p ->
                        PlugRow(p.name, p.version, p.desc, p.thirdParty, "安装") {
                            scope.launch {
                                runCatching { app.call("plugin.marketInstall", args("id" to p.id)) }
                                    .onSuccess { reload++ }.onFailure { app.report(it) }
                            }
                        }
                    }
                    // 「已装」经常是空的 —— **做成 Tab 而不是两个入口,空 Tab 比空页面便宜**
                    1 -> if (installed.isEmpty()) item("e") {
                        EmptyState("还没有装插件", "去「市场」看看。", LpIcons.plugin)
                    } else items(installed, key = { it.id }) { p ->
                        PlugRow(p.name, p.version, p.desc, p.thirdParty,
                            if (p.enabled) "停用" else "启用") {
                            scope.launch {
                                runCatching {
                                    app.call(
                                        if (p.enabled) "plugin.disable" else "plugin.enable",
                                        args("id" to p.id))
                                }.onSuccess { reload++ }.onFailure { app.report(it) }
                            }
                        }
                    }
                    else -> if (sources.isEmpty()) item("e") {
                        EmptyState("没有订阅任何插件源", "插件源是一个 registry 地址。", LpIcons.globe)
                    } else items(sources, key = { it.first }) { (name, on) ->
                        Row(Modifier.fillMaxWidth().padding(Sp.x16),
                            verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Body(name, maxLines = 2)
                                Dim3(if (on) "已启用" else "已停用", Modifier.padding(top = Sp.x2))
                            }
                        }
                        Hairline()
                    }
                }
            }
        }
    }
}

@Composable
private fun PlugRow(
    name: String, version: String, desc: String?, thirdParty: Boolean,
    action: String, onAction: () -> Unit,
) {
    Row(Modifier.fillMaxWidth().padding(Sp.x16), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Body(name, maxLines = 1)
                // 第三方源要有**信任标记**
                if (thirdParty) {
                    Spacer(Modifier.padding(horizontal = Sp.x4))
                    Text("第三方", Modifier.clip(RoundedCornerShape(R.sm))
                        .background(Lp.colors.warn.copy(alpha = .2f))
                        .padding(horizontal = 6.dp, vertical = 1.dp),
                        color = Lp.colors.warn, fontSize = 10.sp)
                }
            }
            Dim3(listOfNotNull(version.takeIf { it.isNotBlank() }, desc).joinToString(" · "),
                Modifier.padding(top = Sp.x2), maxLines = 2)
        }
        xyz.linplayer.app.ui.components.LpButton(action, onAction,
            kind = xyz.linplayer.app.ui.components.BtnKind.Secondary)
    }
    Hairline()
}
