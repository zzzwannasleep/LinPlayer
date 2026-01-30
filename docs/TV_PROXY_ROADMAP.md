# LinPlayer + TV 内置代理（mihomo + metacubexd）实施路线图

本文目标：在保持 **单一主干可持续演进** 的前提下，为 **Android TV** 提供 **可选开关的内置代理（mihomo）+ 管理面板（metacubexd）**，并让 **App HTTP 请求 + 播放器网络流（mpv）** 在需要时走代理，从而更顺畅访问境外服务端。

---

## 0. 结论与原则（先统一口径）

### 0.1 结论
- 可以做，并且推荐用 **“主干 + 适配层（Server Adapter）+ Feature Flags + 可选模块（TV Proxy）”** 的方式做。
- 不建议维护额外的长期业务分支；差异应该收口在少数明确的“收口点”里。

### 0.2 设计原则（以后所有 PR 都按这个来）
- **差异只允许出现在少数收口点**：Feature Flags、Server Adapter、TV 专用模块。
- **UI 不直接依赖具体服务端实现**：UI 只依赖抽象接口（adapter），不在 UI 到处 new 具体 API。
- **尽量“加层不改逻辑”地渐进迁移**：先把插槽/骨架立起来，再逐步搬迁实现，避免一次性大改导致回滚困难。

---

## 1. 目标矩阵（最终形态）

### 1.1 产品（Product）
- `LinPlayer`：通用跨平台播放器（当前项目）。

### 1.2 形态（Form Factor）
- 全端：Android / iOS / Windows / macOS / Linux / Web（同一套 UI/核心）
- TV：先定义为 **Android TV**（由 `DeviceType.isTv` 判定）

### 1.3 TV 内置代理能力（只对 TV 形态开放）
- 设置页提供开关：`是否启用内置代理`
- 开启后：
  - 启动 `mihomo`（仅本机回环）
  - 启用并提供 `metacubexd` 面板（本机回环 Web UI）
  - App 内 HTTP 请求 + 播放器网络流（mpv）可走代理

---

## 2. 推荐落地方式（代码结构）

> 先不大迁移目录，优先在现有工程上“叠加骨架”。等骨架稳定再抽成 `packages/`。

### 2.1 第一阶段（低风险：先留在 `lib/`）
- `lib/services/http_client_factory.dart`（新增/统一入口）
  - 统一创建 `HttpClient/IOClient` 的入口，为后续“走代理”铺路
- `lib/services/built_in_proxy/`（新增）
  - `built_in_proxy_service.dart`：`start/stop/status`
  - `android_tv/`：Android TV 进程启动、资产解压、权限/兼容性处理
- `lib/server_adapters/`（若尚未收口）
  - 定义 UI 真实使用到的最小接口
  - 用 wrapper 封装现有实现，避免侵入式重构

### 2.2 第二阶段（稳定后抽离到 `packages/`）
- `packages/core`：通用状态、工具、网络、播放器配置、通用 UI 基建
- `packages/server_common`：统一的 Server Adapter 接口定义
- `packages/tv_proxy`：mihomo + 面板（TV only）

---

## 3. 构建与产物方案（单产品 + TV）

- 先 **运行时区分 TV**（`DeviceType.isTv`）：复杂度最低、最易验证。
- 后续如需更“TV 化”的 APK（更小体积、不同入口/权限/资源），再考虑增加 `tv` flavor（或独立 target）。

---

## 4. 路线图（里程碑 + 验收标准）

> 每个里程碑都要可验收；通过后再进入下一步。

### M0：统一规则与命名（半天）
**任务**
- 定义 Feature Flags 的命名规范与收口点边界（哪些地方允许出现平台/形态差异）。

**验收**
- README/本文件确认后，后续改动按规则走。

---

### M1：TV 形态基础（1–3 天）
**任务**
- 设置页新增 TV 专区（仅 `DeviceType.isTv == true` 显示）。
- TV 下按需调整 UI（焦点/遥控等）与不适配入口的隐藏。

**验收**
- Android TV 上能看到 TV 专区，非 TV 不显示。

---

### M2：TV 内置代理 MVP（先不做面板）（2–5 天）
**任务**
1. 新增 `BuiltInProxyService`：`start/stop/status`。
2. 设置页 TV 专区增加开关：
   - `是否启用内置代理`
   - 展示状态：未运行/运行中/失败（失败原因）
3. 仅在 Android TV 支持；其他平台隐藏或显示“不支持”。

**验收**
- 开关打开：mihomo 进程启动成功（至少端口可用、进程存活）。
- 开关关闭：mihomo 能停止。
- 不影响非 TV。

---

### M3：接入 metacubexd 面板（2–4 天）
**任务**
1. 将 metacubexd 作为静态资源打包进 App（Android assets），启动时解压到本地目录。
2. mihomo 配置：
   - `external-controller: 127.0.0.1:<port>`
   - `external-ui: <解压后的目录>`
3. 设置页提供按钮：`打开代理面板`（WebView 打开本地地址）。

**验收**
- TV 上可打开面板、添加订阅、看到节点/规则变化。

---

### M4：让“App 网络 + 播放器”真正走代理（关键）（2–6 天）
**任务**
1. App HTTP（`package:http`）
   - 增加 `HttpClientFactory`：代理开时设置 `findProxy` 指向 `127.0.0.1:<mixedPort>`
   - 现有网络请求统一用工厂创建的 client
2. 播放器（`media_kit` / mpv）
   - 代理开：向 mpv 注入 `http-proxy=...`（或等价参数）确保媒体流也走代理

**验收**
- 代理开：访问与播放明显改善。
- 代理关：行为恢复正常。

---

### M5：工程化与合规（1–3 天）
**任务**
- 安全：所有端口只监听 `127.0.0.1`；必要时为 controller 增加 token/secret。
- 兼容性：对 `noexec` 等导致二进制无法执行的设备给出明确错误提示（后续可升级为原生 Service/JNI 方案）。
- 合规：确认 mihomo / metacubexd 许可证与分发声明（README/关于页）。

**验收**
- 错误可定位、默认安全、合规信息齐全。

---

## 5. TV 内置代理实现备注（提前避坑）

### 5.1 二进制分发与执行（Android）
- 常见方案：把 `mihomo` 按 ABI 放到 assets（或 jniLibs），运行时解压到 app 私有目录并 `chmod +x`，再用 `Process.start` 启动。
- 风险：少数设备可能对 app 私有目录 `noexec`，导致无法执行；需要在 UI 给出明确错误提示。

### 5.2 安全性（默认只监听 loopback）
- `external-controller`、`mixed-port`、`socks-port` 都只绑定 `127.0.0.1`，避免同网段可访问。
- （可选）为 controller 加 secret/token，避免本机其他 app 乱连。

### 5.3 许可证合规
- `mihomo` 与 `metacubexd` 需要确认许可证与分发要求（README/关于页中声明）。

---

## 6. 下一步（从哪里开始）

建议从 **M1（TV 形态基础）** 开始：改动最小、可快速验收、也为后续代理开关提供落点。

