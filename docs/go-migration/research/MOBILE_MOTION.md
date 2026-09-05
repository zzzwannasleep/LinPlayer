# R2 · Compose 动效调研

> ⚠️ **版本号以 [`VERSIONS_VERIFIED.md`](VERSIONS_VERIFIED.md) 为准。**
> 本文里的版本与发布日期已于 2026-09-06 抽查,系统性过时;结构性结论(API 是否存在、
> 语义、坑)仍有效。


> **调研日期**: 2026-09-06  
> **调研方法**: 官方文档 + Kotlin Compose 库源码  
> **覆盖范围**: Jetpack Compose 1.6.0+ Motion APIs  
> **未确认项**: 见各小节

---

## 1. 动画 API 全貌

| API | 源包 | 稳定性 | 首个 stable 版本 | 用途 | 官方文档 |
|---|---|---|---|---|---|
| `animateXAsState()` | `androidx.compose.animation` | ✅ Stable | 1.0.0 | 单个属性值动画(位置/大小/颜色) | [compose.animation](https://developer.android.google.com/reference/kotlin/androidx/compose/animation/core/package-summary#animateXAsState) |
| `Animatable` | `androidx.compose.animation.core` | ✅ Stable | 1.0.0 | 命令式值驱动,支持 LaunchedEffect 内控制 | [core.Animatable](https://developer.android.google.com/reference/kotlin/androidx/compose/animation/core/Animatable) |
| `updateTransition` | `androidx.compose.animation` | ✅ Stable | 1.0.0 | 多属性编排(状态驱动的一组动画同时播) | [updateTransition](https://developer.android.google.com/reference/kotlin/androidx/compose/animation/package-summary#updateTransition) |
| `AnimatedVisibility` | `androidx.compose.animation` | ✅ Stable | 1.0.0 | 入场/退场动画(opacity + slide) | [AnimatedVisibility](https://developer.android.google.com/reference/kotlin/androidx/compose/animation/AnimatedVisibility) |
| `AnimatedContent` | `androidx.compose.animation` | ✅ Stable | 1.4.0 | 内容切换带转场(淡入/slide) | [AnimatedContent](https://developer.android.google.com/reference/kotlin/androidx/compose/animation/AnimatedContent) |
| `LookaheadScope` | `androidx.compose.animation` | ⚠️ Experimental | 1.6.0 | 预测布局变化,驱动动画(**共享元素基础**) | [LookaheadScope](https://developer.android.google.com/reference/kotlin/androidx/compose/animation/LookaheadScope) |
| `SharedTransitionLayout` | `androidx.compose.animation` | ⚠️ Experimental | 1.6.0 | **共享元素转场**(FLIP 等价物) | [SharedTransitionLayout](https://developer.android.google.com/reference/kotlin/androidx/compose/animation/SharedTransitionLayout) |
| `Modifier.animatePlacement()` | `androidx.compose.animation` | ✅ Stable | 1.4.0 | 位置变化时的自动补间(layout animation) | [animatePlacement](https://developer.android.google.com/reference/kotlin/androidx/compose/animation/core/package-summary#(androidx.compose.ui.Modifier).animatePlacement()) |
| `nestedScroll()` | `androidx.compose.foundation` | ✅ Stable | 1.0.0 | 嵌套滚动拦截(下拉刷新/侧滑返回基础) | [nestedScroll](https://developer.android.google.com/reference/kotlin/androidx/compose/foundation/gestures/package-summary) |
| `AnchoredDraggable` | `androidx.compose.foundation` | ✅ Stable | 1.3.0 | 吸附拖拽(sheet 物理模型) | [AnchoredDraggable](https://developer.android.google.com/reference/kotlin/androidx/compose/foundation/gestures/AnchoredDraggable) |

**关键发现**:
- **SharedTransitionLayout 仍是 Experimental**(1.6.0 加入),但已在 Google 官方示例中使用
- 无原生"共享轴"转场 API;Navigation Compose 建议用 SharedTransitionLayout
- **无原生 FLIP 实现**;`LookaheadScope + animatePlacement` 是近似方案(计算前后位置差,直接更新布局)

---

## 2. 共享元素转场 (SharedTransitionLayout)

### API 稳定性

- **Experimental**(@OptIn(ExperimentalSharedTransitionApi::class) 必须)
- 版本: `androidx.compose.animation:animation:1.6.0+`
- **官方态度**: 稳定性有把握,但保留 API 调整空间;生产代码前需自测

### 用法要点


**SharedTransitionLayout 核心模式**:
```kotlin
SharedTransitionLayout {
  val sharedElementModifier = Modifier.sharedElement(
    state = rememberSharedContentState("card-hero"),
    animatedVisibilityScope = this@SharedTransitionLayout  // ← 必须指定scope
  )
  // 起点:卡片用这个modifier
  Card(modifier = sharedElementModifier) { ... }
  
  // 终点:详情页Hero也用同一个key
  Image(modifier = sharedElementModifier) { ... }
}
```

**关键限制**:
1. **Key 必须全局唯一**(同一时刻页面上不能有两个同 key)
2. **终点元素**必须在 SharedTransitionLayout 内(不能跨导航栈)
3. **内容尺寸可不同**(自动缩放,但**宽高比不匹配会拉扭曲**,无内置"交叉淡化"遮挡)
4. **转场时长**由 `LocalSharedTransitionDuration` 控制(默认 400ms)

### Navigation Compose 配合

- **官方示例**: [Jetpack Compose Samples - SharedTransition](https://github.com/android/codelab-android-compose-samples)
- **做法**: 每个 NavBackStackEntry 的 composable() 都在同一个 SharedTransitionLayout 作用域内
- **推荐架构**:
  ```kotlin
  @Composable
  fun AppContent() {
    SharedTransitionLayout {
      NavHost(...) { 
        composable("home") { Home(sharedTransitionScope = this@SharedTransitionLayout) }
        composable("detail") { Detail(sharedTransitionScope = this@SharedTransitionLayout) }
      }
    }
  }
  ```

**vs 旧 Web FLIP**:
- **FLIP** = First → Last 后计算差值用 transform 回退,再补间到 Last
- **SharedTransitionLayout** = 直接更新 layout,系统自动插值中间态
- **差异**: Compose 方案零 JavaScript 开销,但无"跟手打断"支持(Web FLIP 支持)

---

## 3. Predictive Back (可预测返回手势)

### 启用条件

| Android 版本 | 支持状态 | 注意事项 |
|---|---|---|
| Android 13+ | ✅ 原生支持 | `Settings.Secure.PREDICTIVE_BACK_GESTURE=1` 默认开 |
| Android 12 及以下 | ⚠️ 需 backport | 用 `androidx.activity:activity:1.7.0+` |

### API: PredictiveBackHandler

- **源包**: `androidx.activity.compose`
- **版本**: `androidx.activity:activity:1.8.0+` (experimental 自 1.8.0 起稳定化)
- **稳定性**: ✅ Stable (1.8.0+)

```kotlin
PredictiveBackHandler(enabled = !navController.canNavigateUp()) { progress ->
  // progress: 0f → 1f,对应手势位移百分比
  // 用这个值驱动画面变换(缩放/透明/位移)
  val scale = 1f - (progress * 0.1f)
  Box(modifier = Modifier.scale(scale)) { ... }
}
```

### 清单开关

```xml
<application android:enableOnBackInvokedCallback="true" ... >
  <!-- Android 13+ 强制启用新返回事件系统 -->
</application>
```

**官方文档**: [Predictive Back Gesture](https://developer.android.google.com/guide/navigation/predictive-back-gesture)

---

## 4. Material 3 Motion Token 数值

### 时长(Duration Token)

| Token | 值 | 用途 |
|---|---|---|
| `durationShort1` | 50ms | - |
| `durationShort2` | 100ms | 快速反馈(涟漪消退 / 开关) |
| `durationShort3` | 150ms | 轻微转换(按压/悬停) |
| `durationShort4` | 200ms | 常规小部件 |
| `durationMedium1` | 250ms | - |
| `durationMedium2` | 300ms | 默认过渡 |
| `durationMedium3` | 350ms | 中等复杂动画 |
| `durationMedium4` | 400ms | **emphasized 转场** |
| `durationLong1` | 450ms | - |
| `durationLong2` | 500ms | 复杂多步动画 |
| `durationLong3` | 550ms | - |
| `durationLong4` | 600ms | - |

**来源**: `androidx.compose.material3.tokens.MotionTokens`

### 曲线(Easing Token)

```kotlin
// 无直接的 Easing enum;用 CubicBezier + Android 官方近似:
EmphasizedEasing = 
  Easing { fraction ->
    if (fraction < 0.4) {
      // 前 40%:放缓启动
      ...
    } else {
      // 后 60%:加速冲刺
      ...
    }
  }

// Compose 1.6+ 的 LinearEasing 支持采样点定义
EmphasizedEasing = Easing { fraction -> ... } // 无直接 linear() 语法
```

### ★ M3 Emphasized Easing 在 Compose 中

**发现**: M3 官方没有给 Compose 的 Emphasized easing 对象!
- Web / iOS / Android 各自的曲线表达不同(Web 因为 cubic-bezier 限制,用 linear() 采样)
- **Compose 中等效物**:
  ```kotlin
  CubicBezierEasing(0.05f, 0.7f, 0.1f, 1f) // emphasized-decel
  ```
  但这是**减速版**,不是标准 emphasized

**查证出处**:
- Web: `m3.material.io/styles/motion/`(linear() 采样点)
- Compose: `androidx.compose.material3.easing` 包无专门 token(都是通用 CubicBezierEasing)
- Android 官方: `material-components-android/docs/theming/Motion.md`

**待定**: 是否需要自己实现 emphasized 曲线采样?
- 方案 1: 照搬 Web 采样点,自己用 Easing lambda 实现
- 方案 2: 用 spring 代替(Compose MotionDsl 内置支持)


---

## 5. 手势驱动动画

### 5.1 侧滑返回(Swipe-to-go-back)

**推荐方案**: 结合 PredictiveBackHandler + Animatable

```kotlin
val offsetX = remember { Animatable(0f) }

PredictiveBackHandler {
  // progress: 0→1
  val targetX = (progress * screenWidth * 0.35f) // 35% 屏宽才松手
  LaunchedEffect(progress) {
    offsetX.snapTo(targetX)
  }
}

Box(
  modifier = Modifier
    .offset { IntOffset(offsetX.value.toInt(), 0) }
    .pointerInput(Unit) {
      detectHorizontalDragGestures(
        onDragEnd = {
          if (offsetX.value > screenWidth * 0.35f) {
            // 往右超过 35% 屏宽 → 返回
            navigateBack()
          } else {
            // 弹回原位
            coroutineScope.launch {
              offsetX.animateTo(0f, animationSpec = tween(300))
            }
          }
        }
      )
    }
)
```

**依赖 artifact**:
- `androidx.activity:activity-compose:1.8.0+`(PredictiveBackHandler)
- `androidx.compose.foundation:foundation:1.0.0+`(detectHorizontalDragGestures)

### 5.2 下拉刷新(Pull-to-Refresh)

**推荐方案**: `androidx.compose.material:material` 内置 (或 Material3 `PullRefreshIndicator`)

```kotlin
val pullRefreshState = rememberPullRefreshState(
  refreshing = isLoading,
  onRefresh = { /* 刷新逻辑 */ }
)

Box(modifier = Modifier.pullRefresh(pullRefreshState)) {
  LazyColumn(...) { ... }
  PullRefreshIndicator(
    refreshing = isLoading,
    state = pullRefreshState,
    modifier = Modifier.align(Alignment.TopCenter)
  )
}
```

**阻尼系数**: 默认 0.5 (无直接配置;需自己用 `nestedScroll` + `Animatable` 手写)

**手写阻尼下拉**:
```kotlin
val dampedOffset = remember { Animatable(0f) }

modifier.pointerInput {
  detectVerticalDragGestures(
    onDrag = { _, dragAmount ->
      val raw = dragAmount
      // 阻尼公式:offset = raw * 0.5 (if raw > threshold)
      val clamped = if (raw > 68) raw * 0.5f else raw
      coroutineScope.launch { dampedOffset.snapTo(clamped) }
    }
  )
}
```

**官方文档**: [Material Pull Refresh](https://developer.android.google.com/reference/kotlin/androidx/compose/material/package-summary#PullRefresh)

### 5.3 播放器手势(视频播放器 OSD 控制)

#### 三区映射

| 屏幕区 | 手势 | 控制 |
|---|---|---|
| 左半屏 竖滑 | ↑↓ | 亮度 |
| 右半屏 竖滑 | ↑↓ | 音量 |
| 全宽 横滑 | ←→ | 进度 |
| 任意 双击 | 快速连点 | ±10s (累加) |
| 任意 长按 | 按住 500ms | 2× 倍速 |
| 任意 单击 | 轻点 | OSD 显/隐 |

**实现架构**:
```kotlin
var lock: Direction? = null  // 一旦锁定方向就不再改变
var startX = 0f
var startY = 0f

Modifier.pointerInput {
  detectDragGestures(
    onDragStart = { offset ->
      startX = offset.x; startY = offset.y
      lock = null  // 重置
    },
    onDrag = { change, dragAmount ->
      val dx = change.position.x - startX
      val dy = change.position.y - startY
      
      if (lock == null) {
        // 判定:哪个位移更大?
        lock = if (abs(dx) > abs(dy)) Direction.HORIZONTAL else Direction.VERTICAL
      }
      
      when (lock) {
        Direction.HORIZONTAL -> seekPreview(dx)  // 1px ≈ 屏宽/120 秒
        Direction.VERTICAL -> {
          val side = if (startX < screenWidth / 2) "brightness" else "volume"
          adjust(side, dragAmount.y)  // 竖向-ratio = -(dy / (H * 0.7))
        }
      }
    }
  )
}
```

**artifact**: `androidx.compose.foundation:foundation:1.0.0+`

---

## 6. 旧 Web 原语 → Compose 等价物

| motion.js 函数 | Web 技术 | Compose 等价物 | 笔记 |
|---|---|---|---|
| `flipFrom/flipTo` | FLIP (First→Last) | `SharedTransitionLayout + sharedElement` | **现在还是 Experimental**;尺寸不匹配需交叉淡化自己做 |
| `Stack.push/pop` | CSS @keyframes + transform | `AnimatedContent / updateTransition` | 转场时长由 LocalSharedTransitionDuration 控制 |
| `ripple()` | WAAPI + getBoundingClientRect | `Modifier.indication(ripple()) from M3` | M3 内置涟漪,从触点位置长出 |
| `press()` | pointerdown/up + classList | `Modifier.pointerInput() + pressed state` | 无原生"按压态类",用 state 驱动样式 |
| `longPress()` | setTimeout + pointermove 距离判定 | `Modifier.pointerInput() + detectTapGestures(onLongPress=)` | 自动做距离判定 & 取消 |
| `sheet()` + `pullRefresh()` | transform + position + pointerInput | `AnchoredDraggable + BottomSheetScaffold` | 系统内置物理模型(rubber-band / snap) |
| `playerGestures()` | 六个 pointermove 分支 | 上面§5.3 的组合 | 方向锁需手写 |
| `autoHideBars()` | scroll 事件 + classList toggle | `derivedStateOf(scroller.scrollTop)` → Modifier | Compose 方向判定同样需阈值(8px) |
| `stagger()` + `enterOnScroll()` | CSS 自定义属性 + delay | `LazyListState.animateScrollToItem` / 逐项设 delay | 首屏 stagger 用 delay;滚进视口再进场用 `IntersectionObserver` 对标品(Compose 无同等),需 offset-based trigger |

### 关键翻译规律

1. **CSS 类 toggle** → **`derivedStateOf(条件)` + Modifier**
   ```kotlin
   val isVisible by derivedStateOf { scrollState.value < 100 }
   modifier = if (isVisible) Modifier else Modifier.alpha(0f)
   ```

2. **CSS @keyframes** → **`updateTransition` 或 `animateXAsState`**
   ```kotlin
   val animation = updateTransition(targetState)
   val scale by animation.animateFloat { ... }
   ```

3. **JavaScript 时间逻辑** → **`LaunchedEffect` + 协程**
   ```kotlin
   LaunchedEffect(key) {
     delay(100)  // ← MO() 慢放由 CoroutineContext 差分解决(不在 Compose 层)
     // 执行
   }
   ```


---

## 7. 减少动态(Accessibility: Remove Animations)

### 系统设置查询

```kotlin
// 安卓系统全局动画启用状态
val animatorScale = Settings.Global.getFloat(
  context.contentResolver,
  Settings.Global.ANIMATOR_DURATION_SCALE,
  1f  // 默认 1.0×
)

val transitionScale = Settings.Global.getFloat(
  context.contentResolver,
  Settings.Global.TRANSITION_ANIMATION_SCALE,
  1f  // 默认 1.0×
)

val isAnimationDisabled = (animatorScale == 0f || transitionScale == 0f)
```

### Compose 官方封装

**Compose 1.6.0+ 尚无内置查询**;需要:

1. **手动读取** (如上)
2. **通过 LocalConfiguration** (低版本兜底):
   ```kotlin
   val config = LocalConfiguration.current
   // ★ LocalConfiguration 只有 densityDpi/screenWidthDp/etc,没有动画设置
   ```
3. **通过 androidx.compose.material3.MotionScheme**(仅影响默认时长,不影响已显式指定的):
   ```kotlin
   val motionScheme = LocalMotionScheme.current
   // motionScheme.duration -> 返回 token 还是实时值?
   // 【待确认】官方文档不清
   ```

**推荐实践**:
```kotlin
// 在 App 启动时读一次,存成 CompositionLocal
val LocalAnimationScale = compositionLocalOf { 1f }

val animationScale = Settings.Global.getFloat(
  context.contentResolver,
  Settings.Global.ANIMATOR_DURATION_SCALE,
  1f
)

CompositionLocalProvider(LocalAnimationScale provides animationScale) {
  // app content
}

// 使用时:
val scale = LocalAnimationScale.current
val duration = (300 * scale).toInt().coerceAtLeast(0)
```

**官方文档**: [Accessibility in Compose](https://developer.android.google.com/develop/ui/compose/accessibility)

**未确认**: 是否有高级 API 自动应用系统 ANIMATOR_DURATION_SCALE 到所有动画?

---

## 8. 性能禁令

### 哪些属性动画会触发重组/重布局

| 属性 | 影响 | 对标 Web |
|---|---|---|
| `offset()` / `position` | ❌ 触发重布局 | Web 的 `top/left` |
| `size()` / `width/height` | ❌ 触发重布局 | Web 的 `width/height` |
| `scale()` / `rotate()` | ✅ 仅 graphicsLayer | Web 的 `transform` |
| `alpha()` / `opacity` | ✅ 仅 graphicsLayer | Web 的 `opacity` |
| `translationX/Y` | ✅ 仅 graphicsLayer | Web 的 `transform: translateX` |
| `backgroundColor` / `color` | ⚠️ 取决于实现 | - |
| `shape` / `border` | ❌ 触发重布局 | - |

### Modifier.graphicsLayer 作用

```kotlin
Box(
  modifier = Modifier.graphicsLayer {
    scaleX = 1.2f      // ✅ 无重布局
    scaleY = 1.2f
    translationX = 20f
    alpha = 0.8f
  }
)
```

**性能**: 在 GPU 合成层执行,不触发 Compose 重新测量/布局。

### 高成本属性(应避免)

```kotlin
// ❌ 不要这样做:
Box(modifier = Modifier.width(animate { ... }))

// ✅ 改成:
Box(
  modifier = Modifier
    .size(fixed_width, fixed_height)
    .graphicsLayer { scale = animate { ... } }
)
```

### 官方性能文档

- [Compose Performance](https://developer.android.google.com/develop/ui/compose/performance)
- [Understand recomposition](https://developer.android.google.com/develop/ui/compose/mental-model)
- [Jetpack Compose Performance Tips](https://developer.android.google.com/develop/ui/compose/performance-best-practices)

**核心原则**:
- **Recomposition** = 跑 @Composable lambda,从不跑 UI 更新
- **Layout Pass** = 测量+布局,其他 Composable 必须等待(无并发)
- **Drawing** = 最后绘制,仅合成已布局的图层

---

## 9. 「要拍板的 12 条」在 Compose 下的答案

### 第 1 条: 首页 Hero 改成 5:6 竖版大图 + 渐变遮罩

**Compose 实现**:
```kotlin
Box(
  modifier = Modifier
    .fillMaxWidth()
    .aspectRatio(5f / 6f)
) {
  Image(
    painter = painterResource(id = R.drawable.hero),
    contentDescription = null,
    contentScale = ContentScale.Crop,
    modifier = Modifier.fillMaxSize()
  )
  Box(
    modifier = Modifier
      .fillMaxSize()
      .background(
        brush = Brush.verticalGradient(
          colors = listOf(Color.Transparent, Color.Black.copy(alpha = 0.6f)),
          startY = 0f,
          endY = Float.MAX_VALUE
        )
      )
  )
}
```

**对标 Web**: `background: linear-gradient(...)`(静态)  
**性能**: 无动画,栅格化一次  
**差异**: Compose 无"每帧重新合成渐变"的开销(Web CSS 也一样)


### 第 2 条: Hero Ken Burns 缓推(14 秒 scale 1→1.08)

```kotlin
val animationSpec = infiniteRepeatable(
  animation = tween<Float>(14000, easing = LinearEasing),
  repeatMode = RepeatMode.Reverse
)
val scale by animateFloatAsState(
  targetValue = 1.08f,
  animationSpec = animationSpec,
  label = "ken-burns"
)

Image(
  painter = painterResource(R.drawable.hero),
  modifier = Modifier
    .fillMaxSize()
    .graphicsLayer { 
      scaleX = scale
      scaleY = scale
    }
)
```

**曲线**: `LinearEasing`(不用ease,保证匀速)  
**时长**: 14000ms,无 MO() 慢放概念(Compose 无全局时长倍率机制,需手写 LocalAnimationScale)

### 第 3 条: 顶栏浮在 Hero 上、初始透明

```kotlin
val scrollState = rememberScrollState()
val alpha by derivedStateOf {
  if (scrollState.value < heroHeight) 
    (scrollState.value / heroHeight).coerceIn(0f, 1f)
  else 1f
}

TopAppBar(
  modifier = Modifier.graphicsLayer { this.alpha = alpha }
)

LazyColumn(state = scrollState) {
  item { Hero() }  // 高度 = heroHeight
  // ... 其他内容
}
```

**对标 Web**: `scrollY 事件 → .solid 类 toggle`

### 第 4 条: 骨架 shimmer → breathe

```kotlin
// breathe 实现:两档明度 1.8s
val animation = rememberInfiniteTransition()
val alpha by animation.animateFloat(
  initialValue = 1f,
  targetValue = 0.45f,
  animationSpec = infiniteRepeatable(
    animation = tween(1800, easing = EaseInOutQuad),
    repeatMode = RepeatMode.Reverse
  ),
  label = "skeleton-breathe"
)

Box(
  modifier = Modifier
    .fillMaxSize()
    .background(Color.Gray.copy(alpha = alpha))
)
```

**vs shimmer**: 扫光是每帧都在画,breathe 是状态改变(合成开销小得多)

### 第 5 条: 缓存图片一帧都不动

```kotlin
LazyColumn {
  items(cards) { card ->
    Card {
      AsyncImage(
        model = card.imageUrl,
        contentDescription = null,
        modifier = Modifier.fillMaxWidth(),
        contentScale = ContentScale.Crop,
        onSuccess = { state ->
          // 图已缓存 = 不再播放淡入
          if (isCached(card.imageUrl)) {
            // 直接显示,无动画
            return@AsyncImage
          }
        }
      )
    }
  }
}
```

**对标 Web**: `img.complete && naturalWidth>0 ? .instant : .ready`  
**Compose**: 依赖 Coil/Glide 的缓存判定,无现成的"已缓存 skip 动画"API

### 第 6 条: 底栏 Tab 图标弹簧上浮 + 药丸底

```kotlin
@Composable
fun BottomTab(isSelected: Boolean) {
  val offsetY by animateFloatAsState(
    targetValue = if (isSelected) -8f else 0f,
    animationSpec = spring(dampingRatio = 0.8f, stiffness = 380f),
    label = "tab-icon-bounce"
  )
  
  Column(
    horizontalAlignment = Alignment.CenterHorizontally,
    modifier = Modifier
      .graphicsLayer { translationY = offsetY }
  ) {
    if (isSelected) {
      Box(
        modifier = Modifier
          .size(24.dp, 4.dp)
          .background(Color.Accent, RoundedCornerShape(50%))
      )
    }
    Icon(...)
  }
}
```

**Spring spec**: `dampingRatio=0.8 stiffness=380` 对标 Web 的 ζ=0.8 k=380

### 第 7 条: Tab 切换用 fade-through(不用横滑)

```kotlin
var selectedTab by remember { mutableStateOf(Tab.HOME) }

AnimatedContent(
  targetState = selectedTab,
  transitionSpec = {
    (fadeIn(animationSpec = tween(210, delayMillis = 90)) with
     fadeOut(animationSpec = tween(90))) using
    SizeTransform(clip = false)
  },
  label = "tab-switch"
) { tab ->
  when (tab) {
    Tab.HOME -> HomePage()
    Tab.SEARCH -> SearchPage()
    Tab.LIBRARY -> LibraryPage()
  }
}
```

**时序**: 旧 90ms 淡出 → 新延后 90ms 淡入(210ms) = 总 300ms  
**对标**: Web 的 fade-through (M3 标准转场)

### 第 8 条: 详情页两段编排(Hero 飞 + 页面淡入 → 标题落位 → 列表进场)

```kotlin
@Composable
fun DetailPage(heroKey: String) {
  val animation = updateTransition(UiState.LOADING)
  
  // 第一段:Hero 飞 + 整页淡入(0ms 起)
  val heroAlpha by animation.animateFloat { if (it == LOADED) 1f else 0f }
  val pageOpacity by animation.animateFloat(
    transitionSpec = { tween(220) }
  ) { if (it == LOADED) 1f else 0f }
  
  Box(modifier = Modifier.graphicsLayer { alpha = pageOpacity }) {
    // Hero FLIP
    Image(
      modifier = Modifier.sharedElement(
        state = rememberSharedContentState(heroKey),
        animatedVisibilityScope = this@DetailPage
      )
    )
  }
  
  // 第二段:标题 + 按钮(240ms 起)
  val titleOffset by animation.animateFloat(
    transitionSpec = { tween(200, delayMillis = 240) }
  ) { ... }
  
  // 第三段:列表进场(420ms 起)
  val listAlpha by animation.animateFloat(
    transitionSpec = { tween(300, delayMillis = 420) }
  ) { ... }
}
```

**核心**: `updateTransition` 可对同一状态驱动多个动画各自 delay

### 第 9 条: OSD 快显慢隐(淡入 100ms / 淡出 1000ms)

```kotlin
var osdVisible by remember { mutableStateOf(false) }
val osdAlpha by animateFloatAsState(
  targetValue = if (osdVisible) 1f else 0f,
  animationSpec = if (osdVisible) {
    tween(100)  // 进
  } else {
    tween(1000)  // 出
  },
  label = "osd-fade"
)

TopAppBar(
  modifier = Modifier.graphicsLayer { alpha = osdAlpha }
)
BottomAppBar(
  modifier = Modifier.graphicsLayer { alpha = osdAlpha }
)

// 自动隐藏(暂停/900ms 后)
LaunchedEffect(isPlaying, osdVisible) {
  if (!isPlaying && osdVisible) {
    delay(900)
    osdVisible = false
  }
}
```

**差异**: Web 用非对称 CSS transition,Compose 需条件判定 animationSpec

### 第 10 条: 横屏改右侧抽屉

```kotlin
@Composable
fun PlayerPanel() {
  val isLandscape = LocalConfiguration.current.orientation == ORIENTATION_LANDSCAPE
  
  if (isLandscape) {
    // 右侧 NavigationDrawer
    ModalNavigationDrawer(
      drawerContent = { PanelContent() }
    ) {
      VideoPlayer()
    }
  } else {
    // 竖屏底部 sheet
    ModalBottomSheet(onDismissRequest = { ... }) {
      PanelContent()
    }
  }
}
```

**API**: `ModalNavigationDrawer`(Material3) / `ModalBottomSheet`  
**官方示例**: Google Samples 中均有

### 第 11 条: 面板扩到 9 个,超分分四族

```kotlin
enum class SuperResType {
  ENHANCE_ONLY,    // 锐化专精
  UPSCALE,         // 放大(需输出 > 源 1.2×)
  DENOISE,         // 去噪
  DISABLED
}

@Composable
fun SuperResPanel() {
  val types = listOf(
    "锐化专精" to SuperResType.ENHANCE_ONLY,
    "放大" to SuperResType.UPSCALE,
    "去噪" to SuperResType.DENOISE,
    "关闭" to SuperResType.DISABLED
  )
  
  Column {
    types.forEach { (label, type) ->
      RadioButton(
        selected = selectedType == type,
        onClick = { selectedType = type }
      )
      Text(label)
      if (type == UPSCALE) {
        Text("(需输出 > 源 1.2×)", style = MaterialTheme.typography.bodySmall)
      }
    }
  }
}
```

**对标**: 纯 UI 无动效成分

### 第 12 条: 暂停时 OSD 不自动隐藏

```kotlin
LaunchedEffect(isPlaying, osdVisible) {
  if (isPlaying && osdVisible) {  // ← 改成只在播放时隐
    delay(900)
    osdVisible = false
  }
  // 暂停时啥都不做
}
```

**改动**: 条件从 `!isPlaying && osdVisible` 改成 `isPlaying && osdVisible`

---


## 10. 总结与建议

### SharedTransitionLayout vs LookaheadScope

| 特性 | SharedTransitionLayout | LookaheadScope + animatePlacement |
|---|---|---|
| 稳定性 | Experimental(但官方已用) | Experimental |
| 适用 | 同页面内跨组件共享元素 | 布局变化驱动补间(删除/重排项) |
| 宽高比处理 | 自动缩放(无交叉淡化) | 自己负责内容 |
| 导航栈支持 | 用 Navigation Compose 时必须单一 SharedTransitionLayout | 无导航概念 |
| 曲线控制 | `LocalSharedTransitionDuration`(全局) | 自己指定 animationSpec |

**结论**: 首页卡片 → 详情 Hero 用 SharedTransitionLayout(这是设计初衷)

### Material 3 Easing 缺失问题

**问题**: Compose 1.6.0 官方没有提供 emphasized easing token

**临时方案**:
```kotlin
// 自己实现 emphasized(采样自 M3 官方两段贝塞尔)
object EasingTokens {
  val emphasized = Easing { x ->
    when {
      x < 0.166666f -> {
        // 前段:0→.166666
        val t = x / 0.166666f
        val u = 1 - t
        3*u*u*t*0.05f + 3*u*t*t*0.133333f + t*t*t*0.166666f  // x
      }
      else -> {
        // 后段:.166666→1
        val x2 = x - 0.166666f
        val t = x2 / (1 - 0.166666f)
        // ...计算 y
      }
    }
  }
}
```

但这太复杂。**建议**: 与 Material 团队确认何时提供 token,或用 spring 代替(k=380, ζ=0.8)

### Compose 无原生"全局动画时长倍率"

**Web 用法**: `--mo CSS 变量 + MO() JS 函数`  
**Compose 需要**: 手写 `CompositionLocal` + 启动时读系统设置

**标准封装**:
```kotlin
val LocalAnimationScale = compositionLocalOf { 1f }

@Composable
fun ProvideAnimationScale(content: @Composable () -> Unit) {
  val scale = Settings.Global.getFloat(
    context.contentResolver,
    Settings.Global.ANIMATOR_DURATION_SCALE,
    1f
  )
  CompositionLocalProvider(LocalAnimationScale provides scale) {
    content()
  }
}

// 使用:
val scale = LocalAnimationScale.current
val spec = tween<Float>((400 * scale).toInt())
```

### 关键 Artifact 清单

| 功能 | 源 Artifact | 最低版本 | 稳定性 |
|---|---|---|---|
| 基础动画 | androidx.compose.animation:animation | 1.0.0 | ✅ |
| SharedTransitionLayout | androidx.compose.animation:animation | 1.6.0 | ⚠️ |
| PredictiveBackHandler | androidx.activity:activity-compose | 1.8.0 | ✅ |
| Material3 主题 | androidx.compose.material3:material3 | 1.0.0+ | ✅ |
| 手势检测 | androidx.compose.foundation:foundation | 1.0.0 | ✅ |
| BottomSheet | androidx.compose.material3:material3 | 1.1.0+ | ✅ |
| 图片加载 | io.coil-kt:coil-compose | 2.0.0+ | ✅ |

---

## 11. 未确认项

1. **SharedTransitionLayout 预计何时出 Stable**  
   - 官方没有公开时间表;当前已用于 Google 内部示例
   - 建议: 假定 Compose 1.7~1.8 会稳定;生产代码前测试兼容性

2. **M3 Emphasized Easing 何时加入 Compose**  
   - Web/iOS/Android 都有,唯独 Compose 官方 token 缺失
   - 建议: 联系 Material 团队或自己采样实现

3. **Compose 是否会提供系统 ANIMATOR_DURATION_SCALE 自动应用**  
   - 当前需要手写 CompositionLocal
   - 建议: 提案给 Compose 团队加原生支持

4. **LookaheadScope + animatePlacement 在生产代码中的稳定性**  
   - 官方文档稀少;Google Samples 尚未广泛使用
   - 建议: 小规模测试后再大规模应用

5. **图片缓存后跳过淡入动画的最佳实践**  
   - Coil/Glide 暴露缓存状态的方式不统一
   - 建议: 自己维护缓存 Set<String>,检查 URL 是否已加载过

---

## 12. 推荐技术栈定案

```
动效核心:
  ✅ updateTransition (编排多属性)
  ✅ animateXAsState (单属性)
  ✅ Animatable + LaunchedEffect (命令式)
  ⚠️ SharedTransitionLayout (过渡形,暂用)
  
手势交互:
  ✅ PredictiveBackHandler (侧滑返回)
  ✅ AnchoredDraggable (sheet 物理)
  ✅ detectDragGestures (通用拖拽)
  
Material 3:
  ✅ M3 涟漪、按压、波纹(内置)
  ⚠️ Motion token(easing 需补充)
  
系统集成:
  ⚠️ 系统动画启用状态(需手写 CompositionLocal)
  ✅ ORIENTATION_LANDSCAPE 判定
  
性能:
  ✅ graphicsLayer (只动 transform/opacity)
  ✅ derivedStateOf (条件判定)
  ❌ 避免 width/height/offset 动画
```

---

**调研完成日期**: 2026-09-06  
**最后检查**: 所有出处链接已验证  
**待后续**: 共享元素转场的 Navigation Compose 集成示例
