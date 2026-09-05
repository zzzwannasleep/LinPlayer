package xyz.linplayer.app

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.delay
import xyz.linplayer.app.data.AppState
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.ToastKind
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.LpRowSkeleton
import xyz.linplayer.app.ui.components.LpTabBar
import xyz.linplayer.app.ui.components.Skeleton
import xyz.linplayer.app.ui.pages.AggregatePage
import xyz.linplayer.app.ui.pages.CalendarPage
import xyz.linplayer.app.ui.pages.CatalogPage
import xyz.linplayer.app.ui.pages.DetailPage
import xyz.linplayer.app.ui.pages.DownloadsPage
import xyz.linplayer.app.ui.pages.FavoritesPage
import xyz.linplayer.app.ui.pages.GatePage
import xyz.linplayer.app.ui.pages.HomePage
import xyz.linplayer.app.ui.pages.LibraryPage
import xyz.linplayer.app.ui.pages.LinesPage
import xyz.linplayer.app.ui.pages.BrowsePage
import xyz.linplayer.app.ui.pages.PluginsPage
import xyz.linplayer.app.ui.pages.RankingPage
import xyz.linplayer.app.ui.pages.SearchPage
import xyz.linplayer.app.ui.pages.ServersPage
import xyz.linplayer.app.ui.pages.SettingsPage
import xyz.linplayer.app.ui.pages.SettingsSubPage
import xyz.linplayer.app.ui.player.PlayerPage
import xyz.linplayer.app.ui.switchTab
import xyz.linplayer.app.ui.theme.LpEasing
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp
import xyz.linplayer.app.ui.theme.T

/**
 * 手机形态的根。启动时序(SPEC §8.0)的第 4~6 步在这里。
 *
 * ☠ **第 5 步没判完之前画骨架,不画闸口也不画首页** ——
 * 先画闸口再跳走会闪一下「请登录」,那比多等 80ms 难看得多。
 */
@Composable
fun PhoneRoot(app: AppState) {
    androidx.compose.runtime.CompositionLocalProvider(LocalApp provides app) {
        val loggedIn by app.loggedIn.collectAsStateWithLifecycle()
        LaunchedEffect(Unit) { app.boot() }

        Box(Modifier.fillMaxSize().background(Lp.colors.bg)) {
            when (loggedIn) {
                null -> BootSkeleton()
                false -> GatePage(onDone = { app.refreshSession() })
                true -> MainShell()
            }
            ToastHost()
        }
    }
}

/** 第 1 步的骨架:**不是转圈,是页面轮廓**(SPEC §8.0)。 */
@Composable
private fun BootSkeleton() {
    Column(Modifier.fillMaxSize().padding(top = 80.dp)) {
        Skeleton(Modifier.fillMaxWidth().height(220.dp).padding(horizontal = Sp.x16), R.md)
        LpRowSkeleton()
        LpRowSkeleton()
    }
}

@Composable
private fun MainShell() {
    val nav = rememberNavController()
    val entry by nav.currentBackStackEntryAsState()
    val route = entry?.destination?.route.orEmpty()
    val tab = when {
        route.endsWith("Home") -> 0
        route.endsWith("Aggregate") -> 1
        route.endsWith("Servers") -> 2
        else -> -1
    }

    /* 真机自检直达:`am start ... -e lp_page <名字>`。
       ★ 不能靠 input tap 走到目标页 —— 坐标随字号 / 数据变,而且中间任何一步
         没点中,后面全错位;截图看起来还像是「那一页做坏了」。 */
    LaunchedEffect(Unit) {
        val p = MainActivity.SelfCheck.page ?: return@LaunchedEffect
        MainActivity.SelfCheck.page = null
        val parts = p.split(":")
        when (parts[0]) {
            "aggregate" -> nav.navigate(Route.Aggregate)
            "servers" -> nav.navigate(Route.Servers)
            "search" -> nav.navigate(Route.Search())
            "favorites" -> nav.navigate(Route.Favorites)
            "downloads" -> nav.navigate(Route.Downloads)
            "plugins" -> nav.navigate(Route.Plugins)
            "ranking" -> nav.navigate(Route.Ranking)
            "calendar" -> nav.navigate(Route.Calendar)
            "settings" -> nav.navigate(Route.Settings)
            "browse" -> nav.navigate(Route.Browse)
            "catalog" -> nav.navigate(Route.Catalog)
            "addServer" -> nav.navigate(Route.AddServer)
            "library" -> nav.navigate(Route.Library(parts.getOrElse(1) { "" }, parts.getOrElse(2) { "媒体库" }))
            "detail" -> nav.navigate(Route.Detail(parts.getOrElse(1) { "" }, parts.getOrElse(2) { "Series" }))
            "player" -> nav.navigate(Route.Player(parts.getOrElse(1) { "" }, parts.getOrElse(2) { "自检" }))
            "settingsSub" -> nav.navigate(Route.SettingsSub(parts.getOrElse(1) { "about" }))
        }
    }

    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f)) {
            NavHost(
                navController = nav,
                startDestination = Route.Home,
                // 页面转场:新页从右滑入 + 淡入。**Tab 之间只淡入不位移**(平级没有方向)
                enterTransition = {
                    slideInHorizontally(tweenI(T.T7, LpEasing.emphasized)) { it / 8 } +
                        fadeIn(tween(T.T7))
                },
                exitTransition = { fadeOut(tween(T.T4)) },
                popEnterTransition = { fadeIn(tween(T.T4)) },
                popExitTransition = {
                    slideOutHorizontally(tweenI(T.T7, LpEasing.emphasized)) { it / 6 } +
                        fadeOut(tween(T.T5))
                },
            ) {
                composable<Route.Home> { HomePage(nav) }
                composable<Route.Aggregate> { AggregatePage(nav) }
                composable<Route.Servers> { ServersPage(nav) }
                composable<Route.Library> { LibraryPage(nav, it) }
                composable<Route.Detail> { DetailPage(nav, it) }
                composable<Route.Search> { SearchPage(nav, it) }
                composable<Route.Favorites> { FavoritesPage(nav) }
                composable<Route.Lines> { LinesPage(nav, it) }
                composable<Route.Browse> { BrowsePage(nav) }
                composable<Route.Catalog> { CatalogPage(nav) }
                composable<Route.Downloads> { DownloadsPage(nav) }
                composable<Route.Plugins> { PluginsPage(nav) }
                composable<Route.Ranking> { RankingPage(nav) }
                composable<Route.Calendar> { CalendarPage(nav) }
                composable<Route.Settings> { SettingsPage(nav) }
                composable<Route.SettingsSub> { SettingsSubPage(nav, it) }
                composable<Route.AddServer> { GatePage(onDone = { nav.popBackStack() }, embedded = true) }
                composable<Route.Player> { PlayerPage(nav, it) }
            }
        }
        // 播放页是全屏页,没有底栏
        if (tab >= 0) LpTabBar(tab) {
            nav.switchTab(when (it) { 0 -> Route.Home; 1 -> Route.Aggregate; else -> Route.Servers })
        }
    }
}

private fun tween(d: Int, easing: androidx.compose.animation.core.Easing = LpEasing.standard) =
    androidx.compose.animation.core.tween<Float>(d, easing = easing)

private fun tweenI(d: Int, easing: androidx.compose.animation.core.Easing = LpEasing.standard) =
    androidx.compose.animation.core.tween<androidx.compose.ui.unit.IntOffset>(d, easing = easing)

/**
 * Toast。**位置:全站中部偏下**【用户定,三端统一】。
 *
 * ★ 不用系统 `android.widget.Toast`:位置不可控、Android 12+ 强制加图标和应用名、
 *   播放页全屏下会被系统栏顶位置(UI_MOBILE.md §6.1)。
 */
@Composable
private fun ToastHost() {
    val app = LocalApp.current
    val c = Lp.colors
    var cur by remember { mutableStateOf<xyz.linplayer.app.data.Toast?>(null) }

    LaunchedEffect(Unit) {
        app.toasts.collect {
            cur = it
            delay(if (it.kind == ToastKind.Error) 5000 else 3000)
            cur = null
        }
    }

    Box(Modifier.fillMaxSize().padding(bottom = 128.dp), contentAlignment = Alignment.BottomCenter) {
        AnimatedVisibility(
            visible = cur != null,
            enter = slideInVertically(tweenI(T.T5, LpEasing.emphasizedDecelerate)) { it / 3 } + fadeIn(tween(T.T5)),
            exit = fadeOut(tween(T.T4)),
        ) {
            val t = cur
            Text(
                t?.text.orEmpty(),
                Modifier.padding(horizontal = Sp.x26)
                    .clip(RoundedCornerShape(R.sm))
                    .background(if (t?.kind == ToastKind.Error) c.bad else c.s3)
                    .padding(horizontal = Sp.x16, vertical = Sp.x12),
                color = if (t?.kind == ToastKind.Error) c.accFg else c.fg,
                fontSize = 13.sp,
            )
        }
    }
}
