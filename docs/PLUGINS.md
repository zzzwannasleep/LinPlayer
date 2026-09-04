# LinPlayer 插件系统

一个基于 **[goja](https://github.com/dop251/goja)**（纯 Go 的 ECMAScript 引擎）的插件系统：
每个插件跑在自己的专用 goroutine 上，通过受权限控制的 `ctx` API 与宿主交互，
并可向预定义的扩展点挂载自定义功能。

> 本文讲的是**插件运行时与契约**。市场（安装源/列表页/权限弹窗/声明式 UI 槽位）
> 当时的设计文档随 Rust 栈一起删除,要看走 `git show rust-final:docs/PLUGINS_V2_PLAN.md`。
> 目前插件**只在 PC 端可用**。

## 目录结构

实现全在 `core/plugin/`（平台无关，各端共用）：

```
core/plugin/
├── manifest.go        # manifest.json 解析与校验
├── permission.go      # 权限定义 / 授予 / 校验
├── engine.go          # goja 引擎 + 每插件一条专用 goroutine + 空转看门狗
├── ctx.go             # Host 接口 + 宿主侧 ctx.* 分发器(权限检查在这)
├── ctxhttp.go         # ctx.http.* 的落地
├── netpolicy.go       # 出网准入判定(白名单 / $sourceServer 令牌展开)
├── state.go           # 运行时状态
├── storage.go         # 每插件独立存储(有配额)
├── manager.go         # 扫描/安装/启用/禁用/卸载/触发
├── installer.go       # 插件包解压与校验
├── contributions.go   # 扩展点收集
├── registryindex.go   # 插件市场索引
├── market.go          # 插件源
├── convert.go / assets.go
```

宿主侧接线：`core/plugincmd/`（`commands.go` 命令注册 + `host.go` 宿主能力），
UI 在 `apps/windows/`。

### 插件放在哪

`plugin.NewManager(host)` 在 base 目录下建两个目录（要自定路径走 `NewManagerAt`）：

- `plugins/<id>/` —— 安装后的插件文件（重装整体覆盖该子目录）
- `plugin_data/<id>/` —— 插件存储，**与插件目录分离**，所以升级/重装不丢数据
- `plugins_state.json` —— 启用状态与已授权限

`base_dir` 由各壳决定，目标都是「卸载即清理、不残留」：

| 平台 | base_dir | 卸载是否自动清理 |
|------|----------|------------------|
| Windows / Linux（压缩包分发） | `userdata/data/plugins`，即 **exe 同级的 userdata 里** | 删掉应用文件夹即清理 |
| Android | 应用私有目录（沙盒内） | ✅ 系统卸载时随沙盒一并删除 |

> **不要**用系统的「应用配置目录」API：那类路径由系统 identifier
> 推出来的另一个根，会在 `%APPDATA%` 下再开一份，而且改 identifier 就让已装插件静默失联。
> 所有数据的唯一出口是 `core/paths`。

## manifest.json

```json
{
  "id": "com.example.foo",          // 必填：反向域名，唯一
  "version": "1.0.0",               // 必填：语义化版本
  "name": "示例插件",                // 必填
  "author": "作者",
  "description": "一句话说明",
  "main": "main.js",                // 入口，默认 main.js
  "permissions": ["http", "storage"],
  "httpAllowedHosts": ["api.example.com", "*.cdn.example.com"],  // 联网必填，fail-closed
  "extends": {                      // 可选：静态声明扩展点
    "settingsPages": [
      { "id": "settings", "title": "设置", "handler": "openSettings" }
    ]
  }
}
```

## ctx API（暴露给插件）

| 能力 | 方法 | 所需权限 |
|------|------|----------|
| `ctx.log` | `info/warn/error` | 始终允许 |
| `ctx.http` | `get(url,opts)` / `post(url,body,opts)` | `http`（仅 HTTPS + 白名单） |
| `ctx.storage` | `get/set/delete/keys/clear` | `storage`（上限 5MB） |
| `ctx.player` | `getCurrentMedia` | `player.read` |
| `ctx.player` | `play/pause/seek` | `player.control` |
| `ctx.player` | `on(event,fn)/off(event,fn)` | `player.read` |
| `ctx.ui` | `showToast/showDialog/showForm/openPage` | `ui` |
| `ctx.emby` | `getCurrentUser/getServerUrl/getServerInfo` | `emby.read` |
| `ctx.emby` | `getCredentials()`（返回 username/password/url） | `emby.credentials` |
| `ctx.emby` | `apiRequest({method,path,query,body})` | `emby.api` |
| `ctx.extensions` | `register(type,desc)/unregister(type,id)` | `extensions` |

所有 `ctx.*` 调用都返回 Promise；权限不足会以 JS 异常形式 reject。

播放器事件：`onPlay` / `onPause` / `onPlayEnd`（用 `ctx.player.on` 订阅）。

## 贡献点（contributions）

插件把能力「挂载」到宿主的预定义位置。**v2 收敛成 4 类 × slot**（抄 VS Code 的 contribution points）：

| 类型 | 作用 | 需要的权限 |
|------|------|-----------|
| `dataSources` | 贡献一个完整数据源（浏览/搜索/播放），接进宿主的 `MediaSourceBackend` | `sources` |
| `panels` | 贡献一块 UI，挂在 `slot` 指定的位置 | `extensions` |
| `actions` | 贡献一个操作项，出现在 `context` 指定的上下文 | `extensions` |
| `sandboxViews` | 贡献一个 iframe 逃生舱视图 | `extensions` |

以后加新位置**只加 slot 常量，不加类型**。

- 静态：在 manifest 的 `contributes` 里声明；
- 动态：运行时 `ctx.extensions.register(kind, descriptor)`。

宿主侧由 `plugin.Registry`（`core/plugin/contributions.go`）收集，前端读它渲染。

> ⚠️ **v1 的 8 个老扩展点名（`sidebarItems` / `mediaSources` / `eventListeners` /
> `settingsPages` / `homeStats` / `playerOverlays` / `contextMenus` / `actions`平级版）
> 一律不再识别**，`core/plugin/manifest_test.go:25` 有条测试逐个钉这 7 个名字 —— 认了会让 v1 插件
> 半死不活地跑起来。`eventListeners` 被直接删掉：它本来就该是运行时的
> `ctx.player.on()`，声明成扩展点是概念错位。

**每类贡献都必须绑一个权限。** 漏绑 = 用户在授权弹窗里看不见、却被挂上了东西。
注意 `panels`/`actions` 要的是 `extensions` 而**不是** `ui`（后者管的是 `ctx.ui.*` 弹提示/对话框）——
第一版写成 `ui`，结果是只声明了 `ui` 的插件能过静态校验、运行时注册面板却被拒，
而那个异常发生在 `onEnable` 里被吞掉，表现为**插件显示已启用、面板永远是空的**。

## 安全模型

- **权限声明制**：启用前弹窗征得用户同意，同意结果落 `plugins_state.json`。
- **隔离**：每个插件一个 goja 引擎，钉在自己的一条 goroutine 上（goja 的 Runtime 不是并发安全的，
  所有对 VM 的触碰都投进 jobs 通道串行执行）；插件 JS 崩溃/栈溢出只毁自己，宿主始终响应。
  ⚠️ **没有内存上限** —— rquickjs 版靠 `set_memory_limit(64MB)`，goja 没有对应能力，
  所以 `MaxEnabled = 16` 那道闸在 Go 版只剩「限数」，不再等于「限内存」（`core/plugin/manager.go:16`）。
- **网络**：仅 HTTPS，且受 `httpAllowedHosts` 白名单约束 —— **fail-closed**：不写 =
  拒绝所有出网（不是放行）。支持 `*.example.com` 子域通配（不覆盖主域本身，裸 `*`
  不算通配）。重定向后的最终 host 也要在白名单内。实现见 `core/plugin/netpolicy.go`。
- **无文件系统**：不暴露 fs / 模块加载（`import` 被拒绝）。
- **空转看门狗**：`vm.Interrupt`，墙钟 30 秒（`WatchdogMS`）。判据是**无任何宿主交互**的时长 ——
  每次触碰宿主都把 deadline 往后推，所以「弹个表单等用户填」不会被误杀，
  而纯 JS 死循环在 30s 后被中断。

## 打包与安装（.lpk）

插件包 = 含 `manifest.json` + `main.js`(+assets) 的 zip。

打包脚本在**独立的插件仓库**里（`build.py`），不在本仓库。产物必须可复现
（无时间戳、强制 LF），registry 索引的键是 snake_case、`author` 是字符串 —— 这是硬契约，
写错会被静默清空成空列表。

安装：设置 → 插件 → 从插件源安装，或选本地包 → 解压到 `plugins/<id>/` 并校验清单 →
同意权限后启用。启用状态与已授权限存在 `plugins_state.json`。

## 依赖说明

- **`goja`（`github.com/dop251/goja`）** —— 纯 Go 的 ECMAScript 解释器，无 cgo，
  三端交叉编译不用为各平台准备 FFI binding。这是核心层**唯一**的第三方依赖
  （见 `core/go.mod` 顶部注释）。
- **`archive/zip`（标准库）** —— 插件包解压。
  ⚠️ Go 的 `archive/zip` **不做**路径逃逸检查（Rust 的 zip crate 有 `enclosed_name`），
  所以那道校验是我们自己在 `installer.go` 里补的。

> 历史：Flutter 时代用的是 vendored `flutter_qjs`（pub 上的 0.3.7 在 Dart 3.x 下编不过，
> 打了补丁放在 `third_party/`）。那套连同整个 Dart 栈已于 2026-07 删除，这里只留一句免得考古。
