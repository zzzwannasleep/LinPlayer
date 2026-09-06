package xyz.linplayer.app.ui.pages

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.graphics.graphicsLayer
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
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.block
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.dbl
import xyz.linplayer.app.data.long
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.data.strList
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.DataStrip
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.GlassIcon
import xyz.linplayer.app.ui.components.IconAction
import xyz.linplayer.app.ui.components.Kicker
import xyz.linplayer.app.ui.components.Layer
import xyz.linplayer.app.ui.components.LpButton
import xyz.linplayer.app.ui.components.LpDialog
import xyz.linplayer.app.ui.components.LpImmersive
import xyz.linplayer.app.ui.components.LpRow
import xyz.linplayer.app.ui.components.NetImage
import xyz.linplayer.app.ui.components.OptRow
import xyz.linplayer.app.ui.components.PrimaryAction
import xyz.linplayer.app.ui.components.SectionTitle
import xyz.linplayer.app.ui.components.ToneChip
import xyz.linplayer.app.ui.components.dissolve
import xyz.linplayer.app.ui.components.pressable
import xyz.linplayer.app.ui.components.toneScene
import xyz.linplayer.app.ui.theme.Dim
import xyz.linplayer.app.ui.theme.LpEasing
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp
import xyz.linplayer.app.ui.theme.T
import xyz.linplayer.app.ui.theme.lpTween
import xyz.linplayer.app.ui.theme.rememberTone

/* ───────────────────────────── 数据 ───────────────────────────── */

/** 一条流。字段名照 `core/emby/mediainfo.go` 的 `StreamInfo`。 */
internal data class Stream(
    val index: Long, val type: String, val codec: String, val profile: String?,
    val title: String?, val lang: String?, val width: Long?, val height: Long?,
    val bitrate: Long?, val channels: Long?, val layout: String?, val fps: Double?,
    val range: String?, val isDefault: Boolean, val isExternal: Boolean,
) {
    val label: String get() = title ?: listOfNotNull(langCn(lang), codec.uppercase()).joinToString(" ")
}

/** 一个可播版本。`preferred` 由**核心层**标 —— UI 不许自己回落 `versions[0]`。 */
internal data class Version(
    val id: String, val name: String, val preferred: Boolean,
    val container: String? = null, val sizeBytes: Long? = null, val bitrate: Long? = null,
    val streams: List<Stream> = emptyList(),
) {
    fun of(kind: String) = streams.filter { it.type == kind }
    companion object {
        /** ☠ `emby.itemMedia` 返回的是**裸数组** `[]MediaVersion`,不是 `{versions:[…]}`。 */
        fun list(e: kotlinx.serialization.json.JsonElement?): List<Version> = e.arr().mapNotNull {
            val o = it.obj() ?: return@mapNotNull null
            Version(
                id = o.str("id") ?: return@mapNotNull null,
                name = o.str("name") ?: "版本",
                preferred = o.bool("preferred"),
                container = o.str("container"),
                sizeBytes = o.long("size_bytes"),
                bitrate = o.long("bitrate"),
                streams = o["streams"].arr().mapNotNull inner@{ se ->
                    val s = se.obj() ?: return@inner null
                    Stream(
                        index = s.long("index") ?: 0, type = s.str("type_") ?: "",
                        codec = s.str("codec") ?: "", profile = s.str("profile"),
                        title = s.str("display_title"), lang = s.str("language"),
                        width = s.long("width"), height = s.long("height"),
                        bitrate = s.long("bitrate"), channels = s.long("channels"),
                        layout = s.str("channel_layout"), fps = s.dbl("frame_rate"),
                        range = s.str("video_range_type") ?: s.str("video_range"),
                        isDefault = s.bool("is_default"), isExternal = s.bool("is_external"),
                    )
                },
            )
        }
    }
}

/** 一位演职人员。 */
internal data class Person(val id: String, val name: String)

/**
 * 唯一的「会播哪个版本」算法。
 * ☠ **不许自己回落 `versions[0]`** —— 核心层没标 preferred 就是「让核心层自己决定」,
 * UI 传 null 而不是替它选一个。这条有真实故障:正则真选对了版本,
 * 但详情页写死回落,用户看到的是「功能没生效」。
 */
internal fun defaultVersion(vs: List<Version>): Version? = vs.firstOrNull { it.preferred }

/* ───────────────────────────── 页面 ───────────────────────────── */

/**
 * 详情页族(U1.5)。版式照草稿 03(剧 / 影)与 04(集)。
 *
 * ☠ **封面不许有边界**【用户定 2026-09-06】:背景图下沿用 [dissolve] 把自己的 alpha 推到 0,
 *   露出来的是**从这张封面取的色**([rememberTone] + [toneScene])。
 *   盖一层「透明→背景色」的渐变是错的 —— 那会留下一块比周围略深的矩形。
 * ☠ **没有分享按钮**【用户定】—— 我们本来就分享不了。
 */
@Composable
fun DetailPage(nav: NavController, entry: NavBackStackEntry) {
    val route = entry.toRoute<Route.Detail>()
    val app = LocalApp.current
    val c = Lp.colors
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
    var people by remember { mutableStateOf<List<Person>>(emptyList()) }
    var favorite by remember { mutableStateOf(false) }
    var played by remember { mutableStateOf(false) }
    var audioLang by remember { mutableStateOf<String?>(null) }
    var subLang by remember { mutableStateOf<String?>(null) }
    var sheet by remember { mutableStateOf<String?>(null) }
    var serverId by remember { mutableStateOf<String?>(null) }
    /** 「哪台服务器的哪条线路」。取不到线路表时只有服务器名 —— 也比「服务器线路」四个字强。 */
    var lineLabel by remember { mutableStateOf<String?>(null) }

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
            favorite = o.bool("is_favorite")
            played = o.bool("played")
            people = o?.get("people").arr().mapNotNull {
                val p = it.obj() ?: return@mapNotNull null
                Person(p.str("id") ?: return@mapNotNull null, p.str("name") ?: "")
            }

            val seriesId = o.str("series_id") ?: route.itemId.takeIf { route.type == "Series" }
            // ★ 这两个值都从**详情**里取,在发下一条命令之前就读完 ——
            //   夹在 seriesSeasons 调用后面的话,`check-android-fields.py` 的窗口
            //   会把它算成 SeasonInfo 的字段,报一条查不出所以然的假红
            val wantSeason = o.str("season_id") ?: route.itemId
            if (seriesId != null &&
                (route.type == "Series" || route.type == "Season" || route.type == "Episode")) {
                launch {
                    seasons = Item.list(app.block("emby.seriesSeasons",
                        args("series_id" to seriesId)).valueOrNull)
                    // 集详情页要定位到**这一集所属的季**,不是第一季
                    val s = seasons.firstOrNull { it.id == wantSeason } ?: seasons.firstOrNull()
                    curSeason = s
                    if (s != null) episodes = Item.list(app.block("emby.seasonEpisodes",
                        args("parent_id" to s.id)).valueOrNull)
                }
            }
        }
        launch { versions = Version.list(app.block("emby.itemMedia", args("item_id" to route.itemId)).valueOrNull) }
        launch { similar = Item.list(app.block("emby.similarItems", args("item_id" to route.itemId)).valueOrNull) }
        launch {
            val p = runCatching { app.call("prefs.getPrefs") }.getOrNull().obj()
            audioLang = p.str("audio_lang"); subLang = p.str("sub_lang")
        }
        /* 线路那一行要跳线路页,而线路页认的是**账号 id**,不是当前生效的线路地址。
           拿 session.server 去传是错的 —— 换过线路之后那个值已经是中转地址了。 */
        launch {
            val raw = app.block("account.listAccounts").valueOrNull
            val active = xyz.linplayer.app.data.Account.list(raw).firstOrNull { it.isActive }
            serverId = active?.id
            /* ★★ 线路那一行要写**具体是哪台的哪条**【用户定 2026-09-06】。
               原来恒写死「服务器线路」—— 那句话对多线路用户等于没说:
               他想知道的正是「我现在连的是哪一条」。
               线路名和当前线路都只在**账号表**里(`lines[] / active_line`);
               `account.probeLines` 只发 index/ms/url,照它取值会恒「线路 N」。 */
            val accObj = raw.arr().firstOrNull { it.obj().str("server") == active?.id }.obj()
            val idx = accObj.long("active_line")?.toInt() ?: 0
            val lines = accObj?.get("lines").arr()
            val lineName = lines.getOrNull(idx).obj()?.str("name")?.takeIf { it.isNotBlank() }
                ?: if (lines.isEmpty()) "主线路" else "线路 ${idx + 1}"
            lineLabel = active?.name?.let { "$it · $lineName" } ?: lineName
        }
        // 进详情页就开始预热「▶ 会播的那个条目」。fire-and-forget,失败全吞
        launch { runCatching { app.call("prefs.preloadItem", args("item_id" to route.itemId)) } }
    }

    // 离页取消预热:留着不取消 = 用户翻十个详情就有十条流在偷偷拉
    androidx.compose.runtime.DisposableEffect(route.itemId) {
        // 同 PlayerPage:收尾要走 app.bg,composition 的 scope 这时已经在取消了
        onDispose { app.bg.launch { runCatching { app.call("prefs.preloadCancel") } } }
    }

    val d = detail.valueOrNull
    val title = d.str("name") ?: ""
    val isEpisode = route.type == "Episode"
    val isSeries = route.type == "Series" || route.type == "Season"
    /* ☠☠ **展示用的版本和「发给核心层的版本 id」是两回事,以前混成了一个。**
       `defaultVersion` 只认核心层标的 `preferred`,标不出来时返回 null —— 那是对的,
       因为**不许替核心层挑一个 id 发过去**(版本正则会被整个跳过)。
       但上一版把这个 null 直接当成了「没有版本可展示」,后果全落在集详情页上:
         · 音轨 / 字幕两行 `ver?.of(...)` 恒空 → onClick 恒 null → **点不动**
         · 「媒体信息」整块 `if (ver != null)` 不成立 → **整块不画**
       用户报的「音轨字幕选不了、缺媒体信息模块」是同一个 null。
       所以这里分成两个值:**展示**可以回落到第一条,**发命令**仍然只认 preferred。 */
    val ver = versions.firstOrNull { it.id == pickedVersion }
        ?: defaultVersion(versions) ?: versions.firstOrNull()

    // 底色从**海报**取,不从背景图取:海报是这部片的主视觉,背景图常常是一片夜景
    val tone = rememberTone(app.imageUrl(route.itemId, "Primary", 330), c.acc.copy(alpha = .9f))

    val toPlayer: (String) -> Unit = { target ->
        nav.navigate(Route.Player(target, title, pickedVersion ?: ver?.takeIf { it.preferred }?.id))
    }

    LpImmersive(bar = {
        GlassIcon(LpIcons.back, "返回") { nav.popBackStack() }
        Spacer(Modifier.weight(1f))
        // ★ 分享按钮**去掉了**。收藏挪进下面那排图标动作里,顶上只留一个「更多」
        GlassIcon(LpIcons.more, "更多") { sheet = "more" }
    }) { pad ->
        val f = detail
        if (f is Block.Fail && !f.isSilent) {
            xyz.linplayer.app.ui.components.ErrorState(f.message, null, Modifier.fillMaxSize())
            return@LpImmersive
        }

        // ★ 取色底铺满整屏并且**不跟着滚**:图往上走、色留在原地,那一层视差就是「华丽」的来源
        Box(Modifier.fillMaxSize().background(toneScene(tone, c.bg))) {
            LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
                item("hero") {
                    if (isEpisode) EpisodeHead(app, route.itemId, d, list)
                    else SeriesHead(app, route.itemId, d, list)
                }

                item("data") {
                    val cells = buildList {
                        d.dbl("rating")?.takeIf { it > 0 }?.let { add("%.1f".format(it) to "★ 评分") }
                        d.long("year")?.let { add(it.toString() to "年份") }
                        d.long("child_count")?.takeIf { it > 0 && isSeries }
                            ?.let { add(it.toString() to "集") }
                        d.dbl("runtime_secs")?.takeIf { it > 0 }
                            ?.let { add((it / 60).toInt().toString() to "分钟") }
                    }
                    if (cells.isNotEmpty()) {
                        Spacer(Modifier.height(Sp.x16))
                        DataStrip(cells)
                    }
                }

                item("tags") {
                    val tags = d.strList("genres").take(4) +
                        listOfNotNull(d.str("official_rating"), d.str("status"))
                    if (tags.isNotEmpty()) Row(
                        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                            .padding(start = Sp.x16, end = Sp.x16, top = Sp.x12),
                        horizontalArrangement = Arrangement.spacedBy(Sp.x6),
                    ) { tags.forEach { Tag(it) } }
                }

                item("actions") {
                    val resume = d.dbl("resume_secs") ?: 0.0
                    val runtime = d.dbl("runtime_secs") ?: 0.0
                    val nextEp = episodes.firstOrNull { !it.played } ?: episodes.firstOrNull()
                    Column(Modifier.padding(top = Sp.x16)) {
                        PrimaryAction(
                            text = when {
                                resume > 0 && runtime > resume ->
                                    "继续观看 · 还剩 ${fmtDur(runtime - resume)}"
                                isSeries && nextEp != null ->
                                    "播放 S${nextEp.seasonNo ?: 1}E${nextEp.episodeNo ?: 1}"
                                else -> "播放"
                            },
                            icon = LpIcons.play,
                            m = Modifier.padding(horizontal = Sp.x16),
                        ) { toPlayer(if (isSeries) (nextEp?.id ?: route.itemId) else route.itemId) }

                        Row(
                            Modifier.fillMaxWidth().padding(start = Sp.x10, end = Sp.x10, top = Sp.x12),
                            horizontalArrangement = Arrangement.SpaceEvenly,
                        ) {
                            IconAction(
                                if (favorite) LpIcons.heartOn else LpIcons.heart,
                                "收藏", on = favorite,
                            ) {
                                scope.launch {
                                    val want = !favorite
                                    favorite = want // 乐观更新
                                    runCatching {
                                        app.call("emby.setFavorite",
                                            args("item_id" to route.itemId, "fav" to want))
                                    }.onFailure { favorite = !want; app.report(it) } // ☠ 失败必须回滚
                                }
                            }
                            IconAction(LpIcons.check, if (played) "标未看" else "标已看", on = played) {
                                scope.launch {
                                    val want = !played
                                    played = want
                                    runCatching {
                                        app.call("emby.setPlayed",
                                            args("item_id" to route.itemId, "played" to want))
                                    }.onFailure { played = !want; app.report(it) }
                                }
                            }
                            IconAction(LpIcons.download, "下载") {
                                scope.launch {
                                    runCatching {
                                        app.call("download.enqueue", args("item_id" to route.itemId))
                                    }.onSuccess {
                                        app.toast("已加入下载队列", xyz.linplayer.app.data.ToastKind.Ok)
                                    }.onFailure { app.report(it) }
                                }
                            }
                            if (episodes.isNotEmpty()) IconAction(LpIcons.list, "选集") {
                                scope.launch { list.animateScrollToItem(6) }
                            }
                        }
                    }
                }

                /* ☠ 季 / 集**排在动作按钮和简介之间**【用户定 2026-09-06】。
                   原来它们排在「播放选项 / 媒体信息 / 演职人员」后面 —— 进剧集详情页
                   最常做的事是**找集**,不是读简介,把选集推到三屏以下等于没做。
                   ★ 一季的剧也画季那一栏:用户报「季度没显示出来」正是这一条 ——
                     `seasons.size > 1` 把单季剧整条藏掉了,而那是最常见的情况。 */
                if (seasons.isNotEmpty()) item("seasons") {
                    SectionTitle("季")
                    Row(
                        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                            .padding(horizontal = Sp.x16, vertical = Sp.x6),
                        horizontalArrangement = Arrangement.spacedBy(Sp.x8),
                    ) {
                        seasons.forEach { s2 ->
                            ToneChip(s2.name, s2.id == curSeason?.id) {
                                curSeason = s2
                                episodes = emptyList()   // 先清空:留着上一季的会让人以为没换
                                scope.launch {
                                    episodes = Item.list(app.block("emby.seasonEpisodes",
                                        args("parent_id" to s2.id)).valueOrNull)
                                }
                            }
                        }
                    }
                }

                if (episodes.isNotEmpty()) item("episodes") {
                    SectionTitle(
                        curSeason?.name?.let { "$it · 选集" } ?: "选集",
                        trailing = { Dim3("已看 ${episodes.count { it.played }} / ${episodes.size}") },
                    )
                    EpisodeStrip(
                        app, episodes, currentId = route.itemId,
                        onOpen = { ep -> nav.navigate(Route.Detail(ep.id, "Episode")) },
                    )
                }

                d.str("overview")?.takeIf { it.isNotBlank() }?.let { ov ->
                    item("overview") { Overview(ov) }
                }

                if (people.isNotEmpty()) item("people") { People(app, people) }

                /* 播放选项:**版本 / 线路 / 音轨 / 字幕**【用户点名要的四项】。
                   剧集页不画 —— 那是整部剧,选版本没有意义;进到某一集里才有。 */
                if (!isSeries) item("pick") {
                    SectionTitle("播放选项")
                    PickList(
                        rows = listOf(
                            PickRow(
                                "版本", ver?.name ?: "默认",
                                extra = if (versions.size > 1) "共 ${versions.size} 个" else null,
                                onClick = if (versions.size > 1) ({ sheet = "version" }) else null,
                            ),
                            PickRow(
                                "线路", lineLabel ?: "默认线路",
                                onClick = serverId?.let { sid ->
                                    // 线路页认的是**账号 id**,不是当前生效的线路地址 ——
                                    // 换过线路之后 session.server 已经是中转地址了
                                    ({ nav.navigate(Route.Lines(sid, title)) })
                                },
                            ),
                            PickRow(
                                "音轨", trackLabel(ver?.of("Audio"), audioLang),
                                onClick = if ((ver?.of("Audio")?.size ?: 0) > 1)
                                    ({ sheet = "audio" }) else null,
                            ),
                            PickRow(
                                "字幕", trackLabel(ver?.of("Subtitle"), subLang, subOff = subLang == ""),
                                onClick = if (!ver?.of("Subtitle").isNullOrEmpty())
                                    ({ sheet = "sub" }) else null,
                            ),
                        ),
                    )
                }

                // 媒体信息:**照 Emby 官端分组成卡**,不是一张 kv 大表
                if (!isSeries && ver != null) item("media") {
                    SectionTitle("媒体信息")
                    MediaCards(ver)
                }

                /* 季 / 集**两条横滑栏**(照 PC 端)【用户定 2026-09-06】。
                   ★ 换季那一栏一动,下面的集数栏当场跟着换 —— 两栏是一条链,不是两个列表。
                   ★ 点一集进的是**这一集的详情页**,不是直接起播:起播是详情页里那颗大按钮。
                     上一版是一条竖着的长列表,把整页撑得看不到下面的相似推荐。 */
                if (similar.isNotEmpty()) item("similar") {
                    LpRow("相似推荐", similar, { app.imageUrl(it.id, "Primary", 330) },
                        { nav.navigate(Route.Detail(it.id, it.type)) },
                        menu = { cardActions(app, scope, it) })
                }

                item("tail") { Spacer(Modifier.height(Sp.x26)) }
            }
        }
    }

    /* ── 选择弹窗。**全站没有 bottom sheet**,一律居中弹窗 ── */
    when (sheet) {
        "version" -> LpDialog({ sheet = null }, "选择版本") {
            Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                versions.forEach { v ->
                    OptRow(
                        v.name, { pickedVersion = v.id; sheet = null },
                        sub = listOfNotNull(v.container?.uppercase(), fmtSize(v.sizeBytes),
                            fmtRate(v.bitrate)).joinToString(" · ").takeIf { it.isNotEmpty() },
                        selected = v.id == ver?.id,
                        badge = if (v.preferred) "正则选中" else null,
                    )
                }
            }
        }
        "audio" -> LangDialog(
            "首选音轨语言", ver?.of("Audio").orEmpty(), audioLang, allowOff = false,
            onPick = { lang ->
                audioLang = lang; sheet = null
                // ☠ **两项必须一起发**:核心层的 setPrefs 是无条件覆盖,
                //   只发 audio_lang 会把 sub_lang 清成 null
                scope.launch { savePrefs(app, lang, subLang) }
            },
            onDismiss = { sheet = null },
        )
        "sub" -> LangDialog(
            "首选字幕语言", ver?.of("Subtitle").orEmpty(), subLang, allowOff = true,
            onPick = { lang ->
                subLang = lang; sheet = null
                scope.launch { savePrefs(app, audioLang, lang) }
            },
            onDismiss = { sheet = null },
        )
        "more" -> LpDialog({ sheet = null }, title) {
            Column {
                OptRow("屏蔽这个条目", {
                    sheet = null
                    scope.launch {
                        runCatching {
                            app.call("emby.setBlocked",
                                args("id" to route.itemId, "name" to title, "blocked" to true))
                        }.onSuccess { nav.popBackStack() }.onFailure { app.report(it) }
                    }
                })
                Spacer(Modifier.height(Sp.x8))
                LpButton("关闭", { sheet = null }, Modifier.fillMaxWidth(),
                    xyz.linplayer.app.ui.components.BtnKind.Secondary)
            }
        }
    }
}

private suspend fun savePrefs(app: xyz.linplayer.app.data.AppState, audio: String?, sub: String?) {
    runCatching {
        app.call("prefs.setPrefs", JsonObject(buildMap {
            put("audio_lang", kotlinx.serialization.json.JsonPrimitive(audio ?: ""))
            put("sub_lang", kotlinx.serialization.json.JsonPrimitive(sub ?: ""))
            put("sub_enabled", kotlinx.serialization.json.JsonPrimitive(sub != ""))
        }))
    }.onFailure { app.report(it) }
}

/* ───────────────────────────── 头部 ───────────────────────────── */

/**
 * 剧 / 影头部(草稿 03)。
 *
 * ★ 结构是**图 236 + 海报下探 78** —— 海报压在图的下沿上,而图的下沿已经溶掉了,
 *   所以没有任何一条边:海报是从颜色里长出来的。
 * ★ 标题拆两级:眉标 → 主名 25sp → 副名 16sp 半透明。
 *   「鬼灭之刃 无限城篇」挤在一行是上一稿最明显的塌陷点。
 */
@Composable
private fun SeriesHead(
    app: xyz.linplayer.app.data.AppState,
    id: String,
    d: JsonObject?,
    list: androidx.compose.foundation.lazy.LazyListState,
) {
    val c = Lp.colors
    val imgH = Dim.coverDetail
    Box(Modifier.fillMaxWidth().height(imgH + 66.dp)) {
        Box(
            Modifier.fillMaxWidth().height(imgH)
                // 视差:图跟着滚一半 —— 海报和文字按正常速度走,两层错开才有纵深
                .graphicsLayer {
                    val off = if (list.firstVisibleItemIndex == 0)
                        list.firstVisibleItemScrollOffset.toFloat() else imgH.toPx()
                    translationY = off * 0.35f
                }
                .dissolve(0.54f, 0.99f)
        ) {
            NetImage(app.imageUrl(id, "Backdrop", 720), null, Modifier.fillMaxSize(), 0.dp)
            // 顶上压一层:给浮在图上的状态栏和返回键留可读性。**不是给它留黑底**
            Box(
                Modifier.fillMaxSize().background(
                    Brush.verticalGradient(
                        0.00f to Color.Black.copy(alpha = .52f),
                        0.30f to Color.Transparent,
                        0.78f to Color.Black.copy(alpha = .34f),
                        1.00f to Color.Black.copy(alpha = .62f),
                    )
                )
            )
        }
        Row(
            Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(horizontal = Sp.x16),
            verticalAlignment = Alignment.Bottom,
        ) {
            NetImage(
                app.imageUrl(id, "Primary", 330), null,
                Modifier.width(96.dp).aspectRatio(2f / 3f), 14.dp,
            )
            Spacer(Modifier.width(13.dp))
            Column(Modifier.weight(1f).padding(bottom = Sp.x6)) {
                Kicker(kickerOf(d), color = c.fg2)
                Spacer(Modifier.height(Sp.x4))
                Text(
                    d.str("name") ?: "", color = c.fg, fontSize = 25.sp,
                    fontWeight = FontWeight.Bold, lineHeight = 28.sp,
                    maxLines = 3, overflow = TextOverflow.Ellipsis,
                )
                // 标语实测只有三成条目有 —— **没有就整行不画,不留空位**
                d.str("tagline")?.takeIf { it.isNotBlank() }?.let {
                    Spacer(Modifier.height(3.dp))
                    Text(it, color = c.fg.copy(alpha = .82f), fontSize = 16.sp,
                        maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

/**
 * 集头部(草稿 04)。
 *
 * ★ **封面上没有播放键**【用户定 2026-09-06】—— 下面那颗宽按钮就是播放,
 *   在封面上再来一个是同一件事写两遍。那块地方改放标题。
 */
@Composable
private fun EpisodeHead(
    app: xyz.linplayer.app.data.AppState,
    id: String,
    d: JsonObject?,
    list: androidx.compose.foundation.lazy.LazyListState,
) {
    val c = Lp.colors
    val runtime = d.dbl("runtime_secs") ?: 0.0
    val resume = d.dbl("resume_secs") ?: 0.0
    Box(Modifier.fillMaxWidth().aspectRatio(16f / 10.4f)) {
        Box(
            Modifier.fillMaxSize()
                .graphicsLayer {
                    val off = if (list.firstVisibleItemIndex == 0)
                        list.firstVisibleItemScrollOffset.toFloat() else size.height
                    translationY = off * 0.35f
                }
                .dissolve(0.50f, 0.99f)
        ) {
            NetImage(app.imageUrl(id, "Primary", 480), null, Modifier.fillMaxSize(), 0.dp)
            Box(
                Modifier.fillMaxSize().background(
                    Brush.verticalGradient(
                        0.00f to Color.Black.copy(alpha = .52f),
                        0.34f to Color.Transparent,
                        0.72f to Color.Black.copy(alpha = .40f),
                        1.00f to Color.Black.copy(alpha = .70f),
                    )
                )
            )
        }
        Column(
            Modifier.align(Alignment.BottomStart).fillMaxWidth()
                .padding(start = Sp.x16, end = Sp.x16, bottom = Sp.x12),
        ) {
            d.str("series_name")?.let {
                Text(it, color = c.fg2, fontSize = 12.sp, maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
            }
            Kicker(
                listOfNotNull(
                    d.long("season_no")?.let { "S$it" }, d.long("episode_no")?.let { "E$it" },
                ).joinToString(" · "),
                color = c.acc,
            )
            Spacer(Modifier.height(Sp.x4))
            Text(
                d.str("name") ?: "", color = c.fg, fontSize = 23.sp,
                fontWeight = FontWeight.Bold, lineHeight = 27.sp,
                maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(Sp.x6))
            Dim3(
                listOfNotNull(
                    runtime.takeIf { it > 0 }?.let { fmtDur(it) },
                    (runtime - resume).takeIf { resume > 0 && it > 0 }?.let { "还剩 ${fmtDur(it)}" },
                ).joinToString(" · ")
            )
            // 进度贴在图的下沿:一眼看到上次停在哪,不用读那行小字
            if (runtime > 0 && resume > 0) {
                Spacer(Modifier.height(Sp.x10))
                Box(
                    Modifier.fillMaxWidth().height(3.dp)
                        .clip(RoundedCornerShape(R.pill)).background(c.line2)
                ) {
                    Box(
                        Modifier.fillMaxWidth((resume / runtime).toFloat().coerceIn(0f, 1f))
                            .height(3.dp).clip(RoundedCornerShape(R.pill)).background(c.acc)
                    )
                }
            }
        }
    }
}

private fun kickerOf(d: JsonObject?): String = when (d.str("type_")) {
    "Series" -> "剧集"
    "Season" -> "季"
    "Movie" -> "电影"
    "Episode" -> "分集"
    else -> "条目"
}

/* ───────────────────────────── 区块 ───────────────────────────── */

@Composable
private fun Tag(text: String) {
    val c = Lp.colors
    Text(
        text,
        Modifier.clip(RoundedCornerShape(R.pill)).background(c.s1)
            .padding(horizontal = Sp.x10, vertical = 3.dp),
        color = c.fg.copy(alpha = .86f), fontSize = 11.sp, maxLines = 1,
    )
}

/** 简介。**装进一张带层次的卡里,不是裸文字** —— 正文有了边界,下面的选项组才不会读成同一段。 */
@Composable
private fun Overview(text: String) {
    val c = Lp.colors
    var expand by remember { mutableStateOf(false) }
    SectionTitle("简介")
    Layer(Modifier.padding(horizontal = Sp.x16), corner = 16.dp) {
        Column(Modifier.pressable({ expand = !expand }).padding(horizontal = 14.dp, vertical = 13.dp)) {
            Text(
                text, color = c.fg2, fontSize = 13.sp, lineHeight = 21.sp,
                maxLines = if (expand) Int.MAX_VALUE else 4, overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(Sp.x6))
            Text(if (expand) "收起" else "展开", color = c.acc, fontSize = 12.sp,
                fontWeight = FontWeight.Medium)
        }
    }
}

@Composable
private fun People(app: xyz.linplayer.app.data.AppState, people: List<Person>) {
    val c = Lp.colors
    SectionTitle("演员")
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            .padding(horizontal = Sp.x16),
        horizontalArrangement = Arrangement.spacedBy(Sp.x12),
    ) {
        people.take(20).forEach { p ->
            Column(Modifier.width(54.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                NetImage(app.imageUrl(p.id, "Primary", 120), p.name, Modifier.size(54.dp), R.pill)
                Spacer(Modifier.height(5.dp))
                Text(p.name, color = c.fg2, fontSize = 10.5.sp, maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }
        }
    }
}

/**
 * 一行播放选项。
 * ★ `onClick` 为 null = **这一行只是在告诉你会用哪个**,没有别的可选。
 *   照样画一个箭头、点了没反应,是界面在撒谎 —— 只有一个选项的选择器本来就不该是选择器。
 */
private data class PickRow(
    val label: String, val value: String, val extra: String? = null,
    val onClick: (() -> Unit)? = null,
)

/** 播放选项组:**无描边**,行与行之间是一道内发丝,不是分割线。 */
@Composable
private fun PickList(rows: List<PickRow>) {
    val c = Lp.colors
    Layer(Modifier.padding(horizontal = Sp.x16), corner = 16.dp) {
        Column {
            rows.forEachIndexed { i, r ->
                if (i > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(c.line))
                Row(
                    Modifier.fillMaxWidth().heightIn(min = Dim.tap)
                        .then(r.onClick?.let { Modifier.pressable(it) } ?: Modifier)
                        .padding(horizontal = 14.dp, vertical = 11.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(r.label, color = c.fg2, fontSize = 12.5.sp, modifier = Modifier.width(38.dp))
                    Spacer(Modifier.weight(1f))
                    Text(
                        r.value, color = c.fg, fontSize = 13.sp, fontWeight = FontWeight.Medium,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(3f, fill = false),
                        textAlign = androidx.compose.ui.text.style.TextAlign.End,
                    )
                    r.extra?.let {
                        Spacer(Modifier.width(Sp.x6))
                        Text(it, color = c.acc, fontSize = 11.sp, maxLines = 1)
                    }
                    if (r.onClick != null) Icon(LpIcons.chevR, null,
                        Modifier.padding(start = Sp.x6).size(15.dp), tint = c.fg3)
                    else Spacer(Modifier.width(Sp.x6))
                }
            }
        }
    }
}

/**
 * 媒体信息卡(照 Emby 官端分组)。
 * ★ **卡头写摘要,卡里逐条列** —— 一张 kv 大表读不出「这是视频那是音频」。
 */
@Composable
private fun MediaCards(v: Version) {
    val video = v.of("Video").firstOrNull()
    val audio = v.of("Audio")
    val subs = v.of("Subtitle")

    InfoCard("常规", listOfNotNull(v.container?.uppercase(), fmtSize(v.sizeBytes)).joinToString(" · "),
        listOfNotNull(
            v.container?.let { "容器" to it.uppercase() },
            fmtRate(v.bitrate)?.let { "总比特率" to it },
            v.sizeBytes?.let { "文件大小" to fmtSize(it).orEmpty() },
        ))

    if (video != null) InfoCard(
        "视频",
        listOfNotNull(video.codec.uppercase(), video.height?.let { "${it}p" }).joinToString(" · "),
        listOfNotNull(
            "编解码器" to listOfNotNull(video.codec.uppercase(), video.profile).joinToString(" "),
            video.width?.let { w -> video.height?.let { h -> "分辨率" to "$w × $h" } },
            video.fps?.takeIf { it > 0 }?.let { "帧率" to "%.3f fps".format(it) },
            video.range?.let { "动态范围" to it },
            fmtRate(video.bitrate)?.let { "比特率" to it },
        ))

    audio.forEachIndexed { i, a ->
        InfoCard(
            if (audio.size > 1) "音频 ${i + 1}" else "音频",
            listOfNotNull(langCn(a.lang), a.codec.uppercase()).joinToString(" · "),
            listOfNotNull(
                "编解码器" to listOfNotNull(a.codec.uppercase(), a.profile).joinToString(" "),
                a.layout?.let { "声道" to it } ?: a.channels?.let { "声道数" to it.toString() },
                langCn(a.lang)?.let { "语言" to it },
                fmtRate(a.bitrate)?.let { "比特率" to it },
            ))
    }

    if (subs.isNotEmpty()) InfoCard(
        "字幕", "${subs.size} 条",
        subs.take(8).map { s ->
            (langCn(s.lang) ?: s.codec.uppercase()) to
                listOfNotNull(s.codec.uppercase(), if (s.isExternal) "外挂" else "内封")
                    .joinToString(" · ")
        })
}

@Composable
private fun InfoCard(title: String, summary: String, rows: List<Pair<String, String>>) {
    val c = Lp.colors
    if (rows.isEmpty()) return
    Layer(Modifier.padding(start = Sp.x16, end = Sp.x16, bottom = 9.dp), corner = 16.dp) {
        Column {
            Row(
                Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 9.dp, bottom = 7.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                Text(title, color = c.fg, fontSize = 12.5.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                Text(summary, color = c.fg3, fontSize = 11.sp, maxLines = 1)
            }
            rows.forEachIndexed { i, (k, val2) ->
                Row(
                    Modifier.fillMaxWidth().padding(
                        start = 14.dp, end = 14.dp, top = 4.dp,
                        bottom = if (i == rows.lastIndex) 11.dp else 4.dp,
                    )
                ) {
                    Text(k, color = c.fg3, fontSize = 12.sp)
                    Spacer(Modifier.weight(1f))
                    Text(
                        val2, color = c.fg2, fontSize = 12.sp, maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = androidx.compose.ui.text.style.TextAlign.End,
                    )
                }
            }
        }
    }
}

/**
 * 集数栏:**一条横滑的卡带**(草稿 03 的 `.eplist` 横过来)。
 *
 * ★ 高度按 sp 现算,不写死 dp —— 系统字号放大时写死的 dp 会把集名裁掉半行
 *   (和首页那两条轨道同一个坑,见 `Cards.kt` 的 `rowHeight`)。
 * ★ **正在看的那一集用状态表达,不用文字**:一圈琥珀描边 + 集号变琥珀。
 * ★ 逐张错开 22ms 上浮进场,只跑一次。
 */
@Composable
private fun EpisodeStrip(
    app: xyz.linplayer.app.data.AppState,
    episodes: List<Item>,
    currentId: String,
    onOpen: (Item) -> Unit,
) {
    val h = with(androidx.compose.ui.platform.LocalDensity.current) {
        // 封面 16:9 + 集号行 + 两行集名 + 时长行
        EpCardW * 9 / 16 + Sp.x6 + 15.sp.toDp() + 17.sp.toDp() * 2 + 15.sp.toDp() + Sp.x8
    }
    LazyRow(
        Modifier.fillMaxWidth().height(h),
        contentPadding = PaddingValues(horizontal = Sp.x16),
        horizontalArrangement = Arrangement.spacedBy(Sp.x10),
    ) {
        itemsIndexed(episodes, key = { _, e -> e.id }, contentType = { _, _ -> "ep" }) { i, ep ->
            EpCard(app, ep, i, ep.id == currentId) { onOpen(ep) }
        }
    }
}

private val EpCardW = 168.dp

@Composable
private fun EpCard(
    app: xyz.linplayer.app.data.AppState,
    ep: Item,
    index: Int,
    current: Boolean,
    onOpen: () -> Unit,
) {
    val c = Lp.colors
    var shown by remember(ep.id) { mutableStateOf(false) }
    LaunchedEffect(ep.id) {
        kotlinx.coroutines.delay((index.coerceAtMost(8) * 22).toLong()); shown = true
    }
    val a by animateFloatAsState(
        if (shown) 1f else 0f, lpTween(T.T5, LpEasing.emphasizedDecelerate), label = "epIn")

    Column(
        Modifier.width(EpCardW)
            .graphicsLayer { alpha = a; translationY = (1f - a) * 16f }
            .pressable(onOpen)
    ) {
        Box(
            Modifier.fillMaxWidth().aspectRatio(16f / 9f)
                .clip(RoundedCornerShape(12.dp))
                .then(
                    if (current) Modifier.border(2.dp, c.acc, RoundedCornerShape(12.dp))
                    else Modifier
                )
        ) {
            NetImage(app.imageUrl(ep.id, "Primary", 330), null, Modifier.fillMaxSize(), 12.dp)
            if (ep.progress > 0f) Box(
                Modifier.align(Alignment.BottomStart).fillMaxWidth().height(2.dp)
                    .background(c.line2)
            ) { Box(Modifier.fillMaxWidth(ep.progress).height(2.dp).background(c.acc)) }
            if (ep.played) Box(
                Modifier.align(Alignment.TopEnd).padding(Sp.x6).size(18.dp)
                    .clip(RoundedCornerShape(R.pill)).background(c.ok),
                contentAlignment = Alignment.Center,
            ) { Icon(LpIcons.check, "已看完", Modifier.size(11.dp), tint = Color(0xFF062418)) }
        }
        Spacer(Modifier.height(Sp.x6))
        Text(
            "EP %02d".format(ep.episodeNo ?: (index + 1).toLong()),
            color = if (current) c.acc else c.fg3, fontSize = 11.sp, lineHeight = 15.sp,
            fontWeight = FontWeight.Bold, letterSpacing = 1.1.sp,
        )
        Text(
            ep.name, color = c.fg, fontSize = 12.5.sp, fontWeight = FontWeight.Medium,
            lineHeight = 17.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
        )
        Text(
            if (ep.progress > 0f && ep.runtimeSecs > 0)
                "还剩 ${fmtDur(ep.runtimeSecs - ep.resumeSecs)}"
            else fmtDur(ep.runtimeSecs),
            color = c.fg3, fontSize = 11.sp, lineHeight = 15.sp, maxLines = 1,
        )
    }
}

/** 语言选择弹窗。 */
@Composable
private fun LangDialog(
    title: String,
    streams: List<Stream>,
    current: String?,
    allowOff: Boolean,
    onPick: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val langs = streams.mapNotNull { it.lang }.distinct()
    LpDialog(onDismiss, title) {
        Column(Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState())) {
            if (langs.isEmpty()) Dim3("这个版本里没有可选的轨。", Modifier.padding(Sp.x12), maxLines = 3)
            langs.forEach { l ->
                OptRow(
                    langCn(l) ?: l, { onPick(l) },
                    sub = streams.firstOrNull { it.lang == l }?.label,
                    selected = l == current,
                )
            }
            if (allowOff) OptRow("不显示字幕", { onPick("") }, selected = current == "")
            Spacer(Modifier.height(Sp.x8))
            LpButton("关闭", onDismiss, Modifier.fillMaxWidth(),
                xyz.linplayer.app.ui.components.BtnKind.Secondary)
        }
    }
}

/* ───────────────────────────── 小工具 ───────────────────────────── */

/** 播放选项里那一行显示什么。**显示的必须是真会播的那一条**,不是列表第一条。 */
private fun trackLabel(streams: List<Stream>?, prefer: String?, subOff: Boolean = false): String {
    if (subOff) return "关闭"
    val ss = streams.orEmpty()
    if (ss.isEmpty()) return "无"
    val hit = prefer?.takeIf { it.isNotEmpty() }?.let { p -> ss.firstOrNull { it.lang == p } }
    val use = hit ?: ss.firstOrNull { it.isDefault } ?: ss.first()
    return use.label.ifBlank { langCn(use.lang) ?: use.codec.uppercase() }
}

/** ISO 639-2 → 中文。查不到就原样返回 —— **不编一个名字出来**。 */
internal fun langCn(code: String?): String? = when (code?.lowercase()) {
    null, "" -> null
    "chi", "zho", "zh", "cmn" -> "中文"
    "jpn", "ja" -> "日语"
    "eng", "en" -> "英语"
    "kor", "ko" -> "韩语"
    "fre", "fra", "fr" -> "法语"
    "ger", "deu", "de" -> "德语"
    "spa", "es" -> "西班牙语"
    "rus", "ru" -> "俄语"
    "ita", "it" -> "意大利语"
    "und" -> "未标注"
    else -> code
}

internal fun fmtSize(bytes: Long?): String? {
    val b = bytes ?: return null
    if (b <= 0) return null
    val g = b / 1024.0 / 1024.0 / 1024.0
    return if (g >= 1) "%.1f GB".format(g) else "%.0f MB".format(b / 1024.0 / 1024.0)
}

internal fun fmtRate(bps: Long?): String? {
    val v = bps ?: return null
    if (v <= 0) return null
    return "%.1f Mbps".format(v / 1_000_000.0)
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
