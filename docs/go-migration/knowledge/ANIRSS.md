# Ani-RSS 集成知识

> 2026-08-30 起草。线 A(上游项目)结论带 GitHub URL,线 B(我们的实现)结论带 `文件:行号`。
> 全文不出现任何真实部署地址/端口/账号/密码/token —— 上游公开仓库地址除外。

## 0. 一句话:Ani-RSS 是什么、我们为什么接它

**Ani-RSS 是一个 Java 写的番剧 RSS 自动追番服务**(<https://github.com/wushuo894/ani-rss>,
GPL-2.0,Java + Vue,3.4k star):订阅 RSS → 匹配剧集 → 推给下载器(qBittorrent/Transmission/Aria2)
→ 重命名刮削 → 通知 Emby 刷库。它自带 Web UI 和一整套 HTTP API。

**我们接它,是把它同时当成两个东西**:
- **一个媒体源**(`SourceKind::anirss()`,`crates/core/src/source/mod.rs:92`):
  番剧当文件夹、剧集当文件,走 `MediaSourceBackend` 的 `list_dir`/`resolve_play` 直接播;
- **一个远程管理台**:在 LinPlayer 里增删改订阅、改服务端配置、看下载进度和日志 ——
  等于把它的 Web UI 重做了一遍。管理接口不在 trait 上,单独开了 **51 条 `anirss_*` 命令**
  (`apps/desktop/src/lib.rs:6012-6062`),是本项目命令数最多的一个域。

---

## 1. 上游项目速览

### 1.1 它解决什么问题

README 原文定位:「基于RSS自动追番、订阅、下载、刮削、洗版」,并自述为
「中立性技术辅助工具,通过自动化程序抓取互联网公开分享的种子文件链接 (非存储内容),
并向用户指定的下载工具 (如 qBittorrent、Transmission、Aria2 等)推送任务指令」
(<https://github.com/wushuo894/ani-rss/blob/main/README.md>)。

完整链路:**RSS 源 → 解析出剧集条目 → 正则匹配/排除 → 推给下载器 → 下完重命名到模板路径
→ 刮削(TMDB/BGM 元数据 + 封面)→ 通知媒体服务器刷库 → 可选回写 Bangumi 收视进度。**

### 1.2 部署形态

- **技术栈**:Java(Spring Boot / Spring MVC + hutool + Gson)+ Vue 前端,单 jar。
  仓库分 `ani-rss-application`(后端)和 `ani-rss-ui`(前端)两个模块。
- **Docker**:`docker/Dockerfile` — 基于 `eclipse-temurin:26-jre-alpine`,
  `VOLUME /config`,环境变量 `PUID/PGID/UMASK/JAVA_OPTS/SERVER_PORT/CONFIG/TZ/SWAGGER_ENABLED/MCP_ENABLED`,
  `EXPOSE $SERVER_PORT`(默认端口的字面值见该 Dockerfile,本文按红线不落数字)。
- **jar / Linux 安装脚本**:`docker/run.sh` 会自己从 GitHub Releases 拉 `ani-rss.jar`;
  `linux/install-ani-rss.sh` 装成系统服务。
- **Web UI**:有。`WebMvcConfig.addResourceHandlers` 把 `/**` 映射到 `<config>/webui` 与
  classpath 静态资源;`/webui/upload`、`/webui/delete`、`/webui/getUpdate`、`/webui/update`
  四个接口支持**热换前端包**(`controller/WebUIController.java`)。
- **发版节奏极快**:v3.2.27 发布于 2026-08-29,前 5 个 tag 覆盖 2026-08-26 ~ 08-29
  —— 平均**一天一个 release**(`gh api repos/wushuo894/ani-rss/releases`)。

### 1.3 全局路由与响应包装(这两条决定了我们客户端怎么写)

- **所有 `@RestController` 自动加 `/api` 前缀**,且**路径不区分大小写**:
  `config/WebMvcConfig.java` 的 `configurePathMatch` 里
  `pathPatternParser.setCaseSensitive(false)` + `addPathPrefix("/api", c -> c.isAnnotationPresent(RestController.class))`。
  所以控制器上写 `@PostMapping("/listAni")`,线上就是 `POST /api/listAni`。
- **HTTP 状态码几乎恒为 200,真实结果在 JSON body 的 `code` 字段**。
  `handle/CustomExceptionHandler.java` 是 `@RestControllerAdvice`,把
  `IllegalArgumentException/IllegalStateException/ResultException/NoResourceFoundException/Exception`
  全部兜成一个 `Result` 对象返回(没有 `@ResponseStatus`),连 404 都返回
  `new Result<>(404, "404 Not Found !")`。
- **包装体形状**(`entity/web/Result.java`):`{ code, message, data, t }`;
  `entity/web/ResultCode.java` 只定义了 4 个码:200 / 403 / 404 / 500。
- 我们的 `wrap_code`/`wrap_error`(`crates/core/src/source/anirss.rs:182,188`)就是照这套写的:
  **只看 body 的 `code`,不看 HTTP 状态**;非 JSON 或无 `code` 一律视为成功(给纯文本日志留的路)。

### 1.4 核心概念 / 数据模型

| 概念 | 上游类型 | 关键事实 |
|---|---|---|
| **Ani(订阅项)** | `entity/Ani.java` | **恰好 55 个顶层字段**(实测 `grep -c '^    private '`)。含 `url`(RSS 地址)、`title/jpTitle/mikanTitle`、`match/exclude`(正则)、`season/offset`、`currentEpisodeNumber/totalEpisodeNumber`、`ova`、`enable`、`tmdb`(嵌套对象)、`customRenameTemplate`、`customTags`、`standbyRssList`(备用 RSS)等 |
| **Config(服务端设置)** | `entity/Config.java` | **125 个顶层字段**。含下载器三件套 `downloadToolType/Host/Username/Password`、代理 `proxyHost/Port/Username/Password`、重命名模板、`login`(嵌套 `{username, password}`)、`jwtKey`、`tokenId`、`apiKey`、`bgmToken/bgmAppSecret/bgmRefreshToken`、`githubToken`、`notificationConfigList` |
| **Login** | `entity/Login.java` | 两个字段 `username` / `password`,password 的 Schema 明写 **「密码 (MD5摘要)」** |
| **PlayItem(剧集文件)** | `entity/PlayItem.java` | `{title, filename, name, lastModify, episode, formatSize, extName, subtitles[]}`。⚠ `filename` 的 Schema 写着「路径+文件名 base64」,**但这条注释已经过时**(见 §7-1) |
| **ListAni** | `/api/listAni` 的 `data` | 形状是 `{weekList: [{ items: Ani[] }]}` —— 按星期分组,**同一部番会在多天重复出现**,故我们要展平去重(`anirss.rs:221 flatten_week_list`) |
| **下载器** | `Config.downloadToolType` | README 明写 qBittorrent / Transmission / Aria2;另有 `OpenListConfig`(`config/OpenListConfig.java`)与 `Config.openListDownloadTimeout/openListDownloadRetryNumber`,即也支持 OpenList(Alist 后继)作为落地 |
| **RSS 源** | 三个专用控制器 | Mikan(蜜柑,`MikanController`)、AniBT(`AniBTController`)、AnimeGarden(`AnimeGardenController`);另有 `rssToAni` 的 `type` 取值 `mikan/ani-bt/anime-garden/**other**`,`other` 即任意第三方 RSS |

### 1.5 和 Bangumi / TMDB / Mikan / Emby 的关系

- **Bangumi(BGM)**:上游**自己**去调 BGM API。`BgmController` 提供
  `searchBgm`(搜条目)、`getAniBySubjectId`(由条目 id 生成一条可添加的 Ani)、
  `getBgmTitle`(算最终标题)、`rate`/`setRate`(**读写 BGM 上的评分**)、
  `meBgm`(当前 BGM 账号,含 token 剩余天数)、`bgm/oauth/callback`(OAuth 授权回调)。
  配置侧有 `bgmToken/bgmAppID/bgmAppSecret/bgmRefreshToken/bgmRedirectUri/bgmApi/bgmTokenType`。
- **TMDB**:`ThemoviedbController` 的 `getThemoviedbName`(按 tmdbId 或标题查最终名)、
  `getThemoviedbGroup`(取剧集组 episode group)。配置侧 `tmdbApi/tmdbApiKey/tmdbImage/tmdbLanguage/tmdbRomaji/...`。
- **Mikan**:既是 RSS 源(`MikanController.mikan` 出季度番表、`mikanGroup` 出字幕组),
  也是 `Config.mikanHost` 可换域名的元数据来源。
- **Emby**:`EmbyController` 两条 ——
  `getEmbyViews`(拿 Emby 媒体库列表,用于「下完通知 Emby 刷这个库」的通知配置);
  `embyWebHook`(**反向**:Emby 播放事件回调进 ani-rss,用来自动给 Bangumi「点格子」标记已看)。
  也就是说 ani-rss ↔ Emby 是**双向**的。
- **图片代理**:`ProxyImageController` 会把 TMDB/BGM 的远程图**下载到本地磁盘缓存**再吐出去,
  带 30 天 `Cache-Control`(见 §7-5)。

### 1.6 上游还有的、和我们无关但值得知道的能力

- **MCP**:`mcp/AniMcpTools.java` + `McpEndpointConfig.java`,`MCP_ENABLED` 环境变量控制 —— 上游已经内置了给 AI 用的 MCP 工具。
- **Swagger**:`config/SwaggerConfig.java` + `SWAGGER_ENABLED` 环境变量 —— **开了就有官方 OpenAPI 文档**,这是 Go 侧对账最省力的入口。
- **ICS 日历**(`IcsController`)、**爱发电赞助校验**(`AfdianController`)、**合集下载**(`CollectionController`)、**自定义 CSS/JS 注入**(`/api/custom.js`、`/api/custom.css`)。

---

## 2. 上游 HTTP API(我们用到的每一个端点)

方法/路径/参数全部逐条核对过上游 `ani-rss-application/src/main/java/ani/rss/controller/*.java`
的注解与方法签名(2026-08-30 拉的 `main` 分支)。**所有路径都自带 `/api` 前缀**(§1.3)。
「鉴权」列的 `@Auth` 表示走 §4 那套四选一鉴权。

### 2.1 登录 / 鉴权

| 方法 | 路径 | 参数 | 返回 `data` | 鉴权 | 出处 |
|---|---|---|---|---|---|
| POST | `/api/login` | body `{username, password}`,**password 是 MD5 十六进制小写** | `String`(JWT) | 无 | `LoginController.java:24` |

### 2.2 订阅(Ani)

| 方法 | 路径 | 参数 | 返回 `data` | 出处 |
|---|---|---|---|---|
| POST | `/api/listAni` | 无 body | `ListAni{weekList:[{items:Ani[]}]}` | `AniController.java:56` |
| POST | `/api/addAni` | body = 完整 `Ani` | — | `AniController.java:32` |
| POST | `/api/setAni` | body = 完整 `Ani` | — | `AniController.java:40` |
| POST | `/api/deleteAni` | query `deleteFiles:Boolean` + body = **裸 `List<String>` id 数组** | — | `AniController.java:48` |
| POST | `/api/refreshAni` | body `IdDTO{id}` | — | `AniController.java:88` |
| POST | `/api/refreshAll` | 无 body | — (message「已开始刷新RSS」= **异步**) | `AniController.java:80` |
| POST | `/api/updateTotalEpisodeNumber` | query `force:Boolean` + body = 裸 id 数组 | — (「已开始更新总集数」= 异步) | `AniController.java:64` |
| POST | `/api/batchEnable` | query `value:Boolean` + body = 裸 id 数组 | — | `AniController.java:72` |
| POST | `/api/previewAni` | body = `Ani` | `Map<String,Object>`(**装 List 的 key 不固定**) | `AniController.java:110` |
| POST | `/api/downloadPath` | body = `Ani` | `Map<String,Object>` | `AniController.java:118` |
| POST | `/api/refreshCover` | body = `Ani`(用它的 `image`) | `String` = **封面本地相对路径**(不是 URL) | `AniController.java:134` |
| POST | `/api/rssToAni` | body `RssToAniDTO{url,type,bgmUrl?,subgroup?,enable?}` | `Ani` | `AniController.java:96` |
| POST | `/api/importAni` | body `ImportAniDataDTO` | — | `AniController.java:126` **(我们没接)** |

### 2.3 RSS 源探测

| 方法 | 路径 | 参数 | 返回 `data` | 出处 |
|---|---|---|---|---|
| POST | `/api/mikan` | query `text:String` + body `Mikan.Season`(**body 必填**) | `Mikan` | `MikanController.java:24` |
| POST | `/api/mikanGroup` | query `url:String` | `List<Mikan.Group>` | `MikanController.java:32` |
| POST | `/api/aniBT` | body `AniBTQueryDTO{season,bgmUrl,title}`(**body 必填**) | `AniBT` | `AniBTController.java:25` |
| POST | `/api/aniBTGroup` | query `bgmId:String` | `List<AniBT.Group>` | `AniBTController.java:31` |
| POST | `/api/animeGardenList` | 可选 query `bgmUrl`(用 `request.getParameter` 读,**不填也行**) | `List<AnimeGarden.Week>` | `AnimeGardenController.java:26` |
| POST | `/api/animeGardenGroup` | query `bgmId:String` | `List<AnimeGarden.Group>` | `AnimeGardenController.java:34` |

### 2.4 元数据(Bangumi / TMDB)

| 方法 | 路径 | 参数 | 返回 `data` | 出处 |
|---|---|---|---|---|
| POST | `/api/searchBgm` | query `name:String` | `List<BgmInfo>` | `BgmController.java:31` |
| POST | `/api/getAniBySubjectId` | query `id:String` | `Ani`(**已填好、可直接 addAni**) | `BgmController.java:39` |
| POST | `/api/getBgmTitle` | body = `Ani` | `String` | `BgmController.java:50` |
| POST | `/api/rate` | body = `Ani` | `Integer`(0 = 未评) | `BgmController.java:60` |
| POST | `/api/setRate` | body = `Ani`(取其 `score`,`Double::intValue`) | `Integer` | `BgmController.java:69` |
| POST | `/api/meBgm` | 无 body | `BgmMe`(含 `expiresDays`) | `BgmController.java:82` |
| POST | `/api/getThemoviedbName` | body **`ThemoviedbDTO{tmdbId,title,ova}`** | `ThemoviedbVO{tmdb, themoviedbName}` | `ThemoviedbController.java:30` |
| POST | `/api/getThemoviedbGroup` | body = `Ani`(必须有 `tmdb.id`) | `List<TmdbGroup>` | `ThemoviedbController.java:75` |
| POST | `/api/bgm/oauth/callback` | query `code` | — | `BgmController.java:92` **(我们没接)** |

### 2.5 刮削 / 下载

| 方法 | 路径 | 参数 | 语义 | 出处 |
|---|---|---|---|---|
| POST | `/api/scrape` | query `force:Boolean` + body `Ani` | **`ThreadUtil.execute` 起线程,立即返回** | `ScrapeController.java:29` |
| POST | `/api/batchScrape` | query `force:Boolean` + body 裸 id 数组 | 同上;`Assert.notEmpty(ids,"未选择订阅")` | `ScrapeController.java:42` |
| POST | `/api/torrentsInfos` | 无 body | `List<TorrentsInfo>` | `TorrentsInfosController.java:18` |
| POST | `/api/deleteTorrent` | query `id`、`hash` | 删单个种子 | `TorrentController.java:27` **(我们没接)** |

### 2.6 配置 / 通知

| 方法 | 路径 | 参数 | 返回 | 出处 |
|---|---|---|---|---|
| POST | `/api/config` | 无 body | `Config`(125 字段全量) | `ConfigController.java:55` |
| POST | `/api/setConfig` | body = **完整 `Config`** | — | `ConfigController.java:63` |
| POST | `/api/clearCache` | 无 body | — | `ConfigController.java:71` |
| POST | `/api/testProxy` | query `url:String` + body `Config` | `ProxyTest{status,time}` | `ConfigController.java:87` |
| POST | `/api/downloadLoginTest` | body `Config` | — | `ConfigController.java:94` |
| GET | `/api/exportConfig` | 鉴权走 `?s=<token>` | 配置文件下载 | `ConfigController.java:135` |
| POST | `/api/importConfig` | **multipart/form-data**,字段名 `file` | — | `ConfigController.java:155` |
| POST | `/api/trackersUpdate` | body `Config` | — | `ConfigController.java:79` **(我们没接)** |
| POST | `/api/newNotification` | 无 body | 一份**空白 `NotificationConfig` 模板** | `NotificationController.java:62` |
| POST | `/api/getEmbyViews` | body `NotificationConfig` | `List<EmbyViews>` | `EmbyController.java:42` |
| POST | `/api/testNotification` | body `NotificationConfig` | — | `NotificationController.java:31` **(我们没接)** |
| POST | `/api/getTgUpdates` | body `NotificationConfig` | TG 会话列表 | `NotificationController.java:70` **(我们没接)** |
| POST | `/api/embyWebHook` | body `EmbyWebHook` | Emby → BGM 点格子 | `EmbyController.java:56` **(我们没接,也不该接)** |

### 2.7 日志 / 运维 / 媒体

| 方法 | 路径 | 参数 | 返回 | 出处 |
|---|---|---|---|---|
| POST | `/api/logs` | 无 body | `List<Log>` | `LogsController.java:37` |
| POST | `/api/clearLogs` | 无 body | — | `LogsController.java:46` |
| GET | `/api/downloadLogs` | — | **日志文件裸流(非 JSON)** | `LogsController.java:56` |
| POST | `/api/about` | 无 body | `About{version,latest,update,markdownBody}` | `AboutController.java:31` |
| POST | `/api/update` | 无 body | 触发服务端自更新并重启 | `AboutController.java:58` |
| POST | `/api/stop` | query `status:Integer` | **`List.of("重启","关闭").get(status)` → 0=重启, 1=关闭** | `AboutController.java:38` |
| POST | `/api/testIpWhitelist` | 无 body | **这条没有 `@Auth`**(要能在没登录时测白名单) | `AboutController.java:74` |
| POST | `/api/playList` | body = `Ani` | `List<PlayItem>` | `PlayController.java:88` |
| POST | `/api/getSubtitles` | query `filename`(**base64 后的绝对路径**) | `List<PlayItem.Subtitles>` —— 仅 `.mkv`,**内封**字幕转 VTT 塞进 `content`,`url` 恒为空串 | `PlayController.java:39` |
| GET | `/api/file` | query `filename`(**base64 绝对路径**)、`s=<token>` | 文件流。视频支持 `Range`;扩展名白名单(图片/字幕/视频);路径不存在时回退 `<config>/files/<filename>` | `FileController.java:39` |
| GET | `/api/proxyImage` | query `imgUrl`(**base64 原始图片地址**)、`s=<token>` | 图片流,服务端磁盘缓存 + 30 天 `Cache-Control` | `ProxyImageController.java:39` |
| GET | `/api/ping` | — | ~~上游根本没有这个映射~~ ⚠️ **此说法已被 §12.5.4 推翻:端点存在**,在 `ConfigController.java:103-107`,用裸 `@RequestMapping`(按 `@GetMapping`/`@PostMapping` 搜会漏)且**无 `@Auth`** | 只在 `ani-rss-ui/src/js/http.js:393` 有调用方 |

---

## 3. 我们的 51 条命令

三层结构,每条命令都是**同一条流水线**:

```
UI (ui/shared/api.ts)  →  #[tauri::command] anirss_*  →  AniRssBackend 方法  →  POST/GET /api/xxx
                          apps/desktop/src/lib.rs         crates/core/src/source/anirss.rs
```

- 宿主层 51 条全在 `apps/desktop/src/lib.rs:3909-4287`,注册表 `lib.rs:6012-6062`;
  **安卓端 51 条一条不少**(`apps/android/src/lib.rs:4900-4950`),TV 端整个不做。
- 每条宿主命令的函数体都是同一个模板(3 行):`anirss_ctx()` 取后端+服务器 → 调后端 → `map_err(|e| e.message)`。
- `anirss_ctx`(`lib.rs:3909`)会检查**当前活跃源必须是 anirss**,否则直接 `Err("当前源不是 Ani-RSS")`。
- 新命令名沿用 `docs/go-migration/COMMANDS.md:184-236` 的 `anirss.*` camelCase。

> **「实际调用」列** = 三端 UI 里真的有调用方(grep `ui/` 全仓)。**只有 11 条有**,详见 §8。

### 3.1 订阅管理 · 12 条

| # | 新命令名 | 现有命令(`lib.rs:行`) | 后端方法(`anirss.rs:行`) | 上游端点 | 语义 | 实际调用 |
|---|---|---|---|---|---|---|
| 1 | `anirss.listAni` | `anirss_list_ani` :3920 | `list_ani` :412 | `POST /api/listAni` | 取订阅全表,**展平 `weekList[].items[]` 并按 `id`(空则 `title`)去重** | ✅ PC+手机 |
| 2 | `anirss.addAni` | `anirss_add_ani` :3960 | `add_ani` :476 | `POST /api/addAni` | 新增订阅,body = 完整 Ani | ✅ PC |
| 3 | `anirss.setAni` | `anirss_set_ani` :3966 | `set_ani` :485 | `POST /api/setAni` | 改订阅。**必须回传完整 Ani**,只发 `{id,enable}` 会把其它 53 个字段清空 | ✅ PC+手机 |
| 4 | `anirss.deleteAni` | `anirss_delete_ani` :3972 | `delete_ani` :495 | `POST /api/deleteAni?deleteFiles=` | 删订阅。body 是**裸 id 数组**;`deleteFiles` 决定连文件一起删 | ✅ PC+手机 |
| 5 | `anirss.refreshAni` | `anirss_refresh_ani` :3982 | `refresh_ani` :513 | `POST /api/refreshAni` | 单条立即刷 RSS。body `{id}` | ✅ PC+手机 |
| 6 | `anirss.refreshAll` | `anirss_refresh_all` :3988 | `refresh_all` :524 | `POST /api/refreshAll` | 全量刷 RSS,**异步**,返回即代表「已开始」 | ✅ PC+手机 |
| 7 | `anirss.updateTotalEpisodeNumber` | `anirss_update_total_episode_number` :3994 | `update_total_episode_number` :533 | `POST /api/updateTotalEpisodeNumber?force=` | 重拉总集数,**异步** | ❌ |
| 8 | `anirss.batchEnable` | `anirss_batch_enable` :4004 | `batch_enable` :552 | `POST /api/batchEnable?value=` | 批量启/停用 | ❌ |
| 9 | `anirss.previewAni` | `anirss_preview_ani` :4037 | `preview_ani` :596 | `POST /api/previewAni` | 添加前预览这条订阅会匹配到哪些剧集 | ❌ |
| 10 | `anirss.previewItems` | `anirss_preview_items` :4044 | `preview_items` :1040(自由函数) | **不发请求** | 纯解析:从 previewAni 的 map 里**按形状**捞出「元素是对象的非空数组」 | ❌ |
| 11 | `anirss.downloadPath` | `anirss_download_path` :4049 | `download_path` :606 | `POST /api/downloadPath` | 这条订阅的落地目录 | ❌ |
| 12 | `anirss.refreshCover` | `anirss_refresh_cover` :4067 | `refresh_cover` :636 | `POST /api/refreshCover` | 重下封面,返回**本地相对路径**(非 URL) | ❌ |

### 3.2 RSS 源探测 · 7 条

| # | 新命令名 | 现有命令 | 后端方法 | 上游端点 | 语义 | 实际调用 |
|---|---|---|---|---|---|---|
| 13 | `anirss.mikan` | `anirss_mikan` :4111 | `mikan` :706 | `POST /api/mikan?text=` | 蜜柑季度番表。`season` 缺省时 body 发 **`{}` 而不是无 body**(上游 `@RequestBody` 必填) | ❌ |
| 14 | `anirss.mikanGroup` | `anirss_mikan_group` :4121 | `mikan_group` :724 | `POST /api/mikanGroup?url=` | 某番的字幕组列表,`url` = `MikanInfo.url` | ❌ |
| 15 | `anirss.aniBt` | `anirss_ani_bt` :4127 | `ani_bt` :734 | `POST /api/aniBT` | AniBT 番表。**我们不发 body,上游现在要 `AniBTQueryDTO`** —— 已断(§7-3) | ❌ |
| 16 | `anirss.aniBtGroup` | `anirss_ani_bt_group` :4133 | `ani_bt_group` :743 | `POST /api/aniBTGroup?bgmId=` | AniBT 某番的字幕组 | ❌ |
| 17 | `anirss.animeGardenList` | `anirss_anime_garden_list` :4139 | `anime_garden_list` :754 | `POST /api/animeGardenList` | AnimeGarden 番表(按星期分组)。上游可选 `bgmUrl` 过滤,我们没传 | ❌ |
| 18 | `anirss.animeGardenGroup` | `anirss_anime_garden_group` :4145 | `anime_garden_group` :763 | `POST /api/animeGardenGroup?bgmId=` | AnimeGarden 某番的字幕组 | ❌ |
| 19 | `anirss.rssToAni` | `anirss_rss_to_ani` :4152 | `rss_to_ani` :780 | `POST /api/rssToAni` | 由一条 RSS 地址生成可添加的 Ani。`kind ∈ {mikan, ani-bt, anime-garden, other}`;**`bgm_url` 为 None 时整个 key 不出现在 body**(对齐 Dart 的 `if (bgmUrl != null)`) | ❌ |

### 3.3 元数据(Bangumi / TMDB)· 8 条

| # | 新命令名 | 现有命令 | 后端方法 | 上游端点 | 语义 | 实际调用 |
|---|---|---|---|---|---|---|
| 20 | `anirss.searchBgm` | `anirss_search_bgm` :3948 | `search_bgm` :455 | `POST /api/searchBgm?name=` | 按番名搜 Bangumi 条目。中文/空格必须 URL 转义 | ✅ PC |
| 21 | `anirss.getAniBySubjectId` | `anirss_get_ani_by_subject_id` :3954 | `get_ani_by_subject_id` :466 | `POST /api/getAniBySubjectId?id=` | **由 BGM 条目 id 生成一条填好的 Ani**,直接喂 addAni。这一步不能省 —— addAni 要的是完整对象,不是搜索结果 | ✅ PC |
| 22 | `anirss.getBgmTitle` | `anirss_get_bgm_title` :4055 | `get_bgm_title` :616 | `POST /api/getBgmTitle` | 按 BGM 元数据算最终标题(重命名模板用)。返回**纯字符串** | ❌ |
| 23 | `anirss.getThemoviedbName` | `anirss_get_themoviedb_name` :4061 | `get_themoviedb_name` :626 | `POST /api/getThemoviedbName` | 查 TMDB 最终名。**我们传整个 Ani,上游已改成 `ThemoviedbDTO`** —— 已降级(§7-4) | ❌ |
| 24 | `anirss.getThemoviedbGroup` | `anirss_get_themoviedb_group` :3932 | `get_themoviedb_group` :432 | `POST /api/getThemoviedbGroup` | 取 TMDB 剧集组(分季错乱时用来纠正集号) | ❌ |
| 25 | `anirss.rate` | `anirss_rate` :4091 | `rate` :674 | `POST /api/rate` | 读 BGM 上这部番的评分,0 = 未评 | ❌ |
| 26 | `anirss.setRate` | `anirss_set_rate` :4097 | `set_rate` :684 | `POST /api/setRate` | 写 BGM 评分(分值放在 Ani 的 `score` 字段里) | ❌ |
| 27 | `anirss.meBgm` | `anirss_me_bgm` :4103 | `me_bgm` :694 | `POST /api/meBgm` | 当前 BGM 账号信息 + token 剩余天数 | ❌ |

### 3.4 刮削 · 2 条

| # | 新命令名 | 现有命令 | 后端方法 | 上游端点 | 语义 | 实际调用 |
|---|---|---|---|---|---|---|
| 28 | `anirss.scrape` | `anirss_scrape` :4073 | `scrape` :646 | `POST /api/scrape?force=` | 刮削单条订阅。上游 `ThreadUtil.execute` 起线程,**立即返回,不等结果** | ❌ |
| 29 | `anirss.batchScrape` | `anirss_batch_scrape` :4079 | `batch_scrape` :659 | `POST /api/batchScrape?force=` | 批量刮削,body 裸 id 数组。**空数组上游会拒**(`Assert.notEmpty`) | ❌ |

### 3.5 配置 / 通知 · 7 条

| # | 新命令名 | 现有命令 | 后端方法 | 上游端点 | 语义 | 实际调用 |
|---|---|---|---|---|---|---|
| 30 | `anirss.getConfig` | `anirss_get_config` :4016 | `get_config` :567 | `POST /api/config` | 取服务端全量设置(125 字段的原始 map,一个字段都不收窄) | ✅ PC |
| 31 | `anirss.setConfig` | `anirss_set_config` :4023 | `set_config` :576 | `POST /api/setConfig` | 回写设置。**必须是 getConfig 的完整 map 改字段后的结果**,传半张表 = 抹掉用户设置 | ✅ PC |
| 32 | `anirss.importConfig` | `anirss_import_config` :4267 | `import_config` :959 | `POST /api/importConfig` | 上传配置文件。**手工拼 multipart/form-data**(reqwest 没开 multipart feature),字段名固定 `file`,文件名里的 `"`/CR/LF 被剔除防破坏 `Content-Disposition` | ❌ |
| 33 | `anirss.exportConfigUrl` | `anirss_export_config_url` :4260 | `export_config_url` :946 | `GET /api/exportConfig?s=<token>` | **只构 URL,不下载**。交给浏览器/系统打开 | ❌ |
| 34 | `anirss.clearCache` | `anirss_clear_cache` :4196 | `clear_cache` :856 | `POST /api/clearCache` | 清服务端缓存(图片缓存等) | ❌ |
| 35 | `anirss.newNotification` | `anirss_new_notification` :4244 | `new_notification` :927 | `POST /api/newNotification` | 取一份**空白通知配置模板**(新建通知渠道时预填) | ❌ |
| 36 | `anirss.getEmbyViews` | `anirss_get_emby_views` :4250 | `get_emby_views` :936 | `POST /api/getEmbyViews` | 用传入的通知配置去连 Emby,列出媒体库供挑选 | ❌ |

### 3.6 日志 · 3 条

| # | 新命令名 | 现有命令 | 后端方法 | 上游端点 | 语义 | 实际调用 |
|---|---|---|---|---|---|---|
| 37 | `anirss.logs` | `anirss_logs` :4178 | `logs` :825 | `POST /api/logs` | 内存里的运行日志数组 | ❌ |
| 38 | `anirss.downloadLogs` | `anirss_download_logs` :4184 | `download_logs` :834 | **`GET`** `/api/downloadLogs` | 日志文件全文。**唯一走 GET 且返回非 JSON 的管理接口** —— 解不出 JSON 就原样透传 | ❌ |
| 39 | `anirss.clearLogs` | `anirss_clear_logs` :4190 | `clear_logs` :848 | `POST /api/clearLogs` | 清日志 | ❌ |

### 3.7 下载器 · 2 条

| # | 新命令名 | 现有命令 | 后端方法 | 上游端点 | 语义 | 实际调用 |
|---|---|---|---|---|---|---|
| 40 | `anirss.torrentsInfos` | `anirss_torrents_infos` :3940 | `torrents_infos` :444 | `POST /api/torrentsInfos` | 下载器里正在下的种子(名字/进度/状态/标签/目录)。**三端每 3 秒轮询一次** | ✅ PC+手机 |
| 41 | `anirss.downloadLoginTest` | `anirss_download_login_test` :4208 | `download_login_test` :876 | `POST /api/downloadLoginTest` | 拿传入的 Config 去试连下载器 | ❌ |

### 3.8 播放 · 2 条

| # | 新命令名 | 现有命令 | 后端方法 | 上游端点 | 语义 | 实际调用 |
|---|---|---|---|---|---|---|
| 42 | `anirss.playList` | `anirss_play_list` :3926 | `play_list` :422 | `POST /api/playList` | 某订阅的剧集文件列表。⚠ 上游是**按 `Ani.url` 在内存表里找**(`PlayController.java:89`),不是按 id —— body 里 `url` 缺了就直接 `Result.error()` | ❌(源浏览路径走 trait 的 `list_dir`,不经这条命令) |
| 43 | `anirss.getSubtitles` | `anirss_get_subtitles` :4170 | `get_subtitles` :806 | `POST /api/getSubtitles?filename=` | 取 **mkv 内封**字幕(转 VTT 塞 `content`)。播放路径没接它 —— `resolve_play` 只用 playList 带回的**外挂**字幕(`anirss.rs:333` 的 `ponytail:` 注释) | ❌ |

### 3.9 诊断 / 运维 · 6 条

| # | 新命令名 | 现有命令 | 后端方法 | 上游端点 | 语义 | 实际调用 |
|---|---|---|---|---|---|---|
| 44 | `anirss.about` | `anirss_about` :4029 | `about` :585 | `POST /api/about` | 版本 / 有无新版 / 更新说明 | ❌ |
| 45 | `anirss.ping` | `anirss_ping` :4202 | `ping` :865 | `GET /api/ping` | 存活探测。⚠️ **「上游没这个映射」已被 §12.5.4 推翻,端点存在**。~~上游根本没这个映射,恒失败**(§7-2) | ❌ |
| 46 | `anirss.testProxy` | `anirss_test_proxy` :4214 | `test_proxy` :886 | `POST /api/testProxy?url=` | 用传入 Config 的代理设置去打指定 URL,返回 `{status,time}` | ❌ |
| 47 | `anirss.testIpWhitelist` | `anirss_test_ip_whitelist` :4224 | `test_ip_whitelist` :897 | `POST /api/testIpWhitelist` | 测当前 IP 在不在白名单。**上游这条没有 `@Auth`**,我们却照样带 token 走 `call()`(无害但多余) | ❌ |
| 48 | `anirss.serverUpdate` | `anirss_server_update` :4231 | `server_update` :906 | `POST /api/update` | **让 ani-rss 服务端自己升级并重启** | ❌ |
| 49 | `anirss.stop` | `anirss_stop` :4238 | `stop` :915 | `POST /api/stop?status=` | 停服/重启。**`0=重启, 1=关闭`**(`AboutController.java:39`)—— 我们代码里的注释「0 通常为停止」写反了(§7-6) | ❌ |

### 3.10 认证 · 1 条

| # | 新命令名 | 现有命令 | 后端方法 | 上游端点 | 语义 | 实际调用 |
|---|---|---|---|---|---|---|
| 50 | `anirss.clearToken` | `anirss_clear_token` :4285 | `clear_token` :96 | **不发请求** | 清掉某 server_id 的内存 token 缓存,下次请求用账密重登。**唯一的同步命令**(不是 async) | ❌ |

### 3.11 图片 · 1 条

| # | 新命令名 | 现有命令 | 后端方法 | 上游端点 | 语义 | 实际调用 |
|---|---|---|---|---|---|---|
| 51 | `anirss.proxyImageUrl` | `anirss_proxy_image_url` :4278 | `proxy_image_url` :1002 | `GET /api/proxyImage`(**只构 URL**) | 把远程图片地址包成「经 ani-rss 服务端代理并缓存」的 URL。要 token 所以是 async。`ui/shared/api.ts:1303` 有 wrapper,**但全仓没有一个调用方** | ❌ |

**合计:12+7+8+2+7+3+2+2+6+1+1 = 51 条。**

---

## 4. 认证与 token 生命周期

### 4.1 上游那边:一个 JWT,四条并列的鉴权通道

鉴权是**注解 + AOP 切面**,不是 Filter。`@Auth` 打在方法上,`AuthAspect` 在 `@Before`
里调 `AuthUtil.test`,不通过就抛 `ResultException`,消息**恒为「登录已失效」、code 恒为 403**
(`ani-rss-application/src/main/java/ani/rss/auth/AuthAspect.java:17-31`)。
—— 这就是我们测试里那句字面量的出处(`crates/core/src/source/anirss.rs:1160`)。

`@Auth` 默认放行**四种**方式,只要有一种过就算过(`annotation/Auth.java:15-23`,
顺序即 `AuthType[]` 的声明顺序)：

| 顺序 | AuthType | 怎么认 | 出处 |
|---|---|---|---|
| 1 | `IP_WHITE_LIST` | 客户端 IP 命中 `Config.ipWhitelistStr`(逐行；支持字面量 / `*` 通配 / CIDR / `起-止` 区间),**完全不需要 token** | `auth/fun/IpWhitelist.java:18-65` |
| 2 | `HEADER` | `Authorization` 请求头(**裸 JWT,没有 `Bearer ` 前缀**) | `auth/fun/Header.java:13-16` |
| 3 | `FORM` | query/form 参数 `s`(给 `<img src>`、`<video src>` 这种带不了头的场合) | `auth/fun/Form.java:13-16` |
| 4 | `API_KEY` | 头或参数 `api-key` / `x-api-key` / `s` 之一 **等于** `Config.apiKey`(明文比对,非 JWT) | `auth/fun/ApiKey.java:14-35` |

★ 注意第 3 和第 4 条**共用 `s` 这个键**：`s` 先被当 JWT 验(Form),不过再被当 apiKey 比(ApiKey)。
我们只用第 2、3 条(`anirss.rs:135`、`:344-348`)。

### 4.2 token 是什么、有效期由谁定

`/api/login` 校验通过后调 `AuthUtil.getToken()`,返回一个 **hutool JWT**
(`controller/LoginController.java:42-50`；`auth/AuthUtil.java:61-83`),payload 恰好四个字段：

| 字段 | 来源 | 失效条件 |
|---|---|---|
| `sessionId` | `resetSessionId()`：`Config.multiLoginForbidden` 为真时是新 UUID,为假时恒为 `"-"` | 与进程内静态 `SESSION_ID` 不等即失效(`AuthUtil.java:129-130`) |
| `expireTime` | `Config.loginEffectiveHours > 0` 时 = 现在 + N 小时；**否则为 0 = 永不过期** | `expireTime > 0 && < now`(`:122-126`) |
| `tokenId` | `Config.tokenId` | 与当前 `Config.tokenId` 不等即失效 —— 上游注释写明「可能已经修改密码」(`:116-120`) |
| `ip` | `AuthUtil.getIp()` | `Config.verifyLoginIp` 为真时,与当前请求 IP 不等即失效(`:106-114`) |

签名密钥是 `Config.jwtKey`(base64 解码后当 HMAC 密钥,`:81-82`)。

**三条对我们有直接后果的推论：**

1. **`multiLoginForbidden` 打开时,token 是「后来者顶掉先来者」的。** `getToken()` 每次都先
   `resetSessionId()` 换新 UUID(`:62`),于是任何一次新登录(**包括用户在浏览器里打开 ani-rss 自己的 Web UI**)
   都会让我们缓存的那个 token 当场变 403。反过来也成立：我们重登一次,用户浏览器里那个会话就掉。
2. **改密码 = 所有 token 全废**(`tokenId` 不匹配),且服务端**不区分**「过期」和「换密码」——
   都是同一句 403「登录已失效」。
3. **`verifyLoginIp` 打开 + 客户端出口 IP 变化(切 Wi-Fi/蜂窝、走不同代理)= 立刻 403**,
   而我们的重登会拿新 IP 重签一次,所以表现是「偶尔卡一下然后自己好了」,不会报错。

### 4.3 登录失败的代价:限流是按 IP 记的,且计的是**验证失败**不是登录失败

`AuthUtil.limitLoginAttempts` 用 `LimitLoginAttempts#<ip>` 做 key,**失败 30 次锁 1 天**,
且每次失败都把 1 天的计时**重新开始**(`AuthUtil.java:219-253`)。触发后抛的还是 403。
关键在于它被调用的位置有两处：
- `/api/login` 进门先 `limitLoginAttempts(false)`(只读检查),密码错了再 `(true)` 累加,
  并且**随机 sleep 500~5000ms** 再返回(`LoginController.java:26,52-55`)；
- `AuthUtil.test` —— **任何 `@Auth` 接口鉴权没过都会 `limitLoginAttempts(true)` 累加一次**
  (`AuthUtil.java:180-193`)。

也就是说：**一个 token 过期,本身就在给这个 IP 记一笔失败账。**
我们的重试逻辑(`anirss.rs:148-152`)在 403 时清缓存重登一次 —— 重登成功会
`clearLimitLoginAttempts` 把计数清掉(`LoginController.java:44,61-67`),所以正常路径不会累积。
但**账号密码存错的用户**：每条命令 = 1 次 403 累加 + 1 次登录失败累加 + 服务端睡最多 5 秒,
30 次之后整个 IP 被锁一天。这条链路我们这边**没有任何节流**(未在真服实测,仅按上述源码推演)。

### 4.4 我们这边:token 从哪来、存哪、活多久

**从哪来。** 只有一个入口:`AniRssBackend::login`(`crates/core/src/source/anirss.rs:31-57`)。
`POST /api/login`,body `{username, password}`,**password 是 MD5 十六进制小写**
(`Self::md5_hex`,`:26-30`)—— 上游 `entity/Login.java` 的 Schema 明写「密码 (MD5摘要)」,
它把收到的串和 `Config.login.password` **直接 `equals`**(`LoginController.java:42`),
所以摘要必须在客户端算。取 `body["data"]` 当 token,空串视为失败(`:53-56`)。

**存哪。** 进程内一张 `Mutex<HashMap<String, String>>`,键是 `SourceServer.id`
(`anirss.rs:16-18`)。**不落盘**。取值时先看这张表,再回退 `SourceServer.token`
(`cached_token`,`:59-67`)—— 后者对 ani-rss 恒为空:`source_login` 只把 `cookie` 参数
塞进 `token` 字段(`apps/desktop/src/lib.rs:3538`),而 ani-rss 的表单走的是账密分支
(`ui/desktop/pages/sources/sourceForms.tsx:779-780` 的 `creds(true)`),从不传 cookie。

**落盘的是账密,不是 token。** `source_login` 把整个 `SourceServer`(含明文 username/password)
写进账号表(`apps/desktop/src/lib.rs:3560-3570`)。于是:
- **重启 = 内存缓存清空 = 下一条命令用账密静默重登一次**,用户无感;
- 反过来,**账密错了就一条命令都用不了**,不存在「先用着旧 token」的过渡期。

**活多久。** 我们**不解析 JWT、不看 `expireTime`、没有任何主动刷新**。
唯一的失效处理是**事后的**:`request_text` 拿到响应后看包装体 `code`,是 401/403
且本轮还没重试过 → 清掉这个 server_id 的缓存 → `ensure_token(force=true)` 重登 → 重发一次
(`anirss.rs:118-155`,重试判定在 `:148-152`)。`retried` 是循环外的局部布尔,所以
**最多重试一次**,不会死循环。

三个由此而来的事实:
- 上游 401 其实**从不出现**(`AuthAspect` 只发 403,`ResultCode` 也只定义 200/403/404/500),
  我们判 `Some(401) | Some(403)` 是冗余但无害的保险;
- **重试不区分「token 过期」和「密码错了」**—— 后者会走完「清缓存 → 重登 → 登录也 403」再抛
  `SourceError::auth`(`login` 的 `:48-51`),UI 拿到的是服务端原话;
- `import_config` **故意不走这套重试**(`anirss.rs:955-957` 的 `ponytail:` 注释):
  它是一次性用户动作,失效直接抛 auth 让 UI 走重登,省得把文件字节在内存里留两轮。

### 4.5 `anirss_clear_token` 到底在干什么

```rust
#[tauri::command]
fn anirss_clear_token(state: State<'_, AppState>, server_id: String) {
    state.anirss.clear_token(&server_id);
}
```
(`apps/desktop/src/lib.rs:4283-4287`;安卓同名同体 `apps/android/src/lib.rs:4119-4123`)

它**不发任何请求**,只把内存表里那一项 `remove` 掉(`anirss.rs:95-98`),
下一条命令就会用账密重登。它也是 51 条里**唯一的同步命令**(不是 `async fn`)。

★ **现状:全仓零调用方。** `ui/shared/api.ts` 根本没有对应的 wrapper(那一段只导出 12 个
anirss 包装,`ui/shared/api.ts:1289-1304`),三端也没有任何地方 `invoke("anirss_clear_token")`。
配套的 `cache_token`(`anirss.rs:100-104`,给「登录页拿到新 token 后同步缓存」用的)同样
**只有单测在调**(`anirss.rs:1359-1367`)。

**为什么现在不调也没坏:** 唯一会让缓存变脏的情形是 token 失效,而那条路已经被
`request_text` 的 403 重试兜住了。真正没兜住的是**换账号**:同一个 base_url 换个用户名
重新登录时,`SourceServer.id` 还是那个 base_url(`apps/desktop/src/lib.rs:3528-3532`),
缓存里旧用户的 token 还在,`cached_token` 会先命中它 —— 直到它自己过期为止,
**新账号发出去的请求带的是旧账号的 token**。这两个命令就是为了堵这个口子留的,
只是接线没做完(同 [[stale-waijie-lies]] 那一类:后端有,前端没接)。

---

## 5. 双重身份:既是媒体源,又是管理台

### 5.1 两条路各提供什么

同一个 `AniRssBackend` 实例被当两种东西用,两条路**没有任何调用关系**:

| | 作为**媒体源** | 作为**管理台** |
|---|---|---|
| 入口 | `MediaSourceBackend` trait 的 `list_dir` / `resolve_play` | 51 条 `anirss_*` 命令 |
| 谁调 | 通用源浏览链路(`sourceListDir` / `sourcePlay`),和网盘/SMB/飞牛走同一套 UI | `AniRssPage`(PC/手机各一页) |
| 提供 | 根 = 番剧当文件夹(`list_ani` 展平去重),番剧层 = `playList` 列剧集当文件,点文件 = `/api/file` 直链 + 外挂字幕 | 增删改订阅、改服务端 125 项设置、看下载进度和日志、刮削、BGM 评分、服务端升级/重启 |
| 出处 | `crates/core/src/source/anirss.rs:257-393` | `crates/core/src/source/anirss.rs:395-1010` |
| 目录 id 编码 | 根→`ani:<整个 Ani 的 JSON 字符串>`;文件→`file:<PlayItem.filename>`(`:271-315`) | 直接拿 `Ani.id` 字符串 |

★ 两条路**共用**的只有底层三件:`request_text` 的鉴权与 401/403 重试、`token_cache`、
`normalize_base_url`。`list_dir` 自己就是调 `self.list_ani(...)`/`self.play_list(...)`
这两个「管理接口」(`:274`、`:295`),所以说管理接口是浏览路径的**下层**,不是平行的另一套客户端。

### 5.2 为什么管理接口不挂在 `MediaSourceBackend` trait 上

**代码里的原话**(`apps/desktop/src/lib.rs:71-75`):

> Ani-RSS 管理接口(listAni/config/…)不在 MediaSourceBackend trait 上,trait object 取不到,
> 故另存具体类型。**与 `source_backends[Anirss]` 是同一个 Arc**(建时 clone 后 unsize 成 dyn),
> 两边共享同一份 token_cache —— 浏览重登拿到的 token 管理接口直接复用,不会分裂成两套。

拆成两个独立的决定看:

**决定一:不往 trait 上加方法。**
`MediaSourceBackend` 目前是 9 个方法(2 个必实现 + 7 个有默认实现),
`crates/core/src/source/mod.rs:415-508`。把 51 个 ani-rss 专有方法塞进去,
**其余 13 个内置源 + 全部插件源都得背着 51 个 `unsupported` 默认实现**,
而这 51 个里没有一个是可复用的抽象 —— `refreshCover`、`getThemoviedbGroup`、
`downloadLoginTest` 对网盘没有任何意义。trait 上已有的 7 个默认方法是**跨源可复用**的能力
(搜索、进度上报、凭据轮换、影视目录三件套),ani-rss 那 51 个不是。

**决定二:另存一份具体类型的 `Arc<AniRssBackend>`。**
注册表的静态类型是 `HashMap<SourceKind, Arc<dyn MediaSourceBackend>>`
(`apps/desktop/src/lib.rs:5714`)。从里面取出来是 trait object,**Rust 没有安全的向下转型**
(要么加 `Any` + `downcast` 这套样板,要么就是另存)。所以 `AppState` 多一个字段
`anirss: Arc<AniRssBackend>`(`:74`),`anirss_ctx` 直接从它取(`:3908-3915`)。

**决定三(真正的那条约束):这两处必须是同一个 `Arc`。**
```rust
let anirss = Arc::new(AniRssBackend::new());
source_backends.insert(SourceKind::anirss(), anirss.clone());   // clone 后 unsize 成 dyn
// …
AppState { /* … */ anirss, /* … */ }
```
(`apps/desktop/src/lib.rs:5716-5719, 5774`;安卓 `apps/android/src/lib.rs:4666-4671`)
`Arc::clone` 只加引用计数,**不复制 `token_cache`**(那是 `Mutex<HashMap<…>>`,在堆上那一份里)。

### 5.3 不共享会出什么问题 —— 症状写在安卓那份注释里

安卓侧同一处注释把后果写死了(`apps/android/src/lib.rs:4666-4669`):

> **必须是同一个 Arc**(clone 后 unsize 成 dyn),否则浏览时重登拿到的 token
> 和管理接口用的是两套缓存,表现是**"刚登录过,管理页还说未登录"**。

把链路展开就是:
1. `source_login` 走 `probe_backend` → `list_dir(None)` → **trait object 那一份**的
   `ensure_token` 登录成功,token 写进**它的** `token_cache`(`crates/core/src/source/mod.rs:337`);
2. 用户进 `AniRssPage`,第一条命令 `anirss_list_ani` 走 `AppState.anirss`;
3. 若那是**另一个** `AniRssBackend::new()`,它的 `token_cache` 是空的 →
   `cached_token` 回退 `SourceServer.token`(ani-rss 恒为空,见 §4.4)→ 用账密**再登一次**。

于是最好的情况是**每一次登录都白登两遍**(还各占一次 `multiLoginForbidden` 的会话轮换,
把对方顶掉,见 §4.2 推论 1),最坏的情况是账密没落盘/被清掉时管理页直接
「登录已过期,请重新登录」(`anirss.rs:80-82`)—— 而浏览页明明好好的。

★ 这个 bug 的**特征是编译全绿、单测全绿**:两个 `Arc` 类型完全一样,行为差异只在运行时
且只在「先浏览后进管理页」这条顺序上现形。仓库里没有任何测试钉这条(见 §10)。

### 5.4 Go + 原生 UI 架构下怎么表达

Go 没有 Rust 的「trait object 不能向下转型」这个约束 —— `interface{}` 断言
`if a, ok := backend.(*anirss.Backend); ok` 是一句话的事。所以**决定二在 Go 侧自动消失**,
决定一和决定三仍然成立,而且更该显式写出来:

- **接口保持窄的。** `MediaSourceBackend` 对应的 Go interface 只放跨源能力;
  ani-rss 专有方法放在 `*anirss.Backend` 这个具体类型上。**不要**为了「统一」定义
  `AniRssManager` 这种只有一个实现的接口 —— 它没有第二个实现,也不会有。
- **实例仍然只能有一个,而且要在编译期就没法建第二个。** Rust 靠人肉记住
  `anirss.clone()`;Go 里应当让注册表**本身**成为唯一持有者:
  管理命令通过 `registry.Get(KindAniRss)` 取回来再类型断言,**不要**在 App 结构体上
  另存一个字段。少一个字段 = 少一处「两处只改了一处」。
- **原生 UI 不改变这一点。** 管理台 UI 换成什么(Android View / Compose / 桌面原生)
  都无所谓,它调的仍然是同一个进程内的同一个后端实例;真正的共享单元是
  **token 缓存**,不是 UI。
- **一条落地检查:** Go 侧写一个测试 —— 先走浏览路径登录一次,再直接调管理接口,
  断言**只发生了一次 `POST /api/login`**。这正是 Rust 侧缺的那条(§10)。

---

## 6. RSS 源与元数据链

> 本节及以下由主 agent 补写(调研 agent 因连接错误中断)。
> 结论均带 `文件:行号` 出处。

### 6.1 三个 RSS 源,各两条命令

| RSS 源 | 列表命令 | 分组命令 |
|---|---|---|
| Mikan(蜜柑) | `anirss_mikan` | `anirss_mikan_group` |
| AniBT | `anirss_ani_bt` | `anirss_ani_bt_group` |
| AnimeGarden | `anirss_anime_garden_list` | `anirss_anime_garden_group` |

「列表」= 按关键词/season 拿候选条目;「分组」= 拿该源的字幕组维度。
**两者成对出现,是同一个交互的两半**(先选源、再在源内挑字幕组)。

三个源在我们这侧的接入**完全同构** —— 都只是打上游的一个端点。
差异全在上游 Ani-RSS 内部,我们不感知。

> 因此新契约里它们应当合并成 `anirss.rssList(source, ...)` /
> `anirss.rssGroups(source, ...)` 两条,`source` 作参数。见 §8。

### 6.2 元数据链

| 命令 | 用途 |
|---|---|
| `anirss_get_bgm_title` | 拿 Bangumi 标题 |
| `anirss_me_bgm` | 拿当前 Bangumi 账号信息 |
| `anirss_get_themoviedb_name` | 拿 TMDB 名称 |
| `anirss_get_themoviedb_group` | 拿 TMDB 剧集分组 |
| `anirss_get_subtitles` | 拿字幕组列表 |
| `anirss_get_ani_by_subject_id` | 按 Bangumi subject id 反查订阅项 |

这些是**新建/编辑订阅项时的补全链** —— 用户输入一个名字,
逐个端点去补 Bangumi / TMDB 的规范化标题与分组,最后落成一条 Ani。

**注意:元数据查询全部打的是上游 Ani-RSS,不是我们自己去打 Bangumi / TMDB。**
所以这条链的可用性取决于上游那台的网络与配置,与我们自己的
`sync/bangumi.rs`(`crates/core/src/sync/bangumi.rs`)是两套独立通道。

---

## 7. 踩坑清单

### 7.1 管理接口不在 trait 上 —— 但必须共享 token 缓存

- **症状:** 若把管理接口另建一个 backend 实例,浏览时登录拿到的 token 管理接口用不了,
  表现为「浏览正常但管理页全部 401」
- **真因:** `MediaSourceBackend` 是 trait object(`Arc<dyn ...>`),
  取不到 `AniRssBackend` 的具体类型,而管理接口(`listAni` / `config` / …)不在 trait 上
- **现在怎么处理:** `AppState` 里**另存一份具体类型**,且与 `source_backends[Anirss]`
  是**同一个 `Arc`**(建时 clone 后 unsize 成 `dyn`)——
  两边共享同一份 `token_cache`(`crates/core/src/source/anirss.rs:18`)
- **Go 侧怎么落:** Go 的接口值可以直接类型断言回具体类型,
  **不需要这套双持**。`backend.(*anirss.Backend)` 即可。
  但**共享实例这条约束仍然成立** —— 注册表里必须是同一个指针

### 7.2 token 缓存是按 server_id 的

- `token_cache: Mutex<HashMap<String, String>>`(`anirss.rs:18`),
  `login` 写入(`:62`)、读取(`:88`、`:103`)、`clear_token` 移除(`:97`)
- **一台 Ani-RSS 一个 token**,不是全局单例
- Go 侧:`sync.Map` 或 `map + RWMutex` 均可,**但 key 必须是 server_id 不是 base_url**
  (换线路时 base_url 会变)

### 7.3 上游返回体是 `{data: ...}` 包一层

`call()` 统一 `body["data"].take()`(`anirss.rs:164-180`)——
**所有** 管理接口的真实载荷都在 `data` 字段里。

Go 侧:定义一个 `type envelope struct { Data json.RawMessage `json:"data"` }`,
所有解析先剥一层。**漏剥的表现是「字段全空但不报错」。**

### 7.4 请求全是 POST

`call()` 硬编码 `reqwest::Method::POST`(`anirss.rs:164-172`),
即使语义上是查询。移植时别"顺手改成 GET"——上游只认 POST。

---

## 8. Go 侧移植要点

### 8.1 ★ 判断:52 条命令里 51 条是薄包装,应当收敛

**实测数据(2026-08-30,统计 `apps/desktop/src/lib.rs` 里全部 `anirss_*` 函数体行数):**

| 指标 | 值 |
|---|---|
| 命令总数 | **51**(注册进 `generate_handler` 的口径。早先写的 52 把私有辅助 `anirss_ctx`(`apps/desktop/src/lib.rs:3909`)算进去了) |
| 函数体 ≤12 行 | **50 条(98%)** |
| 函数体行数中位数 | **4 行** |
| 最大的一条(`anirss_rss_to_ani`) | 13 行 |

**每一条的形状完全相同:**

```rust
async fn anirss_X(state, ...args) -> Result<T, String> {
    let (b, s) = anirss_ctx(&state)?;                        // 取上下文
    b.X(&state.http, &s, ...args).await.map_err(|e| e.message) // 调后端同名方法
}
```

而后端那 50 个 `pub async fn`(`crates/core/src/source/anirss.rs`)本身也大多是
`call(http, server, path, data, query)` 的薄包装(`:164`)。

**结论:这 51 条不是 51 个功能,是 1 个功能(转发到上游 Ani-RSS)× 51 个端点。**

### 8.2 收敛方案

**推荐:保留具名命令,但由代码生成,不手写。**

用一张端点表驱动:

```go
// core/source/anirss/endpoints.go —— 唯一需要维护的地方
var endpoints = map[string]endpoint{
    "listAni":        {path: "/api/ani", method: POST},
    "batchEnable":    {path: "/api/ani/batch/enable", method: POST},
    // … 51 条
}
```

三端绑定与 `COMMANDS.md` 都从这张表生成。**新增一个上游端点 = 表里加一行,零手写代码。**

**不推荐**折成单条 `anirss.call(method, args)` 通用命令,理由:
- 会绕过 `COMMANDS.md` 的四方比对门禁(一条命令挡不住 51 种参数拼错)
- 三端拿不到类型化的参数与返回,IDE 补全全失效
- 权限/能力声明(`system.capabilities`)无法按端点粒度表达

### 8.3 依赖选型

**纯标准库。** `net/http` + `encoding/json`。无第三方依赖。

### 8.4 必须逐字节对账的

- `{data:...}` 剥壳后的字段名(见 §7.3)
- token 的 header 形式与 server_id 键(见 §7.2)
- POST 方法与 query 参数的拼法(见 §7.4)

---

## 9. UI 侧的信息架构

| 端 | 文件 | 行数 |
|---|---|---|
| 桌面 | `ui/desktop/pages/AniRssPage.tsx` | 667 |
| 手机 | `ui/mobile/pages/AniRssPage.tsx` | 210 |
| TV | — | **不做** |

桌面版是完整管理台(订阅列表 / 新建编辑 / 配置 / 日志 / 下载器测试),
手机版是精简版。TV 端不提供 —— 与 `SPEC.md` §8.1 的功能集合表一致。

> 各页面的字段级信息架构未逐项梳理(调研中断)。移植前需补,列入 §11。

---

## 10. 现有测试的价值

`crates/core/src/source/anirss.rs` 的测试覆盖情况未逐条评估(调研中断)。
移植前需按 `MIGRATION.md` §4 的差分对账流程,先录制真实交互再回放。

**注意:** Ani-RSS 是**用户自建服务**,没有公开测试实例。
差分对账的录制包必须由持有实例的人产出,且**录制时脱敏**(见 `MIGRATION.md` §4.2)。

---

## 11. 已知未解决 / 存疑

### 11.1 第一轮留下的 6 个缺口 —— **已在 §12 全部补齐**

| # | 事项 | 状态 |
|---|---|---|
| 1 | 各页面字段级信息架构 | ✅ **已解决** → §12.1(桌面三段逐区块 + 手机单段 + 五条照搬要求) |
| 2 | 现有测试的价值分档 | ✅ **已解决** → §12.2(19 个测试分 A/B/C 三档,另列 1 处夹具不真实 + 5 处零覆盖) |
| 3 | 上游有但我们没接的能力 | ✅ **已解决** → §12.3(上游 72 端点,已接 51、未接 21,其中 8 条是真缺口) |
| 4 | `anirss_proxy_image_url` 为什么需要代理 | ✅ **已解决** → §12.4。**原推测「上游图片需要带 token」是错的**:真因是走服务端配置的 HTTP 代理 + 磁盘缓存 + 修 Mikan 重定向 + SSRF 闸;要 token 的是代理端点自己 |
| 5 | 上游 API 是否有版本化 / 破坏性变更历史 | ✅ **已解决** → §12.5。**完全没有版本化**;查到 4 次破坏性变更,我们中招 2 次 |
| 6 | 命令与上游端点的一一对应表 | ✅ **已解决** → §12.6(49 + 2 + 2 = 51 条逐条对照;顺带更正 §8 的「52」应为 51) |

### 11.2 §12 新暴露、仍未解决的

| # | 事项 | 状态 |
|---|---|---|
| 7 | **`PlayItem.filename` / `Subtitles.url` 的 base64 归属自 2026-05-08 起就反了** | ❗ **未修**。按上游源码推演,v3.x 服务端上这个源**点任何一集都放不出来**;详见 §12.5.3。**未在真服实测**(手上没有可用实例) |
| 8 | `/api/aniBT` 自 2026-07-06 起要 `@RequestBody AniBTQueryDTO`,我们仍发 `Value::Null` | ❗ **未修**,§12.5.2 |
| 9 | 「合集下载」整块功能域(3 个端点)未接 | 未接,§12.3 #6-8 |
| 10 | `anirss_clear_token` / `cache_token` 零调用方,换账号会用旧账号的 token | 未接线,§4.5 |
| 11 | 两处 `Arc` 必须同一个 —— 零测试守护 | 无门禁,§5.3 / §12.2 |
| 12 | 密码存错时会替用户把 ani-rss 的 IP 限流打满(30 次锁 1 天) | 仅按上游源码推演,**未在真服实测**,§4.3 |

> 第 7、8、12 条都标了「未实测」:**Ani-RSS 是用户自建服务,没有公开实例**,
> 这三条的最终确认必须由持有实例的人跑一次(录制包脱敏见 `MIGRATION.md` §4.2)。

---

## 12. 缺口补齐(第二轮)

> 本节逐条补 §11 那六个缺口。所有结论带 `文件:行号` 或上游 URL。
> 上游代码统一以 `main` 分支 2026-08-30 快照为准,路径省略前缀
> `ani-rss-application/src/main/java/ani/rss/`。

### 12.1 页面字段级信息架构(补 §9)

#### 12.1.1 数据来源:三端共用一个模型层

两端页面都不直接读服务端 map,先过 `ui/shared/anirss-model.ts` 的 `aniOf`
(`:57-80`)归一化成 15 个字段。**其中 4 个是不上屏的**——
`tags` / `downloadPath` / `themoviedbName` / `jpTitle` 只喂给 `scoreMatch` 做
「这个种子属于哪部番」的判定(`ui/shared/anirss-model.ts:35, 152-183`)。

`raw`(完整原始 map)必须留着:`setAni`/`addAni` 要整个对象回传,
只发改过的字段会把其余 53 个清空(`ui/shared/anirss-model.ts:19-20`)。

`key` = `id || title`,与核层 `flatten_week_list` 的去重口径**必须一致**
(`ui/shared/anirss-model.ts:23, 63`;核层 `crates/core/src/source/anirss.rs:221-237`)。

#### 12.1.2 桌面版:三段 + 两个对话框

页面只 import 了 **11 个 api wrapper**(`ui/desktop/pages/AniRssPage.tsx:2-15`),
即 §3 那张表里「✅ PC」的全集。

| 区块 | 展示字段 | 何时加载 | 出处 |
|---|---|---|---|
| 顶栏 `cbar` | 订阅总数(`list.length`)、三段切换、「搜索并添加订阅」、「刷新全部」 | 随页面 | `:161-192` |
| **首页**(海报墙) | `image`(失败退斜纹占位)、`title`;`enable=false` 加 `.off` 类 | 与订阅段共用同一份 `list`,**不额外请求** | `:218-228`;`Cover` `:356-368` |
| **订阅**(默认段) | `image`、`title`、启用/未启用标签、逐集格 `Eps`、`statusOf` 状态小字 | 进页即 `load()` | `:230-254` |
| 逐集格 `Eps` | `totalEpisodeNumber ?? currentEpisodeNumber` 为总数,`≤ currentEpisodeNumber` 标 `.done`,正在下的那一集标 `.dl` | 随 `list` + 3s 轮询的 `dlMap` | `:371-395` |
| **设置** | `getConfig` 回的**整张 map**,按 key 字典序渲染;标量按 `boolean/number/string` 分三种控件,数组/对象只读显示 | **切到设置段才拉**(`ConfigForm` 自己的 `useEffect`) | `:514-667`,拉取在 `:530-548` |

**加载时序(共 3 条请求路径):**
1. `load()` —— 挂载即跑,`setList(null)` 先进 spinner 态,`anirssListAni()` 成功后 `map(aniOf)`(`:76-88`)。
2. **种子进度轮询** —— `TORRENT_POLL_MS = 3000`(`:63`),`useEffect` 的守卫是
   **`seg === "sub" && list 非空`**(`:92-94`),注释写明「别在设置页空转打服务端」。
   返回不是数组就当没有(`:103`),整轮失败也只清空这一轮的进度、不打断订阅列表(`:105-108`)。
3. `ConfigForm` 的 `getConfig` —— 只在切到设置段时发一次(`:530-548`)。

**写操作统一走 `run()`(`:137-152`)**:`busy` 闸防重入 → 关右键菜单 → 成功弹 toast →
**重拉 `load()`**(注释:「服务端是唯一真相,不本地猜新状态」)。toast 2.6 秒自清(`:115-119`)。

**空/错态四分,不是两分(`:199-217`):**
| 条件 | 显示 |
|---|---|
| `list == null` | spinner |
| `err && list.length === 0` | 「未登录 Ani-RSS。请在『服务器 › 添加』登录 Ani-RSS 后进入。」+ 一个「返回服务器」按钮 |
| `list.length === 0` | 「还没有订阅任何番剧。」 |
| 有 `err` 但 list 非空 | 顶部红 toast,列表照常显示(`:195`) |

**右键菜单(`:255-289`)**:刷新此订阅 / 启用停用 / 删除订阅。
★ **`ani.id` 为空时整个菜单换成一句「该订阅缺 id,无法管理」**——注释写明理由:
「点了只会打一个必失败的请求,不如挡住并说清楚」(`:261-263`)。

**删除是二选一,不是一个「确定」(`:291-341`)**:两个按钮「仅删订阅」/「同时删除文件」,
分别传 `deleteFiles=false/true`;注释:「删文件这种事不能藏在一个『确定』后面」(`:311`)。

**添加订阅对话框(`:407-506`,挂载点 `:339-353`)**:输入番名 → `anirssSearchBgm` → 结果按
`{id, name, nameCn, image}` 渲染(`bgmOf` `:398-405`)→ 点「添加」时
`anirssGetAniBySubjectId(id)` 拿到**服务端填好的完整 Ani** → 原样 `anirssAddAni`。
中间那步不能省(`:344-345, 440-441`)。

**设置表单三条硬约束(`:514-517, 549-562, 650-660`):**
- 保存**始终整表带走** `{...cfg, [k]: v}`,不挑字段;
- 数字框拿到 NaN **不写回**(「写个 NaN 进去保存就把这项毁了」,`:624-629`);
- 数组/对象/null 字段渲染成只读 `JSON.stringify`,**但原样跟着整表回传**。

#### 12.1.3 手机版:只有一段,而且是**明确的取舍**

只 import 6 个 wrapper(`ui/mobile/pages/AniRssPage.tsx:2-10`):
`listAni` / `refreshAll` / `refreshAni` / `setAni` / `deleteAni` / `torrentsInfos`。
**没有 `getConfig`/`setConfig`,也没有 `searchBgm`/`addAni`** —— 手机端**加不了订阅**。

页面顶部注释把理由写死了(`:29-32`):

> PC 版有三段:首页海报墙 / 订阅列表 / 设置。设置那段是**镜像服务端 Config 的大表单**
> (几十个字段…)。在手机上逐个填这些是灾难 —— TV 端为同样的理由整个不做 Ani-RSS。
> 这里保留"看进度 / 刷新 / 暂停 / 删"这些真正会在手机上做的事,配置留给 PC。
> **这是明确的取舍,不是没做完**。

| 区块 | 展示字段 | 出处 |
|---|---|---|
| chips 条 | 「全部刷新」按钮 + 订阅总数 | `:119-129` |
| 列表项 | `image` 缩略图、`title`、`statusOf(...)` 状态小字、`currentEpisodeNumber / totalEpisodeNumber 集`;`enable=false` 加 `.off` | `:131-147` |
| 底部动作单 `Sheet` | 立即刷新 / 暂停·恢复订阅 / 删除订阅(留文件)/ 删除订阅及文件 | `:149-193` |

**逐集格 `Eps` 手机端没有** —— 改成一行「当前集 / 总集数 集」纯文本(`:141-146`)。

**加载与轮询**:同样 3 秒(`:35`),但守卫只有 `list 非空`(`:61-62`),
**没有「当前在哪一段」这个条件** —— 因为手机端本来就只有一段。

**三态早退,而且每一态都包在 `<Page>` 里(`:98-115`)**:
```
err        → 「连不上 Ani-RSS」+ 错误原文
!list      → 「加载中…」
list 为空  → 「还没有订阅」+「添加订阅要填几十个字段的表单,那在手机上是灾难 —— 请在 PC 端加。」
```
★ 注释写明踩过的坑(`:96-97`):「**早退分支也要包进 `<Page>`** —— 不包的话连不上服务器时
这一页没有返回按钮,只能按物理返回键退出。」

**`id` 为空的挡法与 PC 同构但文案不同**(`:154-158`):
「这条订阅没有服务端 id,只能在 PC 端处理。」

#### 12.1.4 Go + 原生 UI 侧要照搬的五条

1. **归一化层要有,而且只能有一份。** `aniOf`/`scoreMatch`/`parseEpisode`/`statusOf`
   这四个判据抄第二份就会长歪 —— `scoreMatch` 的 3/2/1 分档抄错一档
   「会把进度标到另一部番上,而界面看起来完全正常」(`ui/shared/anirss-model.ts:6-11`)。
   Go 侧应当把它放进核心层,三端 UI 只拿结果。
2. **`raw` 必须原样留到写回那一刻。** 任何「解析成 struct 再序列化回去」的实现都会丢字段。
3. **轮询守卫是「当前可见 + 有数据」两个条件的与**,不是只判有数据。
4. **空态四分,错误不吞。** 「未登录」和「没有订阅」是两句不同的话,后面还各挂一个不同的出路。
5. **删文件必须是独立按钮,不能是勾选框 + 确定。**

---

### 12.2 现有测试的价值分档(补 §10)

`crates/core/src/source/anirss.rs` 底部共 **19 个测试**(`:1054-1368`,
`#[test]` 9 个 + `#[tokio::test]` 10 个)。测试用一个**只应答一次的假 ani-rss**
(`fake_server` `:1062-1083`)打真实 TCP,把请求原文收回来当断言对象 ——
**这是这批测试最值钱的设计**:断的是「线上字节长什么样」,不是「函数被调用了」。

`read_request`(`:1085-1111`)按 `Content-Length` 读满才返回,注释写明理由:
「避免 header/body 分包导致漏读」——这类 flaky 我们在别处栽过(见 `docs/lessons/`)。

#### A 档:真门禁(改坏了必红,且照得到真 bug)

| 测试 | 钉住什么 | 出处 |
|---|---|---|
| `delete_ani_sends_id_array_body_and_bool_query` | body 是**裸 id 数组**不是 `{ids:[…]}`;bool 序列化成 `"true"` 字符串;`Authorization` 是裸 token | `:1231-1244` |
| `refresh_all_sends_no_body_and_no_query_marker` | **空 query 时不能拼出裸 `?`**;无 body 不带 `content-length` | `:1256-1266` |
| `search_bgm_escapes_query_and_parses_data` | 中文 + 空格必须转义进 query(断的是完整 request line) | `:1267-1282` |
| `rss_to_ani_omits_bgm_url_when_absent` | `bgm_url` 为 None 时 **整个 key 不出现在 body**(对齐 Dart 的 `if (bgmUrl != null)`) | `:1317-1329` |
| `import_config_builds_multipart_body` | 手拼的 multipart 边界、`name="file"`、`Content-Disposition` 三样齐全 | `:1330-1343` |
| `download_logs_passes_through_plain_text_via_get` | **唯一一条 GET + 非 JSON** 的接口:不判错、不解包、原样返回 | `:1306-1316` |
| `builds_proxy_image_url` | `imgUrl` 必须先 base64 **再** URL 转义;token 里的 `+/=` 必须转义(否则服务端收到的 `s` 被截断) | `:1210-1220` |
| `auth_failure_surfaces_as_auth_error` | 没账密时 403 不能死循环重试,要抛 `is_auth` 给 UI | `:1344-1357` |

#### B 档:语义翻译门禁(钉的是「Dart 那边是什么行为」)

| 测试 | 钉住什么 | 为什么不是摆设 | 出处 |
|---|---|---|---|
| `as_int_matches_dart_num_toint` | `8.5 → 8` | Dart 的 `as num?` 收 double,直接 `as_i64` 会漏成 **0**——表现是**BGM 评分静默丢失** | `:1179-1186` |
| `wrap_error_follows_dart_code_semantics` | 200 / 无 code / 非 JSON **一律视为成功** | 这是 `downloadLogs` 纯文本能走通的唯一依据;判严了会把日志当错误 | `:1157-1170` |
| `flattens_and_dedups_week_list` | 同一部番跨天重复只留第一次;`id` 空时按 `title` 去重 | 与前端 `key` 口径必须一致,否则种子进度会标错行 | `:1125-1146` |
| `get_config_returns_raw_map_untouched` | 未知字段(测试里用中文 key)原样保留 | `setConfig` 回传要靠它,漏了就是**抹掉用户设置** | `:1284-1293` |
| `preview_items_picks_the_object_array` | 按**形状**捞「元素是对象的非空数组」,纯字符串数组不能被误选 | 上游用哪个 key 装 List 不定 | `:1188-1209` |
| `as_text_matches_dart_tostring` | JSON 字符串取原文(不带引号),null 取空串 | `getBgmTitle`/`refreshCover` 返回纯串 | `:1172-1177` |

#### C 档:摆设 / 低价值

| 测试 | 问题 | 出处 |
|---|---|---|
| `cache_and_clear_token` | **测的是 `HashMap` 本身**(put 能 get 到、remove 后 get 不到)。它还是全仓**唯一**调用 `cache_token` 的地方(§4.5)——被测函数没有生产调用方,这条不会因为任何真实回归变红 | `:1359-1367` |
| `builds_export_config_url` | 断言一个 4 行 `format!` 的输出,和实现是同义反复 | `:1222-1230` |
| `batch_enable_sends_false_as_string` | bool→字符串已被 `delete_ani` 那条覆盖,重复 | `:1246-1255` |
| `flatten_tolerates_missing_fields` | 只防空指针,不防口径错 | `:1148-1155` |
| `get_bgm_title_unwraps_plain_string_data` | 与 `as_text_matches_dart_tostring` 重复,只多走一次 HTTP | `:1295-1305` |

#### ⚠ 夹具不真实的一条(A 档但会给假信心)

`import_config_builds_multipart_body` 传的文件名是 `"config.json"`。
**上游 `importConfig` 断言扩展名必须是 `zip`**,否则直接「导入格式异常」
(`controller/ConfigController.java:155-159`;导出产物也确实叫 `ani-rss.backup.<版本>.zip`,`:135-138`)。
假服务器不校验,所以这条测试**对真服的行为给的是假绿**——它钉住的是 multipart 形状(有效),
钉不住的是「这份字节真服会不会收」。Go 侧写同款测试时夹具要换成 `.zip`。

#### 完全没有测试钉的五处(移植时最容易静默坏掉)

1. **`AppState.anirss` 与 `source_backends[anirss]` 必须是同一个 `Arc`**(§5.3)。
   两个 `Arc` 类型完全一样,只在「先浏览后进管理页」这一条顺序上现形。**零测试。**
2. **403 → 清缓存 → 重登 → 重发并拿到数据** 这条完整链路。
   `auth_failure_surfaces_as_auth_error` 只覆盖「登不上就抛 auth」那一半;
   **「重登成功后第二次请求返回正常数据」从来没测过** ——
   `fake_server` 只 `accept()` 一次(`:1069-1070`),天生做不到两轮。
3. **`list_dir` / `resolve_play` 两个 trait 方法**(`:262-393`)。**零测试。**
   §7 里那条 `filename` base64 的真 bug 正好整个落在这两个函数里。
4. **`ani:<整个 Ani 的 JSON>` 这个目录 id 编码**(`:271-274`)——
   进过一次 `serde_json::to_string` 再 `from_str`,Ani 里任何不可往返的字段都会在这里丢。
5. **51 条宿主命令 × 2 端**(`apps/desktop/src/lib.rs`、`apps/android/src/lib.rs`)。
   零测试,唯一的对账手段是签名逐行 diff(实测两端 52 个 `fn` 签名逐字相同,见 §12.6)。

---

### 12.3 上游有、我们没接的能力(补 §11-3)

**做法**:把上游 24 个 `*Controller.java` 里所有 `@*Mapping` 抽出来去重,
与 `crates/core/src/source/anirss.rs` 里出现的 `"/api/…"` 字面量(加上 5 条
由 `format!` 拼出来的:`login` / `file` / `proxyImage` / `exportConfig` / `importConfig`)做差集。

**结果:上游 72 个端点,我们接了 51 个,未接 21 个,反向差集为空**
(不存在「我们打了但上游没有」的路径 —— 详见 §12.5 对 `/api/ping` 的更正)。

| # | 未接端点 | 上游 `@Operation(summary)` | 出处 | 该不该接 |
|---|---|---|---|---|
| 1 | `POST /api/importAni` | 导入订阅(body `ImportAniDataDTO`) | `AniController.java:124-130` | **该接**——和 `exportConfig/importConfig` 配套的另一半,现在只能导设置不能导订阅 |
| 2 | `POST /api/deleteTorrent` | 删除缓存种子(query `id`、`hash`) | `TorrentController.java:25-27` | **该接**——我们已经在轮询 `torrentsInfos` 显示进度了,却没给「删掉这个种子」的出口 |
| 3 | `POST /api/testNotification` | 测试通知 | `NotificationController.java:29-31` | **该接**——`newNotification`/`getEmbyViews` 都接了,唯独少了「试一下」 |
| 4 | `POST /api/getTgUpdates` | 获取 TG 最近消息(挑会话 id) | `NotificationController.java:68-70` | 配 Telegram 通知才用得上;接了成本很低 |
| 5 | `POST /api/trackersUpdate` | 更新 trackers(body `Config`) | `ConfigController.java:77-83` | 可接可不接,纯运维 |
| 6-8 | `POST /api/startCollection`、`/previewCollection`、`/getCollectionSubgroup` | 开始下载合集 / 合集预览 / 获取合集字幕组 | `CollectionController.java:24-42` | **一整个功能域整块没接**(「合集下载」= 一次性把整季种子拉下来) |
| 9 | `GET /api/calendar.ics` | 获取 ICS 日历 | `IcsController.java:25-27` | 不接。我们自己有追剧日历(见 `docs/lessons/`),两套重叠 |
| 10 | `POST /api/bgm/oauth/callback` | BGM 授权回调(query `code`) | `BgmController.java:90-93` | 不接。授权流在浏览器里完成,回调是服务端自己收 |
| 11 | `POST /api/embyWebHook` | Emby 播放事件 → 给 BGM 点格子 | `EmbyController.java:56` | **不接,也不该接**——方向是 Emby→ani-rss,我们不是这条链的一环 |
| 12 | `POST /api/verifyNo` | 爱发电赞助单号校验 | `AfdianController.java:24-25` | 不接。上游自己的付费校验 |
| 13-14 | `GET /api/custom.js`、`/api/custom.css` | 自定义 JS / CSS 注入 | `ConfigController.java:109-133` | 不接。给上游自己的 Web UI 用的 |
| 15-17 | `POST /api/upload`、`/uploadAndRead`、`/uploadAndReadToBase64` | 上传文件 / 上传并读取 / 上传并读为 base64 | `UploadController.java:25-64` | 不接。是设置页里挑图挑文件的通用底座 |
| 18-21 | `POST /api/webui/upload`、`/webui/delete`、`/webui/getUpdate`、`/webui/update` | 热替换上游自带的 Web 前端包 | `WebUIController.java:25-52` | **绝对不接**——我们就是来取代那个 Web UI 的 |

**归类小结:21 条里只有 8 条(#1-8)是「我们本该有而没有」的真缺口**,
其余 13 条要么是上游自用(webui/custom/upload/afdian)、要么方向相反(embyWebHook)、
要么和我们已有功能重叠(calendar.ics)。

★ **#6-8 那个「合集下载」是唯一整块缺失的功能域** —— 三条端点齐全、上游有独立控制器,
而我们连一条都没有。Go 侧要不要补是产品决定,但**别再说「51 条已经全量对齐上游」**。

---

### 12.4 `anirss_proxy_image_url` 到底为什么需要代理(补 §11-4)

> §11 原写「推测是上游图片需要带 token,但未验证」。**读完上游实现,这个推测是错的。**

`ProxyImageController.proxyImage`(`controller/ProxyImageController.java:37-118`)干四件事:

1. **走服务端配置的 HTTP 代理出网。**
   取图用 `HttpReq.get(url)`,而 `HttpReq` 会 `setProxy(req)`,把
   `Config.proxy / proxyHost / proxyPort / proxyUsername / proxyPassword` 应用上去
   (`util/basic/HttpReq.java:52, 89-127`)。**这才是主要理由**:TMDB / BGM 的图源
   在很多网络下客户端直连不通,而 ani-rss 那台通(它本来就要靠这条代理去刮元数据)。
   我们客户端**没有**这份代理配置,也不该有。
2. **服务端磁盘缓存。** 落在 `<config>/img/<md5首字符>/<md5(imgUrl)>.<扩展名>`
   (`:88-100`),命中就不再出网;响应带 **30 天** `Cache-Control: private, max-age=2592000`
   (`:70-72`,`BaseController.setCacheControl`)。
3. **修 Mikan 的自动重定向。** 跟随后主机名变了就用新主机重拼 URL 再取一次
   (`:102-117`,注释原文「处理mikan自动重定向的问题」)。
4. **SSRF 闸。** `URLUtils.verify` 拒绝非 `http(s)`、拒绝 `127.0.0.1`/`localhost`、
   拒绝内网 IPv4(`commons/URLUtils.java:40-59`)。

**token 的真相**:需要 token 的是**这条代理端点本身**(`@Auth`,`:37`),
**不是上游那张图**。这就是为什么我们的 wrapper 必须 `async`——
它要先 `ensure_token` 才拼得出带 `s=<token>` 的 URL(`crates/core/src/source/anirss.rs:1000-1010`);
纯 URL 拼接那部分是同步的 `build_proxy_image_url`(`:1013-1024`)。

**现状:全仓零调用方。** `ui/shared/api.ts:1303-1304` 有 wrapper,
两端 `AniRssPage` 都直接 `<img src={ani.image}>`
(`ui/desktop/pages/AniRssPage.tsx:356-368`、`ui/mobile/pages/AniRssPage.tsx:142`),
封面加载失败就退占位图。所以**「图片走代理」这个能力做好了但一次都没用上**。

**Go 侧**:保留这条(它是「用户网络进不去 TMDB」时唯一的封面来源),
但接线时要注意 `imgUrl` 必须**先 base64 再 URL 转义**,且 token 里的 `+/=` 必须转义
——两条都已有测试钉住(`crates/core/src/source/anirss.rs:1210-1220`)。

---

### 12.5 上游 API 的版本化与破坏性变更史(补 §11-5)

#### 12.5.1 结论:**完全没有版本化**

- 72 个端点全在**扁平的 `/api/*`** 下,前缀由 `config/WebMvcConfig.java` 的
  `addPathPrefix("/api", …)` 统一加(§1.3)。**没有 `/v1/`、没有 `Accept-Version`、
  没有 `Deprecation`/`Sunset` 响应头**(扫过全部 24 个 `*Controller.java`,零命中)。
- 唯一的版本信号是 `POST /api/about` 返回的 `About{version, latest, update, markdownBody}`
  (`controller/AboutController.java:29-34`)。
- 而发版节奏是**平均一天一个 release**(§1.2)。

**两条合起来 = 上游随时可以改线上契约,而客户端拿不到任何提示。**
再叠上「HTTP 状态码恒 200、真实结果在 body 的 `code`」(§1.3),
表现就是**功能静默失效**,不是报错。

#### 12.5.2 破坏性变更实录(逐条查 commit 得到)

| 日期 | commit | 标题 | 改了什么 | 我们中招了吗 |
|---|---|---|---|---|
| 2026-05-03 | `646495fb` | 优化接口 /api/listAni | `ListAni` 加 `total` 字段 | 否(纯加法) |
| **2026-05-08** | **`a91b5b76`** | 图片与文件接口改动 | `PlayItem.filename` 与 `Subtitles.url` 由 **base64 改成裸绝对路径**;`/api/file` 由「是 base64 才解」改成 **无条件 `Base64.decodeStr`**;编码责任移交客户端(`ani-rss-ui/src/js/global.js` 新增 `base64Encode`/`toApiFile`) | **中招,见 12.5.3** |
| **2026-05-09** | **`1b049c8d`** | 获取字幕接口改动 | `/api/getSubtitles` 由 `@RequestBody Map{file}` 改成 `@RequestParam filename`;`/api/getSubtitles` 与 `/api/proxyImage` 双双由「是 base64 才解」改成**无条件解** | 参数位置我们是对的(query `filename`);编码归属见 12.5.3 |
| **2026-07-06** | **`69cde152`** | AniBT 支持搜索 | `/api/aniBT` 由 **query 参数** `season`/`bgmUrl` 改成 **`@RequestBody AniBTQueryDTO{season,bgmUrl,title}`** | **中招**——我们 `ani_bt` 发的是 `Value::Null`(无 body),`crates/core/src/source/anirss.rs:734-741` |
| 2026-08-24 | `9e42639a` | 优化登陆逻辑 | `AuthUtil.resetKey/getAuth` 重命名为 `resetSessionId/getToken` | 否——**已核对当前 `main` 的 `/api/login` 线上契约未变**:body `{username, password(MD5)}` → `data` 是 JWT 串(`controller/LoginController.java:24-56`) |

**四条破坏性变更里有三条是同一个模式:「参数位置 / 编码归属」搬家,不是加删字段。**
这类变更**编译期无感、单测无感、连响应码都不变**——上一次我们发现,是靠逐行读上游源码。

#### 12.5.3 由此确认的一个真 bug(比 §7 已列的都严重)

`a91b5b76` 之前 `PlayItem.filename = Base64.encode(absolutePath)`;
之后 `PlayItem.filename = absolutePath`(**裸路径**,`controller/PlayController.java:156-160`),
`Subtitles.url` 同样从 base64 改成裸路径(`:215-219`),
而 `/api/file` 与 `/api/getSubtitles` 都**无条件** `Base64.decodeStr`
(`controller/FileController.java:41-42`、`controller/PlayController.java:41-42`)。
上游自家 Web UI 因此改成在客户端编码:`toApiFile(filename)` → `base64Encode`
(`ani-rss-ui/src/js/global.js:145-150`、`ani-rss-ui/src/view/play/PlayStartView.vue:22-24`)。

**我们这边仍按旧契约走**:
- `list_dir` 把 `p["filename"]` 当**已经是 base64** 直接塞进 `entry.id`(`crates/core/src/source/anirss.rs:305-309`);
- `resolve_play` 把它**原样**当 `?filename=` 发给 `/api/file`(`:344-348`);
- `get_subtitles` 的文档注释还写着「**勿再编码**」(`:805`);
- `safe_decode` 拿它去 base64 解码做显示兜底(`:239-247`)——现在恒失败退回原串。

**后果(按上游源码推演,未在真服实测)**:服务端把一条裸路径拿去 base64 解码得到乱码,
`verifyFileFormat` 的扩展名断言过不了 → 「不允许访问」;即使侥幸过了也 404。
**即 v3.x(≈2026-05 起)的 ani-rss 上,我们这个源点任何一集都放不出来。**
外挂字幕同理:`subtitles[].url` 现在是裸路径,而我们把它当相对 URL 去拼
`{base}{/}{u}`(`:333-346`),拼出来是 `<base>/mnt/…/xxx.ass`,必 404。

**修法**:`filename` / `subtitles[].url` 在**我们这边** base64 编码后再发;
`safe_decode` 改成直接取路径末段;`get_subtitles` 那条注释要反过来写。
**Go 侧移植时这三处必须一起改,并且用真服录制包对账**(见 §10 的差分对账说明)。

#### 12.5.4 顺手更正:`/api/ping` 是存在的

§3 第 45 条与 §7-2 写着「上游 `main` 根本没有这个映射,恒失败」。**这条是错的。**
`/ping` 在 `controller/ConfigController.java:103-107`,用的是
**`@RequestMapping("/ping")`**(不限方法,GET/POST 都收)、**且没有 `@Auth`**。
之所以之前没找到,是因为按 `@GetMapping`/`@PostMapping` 去搜会漏掉裸 `@RequestMapping`。

我们的 `ping` 走 `request_text` 的 GET(`crates/core/src/source/anirss.rs:865-871`)是**通的**,
只是它会先 `ensure_token` 白登一次(上游这条根本不校验),
Go 侧应当让存活探测**跳过鉴权**。

---

### 12.6 51 条命令 ↔ 上游端点的完整对照(补 §11-6)

#### 12.6.1 先更正一个数:是 **51 条**,不是 52 条

`apps/desktop/src/lib.rs` 里 `generate_handler!` 注册表实际登记 **51** 个 `anirss_*`
(`:6012-6062`);源码里能匹配到 `fn anirss_*` 的有 52 个,多出来的那个是
**`anirss_ctx`(私有辅助函数,不是命令)**(`:3909`)。安卓侧同样是 51 注册 + 1 辅助
(`apps/android/src/lib.rs:4900-4950`、`:2684`)。§8 那张表的「52」按 `fn` 计数,
把 `anirss_ctx` 算进去了 —— **§8 的结论(压倒性是薄包装)不受影响**,只是分母该写 51。

**两端签名逐字相同**:把两个文件里的 `fn anirss_*` 签名各自排序后 `diff`,**零差异**
(52 行 vs 52 行)。这是目前唯一在跑的双端对账手段(见 §12.2 最后一条)。

#### 12.6.2 逐条对照(49 条经 `call()` 的 + 2 条特殊 + 2 条不打网络)

| `/api/about` | About | `anirss_about` :4029 | `about` :585 |
| `/api/stop` | About | `anirss_stop` :4238 | `stop` :915 |
| `/api/testIpWhitelist` | About | `anirss_test_ip_whitelist` :4224 | `test_ip_whitelist` :897 |
| `/api/update` | About | `anirss_server_update` :4231 | `server_update` :906 |
| `/api/addAni` | Ani | `anirss_add_ani` :3960 | `add_ani` :476 |
| `/api/batchEnable` | Ani | `anirss_batch_enable` :4004 | `batch_enable` :552 |
| `/api/deleteAni` | Ani | `anirss_delete_ani` :3972 | `delete_ani` :495 |
| `/api/downloadPath` | Ani | `anirss_download_path` :4049 | `download_path` :606 |
| `/api/listAni` | Ani | `anirss_list_ani` :3920 | `list_ani` :412 |
| `/api/previewAni` | Ani | `anirss_preview_ani` :4037 | `preview_ani` :596 |
| `/api/refreshAll` | Ani | `anirss_refresh_all` :3988 | `refresh_all` :524 |
| `/api/refreshAni` | Ani | `anirss_refresh_ani` :3982 | `refresh_ani` :513 |
| `/api/refreshCover` | Ani | `anirss_refresh_cover` :4067 | `refresh_cover` :636 |
| `/api/rssToAni` | Ani | `anirss_rss_to_ani` :4152 | `rss_to_ani` :780 |
| `/api/setAni` | Ani | `anirss_set_ani` :3966 | `set_ani` :485 |
| `/api/updateTotalEpisodeNumber` | Ani | `anirss_update_total_episode_number` :3994 | `update_total_episode_number` :533 |
| `/api/aniBT` | AniBT | `anirss_ani_bt` :4127 | `ani_bt` :734 |
| `/api/aniBTGroup` | AniBT | `anirss_ani_bt_group` :4133 | `ani_bt_group` :743 |
| `/api/animeGardenGroup` | AnimeGarden | `anirss_anime_garden_group` :4145 | `anime_garden_group` :763 |
| `/api/animeGardenList` | AnimeGarden | `anirss_anime_garden_list` :4139 | `anime_garden_list` :754 |
| `/api/getAniBySubjectId` | Bgm | `anirss_get_ani_by_subject_id` :3954 | `get_ani_by_subject_id` :466 |
| `/api/getBgmTitle` | Bgm | `anirss_get_bgm_title` :4055 | `get_bgm_title` :616 |
| `/api/meBgm` | Bgm | `anirss_me_bgm` :4103 | `me_bgm` :694 |
| `/api/rate` | Bgm | `anirss_rate` :4091 | `rate` :674 |
| `/api/searchBgm` | Bgm | `anirss_search_bgm` :3948 | `search_bgm` :455 |
| `/api/setRate` | Bgm | `anirss_set_rate` :4097 | `set_rate` :684 |
| `/api/clearCache` | Config | `anirss_clear_cache` :4196 | `clear_cache` :856 |
| `/api/config` | Config | `anirss_get_config` :4016 | `get_config` :567 |
| `/api/downloadLoginTest` | Config | `anirss_download_login_test` :4208 | `download_login_test` :876 |
| `/api/exportConfig` | Config | `anirss_export_config_url` :4260 | `export_config_url` :946 |
| `/api/importConfig` | Config | `anirss_import_config` :4267 | `import_config` :959 |
| `/api/ping` | Config | `anirss_ping` :4202 | `ping` :865 |
| `/api/setConfig` | Config | `anirss_set_config` :4023 | `set_config` :576 |
| `/api/testProxy` | Config | `anirss_test_proxy` :4214 | `test_proxy` :886 |
| `/api/getEmbyViews` | Emby | `anirss_get_emby_views` :4250 | `get_emby_views` :936 |
| `/api/clearLogs` | Logs | `anirss_clear_logs` :4190 | `clear_logs` :848 |
| `/api/downloadLogs` | Logs | `anirss_download_logs` :4184 | `download_logs` :834 |
| `/api/logs` | Logs | `anirss_logs` :4178 | `logs` :825 |
| `/api/mikan` | Mikan | `anirss_mikan` :4111 | `mikan` :706 |
| `/api/mikanGroup` | Mikan | `anirss_mikan_group` :4121 | `mikan_group` :724 |
| `/api/newNotification` | Notification | `anirss_new_notification` :4244 | `new_notification` :927 |
| `/api/getSubtitles` | Play | `anirss_get_subtitles` :4170 | `get_subtitles` :806 |
| `/api/playList` | Play | `anirss_play_list` :3926 | `play_list` :422 |
| `/api/proxyImage` | ProxyImage | `anirss_proxy_image_url` :4278 | `proxy_image_url` :1002 |
| `/api/batchScrape` | Scrape | `anirss_batch_scrape` :4079 | `batch_scrape` :659 |
| `/api/scrape` | Scrape | `anirss_scrape` :4073 | `scrape` :646 |
| `/api/getThemoviedbGroup` | Themoviedb | `anirss_get_themoviedb_group` :3932 | `get_themoviedb_group` :432 |
| `/api/getThemoviedbName` | Themoviedb | `anirss_get_themoviedb_name` :4061 | `get_themoviedb_name` :626 |
| `/api/torrentsInfos` | TorrentsInfos | `anirss_torrents_infos` :3940 | `torrents_infos` :444 |

**上表 49 行。** 另有 2 条命令走的不是 `call()`:

| 上游端点 | 我们的命令 | 说明 |
|---|---|---|
| `GET /api/file`(`FileController.java:39`) | **没有对应命令** | 只在 `resolve_play` 内部拼成播放 URL(`crates/core/src/source/anirss.rs:342-350`),前端拿到的是成品 URL |
| `POST /api/login`(`LoginController.java:24`) | **没有对应命令** | 只由 `ensure_token` 内部调(`anirss.rs:31-57, 84`);源登录走的是通用的 `source_login`(`apps/desktop/src/lib.rs:3516`) |

以及 2 条**一个字节都不发**的命令:

| 命令 | 干什么 | 出处 |
|---|---|---|
| `anirss_preview_items` :4044 | 纯解析:从 `previewAni` 的返回里按形状捞「元素是对象的非空数组」 | `anirss.rs:1040-1052` |
| `anirss_clear_token` :4285 | 清内存 token 缓存(§4.5) | `anirss.rs:95-98` |

**账对得上:49 + 2 = 51 条命令;49 + `/api/file` + `/api/login` = 51 个上游端点被触达。**
上游共 72 个端点,未接 21 个(逐条见 §12.3),反向差集为 0(不存在我们打了而上游没有的路径)。

#### 12.6.3 对照过程中发现的三处**命令名与语义不符**

| 命令 | 打的端点 | 问题 |
|---|---|---|
| `anirss_get_config` | `POST /api/config` | 端点叫 `config`,命令叫 `get_config` —— Go 侧新契约要在**两个名字里挑一个**并写进对照表,别再靠人记 |
| `anirss_server_update` | `POST /api/update` | 唯一一处命令名和端点名完全对不上;取名是对的(`update` 太容易被当成「更新订阅」),但必须显式登记 |
| `anirss_get_subtitles` | `POST /api/getSubtitles` | §6.2 把它写成「拿字幕组列表」是**错的**。上游这条只处理 **`.mkv` 的内封字幕**,用 EBML 解出来转成 VTT 塞进 `content`、`url` 恒为空串(`controller/PlayController.java:37-84`),与「字幕组(subgroup)」毫无关系 |

#### 12.6.4 给 Go 侧的一条落地要求

这张对照表本身就该是**产物**,不是文档:端点表(路径 / 方法 / 参数位置 / body 形状)
放进核心层一个文件,命令绑定、`COMMANDS.md`、以及这张对照表全部由它生成(§8.2)。
理由在 §12.5 已经写清楚了 —— **上游没有版本化,改的又都是「参数位置 / 编码归属」,
只有一张能机器比对的表才拦得住下一次静默失效。**
