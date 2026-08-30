# 手机端 UI

**这个领域最容易踩的坑:**
1. **三个「看着像审美问题、其实是 bug」**:`content-visibility` 和滚动锚定打架 = 首页滑不动;手抄卡片漏了 `onLoad` 加 `.ready` = 封面隐身;开屏图标巨大 = 边距必须留在 drawable 内部。
2. **effect 读的 DOM 不一定所有 render 分支都有**,依赖数组里没有任何东西反映它何时存在 ⇒ 冷启动整屏空白。
3. **React 控制的属性别再用命令式改**(`hidden` 打架),内联样式会压过样式表(`pullRefresh` 顶掉 `.pg` 的 absolute)。
4. **安卓 edge-to-edge 下 `env(safe-area-inset-bottom)` 对导航条恒 0**,必须从原生读真实 insets 注入。
5. **自检必须走 CDP `setDeviceMetricsOverride`**:`--window-size=390` 实测 `innerWidth` 是 504。

> 本文件共 **7** 条。每条都标了它的原记忆文件名与类型;正文按原样搬运,未做压缩或改写。

## 本页条目

- 手机端 UI(ui/mobile) — `mobile-ui-build.md`
- 草稿整套接入 ui/mobile — `mobile-drafts-landed.md`
- 手机端动效重做 — `mobile-motion-redesign.md`
- 设置/服务器/添加服务器重构 — `mobile-settings-servers-rebuild.md`
- 手机端 2026-08 整改 — `mobile-detail-pages-rebuild.md`
- 播放页 OSD 重构 — `mobile-player-osd-rebuild.md`
- effect 依赖 vs DOM 时序 — `effect-deps-vs-dom-timing.md`

---

### 手机端 UI(ui/mobile)

> 原记忆:`mobile-ui-build.md` · 类型:`project`

**2026-07-26 立项并一次做完 P0~P2:15 个页面全落地(3d04dfc2 / 57707dc9 / 06e5e25a)。**
规格全文在 `ui/mobile/README.md`,这条只记那些**读代码看不出来**的。

##### 单 APK,不出第二个

子 agent 说「包名冲突必须出两个 APK」—— **假的**。`AndroidManifest.xml:6,12` 早就把
`leanback` 和 `touchscreen` 都写成 `required="false"`,`build.gradle.kts:65` 的
`applicationId` 已是 `xyz.linplayer.app` 且被 `build.yml:785` 钉死(换包名 = 老用户
收不到覆盖升级)。manifest 里 `LAUNCHER` 和 `LEANBACK_LAUNCHER` 两个 category 都有。

分流:`MainActivity` 判 `UiModeManager.currentModeType`,在 **`onWebViewCreate` 里**给
WebView UA 尾巴加 ` LinPlayerTV`(放 `post{}` 里就晚了,那时 shim 已经跑完),
`index-android.html` 这个 shim 按标 `location.replace()`。
**判据只用 `currentModeType`**,别改成猜屏幕尺寸/触摸屏 —— 猜反的表现是用户拿到另一端的
整套界面。`namespace` 仍是 `xyz.linplayer.tv`,别顺手改整齐(`build.gradle.kts:55-64` 有说明)。

##### 底栏只有三个 Tab(用户 2026-07-26 定,推翻我提的 5 个)

`首页 / 搜索 / 设置`。其余入口:媒体库·收藏·下载·排行榜·追剧日历 → **首页顶部横滑 chip 行**;
服务器·插件·网盘·Ani-RSS → **设置页分组**。**横竖屏跟随系统**(每页都要两套版式,不是竖屏拉宽)。

##### 自检:CDP 设备指标,不是 --window-size

`--window-size=390` 时 headless 的 `innerWidth` **实测是 504** —— 按 390 截出来的图看着像
布局溢出,差点据此改错代码。量手机版式必须 `Emulation.setDeviceMetricsOverride`。
判"有没有横向溢出"看 `document.documentElement.scrollWidth` 是否等于 `innerWidth`,
别看截图边缘。脚本在 scratchpad 的 `shot.mjs` / `drive.mjs`(Node 22+ 有全局 `WebSocket`,
不用为探测装 `ws`)。

**功能自检只能在壳里做**:浏览器里 `window.__TAURI_INTERNALS__` 不存在,所有 invoke 都是
`TypeError: Cannot read properties of undefined (reading 'invoke')` —— 截图好看不代表接得通。
路径:`npm run dev` + `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--remote-debugging-port=9223"
./target/debug/app.exe`,再 CDP `Page.navigate` 到 `index-mobile.html`。

##### 两个只有真渲染才现形的 bug

1. **`scroll-snap-align: start` 会吃掉横滑容器的 `padding-left`** —— snap 对齐的是滚动端口
   边缘(不含 padding),浏览器一上来自动滚,`scrollLeft` 恰好等于 `padding-left`,
   第一张卡被屏幕左缘切掉。修法 `scroll-padding-left`,**不是删 snap**(那是把手感一起扔)。
2. 首页 15 个媒体库 = **284 个 `<img>` 在 DOM 里**(lazy 只挡住下载,同一时刻 102 张在下,
   布局绘制仍要为 284 个节点买单)。解:`.row` 上 `content-visibility:auto` +
   `contain-intrinsic-size`(零依赖)。**先量再优化**,不预防性装虚拟列表。

##### 别踩的

- **不装** Framer Motion / react-router / react-virtuoso(见 README 的依赖表)
- 登录闸口复用 `ui/desktop/pages/sources/sourceForms`,**不抄第二份**(抄了新增源类型
  就会改一处漏一处,而两边都不报错) —— 见 [首登闸口+源表单共用](sources.md)
- 会话闸口必须**同时**问 `currentSession` 和 `currentSource`,只判前者 = 网盘用户永远进不了门
- 底栏/toast/sheet 是 `position:fixed`,**不能被带 `transform`/`will-change` 的祖先包住** ——
  见 [transform 关键帧毁 fixed 定位](ui-desktop.md)
- `vite.config.ts` 现在是**四**入口。漏列的那个会静默产不出 html 而构建 exit 0,
  CI 的 Build frontend 已改成逐个断言

##### 自检的两次假绿(比 bug 本身更该记)

1. **测试写错了却怪代码**:查手势 HUD 必须在**抬手之前**(`onEnd` 会清掉它)。
   第一版在 touchEnd 之后查,得出"竖滑手势没生效"的结论,差点去改一段本来是对的代码。
   同理:音量本来就是 100,往上拖被钳住看不出变化 —— 要往下拖才测得到。
2. **注入脚本根本没改到文件**:python 转义 / sed 分隔符出错,于是"注入后测试仍通过"。
   那不是验证,那是什么都没做。**注入之后必须回读确认真改了。**
3. **测试输入不具区分度**:用「番名 - 12 [1080p]」测正则优先级 —— 那个输入下两条正则
   **都返回 12**,把正则挪到末尾照样绿。要钉顺序,输入必须让两条给出**不同**答案。

##### 出包时差点误判

APK 里按 zip 条目找 `index-mobile.html` **一个都找不到** —— 差点判成"前端没打进去"。
真相:Tauri 把 frontendDist **编进二进制**,要去 `lib/*/liblinplayer_android_lib.so` 里找。
同理 UA 标 `LinPlayerTV` 在 `classes.dex` 而不是 .so。验成品要分清东西在哪一层。

##### 安卓侧的真相(推翻两条旧记忆)

- **播放器不是桩**:`apps/android/Cargo.toml:31` 链的是 `crates/mpv`,真 libmpv + SurfaceView,
  与桌面同一份。`play_local`(本地下载文件播放)原本是桩,**已于 2026-07-26 接上**。
- **命令已补齐**:android 注册 82 → **233**,余下 20 条是真·桌面专属。
  当初缺 171 条时的判断:但 `set_speed` 那批只是对 `crates/mpv`
  的三行薄包装(`apps/desktop/src/lib.rs:2004`),**搬过去是复制不是重写**。
  加命令要同步三处:`generate_handler![]` / 新建的 `mobile-commands.txt` / `api.ts`,
  照 `every_tv_invoke_names_a_registered_command` 另起一个测试。两份清单不要合并。

**Why:** 手机端从零建,而这个仓库的高发病是「两处只改一处」和「编译绿但静默失效」——
上面每一条都是这两类。
**How to apply:** 15 个页面已全落地,继续改动前先读 `ui/mobile/README.md`
(硬约束 / 动效数字 / 手势冲突裁决 / 已知未做项都在那儿)。
仍未做且**明确不是忘了**的:亮度是 Web 层黑蒙版模拟(真调系统亮度要走宿主
`Window.attributes.screenBrightness`)、无后台播放/MediaSession、Ani-RSS 不做设置表单、
`env(safe-area-inset-*)` 在安卓 WebView 上还没真机验过。
仓库结构见 [仓库结构(2026-07重构后)](build-release.md);提交规矩见 [Git workflow](methodology.md)。

---

### 草稿整套接入 ui/mobile

> 原记忆:`mobile-drafts-landed.md` · 类型:`project`

2026-07-28 把 `docs/mobile-drafts`(87 格评审板的可运行原型)**整套接进 `ui/mobile`**。
用户原话:「完完全全的按照草稿接入吧 草稿的UI和动效已经足够好了」。

##### 差点做错的一件事:草稿的 CSS **不只在 app.css 里**
`app.css` 只有全站骨架 + 通用组件(433 条规则)。**每个 `p-*.js` 页面模块自己在文件顶部
还挂着一段 `const CSS = \`…\`` + `document.head.append(h("style"))`** —— 六个页面共 406 条规则。
只搬 app.css 的话 grep 会发现 **166 个类"没有样式"**,而草稿跑起来是好的。
**是靠读 `document.styleSheets` 发现有 7 张表才查出来的** —— 光看截图完全看不出缺了什么
(截图是对的)。落码时全部合进 `theme/mobile.css`。

##### 底栏三个 Tab 换过了
`首页 / 搜索 / 设置` → **`首页 / 聚合视界 / 服务器`**。
搜索并进聚合视界(同一件事的两面);设置挪到**首页右上角**(低频,不配占拇指最贵的位置)。
原首页 chip 行整条删掉(用户:"很难看没有用"),那五个入口搬到**聚合视界顶部的四个方块**。

##### 为这一版新加的核层能力(desktop + android 各注册一次)
- `aggregate_overview` —— 每个源的 counts + resume 一次拿齐(首页统计和聚合视界是同一批数据)
- `emby::counts` → `/Items/Counts?UserId=`。**必须带 UserId**,实测差 39 部电影 / 870 集
- `series_seasons` / `season_episodes` —— 季名用**服务器给的 Name**;分集**分页**
  (实测 2648 集全量拉 1.8MB/1841ms,分页 30 条 20KB/435ms)
- `item_detail(withChildren)` —— 手机端传 false,不拉那一坨分集。桌面不传,行为不变
- `screenshot`(安卓)—— 落数据根下的 `screenshots/`,**不是系统相册**(往相册写要过 MediaStore)
- `ItemDetail` 加 `official_rating / status / tagline / child_count`(真服务器实测都有值)
`mobile-commands.txt` 从 81 条扩到 121 条,守卫测试 `every_mobile_invoke_names_a_registered_command` 绿。

##### 真渲染抓到、编译和 CI 全绿的两个 bug(都是 React 独有的)
1. **React 控制的 `hidden` 和命令式 `el.hidden` 打架**。JSX 上写 `hidden={t.id !== tab}`,
   切 Tab 的 fade-through 又直接改 `el.hidden` —— React 下次 render 比对**自己上一次的虚拟值**
   发现没变,**不会把属性写回去**。表现:切过一次 Tab 之后三条栈全部可见叠在一起,
   在「首页」上量到的却是「服务器」那条栈的内容。
   **规律:任何要命令式操作的 DOM 属性,就别让 React 也控制它。**
2. **`.stack` 套了两层**(App 的 Tab 容器 + PageStack 自己),`querySelectorAll` 数出双倍,
   而 CSS 上两层都是 `absolute/inset:0` 又刚好看不出毛病。内层改名 `.pg-stack`。

##### 自检
`node ui/mobile/check-shell.mjs`(先 `npx vite build`)。**真渲染**,自带静态服务器
(不 spawn `vite preview` —— npx 隔着两层进程,kill 只杀最外层,下次跑报 "Port already in use",
而那句报错**看起来像"构建没做"**,绕了半天)。
测:挂载 / 三条栈 / 底栏 / 横向溢出 / 首启闸口 / SourceKind 正反断言 / 必填字段位置 /
逐个设置子页 / 「能就地调的没退回弹窗」。
★ 注入一个返回空数据的假 `__TAURI_INTERNALS__.invoke`,才测得到带 Tab 的外壳和各页空态 ——
没有它 App 会一直停在首启闸口。
★ 要加 `--disable-extensions`:用户 profile 里的下载器扩展会往页面注入脚本并抛
`siteHostMap` 错误,把"控制台干净"这条染红。

##### 还没做、明说的几处
- 摄像头扫码(加服务器 / 搬配置)要宿主接相机权限 —— 留了粘贴载荷这条路
- Trakt / Bangumi 的设备码授权交互没接 —— 设置里只显示状态,不摆按了没反应的按钮
- 从相册选服务器图标要走 SAF —— 只做了填图片地址
- 短信验证码下发核层没提到命令层 —— 天翼/移动云盘先走密码登录
- 浅色主题没做(强制深色,理由写在 theme/mobile.css 顶部)

见 [手机端 UI(ui/mobile)](ui-mobile.md) [手机端动效重做](ui-mobile.md) [播放页 OSD 重构](ui-mobile.md)
[设置/服务器/添加服务器重构](ui-mobile.md) [「待接」多半是谎](methodology.md) [测试必须先红](methodology.md)

---

### 手机端动效重做

> 原记忆:`mobile-motion-redesign.md` · 类型:`project`

用户 2026-07-27 痛批手机端动效「和好的 UI 动效八杆子打不着」。派 5 个 Haiku 调研 +
自己补两处缺口后,做了一份**能跑的原型**当草稿:`docs/mobile-drafts/`(评审台 `index.html`)。
覆盖 15 页 + 9 个播放器面板,零依赖,mock 数据 + 程序化 SVG 封面(离线可开)。

##### 体检结论(不是"某个动画调得不好")
`ui/mobile` 全站只有 **2 条曲线 / 5 个 keyframes**,而**页面转场和共享元素完全是空的**
(README 写着「用 View Transitions API」但没实现)。`README.md` 的动效规格表 **7 条里 4 条没落地**。

##### 两条推翻子 agent 的技术事实
1. **M3 的 `emphasized` 不是 cubic-bezier** —— 官方是两段贝塞尔路径
   `M 0,0 C .05,0 .133,.06 .167,.4 C .208,.82 .25,1 1,1`,CSS 只能写成 `linear()`。
   我们那条 `cubic-bezier(.2,0,0,1)` 其实是 M3 的 **standard**(最平淡那条)。
   弹簧同理:官方给 (ζ, k),要解阻尼振荡方程采样成 `linear()`,**时长 = 弹簧自己的收敛时长**
   (脚本 `gen-easing.mjs`,可复算)。
2. **Android WebView 自 Android 5 起是 Play 独立更新的组件**,和 OS 版本脱钩 ——
   子 agent 说的「Android 10~13 存量 Chrome 89/95/103 不支持 View Transitions」是错的
   (它自己表里 Android 14 = Chrome 119 还写"不支持",119>111 自相矛盾)。
   真风险是**国内无 Google Play 的 ROM**。所以:**FLIP 做地基(100% 支持且能被跟手打断),
   View Transitions 只做增强**。

##### ★ 自检环境和用户环境不一致 = 假绿(这一轮最贵的教训)
用户双击打开草稿:**48 个手机壳全黑**。我这边所有断言全绿。
根因:我启动无头 Edge 时带了 `--allow-file-access-from-files`,
而 **`file://` 下 ES module 的 `import` 会被 CORS 拦死**
(`Access to script at 'file:///…/motion.js' from origin 'null' has been blocked by CORS policy`),
那个标志正好把这条豁免掉了。解:写个 30 行的 mini 打包器(`build.mjs`)把 ES module
打成 classic script,`<script src="bundle.js">` 载入 —— classic script 不受这条限制。
**自检绝不能加这个标志。**
连带:`file://` 下每个文件是各自的 opaque origin,父页面**拿不到 iframe 的 contentDocument**,
所以"父页面伸手进 iframe 改 DOM"这条路要改成 URL 参数。

同一轮里还踩了两次"验证本身是假的":
- `sed 's/--allow-file-access-from-files//'` **没删掉**(grep -c 仍是 1),我却当成"已去掉标志重测"。
  → **注入/删除之后必须回读确认真改了**([测试必须先红](methodology.md) 早写过这条,又犯)。
- 提取器用大正则抓 `t:"..."`,我把字段改成反引号后只抓到 1 格,而它照样打印"验证通过"。
  → 提取器必须**先自证**:抓到的数量要和文件里的条目数对得上,对不上就退出。

##### 三个只有真渲染才现形的 bug(比动效本身更该记)
1. **hyperscript `h(tag, props, kids)` 不接受字符串子节点** → 字符串被当成 props,
   `for (const k in "继续观看")` 遍历字符串下标 → **全站标题/Tab 名/卡片标题静默消失**,
   不报错、不白屏、页面照常渲染。靠断言 `document.body.innerText.length`(59 → 1067)发现的。
2. **`.tabs{display:flex}` 优先级高于浏览器给 `[hidden]` 的 `display:none`** →
   `el.hidden = true` **完全无效**。JS 里查 `.hidden === true` 是对的,只有截图才看得见。
   要显式写 `.tabs[hidden]{display:none}`。
3. **Hero 拿 16:9 素材 `object-fit:cover` 成 3:4** → 构图(地平线/山脊)整个被裁掉,
   表现是"图很糊"。每种用途要按**目标宽高比**出图。

**Why:** 用户明确要「先探索→规划→草稿→商量→再落码」,草稿是他要逐条批的东西;
而这个仓库的高发病就是「编译绿 + 控制台干净 + 没人过眼 = 静默失效」。
**How to apply:** 改手机端动效前先开 `docs/mobile-drafts/index.html`;
自检必须走无头 Edge 渲染真 DOM(脚本形态见 [本周看板定案+PC视觉自检](methodology.md)),
断言 `innerText` 长度 + `scrollWidth===innerWidth` + console error,别只看编译绿。
相关:[手机端 UI(ui/mobile)](ui-mobile.md) [对着桌面草稿做](ui-desktop.md) [测试必须先红](methodology.md)
[transform 关键帧毁 fixed 定位](ui-desktop.md) [做完所有再交付](methodology.md)

---

### 设置/服务器/添加服务器重构

> 原记忆:`mobile-settings-servers-rebuild.md` · 类型:`project`

2026-07-28 重构手机端草稿(`docs/mobile-drafts`)的设置页 / 服务器页 / 添加服务器页 /
长按菜单四个弹窗(编辑信息·重新登录·线路管理·图标选择)。评审板 F 区从 11 格扩到 30 格,
全板 86 格。专项自检 `check-settings.mjs`。

##### PC 端的规模(A agent 实测)
`ui/desktop/pages/SettingsPage.tsx` **2878 行 / 12 面板 / 约 90 项**,
**全页零二次确认**——清缓存、删 1-3GB Whisper 模型、清空 mpv.conf、导入配置覆盖账号,
全是一步到位。手机端这几个已补确认(拇指误触率和鼠标不是一个量级)。

##### PC 代码里钉着的三条,照抄
1. **编辑弹窗里 `relogin` 必须排在 `updateAccount` 前**,反了 relogin 写的记录会被整个覆盖
2. **重新登录不能用 `login()`**——它按「登录时用的地址」upsert,会凭空多出一台服务器;
   `relogin()` 才是原地换 token,且自动用当前生效的线路
3. **线路排序后活跃线路跟 URL 走不跟数组下标走**

##### 我不照抄 PC 的三处
| | PC | 手机端 |
|---|---|---|
| 重新登录 | `ReloginDialog` 写死账密两字段,**扫码型源(阿里/夸克/百度)在服务器页根本没法重登**——这是 PC 的残缺 | 复用 `sourceForm(kind)`,扫码型给二维码 |
| 图标库 | ~1468 项铺 6 列硬滚 | 搜索框优先 + 5 列 + 分批 60 个 |
| 线路管理 | 弹窗内拖拽 | **独立页**:sheet 的关闭手势就是往下拖,和拖排序叠在同一区域必然误关 |

##### 草稿两处历史错误(已修)
- **`SOURCE_KINDS` 整套 id 是错的**:`aliyun`→`aliyundrive` / `p115`→`pan115` /
  `tianyi`→`pan189` / `mobile139`→`pan139`,且 **Jellyfin 不是独立 kind**(和 emby 共用)。
  同 [SourceKind 线上是小写](sources.md)。`check-settings.mjs` 钉了正反两条断言
- **曾有两套 `linesPage`**:`p-aggregate.js` 一套只读切换器(首页顶栏进) +
  我新写的管理页。已合并到 `p-settings.js`,旧的删掉,首页入口改成带当前服务器 id

##### 图标:三形态共用一个字符串字段
和 Rust `Account.icon_url` 一致。判据抄 PC:
`isGlyph(s) = s.length <= 2 && !/[\\/:.]/.test(s)` → 内置字形(20 个),否则当图片地址。
**别在手机端另发明 iconType 字段。**

##### 后端不是瓶颈
D agent 查实:**安卓侧已注册 233/249 条命令**,线路(`set_lines`/`set_active_line`/
`probe_lines`/`sync_lines`)、图标(`account_icon`/`set_account_icon_file`/
`clear_account_icon`/`icon_library`)、`relogin`、设置持久化全部可用。缺的 16 条是
桌面专属(文件对话框等)。参见 [「待接」多半是谎](methodology.md)。

##### 两个只有真渲染才现形的坑
- **同一块区域叠两个长按语义会打架**:行上挂 `longPress`,行内拖手柄不 `stopPropagation`
  的话,按住手柄 480ms 菜单就弹出来。`longPress` 只在「元素**自己**收到 `pointermove`
  且位移 >10px」时取消,而拖拽 move 挂在 `document` 上
- **写探针的两个坑**:①`document.querySelectorAll` 会抓到栈里压着的旧页(它们只是
  `hidden` 没出 DOM),量顶栏按钮必须写 `.stack:not([hidden]) .pg:last-child …`;
  ②`menu()` 的背板监听 **`pointerdown` 不是 `click`**,且 `close()` 只加 `.out`、
  节点等 `animationend` 才移除——判断菜单在不在要看 `.menu:not(.out)`

##### 用户 2026-07-28 的五条修正(已落)
1. **代理整组去掉**。手机上 Clash / VPN 类 App 是**系统级全局代理**,轮不到播放器自己做一套。
   PC 端保留是因为桌面没有这种统一入口。页面底部直接把这句写给用户,免得他以为功能缺失
2. **服务器名称必填**,添加页和编辑页都要,且排在**表单第一行** ——
   扫码型的用户扫完就跳走了,放后面等于没有。校验统一读 `[data-req]`,
   **在发请求之前拦**(等服务端回来再说"名字没填"是白等一趟网络)
3. **弹幕源必须是可增删的列表**,不是四选一的下拉。写死「第三方弹幕库」这么一个
   选项等于没给 —— 自建源地址各不相同,必须能自己填 API 地址。内置默认源只读
   (编译期注入凭据),顺序即优先级
4. **弹幕源里不该有「本地文件」**。那是播放页临时挂 xml/ass 的事,
   设置页里没法预先指定"以后每部片都用哪个本地文件"
5. **能就地调的绝不开二次弹窗**(最重要的一条)。我原来把所有可调项都做成 pickSheet,
   「点开→选→关掉」三步只为把「中」改成「大」。已加三个原语到 `ui.js`:
   `segRow`(2~4 个互斥选项)/ `stepRow`(有步长的数值,到头禁用按钮)/ `sliderRow`(连续值)。
   **弹窗只留给两种**:选项多且互斥(超分十几档、语言列表——语言还会长)、需要填表(正则)。
   PC 端本来用的就是 Seg + Stepper 就地生效,做成弹窗是退步

##### 自检脚本的一个坑(已修)
`must(cond, msg)` 直接传表达式的话,前一步探针返回空对象时 `r.on.length` 会当场抛
TypeError,**整个脚本从那里断掉,后面的断言一条都不跑**。注入验证时撞上过:
前 8 条红了,弹幕/网络两组根本没执行 —— **"看起来只错了 8 条"比全红更危险**。
改成 `must(() => expr, msg)` 惰性求值 + try/catch。

##### 设置页取舍(三档,不是没做完)
- **做**:片源 / 播放 / 弹幕 / 外观 + **新增网络(代理·多线程·CF优选)和同步(Trakt·Bangumi·跨服·回传)**
- **降级**:存储(PC 铺 11 条绝对路径还写死 420px 宽 → 只留缓存·下载·截图) / 关于
- **不做**:快捷键(没键盘) / mpv.conf(textarea 一弹键盘盖掉 1/3 屏) / 翻译引擎密钥(5 套 Key 共 20+ 项)
- 结构:片源和外观**就地展开**(片源最高频、外观只 3 项),其余进子页,主页副标题写当前值
- **PC 让用户手打 ISO 639-3 三字母码**(chi/jpn/eng)选音轨语言,手机改成挑列表

见 [手机端 UI(ui/mobile)](ui-mobile.md) [手机端动效重做](ui-mobile.md) [播放页 OSD 重构](ui-mobile.md) [测试必须先红](methodology.md)

---

### 手机端 2026-08 整改

> 原记忆:`mobile-detail-pages-rebuild.md` · 类型:`project`

2026-08-01 按用户 20 条意见整改 ui/mobile。**三个"看着像审美问题、其实是 bug"**:

- **首页滑到一半就再也滑不动、必须大退重开** = `.row` 的 `content-visibility:auto` +
  `contain-intrinsic-size:auto 216px`。216 是猜的(海报轨道真高 239 / 剧照轨道 166),
  轨道具现化 → 内容变高 → **滚动锚定**把 scrollTop 推回 → 轨道离开视口又缩回 →
  互相抵消,滚不动。骨架期等高不发作,**"内容全加载完"那一刻开始**。已删除该属性。
  同类风险还在 `.ep`/`.epc`(已随详情页重做一并去掉)。
- **单集页「本季其它集」封面一张都不显示** = `.card-a img` 初始 `opacity:0`,靠 onLoad 加
  `.ready`。那一栏手抄了卡片 DOM 却抄漏那句 → 图下完了就是永远透明。现复用 `EpCard`。
- **开屏图标巨大** = 2026-07-30 的 layer-list 钉 108dp **从来没生效过**(系统把整张
  drawable 缩放填满图标槽)。真解法是把边距留在 drawable **内部**:`<inset 22%>`。
  ★ 另:安卓 res/*.xml 的注释里出现 `--`(比如写 CSS 变量原名)会让
  `mergeResources` SAXParseException,**整个 APK 出不来**。

其余落点:
- **全站禁 bottom sheet** → 重写 `components/Sheet.tsx` 为居中弹窗,20+ 调用点零改动
  (类名 `.sheet/.sheet-title/.sheet-body/.sheet-acts` 全保留)。理由不是审美:
  悬浮底栏盖住 sheet 底部那排「取消/确定」,**画得出来点不到**。
- 剧/电影/单集/演职员**四张页面版式各不相同**;2:3 大海报 `object-fit:contain` 不裁剪;
  **真读像素**取主色做背景渐变(`ui/mobile/app/color.ts`,按色相分桶+饱和度加权投票,
  明度按主题重钉)。前提是 imgcache 回 `Access-Control-Allow-Origin` + `<img crossOrigin>`,
  少任何一半 `getImageData` 抛 SecurityError 而 catch 一吞**一点痕迹都没有**。
- 剧集列表默认横滑轨道 `.ep-box.as-rail`,可切 2 列矩形网格;媒体信息改平铺
  `components/MediaCard.tsx`(不再点击展开);动作区与顶栏重复的「更多」删掉。
- 线路页:长按 420ms 抬起 + 同一个 pointer 手势拖拽(旧注释说"拖拽和长按会打架"
  只在两套独立监听时成立);进页面用 `probe_line` **逐条**自动测速(整表 `probe_lines`
  要等最慢那条 6s);删掉底部说明。
- 核层新增 `person_detail` / `person_items`(桌面端一并注册)。
- 图片管线加**并发闸 6 + 20s 超时**:封面和 `item_detail` 走同一个 reqwest 连接池,
  一屏三十几张封面回源时 JSON 排在后头 —— 这是"简介也加载得很慢"的一条真因。

**自检台**(临时,不入库):无头 Edge + CDP `setDeviceMetricsOverride(390x844@3)` +
stub 掉 `window.__TAURI_INTERNALS__.invoke` 喂假数据,对真 DOM 跑 40 项断言。
两条只有真渲染才现形的自家 bug 是它抓的:`clearDragStyles` 从已置空的 ref 读状态
(拖完残留 transform,数据换序了屏幕上看不出来)、`setPointerCapture` 抛异常
连带吃掉后面两行(拖拽没有任何视觉反馈)。
★ 写这类台子的三个坑:①查询必须限定在**栈顶那一页**(整条栈的 DOM 全挂着,
裸 querySelector 会数出双倍);②三条 Tab 栈**一开始就全挂着**,崩在别的 Tab 上
当前页一点看不出来;③夹具图必须是**饱和**色,低饱和的随机 RGB 会让取主色
正确地返回 null,红的是夹具不是产品。
详见 [卡片看完打勾/悬停/角标](ui-desktop.md) [手机端 UI(ui/mobile)](ui-mobile.md) [挂真机 CDP 调试](methodology.md)

═══ 2026-08-02 第二轮(用户又逐条来了一遍)═══
- **播放页只有声音没画面** = `.pg` 自己的 `background: var(--bg)` 盖住 SurfaceView。
  `html.playing` 只清 html/body 不够;ui/tv 清的是 `.tv-app`,两端容器名不同**两边都得写**。
  钉这条链的 Rust 测试原来**只看 tv.css**,手机端整条链一个字没检 —— 已补。
- **换集跳回顶部** = `router.ts` 的 `replace` 每次发新 key → React 卸载重挂 → scrollTop 归零。
  改成"同种页面复用 key",并让单集页在新数据到之前继续显示旧的(页面一塌 scrollTop 会被截断)。
- **随机推荐滑不动** = `.hero` 缺 `touch-action: pan-y`。叠着 crossfade 的图没有可滚内容,
  换片只能靠 pointermove 自己算;而纵向滚动容器里 WebView 一旦认定手势归自己就
  **直接发 pointercancel 不再发 pointermove**,那段判定一次都跑不到。`.ln` 早有这条,hero 漏了。
- **「加载极慢」的一条真因是请求顺序**:首页一次性渲染 8 库 × 20 张卡,而 Rust 侧取图闸
  只有 6 个名额且 FIFO —— 首屏那几张排在第一百多位。改 IntersectionObserver 按轨道渐进挂载
  (**不能用 content-visibility**,见上一轮那条滚动锚定)。
- 顶栏"透明"唯一做得到的方式是 `position:absolute` 把它从 flex 流里摘出去(`.topbar.float`):
  常规顶栏是 `flex:none` 的一格,它自己透明也没用,背后露的是 `.pg` 的不透明底。
- 开屏那半秒见 [安卓资源限定符优先级](android.md)。
- 起播前选音轨/字幕:候选来自 Emby MediaStreams,**生效**要等 mpv demux 完 ——
  两个时刻,中间靠 `ui/mobile/app/prepick.ts` 交接,记的是"同类轨里的第几条"不是 mpv track id。
  `sub: -1`(明确关闭)和 `null`(没选过)必须分开,合成一个值就是"关了又被 apply_prefs 打开"。
- 屏幕方向走新的 `window.LPHost` JS 桥(`addJavascriptInterface`),**不是** `screen.orientation.lock()`
  —— 后者在 WebView 里要求 DOM 处于 Fullscreen,而我们的全屏是原生窗口层面的,直接 reject。

---

### 播放页 OSD 重构

> 原记忆:`mobile-player-osd-rebuild.md` · 类型:`project`

手机端播放页(草稿 `docs/mobile-drafts/p-player.js`)2026-07-28 重做。用户原话:
「按钮乱七八糟挤在一块 / 上下底栏也很丑 / 没有动效 / 挡住视频画面太多 / 弹窗列表好丑」。

**先把吐槽量成数**(CDP 实测 844×390 横屏,`check-player.mjs` 钉着):
遮挡 83.6%→**38.5%**;底栏可点 14→**7**;倍速面板 43% 屏宽→**18%**。
横屏总高只有 390px,**所有尺寸都是从"遮挡 ≤42%"这个预算倒推**的,不是照抄谁。
竞品的像素规格根本不公开(查证过,别再派 agent 去查),这是算术题不是抄袭题。

**四种收纳手法(功能比 B 站还多时的解法)**
1. 字幕+音轨合成「轨道」——开这两个的动机是同一句"这条不对,换一条"
2. 版本/线路/超分收进**顶栏副标题胶囊**——它显示什么点它就改什么,卡顿换线路一步够得到
3. 面板分两形态,判据只有"这一屏放得下吗":短单选→贴按钮小浮层,长内容→抽屉
4. 播放信息做**浮层不是面板**——排查卡顿要一边看画面一边看数字

**三个静默 bug(不报错、不错位,只是一直是错的)**
- `.sa-on` 全局钉死 `--sa-top:44px` **不分方向**;横屏刘海在侧边,每张横屏页白让 44px(=11% 屏高)。已加 `--sa-side` + landscape media query
- `.player.portrait` 这个类 **CSS 写了一整套规则但从来没有代码 toggle 过**,竖屏一直用右侧抽屉占 98% 屏高
- app.css 里留着上一版 `.pl-panel{right:0;bottom:0}`,把新小浮层拽到屏幕右下角——**同一个类两份定义**

**通用教训:量出来的值 ≠ 渲染出来的值。**
`getBoundingClientRect` 在入场态 `scale(.88)` 下小 12%;关掉 transform 后仍差 35px(内容没排完)。
解法不是继续追这个差,是**别量**——按下沿钉位(`bottom` 而不是算好的 `top`),多高都对齐。

另:数字只用有出处的——自动隐藏 5000ms = Media3 `DEFAULT_SHOW_TIMEOUT_MS`;
Video.js 的 入100/出1000 **没照抄**(那是鼠标播放器,慢淡出防指针抖动;触屏拆成 自动收 500 / 点掉 200)。

见 [手机端动效重做](ui-mobile.md) [手机端 UI(ui/mobile)](ui-mobile.md) [测试必须先红](methodology.md) [别过度解读需求](methodology.md)

---

### effect 依赖 vs DOM 时序

> 原记忆:`effect-deps-vs-dom-timing.md` · 类型:`project`

2026-07-30 修的一批 ui/mobile 问题,四条以后还会再踩的:

**1. effect 的前提是 DOM 存在,依赖数组里却没有任何东西反映它何时存在。**
App.tsx 摘三条栈 `hidden` 的 effect 依赖 `[tab]`;首帧 `session===undefined` 时组件早退成
`<div className="app"/>`,`.stacks` 不在 DOM 里,effect 空跑一次;会话回来第二次 render
挂上 `.stacks` 时 tab 没变,**effect 再也不跑** → `.stack[hidden]{display:none}` 把整个
应用画成空屏,只剩底栏。再点「首页」也没用(setTab 同值,React bail out)。
解法:容器用 **callback ref 存进 state** 并进依赖。同一页的 HomePage 那个装下拉刷新的
`[]` 依赖 effect 是同一类(早退分支下 bodyRef 为 null)。**写 effect 前先问:它读的那个
DOM 是不是所有 render 分支都有?**

**2. 内联样式压得过样式表 —— 工具函数别无脑写 `el.style.position`。**
`pullRefresh` 曾无脑 `host.style.position="relative"`,把 `.pg` 的 `absolute` 顶掉;
`.pg` 掉回文档流后高度塌成内容高度,`flex:1` 的 `.pg-body` 跟着塌,**整页滑不动**。
CSS 看不出问题,只有量运行时 computed position 才看得见。只在 computed 为 static 时才设。

**3. 安卓 edge-to-edge 下 WebView 的 `env(safe-area-inset-bottom)` 只反映刘海,导航条恒返回 0。**
后果:悬浮底栏有一大半画在系统导航条底下,内容给底栏让的高度也白让。
mobile.css 早就留好覆盖点(「全站只认 `--sa-*`,任何地方都不直接写 env()」),
MainActivity 里 `ViewCompat.setOnApplyWindowInsetsListener` 读真实 WindowInsets
(systemBars | displayCutout)**除以 density** 后 setProperty 注入。见 [手机端 UI(ui/mobile)](ui-mobile.md)。

**4. Android 12+ 的 SplashScreen 会把满幅传统图标放大。**
`@mipmap/ic_launcher` 没有自适应图标那 1/3 安全边距,被系统按自适应口径塞进 240dp 画布 →
开机瞬间一张巨大糊图。解法 `values-v31/themes.xml` + 一个把尺寸钉死 108dp 的 layer-list。
★ 同名 style 在 values-v31 里是**整条替换不是叠加** —— `windowBackground` 的透明必须
一起写上,漏了就是「安卓 12 以上有声音没画面」而 12 以下正常。

**另:手机端表单的「服务器名称」一直没落库。** 核层 login/source_login **都不收 name**,
PC 端(desktop/pages/sources/sourceForms.tsx)一直是加完补一刀 `update_account`,
手机端整条漏掉(连扫码型 QrPane 里那个 nameRef 都是存了没人用)。
`source_login` 返回 `()`,拿不到账号键 → 回读 `current_source`。
表现是名称填了、首页/聚合页显示的却是 host,用户会以为「显示的是线路名」。
移植 PC 功能到别端时,**补刀式的收尾调用最容易漏,而且两边都不报错**。见 [「待接」多半是谎](methodology.md)。

查法一律是真渲染:`ui/mobile/check-shell.mjs`(已补 6 条断言并逐条反向注入验红),
外加 CDP 录 `__TAURI_INTERNALS__.invoke` 流水验「有没有真发出去」。见 [测试必须先红](methodology.md)。

---

## 跨域交叉引用

这些条目和本领域强相关,但正文放在别的文件里(一条经验只存一份正文):

- [安卓资源限定符优先级](android.md) — 开屏/深色主题那半在安卓资源限定符上
- [起播不露视频窗](player-mpv.md) — 手机端起播后只 back() 不导航到播放页 = 只有声音
- [正则筛选前端接线](ui-desktop.md) — 手机端「高级筛选规则」保存从没落库
- [首登闸口+源表单共用](sources.md) — 登录闸口复用 PC 的 sourceForms,不抄第二份
- [VOD 资源站插件](plugins.md) — 手机端网盘/插件源用户进不去浏览页的宿主 bug
