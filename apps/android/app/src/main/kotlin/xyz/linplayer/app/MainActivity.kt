package xyz.linplayer.app

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import xyz.linplayer.app.ui.theme.LpTheme

/**
 * 单 Activity。**双形态分流靠 UiModeManager,不是两个 Activity**(U1.1)——
 * 两个 Activity 意味着两份深链、两份生命周期、两份 surface 交接。
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // 开屏必须在 super.onCreate 之前装(U1.17)。
        // ★ 不挂 setKeepOnScreenCondition:核心层已经在 Application 里起好了,
        //   把开屏拖到「首页有数据」等于做了一个假的加载页 —— 而契约是骨架先出。
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        setContent {
            LpTheme {
                if (isTelevision()) TvPlaceholder() else PhoneRoot()
            }
        }
    }

    /** TV 形态本轮不做(U1.16 单开一轮),留一个说清楚的空壳而不是让它跑手机版。 */
    private fun isTelevision(): Boolean {
        val ui = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
        return ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
    }
}

@androidx.compose.runtime.Composable
private fun TvPlaceholder() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text("LinPlayer 的电视版还没做好,请用手机端。")
    }
}
