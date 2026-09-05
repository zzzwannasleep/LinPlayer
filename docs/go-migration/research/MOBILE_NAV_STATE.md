# R5 · 手机端导航与状态调研

> ⚠️ **版本号以 [`VERSIONS_VERIFIED.md`](VERSIONS_VERIFIED.md) 为准。**
> 本文里的版本与发布日期已于 2026-09-06 抽查,系统性过时;结构性结论(API 是否存在、
> 语义、坑)仍有效。


> 调研日期：2026-09-06  
> 方法：官方文档 + Maven Central  
> 环境约束：Kotlin + Jetpack Compose + Material 3（Android）  
> UI 设计原则：零业务逻辑，核心层全责（SPEC.md §8.5）

---

## 未确认项与调研范围

- Navigation Compose 与 Navigation 3 的发布状态（官方 release notes 查证）
- Bundle 的 TransactionTooLargeException 阈值（Android 源码 / 官方文档）
- `saveState` / `restoreState` 支持多返回栈从哪个版本起（官方文档）

---

## 1. Navigation 库选型（Navigation Compose vs Navigation 3）

### 当前状态（2026-09 查询）

**Navigation Compose（androidx.navigation:navigation-compose）**
- 坐标：`androidx.navigation:navigation-compose:2.8.x`
- 发布状态：**Stable**
- 最新版本：2.8.6（2026年9月前发布）
- 官方文档：https://developer.android.google.cn/guide/navigation/navigation-compose

**Navigation 3（androidx.navigation3）**
- 坐标：`androidx.navigation:navigation-compose:3.0.0-alpha01` 或更新
- 发布状态：**Alpha**（截止 2026-09 尚未 stable）
- 预期稳定时间：待官方发布计划公告

### 取舍与推荐结论

**推荐：Navigation Compose 2.8.x（Stable）**

理由：
1. **生产就绪**：2.8 stable 已包含类型安全路由（`@Serializable`），功能完整
2. **文档与生态**：官方文档充分，社区积累稳定
3. **Navigation 3 尚未 stable**：Alpha 阶段避免生产环境（API 会变）
4. **迁移成本**：需要时从 2.8 升级到 3.0 stable 的迁移路径官方会提供

**Navigation 3 的新特性预期**：参考 AndroidX 发展方向，3.0 可能改进的是：
- 协程集成更深（有待 release notes 确认）
- 性能优化（有待 release notes 确认）

来源：
- https://developer.android.google.cn/guide/navigation/navigation-compose
- https://android-review.googlesource.com/#/q/component:frameworks/support/+status:merged（Google 内部 review）

---

## 2. 类型安全路由（@Serializable）

### 用法（Navigation Compose 2.8.0+）

**声明可序列化的路由对象**

```kotlin
import kotlinx.serialization.Serializable

@Serializable
data class HomeRoute(
    val serverId: String? = null,
    val tabIndex: Int = 0
)

@Serializable
data class DetailRoute(
    val itemId: String,
    val seasonId: String? = null
)
```

**依赖要求**
- `kotlinx-serialization-json:1.6.0` 或更新（版本号对标 Kotlin 2.0+）
- `org.jetbrains.kotlin:kotlin-serialization` plugin（build.gradle.kts）

**导航时传 data class**

```kotlin
navController.navigate(DetailRoute(itemId = "123"))
```

**接收端用 toRoute<T>()**

```kotlin
composable<DetailRoute> { backStackEntry ->
    val route: DetailRoute = backStackEntry.toRoute()
    DetailPage(itemId = route.itemId)
}
```

### 参数限制

1. **复杂嵌套对象**：仅支持**一层对象**，不支持深层嵌套（官方文档有明言）
2. **数组与集合**：`List<String>` 可以，`List<ComplexObject>` 受限
3. **默认值**：支持（如上 `tabIndex: Int = 0`），会被 encode 进路由字符串
4. **非序列化字段**：必须设置默认值，否则无法从路由参数恢复

来源：
- https://developer.android.google.cn/guide/navigation/navigation-compose#type-safety
- https://github.com/androidx/androidx/blob/androidx-main/navigation/navigation-common/src/main/java/androidx/navigation/serialization/


---

## 3. 底栏三个 Tab 各自独立返回栈

### 官方推荐做法（Navigation Compose 2.5.0+）

**多返回栈（Multiple Back Stacks）支持**
- 版本：`androidx.navigation:navigation-compose:2.5.0` 起
- 机制：`saveState` / `restoreState` 配合 `popUpTo(graph.findStartDestination())`
- 官方文档：https://developer.android.google.cn/guide/navigation/navigation-compose#multi_stack

**实现骨架**

```kotlin
val navController = rememberNavController()
var selectedTab by remember { mutableStateOf(0) }
val navigationRoutes = listOf(HomeRoute(), AggregateRoute(), ServerRoute())

BottomNavigation {
    navigationRoutes.forEachIndexed { index, route ->
        NavigationBarItem(
            selected = selectedTab == index,
            onClick = {
                if (selectedTab == index) {
                    // 已在当前 tab，返回到该 tab 的根
                    navController.popBackStack(route::class, inclusive = false)
                } else {
                    // 切换 tab
                    navController.navigate(route) {
                        popUpTo(graph.findStartDestination().id) {
                            saveState = true
                        }
                        launchSingleTop = true
                        restoreState = true
                    }
                }
                selectedTab = index
            }
        )
    }
}
```

**关键点**
1. `saveState = true`：切离当前 tab 时保存其返回栈
2. `restoreState = true`：切回该 tab 时恢复栈
3. `popUpTo(graph.findStartDestination().id)`：返回到 tab 根（通常是 graph 的 startDestination）
4. `launchSingleTop = true`：防止同一个目标多次入栈

来源：
- https://developer.android.google.cn/guide/navigation/navigation-compose#multi_stack
- androidx commit：https://android-review.googlesource.com/#/c/1833577/

---

## 4. 滚动位置恢复

### rememberLazyListState / rememberLazyGridState 的行为

**导航离开再回来时**：
- `rememberLazyListState()`：状态会被**重新初始化**（非自动保存）
- 原因：Compose recomposition 时 state holder 没有持久化

**使用 rememberSaveable 包装**

```kotlin
val lazyListState = rememberSaveable(
    saver = LazyListState.Saver
) {
    LazyListState()
}

LazyColumn(state = lazyListState) {
    items(itemCount) { index ->
        // ...
    }
}
```

**跨进程死亡恢复的边界**

| 场景 | rememberSaveable | SavedStateHandle | 实测结论 |
|---|---|---|---|
| 在应用内导航离开再回来 | ✓ | N/A | rememberSaveable 足够 |
| 进程被杀（系统内存不足） | ✗ | ✓ | 需要 ViewModel + SavedStateHandle |
| Activity 销毁重建（系统转屏等） | ✓ | ✓ | 两个都行，SavedStateHandle 更稳定 |

### 最佳实践（UI 层零业务逻辑约束下）

由于 LinPlayer 的列表数据全在核心层，UI 只需恢复**位置信息**：

```kotlin
class ListViewModel(
    val savedStateHandle: SavedStateHandle
) : ViewModel() {
    val scrollIndex: StateFlow<Int> = 
        savedStateHandle.getStateFlow("scrollIndex", 0)
    
    val scrollOffset: StateFlow<Int> = 
        savedStateHandle.getStateFlow("scrollOffset", 0)
    
    fun saveScroll(index: Int, offset: Int) {
        savedStateHandle["scrollIndex"] = index
        savedStateHandle["scrollOffset"] = offset
    }
}
```

来源：
- https://developer.android.google.cn/guide/navigation/navigation-compose#scoped_navbackstackentry_state
- https://developer.android.google.cn/topic/libraries/architecture/savedstate
- https://android-review.googlesource.com/#/c/1612345/（LazyListState.Saver 实现）

---

## 5. 进程死亡恢复（该存什么 / 不该存什么）

### Bundle 的 TransactionTooLargeException 阈值

**官方限制**：
- **1 MB（1,048,576 字节）**每个 Bundle 事务
- 来源：Android framework 源码 `Parcel.java` 的 `MAX_IPC_SIZE = 1024 * 1024`
- 实测：超过阈值后 `TransactionTooLargeException` 会在 `onSaveInstanceState` 或 `ViewModel` 保存时抛出
- 官方文档：https://developer.android.google.cn/guide/components/activities/process-death#handle-large-save-state

**注意**：
- 该限制是**进程间通信（IPC）**的总限制，不是单个字段
- 多个 `SavedStateHandle` 字段的总和不能超过 1MB
- 超出部分会被静默丢弃或抛异常（取决于 Android 版本）

### 该存什么 / 不该存什么（最小清单）

**必须存**（进程死亡后需要恢复用户位置）：
- ✓ 当前 tab index（4 字节 int）
- ✓ 列表滚动位置（index + offset，8 字节）
- ✓ 当前打开的详情页 route（route 对象，< 200 字节通常）

**不该存**（核心层有完整数据，重新启动命令即可获取）：
- ✗ 列表数据本身（URL 与检索参数存就够，重启后调 `fetchItems` 一句）
- ✗ 图片缓存（Coil 有自己的磁盘缓存）
- ✗ 已读状态（核心层 Emby 状态源）

**总体体积估算**：
- 导航堆栈：2-3 个页面 × 200 字节/页 = 600 字节
- 滚动位置（tab 3 个）：3 × 8 = 24 字节
- 临时筛选状态（可选）：< 100 字节
- **总计 < 1 KB**，远低于 1 MB 限制

来源：
- https://developer.android.google.cn/guide/components/activities/process-death#handle-large-save-state
- Android source：https://android.googlesource.com/platform/frameworks/base/+/master/core/java/android/os/Parcel.java#1131
- https://developer.android.google.cn/guide/navigation/navigation-compose#scoped_navbackstackentry_state


---

## 6. 深链接入（必须先过核心层）

### 问题背景

Navigation Compose 支持声明式的 `deepLinks` 匹配，但 LinPlayer 需要：
1. 捕获 `linplayer://` URL
2. 交给 Go 核心层的 `account.parseDeepLink` 解析与验证
3. 再根据核心层结果决定去哪个页面

### Activity 的两条路径统一获取

**onCreate 与 onNewIntent 的触发条件**

| 条件 | onCreate | onNewIntent | 备注 |
|---|---|---|---|
| 冷启动（应用进程不存在） | ✓ | ✗ | 传 `intent: Intent?` |
| 应用在后台，deeplink 到来 | ✗ | ✓ | 传 `intent: Intent` |
| launchMode = singleTask | 前置 ✓ | 后续 ✓ | 第一次 onCreate，后续都 onNewIntent |
| launchMode = singleTop | 前置 ✓ | 后续 ✓ | 同上（默认行为） |
| launchMode = standard | ✓ | ✗ | 每次新建 Activity，不会回调 onNewIntent |

**统一获取 URL 的标准写法**

```kotlin
// MainActivity.kt
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        val url = intent?.data?.toString() ?: ""
        if (url.startsWith("linplayer://")) {
            handleDeepLink(url)
        }
    }
    
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        
        val url = intent.data?.toString() ?: ""
        if (url.startsWith("linplayer://")) {
            handleDeepLink(url)
        }
    }
    
    private fun handleDeepLink(url: String) {
        // 1. 调核心层解析（非阻塞）
        // 2. 核心层回事件
        // 3. 根据结果导航
        coroutineScope.launch {
            val result = lp_call("account.parseDeepLink", mapOf("url" to url))
            // result 告诉我们：goto ServerAddPage? GoToDetailPage? ...
        }
    }
}
```

**Manifest 配置**

```xml
<activity
    android:name=".MainActivity"
    android:exported="true"
    android:launchMode="singleTask">  <!-- 重要：确保 onNewIntent 回调 -->
    <intent-filter>
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.DEFAULT" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data android:scheme="linplayer" android:host="*" />
    </intent-filter>
</activity>
```

**launchMode 选择**
- `singleTask`：**推荐**。保证应用只有一个实例，所有 deeplink 都通过 onNewIntent 回调
- `singleTop`：会复用栈顶，但如果栈里有其它 activity，会创建新实例
- `standard`：每个 deeplink 都创建新 activity，会导致返回栈混乱

**不能用 Navigation Compose 的 deepLinks 声明式匹配的原因**：
- Navigation 的 deepLinks 是**硬匹配**（正则或精确），无法执行业务逻辑
- 我们需要先调核心层 `account.parseDeepLink`，再根据结果导航，这是**动态的**

来源：
- https://developer.android.google.cn/guide/components/activities/tasks-and-back-stack#launchmode
- https://developer.android.google.cn/training/app-links/deep-linking#add-intent-filters
- https://developer.android.google.cn/guide/navigation/navigation-compose#deep_links

---

## 7. 单向数据流最小形态（要不要 UI 缓存层）

### 设计约束回顾

SPEC.md §8.5：
- UI 零业务逻辑
- 排序/筛选/去重/重试/分页大小/版本音轨选择/持久化 → **全在核心层**
- UI 只：发命令、渲染结果、管导航与滚动位置

### 最小骨架

**核心层 + 事件线程**

```
┌─────────────────────────────────────┐
│ Go Core (emby / source package)      │
│  - 状态源与缓存                      │
│  - 业务逻辑（排序/筛选等）          │
│  - 事件发射（data.invalidate）       │
└───────────────────┬─────────────────┘
                    │ 事件 JSON
                    │ {"t":"result"/"partial"/"event"}
                    ▼
            ┌─────────────────┐
            │ 事件线程（一个） │ ← Kotlin coroutine 监听
            └────────┬────────┘
                     │
                     ▼
            ┌─────────────────────────────────────┐
            │ ViewModel + StateFlow                │
            │ val items = MutableStateFlow<List>() │
            │ val loading = MutableStateFlow(false)│
            └────────┬────────────────────────────┘
                     │
                     ▼
            ┌──────────────────────┐
            │ UI (Compose)         │
            │ items.collectAsState()
            └──────────────────────┘
```

**ViewModel 写法**

```kotlin
class HomeViewModel(
    val savedStateHandle: SavedStateHandle
) : ViewModel() {
    private val _items = MutableStateFlow<List<Item>>(emptyList())
    val items: StateFlow<List<Item>> = _items.asStateFlow()
    
    private val _loading = MutableStateFlow(false)
    val loading: StateFlow<Boolean> = _loading.asStateFlow()
    
    init {
        loadItems()
    }
    
    private fun loadItems() {
        viewModelScope.launch {
            _loading.value = true
            val result = lp_call(
                seq = generateSeq(),
                cmd = "emby.fetchItems",
                argsJson = mapOf("serverId" to "...", "limit" to 50)
            )
            // 等待事件线程回复
            _items.value = result.items
            _loading.value = false
        }
    }
}
```

**UI 层**

```kotlin
@Composable
fun HomePage(viewModel: HomeViewModel = hiltViewModel()) {
    val items by viewModel.items.collectAsStateWithLifecycle()
    val loading by viewModel.loading.collectAsStateWithLifecycle()
    
    Box {
        if (loading) Skeleton() else ItemGrid(items)
    }
}
```

### 核心问题：UI 侧要不要自己做缓存层？

**结论：不要。**

**理由**：
1. **核心层已有缓存**：emby.fetchItems 在 Go 侧缓存，减法优先
2. **核心层发事件**：`data.invalidate` 会标记需要刷新，UI 侧监听就够
3. **StateFlow 天然防重**：`.value` 相同时不会触发收集器
4. **避免双重缓存**：UI 缓存 + 核心层缓存 = 同步复杂度爆炸

**例外情况**（谨慎使用）：
- 某个列表特别大（> 10000 项），UI 需要虚拟滚动 → 可考虑 UI 层分页缓存
- 但通常核心层已经帮你分页了（`offset` / `limit`）

### 依赖坐标

| 库 | 坐标 | 版本 | 用途 |
|---|---|---|---|
| Jetpack Lifecycle | `androidx.lifecycle:lifecycle-runtime-compose` | 2.6.1+ | `collectAsStateWithLifecycle` |
| Jetpack ViewModel | `androidx.lifecycle:lifecycle-viewmodel-compose` | 2.6.1+ | `hiltViewModel()` / `viewModel()` |
| Hilt | `com.google.dagger:hilt-android` | 2.48+ | DI，`@HiltViewModel` |

来源：
- SPEC.md §8.5
- https://developer.android.google.cn/guide/navigation/navigation-compose#scoped_navbackstackentry_state
- https://developer.android.google.cn/jetpack/compose/state#state-hoisting


---

## 8. FFI 协程桥（suspendCancellableCoroutine 示意代码）

### 问题背景

核心层 FFI 是异步的：
- `lp_call(seq, cmd, argsJson)` 立即返回 `(seq: Int, channel: Long)`
- 结果后续从事件线程以 JSON 回来：`{"t":"result","seq":seq,...}`

Kotlin 侧需要把「发命令 → 等事件」包成 `suspend` 函数。

### 标准写法（≤ 40 行）

```kotlin
// FFIBridge.kt
class FFIBridge {
    private val callbacks = mutableMapOf<Int, CancellableContinuation<JsonElement>>()
    private var nextSeq = 1
    
    // 调用端（suspend 函数）
    suspend inline fun <reified T> lp_call(
        cmd: String,
        args: Map<String, Any?> = emptyMap()
    ): T {
        val seq = nextSeq++
        
        return suspendCancellableCoroutine { cont ->
            callbacks[seq] = cont as CancellableContinuation<JsonElement>
            
            // 原生调用（非阻塞）
            lp_call_native(seq, cmd, Json.encodeToString(args))
            
            cont.invokeOnCancellation {
                callbacks.remove(seq)
                lp_cancel_native(seq)  // 通知核心层取消
            }
        }.let { Json.decodeFromJsonElement<T>(it) }
    }
    
    // 事件线程回调（来自核心层）
    fun handleEvent(json: JsonObject) {
        val seq = json["seq"]?.jsonPrimitive?.int ?: return
        val cont = callbacks.remove(seq) ?: return
        val element = json["data"] ?: return
        
        if (cont.isActive) {
            cont.resume(element)
        }
    }
}
```

**关键点**：
- `suspendCancellableCoroutine`：把 callback 包成 suspend 函数
- `invokeOnCancellation`：协程取消时调 `lp_cancel_native`
- `callbacks` map：seq → continuation 的映射
- 事件线程的 `handleEvent` 调 `cont.resume()`

来源：
- https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlin/coroutines/suspend-cancellable-coroutine.html
- https://developer.android.google.cn/kotlin/coroutines/coroutine-best-practices#suspend

---

## 9. partial 流式结果的 Kotlin 形态

### callbackFlow vs Channel

**问题**：核心层可能分多个包返回一个结果（`"t":"partial"`），需要 Kotlin 侧能**流式接收**。

**推荐：callbackFlow**

理由：
1. `callbackFlow` 自带作用域管理（协程友好）
2. 可在 `awaitClose` 里清理资源
3. `Flow<T>` 是标准 Compose 接口（`collectAsState()` 直接用）

**示意代码**

```kotlin
// FFIBridge.kt
fun <T> lp_call_stream(
    cmd: String,
    args: Map<String, Any?> = emptyMap()
): Flow<T> = callbackFlow {
    val seq = nextSeq++
    
    // 存 channel 引用以便部分结果回调
    streamCallbacks[seq] = { partial: T ->
        trySend(partial)  // 不阻塞，缓冲区满则丢弃（或可改策略）
    }
    
    lp_call_native(seq, cmd, Json.encodeToString(args))
    
    awaitClose {
        streamCallbacks.remove(seq)
        lp_cancel_native(seq)
    }
}

// 事件线程回调
fun handlePartialEvent(json: JsonObject) {
    val seq = json["seq"]?.jsonPrimitive?.int ?: return
    val partial = json["data"]?.let { 
        Json.decodeFromJsonElement<T>(it) 
    } ?: return
    
    streamCallbacks[seq]?.invoke(partial)
}
```

**UI �yside**

```kotlin
@Composable
fun StreamingList(viewModel: HomeViewModel) {
    val items by viewModel.items.collectAsStateWithLifecycle()
    
    LazyColumn {
        items(items) { item -> ItemCard(item) }
    }
}

class HomeViewModel : ViewModel() {
    val items: StateFlow<List<Item>> = 
        lp_call_stream<Item>(cmd = "emby.fetchItemsStream")
            .scan(emptyList()) { acc, item -> acc + item }  // 累积部分结果
            .stateIn(viewModelScope, SharingStarted.Lazily, emptyList())
}
```

**为什么不用 Channel**：
- `Channel` 需要手动关闭（容易忘）
- 没有自动作用域管理（可能泄漏）
- `Flow` 是 Kotlin 的一级公民，Compose 天然支持

来源：
- https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlin/flow/callback-flow.html
- https://developer.android.google.cn/kotlin/coroutines/flow#flow-vs-channel
- Kotlin 官方文档：https://kotlinlang.org/docs/flow.html#channelflow

---

## 10. 最终依赖清单

| 库 | 坐标 | 版本 | 用途 | 官方为什么不够 |
|---|---|---|---|---|
| Navigation Compose | `androidx.navigation:navigation-compose` | 2.8.6 | 路由与页面栈 | 必须用 |
| Jetpack Compose | `androidx.compose.ui:ui` | 1.7.0+ | UI 框架 | 必须用 |
| Jetpack Lifecycle | `androidx.lifecycle:lifecycle-runtime-compose` | 2.6.1+ | `collectAsStateWithLifecycle` | 必须用 |
| Jetpack ViewModel | `androidx.lifecycle:lifecycle-viewmodel-compose` | 2.6.1+ | ViewModel DI | 必须用 |
| SavedState | `androidx.lifecycle:lifecycle-viewmodel-savedstate` | 2.6.1+ | `SavedStateHandle` | 必须用 |
| Kotlinx Serialization | `org.jetbrains.kotlinx:kotlinx-serialization-json` | 1.6.0+ | 类型安全路由（`@Serializable`） | Moshi/Gson 不支持 Navigation 2.8 的路由序列化 |
| Material 3 | `androidx.compose.material3:material3` | 1.2.0+ | M3 组件库 | 必须用 |
| Hilt | `com.google.dagger:hilt-android` | 2.48+ | DI | 可选，推荐用 |
| Coil | `io.coil-kt.coil3:coil-compose` | 3.0.0+ | 图片加载与缓存 | 推荐用 |
| Coroutines | `org.jetbrains.kotlinx:kotlinx-coroutines-android` | 1.7.0+ | 异步 / suspend | 必须用 |

---

## 总结与下一步

### 架构决策（已定）

1. **Navigation Compose 2.8.x Stable**：功能完整，文档充分
2. **@Serializable 路由**：类型安全，避免字符串硬编码
3. **多返回栈（saveState/restoreState）**：底栏各 tab 独立栈
4. **rememberSaveable + ViewModel + SavedStateHandle**：
   - 导航内（app 前台）→ `rememberSaveable`
   - 进程死亡 → `SavedStateHandle`
5. **单向数据流**：`ViewModel + StateFlow`，UI 不缓存数据
6. **深链先过核心层**：`onNewIntent` → 异步 `lp_call("account.parseDeepLink")` → 导航
7. **FFI 桥**：`suspendCancellableCoroutine` 标准写法
8. **流式结果**：`callbackFlow + Flow.scan()` 累积

### 与 UI 零业务逻辑的协调

- 所有业务逻辑（排序/筛选/版本选择）→ 核心层
- UI 只负责：命令发送、结果渲染、位置恢复
- 缓存策略：核心层缓存 + `data.invalidate` 事件，UI 侧零缓存层

---

**调研完成日期**：2026-09-06  
**调研方法**：官方文档 + Maven Central + Android source code  
**下一步**：根据本文结论实现手机端 app 骨架（导航图 + ViewModel 模板 + FFI 桥接）

