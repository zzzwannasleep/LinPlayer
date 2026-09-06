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

    // ---------------------------------------------------------------- libass
    //
    // ☠ 这一组**只服务 ExoPlayer 内核**。mpv 那条路的字幕是 libmpv 自己
    //   用同一个 libass 画进画面里的,走这里等于画两遍。
    // ★ 实现全在 core/ffi/libass_android.go 的 cgo 前导里,符号借的是
    //   **libmpv.so 已经导出的那 191 个 `ass_*`** —— 没有第二份 libass。

    /** 这个构建的 libass API 版本。0 或负数 = 不可用。 */
    external fun assVersion(): Int

    /** 内封轨:header 是 MKV 的 CodecPrivate(`Format.initializationData[0]`)。 */
    external fun assOpen(header: ByteArray?, fontsDir: String): Int

    /** 外挂轨:整份 .ass / .ssa 文件的字节。 */
    external fun assOpenFile(file: ByteArray, fontsDir: String): Int

    /**
     * 一条事件。
     * ☠ body 必须是 **Matroska 口径**(`ReadOrder,Layer,Style,…,Text`),
     * 不带 `Dialogue:`、不带时间 —— 时间走后两个参数(毫秒)。
     */
    external fun assChunk(body: ByteArray, startMs: Long, durMs: Long)

    /** frame = 位图尺寸;video = 片源分辨率(不给的话特效字幕的定位会整体错位)。 */
    external fun assSetSize(frameW: Int, frameH: Int, videoW: Int, videoH: Int)

    /** 返回 -1 出错 / 0 和上一帧一样(不必重绘)/ 1 位图已更新。 */
    external fun assRender(bitmap: android.graphics.Bitmap, posMs: Long, force: Boolean): Int

    external fun assClose()

    /**
     * 灌一份内嵌字体(MKV 附件里抠出来的)。
     *
     * ★ 特效字幕十有八九指名一个压制组自己塞进容器里的字体。
     *   不给的话 libass 回落到系统字体:特效和位置都对,**字形不对**。
     */
    external fun assAddFont(name: String, data: ByteArray): Int
}
