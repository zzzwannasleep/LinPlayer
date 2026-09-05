package xyz.linplayer.app.data

import androidx.compose.runtime.Immutable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/*
 * 核心层的返回是 JSON,这里只做「JSON → 显示用的不可变数据类」这一步。
 *
 * ★ 不用 @Serializable 自动反序列化:核心层的字段随版本会加,
 *   而 kotlinx 默认对未知字段是报错的。手写取值 = 加字段不会把界面打红,
 *   少字段也只是那一项没有。这是**跨进程边界**该有的宽容度。
 * ★ 数据类一律 @Immutable + 只读集合:Compose 的强跳过模式靠它跳过重组。
 */

// ---------------------------------------------------------------- 取值助手

fun JsonElement?.obj(): JsonObject? = this as? JsonObject
fun JsonElement?.arr(): List<JsonElement> = (this as? JsonArray) ?: emptyList()
fun JsonObject?.str(k: String): String? = this?.get(k)?.jsonPrimitive?.contentOrNull
fun JsonObject?.long(k: String): Long? = this?.get(k)?.jsonPrimitive?.longOrNull
fun JsonObject?.dbl(k: String): Double? = this?.get(k)?.jsonPrimitive?.doubleOrNull
fun JsonObject?.bool(k: String): Boolean = this?.get(k)?.jsonPrimitive?.booleanOrNull == true
fun JsonObject?.strList(k: String): List<String> =
    this?.get(k).arr().mapNotNull { it.jsonPrimitive.contentOrNull }

/** 条目。字段名照 `core/emby/emby.go` 的 `Item`(JSON 名一致,对账靠的就是这个)。 */
@Immutable
data class Item(
    val id: String,
    val name: String,
    val type: String,
    val isFolder: Boolean = false,
    val runtimeSecs: Double = 0.0,
    val resumeSecs: Double = 0.0,
    val seriesName: String? = null,
    val seriesId: String? = null,
    val episodeNo: Long? = null,
    val seasonNo: Long? = null,
    val played: Boolean = false,
    /** 未看子项数。played 时必为 0 —— **有勾优先,否则显数字** */
    val unplayed: Long = 0,
    val genres: List<String> = emptyList(),
    val year: Long? = null,
    val rating: Double? = null,
) {
    val isSeries: Boolean get() = type == "Series"
    val isEpisode: Boolean get() = type == "Episode"

    /** 卡下第一行。**剧集恒带剧名** —— Emby 的 Episode.Name 只是「第 35 集」,单看无意义。 */
    val cardTitle: String get() = seriesName ?: name

    /** 卡下第二行。是某一集时写 SxEy,否则写年份。 */
    val cardSub: String?
        get() = when {
            seriesName != null && seasonNo != null && episodeNo != null -> "S${seasonNo}E${episodeNo}"
            year != null -> year.toString()
            else -> null
        }

    val progress: Float
        get() = if (runtimeSecs > 0 && resumeSecs > 0) (resumeSecs / runtimeSecs).toFloat().coerceIn(0f, 1f) else 0f

    companion object {
        fun from(e: JsonElement?): Item? {
            val o = e.obj() ?: return null
            val id = o.str("id") ?: return null
            return Item(
                id = id,
                name = o.str("name") ?: "",
                type = o.str("type_") ?: "",
                isFolder = o.bool("is_folder"),
                runtimeSecs = o.dbl("runtime_secs") ?: 0.0,
                resumeSecs = o.dbl("resume_secs") ?: 0.0,
                seriesName = o.str("series_name"),
                seriesId = o.str("series_id"),
                episodeNo = o.long("episode_no"),
                seasonNo = o.long("season_no"),
                played = o.bool("played"),
                unplayed = o.long("unplayed_item_count") ?: 0,
                genres = o.strList("genres"),
                year = o.long("year"),
                rating = o.dbl("rating"),
            )
        }

        fun list(e: JsonElement?): List<Item> = e.arr().mapNotNull { from(it) }
    }
}

/** 一页结果(含总数)。`total` 为 null 表示服务端给不出 —— UI 显示「加载更多」而非进度。 */
@Immutable
data class Page(val items: List<Item>, val total: Long?) {
    companion object {
        fun from(e: JsonElement?): Page {
            val o = e.obj() ?: return Page(Item.list(e), null)
            return Page(Item.list(o["items"]), o.long("total"))
        }
    }
}

/** 媒体库。 */
@Immutable
data class View(val id: String, val name: String, val collectionType: String?) {
    companion object {
        fun list(e: JsonElement?): List<View> = e.arr().mapNotNull {
            val o = it.obj() ?: return@mapNotNull null
            View(o.str("id") ?: return@mapNotNull null, o.str("name") ?: "", o.str("collection_type"))
        }
    }
}

/** 服务器账号。 */
@Immutable
data class Account(
    val id: String,
    val server: String,
    val name: String,
    val remark: String?,
    val userName: String?,
    val isActive: Boolean,
    val kind: String?,
) {
    companion object {
        fun list(e: JsonElement?): List<Account> = e.arr().mapNotNull {
            val o = it.obj() ?: return@mapNotNull null
            val server = o.str("server") ?: return@mapNotNull null
            Account(
                id = o.str("id") ?: server,
                server = server,
                // 名字取不到就回落 host —— 核心层探服务器名是「锦上添花」,探失败不挡登录
                name = o.str("name")?.takeIf { s -> s.isNotBlank() } ?: hostOf(server),
                remark = o.str("remark"),
                userName = o.str("user_name") ?: o.str("username"),
                isActive = o.bool("active") || o.bool("is_active"),
                kind = o.str("kind"),
            )
        }

        private fun hostOf(url: String) =
            url.substringAfter("://").substringBefore('/').substringBefore(':')
    }
}

/**
 * 已登录的 Emby 会话。`server` 是**当前生效线路**,拼封面地址要用它。
 *
 * ☠ 字段名**就是线上字段名**(小写下划线)。迁移期的命令层要调用方把这四个值
 * 显式传回去(`core/emby/commands.go` 的 `sessionFrom`),写成驼峰发出去核心层
 * 当作没传,报「缺少 server 或 user_id」—— 两边都不报编译错,只在运行时现形。
 */
@Immutable
data class Session(
    val server: String,
    val token: String,
    val userId: String,
    val userName: String,
) {
    companion object {
        fun from(e: JsonElement?): Session? {
            val o = e.obj() ?: return null
            val s = o.str("server") ?: return null
            return Session(s, o.str("token") ?: "", o.str("user_id") ?: "", o.str("user_name") ?: "")
        }
    }
}

/** `system.capabilities`(SPEC §5.6)。 */
@Immutable
data class Capabilities(
    val platform: String,
    val version: String,
    val unsupported: Set<String>,
    val features: Map<String, Boolean>,
) {
    /** 入口该不该画。**`unsupported` 里的命令,入口在启动时就不画**(UI_MOBILE §6.3)。 */
    fun supports(command: String) = command !in unsupported
    fun feature(name: String) = features[name] == true

    companion object {
        val EMPTY = Capabilities("android", "", emptySet(), emptyMap())

        fun from(e: JsonElement?): Capabilities {
            val o = e.obj() ?: return EMPTY
            return Capabilities(
                platform = o.str("platform") ?: "android",
                version = o.str("version") ?: "",
                unsupported = o.strList("unsupported").toSet(),
                features = (o["features"] as? JsonObject)?.mapValues {
                    it.value.jsonPrimitive.booleanOrNull == true
                } ?: emptyMap(),
            )
        }
    }
}

/** 三态。**页面不持有一个全局 loading**,每个区块自己一个(UI_MOBILE §6.4)。 */
@Immutable
sealed interface Block<out T> {
    data object Loading : Block<Nothing>
    data class Ok<T>(val value: T) : Block<T>
    /** `code` 用来判该不该显示 —— `E_UNSUPPORTED` 静默降级,整块不画。 */
    data class Fail(val code: String, val message: String) : Block<Nothing>

    val valueOrNull: T? get() = (this as? Ok)?.value
    /** `E_UNSUPPORTED` 不是错误是信息:这一块整个不画,不弹错。 */
    val isSilent: Boolean get() = this is Fail && code == "E_UNSUPPORTED"
}
