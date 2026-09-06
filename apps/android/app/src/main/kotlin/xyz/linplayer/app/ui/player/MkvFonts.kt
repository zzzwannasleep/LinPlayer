package xyz.linplayer.app.ui.player

import java.net.HttpURLConnection
import java.net.URL

/**
 * 从 MKV 容器里抠出内嵌字体(Exo 内核专用)。
 *
 * ## 为什么必须自己抠
 *
 * 特效字幕十有八九指名一个压制组塞进容器里的字体。ExoPlayer 的
 * `MatroskaExtractor` **完全不解析 Attachments** —— 它只认 Tracks 和 Clusters
 * (反编译核对过:那个 class 的常量池里没有 Attachments 这个 ID)。
 * 拿不到字体的表现不是报错,是「特效和位置都对、字形不对」。
 * mpv 那条路没有这个问题:libavformat 会把附件透给 libass。
 *
 * ## 只读需要的那几段
 *
 * 一部片几个 GB,不能整份拉下来。做法是 HTTP Range:
 * 先读头部 256 KB 找 Attachments,找不到就去 SeekHead 查它的位置再定点取。
 * **服务端不回 206 就整个放弃** —— 回 200 意味着它在给整部片,那比没有字体糟得多。
 */
object MkvFonts {

    class Font(val name: String, val data: ByteArray)

    /** 读文件的 [len] 个字节(从 [offset] 起)。读不到回 null。抽成接口是为了能在 JVM 上测。 */
    fun interface Ranged {
        fun read(offset: Long, len: Int): ByteArray?
    }

    private const val ID_SEGMENT = 0x18538067L
    private const val ID_SEEKHEAD = 0x114D9B74L
    private const val ID_SEEK = 0x4DBBL
    private const val ID_SEEK_ID = 0x53ABL
    private const val ID_SEEK_POS = 0x53ACL
    private const val ID_ATTACHMENTS = 0x1941A469L
    private const val ID_ATTACHED_FILE = 0x61A7L
    private const val ID_FILE_NAME = 0x466EL
    private const val ID_FILE_MIME = 0x4660L
    private const val ID_FILE_DATA = 0x465CL
    private const val ID_CLUSTER = 0x1F43B675L

    private const val HEAD_BYTES = 256 * 1024
    private const val MAX_ATTACH_BYTES = 64 shl 20
    private const val MAX_TOTAL = 32 shl 20
    private const val MAX_FONTS = 100

    /** 抠字体。任何一步读不到就返回已经拿到的那些 —— 少几个字体好过整条路失败。 */
    fun extract(read: Ranged): List<Font> {
        val head = read.read(0, HEAD_BYTES) ?: return emptyList()
        val seg = findSegment(head) ?: return emptyList()

        var seekPos = -1L
        var p = seg
        while (p < head.size) {
            val id = readId(head, p) ?: break
            val sz = readSize(head, id.next) ?: break
            val bodyAt = sz.next
            /* Cluster 一到就停:附件正常都排在它前面。再往下走等于在头部缓冲里
               逐个跳过几百 MB 的簇,而那些字节我们根本没读到。 */
            if (id.value == ID_CLUSTER) break
            if (id.value == ID_ATTACHMENTS) {
                val end = bodyAt + sz.value
                if (sz.value in 1..MAX_ATTACH_BYTES && end <= head.size) {
                    return parseAttachments(head, bodyAt, end.toInt())
                }
                return fetchAndParse(read, bodyAt.toLong(), sz.value.toInt())
            }
            if (id.value == ID_SEEKHEAD && sz.value > 0 && bodyAt + sz.value <= head.size) {
                seekPos = findSeekTarget(head, bodyAt, (bodyAt + sz.value).toInt())
            }
            if (sz.value <= 0) break        // 未知长度:再往下走就是瞎猜
            p = (bodyAt + sz.value).toInt()
            if (p <= bodyAt) break
        }

        // SeekHead 说了 Attachments 在哪(位置相对 Segment 的**数据起点**)
        if (seekPos < 0) return emptyList()
        val at = seg.toLong() + seekPos
        val hdr = read.read(at, 32) ?: return emptyList()
        val id = readId(hdr, 0) ?: return emptyList()
        if (id.value != ID_ATTACHMENTS) return emptyList()
        val sz = readSize(hdr, id.next) ?: return emptyList()
        return fetchAndParse(read, at + sz.next, sz.value.toInt())
    }

    private fun fetchAndParse(read: Ranged, at: Long, size: Int): List<Font> {
        if (size !in 1..MAX_ATTACH_BYTES) return emptyList()
        val b = read.read(at, size) ?: return emptyList()
        return parseAttachments(b, 0, b.size)
    }

    // ---------------------------------------------------------------- EBML

    internal class Field(val value: Long, val next: Int)

    /** ID 连**首字节的长度标记一起**保留 —— 规范里的元素 ID 就是那个完整值。 */
    internal fun readId(b: ByteArray, at: Int): Field? {
        if (at < 0 || at >= b.size) return null
        val first = b[at].toInt() and 0xFF
        if (first == 0) return null
        var len = 1
        while (len <= 4 && (first and (0x80 shr (len - 1))) == 0) len++
        if (len > 4 || at + len > b.size) return null
        var v = 0L
        for (i in 0 until len) v = (v shl 8) or (b[at + i].toLong() and 0xFF)
        return Field(v, at + len)
    }

    /**
     * 长度。
     *
     * ☠ **首字节的长度标记那一位要抹掉,而 ID 不抹** —— 两者规则不同。
     * 混用的表现是每个元素的长度都大出一大截,解析当场跑飞而且不报错。
     * 全 1 = 未知长度,这里回 0 让调用方自己决定怎么办。
     */
    internal fun readSize(b: ByteArray, at: Int): Field? {
        if (at < 0 || at >= b.size) return null
        val first = b[at].toInt() and 0xFF
        if (first == 0) return null
        var len = 1
        while (len <= 8 && (first and (0x80 shr (len - 1))) == 0) len++
        if (len > 8 || at + len > b.size) return null
        val mask = 0xFF shr len
        var v = (first and mask).toLong()
        var allOnes = (first and mask) == mask
        for (i in 1 until len) {
            val x = b[at + i].toInt() and 0xFF
            if (x != 0xFF) allOnes = false
            v = (v shl 8) or x.toLong()
        }
        if (allOnes || v > Int.MAX_VALUE) return Field(0, at + len)
        return Field(v, at + len)
    }

    /** Segment 的**数据起点**在文件里的偏移。 */
    private fun findSegment(b: ByteArray): Int? {
        var p = 0
        while (p < b.size) {
            val id = readId(b, p) ?: return null
            val sz = readSize(b, id.next) ?: return null
            if (id.value == ID_SEGMENT) return sz.next
            if (sz.value <= 0) return null
            p = (sz.next + sz.value).toInt()
            if (p <= id.next) return null
        }
        return null
    }

    private fun findSeekTarget(b: ByteArray, from: Int, to: Int): Long {
        var p = from
        while (p < to) {
            val id = readId(b, p) ?: return -1
            val sz = readSize(b, id.next) ?: return -1
            val end = (sz.next + sz.value).toInt()
            if (sz.value <= 0 || end > to) return -1
            if (id.value == ID_SEEK) {
                var q = sz.next
                var wanted = false
                var pos = -1L
                while (q < end) {
                    val i2 = readId(b, q) ?: break
                    val s2 = readSize(b, i2.next) ?: break
                    val e2 = (s2.next + s2.value).toInt()
                    if (s2.value <= 0 || e2 > end) break
                    if (i2.value == ID_SEEK_ID && uint(b, s2.next, e2) == ID_ATTACHMENTS) wanted = true
                    if (i2.value == ID_SEEK_POS) pos = uint(b, s2.next, e2)
                    q = e2
                }
                if (wanted && pos >= 0) return pos
            }
            p = end
        }
        return -1
    }

    private fun uint(b: ByteArray, from: Int, to: Int): Long {
        var v = 0L
        for (i in from until minOf(to, b.size)) v = (v shl 8) or (b[i].toLong() and 0xFF)
        return v
    }

    // ---------------------------------------------------------------- 附件

    internal fun parseAttachments(b: ByteArray, from: Int, to: Int): List<Font> {
        val out = ArrayList<Font>()
        var total = 0
        var p = from
        while (p < to && out.size < MAX_FONTS) {
            val id = readId(b, p) ?: break
            val sz = readSize(b, id.next) ?: break
            val end = (sz.next + sz.value).toInt()
            if (sz.value <= 0 || end > to) break
            if (id.value == ID_ATTACHED_FILE) {
                var name: String? = null
                var mime = ""
                var dataAt = -1
                var dataLen = 0
                var q = sz.next
                while (q < end) {
                    val i2 = readId(b, q) ?: break
                    val s2 = readSize(b, i2.next) ?: break
                    val e2 = (s2.next + s2.value).toInt()
                    if (s2.value <= 0 || e2 > end) break
                    when (i2.value) {
                        ID_FILE_NAME -> name = String(b, s2.next, s2.value.toInt(), Charsets.UTF_8)
                        ID_FILE_MIME -> mime = String(b, s2.next, s2.value.toInt(), Charsets.UTF_8)
                        ID_FILE_DATA -> { dataAt = s2.next; dataLen = s2.value.toInt() }
                    }
                    q = e2
                }
                if (dataAt >= 0 && dataLen > 0 && isFont(name, mime) && total + dataLen <= MAX_TOTAL) {
                    out.add(Font(name ?: "embedded", b.copyOfRange(dataAt, dataAt + dataLen)))
                    total += dataLen
                }
            }
            p = end
        }
        return out
    }

    /**
     * 是不是字体。
     *
     * ☠ **不能只信 MIME。** 实测封装工具写进去的五花八门:
     * `application/x-truetype-font`、`application/vnd.ms-opentype`、
     * `application/octet-stream`,甚至空串。所以后缀也算一条判据。
     * 判宽了的代价只是白灌一份 libass 认不出来的数据(它自己会忽略),
     * 判窄了的代价是字幕字形不对 —— 两边不对称。
     */
    internal fun isFont(name: String?, mime: String): Boolean {
        val m = mime.lowercase()
        if (m.contains("font") || m.contains("opentype") || m.contains("truetype")) return true
        val n = (name ?: "").lowercase()
        return n.endsWith(".ttf") || n.endsWith(".otf") || n.endsWith(".ttc") ||
            n.endsWith(".pfb") || n.endsWith(".woff") || n.endsWith(".woff2")
    }

    // ---------------------------------------------------------------- HTTP

    /**
     * 走 HTTP Range 读。
     *
     * ☠ **只认 206。** 回 200 = 服务端无视了 Range,正在给整部片;
     * 那时候继续读下去是几个 GB 的流量换零个字体。
     */
    fun ranged(url: String, ua: String): Ranged = Ranged { off, len ->
        runCatching {
            val c = URL(url).openConnection() as HttpURLConnection
            c.connectTimeout = 8000
            c.readTimeout = 20000
            c.setRequestProperty("User-Agent", ua)
            c.setRequestProperty("Range", "bytes=" + off + "-" + (off + len - 1))
            if (c.responseCode != HttpURLConnection.HTTP_PARTIAL) null
            else c.inputStream.use { st -> st.readBytes() }
        }.getOrNull()
    }
}
