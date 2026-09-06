package xyz.linplayer.app.ui.player

import android.graphics.Bitmap
import androidx.annotation.OptIn
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.Consumer
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.text.CuesWithTiming
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.text.SubtitleParser
import xyz.linplayer.app.core.Native

/**
 * ExoPlayer 内核的**特效字幕**(U1.6b)。
 *
 * ## 为什么必须自己接 libass
 *
 * media3 的 `SsaParser` 把 ASS 折成 `Cue`:`\pos` `\move` `\fad`、卡拉OK、
 * 逐字变色、矢量绘图全部在那一步丢掉。压制组发的字幕十有八九靠这些 ——
 * 丢了之后画面上是「有字幕」,但不是那份字幕。
 *
 * ## 借的是哪份 libass
 *
 * **libmpv.so 自己导出的那份**(实测 191 个 `ass_*` 符号)。不另编第二份:
 * 那等于把包里已有的东西再编一遍,还多一份要跟着升级的依赖。
 * 桥在 `core/ffi/libass_android.go`。
 *
 * ## 事件从哪来
 *
 * media3 1.11 的字幕解析发生在**解封装阶段**(`TextRenderer` 已经没有
 * `SubtitleParser.Factory` 这个构造参数了,只剩消费解析好的样本),
 * 所以唯一的入口是 `DefaultMediaSourceFactory.setSubtitleParserFactory`。
 * 那一层会把**所有**文本轨都解一遍,不只是选中的那条 —— 所以这里按
 * `Format.id` 分桶存,切轨时重放,而不是一股脑喂给 libass。
 */
@OptIn(UnstableApi::class)
object Libass {

    /** 一条事件:Matroska 口径的正文 + 起止(毫秒)。 */
    private class Ev(val body: ByteArray, val startMs: Long, val durMs: Long)

    private class Buf(var header: ByteArray?) {
        val events = ArrayList<Ev>()
        var bytes = 0
    }

    /* ☠ 单条轨最多留 8MB / 4 万条。正常一集 ASS 是几十到两百 KB ——
       这道闸挡的是「某个文件把一整部剧的事件塞进一条轨」那种病态输入,
       不设的话表现是切一次轨就 OOM。到闸之后**只停止留存,不停止直通**:
       当前正在放的那条照样是全的。 */
    private const val MAX_BYTES = 8 shl 20
    private const val MAX_EVENTS = 40_000

    private val lock = Any()
    private val bufs = LinkedHashMap<String, Buf>()
    private var active: String? = null
    private var opened = false

    /** 这个构建的 libass 能不能用。取不到就整条路不走 —— 不是崩,是回落成普通字幕。 */
    val available: Boolean by lazy {
        runCatching { Native.assVersion() }.getOrDefault(0) > 0
    }

    fun isAss(f: Format?): Boolean =
        f?.sampleMimeType == MimeTypes.TEXT_SSA

    // ------------------------------------------------------------ 喂数据

    fun header(id: String, header: ByteArray?) = synchronized(lock) {
        bufs.getOrPut(id) { Buf(header) }.header = header ?: bufs[id]?.header
    }

    fun chunk(id: String, body: ByteArray, startMs: Long, durMs: Long) = synchronized(lock) {
        val b = bufs.getOrPut(id) { Buf(null) }
        if (b.bytes < MAX_BYTES && b.events.size < MAX_EVENTS) {
            b.events.add(Ev(body, startMs, durMs))
            b.bytes += body.size
        }
        // 正在放的这条直通。libass 自己按 ReadOrder 去重,seek 之后重复喂不会画两遍
        if (id == active && opened) Native.assChunk(body, startMs, durMs)
    }

    // ------------------------------------------------------------ 切轨

    /**
     * 切到某条内封 ASS 轨。**重放它的全部事件** ——
     * 解封装阶段早就把每条轨都解过一遍了,不重放的话切过去是一片空白,
     * 而且不会有任何东西再来触发它。
     */
    fun activateTrack(id: String, fontsDir: String): Boolean = synchronized(lock) {
        if (!available) return false
        if (active == id && opened) return true
        val b = bufs[id] ?: return false
        if (Native.assOpen(b.header, fontsDir) != 0) {
            opened = false; active = null
            return false
        }
        for (e in b.events) Native.assChunk(e.body, e.startMs, e.durMs)
        active = id
        opened = true
        return true
    }

    /** 切到一份外挂 .ass / .ssa(整份文件)。 */
    fun activateFile(key: String, bytes: ByteArray, fontsDir: String): Boolean = synchronized(lock) {
        if (!available) return false
        if (active == key && opened) return true
        if (Native.assOpenFile(bytes, fontsDir) != 0) {
            opened = false; active = null
            return false
        }
        active = key
        opened = true
        return true
    }

    fun deactivate() = synchronized(lock) {
        if (opened) Native.assClose()
        opened = false
        active = null
    }

    /** 换一部片:连缓存一起清。留着就是把上一集的字幕喂给下一集。 */
    fun reset() = synchronized(lock) {
        if (opened) Native.assClose()
        opened = false
        active = null
        bufs.clear()
    }

    val isActive: Boolean get() = synchronized(lock) { opened }

    // ------------------------------------------------------------ 渲染

    fun setSize(frameW: Int, frameH: Int, videoW: Int, videoH: Int) = synchronized(lock) {
        if (opened) Native.assSetSize(frameW, frameH, videoW, videoH)
    }

    /** -1 出错 / 0 和上一帧一样 / 1 位图已更新。 */
    fun render(bmp: Bitmap, posMs: Long, force: Boolean): Int = synchronized(lock) {
        if (!opened) -1 else Native.assRender(bmp, posMs, force)
    }
}

/**
 * 拦下 ASS/SSA 的原始事件交给 libass,**自己一条 cue 都不输出**。
 *
 * ☠ 不输出是有意的:输出了的话 media3 会把它当普通字幕再画一遍,
 * 屏幕上就是两层字。别的格式(SRT / VTT / PGS)原样交给 media3 自己那套。
 */
@OptIn(UnstableApi::class)
class LibassParserFactory(private val fontsDir: String) : SubtitleParser.Factory {
    private val fallback = DefaultSubtitleParserFactory()

    // 支持面不扩大:我们只是把其中 ASS 那一类换个人画
    override fun supportsFormat(format: Format) = fallback.supportsFormat(format)

    override fun getCueReplacementBehavior(format: Format) =
        fallback.getCueReplacementBehavior(format)

    override fun create(format: Format): SubtitleParser =
        if (Libass.available && Libass.isAss(format))
            LibassParser(format.id ?: "ass", format)
        else fallback.create(format)
}

/**
 * ☠☠ **media3 给的不是标准 ASS 行。**
 *
 * `MatroskaExtractor` 把每个 SSA 样本重写成
 * `Dialogue: <Start>,<End>,` + 原始 Matroska 事件体,并配一条自定义的
 * `Format: Start, End, ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text`
 * (常量原文来自 `MatroskaExtractor.SSA_PREFIX` / `SSA_DIALOGUE_FORMAT`,反编译核对过)。
 * 字段顺序和标准 ASS 的 `Layer,Start,End,Style,…` **不是一回事** ——
 * 直接丢给 `ass_process_data` 会把 Layer 当成 Style,样式全错而且不报错。
 *
 * 而切掉前两个字段之后剩下的正好是
 * `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text` ——
 * **就是 `ass_process_chunk` 要的那个口径**(libass 自己读掉 ReadOrder 和 Layer,
 * 再按 n_ignored=3 跳过 Format 里的 Layer/Start/End)。所以这里只做两件事:
 * 解出时间、把正文原样递过去。
 */
@OptIn(UnstableApi::class)
private class LibassParser(private val id: String, format: Format) : SubtitleParser {

    init {
        // initializationData[0] 是 MKV 的 CodecPrivate,也就是真正的 ASS 头
        Libass.header(id, format.initializationData.firstOrNull())
    }

    override fun parse(
        data: ByteArray, offset: Int, length: Int,
        outputOptions: SubtitleParser.OutputOptions,
        output: Consumer<CuesWithTiming>,
    ) {
        val ev = splitMedia3Dialogue(String(data, offset, length, Charsets.UTF_8)) ?: return
        Libass.chunk(id, ev.body.toByteArray(Charsets.UTF_8), ev.startMs, ev.durMs)
        // 故意什么都不 output:这一条已经交给 libass 了
    }

    override fun getCueReplacementBehavior() = Format.CUE_REPLACEMENT_BEHAVIOR_MERGE

    override fun reset() { /* 事件按 ReadOrder 去重,seek 不必清空 —— 清了反而要重放 */ }
}

/** 一条切好的事件。`body` 已经是 `ass_process_chunk` 要的 Matroska 口径。 */
data class AssEvent(val startMs: Long, val durMs: Long, val body: String)

/**
 * 把 media3 重写过的那行 `Dialogue:` 拆成 libass 要的三样东西。
 *
 * 抽成顶层函数不是为了好看,是**为了能在 JVM 上测** ——
 * 这一步错了不会报错,只会「字幕出来了但样式全丢」或者「时间全偏」,
 * 而那两种在真机上都得靠肉眼才看得出来。
 *
 * 拆不出来返回 null:宁可这一条不画,也不画一条错的。
 */
internal fun splitMedia3Dialogue(line: String): AssEvent? {
    val body = line.removePrefix("Dialogue: ")
    if (body.length == line.length) return null
    val c1 = body.indexOf(',')
    if (c1 < 0) return null
    val c2 = body.indexOf(',', c1 + 1)
    if (c2 < 0) return null
    val start = assTimeMs(body.substring(0, c1))
    val end = assTimeMs(body.substring(c1 + 1, c2))
    if (start < 0 || end < 0) return null
    return AssEvent(start, (end - start).coerceAtLeast(0), body.substring(c2 + 1))
}

/**
 * `H:MM:SS:CC`(百分秒)。
 *
 * ☠ 这是 **media3 写进去的**格式(`MatroskaExtractor.SSA_TIMECODE_FORMAT`
 * = `%01d:%02d:%02d:%02d`),不是 ASS 自己那个 `H:MM:SS.CC` ——
 * 最后一段的分隔符是**冒号不是点**。按点去切的话四段变三段,整条丢掉。
 */
internal fun assTimeMs(s: String): Long {
    val p = s.trim().split(':')
    if (p.size != 4) return -1
    return try {
        p[0].toLong() * 3_600_000 + p[1].toLong() * 60_000 +
            p[2].toLong() * 1_000 + p[3].toLong() * 10
    } catch (_: NumberFormatException) {
        -1   // 解不出来就当这一条不存在:画错时间的字幕比没有更烦
    }
}
