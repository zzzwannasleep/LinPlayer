# ui/mobile —— Android 手机 UI

触摸版式 + 手势优先。宿主是 `apps/android`(与 TV 端**同一个 APK**),入口 `index-mobile.html`。

对标物是 **Emby 官方安卓客户端**,目标是超过它。它被用户反复吐槽的三件事就是我们要打的三个点:
**卡片单调 / 同一件事比竞品多点 2–3 次 / 播放器完全没有手势**。功能侧我们已经领先(核层 249 条命令),
这个目录里唯一要解决的问题是**手感**。

---

## 先读这个:后端不是瓶颈,别写「核层暂无」

`crates/core` + `crates/mpv` 已经把能力做完了。写任何「待接线 / 核层还没有」之前,
**先 grep `apps/desktop/src/lib.rs` 的 `generate_handler![]`**。这个仓库栽过:
30 个命令零调用,UI 里却写着「核层暂无」。

安卓壳当前的注册情况(2026-07-26 实测):

| | 数量 |
|---|---|
| `apps/desktop/src/lib.rs` 注册 | 249 |
| `apps/android/src/lib.rs` 注册 | 82 |
| 安卓缺 | **171** |

缺的那 171 条**绝大多数不是没实现**,是安卓壳没注册。`set_speed` 那一批在
`apps/desktop/src/lib.rs:2004` 只是对 `crates/mpv` 的三行薄包装,而 `apps/android/Cargo.toml:31`
已经链了 `crates/mpv` —— **搬过去就是复制薄包装,不是重写**。

### 分诊(按批次补,不要一次全搬)

| 批次 | 内容 | 条数 |
|---|---|---|
| **M0** | 播放器属性 `set_*`(16) + `mpv_get/set/command`(3) + `danmaku_*`(16) + 登录/媒体库/账号杂项 | ~55 |
| **M1** | `watch_history_*`(5) + `cf_proxy_*`(4) + `bangumi_*`/`trakt_*`(4) + `afdian_*`(2) + `plugin_*`(22) | ~45 |
| **M2** | `anirss_*` | 51 |
| **X 不做** | `pick_directory` `pick_file` `open_data_dir` `get/set_screenshot_dir`(安卓没有桌面文件对话框)、`download_and_apply_update`(安卓走下载 APK + 系统安装器)、`whisper_*`(5) + `translat*`(6)(要 ffmpeg 二进制 + 模型体积) | ~20 |

### ★ 加命令必须同步改三处

`apps/android/src/lib.rs` 里的测试 `every_tv_invoke_names_a_registered_command` 会拿
`apps/android/tv-commands.txt` 去比对**注册表**和 `ui/shared/api.ts`。手机端照这个形态**另起一份**:

1. `apps/android/src/lib.rs` 的 `generate_handler![]` —— 漏了**不编译报错**,只在用户走到那页时报 `command not found`
2. `apps/android/mobile-commands.txt` —— 新建,手机端要用的命令清单
3. 新测试 `every_mobile_invoke_names_a_registered_command` —— 照抄 TV 那个

**两份清单不要合并。** 合并了就分不清某条命令是谁要的,砍 TV 功能时会误伤手机端。

---

## 硬约束(违反了出的是掉帧和布局 bug,不是审美问题)

| 约束 | 为什么 |
|---|---|
| **只动 `transform` 和 `opacity`** | 其余属性一律触发重排/重绘。安卓 WebView 比桌面弱得多 |
| **禁 `backdrop-filter`** | 安卓 WebView 上有黑块 bug。TV 端和 PC 端各栽过一次 |
| **禁动画 `box-shadow` / `filter` / `width` / `height` / `top` / `left`** | 每帧重新光栅化 |
| **底栏 / toast / bottom sheet 不能放在带 `transform` 动画的祖先里** | `transform` 会给后代 `position:fixed` 建**包含块**,fixed 会以它为参照而不是视口。PC 端的右键菜单偏位、TV 端播放页底栏跑到屏幕上方 200px,都是栽在这。`will-change` 同样建包含块 |
| **强制深色,不 import `@shared/tokens.css`** | 那份 token 带侧栏宽 / 标题栏高 / 正文上限等 PC 专属量。与 TV 同模式,自建 `theme/mobile.css` |
| **触摸目标 ≥48dp** | Material Design 与 WCAG AA 的下限 |
| **主要操作排在屏幕下 1/3** | 单手拇指可达区。顶部只放不常点的(返回/标题/更多) |
| hover 样式必须包 `@media (hover:hover)` | 触摸设备上 hover 会粘住 |
| 页面不新写 CSS 文件,全站样式集中在 `theme/mobile.css` | 与 TV 同规矩。散着写必然出现两套间距 |

---

## 版式口径

### 底栏只有三个 Tab

```
首页 │ 搜索 │ 设置
```

PC 有 9 个入口,手机底栏**只留三个**。剩下的这样安置:

| PC 入口 | 手机端去处 |
|---|---|
| 媒体库 · 收藏 · 下载 · 排行榜 · 追剧日历 | **首页顶部的横滑 chip 行**,点进各自页面(进栈) |
| 服务器 · 插件 · 网盘 · Ani-RSS | **设置** 页的分组项 |
| 添加服务器 | 服务器页内,含**摄像头扫码**(手机独有) |

**理由**:底栏是拇指最贵的位置,只配给「随时想去」的三件事。
媒体库/收藏/排行榜/日历都是「进去逛一会儿」的目的地,做成首页 chip 反而比塞进底栏更快到达 ——
底栏 5 个图标的可点面积会被压到 48dp 以下,而 chip 行可以横滑放任意多个且带文字。

### 横竖屏跟随系统

**每个页面都要有横屏版式**,不是竖屏拉宽。基本规则:

| 页面 | 竖屏 | 横屏 |
|---|---|---|
| 首页 | 单列轨道 | 轨道卡片变多,Hero 变宽幅 |
| 媒体库 | 网格 3 列 | 网格 5–6 列 |
| 详情 | 上下:背景图 → 信息 → 剧集 | 左右:左封面+信息,右剧集列表 |
| 播放 | 视频居中 + 下方 OSD | 全屏视频 + 悬浮 OSD |
| 设置 | 单列列表 | 左分组 + 右详情(双栏) |

断点用 `orientation` 媒体查询,不用宽度断点 —— 折叠屏展开时宽度像平板但仍是竖屏。

### 卡片与信息密度

- **卡片不能单调**(这是 Emby 被喷得最多的一条)。海报要有:未看角标 / 看完打勾 / 进度条 / 长按菜单
- 长按 = PC 的右键。长按 500ms 触发,带触觉反馈
- 首页 Hero 用大图,**不裁封面**(PC 端栽过:`contain` 不裁,`cover` 会把人脸切没)

---

## 动效规格(逐条都是可验收的数字,不是「要流畅」)

| 场景 | 规格 |
|---|---|
| 页面 push/pop | View Transitions API(WebView 111+);不支持则退 `transform: translateX` 300ms `cubic-bezier(.2,0,0,1)` |
| 侧滑返回 | 左缘 20px 起手,跟手位移;松手阈值 = 屏宽 35% 或速度 >0.5px/ms |
| 卡片按压 | `scale(.96)` 120ms ease-out;松开 180ms 回弹 |
| 列表进场 | stagger 30ms/项,**仅首屏 12 项**;`opacity 0→1` + `translateY 8px→0` |
| Bottom sheet | 跟手拖拽;三档位 peek/half/full;松手速度 >0.8px/ms 直接跨档;回弹 `cubic-bezier(.32,.72,0,1)` 400ms |
| 下拉刷新 | 阈值 64px,阻尼 0.5,过阈触觉反馈 |
| 图片加载 | 骨架 → 渐显 160ms。**不许闪** |

### 播放器手势(Emby 官方一个都没有,这是最容易拉开差距的地方)

| 手势 | 行为 | 反馈 |
|---|---|---|
| 左半屏竖滑 | 亮度,全程 = 屏高 70% | 左侧竖条 |
| 右半屏竖滑 | 音量,同上 | 右侧竖条 |
| 横滑 | 进度,1px ≈ 屏宽/120 秒 | 中央 `目标时间 / ±差值` |
| 双击左/右半屏 | ±10s | 涟漪 + 秒数 |
| 长按 | 2× 倍速,松开还原 | 顶部提示条 |
| 单击 | OSD 显隐,3s 自动隐 | — |

### ★ 手势冲突裁决(不先定死,落码时必然打架)

| 冲突 | 裁决 |
|---|---|
| 播放页横滑进度 **vs** 侧滑返回 | 播放页**禁用侧滑返回**,返回只走物理键 / 顶栏箭头 |
| 首页轨道横滑 **vs** 侧滑返回 | 轨道横滑优先;侧滑返回**仅左缘 20px** 触发 |
| Sheet 拖拽 **vs** sheet 内滚动 | 内容滚到顶后再下拉,才开始拖 sheet |

---

## 依赖:一个都不加

仓库红线是「不必要的不进仓库」。落码起步阶段**不装**动画库、路由库、虚拟列表库:

| 想装的 | 先用什么替代 | 什么时候才装 |
|---|---|---|
| Framer Motion(~30KB) | View Transitions API + CSS transition | 实测某个转场用 CSS 做不出来 |
| react-router | 手工 page state(desktop/tv 两端都这么干,已验证够用) | 出现真实的深链/历史需求且手工栈扛不住 |
| react-virtuoso | CSS `content-visibility: auto` | **实机量到掉帧之后**,不是预防性安装 |

先量再优化。预防性依赖是这个仓库明确的反模式。

---

## 与 TV 端共用一个 APK

`AndroidManifest.xml:6,12` 已经把 `leanback` 和 `touchscreen` 都声明成 `required="false"`,
`build.gradle.kts:65` 的 `applicationId` 是 `xyz.linplayer.app`,`build.yml:785` 把这个包名钉死了
(换包名 = 老用户收不到覆盖升级)。**所以不出第二个 APK。**

分流方式:`MainActivity` 判 `uiMode == UI_MODE_TYPE_TELEVISION`,给 WebView UA 打标;
`index-android.html` 是个几行的 shim,按标 `location.replace()` 到 `index-tv.html` 或 `index-mobile.html`。

> ⚠️ `namespace` 是 `xyz.linplayer.tv`,**别顺手改整齐** —— `build.gradle.kts:55-64` 有一整段
> 说明为什么不能动它(改了要连 Kotlin 源码目录一起搬,收益为零)。

---

## 目录

| 路径 | 内容 | 状态 |
|---|---|---|
| `main.tsx` | 入口。返回键桥必须在任何组件挂载前装好 | ✅ |
| `App.tsx` | Tab 栈 + 页面栈 + 会话闸口 + 返回键编排 | ✅ |
| `app/router.ts` | 手工路由栈。**每个 Tab 一条独立的栈** | ✅ |
| `app/backkey.ts` | 安卓物理返回键桥 + 返回键消费栈 | ✅ |
| `app/nav.ts` | Tab / chip / 页面 id 定义 | ✅ |
| `app/Tabs.tsx` `app/TopBar.tsx` | 底栏 / 顶栏 | ✅ |
| `app/icons.tsx` | **只是从 `ui/desktop/app/icons` 再导出**,不重画一套(理由写在文件里) | ✅ |
| `app/PageBoundary.tsx` | 页面级错误边界 | ✅ |
| `components/Card.tsx` `components/Row.tsx` | 海报卡(长按 = PC 的右键)/ 横滑轨道 | ✅ |
| `theme/mobile.css` | 全站样式 + token。**页面不新写 CSS 文件** | ✅ |
| `components/Sheet.tsx` | bottom sheet(三档位跟手) | 待建 |
| `components/MiniPlayer.tsx` | 迷你播放器(手机独有,PC 没有) | 待建 |
| `components/Gestures.ts` | 播放器手势识别 | 待建 |
| `components/PullRefresh.tsx` | 下拉刷新 | 待建 |
| `theme/player.css` | 播放器 OSD | 待建 |

**安全区没有单独的 ts 文件** —— `theme/mobile.css` 里的 `--sa-top/-bottom/-left/-right`
就是那个接缝:现在它们的值来自 `env(safe-area-inset-*)`,全站只认这四个变量、不直接写 `env()`。
`env()` 在安卓 WebView 上的可靠性**还没在真机上验过**;万一不可靠,宿主侧读 `DisplayCutout`
往 `:root` 注入同名变量覆盖即可,前端一行不用改。
(前提:`index-mobile.html` 里必须有 `viewport-fit=cover`,没有的话 `env()` 全返回 0 且不报错。)

---

## 状态与数据

沿用仓库既有约定,**不引入 store**:各组件各持 `useState` 副本,改数据在
`ui/shared/api.ts` 的 invoke 层**广播**,别指望调用点自觉刷新。这条在 PC 端栽过。

`ui/shared` 是三端共用层 —— **往里塞手机专属的东西是污染**。
某个 `ui/desktop` 的组件如果值得三端共用,应该把它提到 `ui/shared`,而不是复制一份到这里。

---

## 分期

| 期 | 内容 | 验收(必须可运行) |
|---|---|---|
| **P0-a** | 入口 + Tab + 路由栈 + 主题 + 登录 + 首页 | `npm run dev` 开 `index-mobile.html`,Chrome 手机模拟能登录 → 首页出真实 Emby 数据 |
| **P0-b** | 搜索 + 媒体库 + 详情 + 播放页 + 手势 + MiniPlayer + M0 命令 + `play_local` | 桌面 Tauri 壳加载 `index-mobile.html`,从首页点进详情能播,六个手势全部生效 |
| **P0-c** | 单 APK 分流 + 守卫测试 + CI | `scripts/build-android-apk.sh` 出包;手机装上走完整链路;**TV 盒子装同一个包仍进 TV UI** |
| **P1** | 收藏 / 下载 / 排行榜 / 追剧日历 / 服务器 / 网盘 + M1 命令 | 每页真机走一遍 |
| **P2** | 插件 / Ani-RSS + M2 命令 | 同上 |

`play_local`(`apps/android/src/lib.rs:172` 目前直接返回错)在 **P0-b 一起修** ——
下载功能在手机上价值最高,下得了却播不了等于下载页是摆设。

---

## 现状(2026-07-26)

**P0-a 骨架已落地并在真壳里验过。** 已完成:

- 入口 `index-mobile.html` + 分流 shim `index-android.html`,`vite.config.ts` 四入口全出产物(CI 已加断言)
- `MainActivity` 判 `UiModeManager` 打 UA 标;顺带修掉「手机上无条件隐藏系统栏」(那是 TV 的做法)
- 底栏三 Tab + 每 Tab 独立栈 + 返回键四级优先级
- 首页(Hero / chip 行 / 继续观看 / 接下来看 / 每库一条轨道)、搜索(全服聚合)、设置、首启闸口

**验证方式**:跑桌面 Tauri 壳(`target/debug/app.exe`)+ `npm run dev`,
用 WebView2 的 `--remote-debugging-port` 把页面导到 `index-mobile.html`,
CDP `Emulation.setDeviceMetricsOverride` 设 390×844 手机指标,再截图。
真 invoke、真 Emby 数据、真图片协议 —— 浏览器里 `window.__TAURI_INTERNALS__` 不存在,
所有 invoke 都是 `TypeError`,**截图好看不代表接得通**。

> ⚠️ `--window-size` 给的是窗口不是布局视口:headless 下 `--window-size=390` 时
> `innerWidth` 实测是 504,按 390 截出来的图看着像"布局溢出",差点据此改错代码。
> 量手机版式必须走 `Emulation.setDeviceMetricsOverride`。

**这一轮真机自检抓到的两个 bug**(都是编译绿、肉眼不一定看得出的):

1. `scroll-snap-align: start` 把轨道的 `padding-left` **吃掉了** —— snap 对齐的是滚动端口
   边缘(不含 padding),浏览器一上来自动滚 16px,第一张卡被屏幕左缘切掉。
   实测 `scrollLeft` 恰好等于 `padding-left`。修法是 `scroll-padding-left`,不是删 snap。
2. 首页 15 个媒体库 = **284 个 `<img>` 在 DOM 里**(图片本身有 lazy 兜着,同一时刻只 102 张在下)。
   已给 `.row` 上 `content-visibility: auto` + `contain-intrinsic-size`,零依赖。

**下一步**:P0-b —— 媒体库 / 详情 / 播放页 + 六个手势 + MiniPlayer + M0 命令 + `play_local`。
底栏 chip 行点进去的五个页面目前是**显式的「还没落地」占位**(不做假 UI,假 UI 在评审时
会被当成已经做好了)。
