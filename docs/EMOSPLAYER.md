# EmosPlayer（`APP_PRODUCT=emos`）使用与开发说明

本文面向本仓库的 `emos` 产品（`AppProduct.emos`）：说明 **EmosPlayer** 的运行/构建方式、登录与会话机制、Emya(Emby) 接入策略、已落地功能入口，以及已知限制与后续扩展点。

> 提示：Postman 导出的 collection（如 `api.postman_collection.json` / `emya.postman_collection.json`）仅用于本地联调，不需要提交到仓库；客户端侧已将接口封装为 `EmosApi`，播放与媒体库继续复用 `EmbyApi`。

---

## 目录

- [0. 快速开始（TL;DR）](#0-快速开始tldr)
- [1. 运行与构建](#1-运行与构建)
- [2. 登录与会话（Emos Sign-in）](#2-登录与会话emos-sign-in)
- [3. Emya（Emby）接入策略](#3-emyaemby-接入策略)
- [4. Emos Console：已落地功能入口](#4-emos-console已落地功能入口)
- [5. 求片（Seek）状态：已评估，暂未实现 UI](#5-求片seek-状态已评估暂未实现-ui)
- [6. 常见问题（FAQ）](#6-常见问题faq)
- [7. 相关文档](#7-相关文档)

---

## 0. 快速开始（TL;DR）

运行：

```bash
flutter run --dart-define=APP_PRODUCT=emos
```

自定义 Emos 服务端地址：

```bash
flutter run --dart-define=APP_PRODUCT=emos --dart-define=APP_EMOS_BASE_URL=https://emos.best
```

构建 Release APK：

```bash
flutter build apk --release --dart-define=APP_PRODUCT=emos --dart-define=APP_EMOS_BASE_URL=https://emos.best
```

---

## 1. 运行与构建

### 1.1 配置项（`--dart-define`）

| Key | 说明 | 默认值 |
| --- | --- | --- |
| `APP_PRODUCT` | 产品开关（必须为 `emos` 才会启用 Emos 相关入口） | `lin` |
| `APP_EMOS_BASE_URL` | Emos 服务端 Base URL（需要包含 `http/https`） | `https://emos.best` |
| `APP_GITHUB_OWNER` | 用于“关于/更新”等场景的仓库 owner（可选） | `zzzwannasleep` |
| `APP_GITHUB_REPO` | 用于“关于/更新”等场景的仓库 repo（可选） | `LinPlayer` |

> 建议：本地调试时优先显式传 `APP_PRODUCT=emos`，避免误用默认值导致入口/功能不显示。

### 1.2 启动（Debug/Profile）

```bash
flutter run --dart-define=APP_PRODUCT=emos
```

### 1.3 指定 Emos 服务端地址（可选）

```bash
flutter run --dart-define=APP_PRODUCT=emos --dart-define=APP_EMOS_BASE_URL=https://emos.best
```

### 1.4 构建（Release）

Android APK：

```bash
flutter build apk --release --dart-define=APP_PRODUCT=emos --dart-define=APP_EMOS_BASE_URL=https://emos.best
```

其他平台同理（示例）：

```bash
flutter build windows --release --dart-define=APP_PRODUCT=emos
flutter build macos   --release --dart-define=APP_PRODUCT=emos
flutter build linux   --release --dart-define=APP_PRODUCT=emos
flutter build ios     --release --dart-define=APP_PRODUCT=emos
```

### 1.5 App 名称（不共存）

`emos` 产品在各平台展示名统一为 **EmosPlayer**（Android/iOS/Windows/macOS/Linux）。  
该分支不再追求“同机共存 LinPlayer/UPlayer”，只保留 EmosPlayer 这一套名字与产物。

### 1.6 GitHub Actions：两个独立工作流

对应文件：
- 直接构建：`.github/workflows/emos-build.yml`（`Build EmosPlayer`）
- 同步主分支后构建：`.github/workflows/emos-sync-and-build.yml`（`Sync main -> emos & Build EmosPlayer`）

工作流说明：
- `Build EmosPlayer`：直接基于当前 `emos` 分支构建 Android APK（产物在 Artifacts：`EmosPlayer-Android-APKs`）
- `Sync main -> emos & Build EmosPlayer`：先把 `origin/main` 合并进 `emos` 并推送，再构建 APK（如有冲突会失败，需要你本地解决后 push）
- 两个工作流都支持在手动触发时填写 `APP_EMOS_BASE_URL`（默认 `https://emos.best`）

---

## 2. 登录与会话（Emos Sign-in）

### 2.1 入口

- App 内：设置页 → **Emos** 区块 → `Emos Console`
- 服务器列表页（`ServerPage`）右上角 `+`：当且仅当产品为 `emos` 时，会触发 Emos 登录流程并自动添加 Emya(Emby) 服务器

### 2.2 登录方式（Loopback 回调）

当前实现为“浏览器登录 + 本机回环回调”模式：

1. App 启动本地回调服务：`127.0.0.1:<port>/emos_callback`
2. 拉起浏览器访问 Emos `/link`，并把回调 URL 作为参数
3. 浏览器登录后，Emos 服务端回跳到本机回调地址，携带 `token/user_id/username/avatar` 等信息
4. App 捕获回调并写入本地会话

对应实现：
- 登录编排：`lib/services/emos_sign_in_service.dart`
- 回调服务：`lib/services/emos_auth_flow.dart`

### 2.3 常见排障

- **Web 平台无法登录**：Web 不支持本机 `127.0.0.1` 回调的 `HttpServer`（见 FAQ）。
- **桌面端首次登录无回调**：检查系统防火墙/安全软件是否拦截本地端口监听；必要时允许应用监听回环地址。
- **`APP_EMOS_BASE_URL` 不可用**：确认 Base URL 可在设备浏览器直接访问；建议显式带上 `https://` 或 `http://`。

### 2.4 会话持久化与退出登录

会话保存在本地（SharedPreferences），字段包含：
- `token`
- `userId`
- `username`
- `avatarUrl`（可空）

对应代码：
- 数据结构：`lib/state/emos_session.dart`
- 持久化：`lib/state/app_state.dart`（Key：`emosToken_v1/emosUserId_v1/emosUsername_v1/emosAvatarUrl_v1`）

退出登录：
- 设置页 → Emos → `Sign out`（内部调用 `AppState.clearEmosSession()`）
- 或在 `Emos Console` 顶部卡片点击 `Sign out`

---

## 3. Emya（Emby）接入策略（用于播放/媒体库）

### 3.1 总体思路

- **播放与媒体库**：继续走现有 `EmbyApi`（保持稳定，复用现有播放器链路）
- **Emos 业务能力**（片单/反代/求片/上传等）：走 `EmosApi`

### 3.2 自动添加 Emya(Emby) 服务器

Emos 登录成功后会自动拉取用户信息 `GET /api/user`：
- `emya_url`：Emya 服务器地址（Emby）
- `emya_password`：Emya 登录密码（若为空则调用一次性密码接口）

然后 App 会用现有 `EmbyApi` 进行 Emby 侧鉴权，最终调用 `AppState.addServer(...)` 把 Emya 服务器加入服务器列表并激活。

### 3.3 关键代码位置

- Emos 业务 API（Bearer token）：`lib/services/emos_api.dart`
- Emos 适配器（Emby-backed）：`lib/server_adapters/emos/emos_adapter.dart`
- 登录并引导添加 Emya：`lib/services/emos_sign_in_service.dart`

### 3.4 HTTP/鉴权细节（实现现状）

- Emos 侧鉴权：`Authorization: Bearer <token>`（由 `EmosApi` 统一注入）。
- `EmosApi` 当前默认接受自签/无效 TLS 证书（`badCertificateCallback: true`），联调用起来更省事；如需严格校验，请按你的安全要求调整实现。

---

## 4. 已落地功能与入口（Emos Console）

入口：设置页 → Emos → `Emos Console`（`lib/emos/emos_console_page.dart`）

### 4.1 User & Invite

- 用户信息（`/api/user`）
- 切换“显示空库”（`/api/user/showEmpty`）
- 修改 pseudonym（`/api/user/pseudonym`）
- 同意上传协议（`/api/user/agreeUploadAgreement`）
- Emya 密码：获取一次性密码（`/api/emya/getLoginPassword`）、重置密码（`/api/emya/resetPassword`）
- 邀请：邀请/详情/历史（`/api/invite`、`/api/invite/info`、`/api/invite/history`）

页面：`lib/emos/emos_user_invite_page.dart`

### 4.2 Proxy Lines（反代线路）

> 注意：这是 Emos 业务里的“线路”，与 TV 端“内置代理（mihomo）”不是一回事；本模块保持 **EmosPlayer 独立**，不与 TV 模块/通用 LinPlayer 绑定。

- 列表（`/api/proxy/line`）
- 新增（`POST /api/proxy/line`）
- 删除（`DELETE /api/proxy/line?id=...`）

页面：`lib/emos/emos_proxy_lines_page.dart`

### 4.3 Watchlists（片单）

实现了基础管理：
- 列表筛选：我的 / 已订阅 / 公共（`GET /api/watch`）
- 新建/编辑片单（`POST /api/watch`）
- 订阅/取消订阅（`PUT /api/watch/{id}/subscribe`）
- 更新维护者（`PUT /api/watch/{id}/maintainer`）
- 删除片单（`DELETE /api/watch/{id}`）

页面：`lib/emos/emos_watchlists_page.dart`

> 说明：片单视频的“搜索/增删改排序”等接口已在 `EmosApi` 中封装；若你希望把“片单视频管理”做成完整 UI，可继续扩展该页面。

### 4.4 Video Manager（视频管理 + 目录树 + 资源/字幕）

- 视频列表（`GET /api/video/list`）
- 标记删除/恢复（`PUT /api/video/{id}/delete`）
- 同步（`PATCH /api/video/sync`）
- 目录树（`GET /api/video/tree`）
- 资源列表/重命名/删除（`/api/video/media/*`）
- 字幕列表/重命名/删除（`/api/video/subtitle/*`）

页面：
- 视频管理：`lib/emos/emos_video_manager_page.dart`
- 资源/字幕：`lib/emos/emos_video_assets_page.dart`

### 4.5 Upload（上传）

已做：
- 获取上传 token（`POST /api/upload/getUploadToken`）
- 获取视频上传基础信息（`GET /api/upload/video/base`）
- 保存上传结果：
  - 视频：`POST /api/upload/video/save`
  - 字幕：`POST /api/upload/subtitle/save`
- “直传”仅 best-effort：如果 token 响应里包含 `upload_url`/`url`，会尝试对该地址做 `PUT` 上传（不同后端实现可能不兼容）

页面：`lib/emos/emos_upload_page.dart`

**重要限制：** Postman 导出里 `getUploadToken` 没有示例响应体，因此目前无法保证“自动直传”可用。要补全直传逻辑，需要你提供一份真实响应示例（至少包含：上传地址、鉴权字段、最终 `file_id` 的获取方式）。

### 4.6 Rank（榜单）

- 萝卜榜：`GET /api/rank/carrot`
- 上传榜：`GET /api/rank/upload`

页面：`lib/emos/emos_rank_page.dart`

### 4.7 Carrot（萝卜）

- 变更记录：`GET /api/carrot/history?type=earn|cost`
- 转赠：`PUT /api/carrot/transfer`

页面：`lib/emos/emos_carrot_page.dart`

### 4.8 扩展指南（新增 Emos 模块）

推荐落地路径：
1. 在 `lib/services/emos_api.dart` 增加接口封装（优先“薄封装”，统一走 `_getAny/_postJson/_putJson/...`）。
2. 在 `lib/emos/` 新增页面（按现有页面模式：从 `AppConfigScope` 读取 `emosBaseUrl`，从 `appState.emosSession` 取 token）。
3. 在 `lib/emos/emos_console_page.dart` 增加入口 `ListTile`。
4. 如需在“播放/媒体库”等通用页面复用 Emos 能力，优先从 `lib/server_adapters/emos/emos_adapter.dart` 走适配层，避免 UI 直接依赖具体实现。

注意事项：
- 大多数 Emos API 需要登录 token；建议在页面入口处判断 `appState.hasEmosSession`，无会话时引导用户 Sign in。
- token 失效/过期时通常需要重新登录（Sign in）。

---

## 5. 求片（Seek）状态：已评估，暂未实现 UI

目前：
- `EmosApi` 已包含求片相关接口封装（`/api/seek/*`）
- UI 暂未接入（按你的要求：先评估再决定做不做）

接口能力概览：
- 列表：`POST /api/seek`（支持筛选：`video_type/status/upload_self/video_title/with_user`；排序：`sort_by/sort_order`）
- 轮询未认领：`GET /api/seek/poll`
- 求片/取消：`PUT /api/seek/apply?item_type=...&item_id=...`
- 查询认领状态：`GET /api/seek/query?seek_id=...`
- 历史：`GET /api/seek/history?...`
- 认领/取消认领：`PUT /api/seek/claim {seek_id,type}`
- 催更（加萝卜）：`PUT /api/seek/urge {seek_id,carrot}`

如果你决定要做，建议实现顺序：
1) Seek 列表（带筛选/排序）
2) Seek 详情页（含 query/history）
3) 在视频/剧集资源页加“一键求片/取消/认领/催更”按钮

---

## 6. 常见问题（FAQ）

### 6.1 Web 平台为什么不能登录？

当前登录依赖本机 `127.0.0.1` 回调 `HttpServer`，Web 平台不支持该方式。

### 6.2 为什么代码里有部分中文显示乱码？

仓库中已有部分历史字符串存在编码问题（mojibake），本分支尽量避免在这些行上做大规模重写，减少 patch 冲突与风险。

---

## 7. 相关文档

- 源码导览与模块说明：`docs/ARCHITECTURE.md`
- 播放器模块化拆分（WIP）：`docs/PLAYER_MODULARIZATION.md`
