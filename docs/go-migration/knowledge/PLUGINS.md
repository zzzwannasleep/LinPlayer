# 插件系统宿主契约

> 挖掘时间 2026-08-30。目标:Go 重写核心层时,**插件包零改动**继续跑。
> 所有结论带 `文件:行号` 出处。行号对应本次挖掘时的 HEAD(`85b47417`)。

## 0. 一句话

**每个插件 = 一个 64MB 上限的 QuickJS 实例 + 一个全局 `ctx` 对象 + 一份 manifest 声明的权限集;
四类贡献点(`dataSources` / `panels` / `actions` / `sandboxViews`)是它接进宿主的全部通道;
网络边界 fail-closed(`crates/core/src/plugins/state.rs:102`),`dataSources` 那条把插件直接变成
`MediaSourceBackend`,浏览/搜索/播放/字幕/多清晰度/跨服聚合全部白拿。**

契约面共四层,Go 侧必须逐层原样复刻:

| 层 | 契约物 | 权威出处 |
|---|---|---|
| 语言面 | 全局 `ctx.*`、`__lp_call` 前奏 | `crates/core/src/plugins/ctx.rs`、`engine.rs:27` |
| 声明面 | `manifest.json` 字段与校验规则 | `crates/core/src/plugins/manifest.rs` |
| 挂载面 | 四类贡献点 + slot/context 常量 + 声明式 UI 树 | `contributions.rs`、`ui/shared/plugin-ui.ts` |
| 分发面 | `registry.json` schema + `.ipk` 包 + sha256 | `registry_index.rs`、`installer.rs` |

---

## 1. `ctx.*` API 全表

装配点唯一:`crates/core/src/plugins/ctx.rs:152` 的 `install()`,把整个 `ctx` 塞进 globals
(`ctx.rs:418`)。权限检查**全部在核层完成**,宿主只落地已授权的调用(`host.rs:4-5`)。

约定:
- **异步**列写 `async` 的返回真 Promise(Rust 侧 `Async(...)` 绑定,`ctx.rs:38`);同步列直接返回。
- 权限不足 → 抛 JS 异常,文案 `插件 <id> 缺少权限「<perm>」`(`permission.rs:88-90`,经 `JsOut` 变成真 Error 对象 `state.rs:296-302`)。

### 1.1 日志 / 工具 / 错误 / 睡眠(无需权限)

| 方法 | 签名 | 语义 | 权限 | 出处 |
|---|---|---|---|---|
| `ctx.log.info/warn/error` | `(msg) → void` 同步 | 转 `PluginHost::log(pluginId, level, msg)` | **隐式授予** `log` | `ctx.rs:67-73,156-160`;隐式表 `permission.rs:57` |
| `ctx.util.isVideoName` | `(name) → bool` 同步 | 直接复用宿主扩展名表 `source::is_video_file_name`。**故意不让插件自己维护一份**——漂移的后果是「某格式在内置源能播、插件源里根本不显示」 | 无 | `ctx.rs:384-389` |
| `ctx.errors.unsupported` | `(msg?) → never`(抛) | 抛出以 `__LP_UNSUPPORTED__` 为前缀的异常。数据源桥据此还原成 `SourceError::unsupported()`,UI **静默退回本地过滤**而不是弹红字 | 无 | `ctx.rs:18-21,396-400`;还原 `source/plugin_source.rs:63-79` |
| `ctx.sleep` | `(ms) → Promise<null>` | **clamp 到 0..10000ms**,越界不报错 | 无 | `ctx.rs:404-411` |
| `ctx.plugin` | 对象 `{id,name,version}` | 引擎启动时注入的元信息 | 无 | `ctx.rs:414`;构造 `engine.rs:108-110` |
| `ctx.onEnable(fn)` | 同步注册 | 存 `Persistent<Function>`,启用后由 manager 调 | 无 | `ctx.rs:75-82,415` |
| `ctx.onDisable(fn)` | 同步注册 | 禁用/卸载前调 | 无 | `ctx.rs:416`;调用点 `manager.rs:301` |

### 1.2 网络 `ctx.http`(权限 `http`)

| 方法 | 签名 | 出处 |
|---|---|---|
| `ctx.http.get` | `(url, opts?) → Promise<Resp>` | `ctx.rs:164` |
| `ctx.http.post` | `(url, body?, opts?) → Promise<Resp>` | `ctx.rs:165` |
| `ctx.http.delete` | `(url, opts?) → Promise<Resp>` | `ctx.rs:166` |

- **参数位是不对称的**:`post` 的 opts 在 `args[2]`(`args[1]` 是 body),`get`/`delete` 的 opts 在 `args[1]`。`state.rs:185-189`。
- `opts` 支持 `query`(对象 → 查询串,非字符串值 `to_string()`)、`headers`(同)、`body`、`discardBody`。`state.rs:191-226`。
- 返回:`{status, headers, body}`;`discardBody:true` 时是 `{status, headers, bytes}`——**按流丢弃只数字节,内存恒定**(测速用)。`state.rs:239-251`。
- `body` 解码:开头是 `{` 或 `[` 就尝试解析成 JSON 对象/数组,否则原样字符串。`state.rs:273-281`。
- 权限检查在 `http_request` 内部(`state.rs:178`),三个动词共用一处。
- **重定向后的最终 URL 必须再过一遍同一道准入**,失败文案「请求经重定向后不再被允许」。`state.rs:230-234`。

### 1.3 存储 `ctx.storage`(权限 `storage`)

| 方法 | 签名 | 语义 | 出处 |
|---|---|---|---|
| `get` | `(key) → Promise<Json>` | 缺失返回 `null`,不抛 | `ctx.rs:173-182`;`storage.rs:58-62` |
| `set` | `(key, val) → Promise<null>` | **超 5MB 抛错且不写入内存**(先算加入后大小再决定) | `ctx.rs:186-195`;`storage.rs:70-87` |
| `delete` | `(key) → Promise<null>` | 键不存在时不落盘 | `ctx.rs:199-208`;`storage.rs:89-96` |
| `keys` | `() → Promise<string[]>` | BTreeMap 序 | `ctx.rs:212-221` |
| `clear` | `() → Promise<null>` | | `ctx.rs:225-234` |

### 1.4 播放器 `ctx.player`

| 方法 | 权限 | 语义 | 出处 |
|---|---|---|---|
| `getCurrentMedia()` | `player.read` | 桌面实现返回 `{name,type,indexNumber,parentIndexNumber}`,没在播是 `null` | `ctx.rs:240`;`apps/desktop/src/plugins_host.rs:65-77` |
| `getCacheLimitBytes()` | `player.read` | 桌面**目前写死 300MB**(标了 `ponytail:` 待接真配置) | `ctx.rs:241`;`plugins_host.rs:78-79` |
| `play()` / `pause()` | `player.control` | `set_pause(false/true)` | `ctx.rs:242-243`;`plugins_host.rs:80-91` |
| `seek(secs)` | `player.control` | 绝对秒 | `ctx.rs:244`;`plugins_host.rs:92-98` |
| `on(event, fn)` | `player.read` | 存 `Persistent`,宿主派发时回调 | `ctx.rs:248-256` |
| `off(event)` | **无检查** | 按事件名**整体清空**,不做函数身份匹配(代码里标了 `ponytail:` 说明这是刻意取舍) | `ctx.rs:259-268` |

事件名:`onPlay` / `onPause` / `onPlayEnd`(`docs/PLUGINS.md:93`)。派发入口 `manager.rs:376-378` → `worker.rs:162-170` → `engine.rs:176-195`,**广播给所有已启用插件**。

### 1.5 界面 `ctx.ui`(全部需权限 `ui`)

九个方法共用一个 host 路由,一律转 `ui` 通道:`render` / `showToast` / `showDialog` /
`showForm` / `showList` / `openPage` / `showProgress` / `updateProgress` / `closeProgress`
(`ctx.rs:276-284`)。

- `render` 是 v2 的声明式 UI 入口:插件交一棵 JSON 描述树,宿主用**自己的组件**渲染
  (三端各一套,TV 的遥控器焦点因此白拿)。其余几个是它的糖 —— `showForm`/`showList`
  本质就是预置形状的 `render`。`ctx.rs:272-275`。
- 桌面宿主分两类(`plugins_host.rs:169-193`):
  - **即发即忘**:`showToast` / `updateProgress` / `closeProgress` / `openPage` / `render`
    —— 发 `plugin://ui-request` 事件后立即返回 `null`;
  - **需返回值**:`showForm` / `showDialog` / `showList` / `showProgress` —— 挂 oneshot
    等前端 `plugin_ui_respond(id, value)` 回填。
- ★ **需返回值的那几个没有超时**。前端不回,插件那边的 `await` 永远悬着
  (`ui/desktop/components/PluginHost.tsx:12-14`)。所以前端关弹窗必须显式回 `null`
  (`PluginHost.tsx:124-128`)。**Go 侧必须保留这条约束或补超时,但补超时是行为变更,要单独立 issue。**
- `openPage` 在 v2 **未实现**,前端如实提示一句而不是静默吞掉(`PluginHost.tsx:112-116`;
  已知限制清单 `git show rust-final:docs/PLUGINS_V2_PLAN.md` 第 615 行)。

### 1.6 Emby `ctx.emby`

| 方法 | 权限 | 语义 | 出处 |
|---|---|---|---|
| `getServerUrl()` | `emby.read` | 当前活跃账号的 server | `ctx.rs:288`;`plugins_host.rs:108` |
| `getServerInfo()` | `emby.read` | `{url,baseUrl,name,username,userId}` | `ctx.rs:289`;`plugins_host.rs:109-115` |
| `getCurrentUser()` | `emby.read` | `{id,name}` | `ctx.rs:290`;`plugins_host.rs:116` |
| `apiRequest(opts)` | `emby.api` | 以当前登录身份打 Emby;`opts = {path,method,query,headers,body}`,返回 `{status, body}` | `ctx.rs:293`;`plugins_host.rs:125-167` |

- **`getCredentials` 已删**:宿主不再持久化明文密码,插件要账密自己弹表单存自己的 storage。
  `ctx.rs:291-292`、`permission.rs:46-49`。
- `apiRequest` 有**防 SSRF 闸**:`base.join(path)` 后 scheme/host/port 必须仍等于服务器本身,
  否则拒绝(避免 `X-Emby-Token` 外泄)。`plugins_host.rs:130-136`。**Go 侧必须原样保留。**

### 1.7 贡献点注册 `ctx.extensions`

| 方法 | 签名 | 权限 | 出处 |
|---|---|---|---|
| `register(kind, descriptor)` | → `{id, registered:boolean}` | **按 kind 各自校验**(`ContributionKind::required_permission()`),不是笼统的 `extensions` | `ctx.rs:303-314` |
| `unregister(kind, id)` | → void | `extensions`(固定) | `ctx.rs:318-328` |

- `register` 只查 kind 自己那一条,**和 manifest 静态校验同一把尺子** —— 多查一条 `extensions`
  会让「manifest 过了、运行时被拒」成为可能。`ctx.rs:308-310`。
- `descriptor` **必须是对象且必须有非空 `id`**,否则当场抛。挡的是
  `ctx.extensions.register('panels','stats',{…})` 这类多写一个参数的写法。`ctx.rs:110-140`。
- descriptor 里的函数在转 JSON 时被抽出存进引擎 handler 表,原位换成 `{"__handler__": "hN"}`。
  `ctx.rs:104-109`;转换器 `convert.rs:25-28`;id 分配 `state.rs:155-158`。

### 1.8 数据源注册 `ctx.sources`(权限 `sources`)

```js
ctx.sources.register("mysrc", { listDir, search, resolvePlay,
                                categories, catalog, mediaDetail })
```

| 方法 | 签名 | 出处 |
|---|---|---|
| `register(srcId, handlers)` | srcId 非空;第二参必须是对象;内部把 srcId 拍进 `descriptor.id` 后走同一条 `register_contribution` | `ctx.rs:341-362` |
| `unregister(srcId)` | 摘掉后同时发 `sources_changed` + `extensions_changed` | `ctx.rs:367-377` |

插件侧六个函数的宿主映射(全部在 `crates/core/src/source/plugin_source.rs`):

| JS 字段 | 宿主参数 | 返回映射 | 出处 |
|---|---|---|---|
| `listDir(dirId, server)` | `dirId: string\|null` | 数组 → `Vec<SourceEntry>`,**逐条跳过畸形项**,整体不是数组才报错 | `plugin_source.rs:309-319,125-131` |
| `search(query, server)` | | 返回 `null`(= 插件没实现这个字段)**当作 unsupported**,不是「搜到 0 条」 | `plugin_source.rs:321-337` |
| `resolvePlay(entry, qualityId, server)` | `entry` 含 `{id,name,isDir,isVideo,size,raw}` | 见下 | `plugin_source.rs:339-364` |
| `categories(server)` | | `null` → `unsupported_feature("影视目录")` | `plugin_source.rs:370-383` |
| `catalog(req, server)` | `req = {categoryId, keyword, page}` | `{items,hasMore,total}`;**`hasMore` 缺省 false**(缺省 true 会让前端无限拉空页) | `plugin_source.rs:385-414` |
| `mediaDetail(id, server)` | | `MediaDetail`,缺字段一律留空不报错 | `plugin_source.rs:416-429` |

`server` 下发的是**显式白名单**,不是整包:`{id, baseUrl, username, password, token, extra}`
(`plugin_source.rs:83-92`,测试钉住键集 `plugin_source.rs:542-556`)。
`SourceServer` 将来加字段时不会自动流进所有插件。

`resolvePlay` 返回值映射(`plugin_source.rs:147-214`):

| JS 键 | Rust 字段 | 规则 |
|---|---|---|
| `url` | `url` | **必填,空/缺失直接报错**(放过去播放器会收到空地址,表现是「点了没反应」) |
| `title` | `title` | 缺省回落条目名 |
| `httpHeaders` | `http_headers` | 非字符串值 `to_string()` |
| `userAgent` | `user_agent_override` | |
| `subtitles[]` | `subtitles` | `{url(必填), title, language, httpHeaders}`,缺 url 的整条跳过 |
| `qualities[]` | `qualities` | `{id(必填), label(缺省=id), rank(缺省 0)}` |
| `quality` / `selectedQualityId` | `selected_quality_id` | 两个键都认 |

`SourceEntry` 的 `isVideo` **允许插件不填** —— 缺省按宿主扩展名表判定,目录永远不是视频。
`plugin_source.rs:98-123`。

JS 异常 → `SourceError` 的还原规则(`plugin_source.rs:63-79`):
1. 含 `__LP_UNSUPPORTED__` → `unsupported()`,带尾巴就用尾巴当文案;
2. 否则文案里含 `401` / `unauthorized` / `登录` → `is_auth = true`(UI 引导重登);
3. 其余 → 普通错误。

---

## 2. manifest 格式

解析与校验唯一入口:`crates/core/src/plugins/manifest.rs:87` 的 `from_value()`。
**当前 `API_VERSION = 2`**(`manifest.rs:17`)。

### 2.1 字段表

| 字段 | 必填 | 类型 | 校验规则 | 出处 |
|---|---|---|---|---|
| `id` | ✅ | string | 反向域名:**至少一个点**,每段非空,仅 `[A-Za-z0-9_-]` | `manifest.rs:63-72,95-98` |
| `version` | ✅ | string | 宽松语义化:`major.minor.patch` 三段全数字,允许 `-`/`+` 后缀 | `manifest.rs:74-79,99-102` |
| `name` | ✅ | string | 非空(trim 后) | `manifest.rs:88-93,103` |
| `apiVersion` | ✅(实质) | number | **缺省视为 1 并直接拒**;`< 2` 报「旧版本…请到插件市场获取新版」;`> 2` 报「请先升级 LinPlayer」 | `manifest.rs:105-116` |
| `author` | ❌ | string | 缺省 `"未知作者"` | `manifest.rs:187` |
| `description` | ❌ | string | 缺省空串 | `manifest.rs:188` |
| `category` | ❌ | string | 缺省 `"tools"`;取值必须 ∈ `source/ui/player/notify/tools` | `manifest.rs:60,149-159` |
| `targets` | ❌ | string[] | 取值必须 ∈ `pc/mobile/tv`,去重;空 = 不限。**没有 ios,苹果全线不做** | `manifest.rs:61,161-173`;测试 `manifest.rs:486` |
| `main` | ❌ | string | 缺省 `"main.js"`;文件必须存在,否则安装/加载报「入口不存在」 | `manifest.rs:191`;`installer.rs:21-24` |
| `permissions` | ❌ | string[] | 必须是数组;元素必须是字符串;**已删权限给专门文案**;未知权限直接拒;自动去重 | `manifest.rs:132-147` |
| `contributes` | ❌ | object | `{kind: descriptor | [descriptor,…]}`,见 §4 | `manifest.rs:230-259` |
| `httpAllowedHosts` | ❌ | string[] | 空/缺失 = **拒绝所有出网**(fail-closed,不是放行);`$` 开头一律当令牌,拼错的令牌**直接报错**不静默放过 | `manifest.rs:315-341` |
| `icon` | ❌ | string | 插件目录内相对路径 | `manifest.rs:195` |
| `homepage` | ❌ | string | | `manifest.rs:196` |
| `license` | ❌ | string | | `manifest.rs:197` |
| `minAppVersion` | ❌ | string | 解析时不校验(市场侧用) | `manifest.rs:198` |
| `raw` | — | — | 原始 JSON 全量留一份,展示/备份用 | `manifest.rs:199` |

### 2.2 已废弃字段(撞上要给「这是老插件」而不是 JSON 语法错)

| 字段 | 报错内容 | 出处 |
|---|---|---|
| `runtime` | 「含已废弃的 runtime 字段(v1 遗留,曾用于 iOS 合规);请使用 v2 规范重新打包」 | `manifest.rs:118-124` |
| `extends` | 「含已废弃的 extends 字段;v2 改用 contributes」 | `manifest.rs:125-129` |

理由写在 `manifest.rs:9-10`:官方仓库总共 8 个插件,全部重写比养两套概念便宜,而且
`emby.credentials` 这个刚删掉的攻击面会被兼容层拖回来。

> ⚠️ `docs/PLUGINS.md:57-73` 的 manifest 示例**是 v1 的**(还写着 `extends` 和
> `getCredentials`),`docs/PLUGINS.md:139` 还把包叫 `.lpk`(实际是 `.ipk`,
> `installer.rs:29`、`api.ts:1573`)。**以 `manifest.rs` 为准,别照那份文档抄。**

### 2.3 `$sourceServer` 令牌

`manifest.rs:25` 定义,值就是字面量 `"$sourceServer"`。

- 存在理由(`manifest.rs:19-24`):白名单是**发布期固定**的,而通用数据源插件
  (OpenList / 飞牛 / 任意自建)发布时不可能知道用户自建服务器的域名;裸 `*` 又被明确堵死。
  **不补这条,数据源插件是废的。**
- 运行时展开成**用户在「添加服务器」里亲手填的 `base_url` 的 origin**。
- `wants_source_server_host()`(`manifest.rs:223-227`)供「添加服务器」页提示用户。
- 目前**只支持这一个令牌**,其它 `$xxx` 一律报「未知令牌」(`manifest.rs:331-335`)。

---

## 3. 权限模型

定义表:`crates/core/src/plugins/permission.rs:16-39`。**顺序即 UI 展示顺序**。

| id | 标题 | dangerous | 说明(原文) |
|---|---|---|---|
| `player.read` | 读取播放状态 | 否 | 获取当前播放的媒体信息、播放进度,并监听播放事件 |
| `player.control` | 控制播放器 | **是** | 可以播放、暂停、跳转当前视频 |
| `http` | 网络访问 | **是** | 通过 HTTPS 访问外部网络(受域名白名单限制) |
| `storage` | 本地存储 | 否 | 在本地保存插件自己的数据(每个插件独立,上限 5MB) |
| `ui` | 界面交互 | 否 | 弹出提示、对话框,或打开插件页面 |
| `emby.read` | 读取 Emby 信息 | 否 | 读取当前登录用户和服务器地址 |
| `emby.api` | 调用 Emby 接口 | **是** | 以当前登录身份向 Emby 服务器发起任意 API 请求 |
| `sources` | 提供数据源 | **是** | 向应用注册可浏览、搜索、播放的媒体源,出现在你的服务器列表里 |
| `extensions` | 扩展界面 | 否 | 向应用注册侧边栏入口、操作按钮、设置页等界面模块 |
| `sandbox` | 自定义界面 | **是** | 在隔离沙箱里渲染插件自带的网页界面(拿不到应用本身的任何接口) |
| `log` | 写日志 | 否 | 输出调试日志(始终允许) |

### 3.1 已删除权限(必须单列,不能只从表里删)

`permission.rs:46-49`:

| id | 给用户看的原因 |
|---|---|
| `emby.credentials` | 宿主不再保存登录密码;请改为在插件自己的设置页里让用户填写 |
| `cfproxy` | CF 优选反代已改为应用内置功能,不再经由插件 |

★ **只删一半会出事**:从 `ALL` 里删了却忘了进 `REMOVED`,老插件会撞上「未知权限: cfproxy」——
看起来像 App 出了 bug 而不是设计。测试 `permission.rs:116-125` 钉住「不在 ALL 里」+「有人话原因」两条。

### 3.2 授予流程

1. **声明**:manifest 的 `permissions` 数组。
2. **同意**:启用前弹窗,同意结果落 `plugins_state.json` 的 `approved[pluginId]`(`manager.rs:214-228,580-592`)。
3. **运行时检查**:每次 `ctx.*` 调用查一次(`state.rs:142-148`),未授权 → `Err` → JS 异常。
4. **`log` 隐式授予**,无需声明(`permission.rs:57`,`GrantedPermissions::new` 强行塞进去 `permission.rs:74-80`)。

### 3.3 fail-closed 边界(逐条,都有测试钉住)

| 边界 | 规则 | 出处 |
|---|---|---|
| 空白名单 | `httpAllowedHosts` 为空 = **拒绝一切**,不是放行 | `state.rs:73-91`;测试 `state.rs:313-316` |
| 裸 `*` | **不是通配符**。只认 `*.` 开头且要求点分隔;裸 `*` 一个字符就能把 fail-closed 击穿成放行全网 | `state.rs:83-89`;测试 `state.rs:336-341` |
| 子域通配 | `*.example.com` 匹配子域**不含主域本身**;`h.len() > suffix.len()` 防 `evil-example.com` 和 `example.com.evil.net` | `state.rs:87`;测试 `state.rs:326-334` |
| 令牌未声明 | 没在 manifest 写 `$sourceServer`,用户配了源也不放行 | `state.rs:109-114`;测试 `state.rs:352-360` |
| 令牌展开为空 | 声明了但用户一个源都没配 = 拒绝一切 | 测试 `state.rs:363-369` |
| 令牌作用域 | 配了 A 服 ≠ 能访问 B 服;**子域也不放行**(令牌不是通配) | 测试 `state.rs:371-380` |
| 明文 http | **只对用户自己填过 `http://` 的那个 origin 放行**;manifest 里硬编码的域名永远 https-only | `state.rs:119-129`;测试 `state.rs:383-399` |
| 非 http(s) | `file`/`ftp`/`data`/`javascript` 一律拒 | `state.rs:130`;测试 `state.rs:401-408` |
| 重定向 | 最终 URL 必须再过一遍同一道准入(含协议降级) | `state.rs:230-234` |
| 端口 | **不参与匹配**,白名单一贯按 host | `state.rs:30`;测试 `state.rs:410-419` |
| 贡献点 | 没声明对应权限,连 manifest 里静态声明都不许 | `manifest.rs:239-245`;测试 `manifest.rs:409-428` |
| 重装 | 装 `.ipk` 或挂 dev 目录都**清掉旧启用态与已同意权限**,强制重新授权(防新清单悄悄提权) | `manager.rs:194-198,429-431` |
| 开机自启 | 只激活「已启用 **且** 权限未提权」的插件(`perms_approved`) | `manager.rs:111-115,606-610` |
| 静态资源 | `lpplugin://` **只有已启用的插件可读** —— 否则「禁用」这个动作没有实际约束力 | `manager.rs:396-409` |
| 同时启用数 | `MAX_ENABLED = 16`(每引擎 ~64MB,限数即限内存) | `manager.rs:21,219-221` |

★ 网络准入判定被刻意抽成**自由函数** `check_request(allowed, grants, scheme, host)`
(`state.rs:102`),理由写在 `state.rs:93-94`:构造 `CtxState` 要拉起整个 rquickjs 句柄,
那样的测试没人会写。**Go 侧照做 —— 边界逻辑必须能不起引擎就单测。**

---

## 4. 贡献点与声明式 UI

### 4.1 四类 × slot(取代 v1 的 8 个平级扩展点)

定义:`crates/core/src/plugins/contributions.rs:20-65`。

| kind(线上字符串) | 作用 | 需要权限 |
|---|---|---|
| `dataSources` | 贡献一个完整数据源,接进 `MediaSourceBackend` | `sources` |
| `panels` | 贡献一块 UI,挂在 `slot` 指定的位置 | `extensions` |
| `actions` | 贡献一个操作项,出现在 `context` 指定的上下文 | `extensions` |
| `sandboxViews` | 贡献一个 iframe 逃生舱视图 | `sandbox` |

★ **kind 字符串是硬契约**:它是写在用户 manifest 里的字面量,也是前端查询用的键。
改一个字母,所有已发布插件的那一类贡献**静默消失**(不报错,只是不出现)。
测试 `contributions.rs:224-246` 同时钉住「四个新名认得」和「v1 的 7 个老名一律不认」。

v1 老名(**必须继续不认**):`sidebarItems` / `mediaSources` / `eventListeners` /
`settingsPages` / `homeStats` / `playerOverlays` / `contextMenus`(`contributions.rs:235-243`)。
`eventListeners` 被直接删掉 —— 它本来就该是运行时的 `ctx.player.on()`,声明成扩展点是概念错位
(`contributions.rs:13-14`)。

★ **`panels`/`actions` 要的是 `extensions` 不是 `ui`**。第一版写成 `ui`,后果:manifest 静态校验
放行、运行时注册被拒,而拒的异常发生在 `onEnable` 里被 `let _ =` 吞掉,表现成
**「插件显示已启用、面板却永远是空的」**。`contributions.rs:48-64`,测试 `contributions.rs:349-369`。

### 4.2 slot / context 常量

```
PANEL_SLOTS    = home.stats | sidebar | settings | player.overlay | page
ACTION_CONTEXTS = global | item | player   (缺省 global)
```
`contributions.rs:68-77`;manifest 侧校验 `manifest.rs:267-286`。
**以后加新位置只加 slot 常量,不加类型**(`contributions.rs:14`)。

### 4.3 每类的描述对象字段

统一必填:非空 `id`(`manifest.rs:261-266`)。

| kind | 字段 | 校验 | 出处 |
|---|---|---|---|
| `panels` | `id`, `title`, `slot`, `handler`/`render` | `slot` 必须 ∈ PANEL_SLOTS | `manifest.rs:268-276` |
| `actions` | `id`, `title`, `icon`, `context`, `handler` | `context` 缺省 `global`,必须 ∈ ACTION_CONTEXTS | `manifest.rs:277-286` |
| `sandboxViews` | `id`, `title`, `entry`(**必填**), `slot` | `entry` 非空;**不许含 `..`、不许以 `/` 或 `\` 开头**(第一道穿越防线) | `manifest.rs:287-296` |
| `dataSources` | `id`, `name`, `icon`, `auth` | 有 `auth` 时 `auth.fields` 必须是数组,每项必须有非空 `id` | `manifest.rs:297-310` |

`auth.fields` 每项形如 `{id, label, type, placeholder, required}`,由前端**通用表单**渲染,
产物存进既有的 `SourceServer`(`git show rust-final:ui/shared/api.ts` 第 1631-1637 行;规划口径同 tag 下 `docs/PLUGINS_V2_PLAN.md` 第 154-156 行)。
`base_url` / `username` / `password` 是核层认得的三个专用槽,其余字段一股脑塞 `extra`
(`ui/desktop/pages/sources/sourceForms.tsx:268-287`)。

### 4.4 静态声明 vs 运行时注册:**必须合并,不能整条顶掉**

`ContributionRegistry::register`(`contributions.rs:128-150`)。

- manifest 写的是**描述性**字段(数据源的 `name`/`auth` 表单、面板的 `title`/`slot`);
- 运行时 `ctx.sources.register('demo', {…})` 交的是**行为**字段(几个回调);
- 两边天然只各写一半。

★ 第一版直接 `*slot = c`,于是插件一注册回调,manifest 里的 `name` 和 `auth` **就没了** ——
「添加服务器」页拿到一个**没有任何输入框**的插件源,名字还退化成源 id。
2026-07-23 真机端到端跑出来的,单测和编译都看不见。`contributions.rs:121-127`。

合并方向:**同名键运行时赢,manifest 只填空缺**(`contributions.rs:135-143`),
合并后 `from_manifest = false`。测试 `contributions.rs:296-344` 特意让两边都带 `name`,
就是为了钉住方向 —— 方向写反了测试照样绿。

同一条的键是 `(plugin_id, kind, id)` 三元组;`unregister` 严格按这三元组,
同 id 不同插件不会被误删(测试 `contributions.rs:372-391`)。

### 4.5 handler 的两种引用形式

`contributions.rs:200-215`:

| 描述值形状 | 含义 | 怎么调 |
|---|---|---|
| `{"__handler__": "hN"}` | 运行时注册的匿名函数 | 按 id 查引擎 handler 表 → `engine.rs:143` |
| `"someName"`(非空字符串) | manifest 声明的全局具名函数 | `ctx.globals().get(name)` → `engine.rs:160` |
| 其它 / 缺失 | 无 handler | 返回 `Ok(Null)`,不报错 |

派发入口两条(`manager.rs:330-360`):
- `trigger_extension(pluginId, kind, extId, args)` → 取 `data["handler"]`;
- `invoke_extension_field(pluginId, kind, extId, field, args)` → 取 `data[field]`。
  数据源的六个方法就走它(`manager.rs:553-568`),**不新开一条通路**。

★ **前端要传的是「字段名」不是「字段的值」**。老代码写 `String(panel.data?.handler ?? "render")`,
把值当成了字段名:manifest 声明 `handler:"renderGreeting"` → 去查 `data["renderGreeting"]` 不存在;
运行时注册 `handler: 某函数` → `String()` 出来是 `"[object Object]"`。两种都落到 `HandlerRef::None`,
返回 `Ok(Null)`,**面板永远空白且不报错**。现在的写法见 `ui/desktop/components/PluginHost.tsx:271-282`。

★ **handler 返回 null 时必须重拉一次面板**。第一版是「返回了树才更新」,而绝大多数 handler
只是干件事然后返回 null(改个开关、发个请求),于是**点了完全没反应**。
`ui/desktop/components/PluginHost.tsx:295-306`。

### 4.6 声明式 UI 描述树(14 种块)

类型 + 消毒在 `ui/shared/plugin-ui.ts`(node 可直跑,配套 `plugin-ui.test.mjs`)。
**这棵树是插件写的、不可信的数据**,渲染前必须过 `sanitizeTree`(`plugin-ui.ts:11-15,64-67`)。

节点按 **`t` 字段**分派(`plugin-ui.ts:75`)。全部 14 种(`plugin-ui.ts:20-34`):

| t | 字段 | 消毒规则 |
|---|---|---|
| `text` | `text`, `variant?: title/body/hint/mono` | text 空 → 整节点丢 |
| `row` | `children[]`, `wrap?` | **空容器丢掉**(留着只画出一条空隙) |
| `col` | `children[]` | 同上 |
| `divider` | — | — |
| `badge` | `text`(≤60), `tone?: info/good/warn/danger` | |
| `stat` | `label`(≤60), `value`(≤60), `hint?`(≤120) | label 和 value 都空 → 丢 |
| `progress` | `value` 0..1, `label?` | **越界 clamp 而不是丢**(不画反而让人以为卡死) |
| `image` | `src`, `alt?`, `height?` 16..400 | src 协议白名单 `data:image/` / `lpplugin://` / `https://`,**不许 http** |
| `link` | `text`, `url` | 协议白名单 `https://` / `http://`;`javascript:`/`data:` 是现成注入面 |
| `button` | `label`, `handler?`, `variant?: primary/normal/danger` | label 空 → 丢 |
| `input` | **`id`(必填)**, `label?`, `placeholder?`, `value?`, `password?`, `multiline?` | 无 id → 丢 |
| `select` | **`id`**, `options[{value,label}]`(≤100) | 无 id 或选项全空 → 丢;label 缺省 = value |
| `switch` | **`id`**, `label`(必填) | 缺一即丢 |
| `list` | `items[{id?,title,subtitle?,handler?}]`(≤100) | title 空的行丢掉 |

配额(`plugin-ui.ts:37-41`):`MAX_DEPTH=12` / `MAX_NODES=400` / `MAX_CHILDREN=100`。
超深的子树**整棵丢掉,不截断成半棵**;不认识的 `t` 直接丢 —— 将来加新块,老宿主上是
「少了一块」而不是崩(`plugin-ui.ts:183-186`)。

★ **配额不是洁癖**:一棵递归树能把渲染栈打爆,而 Tauri 窗口是透明的,白屏看起来就是
「整个 app 打不开」(`plugin-ui.ts:22-25`)。

### 4.7 `showForm` / `showList` 是同一棵树的糖

`formTree` / `listTree` 在 `ui/shared/plugin-ui.ts:239-278`。**字段键是 `id` 和 `value`。**

★ 宿主自带的参考示例一度教的是 `key` / `default`(错的),而 `sanitizeTree` 遇到没有 `id`
的输入控件直接返回 null,于是**整个表单一片空白、日志里什么都没有**。那个示例的集成测试
用假 host 硬编码返回值,根本没跑到这段映射 —— **编译绿、单测绿、功能是坏的**。
`plugin-ui.ts:224-234`;示例侧的复盘 `crates/core/src/plugins/hello_it.rs:38-46`。

`type` 映射:`switch`/`bool` → switch 块;`select` → select 块;其余 → input 块,
`password` 走 `type==="password"`,`textarea` 走 `multiline`(`plugin-ui.ts:244-259`)。

★ **提交按钮不画进描述树里**。树是插件写的,把提交塞进去意味着插件忘了写按钮就是一个
关不掉的弹窗。按钮由宿主固定提供(`ui/desktop/components/PluginHost.tsx:192-194`)。
