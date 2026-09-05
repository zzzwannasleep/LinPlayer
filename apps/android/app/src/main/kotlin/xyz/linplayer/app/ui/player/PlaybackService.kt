package xyz.linplayer.app.ui.player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import xyz.linplayer.app.MainActivity
import xyz.linplayer.app.core.CoreClient
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.dbl
import xyz.linplayer.app.data.str

/**
 * 前台服务 + MediaSession + 音频焦点(U1.21 / U1.22 / U1.23)。
 *
 * ★ **播放器不在 Java 侧** —— 解码渲染全在核心层的 libmpv 里。所以:
 *   · 不用 `media3-exoplayer`,也不实现 `androidx.media3.common.Player`;
 *   · 用平台的 `MediaSessionCompat` + `MediaStyle` 通知,控制指令一律转成
 *     `player.*` 命令发给核心层。
 *   接一个 `SimpleBasePlayer` 适配器只是为了让 media3 的通知帮我们画一遍,
 *   代价是要把 mpv 的状态映射成 Player 的 20 多个方法 —— 那是一层纯翻译的债。
 *
 * ★ Android 14 起 `foregroundServiceType` 必填(清单里写了 `mediaPlayback`),
 *   且 `startForeground` 必须在 5 秒内调,否则 ANR。所以它在 `onStartCommand` 的第一行。
 */
class PlaybackService : Service() {

    private lateinit var session: MediaSessionCompat
    private var focusRequest: AudioFocusRequest? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val core get() = CoreClient.get()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()

        session = MediaSessionCompat(this, "LinPlayer").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() = send("player.setPause", "paused" to false)
                override fun onPause() = send("player.setPause", "paused" to true)
                override fun onSeekTo(pos: Long) = send("player.seek", "position_secs" to pos / 1000.0)
                override fun onStop() = send("player.stopPlayback")
            })
            isActive = true
        }

        // 播放状态跟着核心层的 player.status 走,不自己数
        scope.launch {
            core.events.collect { ev ->
                if (ev.name != "player.status") return@collect
                val o = ev.data as? JsonObject
                val paused = o.bool("paused")
                val pos = ((o.dbl("position") ?: 0.0) * 1000).toLong()
                session.setPlaybackState(
                    PlaybackStateCompat.Builder()
                        .setActions(
                            PlaybackStateCompat.ACTION_PLAY or PlaybackStateCompat.ACTION_PAUSE or
                                PlaybackStateCompat.ACTION_SEEK_TO or PlaybackStateCompat.ACTION_STOP
                        )
                        .setState(
                            if (paused) PlaybackStateCompat.STATE_PAUSED else PlaybackStateCompat.STATE_PLAYING,
                            pos, if (paused) 0f else 1f,
                        ).build()
                )
                notify(o.str("title") ?: "LinPlayer", paused)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // ★ 5 秒内必须调,否则 ANR。放在第一行,别排在任何 IO 后面
        startForeground(NOTI_ID, buildNotification("LinPlayer", false))
        requestFocus()
        acquireWake()
        return START_STICKY
    }

    override fun onDestroy() {
        releaseWake()
        abandonFocus()
        session.isActive = false
        session.release()
        scope.cancel()
        super.onDestroy()
    }

    /**
     * 音频焦点(U1.23)。
     *
     * ★ **duck 走降 mpv 音量而不是暂停** —— 导航提示音只有两三秒,
     *   为它暂停再恢复会打断观看节奏;而永久丢失(别的 App 开始播)才暂停。
     */
    private fun requestFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS -> send("player.setPause", "paused" to true)
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> send("player.setPause", "paused" to true)
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> send("player.setVolume", "volume" to 30)
                AudioManager.AUDIOFOCUS_GAIN -> send("player.setVolume", "volume" to 100)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build()
                )
                .setOnAudioFocusChangeListener(listener)
                .build()
            focusRequest = req
            am.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
    }

    private fun abandonFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
        }
    }

    /** 后台播放期间保住 CPU。**屏幕常亮是 Activity 的事**(FLAG_KEEP_SCREEN_ON),不在这。 */
    private fun acquireWake() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "LinPlayer::playback").apply {
            setReferenceCounted(false)
            acquire(4 * 60 * 60 * 1000L)
        }
    }

    private fun releaseWake() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }

    private fun send(cmd: String, vararg pairs: Pair<String, Any>) {
        scope.launch {
            runCatching {
                core.callJson(cmd, JsonObject(pairs.associate { (k, v) ->
                    k to when (v) {
                        is Number -> kotlinx.serialization.json.JsonPrimitive(v)
                        is Boolean -> kotlinx.serialization.json.JsonPrimitive(v)
                        else -> kotlinx.serialization.json.JsonPrimitive(v.toString())
                    }
                }))
            }
        }
    }

    private fun notify(title: String, paused: Boolean) =
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTI_ID, buildNotification(title, paused))

    private fun buildNotification(title: String, paused: Boolean): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setContentTitle(title)
            .setContentText(if (paused) "已暂停" else "正在播放")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(open)
            .setOngoing(!paused)
            .setStyle(androidx.media.app.NotificationCompat.MediaStyle()
                .setMediaSession(session.sessionToken))
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val ch = NotificationChannel(CHANNEL, "播放控制", NotificationManager.IMPORTANCE_LOW)
        ch.setShowBadge(false)
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(ch)
    }

    companion object {
        private const val CHANNEL = "playback"
        private const val NOTI_ID = 1001

        fun start(ctx: Context) = ctx.startForegroundService(Intent(ctx, PlaybackService::class.java))
        fun stop(ctx: Context) = ctx.stopService(Intent(ctx, PlaybackService::class.java))
    }
}
