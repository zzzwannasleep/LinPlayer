package xyz.linplayer.app

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.CachePolicy
import coil3.request.crossfade
import okhttp3.OkHttpClient
import xyz.linplayer.app.core.CoreClient
import xyz.linplayer.app.core.Logs

/**
 * 进程入口。核心层在这里起(SPEC §8.0 第 2 步),不在 Activity 里 ——
 * Activity 会重建,而 `lp_init` 虽然幂等,事件线程不该跟着 Activity 生死。
 */
class LinPlayerApp : Application(), SingletonImageLoader.Factory {
    lateinit var core: CoreClient
        private set

    override fun onCreate() {
        super.onCreate()
        // 日志排在核心层之前:核心层起不来本身就是最该留下记录的一种失败
        Logs.init(this)
        // 数据根是应用私有目录:安卓上没有「绿色包同级 userdata/」那回事,
        // 也不需要 —— 卸载即清干净,而且不用任何存储权限
        core = CoreClient.start(
            dataDir = filesDir.absolutePath,
            version = BuildConfig.VERSION_NAME,
        )
    }

    /**
     * 图片加载器(UI_MOBILE.md §4.4)。
     *
     * ☠ **本地数据通道要 `X-LP-Token` 请求头**(`core/net/localserve`)——
     *   不带就是 401,而 401 在界面上长得和「这张图不存在」一模一样:
     *   骨架不消失、不报错、一个字都没有。查了才知道是缺一个头。
     *   token **每次启动重新随机生成**,所以只能在拦截器里现读,不能拼进 URL
     *   (拼进 URL 会进 mpv 日志,这也正是核心层把它放在头里的理由)。
     *
     * ★ **磁盘缓存关掉**:核心层的 `imgcache` 已经落过一份盘了。
     *   UI 再落一份 = 同一张图占两份磁盘,而且设置页的「清理缓存」清不到 UI 那份,
     *   变成一个安慰剂按钮。
     */
    override fun newImageLoader(context: PlatformContext): ImageLoader {
        val ok = OkHttpClient.Builder().addInterceptor { chain ->
            val req = chain.request()
            val isLocal = req.url.host == "127.0.0.1" || req.url.host == "localhost"
            chain.proceed(
                if (isLocal && core.localToken.isNotEmpty())
                    req.newBuilder().header("X-LP-Token", core.localToken).build()
                else req
            )
        }.build()

        return ImageLoader.Builder(context)
            .components { add(OkHttpNetworkFetcherFactory(callFactory = { ok })) }
            .diskCachePolicy(CachePolicy.DISABLED)
            .crossfade(false)   // 淡入由 NetImage 自己按 state 做,两处一起淡会闪两下
            .build()
    }
}
