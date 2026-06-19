package com.example.linplayer_mobile

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.Surface
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackGroup
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.Cue
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import io.github.peerless2012.ass.media.kt.buildWithAssSupport
import io.github.peerless2012.ass.media.type.AssRenderType
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@OptIn(UnstableApi::class)
class ExoPlayerPlugin(
    private val context: Context,
    private val binaryMessenger: io.flutter.plugin.common.BinaryMessenger,
    private val textureRegistry: TextureRegistry
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val METHOD_CHANNEL = "com.linplayer/exoplayer"

        fun registerWith(engine: FlutterEngine, context: Context) {
            val plugin = ExoPlayerPlugin(
                context,
                engine.dartExecutor.binaryMessenger,
                engine.renderer
            )
            MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
                .setMethodCallHandler(plugin)
        }

        fun detectMimeType(url: String): String {
            var clean = url
            val qIdx = clean.indexOf('?')
            if (qIdx >= 0) clean = clean.substring(0, qIdx)
            val hIdx = clean.indexOf('#')
            if (hIdx >= 0) clean = clean.substring(0, hIdx)
            val lower = clean.lowercase()
            return when {
                lower.endsWith(".srt") -> MimeTypes.APPLICATION_SUBRIP
                lower.endsWith(".ass") || lower.endsWith(".ssa") -> MimeTypes.TEXT_SSA
                lower.endsWith(".vtt") -> MimeTypes.TEXT_VTT
                lower.endsWith(".ttml") || lower.endsWith(".dfxp") || lower.endsWith(".xml") -> MimeTypes.APPLICATION_TTML
                lower.endsWith(".pgs") || lower.endsWith(".sup") -> MimeTypes.APPLICATION_PGS
                lower.endsWith(".vob") -> MimeTypes.APPLICATION_VOBSUB
                else -> MimeTypes.APPLICATION_SUBRIP
            }
        }

        fun resolveSubtitleUri(url: String): Uri {
            if (url.startsWith("file://") || url.startsWith("http://") ||
                url.startsWith("https://") || url.startsWith("content://") ||
                url.startsWith("asset://")) {
                return Uri.parse(url)
            }
            val file = File(url)
            if (file.exists()) {
                return Uri.fromFile(file)
            }
            return Uri.parse(url)
        }
    }

    private val players = ConcurrentHashMap<String, ExoPlayerInstance>()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "createPlayer" -> {
                val videoUrl = call.argument<String>("videoUrl") ?: ""
                val startPositionMs = call.argument<Int>("startPositionMs") ?: 0
                val dolbyVisionFix = call.argument<Boolean>("dolbyVisionFix") ?: false
                val preferredSubtitleLanguage = call.argument<String>("preferredSubtitleLanguage")
                val enableAssSupport = call.argument<Boolean>("enableAssSupport") ?: false
                // 统一 UA：部分 CDN 拒绝默认 UA 导致取流失败。
                val userAgent = call.argument<String>("userAgent")
                createPlayer(
                    videoUrl,
                    startPositionMs,
                    dolbyVisionFix,
                    preferredSubtitleLanguage,
                    enableAssSupport,
                    userAgent,
                    result
                )
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
                val positionMs = call.argument<Int>("positionMs") ?: 0
                getPlayer(playerId)?.seekTo(positionMs.toLong())
                result.success(true)
            }
            "setSpeed" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val speed = call.argument<Double>("speed") ?: 1.0
                getPlayer(playerId)?.setSpeed(speed.toFloat())
                result.success(true)
            }
            "setVolume" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val volume = call.argument<Double>("volume") ?: 1.0
                getPlayer(playerId)?.setVolume(volume.toFloat())
                result.success(true)
            }
            "getPosition" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val pos = getPlayer(playerId)?.exoPlayer?.currentPosition?.toInt() ?: 0
                result.success(pos)
            }
            "getDuration" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val dur = getPlayer(playerId)?.exoPlayer?.duration?.toInt() ?: 0
                result.success(if (dur > 0) dur else 0)
            }
            "getVideoSize" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val size = getPlayer(playerId)?.getVideoSize()
                result.success(size ?: mapOf("width" to 0, "height" to 0))
            }
            "getTracks" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val tracks = getPlayer(playerId)?.getTracksInfo()
                result.success(tracks)
            }
            "selectTrack" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val groupIndex = call.argument<Int>("groupIndex") ?: 0
                val trackIndex = call.argument<Int>("trackIndex") ?: 0
                val trackType = call.argument<Int>("trackType") ?: C.TRACK_TYPE_TEXT
                getPlayer(playerId)?.selectTrack(groupIndex, trackIndex, trackType)
                result.success(true)
            }
            "deselectSubtitleTrack" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                getPlayer(playerId)?.deselectSubtitleTrack()
                result.success(true)
            }
            "loadSubtitle" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val subtitleUrl = call.argument<String>("subtitleUrl") ?: ""
                val subtitleMimeType = call.argument<String>("subtitleMimeType")
                val subtitleLanguage = call.argument<String>("subtitleLanguage")
                getPlayer(playerId)?.loadSubtitle(subtitleUrl, subtitleMimeType, subtitleLanguage)
                result.success(true)
            }
            "screenshot" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                getPlayer(playerId)?.screenshot(result)
            }
            "setSubtitleDelay" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val seconds = call.argument<Double>("seconds") ?: 0.0
                getPlayer(playerId)?.setSubtitleDelay(seconds)
                result.success(true)
            }
            "setAudioDelay" -> {
                result.success(true)
            }
            "setSubtitleFont" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val fontName = call.argument<String>("fontName") ?: ""
                getPlayer(playerId)?.setSubtitleFont(fontName)
                result.success(true)
            }
            "setSubtitleSize" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val size = call.argument<Double>("size") ?: 0.5
                getPlayer(playerId)?.setSubtitleSize(size)
                result.success(true)
            }
            "setSubtitlePosition" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val position = call.argument<Double>("position") ?: 0.5
                getPlayer(playerId)?.setSubtitlePosition(position)
                result.success(true)
            }
            "setSubtitleBackground" -> {
                val playerId = call.argument<String>("playerId") ?: ""
                val enabled = call.argument<Boolean>("enabled") ?: false
                getPlayer(playerId)?.setSubtitleBackground(enabled)
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
            else -> result.notImplemented()
        }
    }

    private fun createPlayer(
        videoUrl: String,
        startPositionMs: Int,
        dolbyVisionFix: Boolean,
        preferredSubtitleLanguage: String?,
        enableAssSupport: Boolean,
        userAgent: String?,
        result: MethodChannel.Result
    ) {
        mainHandler.post {
            try {
                val playerId = UUID.randomUUID().toString()

                val surfaceTextureEntry = textureRegistry.createSurfaceTexture()
                val surfaceTexture = surfaceTextureEntry.surfaceTexture()
                val surface = Surface(surfaceTexture)

                val trackSelector = DefaultTrackSelector(context)
                val paramsBuilder = trackSelector.buildUponParameters()
                    .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                    .setTrackTypeDisabled(C.TRACK_TYPE_IMAGE, false)
                    .setSelectUndeterminedTextLanguage(true)

                if (!preferredSubtitleLanguage.isNullOrEmpty()) {
                    paramsBuilder.setPreferredTextLanguage(preferredSubtitleLanguage)
                }
                trackSelector.parameters = paramsBuilder.build()

                val renderersFactory = DefaultRenderersFactory(context)
                    .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER)
                    .setEnableDecoderFallback(true)

                android.util.Log.i("ExoPlayerPlugin", "Creating ExoPlayer with Media3 extension renderers")

                // 统一 UA：用自定义 HTTP DataSource 工厂覆盖 ExoPlayer 默认 UA，
                // 部分 CDN 拒绝默认 UA 导致取流失败（403/空响应）。
                val playerBuilder = ExoPlayer.Builder(context)
                    .setTrackSelector(trackSelector)

                if (!userAgent.isNullOrEmpty()) {
                    val httpDataSourceFactory = androidx.media3.datasource.DefaultHttpDataSource.Factory()
                        .setUserAgent(userAgent)
                        .setAllowCrossProtocolRedirects(true)
                    val dataSourceFactory = androidx.media3.datasource.DefaultDataSource.Factory(
                        context, httpDataSourceFactory
                    )
                    playerBuilder.setMediaSourceFactory(
                        androidx.media3.exoplayer.source.DefaultMediaSourceFactory(dataSourceFactory)
                    )
                }

                val exoPlayer = if (enableAssSupport) {
                    android.util.Log.i("ExoPlayerPlugin", "Creating ExoPlayer with ass-media subtitle pipeline")
                    playerBuilder.buildWithAssSupport(
                        context = context,
                        renderType = AssRenderType.CUES,
                        renderersFactory = renderersFactory
                    )
                } else {
                    playerBuilder
                        .setRenderersFactory(renderersFactory)
                        .build()
                }
                exoPlayer.setVideoSurface(surface)

                val mediaItem = MediaItem.Builder()
                    .setUri(videoUrl)
                    .build()
                exoPlayer.setMediaItem(mediaItem)
                exoPlayer.prepare()

                if (startPositionMs > 0) {
                    exoPlayer.seekTo(startPositionMs.toLong())
                }

                val eventChannel = EventChannel(
                    binaryMessenger,
                    "com.linplayer/exoplayer/events/$playerId"
                )

                val instance = ExoPlayerInstance(
                    playerId = playerId,
                    exoPlayer = exoPlayer,
                    trackSelector = trackSelector,
                    surfaceTextureEntry = surfaceTextureEntry,
                    surface = surface,
                    eventChannel = eventChannel,
                )

                exoPlayer.addListener(instance)
                players[playerId] = instance

                result.success(mapOf(
                    "playerId" to playerId,
                    "textureId" to surfaceTextureEntry.id()
                ))
            } catch (e: Exception) {
                result.error("CREATE_ERROR", e.message, null)
            }
        }
    }

    private fun getPlayer(playerId: String): ExoPlayerInstance? = players[playerId]

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

    @OptIn(UnstableApi::class)
    class ExoPlayerInstance(
        val playerId: String,
        val exoPlayer: ExoPlayer,
        val trackSelector: DefaultTrackSelector,
        val surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry,
        val surface: Surface,
        private val eventChannel: EventChannel,
    ) : Player.Listener {

        private var eventSink: EventChannel.EventSink? = null
        private val instanceHandler = Handler(Looper.getMainLooper())

        private var subtitleDelayMs: Long = 0
        private var externalSubtitles: MutableList<MediaItem.SubtitleConfiguration> = mutableListOf()

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

        fun play() = exoPlayer.play()
        fun pause() = exoPlayer.pause()
        fun seekTo(positionMs: Long) = exoPlayer.seekTo(positionMs)

        fun setSpeed(speed: Float) {
            exoPlayer.playbackParameters = PlaybackParameters(speed)
        }

        fun setVolume(volume: Float) {
            exoPlayer.volume = volume
        }

        fun setSubtitleDelay(seconds: Double) {
            subtitleDelayMs = (seconds * 1000).toLong()
        }

        fun setSubtitleFont(fontName: String) {}

        fun setSubtitleSize(size: Double) {}

        fun setSubtitlePosition(position: Double) {}

        fun setSubtitleBackground(enabled: Boolean) {}

        fun setAspectRatio(ratio: String) {
            val paramsBuilder = trackSelector.buildUponParameters()
            when (ratio) {
                "16:9" -> paramsBuilder.setViewportSize(16, 9, false)
                "4:3" -> paramsBuilder.setViewportSize(4, 3, false)
                "21:9" -> paramsBuilder.setViewportSize(21, 9, false)
                else -> paramsBuilder.clearViewportSizeConstraints()
            }
            trackSelector.parameters = paramsBuilder.build()
        }

        fun getTracksInfo(): List<Map<String, Any>> {
            return currentTracks
        }

        fun getVideoSize(): Map<String, Int> {
            val size = exoPlayer.videoSize
            return mapOf(
                "width" to size.width,
                "height" to size.height
            )
        }

        fun selectTrack(groupIndex: Int, trackIndex: Int, trackType: Int) {
            val tracks = exoPlayer.currentTracks
            if (groupIndex < tracks.groups.size) {
                val group = tracks.groups[groupIndex]
                if (trackIndex < group.length) {
                    val actualTrackType = group.type
                    val format = group.getTrackFormat(trackIndex)
                    val mime = format.sampleMimeType ?: ""
                    val codec = format.codecs ?: ""
                    android.util.Log.i("ExoPlayerPlugin", "selectTrack: group=$groupIndex, track=$trackIndex, actualType=$actualTrackType, mime=$mime, codec=$codec")
                    
                    val trackSelection = TrackSelectionOverride(group.mediaTrackGroup, listOf(trackIndex))
                    val paramsBuilder = trackSelector.buildUponParameters()
                    paramsBuilder.clearOverridesOfType(actualTrackType)
                    paramsBuilder.setOverrideForType(trackSelection)
                    if (actualTrackType == C.TRACK_TYPE_TEXT || actualTrackType == C.TRACK_TYPE_IMAGE) {
                        paramsBuilder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                        paramsBuilder.setTrackTypeDisabled(C.TRACK_TYPE_IMAGE, false)
                        val subType = if (mime.contains("pgs", ignoreCase = true) || mime.contains("hdmv", ignoreCase = true) || mime.contains("vobsub", ignoreCase = true) || mime.contains("dvb", ignoreCase = true)) "bitmap" else if (mime.contains("ssa", ignoreCase = true) || mime.contains("ass", ignoreCase = true)) "ass" else "text"
                        android.util.Log.i("ExoPlayerPlugin", "selectTrack: subtitle type=$subType")
                        emitEvent("subtitleType", subType)
                        
                        // PGS/SUP 图形字幕需要额外确保 bitmap 字幕渲染开启
                        if (subType == "bitmap") {
                            isBitmapSubtitle = true
                            emitEvent("subtitle", "")
                        }
                    }
                    trackSelector.parameters = paramsBuilder.build()
                    android.util.Log.i("ExoPlayerPlugin", "selectTrack: track selection applied")
                } else {
                    android.util.Log.w("ExoPlayerPlugin", "selectTrack: trackIndex out of bounds, group=$groupIndex, track=$trackIndex, groupLength=${group.length}")
                }
            } else {
                android.util.Log.w("ExoPlayerPlugin", "selectTrack: groupIndex out of bounds, group=$groupIndex, totalGroups=${tracks.groups.size}")
            }
        }

        fun deselectSubtitleTrack() {
            val paramsBuilder = trackSelector.buildUponParameters()
            paramsBuilder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            paramsBuilder.setTrackTypeDisabled(C.TRACK_TYPE_IMAGE, true)
            trackSelector.parameters = paramsBuilder.build()
        }

        private var lastLoadedSubtitleMimeType: String? = null

        fun loadSubtitle(subtitleUrl: String, subtitleMimeType: String?, subtitleLanguage: String?) {
            val mimeType = subtitleMimeType ?: Companion.detectMimeType(subtitleUrl)
            val isGraphical = mimeType == MimeTypes.APPLICATION_PGS || mimeType == MimeTypes.APPLICATION_VOBSUB || mimeType == MimeTypes.APPLICATION_DVBSUBS
            val isAss = mimeType == MimeTypes.TEXT_SSA

            if (isGraphical) {
                emitEvent("subtitleType", "bitmap")
            } else if (isAss) {
                emitEvent("subtitleType", "ass")
            } else {
                emitEvent("subtitleType", "text")
            }

            val subtitleUri = resolveSubtitleUri(subtitleUrl)
            val subtitleConfig = MediaItem.SubtitleConfiguration.Builder(subtitleUri)
                .setMimeType(mimeType)
                .setLanguage(subtitleLanguage ?: "und")
                .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
                .setId("ext_${externalSubtitles.size}")
                .build()

            externalSubtitles.add(subtitleConfig)
            lastLoadedSubtitleMimeType = mimeType

            val currentMediaItem = exoPlayer.currentMediaItem
            if (currentMediaItem != null) {
                val allSubtitles = currentMediaItem.localConfiguration?.subtitleConfigurations?.toMutableList() ?: mutableListOf()
                allSubtitles.add(subtitleConfig)

                val currentPosition = exoPlayer.currentPosition
                val playWhenReady = exoPlayer.playWhenReady

                val newMediaItem = currentMediaItem.buildUpon()
                    .setSubtitleConfigurations(allSubtitles)
                    .build()

                val paramsBuilder = trackSelector.buildUponParameters()
                paramsBuilder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                paramsBuilder.setTrackTypeDisabled(C.TRACK_TYPE_IMAGE, false)
                paramsBuilder.setSelectUndeterminedTextLanguage(true)
                paramsBuilder.setPreferredTextLanguage(subtitleLanguage ?: "und")
                trackSelector.parameters = paramsBuilder.build()

                exoPlayer.playWhenReady = playWhenReady
                exoPlayer.setMediaItem(newMediaItem, currentPosition)
                exoPlayer.prepare()
            }
        }

        private fun forceSelectLatestSubtitleTrack() {
            try {
                val tracks = exoPlayer.currentTracks
                val groups = tracks.groups
                val targetMime = lastLoadedSubtitleMimeType?.lowercase()

                var bestGroupIdx = -1
                var bestTrackIdx = -1

                for (groupIndex in groups.indices) {
                    val group = groups[groupIndex]
                    if (group.type != C.TRACK_TYPE_TEXT && group.type != C.TRACK_TYPE_IMAGE) continue
                    for (trackIndex in 0 until group.length) {
                        val format = group.getTrackFormat(trackIndex)
                        val mime = format.sampleMimeType?.lowercase() ?: ""
                        if (targetMime != null && mime.contains(targetMime.substringAfterLast("/"))) {
                            bestGroupIdx = groupIndex
                            bestTrackIdx = trackIndex
                        }
                    }
                }

                if (bestGroupIdx < 0) {
                    val lastTextGroupIdx = groups.indices.lastOrNull { gi ->
                        val g = groups[gi]
                        g.type == C.TRACK_TYPE_TEXT || g.type == C.TRACK_TYPE_IMAGE
                    }
                    if (lastTextGroupIdx != null) {
                        val group = groups[lastTextGroupIdx]
                        bestGroupIdx = lastTextGroupIdx
                        bestTrackIdx = group.length - 1
                    }
                }

                if (bestGroupIdx >= 0 && bestTrackIdx >= 0) {
                    val group = groups[bestGroupIdx]
                    val override = TrackSelectionOverride(group.mediaTrackGroup, listOf(bestTrackIdx))
                    val paramsBuilder = trackSelector.buildUponParameters()
                    paramsBuilder.setOverrideForType(override)
                    paramsBuilder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                    paramsBuilder.setTrackTypeDisabled(C.TRACK_TYPE_IMAGE, false)
                    trackSelector.parameters = paramsBuilder.build()
                    val selectedMime = group.getTrackFormat(bestTrackIdx).sampleMimeType ?: "unknown"
                    emitEvent("subtitleType", if (selectedMime.contains("pgs", ignoreCase = true) || selectedMime.contains("hdmv", ignoreCase = true) || selectedMime.contains("vobsub", ignoreCase = true) || selectedMime.contains("dvb", ignoreCase = true)) "bitmap" else if (selectedMime.contains("ssa", ignoreCase = true) || selectedMime.contains("ass", ignoreCase = true)) "ass" else "text")
                }
            } catch (e: Exception) {
                emitEvent("subtitleError", "forceSelect failed: ${e.message}")
            }
        }

        fun screenshot(result: MethodChannel.Result) {
            try {
                val width = exoPlayer.videoSize.width
                val height = exoPlayer.videoSize.height
                if (width <= 0 || height <= 0) {
                    result.success(null)
                    return
                }

                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                val latch = CountDownLatch(1)
                var copyResult = false

                android.view.PixelCopy.request(
                    surface,
                    bitmap,
                    { copyResultCode ->
                        copyResult = copyResultCode == android.view.PixelCopy.SUCCESS
                        latch.countDown()
                    },
                    instanceHandler
                )

                Thread {
                    latch.await(2, TimeUnit.SECONDS)
                    if (copyResult) {
                        val stream = java.io.ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                        val bytes = stream.toByteArray()
                        bitmap.recycle()
                        instanceHandler.post {
                            result.success(bytes)
                        }
                    } else {
                        bitmap.recycle()
                        instanceHandler.post {
                            result.success(null)
                        }
                    }
                }.start()
            } catch (e: Exception) {
                result.success(null)
            }
        }

        fun release() {
            exoPlayer.removeListener(this)
            exoPlayer.release()
            surface.release()
            surfaceTextureEntry.release()
            eventSink = null
        }

        private fun emitEvent(type: String, value: Any?) {
            instanceHandler.post {
                eventSink?.success(mapOf("type" to type, "value" to value))
            }
        }

        private var isBitmapSubtitle: Boolean = false
        private var toneMappingApplied: Boolean = false

        /// 检测当前选中的视频轨是否为 HDR / 杜比视界；是则启用 Media3 的
        /// effects 管线（DefaultVideoFrameProcessor）做 HDR→SDR tone-map。
        /// 视频输出到 Flutter 的 SurfaceTexture（SDR 表面），若不 tone-map，
        /// BT.2020 PQ 会直接灌到 SDR 表面 → 画面发灰/去饱和。
        /// 仅在检测到 HDR 时启用，避免给普通 SDR 视频引入 GL 处理开销。
        @OptIn(UnstableApi::class)
        private fun maybeEnableHdrToneMapping(tracks: Tracks) {
            if (toneMappingApplied) return
            var isHdr = false
            for (group in tracks.groups) {
                if (group.type != C.TRACK_TYPE_VIDEO) continue
                for (i in 0 until group.length) {
                    if (!group.isTrackSelected(i)) continue
                    val f = group.getTrackFormat(i)
                    val transfer = f.colorInfo?.colorTransfer
                    val mime = f.sampleMimeType ?: ""
                    val codecs = f.codecs ?: ""
                    if (transfer == C.COLOR_TRANSFER_ST2084 ||
                        transfer == C.COLOR_TRANSFER_HLG ||
                        mime.equals(MimeTypes.VIDEO_DOLBY_VISION, ignoreCase = true) ||
                        codecs.startsWith("dvh", ignoreCase = true) ||
                        codecs.startsWith("dav", ignoreCase = true)
                    ) {
                        isHdr = true
                    }
                }
            }
            if (!isHdr) return
            try {
                // 空 effects 列表即可让帧经 DefaultVideoFrameProcessor，
                // 在 SDR 输出表面上自动对 HDR 源做 tone-mapping。
                exoPlayer.setVideoEffects(emptyList())
                toneMappingApplied = true
                android.util.Log.i("ExoPlayerPlugin", "HDR/DV detected -> enabled SDR tone mapping")
                emitEvent("hdrToneMapping", true)
            } catch (e: Exception) {
                android.util.Log.w("ExoPlayerPlugin", "enable HDR tone mapping failed: ${e.message}")
            }
        }

        override fun onCues(cueGroup: CueGroup) {
            onCues(cueGroup.cues)
        }

        override fun onCues(cues: List<Cue>) {
            val textParts = mutableListOf<String>()
            val bitmapParts = mutableListOf<Map<String, Any>>()
            var hasBitmap = false
            var hasAnyCue = false
            
            android.util.Log.d("ExoPlayerPlugin", "onCues: received ${cues.size} cues, isBitmapSubtitle=$isBitmapSubtitle")

            for (cue in cues) {
                hasAnyCue = true
                val bmp = cue.bitmap
                if (bmp != null) {
                    hasBitmap = true
                    android.util.Log.d("ExoPlayerPlugin", "onCues: bitmap cue found, size=${bmp.width}x${bmp.height}")
                    try {
                        var src = bmp

                        val maxDim = 1920
                        if (src.width > maxDim || src.height > maxDim) {
                            val scale = minOf(maxDim.toFloat() / src.width, maxDim.toFloat() / src.height)
                            val newW = (src.width * scale).toInt()
                            val newH = (src.height * scale).toInt()
                            val scaled = Bitmap.createScaledBitmap(src, newW, newH, true)
                            if (scaled != src) {
                                src.recycle()
                            }
                            src = scaled
                        }

                        val processed = ensureArgb8888(src)
                        if (processed != src) {
                            src.recycle()
                        }

                        val stream = ByteArrayOutputStream()
                        processed.compress(Bitmap.CompressFormat.PNG, 100, stream)
                        val bytes = stream.toByteArray()
                        processed.recycle()
                        val base64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
                        val bmpInfo = mutableMapOf<String, Any>("data" to base64)
                        try {
                            if (cue.position != Cue.DIMEN_UNSET) bmpInfo["left"] = cue.position
                            if (cue.line != Cue.DIMEN_UNSET &&
                                cue.lineType == Cue.LINE_TYPE_FRACTION
                            ) {
                                bmpInfo["top"] = cue.line
                            }
                            if (cue.size != Cue.DIMEN_UNSET) bmpInfo["width"] = cue.size
                            // 关键：转发 bitmapHeight（高度占帧高的比例）。ass-media 渲染
                            // ASS 时给每个事件一张精确定位的位图并带 left/top/width/height，
                            // 之前漏掉 height 导致 Flutter 侧只能按宽度缩放、字号/位置失真。
                            if (cue.bitmapHeight != Cue.DIMEN_UNSET) bmpInfo["height"] = cue.bitmapHeight
                        } catch (_: Exception) {}
                        bitmapParts.add(bmpInfo)
                    } catch (e: Exception) {
                        emitEvent("subtitleError", "bitmap processing failed: ${e.message}")
                    }
                }
                val txt = cue.text
                if (txt != null && txt.isNotEmpty()) {
                    val textStr = txt.toString()
                    if (textStr.isNotBlank()) {
                        textParts.add(textStr)
                    }
                }
            }

            if (hasBitmap) {
                isBitmapSubtitle = true
                if (bitmapParts.isNotEmpty()) {
                    val images = bitmapParts.map { it["data"] as String }
                    // positions 与 images 严格按下标对齐（旧实现用 mapNotNull 丢掉无位置项，
                    // 导致两列表错位）。每项仅带已知的几何字段，缺失则交给 Flutter 兜底。
                    val positions = bitmapParts.map { m ->
                        val p = HashMap<String, Any>()
                        (m["left"] as? Float)?.let { p["left"] = it }
                        (m["top"] as? Float)?.let { p["top"] = it }
                        (m["width"] as? Float)?.let { p["width"] = it }
                        (m["height"] as? Float)?.let { p["height"] = it }
                        p
                    }
                    emitEvent("subtitleBitmap", mapOf(
                        "images" to images,
                        "text" to textParts.joinToString("\n"),
                        "positions" to positions
                    ))
                } else {
                    emitEvent("subtitle", textParts.joinToString("\n"))
                }
            } else if (textParts.isNotEmpty()) {
                isBitmapSubtitle = false
                emitEvent("subtitle", textParts.joinToString("\n"))
            } else if (hasAnyCue && isBitmapSubtitle) {
                // Bitmap subtitle track active but no bitmap at this moment (e.g. between subtitles)
                // Keep bitmap mode but clear display
                emitEvent("subtitleBitmap", mapOf(
                    "images" to emptyList<String>(),
                    "text" to "",
                    "positions" to emptyList<Map<String, Float>>()
                ))
            } else {
                isBitmapSubtitle = false
                emitEvent("subtitle", "")
            }
        }

        private fun ensureArgb8888(src: Bitmap): Bitmap {
            if (src.config == Bitmap.Config.ARGB_8888) return src
            val result = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(result)
            val paint = Paint()
            canvas.drawBitmap(src, 0f, 0f, paint)
            return result
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            when (playbackState) {
                Player.STATE_BUFFERING -> emitEvent("buffering", true)
                Player.STATE_READY -> {
                    emitEvent("buffering", false)
                    emitEvent("duration", exoPlayer.duration.toInt())
                    emitCurrentVideoSize()
                }
                Player.STATE_ENDED -> emitEvent("completed", true)
            }
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            emitEvent("playing", isPlaying)
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width > 0 && videoSize.height > 0) {
                surfaceTextureEntry.surfaceTexture().setDefaultBufferSize(
                    videoSize.width, videoSize.height
                )
                emitCurrentVideoSize()
            }
        }

        private fun emitCurrentVideoSize() {
            val size = exoPlayer.videoSize
            if (size.width > 0 && size.height > 0) {
                emitEvent("videoSize", mapOf(
                    "width" to size.width,
                    "height" to size.height
                ))
            }
        }

        override fun onTracksChanged(tracks: Tracks) {
            val trackList = mutableListOf<Map<String, Any>>()
            tracks.groups.forEachIndexed { groupIndex, group ->
                val type = when (group.type) {
                    C.TRACK_TYPE_AUDIO -> "audio"
                    C.TRACK_TYPE_TEXT -> "text"
                    C.TRACK_TYPE_VIDEO -> "video"
                    C.TRACK_TYPE_IMAGE -> "bitmap"
                    else -> {
                        val firstMime = if (group.length > 0) group.getTrackFormat(0).sampleMimeType else null
                        if (firstMime != null && (firstMime.contains("pgs", ignoreCase = true) ||
                                    firstMime.contains("hdmv", ignoreCase = true) ||
                                    firstMime.contains("vobsub", ignoreCase = true) ||
                                    firstMime.contains("dvd", ignoreCase = true) ||
                                    firstMime.contains("dvb", ignoreCase = true))) {
                            "bitmap"
                        } else if (group.length > 0) {
                            val lang = group.getTrackFormat(0).language
                            if (!lang.isNullOrEmpty()) "text" else "unknown"
                        } else {
                            "unknown"
                        }
                    }
                }
                for (i in 0 until group.length) {
                    val format = group.getTrackFormat(i)
                    val mimeType = format.sampleMimeType ?: ""
                    val isBitmap = mimeType.contains("pgs", ignoreCase = true) ||
                            mimeType.contains("hdmv", ignoreCase = true) ||
                            mimeType.contains("vobsub", ignoreCase = true) ||
                            mimeType.contains("dvd", ignoreCase = true) ||
                            mimeType.contains("dvb", ignoreCase = true)
                    val isAss = mimeType.contains("ssa", ignoreCase = true) ||
                            mimeType.contains("ass", ignoreCase = true)
                    val resolvedType = if (isBitmap && type == "text") "bitmap" else type
                    trackList.add(mapOf(
                        "id" to "${groupIndex}_$i",
                        "groupIndex" to groupIndex,
                        "trackIndex" to i,
                        "type" to resolvedType,
                        "trackType" to group.type,
                        "language" to (format.language ?: ""),
                        "label" to (format.label ?: ""),
                        "mimeType" to mimeType,
                        "codec" to (format.codecs ?: ""),
                        "isAss" to isAss,
                        "isBitmap" to isBitmap,
                        "isSelected" to group.isTrackSelected(i)
                    ))
                }
            }
            currentTracks = trackList
            emitEvent("tracksChanged", trackList)
            maybeEnableHdrToneMapping(tracks)

            if (lastLoadedSubtitleMimeType != null) {
                instanceHandler.postDelayed({
                    forceSelectLatestSubtitleTrack()
                    lastLoadedSubtitleMimeType = null
                }, 500)
            }
        }

        override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
            emitEvent("error", error.message)
        }
    }
}
