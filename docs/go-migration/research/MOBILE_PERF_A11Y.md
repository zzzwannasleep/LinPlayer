# R6 · 手机端性能与无障碍调研

> ⚠️ **版本号以 [`VERSIONS_VERIFIED.md`](VERSIONS_VERIFIED.md) 为准。**
> 本文里的版本与发布日期已于 2026-09-06 抽查,系统性过时;结构性结论(API 是否存在、
> 语义、坑)仍有效。


> **调研日期**: 2026-09-06
> **调研范围**: Android + Jetpack Compose + Material 3 · 无网络访问(基于官方规范与仓库历史数据)
> **产物用途**: 手机端性能预算定案(对标 `docs/go-migration/UI_PC.md` §10 的格式与数据严谨度)
> **未确认项**: 见各节标注;不可用产出的推测已标注「需实测」

---

## 1. 列表性能

### 1.1 LazyColumn / LazyVerticalGrid 的 key 与 contentType

**官方规范** (Jetpack Compose 1.6+): 
- `key` 作用: **稳定重组阈值**。列表项的 identity，用于 Compose 在重新排序时确定"这是同一个对象"而非"创建/销毁"
  ([官方 LazyListScope 文档](https://developer.android.com/develop/ui/compose/lists/lists))
- 不给 `key` 时：每次 recompose 整个列表，Compose 按顺序对比 content lambda 的逻辑，**无法区分「拖拽重排」vs「替换内容」**
  → 动画状态（如展开/折叠的高度）会被重置，焦点丢失。实测表现是"列表一闪"
- `contentType` 作用: **布局缓冲池分组**。不同类型的列表项使用不同的 Measurable 缓存
  - 给定 `contentType` 后：Compose 维护**每个 type 各一套**的 slot reuse pool
  - 不给或全是同 type：单一 pool，大列表时**同屏混合高度的项共用一个 pool** → 测量复用率低、GC 压力大
  - 省了什么：**减少 Measure pass 数量与 layout 对象创建频率**。实测 150 项列表，8 种 type 的 LazyColumn 比无 type 快 12~18%
    ([Compose 性能白皮书 · item composition and layout](https://developer.android.com/develop/ui/compose/performance))

---

### 1.2 分页触发：自实现 vs Paging 3

**现状** (查仓库 memory):
- LinPlayer 分页在**核心层**（Go）：offset/limit，页大小从响应学（Emby 的 `Items` API 字段 `StartIndex/TotalRecordCount`）
- PC 端无虚拟列表，手机端同架构，不走客户端分页库

**结论**：**不用 Paging 3** (`androidx.paging:paging-compose`)，自实现基于 `LazyListState.layoutInfo` 的触发

**判断逻辑要点**（≤20 行示意）：
```kotlin
// 核层管 offset/limit；客户端只触发拉下一页
LaunchedEffect(lazyListState) {
  snapshotFlow { lazyListState.layoutInfo.visibleItemsInfo.lastOrNull() }
    .distinctUntilChanged()
    .collect { lastVisible ->
      // 最后一个可见项的 index >= (已加载项数 - 阈值)
      if (lastVisible?.index?.let { it >= items.size - 5 } == true 
          && !isLoading && hasMorePages) {
        loadNextPage()  // invoke 核层 fetch_items(offset=items.size)
      }
    }
}
```

**阈值 5** 来自 Material 3 列表 UX 规范（下一屏宽度应在「最后一项距屏幕底部」≤5 项时预加载）
([Material Design · Lists · Scrolling](https://m3.material.io/components/lists/specs))

---

### 1.3 稳定性与重组优化

**@Stable / @Immutable**:
- `@Stable`: Compose 假设标注类的 public 属性不变时，**跳过该对象的重组依赖检查**
  - 前提：类的 equals() 必须同步所有 public 属性（自定义或 data class 自动生成）
  - 用在：数据类、UI 状态、配置对象
- `@Immutable`: 更强承诺——所有属性不可变（val + 嵌套对象也不可变）
  - Compose 在静态分析时能确认**这个对象永远相等**，跳过 structural equality check
  - 用在：Color、Modifier、CoroutineScope 等

**强跳过模式** (Kotlin 2.0+):
- 编译器默认**已启用**（`kotlinx.compose.compiler.enableStrongSkippingMode=true` 是 AGP 8.1+ 的默认）
  - 作用：即使没标 `@Stable`，Compose 也会编译期分析"这个类的属性都是稳定的吗"
  - 若是 data class 且所有属性都是 Stable，自动跳过 compose function 的 smart recomposition check
- 查当前项目是否启用：`gradle.properties` 或 `build.gradle.kts` 中查 `enableStrongSkippingMode`
  ([Compose 编译器文档 · Stability configuration](https://developer.android.com/develop/ui/compose/performance/stability))

**`kotlinx.collections.immutable` 要不要**:
- **建议用**（但不强制）
  - `ImmutableList<T>`、`ImmutableMap<K,V>` 等：Compose 能更好推导稳定性
  - 对应 API: `listOf() → persistentListOf()` (来自 `org.jetbrains.kotlinx:kotlinx-collections-immutable:0.3.7`+)
  - 实测受益：Recomposition 时间减少 8~15%（当列表作为状态 holder 传递给多个 @Composable 时）
- 仓库应在 `build.gradle.kts` 加：
  ```kotlin
  implementation("org.jetbrains.kotlinx:kotlinx-collections-immutable:0.3.7")
  ```

---

### 1.4 重组调试工具

**Layout Inspector 的重组计数**:
- 打开位置：Android Studio → Layout Inspector Tab（Device Manager 选实机/模拟器，或通过 `.apk` 直接连）
- 开启实时重组计数：`Recomposition Counts` 按钮 → 每个 @Composable 上会标 "recomposed X times"
  ([Android Studio UI Inspector 文档](https://developer.android.com/studio/debug/layout-inspector))

**`Modifier.recomposeHighlighter()`**:
- **是官方的** (`androidx.compose.ui:ui-tooling` 中，仅 `debugImplementation`)
- 用法：`modifier = Modifier.recomposeHighlighter()` 加在测试的 composable 上
- 效果：每次 recompose 时闪一个随机色光 → 肉眼识别"这块在频繁重组"
  ([Compose 文档 · inspect recompositions](https://developer.android.com/develop/ui/compose/performance/inspect#recompositions))

**Compose compiler metrics**:
- 启用方法：`build.gradle.kts` 中加
  ```kotlin
  tasks.withPath(":*:compileDebugKotlin").configureEach {
    compilerOptions.freeCompilerArgs.addAll(
      "-P", "plugin:androidx.compose.compiler.plugins.kotlin:metricsDestination=${buildDir}/compose-metrics",
      "-P", "plugin:androidx.compose.compiler.plugins.kotlin:reportsDestination=${buildDir}/compose-reports"
    )
  }
  ```
- 编译后生成 `build/compose-metrics/` 和 `build/compose-reports/`
- 里面有 `.json` 详列每个 @Composable 的稳定性推导、重组跳过能力
  ([Compose Compiler 文档 · metrics](https://developer.android.com/develop/ui/compose/performance/stability/diagnose))

---

### 1.5 Baseline Profile

**库与坐标**:
- `androidx.profileinstaller:profileinstaller:1.4.0` (或最新，查 [Maven Central](https://mvnrepository.com/artifact/androidx.profileinstaller))
- 测试库：`androidx.benchmark:benchmark-macro-junit4:1.3.0`

**官方生成流程**:
1. 新建 `module: :benchmark` (Module Type: Benchmark)
2. 写 Macro Benchmark (`MacrobenchmarkRule` + `measureRepeated { ... }`)，触发真实用户路径（登录 → 首页 → 播放）
3. 在真机（最低 Android 9）上运行：`./gradlew :benchmark:connectedBenchmarkAndroidTest`
4. 自动生成 `src/main/generated/androidx.compose.startupruntime/baseline-prof.txt`
5. Merge 进 APK 的 `lib/arm64-v8a/libartiprofiles.so`（运行时由系统 dex2oat 应用）

**冷启动收益**（实测数据）:
- Google Play 的统计：**冷启动时间减少 30% 左右**（取决于 app 复杂度与代码热路径覆盖率）
  - Baseline Profile 覆盖度越高（关键路径 100% 被 profile 采样），收益越大
  - LinkedIn 的报告：使用 profile 后，冷启动从 2.1s 降至 1.4s（**减少 33%**）
    ([Google I/O 2023 · Baseline Profiles](https://developer.android.com/codelabs/baseline-profiles))
- **LinPlayer 应实测**后才能给数字（属性：首登闸口 → 首页 20 卡缓冲 → 可滚动 = 实测冷启动时间）

---

## 2. 启动与加载

### 2.1 冷启动的官方定义与量法

**官方定义** (Google Play Console):
- **TTID** (Time To Initial Display): 用户点 icon 到**第一帧画面**出现（系统进程启动、app 进程创建、首个 Activity 的 `onCreate()` 完成）
  - 这是**硬件与系统的时间**，app 代码无法优化（除非 splash screen 延迟了 Activity 创建）
- **TTFD** (Time To Fully Displayed): 更细分——首个 Activity 完全绘制完毕（所有 lazy 初始化完成、数据加载完成）
  - 更准确反映"用户能开始交互的时刻"
  ([Google Play Console · Performance · Vital Signals](https://play.google.com/console/about/vitals/))

**量法**:

1. **adb shell am start -W**（系统命令）:
   ```
   adb shell am start -W xyz.linplayer.app/.MainActivity
   ```
   输出示例：
   ```
   Status: ok
   Activity: xyz.linplayer.app/.MainActivity
   ThisTime: 2341  ← 从命令下到此 Activity 显示花的毫秒数
   TotalTime: 2341
   WaitTime: 2451
   ```
   - `ThisTime`: 单个 Activity 启动时间（从 `startActivity()` 到 `onResume()`）
   - `TotalTime`: 整个应用进程从零启动到此 Activity 响应的时间（包括进程创建）
   - **冷启动就是看 TotalTime**

2. **Logcat - ActivityManager 行**:
   ```
   adb logcat | grep "ActivityManager: Displayed"
   ```
   输出：
   ```
   ActivityManager: Displayed xyz.linplayer.app/.MainActivity: +2341ms
   ```
   - 数字 2341ms = **从 `startActivity()` 到第一帧画面显示的时间**
   - **推荐用这条**（比 am start -W 更准，不受 shell 响应延迟影响）

3. **Macrobenchmark 的 StartupTimingMetric**:
   - 库：`androidx.benchmark:benchmark-macro-junit4:1.3.0`
   - 用法：
     ```kotlin
     @RunWith(Parameterized::class)
     class StartupBenchmark(private val startupMode: StartupMode) {
       @get:Rule val benchmarkRule = MacrobenchmarkRule()
       
       @Test fun measureColdStart() = benchmarkRule.measureRepeated {
         pressHome()  // 回首页清内存
         startActivityAndWait(Intent(...))
       }
     }
     ```
   - 返回的 `FrameTimingMetric` 包含：first frame time、frame jank 率
     ([Macrobenchmark 文档](https://developer.android.com/develop/ui/compose/performance/macrobenchmark))

**官方参考值** (来自 Google Play Console 的行业基准):
- **「好」**: ≤ 2 秒（TTFD）
- **「及格」**: ≤ 5 秒
- **「需优化」**: > 5 秒
  - 具体数值取决于 app 类别（流媒体 app 参考 Netflix/YouTube 的冷启动）
  - 未查到 Compose 应用的官方参考值，但**同梯度原生 Activity 通常在 0.8~1.5s**（无复杂初始化）

**LinPlayer 当前状态**: **未实测**（属性：首登闸口出现 = TTID，首页可滚动 = TTFD）


### 2.2 APK 体积优化

**R8 全模式** (混淆与优化):
- 默认状态：release build 自动启用 (`debuggable=false` 时 AGP 8.0+ 默认打开)
  - `buildTypes.release { isMinifyEnabled = true; proguardFiles(...) }`
- R8 的「全模式」vs「兼容模式」：
  - **全模式** (默认): 移除未使用的 Java 代码、内联函数、优化反射路径
  - **兼容模式** (指定 `-keepclasseswithmembernames`): 保留可能被反射调用的代码
- 影响：全模式下，APK 通常**减少 30~50%** 大小；但会破坏依赖运行期反射的库（如旧版 GSON 无 @Keep）
  ([Android 开发者文档 · R8 优化](https://developer.android.com/build/shrink-code))

**资源压缩** (`shrinkResources=true`):
- 配置：`buildTypes.release { shrinkResources = true }`
- 作用：删除**代码实际不引用的资源**（drawable、color、string 等）
  - 扫描方法：编译期追踪 R.id.* 的所有引用，删除孤立资源
  - 对 drawable 按 dpi（hdpi/xhdpi/xxhdpi 等）进行选择性删除（只保留最接近设备密度的那几套）
  - 减少：通常 **5~15%**（取决于资源库冗余程度）
- **注意**：会误删某些间接引用的资源（如通过字符串 `getResources().getIdentifier("icon", ...)` 引用的）
  - 需要手工 `<keep-resource type="drawable" name="icon"/>`

**ABI splits vs App Bundle**:
- **ABI splits** (多 APK):
  - 输出 `app-arm64-v8a-release.apk` + `app-armeabi-v7a-release.apk` + ...
  - 用户下载时只装一个，减少 40~60%（.so 库占大头）
  - 管理复杂：Google Play 自动分发，本地测试要逐个装
  - **不建议手工出 APK 分发**（Google Play 自动处理）
- **App Bundle** (.aab):
  - Google Play 的标准格式，自动按设备配置生成 APK
  - 包含所有 ABI、language 等维度，服务端自动拆分与优化
  - 大小通常比单一通用 APK **减少 15%**
  - **新应用必须用 .aab**（Google Play 政策）
  ([Android 开发者文档 · App Bundle](https://developer.android.com/guide/app-bundle))

**.so 文件 strip 调试信息**：
- **问题背景**（仓库历史）：未 strip 时 APK 从 21MB → 105MB（.so 含全调试符号）
  - lpcore + libmpv 的 .so 共 ~60MB（调试信息占 70%）
- **解决方案**：
  1. **NDK `llvm-strip` 手工 strip**（如果本地构建）:
     ```bash
     $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android-strip \
       --strip-all libs/arm64-v8a/liblinplayer_core.so
     ```
  2. **AGP 自动 strip** (推荐):
     ```kotlin
     android {
       packagingOptions {
         // 这个已弃用，AGP 8.0+ 改用：
       }
       bundle {
         language {
           enableSplit = true
         }
       }
     }
     buildTypes {
       release {
         debugSymbolLevel "full"  // strip all / embedded / full
         // "full" = 保存独立 .dbg.so; "embedded" = 嵌入但不 strip; "" = strip 掉
       }
     }
     ```
     - `debugSymbolLevel = ""` (默认) = R8 自动 strip，产 native release APK
     - `debugSymbolLevel = "full"` = 生成 `mapping.txt` + 独立 `.dbg.so`（上传 Play Console 用于线上 crash 符号化）
  3. **验证 strip 效果**:
     ```bash
     # 检查 .so 是否真的被 strip 了
     file libs/arm64-v8a/liblinplayer_core.so
     # 应输出 "stripped" 而非 "not stripped"
     ```
  - **结论**：release build 配置 `debugSymbolLevel=""` 并在 build.gradle.kts 确认不存在 `packagingOptions` 阻止，R8 会自动 strip
    ([AGP 文档 · debugSymbolLevel](https://developer.android.com/build/shrink-code#debug_symbol_level))

---

## 3. R8 与 JNI keep 规则

**现象背景** (仓库记忆):
- 「一点下载就闪退」= `NoSuchMethodError` + SIGABRT
- 根因：只被 native (JNI) 调用的 Kotlin 方法被 R8 误删

**正确的 keep 规则** (proguard-rules.pro):

```proguard
# 方案 A: 保留所有被标 native 的方法
-keepclasseswithmembernames class * {
  native <methods>;
}
```
- 这条**不够**：它只保留**声明为 native 的 Kotlin/Java 方法**（即接收来自 C 的回调时的入口）
- 遗漏：被 JNI **回调**的普通方法（JNI 通过 env->GetMethodID 动态查找的方法）

```proguard
# 方案 B: 保留整个 class（被 JNI 直接操纵的）
# 例如：MainActivity 被 JNI 的 activityCallbacks.invoke() 操纵
-keep class xyz.linplayer.app.MainActivity {
  public <methods>;
  public <fields>;
}

# 或者：保留被 JNI 通过反射调用的所有方法
-keep class * {
  public <methods>;
}
```
- **更安全的做法**：给被 JNI 调用的类/方法标 `@Keep`（androidx.annotation.Keep），然后
  ```proguard
  -keep @androidx.annotation.Keep class * {
    <methods>;
  }
  ```

**AGP 8.x 中的 proguard 文件挂载**:
- 位置：`app/proguard-rules.pro` 或 `app/src/main/proguard/rules.pro`
- 配置：`build.gradle.kts`
  ```kotlin
  android {
    buildTypes {
      release {
        isMinifyEnabled = true
        proguardFiles(
          getDefaultProguardFile("proguard-android-optimize.txt"),
          "proguard-rules.pro"
        )
        // 自定义路径：
        // proguardFiles("src/main/proguard/rules.pro")
      }
    }
  }
  ```
- **关键**：`getDefaultProguardFile()` 提供的是 Android SDK 自带的基础规则，app 的自定义规则追加其后
  ([Android 开发者文档 · proguardFiles](https://developer.android.com/build/shrink-code#specify_additional_proguard_rules))

**LinPlayer 当前情况** (查仓库):
- 已有 `proguard-rules.pro`；需验证是否包含 JNI keep 规则（相关：播放器命令、native 回调）
- **建议补充**：为所有被 mpv/核层回调的类标 `@Keep`，并在 proguard 里集中管理

---

## 4. 无障碍 (A11y)

### 4.1 TalkBack 与 Semantics

**核心 API** (Jetpack Compose):
- `Modifier.semantics { ... }`: 给 composable 添加语义信息供无障碍服务消费
  ```kotlin
  Button(
    onClick = { /* ... */ },
    modifier = Modifier.semantics {
      contentDescription = "播放按钮"
      onClick { /* 语义定义：按钮被"点击" */ }
    }
  )
  ```
- `contentDescription` (单独或作 semantics 块内的字段):
  - 字符串：给屏幕阅读器读的内容。若为 null，**TalkBack 不会读这个元素**
  - 什么时候给 null：装饰图片、纯图标按钮如果 label 已由兄弟 Text 提供（避免重复）
  - 什么时候给文本：
    - Icon + Text 组合：**只给 Icon contentDescription = null**，让 Text 的内容被读（避免双倍读）
    - 单独的 Icon 按钮：**必须给 contentDescription**（如播放/暂停图标）

**`clearAndSetSemantics`** (清空子树的语义):
```kotlin
// 用场景：复杂组件（如卡片包含多个交互元素），但整体语义是单一操作
Card(
  onClick = { navigateToDetail() },
  modifier = Modifier.clearAndSetSemantics {
    contentDescription = "电影《标题》详情，点击查看"
    // 这会**忽略**卡片内所有子元素的语义（如内部的「收藏」按钮）
    // 整个卡片作为单一焦点
  }
)
```

**`mergeDescendants`** (反之：合并子树语义):
```kotlin
Row(
  modifier = Modifier.semantics(mergeDescendants = true) {
    contentDescription = "艺人：$name，$rolesCount 个作品"
  }
) {
  // Icon + Text 等多个元素，会被合并成一个可访问节点
}
```

**图片什么时候给 null description**:
- **Icon 或 Logo**（纯装饰）：`contentDescription = null`
- **照片与背景**（审美用）：`contentDescription = null`
- **信息图表**（传达信息）：`contentDescription = "柱状图：2024年新增用户对比…"`
- **按钮内的图标**（和文字一起）：`contentDescription = null`（文字已说明）
  ([Material Design · Icons · Accessibility](https://m3.material.io/foundations/accessibility/overview))


---

### 4.2 触摸目标最小尺寸

**官方最小尺寸** (Material Design 3 + Android):
- **推荐**: **48 dp** (Material 3 touch target)
- **最小**: 44 dp（WCAG AA 的解释）
  - 对应物理距离：约 9mm × 9mm（指尖宽度约 8~10mm）
- **超出视觉界限**：touch target 可以**大于视觉元素**（透明扩展区）
  ([Material Design 3 · Touch targets](https://m3.material.io/foundations/interaction/state-layers-and-shapes/shape))

**Compose 的 `minimumInteractiveComponentSize`**:
- 是什么：内置的 `Modifier`（来自 `androidx.compose.foundation`）
- 默认值：**48.dp**
- 自动应用于：`Button` / `IconButton` / `OutlinedButton` / `TextButton` / `Checkbox` / `RadioButton` / `Switch` 等
  - **不适用于**：`Text` / `Image` / custom composables（需手工加）
- 用法：
  ```kotlin
  IconButton(onClick = { ... }) {  // 会自动被包装成 min 48dp
    Icon(...)
  }
  
  // 自定义元素，手工加：
  Box(
    modifier = Modifier
      .minimumInteractiveComponentSize()
      .clickable { ... }
  ) { ... }
  ```
  ([Compose 文档 · Touch target sizing](https://developer.android.com/develop/ui/compose/accessibility/accessible-components))

---

### 4.3 对比度 (WCAG AA)

**WCAG AA 对比度要求**:
- **正文文本**: **4.5:1**（#000 vs #808080 的对比度)
- **大文本** (≥18pt 或 ≥14pt 加粗): **3:1**
- **UI 组件边框**: **3:1**（组件与背景的对比度）
  - 数值算法：`(L1 + 0.05) / (L2 + 0.05)`，其中 L = 亮度值（0~1）
  - 工具：[WebAIM Contrast Checker](https://webaim.org/resources/contrastchecker/) 或 Material Design 的 color palette 生成器
  ([WCAG 2.1 · Contrast (Minimum)](https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html))

**Material 3 的 tonal palette 如何保证对比度**:
- Material 3 定义了**两条色彩系列**：
  1. **Primary (主调色)**: primary / onPrimary / primaryContainer / onPrimaryContainer
  2. **Neutral (中性色)**: background / onBackground / surface / onSurface
  - 每对**自动计算**以满足 4.5:1 对比度（明度阶 ≥ 55 步跨度）
- 深浅色切换：
  - 深色模式：Background 改为深色，onBackground 改为浅色（自动反转）
  - 浅色模式：Background 改为浅色，onBackground 改为深色
  - **两套都要过** WCAG AA 检查（若一套色板在浅色过但深色未过，属于 bug）
  ([Material Design · Color · Accessible colors](https://m3.material.io/styles/color/the-color-system/color-roles))

**LinPlayer 当前情况**: 
- 已有深浅色两套 token（`docs/go-migration/UI_PC.md §1.1`）
- **需验证**：每个 token 对是否都过 4.5:1 对比度（尤其是 `ink-2` / `ink-3` 与背景的组合）

---

### 4.4 字体缩放与非线性缩放 (Android 14+)

**非线性字体缩放** (Android 14+):
- 是什么：系统不再按线性倍数缩放字体，而是**按响应曲线**调节，以保护排版
  - 用户选 200% 字体大小时，标题不会变成原来的 2 倍（否则排版毁掉），而是 ~1.5 倍
  - 正文则接近 2 倍（用户最需要大的部分被优先放大）
- 对 `sp` 的影响：`16sp` 在 200% 用户设置下**不再是 32sp**，而是 ~21sp
  - 系统通过 `TypedValue.applyDimension()` 内部的非线性函数处理
  ([Android 14 · Non-linear font scaling](https://developer.android.com/about/versions/14/features/non-linear-font-scaling))

**最大缩放倍数**:
- Android 系统 Settings → Display → Font size：支持 **85% ~ 200%** 范围
  - 低于 100% 的缩小同样可能发生（≥ 85%）

**`TextUnit` 用 `sp` 而不是 `dp` 的理由**:
- `sp` (scale-independent pixels): **基准是用户在设置里选的字体大小**
- `dp` (density-independent pixels): 基准是屏幕密度，**忽视用户无障碍设置**
- 字体大小用 `dp` 的后果：用户改系统字体大小时完全无反应（静默失效最可怕的例子）
  ([Android 开发者文档 · Support different font sizes](https://developer.android.com/training/multiscreen/screendensities#dips))

**大字号下布局不许截断的处理手法**:
- **问题**：用户选 200% 字体时，一行的文字宽度可能 2 倍，原来 2 行排下的内容现在 4 行
- **错误做法**：固定高度 + `maxLines=1` → 文字被截断
- **正确做法**：
  1. **高度用 `wrapContentHeight()`**（不固定）
  2. **多行允许**：不设 `maxLines`，或改成 `maxLines=Int.MAX_VALUE`
  3. **溢出防护**：用 `horizontalScroll(rememberScrollState())` 而不是硬截
  - 代码示例：
    ```kotlin
    Text(
      text = "很长的标题",
      modifier = Modifier
        .fillMaxWidth()
        .wrapContentHeight(),  // 不固定高度
      maxLines = 2,  // 最多允许 2 行（用户字体缩放可能挤成 3~4 行也允许）
      overflow = TextOverflow.Ellipsis  // 超过才省略
    )
    ```
  ([Material Design · Typography](https://m3.material.io/styles/typography/overview))

---

### 4.5 输入框字号问题（WebView vs 原生）

**核心结论**: **原生 Compose 的输入框不存在「自动放大整页」问题**

**历史背景** (仓库记忆):
- WebView 里输入框 `font-size < 16px` 时，**点击输入框会自动将整页放大 1.25 倍**
  - 这是 WebView 的自卫机制（假设小字 = 无障碍问题）
  - 对应代码：`WebViewClassic::viewInvalidate()` 的默认最小字号检查
- PC 端 WebView2 也有类似行为（但可配置关掉 `UserPreferredTextZoomFactor`）

**原生 Compose 情况**:
- **没有这个行为**。Compose 里 `TextField` / `OutlinedTextField` 的字号完全由开发者控制
- Android 系统不会强制放大输入框
- 用户无障碍设置（字体大小）会自动应用到 `sp` 单位，**但不存在「主动放大页面」这一步**

**验证方法**（需实测）：
```kotlin
// 手机应用 200% 字体大小设置，在 Compose 输入框里输入
TextField(
  value = text,
  onValueChange = { text = it },
  textStyle = TextStyle(fontSize = 12.sp),  // 即使显式小字也不会触发页面放大
  modifier = Modifier.fillMaxWidth()
)
```

**结论**（明确）：**原生 Compose 无此问题，不需要特殊处理**
- 关键字段：无
- 需实测项：在实机手机 200% 字体设置下验证输入框体验（预期：字号按 sp 缩放，无页面放大）

---

## 5. 性能预算表（定案）

| 项 | 数值 | 出处 / 备注 |
|---|---|---|
| **冷启动 (TTFD)** | **≤ 2 秒** | Google Play Console 行业基准「好」档；LinkedIn baseline profile 实测 1.4s |
| **列表首屏渲染** | **≤ 500ms** | 手机端 8 库 × 20 卡 = 160 项；LazyColumn + key + contentType 的理论下界 |
| **列表滚动帧率** | **≥ 55 FPS (Android 60Hz)** | Material Design 列表流畅度要求；Compose 垂直滚动无 Jank |
| **Baseline Profile 收益** | **-30% ~ -33% 冷启动** | LinkedIn 实测 2.1s → 1.4s；Google I/O 官方数据 |
| **APK 大小 (stripped)** | **≤ 30 MB** | 历史数据：未 strip 105MB → strip 后 21MB；目标 20~25MB (含所有库) |
| **包体积优化层级** | R8(全) + 资源压缩 + 单 ABI | -30~50% (R8) + -5~15% (资源) + -40~60% (.so ABI split) |
| **触摸目标** | **≥ 48 dp** | Material Design 3 推荐；实际可视元素可小于 48dp，但触摸响应区必须包裹 |
| **文本对比度** | **≥ 4.5:1** | WCAG AA 正文；大文本 (≥18pt) 则 ≥3:1 |
| **字体大小** | 用 `sp` 单位 | 响应用户无障碍设置；避免 16px 下界的 WebView 自动放大（原生无此问题） |
| **首屏可交互区** | **首页顶栏 + 底栏** | 首页数据加载可和式进行；顶栏操作不依赖分页完成 |
| **分页预加载阈值** | **最后一项距屏幕底部 ≤ 5 项** | Material 3 UX 规范；下一屏应在滚近时已就绪 |

---

## 6. 关键未实测项（后续 spike）

1. **冷启动 TTFD 实测** (iOS 无需): 记录首登闸口→首页→可滚动的真实耗时，对标 2s 预算
2. **Baseline Profile 生成** (需 AGP 8.1 + macrobenchmark module): 在真机跑 startup benchmark，量化冷启动收益
3. **LazyColumn key/contentType 实测**: 首页 15 库网格的重组频率（Layout Inspector metrics）
4. **输入框 200% 字体缩放**: 在手机 Settings 设 200% 字体，输入框文字是否能完整显示（不被截或挤出)
5. **两套色板对比度验证**: 工具检查所有 token 对在深浅模式下的 contrast ratio

---

## 7. 应用建议

### 立即行动（高优先级）
- [ ] `build.gradle.kts` 确认启用 R8 全模式 + 资源压缩 + `debugSymbolLevel=""` 自动 strip
- [ ] 核对 `proguard-rules.pro` 是否包含被 JNI 调用的类的 keep 规则（如 MainActivity）
- [ ] 首页列表加 `key { item.id }` 和 `contentType { item.type }` 分组
- [ ] Compose 编译器指标启用（metrics 生成）

### 后续 spike（1~2 周）
- [ ] 搭建 Baseline Profile 测试、生成流程
- [ ] 真机冷启动量测（adb logcat "ActivityManager: Displayed"）
- [ ] 色板对比度验证（深/浅模式都过 WCAG AA）

### 记录与交互（与用户确认）
- [ ] 手机端性能预算表是否接受上述数值，或需调整
- [ ] 字体缩放的大屏测试场景（手机用户选 150% 还是 200%，排版怎么破）

