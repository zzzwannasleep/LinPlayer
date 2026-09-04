# 插件系统 v2 重构规划

> ## 📦 历史文档(2026-09-04 归档)
>
> **本文描述的是已删除的 Rust + React/Tauri 栈**,其中的文件路径、命令、构建方式
> 在当前仓库里**都不存在了**。当前技术栈是 Go 核心层 + C#(Avalonia) Windows 外壳。
>
> 保留它是因为**决策理由**仍有参考价值(为什么这么选、当时排除了什么)。
> 要看它描述的代码:`git show rust-final:<路径>`。
>
> ⚠️ **别照着本文动手** —— 先对当前仓库的实际结构(见 `AGENTS.md` §1)。



> 2026-07-23 定稿。范围：`crates/core/src/plugins` + `apps/desktop` + `ui/` + 独立仓库 `LinplayerPluginsRepository`。
> 本轮只做桌面（Win/Linux）。安卓/TV 下一轮。

---

## 0. 为什么重构

摸底结论（每条都有代码证据，见文末「勘察证据」）：

| 层 | 现状 | 判决 |
|---|---|---|
| JS 运行时 | rquickjs 0.10，64MB 限额 / 30s 看门狗 / fail-closed 权限 / HTTPS+域名白名单 / 5MB/插件存储 | **保留**。独立选型调研（rquickjs vs boa vs deno_core vs wasmtime vs Extism vs WebView）第一推荐就是它 |
| 能力层 `ctx.*` | log / http / storage / player / emby.api / extensions **是真的**；`getCredentials` 硬报错、cfproxy 8 个方法只有 1 个真、ui 只发事件没人收 | 补桩 + 删两块 |
| 贡献点 | 8 种扩展点定义齐全，但 `mediaSources` 跟 `MediaSourceBackend` **零耦合**，是空气 | **本次核心**：打通 |
| 桌面命令 | 9 条全注册 | 保留 |
| 桌面前端 | 只接 5/9 条；插件面板是设置页里 116 行的裸列表；无市场/图标/权限/详情/扩展渲染 | 推倒重做 |
| 安卓/TV | `plugin_` 出现 0 次 | 本轮不做 |
| 插件仓库 | 8 个插件（2 个 iOS 死重）、SPEC 里 `runtime:data/addon` 被 Rust 侧明确拒绝、市场网页是老的 | 重构 |

一句话：**引擎不用换，缺的是贡献点接线 + 数据源打通 + 前端从零 + 仓库对齐。**

---

## 1. 已定决策

| # | 决策 | 取舍 |
|---|---|---|
| D1 | **UI 两层制**：声明式 DSL（覆盖 90%，宿主渲染，TV 焦点白拿）+ iframe 逃生舱（覆盖 10%，任意 HTML/JS） | 自由度和跨端一致两头都要 |
| D2 | **本轮只做桌面** | 链路短、能快速验证整套设计，避免三端同时返工 |
| D3 | **分发 = 官方源 + 自定义源订阅 + 本地安装 + 开发模式热重载** | "自己写自己用"要最顺 |
| D4 | **删 `emby.credentials` 权限和 `ctx.emby.getCredentials()`**，插件自己表单收账密存自己 storage | 宿主永不保存明文密码，攻击面直接消失 |
| D5 | **App 内市场 + 仓库网站都重做**，共用一套卡片语言 | 观感成体系 |
| D6 | **彻底删 `cfproxy` 权限和 cf-proxy 插件** | CF 优选本来就是宿主的活，包成插件反而绕圈；将来做宿主内置设置项 |
| D7 | **重写现有 5 个插件 + 新增 3 个示例插件**（数据源 / 声明式 UI 全块型 / iframe 逃生舱） | 没有参考实现的能力等于没有能力 |
| D8 | **不做下载量/评分**，卡片用 registry 里白拿的静态信息 | 静态站零后端；八个插件的阶段做统计只会是一堆 0 |
| D9 | **图标内联 data URI，包和 registry 继续走 GitHub raw** | 见 6.4。**别把包挪到 Cloudflare** |
| D10 | **不写 v1 兼容层**，`apiVersion < 2` 直接拒装 | 官方总共 8 个插件，兼容层比重写贵；且 `emby.credentials` 这个刚删掉的攻击面会被拖回来 |
| D11 | **只做 sha256 校验和，不做签名** | 防传输损坏和镀包；信任锚是 HTTPS 下的 registry 本身。零密钥管理负担，不会因密钥轮换让老包全部验签失败 |

### 顺带删除

- `plugins/com.linplayer.telegram-notify-ios`、`plugins/com.linplayer.uhdnow-traffic-ios`
- 规范里的 `runtime: "data"` 和 `runtime: "addon"`
  —— `runtime:data` 当年存在的唯一理由是过 iOS App Store 审核（无可执行 JS 的声明式解释器）。
  苹果全线已不做，理由消失，Rust 侧 `manifest.rs` 本来就拒绝它们。**不要在 Rust 侧补声明式解释器。**

---

## 2. 承重梁：插件即数据源

### 2.1 为什么这条是核心

`crates/core/src/source/mod.rs:119` 的 `MediaSourceBackend` trait 只有三个方法：

```rust
async fn list_dir(&self, http, server, dir_id: Option<&str>) -> Result<Vec<SourceEntry>, SourceError>;
async fn search  (&self, http, server, query: &str)          -> Result<Vec<SourceEntry>, SourceError>;
async fn resolve_play(&self, http, server, entry, quality_id) -> Result<ResolvedPlay, SourceError>;
```

**这个接口小到可以直接翻译成 JS 侧三个导出函数，同时又被实测证明足够强**：
`source/stremio.rs`（1303 行）已经用这三个方法扛住了 Stremio 完整的 catalog → meta → stream 三层元数据协议，
靠的是把三层折成虚拟路径（`stremio.rs:8-17`）。够用不是推断，是既成事实。

分派早已是注册表 —— `apps/desktop/src/lib.rs:4472`、`apps/android/src/lib.rs:1958` 都是
`HashMap<SourceKind, Arc<dyn MediaSourceBackend>>`。插件源只要能塞进这张表，
**浏览页 / 搜索 / 播放 / 外挂字幕 / 多清晰度 / 跨服聚合全部白拿，零新页面零新命令。**

唯一卡点是 `source/mod.rs:15` 的 `SourceKind` 是封闭 enum，加源必须改 Rust 重编译。

### 2.2 改造

```rust
// crates/core/src/source/mod.rs
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Hash, Debug)]
#[serde(transparent)]
pub struct SourceKind(String);

impl SourceKind {
    pub fn emby() -> Self { Self("emby".into()) }
    pub fn is_emby(&self) -> bool { self.0 == "emby" }
    /// 插件源:`plugin:<插件id>/<源id>`。一个插件可贡献多个源。
    pub fn plugin(plugin_id: &str, src_id: &str) -> Self {
        Self(format!("plugin:{plugin_id}/{src_id}"))
    }
}
```

**`#[serde(transparent)]` 让线上表示仍是裸小写字符串，跟今天逐字节相同。**
`source/mod.rs:210` 那个 `kind_wire_format_is_lowercase` 测试保持绿，老配置只会更好读（不再有未知变体反序列化失败）。

爆炸半径实测：**20 个 Rust 引用点 + 4 个 TS 引用点**，`config.rs:48` 上面挂着 `#[serde(default)]`。

新增 `crates/core/src/source/plugin_source.rs`：

```rust
pub struct PluginSourceBackend { plugin_id: String, src_id: String, mgr: Weak<PluginManager> }

#[async_trait]
impl MediaSourceBackend for PluginSourceBackend {
    fn kind(&self) -> SourceKind { SourceKind::plugin(&self.plugin_id, &self.src_id) }
    async fn list_dir(&self, _http, server, dir_id) -> ... {
        self.call("listDir", json!([dir_id, server_public(server)])).await
    }
    // search / resolve_play 同理
}
```

注意：**插件源的网络请求走插件自己的 `ctx.http`**（受域名白名单约束），不把宿主 `reqwest::Client` 借给它。
`server` 里的凭据按需下发，不整包丢给 JS。

生命周期：`PluginManager` 启用插件时把它贡献的每个源注册进共享注册表，禁用/卸载时移除。

### 2.3 插件侧写法

manifest 声明（供市场展示，不用运行插件就知道它是数据源）：

```json
"contributes": {
  "dataSources": [{
    "id": "mysrc",
    "name": "我的网盘",
    "icon": "icon.svg",
    "auth": { "fields": [
      { "id": "base_url", "label": "地址",   "type": "url" },
      { "id": "token",    "label": "访问令牌", "type": "password" }
    ]}
  }]
}
```

运行时注册真函数：

```js
ctx.sources.register("mysrc", {
  async listDir(dirId, server) {
    const r = await ctx.http.get(`${server.base_url}/api/list?p=${dirId ?? "/"}`,
                                 { headers: { Authorization: server.token } });
    return r.body.items.map(f => ({
      id: f.path, name: f.name, isDir: f.is_dir,
      isVideo: ctx.util.isVideoName(f.name), size: f.size, thumb: f.thumb, raw: f,
    }));
  },
  async search(q, server) { /* 不支持就 throw ctx.errors.unsupported() */ },
  async resolvePlay(entry, qualityId, server) {
    return { url: ..., title: entry.name, httpHeaders: { Referer: ... },
             subtitles: [], qualities: [] };
  },
});
```

`auth.fields` 由前端通用表单渲染，产物存进既有的 `SourceServer`（`base_url` / `username` / `password` / `token` / `extra`），
**沿用既有落盘和多源并存机制，不新建凭据存储。**

> ⚠️ 写进插件开发文档的实战坑（来自 `stremio.rs:40`）：
> **分页大小必须从响应里学，不能照文档写死。** Cinemeta 文档说每页 100，2026-07-23 实测只回 50。
> 写死的后果是永远只看得到第一页，而且不报错。

### 2.4 `$sourceServer` —— 不补这条，数据源插件是废的

规划自检时发现两个会让本方案在最常见场景上直接失效的洞：

| 洞 | 证据 | 后果 |
|---|---|---|
| `allowed_hosts` 是**发布期固定**的，裸 `*` 已被明确堵死 | `state.rs:26`、`state.rs:53-55` | 通用数据源插件发布时不可能知道用户自建服务器的域名，一个请求都发不出去 |
| 只放行 `https` | `state.rs:108` | 自建 OpenList/飞牛绝大多数是局域网 `http://192.168.x.x:5244`，开箱即拒 |

两条合起来：数据源插件只能访问发布时写死的公网 HTTPS 域名 ——
**做不了网盘和自建服务器，而那正是现有 5 个内置源里的 4 个。**

修法：`httpAllowedHosts` 支持 `$sourceServer` 令牌。

```json
"httpAllowedHosts": ["$sourceServer", "cdn.example.com"]
```

- 运行时展开成**用户在「添加服务器」里亲手填的 `base_url` 的 origin**（含端口）
- **只有 `$sourceServer` 展开出来的 origin 允许明文 http**；manifest 里硬编码的域名仍然 https-only
- 添加服务器时 UI 明示："该插件将访问你填写的地址"；填 http 时补一句"明文传输，局域网可用，公网不建议"
- 一个插件贡献多个源时，各源的 origin 互相隔离，不互通

**边界仍然 fail-closed** —— 放行的只有"用户自己亲手输入的那个地址"。用户没输入过的域名，一个都进不来。

不受此约束的三类（本来就不经插件发请求，白名单管不着也不需要管）：
播放取流（`resolvePlay` 返回 URL，由 mpv 直接拉，含跨域 302）、封面缩略图（前端图片缓存拉）、外挂字幕（播放层拉）。

---

## 3. Manifest v2

八个零散扩展点收敛成四类 `contributes`，位置用 `slot` 表达（抄 VS Code contribution points）——
**以后加新位置不用加新类型。**

```json
{
  "id": "com.example.foo",
  "version": "1.0.0",
  "apiVersion": 2,
  "name": "示例插件",
  "description": "一句话说明",
  "author": "作者",
  "icon": "icon.svg",
  "homepage": "https://...",
  "license": "MIT",
  "minAppVersion": "1.2.0",
  "targets": ["pc", "mobile", "tv"],
  "category": "source | ui | player | notify | tools",
  "main": "main.js",
  "permissions": ["http", "storage", "ui", "player.read"],
  "httpAllowedHosts": ["api.example.com", ".example.org"],
  "contributes": {
    "dataSources":  [{ "id", "name", "icon", "auth" }],
    "panels":       [{ "id", "title", "slot", "handler" }],
    "actions":      [{ "id", "title", "icon", "context", "handler" }],
    "sandboxViews": [{ "id", "title", "entry": "ui.html", "slot" }]
  }
}
```

`panels.slot` 取值：`home.stats` / `sidebar` / `settings` / `player.overlay` / `page`
（老的 `homeStats` / `sidebarItems` / `settingsPages` / `playerOverlays` 折进来）

`actions.context` 取值：`global` / `item` / `player`（老的 `actions` / `contextMenus` 折进来）

`eventListeners` 不再是贡献点 —— 它本来就该是运行时的 `ctx.player.on()`，声明成扩展点是概念错位。

### 权限枚举 v2

| 保留 | `player.read` `player.control` `http` `storage` `ui` `emby.read` `emby.api` `extensions` `log`(隐式) |
|---|---|
| **删除** | `emby.credentials`（D4）、`cfproxy`（D6） |
| **新增** | `sources`（贡献数据源）、`sandbox`（使用 iframe 逃生舱） |

### 破坏性升级

`apiVersion: 2`，**不做 v1 兼容层**。官方仓库总共 8 个插件，全部重写；
宿主遇到 `apiVersion < 2` 的包直接拒装并提示"该插件为旧版本，请联系作者更新"。
写兼容层的成本远高于重写 8 个插件。

---

## 4. UI 第一层：声明式 DSL

插件返回一棵 JSON 树，宿主用自己的 React 组件渲染。Rust 侧只透传，schema 校验在前端。

### 块清单（刻意保持小）

```
布局  Stack{dir,gap,align,children}  Row  Card{title,children}  Divider
展示  Text{text,variant,tone}  Image{src,ratio,fit}  Badge{text,tone}
      Progress{value,label}  Spinner  Empty{icon,text}
输入  Button{label,onTap,variant}  Input{id,label,type,placeholder,value}
      Select{id,label,options}  Switch{id,label,value}
列表  List{items:[{icon,title,subtitle,trailing,onTap}]}
```

14 个块。加块要改宿主 —— 这是刻意的边界，逃生舱负责兜住剩下的需求。

### 交互协议

- `onTap: "handlerName"` → 前端调 `plugin_trigger(pluginId, "panel", panelId, { action, state })`
- 插件返回新的一棵树，前端整树重渲染（**不做 diff/patch**，插件面板都很小，
  `ponytail:` 上限是面板大到闪烁时再上 key-diff）
- 表单：带 `id` 的输入块的值收成 `{id: value}` 一起回传

### 落点

`ui/shared/plugin-ui/schema.ts`（类型 + 校验）
`ui/desktop/plugin-ui/render.tsx`（桌面渲染器）
下一轮：`ui/mobile/plugin-ui/`、`ui/tv/plugin-ui/`（TV 渲染器给每个可聚焦块挂 norigin 焦点）

现有 `ctx.ui.showForm / showList / showDialog / showToast / showProgress` **不删**，
改成这套 DSL 的糖 —— 它们的管道（`plugin://ui-request` + `plugin_ui_respond`）早就铺好了，只是没人接。

---

## 5. UI 第二层：iframe 逃生舱

插件带一个 `ui.html`，宿主用隔离 iframe 装。

**加载方式**：注册 `lpplugin://` 自定义协议，按 `lpplugin://<插件id>/<相对路径>` 从该插件目录读文件。
照抄 `apps/desktop/src/imgcache.rs:32` 已在用的 `register_asynchronous_uri_scheme_protocol`。
只有已启用的插件可被读，路径必须做规范化后前缀校验（防 `../` 穿越）。

```tsx
<iframe
  src={`lpplugin://${id}/${entry}`}
  sandbox="allow-scripts allow-same-origin"  // same-origin 指的是 lpplugin://<id>,与 App 主源隔离
/>
```

**通信**：`postMessage`。iframe 里能调的只有它自己插件的 JS 函数
（经宿主转发到 `plugin_invoke_field`），**拿不到 `__TAURI_INTERNALS__.invoke`**。

> 这才是"插件不能直接把 React 组件塞进主窗口"的真实理由。
> 不是 Tauri CSP —— `apps/desktop/tauri.conf.json:16` 和安卓那份都是 `"csp": null`，压根没注入 CSP。
> 真实理由是主窗口 JS 上下文里有 `__TAURI_INTERNALS__.invoke`，插件代码进去等于拿到宿主全部命令，
> rquickjs 那套权限模型直接变成摆设。

**沙箱视图的权限严格弱于插件本体**：它继承插件已获授权的能力，一分不多。

顺带复用：市场详情页的 README 用 `<iframe sandbox="" srcdoc={html}>` 渲染 —— `sandbox=""` 不给脚本，
所以引入 `marked` 就够了，**不用再加一层 DOMPurify**。复用本来就要建的隔离层，不新建消毒链路。

---

## 6. 分发

### 6.1 registry v2

```json
{
  "schemaVersion": 2,
  "updatedAt": "2026-07-23T00:00:00Z",
  "plugins": [{
    "id", "name", "description", "author", "icon", "category", "tags", "targets",
    "permissions": ["http", "storage"],
    "contributes": { "dataSources": 1, "panels": 2, "actions": 0, "sandboxViews": 0 },
    "versions": [{
      "version", "apiVersion", "minAppVersion",
      "manifestUrl", "packageUrl",
      "sha256",            // ← 新增。现在完全没有校验和
      "publishedAt", "changelog"
    }]
  }]
}
```

`permissions` 和 `contributes` 摘要上移到 registry —— **市场不下载包就能展示权限和能力徽章。**

### 6.2 多源订阅

```rust
struct PluginSource { id, name, url, enabled, builtin }
```

- 官方源 `builtin: true`，可禁不可删
- 按插件 id 去重，官方源优先
- 第三方源的插件卡片打「第三方源」徽章，安装前弹权限确认
- 安装时校验 `sha256`，不匹配直接拒装

### 6.4 分发通道：图标内联，包留在 GitHub

**用户实测口径（2026-07-23 确认，不要凭直觉改）：国内 Cloudflare 有地方会被阻断，GitHub 反而更稳。**
所以**不要**把 `.ipk` 挪到 Cloudflare Pages —— 那是想当然的"优化"，方向是反的。

| 资产 | 通道 | 理由 |
|---|---|---|
| 插件图标 | **构建时压成 data URI 内联进 `registry.json`** | SVG 通常 1–3KB，八个插件总共几十 KB。卡片永远不碎图、零额外请求、零跨域 |
| `.ipk` 包 | **GitHub raw（保持现状）** | 同上口径 |
| `registry.json` | **GitHub raw** | 同上 |
| 市场网站 | Cloudflare Pages（保持现状） | 网站可达性不影响 App —— App 只读 registry 和包，不依赖网站 |

`tools/build.py` 里硬编码的仓库 owner/分支改成读 `GITHUB_REPOSITORY` 环境变量（fork 后仍能出正确 URL），
但**通道本身不变**。

### 6.3 开发模式

- 新增 `plugin_install_dev(dir)`：**记录目录不复制**，插件直接从源目录加载
- 热重载：轮询入口文件 mtime（1s）—— `ponytail:` 轮询而非上 `notify` crate，
  零新依赖；开发模式插件通常只有一两个，代价可忽略。真嫌慢再换 `notify`
- 「从文件安装」走 Rust 侧命令用已注册的 `tauri_plugin_dialog`（`lib.rs:4508`）开原生选择器，
  **不加 `@tauri-apps/plugin-dialog` 前端依赖、不动 capabilities**（那是本仓库已知的坑）

---

## 7. App 内市场（桌面）

从 `设置 → 插件` 里挪出来，做成**侧栏一级页** `/plugins`。

```
┌────────────────────────────────────────────────────────┐
│  发现   已安装 ②                        🔍 搜索        │
│  ─────                                                 │
│  [全部][数据源][界面][播放][通知][工具]   源:[全部 ▾]   │
│                                                        │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐   │
│  │ 🎬            │ │ 📊            │ │ 🔔            │   │
│  │ Stremio 聚合源 │ │ 流量看板      │ │ 播完通知      │   │
│  │ LinPlayer·v2.1 │ │ LinPlayer·1.0 │ │ LinPlayer·1.0 │   │
│  │ 把 Stremio 源 │ │ 首页显示已用  │ │ 看完自动推送  │   │
│  │ 接进浏览页    │ │ 流量和余量    │ │ 到 Telegram   │   │
│  │ [数据源][PC]  │ │ [界面][PC]    │ │ [通知][PC]    │   │
│  │ 🔒网络 ·3天前 │ │ 🔒网络 ·1周前 │ │ 🔒网络 ·1周前 │   │
│  │       [ 安装 ]│ │       [ 安装 ]│ │      [已安装] │   │
│  └──────────────┘ └──────────────┘ └──────────────┘   │
└────────────────────────────────────────────────────────┘
```

**卡片字段**：图标 / 名称 / 作者·版本 / 描述(2 行) / 分类徽章 + 端徽章 / 权限摘要 + 更新时间 / 主按钮

**详情**（右侧滑出面板，符合本项目既有侧滑习惯）：
Hero(图标·名称·作者·版本·安装按钮) → 贡献点清单（"提供 1 个数据源、2 个面板"）→
**权限逐条中文解释**（"访问网络：仅限 api.example.com"）→ README → 版本历史 → 来源

**已安装 tab**：卡片 + 启用开关 + 卸载 + 更新徽章 + 「设置」（用 DSL 渲染器打开插件的 settings 面板）

**贡献点消费**（这是"鸡肋"的病根，必须接）：
`plugin_extensions` / `plugin_trigger` / `plugin_invoke_field` / `plugin_ui_respond` 四条全部接线，
`home.stats` 挂首页、`sidebar` 挂侧栏、`settings` 挂插件详情、`player.overlay` 挂播放页。

**样式约定**（照抄现有体系，不另起炉灶）：
`--panel` 面板底 / `--line` 描边 / `--ink`·`--ink-2`·`--ink-3` 三级文字 / `--accent` 强调 /
`--r-md: 12px` 卡片圆角 / `--dur-med: 240ms` + `--ease` 过渡 / 加载用骨架屏不用转圈

---

## 8. 仓库网站重做

Cloudflare Pages 静态站，读同一份 `registry.json`，共用卡片语言。

- 首页：搜索 + 分类 chips + 卡片网格
- 详情：hash 路由 `#/plugin/com.x.y`，模块同 App 内详情
- 开发指南：从 `SPEC.md` 生成
- `tools/build.py` 去掉硬编码的仓库 owner/分支（改读 `GITHUB_REPOSITORY`），补 `sha256` 生成
- `tools/validate_repo.py` 对齐 v2 权限/贡献点清单，修掉 `author` 校验与 schema 打架的老问题

---

## 9. 插件阵容

| 插件 | 动作 | 说明 |
|---|---|---|
| `com.linplayer.hello` | 重写 | 教学示例，展示 storage + panel + settings |
| `com.linplayer.telegram-notify` | 重写 | 播完通知 |
| `com.linplayer.uhdnow-traffic` | 重写 | 改为自己表单收账密（D4） |
| `com.linplayer.uhdnow-request` | 重写 | 同上 |
| `com.linplayer.uhdnow-speed` | 重写 | 同上 |
| `com.linplayer.cf-proxy` | **删除** | D6 |
| `com.linplayer.telegram-notify-ios` | **删除** | 苹果全线不做 |
| `com.linplayer.uhdnow-traffic-ios` | **删除** | 同上 |
| ★ `example.source-demo` | **新增** | 三个函数做一个完整数据源 |
| ★ `example.ui-demo` | **新增** | 声明式 DSL 全部 14 个块的活样板 |
| ★ `example.iframe-demo` | **新增** | 逃生舱 + postMessage 双向通信 |

---

## 10. 施工顺序

### P0 — Rust 核层 ✅ 已完成(2026-07-23)

施工中相对原计划的**一处偏离**,记在这里免得后面有人照着旧计划改:

> 原计划让插件源在启用/禁用时**注册进/移出** `HashMap<SourceKind, Arc<dyn MediaSourceBackend>>`。
> 实际改成了**现建现用**:`source_backend()` 发现 `kind.as_plugin()` 命中就当场
> `Arc::new(PluginSourceBackend::new(...))`,静态表原封不动。
>
> 理由:`PluginSourceBackend` 是无状态的(只有 plugin_id + src_id + Weak),建一个的成本
> 可忽略;而往一张会被播放链路读的表里动态增删要引入锁 + 生命周期同步,是白挨的复杂度。
> 插件被禁用时自然失效 —— 贡献点注册表里查不到,调用直接报错(有测试钉住)。


1. `SourceKind` → `#[serde(transparent)]` newtype + 守卫测试（老配置反序列化必须绿）
2. `PluginSourceBackend` + 启用/禁用时注册/注销
3. manifest v2：`contributes` 收敛、删 `runtime`/`cfproxy`/`emby.credentials`、`apiVersion:2` 门禁
4. `ctx.sources.register` + `ctx.util.isVideoName` + `ctx.errors.unsupported`
4b. **`$sourceServer` 令牌**（见 2.4）：白名单运行时展开 + 仅该 origin 放行 http。
    守卫测试：未配置源时 `$sourceServer` 展开为空必须拒绝一切；
    配置 A 服后不得访问 B 服；硬编码域名仍须 https
5. `ctx.ui.render`（透传 DSL 树）
6. `lpplugin://` 协议 + 路径穿越防护
7. 多源 registry 拉取/聚合/`sha256` 校验
8. 开发模式：目录安装 + mtime 轮询热重载
9. `plugin_pick_install`（Rust 侧原生文件选择器）

### P1 — 桌面前端
10. `ui/shared/plugin-ui/schema.ts` + `ui/desktop/plugin-ui/render.tsx`
11. 接 `plugin://ui-request` 监听 + `plugin_ui_respond`
12. 市场页：发现 / 已安装 / 详情侧滑 / 权限展示 / 源管理
13. 贡献点消费：`home.stats` / `sidebar` / `settings` / `player.overlay`
14. 数据源接线：插件源进「添加服务器」和浏览页
15. 侧栏加 `/plugins` 一级入口，从设置页移除旧面板

### P2 — 仓库
16. 删 3 个插件（2 iOS + cf-proxy）
17. schema + SPEC.md 升 v2
18. `tools/*.py` 更新
19. 重写 5 个 + 新增 3 个示例插件
20. 网站重做
21. CI 更新

### P3 — 验证（不做完不算交付）
22. `cargo test`：SourceKind 线上格式守卫、老配置兼容、插件源注册/注销、路径穿越拒绝
23. **反向注入真 bug 验证测试会红**（本仓库红线：新测试必须先红）
24. `npm run pack` 出可测 exe（本仓库红线：光编译绿不算交付）
25. 真机闭环：装示例数据源插件 → 浏览 → 搜索 → 播放 → 卸载

---

## 11. 勘察证据

| 结论 | 证据 |
|---|---|
| 引擎是 rquickjs 0.10 | `crates/core/Cargo.toml:32` |
| `getCredentials` 是硬报错 | `apps/desktop/src/plugins_host.rs:111` |
| cfproxy 是桩 | `apps/desktop/src/plugins_host.rs:7` 自述「重活留待接 Phase 5」 |
| `ctx.ui` 无人接收 | `apps/desktop/src/plugins_host.rs:5-6` 自述「React 宿主 UI 是下一步」 |
| 前端只接 5/9 | `ui/shared/api.ts:1166-1172` |
| 安卓 0/9 | `apps/android/src/lib.rs` 中 `plugin_` 命中 0 次 |
| 源分派是注册表 | `apps/desktop/src/lib.rs:4472`、`apps/android/src/lib.rs:1958` |
| trait 只有三个方法 | `crates/core/src/source/mod.rs:119` |
| 三方法能扛 Stremio 三层协议 | `crates/core/src/source/stremio.rs:8-17` |
| `SourceKind` 线上是小写字符串 | `crates/core/src/source/mod.rs:210` 测试 |
| 爆炸半径 20 Rust + 4 TS | `grep -rn source_kind` |
| CSP 没开 | `apps/desktop/tauri.conf.json:16` `"csp": null` |
| 自定义协议已有先例 | `apps/desktop/src/imgcache.rs:32` |
| dialog 插件已注册 | `apps/desktop/src/lib.rs:4508`、用法见 `2304`/`2326` |
| 分页要从响应学 | `crates/core/src/source/stremio.rs:40`（Cinemeta 实测 50 ≠ 文档 100） |

### 外部调研来源

- Stremio Addon 协议 https://stremio.github.io/stremio-addon-sdk/protocol.html
- VS Code contribution points https://code.visualstudio.com/api/references/contribution-points
- VS Code Webview API https://code.visualstudio.com/api/extension-guides/webview
- Figma 插件双进程模型 https://www.figma.com/blog/how-we-built-the-figma-plugin-system/
- Obsidian 社区插件分发 https://github.com/obsidianmd/obsidian-releases
- Raycast 扩展（React 作为扩展 UI）https://developers.raycast.com/
- Kodi `plugin://` 虚拟路径 https://kodi.wiki/view/Plugin_sources
- Jellyfin 仓库订阅制 https://jellyfin.org/docs/general/server/plugins/
- Adaptive Cards schema https://adaptivecards.io/explorer/
- Slack Block Kit https://docs.slack.dev/block-kit/
- rquickjs 中断/内存 API https://docs.rs/rquickjs/
- deno_core Android 崩溃（已排除该候选）https://github.com/denoland/deno/issues/13936

### P1 — 桌面前端 ✅ 已完成(2026-07-23)

新增/改动:
| 文件 | 作用 |
|---|---|
| `apps/desktop/src/pluginmarket.rs` | 市场后端:多源订阅持久化 / 聚合拉取 / 下载校验安装 / 权限词表透出 |
| `ui/shared/plugin-ui.ts` + `.test.mjs` | 声明式 UI 的 14 种块 + **消毒**(深度/节点数封顶、URL 协议白名单),node 可直跑 |
| `ui/desktop/components/PluginView.tsx` | 描述树渲染器(宿主组件,自动跟主题) |
| `ui/desktop/components/PluginHost.tsx` | `plugin://ui-request` 接线 + `PluginSlot` 槽位 |
| `ui/desktop/pages/PluginsPage.tsx` | 市场页:发现 / 已安装 / 插件源 + 详情抽屉 + 授权弹窗 |
| `ui/desktop/theme/plugins.css` | 全部样式 |
| nav / Shell / HomePage / App / AddServerPage | 侧栏入口、四个槽位、插件源登录表单 |

**槽位落点(与原计划的偏离)**:`settings` 槽的面板画在**插件详情抽屉的「设置」标签**里,
不是设置页的某个二级项 —— 用户找「这个插件怎么配」的第一反应是点开这个插件(VS Code 同款)。

**真机端到端跑通(CDP 驱动真实 exe)**:订阅本地 v2 源 → 刷新市场 → 下载+sha256 校验安装 →
默认停用 → 授权确认 → 启用 → 数据源出现在「添加服务器」并按 manifest 渲染登录表单 →
首页面板渲染声明式 UI → 点按钮 → 面板刷新。

**这一轮真机抓到、编译和单测都看不见的 7 个 bug**(全部已修 + 反向注入验证):
1. `SourceKind` 前端写成首字母大写 —— 每处比较恒 false、每次 `sourceLogin` 送错值,两边都不报错(**先于本轮就已存在**)
2. 契约测试解析器对内联对象泛型踩空 —— 那条命令悄悄不受闸门保护
3. 运行时注册整条顶掉 manifest 静态声明 —— 数据源丢掉 name 和 auth 表单
4. `panels/actions` 要的权限 `ui` 与 `ctx.extensions.register` 要的 `extensions` 对不上
5. `onEnable` 抛错被 `let _ =` 吞掉 —— 插件半死不活而界面显示"已启用、无错误"
6. `register` 收到非对象描述照单全收,编一个 `ext_N` 的幽灵贡献
7. 面板 handler 返回 null 时不刷新 —— 点按钮完全没反应
8. registry 全部条目解析失败时报 0 插件 0 错误 —— 和"空源"无法区分
9. 市场缓存只存插件不存错误 —— 二次进入警告条消失
10. 浮层 `inset:0` 被 z-index 90 的自绘标题栏盖住 36px —— 抽屉头部被切

---

### P2 — 插件仓库重写 ✅ 已完成(2026-07-23)

仓库:`D:\LinplayerPluginsRepository`(独立 repo,GitHub Pages 托管)。

**先做的减法**:删 layui + animate.css(约 1MB vendor,只为三个页签和一个弹层)、
删「按端分三个页签」(同一批插件画三遍,正是「鸡肋」的具体形态)、删 `blocked.json`
(宿主 `parse_registry` 根本不读它 —— 一个不生效的封杀开关比没有更糟)、
删 `registry.schema.json`/`blocked.schema.json`(没有任何代码在用,纯属规则的第三份手抄副本)、
删 3 个插件(2 个 iOS + cf-proxy,后者已实证是宿主内置功能)。

**插件阵容(6 个,覆盖全部 4 类贡献点)**:

| id | 分类 | 贡献点 |
|---|---|---|
| `hello` | tools | panels(home.stats + settings) |
| `ui-kit` | ui | panels(page + settings) —— 14 种界面块的活样例 |
| `sandbox-demo` | ui | sandboxViews —— iframe 逃生舱 |
| `m3u` | source | dataSources —— 真能用的 M3U 直播源 |
| `telegram-notify` | notify | panels(settings) + player.on |
| `uhdnow` | tools | panels ×3 —— v1 三个插件合并,账号只填一次 |

**工具链**:`build.py` 仓库地址改从 `GITHUB_REPOSITORY`/git remote 推导(推不出就报错中止,
绝不退回猜测默认值);registry 版本键改 snake_case;`author` 改字符串;图标构建期内联成
data URI;每包算 sha256;**产物可复现**(无任何时间戳,重跑逐字节一致,CI 靠这个判断产物是否过期)。
`validate_repo.py` 重写成宿主规则的镜像并**自带 23 条注入自检**。

**跨仓库契约的守门人**:`crates/core/src/plugins/registry_index.rs::the_real_official_registry_shape_parses_with_nothing_skipped`
把 build.py 真实产出的形状一字不改钉在核层测试里。两个仓库的字段名对不上时,
两边都不报错、市场只显示 0 个插件 —— 这条测试是唯一能提前发现的地方。

#### P2 顺带修的宿主 bug(全部是「两边都不报错」类)

| # | Bug | 后果 |
|---|---|---|
| 1 | `source_login` **先验证后授权** | `$sourceServer` 白名单晚一步注册,**任何需要用户填地址的插件数据源都永远添加不上**。P1 的演示插件 listDir 返回写死数据、一个请求都不发,所以没撞上 |
| 2 | `pluginassets.rs` 拿 `uri.host()` 当插件 id | Windows 上是 `lpplugin.localhost`、Linux 上是 `localhost`,两边都不是插件 id → **所有插件图标和逃生舱页面静默 403**。同仓库的 `lpimg` 从第一天起就只认 path |
| 3 | 前端从不转换 `lpplugin://` | 消毒器放行这个协议,但 WebView2 不认 → 图片是坏图且无报错 |
| 4 | `sandboxViews` 后端全通、前端只**数个数** | 「极高自由度」的逃生舱等于没有 |
| 5 | `sidebar` / `page` 两个 slot 从未渲染 | 插件挂上去永远看不见 |
| 6 | `hello_it.rs` 参考示例教 `{metrics:[…]}` | 那是 v1 形状,`sanitizeTree` 走 default 返回 null → **照抄官方示例写出来的面板是一片空白** |
| 7 | 同一示例教 `showForm` 用 `key`/`default` | 真实映射读 `id`/`value`,没有 id 的控件被整棵消毒掉 → **表单一片空白**。该示例的集成测试用假 host 硬编码返回值,从没跑到这段映射 |
| 8 | 树消毒成 null 时静默画空 | 「插件交了东西但画不出来」和「插件什么都没交」不该长得一样 |

修法:1 加 `grant_plugin_source_host` 在验证前授权(失败后重算撤销);2 改按 path 第一段取
(带 3 条单测);3 加 `resolvePluginAssetUrl`;4/5 新增 `PluginViewPage` + `pluginview` 路由 +
侧栏动态入口 + 详情页「打开界面」;6/7 改示例并把 `formTree` 提到 `ui/shared/plugin-ui.ts`
(node 可直跑单测钉住字段名);8 画一条说人话的提示。

#### 目前诚实的限制(已写进 SPEC)

- 插件**只在 PC 可用**:`apps/android/src/lib.rs` 里 plugin 命令数 = 0,`ui/tv` 不渲染任何插件槽位。
  所以官方插件 `targets` 一律只写 `pc`,不写 `["pc","mobile","tv"]` 骗人。
- `ctx.http` 无流式进度(只有整体读完 / `discardBody` 只数字节),UHDNow 测速因此没有实时百分比。
- 沙箱视图与 main.js 之间无消息通道。
- `ctx.ui.openPage` 未实现。
