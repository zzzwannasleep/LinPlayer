package xyz.linplayer.app.core

import android.util.Log
import android.view.Surface
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import xyz.linplayer.core.LinPlayerAbi
import xyz.linplayer.core.LinPlayerCommands
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** 核心层抛回来的错误(SPEC §5.4:错误是对象不是字符串)。 */
class CoreException(
    val code: String,
    override val message: String,
    val retryable: Boolean,
    val detail: String? = null,
) : Exception(message) {

    /**
     * 给用户看的一句话。**永远带上核心层给的真实原因。**
     *
     * PC 端原来是「错误码 → 固定话」,把 message 整个丢掉了 —— 密码错、token 过期、
     * 地址打错,用户看到的全是「网络不通,可以重试」。固定话只是补一句该怎么办,
     * 不是替换原因。
     */
    val advice: String
        get() {
            val what = when (code) {
                "E_AUTH" -> "登录状态失效或凭据不对,请重新登录"
                "E_NETWORK" -> "连不上服务器"
                "E_UNSUPPORTED" -> "这台服务器或这个平台不支持这项功能"
                "E_NOTFOUND" -> "找不到这个内容"
                "E_PERMISSION" -> "当前账号没有权限"
                else -> ""
            }
            var why = message
            if (!detail.isNullOrBlank()) why = if (why.isNotBlank()) "$why($detail)" else detail
            if (what.isEmpty()) return why.ifBlank { "出错了($code)" }
            return if (why.isNotBlank() && why != what) "$what —— $why" else what
        }
}

/** 主动事件(SPEC §5.5)。`name` 是事件名,`data` 是载荷。 */
data class CoreEvent(val name: String, val data: JsonElement)

/**
 * 命令通道 + 事件泵。**进程内唯一实例**(`LinPlayerApp` 持有)。
 *
 * 三件事:发命令并挂起到 result、把主动事件广播成 Flow、把本地数据通道的地址存下来。
 */
class CoreClient private constructor() : LinPlayerCommands {

    private val seq = AtomicLong(0)
    private val pending = ConcurrentHashMap<Long, CancellableContinuation<JsonElement>>()
    private val partials = ConcurrentHashMap<Long, (JsonElement) -> Unit>()
    @Volatile private var stop = false

    private val _events = MutableSharedFlow<CoreEvent>(
        // 事件是广播,慢的订阅者不该把事件线程堵住 —— 堵住的表现是 player.status
        // 整条停摆(进度条不动),而没有任何地方会喊
        extraBufferCapacity = 256,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val events: SharedFlow<CoreEvent> = _events

    /** 本地数据通道的基址与 token(SPEC §6)。图片 URL 从这里拼。 */
    @Volatile var localBaseUrl: String = ""; private set
    @Volatile var localToken: String = ""; private set

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = false }

    companion object {
        private const val TAG = "LinPlayer"
        @Volatile private var instance: CoreClient? = null

        /**
         * 起核心层。**幂等** —— Activity 重建不该再 init 一次。
         *
         * ABI 先协商再 init(SPEC §5.0):版本错配的表现不是报错,是崩溃或静默乱码。
         */
        fun start(dataDir: String, version: String): CoreClient =
            instance ?: synchronized(this) {
                instance ?: CoreClient().also { c ->
                    val abi = Native.abiVersion()
                    check(abi == LinPlayerAbi.VERSION) {
                        "核心层 ABI 是 $abi,本程序按 ${LinPlayerAbi.VERSION} 编译 —— 版本对不上,不能继续"
                    }
                    val cfg = """{"dataDir":${q(dataDir)},"platform":"android","version":${q(version)}}"""
                    check(Native.init(cfg) == 0) { "核心层初始化失败" }
                    c.startPump()
                    instance = c
                }
            }

        fun get(): CoreClient = requireNonNullInstance()

        private fun requireNonNullInstance(): CoreClient =
            instance ?: error("CoreClient 还没起来 —— 启动时序错了(SPEC §8.0 第 2 步)")

        private fun q(s: String) = Json.encodeToString(kotlinx.serialization.json.JsonPrimitive.serializer(),
            kotlinx.serialization.json.JsonPrimitive(s))
    }

    // ---------------------------------------------------------------- 命令

    override suspend fun call(command: String, args: Map<String, Any?>?): JsonElement =
        callJson(command, args?.let { toJsonObject(it) })

    /**
     * 发一条命令,挂起到它的 result 事件回来。
     *
     * 取消时**必须同时通知核心层**:只丢掉本地的 continuation 的话,核心层那边还在跑,
     * 而它的结果没人收 —— 事件队列会一直堆着。
     */
    suspend fun callJson(
        command: String,
        args: JsonObject? = null,
        onPartial: ((JsonElement) -> Unit)? = null,
    ): JsonElement = suspendCancellableCoroutine { cont ->
        val s = seq.incrementAndGet()
        pending[s] = cont
        if (onPartial != null) partials[s] = onPartial
        cont.invokeOnCancellation {
            Native.cancel(s)
            pending.remove(s)
            partials.remove(s)
        }
        val rc = Native.call(s, command, args?.toString() ?: "{}")
        if (rc != 0) {
            pending.remove(s)
            partials.remove(s)
            cont.resumeWithException(CoreException("E_INTERNAL", "命令没发出去($command,rc=$rc)", false))
        }
    }

    fun setSurface(surface: Surface?, w: Int, h: Int): Int = Native.setSurface(surface, w, h)

    fun shutdown() {
        stop = true
        Native.shutdown()
    }

    // ---------------------------------------------------------------- 事件泵

    private fun startPump() {
        thread(name = "lp-events", isDaemon = true) {
            while (!stop) {
                val json = Native.nextEvent(200) ?: continue
                try { dispatch(json) } catch (e: Throwable) {
                    // 一条事件处理坏了不能把整个泵打死 —— 泵停了的表现是
                    // 「所有命令永远不返回」,而且没有任何地方会喊
                    Log.w(TAG, "事件处理出错(已吞)", e)
                }
            }
        }
    }

    private fun dispatch(raw: String) {
        val root = Json.parseToJsonElement(raw).jsonObject
        when (root["t"]?.jsonPrimitive?.contentOrNull) {
            "result" -> {
                val s = root["seq"]!!.jsonPrimitive.long
                partials.remove(s)
                val cont = pending.remove(s) ?: return // 已取消
                val ok = root["ok"]?.jsonPrimitive?.booleanOrNull == true
                if (ok) {
                    cont.resume(root["data"] ?: JsonNull)
                } else {
                    val err = root["err"] as? JsonObject
                    cont.resumeWithException(CoreException(
                        err?.str("code") ?: "E_INTERNAL",
                        err?.str("msg") ?: "核心层报错",
                        err?.get("retryable")?.jsonPrimitive?.booleanOrNull == true,
                        // detail 装的常常正是「到底怎么了」那一句。PC 端曾经直接丢了它
                        err?.str("detail"),
                    ))
                }
            }
            "partial" -> {
                val s = root["seq"]!!.jsonPrimitive.long
                partials[s]?.invoke(root["data"] ?: JsonNull)
            }
            "event" -> {
                val name = root["name"]?.jsonPrimitive?.contentOrNull ?: return
                val data = root["data"] ?: JsonNull
                if (name == "localserve.ready") {
                    localBaseUrl = (data as? JsonObject)?.str("baseUrl") ?: ""
                    localToken = (data as? JsonObject)?.str("token") ?: ""
                }
                if (name == "log" && BuildConfigLog.enabled) {
                    val d = data as? JsonObject
                    Log.d(TAG, "[核心层:${d?.str("level")}] ${d?.str("msg")}")
                }
                _events.tryEmit(CoreEvent(name, data))
            }
            "eof" -> stop = true
        }
    }

    private fun JsonObject.str(k: String) = this[k]?.jsonPrimitive?.contentOrNull
}

/** 核心层日志默认不打:它每几秒就有几条,会把自检那几行断言淹掉。 */
internal object BuildConfigLog {
    val enabled: Boolean = System.getenv("LP_CORELOG") == "1"
}

/** `Map<String, Any?>` → `JsonObject`。生成的绑定层用弱类型入参,这里收口一次。 */
internal fun toJsonObject(m: Map<String, Any?>): JsonObject = buildJsonObjectFrom(m)

private fun buildJsonObjectFrom(m: Map<String, Any?>): JsonObject =
    JsonObject(m.mapValues { (_, v) -> toJsonElement(v) })

private fun toJsonElement(v: Any?): JsonElement = when (v) {
    null -> JsonNull
    is JsonElement -> v
    is Boolean -> kotlinx.serialization.json.JsonPrimitive(v)
    is Number -> kotlinx.serialization.json.JsonPrimitive(v)
    is String -> kotlinx.serialization.json.JsonPrimitive(v)
    is Map<*, *> -> JsonObject(v.entries.associate { (k, x) -> k.toString() to toJsonElement(x) })
    is Iterable<*> -> kotlinx.serialization.json.JsonArray(v.map { toJsonElement(it) })
    else -> kotlinx.serialization.json.JsonPrimitive(v.toString())
}
