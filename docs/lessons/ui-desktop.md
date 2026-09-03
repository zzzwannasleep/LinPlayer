# PC 端 UI

**这个领域最容易踩的坑:**
1. **「点了没反应」的第一嫌疑是层叠上下文**:关下拉的背板盖住整条顶栏、祖先带 transform 关键帧永久成为 fixed 包含块。查法是 `elementFromPoint`,不是读 CSS。
2. **窗口透明 ⇒ React 一崩就是一片黑**,先怀疑 JS 渲染崩溃,别先查 mpv。
3. **Tauri v2 的窗口写操作要在 capabilities 里逐个放行**,漏了就被权限拦截并被 `catch{}` 吞成静默失效。
4. **前端零 store,各页各持 useState 副本** —— 改数据必须在 `api.ts` 的 invoke 层广播,别靠调用点自觉。
5. **「慢」先查加载编排**(Promise.all 屏障 + 串行 await),别拿动画当替罪羊。

> 本文件共 **13** 条(另有 2026-09-02 起追加的若干条)。每条都标了它的原记忆文件名与类型;正文按原样搬运,未做压缩或改写。

## 本页条目

- 对着桌面草稿做 — `follow-the-desktop-drafts.md`
- 卡片看完打勾/悬停/角标 — `card-watched-indicators-and-hover.md`
- 「不秒加载」是加载结构不是动画 — `perceived-slowness-is-animation.md`
- 前端副本要靠广播 — `frontend-state-copies-need-broadcast.md`
- 正则筛选前端接线 — `regex-filters-frontend-wiring.md`
- 界面在撒谎:当前版本 — `ui-lies-about-current-version.md`
- flex 挂错层 + auto-fill 陷阱 — `css-flex-child-autofill-trap.md`
- 顶栏下拉点不动 — `cbar-dropdown-scrim-stacking.md`
- transform 关键帧毁 fixed 定位 — `transform-keyframe-breaks-fixed.md`
- 「黑屏」多半是 JS 崩了 — `transparent-window-crash-looks-like-blackscreen.md`
- PC 窗口 chrome — `pc-tauri-window-chrome.md`
- Win最大化控制栏消失 — `windows-maximize-overhang.md`
- PC 快捷键 + mpv.conf — `pc-shortcuts-and-mpvconf.md`
- Avalonia 打磨主流程:五个只有真渲染才现形的坑 — 2026-09-02(Go + Avalonia 新栈)
- 「卡」不是掉帧,是根本没有中间帧 — 2026-09-02
- 「响应慢」指不到位置,先建仪表 — 2026-09-02
- 详情页重排:头图出血,正文封顶 — 2026-09-02
- 造卡时就建右键菜单 = 140 个用不上的弹出宿主 — 2026-09-02
- 自检脚本自己也会静默坏掉 — 2026-09-02
- 网格按行虚拟化 —— 而「加了虚拟化」这句话本身是验不了的 — 2026-09-02
- 渲染抛异常会打死进程:要横切兜住,而且必须看得见 — 2026-09-02
- 详情页只做「版本」,不照搬旧版四个下拉 — 2026-09-02
- 首页:一条全局「最新加入」把信息稀释掉了 — 2026-09-02
- Avalonia 的 Animation 动不了 RenderTransform — 2026-09-02
- 「轮播在不在动」截图判不出来:要把动效曲线采出来 — 2026-09-02
- 首页 Hero:全宽出血、交叉淡入、慢推 — 2026-09-02
- 改了假服务器的图,必须清核心层的图片缓存 — 2026-09-02
- 「整张剧照不裁」和「慢推」是互斥的 — 2026-09-02
- Border 挂了 OpacityMask,它的内容整个不画 — 2026-09-02
- 侧栏高亮「闪一下」:BrushTransition 到 Transparent 会中途过亮 — 2026-09-02
- 缺一个 MDL2 字形 = 一个空心方框,而且不报错 — 2026-09-02

---

### 对着桌面草稿做

> 原记忆:`follow-the-desktop-drafts.md` · 类型:`feedback`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

PC 端 React UI 有一份**用户精心评审过的 14 页草稿**,现已入库:`native-poc/docs/desktop-drafts.html`(每页含布局 + 橙色编号标注「移动端做法→桌面做法」)。我第一轮把草稿当"丢了"没打开,凭空造了一套完全不同的设计,被用户两次痛批「根本不是按草稿做」「草稿设计那么多东西就是要你全用上」。

**Why:** 用户花大量时间和我逐页讨论、定稿这份草稿,就是要照着实现;我不看草稿自己发挥 = 把他的设计投入全部作废,是最严重的失职。

**How to apply:** 做/改任何 PC 页面前,**先打开 `docs/desktop-drafts.html` 找到对应页**,照它的布局与交互实现。派 subagent 做页面时,把该页的草稿 HTML 片段 + 组件词汇一起给它。草稿的核心桌面交互语言(务必全用上):
- **cbar**:每页内容区自带顶栏——面包屑/页名在左,操作(搜索/刷新/排序/筛选/视图切换/主按钮)在右,**都在内容区内**,不是浮在角落的图标钮。
- 侧栏导航固定序:首页/媒体库/收藏/下载/排行榜,底部 服务器/设置;**没有「网盘」项**(网盘=点非Emby服务器卡进入的文件浏览)。服务器切换器常驻侧栏顶。
- 右键菜单(非底部弹窗)、悬停显现按钮、键盘快捷键、锚定下拉浮层、右侧滑出面板、主从两栏、居中模态弹窗——这套取代移动端做法。
- 配色 accent `#5B8DEF`,mono 字体用于 eyebrow/标签/数值/编号;深色沉浸 + 用户另要的米黄浅色双主题。
文件找不到时:草稿源在 scratchpad `linplayer-desktop-drafts.html`,已 cp 到 docs/。跟 [做完所有再交付](methodology.md)、[别过度解读需求](methodology.md) 一脉:用户定了的东西照做,别自作主张。

**每个橙色标注(编号 1-44)都是一条需求**,不是配图说明 —— 逐条核。**用户口头指令 > 草稿**:已知覆盖有「继续观看封面**横向**」(草稿画的竖版,但那是剧集,16:9 才对)、「媒体库封面**不裁剪**」。

##### 三类反复犯的错(2026-07-15 第三轮痛批后全项目审计实锤)

**① 摆了控件不接线 = 死按钮。** 播放器 24 条草稿要求只落 9 条,4 个 `onClick={() => {}}` 空函数(音量/亮度/上一集/下一集/选集),`.p-vbar` 竖条 CSS 写好了**全项目零引用**;收藏页排序 pill 和视图切换**根本没 onClick**,是装饰品。**「点了没反应」比「没做」更伤信任。** 要么真做、要么诚实 toast、要么按草稿删 —— **不许留空函数**。

**② 用注释把「有后端」说成「没后端」(最恶劣)。** 实锤:日历点卡写「聚合搜索待接」但 `aggregate_search` 早就存在且 SearchOverlay 在用;播放器版本面板写「暂未接入」但 `item_media` 存在且 DetailPage 在用;夸克扫码写「待接」但 `quark_scan_start/poll` 已注册。**写「待接」前必须先 grep `#[tauri::command]` 全表**(现 80+ 个)。

**③ 留白 = 用户最刺眼的投诉。** 根因常常**不是 CSS bug 而是整段没做**(详情页 7 段只做 3 段 → 集详情页 Hero 底下就剩一段 78ch 简介,右半当然空)。次因:全项目只有 Home/Detail 封了宽度。**已修**:`tokens.css` 加 `--content-max:1560px`,ui.css 给 `.cbar`/`.cbody`/`.dense-grid`/`.empty` 统一封顶居中 → 顶栏与正文左右边缘对齐(用户原话「不会做对称布局吗」)。⚠️ **Hero 类全宽出血元素必须留在封顶容器外**(详情页靠 `.detail .cbody{max-width:none}` 逃生),否则 2560px 下 Hero 缩到 1560 露黑边 = 更丑。

##### 技术坑
- 草稿的 `--line-2` 在本项目叫 **`--line-strong`** —— 照抄会静默失效(var 不存在 → 边框变 currentColor)。
- 草稿 `.mi` = 媒体信息卡,但 ui.css 的 `.mi` 已经是**右键菜单项** → 撞名必须改名(用了 `.dt-mi`)。
- **`tsc` 看不到 CSS**。CSS 注释里写个 `*/` 能静默吃掉半个文件,**只有 `npm run build` 会报** → 两个门禁都要跑。
- **subagent 的汇报不是证据**:自己复跑门禁 + grep 抽查关键声明(有 agent 自查用 `git diff` 查违规,而新文件全是 untracked,diff 根本看不见 → 自查恒过,假的)。

---

### 卡片看完打勾/悬停/角标

> 原记忆:`card-watched-indicators-and-hover.md` · 类型:`feedback`

2026-07-24 对标 Emby 官方客户端补卡片细节（Haiku 子 agent 调研后落码）：

- **看完打勾**：`item.played`（emby::Item 早就透传）→ 海报右上角**绿勾**；分集缩略图同款。电影/剧集「全看完」Emby 都把 Played=true 打在条目上。
- **未看集数角标**：`UserData.UnplayedItemCount` 过去**真缺**（Poster 注释「核层没这字段」半真半假）→ 已给 `emby::UserData`/`Item` + `api.ts` 补 `unplayed_item_count`（默认就在 UserData 里，不需任何 Fields）。剧集卡右上角**蓝数字**，`played` 时必为 0 → 勾优先。
- **配色**：用户定 **绿勾+蓝数字**（红绿灯语义），故意避开官方 Jellyfin「蓝勾配蓝数字」分不清（issue #706）。固定色不跟主题 accent。评分角标从右上挪到**左上**给状态让位。

**Why（重点）**：**用户 2026-07-24 主动推翻了 2026-07-15「卡片悬停只浮起、不出任何按钮」的旧决策**。现在悬停 = 中央 ▶（仅非文件夹可播条目）+ 右下 ✓ 标记已看/♥ 收藏；右键菜单（标记已/未看+收藏+管理员项）从「只有首页」**扩到库/收藏/搜索全部网格**。Poster.tsx 里那条「别照草稿改回来」的注释已删——别再拿旧决策或 desktop-drafts 把按钮改没。见 [别过度解读需求](methodology.md) [对着桌面草稿做](ui-desktop.md) [「待接」多半是谎](methodology.md)。

**How to apply**：卡片动作全走 `ui/desktop/lib/cardActions.tsx` 的 `useCardActions(session, {onPlay,onChanged,onFavChanged})`——收藏态/标记/右键菜单/toast 一处出，四页共用，别再各写一份（见 [前端副本要靠广播](ui-desktop.md)：标记后靠 onChanged 回调让持有页更新自己那份 items）。**搜索页只给本服结果右键**：聚合结果跨服，右键会写错服务器，故仍只「点=进详情」由 openFromSearch 先切服。Next Up（/Shows/NextUp，命令一直在）也顺手接进首页「接下来观看」栏。

---

### 「不秒加载」是加载结构不是动画

> 原记忆:`perceived-slowness-is-animation.md` · 类型:`feedback`

2026-07-15,用户三轮反馈,我错了两次,第三次他当面把我点醒。

##### 我的两次错判
1. 第一反应查**缓存** —— 缓存无辜,实测磁盘 124 张/35.9MB 好好的。
2. 第二次怪**动画**(`.enter` 380ms + 按 index 阶梯延迟最多 288ms = 668ms),把动画砍了。
   **这是拿掉表象。** 用户原话纠正:「其实不秒加载并不是你的动画问题
   你完全可以先出现骨架 然后再不断加载图片……这样有动画 加载看起来也会快」——
   即:动画根本不该背锅,砍它反而错了。

##### 真正的根因:加载结构(HomePage.tsx)
两个屏障叠起来是**秒级**的,668ms 动画只是零头:
```
1) 五个请求 await Promise.all(views/resume/random/favorites/collections)
   → 最慢的那个(收藏/合集)没回来,Hero 就跟着干等
2) for (const v of vs) { await listLatest(v) }
   → 八个媒体库 = 八次**串行**往返
```
E2E 实测(node 模拟 8 个库各自延迟):串行 1706ms(之和) vs 并发 310ms(最慢那个)= **5.5×**。

##### 正解(用户口径)
**骨架先出 → 每块数据各自 .then 里 set,谁先回谁先画 → 媒体库 Promise.all 并发。**
- Hero/媒体库行/最新轨道在 loading 时都垫 `.skeleton`(自带 shimmer 流光,`ui.css`)。
- 图片淡入用 `@keyframes img-fade`(只动 img 的 opacity),**卡片框和骨架第一帧就在,不藏内容**。
- **别再用 `.enter` + `fill-mode:both` + 按 index 阶梯延迟** —— 那会把整张卡藏在延迟里。

##### Why / How to apply
- 用户报「慢」→ 别停在第一个看到的原因。慢分层:字节到达 / **加载编排(串行 vs 并发/屏障)** /
  解码 / 动画 / 布局。**加载编排最常见也最贵**,先量它:`grep "await Promise.all"` 找屏障、
  `for...of` 里 `await` 找串行循环。
- 我上一轮验收只验「字节有没有落盘」全绿,但那不是用户的标准(「我眼睛看着快不快」)。
  **测试全绿 + 用户说慢 = 我的验收标准错了。** 定标准先问:这标准和用户体感是同一件事吗?
- 「有动画反而显得快」:动效要**衬托**内容出现(骨架→淡入),不能**挡着**内容出现。
- 见 [别过度解读需求](methodology.md)、[测试必须先红](methodology.md)。

---

### 前端副本要靠广播

> 原记忆:`frontend-state-copies-need-broadcast.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

`native-poc/src/` **没有任何 store / context / 事件总线**(zustand/redux/jotai/emit 全零命中)。
真源在 Rust,Sidebar 和 ServersPage 各持一份 `useState<AccountInfo[]>` 副本,互不知情。
Sidebar 还在 Shell 的 `key` 容器**之外** → 翻页不重挂载,陈旧 state 能活到关程序。

修法(2026-07-15,commit 396c4473):在 `api.ts` 的 `invoke` 包装层拦截 ——
`ACCOUNT_MUTATIONS` / `ITEM_MUTATIONS` 里的命令**成功后**自动广播
`lp:accounts-changed`(window CustomEvent)+ 清详情缓存;订阅用 `onAccountsChanged`。

**Why:** 原来的 bug 就是「靠调用点自觉」造成的 —— ServersPage 改名称/备注/图标/密码走
`onDone(false)`,压根不通知外层,侧栏永远显示旧名字。**让「改数据」这个动作本身成为信号,
谁都忘不掉。** api.ts 本来就是「前端调核层的唯一入口」,天然是收口点。

**How to apply:**
- 新增会改账号表的命令 → 名字加进 `ACCOUNT_MUTATIONS`。**漏加 = 侧栏不刷新且不报错。**
- 名字必须和 `generate_handler!` 里注册的一致。`src-tauri/src/lib.rs` 的
  `api_contract_tests` 会跨语言比对(我就写错过一次:`add_source_server` 不存在,真名 `source_login`)。
- 详情缓存**整体清**,别按 itemId 定点清:标记分集已看变的是**剧集**的 `children[].played`;
  `report_progress` 压根没有 itemId 参数。见 [「待接」多半是谎](methodology.md)。

---

### 正则筛选前端接线

> 原记忆:`regex-filters-frontend-wiring.md` · 类型:`project`

2026-07-30 修。用户报「按官网 /wiki/regex-filters 写好了却匹配不了」,PC + 手机都不行。
**核层 crates/core/src/media.rs 一直是对的**(431 条 Rust 测试全绿),断的是三根前端线:

1. **版本正则从上线起一次都没跑过**(PC/手机/TV)。三个详情页的版本选择器初值是
   `versions[0]`,起播时无脑把它的 id 传下去 → 核层 `resolve_stream` 见
   `media_source_id=Some(..)` 就走「手动指定」分支,正则整段跳过。
   前端从来没给过「用户没手动选」这个状态。**修法:没挑过传 null,显示仍回落第一条**
   (desktop `verIdx: number|null`;mobile 加 `verPicked`;TV 用 `picks.ver` 而非 `cur`)。
2. **字幕/音频正则匹配了个空表**。`apply_prefs` 拿的是**当时的** mpv track-list;
   桌面只在起播后 1.2s 打一枪(网络流那会儿内封轨还没 demux),手机/TV 一次都不调。
   修法放进 `ui/shared/track-poll.ts` —— 轨表每变一次就 applyPrefs,稳定即停,**一处修三端**。
3. **手机端「高级筛选规则」根本没落库**:保存只 `setPr` 改 React state,从没调
   `setTrackRegexes`,关掉面板就没了且不报错(同 [effect 依赖 vs DOM 时序](ui-mobile.md) 里
   「手机端表单的服务器名称从来没落库」一个模式)。

##### 教训
- 「核层有单测 + 文档写得对」≠ 功能能用。这类 bug 的落点是**发给核层的 invoke 参数**,
  只有真渲染 + 真点击 + 记录 invoke 才照得到。测试:`ui/shared/regex-filters.check.mjs`
  (CDP 驱动 dist,假后端记录 `window.__CALLS`),`ui/shared/track-poll.test.mjs`(npx tsx)。
- CDP 驱动两端时踩的两个**测试自身**的坑:桌面壳缺
  `__TAURI_INTERNALS__.metadata.currentWindow` 会整页白板(所有断言以「找不到元素」形式红,
  像是被测功能坏了);React 的 `onBlur` 挂的是 **focusout**,派 `blur` 不冒泡进不了 React。
  手机端是真页面栈不是 history,`history.back()` 退不回去 —— 每个场景重新 navigate 最省事。
- 见 [「待接」多半是谎](methodology.md) [测试必须先红](methodology.md) [挂真机 CDP 调试](methodology.md)

---

### 界面在撒谎:当前版本

> 原记忆:`ui-lies-about-current-version.md` · 类型:`project`

2026-07-30。修完 [正则筛选前端接线](ui-desktop.md) 后用户仍报「根本不行」。
挂 CDP 连他真服(105°)实测发现:**起播其实早就对了**(版本正则 `喵萌` → mpv 真的在放
mediasource_28909),但界面上**每一处**都在说在放第一条:

1. 详情页「版本 · xxx」= `versions[0]`
2. 播放器版本面板高亮 = `setCurMsId(id => id ?? vs[0]?.id)`,连「更多 · 播放信息」
   的分辨率/码率/大小也全是第一条的
3. 面板每行只画「1080p · MP4 · 3.6M」——那个库四条版本分辨率一模一样、差的是字幕组,
   **就算高亮对了也分辨不出来**

##### 解法
核层直接标结论,别让前端自己猜:`MediaVersion.preferred: bool`,由 `media_versions()`
用**和 `resolve_stream` 同一个 PlaybackInfo 响应 + 同一套 `source_match_text` + 同一个
`pick_index`** 算出来 → 「显示哪条」和「播哪条」结构上不可能分叉。
前端唯一算法 `defaultVersion(vs)`(ui/shared/api.ts),三端详情页/播放器面板共用。

##### 教训
- **「功能没生效」有两类根因:功能真没跑,和功能跑了但界面在撒谎。** 第二类先看不出来,
  因为所有单测和 e2e 断言的都是「发出去的命令对不对」,没人断言「界面显示的和实际在放的一致」。
- 用户的判据永远是屏幕,不是 invoke 参数。凡是「核层自动挑了什么」的功能,
  UI 必须显示核层挑的结果,**不能自己回落 `[0]`**。
- 查法:CDP 连真机 → `mpv_get('path')` 里的 `MediaSourceId` 是唯一真相,拿它和界面比。
  见 [挂真机 CDP 调试](methodology.md)。
- 同一次还揪出第四处版本旁路(TV 集详情页 `play(..., curVer?.id ?? null)`)——
  同类问题要 grep 干净,见 [正则筛选前端接线](ui-desktop.md)。

---

### flex 挂错层 + auto-fill 陷阱

> 原记忆:`css-flex-child-autofill-trap.md` · 类型:`feedback`

排行榜「每行只有一个图 而且图巨大」(用户 2026-07-16 骂「0 分」)的**真因不是审美,是布局 bug**:

```html
<div class="rkwrap">        <!-- display:flex -->
  <div class="rkrail">…</div>
  <div>                      <!-- 裸 div ← 真正的 flex 子元素 -->
    <div class="rankgrid">…  <!-- flex:1;min-width:0 写在这 → 无效 -->
```

两条规律,PC 端排版出怪状先查这两个:
1. **`flex:1`/`min-width:0` 只对 flex 容器的直接子元素生效**。中间夹一层没 class 的 wrapper,这两条就是死的 —— 且**不报错**,只是布局静默变形。
2. **`repeat(auto-fill, minmax(Npx,1fr))` 在不定宽(shrink-to-fit / max-content)下按规范只解析出 1 列**,`1fr` 再摊成 max-content = 原图尺寸。于是症状恰好是「一行一张 + 巨大」。看到这个症状 = 网格没拿到确定宽度。

**Why**:这类 bug 长得像「样式没调好」,会被误当审美问题去改 gap/尺寸,越改越歪。
**How to apply**:给 flex 子元素一个真 class(`.rk-main{flex:1;min-width:0}`),网格自己只管 `grid-template-columns`。另:给 `<img>` 加 `position:relative;z-index:1` 做淡入后,同卡片内的角标必须显式 `z-index:2`,否则被图盖住(`.cal-time` 早就踩过)。

同类:[别过度解读需求](methodology.md)(写死的 aspect-ratio + max-height 双向锁)、[「不秒加载」是加载结构不是动画](ui-desktop.md)(症状归因归错层)

---

### 顶栏下拉点不动

> 原记忆:`cbar-dropdown-scrim-stacking.md` · 类型:`project`

**PC 顶栏(.cbar)里的下拉菜单点不动 / 按钮要点两下** —— 不是事件没绑，是被透明背板盖了。

`.cbar { position: relative; z-index: 2 }` 开了个**层叠上下文**：里面的 `.dd { z-index: 30 }`
对外只等于 2。关下拉用的 `.lib-ddscrim` 原来是 `.cbar` 的**兄弟节点**、`z-index: 29`，
在根层叠上下文里 → 29 > 2，背板盖住整条顶栏，下拉项和右侧所有按钮点下去命中的全是背板。

**修法**（2026-07-19，LibraryPage.css + Library/FavoritesPage.tsx）：
背板**渲染进 `.cbar` 内部**，`z-index: 1`；`.cbar .push, .lib-ddwrap` 抬到 `z-index: 2`。
同一个上下文里比较才有意义：控件在上、背板在下、顶栏之外仍由背板接管关闭。

**查法（关键，别靠肉眼)**：无头 Edge 加载真实构建产物 CSS + 一段最小 DOM，用
`document.elementFromPoint(元素中心)` 报出「点下去命中的到底是谁」：
```
msedge --headless=new --disable-gpu --dump-dom --virtual-time-budget=3000 file:///.../probe.html
# 把结果写进 document.title 再 grep <title>
```
修之前全是 `"scrim"`，修之后全是 `"SELF"` —— 先红后绿，见 [测试必须先红](methodology.md)。
同类症状（右键菜单/toast 偏位）另有一因，见 [transform 关键帧毁 fixed 定位](ui-desktop.md)。

---

### transform 关键帧毁 fixed 定位

> 原记忆:`transform-keyframe-breaks-fixed.md` · 类型:`project`

2026-07-19:右键菜单飘到隔壁条目、`.toast` 的 `left:50%` 不在屏幕中间 —— 根因不是 `clientX/Y` 算错,
是 `.page` 上的 `animation: enter ... both`,而 `@keyframes enter` 里有 `transform: translateY(8px)`。

**带 transform 关键帧的动画会让元素成为 `position:fixed` 的包含块,Chromium 在动画播完后依然保持。**
实测(headless Edge,fixed 元素 `left:100px`,侧栏 200px):

| 祖先动画 | fixed 子元素实际 left |
|---|---|
| 无动画 | 100 ✓ |
| 只有 opacity 的关键帧 | 100 ✓ |
| 含 transform + `both` | 300 ✗ |
| 含 transform + `backwards` | 300 ✗ |

**`fill-mode` 换成 `backwards` 不管用**(我第一版就是这么改的,靠上表才发现是错的)。
唯一解:页面级容器的入场动画只用 `opacity`(现为 `@keyframes page-enter`),位移留给卡片
(`.enter`,卡片里不放 fixed 浮层所以不咬人)。守卫测试
`page_entrance_animation_must_not_use_transform`(src-tauri/src/lib.rs)钉住这条。

`.page` 自己肉眼毫无异常(transform 终值 `none`),只有 fixed 后代遭殃 —— 所以这类 bug
一定要用真浏览器量 `getBoundingClientRect`,别靠读 CSS 推理。见 [本周看板定案+PC视觉自检](methodology.md)。
DetailPage 早就 `createPortal` 到 body,所以它一直是对的 —— 同一份 `.ctxmenu` 有的准有的不准,
这个反差本身就是线索。

---

##### 变体:`will-change: transform` 同样建包含块,而且能把滚动层压成 0 高(TV 播放页,2026-07-22)

用户报「播放页上下底栏根本没出现,更不用说选项卡」。真凶是 `ui/tv/pages/PlayerPage.tsx` 的嵌套:

```
.osd (absolute, inset:0)
  └ FocusColumn → .vscroll → .inner   ← `.vscroll > .inner { will-change: transform }` + 内联 translateY
        └ .osd-bot (position:absolute; bottom:56px)   ← 唯一子元素,而且是 out-of-flow
```

两件事叠起来才炸:
1. **`will-change: transform` 让 `.inner` 成为绝对定位后代的包含块**(和上面那条动画的机制同源 ——
   不是只有真的 transform 值才建包含块,`will-change` 声明了就算)。
2. `.inner` 唯一的子元素是 out-of-flow 的 → **`.inner` 高度塌成 0**。

于是 `bottom:56px` 是对着一个 0 高、位于 y=32 的盒子解析的 → `top:-232px`。
实测(无头 Edge 量真 DOM):`.osd-bot` rect = `y −200, h 176`,**整条底栏在视口上方 200px 外**。
`.osd-top` 同页却完全正常 —— 因为它没被包进 FocusColumn。

**A/B 铁证是 `offsetParent`**:原样 = `inner`;把 `.inner` 的 `will-change/transform` 去掉后 = `osd`,
rect 立刻变成 `top 848 / bottom 1024`。**光看 rect 只知道位置不对,看 offsetParent 才知道错在谁身上。**

**修法不是加 `!important` 去压内联 transform**(那是和 `Focus.tsx` 写的内联样式打架),
而是**把嵌套摆正**:`.osd-bot` 提到 `FocusColumn` 外面当外层,焦点列放进它里面。
这样 `.osd-bot` 直接对着 `.osd` 定位,顺带也躲开 `.vscroll` 那对 `padding:0 32px / margin:0 -32px`
横向外扩。**全站只有这一处**是「绝对定位元素直接挂在 `.inner` 下」,不用泛化。

教训:滚动容器(`.vscroll > .inner` 这类带 will-change 的位移层)里**不要放绝对定位的元素** ——
它既改了参照系又可能塌成 0 高,两个错误互相掩护,读代码完全看不出来。
排查过程的教训见 [本周看板定案+PC视觉自检](methodology.md) 末段(我先往 Android 合成层猜了两轮)。

---

### 「黑屏」多半是 JS 崩了

> 原记忆:`transparent-window-crash-looks-like-blackscreen.md` · 类型:`project`

native-poc(PC)的 Tauri 窗口是**透明的**(为了露出垫在下面的独立 mpv 顶层窗口)。后果:

**React 任何一处渲染期抛错 → 整棵树卸载 → 屏幕上就是一片黑,零信息** —— 和「视频没出画」「合成出问题」长得一模一样。用户只会报「黑屏」。

→ **看到「某页黑屏/打不开」,先怀疑 JS 渲染崩溃,别先去查 mpv/合成。** F12 Console 有真堆栈。
→ 已加 `src/app/PageBoundary.tsx`(class 组件,React 至今无 hooks 版错误边界),包在 Shell 的 `.page` 里,`resetKey={pageKey}` 换页重置。现在一页崩只崩一页,侧栏还在,错误原文写在脸上。它只吃**渲染期**抛错;事件/异步里的错仍要各自 try/catch。

##### 实际案例(2026-07-16,追剧日历)
`groupByWeek(entries, week)` 的 weekday 分支是 `cols[e.weekday - 1].push(...)` —— 按**绝对星期几**索引,**写死 7 列**。我做「本日」视图时图省事传了 `[theDay]`(长度 1)→ weekday≥2 的条目全 `cols[undefined].push` → TypeError → 黑屏。
教训:**复用一个函数前要读它,别信自己「它是通用的」的直觉**。我当时还跟用户吹「归组规则一份,不写第二套」——那句话本身就是 bug。
现在:`week.length !== 7` 当场抛断言;日视图 = 跑 theDay 所在**整周**再取 `weekdayIndex(theDay)` 那一列。

##### 前端纯逻辑可以真测,别再抄副本
纯逻辑拆到 `src/pages/calendar-grouping.ts`,`scripts/check-calendar-grouping.mjs` 用 **Node 24 原生剥类型直接 import 真模块**(`node scripts/check-calendar-grouping.mjs`,零新依赖,前端没有 vitest)。
反向注入验证过会红(去掉断言→复现出真实的 `Cannot read properties of undefined (reading 'push')`)。
⚠️ 注入过一次**没生效**:源码是 `"￿"` 双引号,我 python 里写单引号,replace 静默没匹配 → 测试"通过"了。**注入后必须 assert 替换串真的匹配上**,见 [测试必须先红](methodology.md)。

相关:[测试必须先红](methodology.md)、[重构决策(已定+PoC已验)](decisions.md)(透明窗口垫 mpv 的合成方案)、[预取代理死锁(已修)](network.md)(另一类「黑屏」:真的是流的问题)

---

### PC 窗口 chrome

> 原记忆:`pc-tauri-window-chrome.md` · 类型:`project`

PC 端(native-poc,Tauri v2 + React)的窗口 chrome:

- **全屏按钮「点了没用」的真因**:`capabilities/default.json` 只有 `core:default`,其中 `core:window:default` **只含 getter**,不含 `allow-set-fullscreen`。JS 调 `getCurrentWindow().setFullscreen()` 被权限拦截抛错,又被 `withFsHidden` 的 `catch{}` 吞掉 = 静默失效。**任何 window 写操作都要在 capabilities 里逐个放行**。
- **自绘标题栏**:`tauri.conf.json` 设 `decorations:false`,组件 `src/app/Titlebar.tsx`(fixed 顶栏,`data-tauri-drag-region` 拖动,minimize/toggleMaximize/close 按钮)。需权限:`allow-minimize / allow-toggle-maximize / allow-is-maximized / allow-close / allow-start-dragging / allow-set-fullscreen`。内容整体下移 `var(--titlebar-h)`(在 `.app-surface`/`.login-wrap` 加 padding-top)。**播放时不渲染标题栏**(`{!playing && <Titlebar/>}`),让 mpv 全屏且不与播放器顶栏冲突。
- **内封音轨/字幕枚举**:mpv 的 `tracks()` 本身对,但网络流起播 1.2s 内还没 demux 完 track-list 为空 → 只拉一枪必然空。App.tsx 用 `[playing]` effect 每 700ms 轮询。**★ 2026-07-16 关键修:不能「拿到第一次非空就停」** —— 音轨常先于字幕 demux 出来,停在只有音轨那帧,内封**字幕永远进不了面板**(用户两轮都报字幕不显示,根因在此)。改成每轮都 `setTracks`,直到轨数**连续两次不变**(demux 稳定)或 ~14s 兜底才停。切轨后重拉刷新 selected 高亮(chooseTrack)。若改完仍无字幕 = Emby 直传流没内封字幕(它把字幕当独立 stream 发),要另做「拉 Emby 字幕 URL → sub-add」才行。
- **播放页面板浅/深色**:OSD 上下栏(`.p-top/.p-bot`)压在视频上,固定深底不随主题;但右侧滑出**面板**(`.p-slide` 及子元素)2026-07-16 改走主题 token(`--panel/--ink/--line`),跟随浅/深色。别把两者混为一谈。
- **视频未出画面**:mpv 独立窗口在网页层下,起播到第一帧之间盖 `.p-loading`(纯黑+spinner),`ready` 由「status.time>0」置真、4s 兜底,免得露上一段残帧。
- **全屏退出**:mpv 独立窗口靠 `sync_video`(WindowEvent::Resized/Moved/Focused)对齐;全屏进/出连发多个 Resized,**末帧几何要 settle 才准** → lib.rs 加了「代际防抖 + 220ms 延时补一发 run_on_main_thread 重同步」,否则退全屏后 mpv 窗口停在全屏尺寸压在上面像没退出。

见 [「待接」多半是谎](methodology.md)(后端领先前端)、[「不秒加载」是加载结构不是动画](ui-desktop.md)。

---

### Win最大化控制栏消失

> 原记忆:`windows-maximize-overhang.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

Windows 自绘标题栏(TitleBarStyle.hidden)窗口最大化时,系统默认把窗口四周各外扩约 8px
(缩放边溢出),自绘的最小化/还原/关闭按钮被顶出屏幕 → 用户「最大化后控制栏没了」。

原本只靠 window_manager 的 WM_NCCALCSIZE(adjustNCCALCSIZE 按 rcWork 内缩)补偿,跨机器不稳。

**根治:** `windows/runner/win32_window.cpp` 的 `WM_GETMINMAXINFO` 里把最大化尺寸钉到显示器
**工作区** rcWork(ptMaxSize/ptMaxPosition),从根上消掉溢出。只钉 ptMaxSize/ptMaxPosition,
`ptMaxTrackSize` 保持默认(虚拟屏),否则会卡住原生全屏那条 `SetWindowPos(rcMonitor)` 铺满整屏
(见 [Windows 无画无声"加载不出来"](player-mpv.md) 邻近的全屏 NCCALCSIZE 逻辑)。

排查踩坑:用 PowerShell 截图验证时,PS 进程默认 DPI-unaware,CopyFromScreen 坐标被虚拟化 →
截出来内容偏移/按钮"消失"是假象。必须先 SetProcessDpiAwarenessContext(-4) 再截图才准。

无关但同批:媒体库「更新时间」排序 key 从 DateCreated 改 DateLastContentAdded(剧集最新一集
入库时间,DateCreated 只是首次入库≈首播);三端 library_filter_bar / tv_library_screen。

---

### PC 快捷键 + mpv.conf

> 原记忆:`pc-shortcuts-and-mpvconf.md` · 类型:`project`

**2026-07-27 落地(commit eb5c4526)。** 都在 PC 端(`ui/desktop`)。

##### 自定义 mpv 配置

**libmpv 默认 `config=no` —— 一个配置文件都不读**,这是它和 mpv 命令行最大的行为差异。
所以不用自己写 ini 解析器:在 `mpv_initialize` **之前**设 `config=yes` + `config-dir=<目录>`,
mpv 会自己解析 `<目录>/mpv.conf`(连 `input.conf`、`scripts/` 一起)。

- 目录:`<数据根>/data/mpv/`,helper 在 `crates/mpv/src/lib.rs`(`user_config_dir` / `read_user_conf` / `write_user_conf`)
- 命令:`get_mpv_conf` / `set_mpv_conf`,UI 在 设置 › 播放器 底部
- **配置文件在 initialize 阶段解析,晚于我们那串 set_option → 用户写的同名项会覆盖默认值**。
  写坏了 `mpv_initialize` 直接失败,错误串里必须点名 mpv.conf(否则没人想得到是自己刚写的)
- 生效点是 `Player::new`,而播放器是**进程启动时建一次** → 改完必须重启应用
- 验证手法:conf 写 `volume=42`,重启后 `player_opts` 回读 42(别只看文件写没写进去)

##### 快捷键

`ui/desktop/lib/shortcuts.ts`:按键 → combo 字符串 → 命令 id → 谁注册谁执行,**全 app 只有一条 keydown**。
`useCommand(id, fn, enabled)` 注册(内部用 ref 包一层,否则播放页 250ms 轮询会把几十条命令反复卸载重装)。
`setScope("app"|"player")` 隔离作用域。改键存 localStorage `shortcuts:v1`,**只存改过的那几条**
(全存的话以后加命令,老存档会把新命令覆盖成「没有键」且不报错)。

**「所有能点的按钮都要能用快捷键」是靠两层满足的,别试图逐个起名**:
扫下来 160+ 个动作,而且每加一个按钮就得有人记得回来补表,漏了不报错。
第二层 = `components/HintOverlay.tsx`,按 `;` 现场扫当前屏幕的可点元素发字母标签(Vimium 式)。
两个坑,都只有挂真机才现形:

1. **可见性必须沿祖先链查**。海报卡上的播放/已看/收藏钮装在 `.overlay` 里(悬停才 opacity 0→1),
   按钮**自己**的 opacity 一直是 1 —— 只看自己的话,首页 35 个标签全是看不见的悬停钮,
   一个都打不开条目。
2. **不能「有子候选就丢父」**。卡片里塞着几个小动作钮,无条件留子会让整张卡点不开。
   规则改成:子候选面积 ≥ 父的 90% 才算「父只是个壳」。
3. **新起的全局 CSS 类名必须先 grep**。第一版把提示标签叫 `.hint` ——
   而这仓库里 `.hint` 早就是设置页/添加服务器页所有说明文字的类名(66 处),
   全 app 的描述当场变成 `position:absolute` 的黄底浮空块。
   **tsc / vite / cargo test 全绿**,CSS 类名撞车没有任何工具会报;
   我只截了提示层自己的图,没回头看设置页 —— 改了全局样式表就必须逐页过眼
   (见 [本周看板定案+PC视觉自检](methodology.md))。现叫 `.hintkey`。

##### 进度条在服务器上乱跳的根因(已修,有单测)

`apply_seek_latch` 原来吃的是 `sticky_f64("time-pos")`(读不到就沿用上次),
而**粘性值在 seek 期间恰好等于闩的目标位**(`latched_time` 每拍把目标写回 `last_pos`)——
一比就相等,闩在第一次 time-pos 读不到时当场自解除,下一拍 mpv 报的还是旧位置。

- 本地文件 seek 一拍就完事、time-pos 从不缺席 → **完全看不出问题**;网络流上 time-pos 频繁不可用 → 乱跳
- 修法:闩只吃**这一拍真读到的** `try_f64`;并引入 mpv 的 `seeking` 属性 ——
  见过 yes 再回到 no 才算落地,且 **seek 进行中不计超时**
  (慢服务器 seek 要 5 秒,2.5 秒超时一到就放行旧值 = 「画面回退、进度反而前进」的另一半)
- 前端配套:松手后 `await seekApi` 再放开 `seeking`,不留「已经不拖了但闩还没建」的空窗
- 真服实测:seek 2400s,服务端 **5.1 秒**才落地,期间读数稳在 2400.00 不抖

##### 弹幕:只剩网页 Canvas 一条路(mpv/ASS 已整条删除)

mpv 那条路占 `secondary-sid`,和双语字幕抢同一个位子 —— 一个设置项换来两个功能互斥。
当初换 mpv 是为了治「倍速下弹幕卡」,而真因是网页层插值漏了倍速因子(早已修好)。
**2026-07-27 用户拍板全删**:`danmaku/ass.rs`、mpv crate 的 `set_danmaku_sub` 一族、
两个壳的 `danmaku_attach/detach/visible`、api.ts 的三个导出,全部不在了。别再去找。

组件在 **`ui/shared/Danmaku.tsx`**(PC + 手机共用)。手机播放页原先只有一个调
`danmakuVisible` 的按钮而**从来没人加载过弹幕** —— 那开关切的是 mpv 次字幕可见性,
点了要么没反应要么关掉用户的双语字幕;现已真接 `danmaku_auto_load`。
接这一层必须补 `TimeSync` 且**带 speed**(轮询之间靠墙钟外推),
倍速面板 / 长按 2× 都要同步那个 ref,漏了就是「倍速下弹幕一直被拽回去」。

**脚本批量删代码的教训**:按注释锚点定位(往前找最近的 `/*`)跑飞了,一刀砍掉 android
978 行不相干命令(git checkout 回滚重做)。批量替换后必须回读校验 + 对删除区间下断言。

**Why:** 用户 2026-07-27 一次提的六件事;其中进度条那条是「本地跟手、服务器上必现」的典型
——「只在一种环境下现形」几乎总意味着有个判据在另一种环境下恒真。
**How to apply:** 见 [挂真机 CDP 调试](methodology.md)(本次全部结论都是挂真 exe 用 CDP 打出来的)、
[测试必须先红](methodology.md)(两条 seek 闩单测都做过反向注入验证)、[每次都要出可测 exe](methodology.md)。

---

### Avalonia 打磨主流程:五个只有真渲染才现形的坑

> 2026-09-02。把功能砍到只剩「添加服务器 → 登录 → 首页 → 媒体库 → 搜索 → 详情 → 播放」
> 之后逐页打磨时踩的。**五条全部编译通过、日志全绿**,只有截图看得出来。

**① 控件必须在 UI 线程创建 —— 否则整页停在骨架屏,而且不报错。**
`LibraryPage` 把数据拉取放进 `Task.Run`,顺手在同一个 lambda 里 `new Card(...)`。
表现不是异常弹窗,是**媒体库页永远呼吸着骨架屏**:异常在后台线程里被外层 catch 吞掉,
连「加载失败」那行字都没有。
判据:`Task.Run` 里只允许算数据;`new` 任何 `Control` 都要包进 `Dispatcher.UIThread.Post`。
**区分**:`async` 方法如果是从 UI 线程调起的(比如构造函数里 `_ = LoadAsync()`),
`await` 之后的续跑还在 UI 线程上 —— 所以 `HomePage` 同样的写法是对的。
两者差一个 `Task.Run`,而**看代码几乎看不出区别**。

**② `Opacity = 0` 起手做淡入,就必须有人把它拨回 1。**
给 `Image` 挂 `Opacity=0` + 样式过渡做淡入之后,`DetailPage.Fill()` 只写了 `target.Source = bmp`。
结果:图**拉回来了、解码了、也挂上去了**,请求日志里是 200,画面上是一块空底色。
海报、背景大图、演职员头像三处一起中招。

**③ `HorizontalAlignment=Stretch` + `MaxWidth` = 居中,不是左对齐。**
搜索框写成 `Stretch` 配 `MaxWidth=720`,以为是「最多 720、靠左」,实际是
「拉满 → 收窄到 720 → **居中**」—— 搜索框浮在内容区中间,左边空一大块。
要么真撑满(不给 MaxWidth),要么给死宽度。中间那档不存在。

**④ 骨架屏要和真卡**同尺寸**,否则它只解决了一半问题。**
「加载中…」三个字只有 20px 高,内容一回来这一行从 20px 撑到 280px,
底下几条轨道全被顶走 —— 用户正在看的东西会跳掉。
骨架的一半价值是「有反馈」,另一半是**不跳版**;尺寸不对就只剩前一半。
配套:`Skeleton.cs` 的尺寸常量是照着 `Card` 抄的,改卡片尺寸要一起改。

**⑤ 钉死标题行数是对的,但「几行」得跟着内容走。**
卡片标题区固定两行(不钉的话网格里下一行会整体上移,表现是「卡片参差不齐」,
而看着像间距没调好 —— 调间距永远调不好)。
但库卡和分集卡的标题**永远只有一行**,还留两行的话副标题会掉到空出来的那行下面,
和标题之间空出一整行,看着像两个不相干的东西。所以 `titleLines` 要能传。

#### 顺带定下来的三条口径

- **只有一个选项的选择器不画**。首登闸口砍到只剩 Emby 之后那个芯片还孤零零摆着;
  详情页只有一季时也不画季条。用户会盯着它想「还能选什么」,而答案是没有。
- **服务端回的英文枚举要翻译,认不出的整个不显示**。`Continuing` / `Ended` 原样摆在
  一整页中文里不是「没翻译」,是用户读不懂这一栏在说什么;
  而摆一个原文英文比不摆更像 bug。
- **空态分三种,不能合成一句**:还没搜(引导下一步)/ 搜不到(给替代做法)/
  出错(说原因)。合成「暂无数据」的代价是用户不知道该干什么。
  另:能表达「没找到」的 emoji 在 Windows 上一律渲染成一张古怪的脸,失败态就别放图标。

#### 动效:三档时长,不要每处各拍一个数

`120ms` 微反馈(底色 / 前景)· `170ms` 元素位移(卡片抬起)· `220ms` 页面转场,
缓动统一 `CubicEaseOut`。混着写的表现不是「不好看」,是**节奏乱** ——
同一次点击里按钮 90ms 变色、卡片 400ms 缩放,人眼会读成「卡了一下」。

- 卡片悬停缩放**必须给 `RenderTransformOrigin=50%,50%`**:默认是左上角,
  缩放时整张卡往右下漂,看着像在抖。
- 光靠放大 4% 在截图上几乎读不出来,要配一圈强调色描边才看得见「当前是哪张」。
- 换页转场用 `TransitioningContentControl`,**不要在 `Show()` 里自己写动画** ——
  写在代码里的话侧栏 / `Nav.Push` / `Nav.Back` / 自检跳转每个入口都得各记得动一次,
  漏掉的那个就是「只有这条路没有转场」。
- **只淡不滑**:滑动要选方向,而「返回」和「进入」的方向应当相反;
  这个页面栈没有方向信息,硬滑就会出现返回时也往左滑的错觉。
- 输入框的聚焦态必须自己写。Fluent 默认是**底色刷白 + 一圈亮白边**,
  在深色皮里是一块刺眼的白斑。模板里那层边框叫 `PART_BorderElement`,
  **名字写错不报错,只是静默不生效**。

#### 播放页 OSD:它是 OSD,不是压在画面上的设置面板

原来底栏是一条实心黑块,一行里塞着 `暂停 / 时间 / 音量 / 音轨 / 字幕 / 画质` 六组
标签加下拉框。问题不是丑,是**类型错了**:音轨、字幕、画质看片时基本不动,
不该长期占着画面;而暂停、快退快进、音量是随时要点的。两类东西不能排在同一行。

- 收进一个**贴右下角**的抽屉(不是居中弹窗 —— 那是一次决策的形态,
  而这是就地调整,居中会把整块画面遮掉)。OSD 收起时抽屉要跟着收,
  否则画面上孤零零飘着一块面板,而它下面那条控制条已经没了。
- 上下两条用**渐变蒙版**不是实心黑条:实心是一条硬边压在画面上,
  边缘那一行像素突兀地断掉;渐变从画面里长出来,字仍然压得住。
- 已播时间和总时长**分列进度条两侧**。挤成 `12:30 / 1:45:00` 时,
  眼睛得先找到那个斜杠才知道读到哪儿了。
- 进度条已播段必须是强调色。Fluent 默认全灰,两段几乎分不出来 = 等于没有进度条。
  改法是**覆盖 Fluent 自己的资源键**(`SliderTrackValueFill` / `SliderThumbBackground`),
  不要去改模板部件名 —— 部件名跨大版本会变,**写错不报错只是静默不生效**。
- 图标按钮要有 40×36 的方形热区:符号本身只有十来像素,靠字形当热区得瞄准才点得中,
  而 OSD 三秒就收,瞄不中就得再晃一次鼠标。每个都挂 `ToolTip` 并把快捷键写进去。
- **别用彩色 emoji 当图标**(🔊):Windows 拿 Segoe UI Emoji 渲染成一枚彩色图标,
  和旁边一排线条符号完全不是一套东西。而且静音图标**必须跟着状态变** ——
  不变的话按下去除了没声音之外没有任何反馈。
- 一条音轨都没有的片子真的存在。空下拉框看着像没加载出来,
  要 `IsEnabled=false` + `PlaceholderText="无音轨"` 才说得清是「没有」不是「没拉到」。
- 同一个抽屉里竖排的下拉框要**同宽**。三个宽度不一样,右边缘就是锯齿状 ——
  在一块半透明面板上特别扎眼,而它只是三个数没对齐。

⚠️ 自检钩子的坑:`LP_DRILL=2`(拉开抽屉)那次**整个 OSD 都没出现**,
因为启动判据写的是 `== "1"`。截出来是一张干净画面,而它看着**很像**「抽屉没画出来」。
自检钩子扩参数时,先看一眼门口那个判据是不是还认得新值。

#### 横向轨道:光有滚轮不算能滚

一条轨道放 20 张卡,屏幕上一次只看得到五六张 ——
**后面那十几张没有任何东西告诉用户它们存在**。而且鼠标滚轮在横向滚动区上的行为
依赖设备(有的鼠标只发纵向),触控板用户和滚轮用户看到的是两个不同的应用。

- 翻页按钮**按能不能滚来显隐**,不是常驻。到头了还亮着一个点不动的按钮,
  用户会以为卡住了。判据留 1px 容差 —— 浮点算出来的 `Extent - Viewport`
  常常差个零点几,严格比较会让按钮在到头时闪。
- 按钮对齐**图区中线**,不是整张卡的中线:卡下面还有两行标题,
  按整张卡居中会偏低,看着像没对准。
- 一次翻**视口的 80%**,不是一整屏。留一张卡在视野里,用户才知道自己是接着看
  而不是跳到了另一段。
- **滑过去,不是跳过去**。直接改 `Offset` 是一帧瞬移:一整排卡片突然换一批,
  人眼读不出「它往右移了」,只读到「内容变了」,位置感就丢了。
  12 帧 CubicEaseOut(≈190ms),和样式表里那三档一个手感。
- 首帧要等布局:构造时 `Viewport`/`Extent` 都是 0,当场判等于两个按钮都不出现。
  用 `LayoutUpdated` 补一次,**量到了就把处理器摘掉** ——
  它在这一页活着的时候会一直发,而之后的变化 `ScrollChanged` 已经盯着了。

⚠️ 顺手修掉的自检漏洞:`LP_SCROLL` 在**首页上从来没生效过**。
`SelfCheckJump` 在 `LP_SELFCHECK_PAGE` 为空时从早退那一行就返回了,
而滚动是排在方法末尾的 —— 首页恰恰是最长的一页,折线以下那两条轨道一次都没被看过。
**一个「设了没反应」的自检开关比没有更糟:它会让人以为已经验过了。**

#### 假服务器只能造出你想到的形状

「按季分组」这个功能在 `fakeemby` 只有一季的时候**永远验不出对错** ——
分组代码就算把季号写死成 1 也照样绿。同理背景大图:
`BackdropImageTags` 不造,详情页的大图就永远是「没有背景图」那一版。
这次一起补进 `core/cmd/fakeemby`:两季(12 + 8 集)、
`BackdropImageTags`、按 `SearchTerm` **真的过滤**(不过滤就验不到「搜不到」那一页)、
`Backdrop` 出 16:9 宽图(都出 2:3 的话看不出比例对不对)。

**Why:** 用户 2026-09-02:「把完整的流程打通了、做好了、UI 做好了、动效做流畅了,
才是真的做好一个基础的 Emby 播放器。」
**How to apply:** 每改一页就跑一次 `bash scripts/selfcheck-win.sh <名字> <页>` 看截图 ——
这五条**没有一条**能靠 `dotnet build` 发现。见 [每次都要出可测 exe](methodology.md)。

---

### 「卡」不是掉帧,是根本没有中间帧

用户 2026-09-02:「动效方面 卡顿 不流畅不跟手」「图片根本就不大 人家的图片一样大
人家也能做到流畅的浏览 **可以做成线性速度滑动浏览 这样就不会觉得卡**」。

最后这一句就是答案。Avalonia 的 `ScrollViewer` 收到滚轮**当场把 Offset 挪过去** ——
一格滚轮 = 内容瞬移几十像素。每一帧都按时画了,帧率是满的、也没掉帧,
但眼睛看到的是「跳、跳、跳」,大脑把它读成卡顿。
**别人的软件滑起来顺,不是因为渲染得快,是因为把这一跳摊成了十几帧。**

判据必须是可量的,「感觉顺多了」不算。自检里加了滚动扫描
(`LP_SCROLL=sweep`):每 140ms 发一格**真的滚轮事件**,同时**另起一路每帧采样
`Offset`**。同一台机器同一个页面跑两遍:

| | 出现的不同位置 | 移动帧 | 每帧位移(中位) |
|---|---|---|---|
| 关平滑 | **9** | 8 | 50.0px |
| 开平滑 | **82** | 81 | 9.2px |

8 格滚轮只产生 9 个位置 —— 中间什么都没有。这就是「卡」。

实现上四个坑:

- **驱动用 `TopLevel.RequestAnimationFrame`,不要 `DispatcherTimer`**。
  后者是自己定的 16ms 闹钟,和刷新率对不齐,会周期性地一帧画两次、一帧不画 ——
  那才是真的会看出抖。它是**一次性**的,每帧要重新挂;而且要重新取 TopLevel,
  页面换掉之后往一个卸载了的窗口上排帧是一条永远不会停的循环。
- **指数逼近,不是定长补间**。连续滚轮时目标一直在往前挪,定长补间每来一格
  就重启一次动画,速度一顿一顿;指数逼近对「移动中的目标」是连续的。
- **一格走视口的 20%,不写死像素**。写死 120px 的话,1080p 上一格走五分之一屏、
  4K 上只走十分之一 —— 同一个手势在两台机器上是两种速度。
- **竖滚轮只喂竖向**。首页那种横向轨道自己也是个 ScrollViewer(横能滚、竖不能),
  顺手把竖滚轮转成横滚看着很聪明,实际后果是鼠标停在轨道上时整页滚不动了,
  而用户只是想往下看下一条轨道。

#### 装在类级处理器上,不要逐个 Attach

第一版写的是 `PageBase.Scrolled()` 里 `Smooth.Attach(sv)`。当场就漏了 ——
全站有 **6 处页面自己 `new ScrollViewer`**(媒体库网格、日历、聚合、影视目录、
图标库、轨道),不走公共那条路。于是首页是顺的,而**媒体库网格**
(最需要顺滑的那一页)一格滚轮照样瞬移 50px。
**「有的页面顺有的页面卡」比整页都卡更像坏了**,而且没人会想到去查是漏装了。

改成 `InputElement.PointerWheelChangedEvent.AddClassHandler<ScrollViewer>(…, Tunnel)`,
对所有 ScrollViewer 生效,包括以后新写的页面。

配套两条:

- 用**隧道阶段**。ScrollViewer 的默认滚轮处理在 `ScrollContentPresenter`
  (它是子节点)的冒泡阶段,隧道先到,在那儿把事件吃掉它就不会再瞬移一次。
- 隧道是**从外往里**走的,而滚动的正确归属是**从里往外**。不判这一下的话,
  页面里但凡有一处内嵌滚动区,它就**永远滚不动**,外层页面会代它滚 ——
  看着像那块内容卡住了。判据:从事件源往上找,第一个在这个方向上滚得动的
  ScrollViewer 是不是我。

#### 自检发的必须是真事件

第一版的滚动扫描直接调 `Smooth` 里的方法,**绕过了事件路由** ——
于是「平滑滚动到底有没有挂上去」「隧道有没有把默认那套拦住」一次都没被验过,
A/B 里关掉开关的那一边照样是平滑的,对出来的两组数**没有任何意义**。

改成 `RaiseEvent(new PointerWheelEventArgs(...))`。还有一个坑:
**必须发给 `ScrollContentPresenter`,不是 ScrollViewer 自己** ——
路由事件从 Source 往上冒,把 Source 设成 ScrollViewer,presenter 在它下面,
**永远收不到**。表现是「发了 8 格滚轮,位置一动不动」,而且不报任何错。

### 「响应慢」指不到位置,先建仪表

用户 2026-09-02:「软件响应的很慢 和别人写的软件相比 我们响应的很慢 **不知道为什么**」。

慢在网络、慢在解码、还是慢在 UI 线程被占住,改法完全不同 —— 而这三种在用户
那边**看起来一模一样**。所以先加 `LP_PERF=1` 的仪表(`Core/Perf.cs`):
每条命令耗时、每张图的取/解码/**在哪个线程**、UI 线程被占住的时长与汇总。
三个真问题全是量出来的,没有一个能靠 `dotnet build` 发现。

#### ① 图片解码全在 UI 线程上

`Images.Fetch` 里**一个 `ConfigureAwait(false)` 都没有**,而它是被**卡片构造函数**
发起的 —— 卡片在 UI 线程上构造,于是每个 await 的续体都回到 UI 线程,
解码就在那儿做。一屏几十张 = UI 线程连续被占几百毫秒,动画在这期间不推进。

**连测出来的耗时都是假的**:localhost 上一张 0KB 的图报「取了 103ms」,
那 103ms 全是在排队等 UI 线程,不是网络。加上 `ConfigureAwait(false)` 后
同一批图 103ms → 20ms,日志里的 `线程=★UI★` 变成 `线程=后台`。

同批补的两条:按**显示高度**解码(`Bitmap.DecodeToHeight`,一张 1000×1500 的海报
画在 158×237 的槽里白解 40 倍像素);解好的位图留 400 张
—— 核心层那两层缓存存的是**压缩字节**,省的是回源,而每次翻回首页仍然要重走
一遍「本地 HTTP + 解码」,解码是 UI 侧的成本,核心层再快也省不掉。

#### ② 详情页在等它不需要等的东西

`emby.itemDetail` 的 `with_children=true` 让核心层**在同一条命令里**先拉条目、
再把全部分集拉完才返回(实测最长的剧 1.8MB / 1841ms)。
于是海报、标题、简介、播放按钮这些**早就到手的东西**,要陪着分集一起等两秒。

拆成两条命令:头部先画,分集自己在后面补(骨架同尺寸)。
主按钮**不等分集就能点** —— 用户点它的意图是「接着看」,哪一集是我们该算出来的,
不是他要读的;集号等分集到了再补上去。

这正是本文件上面那条〈「不秒加载」是加载结构不是动画〉。首页早就是各轨道各自
渲染了,**详情页这里漏了** —— 同一条教训在同一个应用里犯第二次。

#### ③ 起播路径上三次串行往返

`player.play` 里原本是:取流地址(PlaybackInfo)→ 取观看记录判据 → 查这部剧的
TMDB id → 这才轮到 `loadfile`。后两条和取流地址**互不依赖**
(代码注释本来就写着「本可以并发」,只是没做)。本机上看不出来,
150ms 延迟的服务器上就是黑屏多停将近半秒。

并发的前提是这两条路上**没有跨网络调用持有的锁**。通道要**带缓冲**:
取流地址失败时直接 return,无缓冲的话那个 goroutine 会永远卡在发送上。

`SeriesTmdbID` 顺手加缓存 —— 追剧就是同一部剧一集接一集地放,
不缓存每集都要重打一次而答案永远一样。三条容易错的地方各有一条断言:
**负结果也要缓存**(没刮削 TMDB 的库整个不命中,而那正是最需要缓存的场景)、
**键要带 server**(同一 seriesID 跨服串成同一部剧,且不报错)、
**网络错不进缓存**(那不是「这剧没有」,是这次没问到)。

#### ④ 启动:429 毫秒里没有我们的代码

把启动切成段之后一眼看得出:`核心层就绪 103ms` → `App.Initialize 532ms`,
中间那 429 毫秒是 Avalonia + Win32 + 图形初始化,**每次开机现 JIT 一遍**。
开 `PublishReadyToRun` 把这条路提前编好。发行包实测各跑三次:

| | 框架初始化完成 | 窗口出现 | UI 首次空闲 |
|---|---|---|---|
| 改前 | 659 / 712 / 665 | 806 / 868 / 816 | 1488 / 1483 / 1277 |
| 改后 | 533 / 447 / 442 | 604 / 522 / 521 | **989 / 907 / 901** |

包 95 → 100 MB。**必须用发行配置量**(自检加了 `LP_CONF=Release`):
Debug 不做优化、方法不内联,同一段代码能慢好几倍 ——
拿 Debug 的数去优化,优化的是一个用户根本跑不到的程序。

#### ⑤ 探针不能测自己

掉帧探针第一版阈值设 32ms,一次运行报出 **85 次**「UI 线程被占住 33ms」——
其中 80 次是噪音:Windows 默认定时器分辨率是 15.6ms,一个 16ms 的
`DispatcherTimer` 只能落在 15.6 的整数倍上,应用**完全空闲**时也会报。
噪音不是无害的,它把那几次真的 400ms **淹掉了**,还让人以为已经很糟。
阈值抬到 50ms(≈3 帧)之后,一次运行只剩 1 次 —— 那一次是真的。

### 详情页重排:头图出血,正文封顶

原来整页被封在 1560 的水槽里,头部信息列**又自己封了 900** ——
1920 的窗口上右边有将近一半是死白,而背景大图本该铺在那儿。
旧 React 版的分法是对的:`dt-hero` 在 `dt-body` **外面**,头图全宽出血、
正文另外封顶。C# 这边照搬了这个结构。

同批四条:

- **背景图用 `ImageBrush` 当底纹,不要塞一个 `Image` 进去**。
  Image 会把自己的**自然尺寸算进布局**:一张 16:9 的图铺到 1600 宽就要 900 的高,
  头图被撑到海报底下空一大片。用 `Height = 420` 钉死能挡住这件事,
  但那样图的下沿又会卡在海报中间。画刷不参与测量,这一层多高由内容决定。
- **元信息做成一排小片,不是一串用「·」连起来的长句**。连成一句的问题不是不好看:
  它**不换行**,类型一多就被挤出可视区;而且年份、评分、分级、类型是四种不同的
  东西,拿同一个分隔符串起来等于告诉眼睛「它们是一类」。
- **简介放头图右列**。那一大片空白唯一该放的就是它 —— 它也是全页唯一一段
  「宽度越大越好读」的内容。收到 3 行 + 展开:不收的话一段十几行的简介会把分集
  整个推到折线以下,而进详情页最常见的动作是**找集**,不是读简介。
- **分集卡 256 → 214**。分集列表是用来找集的,一屏看得到的集越多越好;
  单张再大也提供不了更多信息(剧照都长一样)。

⚠️ 换父之前必须**先从原来的容器里摘掉**。Avalonia 里一个控件同时挂两处不是
「后者生效」,是当场抛 `InvalidOperationException` —— 而它抛在渲染里,
**整个进程当场就没了**。已给详情页的渲染补上边界(Rust 版为此有 PageBoundary,
C# 这边一直没有对应的东西);但别的页面还没有,这是个待补的横切。

### 造卡时就建右键菜单 = 140 个用不上的弹出宿主

`CardActions.Attach` 原来每张卡当场 `new ContextMenu()` 加两三个 `MenuItem`。
ContextMenu 是个**弹出宿主**,不是一个轻量对象。一屏 140 张卡就是 140 个弹出宿主
加 200 多个菜单项,而其中**被打开过的是 0 个** —— 用户右键一张卡之前,
这些东西一件都不需要存在。改成 `ContextRequested` 那一下才建。
(造 140 张卡 84ms → 59ms;同批把手型光标和 6 支画刷改成全站共用一份 ——
`Cursor` 是平台资源,每次 new 都去问一次系统。)

两个必须注意的:

- 这一次的右键要**自己补开一次**。菜单是在事件处理当中才挂上去的,
  挂之前那一下已经走过「有没有菜单」的判断了 —— 不补的话第一次右键没反应、
  第二次才出来,而用户只会认为右键坏了。
- 建好之后**留住**,第二次右键不重建:菜单项里的「标记为已看 / 未看」是有状态的。

⚠️ **这类改动截图验不到** —— 截图点不了右键,而它坏掉的样子恰恰是「点了没反应」,
不报错、不崩、编译全绿。已加 `LP_MENU=1`:在第一张卡上真的发一次
`ContextRequested`,打印「菜单建出来了,N 项,打开=?」。
注入「忘了建」和「忘了 Open」两个真 bug 都验过会红。

### 自检脚本自己也会静默坏掉

这一轮撞上两个,都属于「设了没反应比没有更糟」:

1. **就绪探测从来没成功过**。`curl -s URL >/dev/null && break` ——
   假服务器开着 `-gzip` 时 curl 不发 `Accept-Encoding`、拿到一坨 gzip 字节,
   **退出码 23**(写出错),于是 `break` 从来没触发过:每一次自检都白等满 30 轮
   ≈ 8 秒。日志里只是多了 30 行 `/System/Info/Public`,谁也不会多看一眼 ——
   我为此把这 30 行当成「应用在疯狂探活」查了半天。
   改成 `curl -s --compressed -o /dev/null`。
2. **控制台中文全是问号**。Windows 默认代码页是 GBK,而自检脚本正是靠
   `grep` 中文关键字读这些日志的 —— 乱码 = 整套日志形同不存在。
   `Console.OutputEncoding = UTF8`。

同批给假服务器补了两样,都属于「假服务器只能造出你想到的形状」:
**图片改斜向渐变**(纯色图判不出铺满没有、拉伸对不对、遮罩从哪开始 ——
「背景大图」这一项一直等于没验过)、**请求日志加毫秒时间戳和 UA**
(只打路径的话,「同一条路径出现 30 次」看不出是启动时一次性打的还是每秒都在打,
也分不清是哪一路发的 —— 而这两件事恰恰是排查「响应慢」时唯一要问的问题)。

### 网格按行虚拟化 —— 而「加了虚拟化」这句话本身是验不了的

一个 `WrapPanel` 把所有条目一次性 new 成卡片:140 条 = 140 张卡 × 约 10 个可视元素
= 一千四百个控件要测量、排布、命中测试;真实媒体库上千条,滚到底就是上万个。
**这不是「慢一点」,是量级问题。**

Avalonia 11 的基础包里**没有** ItemsRepeater / UniformGridLayout(那是另一个 NuGet 包),
但有 `VirtualizingStackPanel` —— 它只虚拟化**一维列表**。所以把网格**按行折**:
数据是「一行若干张卡」,竖直方向交给它。卡片宽高固定 = 行高一致,
正是它工作得最好的形状。

- 列数**按实际宽度算**,窗口变了要重算。写死列数的话,侧栏收起、最大化、4K 屏 ——
  每一种都会留下一条空白或者切掉半张卡。
- 但**只在列数真的变了时才重建**:拖窗口时 `SizeChanged` 每帧都发,
  每次都重建 ItemsSource 的话,拖动过程中会一直在丢弃/重建容器,**比不虚拟化还卡**。
- 改在 `LibraryPage.Grid` 这**一处**,四个入口一起受益(媒体库网格 / 搜索 / 收藏 /
  详情页分集)。各处各写一份的话,虚拟化只会做在想起来的那一处。

⚠️ **判据**:代码写上了、编译过了、页面看着也对,但只要 `ItemsPanel` 那一行没生效,
它就退化成全量实例化,**而且外观一模一样**。唯一的判据是**数视觉树里的 Card**
(`LP_COUNT=1`)。同一页 140 条:

| | 实例化的卡片 | UI 线程被占住 |
|---|---|---|
| 不虚拟化 | 140 张 | 932 ms |
| 虚拟化 | **18 张** | 608 ms |

回归要专门验**滚到底翻页** —— 虚拟化改变 `Extent` 估算,而分页触发靠的正是它。

### 渲染抛异常会打死进程:要横切兜住,而且必须看得见

渲染里抛出的异常**会把整个进程打死** —— 没有对话框、没有日志窗口,
用户看到的是「点了一下,软件没了」。(这一轮真撞上一次:一个控件同时挂两处,
Avalonia 里不是「后者生效」而是当场抛。)

一处接住:`Dispatcher.UIThread.UnhandledException` + `e.Handled = true`。

★★ 接住之后**必须让它看得见**。默默吞掉就成了本仓最讨厌的失败形态:
不报错、不崩、只是这一块没画出来,而谁也不知道发生过什么。所以配一条出错横幅
+ 完整堆栈进日志。

★★ 兜网本身**没有任何外在表现** —— 它没生效的唯一症状是「某天某个页面把进程打死了」,
而那一天不会有人想起来是这里坏的。所以留了 `LP_BOOM=1`:往 UI 线程上扔一个异常,
验进程活不活得下来。

⚠️ **有了兜网之后,自检的判据要跟着改**:页面出错不再崩了,截图会看着一切正常,
只是角落多一条横幅。所以全流程扫一遍时必须**主动 grep 日志里的「未捕获异常」**,
不能再拿「进程还活着 + 截图出来了」当通过。

### 详情页只做「版本」,不照搬旧版四个下拉

旧 React 版详情页有**四个**选择器:线路 / 版本 / 音轨 / 字幕。这一版只做版本 ——
是想清楚的取舍,不是没做完:

- **线路**是服务器级设置,不该在每个条目页各摆一份;
- **音轨 / 字幕**播放页的抽屉里已经有了,而且那里才是真正会改它的时刻。
  「放之前先在详情页选好字幕」不是一个真实的使用姿势。

**重复的入口不是多一个选择,是多一处会不一致的状态。**

版本条**只在多于一个版本时才画**(一个选项的选择器是纯噪音,和源类型条、季条一个口径);
默认落在核心层挑中的那一条(`preferred`)而不是第一条 —— 落第一条的话正则明明选对了版本、
详情页却在说另一条,〈界面在撒谎:当前版本〉那个老坑就是这么来的。

⚠️ **「选了版本有没有真的播那一条」看界面看不出来**:版本条高亮了、按钮也点得动,
而送下去的 `media_source_id` 可能根本没变。判据只有一个 ——
**服务器实际被请求的是哪一条流**。`LP_VER=N` 自检钩子选第 N 个版本再按播放,
去假服务器日志里看 `mediaSourceId`。注入「忘了送版本」验过:

  注入后:界面高亮 2160p HDR,服务器拿到 `mediaSourceId=ms-1`   ← 就是「界面在撒谎」
  恢复后:                              `mediaSourceId=ms-2`

同批给假服务器补形状:PlaybackInfo 原来只回**一个**版本 ——
多版本选择在它上面永远看不出对错,代码把版本写死成第一条也照样绿。

### 首页:一条全局「最新加入」把信息稀释掉了

按时间混排的话,一部剧更新几集就能把整行占满,想看「电影有什么新的」根本看不到。
改成**每个库一条**(Emby 自己的首页、旧 React 版都是这么分的)。

★★ 这一段要**先占住位置**再去拉。它依赖库表(得先知道有哪些库),比别的块晚一步 ——
不先占位的话只能被追加到最后,于是「随便看看」会跑到各库最新的**上面**,
而且是等库表回来那一刻**当场跳一下**。

★ 库多的服务器(十几个)只取前 6 个,否则首页会被拉成一条竖直的目录。

### Avalonia 的 Animation 动不了 RenderTransform

做首页 Hero 的慢推(Ken Burns)时**连撞两次**,两次的症状<b>一模一样</b>:
轮播一张图都不出、骨架一直闪、日志里一个字都没有。

| 写法 | 结果 |
|---|---|
| `Animation` + `Setter(Visual.RenderTransformProperty, TransformOperations.Parse("scale(1.07)"))` | 运行时抛 `No animator registered for the property RenderTransform` |
| 改成动 `ScaleTransform.ScaleXProperty`,`anim.RunAsync(scaleTransform)` | 运行时抛 `Unable to cast object of type 'ScaleTransform' to type 'Avalonia.Visual'` |

两条都是**运行时**才现形,编译全绿。原因:
- Avalonia 11 的 `Animation` **没有注册 ITransform 的动画器**
  (`Transitions` 那条路自带 `TransformOperationsTransition`,`Animation` 这条路没有);
- `Animation.RegisterAnimator` / `TransformOperationsAnimator` 在 11.3 里**不是公开 API**(试过,CS0122);
- `Animation.RunAsync` 只收 `Visual`,拿 Transform 对象当目标会当场 InvalidCastException。

**结论:变换类动效一律走 `Transitions`,不要用 `Animation`。**
本仓样式表里 `Button.media` 的悬停抬起本来就是这么写的(`TransformOperationsTransition`),
一开始就该照抄它。

★★ 用 `Transitions` 有一条必须遵守的时序:**目标值要下一轮 dispatcher 才设**。
过渡是靠「属性变了」触发的 —— 同一轮里先设初值再设终值,布局系统只会看到最终值,
过渡一次都不会跑。表现是「入场动效没有」,而不是报错。
所以入场是:建控件时设初值 → 挂进树 → `Dispatcher.UIThread.Post(..., DispatcherPriority.Background)` 里设终值。

★ 错开(stagger)不要用 `Task.Delay` 排 —— 起点会落在任意一帧上,两行的错开量每次都不一样。
`Transition<T>.Delay` 就是干这个的。

★★ 这两个异常之所以能藏住,是因为它们从 `_ = Go(...)` 里抛 —— **没人 await,异常被吞进那个 Task**。
凡是 `_ = SomeAsync()` 发出去的方法,身子要自己包一层 try/catch 并把异常打出来,
否则失败形态就是「这块功能就是不动」,不报错、不崩、日志空白。

### 「轮播在不在动」截图判不出来:要把动效曲线采出来

一张静止的大图,和一个**停住了的轮播**,在截图上长得一模一样。
而做这块 Hero 的过程里,**三次**失败都是这个形态(上面两条 + 「同一轮里设了初值又设终值」),
三次的截图都「看着挺正常」。

所以自检不截图,**隔几百毫秒把数读出来**(`LP_HERO=N`):

```
[Hero 动效] +   0ms  A 透明度 1.00 慢推 1.020 | B 透明度 0.00 慢推 1.000 | 进度条 0.00
[Hero 动效] + 220ms  A 透明度 0.84 慢推 1.021 | B 透明度 0.16 慢推 1.002 | 进度条 0.03
[Hero 动效] + 500ms  A 透明度 0.03 慢推 1.024 | B 透明度 0.97 慢推 1.004 | 进度条 0.07
[Hero 动效] +2000ms  A 透明度 0.00 慢推 1.035 | B 透明度 1.00 慢推 1.016 | 进度条 0.29
```

数在动 = 动效在跑。**注入验证**(掐掉那条 `DoubleTransition`)当场变成:

```
[Hero 动效] +   0ms  A 透明度 0.00 ... | B 透明度 1.00      ← 一上来就到位 = 瞬移,没有中间帧
```

`LP_HERO=0` 是另一半:什么都不碰,隔 8 秒(> 停留 7 秒)再看一次它在第几张。
注入「掐掉自动翻页」后如实报 `✗ 没动,轮播是停的`。

★ 慢推的倍率从 `RenderTransform.Value.M11` 读(TransformOperations 折成矩阵,M11 就是横向缩放)。

### 首页 Hero:全宽出血、交叉淡入、慢推

用户要求:无边框、轮播、艺术字 + 标签评分、**动效必须有但不能卡、不能做错的动效**。

**结构**(和详情页头图同一套):Hero 挂在 `PageBase.Scrolled` 的**外面**,
只有里面的文字按 1560 对齐,和下面几条轨道排成一条竖线。
封进 1560 水槽里的话它就成了「一张居中的插图」——左右留边、顶上一道圆角描边,
那正是用户说的「丑陋简陋」。

**动效三件**(全部走 `Transitions`,见上一条):
- **交叉淡入 620ms**,不是横向滑动。整屏大图做位移要在一帧里画两张全尺寸图并各挪各的,
  是这一页最贵的动作;而且「滑」会和下面轨道的横向滚动打架,用户分不清哪一层在动。
- **慢推 9 秒 1.00→1.07 线性**。一张静止大图挂七秒,人眼读成「卡住了」。
  ★ 时长比停留(7s)长一截:正好推完的话末尾会停住,而**停住的那一下反而看得出来**。
  ★★ 两层**各自来回推,不复位** —— 这层这次 1.00→1.07,下次轮到它就 1.07→1.00。
    每次归零要先关过渡、设值、再打开,而关过渡的那一瞬间**交叉淡入在同一个 Transitions 里,会一起被掐掉**。
- **入场上浮 18px + 淡入,艺术字和标签行错开 90ms**。同时出现读起来是「一块贴图」。

**停留计时和小圆点里的进度条同一句话里起步、同一个时长**(`Task.Delay(Dwell)` + 7s 线性过渡)。
各起各的时钟才会漂,漂出来的症状(进度满了不翻 / 没满就翻)看着像随机的。
★ 进度用 `RenderTransform` 缩放不动 `Width` —— 动 Width 是每帧一次布局。
★ 打断时进度条要**瞬时**退回 0(临时摘掉 Transitions 再设值);带着 7 秒过渡去归零的话,
  它会用 7 秒慢慢退,而那 7 秒里它正在为下一张往前走,两边打架看着就是乱抖。

**压暗与出血**:左侧一道横向压暗(给文字),底部一道纵向压暗 + **OpacityMask 化开最后 12%**。
★ 底边用遮罩化开,不是盖一层页面底色的渐变 —— 盖色要知道当前主题底色,而本仓有深浅两套皮。
★★ Hero 根的 `Background` 必须是 **Transparent**:这一层在遮罩**外面**,
  图的下沿化开之后透出来的就是它。写死一个色号的话深色主题下是一条几乎看不出的暗带,
  **浅色主题下就是一条黑边**。用 Transparent 不是 null —— null 的 Border 不参与命中测试,
  整块可点和悬停暂停会一起失灵。

**其它几条**:
- 艺术字(Logo)**没有 `has_logo` 字段可判**,只能拉了才知道有没有,拉不到回落文字标题(旧 React 版同做法)。
- 几张图**一起预取**。翻页时才拉的话,淡入淡到一半发现下一张还没到,就成了「淡出到空白再淡回来」。
- Hero 和「随便看看」**共用一次 `listRandom`**(前 5 张给 Hero,其余给轨道)。
  分开拉会撞车 —— 同一部片顶上是大图、下面又是一张小卡,那不像随机推荐,像加载出了错。
- 生命周期挂 `AttachedToVisualTree` / `DetachedFromVisualTree`,不是构造函数:
  `Nav.Back()` 回首页**复用的是同一个 HomePage 实例**,在 Detached 里永久停掉的话
  从详情页退回来轮播就再也不动了,而且不报错。同理 `Attached` 会重复发,循环要守一个 `_cycling`。
- 假服务器必须让**一部分条目的 Logo 返回 404**(现在按 id 末位奇偶分),
  否则「取不到艺术字回落文字标题」这条路一次都不会被渲染。


### 改了假服务器的图,必须清核心层的图片缓存

★★ 这一条排在最前面,因为它<b>让我把一个好的实现当成坏的查了十几轮</b>。

给假服务器的横版剧照加了四角标(用来判「有没有被裁」),跑自检 —— 角标一个都没出现。
于是顺着往下查:换渲染方式、换控件、拆遮罩、刷红底、打矩形…… 每一步的诊断都说一切正常
(Source 1280×720、盒 1068×321、层透明度 1.00、可见=True),而截图上就是没有。

真因:核心层的 `/img` 通道把上游字节落盘缓存(`userdata/cache/img`),**键是 src**,
而自检里 src 是固定的 `http://127.0.0.1:18096/Items/xxx/Images/...` ——
**界面上一直画的是上一版那张 192×108 的旧图**(被解码放大到 720 高,尺寸也就对得上)。

- 现在 `scripts/selfcheck-win.sh` 每次都 `rm -rf userdata/cache/img`;
  `LP_KEEPIMG=1` 可以留着(量「第二次进首页有多快」时要热缓存)。
- 教训不是「缓存不好」——缓存是对的。是**自检的前提之一是「这一版的字节」**,
  而一切按 URL 做键的缓存都会悄悄破坏这个前提。
- 一般化:凡是改了**夹具产出的内容**而不是它的地址,就得想一想中间有没有人按地址缓存。

### 「整张剧照不裁」和「慢推」是互斥的

用户 2026-09-02 报「Hero 封面不全」。改成 `Stretch=Uniform` 整张显示之后,
角标仍然缺右上和上边 —— 因为慢推(Ken Burns)挂在**整层**上:
1.07 倍围绕中心缩放,右边顶出裁剪框 14px、上边 4px。

**为了动效把刚修好的裁切又做回去了,只是换了个地方。**

现在:慢推只推**糊底那一层**(它本来就是 UniformToFill 裁过的氛围色块,推它不丢信息),
清晰图一动不动。判据写进自检:

```
[Hero 完整度] ✓ 清晰图没有缩放,高 321 ≈ 块高 320 —— 一个像素都没裁
```

★ 注入验证(把慢推挂回整层)当场变红:`✗ 被裁了:A无缩放=False B无缩放=False`。
★ 第一版这条断言写成 `Scale(box) == 1`,而没有变换时 `RenderTransform` 是 **null**,
  我的 `Scale()` 返回 0 —— 于是它**永远报红**。**假红和假绿一样坏**:
  一条长期红的断言,等于没有断言。

### Border 挂了 OpacityMask,它的内容整个不画

想给「完整剧照」的左沿做一道化开,给它外面那层 Border 挂了 `OpacityMask`(横向渐变)。
结果:**这个 Border 里的东西一个像素都不画**。

- 换成 `SolidColorBrush(Colors.White)` 的全白遮罩(等价于不遮)——<b>还是不画</b>,
  所以不是渐变停靠点算错了。
- `OpacityMask = null` → 立刻正常。
- 诊断全绿:Source 1280×720、盒 1068×321、层透明度 1.00、`IsEffectivelyVisible=True`。

**结论:这条路上不要用 OpacityMask。** Hero 现在整块里一个 OpacityMask 都没有:
- 左沿化开 → 盖一层**横向渐变的压暗**(见下一段,它是算出来的不是凑的);
- 底边化开 → 渐变到**主题底色**(要现取 `Bg` 资源并在 `ActualThemeVariantChanged` 时重算,
  写死色号的话浅色主题下头顶一条黑带)。

### 拼图的缝要「数学上连续」,不是「调到看不出来」

Hero 是「左边糊底 + 右边完整剧照」,两块之间原来有一条笔直的竖线。
压暗、化开、调渐变都治不好 —— 因为**两边显示的不是同一块内容**:
糊底是 UniformToFill 拉满整块,缝的左边显示的是原图 x≈47% 处;
清晰图右对齐,缝的右边是原图 x=0 处。颜色本来就不一样,再怎么化开都是在糊。

解法两条,缺一不可:
1. 糊底改成 `TileMode=FlipX` + `DestinationRect` **对齐清晰图那一块** ——
   缝左边正好是 x=0 往回镜像,两侧在缝上<b>是同一个像素列</b>;
2. 压暗层盖在清晰图**上面**,而且是横向渐变:左边 45% 黑,到图的左沿之后化到 0。
   糊底和清晰图是同一张画面,同样压暗之后缝两侧的亮度**数值上相等**。

判据是量出来的,不是看出来的:

```
相邻像素最大跳变 = 5.0   (>8 就是肉眼看得见的竖线)
```

### 侧栏高亮「闪一下」:BrushTransition 到 Transparent 会中途过亮

用户:「鼠标滑到下一个的时候上一个会闪亮一下」。
原写法是给 `Border#root` 的 Background 挂 `BrushTransition`,悬停 PanelAlt、离开回 `Transparent`。

实测采样(深色皮,注入旧样式跑出来的):

| alpha | rgb | 合成到面板上的亮度 |
|---|---|---|
| 0.83 | (116,118,120) | 102 |
| 0.68 | (154,155,156) | **114** |
| 0.26 | (224,224,224) | 78 |
| 0 | — | 26 |

两端是 悬停 35 / 静止 26 —— **中途比两端亮三倍多**,那就是那一下「闪」。

★★ 我第一版是**推理**出来的:「Transparent 是透明的黑,非预乘插值中途会变暗」,
  按这个写了注释和自检。方向<b>正好反了</b> —— 实测是变亮。
  更糟的是那版自检**注入旧样式照样报 ✓**(我自己算的合成和渲染器算的对不上)。
  一条自己算合成的断言,错的方式和被测代码一样多。

现在的写法:悬停/选中各是一层叠加块,只动 `Opacity`(预乘合成,一定单调)。
自检也不再自己算颜色,直接断言**机制**:

```
[侧栏高亮] 退场 root 底色 Transparent
[侧栏高亮] 退场 hov 透明度 0.97 0.73 0.52 … 0
[侧栏高亮] ✓ 只有 Opacity 在动,底色纹丝不动
```

注入旧样式:`✗ root 的底色在动 —— 那是插值到 Transparent 那条路`。

### 缺一个 MDL2 字形 = 一个空心方框,而且不报错

播放页的图标从杂乱的 Unicode 符号(⏸ ⟲ 🕪 ⚙ ⛶)换成 Segoe MDL2 Assets ——
🕪 在 Windows 上走的是 Segoe UI Emoji,渲染成一枚**彩色**图标,和旁边一排线条符号
完全不是一套东西;⟲ 这类数学箭头字重也比周围细一大截。

但 MDL2 的风险是**码位写错**:字体里没有那个码位时画出来是一个空心方框,
而它<b>编译绿、运行不报错、日志一个字都没有</b> ——
截图里一排图标中间夹一个方框,人眼很容易当成「这个图标就长这样」。

所以有 `LP_GLYPH=1`:把全站用到的 31 个码位挨个问字体一遍。

```
[字形自检] ✓ 31 个字形全都在
```

注入一个不存在的码位:`✗ 【注入】不存在的码位 U+E0F7 字体里没有 —— 会画成方框`。

★ 前提是**码位集中一处写**(`PlayerPage.Ico` + `MainWindow.AllGlyphs`),
  散在各处的话自检查不到,加了新图标就是个盲区。

### 「多久算慢」要量,不要认领

用户报「封面加载挺慢的」。量下来(29 张封面,LP_PERF=1):

| | 取(HTTP) | 解码 |
|---|---|---|
| 冷缓存 中位 | 69 ms | 2~35 ms |
| 热缓存 中位 | 44 ms | 2~35 ms |
| **同一次会话里的后续请求** | **0~1 ms** | 12~14 ms |

第一波 29 个请求**同时完成**在 t=1039ms —— 也就是说 44ms 是一次性的启动成本
(本地服务器首次连接),之后每张 0~1ms。取图这条路本身没有问题。

真正省掉的是**请求条数**:媒体库页原来每个库额外打一次 `listItemsPage(limit=1)`
只为了显示「140 项」,而用户 2026-09-02 说这个数不要了 —— 三五个库就是三五次往返。

★ 剩下的延迟在上游。已知放大器:某些 fork **完全无视 maxWidth/maxHeight**
  (见 `emby-image-api-quirks-uhd`),那边返回的是原图,我们这边解码也跟着变贵。


### 「右边留白」是一道算术题:除不尽的余数

用户 2026-09-02 报「媒体库页面右边有留白」,我去掉了 `MaxWidth=1560` 那道封顶。
2026-09-03 他又报了一遍:「右边**还是**有留空,我不知道你留空的意义在哪」。

第一轮改错了地方。真因是**卡片宽度写死**:

```
可用宽 1032,卡宽 158,间距 14
列数 = (1032 + 14) / (158 + 14) = 6.08 → 6 列
占用 = 6×158 + 5×14 = 1018        余 14px
```

库卡那边更明显(320 宽):1400 的区域放得下 4 张 = 1328,**右边必然剩 72px**。
`WrapPanel` 只会换行,它没有「把这一行铺满」的概念。

解法是把算式反过来:**先按最小宽定列数,再把整行宽度均分给这几列**。

```csharp
var cols = Math.Max(1, (int)((avail + Gap) / (MinCardWidth + Gap)));
var w = Math.Floor((avail - Gap * (cols - 1)) / cols);   // 余数一个像素都不剩
```

判据 `LP_FILL=1` 量的是**真卡片的右沿**,不是 `列数 × 卡宽`:

```
[网格铺满] 容器宽 1172  卡片 3 张  最左 0  最右 1172  右边剩 0.0px  ✓
【注入写死宽度】                        最右 988   右边剩 184.0px  ✗
```

★ 为什么不能拿 `列数 × 卡宽` 当判据:那只证明**我算对了**,证明不了
`Card` 真的按这个宽度画了出来。本仓「算得对但画得不对」栽过
(ImageBrush 尺寸全对、屏幕上一片空)。

★ 卡片宽度跟着窗口变之后,**拖窗口要防抖**:SizeChanged 每帧都发,
每帧重建一次 ItemsSource = 每帧丢弃并重建一屏控件,比不虚拟化还卡。
列数变了立刻响应(结构变化),纯宽度微调压到停手 90ms 之后。

### GridLength 没有动画器 —— 想动侧栏就得把宽度挪到控件身上

用户 2026-09-03:「侧边栏收起/展开没有动效」。

上一版的注释写着「宽度用 GridLength 直接改,**不做动画**:这一列一变,
右边整页要重排版」。理由听着成立,但那是<b>事后合理化</b> ——
真实情况是 `GridLength` 是个结构体、Avalonia **没有给它注册动画器**,
挂 `Transition` 上去<b>无声不生效</b>,所以当时根本加不上。

改法:列宽写成 `Auto`,真实宽度放在侧栏自己的 `Border.Width` 上,
那是个 `double`,一条 `DoubleTransition` 就够。

```
[侧栏动效] 采到的宽度 212 211.9 211.5 209 205.5 200.2 192.4 178.3 … 73.7 72.4 72
[侧栏动效] ✓ 中间经过了 15 个插值宽度 —— 是在动,不是瞬移
【注入拿掉过渡】采到的宽度 72
[侧栏动效] ✗ 只有 212 和 72 两个值 —— 宽度是瞬间跳过去的
```

★★ 「有没有动效」**截图判不出来** —— 收起前后各一张,中间是瞬移还是插值
完全看不出。只能按帧采样。这和「轮播在不在动」是同一类判据。

★ 至于「整页重排」那个顾虑:实测不成立。网格只在**列数变了**时才重建
(见上一条的防抖),220ms 里绝大多数帧只是改了个宽度。

### 折叠态图标不对齐,治不了的原因是选择器压根没选中它

用户 2026-09-03:「侧边栏收起的时候,收起/展开没有和其他图标一样居中」。

导航项是 `RadioButton`,靠这条样式在折叠态下把图标撑成一列:

```xml
<Style Selector="RadioButton.nav.icononly /template/ TextBlock#icon">
  <Setter Property="Width" Value="56" />
</Style>
```

而「收起/展开」是个 `Button` —— **这条选择器选不中它**,它一直是 18px 宽 + 10px Padding,
于是折叠之后它比上面那一列偏左 19px。

★★ 第一反应是去改 `HorizontalContentAlignment`,**治不了**:
居中的是「图标 + 空文字」这一整块,而不是图标本身。
真正要同步的是那一组数(Width 56 / Padding 0 / Spacing 0),而且**必须和样式里的一模一样**。

判据量的是**屏幕坐标**,不是属性值:

```
[折叠图标] 折叠键中心 36.0  导航图标中心 36.0  侧栏宽 72   ✓
【注入不撑宽】折叠键中心 17.0  导航图标中心 36.0   ✗ 偏了 19.0px
```


### ★★ 我第二次拿推理当结论:Hero 糊底「对齐+镜像」实测把缝做坏了

用户 2026-09-03:「Hero 栏你的效果很好,但是我的建议是旁边模糊的部分
不是和封面对立的方向,而是做成那种蒙版模糊然后居中就行了,
**不要有模糊和清晰的界限**,看着有点割裂」。

清晰图从靠右改成**居中**,两条边各铺一叠「画着糊底的竖条」做羽化
(透明度由外到内 1→0)。糊底怎么铺,我做了两版:

| 糊底的画法 | 左缝(相邻像素亮度) | 右缝 |
|---|---|---|
| **UniformToFill 铺满整块** | …61 61 62 **62 64** 63 65… | …77 78 **78 79** 79 78… |
| 对齐清晰图 + `TileMode=FlipX` | …44 44 45 **[69]** 69… | …69 69 **[103]** 104… |

第二版是我**推理**出来的:「目标矩形对齐清晰图,两侧镜像补出去,
缝上左右是同一个像素列,数学上连续」。听起来无懈可击,
实测**跳 24 / 34 级**,肉眼一道硬边。

真因:缝左边显示的是原图**右端**的颜色 —— 也就是说 Avalonia 在这条路上
**没有真的翻转**,行为等同于 `TileMode.Tile`(平铺)。
「镜像连续」这个前提整个不成立。

★★ 上一轮我用同一招消掉过一条缝,还写进了教训。它当时之所以看着有效,
是因为**底下还压着一层压暗渐变**把这个错遮住了;这一轮压暗撤掉,错就露出来。
—— 一条被「另一个 bug 抵消掉」的结论,和错的结论一样危险。

现在:糊底老老实实 `UniformToFill` 铺满,同一个 x 上它和清晰图内容**不一样**,
但那正是羽化那 12 条竖条要在 68px 里抹掉的东西。判据:

```
[Hero 羽化] 左侧 12 条 透明度 0.96 0.88 0.79 … 0.12 0.04;起点 249 应在 249  ✓
y=300 横向最大相邻跳变 2.3      (上一版 24 / 34)
```

★ 羽化条的画刷用**绝对坐标的 DestinationRect 往左推 x**:推的是「整块糊底的位置」,
不是「把整张图塞进这条 6px 的缝」—— 后者画出来是一排被压扁的完整剧照,像彩色噪声。

★ 相邻两条要 `Width = step + 1` **压着**:留缝的话缝里透出清晰图,又成了细竖线。

### 缓存要「先画旧的,再画新的」,而且一样就别重画

用户 2026-09-03:「我现在从其他页面待久一点回到首页,首页要加载四五秒,
这是不对的,有缓存直接就零点几秒就打开了」。

封面那层早就有内存缓存(`Images`),**元数据这层一直没有** ——
每次进首页都是一个全新的 `HomePage`,五条轨道各打一次远端 Emby。

口径是 **stale-while-revalidate**:命中就当场把上一次的结果画出来(零往返),
同时照常发请求,回来再画一次。实测(本机假服务器,真服差距会大得多):

```
冷:  969ms 继续观看 <- 服务器 38ms      热: 1022ms 继续观看 <- 缓存(零往返)
     1168ms 电影    <- 服务器 12ms          1110ms 继续观看 <- 服务器 60ms
```

四条硬规矩,少一条就会出新 bug:

1. **第二次必须也画**。只读缓存不刷新的话「看完一集回首页,继续观看还是旧的」——
   那比慢更糟,因为它是**错的**。
2. **一样就别重画**。详情页 / 媒体库页重画一次要重建整页,
   用户看到的是「刚出来的页面当场闪一下又变回同样的样子」,那看着像 bug。
   比的是**整段原文**,不是挑几个字段 —— 挑字段就得跟着核心层的输出走,漏一个就成了「改了不刷新」。
3. **重画之前先清干净**。缓存那一版已经把整页画出来了,不清的话真数据会**再叠一份**上去。
4. **已经用缓存画出内容之后再失败,不要把内容换成一行红字**。
   离线时屏幕上那批旧数据仍然是用户能用的东西。

★ 缓存键里要**把 token 抠掉**(会话四件套是每页显式传的)。不抠的话每次重登
都等于清空缓存,而重登恰恰是最需要它的时候。

☠ **只能缓存读命令**。写命令进了缓存就是「点了没反应」——
所以这一层**不做横切拦截**,由调用点显式给键。


### 自检报绿、截图空白:右键菜单是另一个顶层窗口

把服务器页那四组编辑动作搬进侧栏的右键菜单之后,加了一条自检把菜单弹出来。
日志:`[服务器菜单] ✓ 已弹出,10 项`。截图上:**什么都没有**。

两个原因叠在一起,而且都只有在自检这条路上才会撞到:

1. **自检模式下主窗是 `Topmost`**(防止截到别的程序)。而 Avalonia 在 Windows 上
   把 `ContextMenu` 画在**另一个顶层窗口**里,那个窗口不是 Topmost ——
   于是它被主窗压在下面。
2. **`ContextMenu` 默认 `Placement = Pointer`**。自检里**鼠标在哪儿是不确定的**
   (多半根本不在窗口上),菜单弹在屏幕的某个角落,而截图只截窗口那块区域。

自检里两条都得改(`Topmost = false` + `Placement = RightEdgeAlignedTop`),
真用户那边不受影响 —— 他是右键点出来的,指针位置天然就是对的。

★★ 这一条本身就是「日志说绿、屏幕上没有」的典型。凡是**弹出层**的自检
(菜单 / 下拉 / 提示气泡),报「已打开」都不算数,**必须在截图上看见**。

### 改夹具内容要清的不只是 cache/img,还有 cache/icons

上一轮记过「改了假服务器的图必须清 `userdata/cache/img`」。这一轮验
「用户头像 404 时要退回官方图标」——**一次 HTTP 都没发出去**,
因为服务器图标另有一层缓存 `userdata/cache/icons`,按 `server_id` 做键,
而自检里 `server_id` 是恒定的。

一般化那条规律:**凡是改了夹具产出的内容而不是它的地址,
就得把中间所有按地址做键的缓存都清一遍**。现在自检脚本两层一起清。

### Slider 做不出现代播放器的进度条

用户 2026-09-03:「播放页的 UI 需要优化,一个是有点小了放大一点,
还有一个就是现在的播放页的 UI 不是现代的播放器的 UI,没有现代播放器的那种交互」。

上一轮为了治「一点都不好点击」,把 `Slider` 的 `MinHeight` 拉到 28。
那只是把**同一个控件**加高 —— 画出来仍然是一条粗线加一个常驻圆点。
现代播放器(YouTube / Netflix / Bilibili / Plex / IINA,见
`docs/research/modern-player-ui.md`)的进度条有五个特征,`Slider` **一个都给不了**:

| 特征 | Slider 的情况 |
|---|---|
| 静止 4px 细线,悬停涨到 7px 并冒出圆头 | Thumb 常驻,一直在画面上戳着 |
| **已缓冲**那一段(浅色) | 只有「已播 / 未播」两段 |
| 章节缺口 | 没有 |
| 悬停时浮一个**时间气泡** | 没有 |
| 热区 24px、视觉 4px **两个数分开** | 绑在一起:想好点就得画粗,画粗就压画面 |

所以自绘(`Views/PlayerBar.cs`)。三个只有真写一遍才知道的坑:

- ☠ **`Control` 不画东西就接不到鼠标**。命中测试看的是**画出来的内容**,
  不是 `Bounds` —— 什么都不画的 `Control`,那 24px 热区等于不存在。
  解法是先 `FillRectangle(Brushes.Transparent, …)`。
  (`Panel.Background="Transparent"` 是同一个把戏,但 `Panel.Render` 是 `sealed`,
  想自绘就只能用 `Control` 自己铺一层。)
- **松手才 seek**,拖动只动画面和气泡。拖一次实时 seek 几十下,
  在网络流上是几十次 Range 重连;而且本仓栽过「seek 闩拿粘性值和目标比,
  一比就相等当场自解除」,这条路上多一个并发源就多一次那种 bug 的机会。
- **拖动中别让轮询盖回时间读数** —— 那会儿它显示的是手指所在位置,
  被盖回当前播放位置的话,拖的时候数字纹丝不动。

顺带补齐的:已缓冲段要核心层给 `demuxer-cache-time`(**绝对时间,不是长度**,
写成 `position + 它` 会算出双倍);版式改成「整条进度条独占一行 + 底下一排按钮」——
原来「时间 | 条 | 时长」挤一行,进度条两端各缩进 60 多像素,
而**片头片尾恰好在那两端**。


### 服务器图标那两条路核心层早就有,UI 一次都没调过

用户 2026-09-03:「获取服务器图标,一个是官方 API,一个是从用户头像获取,
这两个都是 Emby 服常见的服图标获取方式,**这样就不需要做一些奇奇怪怪的图标代替了**」。

查下来:两条路核心层<b>都写好了</b>(`serverbatch.BuildIconURL`:登录时优先用
用户头像 —— 很多 Emby 服把品牌 logo 直接设成用户头像,而且它是免登录的公开资源;
没头像退回 `/web/touchicon.png`),`account.icon` 也早就能吐 data URI。
**缺的只是 UI 从来没调过它** —— 又一条零调用命令(本仓这类缺口的第 N 次)。

真正要补的核心层缺口只有一个:`IconGet` **只试一条地址**。
而那一条会**后来失效** —— 用户把头像删了,`icon_url` 还指着旧的头像地址,
一个 404 之后就再没有图标了,而官方那条明明还好好的。
改成 `IconGetAny(ctx, id, 候选...)`,按序试:`icon_url` → `/web/touchicon.png`
→ `/web/touchicon144.png` → `/web/favicon.ico`。

先红后绿(注入「只试第一条」):

```
--- FAIL: TestIconGetAny_第一条挂了要接着试后面的
    两条里有一条是通的,不该整体失败: 下载图标失败: HTTP 404 (试过 [/Users/u1/Images/Primary])
```

★ 假服务器两条路**画成不同颜色**,截图上才分得清 UI 走的是哪一条;
画成一样的话「头像挂了自动退官方图标」这件事永远验不了。
`-no-avatar` 开关就是为这个加的。


### ☠☠ loadfile 的第 3 个位置是 index 不是选项 —— 只有带续播进度的片子会中招

用户 2026-09-03:「继续观看里面的影片看不了,点击就是 loadfile 失败」。

**这句话本身就把范围锁死了**:继续观看 = `resume_secs > 0` 的那一批,
而它和别处唯一的区别,是 `loadWith` 会多拼一个 `start=`。

mpv 的签名是 `loadfile <url> [<flags> [<index> [<options>]]]` ——
`index` 是 **0.38 才插进来的一个参数**,而我们的代码是照着旧签名写的:

```
loadfile x.mkv replace                    → 0  success
loadfile x.mkv replace start=123.000      → -4 invalid parameter   ← 我们发的
loadfile x.mkv replace -1 start=123.000   → 0  success
```

真机 mpv 日志里的原话:

```
[e][main] The loadfile option must be an integer: start=75.000
[e][main] Command loadfile: argument index can't be parsed: option parameter could not be parsed.
```

★★ 这个 bug 之所以能活着,是因为**从头看的片子永远碰不到它** ——
只有三段的那条路一直是对的。而自检台里 `player:xxx` 那条**续播位置写死传 0**,
于是「带 start= 的 loadfile」这条路在自检里<b>一次都没被走过</b>。
现在自检有 `LP_RESUME=<秒>`。

★ 判据要盯**第 3 段是什么**,不是「参数里有没有 start=」:
后者在旧写法下照样绿。参数表抽成了纯函数 `loadArgs`,单测直接比位置。

### 图片缓存键里带着卡宽,而卡宽自从「按行宽均分」之后是连续量

用户 2026-09-03:「媒体库页和媒体库详情页在我收起/展开侧边栏的时候,
图片都要重新加载或者闪一下,这些图片应该是缩放的吧?」

两个独立的原因叠在一起:

**① 真的在重下。** 图片走 `/img?src=…&h=<高度>`,而 `h` 是从**卡片实宽**算出来的。
上一轮把卡片改成「按行宽均分」之后,这个宽度就成了连续量 ——
收一下侧栏,可用宽 +140,卡宽 158→183,`h` 从 480 变成 549,
**缓存键当场不认**。实测(18 张卡的库页,收一次侧栏):

```
归档前:30 次请求,m1 被取了 480 和 549 两遍
归档后:18 次请求,每张一次
```

解法是把解码高度**取整到一张粗档位表**(相邻档差约 35%),
侧栏收放引起的那点变化落不出一档去。★ 只能往上取:往下取会解出一张比显示尺寸
还小的图,拉大之后是糊的,而且不报错。

**② 命中缓存也要等一帧。** `LoadArt` 无论命中与否都走一次 `Dispatcher.Post`,
于是每张卡都必然有**一帧**是「骨架 + 透明的图」,下一帧才淡入 ——
一屏几十张同时这么来一下,就是那个「闪」。
现在命中就在构造那一刻贴上去,连淡入都不做(那张图上一帧还在屏幕上,
给它做入场动画本身就是错的)。

★ 一般化:**凡是缓存键里含了一个会被布局改变的量,这层缓存就是漏的**,
而漏的表现是「重新加载」,不是「报错」。

### 「做成一行」治不了「上千集卡死」—— 那是两件事

用户 2026-09-03:「详情页里面的集数显示和演职人员的显示,不要一口气全显示出来,
遇到那些上千集的不一下子卡死了,做成一行的,可以点击左右的按钮滑动展示的」。

☠ 「排成一行」是**版式**,「不卡死」是**造了几个控件**,两者毫无关系 ——
一行一千张卡还是一千张卡。真正省下来的是横向的 `VirtualizingStackPanel`。

判据必须写成「条目数 vs 真造出来的容器数」:

```
[分集轨道] 条目 1200 条,真造出来的卡 5 张
[分集轨道] ✓ 只造了 5/1200 —— 虚拟化生效,上千集不会卡死
```

★★ 而且**夹具必须真有上千集**。原来假服务器写死 12 集,
12 张卡不虚拟化也全在屏幕上 —— 这条断言在那个夹具上**必然绿**。
现在 `fakeemby -eps 1200`。「假服务器只能造出你想到的形状」。

★ 季条也顺手换掉了:原来是一排平铺按钮,二十几季会折成四五行把分集推到折线以下;
集更没法平铺。改成两个下拉,列表自己滚 —— 这正是用户说的「滑动浏览季度/集数」。

★ 「跳到第 N 集」不能按控件求位置(那一张多半还没造出来),按**卡宽**算偏移。


### async void 是语言层面把「等它」这个选项拿掉了

用户 2026-09-03:「切换服务器的时候,首页也应该跟着一起切换,
而不是等用户自己点击了首页再切换」。

我先以为是「切完没换页」。读了代码才发现**换页那一句一直都在**:

```csharp
await _core.AccountSetActiveServer(new { server_id = server });
OnServerSwitched();                 // ← async void,调用点等不了
NavHome.IsChecked = true;
Nav.Root(Home());                   // ← Home() 读 Nav.Session,那会儿还是上一台的
```

新首页确实建出来了,只是**拿旧服务器的凭据去拉的内容**。
`OnServerSwitched` 里那句 `Nav.Session = …` 要等两次往返才落地,而这三行早就跑完了。

★★ `async void` 不是风格问题:它**在语言层面把「等它」这个选项拿掉了**。
改成 `Task` 之后调用点一个 `await` 就对了。

★ 顺带把「添加完 / 删除完」也并进同一个收尾(`AfterServerChange`)——
它们原来只是 `Nav.Back()`,退回去的是一张上一台服务器的页面,同一个病的另外两个入口。

★ catch 里要 `Nav.Session = null`,不能留着上一台的会话:非 Emby 账号切进来时
拉不到会话,留着旧的等于「换了账号还在用上一个人的 token」。

### 已经选中的侧栏项点不动:RadioButton 的 Checked 不会再发一次

用户 2026-09-03:「整个软件的交互是有问题的…等等交互问题,你可以自己去探索,很多」。
自己找的第一条,而且它每天都会撞上:

从首页点进一部片的详情页 —— 侧栏的「首页」**仍然亮着**(它确实还是首页这一支)。
这时候点它,`RadioButton.Checked` **不会再发一次**(本来就是选中态),
导航挂在 `Checked` 上,于是**点侧栏毫无反应**;界面上唯一的出路是详情页左上角那个「返回」。
每一个能往下钻的入口(首页 / 媒体库 / 搜索 / 收藏 / 聚合)都有这个毛病。

修法是补挂 `Click`,只处理「本来就选中 + 栈深 > 1」这一种情况,
命中就 `IsChecked = false; IsChecked = true` 把 `Checked` 逼出来。

★ **不要**整体改成用 `Click` 驱动导航:`Checked` 那条路还有程序化调用者
(切完服务器 `NavHome.IsChecked = true`),两条并存会导航两次。

★ 别拿 `Tag` 当「挂过了」的标记 —— 那一格装的是这一项的图标字形。用一个 `HashSet`。

★ 判据是**栈深和当前页**,不是「有没有触发处理器」:触发了但导航到同一张详情页,
用户感觉不到任何区别。

```
[侧栏回根] 点之前:栈深 2 当前页 DetailPage 首页项选中 True
[侧栏回根] 点之后:栈深 1 当前页 HomePage        ✓
```

### 收起 OSD 只降 Opacity 会留下两条看不见的横带吃鼠标

用户 2026-09-03:「播放页的上下栏不会渐隐渐显」。原来那里翻的是 `IsVisible` ——
一条压着画面的黑渐变条**整块凭空出现 / 凭空没了**,暗场景里尤其扎眼。

改成过渡时三条都要:

1. **`IsHitTestVisible` 必须跟着翻**。透明的控件照样吃鼠标 ——
   收起来之后画面上下两头会有两条看不见的横带点不动,
   而用户点画面的意图是暂停,表现是「上下两头点了没反应」。
2. **收起时不要把 `IsVisible` 置 false**:那样过渡还没跑完就被摘掉了,等于没有动画。
   让它透明地待着(Opacity=0 的控件不产生绘制成本)。
3. **判据要逐帧采 Opacity**。只断言「收起后 Opacity==0」的话,一刀切也照样绿 ——
   那正是改之前的行为。和侧栏动效那条同一个道理。

```
[OSD 渐隐] 采到 1 0.51 0.22 0.07 0.01 0     ✓ 中间经过了 3 个过渡值
注入拿掉过渡后:采到 0                        ✗ 一刀切
```

★ 顺带把「沉浸」和「全屏」**拆成两件事**(`Nav.Immersive` / `Nav.Fullscreen`)。
它们原来绑在一起,于是用户说的「播放页不应该有侧边栏」没法单独满足 ——
一收侧栏就把窗口也拽进全屏了。现在进播放页就收外壳,按 F 才动窗口状态。
★ 放回来要挂在 `DetachedFromVisualTree` 上,不能只写在 `Leave()` 里:
用 Alt+← 之类别的路退出时外壳再也不出现,那就是「软件的导航没了」。

### 改夹具要清的缓存现在是三层(img / icons / meta)

上一轮刚把 `cache/icons` 补进自检脚本的清理表,这一轮**当场又栽一次**:
给假服务器补了「分集详情」的形状(原来所有 id 一律回 Movie),
界面上照样画的是电影版式 —— 因为 `emby.itemDetail` 的上一次结果
还躺在 `userdata/cache/meta` 里,而键里只有 server + item_id。

规律再写一遍,这次带上第三层:**凡是改了夹具产出的内容而不是它的地址,
就得把中间所有按地址做键的缓存都清一遍**。今天是 `img` / `icons` / `meta`,
明天加一层就是四层 —— 加缓存的那一次就要顺手改自检脚本。


## 跨域交叉引用

这些条目和本领域强相关,但正文放在别的文件里(一条经验只存一份正文):

- [PC 播放页独立窗口](player-mpv.md) — 播放页已拆成独立 Tauri 窗口
- [播放窗标题栏 + 换片黑屏](player-mpv.md) — 播放窗常驻标题栏与换片黑屏
- [本周看板定案+PC视觉自检](methodology.md) — 无头 Edge 渲染真 DOM 的视觉自检法
- [挂真机 CDP 调试](methodology.md) — 挂真实 exe 用 CDP 验证,别拿合成 DOM 当证据
- [首登闸口+源表单共用](sources.md) — 首登闸口与数据源表单共用一份实现
- [PC 绿色包单一数据根](build-release.md) — PC 是绿色包,落盘路径唯一出口是 paths.rs
