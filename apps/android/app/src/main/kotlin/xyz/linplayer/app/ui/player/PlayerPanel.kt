package xyz.linplayer.app.ui.player

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import xyz.linplayer.app.data.Item
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.ToastKind
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.dbl
import xyz.linplayer.app.data.long
import xyz.linplayer.app.data.strList
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.H2
import xyz.linplayer.app.ui.components.OptRow
import xyz.linplayer.app.ui.pages.args
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp

/**
 * 播放器面板。**从侧边推入,只占屏宽 42%**,不做通栏 sheet(UI_MOBILE.md §8.1 收纳手法 4)。
 *
 * ★ 「源」把**版本 + 线路合成一个入口**:有的服务器十几个版本、三十几条线路,
 *   解法不是「给个滚动条」,是分组。
 * ★ 线路是**三态**:未探(转圈)/ 探过不通(显示「—」,**不装成 0 ms**)/ 毫秒数。
 */
@Composable
fun PlayerPanel(kind: String, itemId: String, onClose: () -> Unit) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()
    val c = Lp.colors

    var options by remember { mutableStateOf<List<Triple<String, String?, String>>>(emptyList()) }
    var current by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }

    LaunchedEffect(kind, itemId) {
        loading = true; options = emptyList()
        when (kind) {
            "audio", "subtitle" -> {
                // ☠ `player.tracks` 返回**裸数组**,轨道类型的字段名是 `kind` 不是 `type`。
                //    两处都错的表现是音轨/字幕面板恒空,而且一句错都不报。
                val t = runCatching { app.call("player.tracks") }.getOrNull()
                val want = if (kind == "audio") "audio" else "sub"
                options = t.arr().mapNotNull {
                    val o = it.obj() ?: return@mapNotNull null
                    if (o.str("kind") != want) return@mapNotNull null
                    Triple(
                        o.str("id") ?: return@mapNotNull null,
                        o.str("lang"),
                        o.str("title") ?: o.str("lang") ?: "轨道",
                    )
                }
                current = t.arr().firstOrNull { it.obj().bool("selected") }.obj().str("id")
            }
            "source" -> {
                val m = runCatching { app.call("emby.itemMedia", args("item_id" to itemId)) }
                    .getOrNull()
                options = m.arr().mapNotNull {
                    val o = it.obj() ?: return@mapNotNull null
                    Triple(o.str("id") ?: return@mapNotNull null,
                        if (o.bool("preferred")) "推荐" else null, o.str("name") ?: "版本")
                }
            }
            "episodes" -> {
                val d = runCatching { app.call("emby.itemDetail", args("item_id" to itemId)) }
                    .getOrNull().obj()
                // ★ 季的主键叫 season_id(核心层这次补上的);Emby 的 ParentId 不在详情里
                val season = d.str("season_id")
                if (season != null) {
                    // 播放中**只拉一屏 40 条**
                    options = Item.list(runCatching {
                        app.call("emby.seasonEpisodes", args("parent_id" to season, "limit" to 40))
                    }.getOrNull()).map {
                        Triple(it.id, "${(it.runtimeSecs / 60).toInt()} 分钟",
                            "S${it.seasonNo ?: 1}E${it.episodeNo ?: 1} ${it.name}")
                    }
                    current = itemId
                }
            }
            "quality" -> {
                options = runCatching { app.call("player.shaderLevels") }.getOrNull().arr()
                    .mapNotNull {
                        val o = it.obj() ?: return@mapNotNull null
                        Triple(o.str("id") ?: return@mapNotNull null, o.str("group"),
                            o.str("name") ?: "档位")
                    }
            }
            "danmaku" -> {
                options = listOf(
                    Triple("on", null, "打开弹幕"),
                    Triple("off", null, "关闭弹幕"),
                )
                // 回显当前状态:不回显的话开关看起来永远是「两个都没选」
                current = if (runCatching { app.call("prefs.getPrefs") }
                        .getOrNull().obj().bool("danmaku_enabled")) "on" else "off"
            }
            "shot" -> {
                runCatching { app.call("player.screenshot") }
                    .onSuccess { app.toast("截图已保存", ToastKind.Ok) }
                    .onFailure { app.report(it) }
                onClose()
            }
            "more" -> {
                options = listOf(
                    Triple("ratio", null, "画面比例"),
                    Triple("sleep", null, "定时关闭"),
                    Triple("subtitle", null, "字幕"),
                )
            }
        }
        loading = false
    }

    val title = when (kind) {
        "source" -> "版本与线路"; "audio" -> "音轨"; "subtitle" -> "字幕"
        "episodes" -> "选集"; "quality" -> "画质"; "danmaku" -> "弹幕"; else -> "更多"
    }

    Box(Modifier.fillMaxSize()) {
        // scrim。★ OSD 在它之上(PlayerPage 的绘制顺序保证),所以面板开关期间上下栏一动不动
        Box(Modifier.fillMaxSize().background(c.scrim.copy(alpha = .5f))
            .pointerInput(Unit) { detectTapClose(onClose) })
        Column(
            Modifier.align(Alignment.CenterEnd).fillMaxHeight().fillMaxWidth(0.42f)
                .background(c.s2).safeDrawingPadding().padding(Sp.x12),
        ) {
            H2(title)
            Spacer(Modifier.height(Sp.x8))
            when {
                loading -> Dim3("正在取…")
                options.isEmpty() -> EmptyState("这里没有可选项", null)
                else -> LazyColumn(Modifier.fillMaxSize(), list) {
                    items(options, key = { it.first }) { (id, badge, label) ->
                        OptRow(label, {
                            scope.launch { pick(app, kind, id, itemId) }
                            onClose()
                        }, selected = id == current, badge = badge)
                    }
                }
            }
        }
    }

    // 打开面板要**滚动到当前项**
    LaunchedEffect(options, current) {
        val i = options.indexOfFirst { it.first == current }
        if (i >= 0) list.scrollToItem(i)
    }
}

private suspend fun pick(app: xyz.linplayer.app.data.AppState, kind: String, id: String, itemId: String) {
    runCatching {
        when (kind) {
            "audio" -> app.call("player.setTrack", args("kind" to "audio", "id" to id))
            "subtitle" -> app.call("player.setTrack", args("kind" to "sub", "id" to id))
            "source" -> app.call("player.play", args("item_id" to itemId, "media_source_id" to id))
            "episodes" -> app.call("player.play", args("item_id" to id))
            "quality" -> app.call("player.setShaderLevel", args("level" to id))
            /* 弹幕开关走 player.setDanmakuEnabled(2026-09-06 新增)。
               ☠ **不是** danmaku.setDanmakuConfig —— 那条收的是**弹幕源清单**,
                 传 enabled 进去核心层只会报「缺少 sources」。
               打开时顺手匹配一次本片的弹幕并灌进渲染层:开关只管开关,
               取哪一集是 danmaku.* 的事,两件事不合成一条命令。 */
            "danmaku" -> {
                app.call("player.setDanmakuEnabled", args("enabled" to (id == "on")))
                if (id == "on") loadDanmakuFor(app, itemId) else
                    app.call("player.danmakuSet", argsEmptyItems())
            }
            else -> Unit
        }
    }.onFailure { app.report(it) }
}

/**
 * 匹配本片弹幕并灌进播放器。
 *
 * ★ 匹配不上**不弹错**:九成片子本来就没有弹幕,弹一次错等于骂用户一次。
 *   `danmaku.autoLoad` 分不够时返回 null,那是正常结果不是失败。
 */
private suspend fun loadDanmakuFor(app: xyz.linplayer.app.data.AppState, itemId: String) {
    val d = runCatching { app.call("emby.itemDetail", args("item_id" to itemId)) }
        .getOrNull().obj() ?: return
    // ★ autoLoad 收的是**嵌套的 input 对象**(MatchInput),不是平铺参数。
    //   平铺传过去核心层只会报「缺少 input」。
    val title = d.str("series_name") ?: d.str("name") ?: return
    val input = buildMap<String, kotlinx.serialization.json.JsonElement> {
        put("title", kotlinx.serialization.json.JsonPrimitive(title))
        d.long("episode_no")?.let {
            put("episode_no", kotlinx.serialization.json.JsonPrimitive(it))
        }
        d.long("season_no")?.let {
            put("season_no", kotlinx.serialization.json.JsonPrimitive(it))
        }
        put("genres", kotlinx.serialization.json.JsonArray(
            d.strList("genres").map { kotlinx.serialization.json.JsonPrimitive(it) }))
    }
    val items = runCatching {
        app.call("danmaku.autoLoad", kotlinx.serialization.json.JsonObject(
            mapOf("input" to kotlinx.serialization.json.JsonObject(input))))
    }.getOrNull()
    if (items == null || items is kotlinx.serialization.json.JsonNull) {
        app.toast("这一集没匹配到弹幕")
        return
    }
    runCatching {
        app.call("player.danmakuSet",
            kotlinx.serialization.json.JsonObject(mapOf("items" to items)))
    }.onFailure { app.report(it) }
}

private fun argsEmptyItems() = kotlinx.serialization.json.JsonObject(
    mapOf("items" to kotlinx.serialization.json.JsonArray(emptyList())))

private suspend fun androidx.compose.ui.input.pointer.PointerInputScope.detectTapClose(onClose: () -> Unit) {
    detectTapGestures { onClose() }
}
