package xyz.linplayer.app.ui.pages

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import kotlinx.serialization.json.JsonObject
import xyz.linplayer.app.data.Item
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.str
import xyz.linplayer.app.data.strList
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.LpIconButton
import xyz.linplayer.app.ui.components.LpRow
import xyz.linplayer.app.ui.components.LpRowSkeleton
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.components.pressable
import xyz.linplayer.app.ui.components.rememberScrolled
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp

/**
 * 聚合视界(U1.8)· 底栏第二个 Tab。
 *
 * ☠ **流式**(SPEC §5.7):每台服务器各自回各自渲染。**收到 `partial` 就画,不许攒齐再画** ——
 * 最慢的那台不该拖住最快的那台。
 */
@Composable
fun AggregatePage(nav: NavController) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()

    var groups by remember { mutableStateOf<List<Pair<String, List<Item>>>>(emptyList()) }
    var failed by remember { mutableStateOf<List<String>>(emptyList()) }
    var done by remember { mutableStateOf(false) }
    var serverCount by remember { mutableStateOf(0) }
    var reload by remember { mutableStateOf(0) }

    LaunchedEffect(reload) {
        groups = emptyList(); failed = emptyList(); done = false
        serverCount = xyz.linplayer.app.data.Account.list(
            runCatching { app.call("account.listAccounts") }.getOrNull()).size
        runCatching {
            app.call("emby.aggregateOverview", null, onPartial = { p ->
                val o = p as? JsonObject
                val name = o.str("server") ?: o.str("name") ?: "服务器"
                groups = groups + (name to Item.list(o?.get("items")))
            })
        }.onSuccess { failed = (it as? JsonObject).strList("failed") }
            .onFailure { app.report(it) }
        done = true
    }

    LaunchedEffect(Unit) { app.invalidate.collect { if (it == "accounts" || it == "all") reload++ } }

    LpScaffold("聚合视界", scrolled = rememberScrolled(list), actions = {
        LpIconButton(LpIcons.search, "搜索") { nav.navigate(Route.Search()) }
        LpIconButton(LpIcons.refresh, "刷新") { reload++ }
    }) { pad ->
        LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
            item("shortcuts") { Shortcuts(nav) }

            if (groups.isEmpty() && !done) item("skel") {
                LpRowSkeleton(); LpRowSkeleton()
            }

            groups.forEach { (server, items) ->
                item(server) {
                    if (items.isEmpty()) Dim3("$server:没有内容", Modifier.padding(Sp.x16))
                    else LpRow(server, items, { app.imageUrl(it.id, "Primary", 330) },
                        { nav.navigate(Route.Detail(it.id, it.type)) },
                        menu = { cardActions(app, scope, it) })
                }
            }

            // 逐台标失败,不整页失败
            if (failed.isNotEmpty()) item("failed") {
                Dim3("这些服务器没拉到:${failed.joinToString("、")}", Modifier.padding(Sp.x16), maxLines = 3)
            }

            if (done && groups.isEmpty()) item("empty") {
                EmptyState(
                    if (serverCount <= 1) "添加更多服务器才有聚合" else "这些服务器上暂时没有内容",
                    if (serverCount <= 1) "聚合视界把多台服务器的内容并排放在一起。现在只有一台。" else null,
                    LpIcons.globe,
                    actionLabel = if (serverCount <= 1) "去添加服务器" else null,
                    onAction = { nav.navigate(Route.AddServer) },
                )
            }
            item("tail") { Spacer(Modifier.height(Sp.x26)) }
        }
    }
}

/** 一行快捷入口:继续观看 / 收藏 / 下载 / 排行榜 / 日历。 */
@Composable
private fun Shortcuts(nav: NavController) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Sp.x16, vertical = Sp.x12),
        horizontalArrangement = Arrangement.spacedBy(Sp.x8),
    ) {
        Shortcut("收藏", LpIcons.heart, Modifier.weight(1f)) { nav.navigate(Route.Favorites) }
        Shortcut("下载", LpIcons.download, Modifier.weight(1f)) { nav.navigate(Route.Downloads) }
        Shortcut("排行榜", LpIcons.trophy, Modifier.weight(1f)) { nav.navigate(Route.Ranking) }
        Shortcut("日历", LpIcons.calendar, Modifier.weight(1f)) { nav.navigate(Route.Calendar) }
    }
}

@Composable
private fun Shortcut(label: String, icon: ImageVector, m: Modifier, onClick: () -> Unit) {
    val c = Lp.colors
    Column(
        m.clip(RoundedCornerShape(R.md)).background(c.s1).pressable(onClick).padding(vertical = Sp.x12),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(icon, null, Modifier.size(20.dp), tint = c.acc)
        Spacer(Modifier.height(Sp.x6))
        Text(label, color = c.fg2, fontSize = 11.sp)
    }
}
