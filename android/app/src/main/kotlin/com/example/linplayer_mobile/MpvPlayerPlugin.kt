package com.example.linplayer_mobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.Surface
import `is`.xyz.mpv.MPVLib
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Flutter platform channel plugin for native mpv playback.
 *
 * Follows the same MethodChannel + EventChannel pattern as ExoPlayerPlugin.
 * Each player instance wraps an MPVLib-managed mpv context. The video surface
 * from Flutter's TextureRegistry is attached to mpv via MPVLib.attachSurface(),
 * which sets the "wid" option — mpv creates its own EGL context on the surface
 * and manages all rendering internally.
 */
class MpvPlayerPlugin(
    private val context: Context,
    private val binaryMessenger: BinaryMessenger,
    private val textureRegistry: TextureRegistry
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "MpvPlayerPlugin"
        private const val METHOD_CHANNEL = "com.linplayer/mpv"
    }

    private val players = ConcurrentHashMap<String, MpvPlayerInstance>()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        android.util.Log.d(TAG, "onMethodCall: ${call.method}, players=${players.keys}")
        when (call.method) {
            "createPlayer" -> {
                val videoUrl = call.argument<String>("videoUrl") ?: ""
                val startPositionMs = call.argument<Number>("startPositionMs")?.toInt() ?: 0
                val dolbyVisionFix = call.argument<Boolean>("dolbyVisionFix") ?: false
                val preferredSubtitleLanguage = call.argument<String>("preferredSubtitleLanguage")
                val hardwareDecoding = call.argument<Boolean>("hardwareDecoding") ?: true
                // Dart 传过来的 int 在 Android 端可能是 Long，用 Number 兼容
                val surfaceViewId = call.argument<Number>("surfaceViewId")?.toInt()
                val useGpuNext = call.argument<Boolean>("useGpuNext") ?: false
                // 用户自定义代理（仅 HTTP 代理可被 mpv 消费；为空则直连）
                val httpProxy = call.argument<String>("httpProxy")
                // 统一 UA：部分 CDN 拒绝 mpv 默认 UA 导致取流失败。
                val userAgent = call.argument<String>("userAgent")
                // 网络播放磁盘缓存（按用户 300MB–8GB 设置；本地文件为空/0 表示不启用）
                val videoCacheDir = call.argument<String>("videoCacheDir")
                val diskCacheForwardBytes = call.argument<Number>("diskCacheForwardBytes")?.toLong() ?: 0L
                val diskCacheBackBytes = call.argument<Number>("diskCacheBackBytes")?.toLong() ?: 0L
                createPlayer(videoUrl, startPositionMs, hardwareDecoding, surfaceViewId, useGpuNext, httpProxy, userAgent, videoCacheDir, diskCacheForwardBytes, diskCacheBackBytes, result)
            }
            "play" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                getPlayer(playerId)?.play()
                result.success(true)
            }
            "pause" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                getPlayer(playerId)?.pause()
                result.success(true)
            }
            "seekTo" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val positionMs = call.argument<Number>("positionMs")?.toInt() ?: 0
                getPlayer(playerId)?.seekTo(positionMs)
                result.success(true)
            }
            "setSpeed" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val speed = call.argument<Double>("speed") ?: 1.0
                getPlayer(playerId)?.setSpeed(speed)
                result.success(true)
            }
            "setVolume" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val volume = call.argument<Double>("volume") ?: 1.0
                getPlayer(playerId)?.setVolume(volume)
                result.success(true)
            }
            "getPosition" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val pos = getPlayer(playerId)?.getPosition() ?: 0
                result.success(pos)
            }
            "getDuration" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val dur = getPlayer(playerId)?.getDuration() ?: 0
                result.success(dur)
            }
            "getVideoSize" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val size = getPlayer(playerId)?.getVideoSize()
                result.success(size ?: mapOf("width" to 0, "height" to 0))
            }
            "getTracks" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val tracks = getPlayer(playerId)?.getTracksInfo()
                result.success(tracks ?: emptyList<Map<String, Any>>())
            }
            "selectSubtitleTrack" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val trackId = call.argument<String>("trackId") ?: ""
                getPlayer(playerId)?.selectSubtitleTrack(trackId)
                result.success(true)
            }
            "deselectSubtitleTrack" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                getPlayer(playerId)?.deselectSubtitleTrack()
                result.success(true)
            }
            "selectAudioTrack" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val trackId = call.argument<String>("trackId") ?: ""
                getPlayer(playerId)?.selectAudioTrack(trackId)
                result.success(true)
            }
            "loadSubtitle" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val subtitleUrl = call.argument<String>("subtitleUrl") ?: ""
                val subtitleLanguage = call.argument<String>("subtitleLanguage") ?: "und"
                getPlayer(playerId)?.loadSubtitle(subtitleUrl, subtitleLanguage)
                result.success(true)
            }
            "setProperty" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val name = call.argument<String>("name") ?: ""
                val value = call.argument<String>("value") ?: ""
                getPlayer(playerId)?.setProperty(name, value)
                result.success(true)
            }
            "getProperty" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val name = call.argument<String>("name") ?: ""
                val value = getPlayer(playerId)?.getProperty(name)
                result.success(value)
            }
            "getPropertyDouble" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val name = call.argument<String>("name") ?: ""
                val value = getPlayer(playerId)?.getPropertyDouble(name)
                result.success(value)
            }
            "command" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                @Suppress("UNCHECKED_CAST")
                val args = call.argument<List<String>>("args") ?: emptyList()
                getPlayer(playerId)?.command(args.toTypedArray())
                result.success(true)
            }
            "screenshot" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val bitmap = getPlayer(playerId)?.screenshot()
                result.success(bitmap)
            }
            "setSubtitleDelay" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val seconds = call.argument<Double>("seconds") ?: 0.0
                getPlayer(playerId)?.setProperty("sub-delay", seconds.toString())
                result.success(true)
            }
            "setAudioDelay" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val seconds = call.argument<Double>("seconds") ?: 0.0
                getPlayer(playerId)?.setProperty("audio-delay", seconds.toString())
                result.success(true)
            }
            "setSubtitleFont" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val fontName = call.argument<String>("fontName") ?: ""
                getPlayer(playerId)?.setProperty("sub-font", fontName)
                result.success(true)
            }
            "setSubtitleSize" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val size = call.argument<Double>("size") ?: 0.5
                // mpv sub-font-size is in scaled pixels; map 0.0-1.0 to a reasonable range
                val fontSize = (size * 60).toInt().coerceIn(10, 120)
                getPlayer(playerId)?.setProperty("sub-font-size", fontSize.toString())
                result.success(true)
            }
            "setSubtitlePosition" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val position = call.argument<Double>("position") ?: 0.0
                // mpv sub-pos: 0=top, 100=bottom (inverted from UI)
                val subPos = ((1.0 - position) * 100).toInt().coerceIn(0, 100)
                getPlayer(playerId)?.setProperty("sub-pos", subPos.toString())
                result.success(true)
            }
            "setSubtitleBackground" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val enabled = call.argument<Boolean>("enabled") ?: false
                getPlayer(playerId)?.setProperty(
                    "sub-back-color",
                    if (enabled) "0.0/0.0/0.0/0.75" else "0.0/0.0/0.0/0.0"
                )
                result.success(true)
            }
            "setAspectRatio" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val ratio = call.argument<String>("ratio") ?: "自动"
                getPlayer(playerId)?.setAspectRatio(ratio)
                result.success(true)
            }
            "disposePlayer" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                disposePlayer(playerId)
                result.success(true)
            }
            "getCacheDir" -> {
                result.success(context.cacheDir.absolutePath)
            }
            "writeFile" -> {
                val path = call.argument<String>("path") ?: ""
                val data = call.argument<ByteArray>("data")
                if (path.isNotEmpty() && data != null) {
                    try {
                        java.io.File(path).writeBytes(data)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("WRITE_ERROR", e.message, null)
                    }
                } else {
                    result.error("INVALID_ARGS", "path and data required", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun createPlayer(
        videoUrl: String,
        startPositionMs: Int,
        hardwareDecoding: Boolean,
        surfaceViewId: Int?,
        useGpuNext: Boolean,
        httpProxy: String?,
        userAgent: String?,
        videoCacheDir: String?,
        diskCacheForwardBytes: Long,
        diskCacheBackBytes: Long,
        result: MethodChannel.Result
    ) {
        // Always use SurfaceTexture (no SurfaceView polling needed)
        mainHandler.post { createPlayerOnMainThread(videoUrl, startPositionMs, hardwareDecoding, useGpuNext, httpProxy, userAgent, videoCacheDir, diskCacheForwardBytes, diskCacheBackBytes, result) }
    }

    private fun createPlayerOnMainThread(
        videoUrl: String,
        startPositionMs: Int,
        hardwareDecoding: Boolean,
        useGpuNext: Boolean,
        httpProxy: String?,
        userAgent: String?,
        videoCacheDir: String?,
        diskCacheForwardBytes: Long,
        diskCacheBackBytes: Long,
        result: MethodChannel.Result
    ) {
        var surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry? = null
        try {
            // MPVLib is a singleton — only one mpv context can exist at a time.
            // Dispose any existing player first.（放进 try：release 内部异常也不外泄）
            if (players.isNotEmpty()) {
                android.util.Log.w(TAG, "createPlayer: disposing existing player(s)")
                players.values.forEach { it.release() }
                players.clear()
            }

            val playerId = UUID.randomUUID().toString()

            // Always use SurfaceTexture for both gpu and gpu-next modes
            surfaceTextureEntry = textureRegistry.createSurfaceTexture()
            val surfaceTexture = surfaceTextureEntry.surfaceTexture()

            // Set initial surface size using screen dimensions (landscape orientation)
            // IMPORTANT: Must be set BEFORE creating Surface to avoid SurfaceSyncer errors
            val dm = context.resources.displayMetrics
            val screenW = if (dm.widthPixels > dm.heightPixels) dm.widthPixels else dm.heightPixels
            val screenH = if (dm.widthPixels > dm.heightPixels) dm.heightPixels else dm.widthPixels
            surfaceTexture.setDefaultBufferSize(screenW, screenH)

            val surface = Surface(surfaceTexture)

            // Create mpv context.
            // 这一步会触发 MPVLib 的 init{}（首次访问时 System.loadLibrary("mpv"/"player")），
            // 从而把 libmpv.so 及其依赖 libavcodec.so 真正加载进进程。
            MPVLib.create(context)

            // 注册 JavaVM 给 ffmpeg（av_jni_set_java_vm，mediacodec 硬解必需）。
            // 必须放在 MPVLib.create() 之后：nativeRegisterJavaVm 通过 dlsym 取
            // av_jni_set_java_vm 符号，而该符号来自 libavcodec.so——首帧播放时若在
            // libmpv 加载前调用，dlsym 返回 null、原生侧调用空指针 → SIGSEGV 闪退。
            // 崩溃会重启进程，使每次播放又成"首帧" → 表现为"每次播放必闪退"。
            MpvInitBridge.ensureJavaVmRegistered()

            // Set mpv options (must be before init)
            android.util.Log.i(TAG, "Setting mpv options: hardwareDecoding=$hardwareDecoding, useGpuNext=$useGpuNext")
            setMpvOptions(hardwareDecoding, useGpuNext = useGpuNext, httpProxy = httpProxy,
                userAgent = userAgent,
                videoCacheDir = videoCacheDir,
                diskCacheForwardBytes = diskCacheForwardBytes,
                diskCacheBackBytes = diskCacheBackBytes)

            // Initialize mpv (registers JavaVM, starts event thread)
            MPVLib.init()

            MPVLib.attachSurface(surface)

            // Notify mpv of initial render target dimensions
            MPVLib.setPropertyString("android-surface-size", "${screenW}x${screenH}")

            // Enable video output
            MPVLib.setPropertyBoolean("force-window", true)

            // Set up EventChannel
            val eventChannel = EventChannel(
                binaryMessenger,
                "$METHOD_CHANNEL/events/$playerId"
            )

            val mpvTexture = MpvTexture(surfaceTextureEntry)
            val instance = MpvPlayerInstance(
                playerId = playerId,
                context = context,
                surface = surface,
                mpvTexture = mpvTexture,
                eventChannel = eventChannel,
                mainHandler = mainHandler
            )

            // Register observer（含日志订阅：把 mpv 原生 warn/error/fatal 落到 App 日志）
            MPVLib.addObserver(instance)
            MPVLib.addLogObserver(instance)

            // Observe key properties
            MPVLib.observeProperty("time-pos", MPVLib.MpvFormat.DOUBLE)
            MPVLib.observeProperty("duration", MPVLib.MpvFormat.DOUBLE)
            MPVLib.observeProperty("pause", MPVLib.MpvFormat.FLAG)
            MPVLib.observeProperty("paused-for-cache", MPVLib.MpvFormat.FLAG)
            MPVLib.observeProperty("eof-reached", MPVLib.MpvFormat.FLAG)
            MPVLib.observeProperty("idle-active", MPVLib.MpvFormat.FLAG)
            MPVLib.observeProperty("speed", MPVLib.MpvFormat.DOUBLE)
            MPVLib.observeProperty("volume", MPVLib.MpvFormat.DOUBLE)
            MPVLib.observeProperty("track-list", MPVLib.MpvFormat.NODE)
            MPVLib.observeProperty("video-params/w", MPVLib.MpvFormat.INT64)
            MPVLib.observeProperty("video-params/h", MPVLib.MpvFormat.INT64)
            MPVLib.observeProperty("hwdec-current", MPVLib.MpvFormat.STRING)

            players[playerId] = instance

            // Load the video
            if (videoUrl.isNotEmpty()) {
                // 续播：在 loadfile 之前通过 start 属性指定起始位置，让 mpv 在加载时
                // 直接定位到续播点。旧做法是 loadfile 之后立刻发 seek，但 loadfile 是
                // 异步的，文件尚未解封装完成时 seek 会落空被丢弃，导致"时不时从头播放"。
                // 用 start 选项可彻底消除该竞态，且不会出现先闪一下片头的问题。
                if (startPositionMs > 0) {
                    MPVLib.setPropertyString("start", "${startPositionMs / 1000.0}")
                    android.util.Log.i(TAG, "Resume playback from ${startPositionMs / 1000.0}s")
                } else {
                    MPVLib.setPropertyString("start", "none")
                }
                MPVLib.command(arrayOf("loadfile", videoUrl, "replace"))
                val voMode = if (useGpuNext) "gpu-next" else "gpu"
                android.util.Log.i(TAG, "Loading video, SurfaceTexture/$voMode")
            } else {
                android.util.Log.w(TAG, "videoUrl is empty, not loading")
            }

            // Return result with texture info
            val resultMap = mutableMapOf<String, Any>(
                "playerId" to playerId,
                "textureId" to surfaceTextureEntry.id()
            )
            android.util.Log.i(TAG, "Created player with SurfaceTexture (textureId=${surfaceTextureEntry.id()})")
            result.success(resultMap)
        } catch (e: Throwable) {
            // 关键：必须捕获 Throwable 而非 Exception。
            // MPVLib / MpvInitBridge 首次访问会触发 object 的 init{} 静态初始化里的
            // System.loadLibrary()，.so 缺失/加载失败抛的是 UnsatisfiedLinkError /
            // ExceptionInInitializerError —— 它们继承 Error 而非 Exception，会绕过
            // catch(Exception) 直接在主线程未捕获 → 整个 App 崩溃(日志表现为 CRASH(JVM)、
            // 既无"初始化完成"也无"初始化失败")。捕获 Throwable 后降级为可恢复的错误，
            // 播放页按统一文案提示，并把真实原因抛回 Dart 落入日志。
            android.util.Log.e(TAG, "createPlayer failed", e)
            try { MPVLib.destroy() } catch (_: Throwable) {}
            try { surfaceTextureEntry?.release() } catch (_: Throwable) {}
            try { players.clear() } catch (_: Throwable) {}
            // 带上原生库加载失败详情（若有），让 Dart 日志直接看到"哪个 .so、为何加载失败"，
            // 而不是只看到下游的 "MPVLib.create 无实现"。
            val libInfo = MPVLib.loadErrors.let { if (it.isEmpty()) "" else " nativeLibLoad=[$it]" }
            result.error(
                "CREATE_ERROR",
                "${e.javaClass.simpleName}: ${e.message}$libInfo",
                null
            )
        }
    }

    /**
     * 检测设备是否支持杜比视界显示
     */
    private fun isDolbyVisionSupported(): Boolean {
        return try {
            val activity = context as? android.app.Activity ?: return false
            val display = activity.display ?: return false
            val hdrCapabilities = display.hdrCapabilities ?: return false
            val supportedHdrTypes = hdrCapabilities.supportedHdrTypes
            // Display.HdrCapabilities.DOLBY_VISION = 2
            supportedHdrTypes.contains(2)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "检测杜比视界支持失败: ${e.message}")
            false
        }
    }

    private fun setMpvOptions(
        hardwareDecoding: Boolean,
        useGpuNext: Boolean = false,
        httpProxy: String? = null,
        userAgent: String? = null,
        videoCacheDir: String? = null,
        diskCacheForwardBytes: Long = 0L,
        diskCacheBackBytes: Long = 0L,
    ) {
        // 用户自定义 HTTP 代理（mpv 不支持 SOCKS，SOCKS 场景在 TV 上经 mihomo 本地口中转）
        if (!httpProxy.isNullOrEmpty()) {
            MPVLib.setOptionString("http-proxy", httpProxy)
            android.util.Log.i(TAG, "mpv http-proxy enabled")
        }

        // 统一 UA：部分 CDN 拒绝 mpv/libavformat 默认 UA 导致取流失败（403/空响应）。
        if (!userAgent.isNullOrEmpty()) {
            MPVLib.setOptionString("user-agent", userAgent)
            android.util.Log.i(TAG, "mpv user-agent set: $userAgent")
        }

        // Video output - try gpu-next for better HDR/DV support, fallback to gpu if unavailable
        var actuallyUsingGpuNext = false
        if (useGpuNext) {
            try {
                MPVLib.setOptionString("vo", "gpu-next")
                actuallyUsingGpuNext = true
                android.util.Log.i(TAG, "Configured mpv for gpu-next rendering")
            } catch (e: Exception) {
                // gpu-next not available (requires Vulkan/libplacebo), fallback to gpu
                android.util.Log.w(TAG, "gpu-next not available, falling back to gpu: ${e.message}")
                MPVLib.setOptionString("vo", "gpu")
                android.util.Log.i(TAG, "Configured mpv for gpu rendering (fallback)")
            }
        } else {
            MPVLib.setOptionString("vo", "gpu")
            android.util.Log.i(TAG, "Configured mpv for gpu rendering")
        }

        // Common GPU settings
        MPVLib.setOptionString("gpu-context", "android")
        MPVLib.setOptionString("opengl-es", "yes")

        // HDR/杜比视界设置
        MPVLib.setOptionString("target-colorspace-hint", "yes")

        if (actuallyUsingGpuNext) {
            // gpu-next 模式：libplacebo 处理 DV RPU 元数据，正确映射 IPT-PQ 色空间
            MPVLib.setOptionString("dolby-vision-mode", "auto")
            MPVLib.setOptionString("tone-mapping", "spline")
            // hdr-compute-peak 是逐帧 GPU 直方图（compute shader），在移动 GPU 上开销很大。
            // 软解时 CPU 已被解码吃满，再叠加 per-frame 峰值检测会让画面明显卡顿，故软解路径
            // 关闭、改用静态元数据；硬解有 GPU 余量时保留以求更准的动态色调映射。
            MPVLib.setOptionString("hdr-compute-peak", if (hardwareDecoding) "yes" else "no")
            android.util.Log.i(TAG, "DV: gpu-next mode, libplacebo handles DV RPU (compute-peak=$hardwareDecoding)")
        } else {
            // gpu 模式：不处理 DV RPU，用 video filter 去除 DV 标记避免绿屏
            MPVLib.setOptionString("vf", "format:dolbyvision=no")
            android.util.Log.i(TAG, "DV: gpu mode, stripping DV metadata via vf filter")
        }

        // Hardware decoding
        if (hardwareDecoding) {
            // 盲修闪退：只用 mediacodec-copy（拷贝模式），不再优先 direct mediacodec。
            // direct mediacodec 把解码帧直接交给 Android Surface，需要 vo 与解码器共享
            // surface 并走 AImageReader 句柄，在部分机型/编码上首帧握手失败会原生 SIGSEGV，
            // 是"每次播放必闪退"的常见根源。copy 模式把帧拷回 CPU 再走 GL 上传，自包含、
            // 不依赖 surface 句柄交接，稳定得多；性能损失对流式直连可忽略。解码失败时 mpv
            // 仍会自动回退软解。
            MPVLib.setOptionString("hwdec", "mediacodec-copy")
            MPVLib.setOptionString("hwdec-codecs",
                "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1")
        } else {
            MPVLib.setOptionString("hwdec", "no")
            // 软解性能优化：4K HEVC/杜比视界纯软解极吃 CPU，默认配置下移动端会严重卡顿。
            // ① 解码线程铺满 CPU 核心——mpv 的 auto 在部分机型只用了一半核，显式给满。
            val decodeThreads = Runtime.getRuntime().availableProcessors().coerceIn(2, 16)
            MPVLib.setOptionString("vd-lavc-threads", decodeThreads.toString())
            // ② 跳过非参考帧的环路去块滤波 + 启用快速(非严格合规)解码路径：省下可观 CPU，
            //    肉眼几乎无损，是软解能否跑到实时帧率的关键。
            MPVLib.setOptionString("vd-lavc-skiploopfilter", "nonref")
            MPVLib.setOptionString("vd-lavc-fast", "yes")
            // ③ 解码器直接渲染，省一次帧拷贝。
            MPVLib.setOptionString("vd-lavc-dr", "yes")
            // ④ 仍跟不上实时时允许在 VO 丢帧追平，避免音画不同步与持续卡顿堆积。
            MPVLib.setOptionString("framedrop", "vo")
            android.util.Log.i(TAG, "Software decode tuned: threads=$decodeThreads, skiploopfilter=nonref, fast=yes")
        }

        // Audio output - 强制立体声降混，解决 TrueHD 等多声道音频无声问题
        MPVLib.setOptionString("ao", "audiotrack,opensles")
        MPVLib.setOptionString("audio-channels", "stereo")
        MPVLib.setOptionString("ad-lavc-downmix", "yes")
        // 简化音频过滤器 - 移除可能导致问题的 pan filter
        // 让 ad-lavc-downmix 自动处理多声道到立体声的转换
        // MPVLib.setOptionString("af", "lavfi=[pan=stereo|c0=c2+0.30*c0+0.30*c4|c1=c2+0.30*c1+0.30*c5]")

        // Config
        MPVLib.setOptionString("config", "yes")
        val configDir = File(context.filesDir, "mpv")
        configDir.mkdirs()
        MPVLib.setOptionString("config-dir", configDir.absolutePath)

        // Idle and window management
        MPVLib.setOptionString("idle", "once")
        MPVLib.setOptionString("force-window", "no")

        // Subtitles
        MPVLib.setOptionString("sub-visibility", "yes")
        // 字幕走 OSD 覆盖层渲染，不混入视频帧。blend-subtitles=video 会让
        // PGS/SUP 位图字幕每次刷新都重绘整帧，造成视频画面闪现。
        MPVLib.setOptionString("blend-subtitles", "no")
        MPVLib.setOptionString("sub-auto", "all")
        MPVLib.setOptionString("sub-ass", "yes")
        MPVLib.setOptionString("sub-codepage", "utf-8")
        // 关键：Android 上 libass 没有 fontconfig，必须显式给字体目录，否则内封/外挂的
        // 文本字幕(SRT/ASS)因找不到任何字体而整段不渲染——表现为"选了字幕也不显示"。
        // 指向系统字体目录，libass 可扫描到 NotoSansCJK / DroidSansFallback 等中文字体并
        // 在请求的字体名缺失时回退到可用字体（位图 PGS/SUP 不依赖字体，本就不受影响）。
        MPVLib.setOptionString("sub-fonts-dir", "/system/fonts")

        // Cache
        // 网络播放：按用户设置（300MB–8GB）把缓冲落到磁盘，避免大缓冲占满内存导致
        // 低配机/TV OOM 闪退。videoCacheDir 为空（本地文件）时退回小额内存缓冲即可。
        if (!videoCacheDir.isNullOrEmpty() && diskCacheForwardBytes > 0L) {
            File(videoCacheDir).mkdirs()
            MPVLib.setOptionString("cache", "yes")
            MPVLib.setOptionString("cache-on-disk", "yes")
            MPVLib.setOptionString("cache-dir", videoCacheDir)
            MPVLib.setOptionString("demuxer-max-bytes", diskCacheForwardBytes.toString())
            MPVLib.setOptionString("demuxer-max-back-bytes", diskCacheBackBytes.toString())
            MPVLib.setOptionString("demuxer-readahead-secs", "180")
            android.util.Log.i(TAG, "mpv disk cache: dir=$videoCacheDir fwd=$diskCacheForwardBytes back=$diskCacheBackBytes")
        } else {
            // 本地文件：无需大缓冲，沿用小额内存缓冲。
            MPVLib.setOptionString("demuxer-max-bytes", "64MiB")
            MPVLib.setOptionString("demuxer-max-back-bytes", "32MiB")
        }

        // TLS
        val cacert = File(context.filesDir, "cacert.pem")
        if (cacert.exists()) {
            MPVLib.setOptionString("tls-verify", "yes")
            MPVLib.setOptionString("tls-ca-file", cacert.absolutePath)
        } else {
            MPVLib.setOptionString("tls-verify", "no")
            android.util.Log.w(TAG, "cacert.pem not found, disabling TLS verification")
        }

        // Misc
        MPVLib.setOptionString("save-position-on-quit", "no")
        MPVLib.setOptionString("msg-level", "all=v")
    }

    private fun getPlayer(playerId: String): MpvPlayerInstance? = players[playerId]

    private fun disposePlayer(playerId: String) {
        mainHandler.post {
            players.remove(playerId)?.release()
        }
    }

    fun disposeAll() {
        mainHandler.post {
            players.values.forEach { it.release() }
            players.clear()
        }
    }

    /**
     * Represents a single mpv player instance.
     * Implements MPVLib.EventObserver to receive property change callbacks
     * from the native event thread and forwards them to Flutter via EventChannel.
     */
    class MpvPlayerInstance(
        val playerId: String,
        private val context: Context,
        private val surface: Surface,
        private val mpvTexture: MpvTexture?,  // Nullable when using SurfaceView
        private val eventChannel: EventChannel,
        private val mainHandler: Handler
    ) : MPVLib.EventObserver, MPVLib.LogObserver {

        private var eventSink: EventChannel.EventSink? = null
        private var currentTracks: List<Map<String, Any>> = emptyList()

        init {
            eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        }

        // ---- Playback control ----

        fun play() {
            android.util.Log.i(TAG, "play() - setting pause=false")
            MPVLib.setPropertyBoolean("pause", false)
        }

        fun pause() {
            android.util.Log.i(TAG, "pause() - setting pause=true")
            MPVLib.setPropertyBoolean("pause", true)
        }

        fun seekTo(positionMs: Int) {
            MPVLib.command(arrayOf("seek", "${positionMs / 1000.0}", "absolute"))
        }

        fun setSpeed(speed: Double) {
            MPVLib.setPropertyDouble("speed", speed.coerceIn(0.25, 8.0))
        }

        fun setVolume(volume: Double) {
            // mpv volume range is 0-100, Flutter passes 0.0-1.0
            MPVLib.setPropertyDouble("volume", (volume * 100).coerceIn(0.0, 100.0))
        }

        fun getPosition(): Int {
            val pos = MPVLib.getPropertyDouble("time-pos") ?: return 0
            return (pos * 1000).toInt()
        }

        fun getDuration(): Int {
            val dur = MPVLib.getPropertyDouble("duration") ?: return 0
            return (dur * 1000).toInt().coerceAtLeast(0)
        }

        fun getVideoSize(): Map<String, Int> {
            val w = MPVLib.getPropertyInt("video-params/w") ?: 0
            val h = MPVLib.getPropertyInt("video-params/h") ?: 0
            return mapOf("width" to w, "height" to h)
        }

        // ---- Track management ----

        fun getTracksInfo(): List<Map<String, Any>> = currentTracks

        fun selectSubtitleTrack(trackId: String) {
            MPVLib.command(arrayOf("set_property", "sid", trackId))
        }

        fun deselectSubtitleTrack() {
            MPVLib.command(arrayOf("set_property", "sid", "no"))
        }

        fun selectAudioTrack(trackId: String) {
            MPVLib.setPropertyString("aid", trackId)
        }

        fun loadSubtitle(subtitleUrl: String, language: String) {
            MPVLib.command(arrayOf("sub-add", subtitleUrl, "auto", "external-sub", language))
        }

        // ---- Property access ----

        fun setProperty(name: String, value: String) {
            MPVLib.setPropertyString(name, value)
        }

        fun getProperty(name: String): String? {
            return MPVLib.getPropertyString(name)
        }

        fun getPropertyDouble(name: String): Double? {
            return MPVLib.getPropertyDouble(name)
        }

        fun command(args: Array<out String>) {
            MPVLib.command(args)
        }

        // ---- Screenshot ----

        fun screenshot(): ByteArray? {
            val bitmap = MPVLib.grabThumbnail(1920) ?: return null
            val stream = java.io.ByteArrayOutputStream()
            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, stream)
            bitmap.recycle()
            return stream.toByteArray()
        }

        // ---- Aspect ratio ----

        fun setAspectRatio(ratio: String) {
            // 原生 mpv 在屏幕大小的 surface 里自行做缩放/letterbox，故比例由 mpv 属性控制：
            // video-aspect-override 改显示宽高比；keepaspect=no 变形拉伸铺满；panscan=1 保持
            // 比例放大裁切铺满。每个模式都把另外两项复位，避免上次模式残留。
            when (ratio) {
                "16:9" -> applyAspect(override = "16:9")
                "4:3" -> applyAspect(override = "4:3")
                "21:9" -> applyAspect(override = "21:9")
                "原始" -> applyAspect(override = "0") // 用片源原始比例
                "拉伸" -> applyAspect(override = "-1", keepAspect = false) // 变形铺满
                "铺满" -> applyAspect(override = "-1", panscan = 1.0) // 裁切铺满
                else -> applyAspect(override = "-1") // 自适应 / 自动
            }
        }

        private fun applyAspect(
            override: String,
            keepAspect: Boolean = true,
            panscan: Double = 0.0,
        ) {
            try {
                MPVLib.setPropertyBoolean("keepaspect", keepAspect)
                MPVLib.setPropertyDouble("panscan", panscan)
                MPVLib.setPropertyString("video-aspect-override", override)
            } catch (e: Exception) {
                android.util.Log.w(TAG, "applyAspect failed: ${e.message}")
            }
        }

        // ---- Release ----

        fun release() {
            MPVLib.removeObserver(this)
            MPVLib.removeLogObserver(this)

            // Detach surface from mpv (stops video rendering)
            try {
                MPVLib.setPropertyBoolean("force-window", false)
                MPVLib.detachSurface()
            } catch (e: Exception) {
                android.util.Log.w(TAG, "detachSurface failed", e)
            }

            // Destroy mpv context
            try {
                MPVLib.destroy()
            } catch (e: Exception) {
                android.util.Log.w(TAG, "MPVLib.destroy() failed", e)
            }

            // Release surface and Flutter texture
            // Note: When using SurfaceView, surface.release() is not needed
            // as the SurfaceView manages its own surface lifecycle
            try {
                surface.release()
            } catch (e: Exception) {
                android.util.Log.w(TAG, "surface.release() failed (may be SurfaceView)", e)
            }
            mpvTexture?.dispose()
            eventSink = null
        }

        // ---- EventObserver implementation ----

        override fun eventProperty(property: String) {
            // NONE format — just a notification that the property changed
            // We'll handle it when the typed value arrives
        }

        override fun eventProperty(property: String, value: Long) {
            when (property) {
                "video-params/w", "video-params/h" -> {
                    emitVideoSize()
                }
            }
        }

        override fun eventProperty(property: String, value: Boolean) {
            android.util.Log.v(TAG, "property[$property] = $value")
            when (property) {
                "pause" -> emitEvent("playing", !value)
                "paused-for-cache" -> emitEvent("buffering", value)
                // 不再用 eof-reached / idle-active 属性推断"播放完成"。
                // seek（尤其向前 seek）或缓冲枯竭时 mpv 会把 eof-reached 瞬时置 true，
                // 用它发 completed 会被上层当成"播放结束"→停止播放、画面消失、进度条停在
                // seek 点，正是"重新 seek 续播后没画面"的根因。真正的结束只认 END_FILE 事件。
            }
        }

        override fun eventProperty(property: String, value: String) {
            when (property) {
                "hwdec-current" -> {
                    // Available for stats
                }
            }
        }

        override fun eventProperty(property: String, value: Double) {
            android.util.Log.v(TAG, "property[$property] = $value")
            when (property) {
                "time-pos" -> emitEvent("timePos", (value * 1000).toLong())
                "duration" -> emitEvent("duration", (value * 1000).toLong())
                "speed" -> emitEvent("speed", value)
                "volume" -> emitEvent("volume", value / 100.0) // normalize to 0-1
            }
        }

        // ---- LogObserver implementation ----

        // mpv 自身的日志（来自 libmpv，经 libplayer.so 回调）。原本无人订阅，导致
        // 原生崩溃前的「最后遗言」全部丢失、用户导出的日志里什么都没有。这里订阅并把
        // 警告/错误/致命级别转发到 Flutter 侧 AppLogger 落盘，便于崩溃后取证。
        // mpv 级别：FATAL=10 ERROR=20 WARN=30 INFO=40 V=50 DEBUG=60 TRACE=70，数字越小越严重。
        override fun logMessage(prefix: String, level: Int, text: String) {
            if (level > MPVLib.MpvLogLevel.WARN) return // 仅转发 warn/error/fatal，避免刷屏
            val trimmed = text.trimEnd()
            if (trimmed.isEmpty()) return
            emitEvent(
                "log",
                mapOf("level" to level, "prefix" to prefix, "text" to trimmed)
            )
        }

        override fun event(eventId: Int) {
            android.util.Log.d(TAG, "mpv event: $eventId")
            when (eventId) {
                MPVLib.MpvEvent.START_FILE -> {
                    android.util.Log.i(TAG, "START_FILE")
                }
                MPVLib.MpvEvent.FILE_LOADED -> {
                    android.util.Log.i(TAG, "FILE_LOADED — emitting tracks and duration")
                    emitEvent("buffering", false)
                    loadTracks()

                    // 诊断日志：检查当前音频和字幕状态
                    val audioCodec = MPVLib.getPropertyString("audio-codec")
                    val audioCodecName = MPVLib.getPropertyString("audio-codec-name")
                    val currentAid = MPVLib.getPropertyInt("aid")
                    val currentSid = MPVLib.getPropertyInt("sid")
                    val subVisibility = MPVLib.getPropertyBoolean("sub-visibility")
                    val audioChannels = MPVLib.getPropertyString("audio-channels")
                    android.util.Log.i(TAG, "FILE_LOADED diagnostics:")
                    android.util.Log.i(TAG, "  audio-codec: $audioCodec")
                    android.util.Log.i(TAG, "  audio-codec-name: $audioCodecName")
                    android.util.Log.i(TAG, "  current aid: $currentAid")
                    android.util.Log.i(TAG, "  current sid: $currentSid")
                    android.util.Log.i(TAG, "  sub-visibility: $subVisibility")
                    android.util.Log.i(TAG, "  audio-channels: $audioChannels")

                    // 检查解码器列表
                    val decoderList = MPVLib.getPropertyString("decoder-list")
                    if (decoderList != null) {
                        val hasTruehd = decoderList.contains("truehd", ignoreCase = true)
                        val hasSubrip = decoderList.contains("subrip", ignoreCase = true)
                        val hasSrt = decoderList.contains("srt", ignoreCase = true)
                        val hasAss = decoderList.contains("ass", ignoreCase = true)
                        android.util.Log.i(TAG, "  decoder-list contains truehd: $hasTruehd")
                        android.util.Log.i(TAG, "  decoder-list contains subrip: $hasSubrip")
                        android.util.Log.i(TAG, "  decoder-list contains srt: $hasSrt")
                        android.util.Log.i(TAG, "  decoder-list contains ass: $hasAss")
                        // 打印前500字符的解码器列表
                        android.util.Log.i(TAG, "  decoder-list (first 500): ${decoderList.take(500)}")
                    }

                    val dur = MPVLib.getPropertyDouble("duration")
                    if (dur != null && dur > 0) {
                        emitEvent("duration", (dur * 1000).toLong())
                    }
                }
                MPVLib.MpvEvent.END_FILE -> {
                    android.util.Log.i(TAG, "END_FILE — emitting completed")
                    val reason = MPVLib.getPropertyInt("eof-reached")
                    emitEvent("completed", true)
                }
                MPVLib.MpvEvent.VIDEO_RECONFIG -> {
                    emitVideoSize()
                }
            }
        }

        // ---- Track parsing ----

        private fun loadTracks() {
            try {
                val count = MPVLib.getPropertyInt("track-list/count") ?: 0
                val trackList = mutableListOf<Map<String, Any>>()

                for (i in 0 until count) {
                    val type = MPVLib.getPropertyString("track-list/$i/type") ?: continue
                    val id = MPVLib.getPropertyInt("track-list/$i/id") ?: continue
                    val lang = MPVLib.getPropertyString("track-list/$i/lang") ?: ""
                    val title = MPVLib.getPropertyString("track-list/$i/title") ?: ""
                    val codec = MPVLib.getPropertyString("track-list/$i/codec") ?: ""
                    val selected = MPVLib.getPropertyBoolean("track-list/$i/selected") ?: false

                    val resolvedType = when (type) {
                        "video" -> "video"
                        "audio" -> "audio"
                        "sub" -> {
                            // Detect bitmap subtitles by codec
                            if (codec.contains("pgs", ignoreCase = true) ||
                                codec.contains("hdmv", ignoreCase = true) ||
                                codec.contains("dvd_subtitle", ignoreCase = true)) {
                                "bitmap"
                            } else {
                                "text"
                            }
                        }
                        else -> type
                    }

                    val isAss = codec.contains("ass", ignoreCase = true) ||
                            codec.contains("ssa", ignoreCase = true)

                    trackList.add(mapOf(
                        "id" to id.toString(),
                        "type" to resolvedType,
                        "language" to lang,
                        "label" to title,
                        "codec" to codec,
                        "isAss" to isAss,
                        "isBitmap" to (resolvedType == "bitmap"),
                        "isSelected" to selected
                    ))
                }

                currentTracks = trackList
                emitEvent("tracksChanged", trackList)
            } catch (e: Exception) {
                android.util.Log.e(TAG, "loadTracks failed", e)
            }
        }

        private fun emitVideoSize() {
            val w = MPVLib.getPropertyInt("video-params/w") ?: return
            val h = MPVLib.getPropertyInt("video-params/h") ?: return
            if (w > 0 && h > 0) {
                // Don't update SurfaceTexture buffer — let mpv handle aspect ratio
                // and letterboxing internally at the surface's native dimensions
                emitEvent("videoSize", mapOf("width" to w, "height" to h))
            }
        }

        private fun emitEvent(type: String, value: Any?) {
            mainHandler.post {
                eventSink?.success(mapOf("type" to type, "value" to value))
            }
        }
    }
}
