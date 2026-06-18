package com.example.linplayer_mobile

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall

class MainActivity : FlutterActivity() {
    private var exoPlayerPlugin: ExoPlayerPlugin? = null
    private var mpvPlayerPlugin: MpvPlayerPlugin? = null
    private var libassChannel: MethodChannel? = null
    private var proxyChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
