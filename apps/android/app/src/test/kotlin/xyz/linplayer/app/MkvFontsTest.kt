package xyz.linplayer.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import xyz.linplayer.app.ui.player.MkvFonts
import java.io.ByteArrayOutputStream

/**
 * MKV 附件字体的解析。
 *
 * ☠ 这一层错了**不会报错**:字体没抠出来的表现只是「特效字幕字形不对」,
 * 在真机上要盯着一帧一帧看才认得出来。所以拿合成的容器在 JVM 上钉死。
 */
class MkvFontsTest {

    // ---------------------------------------------------------------- 造容器

    /** EBML 的长度:首字节最高位是长度标记,余下的位才是数值。 */
    private fun vint(v: Long): ByteArray {
        for (len in 1..8) {
            val max = (1L shl (7 * len)) - 2      // 全 1 留给「未知长度」
            if (v <= max) {
                val out = ByteArray(len)
                var x = v
                for (i in len - 1 downTo 0) { out[i] = (x and 0xFF).toByte(); x = x shr 8 }
                out[0] = (out[0].toInt() or (0x80 shr (len - 1))).toByte()
                return out
            }
        }
        throw IllegalArgumentException("长度太大")
    }

    private fun idBytes(id: Long): ByteArray {
        val n = when {
            id <= 0xFFL -> 1; id <= 0xFFFFL -> 2; id <= 0xFFFFFFL -> 3; else -> 4
        }
        val out = ByteArray(n)
        var x = id
        for (i in n - 1 downTo 0) { out[i] = (x and 0xFF).toByte(); x = x shr 8 }
        return out
    }

    private fun el(id: Long, body: ByteArray): ByteArray {
        val o = ByteArrayOutputStream()
        o.write(idBytes(id)); o.write(vint(body.size.toLong())); o.write(body)
        return o.toByteArray()
    }

    private fun cat(vararg parts: ByteArray): ByteArray {
        val o = ByteArrayOutputStream()
        parts.forEach { o.write(it) }
        return o.toByteArray()
    }

    private val fontBody = ByteArray(300) { (it % 251).toByte() }

    private fun attachedFile(name: String, mime: String) = el(
        0x61A7,
        cat(
            el(0x466E, name.toByteArray()),
            el(0x4660, mime.toByteArray()),
            el(0x465C, fontBody),
        ),
    )

    /** 一份最小可用的 MKV 头。[afterCluster] = 附件排在簇后面(靠 SeekHead 才找得到)。 */
    private fun mkv(afterCluster: Boolean): ByteArray {
        val attachments = el(
            0x1941A469,
            cat(
                attachedFile("SourceHanSans.otf", "application/vnd.ms-opentype"),
                attachedFile("readme.txt", "text/plain"),          // 不是字体,要滤掉
                attachedFile("Deco.ttf", "application/octet-stream"), // MIME 没说,靠后缀
            ),
        )
        val info = el(0x1549A966, ByteArray(40))
        val cluster = el(0x1F43B675, ByteArray(4096))
        val head = el(0x1A45DFA3, ByteArray(16))

        return if (!afterCluster) {
            val segBody = cat(info, attachments, cluster)
            cat(head, el(0x18538067, segBody))
        } else {
            /* SeekPosition 是**相对 Segment 数据起点**的偏移。
               先按占位算一遍 SeekHead 的长度,再算出附件的真实位置 —— 两遍是必须的,
               因为位置本身会改变 SeekHead 的字节数(vint 是变长的)。 */
            var pos = 0L
            var seekHead: ByteArray
            repeat(3) {
                seekHead = el(
                    0x114D9B74,
                    el(0x4DBB, cat(el(0x53AB, idBytes(0x1941A469)), el(0x53AC, uintBytes(pos)))),
                )
                pos = (seekHead.size + info.size + cluster.size).toLong()
            }
            seekHead = el(
                0x114D9B74,
                el(0x4DBB, cat(el(0x53AB, idBytes(0x1941A469)), el(0x53AC, uintBytes(pos)))),
            )
            val segBody = cat(seekHead, info, cluster, attachments)
            cat(head, el(0x18538067, segBody))
        }
    }

    private fun uintBytes(v: Long): ByteArray {
        if (v == 0L) return byteArrayOf(0)
        var n = 0
        var x = v
        while (x > 0) { n++; x = x shr 8 }
        val out = ByteArray(n)
        x = v
        for (i in n - 1 downTo 0) { out[i] = (x and 0xFF).toByte(); x = x shr 8 }
        return out
    }

    private fun reader(file: ByteArray) = MkvFonts.Ranged { off, len ->
        if (off >= file.size) null
        else file.copyOfRange(off.toInt(), minOf(file.size, off.toInt() + len))
    }

    // ---------------------------------------------------------------- 判据

    @Test
    fun `附件排在簇前面时直接抠得出来`() {
        val fonts = MkvFonts.extract(reader(mkv(afterCluster = false)))
        assertEquals("只要字体,readme.txt 要滤掉", 2, fonts.size)
        assertEquals("SourceHanSans.otf", fonts[0].name)
        assertEquals("Deco.ttf", fonts[1].name)
        assertTrue("字节要原样带回来", fonts[0].data.contentEquals(fontBody))
    }

    @Test
    fun `附件排在簇后面时靠 SeekHead 定点取`() {
        val fonts = MkvFonts.extract(reader(mkv(afterCluster = true)))
        assertEquals(2, fonts.size)
        assertEquals("SourceHanSans.otf", fonts[0].name)
        assertTrue(fonts[0].data.contentEquals(fontBody))
    }

    @Test
    fun `读不到就回空表,不抛`() {
        assertEquals(0, MkvFonts.extract { _, _ -> null }.size)
        assertEquals(0, MkvFonts.extract { _, _ -> ByteArray(64) }.size)
    }

    @Test
    fun `不是 MKV 就回空表`() {
        val mp4 = byteArrayOf(0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70) + ByteArray(64)
        assertEquals(0, MkvFonts.extract(reader(mp4)).size)
    }
}
