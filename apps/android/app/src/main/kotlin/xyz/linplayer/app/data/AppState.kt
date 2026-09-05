package xyz.linplayer.app.data

import android.net.Uri
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import xyz.linplayer.app.core.CoreClient
import xyz.linplayer.app.core.CoreException

/**
 * 全局状态:会话 / 能力集 / 图片地址 / 失效广播。
 *
 * ★ **UI 侧不再自己做缓存层**:核心层已经发 `data.invalidate` 事件了(SPEC §5.8),
 *   再养一份缓存等于把失效时机在 UI 抄一遍,抄错还不报错。
 *   这里只把事件转成一条 Flow,页面订阅了就重取。
 */
class AppState(val core: CoreClient, scope: CoroutineScope) {

    private val _session = MutableStateFlow<Session?>(null)
    val session: StateFlow<Session?> = _session.asStateFlow()

    private val _caps = MutableStateFlow(Capabilities.EMPTY)
    val caps: StateFlow<Capabilities> = _caps.asStateFlow()

    private val _hasAnyAccount = MutableStateFlow(false)
    val hasAnyAccount: StateFlow<Boolean> = _hasAnyAccount.asStateFlow()

    /** 启动时序走到第 5 步了没有。null = 还没判完(画骨架,不画闸口也不画首页)。 */
    private val _loggedIn = MutableStateFlow<Boolean?>(null)
    val loggedIn: StateFlow<Boolean?> = _loggedIn.asStateFlow()

    /** 缓存失效广播。`scope` 是 `data.invalidate` 的 scope 字段。 */
    private val _invalidate = MutableSharedFlow<String>(extraBufferCapacity = 32)
    val invalidate: SharedFlow<String> = _invalidate

    private val _toasts = MutableSharedFlow<Toast>(extraBufferCapacity = 8)
    val toasts: SharedFlow<Toast> = _toasts

    init {
        scope.launch {
            core.events.collect { ev ->
                when (ev.name) {
                    "data.invalidate" -> _invalidate.tryEmit((ev.data as? JsonObject).str("scope") ?: "all")
                    "account.status" -> _invalidate.tryEmit("accounts")
                }
            }
        }
    }

    /**
     * 启动时序第 4~5 步(SPEC §8.0)。
     *
     * ☠ **第 5 步必须同时看 `emby.currentSession` 和账号表。**
     * 只判 Emby 会话的话有一类用户永远进不了门 —— 这是有过的真实故障。
     */
    suspend fun boot() {
        _caps.value = Capabilities.from(runCatching { core.callJson("system.capabilities") }.getOrNull())
        val s = runCatching { Session.from(core.callJson("emby.currentSession")) }.getOrNull()
        val accounts = runCatching { Account.list(core.callJson("account.listAccounts")) }.getOrDefault(emptyList())
        _session.value = s
        _hasAnyAccount.value = accounts.isNotEmpty()
        _loggedIn.value = s != null || accounts.isNotEmpty()
    }

    suspend fun refreshSession() = boot()

    /**
     * 发一条命令,**自动把会话四件套并进参数**。
     *
     * ☠ 迁移期的命令层要调用方显式传 `server / token / user_id / device_id`
     * (`core/emby/commands.go` 的 `sessionFrom`,`core/player/` 里有 8 处也要)。
     * 让每个页面各自记得传 = 漏掉的那一页就是「缺少 server 或 user_id」,
     * 而它长得像后端故障。所以收成这一个口子:**页面一律走 `app.call`,
     * 不许直接用 `app.core.callJson`。**
     * 不需要这四个值的命令会把它们当未知键忽略,零代价。
     */
    suspend fun call(
        command: String,
        args: JsonObject? = null,
        onPartial: ((JsonElement) -> Unit)? = null,
    ): JsonElement {
        val s = _session.value
        val merged = if (s == null) args else JsonObject(
            mapOf(
                "server" to JsonPrimitive(s.server),
                "token" to JsonPrimitive(s.token),
                "user_id" to JsonPrimitive(s.userId),
                "device_id" to JsonPrimitive(deviceId()),
            ) + (args ?: JsonObject(emptyMap()))   // 调用方显式给的压过默认的
        )
        return core.callJson(command, merged, onPartial)
    }

    fun toast(text: String, kind: ToastKind = ToastKind.Info) {
        _toasts.tryEmit(Toast(text, kind))
    }

    /**
     * 错误 → UI 行为(UI_MOBILE.md §6.3)。
     *
     * ★ `E_UNSUPPORTED` **静默降级,一个字都不显示**;
     *   `E_NETWORK` **不弹 toast**(网络抖动时会刷屏),交给调用方画行内错误态。
     */
    fun report(e: Throwable) {
        val ce = e as? CoreException ?: run { toast(e.message ?: "出错了", ToastKind.Error); return }
        when (ce.code) {
            "E_UNSUPPORTED", "E_SHUTDOWN", "E_NETWORK" -> Unit
            else -> toast(ce.advice, ToastKind.Error)
        }
    }

    /**
     * 一张图的本地地址(SPEC §6 数据通道)。
     *
     * ★ **UI 传期望宽度,核心层决定实际取多大** —— 有的服务端完全忽略 maxWidth。
     * ★ 尺寸走 `h=` 不写进 `src`:写进去等于每种尺寸一个缓存键。
     */
    fun imageUrl(itemId: String?, kind: String = "Primary", height: Int = 330): String? {
        val server = _session.value?.server ?: return null
        val base = core.localBaseUrl
        if (itemId.isNullOrEmpty() || base.isEmpty()) return null
        // Backdrop 要带序号,Primary/Logo 不带 —— 不带的话某些 fork 直接 404
        val seg = if (kind == "Backdrop") "Backdrop/0" else kind
        val upstream = "${server.trimEnd('/')}/Items/$itemId/Images/$seg?quality=90"
        return "$base/img?src=${Uri.encode(upstream)}&h=${ladder(height)}"
    }

    /**
     * 设备 id。**必须持久** —— 每次换一个会把服务器的设备列表刷满,续播会话也对不上。
     * 用 ANDROID_ID 派生,不用 Build.SERIAL(API 26+ 拿不到)。
     */
    private var deviceIdCache: String? = null
    fun deviceId(): String = deviceIdCache ?: "linplayer-android".also { deviceIdCache = it }

    fun setDeviceId(raw: String) { deviceIdCache = "linplayer-" + raw.take(16) }

    /** 在播放页且没暂停时才进 PiP(U1.25)。不在播放页按 Home 进 PiP 是纯噪音。 */
    @Volatile var wantsPip: Boolean = false

    /** 高度归档:每种尺寸一个缓存键,不归档就是几十个键各存一份。 */
    private fun ladder(h: Int) = when {
        h <= 120 -> 120
        h <= 220 -> 220
        h <= 330 -> 330
        h <= 480 -> 480
        h <= 720 -> 720
        else -> 1080
    }
}

@Immutable data class Toast(val text: String, val kind: ToastKind)
enum class ToastKind { Info, Ok, Error }

val LocalApp = staticCompositionLocalOf<AppState> { error("AppState 还没提供") }

/** 一条命令 → `Block`。**E_UNSUPPORTED 会变成 `Fail` 但 `isSilent` 为真**,调用方据此整块不画。 */
suspend fun AppState.block(command: String, args: JsonObject? = null): Block<JsonElement> =
    try {
        Block.Ok(call(command, args))
    } catch (e: CoreException) {
        Block.Fail(e.code, e.advice)
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Throwable) {
        Block.Fail("E_INTERNAL", e.message ?: "出错了")
    }
