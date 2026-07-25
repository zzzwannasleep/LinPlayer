# LinPlayer 插件系统

一个基于 **QuickJS**（Rust 绑定 [`rquickjs`](https://github.com/DelSkayn/rquickjs)）的插件系统：
每个插件跑在自己的专用 worker 线程上，通过受权限控制的 `ctx` API 与宿主交互，
并可向预定义的扩展点挂载自定义功能。

> 本文讲的是**插件运行时与契约**。市场（安装源/列表页/权限弹窗/声明式 UI 槽位）
> 的设计与落地进度见 [PLUGINS_V2_PLAN.md](./PLUGINS_V2_PLAN.md)。
> 目前插件**只在 PC 端可用**。

## 目录结构

实现全在 `crates/core/src/plugins/`（平台无关，桌面与安卓共用）：

```
crates/core/src/plugins/
├── mod.rs             # 对外入口
├── manifest.rs        # manifest.json 解析与校验
├── permission.rs      # 权限定义 / 授予 / 校验
├── engine.rs          # rquickjs 引擎
├── worker.rs          # 每插件一条专用线程(QuickJS runtime 单线程,不跨线程)
├── ctx.rs             # 宿主侧 ctx.* 分发器(权限检查在这)
├── host.rs            # PluginHost trait —— 平台能力(UI/播放器/网络)由各壳实现
├── state.rs           # 运行时状态 + 出网白名单
├── storage.rs         # 每插件独立存储(有配额)
├── manager.rs         # 扫描/安装/启用/禁用/卸载/触发
├── installer.rs       # 插件包解压与校验
├── contributions.rs   # 扩展点收集
├── registry_index.rs  # 插件市场索引
├── convert.rs / assets.rs / hello_it.rs
```

宿主侧接线：`apps/desktop/src/lib.rs`（`plugins_host::make_host` + Tauri 命令），
前端在 `ui/desktop/pages/`。

### 插件放在哪

`PluginManager::new(base_dir, host)` 在 `base_dir` 下建两个目录：

- `plugins/<id>/` —— 安装后的插件文件（重装整体覆盖该子目录）
- `plugin_data/<id>/` —— 插件存储，**与插件目录分离**，所以升级/重装不丢数据
- `plugins_state.json` —— 启用状态与已授权限

`base_dir` 由各壳决定，目标都是「卸载即清理、不残留」：

| 平台 | base_dir | 卸载是否自动清理 |
|------|----------|------------------|
| Windows / Linux（压缩包分发） | `userdata/data/plugins`，即 **exe 同级的 userdata 里** | 删掉应用文件夹即清理 |
| Android | 应用私有目录（沙盒内） | ✅ 系统卸载时随沙盒一并删除 |

> 桌面端**不要**用 Tauri 的 `app_config_dir()`：那是由 `tauri.conf.json` 的 identifier
> 推出来的另一个根，会在 `%APPDATA%` 下再开一份，而且改 identifier 就让已装插件静默失联。
> 所有数据的唯一出口是 `crates/core/src/paths.rs`。

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

宿主侧由 `ContributionRegistry`（`crates/core/src/plugins/contributions.rs`）收集，前端读它渲染。

> ⚠️ **v1 的 8 个老扩展点名（`sidebarItems` / `mediaSources` / `eventListeners` /
> `settingsPages` / `homeStats` / `playerOverlays` / `contextMenus` / `actions`平级版）
> 一律不再识别**，`contributions.rs` 里有条测试专门钉这件事 —— 认了会让 v1 插件
> 半死不活地跑起来。`eventListeners` 被直接删掉：它本来就该是运行时的
> `ctx.player.on()`，声明成扩展点是概念错位。

**每类贡献都必须绑一个权限。** 漏绑 = 用户在授权弹窗里看不见、却被挂上了东西。
注意 `panels`/`actions` 要的是 `extensions` 而**不是** `ui`（后者管的是 `ctx.ui.*` 弹提示/对话框）——
第一版写成 `ui`，结果是只声明了 `ui` 的插件能过静态校验、运行时注册面板却被拒，
而那个异常发生在 `onEnable` 里被吞掉，表现为**插件显示已启用、面板永远是空的**。

## 安全模型

- **权限声明制**：启用前弹窗征得用户同意，同意结果落 `plugins_state.json`。
- **隔离**：每个插件一个 QuickJS 引擎（`AsyncRuntime` + `AsyncContext`），钉在自己的 worker 线程上，
  **内存上限 64MB**；插件 JS 崩溃/栈溢出只毁自己，宿主始终响应。
- **网络**：仅 HTTPS，且受 `httpAllowedHosts` 白名单约束 —— **fail-closed**：不写 =
  拒绝所有出网（不是放行）。支持 `*.example.com` 子域通配（不覆盖主域本身，裸 `*`
  不算通配）。重定向后的最终 host 也要在白名单内。实现见 `crates/core/src/plugins/state.rs`。
- **无文件系统**：不暴露 fs / 模块加载（`import` 被拒绝）。
- **空转看门狗**：用 QuickJS 的 **interrupt handler**（真 CPU 中断，不是墙钟兜底）。
  它**只在 JS 真跑字节码时触发**，等宿主 UI/网络的 `await` 期间不触发 ——
  所以「弹个表单等用户填」这种交互式流程不会被误杀，而纯 JS 死循环在 30s 无宿主交互后被中断。

## 打包与安装（.lpk）

插件包 = 含 `manifest.json` + `main.js`(+assets) 的 zip。

打包脚本在**独立的插件仓库**里（`build.py`），不在本仓库。产物必须可复现
（无时间戳、强制 LF），registry 索引的键是 snake_case、`author` 是字符串 —— 这是硬契约，
写错会被静默清空成空列表。

安装：设置 → 插件 → 从插件源安装，或选本地包 → 解压到 `plugins/<id>/` 并校验清单 →
同意权限后启用。启用状态与已授权限存在 `plugins_state.json`。

## 依赖说明

- **`rquickjs`（`crates/core/Cargo.toml`）** —— QuickJS 的纯 Rust 绑定，可交叉编译到安卓。
  启用 `macro`（`async_with!`）+ `futures`（AsyncRuntime）。
  **不启 `parallel`**：QuickJS runtime 本就单线程，我们让每个插件钉在自己的 worker 线程上
  （`worker.rs`），从不跨线程共享 runtime。
  安卓无预生成的 FFI bindings，构建期用 `bindgen` 现生成（cargo-ndk 会喂 sysroot）；桌面走预生成。
- **`zip`** —— 插件包解压（只启 `deflate`）。

> 历史：Flutter 时代用的是 vendored `flutter_qjs`（pub 上的 0.3.7 在 Dart 3.x 下编不过，
> 打了补丁放在 `third_party/`）。那套连同整个 Dart 栈已于 2026-07 删除，这里只留一句免得考古。
