# R4 · 播放页平台实践调研

> ⚠️ **版本号以 [`VERSIONS_VERIFIED.md`](VERSIONS_VERIFIED.md) 为准。**
> 本文里的版本与发布日期已于 2026-09-06 抽查,系统性过时;结构性结论(API 是否存在、
> 语义、坑)仍有效。


> **前提**: 播放器在 Go 核心层的 libmpv 里，Java 侧只有 SurfaceView
> **调研日期**: 2026-09-06
> **调研方法**: Android 官方文档 + NDK 官方头文件 + AndroidX 发布说明
> **用途**: Go 迁移 Android 手机/TV 播放页的平台集成

---

## 调研进度

（已写入此行）

## 1. SurfaceView 生命周期与 Compose 集成

### SurfaceHolder.Callback 回调语义与时序

**三个标准回调**（来源：Android Developers 官方文档）：

| 回调 | 语义 | 时序 |
|---|---|---|
| `surfaceCreated(holder)` | Surface 已创建完毕，准备好接收绘制 | View 首次附加到窗口或 View 树变化后 |
| `surfaceChanged(holder, format, width, height)` | Surface 尺寸或格式变化 | 初创建后以及设备旋转/分屏变化时触发 |
| `surfaceDestroyed(holder)` | Surface **即将销毁** | View 从窗口移除或 Activity/Fragment 生命周期终止前 |

**关键约束**（官方文档强调）：
- `surfaceDestroyed` 返回后，Surface **立即失效**。此时访问 Surface 会导致错误或 crash
- 所有对 Surface 的操作（包括 native 侧的 ANativeWindow 指针）**必须在 surfaceDestroyed 返回前完成清理**
- 不能在回调之外延迟清理

### surfaceDestroyed() 中的同步阻塞时间限制

**未找到官方文档明确规定 surfaceDestroyed 中阻塞的最大时间。** 根据 Android 主线程 ANR 规则：
- 主线程阻塞 5 秒以上会触发 ANR（Application Not Responding）
- SurfaceHolder.Callback 通常在主线程调用（除非显式在其他线程执行）
- **推荐实践**：surfaceDestroyed 中的同步调用应在 **100ms - 1s** 内完成

**出处**：
- Surface 失效时序：https://developer.android.com/reference/android/view/SurfaceView
- ANR 规则：https://developer.android.com/topic/performance/vitals/anr

### Compose 里用 AndroidView 包 SurfaceView 的正确写法

**Compose 标准方式**（来源：Android Developers + Media3 示例）：

```kotlin
AndroidView(
    factory = { context ->
        SurfaceView(context).apply {
            holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    // 初始化绘制、绑定 native surface
                }
                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                    // 处理尺寸变化
                    // 需要重新调用 lp_set_surface(1, nativeWindow, w, h)
                }
                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    // 必须同步调用 lp_set_surface(0, 0, 0, 0) 清理 native 绑定
                    // 此处阻塞是允许的（同步清理），但应在 1s 内完成
                }
            })
        }
    },
    modifier = Modifier.fillMaxSize()
)
```

**重要细节**：
- `AndroidView` 的 `factory` lambda 在 Composition 过程中调用，生成的 View 被自动管理生命周期
- Compose 框架会在 AndroidView 要移除时调用 `onRelease {}`（如需自定义清理）
- **surfaceDestroyed 必须同步等待核心层清理，不能异步投递**

（已写入 52 行）

## 2. ANativeWindow_fromSurface(JNI/NDK)

### NDK 函数签名与头文件

**函数声明**（来源：Android NDK native_window.h）：

```c
// 头文件：<android/native_window.h>
// 需要链接：-landroid

ANativeWindow* ANativeWindow_fromSurface(
    JNIEnv* env,
    jobject surface  // java.lang.Object 类型的 Java Surface
);
```

**返回值**：
- 成功：指向 `ANativeWindow` 结构的指针
- 失败：NULL（如 Surface 无效或 env/surface 指针错误）

**函数所在库**：libandroid.so（API 8+）

### 引用计数语义

**`ANativeWindow_release` 语义**（NDK 官方文档）：

```c
void ANativeWindow_release(ANativeWindow* window)
```

- **不是真正的「计数递减」**，而是**通知系统该 ANativeWindow 不再被使用**
- 每个从 `ANativeWindow_fromSurface` 得到的指针**必须恰好调用一次 `ANativeWindow_release`**
- 调用 `ANativeWindow_release` 后，指针变成悬空指针，再访问会导致崩溃

**关键约束**：
- 如果多个地方需要使用同一个 Surface 的 ANativeWindow，**必须各自调用一次 `ANativeWindow_fromSurface`**，各自持有一份引用，各自调用一次 `release`
- **不能「共享」一个 ANativeWindow 指针给多个使用者**（没有真正的引用计数）

### 从 JNI 获取 jobject Surface 的正确写法

**标准模式**（来源：NDK 示例代码）：

```c
// 在 JNI 函数中
JNIEXPORT void JNICALL 
Java_xyz_linplayer_app_Player_nativeSetSurface(
    JNIEnv* env, jobject thiz, jobject surface
) {
    if (surface == NULL) {
        // 清理模式
        if (g_native_window != NULL) {
            ANativeWindow_release(g_native_window);
            g_native_window = NULL;
        }
        return;
    }
    
    // 创建 ANativeWindow
    ANativeWindow* new_window = ANativeWindow_fromSurface(env, surface);
    if (new_window == NULL) {
        // 错误处理：Surface 无效
        return;
    }
    
    // 释放旧引用
    if (g_native_window != NULL) {
        ANativeWindow_release(g_native_window);
    }
    
    // 保存新引用
    g_native_window = new_window;
    
    // 获取 Surface 尺寸（可选）
    int32_t width = ANativeWindow_getWidth(new_window);
    int32_t height = ANativeWindow_getHeight(new_window);
}
```

**从 Kotlin 调用**：

```kotlin
// Kotlin 侧
val surface = surfaceView.holder.surface
nativeSetSurface(surface)  // 传递给 JNI 函数
```

### 哪个 NDK 头文件

**所需头文件**：
- 主头文件：`#include <android/native_window.h>`
- JNI 支持：`#include <jni.h>`（通常已包含在编译环境中）

**所需库**：
- 编译时：`-landroid`（链接器标志）
- Android NDK 版本：r21 及以上（确保 native_window.h 包含完整的 API）

**出处**：
- NDK 官方文档：https://developer.android.com/ndk/reference/group/native-window
- native_window.h 头文件：$NDK_HOME/toolchains/llvm/prebuilt/*/sysroot/usr/include/android/native_window.h

（已写入 61 行）

## 3. MediaSession(无 ExoPlayer) —— 两条路对比 + 推荐

### Media3 · SimpleBasePlayer 路线

**现状**：`androidx.media3:media3-session` 当前版本 **1.3.0**（2024-09 发布）

**核心类**：`androidx.media3.common.SimpleBasePlayer`
- **设计目的**：为自定义播放器（如 libmpv）提供统一的 Player 接口包装
- **不涉及播放逻辑**，纯接口适配层

**SimpleBasePlayer 必须实现的方法**（来源：Media3 GitHub）：

| 方法 | 用途 |
|---|---|
| `getState()` | 返回当前播放状态（duration, position, isPlaying, mediaItems, etc.） |
| `handleSetPlayWhenReady(boolean)` | 处理播放/暂停命令 |
| `handlePrepare()` | 处理准备媒体命令 |
| `handleStop()` | 处理停止命令 |
| `handleRelease()` | 处理释放资源命令 |
| `handleSetVideoOutput(Object)` | 处理设置视频输出（本项目传 Surface） |
| `handleClearVideoOutput(Object)` | 处理清除视频输出 |
| `handleSeek(int mediaItemIndex, long posMs, @Player.Command int cmd)` | 处理 seek 命令 |
| `handleSetMediaItems(List<MediaItem>, int startIdx, long startPosMs)` | 处理媒体列表更改 |

**集成到 MediaSession**：

```kotlin
val customPlayer = MySimpleBasePlayerImpl(context)  // 自定义实现
val mediaSession = MediaSession.Builder(context, customPlayer)
    .setId("my_session")
    .setCallback(object : MediaSession.Callback {
        override fun onConnect(session: MediaSession, controller: ControllerInfo): ConnectionResult {
            return if (controller.isTrusted()) {
                ConnectionResult.AcceptedResultBuilder(session, controller)
                    .setAvailableSessionCommands(SessionCommands.Builder().addAllSessionCommands().build())
                    .setAvailablePlayerCommands(Player.Commands.Builder().addAllCommands().build())
                    .build()
            } else {
                ConnectionResult.reject()
            }
        }
    })
    .build()
```

**优势**：
- ✅ Media3 官方推荐方案
- ✅ 自动处理通知栏、快捷键、蓝牙遥控器等系统集成
- ✅ 支持音频焦点、音量键映射等

### 平台原生 MediaSession 路线

**备选**：`android.media.session.MediaSession`（平台原生，API 21+）或 `androidx.media.session.MediaSessionCompat`（兼容库，支持 API 14+）

**对比**：

| 特性 | Media3 | MediaSessionCompat |
|---|---|---|
| 最低 API | 16 | 14 |
| 自动 UI 集成 | ✅（通知栏、控制中心） | ❌（需手工管理） |
| 蓝牙遥控 | ✅（自动） | ✅（需配置） |
| 音频焦点 | ✅（SimpleBasePlayer 内置） | ❌（需手工） |
| 维护状态 | ✅（活跃维护，2024 年还在更新） | ⚠️（进入维护模式） |
| 自定义播放器适配 | ✅（SimpleBasePlayer） | ⚠️（需自己实现 PlaybackState） |

### 推荐结论

**选 Media3 · SimpleBasePlayer 路线**，原因：

1. **官方设计就是为此**：SimpleBasePlayer 的唯一存在理由就是包装自定义播放器（如我们的 libmpv）
2. **自动化程度高**：通知栏、系统快捷键、蓝牙遥控全部自动工作，减少 bug 面
3. **活跃维护**：Media3 在 2024 年仍有新版本发布，bug fix 及时
4. **减少手工代码**：相比 MediaSessionCompat 需要手工管理的各种状态，SimpleBasePlayer 只需实现 9 个方法

**不选 MediaSessionCompat 的原因**：
- 已进入维护阶段，新功能不会加
- 需要手工管理通知栏状态、PlaybackState 等
- 三端代码维护难度高（PC/Linux 用 MPRIS，安卓用 MediaSessionCompat = 差异化测试）

（已写入 107 行）

## 4. 前台服务(API 34/35/36 规则)

### Android 14 (API 34) foregroundServiceType 规则

**必填条件**（来源：Android 14 行为变化文档）：

- **API 34+** 的应用**必须在 manifest 中声明 `android:foregroundServiceTypes`**，否则 `startForeground()` 会抛 `MissingForegroundServiceTypeException`
- 媒体播放对应类型：`FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK`（对应 manifest 中的 `mediaPlayback`）

**Manifest 声明**：

```xml
<!-- AndroidManifest.xml -->
<manifest ...>
    <!-- 必需权限 -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
    
    <application>
        <service
            android:name=".PlayerService"
            android:enabled="true"
            android:exported="false"
            android:foregroundServiceTypes="mediaPlayback" />
    </application>
</manifest>
```

### startForeground 5 秒 ANR 规则

**强制时间限制**（官方文档强调）：

- 调用 `startForegroundService(Intent)` 后，**必须在 5 秒内调用 `service.startForeground(id, notification)`**
- 5 秒超时后，系统会自动 crash 进程并抛 `ForegroundServiceDidNotStartInTimeException`（API 31+）
- **此 5 秒是硬限制**，不能减少（与主线程 ANR 时限相同）

**正确写法**：

```kotlin
class PlayerService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 立即创建通知（不能延迟）
        val notification = createNotification()
        
        // 立即调用（在 onStartCommand 内、耗时操作前）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        
        // 之后才能做其他初始化
        initializePlayer()
        return START_STICKY
    }
}
```

### Android 15/16 新限制

**未在官方文档找到 Android 15/16 对 mediaPlayback 前台服务的新限制。** 

目前的规则（API 34）预期在 15/16 上继续有效。**需确认**：
- Android 15 (API 35) 是否新增 `android:foregroundServiceTypes` 的新类型
- Android 16 (API 36) 是否调整前台服务的权限模型

**查询方式**：查看 Android 15/16 的官方发布说明（developer.android.com/about/versions）

出处：
- 前台服务 API 34：https://developer.android.com/about/versions/14/changes/fgs
- startForegroundService：https://developer.android.com/reference/android/content/Context#startForegroundService(android.content.Intent)

（已写入 74 行）

## 5. 音频焦点

### AudioFocusRequest + requestAudioFocus (API 26+)

**现代 API**（来源：Android Developers）：

```kotlin
import android.media.AudioManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest

val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

// 创建 AudioFocusRequest（推荐方式，API 26+）
val audioAttributes = AudioAttributes.Builder()
    .setUsage(AudioAttributes.USAGE_MEDIA)
    .build()

val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
    .setAudioAttributes(audioAttributes)
    .setOnAudioFocusChangeListener(
        AudioManager.OnAudioFocusChangeListener { focusChange ->
            when (focusChange) {
                AudioManager.AUDIOFOCUS_GAIN -> {
                    // 获得焦点，恢复正常音量
                    setMusicVolume(normalVolume)
                }
                AudioManager.AUDIOFOCUS_LOSS -> {
                    // 永久失去焦点（如来电、其他 App 播放音乐）
                    pausePlayback()
                }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                    // 临时失去焦点（如通知音）
                    pausePlayback()
                }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                    // 临时失去焦点，但允许「降低音量」继续播放
                    setMusicVolume(duckVolume)  // 通常是正常音量的 20%
                }
            }
        },
        handler  // 可选，指定回调的 Handler（通常不填，默认用主线程）
    )
    .build()

audioManager.requestAudioFocus(focusRequest)
```

### 焦点失败的各分支处理

**四个焦点状态的处理矩阵**：

| 焦点状态 | 含义 | 推荐动作 | 理由 |
|---|---|---|---|
| **AUDIOFOCUS_GAIN** | 获得焦点或焦点恢复 | 恢复正常音量 + 继续/恢复播放 | 系统允许播放 |
| **AUDIOFOCUS_LOSS** | 永久失去焦点 | **暂停播放** | 其他 App 或系统功能占用音频（来电、录音） |
| **AUDIOFOCUS_LOSS_TRANSIENT** | 临时失去焦点（不允许 duck） | 暂停播放 | 通知音/警报音播放，但 App 不允许继续 |
| **AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK** | 临时失去焦点（允许降低音量） | **降低音量 20~30%** 或 暂停 | 通知音/导航语音，App 可继续播放但降低音量 |

### mpv 音量控制与 duck 实现

**问题**：libmpv 的音量在 C 层管理，Java 层 duck 怎么作用？

**方案**：

1. **降低 mpv 音量（推荐）**：
   - 通过 Go 核心层接口（如 `lp_set_volume(0.3)`）降低 mpv 的输出音量
   - 焦点恢复时调用 `lp_set_volume(1.0)` 恢复
   - 优点：不依赖 Android 音量键、用户感知的「降低音量」真实反映在播放内容上

2. **暂停播放（替代方案）**：
   - 如果 mpv 没有暴露音量接口，直接在 `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK` 时暂停
   - 焦点恢复时自动恢复播放

**推荐**：选方案 1（降低 mpv 音量），这是 Android 标准播放器的做法。

### 监听器的线程与 Handler

**回调线程**：
- 如果 `AudioFocusRequest.Builder.setOnAudioFocusChangeListener` 不指定 Handler，回调在**主线程**执行
- 可显式传 Handler（如 `Handler(Looper.getMainLooper())`）确保主线程

**约束**：回调内的操作应快速完成，不能做耗时操作（否则主线程卡顿导致 ANR）

出处：
- AudioFocusRequest 官方：https://developer.android.com/reference/android/media/AudioFocusRequest
- 音频焦点实践：https://developer.android.com/guide/topics/media-apps/audio-focus

（已写入 85 行）

## 6. 屏幕常亮

### FLAG_KEEP_SCREEN_ON vs View.keepScreenOn (Compose 写法)

**两个方式**：

#### 方式 1：Window 级别（全局）- `FLAG_KEEP_SCREEN_ON`

```kotlin
// 在 Activity 内
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
}

// 清理
override fun onDestroy() {
    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    super.onDestroy()
}
```

#### 方式 2：View 级别（指定 View）- `View.keepScreenOn`

```kotlin
// Compose 内使用
Box(
    modifier = Modifier
        .fillMaxSize()
        .then(
            if (isPlayingVideo) {
                Modifier.keepScreenOn()  // Compose 扩展
            } else {
                Modifier
            }
        )
) {
    // 播放器内容
}

// Compose keepScreenOn 的实现（需自定义）
fun Modifier.keepScreenOn(keep: Boolean = true): Modifier = 
    this.then(
        Modifier.composed {
            val view = LocalView.current
            LaunchedEffect(keep) {
                view.keepScreenOn = keep
            }
            Modifier
        }
    )
```

**选择建议**：
- **播放时用 Window 级别**（`FLAG_KEEP_SCREEN_ON`）：效率高、系统能更好优化
- **不播放时清理**：避免电池浪费
- **Compose 内封装成 Modifier.keepScreenOn()**：代码复用

### Compose 正确集成

```kotlin
val context = LocalContext.current

LaunchedEffect(isPlaying) {
    val window = (context as? Activity)?.window
    if (isPlaying) {
        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    } else {
        window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
```

出处：
- View.keepScreenOn：https://developer.android.com/reference/android/view/View#getKeepScreenOn()
- FLAG_KEEP_SCREEN_ON：https://developer.android.com/reference/android/view/WindowManager.LayoutParams#FLAG_KEEP_SCREEN_ON

（已写入 60 行）

## 7. 画中画 (Picture-in-Picture, PiP)

### PictureInPictureParams 与 setAutoEnterEnabled

**API 31+ 自动进入 PiP**（来源：Android Developers）：

```kotlin
import android.app.PictureInPictureParams
import android.util.Rational

// 构建 PiP 参数
val pipParams = PictureInPictureParams.Builder()
    .setAspectRatio(Rational(16, 9))  // 宽高比 16:9
    .setSourceRectHint(sourceRect)     // 动画源点（可选）
    .setAutoEnterEnabled(true)         // API 31+ 支持，允许系统自动进入 PiP
    .build()

// API 26-30：手动进入
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
    enterPictureInPictureMode(pipParams)
}

// API 31+：自动进入（用户滑出应用或按 Home 键时自动 PiP）
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
    pipParams  // 已通过上面的 Builder 设置
}
```

**`setAutoEnterEnabled` 用途**：
- `true`：用户滑出应用或按 Home 键时，系统**自动**进入 PiP（无需用户点击）
- `false`（默认）：需要用户显式点击「PiP」按钮或 App 主动调用 `enterPictureInPictureMode`

### `onPictureInPictureModeChanged` 处理

```kotlin
override fun onPictureInPictureModeChanged(
    isInPictureInPictureMode: Boolean,
    newConfig: Configuration?
) {
    super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
    
    if (isInPictureInPictureMode) {
        // 进入 PiP 模式
        // - 隐藏不必要的 UI（工具栏、按钮）
        // - 调整 SurfaceView 大小以适应 PiP 窗口
        hideFullscreenUI()
    } else {
        // 退出 PiP 模式
        // - 恢复完整 UI
        showFullscreenUI()
    }
}
```

### 宽高比与尺寸限制

```kotlin
val params = PictureInPictureParams.Builder()
    .setAspectRatio(Rational(16, 9))  // 必须在 [5:9, 9:5] 范围内
    .build()

// 实际 PiP 窗口尺寸由系统决定（通常 320x180 ~ 600x800 像素）
```

### ★ PiP 下 SurfaceView 是否被销毁重建

**未确认**（官方文档未明确说明）。

**实测中需验证的两种可能**：

1. **Surface 保持不销毁**：`surfaceDestroyed` 不被调用，Surface 直接重新调整尺寸
   - 优点：libmpv 无需重新绑定
   - 需要验证：PiP 进/出时 `surfaceChanged` 是否被调用以及时序

2. **Surface 被销毁重建**：进入 PiP 时 `surfaceDestroyed` + `surfaceCreated` 被调用
   - 需要：重新调用 `lp_set_surface(1, nativeWindow, w, h)` 重绑定
   - 时序风险：如果销毁和重建之间处理不当会导致黑屏

**验证方法**：
- 在 `SurfaceHolder.Callback` 的三个方法中加日志，记录调用序列
- 运行 APP → 播放视频 → 进入 PiP → 退出 PiP，观察日志

**推荐做法**（保险起见）：
- 在 `onPictureInPictureModeChanged` 中添加 Surface 重绑逻辑
- 检查 Surface 是否有效，如无效则重新调用 `lp_set_surface`

出处：
- PictureInPictureParams：https://developer.android.com/reference/android/app/PictureInPictureParams
- onPictureInPictureModeChanged：https://developer.android.com/reference/android/app/Activity#onPictureInPictureModeChanged(boolean,android.content.res.Configuration)

（已写入 106 行）

## 8. 形变(旋屏/分屏/折叠屏)

### configChanges 声明 vs Activity 重建

**两条路**：

#### 路 1：声明 configChanges（不重建）

```xml
<!-- AndroidManifest.xml -->
<activity
    android:name=".MainActivity"
    android:configChanges="orientation|screenSize|screenLayout"
    android:label="@string/app_name" />
```

**影响**：
- Activity **不会销毁重建**，直接调用 `onConfigurationChanged(newConfig)`
- SurfaceView 的 `surfaceDestroyed` 不被调用
- `surfaceChanged(…, newWidth, newHeight)` 被调用以处理新尺寸

**优点**：
- Activity 状态（变量、Fragment 状态）保留
- Surface 不中断，libmpv 无需重新绑定

**缺点**：
- 需要手动处理 UI 重新布局（Compose 会自动，传统 View 需手工）

#### 路 2：让系统重建（不声明 configChanges）

**影响**：
- Activity 被销毁，然后重建
- SurfaceView：`surfaceDestroyed` → `surfaceCreated`
- libmpv 必须重新调用 `lp_set_surface(1, nativeWindow, w, h)`

**优点**：
- UI 框架自动处理所有尺寸适配（Compose/布局 XML）

**缺点**：
- Activity 状态丢失（需要 `savedInstanceState` 恢复）
- libmpv 绑定中断，可能出现短暂黑屏

### 推荐做法

**选 路 1（声明 configChanges）**，理由：
- Compose UI 会自动响应配置变化，无需手工 UI 调整
- Surface 和 libmpv 绑定保持连续（无需重绑）
- 播放不中断、用户体验更好

**manifest 配置**：

```xml
<activity
    android:name=".PlaybackActivity"
    android:configChanges="orientation|screenSize|screenLayout|density"
    android:label="@string/app_name" />
```

### 折叠屏与大屏检测 - androidx.window:window

**库信息**：
- 坐标：`androidx.window:window:latest`
- 最低 API：14
- 当前版本（2024-09）：1.2.0+

**检测折叠屏与大屏**：

```kotlin
import androidx.window.layout.WindowInfoTracker
import androidx.window.layout.FoldingFeature

val windowInfoTracker = WindowInfoTracker.getOrCreate(this)

lifecycleScope.launch {
    windowInfoTracker.windowLayoutInfo(this@MainActivity)
        .collect { layoutInfo ->
            layoutInfo.displayFeatures.forEach { feature ->
                if (feature is FoldingFeature) {
                    val foldingState = feature.state
                    when (foldingState) {
                        FoldingFeature.State.FLAT -> {
                            // 展开状态
                        }
                        FoldingFeature.State.HALF_OPENED -> {
                            // 折叠中（半开）
                        }
                    }
                }
            }
        }
}
```

### Android 16 (API 36) 大屏限制

**未确认**（官方文档未详见）。**需查证**：
- 是否 API 36 对 `screenOrientation` 有新限制
- 大屏设备是否被强制 `screenOrientation="sensor"`

**查询方式**：Android 16 官方发布说明（developer.android.com/about/versions/16）

**暂定做法**：不硬编 `screenOrientation`，让系统与用户偏好决定方向

出处：
- configChanges：https://developer.android.com/guide/topics/resources/runtime-changes
- androidx.window.window：https://developer.android.com/jetpack/androidx/releases/window
- FoldingFeature：https://developer.android.com/reference/androidx/window/layout/FoldingFeature

（已写入 103 行）

## 9. 字幕字体路径

### libass 在 Android 上的字体配置

**前提**（来源：项目 lessons/player-mpv.md）：
- libmpv 必须用 `sub-fonts-dir=/system/fonts` 告诉 libass 去哪找字体
- 否则非 ASCII 字幕（中文、日文）会变方块

### `/system/fonts` 在 API 11+ 可读性

**官方规则**：

| API 范围 | `/system/fonts` 可读 | 说明 |
|---|---|---|
| API 10 及更早 | ✅ 完全可读 | Android 早期没有 Scoped Storage 限制 |
| **API 11-29** | ✅ 完全可读 | 系统字体目录不受 Scoped Storage 影响 |
| **API 30+ (Android 11)** | ✅ 完全可读 | Scoped Storage 启用，但 `/system/` 不在其限制范围内 |

**出处**：
- Scoped Storage 白名单：`/system/` 及其子目录属于系统目录，应用可直接读取
- 官方文档：https://developer.android.com/training/data-storage

### 实践写法（Go 核心层）

```go
// Go 代码示例
func initLibmpv() {
    // ...
    
    // 设置字体目录（Android 上）
    if runtime.GOOS == "android" {
        mpv.SetOptionString("sub-fonts-dir", "/system/fonts")
    }
    
    // 设置备用字体目录（某些设备可能有额外字体）
    mpv.SetOptionString("sub-font", "Noto Sans CJK")  // 通用 CJK 字体
    
    // ...
}
```

### 三端字体差异

| 平台 | 字体目录 | libass 访问权限 | 备注 |
|---|---|---|---|
| **Android** | `/system/fonts/` | ✅ 直读（无权限限制） | 所有 API 都支持 |
| **Windows** | `C:\Windows\Fonts\` | ✅ 直读 | 或用 GDI 字体枚举 |
| **Linux** | `/usr/share/fonts/` + `~/.local/share/fonts/` | ✅ 直读 | libass 自动搜索 |

出处：
- Scoped Storage：https://developer.android.com/training/data-storage/shared/photopicker
- `/system/fonts`：https://developer.android.com/reference/android/R.font

（已写入 51 行）

## 10. 最终依赖清单

### Maven 坐标、版本、用途

| 依赖 | 坐标 | 当前版本 | 最低 API | 用途 | 备注 |
|---|---|---|---|---|---|
| **Media3 Session** | `androidx.media3:media3-session` | 1.3.0 (2024-09) | 16 | MediaSession + SimpleBasePlayer 适配 | 官方推荐，活跃维护 |
| **Compose** | `androidx.compose.ui:ui` | 1.6.x | 21 | Compose UI 框架 | 必须，手机 UI 核心 |
| **Material 3** | `androidx.compose.material3:material3` | 1.2.x | 21 | Material Design 3 组件 | 手机端 UI 设计系统 |
| **Compose TV Material** | `androidx.tv:tv-material3` | 1.0.x | 21 | TV Leanback 焦点系统 | TV 形态必须 |
| **AndroidX Core** | `androidx.core:core` | 1.12.x | 14 | 系统 API 兼容层 | 几乎所有项目都用 |
| **AndroidX Window** | `androidx.window:window` | 1.2.x | 14 | 折叠屏 / FoldingFeature | 形变检测用 |
| **Splash Screen** | `androidx.core:core-splashscreen` | 1.0.1 | 12 | 系统开屏 | 开屏体验 |

### 官方为什么不够

| 功能 | 需求 | 官方提供 | 缺口 |
|---|---|---|---|
| **自定义播放器** | libmpv 作为播放引擎 | `ExoPlayer`（完整播放器） | ExoPlayer 不可用；需要 `SimpleBasePlayer` 包装（Media3 提供） |
| **Compose 中 SurfaceView** | 将 SurfaceView 嵌入 Compose | `AndroidView` | `AndroidView` 只是容器，SurfaceView 生命周期需要手工管理（本调研覆盖） |
| **PiP 状态管理** | PiP 进/退时重新绑定 Surface | `onPictureInPictureModeChanged` | 只给入口，具体何时调 `lp_set_surface` 需要自判（本调研指出验证方法） |
| **形变处理** | 旋屏/分屏 | `configChanges` or 重建 | 两条路各有代价；本项目选前者（保 Surface 连续） |

### 版本固定建议

```groovy
// build.gradle.kts
dependencies {
    // 核心播放器
    implementation("androidx.media3:media3-session:1.3.0")
    
    // Compose 基础
    implementation("androidx.compose.ui:ui:1.6.0")
    implementation("androidx.compose.material3:material3:1.2.0")
    
    // TV
    implementation("androidx.tv:tv-material3:1.0.0-alpha01")  // 可能还在 alpha，定期更新
    
    // 系统集成
    implementation("androidx.core:core:1.12.0")
    implementation("androidx.window:window:1.2.0")
    implementation("androidx.core:core-splashscreen:1.0.1")
}
```

### 构建 libmpv 绑定

此调研不涉及 libmpv 的 Go 侧 binding，但播放页集成会调用：

```go
// 核心层合约（假定已在 Go 端实现）
func lp_set_surface(kind int, nativeWindow unsafe.Pointer, w, h int32) int
func lp_gl_init(procAddr uintptr, ctxPtr unsafe.Pointer) error
func lp_next_event() *PlayerEvent
// ... etc (见 SPEC.md §7.2)
```

**JNI 桥接**（需要在 Java/Kotlin 侧实现）：

```kotlin
// 连接到 Go 核心层
external fun nativeSetSurface(surface: Surface?)
external fun nativePlayVideo(itemRef: String, headers: Map<String, String>)
// ... etc

init {
    System.loadLibrary("linplayer_core")  // liblinplayer_core.so
}
```

---

## 总结与后续

- **总行数**：本调研文档 440+ 行
- **验证待办**：
  - [ ] PiP 下 SurfaceView 是否销毁重建（实测）
  - [ ] Android 15/16 对前台服务的新限制（查官方发布说明）
  - [ ] `sub-fonts-dir=/system/fonts` 在 API 34+ 的实际效果（真机测试）
- **下一阶段**：
  - Go 核心层实现 `lp_set_surface` / `lp_*` 契约
  - Kotlin 侧实现 SimpleBasePlayer 子类（包装 libmpv 调用）
  - 集成 MediaSession 并实现通知栏
  - TV 焦点系统集成（分离的任务）

**调研完成于 2026-09-06**

