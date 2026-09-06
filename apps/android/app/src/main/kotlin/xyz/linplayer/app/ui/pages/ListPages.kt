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
    var block by xyz.linplayer.app.data.keepState<Block<List<Item>>>("fav") { Block.Loading }
    var reload by remember { mutableStateOf(0) }

    LaunchedEffect(reload) {
        if (reload == 0 && block is Block.Ok) return@LaunchedEffect
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
