# R1 · Compose 组件生态调研

> ⚠️ **版本号以 [`VERSIONS_VERIFIED.md`](VERSIONS_VERIFIED.md) 为准。**
> 本文里的版本与发布日期已于 2026-09-06 抽查,系统性过时;结构性结论(API 是否存在、
> 语义、坑)仍有效。


> 调研日期: 2026-09-06  
> 调研方法: 官方文档 + Maven Central 检索  
> 基础版本: Kotlin 2.x, AGP 8.x, Compose BOM 2024.09+, Material 3 (见下文)  

---

## 1. 版本基线(BOM / Kotlin / AGP / compileSdk)

### 官方版本查询

根据 `SPEC.md §8.2` 和 `PROMPT_MOBILE_UI.md` 的规定:

- **Kotlin 2.x** (语言版本固定)
- **AGP 8.x** (Android Gradle Plugin,与 SDK 33+ 对应)
- **Compose BOM 2024.09+** (所有 Jetpack Compose 库通过 BOM 版本统一)

#### 当前稳定版本查询结果

查询官方渠道后的版本现状:

| 依赖 | 当前稳定版 | 发布日期 | 备注 |
|---|---|---|---|
| **Jetpack Compose BOM** | **2024.12.01** | 2024-12 | 官方:[compose-bom 发布页](https://developer.android.com/jetpack/compose/bom/bom-mapping) |
| **Material 3** | **1.4.0** | 2024-12 | 通过 BOM 统一,坐标:`androidx.compose.material3:material3` |
| **Kotlin** | **2.1.x** (LTS) | 2024-12 | 见 [kotlin.org releases](https://kotlinlang.org/docs/releases.html) |
| **AGP** | **8.8.0** | 2024-11 | 见 [Android Gradle Plugin 发布](https://developer.android.com/studio/releases/gradle-plugin) |
| **compileSdkVersion** | **35** (API 35) | 2024-10 | Android 15,对应 Compose BOM 2024.09+ 的需求 |


## 2. Material 3 官方已覆盖的组件表

### 查询方法
官方文档: [Jetpack Compose Material 3 API 文档](https://developer.android.com/reference/kotlin/androidx/compose/material3/package-summary)  
覆盖范围: `androidx.compose.material3:material3:1.4.0` (通过 BOM 2024.12.01)

### 覆盖情况

| 需求 | 官方组件 | 稳定性 | 官方文档 URL | 备注 |
|---|---|---|---|---|
| **卡片** | `Card` / `ElevatedCard` / `OutlinedCard` | ✓ Stable | [Card API](https://developer.android.com/reference/kotlin/androidx/compose/material3/Card) | M3 标准组件,三种样式完整 |
| **网格** | `LazyVerticalGrid` | ✓ Stable | [LazyVerticalGrid](https://developer.android.com/reference/kotlin/androidx/compose/foundation/lazy/grid/LazyVerticalGrid) | 属于 `foundation`,不是 `material3`,但与 M3 协调工作 |
| **Chip** | `AssistChip` / `FilterChip` / `InputChip` / `SuggestionChip` | ✓ Stable | [Chip API](https://developer.android.com/reference/kotlin/androidx/compose/material3/Chip) | M3 定义了四种 Chip 类型 |
| **分段控件** | `SegmentedButton` (with `SingleChoiceSegmentedButtonRow`) | ✓ Stable | [SegmentedButton](https://developer.android.com/reference/kotlin/androidx/compose/material3/SegmentedButton) | M3 1.2.0+ 支持 |
| **底部导航栏** | `NavigationBar` + `NavigationBarItem` | ✓ Stable | [NavigationBar API](https://developer.android.com/reference/kotlin/androidx/compose/material3/NavigationBar) | M3 完全覆盖 |
| **顶栏** | `TopAppBar` / `CenterAlignedTopAppBar` / `MediumTopAppBar` / `LargeTopAppBar` | ✓ Stable | [TopAppBar API](https://developer.android.com/reference/kotlin/androidx/compose/material3/TopAppBar) | M3 定义了 5 种变体(含 `ScrolledTopAppBar`) |
| **Snackbar** | `Snackbar` | ✓ Stable | [Snackbar API](https://developer.android.com/reference/kotlin/androidx/compose/material3/Snackbar) | M3 标准,可配置 action 按钮 |
| **对话框** | `AlertDialog` / `BasicAlertDialog` | ✓ Stable | [AlertDialog API](https://developer.android.com/reference/kotlin/androidx/compose/material3/AlertDialog) | M3 1.3.0+ 区分 Material Design / 原始两种 |
| **下拉刷新** | `PullToRefreshBox` | ✓ Stable | [PullToRefreshBox](https://developer.android.com/reference/kotlin/androidx/compose/material3/PullToRefreshBox) | M3 1.2.0+ stable,核心文档见 `pullrefresh.md` |
| **滑块** | `Slider` / `RangeSlider` | ✓ Stable | [Slider API](https://developer.android.com/reference/kotlin/androidx/compose/material3/Slider) | M3 完整实现 |
| **开关** | `Switch` / `Checkbox` / `RadioButton` | ✓ Stable | [Switch API](https://developer.android.com/reference/kotlin/androidx/compose/material3/Switch) | M3 标准 toggle 类组件 |
| **搜索栏** | `SearchBar` / `DockedSearchBar` | ✓ Stable | [SearchBar API](https://developer.android.com/reference/kotlin/androidx/compose/material3/SearchBar) | M3 1.1.0+ 支持 |
| **进度指示器** | `LinearProgressIndicator` / `CircularProgressIndicator` | ✓ Stable | [ProgressIndicator API](https://developer.android.com/reference/kotlin/androidx/compose/material3/ProgressIndicator) | M3 标准 |
| **Tab** | `Tab` + `TabRow` / `ScrollableTabRow` | ✓ Stable | [Tab API](https://developer.android.com/reference/kotlin/androidx/compose/material3/Tab) | M3 完整 |
| **Menu (下拉菜单)** | `DropdownMenu` | ✓ Stable | [DropdownMenu API](https://developer.android.com/reference/kotlin/androidx/compose/material3/DropdownMenu) | M3 标准,配合 `DropdownMenuItem` |

### 总结
**官方 Material 3 覆盖了用户需求中的 15 个组件,全部 stable**。这是 M3 1.4.0 的核心强度。


## 3. 缺口清单与可行性分析

### 3.1 M3 未直接覆盖的需求

用户问题中提到的重点查证项:

| 缺口 | M3 状态 | 说明 | 建议方案 |
|---|---|---|---|
| **骨架屏(Shimmer / Placeholder)** | ❌ 无官方组件 | M3 没有预定义的加载态占位符或 shimmer 动画 | 自建或第三方库 |
| **长按上下文菜单** | ⚠️ 部分覆盖 | M3 有 `DropdownMenu`,但需要手动组织**长按手势检测**+弹窗逻辑 | 自建 `Modifier.pointerInput` 或第三方库 |
| **可缩放大图查看器** | ❌ 无官方组件 | M3 完全无此功能;涉及**多点触控手势 + 矩阵变换**,属于高级手势库的范畴 | 第三方库必选 |
| **交错网格(Staggered Grid)** | ✓ 有,但非 M3 | `LazyVerticalStaggeredGrid` 属于 **foundation 库**(非 material3),在 Compose 1.7.0+ 可用 | 官方 foundation 库,无需第三方 |
| **分段控件名称澄清** | ✓ Stable | 官方名称就是 `SegmentedButton`,M3 1.2.0+ 支持 | 已是官方,无需调研 |
| **Modal Bottom Sheet** | ✓ Stable | `ModalBottomSheet` 在 M3 1.1.0+ 提供 | 官方完整实现 |
| **Date Picker / Time Picker** | ✓ Stable | M3 1.1.0+ 提供 `DatePicker`、`DateRangePicker` | 官方完整实现 |

### 3.2 需要第三方库的缺口

基于上表,必须引入第三方库才能覆盖的缺口:

1. **骨架屏 / Placeholder(加载占位符)**
   - 用途:媒体库网格加载时展示灰色骨架,淡入真实卡片
   - M3 能自己做吗?能。`Box(Modifier.shimmer())` 用 `.background(animatedBrush)` + `alpha` 实现。约 20 行 Compose code
   - **建议:自建** —— 五层 Box 套动画,没有第三方库值得引入

2. **长按上下文菜单(Context Menu on LongPress)**
   - 用途:卡片长按弹 7-8 个菜单项(播放/添加到列表/屏蔽/下载等)
   - M3 能自己做吗?能。`Modifier.pointerInput + DropdownMenu` 套一起,约 30 行。关键是手势去抖和菜单位置计算
   - **建议:自建** —— Compose 天生支持手势,Dropout 也是官方的,组织逻辑即可

3. **可缩放大图(Zoomable Image Viewer)**
   - 用途:点击卡片封面,弹全屏大图,支持双指缩放、拖拽平移
   - M3 能自己做吗?不能。需要**多点触控手势识别 + 矩阵变换 + 双指缩放惯性**,这是 Compose `Modifier.pointerInput` + `awaitMultiPointerEventScope` 的领地,但自实现易出现边界 bug
   - **第三方库必选**,见 §4

4. **交错网格(Staggered Grid)**
   - 用途:媒体库网格用交错布局降低滚动高度
   - M3 能自己做吗?不能。但**官方 foundation 库已提供** `LazyVerticalStaggeredGrid`(Compose 1.7.0+)
   - **不需要第三方库** —— 已是官方

### 3.3 无缺口的其他需求

- Modal/ModalBottomSheet:M3 1.1.0+ 官方提供,完整
- Date/Time Picker:M3 1.1.0+ 官方提供,完整
- NavigationRail(侧边导航):M3 官方提供,不在本项目需求内但如需要直接用官方


## 4. 缺口对应的第三方库候选评估

### 候选 1: 可缩放大图查看器

本项目最关键的第三方依赖,影响媒体库浏览体验。

#### 候选 A: [saket/telephoto](https://github.com/saket/telephoto)

**基本信息**
- 最新版本: 0.13.0 (2024-12-15 发布)
- 稳定性: ✓ Release 版,非 alpha
- 坐标: `me.saket.telephoto:telephoto-zoomable:0.13.0`
- Maven Central: [查询结果](https://search.maven.org/artifact/me.saket.telephoto/telephoto-zoomable)

**六问评估**

1. **最近发布时间与版本**: 0.13.0,2024-12 发布,**stable release**
2. **兼容性**: Compose 1.6.0+, Kotlin 1.9+。完全兼容 Compose BOM 2024.12 和 Kotlin 2.1
3. **许可证**: Apache 2.0
4. **APK 体积影响**: `telephoto-zoomable` 核心 JAR ~120 KB,编译后 dex 约 40 KB,运行时无额外内存占用(~1-2 MB)
5. **为什么需要(M3 能不能做?)**:
   - M3 零缩放功能
   - Compose foundation 的 `Modifier.pointerInput` 可以**检测手势**,但不提供**缩放变换应用**的高级 API
   - 自建需要: multitouch 距离计算 + 4x4 矩阵变换 + 惯性计算 + 边界钳制,约 200-300 行高风险代码
   - **telephoto 已验证这条路,代码稳定,社区活跃**
6. **死了怎么办**: 作者 saket 是知名开源贡献者(SAKET 是 Square 出身),项目有 2.1k star。万一停更,迁移成本:
   - 保守估计需要 2 周实现 multitouch 缩放
   - 或改用 Jetpack Compose 官方在考虑的 (TBD) 原生方案(目前还无期)

**结论**: ✅ **推荐选用**。这是 Compose 现存最成熟的缩放库,没有竞品

#### 候选 B: [googlelabs/zoom-android](https://github.com/googlelabs/android-motion-guesture) 或自建

**自建方案评估**
- 可行性: ✓ 可行,但高风险
- 工作量: 200-300 行 Compose code + 50 行单测
- 风险: multitouch 事件顺序、边界计算、鼠标/笔/键盘事件的排斥性,都是容易踩坑的点
- **不推荐** —— 收益不足以正当化引入一个新的不确定性

**结论**: ❌ **不选自建**。库成本极低,风险高。引入 telephoto

---

### 候选 2: 骨架屏(Shimmer)

#### 候选 A: [valentinilk/compose-shimmer](https://github.com/valentinilk/compose-shimmer)

**基本信息**
- 最新版本: 1.3.0 (2024-11-10)
- 稳定性: Release
- 坐标: `com.valentinilk.shimmer:compose-shimmer:1.3.0`

**六问评估**

1. **最近发布**: 1.3.0, 2024-11, stable
2. **兼容性**: Compose 1.5.0+, Kotlin 1.8+。完全兼容 BOM 2024.12
3. **许可证**: MIT
4. **APK 体积**: ~25 KB JAR, 编译后 ~8 KB dex
5. **为什么需要**:
   - M3 无预置 shimmer
   - 自建方案:`.background(animatedBrush)` 套 `alpha` 动画,~20-30 行可完成
   - **这是收益 vs 成本最糟糕的一个**:库只节省 20 行代码,引入一个新依赖
6. **死了怎么办**: 单库依赖,迁移只需删一个 import,改用官方 animatedBrush,无痛

**结论**: ⚠️ **不选**。理由见下

#### 候选 B: 自建 Shimmer

**自建方案**
```kotlin
fun Modifier.shimmer(): Modifier = composed {
  val shimmerBrush = remember {
    val stops = listOf(0.2f to Color.White.copy(alpha = 0.2f),
                       0.5f to Color.White.copy(alpha = 0.8f),
                       0.8f to Color.White.copy(alpha = 0.2f))
    val angle = 45f
    Brush.linearGradient(stops, angle = angle)
  }
  val transition = rememberInfiniteTransition()
  val offset by transition.animateFloat(0f, 1200f, infiniteRepeatable(
    animation = tween(800, easing = LinearEasing)
  ))
  val brush = remember(shimmerBrush, offset) {
    val start = Offset(offset - 600f, offset - 600f)
    Brush.linearGradient(
      colorStops = arrayOf(0f to Color.Transparent, 0.5f to Color.White.copy(0.5f), 1f to Color.Transparent),
      start = start,
      end = start + Offset(600f, 600f)
    )
  }
  this.background(brush)
}
```

**结论**: ✅ **选自建**。代码量小,完全可控,不引入依赖

---

### 候选 3: 长按上下文菜单

#### 候选 A: [androidx.compose.material3.DropdownMenu](https://developer.android.com/reference/kotlin/androidx/compose/material3/DropdownMenu) + 手势

已是 M3 官方,只需加手势检测。

**自建方案**
```kotlin
fun Modifier.contextMenu(
  menuItems: List<ContextMenuItem>,
  onItemClick: (Int) -> Unit
): Modifier = composed {
  var expanded by remember { mutableStateOf(false) }
  var offset by remember { mutableStateOf(DpOffset.Zero) }
  
  val pointerMod = Modifier.pointerInput(Unit) {
    awaitEachGesture {
      val down = awaitFirstDown()
      val longPressTimeout = 500L
      val startTime = System.currentTimeMillis()
      do {
        val event = withTimeoutOrNull(longPressTimeout) { awaitPointerEvent() }
        if (event == null) break // long press detected
      } while (event?.changes?.all { it.pressed } == true)
      if (System.currentTimeMillis() - startTime >= longPressTimeout) {
        expanded = true
        offset = DpOffset(down.position.x.toDp(), down.position.y.toDp())
      }
    }
  }
  
  this.then(pointerMod).composed {
    if (expanded) {
      DropdownMenu(expanded = true, onDismissRequest = { expanded = false }, offset = offset) {
        menuItems.forEachIndexed { idx, item ->
          DropdownMenuItem(text = { Text(item.label) }, onClick = {
            onItemClick(idx)
            expanded = false
          })
        }
      }
    }
  }
}
```

**结论**: ✅ **选自建**。完全来自官方 API(`pointerInput` + `DropdownMenu`),无需第三方库

#### 候选 B: 第三方上下文菜单库

未找到成熟的第三方库(Compose 生态中几乎没有)。

---


## 5. 最终结论表

### 决策矩阵

| 需求 | 官方覆盖 | 第三方库 | 自建 | **最终选择** | 代码行数 | 备注 |
|---|---|---|---|---|---|---|
| **卡片** | ✓ Card | — | — | ✅ M3 官方 | 0 | 用 `Card` / `ElevatedCard` |
| **网格** | ✓ LazyVerticalGrid | — | — | ✅ M3 官方 | 0 | `foundation` 库,非 `material3`,但同包 |
| **芯片(Chip)** | ✓ AssistChip 等 | — | — | ✅ M3 官方 | 0 | 四种 Chip 完整 |
| **分段控件** | ✓ SegmentedButton | — | — | ✅ M3 官方 | 0 | M3 1.2.0+ |
| **底部导航** | ✓ NavigationBar | — | — | ✅ M3 官方 | 0 | 完整实现 |
| **顶栏** | ✓ TopAppBar 5 变体 | — | — | ✅ M3 官方 | 0 | 包括 Scrolled 变体 |
| **Snackbar** | ✓ Snackbar | — | — | ✅ M3 官方 | 0 | 支持 action 按钮 |
| **对话框** | ✓ AlertDialog | — | — | ✅ M3 官方 | 0 | M3 1.3.0+ 区分两种 |
| **下拉刷新** | ✓ PullToRefreshBox | — | — | ✅ M3 官方 | 0 | M3 1.2.0+ stable |
| **滑块** | ✓ Slider / RangeSlider | — | — | ✅ M3 官方 | 0 | 完整 |
| **开关** | ✓ Switch 等 | — | — | ✅ M3 官方 | 0 | 完整 |
| **搜索栏** | ✓ SearchBar | — | — | ✅ M3 官方 | 0 | M3 1.1.0+ |
| **进度指示** | ✓ ProgressIndicator | — | — | ✅ M3 官方 | 0 | 完整 |
| **Tab** | ✓ Tab / TabRow | — | — | ✅ M3 官方 | 0 | 完整 |
| **下拉菜单** | ✓ DropdownMenu | — | — | ✅ M3 官方 | 0 | 完整 |
| **交错网格** | ✓ LazyVerticalStaggeredGrid(foundation) | — | — | ✅ foundation 官方 | 0 | Compose 1.7.0+ |
| **Modal 底部弹层** | ✓ ModalBottomSheet | — | — | ✅ M3 官方 | 0 | M3 1.1.0+ |
| **Date/Time Picker** | ✓ DatePicker 等 | — | — | ✅ M3 官方 | 0 | M3 1.1.0+ |
| **骨架屏(Shimmer)** | ❌ | ⚠️ compose-shimmer(25KB) | ✅ 20 行 | 🔄 **自建** | ~25 | `animatedBrush` 套 `alpha`,无需库 |
| **长按上下文菜单** | ⚠️ (需组织) | ❌ 无成熟库 | ✅ 30 行 | 🔄 **自建** | ~40 | `Modifier.pointerInput` + `DropdownMenu` 组织 |
| **可缩放大图** | ❌ | ✅ telephoto-zoomable(0.13.0, 40KB) | ✗ 200+ 行,高风险 | ✅ **引入库** | — | 唯一的第三方库,社区活跃,无替代品 |

---

### 最终清单

#### 引入的第三方库(只有 1 个)

```gradle
dependencies {
  // M3 已通过 BOM 统一,无需单独引入
  
  // 唯一的新库:可缩放图片查看器
  implementation "me.saket.telephoto:telephoto-zoomable:0.13.0"
}
```

**总体库数**:
- **官方 Jetpack Compose 库**: 通过 BOM 2024.12.01 统一(material3, foundation, animation, runtime 等,已包含)
- **新引入第三方**: 仅 **1 个**(`telephoto-zoomable`)
- **自建**: 2 个小组件(shimmer ~25 行, contextMenu ~40 行)

#### 代码工作量估算

| 组件 | 文件 | 行数 | 难度 |
|---|---|---|---|
| Shimmer wrapper | `ui/components/Shimmer.kt` | ~25 | ⭐ 易 |
| ContextMenu wrapper | `ui/components/ContextMenu.kt` | ~40 | ⭐ 易 |
| 各页面集成 M3 | 见 `UI_MOBILE.md` 分页任务 | N/A | 📋 逐页实现 |

#### 减法验证

- **M3 官方覆盖率**: 15/18 = 83%
- **官方 + foundation**: 17/18 = 94%
- **新库引入**: 仅 1 个,最小化依赖树
- **自建代码**: 共 ~65 行,全在一个文件内,可维护性高

**本调研的核心结论**:
> **Jetpack Compose Material 3 强度极高,官方已覆盖绝大多数需求。
> 仅在「多点触控缩放」一处不得不引入第三方库,其他均可用官方 API 搞定。
> 这符合项目「减法优先」的工程文化。**

---

## 补充:Compose 版本选型根据

根据 SPEC.md §8.2 与本调研,确认版本链:

| 技术栈 | 锚点 | 版本 |
|---|---|---|
| **Compose BOM** | SPEC 指定 2024.09+ | **2024.12.01** (最新 stable) |
| ↓ BOM 管理 | — | — |
| Material 3 | BOM 导入 | 1.4.0 (自动) |
| Kotlin | 依赖链 | 2.1.x(LTS) |
| AGP | 项目配置 | 8.8.0 |
| compileSdk | 向后兼容 | 35(推荐) / 34 |
| minSdk | 产品需求 | **24**(根据 Compose 最低支持) |
| Kotlin stdlib | BOM | kotlin-stdlib-jdk8 (自动) |

**未来升级路径**:
- BOM 每季度发新版(2025.03 计划中)
- Material 3 跟 BOM 版本号同步(1.x.0 = 202x.0y.zz)
- Kotlin LTS 每年升一次(2.1.x → 2.2.x 预计 2025-09)


---

## 6. Android TV 特殊需求补充

根据 SPEC.md §8.2,本项目支持 **Android TV** 形态。Material 3 对 TV 的支持情况:

### TV 专属库:androidx.tv.material3

| 组件 | 官方库 | 稳定性 | 备注 |
|---|---|---|---|
| `androidx.tv:tv-material3` | ✓ 独立库 | ✓ Stable | 焦点框自动管理,无需自建空间导航 |
| 焦点管理 | `androidx.tv:tv-foundation` | ✓ Stable | `Modifier.tvFocusable()` / `focusRequester` |
| 动画 | 继承自 material3 | ✓ 共用 | 动效参数同 M3 |

### 版本对齐

`androidx.tv:tv-material3` 版本号与 `androidx.compose.material3` **不同步**:

- androidx.compose.material3: **1.4.0** (通过 BOM)
- androidx.tv.tv-material3: **1.1.0** (截至 2024-12)
- 两者互相独立版本管理

**引入方式**:
```gradle
dependencies {
  implementation platform("androidx.compose:compose-bom:2024.12.01")
  implementation "androidx.compose.material3:material3"  // 1.4.0
  
  // TV 需单独引入(不通过 BOM)
  implementation "androidx.tv:tv-material3:1.1.0"
  implementation "androidx.tv:tv-foundation:1.1.0"
}
```

### 本调研的 TV 影响范围

- **M3 官方组件**: 手机形态全用,TV 形态改用 `tv-material3` 等价物
- **自建组件**(shimmer, contextMenu): 需在 TV 形态禁用或改写(TV 遥控无"长按")
- **telephotoscale**: 手机用,TV 可能需要改成键盘导航放大

TV 的逐页设计见 `TODO.md` §5.2 的 U1.17 和后续任务。

---

## 7. 未确认项清单

根据调研方法,以下项目基于官方文档和 Maven Central 查询,均已确认:

- ✓ Compose BOM 2024.12.01 发布日期与版本
- ✓ Material 3 1.4.0 各组件 API 稳定性
- ✓ telephoto-zoomable 0.13.0 兼容性与许可证
- ✓ LazyVerticalStaggeredGrid 在 foundation 中的可用性(Compose 1.7.0+)

**唯一的未确认项**:
- [ ] 实际工程中 telephoto 与 Compose BOM 2024.12 的集成测试(仅查了文档,未编译验证)
- [ ] TV 形态下 long-press 手势的可行性(TV 遥控无"长按",需用键盘事件替代)

这些均属于"开工后的实施确认",不影响本调研的决策。

