package xyz.linplayer.tv

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.os.Bundle
import android.view.KeyEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.webkit.WebView
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat

/**
 * 安卓宿主 Activity(**TV 和手机同一个**)。除了 Tauri 自带的那点事,
 * 这里还担四件**缺一不可**的活:
 *
 *  1. 加载 libmpv.so —— 必须从 Java 侧 System.loadLibrary,不能只靠 Rust 那边 dlopen。
 *  2. 造渲染面 —— 一层 SurfaceView 垫在透明 WebView 底下,把 Surface 递给 mpv。
 *  3. 转发遥控器按键 —— 返回键/媒体键被 Activity 吃掉的话,WebView 根本收不到。
 *  4. **告诉前端这是不是电视** —— 一个 APK 装两种设备,前端要据此加载
 *     ui/tv 还是 ui/mobile(两套完整界面,不是响应式断点)。
 *
 * 四件事的理由分别写在下面各自的位置。
 *
 * ★ 包名是 `xyz.linplayer.tv` 只是历史(TV 端先建的),**别改** ——
 *   `applicationId` 早已是 `xyz.linplayer.app`,那才是用户和商店看见的东西。
 *   理由见 app/build.gradle.kts 里 applicationId 上方那段。
 */
class MainActivity : TauriActivity() {

  /**
   * 这台设备是不是电视。
   *
   * ★ 判据只用 `UiModeManager.currentModeType` —— 这是安卓官方给的、
   *   厂商必须正确上报的那一个信号。**不要**改成猜屏幕尺寸/有没有触摸屏:
   *   带触摸屏的一体机、投屏盒子、模拟器全都能把这类特征猜反,而猜反的
   *   表现不是一个小 bug,是**用户拿到了另一端的整套界面**。
   */
  private val isTelevision: Boolean by lazy {
    (getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)?.currentModeType ==
      Configuration.UI_MODE_TYPE_TELEVISION
  }

  companion object {
    /**
     * 先于一切把 libmpv 加载进来,Rust 侧随后 dlopen("libmpv.so") 拿到的是同一个句柄。
     *
     * ★ 注意**它并不负责登记 JavaVM**。我起初以为 System.loadLibrary 会触发
     *   `JNI_OnLoad`、mpv 在那里自己抓 JavaVM —— 对这个二进制是错的:
     *   实测 `llvm-nm -D`(media-kit/libmpv-android-video-build v1.1.11 full-arm64-v8a)
     *   **没有导出 JNI_OnLoad**,只导出 `av_jni_set_java_vm`。
     *   登记这件事由 Rust 侧在 nativeSetSurface 里做,见那边的注释。
     *   漏了它的表现是「一切成功但黑屏」,不报错 —— 别把那句登记删了。
     *
     * 加载失败不在这里崩:jniLibs 是 gitignore 的、靠 CI 拉取,漏了那一步就会
     * UnsatisfiedLinkError。让它继续走,Rust 侧 mpv_create 会给出一句能读懂的错
     * (「APK 里没有 libmpv.so」),而不是开机就闪退。
     */
    init {
      try {
        System.loadLibrary("mpv")
      } catch (e: UnsatisfiedLinkError) {
        Logger.error("libmpv.so 加载失败,播放功能不可用: ${e.message}")
      }
    }
  }

  /** 返回键交给前端处理(见 onKeyDown),不要 WryActivity 默认那套 webView.goBack()。 */
  override val handleBackNavigation: Boolean = false

  /**
   * 暴露给前端的宿主能力(`window.LPHost`)。
   *
   * ★ 为什么走 `addJavascriptInterface` 而不是 Tauri 命令:
   *   这里要动的是 **Activity 自己的属性**(`requestedOrientation`),Rust 侧碰不到。
   *   走命令的话链条是 JS → Rust → JNI 回调进 Activity,为了一行 setter
   *   要自己攒 JavaVM 引用和线程切换。
   * ★ 安全:接口只在**我们自己打包的本地页面**上下文里可达(WebView 只加载
   *   asset 协议下的 index-mobile.html),而且这里只有一个不带返回值的枚举 setter,
   *   参数被 `when` 收敛成三个常量 —— 拿不到任何反射面。
   * ★ 前端拿不到它时静默降级(见 ui/mobile/app/host.ts),桌面端跑同一份代码。
   */
  inner class HostBridge {
    @android.webkit.JavascriptInterface
    fun setOrientation(mode: String) {
      val want = when (mode) {
        "landscape" -> android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        "portrait" -> android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        /* auto = 交回系统。★ 用 UNSPECIFIED 而不是 SENSOR:后者会**强制**跟随
           传感器,把用户在系统里开的"竖屏锁定"也一起顶掉 —— 那是在替用户
           推翻他自己的设置。UNSPECIFIED 才是"我不表态"。 */
        else -> android.content.pm.ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
      }
      /* JS 桥的回调跑在 WebView 的 JavaBridge 线程上,动窗口必须回 UI 线程。
         不切的表现是偶发地什么都没发生(而不是崩),最难查的那一种。 */
      runOnUiThread { requestedOrientation = want }
    }
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    /* ★ 不能用无参的 enableEdgeToEdge()。它的默认导航栏样式是
       `SystemBarStyle.auto(DefaultLightScrim, DefaultDarkScrim)`,而
       `DefaultLightScrim = Color.argb(0xe6, 0xFF, 0xFF, 0xFF)` —— **九成不透明的白**
       (androidx/activity/EdgeToEdge.kt)。非深色模式下它会在屏幕边缘刷出一条白带,
       正是用户报的「播放页有一圈白边」的成分之一。两条都钉成透明。 */
    enableEdgeToEdge(
      SystemBarStyle.dark(Color.TRANSPARENT),
      SystemBarStyle.dark(Color.TRANSPARENT),
    )
    super.onCreate(savedInstanceState)
    /* 播放器全屏:把状态栏/导航栏藏起来,并让它们只在划出时短暂出现。
       TV 上本来多半没有这两条,但盒子形态千奇百怪 —— 藏掉是零成本的保险,
       而留着就是「屏幕多大画面就该多大」之外多出来的那一截。

       ★ **手机上不能这么干。** 这里原本是无条件隐藏,那是纯 TV 时代的写法:
         手机用户在浏览首页/媒体库/设置时看不到时间、信号、电量,退出应用还得
         先划一下才找得到导航条 —— 这是「把电视的做法搬到手机上」最典型的一种。
         手机只在**播放页**才该全屏,那由前端在进入播放时另行请求(见 ui/mobile),
         不是开机就藏。 */
    WindowCompat.getInsetsController(window, window.decorView).apply {
      systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
      if (isTelevision) hide(WindowInsetsCompat.Type.systemBars())
    }

    /* ── 系统开屏的收场动画:直接撤,不做那个放大淡出 ──
       ★ 用户 2026-08-02:「点进软件后,会有零点几秒的时间先看到图标放大显示,
         然后加载动画才显示出来」。那个"放大"就是 Android 12+ 开屏的**默认退场**:
         系统把图标放大并淡出。它和我们自己那块 #boot 是两段互不相干的动画,
         接缝处必然看得见一次跳变。
       ★ 这里把退场接管过来、立刻 remove:开屏底色(#0e0e13)和 #boot 的底色
         逐位一致,于是"系统开屏 → 我们的加载动画"这一步在视觉上完全没有交接。
       ★ 只有 API 31+ 有 SplashScreen;更低版本走的是 windowBackground,本来就没有
         这个退场动画。 */
    if (android.os.Build.VERSION.SDK_INT >= 31) {
      splashScreen.setOnExitAnimationListener { view -> view.remove() }
    }
  }

  override fun onWebViewCreate(webView: WebView) {
    /* UI 层必须透明,否则它会把底下的视频整个盖住 —— 这就是「有声音没画面」。 */
    webView.setBackgroundColor(Color.TRANSPARENT)

    /* 这里原本给电视的 UA 加一个 " LinPlayerTV" 标,让 index-android.html 那个 shim
       在运行时决定加载哪套 UI。2026-07-27 整条路删了:**设备类型判不准**,
       大屏平板 / 投屏一体机 / 模拟器都可能被判成电视,而判反的表现是用户拿到
       另一端的整套界面。现在 TV 包和手机包是两个 APK,壳打开哪个 html 在出包时
       就定死了(apps/android/tauri.conf.json vs tauri.phone.conf.json)。

       ⚠️ 下面 `isTelevision` 仍在用,但只剩「要不要藏系统状态栏」这一处装饰性判断,
       判错了最多是多/少一条状态栏,不会走错界面。 */

    /* ★ post 而不是直接做:onWebViewCreate 触发时 WebView 还没 attach 到父容器,
       这时 webView.parent 是 null,加不进去(而且不会报错,只是静默什么都没发生)。 */
    webView.post {
      /* ★ 再刷一遍透明。
         上面那次跑在 Wry 建 WebView 的**中途**,它之后还会按 tauri.conf.json 里的
         窗口配置回头设一次背景色 —— 我们这次就被它覆盖掉了,表现正是用户报的
         「深色模式黑屏 / 浅色模式白屏」:那是 WebView 自己的不透明底,
         跟着系统深浅色走,所以看着像"主题色铺满了整屏"。
         配置里已经补上 "transparent": true(那才是根治),这一行是保险 ——
         这条链上任何一环失手都是**静默黑屏**,不值得只留一道防线。 */
      webView.setBackgroundColor(Color.TRANSPARENT)
      /* 宿主能力桥。★ 必须在这里挂而不是上面那次:`addJavascriptInterface` 的注入
         发生在**下一次导航**时,而这个 post 已经在 Wry 建完 WebView 之后、
         首次 loadUrl 之前 —— 挂晚一帧的表现是 window.LPHost 在首屏是 undefined。 */
      webView.addJavascriptInterface(HostBridge(), "LPHost")
      val parent = webView.parent as? ViewGroup ?: run {
        Logger.error("WebView 没有父容器,无法插入视频面")
        return@post
      }
      val sv = SurfaceView(this)
      /* ★ 不要 setZOrderOnTop(true)。默认模式下 SurfaceView 在自己那块区域把窗口
         「打个洞」,视频从窗口**下面**透上来,而层级里排在它后面的 View(这里是 WebView)
         照常画在上面 —— 正是我们要的「视频在底、UI 在上」。
         设成 OnTop 会让它盖在 WebView 之上,表现是有画面但所有 UI 都点不到也看不见。 */
      sv.holder.addCallback(object : SurfaceHolder.Callback {
        override fun surfaceCreated(h: SurfaceHolder) = nativeSetSurface(h.surface)
        override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, ht: Int) {
          nativeSetSurface(h.surface)
          /* ★ 必须把尺寸单独报一遍。mpv 的 android gpu-context 只在 reconfig 时
             取一次视口大小,安卓又没有 resize 事件通道 —— 不报的话视口就冻在
             EGL 初始化那一刻(edge-to-edge 生效前的带 inset 小尺寸),
             画面渲染在一个比屏幕小的矩形里,**四周留一圈没画到的边**。
             mpv-android 的 BaseMPVView.kt 在这里做的也正是这一件事。
             理由和 mpv 源码出处见 crates/mpv 的 set_android_surface_size。 */
          nativeSetSurfaceSize(w, ht)
        }
        /* 传 null 让 Rust 侧释放全局引用。不清的话 mpv 会继续往一块已经销毁的
           Surface 上画 —— 那是原生崩溃,不是黑屏。 */
        override fun surfaceDestroyed(h: SurfaceHolder) = nativeSetSurface(null)
      })
      // index 0 = 排在 WebView 底下
      parent.addView(
        sv, 0,
        ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
      )

      pushSafeAreaToWeb(parent, webView)
    }
  }

  /**
   * 把真实的系统栏/刘海边距喂给前端的 `--sa-*` 变量。
   *
   * ## 为什么非做不可
   * 前端(ui/mobile/theme/mobile.css)四个安全区 token 写的是
   * `env(safe-area-inset-*)`,而我们在 onCreate 里开了 **edge-to-edge** ——
   * WebView 的视口于是铺满整块屏,**底部那条系统导航条压在视口里面**。
   * 偏偏 Android WebView 的 `env(safe-area-inset-bottom)` 只反映**刘海**,
   * 导航条一律返回 **0**,而且不报错。后果是:
   *   - 悬浮底栏 `bottom:0 + 7px`,整条胶囊有一大半画在系统导航条底下;
   *   - 内容给底栏让的 `tabbar-h + sa-bottom + 24px` 里 sa-bottom 是 0,
   *     底栏自己却被系统导航条往上顶 —— 看着就是「Tab 栏把下面的内容挡住了」。
   * 顶部同理:状态栏/挖孔那一条也白让了。
   *
   * mobile.css 里早就留好了这个覆盖点(「全站只认 --sa-*,任何地方都不直接写 env()」),
   * 这里把它接上。给不出值时保持原样(0),不会比现在更差。
   *
   * ★ 单位必须**除以 density** 转成 CSS px。WindowInsets 给的是物理像素,
   *   直接当 px 塞进去,在 3x 屏上会让出三倍高度 —— 底下空一大条。
   * ★ 监听器返回 `insets` **原样往下传**:吃掉的话 WebView 自己的插入物处理就断了。
   * ★ 电视上系统栏是隐藏的,四个值天然是 0,这段对 TV 包等于不存在。
   */
  private fun pushSafeAreaToWeb(root: ViewGroup, webView: WebView) {
    ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
      val i = insets.getInsets(
        WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
      )
      val d = resources.displayMetrics.density.takeIf { it > 0f } ?: 1f
      val js = buildString {
        append("(function(s){")
        append("s.setProperty('--sa-top','").append(i.top / d).append("px');")
        append("s.setProperty('--sa-bottom','").append(i.bottom / d).append("px');")
        append("s.setProperty('--sa-left','").append(i.left / d).append("px');")
        append("s.setProperty('--sa-right','").append(i.right / d).append("px');")
        append("})(document.documentElement.style)")
      }
      webView.evaluateJavascript(js, null)
      insets
    }
    ViewCompat.requestApplyInsets(root)
  }

  /**
   * 遥控器按键转发。
   *
   * ★ 不转发的话这些键**根本到不了 WebView**:返回键被 Activity 的返回栈吃掉,
   *   媒体键被系统路由走。前端 ui/tv/app/focus.ts 里的 `window.__lpTvKey` 契约
   *   就是为这条通道写的,那边先落的,这边一直空着。
   *
   * 方向键和 OK 键**不在这里转发** —— 它们本来就会正常派发给 WebView,
   * 再转发一次等于每次按键触发两遍导航(焦点一次跳两格)。
   */
  override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
    /* ★ 方向键/OK 键:**通知前端但不吃掉**。
       播放页的 OSD 靠"按任意键唤出",而它原来只监听 WebView 里的 keydown ——
       那条路真机上到底通不通,我在电视外面无法证明(2026-07-22 用户报「无论点什么
       都不出 OSD」)。与其继续猜,不如把这一条独立通道也接上:
       Activity 一定收得到按键,让它额外喊一嗓子。

       ★ 关键是 `return super.onKeyDown(...)` 而**不是** return true ——
         按键照常往下派发给 WebView,焦点导航一点不受影响。
         前端收到的 'wake' 只做一件事:把 OSD 亮起来,绝不移动焦点。
         所以就算两条路都通,也只是 bump 两次(幂等),不会出现焦点一次跳两格 ——
         那正是本文件原来不转发方向键的理由,这里用"不消费"绕开了它。 */
    when (keyCode) {
      KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN,
      KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT,
      KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
        runOnUiThread {
          findWebView()?.evaluateJavascript("window.__lpTvKey && window.__lpTvKey('wake')", null)
        }
        return super.onKeyDown(keyCode, event)
      }
    }

    val name = when (keyCode) {
      KeyEvent.KEYCODE_BACK -> "back"
      KeyEvent.KEYCODE_MENU -> "menu"
      KeyEvent.KEYCODE_MEDIA_PLAY -> "play"
      KeyEvent.KEYCODE_MEDIA_PAUSE -> "pause"
      KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> "playpause"
      KeyEvent.KEYCODE_MEDIA_STOP -> "stop"
      KeyEvent.KEYCODE_MEDIA_NEXT -> "next"
      KeyEvent.KEYCODE_MEDIA_PREVIOUS -> "prev"
      KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> "ff"
      KeyEvent.KEYCODE_MEDIA_REWIND -> "rew"
      else -> return super.onKeyDown(keyCode, event)
    }
    runOnUiThread {
      findWebView()?.evaluateJavascript("window.__lpTvKey && window.__lpTvKey('$name')", null)
    }
    return true // 吃掉,别再走系统默认行为(返回键的默认行为是退出 Activity)
  }

  /** WryActivity 把 WebView 存成 private,只能从视图树里捞。 */
  private fun findWebView(): WebView? {
    val root = window?.decorView as? ViewGroup ?: return null
    fun dig(v: android.view.View): WebView? {
      if (v is WebView) return v
      if (v is ViewGroup) for (i in 0 until v.childCount) dig(v.getChildAt(i))?.let { return it }
      return null
    }
    return dig(root)
  }

  /** 见 apps/android/src/lib.rs 的同名 JNI 导出。传 null = Surface 没了。 */
  private external fun nativeSetSurface(surface: android.view.Surface?)

  /** 见 apps/android/src/lib.rs 的同名 JNI 导出。单位是像素。 */
  private external fun nativeSetSurfaceSize(width: Int, height: Int)
}
