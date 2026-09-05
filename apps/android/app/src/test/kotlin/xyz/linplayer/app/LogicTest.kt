package xyz.linplayer.app

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import xyz.linplayer.app.data.Capabilities
import xyz.linplayer.app.data.Item
import xyz.linplayer.app.data.Page
import xyz.linplayer.app.data.Session
import xyz.linplayer.app.ui.pages.Version
import xyz.linplayer.app.ui.pages.defaultVersion
import xyz.linplayer.app.ui.pages.fmtTime
import xyz.linplayer.app.ui.pages.withScheme

/**
 * UI 层的纯逻辑。**跑在 JVM 上,不需要设备。**
 *
 * 只测那几条「错了不会报错、只会静默给出一个错事实」的:
 * 版本回落、地址补全、剧集标题、能力集判定。别的交给真渲染自检。
 */
class LogicTest {

    /**
     * ☠ **不许自己回落 `versions[0]`。**
     *
     * 核心层没标 `preferred` 就是「让核心层自己决定」,UI 传 null 而不是替它选一个。
     * 旧实现回落第一版 → 版本筛选正则**从上线起一次都没生效过,还一声不吭**。
     */
    @Test fun `没有 preferred 时不许回落第一版`() {
        val vs = listOf(
            Version("a", "1080p", preferred = false),
            Version("b", "4K", preferred = false),
        )
        assertNull("没有 preferred 就该是 null,不是 versions[0]", defaultVersion(vs))
    }

    @Test fun `有 preferred 时选它而不是第一个`() {
        val vs = listOf(
            Version("a", "1080p", preferred = false),
            Version("b", "4K", preferred = true),
        )
        assertEquals("b", defaultVersion(vs)?.id)
    }

    /**
     * 地址补全。**默认补 http 不是 https** —— 补错协议只会连不上,
     * 而补 https 到一台只有 http 的服务器上,报的是看不懂的 TLS 错。
     */
    @Test fun `地址没写协议时补 http`() {
        assertEquals("http://example.test:8096", withScheme("example.test:8096"))
        assertEquals("https://a.test", withScheme("https://a.test"))
        assertEquals("http://a.test", withScheme("  http://a.test  "))
        assertEquals("", withScheme("   "))
    }

    /** 剧集**恒带剧名** —— Emby 的 Episode.Name 只是「第 35 集」,单看无意义。 */
    @Test fun `剧集卡片标题用剧名副标题用季集`() {
        val ep = item("""{"id":"e1","name":"第 35 集","type_":"Episode",
            "series_name":"某部剧","season_no":2,"episode_no":35}""")!!
        assertEquals("某部剧", ep.cardTitle)
        assertEquals("S2E35", ep.cardSub)
    }

    @Test fun `电影卡片副标题是年份`() {
        val m = item("""{"id":"m1","name":"某部电影","type_":"Movie","year":2019}""")!!
        assertEquals("某部电影", m.cardTitle)
        assertEquals("2019", m.cardSub)
    }

    /** 核心层加字段**不该把界面打红** —— 未知键必须被忽略。 */
    @Test fun `多出来的字段不影响解析`() {
        val it = item("""{"id":"x","name":"n","type_":"Movie","将来才有的字段":123}""")
        assertEquals("n", it?.name)
    }

    /** 少字段也只是那一项没有,不是整条丢掉。 */
    @Test fun `缺字段时给默认值而不是丢掉整条`() {
        val it = item("""{"id":"x"}""")!!
        assertEquals("", it.name)
        assertEquals(0.0, it.runtimeSecs, 0.0)
    }

    @Test fun `没有 id 的条目直接丢掉`() {
        assertNull(item("""{"name":"没有 id"}"""))
    }

    /** 进度条只在有进度时出现,而且不许超过 1。 */
    @Test fun `观看进度按比例且封顶`() {
        assertEquals(0f, item("""{"id":"a","runtime_secs":100}""")!!.progress, 1e-6f)
        assertEquals(0.5f, item("""{"id":"a","runtime_secs":100,"resume_secs":50}""")!!.progress, 1e-6f)
        assertEquals(1f, item("""{"id":"a","runtime_secs":100,"resume_secs":999}""")!!.progress, 1e-6f)
    }

    /** `unsupported` 里的命令,入口在启动时就不画(UI_MOBILE §6.3)。 */
    @Test fun `能力集判定`() {
        val c = Capabilities.from(Json.parseToJsonElement(
            """{"platform":"android","version":"1.0","unsupported":["system.pickFile"],
               "features":{"pip":true,"filePicker":false}}"""))
        assertTrue(c.supports("emby.views"))
        assertTrue(!c.supports("system.pickFile"))
        assertTrue(c.feature("pip"))
        assertTrue(!c.feature("filePicker"))
    }

    /**
     * ☠ 会话字段名**就是线上字段名**(小写下划线)。
     * 写成驼峰发出去核心层当作没传,报「缺少 server 或 user_id」——
     * 两边都不报编译错,只在运行时现形。
     */
    @Test fun `会话按线上字段名解析`() {
        val s = Session.from(Json.parseToJsonElement(
            """{"server":"http://a.test","token":"t","user_id":"u","user_name":"n"}"""))!!
        assertEquals("http://a.test", s.server)
        assertEquals("t", s.token)
        assertEquals("u", s.userId)
    }

    @Test fun `分页既吃裸数组也吃带 total 的对象`() {
        val bare = Page.from(Json.parseToJsonElement("""[{"id":"a"},{"id":"b"}]"""))
        assertEquals(2, bare.items.size)
        assertNull(bare.total)
        val paged = Page.from(Json.parseToJsonElement("""{"items":[{"id":"a"}],"total":42}"""))
        assertEquals(42L, paged.total)
    }

    @Test fun `时间格式一小时以上才带小时位`() {
        assertEquals("12:34", fmtTime(754.0))
        assertEquals("1:00:05", fmtTime(3605.0))
    }

    private fun item(json: String): Item? = Item.from(Json.parseToJsonElement(json))
}
