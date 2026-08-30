# 插件系统 / 插件市场 / 插件仓库

**这个领域最容易踩的坑:**
1. **`httpAllowedHosts` 是 fail-closed**:空/缺省 = 拒绝所有主机;而 resolve 出来的是动态 CDN host,穷举白名单必漏,要用通配子域。
2. **registry 的两条硬契约(键 snake_case、`author` 是字符串)一违反就整条插件从市场消失且零报错** —— 官方源曾被 build.py 七行代码静默清空。
3. **新加的宿主 ctx.ui 能力必须让用户重新构建 App**,只更新插件会退化成旧形态。
4. **资源站不是文件树**,别复用网盘文件页去打补丁。
5. **插件类改动只有挂真机端到端才现形**,编译绿+单测绿是常态。

> 本文件共 **5** 条。每条都标了它的原记忆文件名与类型;正文按原样搬运,未做压缩或改写。

## 本页条目

- 插件 v2 市场与声明式 UI — `plugin-v2-market-ui.md`
- 插件仓库 v2 重写 — `plugin-repo-v2-rewrite.md`
- VOD 资源站插件 — `vod-source-plugin.md`
- UHD 插件 — `uhd-plugins.md`
- UHD 测试账号 — `uhd-test-account.md`

---

### 插件 v2 市场与声明式 UI

> 原记忆:`plugin-v2-market-ui.md` · 类型:`project`

**插件市场 + 声明式 UI 已接入 PC 端(2026-07-23)**。侧栏「插件」独立入口(不在设置里),
三页签:发现 / 已安装 / 插件源。规格与偏离见 `docs/PLUGINS_V2_PLAN.md` 的 P1 段。

**外观口径**(调研 VSCode/JetBrains/Obsidian/Raycast/Figma/Jellyfin/Kodi/HACS 后定):
- 卡片网格发现 + 密列表已装(HACS:已装置顶)
- 深色靠灰阶分层不靠阴影(Raycast)——正好是本仓库 token 原样
- 启用前弹权限清单,一行一条人话,词表**由核层 `plugin_permission_catalog` 透出**,前端不许抄
- 同类产品**共同缺的两个洞**是我们的差异点:①「第三方源」信任徽章 ②启用后一句「去哪用」
- 开发者入口(装本地 ipk / 挂开发目录)放最下面一行小字(Obsidian)

**关键教训:这一轮 7 个 bug 全是编译绿+单测绿,只有挂真机 CDP 端到端才现形。**
共性是「两边都不报错,只是功能不对」:
- 运行时 `register` 整条顶掉 manifest 静态声明 → 数据源丢 name/auth 表单
- 贡献点要的权限两处口径不一致 + `onEnable` 错误被 `let _ =` 吞 → 插件"已启用无错误"但面板空白
- `register` 收非对象描述照单全收编个 `ext_N` 幽灵贡献(API 形状不一致:extensions 是
  (kind,描述),sources 是 (源id,描述),写混很自然)
- 面板 handler 返回 null 时不刷新 → 点按钮没反应
- registry 条目全解析失败报「0 插件 0 错误」→ 和空源无法区分
- 市场缓存只存插件不存错误 → 二次进入警告条消失
- 浮层 `inset:0` 被 z-index 90 自绘标题栏盖住 36px → 顶对齐的抽屉头被切(居中弹窗看不出来)

见 [挂真机 CDP 调试](methodology.md)(挂真机的手法)、[「待接」多半是谎](methodology.md)、
[每次都要出可测 exe](methodology.md)、[Stremio 插件协议源](sources.md)。

---

### 插件仓库 v2 重写

> 原记忆:`plugin-repo-v2-rewrite.md` · 类型:`project`

**`D:\LinplayerPluginsRepository` 已全量重写为 v2(2026-07-23,已推 main)**。
官方源现在真的能用:GitHub raw → 6 个插件 → sha256 校验 → 装 → 启用,真机跑通。

**官方源曾经全空的根因**:`tools/build.py::_author()` 把 manifest 的字符串包成
`{"name": …}` 写进 registry,而 v2 宿主 `RegistryPlugin.author` 是 `String` →
serde 整条失败 → 8 个插件**全部静默跳过** → 市场显示「0 插件 0 错误」,
和空源一模一样。**七行代码,两边都不报错。**

**registry 的两条硬契约**(违反就是整条插件从市场消失且无任何报错):
- 版本键是 **snake_case**(`package_url` 不是 `packageUrl`)
- `author` 是**字符串**

已在 `crates/core/src/plugins/registry_index.rs::the_real_official_registry_shape_parses_with_nothing_skipped`
把 build.py 真实产出的形状一字不改钉住 —— 这是跨仓库唯一的守门人。

**仓库的三条不显然的规矩**:
- **产物必须可复现**:打包时间戳/顺序/权限位钉死,索引里**没有任何时间戳**
  (试过 `datetime.now()` 每次刷新、git 提交时间新插件首提交时取不到值 → CI 必红)。
  `Path.write_text` 默认在 Windows 上把 `\n` 翻成 CRLF,必须显式 `newline="\n"`,
  否则跨平台产物不一致、**只有 CI 红**。
- 图标构建期压成 data URI 内联(零额外请求、不受图床可达性影响),因此有 64KB 上限。
- `validate_repo.py --selftest` 会往干净 manifest 里注入 23 条真实坏值,
  任何一条没让它变红就失败;同时钉住 `schemas/manifest.schema.json` 和
  `assets/permissions.js` 这两份规则副本不漂移。

~~插件目前只在 PC 可用~~ —— **2026-08-01 核实作废**。安卓侧 `apps/android/src/lib.rs` 现在
注册了整套 `plugin_*`(含 `plugin_market_install` / `plugin_sources`),`ui/mobile` 有 PluginsPage,
插件源在手机端能装能用(挂真机 CDP 验过,见 [VOD 资源站插件](plugins.md))。**仍然不可用的只有 TV**:
`ui/tv` 不渲染任何插件槽位。写 manifest 的 `targets` 时按这个填。
所以官方插件 `targets` 一律只写 `pc`。

见 [插件 v2 市场与声明式 UI](plugins.md)、[「待接」多半是谎](methodology.md)、[每次都要出可测 exe](methodology.md)。

---

### VOD 资源站插件

> 原记忆:`vod-source-plugin.md` · 类型:`project`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。

2026-08-01 落地。**纯插件,宿主 Rust 一行没动** —— `MediaSourceBackend` 三方法 +
`plugin_source.rs` 的 JS 桥已经够用(Stremio 早证明过)。代码在
`D:\LinplayerPluginsRepository\plugins\com.linplayer.vod\`,抄的是 `com.linplayer.m3u`。

##### v2 重做:资源站不是文件树(2026-08-01 当天推翻 v1)

v1 复用了 `NetdiskPage`(网盘文件页),因为插件数据源的契约只有
`{id,name,isDir,isVideo,size,thumb,raw}`。用户列的六条毛病**全是这一个决定的症状**:
分类只能伪装成文件夹、翻页只能伪装成一个叫「下一页」的文件夹、「更新至17集」只能
拼进 name、打开只能是文件管理器的双击、页面就是一张文件表。**别在 NetdiskPage 上
打补丁,那条路越修越歪。**

v2 = 核层新加一套**影视目录契约** + 两端各一个新页面:

- 核层 `crates/core/src/source/mod.rs`:`MediaCategory/MediaCard/MediaPage/MediaDetail
  /MediaLine/MediaEpisode` + trait 三个默认方法 `categories / catalog / media_detail`。
  **没往 `SourceEntry` 加字段** —— 那会让 10 个网盘后端的 40 处构造点全跟着改。
  `MediaCard.badge/year/score` 必须是独立字段,这是整件事的由来。
- 命令 `source_categories / source_catalog / source_media_detail`(桌面+安卓各一份)。
- 前端 `VodPage`(PC/手机各一份)+ `SourceBrowsePage` 分流。
  **分流不能看 source_kind**(插件源的 kind 都是 `plugin:<id>/<src>`),要探一次
  `categories`;不支持的源返回 `__LP_UNSUPPORTED__` 前缀,前端据此静默换路。
- 插件 2.0.0 **故意不实现 listDir/search**(测试里有断言钉着)。搜索并进
  `catalog(keyword)`,否则搜索的翻页会漏写。

三个当天踩的坑:
1. **`plugin_enable` 报「internal null bytes at position N」= main.js 里有裸控制字符。**
   manifest 合规、包打得出、装得上,只有启用那一刻炸,报错完全看不出是源码问题。
   已在 `validate_repo.py` 加逐字节闸门(顺带拦 BOM)。
2. **`source_login` 只拿 `list_dir` 探连通性 → 影视目录型的源永远加不进服务器表。**
   已提成核层 `probe_backend`(两条通一条就算能用),两端共用 + 3 条单测。
3. 手机端页面**不能自己造 `position:absolute;inset:0` 的滚动层** —— `Page` 已经给了
   `.pg-body`,再造一层会盖住标题栏。另:手机是真页面栈,DOM 里同时有多个 `.pg-body`,
   CDP 里 `querySelector('.pg-body')` 取到的是别的 Tab 的隐藏页。

速度实测:`ac=detail` 53KB/0.83s vs `ac=list` 7KB/0.75s —— **瓶颈是 RTT 不是体积**,
换轻接口省不下来;能改的是观感结构(骨架先出 + 首屏预抓两页 + 分页缓存)。

##### 采集接口(`…/api.php/provide/vod/`)实测,不是文档

- **`ac=detail` 同样吃 `t` 和 `pg`,一次回 20 条 × 83 字段,含 `vod_pic` 和 `vod_play_url`。**
  这是整个架构的支点。`ac=list` 每条只有 8 个字段、**没有海报也没有播放地址**,用它就得
  「列 20 条 → 再打 20 次详情」。测试里有断言钉死「不许出现 ac=list」。
- 搜索**只有** `ac=detail&wd=` 有效。`ac=list&wd=` 会返回**全站内容**,看起来像搜到一堆
  其实一条没匹配 —— 很安静的坑。
- 每页恒 20 条,无 limit 参数;`limit` 字段是**字符串** `"20"`。
- `vod_play_from`/`vod_play_url` 用 `$$$` 分多线路(两边 1:1 对齐),`#` 分集,`$` 分集名和地址。
- **顶级分类基本是空的**(采集站甲 `t=2`、采集站乙 `t=1` 都 total=0),内容只挂叶子分类。
  v2 的解法:分类横条里点父级时**自动落到它的第一个子分类**,别把用户扔进空页。
  (v1 那套「子分类目录 + 本级内容混排」已随 NetdiskPage 方案一起作废。)
- **有的站 `class` 里根本没有 `type_pid`**(采集站丁 只有 type_id+type_name),父子关系无从得知,
  那种站上「电影/连续剧」点进去就是空的 —— 站点数据如此,不是插件漏了什么。
- **有的线路给的是网页播放页不是流**:采集站丙 的 `liangzi` 是 `/share/<hash>`,GET 回来
  `<!doctype html>`;同片的 `lzm3u8` 才是真 m3u8。解法=同一部片内部**按媒体扩展名取舍**
  (有真流的就不摆网页那条;一条都认不出时全留,无扩展名直链是存在的)。
- 海报和 m3u8 都不需要 Referer、无防盗链、无 302;但**空 UA 会被部分 CDN 403**,`ctx.http`
  默认一个头都不发,必须自己设。
- 故障有两种要分开报:返回 HTML 错误页(采集站戊) vs JSON 被截断(采集站丁 出现过)。

##### 为什么是「一站一服务器」

`httpAllowedHosts: ["$sourceServer"]` 运行时展开成**该插件已配置的全部服务器地址**
(`sync_plugin_source_grants` → `set_source_grants`,整体替换语义)。一个服务器实例只能打
它自己那个域名,**想在一个实例里聚合几十个站就得把域名硬编码进 manifest**。用户 2026-08-01
定:一站一服务器,且**仓库里不出现任何采集站域名**(插件只留一个地址输入框)。
`D:\LinPlayer\vod.json` 已加进 .gitignore。

##### 顺带挖出的两个宿主真 bug(都已修)

1. **`NetdiskPage` 默认「文件夹优先 + 名称升序」会毁掉策展顺序。** 资源站返回「最新在前」,
   一排就全乱,连末尾那条「下一页 ›」都被排到最上面。加了 `"default"`(源顺序)档并设为默认,
   该档**连文件夹置顶都不做**——那也是重排。PC 和手机两处。
2. **手机端只登录网盘/插件源的用户,浏览页一辈子进不去。** `ServersPage` 的 `onTap` 第一行
   是 `if (sv.active) return;`,而手机端到 netdisk 路由的另一条路是「设置 → 网盘文件」,设置的
   入口是首页右上角齿轮 —— 没有 Emby 会话时 `HomePage` 早退成空状态,齿轮跟着没了。
   改成点文件浏览型的源就进它的浏览页(对齐 PC 的 `onEnter`)。这是
   [首登闸口+源表单共用](sources.md) 那个「只判 session = 网盘用户进不了门」的同款复发。

##### 版式

**v2 的 VodPage 是固定海报墙**(2:3 网格),不再靠猜。下面这段讲的是 **NetdiskPage**
(网盘源仍在用,那几处改动保留):

- 过半条目带 `thumb_url` → 自动铺网格,否则文件表。**不落 localStorage 是故意的**:
  一个目录是海报墙、下一层是分集列表,钉死偏好等于永远有一半目录是错版式。
- 宽高比取第一张真图,但**必须 snap 到标准值**(<0.9→2:3,<1.2→1:1,否则 16:9)。直接用实测值的话
  「第一张加载完的是谁」取决于网络竞速,真机上量到同目录两次进来 0.709 / 0.801 不一样。
- 分类**不能和内容平铺在一起**:分类没有图,平铺进海报墙就是一排 172×257 的空盒子。
  v1 试过「收成一个入口」,v2 直接改成顶部 chip 横条 —— 这才是它本来的形态。
  **这个只有真渲染看得见,DOM 断言全是绿的。**

##### 验证手法

- 夹具测试 `tools/test_vod.mjs`(19 条,v2 契约),**逐条注入真 bug 验过会红**;CI 有 node 步骤。
  其中一条专守 v2 的由来:卡片 `title` 里不许再出现角标和年份。
- 真机 CDP:`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=…` 起打包好的 exe,
  `__TAURI_INTERNALS__.invoke` 直接调 `plugin_install` / `source_login` / `source_list_dir`。
- **手机端 UI 也能在桌面 exe 里真跑**:把同一个 WebView `Page.navigate` 到
  `http://tauri.localhost/index-mobile.html` —— 三端共用一份 dist,Tauri 桥还在,所以是真 UI +
  真后端。视口必须 `Emulation.setDeviceMetricsOverride`(见 [手机端 UI(ui/mobile)](ui-mobile.md))。

相关:[插件 v2 市场与声明式 UI](plugins.md)、[插件仓库 v2 重写](plugins.md)、[Stremio 插件协议源](sources.md)、
[网盘源架构(2026-07-24大改+登录扩容)](sources.md)、[挂真机 CDP 调试](methodology.md)、[测试必须先红](methodology.md)

---

### UHD 插件

> 原记忆:`uhd-plugins.md` · 类型:`project`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

UHD(<UHD 求片站>)系列插件在 **D:\LinplayerPluginsRepository**(独立于主项目 D:\LinPlayer)。
已发布：`UHD-traffic`(流量,原有)、`UHD-speed`(线路测速)、`UHD-request`(求片)。
三者都复用同一登录：`POST /api/v1/auth/login {username,password}` → `Authorization: <原始token>`(非 Bearer)。

**逆向官网接口的方法**(官网是 React Router SPA,接口全在 `/api/v1/`)：
1. `curl /speed` 拿 HTML → 找 `/assets/manifest-*.js`
2. manifest 里 `"routes/xxx"` 映射到 `module:"/assets/<route>-*.js"` 的路由 chunk
3. 下载 route chunk + 共享的 `api-*.js`(fetch 封装,baseURL 空=相对,Authorization 头)
4. `grep '/api/v1/...'` 拿端点,读 minified 上下文拿 body 字段

关键端点已在各插件 main.js 顶部注释逐条记录。测速：`subscriptions/domains`→`/{id}/resolve`
→`{线路}/speed-test/session {parent_domain_id,size_mib}`→`/speed-test/download?size_mb=&session_id=`
→`/speed-test/report`。求片：`media-requests/search`→`media-requests`(创建,request_type=missing求片/refresh追新)
→`media-requests/mine/list`。响应列表容器是 `data.list`。

宿主 QuickJS 里 `Date.now()`/`res.headers`(dio map,值是数组)/`query` 都可用(见 「plugin-system」(该条不在本库,多为 Flutter 时代的旧记忆,已作废))。
发布=改完跑 `python tools/build.py`(重生成 registry+ipk)再 push main([Git workflow](methodology.md));
registry 走 raw.githubusercontent main,推完即上市。

**1.0.1 修复(第一版全崩,根因见下,教训:插件必须端到端实测再发)**：
- **httpAllowedHosts 是 fail-closed**:空/缺省=**拒绝所有主机**(不是放行!SPEC 原文写反了,
  加载器 lib/plugins/runtime/plugin_context_bridge.dart:126 才是准的)。任何联网插件必须显式列 host,
  精确匹配无通配符,重定向后 host 也要在名单。测速第一版没写→连 <UHD 求片站> 都被拦。
- UHD 线路域名(前端 speed chunk 硬编码,已全列进测速白名单):www / speed / v1 / v1-vod1/2/3 /
  global / smart .<UHD 主域>。resolve 返回其中之一作线路基址。
- **官网测速文件大小=32/64/100 MiB**(前端 `Ls=[32,64,100]`)。官网单线路流式下载不缓冲;
  插件用 `ctx.http` 会把整个 body 读进 64MB isolate→大文件 OOM。
- **为此给宿主 ctx.http 加了 discardBody(流式只计 bytes,不读进 isolate)+ delete 方法**
  (context_bridge + bootstrap_js,已 push 主仓 main)。所以测速/求片 1.0.1 **依赖重新构建的宿主**,
  旧 build 装新插件仍会内存吃紧/取消投票失败。
- **调试神器**:便携版 build 日志在 `<builddir>/userdata/temp/linplayer_logs/linplayer-YYYY-MM-DD.log`,
  能看到 `[PluginCtx]`/`[Plugin:xxx]` 的 http 失败原因。求片插件已把所有 http 失败落日志。

测速会耗真实账户流量(每线路×大小)。

**1.0.2(第三轮反馈:太简陋)**：
- 求片"参数验证失败"根因=**create 的 content(说明)必填**(前端 `if(!o.trim())error("请填写具体说明")`,
  官网标"说明（必填）")。留空→服务端拒。已改强制校验循环重填。搜索结果项确实带 `tmdb_id`。
- 测速改为**用户下拉选一条线路**(不批量)+选大小;**进度面板实时可视化**(进度条+当前/平均速度),
  分段 8MiB 每段独立 session 驱动进度(总量=所选大小)。
- **为此又给宿主加了两个 ctx.ui 能力**(已 push 主仓):`showProgress/updateProgress/closeProgress`
  可实时更新的模态进度框 + `showForm` 的 `type:'select'` 下拉字段(options:[{value,label}]),
  实现在 lib/plugins/runtime/plugin_ui_host.dart(进度面板+_PluginFormDialog select)。见 「plugin-system」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)。
- ctx.ui 原生只有 toast/dialog/form/openPage,无 webview/gauge;要"可视化"只能靠新加的进度面板。
- 教训累计:**插件每轮都因没真机验证而返工**——宿主 UI 能力有限要先摸清,发版前让用户装真机跑一遍。

**1.0.3(第四轮:两个真机日志坐实的硬伤)**：
- **`callTimeout` 30s 是"总墙钟"不是 CPU 时间**——`qjs_plugin_engine.evaluate` 用 `future.timeout(30s)`
  包住整个 handler Promise,**等用户填表/等网络也在计时**→交互式多步流程必被 30s 杀+插件自动禁用
  (日志 `PluginTimeoutError 调用超时 30000ms`)。**已改「空转看门狗」**:包装宿主桥记 `_hostCallsInFlight`
  +`_lastActivity`,只有既无在途宿主调用又超 30s 无交互(纯 JS 死循环)才判失控;等用户/等网络不计时。
- **新宿主能力=旧 build 装新插件必坏**:build493 不认 `type:'select'`→退化成文本输入框("让我填写");
  不认 showList→无带图列表。**任何新 ctx.ui 能力都必须让用户重新构建 App**,不能只更新插件。
- **`ctx.ui.showList({items:[{id,title,subtitle,image}]})`** 带缩略图的滚动列表选择器(海报由宿主
  直接 Image.network 加载 image.tmdb.org,不走插件白名单),返回选中 id。测速用它选线路、求片用它带海报选片。
- 测速改单线路点选(不批量);求片搜索结果带海报列表。都在 plugin_ui_host.dart。

**1.0.4(build500 实测:宿主修复生效,新暴露 search 500)**：
- build500 已含宿主修复 → 不再 not-a-function,UI/登录都正常。新问题:求片 search 返回
  「服务端错误」(500)。排查法:同 body 用坏 token 打 search 是**干净 401**(`invalid or expired token`),
  证明鉴权已过、是服务端处理阶段 500 → 不是 body/鉴权,是缺浏览器上下文。
- 根因假设(强,未真号验证):官网前端**同源** fetch 默认 `credentials:same-origin` 会自动带
  **Authorization Cookie**(api-client `k()` 用 `document.cookie` 设的)+ Origin/Referer;插件只发了 header。
  search 走服务端代理 TMDB,可能读 Cookie/Origin。**修法**:插件鉴权请求补
  `Cookie: Authorization=<token>` + `Origin` + `Referer`(dio 无浏览器禁用头限制,能设这些头)。
- 顺带 request 业务日志加 HTTP 状态码。**本地 `flutter build windows --release` 成功出 exe**
  (177s,exit0)——证明宿主改动真能编译,不只是 analyze 过。构建产物在 build/windows/x64/runner/Release/。

**测速接口实测约束(speed 1.0.5 修复,用测试账号 [UHD 测试账号](plugins.md) curl 跑通整链)**：
- `POST {线路}/speed-test/session` 的 `size_mib` **只接受 32/64/100**,填 8 → `参数验证失败`。
- `download?size_mb=` **必须等于**会话 size_mib,否则只回 ~39 字节。→ **只能单会话单次下载,不能分段**。
- 旧版(1.0.2~1.0.4)用 8MiB 分段驱动进度条 → session 直接被拒,测速全废。1.0.5 改单次下载 +
  下载阶段用不定态进度条(单请求内 ctx.http 拿不到实时百分比)。
- resolve 返回 `data.domain` 是子线路(<用户主力 Emby 服(UHD fork)>→<UHD 子线路域名>),session/download 打这个;
  `parent_domain_id` 用原列表项 id。列表项字段 `{id,name,description,domain,normalized_host}`,
  **UI 只显示 name**(不暴露 domain,用户要求)。
- **中国大陆线路 resolve 到 `<UHD 大陆线路域名>`(.online TLD!非 .com)**,旧白名单只有
  .<UHD 主域> → 本地白名单拦下 → 插件报「线路域名未授权」(网页端正常)。1.0.6 补 <UHD 备用域> +
  china-vod1/2/3.<UHD 备用域>。**根治**:宿主 httpAllowedHosts 现支持 `*.example.com` 通配子域
  (plugin_context_bridge `_hostAllowed`,点分隔防 evil-example.com 误命中),插件加 `<*.UHD 主域>`/
  `<*.UHD 备用域>` → 重建后动态 CDN 子域不再漏。**教训:resolve 出来的是动态 CDN host,别穷举白名单。**
- **节点按账号分配、稳定**:测试账号大陆线路稳定 resolve 到 `china-vod3`,用户账号稳定到 `china-vod4`——
  我从自己账号 curl **看不到用户的节点**,所以 1.0.6 只列 vod1/2/3 漏了用户的 vod4(日志实证)。
  1.0.7 枚举 <UHD 线路域名枚举> 的 .com/.online 双 TLD 兜底(build500 exact-match)。
  已 curl 实测 china-vod4 整链通(session 200 + download 满 32MiB 无重定向)。**exact-match 构建靠枚举,
  真正一劳永逸只有重建后的通配 `<*.UHD 备用域>`。** 验证插件白名单类改动:必须看用户日志里的真实 host,
  不能只凭自己账号 resolve(节点不同)。

---

### UHD 测试账号

> 原记忆:`uhd-test-account.md` · 类型:`reference`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。

UHD(<UHD 求片站>)**测试账号**(用户提供,服主已授权测试,可直接 curl 实测接口):
- 用户名:`<测试用户名>`
- 密码:`<测试密码>`

**同一套账密也能登 Emby 测试服 `https://<Emby 测试服 A>`** —— 见 [Emby 测试服务器](emby.md)。别把两者搞混:这里的 www 是**求片站**(自家 /api/v1),smart 是 **Emby 媒体服务器**(标准 /Users/AuthenticateByName)。

登录:`POST /api/v1/auth/login {username,password}` → `{ok,data:{token,expires_at}}`,token 作 `Authorization` 头(非 Bearer)。用 `--data-binary @file`(含中文用户名)避免 shell 编码问题。

**用它实测的定论(见 [UHD 插件](plugins.md))**:求片插件整条链路都正常——登录 / **追新(refresh)搜索** / **创建(create,content 必填)** / 我的列表(mine/list)全部 `ok:true`,create 真能建出 `status:pending` 的求片。
曾有段时间 `request_type:"missing"`(求新片)搜索恒返回 `{ok:false,msg:"服务端错误"}`(服务端 TMDB 搜索路径故障),**服主后来修好了**,现 missing 搜索正常 ok:true,missing create 也通(建出 status:pending)。

**poster_path 三形态(1.0.7 修)**:完整 URL(TMDB 直链)/ `/img/...`(UHD 自托管,`<UHD 求片站>`+path 返 jpeg)/ 裸 TMDB 路径。搜索结果含 `exists_in_library`/`allowed_to_create`;对已在库且 `allowed_to_create:false` 的条目提交 missing → 服务端回 `媒体库中已存在该影片`(1.0.7 在列表标「已在库」)。

(实测建过 3 条测试求片需服主/admin 删:沙丘 `<求片单号>`、沙丘(refresh)、To End All War `<求片单号>`;无用户自删接口。)

---

## 跨域交叉引用

这些条目和本领域强相关,但正文放在别的文件里(一条经验只存一份正文):

- [Stremio 插件协议源](sources.md) — 插件协议型源的方法参考(该源已删)
- [起播不露视频窗](player-mpv.md) — 插件源起播不露画面窗的两个真因
- [分发通道 GitHub 优于 CF](build-release.md) — 插件包与 registry 走 GitHub raw,别挪 CF
- [SourceKind 线上是小写](sources.md) — 插件源的 kind 形如 plugin:<插件id>/<源id>
