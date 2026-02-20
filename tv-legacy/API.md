# LinPlayer TV Legacy — 接口文档（MVP）

本文档描述 `tv-legacy/`（Android 4.4 / API 19）低版本 TV 端 **本地服务**的接口与约定，覆盖：

- 订阅链接写入后由 mihomo 拉取订阅
- 代理开关：开启时 App 内 **OkHttp / ExoPlayer 全量走代理**；关闭时直连
- UA 约定：App 请求统一 `LinPlayer/<versionName>`；mihomo 自身请求保持默认 UA

> 版本：`0.1.0`（对应 `tv-legacy/app/build.gradle.kts` 的 `versionName`）

---

## 1. 术语

- **TV Legacy App**：`tv-legacy/` 这个独立 Android 工程（Java + XML/View）
- **mihomo**：内置代理内核（以 `libmihomo.so` 形式放入 `jniLibs` 后执行）
- **Mixed Port**：HTTP(S)+SOCKS 混合端口（默认 `7890`）
- **Controller Port**：mihomo 管理端口（默认 `9090`，仅回环）
- **订阅（Subscription）**：用户输入的订阅 URL（subconverter/Clash/Mihomo 订阅等）

---

## 2. 文件与目录

### 2.1 SharedPreferences

文件：`<shared_prefs>/linplayer_tv_legacy.xml`（由系统管理）

Key：
- `subscription_url`：订阅 URL（字符串）
- `proxy_enabled`：代理是否启用（布尔）
- `last_status`：上次状态文本（字符串，用于 UI 展示）
- `media_backend`：媒体后端类型（legacy，已弃用）
- `media_base_url`：媒体服务器地址（legacy，已弃用）
- `media_api_key`：媒体服务器 API key / token（legacy，已弃用）
- `servers_json`：服务器列表（JSON 字符串数组）
- `active_server_id`：当前激活的服务器 id（字符串）
- `server_view_mode`：服务器页显示模式（字符串：`list` / `grid`）
- `remote_token`：扫码控制的 token（字符串）
- `remote_port`：扫码控制 HTTP server 端口（int，随机端口）

对应代码：`tv-legacy/app/src/main/java/com/linplayer/tvlegacy/AppPrefs.java`

### 2.2 mihomo 工作目录

工作目录：
- `<filesDir>/mihomo/`

配置文件：
- `<filesDir>/mihomo/config.yaml`

订阅 provider 落地路径（由 config 指定）：
- `<filesDir>/mihomo/providers/sub.yaml`

对应代码：`tv-legacy/app/src/main/java/com/linplayer/tvlegacy/MihomoConfig.java`

---

## 3. 端口与绑定

默认端口（可在后续版本中做成可配置项）：
- mixed：`127.0.0.1:7890`
- socks：`127.0.0.1:7891`
- controller：`127.0.0.1:9090`

安全约定：
- **只监听回环**（`127.0.0.1`），实现“只影响本 App”（非 VPN / 非全局系统代理）
- controller `secret` 为空，但由于只绑定回环，外部不可访问（若未来开放到 LAN，必须启用 token/secret）

---

## 4. 代理开关对网络栈的影响

目标行为：
- **代理开启**：App 内所有 HTTP/HTTPS 播放与请求都走 `127.0.0.1:7890`
- **代理关闭**：App 内默认直连（不使用系统代理，也不使用 mihomo）

实现策略（两层）：

### 4.1 OkHttp（建议所有业务请求都从这里走）

- 入口：`NetworkClients.okHttp(context)`
  - 当 `proxy_enabled=true`：返回带 `PerAppProxySelector(127.0.0.1:7890)` 的 OkHttpClient
  - 当 `proxy_enabled=false`：返回 `Proxy.NO_PROXY` 的 OkHttpClient（强制直连）

对应代码：
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/NetworkClients.java`
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/PerAppProxySelector.java`

### 4.2 进程级 ProxySelector（兜底：对 HttpURLConnection 等生效）

当代理开启时，Service 会调用：
- `ProxyEnv.enable()` → `ProxySelector.setDefault(...)`

当代理关闭时，Service 会调用：
- `ProxyEnv.disable()` → 恢复原始 `ProxySelector`

用途：
- 兜底让 ExoPlayer 某些链路（或其他库）内部走 `HttpURLConnection` 时也能被导向代理
- 对 `localhost/127.0.0.1` 自动绕过，避免回环地址被代理导致自引用
- 同时设置 `http.proxyHost/http.proxyPort/https.proxyHost/https.proxyPort`，确保
  `HttpURLConnection`（含 ExoPlayer 默认网络栈）也能走代理（仍然只影响本 App 进程）

对应代码：
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/ProxyEnv.java`

---

## 5. ExoPlayer 接入约定（走代理 + 统一 UA）

TV Legacy（API 19）为了兼容 Android 4.4，播放链路使用 ExoPlayer 默认的 `HttpURLConnection`
数据源（`DefaultHttpDataSource`）。

- DataSourceFactory：`ExoNetwork.dataSourceFactory(context, headers)`
  - UA：统一 `LinPlayer/<versionName>`
  - WebDAV 播放：在匹配 `baseUrl` 时附加 `Authorization: Basic ...`
  - 代理：由 `ProxyEnv.enable()` 的 `ProxySelector` + 进程级 `http(s).proxy*` systemProp 兜底生效

对应代码：
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/ExoNetwork.java`

---

## 6. User-Agent 约定

### 6.1 App 自己发起的请求（OkHttp / ExoPlayer）

统一 UA：
- `LinPlayer/<versionName>`（例如：`LinPlayer/0.1.0`）

实现：
- OkHttp 拦截器强制覆盖每个 request 的 `User-Agent` header

对应代码：
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/NetworkConfig.java`
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/NetworkClients.java`

### 6.2 mihomo 自己发起的请求（订阅拉取/健康检查等）

约定：
- **不做 UA 覆盖**（保持 mihomo 默认 UA，例如 clash.meta/mihomo 默认 UA）

实现：
- 配置里不设置任何 `global-ua` / `user-agent` 覆盖项（字段以 mihomo 版本为准）

---

## 7. 订阅配置与拉取行为

### 7.1 用户输入订阅 URL

UI 入口：
- Settings 页面 `Subscription URL`
- 点击 `Save Subscription` 写入 `subscription_url`

对应代码：
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/SettingsActivity.java`

### 7.2 配置生成逻辑

当 `subscription_url` 为空：
- 生成 DIRECT 配置（只提供 `PROXY` 组且默认 `DIRECT`）

当 `subscription_url` 非空：
- 写入 `proxy-providers.sub`（`type: http`，`url: <subscription_url>`）
- `path: ./providers/sub.yaml`
- `interval: 86400`
- `health-check` 使用 `http://www.gstatic.com/generate_204`

对应代码：
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/MihomoConfig.java`

### 7.3 何时触发 mihomo 拉取订阅

- 启动代理时：Service 会先 `ensureWritten()` 写入 config，再启动 mihomo（mihomo 启动后会按 provider 行为拉取订阅）
- 代理运行中修改订阅：点击保存后触发 `applyConfig`，若代理正在运行且 `proxy_enabled=true`，会自动重启 mihomo，使新订阅生效并重新拉取

对应代码：
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/ProxyService.java`

---

## 8. Service（本地服务）控制接口（Intent）

> 说明：这是 App 内部接口（UI → Service）。如果未来要做“手机扫码控制”，建议在此之上再提供独立的 HTTP API（见下一节规划）。

### 8.1 Actions

- `com.linplayer.tvlegacy.action.START_PROXY`
  - 启动前台服务 + 写配置 + 启动 mihomo + 启用 ProxySelector
- `com.linplayer.tvlegacy.action.STOP_PROXY`
  - 停止 mihomo + 禁用 ProxySelector + stopSelf
- `com.linplayer.tvlegacy.action.APPLY_CONFIG`
  - 写配置；若代理运行中且已启用，则重启 mihomo

对应代码：
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/ProxyService.java`

### 8.2 状态广播

- Action：`com.linplayer.tvlegacy.action.STATUS`
- Extra：`status`（字符串）

用途：
- UI 监听该广播以更新状态文本

对应代码：
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/MainActivity.java`
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/ProxyService.java`

---

## 9. 手机扫码控制 HTTP API（已实现，MVP）

TV 端启动后可在“Servers”页右侧看到二维码，手机扫码后打开网页即可添加服务器（MVP）。

- bind：`0.0.0.0:<randomPort>`（随机端口，启动后固定到 `remote_port`）
- 鉴权：`token`（Query 参数或 JSON body）

已实现 API：
- `GET /`：内置网页 UI（添加服务器 / 批量解析 / 代理设置 / 播放页遥控）
- `GET /api/info?token=...`：App 版本、当前服务器、代理状态
- `POST /api/addServer`：添加服务器（JSON，含 `token`）
- `POST /api/bulkAddServers`：批量解析添加服务器（JSON，含 `token`）
- `POST /api/setProxySettings`：写入订阅链接 + 开关代理（JSON，含 `token`）
- `GET /api/player/status?token=...`：播放页状态（是否在播、进度等）
- `POST /api/player/control`：播放页遥控（播放/暂停/seek/停止）

`POST /api/addServer`（示例字段）：
- `type`：`emby` / `jellyfin` / `plex` / `webdav`
- `baseUrl`：服务器地址（支持不带 scheme，会自动补 `http://`）
- `apiKey`：Emby/Jellyfin API key 或 Plex Token
- `username` / `password`：WebDAV 账号密码
- `displayName` / `remark`：显示名/备注（可选）
- `activate`：添加后设为当前服务器（默认 true）

`POST /api/bulkAddServers`：
- body：`{ token, text, defaultType, activateFirst }`
- `text` 支持两种格式：
  - JSON：`[{...server...}, {...}]`
  - 行文本：`type|baseUrl|apiKey(token)|username|password|displayName|remark|activate`

`POST /api/setProxySettings`：
- body：`{ token, enabled, subscriptionUrl }`

`GET /api/player/status`：
- 返回：`{ ok, active, title, playing, positionMs, durationMs }`

`POST /api/player/control`：
- body：`{ token, action, value }`
- `action`：`toggle` / `play` / `pause` / `stop` / `seekByMs` / `seekToMs`

### 9.1（规划）兼容现有 LinPlayer TV Remote Web UI（可选）

仓库主工程（Flutter 版）已内置一套手机网页控制 UI：`assets/tv_remote/`，其后端（TV 端）接口在
`lib/services/tv_remote/tv_remote_service.dart`。

如果 TV Legacy 后续实现同名接口，理论上可以直接复用这套前端页面（减少重复开发）：

- `GET /api/info?token=...`（已实现）
- `GET /api/settings?token=...`（未实现）
- `POST /api/settings`（未实现）
  - JSON：`{ "token": "...", "values": { "tvBuiltInProxyEnabled": true, "tvBuiltInProxySubscriptionUrl": "..." } }`

其中建议在 TV Legacy 内部做映射：
- `tvBuiltInProxyEnabled` → `proxy_enabled`
- `tvBuiltInProxySubscriptionUrl` → `subscription_url`

> 该部分仅为接口约定草案；实现前需要确认安全模型（LAN 访问、token 生命周期、是否支持配对码等）。

---

## 10.（内部）媒体数据后端接口（给 TV UI 用）

TV Legacy 的首页/详情页目前通过一个“媒体数据后端”抽象拿数据，目的：把 **UI** 和 **具体数据源实现**
（Demo / Emby / Jellyfin / WebDAV / 自建 API）解耦，先把页面与播放链路跑通。

入口：
- `Backends.media(context)` → `MediaBackend`

线程约定：
- 后端在 IO 线程执行耗时工作；
- `Callback<T>` 回调一律切回主线程（可直接更新 UI）。

数据模型（MVP）：
- `Show`：`id`, `title`, `overview`, `posterUrl`, `backdropUrl`, `year`, `genres`, `rating`
- `Episode`：`id`, `index`, `title`, `mediaUrl`, `seasonNumber`, `episodeNumber`, `overview`, `thumbUrl`

接口（MVP）：
- `listShows(cb)`：首页剧集列表
- `getShow(showId, cb)`：剧详情信息
- `listEpisodes(showId, cb)`：全集列表
- `getEpisode(showId, episodeIndex, cb)`：单集信息（含播放 URL）

实现：
- 当前默认实现为 `DemoMediaBackend`（基于 `DemoData`），用于 UI/导航/播放骨架验证；
- 未来替换真实实现时，网络请求必须复用 `NetworkClients.okHttp(context)`，以确保：
  - 代理开关生效（走/不走 mihomo）
  - UA 统一为 `LinPlayer/<versionName>`

对应代码：
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/backend/MediaBackend.java`
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/backend/Backends.java`
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/backend/DemoMediaBackend.java`
- `tv-legacy/app/src/main/java/com/linplayer/tvlegacy/NetworkClients.java`
