package `is`.xyz.mpv

import android.content.Context
import android.graphics.Bitmap
import android.view.Surface

/**
 * JNI wrapper for libplayer.so (from mpv-android).
 *
 * This class MUST be at package is.xyz.mpv because libplayer.so exports JNI
 * symbols with the prefix Java_is_xyz_mpv_MPVLib_*. Moving or renaming it
 * will break native library loading.
 */
@Suppress("unused")
object MPVLib {
    /** 记录各 .so 的加载失败原因，供上层把"为何不能播放"写进可导出的 App 日志。 */
    @JvmField
    var loadErrors: String = ""

    init {
        val errors = StringBuilder()

        // 统一的安全加载：失败只记录不抛，避免 object 静态初始化变成
        // ExceptionInInitializerError（Error 会绕过上层 catch(Exception) 崩溃 App）。
        fun tryLoad(name: String) {
            try {
                System.loadLibrary(name)
            } catch (e: Throwable) {
                val msg = "loadLibrary($name): ${e.message}"
                android.util.Log.e("MPVLib", msg)
                errors.append(msg).append(" || ")
            }
        }

        // JavaVM 注册桥：JNI_OnLoad 缓存 JavaVM（mediacodec 硬解需要）。缺失只降级软解。
        tryLoad("mpv_init_jni")

        // 显式按依赖顺序预加载 ffmpeg 动态库 + libmpv，再加载 libplayer。
        // 关键修复:libplayer.so 的 DT_NEEDED 含 libavcodec/libswscale/libmpv,若仅靠
        // System.loadLibrary("player") 让链接器自行解析传递依赖,在依赖版本/打包顺序不一致时
        // 会"找不到库/找不到符号"而整体加载失败（表现为 MPVLib.create 无实现、无法播放）。
        // 这里把依赖逐个显式载入,既保证解析,也让失败精确落点到具体某个 .so。
        for (dep in arrayOf(
            "avutil", "swresample", "swscale",
            "avcodec", "avformat", "avfilter"
        )) {
            tryLoad(dep)
        }
        tryLoad("mpv")
        tryLoad("player")

        loadErrors = errors.toString()
        if (loadErrors.isNotEmpty()) {
            android.util.Log.e("MPVLib", "native lib load errors: $loadErrors")
        }
    }

    // ---- Lifecycle ----
    external fun create(appctx: Context)
    external fun init()
    external fun destroy()

    // ---- Surface rendering (wid-based, not used by LinPlayer's render context approach) ----
    external fun attachSurface(surface: Surface)
    external fun detachSurface()

    // ---- Commands & options ----
    external fun command(cmd: Array<out String>)
    external fun setOptionString(name: String, value: String): Int

    // ---- Screenshot / thumbnail ----
    external fun grabThumbnail(dimension: Int): Bitmap?

    // ---- Property access ----
    external fun getPropertyInt(property: String): Int?
    external fun setPropertyInt(property: String, value: Int)
    external fun getPropertyDouble(property: String): Double?
    external fun setPropertyDouble(property: String, value: Double)
    external fun getPropertyBoolean(property: String): Boolean?
    external fun setPropertyBoolean(property: String, value: Boolean)
    external fun getPropertyString(property: String): String?
    external fun setPropertyString(property: String, value: String)

    // ---- Property observation ----
    external fun observeProperty(property: String, format: Int)

    // ---- Event observer management ----

    private val observers = mutableListOf<EventObserver>()

    @JvmStatic
    fun addObserver(o: EventObserver) {
        synchronized(observers) { observers.add(o) }
    }

    @JvmStatic
    fun removeObserver(o: EventObserver) {
        synchronized(observers) { observers.remove(o) }
    }

    /**
     * Called from the native event thread (libplayer.so).
     * Uses copy-on-iterate to avoid ConcurrentModificationException.
     */
    @JvmStatic
    fun eventProperty(property: String, value: Long) {
        val copy = synchronized(observers) { observers.toList() }
        copy.forEach { it.eventProperty(property, value) }
    }

    @JvmStatic
    fun eventProperty(property: String, value: Boolean) {
        val copy = synchronized(observers) { observers.toList() }
        copy.forEach { it.eventProperty(property, value) }
    }

    @JvmStatic
    fun eventProperty(property: String, value: Double) {
        val copy = synchronized(observers) { observers.toList() }
        copy.forEach { it.eventProperty(property, value) }
    }

    @JvmStatic
    fun eventProperty(property: String, value: String) {
        val copy = synchronized(observers) { observers.toList() }
        copy.forEach { it.eventProperty(property, value) }
    }

    @JvmStatic
    fun eventProperty(property: String) {
        val copy = synchronized(observers) { observers.toList() }
        copy.forEach { it.eventProperty(property) }
    }

    @JvmStatic
    fun event(eventId: Int) {
        val copy = synchronized(observers) { observers.toList() }
        copy.forEach { it.event(eventId) }
    }

    // ---- Log observer management ----

    private val logObservers = mutableListOf<LogObserver>()

    @JvmStatic
    fun addLogObserver(o: LogObserver) {
        synchronized(logObservers) { logObservers.add(o) }
    }

    @JvmStatic
    fun removeLogObserver(o: LogObserver) {
        synchronized(logObservers) { logObservers.remove(o) }
    }

    @JvmStatic
    fun logMessage(prefix: String, level: Int, text: String) {
        val copy = synchronized(logObservers) { logObservers.toList() }
        copy.forEach { it.logMessage(prefix, level, text) }
    }

    // ---- Interfaces ----

    interface EventObserver {
        fun eventProperty(property: String)
        fun eventProperty(property: String, value: Long)
        fun eventProperty(property: String, value: Boolean)
        fun eventProperty(property: String, value: String)
        fun eventProperty(property: String, value: Double)
        fun event(eventId: Int)
    }

    interface LogObserver {
        fun logMessage(prefix: String, level: Int, text: String)
    }

    // ---- Constants ----

    object MpvFormat {
        const val NONE: Int = 0
        const val STRING: Int = 1
        const val OSD_STRING: Int = 2
        const val FLAG: Int = 3
        const val INT64: Int = 4
        const val DOUBLE: Int = 5
        const val NODE: Int = 6
        const val NODE_ARRAY: Int = 7
        const val NODE_MAP: Int = 8
        const val BYTE_ARRAY: Int = 9
    }

    object MpvEvent {
        const val NONE: Int = 0
        const val SHUTDOWN: Int = 1
        const val LOG_MESSAGE: Int = 2
        const val GET_PROPERTY_REPLY: Int = 3
        const val SET_PROPERTY_REPLY: Int = 4
        const val COMMAND_REPLY: Int = 5
        const val START_FILE: Int = 6
        const val END_FILE: Int = 7
        const val FILE_LOADED: Int = 8
        const val CLIENT_MESSAGE: Int = 16
        const val VIDEO_RECONFIG: Int = 17
        const val AUDIO_RECONFIG: Int = 18
        const val SEEK: Int = 20
        const val PLAYBACK_RESTART: Int = 21
        const val PROPERTY_CHANGE: Int = 22
        const val QUEUE_OVERFLOW: Int = 24
        const val HOOK: Int = 25
    }

    object MpvEndFileReason {
        const val EOF: Int = 0
        const val STOP: Int = 2
        const val QUIT: Int = 3
        const val ERROR: Int = 4
        const val REDIRECT: Int = 5
        const val UNKNOWN: Int = 6
    }

    object MpvLogLevel {
        const val NONE: Int = 0
        const val FATAL: Int = 10
        const val ERROR: Int = 20
        const val WARN: Int = 30
        const val INFO: Int = 40
        const val V: Int = 50
        const val DEBUG: Int = 60
        const val TRACE: Int = 70
    }
}
