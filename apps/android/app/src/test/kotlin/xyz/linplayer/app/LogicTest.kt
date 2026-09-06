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
import xyz.linplayer.app.ui.theme.pickTone
import xyz.linplayer.app.ui.theme.rgbToHsv

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

    /* ───────────────── 封面取色 ───────────────── */

    /**
     * ☠ **色相要按圆周平均,不能按算术平均。**
     *
     * 红色跨 0°/360°:一半像素在 355°、一半在 5°,算术平均得 180° —— 那是**青色**,
     * 正好是红的补色。详情页整页会染成青的,而代码看起来完全正常。
     */
    @Test
    fun `取色_红色跨零度不会平均成青色`() {
        val px = IntArray(200) { if (it % 2 == 0) 0xC81020 else 0xC82010 }
        val hsv = rgbToHsv2(pickTone(px)!!)
        assertTrue("色相应落在红区(±30°),实得 ${hsv[0]}", hsv[0] < 30f || hsv[0] > 330f)
    }

    /** 灰度图取不出色 —— **返回 null 让调用方回落主题色**,不要挑出一个噪点色。 */
    @Test
    fun `取色_灰度图返回null`() {
        assertNull(pickTone(IntArray(200) { 0x3A3A3A }))
        assertNull(pickTone(IntArray(200) { 0x000000 }))
    }

    /**
     * 出来的色必须**能当底色**:太亮压不住白字,太灰等于没取色。
     * 输入是一张刺眼的荧光绿 —— clamp 没生效的话这一条会红。
     */
    @Test
    fun `取色_钳到能当底色的明度和饱和度`() {
        val hsv = rgbToHsv2(pickTone(IntArray(200) { 0x00FF00 })!!)
        assertTrue("饱和度 ${hsv[1]} 该在 .42~.80", hsv[1] in 0.42f..0.80f)
        assertTrue("明度 ${hsv[2]} 该在 .42~.68", hsv[2] in 0.42f..0.68f)
    }

    private fun rgbToHsv2(rgb: Int) =
        rgbToHsv((rgb shr 16) and 0xFF, (rgb shr 8) and 0xFF, rgb and 0xFF)

    private fun item(json: String): Item? = Item.from(Json.parseToJsonElement(json))

    /**
     * ☠☠ **`LpCell` 的 `onClick` 必须是最后一个形参。**
     *
     * 它排在 `onSwitch` 前面的时候,`LpCell("外观", icon = X) { nav.navigate(...) }`
     * 这种写法会把尾随 lambda 绑到 `onSwitch`(Kotlin 绑最后一个形参),
     * 而一个不声明参数的 lambda 完全可以当成 `(Boolean) -> Unit` —— **所以它编译得过**。
     * 后果:`onClick` 恒 null,整张设置列表一条都点不进去,一个警告都没有。
     *
     * 这条只能靠反射钉:它是**签名的形状**,不是运行时行为,任何调用都测不出来。
     * Compose 编译器会在末尾追加 Composer / 两个 int,所以只比较两个 lambda 的先后。
     */
    @Test
    fun `LpCell 的 onClick 必须排在 onSwitch 后面`() {
        val m = Class.forName("xyz.linplayer.app.ui.components.BaseKt")
            .declaredMethods.first { it.name == "LpCell" }
        val types = m.parameterTypes.map { it.name }
        val onSwitch = types.indexOf("kotlin.jvm.functions.Function1")
        val onClick = types.indexOf("kotlin.jvm.functions.Function0")
        assertTrue("签名里该有 onSwitch:(Boolean)->Unit,实得 $types", onSwitch >= 0)
        assertTrue("签名里该有 onClick:()->Unit,实得 $types", onClick >= 0)
        assertTrue(
            "onClick 必须排在 onSwitch 之后,否则尾随 lambda 会静默绑错(实得 " +
                "onSwitch=$onSwitch onClick=$onClick)",
            onClick > onSwitch,
        )
    }
}
