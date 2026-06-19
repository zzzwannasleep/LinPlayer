package com.example.linplayer_mobile

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall

class MainActivity : FlutterActivity() {
    private var exoPlayerPlugin: ExoPlayerPlugin? = null
    private var mpvPlayerPlugin: MpvPlayerPlugin? = null
    private var libassChannel: MethodChannel? = null
    private var proxyChannel: MethodChannel? = null
    private var diagnosticsChannel: MethodChannel? = null
    private var mediaChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 全覆盖崩溃取证：JVM 未捕获异常（任何线程，含 mpv 原生事件线程回调）在被系统
        // 记录为 CRASH(JVM) 时，ApplicationExitInfo 往往拿不到回溯文本（实测为 null）。
        // 这里装一个默认未捕获异常处理器，把完整 Java 堆栈直接追加进可导出的 App 日志，
        // 再链回原处理器（不改变崩溃行为，只补取证）。
        installCrashLogger()

        // 注册 MpvSurfaceView 平台视图工厂（用于 gpu-next 渲染）
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "com.linplayer/mpv_surface",
            MpvSurfaceViewFactory()
        )

        // 注册 ExoPlayer 插件（v2 - 支持字幕轨道）
        exoPlayerPlugin = ExoPlayerPlugin(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.linplayer/exoplayer")
            .setMethodCallHandler(exoPlayerPlugin)

        // 注册原生 MPV 插件（通过 libplayer.so 直接调用 libmpv）
        mpvPlayerPlugin = MpvPlayerPlugin(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.linplayer/mpv")
            .setMethodCallHandler(mpvPlayerPlugin)

        // 注册 legacy libass JNI 桥接 MethodChannel
        // 当前 ExoPlayer 已优先走 Media3/libass 原生字幕管线，这里仅保留兼容实现
        libassChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.linplayer/libass"
        )
        libassChannel!!.setMethodCallHandler { call, result ->
            handleLibassCall(this, call, result)
        }

        // 注册 mihomo 代理内核桥接（仅 TV 构建含内核，其余构建调用 start 会返回内核缺失）
        proxyChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.linplayer/proxy"
        )
        proxyChannel!!.setMethodCallHandler { call, result ->
            ProxyBridge.handle(this, call, result)
        }

        // 诊断：取上次进程退出原因（含原生崩溃 tombstone 回溯）。
        // 原生 SIGSEGV（如 libmpv 闪退）在 Dart/Java 层抓不到、应用日志里只有"戛然而止"。
        // 用 ActivityManager.getHistoricalProcessExitReasons（API 30+，免权限）能拿到
        // 上次崩溃的原生回溯，启动后由 Dart 写入可导出的 App 日志，便于定位。
        diagnosticsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.linplayer/diagnostics"
        )
        diagnosticsChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "getRecentExitReasons" -> result.success(getRecentExitReasons())
                else -> result.notImplemented()
            }
        }

        // 媒体：把播放器截图字节写入系统相册（之前 Dart 侧只拿到字节、从未落盘）。
        mediaChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.linplayer/media"
        )
        mediaChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveImageToGallery" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val name = call.argument<String>("name")
                        ?: "LinPlayer_${System.currentTimeMillis()}"
                    if (bytes == null) {
                        result.success(false)
                    } else {
                        result.success(saveImageToGallery(bytes, name))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 把图片字节保存到系统相册的 Pictures/LinPlayer 目录。
     * Android 10+（Q）走 MediaStore 作用域存储，**无需任何存储权限**；
     * Android 9 及以下写入公共 Pictures（需 WRITE_EXTERNAL_STORAGE，清单已声明 maxSdk28）。
     */
    private fun saveImageToGallery(bytes: ByteArray, displayName: String): Boolean {
        val fileName = if (displayName.endsWith(".jpg", true)) displayName else "$displayName.jpg"
        return try {
            val resolver = contentResolver
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                    put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                    put(
                        MediaStore.Images.Media.RELATIVE_PATH,
                        Environment.DIRECTORY_PICTURES + "/LinPlayer"
                    )
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val uri = resolver.insert(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
                ) ?: return false
                resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: return false
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                true
            } else {
                @Suppress("DEPRECATION")
                val picDir =
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
                val dir = java.io.File(picDir, "LinPlayer").apply { mkdirs() }
                val file = java.io.File(dir, fileName)
                file.outputStream().use { it.write(bytes) }
                @Suppress("DEPRECATION")
                MediaStore.Images.Media.insertImage(resolver, file.absolutePath, fileName, null)
                true
            }
        } catch (e: Exception) {
            android.util.Log.e("MediaSave", "saveImageToGallery failed: ${e.message}")
            false
        }
    }

    /** 装默认未捕获异常处理器：把堆栈写入 App 日志后链回原处理器。 */
    private fun installCrashLogger() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val sw = java.io.StringWriter()
                throwable.printStackTrace(java.io.PrintWriter(sw))
                val text = "线程 ${thread.name} 未捕获异常:\n$sw"
                android.util.Log.e("UncaughtCrash", text)
                appendCrashToLog(text)
            } catch (_: Throwable) {
                // 取证失败绝不影响崩溃链路本身。
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    /** 把崩溃文本追加进 AppLogger 同名日志文件（…/files/linplayer_logs/linplayer-<date>.log）。 */
    private fun appendCrashToLog(text: String) {
        try {
            val dir = java.io.File(getExternalFilesDir(null), "linplayer_logs")
            if (!dir.exists()) dir.mkdirs()
            val date = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
                .format(java.util.Date())
            val ts = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", java.util.Locale.US)
                .format(java.util.Date())
            java.io.File(dir, "linplayer-$date.log")
                .appendText("\n$ts  FATAL [UncaughtCrash] $text\n")
        } catch (_: Throwable) {
        }
    }

    /** 读取最近的进程退出记录；崩溃/ANR 附带原生回溯文本（tombstone/anr trace）。 */
    private fun getRecentExitReasons(): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        return try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val infos = am.getHistoricalProcessExitReasons(packageName, 0, 8)
            infos.map { info ->
                var trace: String? = null
                val reason = info.reason
                if (reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
                    reason == ApplicationExitInfo.REASON_CRASH ||
                    reason == ApplicationExitInfo.REASON_ANR
                ) {
                    try {
                        info.traceInputStream?.use { stream ->
                            trace = stream.readBytes().toString(Charsets.UTF_8)
                        }
                    } catch (_: Exception) {
                    }
                }
                mapOf(
                    "reason" to reason,
                    "description" to (info.description ?: ""),
                    "timestamp" to info.timestamp,
                    "importance" to info.importance,
                    "pid" to info.pid,
                    "trace" to trace
                )
            }
        } catch (e: Exception) {
            android.util.Log.w("Diagnostics", "getRecentExitReasons failed: ${e.message}")
            emptyList()
        }
    }

    override fun onDestroy() {
        exoPlayerPlugin?.disposeAll()
        mpvPlayerPlugin?.disposeAll()
        ProxyBridge.stop()
        super.onDestroy()
    }
}

/**
 * libass JNI 桥接的 MethodChannel 处理
 * 对应 Dart 层 LibassBridge 的调用
 */
private fun handleLibassCall(context: Context, call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
        "isLibassAvailable" -> {
            result.success(LibassBridge.isAvailable(context))
        }
        "initLibass" -> {
            val width = call.argument<Int>("width") ?: 1920
            val height = call.argument<Int>("height") ?: 1080
            LibassBridge.init(context, width, height)
            result.success(true)
        }
        "loadSubFile" -> {
            val path = call.argument<String>("path") ?: ""
            LibassBridge.loadSubFile(path)
            result.success(true)
        }
        "loadSubMemory" -> {
            val data = call.argument<ByteArray>("data") ?: byteArrayOf()
            val codec = call.argument<String>("codec") ?: "ass"
            LibassBridge.loadSubMemory(data, codec)
            result.success(true)
        }
        "setFontSize" -> {
            val size = call.argument<Int>("size") ?: 48
            LibassBridge.setFontSize(size)
            result.success(true)
        }
        "setFontName" -> {
            val name = call.argument<String>("name") ?: ""
            LibassBridge.setFontName(name)
            result.success(true)
        }
        "renderFrame" -> {
            val ptsMs = call.argument<Int>("ptsMs") ?: 0
            val changed = IntArray(1)
            val frameData = LibassBridge.renderFrame(ptsMs.toLong(), changed)
            result.success(frameData)
        }
        "dispose" -> {
            LibassBridge.dispose()
            result.success(true)
        }
        else -> result.notImplemented()
    }
}

object LibassBridge {
    private var assLibrary: Long = 0
    private var assRenderer: Long = 0
    private var assTrack: Long = 0
    private var initialized = false
    private var pathsSet = false

    init {
        try {
            System.loadLibrary("ass")
            android.util.Log.i("LibassBridge", "libass.so loaded successfully")
        } catch (e: UnsatisfiedLinkError) {
            android.util.Log.w("LibassBridge", "libass.so not found, trying libmpv.so (libass may be statically linked)")
            try {
                // libass may be statically linked in libmpv.so (from mpv-android)
                System.loadLibrary("mpv")
                android.util.Log.i("LibassBridge", "libmpv.so loaded, libass symbols should be available")
            } catch (e2: UnsatisfiedLinkError) {
                android.util.Log.w("LibassBridge", "libmpv.so also not found: ${e2.message}")
            }
        }
        try {
            System.loadLibrary("linass_jni")
        } catch (e: UnsatisfiedLinkError) {
            android.util.Log.e("LibassBridge", "Failed to load linass_jni: ${e.message}")
        }
    }

    external fun nativeSetLibraryPaths(libassPath: String, libmpvPath: String)
    external fun nativeIsAvailable(): Boolean
    external fun nativeInit(width: Int, height: Int): Long
    external fun nativeLoadFile(assLibrary: Long, path: String): Long
    external fun nativeLoadMemory(assLibrary: Long, data: ByteArray, codec: String): Long
    external fun nativeSetFontSize(renderer: Long, size: Int)
    external fun nativeSetFontName(renderer: Long, name: String)
    external fun nativeRenderFrame(renderer: Long, track: Long, ptsMs: Long): ByteArray?
    external fun nativeDispose(assLibrary: Long, renderer: Long, track: Long)

    fun isAvailable(context: Context): Boolean {
        if (!pathsSet) {
            try {
                val nativeDir = context.applicationInfo.nativeLibraryDir
                val libassFile = java.io.File(nativeDir, "libass.so")
                val libmpvFile = java.io.File(nativeDir, "libmpv.so")
                
                // 检查库文件是否真实存在，不存在则提供空路径让JNI回退处理
                val libassPath = if (libassFile.exists()) libassFile.absolutePath else ""
                val libmpvPath = if (libmpvFile.exists()) libmpvFile.absolutePath else ""
                
                nativeSetLibraryPaths(libassPath, libmpvPath)
                pathsSet = true
                android.util.Log.i("LibassBridge", "Set library paths: ass=$libassPath, mpv=$libmpvPath")
            } catch (e: Exception) {
                android.util.Log.e("LibassBridge", "Failed to set library paths: ${e.message}")
            }
        }
        return try {
            nativeIsAvailable()
        } catch (e: UnsatisfiedLinkError) {
            android.util.Log.e("LibassBridge", "nativeIsAvailable failed: ${e.message}")
            false
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "nativeIsAvailable exception: ${e.message}")
            false
        }
    }

    fun init(context: Context, width: Int, height: Int) {
        if (initialized) dispose()
        try {
            assLibrary = nativeInit(width, height)
            assRenderer = assLibrary
            initialized = true
            android.util.Log.i("LibassBridge", "Initialized: ${width}x${height}, library=$assLibrary")
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Init failed: ${e.message}")
            initialized = false
        }
    }

    fun loadSubFile(path: String) {
        if (assLibrary == 0L) {
            android.util.Log.w("LibassBridge", "Cannot load sub file: library not initialized")
            return
        }
        try {
            assTrack = nativeLoadFile(assLibrary, path)
            android.util.Log.i("LibassBridge", "Loaded sub file: $path, track=$assTrack")
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Load sub file failed: ${e.message}")
        }
    }

    fun loadSubMemory(data: ByteArray, codec: String) {
        if (assLibrary == 0L) {
            android.util.Log.w("LibassBridge", "Cannot load sub memory: library not initialized")
            return
        }
        try {
            assTrack = nativeLoadMemory(assLibrary, data, codec)
            android.util.Log.i("LibassBridge", "Loaded sub memory: ${data.size} bytes, codec=$codec, track=$assTrack")
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Load sub memory failed: ${e.message}")
        }
    }

    fun setFontSize(size: Int) {
        if (assRenderer == 0L) return
        try {
            nativeSetFontSize(assRenderer, size)
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Set font size failed: ${e.message}")
        }
    }

    fun setFontName(name: String) {
        if (assRenderer == 0L) return
        try {
            nativeSetFontName(assRenderer, name)
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Set font name failed: ${e.message}")
        }
    }

    fun renderFrame(ptsMs: Long, changed: IntArray): ByteArray? {
        if (assRenderer == 0L || assTrack == 0L) return null
        return try {
            nativeRenderFrame(assRenderer, assTrack, ptsMs)
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Render frame failed: ${e.message}")
            null
        }
    }

    fun dispose() {
        if (!initialized) return
        try {
            nativeDispose(assLibrary, assRenderer, assTrack)
        } catch (e: Exception) {
            android.util.Log.e("LibassBridge", "Dispose failed: ${e.message}")
        }
        assLibrary = 0
        assRenderer = 0
        assTrack = 0
        initialized = false
        android.util.Log.i("LibassBridge", "Disposed")
    }
}
