package xyz.linplayer.app.ui.pages

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import xyz.linplayer.app.data.Item
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.long
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
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

    // 一台服务器一组:规模统计 + 继续观看
    var groups by xyz.linplayer.app.data.keepState<List<Overview>>("agg.groups") { emptyList() }
    var done by xyz.linplayer.app.data.keepState("agg.done") { false }
    var reload by remember { mutableStateOf(0) }

    /* ☠ `emby.aggregateOverview` **不是流式的**,它一次性返回整张表。
       这里原来给它挂了 onPartial 回调,又按 server / name / items 三个
       **核心层根本不发**的字段名去取 —— 结果 groups 恒空,页面永远画
       「添加更多服务器才有聚合」。真实字段是 server_name / counts / resume。
       同一类错(响应字段名对不上)由 scripts/check-android-fields.py 守着。 */
    LaunchedEffect(reload) {
        if (reload == 0 && groups.isNotEmpty()) return@LaunchedEffect
        done = false
        groups = runCatching { app.call("emby.aggregateOverview") }.getOrNull()
            .arr().mapNotNull { Overview.from(it) }
        done = true
    }

    LpScaffold("聚合视界", scrolled = rememberScrolled(list), actions = {
        LpIconButton(LpIcons.search, "搜索") { nav.navigate(Route.Search()) }
        LpIconButton(LpIcons.refresh, "刷新") { reload++ }
    }) { pad ->
        LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
            item("shortcuts") { Shortcuts(nav) }

            if (groups.isEmpty() && !done) item("skel") {
                LpRowSkeleton(); LpRowSkeleton()
            }

            groups.forEach { g ->
                item("head-${g.serverId}") { ServerHead(g) }
                if (g.resume.isNotEmpty()) item("resume-${g.serverId}") {
                    LpRow("继续观看", g.resume, { app.imageUrl(it.id, "Primary", 220) },
                        { nav.navigate(Route.Detail(it.id, it.type)) }, thumb = true,
                        menu = { cardActions(app, scope, it) })
                }
            }

            // ★ 单台服务器**照样能用**【用户定 2026-09-06】:聚合视界不是「多服专属」,
            //   它是「跨源总览 + 快捷入口」。空态只在真的一台服都没有时出现。
            if (done && groups.isEmpty()) item("empty") {
                EmptyState(
                    "还没有添加服务器", "添加一台服务器之后,这里会显示它的规模和继续观看。",
                    LpIcons.globe, actionLabel = "去添加服务器",
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

/** 一台服务器的总览。字段名照 `core/aggregate/aggregate.go` 的 `SourceOverview`。 */
@androidx.compose.runtime.Immutable
private data class Overview(
    val serverId: String,
    val serverName: String,
    val active: Boolean,
    val movie: Long,
    val series: Long,
    val episode: Long,
    val resume: List<Item>,
) {
    companion object {
        fun from(e: kotlinx.serialization.json.JsonElement?): Overview? {
            val o = e.obj() ?: return null
            val counts = o["counts"].obj()
            return Overview(
                serverId = o.str("server_id") ?: return null,
                serverName = o.str("server_name")?.takeIf { it.isNotBlank() } ?: "服务器",
                active = o.bool("active"),
                movie = counts.long("movie") ?: 0,
                series = counts.long("series") ?: 0,
                episode = counts.long("episode") ?: 0,
                resume = Item.list(o["resume"]),
            )
        }
    }
}

@Composable
private fun ServerHead(g: Overview) {
    val c = Lp.colors
    Row(
        Modifier.fillMaxWidth().padding(start = Sp.x16, end = Sp.x16, top = Sp.x20, bottom = Sp.x6),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // 当前生效的那台点一个圆点。**不写地址**【用户定】——地址只是内部键
        if (g.active) Box(Modifier.size(6.dp).clip(RoundedCornerShape(R.pill)).background(c.acc))
        if (g.active) Spacer(Modifier.width(Sp.x6))
        Text(g.serverName, color = c.fg, fontSize = 16.sp,
            fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold)
        Spacer(Modifier.width(Sp.x10))
        // 规模统计:0 的那一项整个不画,不写「电影 0」
        Dim3(listOfNotNull(
            g.movie.takeIf { it > 0 }?.let { "电影 $it" },
            g.series.takeIf { it > 0 }?.let { "剧集 $it" },
            g.episode.takeIf { it > 0 }?.let { "分集 $it" },
        ).joinToString("  ·  "))
    }
}
