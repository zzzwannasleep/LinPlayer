package xyz.linplayer.app.ui.player

import android.graphics.Bitmap
import android.view.SurfaceView
import androidx.annotation.OptIn
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.Cue
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import kotlinx.coroutines.delay
import xyz.linplayer.app.BuildConfig

/**
 * libass 找字体的目录。
 *
 * ☠ 这份 libmpv 里**一个 fontconfig 符号都没有**(实测 `Fc*` 为 0),
 * 所以字体只能走 libass 的目录提供者。不给的话它一个字体都找不到,
 * **文本字幕整段不显示**而且不报错 —— 和 mpv 那条路的 `sub-fonts-dir` 是同一件事。
 */
private const val FONTS_DIR = "/system/fonts"

/**
 * 第二个播放内核:ExoPlayer(U1.6b)。
 *
 * ★ **它和 mpv 是并列关系,不是替代**【用户定 2026-09-06】。两者各有死角:
 *   libmpv 在部分机型上出「有声音没画面」(vo 绑不上 Surface),
 *   ExoPlayer 认不了一部分容器/字幕但走的是平台 MediaCodec、稳。给用户一个开关。
 *
 * ☠ **分叉点只有「谁去解码渲染」这一处。** 取哪条流、从第几秒开始、
 *   版本正则、跨服续播、start/stop 上报 —— 全部照旧走核心层的 `player.play`
 *   (带 `engine=exo`,它算完一切、只是不 loadfile,把地址回给这里)。
 *   在 UI 里自己拼地址是**明令禁止**的:反代只在 `/emby/` 下处理 Range,
 *   拼错的表现是「跳到没缓冲的位置就卡死」,而且查不出来。
 */
@OptIn(UnstableApi::class)
@Composable
fun rememberExoPlayer(enabled: Boolean, preferredSubLang: String?): ExoPlayer? {
    val ctx = LocalContext.current
    if (!enabled) return null
    val player = remember {
        /* ★ UA 必须是 `LinPlayer/<版本>`(UA 三分口径)。不设的话 ExoPlayer 发的是
           `media3/x.y.z` —— 服务端的设备列表、会话归属、按 UA 做的分流全会对不上,
           而**播放本身照常能播**,所以这类错不会自己冒出来。 */
        val http = DefaultHttpDataSource.Factory()
            .setUserAgent("LinPlayer/" + BuildConfig.VERSION_NAME)
            .setAllowCrossProtocolRedirects(true)   // Emby 直传常常 302 到 CDN
        /* ☠☠ **特效字幕的唯一入口就是这一行。**
           media3 1.11 的字幕解析发生在解封装阶段(`TextRenderer` 已经没有
           `SubtitleParser.Factory` 构造参数了),所以想拿到 ASS 的原始事件,
           只能在 MediaSource 这一层换掉解析器。换晚了 / 换错层的表现是
           「libass 初始化成功,但一条事件都没进去」—— 而那看着就像 libass 没接上。 */
        val sources = DefaultMediaSourceFactory(http)
            .setSubtitleParserFactory(LibassParserFactory(FONTS_DIR))
        ExoPlayer.Builder(ctx)
            .setMediaSourceFactory(sources)
            .build()
    }
    /* ☠☠ **不设这两项 = 一条字幕都不会被选中。**
       DefaultTrackSelector 默认只在「语言命中偏好」或「系统开了无障碍字幕」时才启用
       文本轨,而 `preferredTextLanguage` 是空的 —— 于是内封字幕明明在,
       `onCues` 一次都不回调,界面上就是「完全没有字幕」。用户报的正是这一条。
       语言偏好走播放偏好里的 `sub_lang`;它是空的时候
       `selectUndeterminedTextLanguage` 兜住「没标语言」的那些轨,
       两条都命中不了的由 [pickSubtitleTrack] 在轨道表到手之后再补一次。 */
    DisposableEffect(player, preferredSubLang) {
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setPreferredTextLanguage(preferredSubLang?.takeIf { it.isNotBlank() })
            .setSelectUndeterminedTextLanguage(true)
            .build()
        onDispose { }
    }
    DisposableEffect(player) { onDispose { player.release() } }
    return player
}

/**
 * 兜底选一条字幕轨。
 *
 * 语言偏好没命中时(片源标的是 `chi` 而偏好写的是 `zh`,或者干脆一条都没标),
 * DefaultTrackSelector 会**一条都不选**。这里在轨道表到手之后补一次:
 * 有文本轨、又一条都没选中 → 选第一条。
 *
 * ★ 用户显式关了字幕(`sub_lang == ""`)时**不补** —— 那是他自己关的。
 */
@OptIn(UnstableApi::class)
private fun pickSubtitleTrack(player: ExoPlayer, tracks: Tracks, subOff: Boolean) {
    if (subOff) return
    val texts = tracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }
    if (texts.isEmpty() || texts.any { it.isSelected }) return
    player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
        .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
        .setOverrideForType(TrackSelectionOverride(texts.first().mediaTrackGroup, 0))
        .build()
}

/** 把一条地址交给 ExoPlayer,并从 [startSecs] 起播。 */
fun ExoPlayer.load(url: String, startSecs: Double) {
    setMediaItem(MediaItem.fromUri(url))
    prepare()
    if (startSecs > 0) seekTo((startSecs * 1000).toLong())
    playWhenReady = true
}

/**
 * ExoPlayer 的视频层。
 *
 * ★ 和 mpv 那条一样用 `SurfaceView` 而不是 `TextureView`:独立合成层,
 *   Compose 的 OSD 天然画在它上面,零 overdraw。
 * ★ **解绑写在 onDispose 里**:不解的话换内核 / 退出播放页之后,
 *   ExoPlayer 还攥着一个已经没了的 Surface。
 *
 * ☠☠ **画面比例必须自己算。**
 *   裸 `SurfaceView` 把画面**拉满整个 View**,不管片源是什么比例 ——
 *   用户报的「画面比例不对,直接被拉伸,没有自适应」就是这一条。
 *   `media3-ui` 的 `AspectRatioFrameLayout` 能干这件事,但为它多引一个包不值当
 *   (那个包还会顺带把一整套我们不用的控制条拖进来):
 *   `onVideoSizeChanged` 的宽高 + `Modifier.aspectRatio` 就够了,而且比例算在
 *   Compose 侧,和 OSD 用的是同一套坐标。
 *   ★ 必须乘 `pixelWidthHeightRatio`:非方形像素的片源(DVD 源、部分 1080i)
 *     光看 width/height 会算出一个瘦长的画面,而这在编译期看不出来。
 */
@Composable
fun ExoSurface(player: ExoPlayer, subOff: Boolean, m: Modifier = Modifier) {
    var ratio by remember(player) { mutableFloatStateOf(0f) }
    var videoW by remember(player) { mutableIntStateOf(0) }
    var videoH by remember(player) { mutableIntStateOf(0) }

    DisposableEffect(player, subOff) {
        val l = object : Player.Listener {
            override fun onVideoSizeChanged(size: VideoSize) {
                val par = if (size.pixelWidthHeightRatio > 0f) size.pixelWidthHeightRatio else 1f
                ratio = if (size.height > 0 && size.width > 0) size.width * par / size.height else 0f
                videoW = size.width; videoH = size.height
            }

            override fun onTracksChanged(tracks: Tracks) {
                pickSubtitleTrack(player, tracks, subOff)
                syncLibassTrack(tracks, subOff)
            }
        }
        player.addListener(l)
        onDispose { player.removeListener(l) }
    }

    /* 外层铺满(黑边归它),内层按真实比例。
       ★ `Modifier.aspectRatio` 单独用就是 FIT:它按外层给的最大约束试宽、放不下再试高,
         宽片得到上下黑边、竖片得到左右黑边。**不要再叠 fillMaxSize()** ——
         叠上去两个约束都被钉死,比例这一条当场失效(表现就是照样拉伸)。
       ★ 比例还不知道时先铺满:首帧一到 onVideoSizeChanged 会纠正,
         而这期间画面本来就还没有。 */
    val fit = if (ratio > 0f) Modifier.aspectRatio(ratio) else Modifier.fillMaxSize()
    Box(m, contentAlignment = Alignment.Center) {
        AndroidView(
            modifier = fit,
            factory = { ctx -> SurfaceView(ctx).also { player.setVideoSurfaceView(it) } },
        )
        /* ★ 特效字幕**必须和画面用同一个 `fit`**:libass 按 PlayResX/Y 定位,
           叠加层只要和画面差一个黑边的高度,`\pos` 定死的字就整体错位。
           共用一个 Modifier 变量而不是各写一遍 —— 各写一遍的两处早晚会漂。 */
        LibassLayer(player, fit, videoW, videoH)
    }
    DisposableEffect(player) { onDispose { player.clearVideoSurface() } }
}

/**
 * 选中的那条文本轨是 ASS 就交给 libass,否则关掉它。
 *
 * ★ 判据是「**选中的**那一条」,不是「有没有 ASS 轨」:片子里常常几条轨并存,
 *   用户选了简体 SRT 却弹出繁体 ASS 特效,那比没有特效更糟。
 * ★ 内封没有 ASS 时回落到**外挂** ASS(压制组单独发的那种,特效字幕的大头)。
 */
@OptIn(UnstableApi::class)
private fun syncLibassTrack(tracks: Tracks, subOff: Boolean) {
    if (!Libass.available || subOff) { Libass.deactivate(); return }
    val sel = tracks.groups
        .filter { it.type == C.TRACK_TYPE_TEXT && it.isSelected }
        .flatMap { g -> (0 until g.length).filter { g.isTrackSelected(it) }.map { g.getTrackFormat(it) } }
        .firstOrNull()
    if (sel != null && Libass.isAss(sel)) {
        if (Libass.activateTrack(sel.id ?: "ass", FONTS_DIR)) return
    }
    // 选中的不是 ASS:内封这条路到此为止。外挂那条由 PlayerPage 在起播时装
    if (sel != null && !Libass.isAss(sel)) Libass.deactivate()
}

/**
 * libass 的画布。
 *
 * ☠ **只在 libass 说「这一帧变了」时才重画。** 对白字幕一秒才变几次,
 *   每帧无脑清屏 + 重画是纯烧电;而卡拉OK 那种逐帧变的,它自然每帧都返回 1。
 * ★ 位图交给 native 直接 `AndroidBitmap_lockPixels` 写 —— 不走 JNI 拷贝。
 *   `unlockPixels` 会 bump 位图的 generation id,Skia 的纹理缓存据此失效;
 *   这里另外还读一次 `frame` 状态,双保险(少一层就是「字幕停在第一句不动」)。
 */
@Composable
private fun LibassLayer(player: ExoPlayer, m: Modifier, videoW: Int, videoH: Int) {
    if (!Libass.available) return
    var size by remember { mutableStateOf(IntSize.Zero) }
    var frame by remember { mutableIntStateOf(0) }
    val bmp = remember(size, videoW, videoH) {
        if (size.width <= 0 || size.height <= 0) null
        else Bitmap.createBitmap(size.width, size.height, Bitmap.Config.ARGB_8888).also {
            Libass.setSize(size.width, size.height, videoW, videoH)
        }
    }

    LaunchedEffect(bmp, player) {
        val b = bmp ?: return@LaunchedEffect
        var force = true      // 位图刚建出来,第一帧必须画
        var last = -1L
        while (true) {
            val pos = player.currentPosition
            // seek / 换片之后要强制重画:libass 的 detect_change 只比「上一次渲染」
            if (kotlin.math.abs(pos - last) > 1000) force = true
            last = pos
            if (Libass.render(b, pos, force) > 0) frame++
            force = false
            delay(33)         // 30Hz。卡拉OK 够用,对白字幕靠 detect_change 直接跳过
        }
    }

    Canvas(m.onSizeChanged { size = it }) {
        val b = bmp ?: return@Canvas
        @Suppress("UNUSED_EXPRESSION") frame    // 制造重绘依赖
        drawIntoCanvas { it.nativeCanvas.drawBitmap(b, 0f, 0f, null) }
    }
}

/**
 * ExoPlayer 的字幕层。
 *
 * ☠ **文本轨和图形轨都要画。** media3 把 SRT / VTT / 内封 SSA 解析成带文字的 `Cue`,
 *   把 PGS / DVBSub 解析成带 `bitmap` 的 `Cue` —— 只画其中一种的表现是
 *   「有的片有字幕、有的片没有」,而那看着像片源的问题。
 *
 * ⚠️ **特效字幕(ASS 的 `\pos` `\move` `\fad`、卡拉OK)这一层画不出来。**
 *   media3 的 SSA 解析器只认位置和基本样式,它不是 libass。要完整特效请切 MP 内核
 *   —— 那条走的是 libmpv 里编进去的 libass。把 libass 接进 ExoPlayer 需要另起一个
 *   JNI 渲染层 —— 好消息是**不必再编一份 libass**:实测我们这份 `libmpv.so`
 *   导出了 191 个 `ass_*` 符号(`ass_library_init` / `ass_render_frame` 那一套齐全)。
 *   难的是取原始 ASS 字节(media3 的 SsaParser 已经把特效丢了)。不在本轮范围里。
 */
@OptIn(UnstableApi::class)
@Composable
fun ExoSubtitles(player: ExoPlayer, m: Modifier = Modifier) {
    var cues by remember(player) { mutableStateOf<List<Cue>>(emptyList()) }
    DisposableEffect(player) {
        val l = object : Player.Listener {
            override fun onCues(cueGroup: CueGroup) { cues = cueGroup.cues }
        }
        player.addListener(l)
        onDispose { player.removeListener(l) }
    }
    if (cues.isEmpty()) return

    Box(m.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        Column(
            Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 56.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            cues.forEach { cue ->
                val bmp = cue.bitmap
                if (bmp != null) {
                    // 图形字幕(PGS/DVBSub):按原图比例贴,**不许拉伸**
                    Image(bmp.asImageBitmap(), null, Modifier.fillMaxWidth()
                        .aspectRatio(bmp.width.toFloat() / bmp.height.coerceAtLeast(1)))
                } else cue.text?.toString()?.takeIf { it.isNotBlank() }?.let { t ->
                    Text(
                        t,
                        Modifier.clip(RoundedCornerShape(6.dp))
                            .background(Color.Black.copy(alpha = .55f))
                            .padding(horizontal = 10.dp, vertical = 2.dp),
                        color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.Medium,
                        textAlign = TextAlign.Center, lineHeight = 23.sp,
                    )
                }
            }
        }
    }
}
