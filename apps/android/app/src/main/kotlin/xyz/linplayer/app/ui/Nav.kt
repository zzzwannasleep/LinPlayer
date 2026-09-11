package xyz.linplayer.app.ui

import androidx.navigation.NavController
import androidx.navigation.NavGraph.Companion.findStartDestination
import kotlinx.serialization.Serializable

/**
 * 类型安全路由(Navigation Compose 2.8+ 的 `@Serializable` 路由对象)。
 *
 * ★ 加页面要同时改两处:这里 + 引到它的那个入口。
 *   只加一处的表现是「点了没反应」,而且**不报错**。
 */
object Route {
    @Serializable data object Gate            // 首登闸口 / 添加服务器(U1.2)
    @Serializable data object Home            // 首页(U1.3)· Tab 0
    @Serializable data object Aggregate       // 聚合视界(U1.8)· Tab 1
    @Serializable data object Servers         // 服务器管理(U1.9b)· Tab 2

    @Serializable data class Library(val viewId: String, val title: String)   // U1.4
    @Serializable data class Detail(val itemId: String, val type: String)     // U1.5
    @Serializable data class Search(val viewId: String? = null, val q: String? = null) // U1.7
    @Serializable data object Favorites                                       // U1.9a
    @Serializable data class Lines(val serverId: String, val name: String)    // U1.9b
    @Serializable data object Browse                                          // U1.10
    @Serializable data object Catalog                                         // U1.11
    @Serializable data object Downloads                                       // U1.12
    @Serializable data object Plugins                                         // U1.13
    @Serializable data object Ranking                                         // U1.14a
    @Serializable data object Calendar                                        // U1.14b
    @Serializable data object Settings                                        // U1.15
    @Serializable data class SettingsSub(val group: String)                   // U1.15 二级
    /**
     * U1.6。`versionId` = 详情页选中的 MediaSource —— 不传就让核心层按版本正则自己挑。
     *
     * `engine` = 这一次用哪个内核(`mpv` / `exo`)。不传就用设置里的默认。
     * ★ 跟着**这一次跳转**走而不是读全局开关:长按播放键换内核只影响按下的这一次,
     *   不该把设置也改掉 —— 换回来还得再进一趟设置页,那不是「另一个内核试一下」。
     */
    @Serializable data class Player(
        val itemId: String, val title: String, val versionId: String? = null,
        val engine: String? = null,
        /* 片源宽高比。详情页点播放那一刻就知道(它手里的 Version 带着 width/height),
           带过来是为了在**第一帧之前**把横竖屏定下来 —— 让播放页自己去问一次网络的话,
           用户会先看见一个竖屏的播放页,再整块转过去。0 = 不知道,播放页自己去问。 */
        val ar: Float = 0f,
    )
    @Serializable data object AddServer                                       // U1.2 的「添加」版式
}

/**
 * 底栏切 Tab。**三个 Tab 各自独立返回栈**(UI_MOBILE.md §5.3)——
 * `saveState` / `restoreState` 保住每个 Tab 的滚动位置与页面栈。
 */
fun NavController.switchTab(route: Any) {
    navigate(route) {
        popUpTo(graph.findStartDestination().id) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}
