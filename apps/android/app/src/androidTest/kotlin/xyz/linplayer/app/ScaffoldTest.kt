package xyz.linplayer.app

import androidx.compose.foundation.layout.Box
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import xyz.linplayer.app.data.Block
import xyz.linplayer.app.ui.components.BlockBox
import xyz.linplayer.app.ui.components.LpIconButton
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.LpTheme

/**
 * Compose UI Test(U1.20)。**只测那几条真栽过的**,不做一页一条的普查
 * —— 普查会变成一堆改一次布局就红一片的噪音,而长期红的门禁等于没有门禁。
 */
@RunWith(AndroidJUnit4::class)
class ScaffoldTest {

    @get:Rule val rule = createComposeRule()

    /**
     * ☠ 真栽过:`LpScaffold` 用 `title != null` 判要不要画整条 topbar,
     * 于是**首页的搜索与设置两个入口一个都没画出来** —— 不报错,只是点不到。
     * 首页正是「没有标题但右上角有入口」的那一页。
     */
    @Test fun 没有标题也要画右上角的入口() {
        rule.setContent {
            LpTheme(darkOverride = true) {
                LpScaffold(actions = {
                    LpIconButton(LpIcons.search, "搜索") {}
                    LpIconButton(LpIcons.settings, "设置") {}
                }) { Box(androidx.compose.ui.Modifier) }
            }
        }
        rule.onNodeWithContentDescription("搜索").assertIsDisplayed()
        rule.onNodeWithContentDescription("设置").assertIsDisplayed()
    }

    /**
     * ☠ `E_UNSUPPORTED` **静默降级,一个字都不显示**(UI_MOBILE §6.3)。
     * 混在一起的表现是「进某个源就弹一个红色报错」。
     */
    @Test fun E_UNSUPPORTED_整块不画() {
        rule.setContent {
            LpTheme(darkOverride = true) {
                BlockBox<Unit>(Block.Fail("E_UNSUPPORTED", "这个平台不支持")) { }
            }
        }
        rule.onNodeWithText("这个平台不支持").assertDoesNotExist()
    }

    /** 反过来:别的错误码必须**看得见**,而且要带核心层给的真实原因。 */
    @Test fun 别的错误码要显示原因和重试() {
        rule.setContent {
            LpTheme(darkOverride = true) {
                BlockBox<Unit>(Block.Fail("E_NETWORK", "连不上服务器"), onRetry = {}) { }
            }
        }
        rule.onNodeWithText("连不上服务器").assertIsDisplayed()
        rule.onNodeWithText("重试").assertIsDisplayed()
    }
}
