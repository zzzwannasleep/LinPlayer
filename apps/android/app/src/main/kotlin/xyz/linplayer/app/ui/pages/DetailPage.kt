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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavController
import androidx.navigation.toRoute
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import xyz.linplayer.app.data.Block
import xyz.linplayer.app.data.Item
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.ToastKind
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.block
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.dbl
import xyz.linplayer.app.data.long
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.data.strList
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.BtnKind
import xyz.linplayer.app.ui.components.Body
import xyz.linplayer.app.ui.components.Dim2
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.H2
import xyz.linplayer.app.ui.components.LpButton
import xyz.linplayer.app.ui.components.LpIconButton
import xyz.linplayer.app.ui.components.LpRow
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.components.MediaCard
import xyz.linplayer.app.ui.components.NetImage
import xyz.linplayer.app.ui.components.Panel
import xyz.linplayer.app.ui.components.Skeleton
import xyz.linplayer.app.ui.components.pressable
import xyz.linplayer.app.ui.components.rememberScrolled
import xyz.linplayer.app.ui.theme.Dim
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp

/** 一个可播版本。`preferred` 由**核心层**标 —— UI 不许自己回落 `versions[0]`。 */
internal data class Version(val id: String, val name: String, val preferred: Boolean)

/**
 * 详情页族(U1.5)。**剧 / 影 / 季 / 集四张分开设计**,共用组件但版式不同。
 *
 * ☠ **界面不许撒谎:展示的版本必须是真正会播的那一个。**
 * 核心层标 `preferred`,UI 用唯一的 [defaultVersion] 算法,
 * **不许自己回落 `versions[0]`** —— 这条有真实故障:正则真选对了版本,
 * 但详情页写死回落,用户看到的是「功能没生效」。
 */
@Composable
fun DetailPage(nav: NavController, entry: NavBackStackEntry) {
    val route = entry.toRoute<Route.Detail>()
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()

    var detail by remember { mutableStateOf<Block<JsonObject>>(Block.Loading) }
    var versions by remember { mutableStateOf<List<Version>>(emptyList()) }
    /** ☠ 「未选」是 `null` 不是 `0` —— 传了 id 核心层就走「手动指定」分支,版本正则整个被跳过。 */
    var pickedVersion by remember { mutableStateOf<String?>(null) }
    var seasons by remember { mutableStateOf<List<Item>>(emptyList()) }
    var curSeason by remember { mutableStateOf<Item?>(null) }
    var episodes by remember { mutableStateOf<List<Item>>(emptyList()) }
    var similar by remember { mutableStateOf<List<Item>>(emptyList()) }
    var favorite by remember { mutableStateOf(false) }
    var played by remember { mutableStateOf(false) }

    // 详情与 itemMedia **并行**;相似推荐也并发;分集要等详情回来(series_id 只有详情才给)
    LaunchedEffect(route.itemId) {
        launch {
            val d = app.block("emby.itemDetail", args("item_id" to route.itemId))
            detail = when (d) {
                is Block.Ok -> Block.Ok(d.value.obj() ?: JsonObject(emptyMap()))
                is Block.Fail -> d
                else -> Block.Loading
            }
            val o = d.valueOrNull.obj()
            favorite = o.bool("favorite") || o.bool("is_favorite")
            played = o.bool("played")

            val seriesId = o.str("series_id") ?: route.itemId.takeIf { route.type == "Series" }
            if (route.type == "Series" || route.type == "Season" || route.type == "Episode") {
                launch {
                    if (seriesId != null) {
                        seasons = Item.list(app.block("emby.seriesSeasons",
                            args("series_id" to seriesId)).valueOrNull)
                        val s = seasons.firstOrNull { it.id == route.itemId } ?: seasons.firstOrNull()
                        curSeason = s
                        if (s != null) episodes = Item.list(app.block("emby.seasonEpisodes",
                            args("season_id" to s.id)).valueOrNull)
                    }
                }
            }
        }
        launch {
            val m = app.block("emby.itemMedia", args("item_id" to route.itemId))
            versions = m.valueOrNull.obj()?.get("versions").arr().mapNotNull {
                val o = it.obj() ?: return@mapNotNull null
                Version(o.str("id") ?: return@mapNotNull null, o.str("name") ?: "版本",
                    o.bool("preferred"))
            }
        }
        launch { similar = Item.list(app.block("emby.similarItems", args("item_id" to route.itemId)).valueOrNull) }
        // 进详情页就开始预热「▶ 会播的那个条目」。fire-and-forget,失败全吞
        launch { runCatching { app.call("prefs.preloadItem", args("item_id" to route.itemId)) } }
    }

    // 离页取消预热:留着不取消 = 用户翻十个详情就有十条流在偷偷拉
    androidx.compose.runtime.DisposableEffect(route.itemId) {
        onDispose { scope.launch { runCatching { app.call("prefs.preloadCancel") } } }
    }

    val d = detail.valueOrNull
    val title = d.str("name") ?: ""
    val isEpisode = route.type == "Episode"

    LpScaffold(
        title = title.takeIf { rememberScrolled(list) },
        onBack = { nav.popBackStack() },
        scrolled = rememberScrolled(list),
        actions = {
            LpIconButton(if (favorite) LpIcons.heartOn else LpIcons.heart,
                if (favorite) "取消收藏" else "收藏") {
                scope.launch {
                    val want = !favorite
                    favorite = want // 乐观更新
                    runCatching {
                        app.call("emby.setFavorite",
                            args("item_id" to route.itemId, "favorite" to want))
                    }.onFailure { favorite = !want; app.report(it) } // ☠ 失败必须回滚
                }
            }
        },
    ) { pad ->
        LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
            item("hero") {
                // 集是**横版剧照**大图,其余是背景剧照 + 海报
                if (isEpisode) EpisodeHero(app, route.itemId, d)
                else SeriesHero(app, route.itemId, d)
            }

            item("actions") {
                Row(Modifier.fillMaxWidth().padding(horizontal = Sp.x16),
                    horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
                    val resume = d.dbl("resume_secs") ?: 0.0
                    LpButton(
                        when {
                            resume > 0 -> "继续 ${fmtTime(resume)}"
                            route.type == "Series" -> {
                                val next = episodes.firstOrNull { !it.played } ?: episodes.firstOrNull()
                                if (next != null) "播放 S${next.seasonNo ?: 1}E${next.episodeNo ?: 1}" else "播放"
                            }
                            else -> "播放"
                        },
                        {
                            val target = if (route.type == "Series")
                                (episodes.firstOrNull { !it.played } ?: episodes.firstOrNull())?.id ?: route.itemId
                            else route.itemId
                            nav.navigate(Route.Player(target, title))
                        },
                        Modifier.weight(1f),
                    )
                    LpButton(if (played) "标未看" else "标已看", {
                        scope.launch {
                            val want = !played
                            played = want
                            runCatching {
                                app.call("emby.setPlayed",
                                    args("item_id" to route.itemId, "played" to want))
                            }.onFailure { played = !want; app.report(it) }
                        }
                    }, kind = BtnKind.Secondary)
                }
            }

            d.str("overview")?.takeIf { it.isNotBlank() }?.let { ov ->
                item("overview") {
                    var expand by remember { mutableStateOf(false) }
                    Column(Modifier.fillMaxWidth().padding(Sp.x16).pressable({ expand = !expand })) {
                        Body(ov, maxLines = if (expand) Int.MAX_VALUE else 4)
                    }
                }
            }

            // 版本选择器。★ 只有一个版本时**整条不画** —— 一个只有一个选项的选择器是纯噪音
            if (versions.size > 1) item("versions") {
                Column(Modifier.padding(horizontal = Sp.x16, vertical = Sp.x8)) {
                    H2("版本")
                    Spacer(Modifier.height(Sp.x8))
                    Row(Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(Sp.x8)) {
                        versions.forEach { v ->
                            val on = (pickedVersion ?: defaultVersion(versions)?.id) == v.id
                            VerChip(v.name, on) { pickedVersion = v.id }
                        }
                    }
                }
            }

            // 季选择条。★ 只有一季时整条不画(同上那条规矩)
            if (seasons.size > 1) item("seasons") {
                Column(Modifier.padding(horizontal = Sp.x16, vertical = Sp.x8)) {
                    Row(Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(Sp.x8)) {
                        seasons.forEach { s ->
                            VerChip(s.name, s.id == curSeason?.id) {
                                curSeason = s
                                scope.launch {
                                    episodes = Item.list(app.block("emby.seasonEpisodes",
                                        args("season_id" to s.id)).valueOrNull)
                                }
                            }
                        }
                    }
                }
            }

            // 分集:剧集页是网格,单集页是横版选集栏。**共用同一张卡**,口径一样
            if (episodes.isNotEmpty()) item("episodes") {
                LpRow(
                    if (isEpisode) "选集" else "分集", episodes,
                    { app.imageUrl(it.id, "Primary", 220) },
                    { nav.navigate(Route.Detail(it.id, "Episode")) },
                    thumb = true,
                    menu = { cardActions(app, scope, it) },
                )
            }

            if (similar.isNotEmpty()) item("similar") {
                LpRow("相似推荐", similar, { app.imageUrl(it.id, "Primary", 330) },
                    { nav.navigate(Route.Detail(it.id, it.type)) },
                    menu = { cardActions(app, scope, it) })
            }

            item("tail") { Spacer(Modifier.height(Sp.x26)) }
        }
    }
}

/**
 * 唯一的「会播哪个版本」算法。
 * ☠ **不许自己回落 `versions[0]`** —— 核心层没标 preferred 就是「让核心层自己决定」,
 * UI 传 null 而不是替它选一个。
 */
internal fun defaultVersion(vs: List<Version>): Version? = vs.firstOrNull { it.preferred }

@Composable
private fun SeriesHero(app: xyz.linplayer.app.data.AppState, id: String, d: JsonObject?) {
    val c = Lp.colors
    Box(Modifier.fillMaxWidth().height(300.dp)) {
        NetImage(app.imageUrl(id, "Backdrop", 720), null, Modifier.fillMaxSize(), 0.dp)
        Box(Modifier.fillMaxSize().background(
            Brush.verticalGradient(0f to Color.Transparent, 0.5f to c.bg.copy(alpha = .6f), 1f to c.bg)))
        Row(Modifier.align(Alignment.BottomStart).padding(Sp.x16), verticalAlignment = Alignment.Bottom) {
            NetImage(app.imageUrl(id, "Primary", 330), null,
                Modifier.width(96.dp).aspectRatio(2f / 3f))
            Spacer(Modifier.width(Sp.x12))
            Column(Modifier.weight(1f)) {
                Text(d.str("name") ?: "", color = c.fg, fontSize = 20.sp,
                    fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(Sp.x4))
                Dim3(listOfNotNull(
                    d.long("year")?.toString(),
                    d.dbl("rating")?.let { "★ %.1f".format(it) },
                    d.dbl("runtime_secs")?.takeIf { it > 0 }?.let { fmtDur(it) },
                ).joinToString("  ·  "))
                d.strList("genres").take(3).takeIf { it.isNotEmpty() }?.let {
                    Spacer(Modifier.height(Sp.x4))
                    Dim3(it.joinToString(" · "))
                }
            }
        }
    }
}

@Composable
private fun EpisodeHero(app: xyz.linplayer.app.data.AppState, id: String, d: JsonObject?) {
    val c = Lp.colors
    Column {
        NetImage(app.imageUrl(id, "Primary", 480), null,
            Modifier.fillMaxWidth().aspectRatio(16f / 9f), 0.dp)
        Column(Modifier.padding(Sp.x16)) {
            d.str("series_name")?.let { Dim3(it) }
            Text(d.str("name") ?: "", color = c.fg, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(Sp.x4))
            Dim3(listOfNotNull(
                d.long("season_no")?.let { s -> d.long("episode_no")?.let { e -> "S${s}E$e" } },
                d.dbl("runtime_secs")?.takeIf { it > 0 }?.let { fmtDur(it) },
            ).joinToString("  ·  "))
        }
    }
}

@Composable
private fun VerChip(label: String, on: Boolean, onClick: () -> Unit) {
    val c = Lp.colors
    Text(
        label,
        Modifier.clip(RoundedCornerShape(R.pill))
            .background(if (on) c.acc else c.s2)
            .pressable(onClick)
            .padding(horizontal = Sp.x16, vertical = Sp.x10),
        color = if (on) c.accFg else c.fg2, fontSize = 13.sp, maxLines = 1,
    )
}

internal fun fmtTime(secs: Double): String {
    val s = secs.toLong()
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s % 3600 / 60, s % 60)
    else "%d:%02d".format(s / 60, s % 60)
}

internal fun fmtDur(secs: Double): String {
    val m = (secs / 60).toLong()
    return if (m >= 60) "${m / 60} 小时 ${m % 60} 分" else "$m 分钟"
}
