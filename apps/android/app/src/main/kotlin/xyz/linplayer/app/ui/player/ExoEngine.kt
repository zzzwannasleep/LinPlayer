package xyz.linplayer.app.ui.player

import android.view.SurfaceView
import androidx.annotation.OptIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import xyz.linplayer.app.BuildConfig

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
fun rememberExoPlayer(enabled: Boolean): ExoPlayer? {
    val ctx = LocalContext.current
    if (!enabled) return null
    val player = remember {
        /* ★ UA 必须是 `LinPlayer/<版本>`(UA 三分口径)。不设的话 ExoPlayer 发的是
           `media3/x.y.z` —— 服务端的设备列表、会话归属、按 UA 做的分流全会对不上,
           而**播放本身照常能播**,所以这类错不会自己冒出来。 */
        val http = DefaultHttpDataSource.Factory()
            .setUserAgent("LinPlayer/" + BuildConfig.VERSION_NAME)
            .setAllowCrossProtocolRedirects(true)   // Emby 直传常常 302 到 CDN
        ExoPlayer.Builder(ctx)
            .setMediaSourceFactory(DefaultMediaSourceFactory(http))
            .build()
    }
    DisposableEffect(player) { onDispose { player.release() } }
    return player
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
 */
@Composable
fun ExoSurface(player: ExoPlayer, m: Modifier = Modifier) {
    AndroidView(
        modifier = m,
        factory = { ctx -> SurfaceView(ctx).also { player.setVideoSurfaceView(it) } },
    )
    DisposableEffect(player) { onDispose { player.clearVideoSurface() } }
}
