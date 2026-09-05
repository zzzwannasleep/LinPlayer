package xyz.linplayer.app

import android.Manifest
import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import xyz.linplayer.app.data.AppState
import xyz.linplayer.app.ui.theme.LpTheme

/**
 * 单 Activity。**双形态分流靠 UiModeManager,不是两个 Activity**(U1.1)——
 * 两个 Activity 意味着两份深链、两份生命周期、两份 surface 交接。
 */
class MainActivity : ComponentActivity() {

    private lateinit var app: AppState

    /** 深链(U1.26)。冷启动走 `onCreate`、热启动走 `onNewIntent`,**两条路径都要收**。 */
    private val deepLink = MutableStateFlow<String?>(null)

    private val askNotification =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* 拒了就没有通知栏控制,不拦流程 */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        // 开屏必须在 super.onCreate 之前装(U1.17)。
        // ★ 不挂 setKeepOnScreenCondition:核心层已经在 Application 里起好了,
        //   把开屏拖到「首页有数据」等于做了一个假的加载页 —— 而契约是骨架先出。
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        app = AppState((application as LinPlayerApp).core, lifecycleScope)
        // 设备 id 必须**持久**:每次换一个会把服务器的设备列表刷满,续播会话也对不上
        runCatching {
            Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
        }.getOrNull()?.let { app.setDeviceId(it) }

        handleIntent(intent)
        // 自检直达:adb shell am start ... -e lp_login "<地址>|<用户>|<密码>"
        // 不能靠 input text —— 焦点落在哪儿不确定,实测一个字符都没进去(PC 端同一条教训)
        intent?.getStringExtra("lp_login")?.let { SelfCheck.login = it }
        intent?.getStringExtra("lp_page")?.let { SelfCheck.page = it }

        setContent {
            LpTheme {
                if (isTelevision()) TvPlaceholder() else PhoneRoot(app)
            }
        }

        // 深链交给核心层解析,**UI 不自己解析 URL**(SPEC §8.5)
        lifecycleScope.launch {
            deepLink.collect { url ->
                if (url == null) return@collect
                runCatching {
                    app.core.callJson("account.parseDeepLink",
                        JsonObject(mapOf("url" to JsonPrimitive(url))))
                }.onSuccess { app.refreshSession() }.onFailure { app.report(it) }
                deepLink.value = null
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    /** 真机自检用的直达入口。发行包里它永远是空的 —— 只有 adb 传 extra 才会有值。 */
    object SelfCheck {
        @Volatile var login: String? = null
        @Volatile var page: String? = null
    }

    private fun handleIntent(i: Intent?) {
        if (i?.action == Intent.ACTION_VIEW) deepLink.value = i.dataString
    }

    /**
     * 通知权限(U1.27)。Android 13+ 要运行时申请,**拒了不拦流程** —— 只是没有通知栏控制。
     *
     * ★ **不在冷启动时问。** 用户还没做任何事就弹权限框是最招人烦的一种要法,
     *   而且这个权限只在**后台播放要挂通知栏**时才有意义(U1.21)。
     *   所以由播放页在起播时调它。
     */
    fun askNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED
        ) return
        askNotification.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    /**
     * 画中画(U1.25)。Home 键进 PiP。
     * ★ 分屏 / 自由窗口下**不进 PiP**(那是两个窗口管理器在抢同一件事)。
     */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (isInMultiWindowMode) return
        if (!app.wantsPip) return
        runCatching {
            enterPictureInPictureMode(
                PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build()
            )
        }
    }

    /** TV 形态本轮不做(U1.16 单开一轮),留一个说清楚的空壳而不是让它跑手机版。 */
    private fun isTelevision(): Boolean {
        val ui = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
        return ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
    }
}

@Composable
private fun TvPlaceholder() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text("LinPlayer 的电视版还没做好,请用手机端。")
    }
}
