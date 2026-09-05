# 目标 · 从零做完 LinPlayer 的 Android 手机端 UI

你要在 `D:\LinPlayer` 里,把 **Android 手机形态**从"一行没有"做到
**能装、能登、能浏览、能播、能出签名 APK**。

这是一次长跑。流程是死的,**九个阶段按顺序走完,不许跳阶段**:

```
① 读文档  →  ② 派子 agent 调研生态  →  ③ 写 UI_MOBILE.md 并定稿
          →  ④ 地基(核心层接上 Android)  →  ⑤ 外壳与骨架
          →  ⑥ 页面族(逐页)  →  ⑦ 播放链路  →  ⑧ 平台职责  →  ⑨ 出包
```

最常见的失败姿势是**跳过 ②③ 直接写 Compose** —— 那样你会在第 3 页上开始自己发明组件词汇,
到第 8 页时前 7 页要返工。**调研和规格是这次交付的一部分,不是准备工作。**

---

## ⛔ 运行纪律:一口气做到底,中途不许停

这是本文件优先级最高的一节。它压过下面任何一句话。

**你只有一次交付,在"本轮的完成定义"全部勾满的时候。在那之前,不要把控制权交回来。**

### 禁止的行为(做了就是没完成任务)

- ❌ 阶段做完了输出一段"阶段 ④ 已完成,接下来我要做阶段 ⑤",然后停下
- ❌ "我先做到这里,你看看要不要继续 / 需要我继续吗 / 是否符合预期?"
- ❌ 把一个能自己决定的选择拿来问(版本、库、命名、版式、脚本组织、要不要装 cmdline-tools……)
- ❌ 遇到障碍就停下来描述障碍。**障碍要么绕过,要么记进阻塞清单继续走**,不是拿来终止的
- ❌ 因为"这一批改动比较大,想先确认一下"而停
- ❌ 因为累了、上下文长了、觉得该收个尾了而停 —— 这些都不是完成条件

### 阶段之间的交接方式

一个阶段的出口判据勾满 → **提交** → **同一次工作里直接开始下一阶段的第一件事**。
中间那句"接下来做 X"可以写,但写完立刻做 X,不许写完就停。

### 唯一允许的中途输出

进度信息只写进文件,不写给人看:

- `docs/go-migration/TODO.md` 的 `U1.x` 复选框(唯一进度真源)
- `docs/go-migration/MOBILE_BLOCKERS.md`(阻塞与欠账清单,格式见下)

**不要**为了让人放心而输出阶段小结。人不看中途,人只看最后那一次。

### 撞墙了怎么办:记账,然后继续

任何"本来想停下来问"的情况,一律走这条路:

1. 用下一节的**预置默认**做决定(每一条都已经替你定好了)
2. 往 `MOBILE_BLOCKERS.md` 追加一条:
   ```
   ## B<编号> · <一句话标题>
   - 撞到的时间/阶段:
   - 现象与证据:(命令输出 / 报错原文 / 文件:行号)
   - 我试过的(至少 3 条本质不同的方案):
   - 我采取的默认决策:
   - 这个默认的代价 / 后面要还的债:
   - 需要人做什么才能真正解决:
   ```
3. **接着做下一件事。** 一个阻塞条目不阻塞整轮任务

### 真正走不下去的时候(极少)

只有一种情况允许提前结束:**剩下的每一件事都被同一个阻塞卡住,且预置默认全部用尽**。
那时也不要问问题,而是输出一份**结构化终止报告**:已完成清单 + `MOBILE_BLOCKERS.md` 全文 +
每个阻塞需要人做的具体动作 + 人做完之后怎么续跑。然后才结束。

> 判据:"我无法解决"这五个字出现之前,那一条的排查顺序(见文末)必须已经走完六步。
> 没走完就说走不下去 = 没完成任务。

---

## 阶段 ① · 开工前必须读完的东西

不读 = 返工。读完在回复里列出你从每份文档里拿到的**关键约束**,不要只说"已读"。

| 文件 | 为什么 |
|---|---|
| `AGENTS.md` | 仓库规矩、构建命令、红线。**全文** |
| `CLAUDE.md` | 代码风格刻度(圆角/间距/颜色是**枚举不是区间**)、注释纪律、**派子 agent 的规矩**(§3) |
| `docs/go-migration/SPEC.md` §5 / §7.2 / §8.0–8.2 / §8.5 | FFI 契约、视频通道 A、启动时序、页面集合、Android 规格、平台职责分工 |
| `docs/go-migration/UI_PC.md`(1206 行) | **PC 端 19 页逐页规格**。你写 `UI_MOBILE.md` 时它是**结构范本 + 行为语义来源** |
| `docs/go-migration/TODO.md` 顶部范围裁剪 + §5.2(U1.1–U1.28) | 你的任务清单本体,带判据 |
| `docs/go-migration/COMMANDS.md` | 218 条命令契约 |
| `docs/mobile-drafts/README.md` + 双击 `pages.html` | **手机端版式真源**:48 格逐页草稿 + 170 条编号标注 |
| `docs/lessons/` 里 android / mpv / 布局相关的文件 | 历史踩坑正本。遇到"这为什么这么写"先 grep 这里 |

三条读的时候就要记住的事:

1. **技术选型已经定死了,不许再选。** `SPEC.md` §8.2:手机形态 = **Kotlin + Compose + Material 3**,
   视频用 **`SurfaceView`**(不是 `TextureView`),开屏用 `androidx.core.splashscreen`。
   阶段 ② 的调研是选**这个框架内部**的组件与库,不是重新评估框架。
2. **`docs/mobile-drafts/` 是旧 Web 栈的原型。** 它的**版式、信息层级、动效时序、交互语义**全部有效,
   **代码一行都不能搬**。当设计稿看,不是当实现看。
3. **范围已于 2026-09-04 裁剪过,老文档里有作废段落。** 以 `TODO.md` 顶部那两个 ⚠️ 为准:
   - **不做**:网盘(阿里/百度/115/189/139/夸克/OpenList/飞牛)、局域网源(SMB/WebDAV/FTP)、**Ani-RSS 管理台**
   - **保留**:本机文件夹播放(`local`)、通用文件浏览页、影视目录页(只走插件 `plugin:<插件id>/<源id>`)
   - `SPEC.md` §8.1 的页面表和 `TODO.md` §5.2 的 U1.14 里还留着 Ani-RSS,**那是历史记录,不是任务**

---

## 阶段 ② · 派子 agent 调研 Compose 生态

**目的**:动手之前先把"用什么组件、用什么动效原语、用什么图片库"查清楚,
让 `UI_MOBILE.md` 里的每一条都落在**真实存在、还在维护、版本对得上**的东西上。
没有这一步,规格会写成一堆"应该有个卡片组件"的空话。

### 派法(照 `CLAUDE.md` §3 执行,这些是硬要求)

- **一次消息里并发派完 6 个**,不要一个一个来
- **用 Haiku**(`model: "haiku"`)—— 这是资料收集不是架构决策,便宜且够用
- **六个 agent 的读取范围不许重叠**
- 每个 agent 的 prompt 里**必须写死**:
  1. 调研哪几个具体问题(列条目,不许只说"分析一下")
  2. **输出到哪个文件 + 什么结构**(直接写文件,不许把内容回吐进你的上下文)
  3. 每条结论带**出处**(官方文档 URL / 仓库路径 / 版本号)
  4. **不许写"应该/可能/大概"** —— 查不到就写"未确认"+ 说明查了哪里
  5. **每次工具调用写入不超过 120 行,写完停,再写下一段**,用 `cat >> 文件 <<'EOF'` 追加
  6. **禁止再派子 agent**(嵌套是脆断的放大器)
  7. **不许修改任何代码**
  8. 不许在输出里写真实域名/IP/账号/密码/token,一律占位符

### 六个调研题目

产物统一放 `docs/go-migration/research/`,文件名如下:

| # | 文件 | 查什么 |
|---|---|---|
| R1 | `MOBILE_COMPONENTS.md` | Material 3 官方组件覆盖了本项目的哪些需求、缺口在哪;第三方组件库(卡片/网格/骨架屏/下拉刷新/底部弹层/芯片/分段控件/长按菜单)的候选与取舍 |
| R2 | `MOBILE_MOTION.md` | Compose 动画 API 全貌:`SharedTransitionLayout` 共享元素、`AnimatedContent`、predictive back、M3 的 easing/duration token、手势驱动动画(侧滑返回、下拉刷新、播放器手势)。**旧 Web 原型里那套 FLIP/sheet 物理在 Compose 里的等价物是什么** |
| R3 | `MOBILE_IMAGES.md` | 图片加载库候选(内存+磁盘缓存、占位与淡入、缩略图/BIF、主色提取、可缩放大图);与核心层"UI 传期望宽度、核心层决定实际取多大"这条分工怎么配合 |
| R4 | `MOBILE_PLAYER.md` | 播放页相关的**平台官方最佳实践**:`SurfaceView` 生命周期、`MediaSession`+通知栏、前台服务、音频焦点、画中画、屏幕常亮、旋屏/分屏/折叠屏形变。**注意:我们不用 ExoPlayer/Media3 的播放器,只可能用它的 MediaSession 部分** —— 解码与渲染全在核心层的 libmpv 里 |
| R5 | `MOBILE_NAV_STATE.md` | 导航与状态:Navigation Compose 的类型安全路由、返回栈、**滚动位置恢复**、进程死亡恢复、深链接入;单向数据流在"UI 层零业务逻辑"约束下的最小形态 |
| R6 | `MOBILE_PERF_A11Y.md` | 列表性能(`LazyColumn`/`LazyVerticalGrid` 的 key/contentType、分页触发、图片回收)、启动耗时、包体积;无障碍(TalkBack、触摸目标 ≥48dp、深浅色对比度、字体缩放) |

### 每条候选库必须回答的六个问题(缺一条这条结论作废)

1. 最近一次发布是什么时候?**stable 还是 alpha?**
2. 与我们要用的 Compose / Kotlin / AGP 版本兼容吗?
3. 许可证是什么?
4. 对包体积的影响量级?
5. **官方 API 能不能做?能做就不要它** —— 每引入一个第三方依赖,
   必须在结论里写清"为什么 Material 3 / 官方 androidx 不够"
6. 它死了会怎样?换掉的代价多大?

> **减法优先。** 这个仓库的纪律是"不为一个实现造接口,不为一个值造配置"。
> 调研的产出如果是"引入 9 个库",那多半是调研做砸了,不是生态丰富。

### 阶段 ② 的出口判据

- [ ] 六份 `research/MOBILE_*.md` 都在,每份都有出处、有版本号、有"选/不选"的结论
- [ ] 你**抽查过至少 6 条出处**(每份抽 1 条),对不上的打回重做
  —— 子 agent 的结论不许照单全收;它说"没找到"也不等于不存在
- [ ] 有一份**最终依赖清单**:每个依赖一行,写明版本、用途、以及"官方为什么不够"

---

## 阶段 ③ · 写 `docs/go-migration/UI_MOBILE.md` 并定稿

**这是本轮最重要的产物之一。** 没有它,后面 15 页会各写各的。

### 它和现有文档的分工

- **跨端契约**(换个 UI 框架还成立)→ 写进 `SPEC.md`,不要在这里重复
- **手机端呈现**(换个框架就不成立)→ 写进 `UI_MOBILE.md`
- **行为语义**(点了这个该发生什么、错误码怎么映射、空态说什么)→ **从 `UI_PC.md` 继承**,
  只在手机端确实不同的地方写差异,不要整段抄

### 结构(照 `UI_PC.md` 的目录,按手机改)

```
0. 这份文档的地位 + 三条来源及其权重 + 标注约定
1. 设计系统      色 / 字 / 间距圆角线阴影 / 图标 / 触摸目标
                 ★ 值以 UI_PC.md §1.1 为语义基准,映射到 Material 3 的 token 体系
                 ★ 刻度是枚举:圆角/间距/颜色各自列出允许值,不给区间
2. 动效规范      token / 转场目录 / 禁令 / 减少动态(follow 系统设置)
                 ★ 来源是 R2 + docs/mobile-drafts/index.html 那 12 条待拍板
3. 布局与形变    断点(手机/大屏/折叠)/ 旋屏 / 分屏 / 手势区 / 安全区
                 ★ env(safe-area) 在安卓 edge-to-edge 下对导航条恒 0,这条要写清怎么处理
4. 组件清单与状态矩阵   每个可交互组件的 默认/悬停无/按下/聚焦/禁用/加载/错误 七态
                 ★ 组件词汇必须**收敛成一张表**,页面只能用它拼,不许各页自造
5. 交互规范      手势全表(点/长按/侧滑返回/下拉刷新/播放器三区手势)
                 返回栈与滚动恢复 / 长按菜单 / 多选
                 ★ 同一块区域不许叠两个长按语义 —— 行上挂了长按、行内又要拖拽,
                   拖拽起手必须吃掉事件,否则两个手势打架
6. 反馈层        Toast(位置:全站中部偏下,播放页顶部居中)/ 对话框与确认策略 /
                 错误码 → UI 行为映射(E_UNSUPPORTED 静默降级,不弹错)/ 加载骨架空态
                 ★ 全站废弃 bottom sheet 改居中弹窗(既有决定)
7. 页面规格      逐页。每页:版式 / 数据来源(用哪几条命令)/ 三态 / 手势 / 判据
8. 播放页与 OSD  遮挡率目标 38.5% 量级、四种收纳手法、横竖屏两套
9. 无障碍
10. 性能预算     冷启动 / 首帧 / 列表滚动 / 内存 / 包体积,**每项给数字**
11. 验收清单     逐页 checklist,阶段 ⑥ 直接拿它对账
```

### 第 7 节要覆盖的页(本轮范围)

首登闸口/添加服务器 · 首页 · 媒体库+筛选 · 详情页族(**剧/影/季/集四张分开设计**) ·
搜索(全局/库内/包括集) · 聚合视界 · 收藏 · 服务器管理/线路 · 文件浏览 ·
影视目录 · 下载 · 插件市场/已装 · 排行榜 · 追剧日历 · 设置 · 播放页

**不做**:Ani-RSS 管理台(范围已砍)、TV 形态全部页面(U1.16 不在本轮)。

### 阶段 ③ 的出口判据

- [ ] `UI_MOBILE.md` 十一节齐全,第 7 节 16 页逐页有规格
- [ ] 每页的"数据来源"列出的命令名,**逐条在 `COMMANDS.md` 里存在**(拼错了编译器不管)
- [ ] 设计 token 表与 `UI_PC.md` §1.1 **语义对齐**(不要求像素一致,要求同名同义)
- [ ] 依赖清单已并入本文档,后面写码不许再临时加依赖 —— 要加就回来改这份文档
- [ ] `README.md` 的文档表里加上 `UI_MOBILE.md` 一行
- [ ] **提交并推送**。这是一个门禁,不是草稿

---

## 阶段 ④ · 地基:把核心层接到 Android 上

### 先纠正一个前提:后端"做好了"只对了一半

盘点过的事实(2026-09-06):

| 事项 | 状态 |
|---|---|
| Go 核心层 `core/**`,218/218 条命令 | ✅ 满格 |
| Windows 外壳(C#/Avalonia,57 文件 / 18616 行) | ✅ 出得了包 |
| `bindings/kotlin/Commands.g.kt`(721 行,命令名全表 + 接口) | ✅ 已生成、编得过 |
| **`apps/android/`** | ❌ **目录不存在** |
| **lpcore 的 Android `.so`** | ❌ 没有;`scripts/build-core-android.sh` **不存在**(TODO S2.3 未做) |
| **JNI 薄层 / 事件线程 / `lp_set_surface`** | ❌ 没有(TODO B2.1 未做) |
| **libmpv 的 Android `.so`** | ❌ `third_party/libmpv/` 只有 Windows 的 `.dll/.lib/.h` |
| 本机 AVD | ❌ `~/.android/avd` 是空的;`adb devices` 无设备 |

本机已有(别重复安装):Android SDK 在 `%LOCALAPPDATA%\Android\Sdk`,
NDK `27.0.12077973` / `28.2.13676358` / `30.0.14904198`、emulator、platform-tools、
build-tools 35–37、platforms android-24/34/35/36/36.1/37.0;
系统镜像只有 `system-images;android-37.0;google_apis_playstore_ps16k;x86_64`;
JDK 21;Go 工具链在 `.toolchain/`(`source scripts/env.sh` 激活)。
⚠️ **没有 `cmdline-tools`** → 没有 `avdmanager` / `sdkmanager`,造 AVD 的三条路见阶段 ⑥ 的 §验证回路。

> 阶段 ② 的六个子 agent 在后台跑着的时候,你可以同时推进 ④.1 和 ④.2 —— 它们不冲突。
> 但 ⑤ 之后的任何一行 UI 代码,都要等 `UI_MOBILE.md` 定稿。

- **④.1** `scripts/build-core-android.sh`:cgo + NDK clang 交叉编译 `lpcore` 成 `.so`
  - ABI 至少两个:`x86_64`(模拟器)、`arm64-v8a`(真机);`armeabi-v7a` / `x86` 可后补
  - 判据:`file` 看得到 ELF 与正确机器类型;`nm -D` 里有 `lp_init` / `lp_call` / `lp_next_event` / `lp_set_surface`
  - 判据:**strip 掉调试信息** —— 不 strip 的话 APK 从 21MB 涨到 105MB(栽过)
  - 注:安卓侧**不用 zig**,走已装的 NDK clang(`AGENTS.md` §2.2)
- **④.2** 拿到 Android 的 libmpv(至少上面两个 ABI)
  - 旧栈用的是 `media-kit/libmpv-android-video-build` 的产物
  - 判据:**`.so` 不入仓库**,脚本/CI 现拉(同 Windows 侧 `libmpv-2.dll` 的做法,见 `.github/workflows/build.yml`)
  - 判据:ELF 魔数校验 —— LFS 指针混进 APK 的表现是 `UnsatisfiedLinkError: bad ELF magic 76657273`
- **④.3** `apps/android/` 工程骨架 + JNI 薄层
  - 判据:`gradlew assembleDebug` 出 APK;装上去起得来一个空 Activity
  - 判据:`lp_init` 成功;`system.capabilities` 有返回;事件线程收得到事件
  - ⚠️ `lp_next_event` **有且只有一个消费者线程**。两个线程同时调不崩,而是事件被随机分掉,
    表现是"有时候收得到有时候收不到"
- **④.4** `CoreClient`:Kotlin 侧命令层
  - **把 `bindings/kotlin/Commands.g.kt` 拉进 sourceSet,不许拷贝改写** —— 它是生成物,
    改了 `check-bindings.sh` 第 4 关会红
  - 判据:`suspend fun call(cmd, args)` 挂起到 result 事件回来;事件走 Flow
- **④.5** R8 keep 规则
  - 判据:release 下 JNI 回调的方法不被裁 —— 被裁的表现是 `NoSuchMethodError` → `SIGABRT`(栽过)

> **地基卡死的逃生舱**:④.2 一时拿不到时,**允许**先做 `FakeCoreClient`
> (纯 Kotlin,按 `COMMANDS.md` 返回假数据),让阶段 ⑤⑥ 并行推进。
> 但这是**临时脚手架**,阶段 ⑦ 之前必须换回真核心,且要能一次删干净。

---

## 阶段 ⑤ · 外壳与骨架

- **U1.1** 双形态分流:`UiModeManager.currentModeType == UI_MODE_TYPE_TELEVISION`。
  本轮**只做手机形态**,TV 分支留空壳 Activity
- **启动时序严格按 `SPEC.md` §8.0 的 6 步**,两条硬约束不许破:
  - 第 5 步**必须同时看** `emby.currentSession` 和 `source.currentSource`
    —— 只判 Emby 会话的话有一类用户永远进不了门,这是有过的真实故障
  - 第 6 步**不许有屏障**。骨架先出、各块各自渲染是**契约不是优化**
    —— 实测串行等待比并发慢 5.5 倍,而用户会把它描述成"不秒加载"并归咎于动画
- 底栏三个 Tab:**首页 / 聚合视界 / 服务器**(用户定的,别加第四个)
- **U1.18** 深浅色:`values-vXX` 与 `values-night-vXX` **两份都建** —— `-night` 压过 `-vXX`,
  只建一份的表现是"浅色修好了深色没修"
- **U1.17** 开屏:`androidx.core.splashscreen`,**图标边距留在 drawable 内部**,否则 Android 12 放大满幅

---

## 阶段 ⑥ · 页面族(逐页,每页做完立刻跑验证回路)

按此顺序:**U1.2** 首登闸口/添加服务器(渲染 `source.formSchema`,字段定义在核心层,UI 只写渲染器)
→ **U1.3** 首页 → **U1.4** 媒体库+筛选 → **U1.5** 详情页族(四张分开设计)
→ **U1.7** 搜索(三个入口都点一遍;"包括集"默认关,分集单独一栏横版)
→ **U1.8** 聚合视界 → **U1.9** 收藏/服务器管理/线路 → **U1.10** 文件浏览
→ **U1.11** 影视目录(**与文件浏览是两套页面,不复用** —— 复用过一次,六个毛病都是那个决定的症状)
→ **U1.12** 下载 → **U1.13** 插件市场/已装 → **U1.14** 排行榜/日历 → **U1.15** 设置。

### 自动验证回路(**全自动的关键,别跳**)

仓库铁律:**"编译通过"不是交付。** UI 布局/焦点/可见性必须**真渲染验证**。

**先把跑的地方搞出来**,按序试,前一条不行再试下一条:

1. `adb devices` 有真机 → 直接用(arm64,记得 ④.1 要出 `arm64-v8a`)
2. 造 AVD。本机没有 `cmdline-tools`,两条路:
   - 下 Google 的 `commandlinetools-win` 解到 SDK 的 `cmdline-tools/latest/`,再
     `avdmanager create avd -n lp-phone -k "system-images;android-37.0;google_apis_playstore_ps16k;x86_64" -d pixel_6`
   - 或**手写** `~/.android/avd/lp-phone.ini` + `lp-phone.avd/config.ini`(emulator 直接读这两个文件)
   - 起:`emulator -avd lp-phone -no-boot-anim -no-audio`,
     等 `adb wait-for-device shell getprop sys.boot_completed` 回 `1`
3. 两条都不通 → 停下来问人

**假 Emby(不许用真服务器,红线)**:

```bash
source scripts/env.sh
go run ./core/cmd/fakeemby -addr 0.0.0.0:18096 -gzip -clip <本地视频> -clip-secs <真实时长秒>
```

- 模拟器里访问主机是 `10.0.2.2:18096`;真机用同网段主机地址(**别写进任何提交**)
- ☠ `-clip-secs` 必须给**真实时长**。不给的话它报写死的假片长,
  一切按百分比算的功能(看完阈值/进度条/片头片尾跳过)全在对着一个假数验
- 其它开关 `-h` 看全表:`-reject`(登录一律 401)`-no-avatar`(验图标回退)
  `-transcode-only`(只给转码地址,验我们照样直连)`-no-boxset`(验首页那条整条不画)`-eps`(验虚拟化)
- **`scripts/selfcheck-win.sh` 是这一套的完整范本**,照它写 `scripts/selfcheck-android.sh`

**每页做完必跑**:

```bash
adb install -r <apk>
adb shell am start -n <包名>/.MainActivity          # 支持直达某一页的调试入口,照 selfcheck-win.sh 的 SelfCheckJump 做
adb exec-out screencap -p > shot.png                # 然后你自己看这张图
adb logcat -d -v brief | grep -iE "linplayer|mpv|AndroidRuntime|FATAL"
```

**看截图,不是看编译输出。** 这个仓库栽过的三类 bug —— 渲染抛错=一片黑不报错 /
卡片没加 ready 态=封面隐身 / 命令全绿但白名单空=一张封面都没有 —— **全都只有真渲染才现形**。

☠ **`screencap` 抓不到视频层时不要下"没画面"的结论。** 某些合成路径下 SurfaceView 的内容
不进 framebuffer 截图。判有没有画面要用 `adb shell dumpsys SurfaceFlinger` 看图层与可见区域,
外加 `player.*` 属性回读 —— 这是 Windows 侧"截图截不到视频层、要用 `EnumWindows` 量窗口类"的同类问题。

**反向注入**:任何你新加的测试/自检脚本,先注入一个真 bug 确认它变红,再修好。
不红的门禁等于没有门禁。

### 判"这一页做完了"的规则(同时满足才算完)

1. `gradlew assembleDebug` 绿
2. `am start` 直达这一页,`screencap` 截图**你看过**,版式与 `UI_MOBILE.md` §7 该页规格一致
3. `logcat` 这条路径上没有 `FATAL` / `AndroidRuntime` / 未捕获异常
4. **空态 / 错误态 / 加载态三态都截过图**(正常数据下看不到,但最容易做砸)
5. 这一页用到的每条核心层命令都真调过(不是 mock),错误码按 `UI_MOBILE.md` §6 映射
   —— 特别是 **`E_UNSUPPORTED` 不许弹错**,静默降级
6. `TODO.md` 对应的 `U1.x` 打上 `[x]`,判据的实测证据写在下面

---

## 阶段 ⑦ · 播放链路(U1.6 + U1.28)

- `SurfaceView`(**不是 `TextureView`**)—— 独立合成层,零 overdraw,Compose 内容天然画在其上
- 视频走 **`SPEC.md` §7.2 通道 A**:`lp_set_surface(kind=1, ANativeWindow_fromSurface(...), w, h)`
- ☠ **解绑必须同步阻塞**:`surfaceDestroyed` 返回后 Surface 立即失效,mpv 还在往里画就是 use-after-free。
  `SPEC.md` 把这条列为"安卓端最容易漏的一条",旧栈就漏着(TODO N5)
- **U1.28** 判据:快速反复旋转屏幕 100 次不崩
- OSD:遮挡率按既有结论的 38.5% 量级,**不是照抄竞品**(竞品像素规格不公开,别派 agent 去查)
- 字幕:`sub-fonts-dir=/system/fonts`,否则 libass 缺字体 → 文本字幕整个不显示(桌面早有、安卓漏过)
- 软解调优参数在旧栈丢过一次(TODO N2),这次**主动做进去**

---

## 阶段 ⑧ · 平台职责(`SPEC.md` §8.5 —— 不是打磨,是"能不能当播放器用"的下限)

U1.21 MediaSession+通知栏 / U1.22 前台服务+后台播放 / U1.23 音频焦点 /
U1.24 屏幕常亮 / U1.25 画中画 / U1.26 深链 `linplayer://` / U1.27 运行时权限

- U1.22 判据:切后台音频不断;通知常驻;**杀进程能干净收尾 —— 先 `lp_set_surface(0,…)` 再销毁**
- U1.26 判据:**冷启动与热启动两条路径**都能拿到 URL 并调 `account.parseDeepLink`
- U1.27 注:本机文件播放要有**越狱闸**(路径校验)。旧栈安卓侧只有 INTERNET 权限,这次一并补

---

## 阶段 ⑨ · 出包(U1.19 + U1.20)

- **U1.19** 签名:判据 `unzip -l` 看得到 `META-INF` 证书 + "APK Sig Block 42" 魔数
  - ⚠️ **`keystore.properties` 写了 ≠ 用了**。release 变体没挂 `signingConfig` 会静默出
    `-unsigned.apk`,表现是用户装的时候报"安装包无效"
- **U1.20** Compose UI Test 覆盖关键路径
- `scripts/pack-android.sh`(照 `pack-win.sh` 的形状),CI 里 Android libmpv 那步要有 ELF 校验

---

## 红线(碰了就是返工)

1. **任何 IP、域名、端口、账号、密码、密钥、token 不得出现在任何提交里** ——
   代码、注释、文档、commit message 全算。推之前扫:
   `grep -rnE '[0-9]{1,3}(\.[0-9]{1,3}){3}|root@|:[0-9]{4,5}\b|passw|token'`
2. **`git add` 逐个文件,禁用 `-A`**。构建产物、`.so`、APK 必须 gitignore
3. **UI 层零出网。** 一切网络请求走核心层,唯一例外是数据通道那几个本地 URL(`SPEC.md` §6)
4. **UI 层不许自己实现**:版本/音轨/字幕的选择算法、排序筛选去重、重试策略、分页大小、
   凭据与签名、持久化。UI 只展示核心层给的 `preferred` 标记,
   **不许自己回落 `versions[0]`** —— 这条有真实故障:正则真选对了版本,
   但详情页写死回落,用户看到的是"功能没生效"
5. **风格刻度是枚举不是区间**。要用第五种圆角,先改 `UI_MOBILE.md` §1 那张表,别就地写新值
6. **注释只回答"为什么"**,一段不超过 6 行,写中文。过程写 `docs/lessons/`,不写进代码
7. **不加没有触发路径的兜底**。写 try/catch 前先答:这里真会抛吗?抛了用户该看到什么?
   两个都答不上就别写
8. 不写"待接""暂无""TODO 以后补"。要么做,要么删。
   —— 且这个仓库里**后端常常领先前端**:写这类注释前先 grep 命令表 + 读真实签名

---

## 直接抄的已知陷阱(踩过的,别再踩)

| 症状 | 真因 |
|---|---|
| APK 105MB 而不是 21MB | `.so` 没 strip |
| `UnsatisfiedLinkError: bad ELF magic 76657273` | APK 里是 Git LFS 指针不是真 `.so` |
| release 崩 `NoSuchMethodError` → `SIGABRT` | R8 把只被 JNI 调的方法裁了,缺 keep |
| 装的时候"安装包无效" | release 没挂 signingConfig,出的是 `-unsigned.apk` |
| 有声音没画面 | 先查 **Activity 主题的 `windowBackground`**(DayNight 给浅白/深黑),别先怀疑 mpv |
| 文本字幕整个不显示 | libass 缺字体,要 `sub-fonts-dir=/system/fonts` |
| 浅色修好了深色没修 | `-night` 压过 `-vXX`,两份都要建 |
| Android 12 开屏图标放大满幅 | 边距必须留在 drawable 内部 |
| 事件"有时候收得到有时候收不到" | 两个线程都在调 `lp_next_event` |
| 输入框一聚焦整页放大 | 字号小于 16sp 触发安卓自动放大 |
| 触摸目标点不中 | ≥48dp。唯一例外是横屏播放器的 chip:视觉 32dp,命中区撑到 44dp |
| 长按菜单和拖拽打架 | 同一区域叠了两个长按语义,拖拽起手要吃掉事件 |

---

## 决策权:全部预先授权,没有一条需要回来问

**下面这些你自己定,不许因为它们停下来:**
- 版式细节、组件拆分、命名、文件组织、动画曲线的具体数值
- NDK / Compose / Gradle / AGP 的具体版本
- 测试怎么写、自检脚本怎么组织
- 文档冲突时的裁决顺序:**范围以 `TODO.md` 顶部裁剪为准 → 功能集合以 `SPEC.md` §8.1 为准
  → 行为语义以 `UI_PC.md` 为准 → 版式以 `docs/mobile-drafts/` 为准**

**下面五条本来是"要问人"的,现在每条都已经替你定好了默认。
照默认做 + 往 `MOBILE_BLOCKERS.md` 记一条,然后继续:**

| 撞到什么 | 预置默认(照做,别问) |
|---|---|
| **Android 的 libmpv 拿不到**(自己编不出、现成产物也拉不到) | 启用 `FakeCoreClient` 逃生舱,**先把阶段 ⑤⑥⑧⑨ 全部做完**。阶段 ⑦ 播放链路能写多少写多少(JNI/Surface 绑定/生命周期都不依赖 libmpv 能不能播),把"真机起播验证"记成 B 条目。**不要因为播不出画面就停下** |
| **既没真机,AVD 也造不出来** | 依次降级:① 下 `cmdline-tools` 造 AVD → ② 手写 `avd/*.ini` + `config.ini` → ③ 退到 **JVM 侧验证**(Compose UI Test / Robolectric / `gradlew` 截图测试)+ 逐页人工审读代码对账 `UI_MOBILE.md` §7。**照 ③ 继续把页面全部做完**,把"真机截图验证"整批记成一条 B 条目 |
| **需要改 `core/**` 的行为**(不是加命令,是改现有输出) | **不改。** 会打破 18 条差分对账。在 UI 侧用现有命令绕过去,把"核心层需要改什么、为什么"写成 B 条目。绕不过去的那一小块功能降级(空态 + 明确文案),继续做别的 |
| **需要往仓库塞大文件**(`.so` / 模型 / 字体) | **不塞。** 写 fetch 脚本 + gitignore,照 Windows 侧 `libmpv-2.dll` 的做法(`.github/workflows/build.yml`)。脚本拉不到就记 B 条目,继续 |
| **产品决策**(Tab 数量、要不要做某页、付费墙) | 用已有决定:**底栏就三个 Tab(首页/聚合视界/服务器)**;范围按 `TODO.md` 顶部裁剪;付费墙照 `UI_PC.md` 现有口径。文档里找不到答案的,**选最保守的那个**(做少不做多、不动钱相关流程),记 B 条目 |

**没有第六条。** 任何这张表没覆盖的情况,按同一个模式处理:选一个可辩护的默认 → 记 B 条目 → 继续。

**卡住时的顺序(走完之前不许说"我无法解决"):**
逐字读失败信号 → 搜索(报错原文/官方文档/多角度关键词)→ 读原始上下文(源码前后 50 行,不是摘要)
→ 用工具验证每个前置假设(版本/路径/权限/依赖,**未验证的归因就是甩锅**)
→ 反转假设(一直以为"问题在 A",现在假设"问题不在 A")→ 换**本质不同**的方案。

同一思路微调参数**不算换方案**。同一个错连续 3 次没进展 = 原地打转,立刻反转假设。

---

## 进度与提交纪律

- **进度的唯一真源是 `docs/go-migration/TODO.md` 的 `U1.x` 复选框。**
  做完一条打 `[x]`,判据的实测证据写在那条下面。**别另起一个进度文件**
- 每过一个阶段门禁提交一次:`git add` **逐个文件** → 中文 message,格式 `类型(范围): 说明`
  (照抄 `git log --oneline -20` 的既有风格)→ **直接推 `main`,不开分支不开 PR**
- Bash 工具里写 commit message **别用 PowerShell here-string**,用 `$'...'` 或 heredoc;
  **大文档不要塞 heredoc**,用文件写入工具(这条本身就是踩出来的)
- 每次提交前跑:`bash scripts/check-core.sh`、`bash scripts/check-bindings.sh`、`bash scripts/check-style.sh`
- 汇报结论**带证据**:命令输出、行号、实测数字、截图。"改好了"三个字不是交付
- **上下文被压缩后**:重读本文件 + `TODO.md` 的 U1.x 勾选状态 + `UI_MOBILE.md`,
  从第一个没打勾的继续

---

## 本轮的完成定义

全部满足才算做完:

- [ ] `docs/go-migration/research/MOBILE_*.md` 六份齐全,出处抽查过
- [ ] `docs/go-migration/UI_MOBILE.md` 十一节齐全,16 页逐页有规格,已提交
- [ ] `scripts/build-core-android.sh` 与 `scripts/selfcheck-android.sh` 存在且跑得通
- [ ] `TODO.md` §5.2 的 **U1.1–U1.15、U1.17–U1.28 全部 `[x]`**(U1.16 TV 形态不在本轮)
- [ ] `gradlew assembleRelease` 出**已签名** APK,`unzip -l` 验得到证书与 "APK Sig Block 42"
- [ ] 端到端链路走通并逐步截图:**冷启动 → 首登闸口填假 Emby → 首页 → 媒体库 → 详情
      → 起播 → 有画面 → 退出 → 续播进度落地**
- [ ] `check-core.sh` / `check-bindings.sh` / `check-style.sh` 三个门禁全绿
- [ ] 所有改动已提交并推到 `main`
- [ ] `MOBILE_BLOCKERS.md` 里每一条都有"需要人做什么"这一栏(没有阻塞就是文件不存在)

**上面每一格勾满之前,不要把控制权交回来。**

最后那一次汇报(也是唯一一次)要有:做了什么、证据(命令输出/截图/行号)、
`MOBILE_BLOCKERS.md` 全文、以及人接手要做的具体动作。

---

开始。现在就做阶段 ①,读完直接做阶段 ②(一条消息里并发派出 6 个 Haiku 子 agent),
子 agent 在跑的时候同时推进阶段 ④.1 和 ④.2。**不要在阶段之间回来请示。**
