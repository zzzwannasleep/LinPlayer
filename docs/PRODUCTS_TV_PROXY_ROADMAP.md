# 多产品（Lin/Emos/UHD）+ TV 内置代理（mihomo + metacubexd）实施路线图

本文目标：把当前单一工程改造成 **一条主干可持续同步**、同时可产出 **3 个产品（Lin/Emos/UHD，全端）**，并在 **Android TV** 上提供 **可选开关的内置代理（mihomo）+ 管理面板（metacubexd）**。

---

## 0. 结论与原则（先统一口径）

### 0.1 结论
- 可以做，并且推荐用 **“主干 + 产品配置（AppProduct）+ 适配层（Server Adapter）+ 可选模块（TV Proxy）”** 的方式做。
- 不建议长期维护 3 条业务分支（`emos/uhd/tv`），那会让同步功能越来越难。

### 0.2 设计原则（以后所有 PR 都按这个来）
- **差异只允许出现在少数“收口点”**：产品配置、Server Adapter、Feature Flags、TV 专用模块。
- **UI 不直接依赖具体服务端实现**（例如不要在 UI 到处 new `EmbyApi`），只依赖抽象接口。
- **尽量“加层不改逻辑”地渐进迁移**：先把插槽/骨架立起来，再逐步搬迁实现。

---

## 1. 目标矩阵（你要的最终形态）

### 1.1 产品（Product）
- `LinPlayer`：通用（现在这套）
- `EmosPlayer`：专门适配 Emos 服务器
- `UPlayer`：专门适配 UHD 服务器

### 1.2 形态（Form Factor）
- 全端：Android / iOS / Windows / macOS / Linux / Web（能跑同一套 UI/核心）
- TV：先定义为 **Android TV**（由 `DeviceType.isTv` 判定）

### 1.3 TV 内置代理能力（只对 TV 形态开放）
- 设置页提供开关：`是否启用内置代理`
- 开启后：
  - 启动 `mihomo`（本机回环）
  - 启用并提供 `metacubexd` 面板（本机回环 Web UI）
  - App 内的 HTTP 请求 + 播放器网络流（mpv）可走代理，从而更顺畅访问境外 Emby

---

## 2. 推荐落地方式（代码结构）

> 先不大迁移目录，优先在现有工程上“叠加骨架”。等骨架稳定再抽成 `packages/`。

### 2.1 第一阶段（低风险：先留在 `lib/`）
- `lib/app_config/`（新增）
  - `app_product.dart`：`enum AppProduct { lin, emos, uhd }`
  - `app_config.dart`：产品名、UA、feature flags、默认开关等
  - `app_config_scope.dart`：`InheritedWidget`/Scope，供全 app 读取
- `lib/services/http_client_factory.dart`（新增）
  - 统一创建 `HttpClient/IOClient` 的入口，为后续“走代理”铺路
- `lib/services/built_in_proxy/`（新增）
  - `built_in_proxy_service.dart`：start/stop/status
  - `android_tv/`：Android TV 进程启动/资产解压等实现

### 2.2 第二阶段（稳定后抽离到 `packages/`）
- `packages/core`：通用状态、工具、网络、播放器配置、通用 UI 基建
- `packages/server_common`：统一的 Server Adapter 接口定义
- `packages/server_lin`：当前 Emby/Jellyfin/Plex/WebDav 适配实现（把现有实现包起来）
- `packages/server_emos`：Emos 适配
- `packages/server_uhd`：UHD 适配
- `packages/tv_proxy`：mihomo + 面板（TV only）

---

## 3. 构建与产物方案（3 产品全端 + TV）

### 3.1 通用方案：用 `--dart-define` 区分产品
- 约定：`APP_PRODUCT=lin|emos|uhd`
- 非 Android 的平台先用这个方案即可（最少改动、最易验证）

示例：
- Lin：`flutter run --dart-define=APP_PRODUCT=lin`
- Emos：`flutter run --dart-define=APP_PRODUCT=emos`
- UHD：`flutter run --dart-define=APP_PRODUCT=uhd`

### 3.2 Android：再增加 Gradle productFlavors（包名/名称/图标）
目标：同一台设备可同时安装三套 App。

- Flavors：`lin` / `emos` / `uhd`
- 分别设置：
  - `applicationIdSuffix` 或直接不同 `applicationId`
  - `resValue("string", "app_name", "...")`
  - 图标资源（可选：先共用，后续再拆）

### 3.3 TV：优先做 Android TV（同 Android 产物）
- TV 可以作为一个 flavor（例如 `tv`），也可以仅运行时用 `DeviceType.isTv` 控制 UI。
- 推荐：先 **运行时区分 TV**，等代理与 UI 稳定再考虑 `tv` flavor（减少第一阶段复杂度）。

---

## 4. 路线图（里程碑 + 验收标准）

> 每个里程碑都要可验收；通过后再进入下一步，避免一次性大改导致回滚困难。

### M0：统一规则与命名（半天）
**任务**
- 定义 `AppProduct`、feature flags 的命名规范。
- 定义“差异只能出现在哪些目录/层”的约束。

**验收**
- README/本文件确定后，后续改动都按规则走。

---

### M1：产品轴（AppProduct）落地（1 天内可完成）
**任务**
1. 新增 `AppConfig`（读取 `--dart-define=APP_PRODUCT`，默认 `lin`）。
2. 在 `MaterialApp.title`、User-Agent、设置页显示等处使用配置。

**验收**
- 同一份代码，用不同 `--dart-define=APP_PRODUCT=...` 运行，应用标题/设置页显示的产品名不同。
- 不影响现有功能。

---

### M2：Server Adapter 插槽（2–4 天）
**任务**
1. 定义最小 Server Adapter 接口（按当前 UI 真实使用的最小集来）。
2. 把当前 Lin（Emby/Jellyfin/Plex/WebDav）“包起来”实现这个接口（不要大改现有 API 类，先 wrapper）。
3. 创建 `EmosAdapter` / `UhdAdapter` 空壳（占位实现 + 未支持提示）。

**验收**
- Lin 产品功能不回退。
- UI 不再到处依赖具体 API 类实例（收口到 adapter/factory）。

---

### M3：Feature Flags 收口（1–2 天）
**任务**
- 每个产品一份 flags：决定“显示哪些入口/默认值/哪些服务器类型可添加”。
- UI 层只用 flags 控制显示与入口，业务逻辑不写 `if (product == ...)` 的散弹式判断。

**验收**
- 同一页面在 3 产品里可“变瘦”，但核心逻辑仍共用。

---

### M4：TV 形态基础（1–3 天）
**任务**
- 在设置页新增 TV 专区（仅 `DeviceType.isTv == true` 显示）。
- TV 下按需调整 UI（焦点/遥控等）与一些不适配入口的隐藏。

**验收**
- Android TV 上能看到 TV 专区，非 TV 不显示。

---

### M5：TV 内置代理 MVP（先不做面板）（2–5 天）
**任务**
1. 新增 `BuiltInProxyService`：`start/stop/status`。
2. 设置页 TV 专区增加开关：
   - `是否启用内置代理`
   - 展示状态：未运行/运行中/失败（失败原因）
3. 仅在 Android TV 支持；其他平台显示“不支持”或隐藏。

**验收**
- 开关打开：mihomo 进程启动成功（至少有端口、进程存活）。
- 开关关闭：mihomo 能停止。
- 不影响非 TV。

---

### M6：接入 metacubexd 面板（2–4 天）
**任务**
1. 将 metacubexd 作为静态资源打包进 App（Android assets），启动时解压到本地目录。
2. mihomo 配置：
   - `external-controller: 127.0.0.1:<port>`
   - `external-ui: <解压后的目录>`
3. 设置页提供按钮：`打开代理面板`（WebView 打开本地地址）。

**验收**
- TV 上可打开面板、添加订阅、看到节点/规则变化。

---

### M7：让“App 网络 + 播放器”真正走代理（关键）（2–6 天）
**任务**
1. App HTTP（`package:http`）
   - 增加 `HttpClientFactory`：代理开时设置 `findProxy` 指向 `127.0.0.1:<mixedPort>`
   - 把现有 `EmbyApi/PlexApi/网站元数据/封面库` 等统一用工厂创建的 client
2. 播放器（`media_kit` / mpv）
   - 代理开：向 mpv 注入 `http-proxy=...`（或等价参数）确保媒体流也走代理

**验收**
- 代理开：境外 Emby 的访问与播放明显改善。
- 代理关：行为恢复正常。

---

### M8：构建产物（Android flavors + 其他平台 define）（1–3 天）
**任务**
- Android 增加 `lin/emos/uhd` flavors（包名/名称/图标可先只改名称与包名）。
- 其他平台沿用 `--dart-define=APP_PRODUCT=...`。

**验收**
- 本地可分别构建/运行 3 产品（至少 Android 先跑通）。

---

## 5. TV 内置代理实现备注（提前避坑）

### 5.1 二进制分发与执行（Android）
- 常见方案：把 `mihomo` 按 ABI 放到 assets（或 jniLibs），运行时解压到 app 私有目录并 `chmod +x` 后用 `Process.start` 启动。
- 风险：少数设备可能对 app 私有目录 `noexec`，导致无法执行；需要在 UI 给出明确错误提示（后续可升级为原生 Service/JNI 方案）。

### 5.2 安全性（默认只监听 loopback）
- `external-controller`、`mixed-port`、`socks-port` 都只绑定 `127.0.0.1`，避免同网段可访问。
- （可选）为 controller 加 secret/token（避免本机其他 app 乱连）。

### 5.3 许可证合规
- `mihomo` 与 `metacubexd` 都需要确认许可证与分发要求（README/关于页中声明）。

---

## 6. 下一步（我们从哪里开始）

建议从 **M1（产品轴）** 开始：改动最小、收益最大、后面所有拆分都依赖它。

开始前需要确认 2 个约定：
1. 产品显示名是否固定为：`LinPlayer` / `EmosPlayer` / `UPlayer`？
2. `APP_PRODUCT` 的取值是否用：`lin` / `emos` / `uhd`？

