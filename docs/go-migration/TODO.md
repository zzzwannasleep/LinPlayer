# TODO · Go 核心 + 各端原生 UI

> 状态:草案 v0.1 · 2026-08-30
> 架构见 `SPEC.md`,迁移方案见 `MIGRATION.md`,命令契约见 `COMMANDS.md`。

## 图例

- `[ ]` 未开始 · `[~]` 进行中 · `[x]` 完成
- **判据** = 这条做完的客观证据。没有判据的任务不算任务。
- 🔴 = 阻塞后续 · 🟡 = 有依赖 · 🟢 = 可独立进行

---

## 0. 迁移必带清单(现网不修 —— 用户 2026-08-30 决定)

调研中从代码里挖出的 17 条缺陷。**用户决定:现网一条都不修,迁移完自然就没了。**

⚠️ **但「迁移完就没了」只对其中一部分成立。** 按是否会自动消失分三类:

| 类 | 含义 | 条目 |
|---|---|---|
| **甲 · 会自动消失** | 根因是当前架构(两份手工拷贝的命令层 / WebView / 双顶层窗) | N3 N4 N5 N9 N10 N11 N14 |
| **乙 · 不会自动消失,Go 版必须主动做进去** | 是缺失的功能或防护,换语言不产生它 | **N1 N2 N12 N15 N16 N17** |
| **丙 · 是测试/护栏缺口,新栈同样需要** | 换语言后同样要写这些测试 | N6 N7 N8 N13 |

**乙类是这份清单存在的全部理由。** 尤其:
- **N1**(magicyuv CVE 防护)——Go 版不加就还是没有,而且这次已经因为一次重构丢过一回
- **N12**(弹幕过滤前端零接线)——核层有实现、UI 从没调用过,新 UI 照抄旧 UI 就照样漏
- **N15**(Ani-RSS 契约已被上游改掉)——不接新契约,新版本一样放不出来

移植到对应模块时,**逐条对照本清单验收**。

### 🔴 N1 · CVE-2026-8461(magicyuv)防护在重构中丢失

- **状态:当前桌面版没有任何防护。** 全仓 `grep magicyuv` 零命中(2026-08-30 实测)
- **怎么丢的:** 原修法是 `mpv_player_adapter.dart` 里一行 `setProperty('vd', '-magicyuv')`。
  该文件随 `0dd295fe`(删 Flutter + 重组仓库)一起删除,Rust 重写**没有接过来**
- **影响面:** 桌面(Win / Linux)用的 libmpv 编入了 `magicyuv` → **受影响**。
  安卓用解码器白名单构建,`magicyuv` 未编入 → 本就免疫
- **攻击向量:** 恶意 AVI / MKV / MOV 触发 libavcodec `magicyuv` 堆越界写(恶意 slice_height)
- **修法:** 在 mpv 初始化选项里加 `vd` = `-magicyuv`
  (mpv `common/codecs.c` 语义:`-<decoder>` = 排除该项,其余仍自动选)

- [ ] **N1.1** 在 `crates/mpv` 的初始化选项里恢复 `vd=-magicyuv`
- [ ] **N1.2** **回读验证**,不能只看编译绿 —— `Player::new` 的 `set` 闭包**吞掉 mpv 返回码**
  (`crates/mpv/src/lib.rs:1229`),选项写错是静默无效
  - 判据:mpv 日志里确认该解码器被排除;或播一个 magicyuv 样本确认走不到那个解码器
- [ ] **N1.3** 加一条测试钉住,防止下次重构再丢
  - **先红**:去掉那行,测试必须变红
- [ ] **N1.4** 检查 Windows libmpv 钉版是否已可升到含 FFmpeg ≥ 8.1.2 的构建

> **教训:** 当初的记忆条目里明写着「新增/换播放器内核时,确认播放路径仍带 `vd=-magicyuv`」。
> 这条指令存在,但换内核时没人执行 —— **靠文档提醒防不住重构,只有测试能。**

### 🔴 N2 · 安卓软解调优参数全丢

- **状态:** `vd-lavc-threads` / `skiploopfilter` / `hdr-compute-peak` / `framedrop`
  全仓零命中(2026-08-30 实测)
- **怎么丢的:** 同 N1 —— 原来在 Flutter 的 Kotlin 侧(`88757f17`),随重构消失
- **影响:** 安卓纯软解(杜比视界等)卡顿调优失效

- [ ] **N2.1** 恢复移动端软解调优参数;移动端软解要关 `hdr-compute-peak`
- [ ] **N2.2** 真机验证卡顿改善(不是看参数设上了)

### 🟠 N3 · `stream-lavf-o` 整条选项丢失

- **状态:** 全仓零命中
- **背景:** 当初只该删 `multiple_requests=1`(它让 libavformat seek ×130 变慢),
  **reconnect 那组是该保留的**,一起被误伤了
- [ ] **N3.1** 恢复 reconnect 组,**不要**恢复 `multiple_requests=1`

### 🟠 N4 · 安卓的播放偏好「假落地」

- **状态:** 安卓完全没有 `apply_playback_defaults` —— hwdec 偏好 / 默认倍速 / 杜比自动软解
  **三项落库但没人读**,而设置命令还在校验 `settings.hwdec`(`apps/android/src/lib.rs:2126`)
- [ ] **N4.1** 补上读取与应用
- [ ] **N4.2** 判据是 mpv 日志里的实际 hwdec,**不是** invoke 参数

### 🟠 N5 · 安卓 Surface 解绑没有同步屏障

- **状态:** `surfaceDestroyed → set_surface(0)` 只改了存的指针,
  活着的 Player 里 mpv **仍持着那个已失效的 ANativeWindow**
- **讽刺的是:** `SPEC.md` §7.2 把这条列为「安卓端最容易漏的一条」—— 现在就漏着
- [ ] **N5.1** 加同步屏障:解绑必须阻塞到 mpv 确认不再持有
- [ ] **N5.2** 判据:快速反复旋屏 100 次不崩

### 🟡 N6 · 超分档位测试是假绿

- **状态:** 上游 ArtCNN 门槛是 `/1.3`,本地这份被改成 `*1.200`;
  而 `when_ratio_matches_shader_source` **只扫 `MAIN.w`,ArtCNN 用的是 `LUMA.w`**
- **后果:** 从上游刷新该文件后,`will_run()` 会在 1.25× 谎报「会生效」而**测试全绿**
- [ ] **N6.1** 测试改成从 shader 文件里解析实际用的变量名,或同时扫 `MAIN.w` 与 `LUMA.w`
- [ ] **N6.2** **先红**验证

### 🟡 N7 · 预取代理零鉴权

- **状态:** `127.0.0.1:<随机端口>/play` **任何本机进程都能打**,`handle()` 不校验任何东西
- **对比:** localserve 只听回环、companion 有一次性 token —— prefetch 是三者里最松的
- **风险:** 同机的其它进程可以枚举/拉取用户的媒体流
- [ ] **N7.1** 加 token(路径段传,不能加请求头 —— mpv 的 `http-header-fields` 是全局粘连属性,
      详见 `SPEC.md` §6)

### 🟡 N8 · 四条关键不变量当前没有独立测试

`NETWORK.md` §9-1 逐条比对 23 个测试的断言后确认的缺口:
残段不进共享登记处 / `live_end` 必须排在落盘后 / 同段双连接只认先到者 / 250ms 兜底轮询。

- [ ] **N8.1** 补齐这四条的测试(**先红**验证)

### 🟠 N9 · 安卓的 302 重签看门狗是死的

- **状态(已验):** `apps/android/src/lib.rs` 里 `source_play_entry` 出现 5 处,
  **没有任何一处写入 `Some(...)`** —— 只有声明、清空成 `None`、以及读取。
  对照桌面:9 处,其中 1 处真写入
- **后果:** 看门狗(`:3729`)读到恒 `None` → 网盘直链过期后**永不重签** → 播到一半断流
- [ ] **N9.1** 起播时把 `(entry_id, entry_name)` 写进去,与桌面对齐
- [ ] **N9.2** 判据:直链过期后能自动续上(不是看代码有没有写)

### 🟠 N10 · 浏览型源的服务端进度上报在安卓侧断链

- **状态(已验):** `report_source_progress` 桌面 3 处、**安卓 0 处**
- **后果:** 飞牛等有服务端观看记录的源,安卓上看的进度不回传
- [ ] **N10.1** 接上该通道

### 🟡 N11 · 安卓插件源授权可能是死代码(待确认)

- **状态:** `sync_plugin_source_grants` 桌面 4 处、安卓 2 处 —— **数量少但不为零**。
  调研 agent 称「插件源在 `source_backend` 就被拦死」,**我只验到了调用次数差异,
  没验到那个拦截点**。归类为待确认,不是已确认
- [ ] **N11.1** 确认安卓上插件提供的媒体源能否真正进入浏览流程
- [ ] **N11.2** 若确为死代码,补齐

> **N9 / N10 / N11 的共同根因:** 桌面与安卓是**两份手工拷贝的命令层**
> (`apps/desktop/src/lib.rs` 5900 行 vs `apps/android/src/lib.rs`)。
> 仓库里贴了两处「改这里要同步改那里」的警告 —— **警告没拦住,因为它靠人眼**。
> 核层唯一做对的示范是 `probe_backend`:口径下沉到 core,两端只调。
>
> **这正是 Go 重写要根治的问题:** 新架构只有一份命令表(`COMMANDS.md` 四方比对),
> 平台差异靠 `system.capabilities` 声明,不靠两份拷贝各自维护。

### 🔴 N12 · 弹幕屏蔽词 / 黑名单 / 类型过滤:前端零接线,且 UI 在骗用户

- **状态(已验):**
  - 核层**有实现**:`apps/desktop/src/lib.rs:3451 danmaku_filter`、`:3460 danmaku_import_blocklist`
  - 前端**零调用**:全仓 `ui/` 里 `danmaku_filter` 只有 2 处命中,**两处都是注释**;
    `danmaku_import_blocklist` 0 处
  - 两个调用点**硬传空过滤器**:`ui/desktop/App.tsx:532`、`ui/mobile/pages/PlayerPage.tsx:276`
    都传 `defaultDanmakuFilter()`(三个空数组)
  - **而 UI 文案已经在告诉用户这个功能存在**:`ui/mobile/pages/PlayerPage.tsx:1198`
    写着「匹配规则、屏蔽词、…」,指向一个**不存在的设置**
- **这是本仓库反复出现的同一个模式:后端领先前端,而注释/文案已经当它做好了**
- [ ] **N12.1** 前端接线:过滤器从设置读,不要硬传默认值
- [ ] **N12.2** 补设置入口(或者改掉那句文案 —— 但别让 UI 撒谎)
- [ ] **N12.3** 判据:**真渲染断言 invoke 的实际参数**。
      核层单测全绿照不到这类 bug,只有 CDP 拿真参数对账才抓得到

### 🟠 N13 · `set_str` 丢弃 mpv 返回值(静默失效的机制源头)

- **状态(已验):** `crates/mpv/src/lib.rs:1466-1470`
  ```rust
  fn set_str(&self, name: &str, val: &str) {
      ...
      unsafe { mpv_set_property_string(self.ctx, n.as_ptr(), v.as_ptr()); }
  }
  ```
  返回码直接丢弃 → **属性名写错、平台不支持,一律静默无效**
- **这是 N1 / N4 / N14 这一整类问题的共同机制** —— 不是某一处写错,是错了没人知道
- [ ] **N13.1** 让 `set_str` 返回 `Result`,调用点按重要性分级处理
      (关键项失败要上抛,可选项失败记日志)
- [ ] **N13.2** 关键项(hwdec / vd 拉黑 / 着色器路径)必须**回读验证**

### 🟡 N14 · 两端 libmpv 版本不同导致的属性静默 no-op(待确认)

- **调研称:** 安卓 libmpv 是 v0.36(`secondary-*` 只有 5 个),Windows 是 v0.41(10 个);
  安卓缺 `secondary-sub-ass-override` / `-delay` / `-pos`,而安卓侧代码三项全调
- **我的复核:** `apps/android/src/lib.rs` 里 grep `secondary-` **只命中注释**
  (`:3254-3256`,内容是 2026-07-16 用 ctypes 实测的属性清单)。
  **没有验到那三处调用点** —— 可能属性名是拼接构造的,也可能行号有偏差
- [ ] **N14.1** 确认安卓侧是否真的在调这三个属性
- [ ] **N14.2** 确认两端 libmpv 版本差异(**用 ctypes 拉 `property-list`,不要 grep 二进制** ——
      见下方方法学警告)

> ### ⚠️ 方法学:grep mpv 二进制查选项是**无效方法**
>
> 调研中的一次自我证伪:`sub-font-size` 在 Windows DLL 里 grep **0 次**,
> 但它被 ctypes 证实存在 —— mpv 的样式类选项是**前缀拼接注册**的,字符串不以全名形式存在。
>
> **记忆条目 `android-mpv-subtitle-fonts.md` 里「grep 全 miss 所以不存在」用的正是这个被证伪的方法。**
> 唯一可靠的查法:ctypes 加载 libmpv,拉 `property-list` / `option-info`。

### 🔴 N15 · Ani-RSS 源在上游 v3.1.23+ 上放不出来(**仍未对真实例验证**)

> **2026-08-31 复核:结论加强,但状态没变。** 本轮 clone 上游(`3845c8e0`,tag **3.2.27**)
> 逐文件读源码,把原来的「推演」补成了带版本号的事实,**但同样没有对着真实例打过** ——
> 手上仍然没有 Ani-RSS 服务端。**「读源码推演」和「复现」是两件事,别混。**
>
> 本轮新增的确定信息:
>
> | 项 | 结论 |
> |---|---|
> | 断点提交 | `a91b5b7`(2026-05-08),`Base64.encode(absolutePath)` → `absolutePath` |
> | **首个含它的 tag** | **v3.1.23**(之前一版是 v3.1.22) |
> | 最新版是否仍如此 | **是**,3.2.27 的 `PlayController` 仍是 `setFilename(absolutePath)` |
> | base64 现在谁做 | **客户端**。上游前端 `js/global.js:145-150` 的 `toApiFile` 自己编码 |
> | 我们错在哪一行 | `anirss.rs:302` 取值、`:340` 注释断言「已是 base64」、`:354` 直接塞进 URL |
>
> **为什么一直没暴露:** 列表显示名优先取 `title`/`name`,只有都缺时才 base64 解码,
> 而 `safe_decode` 解码失败会回退原串 —— **名字永远对,只有播放坏**。又一例「界面在撒谎」。
>
> **Go 版的解法:按内容嗅探,别按版本号分支。**
> ⚠️ 不能用「含 `/` 就是路径」来判 —— **标准 Base64 字符集本身含 `/`**,判据必须落在解码之后。
>
> 完整播放链路(只有三个端点,其中两个必需)、取流鉴权的四个细节、外挂字幕的同款坑:
> **`knowledge/ANIRSS.md` §2.5**。
>
> 讽刺的是:同一个上游提交还新建了 `ProxyImageController`(+109 行)—— 正是下面 N17 那条。
> **有人跟进了图片那条,没跟进播放这条。**

- **调研发现:** 上游 Ani-RSS commit `a91b5b76`(2026-05-08)把 `PlayItem.filename` 与
  `Subtitles.url` 从 base64 改成**裸绝对路径**,编码责任移交客户端。
  **我们仍按旧契约原样发。**
- **按上游源码推演的后果:** v3.x 服务端上,这个源的**任何一集都放不出来**,
  外挂字幕同样必 404
- ⚠️ **状态:未实测。** 手上没有 Ani-RSS 实例,这是**读上游源码推演**的结论,
  不是复现出来的。**在实测确认之前,不要按它改代码**
- [ ] **N15.1** 找一台 v3.x 实例复现(或确认上游改动的实际生效范围)
- [ ] **N15.2** 确认后按新契约改编码,并加一条钉住契约的测试

> **为什么这条值得单列:** 上游**完全没有 API 版本化**(72 个端点全在扁平 `/api/*`,
> 无 `/v1/`、无 `Deprecation` 头),叠加「状态码恒 200」——
> **破坏性变更是静默的**。调研查到上游有过 4 次破坏性变更,**我们中招 2 次**。
>
> 这也是 Go 版必须补的一条护栏:对接无版本化的上游时,
> 契约变更只能靠**主动对账**发现,不能指望对方报错。

### 🟡 N16 · Ani-RSS 有一整块功能域未接

- **状态(机械比对):** 上游 **72 个端点,已接 51,未接 21,反向差集 0**
  (不存在"我们打了但上游没有"的路径)
- 21 条未接里 **8 条是真缺口**,其中
  `startCollection` / `previewCollection` / `getCollectionSubgroup`
  是**唯一整块缺失的功能域**
- [ ] **N16.1** 确认这块功能域要不要做(产品决策,不是移植任务)

### 🟡 N17 · `anirss_proxy_image_url` 做好了一次没用上

- **状态:** 该能力实现完整(走服务端配置的 HTTP 代理出网、磁盘缓存 + 30 天
  `Cache-Control`、修 Mikan 重定向、SSRF 闸),但**全仓零调用方**
- **顺带更正:** 我在 ANIRSS §11 写的「推测是上游图片要带 token」**是错的**。
  要 token 的是代理端点自己(`@Auth`),不是上游图片
- [ ] **N17.1** 决定:接上(海报走代理,拿缓存与防盗链)还是删掉

---

## 1. 阶段 0 · 风险验证(SPIKE)

**四个 SPIKE 全部有结论之前,不写第二行业务代码。**
每个 SPIKE 的产出是一份 `docs/go-migration/spikes/SPIKE-N.md`,含:实测数据、结论、
若失败的备选方案。**禁止**以"应该可以"结题。

### 🔴 SPIKE-1 · Windows/Linux 视频合成

最大的架构风险。见 `SPEC.md` §7.3。

- [x] **S1.1** 路径 A(`--wid` 子 HWND)是否可用 ✅ **已裁决:不做**
  - 原生子窗口永远画在 UI 内容之上(airspace),拿不到「UI 盖在视频上」;
    唯一出路是用 mpv 自己的 Lua OSD —— **已被明确否决**。见 `SPEC.md` §7.3
- [x] **S1.2** ✅ **Avalonia 侧接上路径 B —— 已结题 2026-08-31,四条判据全过**
  - 报告:`spikes/SPIKE-1c-avalonia-path-b.md`(工程在 `spikes/s1-2/`,可复跑)
  - 判据全过:1080p60 满帧 60.0 / 4K24 满帧 24.0,丢帧均 0,`hwdec-current=d3d11va-copy`;
    半透明控件**可见**(品红偏移 323~343)、**真半透明**(视频透上来)、**不闪**(每帧都在)
  - 契约那个窄接口(`fbo / w / h / flip_y`)**够用**,不需要给 UI 层开额外口子
  - CPU(真 Avalonia 控件里量的,不是 harness 的数):**ANGLE 60% vs WGL 18~24%**,
    差 2.9 倍且差在宿主合成底噪(39% vs 13%)→ PC 端必须显式选 `Win32RenderingMode.Wgl`
  - **两条 SPEC 里没写的顺序约束**(都已补进 §7.2 / §5.1):
    起播必须在 `lp_gl_init` 之后(否则 `vo/libmpv: No render context set.` 致命且不重试、
    静默黑屏);关停必须先拆 UI 再关核心
  - ⚠️ **反向验证 `lp_gl_swapped` 没复现**:见下面 S1.2c
- [x] **S1.2c** ✅ **`lp_gl_swapped` 的 18fps 说法已订正 2026-08-31**
  - Avalonia 侧 8 组(三档分辨率 × `block_for_target_time` 0/1 × `video-sync` audio/display-resample)
    + **SPIKE-1b 自己的裸 harness** 2 组,**全部无可测差别**;`estimated-display-fps` 开关都为空
  - 最可能是归因错位:SPIKE-1b §7 第 2 条(离屏 `eglSwapBuffers`)自己就写着
    「改成渲进纹理 FBO 之后**立刻正常**」—— 帧率是被第 2 条修好的
  - **做法不变**(继续调,代价为零),但 SPEC / SPIKE-1b 里那个数字已改成「未复现」
- [ ] **S1.11** 🔴 **Avalonia + WGL 的 FBO 重建崩溃**(挡着「用便宜的 WGL」这条路)
  - 现象:`OpenGlException: Unable to configure OpenGL FBO failed with error GL_NO_ERROR`
    抛在 `OpenGlControlBaseResources.BeginDraw(PixelSize size)`
  - 已归因:**纯 Avalonia 完全不碰核心层也复现(2/10,带 `--resize`)**,与 libmpv / 路径 B 无关;
    ANGLE 上 20 次 0 崩;渲完复位 GL 状态**无效**(1/10 vs 2/10,该代码已删)
  - 判据:在 Avalonia 12.x 上重测;查上游 issue;若确为上游 bug,评估能不能绕开
  - 不通过 → PC 端只能吃 ANGLE 的 CPU,或退 A2
- [ ] **S1.12** Avalonia **12.1.1** 上重跑 S1.2
  - 本次钉 11.3.20 是因为 SPEC §7.2 写的是「Avalonia 11」。12.x 的 `OpenGlControlBase`
    是否同签名、S1.11 的崩溃是否已修,都没测
  - 判据:同 S1.2 四条 + S1.11 的崩溃率
- [x] **S1.2a** 路径 B:图形字幕(PGS/SUP)能不能合成 ✅ **已结题 2026-08-30**
  - 结论:**能**。渲进自建纹理 FBO 也一样,6 个用例噪声基线全 0、字幕信号 2.2~2.8 万像素
  - 「纹理导致 PGS 不显示」这条**归因不成立**,B 未被 PGS 排除
  - 报告:`spikes/SPIKE-1a-PGS-render-api.md`(含实验设计、正负对照、5 个自己踩的坑)
- [x] **S1.2b** 路径 B 拿不到 `d3d11va` 零拷贝 ✅ **已结题 2026-08-31 —— 结论是拿不到**
  - WGL 与 **ANGLE(EGL over D3D11)** 都拿不到;判别器:同一 libmpv 走路径 A 能拿到 `d3d11va`
  - 根因:零拷贝要求解码器与渲染器共用同一个 D3D11 设备,走 GL 就跨了设备边界,只能 copy-back;
    render API **只有 OpenGL / SW 两种类型,没有 D3D11 类型**
  - **核显实测**(输出统一 1920×1080):**1080p60 满帧、4K24 满帧**;4K60 是这块核显的天花板,
    零拷贝的路径 A 在同机同片下丢帧数相近。代价是 CPU 不是可用性
  - 报告:`spikes/SPIKE-1b-zero-copy.md`
  - ⚠️ 本条曾写着「现代 mpv 移除了 ANGLE」「4K60 只渲出 12~14fps」——
    **那是第一版结论,SPIKE-1b 自己已经订正过**(测试台污染 + 拿字符串命中数当证据)。
    2026-08-31 同步订正本条,别再照抄
- [x] **S1.7** 方案 D(DirectComposition)✅ **已排除 2026-08-31**
  - libmpv 公开 API 给不出可被外部合成的 swapchain:render API 只有 OPENGL/SW 两种类型,
    `vo=gpu` 系列自己拥有 HWND 自己呈现;`--d3d11-composition` 探测返回 option not found
  - 澄清:Avalonia 的 `WinUIComposition` **不是 WinUI**,是 Win32 后端的呈现模式
    (底层 `Windows.UI.Composition`,操作系统合成器 API)。**选 B 或 A2 都不需要碰 WinUI**
- [ ] **S1.10** 🔴 **低端真机验证:路径 B 的 CPU 余量够不够**(决定要不要退 A2)
  - 判据:四核无风扇迷你主机 / 只有核显的轻薄本上,**4K24 满帧且 CPU 有余量**
  - 判据:**必须真机,不许靠估计** —— 本次测出的 30% 含测试台开销(Python 忙轮询 + 无垂直同步),
    同解码路径下 mpv 自有 VO 只要 12%,真实实现的期望值**未验证**
  - 不达标 → 退 A2(双顶层窗口,已在产验证,坑记录在 `docs/lessons/`)
- [ ] **S1.8** 独显对照:同一套矩阵钉到独显再跑一遍
  - 判据:先确认真的跑在独显上(回读 GPU 名),否则量的还是核显(R10 现场)
- [ ] **S1.9** 核显矩阵补 **HEVC 10-bit / HDR** 语料
  - 理由:本次是 H.264 8-bit;P010 每帧约 24 MB,往返字节更多,路径 B 只会更差
- [ ] **S1.3** 路径 B 性能实测
  - 判据:1080p60 与 4K60 各连续播 10 分钟;记录掉帧率、CPU%、GPU%、显存
  - 通过线:掉帧率 < 1%,CPU 占用与现有 Tauri 方案同量级(±20%)
- [ ] **S1.4** 路径 B 在 **Linux / X11** 上重跑 S1.2 + S1.2a + S1.3
  - S1.2a 在 Linux 上要重跑一遍:本次 PGS 实测只覆盖 Windows + Intel 核显 + 桌面 GL 4.6
- [ ] **S1.4b** 路径 B 在 **Linux / Wayland** 上重跑 S1.2 + S1.3 🔴
  - **这条不许跳过。** 强制 X11 的两条理由(自己摆顶层窗口 / `--wid` 不支持)
    在新架构下**都已失效**(`SPEC.md` §15.2),沿用旧结论 = 等于没调研
  - 判据:同 S1.2 / S1.3,外加 ① 分数缩放下画面不糊 ② 全屏 / 多显示器行为正常
  - 判据:**明确记录窗口位置能不能记忆** —— Wayland 上客户端定不了绝对位置,
    这会直接改写 `UI_PC.md` §3.3 的"位置记忆"那条
  - 出口:按 §15.2 的三分支决策规则给结论,**不接受"先按 X11 做"**
- [ ] **S1.5** 若 B 失败:实测路径 C(`MPV_RENDER_API_TYPE_SW`)在 1080p 下的可用性
  - 判据:同上口径,明确给出"C 能撑到多少分辨率"
- [ ] **S1.6** 若 A/B/C 全败:验证 WinUI 3 + `SwapChainPanel` 备选
  - 判据:同 S1.2;并评估 Linux 的替代方案(GTK4 / Qt)

> **结论产出:** Windows/Linux UI 框架的最终选择。这是本 SPIKE 的唯一目的。

### 🔴 SPIKE-2 · Go 三宿主 FFI

> **工具链已就位(2026-08-31)。** `bash scripts/fetch-toolchain.sh` 拉 Go 1.27.0 + zig 0.16.0
> 到 `.toolchain/`(项目级,不装进系统),`source scripts/env.sh` 激活,
> `bash scripts/check-toolchain.sh` 自检。**`c-shared` + cgo 已实测编得出、ctypes 调得进**
> (导出 `lp_abi_version` 返回 1)。详见 `AGENTS.md` §2.2。
>
> ⚠️ S2.1 写的是「**八个**函数」,而 `SPEC.md` §5.1 现在是 **13 个**(视频通道拆成两条之后)。
> 按 13 个做,这行文字待订正。

- [x] **S2.1** ✅ **已结题 2026-08-31** —— Go 核心导出 `SPEC.md` §5.1 的 **13 个**函数
  (不是原文写的「八个」;视频通道拆成两条之后是 13。PE 导出表核准,非字符串搜索)
  - 含 `lp_abi_version()`(§5.0):版本错配走拒绝路径,不是崩溃 ✅
  - 工程 `spikes/s2/lpcore/`,零第三方依赖(全标准库)
- [x] **S2.2** ✅ **已结题 2026-08-31** —— C# `LibraryImport` 调通,**35 条判据全绿**
  - 报告:`spikes/SPIKE-2-go-ffi.md`;复跑一条命令,退出码 = 不通过条数
  - 覆盖 §5.0 ABI / §5.2 信封与 `ts` / §5.3 所有权 / §5.4 错误模型 /
    §5.7 流式与取消 / §5.10 panic 边界 / §5.11 队列与 eof
  - 🔴 **产出一条改契约的发现**:光有 `defer recover()` 不够,
    命令必须跑在 `lp_init` 建立的 **worker 池**上 —— 否则运行时故障(非显式 panic)
    在 .NET 宿主下直接 `0xC0000409` 硬杀进程,**且没有任何日志**。已写进 §5.10
  - 🔴 **第二条发现**:内存判据不能用进程内存(正常 23.7 MB vs 故意漏 24.5 MB,分不出来),
    必须数 `alloc`/`free`。已写进 §5.3
- [x] **S2.2b** ✅ **已结题 2026-08-31** —— 视频通道 B 接上真 libmpv,Avalonia 端到端跑通
  - cgo 链法已定:**`zig cc` 直接链仓库自带的 MSVC 格式 `mpv.lib`**,不需要 mingw 格式,
    也不需要退回运行时 `LoadLibrary`
  - `AvaloniaProbe` 改成**只用 13 个契约导出**(比原计划的「一行不改」更有价值:
    UI 侧不再有任何 mpv 类型,属性读取走 `player.prop` 命令)
  - 判据全过:1080p60 满帧 59.9 / 丢帧 0 / `d3d11va-copy`;A 3.05 / B 324.5 / C 1.84 / D 通过
  - 性能与 Rust 桩同量级:1080p60 **25%** vs 18~24%;4K24 **20%** vs 13~26%
  - 顺带在核心层带上 **N1(magicyuv CVE)** 防护 —— 地基里就带,别等以后补
- [ ] **S2.2c** 长跑内存验证:100 万次 `lp_call`/`lp_free`
  - 判据:`cstrOutstanding` 恒在个位数;**不看进程内存**(§5.3 已写明它测不出来)
- [ ] **S2.3** Android:NDK 交叉编译 4 个 ABI → JNI 薄层 → Kotlin 调通
  - 判据:同上;**并把编译脚本固化成 `scripts/build-core-android.sh`**
  - 已知坑:`CGO_ENABLED=1` + NDK toolchain 首次配置耗时;裸 `go build` 会失败
- [ ] **S2.4** 事件线程模型验证:Kotlin/C# 各起一个专用线程死循环 `lp_next_event`
  - 判据:UI 线程无阻塞;`lp_shutdown` 后线程能干净退出(不是靠 kill)
- [ ] **S2.5** 测量 Go 侧产物体积与冷启动
  - 判据:每 ABI 的 `.so` 体积;`lp_init` 到首个事件的耗时(目标 < 200ms)
- [ ] **S2.6** (Apple 可后置)`c-archive` → xcframework → Swift 调通

### 🔴 SPIKE-3 · quickjs-go 跑现有插件

- [x] **S3.1** ✅ **已结题 2026-08-31** —— `ctx.*` 子集实现(log/util/errors/sleep/http/
  storage/ui/emby/extensions/sources),**权限门控是真的**(没声明就不注入)
  - 语料的 `onEnable` 里 HTTP 调用数都是 0,所以**单独补了异步链路测试**:
    本地 httptest 服务器,验 `ctx.sleep` 真等够 + `ctx.http.get` 拿到 200 +
    响应体解析 + storage 往返 + **出网带了我们的 UA**
- [x] **S3.2** ✅ **3/3 全过** —— `m3u` / `uhdnow` / `vod` 全部加载并 onEnable 成功,
  **没有一个因为 JS 语言特性失败**;`m3u`、`vod` 都真的注册了数据源
  - 🔴 产出三条改契约的宿主约束(已写进 `SPEC.md` §9.2):
    ① 必须 `runtime.LockOSThread()`(不锁 5/5 全败,报 `Maximum call stack size exceeded`)
    ② 异步结果必须投回 JS 线程再造值(goroutine 里造的对象是 `undefined` 且不报错)
    ③ 回调注册放 JS 侧(Go 侧存 = 借用引用被释放两次 = 段错误)
- [x] **S3.3** ✅ 内存上限 + 看门狗
  - 32MB 上限拦住 128MB 分配(`out of memory`),宿主存活
  - 死循环 2.0s 被中断(阈值 2.0s),宿主存活。**阈值用 2s 只是让测试跑得快,
    机制与 30s 一致**;30s 是产品取值不是机制
- [x] **S3.4** ✅ `await` 一个等 3s 的 UI 不被 2s 看门狗杀掉,返回 `survived`
  - 关键:**deadline 必须在每次泵作业时重置**。反向注入去掉它 → 「被看门狗中断」
- [ ] **S3.5** 补齐语料:本次只跑了绿色包里带的 3 个,**不是「现存全部插件」**
  - 判据:插件仓库里的其余插件逐个跑一遍,出同样的通过/失败表
- [ ] **S3.6** 测数据源的三个函数(`listDir` / `search` / `resolvePlay`)
  - 判据:返回值形状与 `MediaSourceBackend` 对齐;这才是插件真正干活的地方
- [ ] **S3.7** 一个插件崩了之后,**同进程里其它插件**还能不能正常工作

> 若 S3.2 失败率高:备选是把插件引擎留在一个独立进程里(仍用 QuickJS,走 IPC),
> 或评估 `goja`。**不接受**"让插件作者改代码"这个选项。

### 🟠 SPIKE-5 · `osd-overlay` 能不能撑住平滑滚动弹幕

新增(2026-08-30)。背景与论证见 `SPEC.md` §7.5 与 `knowledge/DANMAKU_CARRIER.md`。

弹幕渲染在新架构必须重建(Canvas 依赖 WebView,原生 UI 下没有)。
选定方案是 `osd-overlay` + `format=ass-events` —— 它**不占字幕轨**,双语字幕能保住。
但 mpv 手册明确写 **`Timing is unused`**:时间轴由宿主自己算并每拍重发。

**唯一的观感风险点就是这个"每拍重发"扛不扛得住。**

- [ ] **S5.0** 🔴 **先照抄 uosc_danmaku 的四条做法,别自创**
  (负责人 2026-08-31:「uosc_danmaku 用成熟方案即可」。拆解见 `knowledge/DANMAKU_CARRIER.md` §1.7)
  1. **双层 overlay**:滚动一层、顶/底一层,用 `z` 控堆叠(`render.lua:8,118-135`)
  2. **按 `time-pos` 线性插出当前 `\pos`**,每拍重发(`render.lua:20-52`)
  3. **`vf append @danmaku:fps=fps=N` 抬高回调频率**(`render.lua:196`)——
     `osd-overlay` 的回调频率跟着视频帧率走,24fps 片源上弹幕会跟着卡,这是它的解法
  4. **`display-fps < 58` 或 `estimated-vf-fps > 58` 时跳过插帧**(`render.lua:196-203`)
  - 判据:S5.1~S5.4 全部在**照抄版**上跑;有任何一条要偏离,先写明为什么
  - 判据:**拿 uosc_danmaku 原版当对照组,不是当实现。** S5.2 压力测时并排跑一遍原版 ——
    它平滑而我们不平滑 = 慢的是我们的循环,不是 `osd-overlay` 这个方案
  - 前置事实(2026-08-31 实测,`spikes/s1-2/luaprobe/`):**libmpv 确实跑用户 Lua 脚本**
    (`LUAPROBE_SCRIPT_RAN`)、`mp.create_osd_overlay('ass-events')` **可用**
    (`LUAPROBE_OSD_OVERLAY=true`)、Lua **能起子进程**(`LUAPROBE_SUBPROCESS_STATUS=0`)。
    所以「直接跑原版」在 Windows 上是可行的,对照组这条不需要额外造轮子
  - ⚠️ **但不照抄它的进程**,理由三条:① 它用 curl 子进程自己拉网络,绕过我们的三条 UA 道 /
    线路优选 / 弹弹Play 签名与配额管理(「配额被刷完」那次就是自己烧的)
    ② 它自带匹配逻辑,换过去会丢掉我们修好的三个静默失败与重写的匹配算法
    ③ **安卓 libmpv(`media-kit/libmpv-android-video-build`)有没有编 Lua 未验证** ——
    没有的话弹幕要写两份,正是 `SPEC.md` §7.5 想消灭的那件事
- [ ] **S5.0b** 查实安卓 libmpv 有没有 Lua
  - 判据:同 S5.0 的探针在安卓真机上跑一遍;**别用 `strings` 猜**(本仓栽过:
    没有 smb 的 DLL 里照样有 "Samba")
- [x] **S5.1** ✅ **已结题 2026-08-31** —— 核心层 `danmaku.go`,双层 overlay 每拍重发
  - 判据达成:视频区近白像素占比 **0.00%(关)-> 7.9%(开 500 条)**。
    基线正好是 0,这个 A/B 是决定性的
  - 实现选择:`osd-overlay` 用**命令数组的位置参数**发,**避开 `mpv_node` 那套 cgo 结构体**
- [~] **S5.2** 压力测 —— **数字部分已做,观感部分没做**
  - 已测(4K24,12 秒 × 2 遍):500 条 → **24.0 fps 满帧、丢帧 0**、CPU 30~36%
    (基线 21%);1000 条 → 22.7 fps、丢帧 +21
  - 🔴 **关键数字:弹幕位置每秒只真变 18~19 次**,被 `time-pos` 的更新频率钉住
    (循环本身转了 52.6 拍/秒 —— **不是我们的循环慢**)
  - 🔴 **`vf append fps=60` 能把它抬到 30~32 次/秒,但丢帧 0 → 477、CPU +25 点。
    核显上不能默认开**
  - ❌ **没做:「录屏逐帧看」。** 19 次/秒对滚动弹幕够不够是观感问题,数字答不了
  - ❌ 没做:5 分钟长跑(本次每档 12 秒)
- [ ] **S5.3** 与倍速联动:0.5x / 2x / 4x 下滚动速度正确
  - 判据:对应现有实现里"没有倍速因子则 2x 播放时弹幕按 1x 爬"那条
- [ ] **S5.4** seek / 暂停 / 换片时弹幕正确清空与重建
- [ ] **S5.5** 安卓真机重测 S5.2(移动端 GPU 与桌面差距大)
- [ ] **S5.6** 若观感不过关:评估退路
  - 退路 A:三端各写一个 Canvas 等价物(三份代码三份 bug)
  - 退路 B:降低重发频率 + 用 `\move` 让 libass 自己插值(但 `Timing is unused` 下 `\move` 是否生效**未确认**,要测)

> **不要**因为"社区方案 uosc_danmaku 用的就是这条路"就跳过实测 ——
> 那是 Lua 脚本在桌面上的场景,与我们三端(含移动端 GPU)的负载不同。

### 🟢 SPIKE-4 · Compose TV 焦点

- [ ] **S4.1** 用 `androidx.tv.material3` 复刻现有 `ui/tv/pages/EpisodePage.tsx` 的布局
  - 选它的理由:1158 行,是 TV 端最复杂的页面,横向行 + 纵向列 + 弹层都有
- [ ] **S4.2** 遥控器 D-pad 全向走一遍
  - 判据:不出现"按↓原地不动";横向行下方的纵向元素能被走到
  - 对照:现有实现踩过"行矩形被负 margin 撑高 32px 导致候选被删"
- [ ] **S4.3** 焦点记忆:进二级页再返回,焦点回到原位
  - 判据:`Modifier.focusRestorer` 生效,无需手写
- [ ] **S4.4** 统计:复刻这一页用了多少行 Kotlin
  - 判据:与 1158 行 TSX + 556 行 `Focus.tsx` 对比,给出比值

---

## 2. 阶段 1 · 骨架

依赖:SPIKE 全部完成。

### 核心层

> **一条命令跑全部:`bash scripts/check-core.sh`**(四关:go vet+test / 出库 /
> FFI 契约 / C# 契约测试)。推之前跑它。

- [x] **B1.1** ✅ `core/ffi`:13 个导出 + C 头文件 —— **有门禁钉住**
  - 判据达成:`scripts/check-ffi-contract.py` 把生成的 `lpcore.h` 与 `SPEC.md` §5.1
    的代码块逐条比(函数集合 / 顺序 / 返回类型 / 参数类型),**13 vs 13 全一致**
  - **先红验证**:把 `lp_gl_render` 的 `flipY` 改成 `int64_t`,门禁报
    「SPEC (…, int32_t) vs 头文件 (…, int64_t)」;还原后绿
  - 两处刻意允许的差异已写进脚本注释:参数名不比;`const char*` 视同 `char*`
    (**cgo 表达不了 const**,是工具限制不是我们的选择)
- [x] **B1.2** ✅ `core/bus`:命令**注册表** + 分派 + 事件队列
  - 判据达成:`system.ping` 往返 ✓;未注册的命令返回 **`E_INVALID`** 不 panic ✓
  - 注册表而不是大 switch:命令归属跟着实现走。现有 Rust 版最痛的一处正是
    「桌面与安卓两份手工拷贝的命令层」(N9/N10/N11 的共同根因)
- [x] **B1.3** ✅ `lp_cancel` 真取消 —— 发出 `debug.slow` 后立即 cancel,收到 `ok=false`
- [x] **B1.4** ✅ 内存所有权压测 —— **100 万次** `lp_call`+`lp_free`:
  分配 1000020 / 释放 1000020 / **未释放 0**
  - ⚠️ 判据原文写「RSS 平稳(±5MB)」。**已改成数 alloc/free** ——
    SPIKE-2 §4.3 实测证明进程内存测不出泄漏(正常 23.7MB vs 故意漏 24.5MB)
- [x] **B1.5** ✅ panic 隔离 —— `debug.panic` 后进程存活、该 seq 收到 `E_INTERNAL`、日志里有栈
  - ★ 关键不是 `defer recover()`,是**命令必须跑在 worker 池上**(SPIKE-2 §4.2)
- [x] **B1.6** ✅ `core/paths` + `core/config`:**能读现有 config.json**
  - 判据达成:拿**真实**配置(5493 字节)读入再回写,**5493 字节,一个字节没丢**
  - 硬规矩(写进包注释):文件不存在 = 新装返回空配置;**文件存在但解析失败 =
    返回错误,绝不返回空配置**。后者正是 Rust 版那条真故障
    ——「.ok() 吞掉 → unwrap_or_default() → 用户所有账号一次性消失且不报错」
  - **先红验证**:把「解析失败退回空配置」注入回去,测试立刻红
  - 未移植的键(accounts/prefs/proxy/…)**原样透传**,保存不抹掉 ——
    否则用户看到的是「升级之后我的 XX 设置没了」
  - 🔴 夹具**全部占位符**:真配置里有服务器地址与 token,一个真值都不许入库
- [ ] **B1.7** `core/net/localserve`:`/img` 路由 + token 校验 + src 白名单
  - 判据:带 token 能取图并落缓存;不带 token 401;白名单外的 src 404
- [x] **B1.8** ✅(Windows 部分)`core/player` 最小可播 —— 1080p60 满帧 60.1、`d3d11va-copy`
  - 安卓 / Linux 部分未做
- [ ] **B1.9** `lp_set_surface(0,...)` 解绑是同步阻塞的 🔴 **现在是桩**
  - 判据:Android 上快速反复旋转屏幕 100 次,不崩
  - 注:现有 Rust 版**现在就漏着**(N5),别再漏一次

### 各端空壳

- [ ] **B2.1** Android:Compose 空页 + SurfaceView + JNI 薄层,能播 🟡
- [x] **B2.2** ✅ Windows:Avalonia + 视频层,能播**且半透明控件盖在上面**
  - 判据达成(对真 `core/` 跑的):视频区逐像素帧间差 2.56 / 最小品红偏移 325.8 /
    叠加区帧间差 1.20 / 每帧都在;60.1 fps
  - 探针 `spikes/s1-2/AvaloniaProbe` **只用 13 个契约导出**,UI 侧没有任何 mpv 类型
- [ ] **B2.3** Linux:与 B2.2 同一份 C# 代码跑通 🟡
- [ ] **B2.4** 三端各自的绑定层**代码生成器**(从 `COMMANDS.md` 生成) 🟡
  - 判据:生成的 Kotlin / C# 类型能编译;新增一条命令只需改 `COMMANDS.md` + 重跑生成

### 阶段 1 出口

- [ ] **B3** 冻结 `SPEC.md` §5 与 §7.2
  - 判据:三端都跑通;契约文档标记 FROZEN;之后改动走变更记录

---

## 3. 阶段 2 · 录制与对账设施

依赖:B1.2、B1.6。

> **一条命令跑对账:`cd core && go run ./cmd/diffcheck`**;也已接进
> `bash scripts/check-core.sh` 的第 5 关。

### 🔴 D1 的形态改了 —— 因为 Rust 侧没有 HTTP 收口

原计划是「在 Rust 版加 `LP_RECORD=<dir>` 旁路,录真实流量」。**查下来做不到便宜地实现:**

- `crates/core/src/http.rs` 只**发客户端**(`client()` / `emby_client()` / `preload_client()`),
  调用方拿到 `reqwest::Client` 之后各自 `.get()/.post()` —— **没有单一的 send() 可以 hook**
- 要 hook 就得把 `reqwest::Client` 换成自家包装类型,那是**改一大片业务代码**,
  违反 D1 自己写的「不改任何业务逻辑」

**改成的形态:共享语料 + mock 上游 + 两侧各跑一遍。**

```
语料(一份 JSON) = 上游怎么答 + 调哪条命令 + 期望输出
        ↓                        ↓
   mock 上游(明文 HTTP)   ──►  Go 侧实现  ──► 归一化 ──► diff
```

好处:不改 Rust 一行、完全确定性、语料可以手写也可以来自真实录制。
代价:**期望值的来源(provenance)必须自己保证**。

- [ ] **D1** 语料的自动生成:从 Rust 侧产出期望值 🔴
  - 现状:期望值是**手工**从 Rust 自己的测试语料搬过来的(每条用例的 `provenance` 字段写明出处)
  - 判据:加一个只调 `crates/core` 公开 API 的 bin,吃同一份语料、吐 JSON;
    **不碰业务逻辑**,只是一个 runner
  - 不做这一步的风险:手工搬运会漏、会错,而错了之后对账是「Go 等于我以为的 Rust」
- [ ] **D2** 录制/语料脱敏
  - 判据:语料里 grep 不到 token / 密码 / Cookie / IP / 域名;同一原值映射到同一占位符
  - 现状:手写语料**本来就没有真值**,但自动生成之后必须补这一关
- [x] **D3** ✅ Go 侧 `cmd/diffcheck` 回放器
  - 起 mock 上游 → 调 Go 实现 → 归一化 → 逐路径 diff。路径形如 `[0].series_name`,报告能直接定位
  - **语料里没写的路径回 599 不回 404** —— 404 是业务里合法的状态,会被当成「上游说没有」
  - **缺 `provenance` 的用例直接判不通过** —— 没有出处的用例只是在断言「Go 等于我以为的 Go」
- [x] **D4** ✅ 差异归一化 —— 走 JSON 往返,map 键序不影响结果
  - 还没做:时间戳 / 随机 id 的归一化(现在的语料里没有,等有了再加)
- [x] **D5** ✅ 已知差异白名单
  - **每条必须带 issue 与到期日**;**过期的白名单不再生效**,工具会把它当失败 ——
    那正是它存在的意义:逼人到期回来看一眼,而不是永久遮着
- [x] **D6** ✅ **先红验证(三种注入各验一次)**
  | 注入 | 报出来的 |
  |---|---|
  | 改坏字段名 `series_name` → `seriesName` | 「多出字段 seriesName / 缺字段 series_name」 |
  | 漏掉一处空串折 null(`path`) | 「[0].path 值不同:期望 null,实得 ""」 |
  | 给 `views` 加上屏蔽过滤(「顺手修好」的诱惑) | 「(根) 长度不同:期望 2,实得 1」 |
  还原后全绿。
- [~] **D7** 接进门禁 —— 已进 `scripts/check-core.sh` 第 5 关;**还没进 GitHub workflow**
  - 判据:PR 上自动跑;红了不许合

### 对账用例(7 条,全部有对应的注入验证)

| 用例 | 盯的是什么 | 注入什么会红 |
|---|---|---|
| `emby.views · 被屏蔽的库必须原样返回` | 屏蔽在 `fetch_items` 那条路生效,**媒体库网格不走那条** —— 滤掉了用户就再也解除不了 | 给 `views` 加上过滤 → 「长度 2 vs 1」 |
| `emby.views · 字段映射` | ticks 换秒 / 空串折 null / MediaSources 取第一个的 Video 流高度 | 改坏字段名、漏一处空串折 null |
| `emby.counts · UserId 必须带` | 不带 UserId 服务端把用户看不到的库也算进去(实测差 39 部电影 / 259 部剧 / 870 集)。**mock 按 path+query 精确匹配,漏了直接打不中** | 去掉 `UserId` → HTTP 599 |
| `emby.latest · 裸数组也要过滤屏蔽` | Latest 端点返回裸数组不走 `fetch_items`,**过滤要自己补一句** | 去掉那句 → 「长度 1 vs 2」 |
| `emby.items · 复筛 + total 要改` | 某 fork 忽略 Genres/Years/评分下限;复筛动过手 total 必须改成本页条数,否则前端画出永远翻不满的页码 | 不改 total → 「total 期望 1 实得 3276」 |
| `emby.resume · 只靠 series_id 命中` | 屏蔽判据 2(名字故意对不上,**只有 series_id 能生效**) | 停用 series_id 判据 → 只有这条红 |
| `emby.resume · 跨服靠名字命中` | 屏蔽判据 3(id 全对不上,只有剧名对得上) | 停用剧名判据 → 只有这条红 |
| `emby.detail · 背景图与演职人员排序` | **背景图在 `BackdropImageTags` 数组里不在 `ImageTags` 里**;Taglines 取第一条且空串折 null;导演优先且其余保持服务端顺序(必须稳定排序);空名字的演职人员要滤掉 | 读 `ImageTags["Backdrop"]` → 「has_backdrop 期望 true 实得 false」;不给导演提前 → 「people[0].id 期望 p-c 实得 p-a」;不滤空名字 → 「people 长度 3 vs 4」 |
| `emby.search · 服务端无视类型筛选` | 某 fork 带 SearchTerm 时把 IncludeItemTypes/ParentId 一起忽略 —— **只信服务端过滤 = 「包括集」开关是个摆设且不报错** | 去掉客户端复筛 → 「长度 2 vs 3」 |
| `emby.person · 生平与出生地为空` | 生平空是**常态**(空串,不是 null);出生地空串要折 null,否则前端画出一行空的「出生地:」 | 不折空串 → 「birth_place 期望 null 实得 ""」 |
| `emby.isAdmin · 缺 Policy 判否` | 宁可少给按钮;而且这个位**不从登录响应取** —— 老账号不会再走 login,取了会永远判成非管理员 | 缺 Policy 判是 → 「期望 false 实得 true」 |
| `emby.getFilters · 一个分面挂掉不拖垮面板` | 某 fork 上 /Tags、/OfficialRatings、/Years 全是 404;各自吞错返回空,**报错才是错的**(整块面板红字重试,而重试永远不会有结果)。年份靠两次 Limit=1 探针铺区间 | 失败退回 nil 切片 → 「tags 期望数组实得 nil」 |
| `emby.itemMedia · 正则标中的必须是真会被播的` | preferred 那条 = 详情页/播放器显示的「当前版本」,和真起播同端点同批同匹配文本;匹配文本要补 4K/8K 口语档位;VideoRange 的 "Unknown" 折 null;非 A/V/S 流不进卡 | 恒标第一条 → 「[0]/[1].preferred 反了」;不补 4K → 「[1].preferred 期望 true」;Unknown 原样透 → 「期望 null 实得 "Unknown"」 |
| `emby.favorites · 空列表给 [] 不是 null` | **Go 的零值切片序列化成 `null`,Rust 的 `Vec::new()` 是 `[]`** —— 前端拿 null 直接 `.map()` 抛错,透明窗口下是一片黑且不报错 | 退回 `var out []Item` → 「(根)期望数组实得 nil」 |
| `emby.seasons · 没有季时返回空` | 有些剧没有季(单季番剧直接挂集),调用方要回落到「拿 seriesId 当 parent 拉集」—— 不回落是「点进去一集都没有」且不报错 | —— |

> **两条 resume 用例是拆出来的,拆的理由值得记:**
> 第一版只有一条,屏蔽项的 `name` 和分集的 `SeriesName` 恰好相同 ——
> 于是「按名字命中」先兜住了,`series_id` 那条判据**根本没被测到**。
> 停用 series_id 之后用例照样绿。**它一直在用错误的理由通过。**
> 是注入把它揪出来的。

> **另一条方法论教训:注入必须能编译。**
> 我第一次停用 series_id 判据时留下了「声明未使用」的编译错误,`go run` 直接失败,
> 而我只 grep「不通过」—— 把编译失败读成了「没红」。
> **「注入之后没红」有两种可能:护栏没在测东西,或者注入压根没跑。**
> 先确认注入跑起来了,再下结论。

> **它已经抓到过一个真差异。** 移植 `date_updated` 时我写成了「空串也回退到 DateCreated」,
> 而 Rust 是 `date_last_media_added.or(date_created).filter(非空)` ——
> `Option::or` 只在 **None** 时取后者,`Some("")` 会直接短路。
> 对账报:`[0].date_updated 值不同:期望 null,实得 "2024-01-01T00:00:00Z"`。
> 这在 UI 上是「本该没有更新时间的条目显示了入库时间」,排序会跟着错。
> **黄金实现里看起来像 bug 的地方也不许顺手改。**

---

## 4. 阶段 3 · 核心层移植

依赖:阶段 2 完成。顺序见 `MIGRATION.md` §2。

**每个模块的完成定义:** Go 实现 + 单元测试(含先红验证)+ 差分对账通过 +
`COMMANDS.md` 里相关命令标 ✅。

### 4.1 基础

- [ ] **C1** `core/config` + `core/paths` 🔴
  - 判据:真实旧 `config.json`(脱敏)读进来再写出去语义等价;
    **先红**:故意改一个字段名,测试变红
  - 特别核对:`SourceKind` 小写、`active_line` 是下标、密码字段不进日志
- [ ] **C2** `core/httpx` 🔴
  - 判据:三个客户端的**空闲超时**都设了(不是整体超时);
    UA 三分口径有测试钉住(Emby / 预取 / 默认不许串)
- [ ] **C3** `core/secrets` + CI 注入门禁
  - 判据:漏传任一凭据时构建**失败**(不是静默通过)
- [ ] **C4** `core/update`
  - 判据:`/releases` 顺序被打乱的夹具下仍取到最大版本;版本单调性门禁

### 4.2 Emby

> **进度(2026-08-31):`core/emby` 已落地首页 + 媒体库 + 详情页那条链** ——
> views / listItemsPage / listLatest / listResume / listNextUp / listFavorites /
> listCollections / counts / itemDetail / seriesSeasons / seasonEpisodes /
> blockedList / setBlocked,共 **14 条命令**,9 条对账用例全绿且每条都有注入验证。
> **2026-08-31 续:**再落 12 条 —— login / logout / search / similarItems /
> personDetail / personItems / setFavorite / setPlayed / isAdmin / refreshItem /
> scanLibraries,外加 `emby.views` 补上命令层的 `include_blocked` 过滤
> (之前只做了核心层的「不滤」,命令层那半漏了 = 屏蔽的库照样出现在首页)。
> **共 26 条命令**,12 条对账用例 + 3 组 Go 单测,全绿。
>
> **2026-08-31 再续:**listItems / listRandom / getFilters / itemMedia 四条,
> 外加新建 `core/media` 包(选轨/选版本的偏好正则)。**共 30 条命令**,
> 15 条对账用例 + 4 组 Go 单测。
>
> ★ 这一批里对账当场抓到一个**移植期的系统性坑**:Go 的零值切片序列化成 JSON
> `null`,而黄金实现(`Vec::new()`)给的是 `[]`。前端拿到 null 直接 `.map()` 会抛错,
> 在透明窗口下就是**一片黑且不报错**。已修 `facet` / `yearRange` / `fetchAllPaged`
> 三处,并留了一条专门钉空列表形状的用例。**后续每移植一个返回列表的函数都要过一眼这条。**
>
> 剩下的 8 条各自压着一个还没移植的子系统,要先做那个:
> aggregate*(多账号,等 core/config)/ watchHistory*(观看记录模块)/
> ranking*(排行榜模块)/ reportProgress(播放会话状态)/
> currentSession、relogin(账号存储,等 core/config)。

- [ ] **C5** `core/emby` 主体 🔴
- [ ] **C6** `core/media`:版本 / 音轨 / 字幕正则筛选
  - 判据:**核心层返回 preferred 标记**;三端不得各自回落 `versions[0]`;
    判据是 mpv 命令行里的 MediaSourceId,不是命令入参
- [ ] **C7** `core/blocklist`
  - 判据:屏蔽单条 / 屏蔽整库两条路径分别验;媒体库网格**不滤**(否则解除不了)
- [ ] **C8** `core/history` + 跨服续播
- [ ] **C9** `core/serverbatch` + 深链
- [ ] **C10** `core/ranking`
  - 判据:fetch 错误不吞,以 `E_UPSTREAM` 上抛

### 4.3 源

每个源一条,判据统一为:登录 / 列目录 / 搜索 / 解析播放 四项差分对账通过。

- [ ] **C11** `core/source` 接口 + 注册表 🔴
  - 判据:`take_rotated_credentials` 等价机制存在并有测试
    (一次性 refresh_token 轮换后必须落盘)
- [ ] **C12** `core/source/local`(含越狱闸) 🟢
- [ ] **C13** `core/source/smb`(含本地 Range 桥)
  - 判据:桥回 `Connection: close`;mpv 能直接播
- [ ] **C14** `core/source/webdav`
  - 判据:子目录不 404(href 双前缀);XML 实体被拆事件时不丢字符
- [ ] **C15** `core/source/ftp`
  - 判据:`MLST` 兜底不产生假文件
- [ ] **C16** `core/source/openlist`
- [ ] **C17** `core/source/quark`(含 TV 变体)
  - 判据:二维码作为 base64 PNG 原样透出,不二次编码
- [ ] **C18** `core/source/aliyun`
- [ ] **C19** `core/source/baidu`
- [ ] **C20** `core/source/pan115`
  - 判据:secp256k1 签名与 Rust 版**逐字节一致**
- [ ] **C21** `core/source/pan139`
  - 判据:`Authorization` 本地计算结果与 Rust 版一致
- [ ] **C22** `core/source/pan189`
  - 判据:RSA 加密结果与 Rust 版一致;短信路径 `dynamicCheck` / epd 槽位对齐
- [ ] **C23** `core/source/feiniu`
  - 判据:authx 签名一致
- [ ] **C24** `core/source/anirss` —— **【范围已砍 2026-08-31】只做播放,不做管理台**
  - 负责人:「Ani-RSS 我们只对接播放功能。clone 其项目,读源码里面的和播放视频相关的 API,
    只做相关的。」于是它从「媒体源 + 远程管理台」变成**只是媒体源**
  - **只需上游两个端点**(第三个不要,理由见 `knowledge/ANIRSS.md` §2.5.1):
    `POST /api/playList`(列剧集)、`GET /api/file?filename=<base64>&s=<token>`(取流,支持 Range)
  - 🔴 判据:**`filename` 走内容嗅探**,不按版本号分支 —— 上游 v3.1.23 把它从 base64 改成明文,
    我们一直没跟(N15)。**不能用「含 `/` 就是路径」判,标准 Base64 含 `/`**
  - 判据:外挂字幕的 `url` 是同款明文路径,要自己包成 `/api/file?...` 才能给 mpv 挂
  - 判据:**不要用 URL-safe Base64** —— 上游解的是标准字符集,且它自己做了 `" "→"+"` 兜底
  - 判据:token 走查询参数 `s=`,不走请求头(mpv 拿不到请求头,`SPEC.md` §6)
  - 判据:**先红** —— 拿一段明文路径的 `PlayItem` 喂进去,断言嗅探把它编码了;
    再拿一段 base64 的,断言没有二次编码
- [ ] **C24b** 管理台那半(增删改订阅 / 改服务端配置 / 下载进度 / 日志)**不移植**
  - 判据:`COMMANDS.md` 里 `anirss.*` 只保留播放路径需要的那几条,其余标注「本次不做」
  - 连带影响:**N16**(Ani-RSS 一整块功能域未接)自动作废 —— 本来就不做了;
    **N17**(`anirss_proxy_image_url` 做好没用上)降级为「封面需要时再说」
- [ ] **C25** `core/source/pluginsrc`
  - 判据:`$sourceServer` 展开表在账号变动后同步;未同步时 fail-closed

### 4.4 网络(收益最大的一块)

- [ ] **C26** `core/net/prefetch` 🔴
  - 判据(逐条,每条一个测试):
    - [ ] 边收边吐:开着多线程加载能在 10s 内起播(不是等整段收完)
    - [ ] seek 不回退边界
    - [ ] 尾部走直连,不占同槽
    - [ ] 响应带 `Connection: close`
    - [ ] 302 只跟随一次
    - [ ] 环形缓存占用恒 = 上限
    - [ ] 并发读写无 TOCTOU 串数据
    - [ ] 段被挤掉后能被重拉(不饿死)
  - **禁止**靠调小 CHUNK_SIZE 让测试变绿(会有几个假绿)
- [ ] **C27** `core/net/preload`
  - 判据:预热 8MB 后起播,**复用同一句柄**(不新起,否则缓存被删);
    起播耗时与现状同量级
- [ ] **C28** `core/net/cf`
  - 判据:路由改写表与代理句柄同步开关
- [ ] **C29** `core/net/localserve` 完整化(所有路由 + 安全约束)
- [ ] **C30** `core/companion`

### 4.5 播放器

- [ ] **C31** `core/player` 完整化 🔴
  - 判据(逐条):
    - [ ] 外挂字幕等 `FILE_LOADED` 且在事件线程挂载,`sub-add` 返回值不许吞
    - [ ] 判播完读 `eof-reached`(`keep-open` 下 `END_FILE` 永不发)
    - [ ] ASS 字幕字号用 `sub-scale` 不用 `sub-font-size`
    - [ ] seek 闩不拿粘性值和目标比
    - [ ] `FILE_LOADED` 前的 seek 排队不丢
    - [ ] 换片时 `ready` 在 play 之前复位
    - [ ] 302 跳转流删 `multiple_requests=1`
    - [ ] 双显卡钉独显(Windows)
    - [ ] `vd=-magicyuv` 拉黑(CVE-2026-8461)
    - [ ] 安卓 `sub-fonts-dir=/system/fonts`
    - [ ] 显式设 `gpu-shader-cache-dir`
    - [ ] 日志级别由环境变量门控(`log-file` 会把 mpv+ffmpeg 钉在 debug 级)
  - **删除**:独立顶层窗口对齐、z 序钩子、`WM_WINDOWPOSCHANGED` 子类化、
    `set_overlay_top_inset`、`is_overlay_host`(约 700 行)

### 4.6 弹幕与同步

- [ ] **C32** `core/danmaku`
  - 判据:`errorCode` 被检查(429 不许显示成"未找到");
    `/match` 的 `fileHash` 非空;`file_name` 传真实文件名;
    多密钥换行分隔时逐个尝试
- [ ] **C33** 弹幕 ASS 生成
  - 判据:插值**带倍速**;颜色按 BGR;走 `secondary-sid`
- [ ] **C34** `core/danmaku/proxy`
  - 判据:路径穿越测试不拿环境当断言
- [ ] **C35** `core/sync/trakt`
- [ ] **C36** `core/sync/bangumi` + matcher
  - 判据:单集写入 subject 位是字面 `-`;请求带 UA(不带会吃 CF 403)
- [ ] **C37** `core/sync/calendar`

### 4.7 插件

- [ ] **C38** `core/plugins/engine`(quickjs-go) 🔴 · 依赖 SPIKE-3
- [ ] **C39** `core/plugins/ctx` 宿主 API 全量
- [ ] **C40** `core/plugins/manifest` + `registry`
  - 判据:registry 键 snake_case、author 为字符串;产物可复现(无时间戳、强制 LF)
- [ ] **C41** `core/plugins/permission` + 授权流
- [ ] **C42** `core/plugins/manager` / `state` / `storage` / `worker` / `installer`
- [ ] **C43** `core/plugins/contributions` + 声明式 UI 描述
  - 判据:描述格式冻结并写进 `COMMANDS.md`,三端渲染器按同一份实现
- [ ] **C44** 逃生舱资源服务(`/plugin/<id>/*`)
  - 判据:独立 origin;跨 origin 拿不到宿主上下文
- [ ] **C45** 全量插件回归
  - 判据:SPIKE-3 的语料再跑一遍,通过率 100%

### 4.8 其余

- [ ] **C46** `core/download`
  - [ ] **C46.1** 已下载条目的播放路径(`SPEC.md` §7.6)
    - 判据:播本地文件,但进度**同时**回传原服务器与本地记录;
      换台设备能续上
    - 注:这是**功能缺口不是移植**,现有实现没有这条路
- [ ] **C47** `core/translation`(桌面独占,优先级最低但**不砍**)
  - 判据:`system.capabilities` 在非桌面平台标为不支持;命令返回 `E_UNSUPPORTED`
- [ ] **C48** `source.formSchema`:源表单字段定义下沉核心层 🔴
  - 判据:三端渲染器共用;新增一个源类型只改核心层一处

### 4.9 阶段 3 出口

- [ ] **C49** `COMMANDS.md` 全部 266 条标 ✅
- [ ] **C50** 差分对账全绿且在 CI 常驻
- [ ] **C51** 四方契约测试(COMMANDS ↔ Go 注册表 ↔ 三端绑定)通过

---

## 5. 阶段 4 · UI

依赖:阶段 3。三端可并行,**Android 优先**。

### 5.1 三端共同前置

- [ ] **U0.1** 页面功能集合表(`SPEC.md` §8.1)转成各端的逐页验收清单
- [ ] **U0.2** 设计令牌:三端各自的 design token 对齐(颜色 / 间距 / 字号语义一致,
      不要求像素一致)
  - **PC 端的值已经定死**:见 `UI_PC.md` §1.1(直接抄现有 `ui/shared/tokens.css`)。
    另外两端以它为语义基准,各自映射到平台习惯
- [ ] **U0.3** 错误码 → UI 行为的映射表实现一次,三端各自复用
  - 判据:`E_UNSUPPORTED` **不弹错**(静默降级)

### 5.2 Android(手机 + TV)

- [ ] **U1.1** 双形态分流(`UI_MODE_TYPE_TELEVISION`)
- [ ] **U1.2** 首登闸口 / 添加服务器(渲染 `source.formSchema`)
- [ ] **U1.3** 首页
  - 判据:滚动流畅;**不要复刻**现有的 `content-visibility` 与滚动锚定打架的问题
- [ ] **U1.4** 媒体库 + 筛选面板
- [ ] **U1.5** 详情页族(剧 / 影 / 季 / 集 四张分开设计)
- [ ] **U1.6** 播放页 + OSD
  - 判据:遮挡率按现有 OSD 重构的结论(38.5% 量级),**不是**照抄竞品
- [ ] **U1.7** 搜索(全局 / 库内 / 包括集)
  - 判据:三个入口都点一遍;"包括集"默认关,分集单独一栏横版
- [ ] **U1.8** 聚合视界
- [ ] **U1.9** 收藏 / 服务器管理 / 线路
- [ ] **U1.10** 文件浏览页
- [ ] **U1.11** 影视目录页(**与文件浏览是两套页面,不复用**)
- [ ] **U1.12** 下载页
- [ ] **U1.13** 插件市场 / 已装 / 设置(手机形态)
- [ ] **U1.14** 排行榜 / 日历 / Ani-RSS(手机形态)
- [ ] **U1.15** 设置页
- [ ] **U1.16** TV 形态:全页面用 `androidx.tv` 复刻
  - 判据:每页 D-pad 全向走通;焦点记忆生效
- [ ] **U1.17** 开屏
  - 判据:图标边距在 drawable 内部;Android 12 上不放大满幅
- [ ] **U1.18** 深浅色主题
  - 判据:`values-vXX` 与 `values-night-vXX` **两份都建**(`-night` 压过 `-vXX`)
- [ ] **U1.19** 签名验证
  - 判据:`unzip -l` 能看到 META-INF 证书 + "APK Sig Block 42" 魔数
    (`keystore.properties` 写了 ≠ 用了)
- [ ] **U1.20** Compose UI Test 覆盖关键路径

#### Android 平台职责(`SPEC.md` §8.5)

这一批**不是可选的打磨**,是 Android 上"能不能当播放器用"的下限。

- [ ] **U1.21** `MediaSession` + 通知栏控制
  - 判据:锁屏 / 通知栏能暂停、上下集;标题封面正确
  - 现状参照:安卓端已有 `set_now_playing`,新架构下它是 UI 层的事
- [ ] **U1.22** 前台服务 + 后台播放
  - 判据:切后台后音频不断;通知常驻;杀进程能干净收尾(先 `lp_set_surface(0)` 再销毁)
- [ ] **U1.23** 音频焦点
  - 判据:来电 / 别的 App 播放时自动暂停,结束后按设置恢复
- [ ] **U1.24** 屏幕常亮
  - 判据:播放中不息屏;暂停 / 退出后恢复
- [ ] **U1.25** 画中画
  - 判据:Home 键进 PiP,PiP 里能暂停;退出 PiP 回到播放页且不重新起播
- [ ] **U1.26** 深链 `linplayer://`
  - 判据:intent-filter 注册;冷启动与热启动两条路径都能拿到 URL 并调
    `account.parseDeepLink`
- [ ] **U1.27** 运行时权限
  - 判据:通知权限(Android 13+)、本地文件访问(若做本地播放)
  - 注:本地播放在安卓侧现在**没做**(只有 INTERNET 权限),这次要一并补,
    且必须有越狱闸
- [ ] **U1.28** 旋屏 / 分屏 / 折叠屏形变时 surface 生命周期正确
  - 判据:快速反复旋转 100 次不崩(对应 B1.9)

### 5.3 Windows / Linux

> **逐条判据见 [`UI_PC.md`](UI_PC.md)。** 本节只列任务,不重复规格。

#### 地基(在任何一页之前做完)

- [ ] **U2.0a** `Tokens.axaml`:两套主题的色 / 字 / 间距 / 圆角 / 阴影 / 滚动条
  - 判据:值与 `UI_PC.md` §1.1 逐项一致;**浅色下玻璃底控件不是深底深字**
  - 判据:两套主题的对比度自动检查(正文 ≥ 4.5:1,次要 ≥ 3:1)
- [ ] **U2.0b** 动效 token + 转场目录(`UI_PC.md` §2)
  - 判据:只有 `dur-fast/med/slow` 三档,代码里搜不到别的时长常量
  - 判据:**跟随系统"减少动画"生效**
  - 🔴 判据:验证 `UI_PC.md` §2.3 第 1 条 —— 给页面根挂 `RenderTransform` 动画后,
    断言右键菜单与 toast 的**屏幕坐标不变**。验不过就沿用"只淡入"
- [ ] **U2.0c** 组件库 + 八态矩阵(`UI_PC.md` §4.1)
  - 判据:每个可交互组件的 `default/hover/focus/pressed/selected/disabled/loading/error`
    都有样式;**焦点环只在键盘导航时出现**
- [ ] **U2.0d** 图标集:`ui/desktop/app/icons.tsx` 转 `PathGeometry` 资源
  - 判据:**不引入图标字体**;图标颜色跟随墨阶

#### 外壳与窗口

- [ ] **U2.1** 主窗 + 自绘标题栏(`ExtendClientAreaToDecorationsHint`)
  - 判据:最大化时按钮不被溢出顶掉(现有 Win 教训:无边框最大化四周溢出 8px)
- [ ] **U2.2** 独立播放窗口 + 常驻标题栏
  - 判据:**不需要**给视频让位 36px;Alt+F4 行为正确
- [ ] **U2.3–U2.15** 逐页实现 —— **逐页契约见 `UI_PC.md` §7(18 页)**
  - 参照:`docs/desktop-drafts.html` 的既有设计
  - 判据:每页都过 `UI_PC.md` §11.1 的九条清单
- [ ] **U2.16** 右键菜单 / 卡片悬停动作 / 看完打勾 / 未看数角标
- [ ] **U2.17** 快捷键 + 按键提示层
- [ ] **U2.18** 设置页 **4 组 14 项**(`UI_PC.md` §7.15)
  - 判据:全页零二次确认(现有设计如此,不要顺手加)
  - 判据:越界值由核心层拒绝并**回滚**,不在 UI 夹紧
  - 判据:「已屏蔽的内容」能解除**所有**隐藏类功能(含被屏蔽的整个库)
- [ ] **U2.19** 绿色包打包
  - 判据:数据全在 exe 同级 `userdata/`;WebView2 profile 与进程 TEMP 单独按住
- [ ] **U2.20** Linux 跑通同一份代码
  - 判据:外部播放器选择器的后缀过滤**按平台给**(`*.exe` 在 Linux 上滤空列表)
- [ ] **U2.21** Avalonia.Headless 截图对账测试

#### 桌面平台职责(`SPEC.md` §8.5)

- [ ] **U2.22** 播放中屏幕常亮(`SetThreadExecutionState` / Linux 抑制空闲)
- [ ] **U2.23** 深链 `linplayer://` 注册(Windows 注册表 / Linux `.desktop`)
  - 判据:冷启动与已在运行两条路径都能收到
- [ ] **U2.24** 退出时不留残留进程 🔴
  - 判据:关窗后进程列表干净。**根因参照**:现有的残留不是 mpv 也不是子进程,
    是 exe 自己 —— 播放窗藏起来不销毁,事件循环永远等不到"最后一个窗口关闭"。
    新架构要在退出路径上显式关掉每个窗口 + 兜底超时
- [ ] **U2.25** 单实例 + 第二次启动把参数转交给已有实例
  - 判据:双击深链时不起第二个进程(第二个进程会抢同一份 `userdata/`)
- [ ] **U2.26** OAuth 回调落地(Trakt / Bangumi)
  - 判据:回调既可走本地 HTTP 端点也可走深链;两条路都测

### 5.3a Windows 专项(`SPEC.md` §16)

> 本组每一条都是**只有 Windows 才有**的问题。逐条判据见 §16。

- [ ] **W1** 数据根三落点 + **探针判据**(`SPEC.md` §16.1) 🔴
  - 判据:把包放进 Program Files 跑一次,数据**不许**被静默重定向到 VirtualStore
  - 判据:**必须真写一个探针文件再删** —— 只看"建目录成功"会被 UAC 虚拟化骗过去
  - 判据:落到 `SystemFallback` 时**设置页显眼提示**,绝不悄悄换地方
  - 判据:兜底用本地应用数据目录,**不用漫游目录**(几 GB 缓存跟着域账户漫游)
- [ ] **W2** 迁移钉在数据根首次解析上,不是启动流程里的一句显式调用
  - 判据:反向注入 —— 把迁移挪到配置加载之后,断言测试变红("升级后服务器全没了")
  - 判据:测试构建下有守卫(`cargo test` 曾真的搬走过开发机上的账号)
- [ ] **W3** 🔴 堵住绕过数据根的暗道(§16.2)——
  **负责人 2026-08-31 明确要求:「数据存到解压出来的文件夹,不存 AppData,不喜欢到处拉屎。」**
  - 判据:进程临时目录已重定向,且**排在数据根首次解析之后**
  - 判据:**不许劫持系统用户目录语义**
  - 判据:换栈新增的四条落点逐个按住 ——
    ① libmpv `gpu-shader-cache-dir`(旧栈已踩过)② libmpv config-dir / watch-later
    ③ .NET 单文件解包目录(默认解到 `%TEMP%`)④ .NET 崩溃转储 / 日志
  - 判据:核心层**不许调** `os.UserConfigDir` / `os.UserCacheDir` / `os.TempDir` 定落点
- [ ] **W3b** 🔴 **外溢探针做成发布门禁**(§16.2 判据一节)
  - 判据:快照用户目录 → 跑完整冒烟(启动 → 登录 → 浏览 → 详情 → 起播 → seek → 切字幕 → 退出)
    → 再快照 → **断言新增为空**
  - 判据:白名单每条写明**为什么挪不动**,不许写"这个不重要"
  - 判据 🔴:**先红** —— 故意让某处写一个用户目录文件,探针必须报红。
    不注入就不知道它是不是在空跑
  - 模板现成:`scripts/check-toolchain.sh`(同一方法 2026-08-31 在工具链上抓到 3 处外溢,
    **没有一处能从文档看出来**,全靠 diff)
- [ ] **W4** 🔴 WebView2 降级为可选(§16.4)
  - 判据:启动路径**一行都不碰** WebView2
  - 判据:运行时缺失时,主 UI 正常,只有插件自定义 UI 被禁用**并说明原因 + 给去处**
  - 判据:profile 显式指进数据根(不指定它自己在系统目录建,实测 126 MB)
  - 判据:`system.capabilities` 如实反映,UI 据此隐藏入口
- [ ] **W5** 窗口几何四条(§16.5) 🔴 **挂真 exe 量,headless 量不到**
  - 判据:150% / 175% 缩放下位置正确(混用逻辑/物理像素的表现是偏 1.5 倍)
  - 判据:先隐身建窗拿真实外框尺寸再摆位(外框每边宽出一圈,建前量不到)
  - 判据:主窗最小化时开播放窗,播放窗**不跑到屏幕外**(哨兵值 -32000)
  - 判据:**最大化 → 点全屏 → 真的全屏**;退出后回到最大化。契约测试钉住单一出口
- [ ] **W6** 最大化溢出 8 px:**先实测状态**(§16.5 ⑤)
  - 判据:最大化后量右上角按钮是否完整可见。**两种结论都要写下来**
  - 注:根治方案在**已被删除的旧运行时**里,当前仓库没有补偿代码 —— 别照抄旧结论
  - 注:自检工具必须先声明 per-monitor DPI 感知再截图,否则量到的偏移是假象
- [ ] **W7** 文件名净化 + 🔴 长路径(§16.6)
  - 判据:下载标题带 `:` 的剧,文件名正确落盘
  - 判据:**条目 id 后缀不许去掉** —— 它顺带挡住保留设备名(CON/PRN/NUL/COM1…)和结尾点
  - 判据 🔴:应用清单声明长路径支持,并**在最低支持版本上验证真的生效**
  - 判据 🔴:超限时报"路径太长"并带上实际长度,不是笼统的"下载失败"
  - 判据 🔴:截断上限**按剩余预算算**,不是固定 60
- [ ] **W8** 🔴 文件锁定语义(§16.6)
  - 判据:播放中删除该片的预取分段 / 下载任务,失败要能容忍并重试
  - 判据:**删不掉时不许静默跳过** —— 至少计数,否则环形缓存无限增长,
    "占用恒等于上限"这条承诺就破了
- [ ] **W9** 路径大小写:用路径当键的地方一律先规范化
  - 判据:同一份缓存两端命中一致(不一致时**两边都不报错**,只是白下一遍)
- [ ] **W10** 系统下限算出来(§16.7)—— **目标已定 2026-08-31:Windows 10**
  - 判据:落成一个**具体 build 号**,不是"Win10 及以上"。取 .NET / Avalonia / libmpv 三者下限的最大值
  - 判据:三个来源逐个查实。**"目标定了"不等于"验过了"**
  - 判据:实际导入表打进构建日志
  - 判据:**在最低支持版本的干净虚拟机上跑启动冒烟**,作为发版门禁
- [ ] **W11** 绿色包内容断言重新设计(§16.8)
  - 判据:必需项逐个存在 + 禁止项(符号 / 源码 / 夹具 / 含凭据文件)不存在
  - 判据:**体积上下限都要有** —— 上限防打多,**下限防打少 / 打了个残废的**
- [x] **W12** ✅ 代码签名裁决(§16.3)—— **已裁决 2026-08-31:方案 A,维持不签**
  - 便携包分发。⚠️ 澄清过一次:便携包解决的是**写入权限**,**规避不了 SmartScreen**
    —— MOTW 随 zip 解压传播给包内 exe(Win10 1803 起)。选 A 是接受代价,不是代价不存在
- [ ] **W12b** 不签的两条必做项(裁决的配套,不是可选)
  - 判据:下载页与首次运行指引写清会遇到什么、为什么。
    用户看到"Windows 已保护你的电脑"而我们一个字没提,他的第一反应是"这是病毒"
  - 判据:发布产物提供校验和

### 5.3b Linux 专项(`SPEC.md` §15)

> **Windows 上过了不代表这些过了。** 本组每一条都对应一个「只有真跑 Linux 才现形」的坑。

- [ ] **L1** libmpv 运行时 `dlopen` + 三个候选名(`libmpv.so.2/.1/.so`)
  - 判据:在只有 `.so.1` 和只有 `.so.2` 的两个系统上都能起
  - 判据 🔴:**CI 反向断言 —— `libmpv` 不许出现在 `DT_NEEDED` 里**
  - 判据 🔴:**CI 正向断言 —— 二进制里 grep 得到 `libmpv.so.2`**
  - 判据 🔴:**构建机故意不装 libmpv 开发包**,并在 CI 里写明这是故意的
- [ ] **L2** 系统没装 mpv 时的首启提示
  - 判据:给出各发行版的安装命令,**不是"加载失败"**
- [ ] **L3** 双显卡钉独显(PRIME 环境变量) 🔴 **新做,不是移植**
  - 判据:**回读 mpv 日志里的 GPU 名字**确认没跑核显,不是"设置了环境变量"
  - 判据:`system.gpuInfo` 把实际设备名透出到设置页
- [ ] **L4** 深链:desktop 条目 + MIME 关联,**落在包外**,每次启动重注册
  - 判据:把解压目录整个挪走再启动,深链仍指向新位置
- [ ] **L5** 文件选择器:选"程序"时**不加后缀过滤**
  - 判据:能列出 `/usr/bin/mpv`
- [ ] **L6** 自更新三条(`SPEC.md` §15.7) 🔴
  - 判据:可执行文件名**不带 `.exe`**
  - 判据:解包后**补 `0755`** —— 不补的表现是"更新看着成功了,App 再也起不来"
  - 判据:`$ORIGIN` rpath **回读确认**真的写进 ELF 了
- [ ] **L7** 打包:zip(不是 tar.gz)+ 资产名含 `linux` + strip 排在符号上传之后
  - 判据:未 strip 与已 strip 的体积都打进日志(实测老版本未 strip 191 MB)
- [ ] **L8** 系统下限:`DT_NEEDED` 清单打进构建日志
  - 判据:新增任何硬依赖在日志里一眼可见
  - **附带决策**:插件逃生舱的 WebView 能否做成**可选依赖**(`SPEC.md` §15.6)——
    能的话基础包的系统下限会显著放宽
- [ ] **L9a** 屏幕常亮(两端各自做,**不依赖 mpv 的 `stop-screensaver`**)
  - 前置:SPIKE-1 里顺手量一次 `stop-screensaver` 在 render API 模式下还灵不灵
    —— render API 下 mpv 没有自己的窗口,那条路大概率断,而且断了不报错
  - 判据:播放中不息屏;**暂停 / 退出必须撤销**(不撤销 = "看完片电脑再也不息屏了")
  - 判据:Linux 接口不存在时**静默降级**,不弹错
- [ ] **L9b** 🔴 **MPRIS**(Linux,新做)
  - 判据:接上后媒体键 / 锁屏 / 通知中心能控制播放
  - 优先级高于 Windows 的 SMTC —— 它一次把桌面环境的整套媒体控制全接上
- [ ] **L10** 单实例锁:**和数据根绑定**,不是和可执行文件绑定
  - 判据:两份不同目录的解压包可以同时跑;崩溃留下的陈旧锁能自愈
- [ ] **L11** 至少两个发行版上的启动冒烟(一个定下限、一个验 soname)

### 5.4 Apple(后置)

- [ ] **U3.x** macOS 优先,页面集合同上;iOS 只做到"能装"

---

## 6. 阶段 5 · 切换与下线

- [ ] **X1** 新旧包并存发布,灰度
- [ ] **X2** 数据迁移真机验证
  - 判据:旧 `config.json` 被新版直接读;账号 / 线路 / 偏好 / 观看记录零丢失
- [ ] **X3** 真机跑满一周零 P0
  - 判据:附 issue 列表证据
- [ ] **X4** 删除旧栈(`ui/` `apps/` `crates/`) 🔴 **单向门**
  - 判据:单独 PR;commit message 写清运行天数;附对账全绿 CI 链接

---

## 7. 横切任务(贯穿全程)

- [x] **T1a** `COMMANDS.md` 生成器(现阶段:从 Rust 注册表生成)
  - `scripts/gen-commands.py` / `--check` 校验
  - 已做先红验证:篡改表格 → `--check` 退出 1;还原 → 退出 0
- [ ] **T1b** 生成器接进 CI
  - 判据:PR 里加了命令但没重跑生成器,CI 红
- [ ] **T1c** 生成器切到 Go 注册表(阶段 3 中)
- [ ] **T1d** 四方比对:`COMMANDS.md` ↔ Go 注册表 ↔ 三端绑定
  - 判据:任何一方缺一条即红
- [ ] **T1e** `system.capabilities` 自洽性测试
  - 判据:`features.X == false` ⟺ 对应命令在 `unsupported` 里
- [ ] **T2** CI:编译期凭据门禁
  - 判据:漏传任一凭据构建失败
- [ ] **T3** CI:Android libmpv LFS 校验
  - 判据:`lfs: true` + ELF 魔数校验(否则 APK 里是指针文本)
- [ ] **T4** CI:版本单调性门禁
- [ ] **T5** CI:体积与冷启动回归门禁
  - 判据:超过上限即红(上限来自 SPIKE-2 的实测)
- [ ] **T6** 仓库卫生
  - 判据:构建产物全部 gitignore;**禁用 `git add -A`**;
    脚本能拉的产物不入库(但删之前必须先给 CI 补 fetch)
- [ ] **T7** 提交红线扫描
  - 判据:推前扫 IP / 域名 / 端口 / 账号 / 密码 / token;
    这类值只放不进版本控制的配置文件,仓库里只留 `*.example`
- [ ] **T9** 核心层 panic 边界(`SPEC.md` §5.10) 🔴
  - 判据:注入 `debug.panic` 命令 → ① 进程存活 ② 该 seq 收到 `E_INTERNAL` ③ 日志里有栈
  - 判据:**先把 recover 注释掉确认这条测试会红**(否则它测的是"没 panic")
- [ ] **T10** 事件队列背压(`SPEC.md` §5.11)
  - 判据:模拟宿主停止消费 10 s,`result` 一条不丢、`player.status` 只留最新、
    `log` 丢弃计数正确透出
  - 判据:队列非空且 5 s 没被取过时写 warn 日志
- [ ] **T11** ABI 版本协商(`SPEC.md` §5.0)
  - 判据:三端绑定里的 `LP_ABI` 与核心层常量比对,不等即红
  - 判据:拿一个故意改了 ABI 的库启动,得到**明确报错**而不是崩溃
- [ ] **T12** 出网规格落地(`SPEC.md` §14.1)
  - 判据:三条 UA 道**按行为验**(打本地测试服务器读 `User-Agent` 头),不比对常量
  - 判据:**空闲超时而不是整体超时** —— 构造一个"慢但一直在出字节"的上游,
    拉满 60 s 不许被判死;再构造一个"连上就不出字节"的上游,30 s 内必须失败
  - 判据:护栏测试共用全局超时值时**必须加锁串行**
- [ ] **T13** 存储规格落地(`SPEC.md` §14.2)
  - 判据:配置写入是**临时文件 → fsync → rename**;写到一半杀进程,重启后配置完好
  - 判据:损坏的 `config.json` 被改名保留而**不是静默重置**
  - 判据:`system.storageUsage` 各项与实际占用一致
- [ ] **T14** 诊断包脱敏(`SPEC.md` §14.3)
  - 判据:构造含已知假凭据的配置,导出后断言那些字符串**一个都不出现**
  - 判据:**这条必须先红过**
- [ ] **T15** 遥测脱敏(`SPEC.md` §14.8)
  - 判据:构造一条含假 token 的错误消息,断言发送前那个值不出现
  - 判据:**这是和 T14 不同的一条路径**,两条都要测;关掉遥测后**一个字节都不发**
  - 判据:追踪头传播目标列表为**空**(绝不给用户自己的服务器请求塞遥测头)
- [ ] **T16** 自更新 applier 链路(`SPEC.md` §14.9) 🔴
  - 判据:Windows 上从旧版跑到新版一次成功,且 `userdata/` 零丢失
  - 判据:「以 applier 身份跑」的判断在**进程入口第一行** ——
    排在数据根重定向之后会推出错误的数据根
  - 判据:版本选择**按语义版本取最大**,不依赖上游返回顺序;
    喂一份"更旧的排在第一位"的真实数据,断言不会降级伪装成升级
  - 判据:解包时越界条目**丢弃不报错**(一个坏条目不许挡住整包)
- [ ] **T17** 备份 / 配置搬迁(`SPEC.md` §14.9)
  - 判据:导入是**合并不是覆盖**;两个二维码出口的**纠错级一致**
  - 判据:导出文件不进日志、不进诊断包
- [ ] **T18** 双端 CI 矩阵(`SPEC.md` §15.8)
  - 判据:两端都**出真产物并跑一次启动冒烟**,不能只 build 就算过
  - 判据:平台专属测试各归各位 —— 反斜杠/盘符只在 Win 跑、符号链接逃逸只在 Linux 跑,
    并在代码里写明"它只在某平台跑,所以不是死代码"
  - 判据:Linux runner **钉 ubuntu-22.04**,并在 CI 注释里写明 glibc 向后不向前兼容
  - 判据:主程序名一致性有测试钉住(曾出现"Windows 绿、Linux 在打包步骤炸")
- [ ] **T8** 文档同步
  - 判据:`SPEC.md` 的 FROZEN 段落任何改动都要有变更记录条目

---

## 8. 待决问题

这些没有答案就往下做会返工,但也不阻塞当前阶段。列在这里定期回看。

| # | 问题 | 何时必须有答案 |
|---|---|---|
| ~~Q1~~ | ~~Windows/Linux 最终用 Avalonia 还是 WinUI3+GTK4?~~ **已定 2026-08-31:Avalonia。** S1.2 四条判据全过,`spikes/SPIKE-1c-avalonia-path-b.md`。Linux 侧待 S1.4 复验(不推翻选型,只可能加平台限定) | ✅ 已关闭 |
| ~~Q2~~ | ~~插件的声明式 UI 描述格式要不要趁机重新设计?~~ **已定 2026-08-31:不重新设计。** 维持 v2 的 JSON 描述树 + 四类贡献点 —— 改格式就撕毁 `SPEC.md` §9.1「现有插件包不重新打包即可运行」,已发布插件全部作废 | ✅ 已关闭 |
| Q3 | 三端的设计语言是各自原生,还是统一一套自绘?(**PC 端已定:沿用现有 token,见 `UI_PC.md` §1**;另两端待定) | U0.2 之前 |
| ~~Q4~~ | ~~迁移期 Rust 版冻结多久?~~ **已定 2026-08-31,答案比「冻结功能」更彻底:迁移期间 GitHub 不发版、不发包。** 见下方「发布通道冻结」 | ✅ 已关闭 |
| ~~Q5~~ | ~~TV 端要不要支持插件?~~ **已定 2026-08-31:不支持**,维持现状。遥控器焦点导航下插件的声明式 UI 与逆向登录表单基本没法用,且要多写一个焦点渲染器 | ✅ 已关闭 |
| ~~Q6~~ | ~~Whisper 要不要拆成可选下载?~~ **已定 2026-08-31:拆。** 主包不带模型,首次使用时下载到 `userdata/models/`。`translate.*` 是桌面独占 9 条(安卓 0 条),模型几百 MB~GB,不拆等于让不用这功能的人也下 | ✅ 已关闭 |
| Q7 | iOS 的分发渠道选哪个? | **前提已澄清 2026-08-31:苹果端是「暂不做」不是「彻底不做」,SPEC 里的 Apple 段落保留。** 所以 Q7 继续挂着,阶段 6 之前答 |
| ~~Q8~~ | ~~弹幕载体是否改用 XML?~~ **已定 2026-08-31:不改。** 维持 `SPEC.md` §7.5.1(XML 只作导入/导出),渲染照 uosc_danmaku 的成熟做法,见 S5.0 | ✅ 已关闭 |
| ~~Q9~~ | ~~超分档位要不要引入新模型 / 要不要持久化?~~ **已定 2026-08-31:两个都不动。** 2026-07-20 已加过第四族「锐化专精」+ ArtCNN;「档位不持久化是故意的」有明确记录,重开等于推翻自己 | ✅ 已关闭 |
| ~~Q10~~ | ~~Ani-RSS 的 51 条命令能不能收敛?~~ **已定 2026-08-31:不是收敛,是砍范围 —— 只对接播放功能。** 见 §4.7a | ✅ 已关闭 |

### 已裁决(2026-08-31)

| # | 裁决 | 出处 |
|---|---|---|
| **R12 Windows 代码签名** | **不签**(方案 A,便携包分发)。⚠️ 澄清:便携包解决的是**写入权限**,**规避不了 SmartScreen** —— MOTW 随 zip 解压传播给包内 exe。首次运行指引 + 发布校验和因此是必做项 | `SPEC.md` §16.3 |
| **数据落点** | 数据全在 exe 同级 `userdata/`,**不写 AppData**。新栈四条落点已点名;判据是**外溢探针门禁**(快照 → 冒烟 → diff → 断言用户目录零新增),不是自觉 | `SPEC.md` §16.2、新增风险 R15 |
| **Windows 最低版本** | **目标 Win10**。但要落成一个具体 build 号并在干净虚拟机上验过 —— 「目标定了」不等于「验过了」 | `SPEC.md` §16.7 |
| **Q8 弹幕载体** | 不改,照 uosc_danmaku | `SPEC.md` §7.5.1、S5.0 |

### 发布通道冻结(Q4 的答案,2026-08-31)

**负责人原话:「迁移期间 GitHub 不发版、不发包。本地构建测试好了,再推到 GitHub,
增加新工作流、去掉旧工作流,重新发版发包。」**

这比「Rust 版功能冻结」更彻底 —— 它把「要不要给 Rust 版修 P0」这个问题**整个消掉了**:
迁移期间没有任何东西发出去,现网就是当前这一版,不动。

| 阶段 | 发布通道 | 开发方式 |
|---|---|---|
| 迁移期间 | **GitHub 不发 release、不发包** | 本地构建、本地测试 |
| 切换时 | 一次性:**加新工作流 → 去旧工作流 → 重新发版发包** | —— |

**三条实施注意,每条都对应过一次真实故障:**

1. 🔴 **版本号单调性。** 发布通道停了一段时间再重开,新版本号**必须大于最后一个已发布版本**。
   仓库重组曾把版本号静默顶退(`1.0.0` → `0.1.0`),表现是**老用户永远收不到更新**且没人报错。
   切换那一刻要有单调性门禁挡着(`SPEC.md` §11.3)。
2. **「不发版」≠「关掉所有工作流」。** 检查类工作流(`check-android.sh` / `check-commands.sh` /
   `check-workflows.sh` / 契约测试)守着的是**对账基准**,迁移期间照样要跑 ——
   Rust 版仍然必须能本地构建,阶段 2 的 `LP_RECORD` 录制就靠它。
   停的是 **release / 出包**那条,不是检查那条。
   > 这一条是我按上下文补的实施细节,不是负责人原话。**理解错了请纠正。**
3. **新工作流不许丢老工作流里的三样东西**(丢了都是 CI 全绿而功能静默残废):
   编译期凭据(`check-workflows.sh` 已设闸门)、Android libmpv 的 `lfs: true` + ELF 魔数校验、
   脚本现拉的产物(删 job 必查 `needs` 悬空)。

**代价要写明白:迁移期间现网用户拿不到任何更新,包括 P0。** 这是负责人的决定,记在这里。

---

> Q9 / Q10 的评估分别在 `knowledge/DANMAKU_CARRIER.md`、`knowledge/UPSCALING.md`、
> `knowledge/ANIRSS.md`。**看完评估再决定,别拍脑袋。**
