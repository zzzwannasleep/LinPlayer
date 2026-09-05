package xyz.linplayer.app

import android.app.Application
import xyz.linplayer.app.core.CoreClient

/**
 * 进程入口。核心层在这里起(SPEC §8.0 第 2 步),不在 Activity 里 ——
 * Activity 会重建,而 `lp_init` 虽然幂等,事件线程不该跟着 Activity 生死。
 */
class LinPlayerApp : Application() {
    lateinit var core: CoreClient
        private set

    override fun onCreate() {
        super.onCreate()
        // 数据根是应用私有目录:安卓上没有「绿色包同级 userdata/」那回事,
        // 也不需要 —— 卸载即清干净,而且不用任何存储权限
        core = CoreClient.start(
            dataDir = filesDir.absolutePath,
            version = BuildConfig.VERSION_NAME,
        )
    }
}
