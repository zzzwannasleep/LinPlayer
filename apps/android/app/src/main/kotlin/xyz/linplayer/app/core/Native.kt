package xyz.linplayer.app.core

import android.view.Surface

/**
 * 核心层的 C ABI(SPEC §5.1)。**这是 UI 与业务之间唯一的边界。**
 *
 * JNI 桥编在 liblpcore.so 里(core/ffi/jni_android.go),所以这里只 load 一个库。
 * 函数名必须逐字对应 `Java_xyz_linplayer_app_core_Native_*` —— 改包名 / 类名 / 方法名
 * 要同时改那一头,对不上的表现是 `UnsatisfiedLinkError: No implementation found`。
 *
 * ⚠️ `nextEvent` **有且仅有一个消费者线程**(SPEC §5.6)。两个线程同时调不是崩溃 ——
 * 是事件被随机分给两个线程,表现为「有时候收得到有时候收不到」。
 * 所以它被 [CoreClient] 封着,外面拿不到。
 */
internal object Native {
    init {
        // libmpv 先载:liblpcore.so 链着它,交给系统解析也行,
        // 但显式载一次能让「libmpv 没打进 APK」当场炸在这里而不是几秒后炸在起播时
        System.loadLibrary("mpv")
        System.loadLibrary("lpcore")
    }

    external fun abiVersion(): Int
    external fun init(configJson: String): Int
    external fun call(seq: Long, cmd: String, argsJson: String): Int
    external fun cancel(seq: Long)

    /** 超时返回 null。**C 侧已经 lp_free 过了**,Kotlin 不管释放。 */
    external fun nextEvent(timeoutMs: Int): String?

    external fun shutdown()

    /**
     * 视频通道 A(SPEC §7.2)。`surface == null` 就是解绑。
     *
     * ☠ **解绑必须同步阻塞** —— 这个调用返回之前 mpv 还可能在往 Surface 里画。
     * 所以 `surfaceDestroyed` 里要直接调它,不许扔到别的线程去做。
     */
    external fun setSurface(surface: Surface?, width: Int, height: Int): Int
}
