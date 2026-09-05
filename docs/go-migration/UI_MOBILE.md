# LinPlayer 手机端 UI 规格 · Android(Kotlin + Compose + Material 3)

> 配套:架构契约 [`SPEC.md`](SPEC.md) · 命令契约 [`COMMANDS.md`](COMMANDS.md) ·
> PC 端规格 [`UI_PC.md`](UI_PC.md) · 生态调研 [`research/`](research/) ·
> 版本基线 [`research/VERSIONS_VERIFIED.md`](research/VERSIONS_VERIFIED.md)

---

## 0. 这份文档的地位

`SPEC.md` 回答「核心层给什么」,`UI_PC.md` 回答「点了这个该发生什么」,
**本文回答「手机上长什么样、怎么摸」**。

**判据:一个没参与过老版本的人,只读本文 + `SPEC.md` + `COMMANDS.md`,
能把 Android 手机端做出来,且做出来的东西和 PC 端是同一个产品。**

### 三条来源及其权重

| 来源 | 权重 | 说明 |
|---|---|---|
| **用户逐条定过的规格** | 最高,不许改 | 文中标 `【用户定】` |
| **`UI_PC.md` 的行为语义** | 高 | 点了这个该发生什么、错误码怎么映射、空态说什么 —— **继承,不重写** |
| **`docs/mobile-drafts/` 48 格草稿** | 高 | 版式的原始依据。**当设计稿看,代码一行不搬**(那是旧 Web 栈) |

### 分工:什么写这里、什么不写这里

| 内容 | 写哪 |
|---|---|
| 跨端契约(换个 UI 框架还成立) | `SPEC.md`,本文不重复 |
| 行为语义(点了发生什么、错误码映射) | `UI_PC.md`,本文**只写手机端不同的地方** |
| 手机端呈现(换个框架就不成立) | **本文** |

### 标注约定

- `【用户定】` —— 拍过板的,改动要重新问
- `【实测】` —— 有测量数据支撑,数据带出处
- `【待验证】` —— Compose 上的等价行为尚未验证,**不许当成已知**
- `【继承 PC】` —— 语义照 `UI_PC.md` 对应节,本文不重复

### 本轮范围

**做**:16 页(§7)+ 播放页(§8)+ 平台职责(MediaSession / 前台服务 / 音频焦点 /
常亮 / PiP / 深链 / 权限)。
**不做**:TV 形态(`TODO.md` U1.16,单开一轮)、Ani-RSS 管理台(2026-09-04 范围裁剪已砍)、
人物详情、图标库(不在本轮 16 页里,`account.icon` 那条链只做到「换服务器图标」)。

---

## 1. 设计系统

### 1.1 色彩

**语义与 `UI_PC.md` §1.1 对齐,值取 `docs/mobile-drafts/app.css` 的深色一套**
—— 那套是在手机屏上调过的,比 PC 的深色更暗一档(手机常在暗环境看)。
浅色一套由 `UI_PC.md` 的浅色值按同名同义映射过来。

| Compose token(`LpColors`) | 深色 | 浅色 | 语义 | PC 对应 |
|---|---|---|---|---|
| `bg` | `#0E0E13` | `#F1ECE2` | 页面底 | `bg` |
| `s1` | `#17171E` | `#FBF8F1` | 卡片 / 单元格 | `panel` |
| `s2` | `#1E1E27` | `#F5F0E6` | 浮起:弹窗 / 面板 | `panel-alt` |
| `s3` | `#262630` | `#EAE2D2` | 更浮:菜单 / 骨架 | `ph` |
| `line` | `#26262F` | `#E4DCCC` | 发丝线 | `line` |
| `line2` | `#383843` | `#D6CCB6` | 强分隔 | `line-strong` |
| `fg` | `#F4F4F8` | `#2A2622` | 主文字 | `ink` |
| `fg2` | `#A3A3B4` | `#6E6559` | 次要文字 | `ink-2` |
| `fg3` | `#6B6B7C` | `#9C9284` | 三级 / 占位 | `ink-3` |
| `acc` | `#5B8CFF` | `#3F73D6` | 强调 | `accent` |
| `accDim` | `#5B8CFF` @16% | `#3F73D6` @13% | 强调底(选中 / 标签) | `accent-soft` |
| `accFg` | `#FFFFFF` | `#FFFFFF` | 强调底上的文字 | `accent-ink` |
| `ok` | `#37C26A` | `#3E9E6E` | **已看**(不是「绿色」) | `good` |
| `warn` | `#E0A95B` | `#C98A2E` | 警告 | `warn` |
| `bad` | `#FF5F56` | `#C7554E` | 危险 / 删除 | `danger` |
| `scrim` | `#0E0E13` @70% | `#F1ECE2` @70% | 遮罩 | `scrim` |
| `chip` | `#17171E` @55% | `#FFFFFF` @74% | **叠在画面上的玻璃底** | `chip-bg` |

#### 四条不许破的色彩约束

1. **叠在画面上的半透明控件必须用 `chip` token,不许就地写 `Color(0x8C17171E)`。**
   浅色主题下写死深色 = 深底深字看不见(用户 2026-07-16 报过)。
   反过来说:**写死的色号必须带 alpha** —— 不透明的一律进 token(`CLAUDE.md` §1.5)。
2. **`ok` 不是「绿色」是「已看」。** 已看勾、成功 toast 共用它。
3. **强调色只有一个。** 需要层级时用 `accDim` 与不同墨阶,不引第二强调色。
4. **不用 Material You 动态取色(`dynamicColorScheme`)。**
   它会把整个界面染成用户壁纸的颜色,而本产品的底色是「影院沉浸」的一部分 ——
   一个被壁纸染成粉色的播放器不是同一个产品。这条是**主动放弃 M3 默认能力**,
   要改的话先改这一行。

#### 主题切换(U1.18)

- 三态:**跟随系统 / 强制深色 / 强制浅色**,默认跟随系统。
  Compose 侧读 `isSystemInDarkTheme()`,被设置覆盖时用 `prefs` 里的值。
- **资源限定符两份都要建。** 需要按 API 分主题时,`values-vXX` 与 `values-night-vXX`
  **必须同时存在** —— `-night` 压过 `-vXX`,只建一份的表现是「浅色修好了深色没修」。
- **Activity 主题的 `windowBackground` 不能是 `DayNight`。**
  播放时窗口底下是 SurfaceView,`windowBackground` 给了浅白/深黑就是一层不透明底。
  「有声音没画面」的第一嫌疑是它,不是 mpv。

### 1.2 排版

| 项 | 值 |
|---|---|
| 字族 | 系统默认(`FontFamily.Default`)。**不打包自定义字体** —— 中文字体 5MB 起,APK 涨得比它值 |
| 等宽 | `FontFamily.Monospace`(时间码、码率、延迟毫秒) |
| `displayL` | 28 sp / w700 | Hero 标题 |
| `titleL` | 20 sp / w700 | 页面大标题 |
| `titleM` | 16 sp / w650 | 区块标题 / topbar |
| `body` | 14 sp / 1.5 | 正文 |
| `bodyS` | 13 sp | 次要 |
| `label` | 12 sp | 标注 / 卡片副标题 |
| `labelS` | 11 sp | 角标 |

- **单位一律 `sp`,不许用 `dp` 写字号。** 用 `dp` 的字不跟系统字体缩放走,
  这是无障碍底线(§9)。Android 14 起是非线性缩放,`sp` 自动吃到。
- 时长 / 码率 / 延迟用 `FontFeatureSetting("tnum")` 等宽数字,否则每秒都在抖。
- 中文不加 `letterSpacing`。
- **输入框字号 ≥ 16 sp 这条在原生 Compose 上不适用。**
  那是 WebView 的自动放大行为,`BasicTextField` 没有这回事
  (`research/MOBILE_PERF_A11Y.md` §5 有结论)。但仍然写 ≥14 sp,理由是可读性。

### 1.3 间距 · 圆角 · 线

**刻度是枚举,不是区间。要用第五种圆角,先改这张表,别就地写新值。**

| | 允许的值(dp) | 说明 |
|---|---|---|
| **间距** | `0 2 4 6 8 10 12 16 20 26 34 48` | Padding / Arrangement.spacedBy / Modifier.padding 同一把尺 |
| **圆角** | `0 8 12 18 999` | 8=小件(chip / 输入 / 角标)· 12=卡片与单元格 · 18=弹窗与面板 · 999=胶囊圆形 |
| **大偏移** | 超过 48 的**不许写字面数字** | 那不是间距节奏,是「让开某个东西」的高度 —— 抽成具名常量(`OsdClearance`、`TabBarHeight`),否则改了被让开的那个东西没人会想起来改它 |
| **发丝线** | `1.dp` | Compose 的 `1.dp` 在高密度屏上就是 1 物理像素以上,**不许再乘密度** |
| **阴影** | 只有 `cardElevation = 0.dp` + 一条 `line` 边 | 深色底上投影看不见,层次靠 `bg → s1 → s2 → s3` 四阶表面色 |

- `BorderStroke` 的宽度**不在这把尺里** —— 它是边框宽度不是间距,套上去会把发丝线加粗一倍。
- 固定尺寸:`topbar 52` · `tabbar 58` · `tap 48`(最小触摸目标)· `gap 12` · `pad 16`。
  这四个是 `docs/mobile-drafts/app.css` 里定过的,直接搬。

### 1.4 图标

- **单一线性图标族,`strokeWidth 1.75`,24×24 网格,圆头圆角。**
  落法是 `ImageVector` 常量表(`ui/theme/LpIcons.kt`),从 `docs/mobile-drafts/icons.js`
  的 path 逐个转。
- **不引 `material-icons-extended`。** 那个 artifact 有 1000+ 图标、几 MB,
  而我们用到的不超过 40 个;而且它是 Material 填充风,和线性族混在一起一眼能看出两套。
- 图标颜色跟随文字墨阶(`fg` / `fg2` / `fg3`),**不给图标单独配色**。

### 1.5 触摸目标

**≥ 48 dp。** 唯一的例外是**横屏播放器的 chip**:视觉 32 dp(横屏总高只有 ~390 dp),
命中区靠 `Modifier.padding` 外扩到 44 dp。这是记在案的取舍,不是漏做。

Compose 的 `LocalMinimumInteractiveComponentSize` 默认给 M3 组件 48 dp,
**自绘的可点区域不自动吃到** —— 自绘的必须显式 `.size(48.dp)` 或 `.sizeIn(minWidth=48.dp)`。

---

## 2. 动效规范

> 总纲:**动效负责解释空间关系,不负责表演。**
> `UI_PC.md` §2 那条教训在手机上一字不差:「不秒加载」不是动画问题,是加载结构问题
> (串行 await / 屏障,实测慢 5.5 倍)。**动效永远不是性能问题的答案。**

### 2.1 token

来源是 M3 的 motion token(`docs/mobile-drafts/app.css` 已按官方值落过一版,直接搬)。

```kotlin
object LpMotion {
  // 时长:M3 duration token
  const val T1 = 50; const val T2 = 100; const val T3 = 150; const val T4 = 200
  const val T5 = 250; const val T6 = 300; const val T7 = 350; const val T8 = 400
  const val T9 = 450; const val T10 = 500
}
```

| 用途 | 时长 | 曲线 |
|---|---|---|
| 按下 / 开关 / 图标态 | `T3`(150) | `standard` |
| 浮层进出 / 面板切换 | `T5`(250) | `emphasizedDecelerate` 进 / `emphasizedAccelerate` 出 |
| 页面转场 | `T7`(350) | `emphasized` |
| Hero 换图交叉淡入 | `T8`(400) | `standard` |

曲线在 Compose 里的落法:

| 名 | Compose 表达式 |
|---|---|
| `standard` | `CubicBezierEasing(0.2f, 0f, 0f, 1f)` |
| `standardDecelerate` | `CubicBezierEasing(0f, 0f, 0f, 1f)` |
| `standardAccelerate` | `CubicBezierEasing(0.3f, 0f, 1f, 1f)` |
| `emphasizedDecelerate` | `CubicBezierEasing(0.05f, 0.7f, 0.1f, 1f)` |
| `emphasizedAccelerate` | `CubicBezierEasing(0.3f, 0f, 0.8f, 0.15f)` |
| **`emphasized`** | **`Easing { t -> ... }` 分段实现** —— 见下 |

> ★ **M3 的 `emphasized` 不是一段 cubic-bezier。** 官方给的是两段贝塞尔路径
> (`M 0,0 C .05,0 .133,.06 .167,.4 C .208,.82 .25,1 1,1`),Web 侧只能用 `linear()` 近似。
> Compose 的 `Easing` 是 `(Float) -> Float` 的函数接口,**可以直接把两段写进去**,
> 不需要近似:`t < 0.1667f` 走第一段、之后走第二段。
> 写成 `CubicBezierEasing(0.2f, 0f, 0f, 1f)` 的话你拿到的是 **standard**,
> 那是最平淡的一条 —— 这是「动效没质感」的根因之一。

**弹簧**用 Compose 原生的 `spring()`,不再自己解阻尼方程:

| 用途 | 参数 |
|---|---|
| 按压 / 开关(不该弹) | `spring(dampingRatio = 0.9f, stiffness = Spring.StiffnessMedium)` |
| 主力(面板回弹 / 卡片入场) | `spring(dampingRatio = 0.8f, stiffness = Spring.StiffnessMediumLow)` |
| 抢注意力(收藏心跳 / 成功) | `spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMedium)` **只给这两处,到处用会显得廉价** |

### 2.2 转场目录

| 场景 | 做法 | 时长 / 曲线 |
|---|---|---|
| 页面推入 / 弹出 | 新页从右 12% 滑入 + 淡入;旧页左移 4% + 压暗 | `T7` / `emphasized` |
| **侧滑返回** | 跟手,见 §5.2 | 跟手,松手补完 |
| 底栏切 Tab | **只淡入,不位移**(平级切换没有方向) | `T4` / `standard` |
| 卡片 → 详情 Hero | `SharedTransitionLayout` 共享元素 | `T7` / `emphasized` |
| 弹窗 | scrim 淡入 + 卡片 `scale .96→1` | `T5` / `emphasizedDecelerate` |
| Toast | 从出现方向滑入 12 dp + 淡入 | `T5` / `emphasizedDecelerate` |
| 按下反馈 | `scale .97` + M3 ripple | `T3` |
| 封面到位 | 解码完成后淡入,骨架**原地淡出** | `T5` |
| 骨架 → 内容 | 不做尺寸动画,只交叉淡 | `T5` |
| 进度条拖动 | 跟手,**零动画** | — |
| OSD 显隐 | 淡入淡出 | `T5` |
| Hero 换图 | 两层交叉淡入 + Ken Burns 恒速缓推 | `T8` |

**首屏编排**:首屏 12 张卡 stagger 40 ms 进场,**屏幕外的不排队** ——
交给 `LazyGrid` 的 item 可见性触发。全都加 = 一进页面几十个动画同时排队。

### 2.3 三条禁令

**1. 列表项不挂阶梯延迟(超过首屏 12 项)。**
入场 350 ms + 300 ms 阶梯 = 最后一张卡 650 ms 才出现,而且延迟期间完全不可见。
**内容出现不能被动效挡着。** 区块级可以有入场,项级只给首屏那 12 个。

**2. 只动 `graphicsLayer` 能表达的属性(`translation` / `scale` / `alpha` / `rotation`)。**
动 `Modifier.padding` / `size` / `offset(Dp)` 会触发重新布局,整棵子树重测。
`Modifier.offset { IntOffset(...) }`(lambda 版)只在 layout 阶段读值,比 `Dp` 版便宜一档;
真正跟手的东西走 `graphicsLayer`。

**3. 跟手的东西每帧绕过重组。**
拖拽、进度条、播放器手势:跟手期间**不要** `mutableStateOf` + 重组,
用 `Animatable`/`Ref` + `Modifier.graphicsLayer { translationX = ref.value }`
(lambda 版 `graphicsLayer` 只在 draw 阶段读,不触发重组)。
松手后把最终值交回状态。**PC 端进度条就是这么栽的。**

> Web 侧那条「`transform` 会成为 `position:fixed` 的包含块」在 Compose 上不存在
> (没有 fixed 定位)。**但等价风险是 `SubcomposeLayout` / `Popup` 的定位基准** ——
> 【待验证】给页面根挂 `graphicsLayer` 动画,断言长按菜单与 toast 的屏幕坐标不变。

### 2.4 减少动态

跟随系统的「移除动画」设置。落法:

```kotlin
val scale = Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
```

`scale == 0f` 时:所有时长压到 0(保留状态切换,去掉过程)、跑马灯不滚改两行换行、
交叉淡入变直接替换、Ken Burns 停。**这个值要挂在 `CompositionLocal` 上**,
每个动画都乘它 —— 散着判会漏。

---

## 3. 布局与形变

### 3.1 外壳骨架

```
┌──────────────────────────┐  ← 状态栏(edge-to-edge,内容画到底下)
│  安全区内边距 sa.top      │
├──────────────────────────┤
│  topbar 52dp(随滚动实体化)│  ← 一上来不画线,滚了才出底和线
├──────────────────────────┤
│                          │
│  内容(LazyColumn/Grid)   │
│                          │
├──────────────────────────┤
│  tabbar 58dp  首页/聚合/服务器│  ← 只有三个 Tab【用户定】
│  安全区内边距 sa.bottom    │
└──────────────────────────┘  ← 手势导航条
```

- **底栏只有三个 Tab:首页 / 聚合视界 / 服务器。**【用户定】不加第四个。
  搜索并进了聚合页顶部;设置挪到首页右上角。
- **topbar 随滚动实体化**:`scrollState.firstVisibleItemScrollOffset > 0` 时
  加底色 + 一条 `line`。一上来就画线会把首屏切一刀。
- 播放页 / 首登闸口**没有底栏**(全屏页)。

### 3.2 安全区(edge-to-edge)

**Android 15(API 35)起 edge-to-edge 是强制的**,`enableEdgeToEdge()` 只是把它显式化。

| 区 | 拿法 |
|---|---|
| 状态栏 / 刘海 | `WindowInsets.statusBars` / `displayCutout` |
| 手势导航条 / 三键栏 | `WindowInsets.navigationBars` |
| 输入法 | `WindowInsets.ime`(输入框所在页要 `imePadding()`) |
| 合并 | `WindowInsets.safeDrawing` |

☠ **旧 Web 栈那条「`env(safe-area-inset-bottom)` 在安卓 edge-to-edge 下对导航条恒 0」
是 WebView 的坑,在原生 Compose 上不存在** —— `WindowInsets.navigationBars` 是真值。
**但不要因此到处 `safeDrawing`**:那会让列表内容在导航条上方戛然而止。
正确做法是**内容画到底、只给最后一项加 `navigationBarsPadding()` 的 contentPadding**。

☠ **横屏时刘海转到侧边,顶部安全区不再是 44dp。**
草稿上一版全局钉死 44px 不分方向,于是每张横屏页的顶部白让出 11% 的屏幕,
不报错、不错位、只是「顶栏好厚」。Compose 侧用 `displayCutout` 就自动分方向,
**不许自己写常量**。

### 3.3 断点

| 宽度(dp) | 形态 | 落法 |
|---|---|---|
| < 600 | 手机竖屏 | 网格 3 列;详情页单栏 |
| 600–839 | 手机横屏 / 小平板 / 折叠展开 | 网格 5 列;详情页海报与信息并排 |
| ≥ 840 | 大平板 | 网格 6 列;底栏换 `NavigationRail` |

用 `androidx.compose.material3.windowsizeclass` 判,**不要自己量 `configuration.screenWidthDp`**
(分屏时它不等于窗口宽)。

### 3.4 旋屏 / 分屏 / 折叠

**Activity 声明 `configChanges` 吃下 `orientation|screenSize|screenLayout|smallestScreenSize|
keyboardHidden|density|uiMode`,不让系统重建 Activity。**

理由不是省事,是 **surface 生命周期**:重建 Activity 会销毁并重建 SurfaceView,
每转一次屏就要走一遍「阻塞解绑 → 重绑」。100 次快速旋转(U1.28 判据)下,
任何一次解绑没阻塞住就是 use-after-free。少一半的解绑次数就是少一半的机会。

- 折叠屏:`androidx.window` 的 `WindowInfoTracker.windowLayoutInfo` 拿 `FoldingFeature`。
  半折(`HALF_OPENED` + 横向铰链)时播放页把视频放上半屏、OSD 放下半屏。
  **不做「铰链避让」的通用布局** —— 只有播放页值得,别的页按 §3.3 的断点走就够。
- 分屏 / 自由窗口:`isInMultiWindowMode` 为真时**不进 PiP**、不锁方向。

---

## 4. 组件清单与状态矩阵

### 4.1 状态矩阵

**每个可交互组件都必须显式定义这 7 态。**(PC 的 8 态去掉 `hover` —— 手机没有悬停。)

| 态 | 视觉规则 |
|---|---|
| `default` | 基线 |
| `pressed` | `scale .97` + M3 ripple(`s2` 色,`alpha .12`) |
| `focus` | **只在接了实体键盘 / 遥控器时出现**:2 dp `acc` 焦点环。触摸不出 |
| `selected` | 底 `accDim` + 文字 `acc`;单元格左侧 3 dp `acc` 竖条 |
| `disabled` | `alpha .45`,**不改颜色**(改颜色会和 `fg3` 撞) |
| `loading` | 组件内联指示器,**保持原尺寸**(尺寸跳变比转圈更烦人) |
| `error` | 边框 `bad` + 下方 11 sp `bad` 说明 |

### 4.2 组件清单(**页面只能用它拼,不许各页自造**)

散着写必然长出两套间距 —— 这条在 PC 端和 TV 端都栽过。
落在 `ui/components/` 一个包里,页面只 import。

| 组件 | 关键规格 |
|---|---|
| `LpScaffold` | topbar(随滚动实体化)+ body + 可选 tabbar。**每一页的外壳都是它** |
| `LpTopBar` | 返回 / 标题 / 副标题 / 右侧动作槽。标题过长跑马灯(§8.2 的规格) |
| `PosterCard` / `ThumbCard` | 见 §4.3 |
| `LpRow` | 横滑轨道:标题 + 「更多」+ `LazyRow`。骨架态是 4 张空卡 |
| `LpGrid` | `LazyVerticalGrid`,列数按 §3.3 断点 |
| `LpButton` | 主(`acc` 底)/ 次(`s2` 底 + `line` 边)/ 危险(`bad`)/ 幽灵(纯文字)/ 图标(48dp) |
| `LpChip` | 胶囊筛选芯片。`FilterChip` 直接用 M3 的 |
| `LpField` | 输入框:高 48;底 `s1`;边 `line`;聚焦边 `acc`;右侧可挂清除 |
| `LpCell` | 设置类单元格:图标 + 标题 + 副标题 + 值 / 开关 / 箭头 |
| `SegRow` | 分段控件(2~4 个互斥选项,**就地生效不开弹窗**)。M3 的 `SingleChoiceSegmentedButtonRow` |
| `StepperRow` | 步进器(有明确步长的数值:倍速 0.25 / 线程数 1)。**到头把按钮禁掉** |
| `SliderRow` | 滑块(连续值:模糊强度 / 透明度)。跟手期间走 §2.3 第 3 条 |
| `OptRow` | 选项行(弹窗 / 播放器面板共用),带选中态与右侧徽标 |
| `LpMenu` | 长按菜单 = PC 的右键。见 §5.4 |
| `LpDialog` | 居中弹窗 + scrim。**全站没有 bottom sheet**,见下 |
| `LpToast` | §6.1 |
| `Skeleton` | `s3` 底 + `rememberInfiniteTransition` 扫光,约 25 行。**形状必须和真内容一致** |
| `EmptyState` | 图标 + 标题 + 一段说明 + 可选动作按钮。**说明必须说清是「没有」还是「没配置」** |
| `LpPullRefresh` | M3 的 `PullToRefreshBox` |
| `NetImage` | 图片:骨架 → 解码完成 → 淡入。见 §4.4 |

#### 【已定】全站废弃 bottom sheet,改居中弹窗

这是既有决定(2026-08 手机端整改)。理由:sheet 会打断「从第 5 集跳到第 10 集」
这种真实存在的流程,长简介在 sheet 里也堆不下。
**唯一保留 sheet 形态的是播放器面板**(§8),那是横屏、从侧边推入,不是 bottom sheet。

单集详情因此是**独立一页**,不是 sheet。

### 4.3 卡片规格

| 元素 | 位置 | 规则 |
|---|---|---|
| 封面 | 整卡(海报 2:3 / 横版 16:9) | 未加载时是**骨架不是空白**。解码完成后延后 150 ms 撤骨架再淡入 —— 立刻撤会露出底色,那一帧是「闪白」 |
| 角标 | 右上 | **剧集 → 未看集数**(`UserData.UnplayedItemCount`),全看完 → `ok` 底打勾;**电影 → 评分**(`CommunityRating`)。角标要**小**,它压在封面上 |
| 播放进度 | 底部 | 2 dp `acc`,仅在有进度时出现 |
| 标题 | 卡下 | 一行 + 省略号。**剧集恒带剧名**;片名长短差别极大,不收会把行高撑成两三行,整条轨道高度乱跳 |
| 副标题 | 卡下 | 年份;是某一集时改写 `S1E12` |

- **画质标签(4K/DV)整个去掉。**【用户定 2026-07-28】原话:「没人会为了参数去看一部烂片」。
  画质在详情页和播放器版本面板里。
- **长按 = PC 的右键,每一项都必须真的能点。** 摆着不接线就是死按钮。
- **卡片动作(长按菜单项)必须是同一份定义**,不许某页自己拼一套 —— 否则会长出
  「A 页有『标记已看』B 页没有」这种不一致(PC 端 `cardActions` 的做法)。

### 4.4 图片(`NetImage`)

- 库:**Coil 3**(`io.coil-kt.coil3:coil-compose` + `coil-network-okhttp`)。
  官方 androidx 没有 Compose 图片加载器,这一条在 `research/MOBILE_IMAGES.md` 有证据。
- **URL 一律来自核心层的本地数据通道**(`SPEC.md` §6):
  `http://127.0.0.1:<port>/img?src=…&w=<期望宽度>&token=…`。
  **UI 传期望宽度,核心层决定实际取多大** —— 有的服务端完全忽略 `maxWidth`。
- **UI 侧关掉磁盘缓存,只留内存缓存。**
  核心层 `core/imgcache/` 已经落盘了一份;UI 再落一份 = 同一张图占两份磁盘,
  而且「清理缓存」按钮清不到 UI 那份,变成安慰剂。
  ```kotlin
  ImageLoader.Builder(ctx).diskCachePolicy(CachePolicy.DISABLED).build()
  ```
- **淡入的正确写法**:用 `AsyncImagePainter.state`,骨架在 `Loading` 时画、
  `Success` 时交叉淡出。
  ☠ 历史故障「封面隐身」的根因是手抄卡片时漏了「解码完成 → 加就绪标记」这一步,
  Compose 上等价的漏法是**只画 `AsyncImage` 不看 state** —— 那样骨架永不消失或永不出现。
- `LazyGrid` 里 **必须给 `key`**(条目 id)与 `contentType`(卡片变体),
  否则滚动时 Coil 会因为 item 复用而重复发起请求。

---

## 5. 交互规范

### 5.1 手势全表

| 手势 | 位置 | 动作 |
|---|---|---|
| 点 | 卡片 / 单元格 / 按钮 | 主动作(卡片 = 进详情,**不是起播**) |
| **长按** | 卡片 / 列表行 | 上下文菜单(= PC 的右键) |
| **右滑返回** | 页面左缘 24 dp 内起手 | 出栈,跟手 |
| **下拉刷新** | 可刷新页的顶部 | `PullToRefreshBox` |
| 上滑到底 | 分页列表 | 自动加载下一页(§10) |
| 双指捏合 | **不做** | 没有需要缩放的页面 |
| 播放页三区 | §8 | 左右竖滑 = 亮度/音量;中间点 = OSD;横滑 = seek |

**同一块区域不许叠两个长按语义。** 行上挂了长按、行内又要拖拽的话,
**拖拽起手必须消费掉事件**(`awaitPointerEventScope` 里 `consume()`)——
长按检测只在「元素自己收到移动且位移超阈值」时取消,而拖拽的 move 常挂在上层,
指望它自己取消是靠运气。

### 5.2 侧滑返回与 predictive back

- **返回的唯一入口是系统返回**(手势 / 三键)。topbar 的返回箭头调同一条路径。
- 落法:`PredictiveBackHandler { progress -> ... }`,跟手把当前页 `translationX`
  推到 `progress * width * 0.9f` 并压暗下层;完成则出栈,取消则弹回。
  清单里 `android:enableOnBackInvokedCallback="true"`。
- **返回栈四级(播放页)**:小浮层 → 面板 → OSD → 才退出播放。
- 深链进入的页面,**栈里要有一个可回退的根**(不能一按返回就退出 App)。

### 5.3 返回栈与滚动恢复

| 项 | 规定 |
|---|---|
| 栈 | Navigation Compose,类型安全路由(`@Serializable` 路由对象) |
| 底栏三 Tab | **各自独立返回栈**(`saveState` / `restoreState` + `popUpTo(startDestination)`) |
| 滚动恢复 | 出栈回上一页**必须恢复滚动位置**,且恢复到**内容已就位之后**的位置 |
| 列表缓存 | 返回时**不许重新拉取**。缓存靠核心层的 `data.invalidate` 事件失效 |
| 进程死亡 | 只恢复「我在哪一页、滚到哪」。**数据不进 `SavedStateHandle`** —— Bundle 有 1 MB 上限,塞列表进去就是 `TransactionTooLargeException` |

> 滚动恢复漏了的表现:从详情页返回媒体库,回到了顶部,用户要重新滚很久。

### 5.4 长按菜单

- 在**手指按下的位置**弹出(`DropdownMenu` + `offset`),贴边时向内翻转。
- 分组用 `line` 分隔;危险项(删除 / 移除)放最后一组并用 `bad` 色。
- 弹出时给一次触感反馈(`HapticFeedbackType.LongPress`)。
- **关闭菜单的背板不能盖住触发它的那一层**(PC 端顶栏下拉栽过)。
  Compose 的 `Popup` 自带 `onDismissRequest`,不要自己铺一层全屏 Box。

### 5.5 多选

**不做。**【继承 PC 的决定】批量操作由长按菜单里的「选择模式」承担。
引入常驻多选意味着每个网格都要重做焦点与手势语义,而实际需求只有「批量标已看」一件事。

---

## 6. 反馈层

### 6.1 Toast

| 项 | 规定 |
|---|---|
| 位置(全站) | **中部偏下**【用户定,三端统一】 |
| 位置(播放页) | **顶部居中**【用户定】—— 底部被控制条占着 |
| 时长 | 普通 3 s,错误 5 s,带动作的不自动消失 |
| 层级 | 最上层,**在弹窗之上** |
| 堆叠 | 最多 3 条,超出替换最旧的 |
| 内容 | 一行。需要多行说明的**不是 toast,是弹窗** |

- **不用系统 `android.widget.Toast`**:位置不可控、Android 12+ 强制加图标和应用名、
  播放页全屏下会被系统栏顶位置。自绘一个挂在 `LpScaffold` 顶层的 `LpToast`。
- **Toast 不许承载唯一的重要信息。** 失败必须同时体现在界面状态上(那一行变红 / 开关弹回去)。

### 6.2 弹窗与确认策略

**【用户定,继承 PC】设置页全页零二次确认 —— 改完即生效,没有保存按钮。**

配套两条硬要求:

1. **越界值让核心层拒绝,不要在 UI 上夹紧。** UI 夹紧的话用户输 999 会静默变成 32。
   原样发,核心层回 `E_INVALID`,UI 显示错误并**回滚到旧值**。
2. **失败必须回滚。** 乐观更新是对的,但命令失败时必须翻回来 + 报错。
   不回滚的表现是「开关是开的但功能没生效」—— 本项目最难查的一类 bug。

需要确认弹窗的**只有三类**:不可逆的删除(删服务器 / 卸插件 / 清空记录)、
影响他人的动作(扫描媒体库 / 刷新元数据)、会丢数据的导入。**其余一律不确认。**

### 6.3 错误码 → UI 行为映射

`SPEC.md` §5.4 定义错误码,这里定义**手机端**必须怎么响应(与 PC 的差异用 ★ 标):

| code | 手机端行为 |
|---|---|
| `E_AUTH` | 弹重新登录弹窗(**对扫码型源要给扫码,不是账密框**);不要只弹 toast |
| `E_NETWORK` | **行内错误态 + 重试按钮,不弹 toast**(网络抖动时会刷屏) |
| `E_UPSTREAM` | Toast 显示 `msg`,详情写日志 |
| `E_UNSUPPORTED` | **静默降级,不显示任何错误。隐藏该入口。** |
| `E_NOTFOUND` | 空态 |
| `E_PERMISSION` | 插件权限弹窗 |
| `E_INVALID` | 行内错误 + 回滚(§6.2) |
| `E_SHUTDOWN` | 忽略 |
| `E_INTERNAL` | Toast「出错了」+ 一个「复制诊断信息」动作 |

★ 手机端多一条:**`system.capabilities` 的 `unsupported` 列表里出现的命令,
对应入口在启动时就不画**,不要等点了才 `E_UNSUPPORTED`。
安卓上必然进这张表的有:`system.pickFile` / `system.pickDirectory` /
`player.playExternal` / `player.windowOpen` / `player.windowClose` /
`player.getMpvConf` / `player.setMpvConf` / `translate.whisper*`。

> `E_UNSUPPORTED` 单列是有原因的:媒体源有一批「默认不支持」的可选能力,
> UI 探测它们时收到的不是错误而是信息。混在一起的表现是「进某个源就弹一个红色报错」。

### 6.4 加载、骨架与空态

**三条硬规矩(继承 PC §6.4,一字不改):**

1. **骨架先出,内容各自到位。**
2. **页面不持有一个全局 loading。** 每个区块自己一个 `Loading / Loaded / Failed`。
   一个区块失败不许让整页变成错误页。
3. **失败提示必须挂在加载分支里面。** 挂在外面的表现是「转圈转到天荒地老,
   真正的原因被界面吞了」。

空态文案必须区分三种情况,**不许都写「暂无内容」**:

| 情况 | 文案方向 |
|---|---|
| 真的没有 | 「这里还没有内容」 |
| 没配置 | 「还没有添加服务器」+ 一个跳转按钮 |
| 被过滤掉了 | 「当前筛选没有结果」+ 一个清除筛选按钮 |

☠ 「排行榜整屏白板一个字都没有」的根因是代码落进了 `if (busy) "加载中…" else ""` 分支
—— 那不是空态,那是白板。**每个 `else` 分支都要有内容。**

### 6.5 更新提示

- **不打断。** 首页右上角设置图标挂一个小圆点 + 设置页顶部一条横幅。
- **不做强制更新弹窗。**
- 安卓端的更新是**下载 APK 后交给系统安装器**(`ACTION_INSTALL_PACKAGE` /
  `PackageInstaller`),需要 `REQUEST_INSTALL_PACKAGES` 权限。
  【已定】本轮**不做应用内更新**,设置页只显示「有新版本」+ 一个跳发布页的链接 ——
  安装权限对一个第三方播放器是过重的要求,而且各厂商 ROM 拦法各不相同。

---

## 7. 页面规格

> 每页五行契约:**版式 / 数据来源 / 三态 / 手势 / 判据**。
>
> **通用规则,不在每页重复:** ① 骨架先出、各块各自渲染,**不设屏障**
> ② 一个区块失败不整页报错 ③ 列表结果有缓存,靠 `data.invalidate` 失效
> ④ 所有卡片有长按菜单 ⑤ 错误码按 §6.3 映射,`E_UNSUPPORTED` 静默降级。
>
> 「数据来源」列出的命令名**逐条在 `COMMANDS.md` 里存在**(有一条脚本门禁钉住,见 §11)。

### 7.0 启动时序(`SPEC.md` §8.0,六步,不许改顺序)

```
1. Activity 起来,画一个不依赖任何数据的骨架(不是转圈,是页面轮廓)
2. lp_init({dataDir, platform:"android", version})
3. 起事件线程,开始 lp_next_event 循环         ← 有且只有一个消费者线程
4. system.capabilities                        ← 拿端口/token/unsupported,据此隐藏入口
5. emby.currentSession + source.currentSource ← 两个都要看
      ├─ 都空 → 首登闸口(§7.1)
      └─ 有一个 → 首页(§7.2)
6. 首页各区块各自并发拉取、各自渲染,不设屏障
```

**两条硬约束:**

- ☠ **第 5 步必须同时看两条命令。** 只判 `emby.currentSession` 的话有一类用户
  永远进不了门 —— 这是有过的真实故障。
- ☠ **第 6 步不许有屏障。** 骨架先出、各块各自渲染是**契约不是优化**。
  实测串行等待比并发慢 5.5 倍,而用户会把它描述成「不秒加载」并归咎于动画。

第 1 步的骨架由 `androidx.core.splashscreen` 接管到第一帧(U1.17):
**图标边距留在 drawable 内部**,否则 Android 12 会放大满幅;
`setKeepOnScreenCondition` 只挂到第 2 步完成,不要挂到「首页有数据」——
那会把开屏拖成一个假的加载页。

---

### 7.1 首登闸口 / 添加服务器(U1.2)

| | |
|---|---|
| 版式 | **同一页的两种版式**:首登 = 全屏居中卡片(无底栏);添加 = 从服务器页推入(有返回)。**不是两个页面** —— 两套的话新增一种源就要改两处,漏掉的那处就是「某个入口加不了这种源」 |
| 数据来源 | `emby.currentSession` `source.currentSource` `account.testConnection` `emby.login` `emby.relogin` `source.login` `account.batchParse` `account.batchAddServers` `account.parseDeepLink` |
| 加载态 | 「正在连接…」/「正在登录…」,按钮禁用但**保持原尺寸** |
| 错误态 | 登录失败**原样显示核心层的 `msg`**,不要换成「网络不通」。改名失败不能把「已经加成功」变成「报错了」 |
| 空态 | — |
| 手势 | 无特殊 |

- 顶部**芯片选源**:`Emby` / `本地文件夹`。**只剩一种时整条不画**
  (一个只有一个选项的选择器是纯噪音)。
- 本地文件夹的表单**只有一个「选择文件夹」按钮**,没有地址框也没有账号密码。
- ★ **地址补全在 UI 侧做**:用户没写 `http://` 时补一个,**默认补 `http` 不是 `https`**。
  不补的表现是 Go 的 URL 解析报一句纯英文技术话。补错协议只会连不上,
  而补 `https` 到只有 `http` 的服务器上,报的是看不懂的 TLS 错。
- **`device_id` 必须持久。** 每次换一个会把服务器的设备列表刷满,续播会话也对不上。
  安卓侧用 `Settings.Secure.ANDROID_ID` 派生,不要用 `Build.SERIAL`(API 26+ 拿不到)。
- 打开就把光标放进第一个要填的框 + 自动弹输入法(`FocusRequester` + `LaunchedEffect`)。
- **批量添加**是这一页的第二个入口:粘贴一段开通信息 → `account.batchParse` 预览
  → `account.batchAddServers`。安卓上从系统剪贴板读(`ClipboardManager`)。

> ⚠️ **`source.formSchema` 不存在。** `SPEC.md` §8.1 与 `UI_PC.md` §7.6 都写着
> 「表单字段定义下沉核心层」,但 218 条命令里**没有这一条**,PC 端也是把源类型表
> 写在 `Views/Pages.cs` 里的。本轮**照 PC 的做法**:源类型表写在
> `ui/pages/AddServerPage.kt` 一处。记为阻塞条目 B1。

### 7.2 首页(U1.3)

| | |
|---|---|
| 版式 | ① **Hero**(随机 5 条,只取有剧照的;两层图交叉淡入 + Ken Burns 恒速缓推;艺术字 logo → 小标题 → 元信息三层居中,整块可点)② 继续观看 ③ 接下来看 ④ 媒体库入口轨 ⑤ **每个媒体库一条「最新」轨** ⑥ 合集 |
| 数据来源 | `emby.listRandom` `emby.listResume` `emby.listNextUp` `emby.views` `emby.listLatest` `emby.listCollections` `emby.counts` `prefs.getHomeSettings` `account.listAccounts` |
| 加载态 | 各块并发。**媒体库最新轨并发不串行**(八个库串行 = 八次往返)。未到的画骨架轨 |
| 错误态 | 各块各自 catch。**只有 `emby.views` 是地基**,它挂了才整页错误条 |
| 空态 | Hero 未到 → 骨架块;`views` 未到 → 先出两条最新轨骨架(否则首屏下半是空的);没有服务器 → 「还没有添加服务器」+ 跳转 |
| 手势 | 下拉刷新;卡片点=进详情、长按=菜单;Hero 左右滑换条目 |

- **元信息只有「年份 · 评分 · 类型」**,画质标签整个去掉【用户定 2026-07-28】。
- **艺术字 logo 取不到 → 回落成文字标题,并隐藏下面那行标题**(否则重复)。
  失败**按条目 id 记,不是一个布尔** —— 否则翻到下一张 Hero 还顶着上一张的失败态。
- 氛围光跟 Hero 图同步换色,颜色由**核心层从封面取的主色**给;
  取不到就不画,**不要在 UI 侧解码位图算主色**(那是主线程上的几十毫秒)。
- **屏蔽条目后整页重拉,不在 UI 逐个过滤。** 首页手里有六份互不相干的列表副本,
  挨个过滤 = 把核心层的规则在 UI 再抄一遍,抄错还不报错。
- 右上角两个入口:**搜索**(进 §7.5)与**设置**(进 §7.15)。底栏没有它们的位置。
- ☠ **不要复刻「首页滑不动」那个 bug**:旧 Web 栈的根因是 `content-visibility`
  与滚动锚定打架。Compose 上没有这两个概念,但等价风险是
  **`LazyColumn` 里嵌 `LazyRow` 而不给固定高度** —— 会在每次测量时重新布局整列。
  轨道高度必须是常量(海报轨 `PosterRowHeight`,横版轨 `ThumbRowHeight`)。

### 7.3 媒体库 + 筛选(U1.4)

| | |
|---|---|
| 版式 | 两级:库列表(网格卡)→ 库内网格。库内 topbar 下一条**排序 + 筛选**芯片条,点筛选开**居中弹窗**(不是 sheet) |
| 数据来源 | `emby.views` `emby.listItemsPage` `emby.getFilters` `emby.setBlocked` `emby.blockedList` `emby.isAdmin` `emby.scanLibraries` `emby.refreshItem` |
| 加载态 | 进库时**并发**拉分面(`getFilters`)与第一页条目。第一页未到 → 12 个骨架卡 |
| 错误态 | **分面拉不到要在筛选弹窗里明说**,不能静默变成「此库没有分面」 |
| 空态 | 库内无结果 = 筛选太窄,**保留筛选条**让用户能退回去 + 一个「清除筛选」按钮 |
| 手势 | 下拉刷新;上滑到底续页(120/页);卡片长按菜单;**库卡长按 = 另一套只有「屏蔽整个库」的菜单** |

- **排序一律走服务端。** 本地排只能排到已加载的那一页,翻页后顺序就乱了。
- 排序档位:加入时间 / **更新时间** / 上映日期 / 名称 A→Z、Z→A / 年份 / 评分。
  「更新时间」≠「加入时间」—— 前者是这部剧**最近一集**入库的时间,追更要的是它。
- 评分筛选固定给 **9 / 8 / 7 / 6 四个下限档**(服务端给的分级不是评分,没有分面可列)。
- **这一页必须拿全量(含已屏蔽的库)** —— 它是唯一能把库找回来解除屏蔽的地方。
- **屏蔽是所有人都有的,管理员项(扫描 / 刷新)才是管理员限定**(`emby.isAdmin`)。
  旧版整个菜单 admin-only,非管理员连菜单都弹不出来。

### 7.4 详情页族(U1.5)—— 剧 / 影 / 季 / 集,**四张分开设计**

四张共用同一套组件,但**版式不同**,不许用一个 `when` 糊在一页里。

| | 剧(Series) | 影(Movie) | 季(Season) | 集(Episode) |
|---|---|---|---|---|
| 顶部 | 背景剧照 + 海报 + 标题 | 同左 | 剧的背景 + 季海报 | **横版剧照**(16:9)大图 |
| 主按钮 | 「继续 S1E5」/「播放」 | 「播放」/「继续 12:34」 | 「从第 1 集开始」 | 「播放」 |
| 中段 | 简介 / 演职员 / **季选择条** | 简介 / 演职员 / 版本 / 线路 | 简介 | **本集简介(可长)** |
| 列表 | **分集网格**(当前季) | 相似推荐 | 分集网格 | **选集横版栏**(当前集高亮) |
| 底部 | 相似推荐 | — | 相似推荐 | 相似推荐 |

| | |
|---|---|
| 数据来源 | `emby.itemDetail` `emby.itemMedia` `emby.seriesSeasons` `emby.seasonEpisodes` `emby.similarItems` `emby.setFavorite` `emby.setPlayed` `emby.aggregateVersions` `account.probeLines` `account.setActiveLine` `prefs.preloadItem` `prefs.preloadCancel` `prefs.setDetailBlur` `prefs.setPrefs` `prefs.getPrefs` `download.enqueue` |
| 加载态 | 详情与 `itemMedia`(版本 / 音轨 / 字幕)**并行**;相似推荐并发;**分集要等详情回来**(`series_id` 只有详情才给) |
| 错误态 | `itemMedia` 失败 → 整段不渲染;相似推荐失败 → 静默;分集失败 → 选集栏整条不渲染;**唯独线路清单失败不能静默**(否则线路选择器凭空消失,没人知道为什么) |
| 空态 | 有缓存就**先把缓存画出来,别先清空** —— 无条件清空 = 每次进详情必然闪一下转圈 |
| 手势 | 从首页卡片进来时走**共享元素**(封面飞到 Hero);右滑返回;分集卡长按菜单 |

- ☠ **版本选择器的「未选」是 `null` 不是 `0`。** 传了 id 核心层就走「手动指定」分支,
  版本筛选正则**整个被跳过**。旧代码用 `0` 初始化 = 每次都替用户选了第一版
  —— 版本正则**从上线起一次都没生效过,还一声不吭**。
- ☠ **界面不许撒谎:展示的版本必须是真正会播的那一个。**
  核心层标 `preferred`,UI 用**唯一的** `defaultVersion()` 算法,
  **不许自己回落 `versions[0]`**。这条有真实故障。
- **详情页选音轨 / 字幕 = 写偏好,不是当场切轨**(此刻还没起播)。
  写偏好时必须**先取基线再改单项**(`prefs.getPrefs` → 改 → `prefs.setPrefs`)——
  三项一起覆写会把另两项悄悄清成 null,两头都不报错。
- **进详情页就开始预热「▶ 会播的那个条目」**(`prefs.preloadItem`)。
  换集 / 换版本时要重新预热的是**另一条流**;离页 `prefs.preloadCancel`。
  fire-and-forget,失败全吞。
- **单击进集详情,没有「双击播放」。**【用户定】曾为等双击把单击延后 220 ms,手感发黏。
- 分集卡在「剧集页网格」和「单集页选集栏」**共用同一张**,交互口径一样;
  差别只有选集栏多标集号 + 当前集高亮。
- **季选择条只有一季时整条不画**(同 §7.1 的芯片规矩)。

### 7.5 搜索(U1.7)

| | |
|---|---|
| 版式 | topbar 里就是输入框(**进页即聚焦并弹输入法**)+ 两个开关芯片(**包括集** / **聚合跨服**)+ 搜索历史(≤8)+ 结果。聚合时**按服务器分组**,分集**单独一栏横版** |
| 数据来源 | `emby.search` `emby.aggregateSearch` |
| 加载态 | 防抖 250 ms 后打**服务端**搜索。**不许**「拉全部库 → 全量拉条目 → 本地过滤」 |
| 错误态 | 半失败(一路 429、一路回空)**不能吞成「没搜到」**,要说清哪台失败了 |
| 空态 | 无 query → 显示历史 + 一句引导;有 query 无结果 → 「『xx』没搜到东西」+ 说清搜了几台 |
| 手势 | 结果点=进详情;**结果不给长按菜单**(见下) |

三条开关规则【用户定】:

1. **「包括集」默认关。** 搜「凡人」应该先看到那部剧,不是被 200 集分集淹掉。
2. **「包括集」一拨就重搜;「聚合」一拨不重搜。** 聚合一次打 N 台,来回拨两下就是 2N 个请求;
   而「包括集」只多打一次当前服,**不重搜才是坏的**。
3. **库内搜索与聚合互斥。** 有搜索范围时聚合开关**整个不出现**。

- **结果只有一个操作:点 = 进详情,不从这里起播。**
- **跨服结果不给长按菜单** —— 收藏 / 标已看是对当前活跃服务器写的,
  对着别的服的条目按下去会写错地方,而且不报错。
- **类型必须显式传。** 不传时服务端默认包含分集 = 「永远包括集」。
- 历史只在**用户真的点开了某个结果**时才记(跟着防抖记会把「阿」「阿凡」「阿凡达」全记进去)。
- **三个入口都要点一遍**:首页右上角搜索、聚合页顶部搜索条、库内搜索。

### 7.6 聚合视界(U1.8)· 底栏第二个 Tab

| | |
|---|---|
| 版式 | 顶部搜索条(点进 §7.5)+ 一行快捷入口(继续观看 / 收藏 / 下载 / 排行榜 / 日历)+ 按服务器分组的聚合内容 |
| 数据来源 | `emby.aggregateOverview` `account.getCrossServerResume` `account.setCrossServerResume` `account.listAccounts` |
| 加载态 | **流式**(`SPEC.md` §5.7):每台服务器各自回各自渲染。**收到 `partial` 就画,不许攒齐再画** |
| 错误态 | 逐台标失败,不整页失败;`result` 汇总里带失败清单,画在底部 |
| 空态 | 只有一台服务器时提示「添加更多服务器才有聚合」+ 跳转按钮 |
| 手势 | 下拉刷新;卡片长按菜单(**只对当前活跃服的条目开**,理由同 §7.5) |

- 跨服请求**不加并发上限**(元数据请求本轻),靠**离页取消**(`lp_cancel`)杀请求 ——
  Compose 侧用 `viewModelScope` + `DisposableEffect` 保证退出即取消。
- 展示阶段**不开深度探测**(不为了展示去做 ffprobe 那一类重活)。

### 7.7 收藏(U1.9a)

| | |
|---|---|
| 版式 | 海报网格 + 排序芯片 |
| 数据来源 | `emby.listFavorites` `emby.setFavorite` |
| 加载态 | 单条命令,12 个骨架卡 |
| 错误态 | 整页错误条 + 重试 |
| 空态 | 「还没有收藏任何内容」+ 说清怎么收藏(长按封面 / 详情页那颗心)+ 跳首页按钮 |
| 手势 | 下拉刷新;长按菜单(含「取消收藏」) |

- **某台 fork 服务器在收藏页忽略 `SortBy`。** 这类补偿**已下沉核心层**,
  UI 不做本地排序 —— 否则三端各补一次,漏的那端就是「排序在手机上不生效」。

### 7.8 服务器管理 / 线路(U1.9b)· 底栏第三个 Tab

| | |
|---|---|
| 版式 | 服务器卡列表:图标 / 名称 / 备注 / **连通状态点** / 「当前」角标。顶部「＋ 添加服务器」。**长按 → 菜单**:设为当前 / 编辑 / 重新登录 / 服务器线路 / 更换图标 / 删除。底部一条「设置」入口 |
| 数据来源 | `account.listAccounts` `account.probeAccounts` `account.setActiveServer` `account.updateAccount` `account.removeAccount` `account.reorderAccounts` `account.icon` `account.setAccountIconFile` `account.clearAccountIcon` `prefs.iconLibrary` `emby.relogin` `account.syncLines` `account.setLines` `account.probeLine` `account.probeLines` `account.setActiveLine` `emby.logout` |
| 加载态 | 账号表来自核心层**原序**;连通状态异步探测,未探时状态点是「未知」不是「不通」 |
| 错误态 | 删除 / 切换失败在页面内报错,不静默 |
| 空态 | 「还没有添加服务器」+ 添加按钮 |
| 手势 | 长按菜单;**长按并拖动 = 排序**(★ 拖拽起手必须消费事件,否则和长按菜单打架,§5.1) |

- **备注 / 图标 / 线路 / 排序全部落核心层,不存本地。**
- **状态点 = 连通健康,不是「选中」**(选中看「当前」角标)。
  `down`(探过确实不通)与 `unknown`(还没探过)**同色不同义**,
  必须靠**文字**区分 —— 手机没有悬停,所以直接在卡片上写「未检测 / 不通」。
  这是「不用颜色作为唯一信息载体」在手机上的落法。
- 编辑弹窗字段顺序【用户定】:服务器名称 / 账号 / 密码 / 备注(+ TLS 开关)。
  **没有地址行** —— 「服务器地址是『服务器线路』里面填写的」。
- ☠ **改账号 / 密码必须走 `emby.relogin`(真登一次换 token),不是 `emby.login`。**
  后者是 Upsert 语义;只改字段不重登 = token 还是旧用户的,
  表现为「显示新账号、媒体库还是旧账号的」,而且不报错。
- **「服务器线路」是独立一页**(不是弹窗):同步 / 添加 / 编辑 / 删除 / 拖动排序,
  行点击 = 切生效线路。
  - **「同步线路」和「测延迟」是两个按钮两回事。**
  - 线路表为空 = 单线路形态,要补出一行可见主线。
    **服主没部署同步服务是常态,404 不能当错误弹。**
  - **拖动排序在筛选状态下必须回原表查真实下标**;活跃行要跟着它的 URL 走,
    只挪数组不挪下标会**静默把用户切到另一条线路上**。
  - **任何地方不展示线路地址。**【用户定】只写名称 + 延迟,没起名的回落「线路 N」。
- 「更换图标」进图标选择页(`prefs.iconLibrary`)。**本地上传走 SAF**(见 §7.16 的说明)。

### 7.9 文件浏览(U1.10)

| | |
|---|---|
| 版式 | 面包屑 + 列表行(图标 / 名称 / 大小 / 修改时间)。**不是网格** —— 文件名比缩略图重要 |
| 数据来源 | `source.currentSource` `source.listDir` `source.search` `source.play` `source.watchdog` |
| 加载态 | `source.listDir` 是**流式**的,边列边出 |
| 错误态 | 凭据失效 → `E_AUTH` → 走重新登录 |
| 空态 | 空目录就说**空目录**,不要说「加载失败」 |
| 手势 | 点=进目录 / 起播;右滑返回上级 |

- **进一个源之前先探能力。** 探到「影视目录型」→ 走 §7.10 那一页;
  探不到(`E_UNSUPPORTED`)→ **静默换路**留在本页,不当错误弹。
- 起播必须走**宿主统一的起播入口**(`ui/player/PlaybackLauncher.kt`),
  **本页不许自己 `player.play`**。
  > 教训:曾经绕开统一入口自己起播,结果「有声音、没画面、还关不掉」。
- 本轮范围内**只有 `local` 一种源**会进这一页(网盘 / 局域网源已于 2026-09-04 砍掉)。
  插件贡献的文件型源将来也走这里。

### 7.10 影视目录(U1.11)· **与文件浏览是两套页面,不复用**

> 这一页存在的唯一理由:**资源站不是文件树。**
> 复用过一次,六个毛病全是那个决定的症状 —— 分类伪装成文件夹、翻页伪装成一个叫
> 「下一页」的文件夹、「更新至 17 集」只能拼进文件名。

| | |
|---|---|
| 版式 | 顶部**横条分类**(不是网格里的卡片)+ 海报墙(角标 / 年份 / 评分**各占各的位置**,标题里只有标题)+ 详情**盖在同一页上** |
| 数据来源 | `source.categories` `source.catalog` `source.mediaDetail` `source.play` |
| 加载态 | 首屏**预抓几页** —— 否则内容铺不满一屏 → 没有滚动 → 无限下拉永远不会被触发 |
| 错误态 | 探能力抛不支持 = 这是个文件型源 → 静默换路回 §7.9 |
| 空态 | **有子分类的父级本身多半是空的**,点它要先落到第一个子分类,不是把用户扔进空页 |
| 手势 | 点=打开详情浮层;上滑续页;**详情关掉时网格的滚动位置还在** |

- **单击就打开,不是双击。** 海报墙不是文件管理器。
- 本轮只有**插件贡献的 VOD 源**会用到这一页(走 `plugin:<插件id>/<源id>` 开放键)。
  没装这类插件时,这一页**没有入口** —— 不是空页,是不存在。

### 7.11 下载(U1.12)

| | |
|---|---|
| 版式 | 任务列表(剧集标题 = `S1E5 · 集名`,电影用整条标题)+ 顶部并发线程数 `StepperRow` + 每条的暂停/继续/删除 + 「清除已完成」 |
| 数据来源 | `download.list` `download.enqueue` `download.pause` `download.resume` `download.remove` `download.clearCompleted` `download.setThreads` + 事件 `download.progress` |
| 加载态 | 进页读任务表 + 订阅 `download.progress` |
| 错误态 | 起播已下完的文件失败要如实说 |
| 空态 | 「下载队列是空的」+ 说清怎么入队 |
| 手势 | 行长按 = 菜单 |

- **「清除已完成」只清记录,不删文件**;想删文件的是每条右边那个 ✕。
  两个语义正相反,**别合并成一个命令**。
- 并发数**只读不灌**:核心层持久化,UI 读 `download.list` 的返回。
- **本页不能自己起播**(同 §7.9)。
- 安卓侧下载在**核心层的后台 goroutine** 里跑,App 进程被杀就停 ——
  这是已知取舍,不做 `WorkManager`。设置页要有一句说明。

### 7.12 插件市场 / 已装(U1.13)

| | |
|---|---|
| 版式 | 一页**三个 Tab**:市场 / 已装 / 源订阅。卡片带**第三方源徽章**。插件详情是独立一页,插件自己贡献的设置面板作为详情里的一段 |
| 数据来源 | `plugin.marketList` `plugin.marketSources` `plugin.marketAddSource` `plugin.marketRemoveSource` `plugin.marketToggleSource` `plugin.marketInstall` `plugin.list` `plugin.install` `plugin.uninstall` `plugin.enable` `plugin.disable` `plugin.permissionCatalog` `plugin.panels` `plugin.extensions` `plugin.invokeField` `plugin.trigger` `plugin.uiRespond` `plugin.sources` `plugin.reload` |
| 加载态 | 进页拉已装列表 + 各订阅源的 registry,**并发** |
| 错误态 | 单个源拉不到只标那个源,不整页失败 |
| 空态 | 「已装」经常是空的 —— **做成 Tab 而不是两个入口,空 Tab 比空页面便宜** |
| 手势 | 卡片点=详情;已装项长按=启用/停用/卸载 |

- **授权清单在装 / 启用之前弹,一行一条人话**,不是一句「该插件需要若干权限」。
  **权限词表由 `plugin.permissionCatalog` 透出,UI 不许抄一份**
  —— 抄了就会漏新权限,弹窗里显示光秃秃的 id。
- **可装版本要取版本号最大值,不是数组第一个** —— 上游返回顺序不可依赖。
- **插件自定义 UI(`plugin.ui` 事件)本轮只支持声明式描述符**
  (`kind` = 表单 / 列表 / 确认),**不起 WebView**。
  PC 端用独立 origin 的 WebView2 跑插件页面;安卓上再养一个 WebView 会把
  APK 和内存都推上去,而本轮 16 页里没有任何一页依赖它。记为阻塞条目。
- **插件是全平台可用的**(2026-08 已推翻「插件只在 PC 可用」),
  但 `system.capabilities.features.plugins` 说 false 时整个 Tab 不画。

### 7.13 排行榜(U1.14a)

| | |
|---|---|
| 版式 | 榜单选择芯片条 + 带排名序号的列表(横版卡 + 名次) |
| 数据来源 | `emby.rankingCategories` `emby.rankingFetch` |
| 加载态 | 按榜单分别拉 |
| 错误态 | 显示错误 + 重试。**不许吞成空表**(空表和失败在界面上长得一样,但一个该重试一个不该) |
| 空态 | 「暂无榜单数据」 |
| 手势 | 下拉刷新;卡片长按菜单 |

- **根本没有「排行榜开关」这个东西** —— 别去找,也别加。

### 7.14 追剧日历(U1.14b · 付费)

| | |
|---|---|
| 版式 | 两种视图:**本周看板**(横滑,一屏 3 天,每列自己滚)/ **本日直列表**(一条一行、按时间从早到晚、**待定沉底**)。手机竖屏默认「本日」 |
| 数据来源 | `sync.bangumiCalendar` `sync.traktCalendar` `sync.bangumiSummary` `system.afdianSponsorUrl` `system.afdianVerify` |
| 加载态 | 放送表整表一次拉;**简介按需拉 + 模块级缓存** |
| 错误态 | 打开外部链接失败**要说出来**(静默失败会让用户以为按钮是坏的) |
| 空态 | 简介缓存里**存 `null` 代表「查过了,确实没有」** —— 不能用「键不存在」表示,否则每次展开都会再查一遍 |
| 手势 | 看板左右滑换天;条目点=进详情 |

- ☠ **赞助地址必须来自 `system.afdianSponsorUrl`,不许硬编。**
  2026-07-19 就栽在这:UI 里写死了一个凭空猜的主页,功能看着完全正常,
  **赞助收益却是零**。收款地址只能有一份。
- 解锁后默认「Bangumi + 不看我追的」(公开放送表免登录即可返回整张表)。
- **今天要居中,不是靠边**【用户定】。周一 / 周日是今天时自然靠边,那是没得居中不是 bug。
- **本周标题不许单行截断**(截成「…」= 显示不全),放开完整换行 + 大封面 `ContentScale.Fit` 不裁。
- 封面用 **2:3 竖版**(源站给的就是竖版,硬裁成方图会切掉大半)。
- 判「今天是周几」**必须按上游时区(JST)** —— 核心层已经处理,UI 直接用它给的分组。

### 7.15 设置(U1.15)

**一级列表 + 二级页**(手机没有主从两栏的宽度)。面包屑用 topbar 的标题+副标题表达。

| 组 | 项 |
|---|---|
| 通用 | 外观与语言 / 播放器 / 弹幕 / 字幕翻译 |
| 网络 | CF 优选加速 / 多线程加载 / 预加载 / 代理设置 |
| 同步 · 账号 | 同步记录 · 跨服聚合 / Trakt · Bangumi |
| 其它 | 已屏蔽的内容 / 存储与数据目录 / 关于 |

> 手机端比 PC 少一项:**快捷键**(没有键盘)。多的没有。

| | |
|---|---|
| 数据来源 | `prefs.getPrefs` `prefs.setPrefs` `prefs.applyPrefs` `prefs.getPrefetchSettings` `prefs.setPrefetchSettings` `prefs.getPreloadSettings` `prefs.setPreloadSettings` `prefs.getProxy` `prefs.setProxy` `prefs.cfProxyStatus` `prefs.cfProxyEnable` `prefs.cfProxyDisable` `prefs.cfSpeedTest` `prefs.getWritebackSettings` `prefs.setWritebackSettings` `prefs.getTranslationSettings` `prefs.setTranslationSettings` `prefs.getHomeSettings` `prefs.setHomeSettings` `prefs.configExportQr` `prefs.configImportQr` `player.getPlaybackPrefs` `player.setPlaybackPrefs` `player.shaderLevels` `player.setShaderLevel` `player.setTrackRegexes` `player.validateTrackRegex` `danmaku.getDanmakuConfig` `danmaku.setDanmakuConfig` `danmaku.minAutoScore` `danmaku.cacheSize` `danmaku.cacheClear` `danmaku.importBlocklist` `sync.traktAccount` `sync.traktDeviceCode` `sync.traktPoll` `sync.traktLogout` `sync.bangumiAccount` `sync.bangumiAuthorizeUrl` `sync.bangumiExchange` `sync.bangumiLoginToken` `sync.bangumiLogout` `emby.blockedList` `emby.setBlocked` `emby.watchHistoryList` `emby.watchHistoryDelete` `emby.watchHistoryClear` `system.dataPaths` `system.cacheSize` `system.clearCache` `system.checkUpdate` `system.exportDiagnostics` `account.getCrossServerResume` `account.setCrossServerResume` |
| 加载态 | 各面板**进入时各自拉自己的配置**;同一面板里的多个请求**必须并发** |
| 错误态 | 读取失败的提示**必须挂在加载分支里面**(§6.4 第 3 条) |
| 空态 | 「已屏蔽的内容」为空 = 没屏蔽过任何东西,正常 |
| 手势 | 单元格点=进二级页 / 就地切开关 |

- 交互口径见 §6.2:**改完即生效、零保存按钮、越界让核心层拒绝、失败回滚**。
- **选项少 / 数值型的东西不开二次弹窗。** 用 `SegRow` / `StepperRow` / `SliderRow` 就地生效。
  弹窗只留给两种情况:① 选项多且互斥(超分十几档、语言列表)② 需要填表(正则、代理)。
- **新增设置项必须有消费点。** 加一个开关但没人读它 = 一个永远不生效的开关,而且不报错。
- 「已屏蔽的内容」是**隐藏类功能的集中解除列表**。
  > 教训:屏蔽的过滤点做在一处很优雅,但那一处也被「库列表」复用了 ——
  > 结果屏蔽了库之后**自己也解除不了**。隐藏类功能必须配一个集中解除的地方。
- 「存储与数据目录」显示 `system.cacheSize` 的逐项占用,否则「清理缓存」就是个安慰剂按钮。
  安卓的数据根是 `context.filesDir`(应用私有),**路径展示但不可点开**
  —— 没有文件管理器能进去,给一个打不开的按钮比不给更糟。
- 「关于」:版本号 / 数据目录 / 开源信息 / **有新版本时的跳转链接**(§6.5)。
- 「字幕翻译」在安卓上整组**不画** —— `translate.whisper*` 在 `unsupported` 里
  (Whisper 模型是几百 MB 的桌面级依赖)。这是 §6.3 那条「入口在启动时就不画」的落法。

### 7.16 安卓专有:文件与目录选择

安卓没有桌面那种文件对话框,`system.pickFile` / `system.pickDirectory` /
`system.pickLocalFolder` 在本平台返回 `E_UNSUPPORTED`。**UI 侧用 SAF 顶上:**

| 场景 | 落法 |
|---|---|
| 选本机文件夹当源(§7.1) | `ActivityResultContracts.OpenDocumentTree` → 拿 `content://` URI → **`takePersistableUriPermission`** |
| 选本地图标文件(§7.8) | `ActivityResultContracts.GetContent("image/*")` |
| 加载本地弹幕 / 字幕文件 | `OpenDocument` |

☠ **核心层要的是路径,SAF 给的是 `content://` URI。** 两者不通用。
本轮的做法:**把 SAF 选中的文件复制进应用私有目录再把真实路径交给核心层**
(图标 / 弹幕 / 字幕这类小文件),**目录型的本机源本轮不做**
—— 复制一整个媒体目录不现实,而 `content://` 树 mpv 打不开。记为阻塞条目。

★ **越狱闸(U1.27)**:交给核心层的任何本地路径,必须先由 UI 校验
「在 `filesDir` / `getExternalFilesDir` 之下」。这条不能省 —— 旧栈安卓侧
连 `READ_EXTERNAL_STORAGE` 都没申请,越狱闸也就没人写过。

---

## 8. 播放页与 OSD(U1.6)

> 行为规格在 `SPEC.md` §7.4(三端共同契约),本节只写**手机端的版式与手感**。
> 视频层是 `SurfaceView`(**不是 `TextureView`**),走 `SPEC.md` §7.2 的**通道 A**。

### 8.1 版式 · 横屏九宫格【用户定 2026-07-28】

```
┌─────────────────────────────────────────────────────────┐
│ ← 标题(过长慢速滚)              版本·线路 │ 超分 │ 更多 │
│                                                          │
│ 截图                                                倍速 │
│ 锁屏                    ( 画  面 )                   ＋  │
│                                                     1.0× │
│                                                      −   │
│                                                          │
│ ⏮ ⏭            ⏪  ⏯  ⏩              音轨│弹幕│选集 │
│ ──────────────── 进度条 ─────────────────  12:34/1:52:00 │
└─────────────────────────────────────────────────────────┘
```

**上一版把东西全堆在上下两条栏里,屏幕两侧和中间全空着** —— 那是没把屏幕用完。
遮挡率从 83.6% 降到 **38.5% 量级**,这是**算术题不是抄袭题**:
把控件摊到九个角落之后,被盖住的只有边缘。
☠ **不要派 agent 去查竞品的像素规格** —— 竞品不公开,查回来的都是编的。

四种收纳手法(遮挡率是靠它们降下来的,不是靠把控件做小):

1. **摊开到九宫格**,不做上下两条通栏
2. **同类合并成一个入口**(版本 + 线路合成一个「源」面板,分组扛得住十几个版本 / 三十几条线路)
3. **不常用的进「更多」**(画面比例 / 旋转 / 定时关闭 / 后台播放)
4. **面板从侧边推入,只占屏宽 42%**,不做通栏 sheet

### 8.2 竖屏版式

竖屏时视频占顶部 16:9,下面是**内容区**(集列表 / 简介 / 相似推荐)——
这是手机上「边看边挑下一集」的常见形态,和横屏是两套布局不是一套的缩放。

- 竖屏 OSD 只有三层:顶部返回+标题、中间三键(退/播/进)、底部进度条+全屏按钮。
  **九宫格是横屏专属。**
- ☠ `.portrait` 这类方向类要**真的有人去加**。草稿里定义了竖屏样式但没有代码切换它,
  于是竖屏永远走横屏那套 —— 不报错,只是「怎么竖屏这么挤」。
  Compose 侧用 `LocalConfiguration.current.orientation` 直接判,不留状态。

### 8.3 手感

| 项 | 规格 |
|---|---|
| OSD 自动收起 | **5000 ms**。两条例外:**面板开着不收**、**暂停时不收** |
| 面板打开期间 | **上下栏一动不动。** ☠「点出去闪一下」的根因是 **scrim 盖在了 OSD 上面**(层级),不是显隐逻辑。OSD 必须抬到 scrim 之上 |
| 返回键四级 | 小浮层 → 面板 → OSD → 才退出播放 |
| 倍速 | **连续不是档位**:点一下走 0.25,长按每 70 ms 走 0.05(≈0.7×/秒,从 1 拉到 3 要 3 秒)。范围 0.25–4.0 |
| 标题跑马灯 | ① 放得下就不滚 ② 速度 **30 dp/s**,**不能写死总时长**(写死 = 标题越长划得越快)③ 完整滚一圈**不来回弹** ④ 两头各留 18% 停顿,下限 12 s |
| 选集列表 | **带封面的行**:封面 \| 第一行 = 季集(+集名)\| 第二行 = 时长·分辨率·码率。播放中只拉一屏 40 条 |
| 缓冲速度 | 0 或负数 → **什么都不画** |
| 线路面板 | **先出表(零等待、立刻可点),再逐条探**。三态:未探(转圈)/ 探过不通(显示「—」,**不装成 0 ms**)/ 毫秒数。按延迟分档、组内升序,**挂掉的单独归最后**;打开面板**滚动到当前线路** |
| seek 卡死提示 | 有的服务器宣称支持 Range 却回整个文件。**播放器修不了,但必须提示「正在跳转…」**,一次 seek 只说一次,跳完复位 |
| 横屏 chip | 视觉 32 dp,命中区外扩到 44 dp(§1.5 的唯一例外) |

### 8.4 三区手势

| 区 | 手势 | 动作 |
|---|---|---|
| 左 1/3 | 竖滑 | 亮度(`window.attributes.screenBrightness`,**不改系统亮度**) |
| 右 1/3 | 竖滑 | 音量(`player.setVolume`,**不用系统音量条**) |
| 中 1/3 | 单击 | OSD 显 / 隐 |
| 中 1/3 | 双击 | 播放 / 暂停 |
| 全屏 | 横滑 | seek 预览(松手才真 seek);滑动中显示「目标时间 ±差值」 |
| 全屏 | 长按 | 临时 2× 快进,松开还原 |
| 锁屏后 | 任何 | 只有解锁按钮响应 |

- 手势跟手期间**走 §2.3 第 3 条**:`graphicsLayer` / `Animatable`,不重组。
- **横滑 seek 松手才发命令。** 跟着滑发是每帧一条 `player.seek`,把核心层的 seek 闩打乱。

### 8.5 视频层与 surface 生命周期(U1.28)

```kotlin
holder.addCallback(object : SurfaceHolder.Callback {
  override fun surfaceCreated(h: SurfaceHolder) { /* 等 surfaceChanged 拿尺寸 */ }
  override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, ht: Int) =
      Core.setSurface(kind = 1, surface = h.surface, w = w, h = ht)
  override fun surfaceDestroyed(h: SurfaceHolder) =
      Core.setSurface(kind = 0, surface = null, w = 0, h = 0)   // ★ 同步阻塞
})
```

☠ **解绑必须同步阻塞。** `surfaceDestroyed` 返回后 Surface 立即失效,
mpv 还在往里画就是 use-after-free。`lp_set_surface(0,…)` 在核心层里阻塞到
mpv 真的不再画为止;JNI 薄层**不许**把它扔到别的线程去做。
这是 `SPEC.md` 点名的「安卓端最容易漏的一条」,旧栈就漏着(TODO N5)。

- `ANativeWindow_fromSurface` 拿到的句柄由**核心层持有并 release**,
  JNI 层只负责转换。引用计数错了的表现是画面正常但退出时崩。
- **U1.28 判据:快速反复旋转屏幕 100 次不崩。** 靠 §3.4 的 `configChanges` 少一半机会,
  剩下的靠这个阻塞屏障。
- **PiP 进出时 SurfaceView 会不会重建** —— `research/MOBILE_PLAYER.md` 标为「未确认」。
  实现上**不假设**:照常走 `surfaceChanged` / `surfaceDestroyed` 那条路,
  重建了也是对的。

### 8.6 起播与收尾

- **换片时先立「未就绪」再发命令**,不能排在两个 await 之后。
  ☠「第二个视频露上一片画面」的真因不是没复位 ready,是**复位排在 `play()` 两个 await 后面**,
  而上一片的状态轮询每 250 ms 还在往回拍。
- **撤黑幕的判据是「时间真的往前走了」**,不是 `position > 0`。另需 4 s 兜底,
  但兜底放行前**必须先确认不在等缓冲**。
- ☠ **`duration == 0` 时进度条禁用**,并且不许用 0 盖掉已知时长。
  真服加载窗口实测 6~7 秒 —— 这期间点进度条中间会跳到 0.5 秒,用户看到的是「画面不变」。
- **播完收尾传总时长,不是当前时间**(差最后零点几秒 = 服务端不算看完,
  Trakt / Bangumi 一次都不触发)。
- **判播完必须读 `eof-reached` 属性**,不能等 `END_FILE` —— `keep-open` 下它永远不发。
  核心层已经处理,UI 只认 `player.status` 里的 `eof`。
- **进度上报三件套必须带 `PlaySessionId`**(核心层负责),UI 只管调 `emby.reportProgress`
  的节奏:播放中每 10 s 一次 + 暂停 / 退出 / 播完各一次。

### 8.7 弹幕层

- 渲染走核心层的 `osd-overlay`(`SPEC.md` §7.5),**不占字幕轨**。
- **UI 不画弹幕**,只发开关与样式设置(`danmaku.*`)。
- 面板里的「屏蔽词 / 黑名单 / 类型过滤」**必须真接线**(`danmaku.filter`)——
  TODO N12 记着前端零接线且 UI 在骗用户。

### 8.8 字幕

- ☠ **`sub-fonts-dir=/system/fonts`**,否则 libass 缺字体 → **文本字幕整个不显示**。
  桌面早有、安卓漏过。这条由核心层在 android 构建下设,UI 不管 —— 但**验收要验**。
- 外挂字幕 `player.addSubtitle`:核心层已处理「必须等 `FILE_LOADED` 且只能在事件线程挂载」。

### 8.9 安卓软解调优(TODO N2 —— 旧栈丢过一次,这次主动做进去)

安卓端 libmpv 是纯软解,不调优的表现是 1080p 以上卡顿。核心层在 android 下设:

| 选项 | 值 | 为什么 |
|---|---|---|
| `vd-lavc-threads` | CPU 核数(封顶 8) | 默认是 1 |
| `vd-lavc-skiploopfilter` | `nonref` | 去环路滤波是软解最大的一块 |
| `vd-lavc-fast` | `yes` | 允许不完全符合规范的加速 |
| `hdr-compute-peak` | `no` | 移动端软解下这个是纯浪费 |
| `vd` | `-magicyuv` | CVE-2026-8461 防护(TODO N1) |

**这一段归核心层**,写在这里是因为 UI 侧的验收要看到它生效(`player.mpvGet` 回读)。

---

## 9. 无障碍

**不做完整读屏适配,但这五条是底线**(它们同时也让普通用户受益):

| 项 | 要求 | 落法 |
|---|---|---|
| 触摸目标 | **≥ 48 dp** | M3 组件自动;自绘的显式 `sizeIn(minWidth=48.dp, minHeight=48.dp)` |
| TalkBack | 每个纯图标按钮都有 `contentDescription` | 装饰性图片给 `null`;卡片用 `Modifier.semantics { mergeDescendants = true }` 让整卡读成一条 |
| 对比度 | 正文对底 ≥ **4.5:1**,次要 ≥ **3:1**,**两套主题都要量** | §11 有一条自动检查 |
| 字体缩放 | 200% 下不截断、不溢出 | 字号一律 `sp`;卡片标题给 `maxLines` 但容器高度**不写死** |
| 颜色不是唯一载体 | 服务器状态点配文字(§7.8);已看用勾不只用绿 | — |

- **播放页横屏的 chip 是 32 dp**(§1.5 的例外),但**命中区仍然 ≥44 dp** ——
  无障碍这条不能因为空间紧就破。

---

## 10. 性能预算

### 10.1 预算(越线即红)

| 指标 | 预算 | 怎么量 |
|---|---|---|
| 冷启动到首帧骨架(TTID) | ≤ **800 ms** | `adb shell am start -W` 的 `TotalTime`;logcat 的 `Displayed` 行 |
| 冷启动到首页有内容(TTFD) | ≤ **2.0 s**(局域网服务器) | `reportFullyDrawn()` + logcat |
| 页面切换到骨架 | ≤ **100 ms** | 手动计时 / Macrobenchmark |
| 列表滚动 | **无掉帧**(120 Hz 屏 8.3 ms 预算) | `adb shell dumpsys gfxinfo <pkg>` 的 janky frames |
| 空闲内存 | ≤ **300 MB** PSS | `adb shell dumpsys meminfo <pkg>` |
| APK 体积(单 ABI) | ≤ **45 MB** | `unzip -l` |
| 进度条拖动延迟 | ≤ 1 帧 | 目测 + §2.3 第 3 条的落法保证 |

> ★ 数字的来源:TTID/TTFD 用 Android Vitals 的「冷启动 < 5 s 才不算差」做下限,
> 本项目自己收紧到 800 ms / 2.0 s;APK 45 MB 是从实测的
> `liblpcore.so` 18.4 MB + `libmpv.so` 16.1 MB(arm64,strip 后)反推的 ——
> 两个 `.so` 压缩后约 14 MB,加 Compose 运行时与资源。
> **超了先看 `.so` 有没有 strip**:不 strip 会从 21 MB 涨到 105 MB(栽过)。

### 10.2 落法

| 手段 | 说明 |
|---|---|
| `LazyColumn` / `LazyVerticalGrid` | 所有网格与长列表。**必须给 `key`(条目 id)与 `contentType`(卡片变体)** |
| 分页触发 | **不用 Paging 3。** 分页在核心层(offset/limit,页大小从响应学)。UI 看 `LazyListState.layoutInfo`:`lastVisibleItemIndex >= totalItems - 6` 就请求下一页,**并用一个 `loading` 闩防重入** |
| 图片按需 | 屏外不解码。Coil + `key` 保证复用不重发 |
| 各块独立加载态 | 页面**不持有一个全局 loading** |
| 同面板内请求并发 | 串行 await 会把后端本身的卡**放大 N 倍** |
| 分页拉分集 | 【实测,PC 侧】最长那部剧 2648 集:全量 1813.9 KB / 1841 ms,分页 30 条 **20.0 KB / 435 ms** |
| 跟手绕过重组 | §2.3 第 3 条 |
| Baseline Profile | `androidx.profileinstaller` 引入。**本轮只引依赖不生成 profile** —— 生成要跑 Macrobenchmark,记为欠账 |
| 强跳过模式 | Kotlin 2.x 的 strong skipping 默认开。**状态类一律 `data class` + 不可变集合语义**,别往 state 里塞 `MutableList` |

### 10.3 缓存口径

| 缓存 | 口径 |
|---|---|
| 详情 | **内存 TTL 5 分钟,不落盘。** 里面带续播进度 / 收藏 / 已看,随时会变还会被别的设备改。落盘跨重启复用 = **给自己造一个「进度莫名回退」的 bug** |
| 列表 | 缓存,**尤其为了返回键**(返回时不许重新拉) |
| 随机推荐 | **也要缓存**。不缓存 = 每次退回首页都要重新下 5 张大图 |
| 图片 | **核心层落盘,UI 只留内存**(§4.4) |
| 失效 | 靠核心层的 `data.invalidate` 事件;**切服务器 / 切线路 / 重登必须清详情缓存** |
| 缓存键 | **必须编进全部入参**,「形状不同的同名数据」要分池 |

---

## 11. 验收清单

阶段 ⑥ 直接拿这一节对账。**每一页都要过 §11.1,全局过 §11.2。**

### 11.1 每个页面

- [ ] `gradlew assembleDebug` 绿
- [ ] `am start` 直达这一页,**截图看过**,版式与 §7 该页规格一致
- [ ] `logcat` 这条路径上没有 `FATAL` / `AndroidRuntime` / 未捕获异常
- [ ] **空态 / 错误态 / 加载态三态都截过图**(正常数据下看不到,但最容易做砸)
- [ ] 这一页用到的每条核心层命令**都真调过**(不是 mock)
- [ ] 骨架先出,各块各自渲染,**没有全局 loading**
- [ ] 一个区块失败不整页报错;地基块失败才整页报错
- [ ] 空态区分「真的没有 / 没配置 / 被筛掉了」三种
- [ ] 卡片有长按菜单,且**菜单项与别处是同一份定义**
- [ ] **深浅两套主题都看过**,叠在画面上的控件在浅色下不是深底深字
- [ ] 竖屏 / 横屏都看过,不溢出、不留大片空白
- [ ] 200% 字体缩放下不截断
- [ ] 返回时滚动位置恢复,且**没有重新拉取**
- [ ] 触摸目标 ≥48 dp

### 11.2 全局

- [ ] 冷启动六步顺序正确(§7.0),第 5 步**两条命令都看**
- [ ] 底栏三个 Tab **各自独立返回栈**,来回切不丢滚动位置
- [ ] `E_UNSUPPORTED` **一次错都不弹**;`unsupported` 里的命令对应入口启动时就不画
- [ ] 深浅色:**`values-vXX` 与 `values-night-vXX` 两份都建**
- [ ] 开屏图标在 Android 12+ 上**不放大满幅**
- [ ] 快速旋转 100 次不崩(U1.28)
- [ ] 切后台音频不断、通知常驻、杀进程干净收尾
- [ ] 深链 `linplayer://` **冷启动与热启动两条路径**都拿得到 URL
- [ ] release APK **已签名**:`unzip -l` 看得到 `META-INF` 证书 + "APK Sig Block 42" 魔数
- [ ] `.so` 已 strip,APK 体积在预算内
- [ ] 命令名门禁:**本文 §7 出现的每个命令名都在 `COMMANDS.md` 里**

### 11.3 自检手段

**「编译通过」不是交付。** UI 布局 / 可见性 / 时序必须真渲染验证。

| 要验什么 | 手段 |
|---|---|
| 真实布局 | `adb exec-out screencap -p > shot.png`,**然后你自己看这张图** |
| **视频层有没有画面** | ☠ **`screencap` 抓不到视频层时不要下「没画面」的结论。** 某些合成路径下 SurfaceView 的内容不进 framebuffer。判有没有画面要用 `adb shell dumpsys SurfaceFlinger` 看图层与可见区域 + `player.status` 属性回读。这是 Windows 侧「截图截不到视频层、要用 `EnumWindows` 量窗口类」的同类问题 |
| 崩溃 / 异常 | `adb logcat -d -v brief \| grep -iE "linplayer\|mpv\|AndroidRuntime\|FATAL"` |
| 纯逻辑 | JVM 单测直跑**本尊模块**,不许抄副本 |
| 关键路径 | Compose UI Test(U1.20) |
| 假服务器 | `go run ./core/cmd/fakeemby -addr 0.0.0.0:18096 -gzip -clip <本地视频> -clip-secs <真实时长>`。☠ **`-clip-secs` 必须给真实时长**,不给的话一切按百分比算的功能(看完阈值 / 进度条 / 片头片尾跳过)全在对着一个假数验 |

**新测试必须先红。** 反向注入一个真 bug 确认它变红,再修好。
假绿的五种形态:注入不忠实 / 环境不同 / 夹具不真实 / 语料选错 /
**断言的时序让 bug 没机会发生**。

---

## 12. 依赖清单(**定死。要加就回来改这份文档**)

版本的实测依据见 [`research/VERSIONS_VERIFIED.md`](research/VERSIONS_VERIFIED.md)。

| 依赖 | 版本 | 用途 | 官方为什么不够 |
|---|---|---|---|
| Gradle | 8.14.3 | 构建 | — |
| AGP | 8.13.2 | 构建 | — |
| Kotlin + compose 编译器插件 | 2.4.10 | 语言 | — |
| `androidx.compose:compose-bom` | 2026.08.00 | 统一 Compose 版本 | — |
| `androidx.compose.material3:material3` | (BOM) 1.4.0 | 组件库 | — |
| `androidx.compose.material3:material3-window-size-class` | (BOM) | 断点(§3.3) | — |
| `androidx.activity:activity-compose` | 1.13.0 | Activity 集成 / predictive back | — |
| `androidx.navigation:navigation-compose` | 2.10.0 | 路由 + 多返回栈 | 官方件,就是它 |
| `androidx.lifecycle:lifecycle-runtime-compose` | 2.11.0 | `collectAsStateWithLifecycle` | — |
| `androidx.lifecycle:lifecycle-viewmodel-compose` | 2.11.0 | ViewModel | — |
| `androidx.core:core-splashscreen` | 1.2.0 | 开屏(U1.17) | — |
| `androidx.core:core-ktx` | (最新 stable) | insets / 系统 API | — |
| `androidx.media3:media3-session` | 1.11.0 | MediaSession + 通知栏(U1.21) | 平台 `MediaSession` 的通知栏样式在各版本行为不一;**只取 session,不取 exoplayer** |
| `androidx.window:window` | 1.5.1 | 折叠屏(§3.4) | — |
| `androidx.profileinstaller:profileinstaller` | 1.4.1 | Baseline Profile 载入 | — |
| `org.jetbrains.kotlinx:kotlinx-serialization-json` | (随 Kotlin) | 命令 JSON + 类型安全路由 | — |
| `io.coil-kt.coil3:coil-compose` | 3.6.2 | 图片(§4.4) | **androidx 没有 Compose 图片加载器** |
| `io.coil-kt.coil3:coil-network-okhttp` | 3.6.2 | Coil 的网络引擎 | 同上 |

**被否掉的**(理由见 `research/VERSIONS_VERIFIED.md`):telephoto(本轮没有大图页)、
Paging 3(分页在核心层)、Hilt / Koin(全局只有一个单例)、shimmer 库(25 行自己写)、
`material-icons-extended`(几 MB 换 40 个图标)、任何 ExoPlayer(解码在 libmpv)。

---

## 附:与 PC 端的对应

| PC | 手机 | 说明 |
|---|---|---|
| 侧栏 212/72 | **底栏三 Tab** | 手机没有侧栏的宽度 |
| 右键菜单 | **长按菜单** | 同一份动作定义 |
| 悬停动作覆盖层 | **无** | 手机没有悬停,动作全在长按菜单里 |
| 快捷键 + `;` 提示层 | **无** | 没有键盘。设置页也没有「快捷键」这一项 |
| 独立播放窗口 | **同一个 Activity 的全屏页** | 手机没有多窗口 |
| 主从两栏(设置 / 添加服务器) | **一级列表 + 二级页** | |
| `Ctrl+K` 搜索浮层 | 首页右上角 + 聚合页顶部搜索条 | |
| 悬停提示(tooltip) | **文字直接写在界面上** | 状态点旁边写「未检测 / 不通」 |
| 拖入文件播放 | **无** | 安卓没有桌面级拖放;本机文件走 SAF(§7.16) |
| 应用内更新 | **只提示,跳发布页** | §6.5 |
