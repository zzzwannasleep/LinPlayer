# Emby 协议 / 媒体库 / 图片 / 上报 / fork 差异

**这个领域最容易踩的坑:**
1. **fork 服和原版 Emby 行为不一样**,拿 A 服的结论替 B 服签字 = 假验证(忽略 `maxWidth`、`Filters=IsFavorite` 上无视 `SortBy`、带 `SearchTerm` 时忽略一切筛选参数)。
2. **别照 Jellyfin 的经验往 Emby 上套**:`EnableTotalRecordCount`、`ImageBlurHashes` 在 Emby 根本不存在;`UserData`/`SeriesName` 也不是 `Fields` 的合法值。
3. **单次请求硬上限 200 条**,`Limit=500` 只回 200 且不报错 —— 唯一正解是 `StartIndex` 翻页。
4. **上报三件套必须带 `PlaySessionId` 且与取流会话同 id**,否则续播进度不落地。
5. **相对路径要拼在对的 API 根上**:`DirectStreamUrl` 拼错前缀时反代不处理 Range,表现是「跳到未缓冲位置卡死」。

> 本文件共 **14** 条。每条都标了它的原记忆文件名与类型;正文按原样搬运,未做压缩或改写。

## 本页条目

- Emby Fields 合法值+压缩 — `emby-fields-enum-and-compression.md`
- Emby image tags — `emby-image-tags.md`
- Emby 图片 API 实测坑(UHD) — `emby-image-api-quirks-uhd.md`
- Emby PlaySessionId 续播 — `emby-playsessionid-resume.md`
- 外挂字幕真根因 — `emby-external-subtitles.md`
- 跳到未缓冲位置卡死=我们拼错API根 — `server-ignores-http-range.md`
- UHD fork 无视收藏 SortBy — `uhd-fork-ignores-sortby-favorites.md`
- Emby 测试服务器 — `emby-test-server.md`
- Emby 测试服 #2 · 服务端B(更接近原版的那台) — `emby-test-server-2-<代号B>.md`
- Library filter panel — `library-filter-panel.md`
- 媒体库屏蔽 — `library-blocklist.md`
- 库内搜索 — `library-scoped-search.md`
- 未看集数角标 — `unwatched-episode-badge.md`
- Batch add & deeplink — `batch-add-and-deeplink.md`

---

### Emby Fields 合法值+压缩

> 原记忆:`emby-fields-enum-and-compression.md` · 类型:`reference`

2026-07-23 把 `https://swagger.emby.media/openapi.json`(2.0 MB,356 个 path)拉到本地实证。**WebFetch 会截断,必须 curl 下来用 python 解析。**

##### Fields 的合法值(官方 spec 原文)

`GET /Users/{UserId}/Items` 的 `Fields` 描述列出的选项**只有**:
`Budget, Chapters, DateCreated, Genres, HomePageUrl, IndexOptions, MediaStreams, Overview, ParentId, Path, People, ProviderIds, PrimaryImageAspectRatio, Revenue, SortName, Studios, Taglines`

- **`UserData` 不是 Fields 值** —— 用户数据走**独立的 `EnableUserData` 布尔参数**(且默认就返回)。任何「Fields 里补个 UserData 就能反显已看角标」的建议都是错的。
- **`SeriesName` 也不在这个表里**(它是 BaseItemDto 的基础属性,分集默认就带)。
- **`EnableTotalRecordCount` 这个参数在 Emby 上根本不存在**(那是 Jellyfin 的)。别照 Jellyfin 的性能经验往 Emby 上套。
- 真实存在的减负参数是 `EnableImages` / `EnableImageTypes` / `ImageTypeLimit` / `Ids`(批量取代多次单条 GET)。

⚠️ 这段描述是**散文列表不是 enum schema**,而我们现网在用的 `Fields=MediaSources` 确实工作(分集卡的「2160p · 45M · 18.4G」有值)。所以它**不完整**,不能拿它当白名单去删现有 Fields;只能拿它证伪「加某个值就会生效」这类主张。

##### reqwest 曾经一个 Accept-Encoding 都不发

`crates/core/Cargo.toml` 是 `default-features = false`,而 features 里**没勾 gzip/brotli** → Emby 的列表 JSON 全程明文传,且**任何地方都不会报错**。
修法:features 补 `gzip`/`brotli`,并在 `http.rs` 按客户端分开(`enum Compress`):

- `client()` / `emby_client()` → 开。JSON 重复结构压后常剩 10~20%。
- `preload_client()` → **显式关**。预取代理靠 `Content-Length` 和 Range 语义对齐分段偏移,透明解压会把长度变成解压后的值甚至抹掉 → 分段错位;视频容器本来也压不动。

守卫测试 `api_clients_negotiate_compression_but_media_client_does_not`:起 TcpListener 收一次真请求验请求头。**必须端到端发一次** —— `.gzip(true)` 在 feature 没勾时代码照编、测试照过、请求里一个字节都没有。

**Why:** 子 agent(Haiku)给的 Emby 优化建议里有 3 条是拍脑袋的 Fields 补丁,照做会白改一通还以为提速了。
**How to apply:** 见 [「待接」多半是谎](methodology.md)(同类「不查真接口就下结论」)、[不发 UA 就吃 403](network.md)(reqwest「不设=不发」的同一个坑)、[Emby 图片 API 实测坑(UHD)](emby.md)(fork 服行为不一致,凡依赖参数都要真服 A/B)。

---

### Emby image tags

> 原记忆:`emby-image-tags.md` · 类型:`reference`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

Emby `/Items` JSON 的图片 tag 分布（解析见 `_parseMediaItem`/`_extractBackdrop` in `lib/core/api/emby_api.dart`）：

- `ImageTags` map 只含 **Primary / Thumb / Logo / Art / Banner / Disc** 等。
- **Backdrop 不在 `ImageTags`**，在独立数组 `BackdropImageTags`（取 `[0]`）。剧集/季自身无背景时用父级 `ParentBackdropImageTags` + `ParentBackdropItemId`。
- **Logo** 自身在 `ImageTags['Logo']`，父级回退 `ParentLogoItemId` + `ParentLogoImageTag`。
- 取背景图 URL 必须用背景图**所属的 itemId**（`MediaItem.backdropItemId`，回退父级时是剧集 id），用自身 id 会 404 → 退回封面图。这是之前"详情页背景沿用封面图"的根因。
- 这些字段要在请求的 `Fields=` 里显式列出才会返回（`BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ParentLogoItemId,ParentLogoImageTag`）。
- `getBackdropImageUrl` 不要强制 `maxHeight`，否则全屏背景被压成低清发虚。

背景图/封面解析统一走 `lib/ui/utils/media_helpers.dart` 的 `resolveMediaItem*ImageUrls`（Landscape/Banner 为 backdrop-first）。相关动效见 「motion-system」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)。

---

### Emby 图片 API 实测坑(UHD)

> 原记忆:`emby-image-api-quirks-uhd.md` · 类型:`reference`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

2026-07-15 在 <Emby 测试服 A> **实测**(不是查文档)。它自报 `Version 4.9.3.0`,
但**是个 fork/反代**,行为和原版 Emby 不同。见 [Emby 测试服务器](emby.md)。

##### 登录有坑
只传 `Pw` 恒 401。必须**同时**带旧版 SHA1 的 `Password` 字段:
`{"Username":"...","Pw":"...","Password":"<sha1(pw) hex>"}`。
条目 id 带前缀:剧集 `m…` / 季 `s…` / 分集 `e…`;图片 tag 是**合成的**(`p`+id / `f`+id / `l`+id / `t`+id),不是哈希。

##### ★ 尺寸参数**完全被忽略**
`maxWidth` / `maxHeight` / `quality` / `format` 全部**接受并丢弃**。实测同一张图 6 种参数组合
**字节数完全相同**,都是 1920×1080 / 450KB 原图。原因:`/Items/{id}/Images/Backdrop/0`
会 **301 跳到静态文件** `/img/i/fanart/{id}.jpg`,压根没有服务端缩放。

**推论**:
- 前端写 `h=480` / `w=640` 是**白写的**,省不了流量,图片缓存里平均 297KB 就是这么来的。
- HTTP 客户端**必须跟 301**,否则拿到 79 字节 HTML,再被 MIME 嗅探判成 octet-stream →
  「图不显示但也不报错」。reqwest 默认跟,别给那个 client 关掉。
- **用户 2026-07-15 明确否掉「在 Rust 侧解码缩放再缓存」** —— 不加图像处理依赖。别再提。

##### 分集(Episode)的图片
- `BackdropImageTags` **键根本不存在**(0/22),不是空数组 —— 判空要先判键在不在。
- `ParentBackdropImageTags` / `ParentBackdropItemId` **这个 fork 不发**(0/22),即使显式请求。
  原版 Emby 有,所以可以 gate 但**绝不能依赖**。
- 唯一可用路径:`SeriesId` → `/Items/{SeriesId}/Images/Backdrop/0`。现有代码
  `bgId = d?.series_id ?? item.id` 正好是对的。
- 分集**自己有** `ImageTags.Primary` = **横版剧照**(22/22),这就是集详情页横版封面的来源。

##### 覆盖率与缺失形态
剧集 Backdrop **50/50**、电影 **46/50(92%)**、Primary 100/100、Logo 84/100。
缺失一律表现为**键不存在**,不是 `[]`。8% 的电影走纯色兜底即可,别为它加复杂度。

##### BlurHash 不存在
`ImageBlurHashes` 0/100,任何 Fields 组合都没有 —— 那是 **Jellyfin** 的字段,**Emby 从来没有**。
没有主色/平均色可用。要背景取色只能自己解码像素。

##### 相似推荐
旧 Flutter 栈的既定口径(`git show HEAD:lib/core/api/emby_api.dart`):
`GET /Items/{id}/Similar?UserId={uid}&Limit=12&Fields=...` → `resp['Items']`。
**旧栈调过 ≠ 这台 fork 能用**,用前先实测。

---

### Emby PlaySessionId 续播

> 原记忆:`emby-playsessionid-resume.md` · 类型:`project`

**Emby 播放上报三件套(`/Sessions/Playing` Start / `/Progress` / `/Stopped`)必须带 `PlaySessionId`,否则续播进度不落地。** 症状:看动漫看到一半退出,Emby 里续播进度仍停在原来(续播起始)位置,只有整集看完才标已观看——因为 Emby 用 PlaySessionId 把 Start→Progress→Stopped 关联成同一会话再写 UserData.PlaybackPositionTicks,缺它则丢弃进度。

关键:上报的 PlaySessionId **必须与取流 URL(`getVideoStreamUrl` 的 playSessionId)是同一个**,Emby 才能把上报和流会话对上。三端都取 `selection.primaryRequest.playSessionId`(TV 是 `req.playSessionId`)。链路:`PlaybackStart/Progress/StopInfo.playSessionId` 字段 → `EmbyPlaybackApi` 三个上报 payload 加 `PlaySessionId` → `video_player_service` 存 `_playSessionId`(`initialize` 传入)→ `_reportStart/_reportProgress/_reportStop` 带上 → 三端 `initialize(playSessionId: selection.primaryRequest.playSessionId)`。网盘/聚合直链(source_playback)无 Emby 会话,playSessionId 为 null 不影响。

上报节奏:`_startProgressTimer` 每 5s 一次(不是用户以为的 30s),`position` 取 `_adapter.position`(mpv/native mpv 都从 time-pos 事件实时更新,值本身不 stale);退出走 `dispose()→_reportStop()`(此时 `_currentItemId` 未清、adapter 未 dispose,拿到的是实时位置)。所以进度值一直是对的,之前不生效纯粹是缺 PlaySessionId 关联。2026-07-03 修(commit 2ee7c30)。参见 「cross-server-resume」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)。

---

### 外挂字幕真根因

> 原记忆:`emby-external-subtitles.md` · 类型:`project`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。

「外挂字幕不加载」(PC+TV 都不加载) 的根因链，2026-07-21 在 <Emby 测试服 B> 真服 A/B 实测确认：

**第一层(源头)**：`resolve_stream` 的 DeviceProfile 里 `"SubtitleProfiles": []`。
空表 = 告诉服务器「本客户端一种字幕格式都不支持」，服务器于是把外挂字幕判成
`DeliveryMethod=Encode` 且 **`DeliveryUrl=null`** —— 根本没有地址可加载。
声明 `[{"Format":"ass","Method":"External"}, ...]` 后同一条流立刻变成
`DeliveryMethod=External` + `DeliveryUrl=/Videos/{item}/{msid}/Subtitles/{idx}/0/Stream.ass?api_key=…`。

**第二层**：`RawStream` 没解析 `IsExternal` / `DeliveryUrl`，内封和外挂分不开。
注意 **`Path` 不能当 URL** —— 那是服务端本地文件系统路径，客户端取不到。

**第三层**：`PlaybackTarget` 不携带字幕；**第四层**：play 路径从不调 `sub-add`。
外挂字幕是独立文件，**不在容器里**，mpv 的 `track-list` 永远看不到它 —— 必须
`load_at` **之后**逐条 `sub-add`（先挂会被 loadfile 冲掉）。

兜底路径格式必须带 `/0`(StartPositionTicks 段)，少了会 404；`subrip`→`srt`、`webvtt`→`vtt`。
测试见 `emby.rs::tests::subtitle_fallback_path_matches_real_server`（期望值抄自真服响应）。

排查手法：别看客户端日志，直接 curl 打 `/Items/{id}/PlaybackInfo`，对比不同 DeviceProfile
下 `DeliveryMethod`/`DeliveryUrl` 的差异。相关 [Emby 图片 API 实测坑(UHD)](emby.md)、[网盘/strm 播放两大坑](player-mpv.md)。

---

### 跳到未缓冲位置卡死=我们拼错API根

> 原记忆:`server-ignores-http-range.md` · 类型:`project`

2026-07-27。用户报「在缓存条没缓存到的内容直接跳过去,画面和进度条一起卡死」,
并明确指出**别的播放器在同一台服务器上都正常**。

##### 真因(是我们的 bug)

```
GET /videos/16612/original.mkv       Range: bytes=1000000-1000099  -> 200 OK,整个文件
GET /emby/videos/16612/original.mkv  Range: bytes=1000000-1000099  -> 206,content-range 正确
```

PlaybackInfo 返回的 `DirectStreamUrl` 是**相对路径**(`/videos/…`),`abs_url` 直接
`format!("{}{}", s.server, path)` 拼在服务器根上。Emby 本体在根和 `/emby/` 两个前缀上
都提供 API,所以我们整套接口(Users/Items/Sessions…)一直正常 —— 但用户那两台服务器
前面挂了反代,**只有 `/emby/` 那条路由正确处理 Range**。别的播放器没事,是因为它们按
Emby 惯例把相对地址拼在 `/emby` API 根上。

ffmpeg 拿不到 206 就只能从当前位置**顺读丢弃**到目标字节:跳 9 分钟 = 370MB。
所以近距离跳只是慢(跳 3 秒 ≈ 7 秒落地),远距离跳就是永远到不了。

##### 修法:实测,不写死

两个候选各发一次 `Range: bytes=0-0`,谁回 206 用谁,每台服务器每次运行只探一次。
写死 `/emby` 会在 Jellyfin(没这个前缀)和带 base path 的部署上把好地址改坏;
而「哪个前缀能 Range」恰恰是唯一在乎的性质,直接测它最准。
原地址能 Range 就一个字不动;都不行也保持原样。**探测失败一律回原样 —— 它绝不能挡住起播。**

##### 查法(两步定死)

1. `LP_MPV_LOG=1` 起 app,读 `userdata/logs/mpv.log`:
   `https: Unexpected offset: expected N, got 0` + `Seek failed` = 服务器没给 206。
2. curl 打真 URL,**并且把候选地址一起打**(这一步我第一轮漏了,导致误判成"服务器的锅"):
   `curl -D- -H 'Range: bytes=1000000-1000099' <url>`,看 `206` vs `200`。
   还可以直接问服务器 `POST /emby/Items/{id}/PlaybackInfo` 看它自己给的 `DirectStreamUrl`。

真机验证口径:同一次跳转,改前 30s 纹丝不动 / `Seek failed` ×6,改后 3.3s 落地 / 计数 0。

**Why:** 「只有我们不行」这句话本身就是最强的定位信息 —— 它直接排除了服务器,
把范围锁死在"我们发出去的请求和别人不一样"。我第一轮拿 curl 复现了 200 就下结论
说是服务器的锅,**只测了我们在用的那一个地址,没测别人可能在用的地址**,这是错的。
用户顶回来才找到真因。观察到"外部工具也复现"只证明不是本地状态问题,**不证明请求是对的**。

**How to apply:** 见 [没加载完就点进度条](player-mpv.md)(同一轮的客户端侧三个真 bug)、
[Windows 无画无声"加载不出来"](player-mpv.md)(同款 curl/ffprobe 打真 URL 的查法)、
[挂真机 CDP 调试](methodology.md)、[mpv 发行版卫生](player-mpv.md)(LP_MPV_LOG 为什么默认关)。
`Status.seek_stalled`(12s 卡死提示)保留 —— 真遇到不认 Range 的服务器它仍是唯一的解释来源。

---

### UHD fork 无视收藏 SortBy

> 原记忆:`uhd-fork-ignores-sortby-favorites.md` · 类型:`reference`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。

**用户的主力 Emby 服 `<用户主力 Emby 服(UHD fork)>` 是 UHD fork，它在 `Filters=IsFavorite` 查询上
完全无视 `SortBy`/`SortOrder`**，恒按 DateCreated 降序返回。

2026-07-19 在真机日志里抓到的铁证（URL 原样到达服务器，返回顺序 6 次全同）：
```
SortBy=SortName&SortOrder=Ascending    -> ["虽然我是不完","钟馗","真爱留声","雀骨","爱情有烟火","我成为了贵族"]
SortBy=CommunityRating&SortOrder=Desc  -> 完全相同
```
注意 `SortName/Ascending` 的结果**根本不是按名称排的** —— 这是判定"服务端在装死"的关键信号。

**但媒体库(`/Items?ParentId=`)的 SortBy 在同一台服上是好的**（SortName 升/降、
CommunityRating 降都正确）。所以是**按端点**坏，不是整台坏，别一刀切。

**字段实测**（同一台服，`Fields=` 要了才给）：
- `DateCreated` ✅ 真实时间戳 · `DateLastMediaAdded` ❌ 恒 null · `SortName` ✅ · `CommunityRating` ✅
- 所以 Item.date_updated = `DateLastMediaAdded ?? DateCreated`

**两台服都验过**（2026-07-19，本地排序方案）：
- UHD(fork) 六种组合全部正确；<Emby 测试服 B>(原版) 也全部正确，
  名称档是标准拼音序(d→f→h→l→x→z)，更新时间档能逐条对上 DateCreated，无评分两个方向都沉底。
- 原版 Emby 的 `date_updated` / `sort_name` 同样正常回传 → 本地排序方案跨服成立。

**How to apply**：
- 收藏排序已改成**前端本地排**（`src/pages/favorites-sort.ts` + 同名 `.test.mjs` 自检）。
- **教训**：我先在 「emby-test-server-2-测试服 B」(该条不在本库,多为 Flutter 时代的旧记忆,已作废) 上 curl 验证通过就当交付，那台是原版、认 SortBy；
  **拿 A 服的结论替 B 服签字 = 假验证**。凡是"服务端参数生效"类结论，必须在**目标服务器**上验。
- 和 [Emby 图片 API 实测坑(UHD)](emby.md) 同源：这台 fork 无视参数是惯犯（maxWidth 也被忽略）。

---

### Emby 测试服务器

> 原记忆:`emby-test-server.md` · 类型:`reference`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。

**Emby 测试服务器**(用户 2026-07-15 提供,服主已授权测试):
- 地址:`https://<Emby 测试服 A>`
- 账密**与 UHD 插件测试号同一套**(见 [UHD 测试账号](plugins.md)):`<测试用户名>` / `<测试密码>`

**注意别混淆**:`<UHD 求片站>` 是**求片站**(插件用,走自家 `/api/v1/auth/login`);`<Emby 测试服 A>` 才是 **Emby 媒体服务器**(走标准 `/Users/AuthenticateByName`)。同一账密,两个完全不同的服务。

curl 实测姿势(Windows 上 python 读 JSON **必须 `encoding='utf-8'` + `PYTHONUTF8=1`**,否则 GBK 解码炸,见 [PowerShell GBK/UTF-8 坑](build-release.md);用户名含中文用 `--data-binary @file` 避免 shell 编码):
```
curl -X POST "https://<Emby 测试服 A>/Users/AuthenticateByName" \
  -H 'X-Emby-Authorization: MediaBrowser Client="LinPlayer", Device="PC", DeviceId="lp-test-001", Version="0.1.0"' \
  -H 'Content-Type: application/json' --data-binary @login.json
```
→ `AccessToken` + `User.Id`(`<user id>`),后续 `?api_key=<token>` 或 `X-Emby-Token` 头。

**2026-07-15 实测定论**(全 HTTP 200):
- 14 个媒体库(华语/欧美/亚洲/动画 电影+剧集、综艺、纪录片、演唱会、儿童…),`CollectionType` = movies/tvshows。
- `Users/{u}/Items/Latest?ParentId=&GroupItems=true` 返**裸数组**(非 `{Items}` 包裹)——核层已按此写。
- `Items/Resume` 有 25 条,但该账号 `PlaybackPositionTicks` 全 0(没真看过)→ **想验进度条/续播得先真播一段**,别指望现成数据。
- `Items/{id}/PlaybackInfo` → `SupportsDirectStream:true`,`DirectStreamUrl` 是**相对路径** `/play/video/<id>?api_key=`(核层 `abs_url` 已处理),**且 302 跳到 CDN**(`<UHD CDN 域名>`),Range 请求返 206 正常。→ 正是 [网盘/strm 播放两大坑](player-mpv.md) / [Windows 无画无声"加载不出来"](player-mpv.md) 记的 302 流场景;**native-poc 的 Rust 栈从没设 `multiple_requests=1`,没继承 Flutter 那个坑**(已 grep 确认)。
- 片源 mkv/hevc + aac,内封 subrip 字幕。

**靠它抓到的真 bug**(纯本地测不出来):`Item` 缺 `series_name` —— Emby 的 `Episode.Name` 只有「第 35 集」,剧名单独在 `SeriesName`,继续观看/收藏/搜索这些混排列表全显示成「第 35 集」认不出是哪部。已修:`RawItem.SeriesName` → `Item.series_name`(单一 `From<RawItem>` 漏斗,所有列表端点一并受益)+ 前端 `itemLabel()` 给 Episode 拼「剧名 · 集名」。回归测试 `emby::tests::episode_carries_series_name` 用真实载荷钉住。

**How to apply:** 改完 Emby 相关的核层/UI,拿它跑一遍再说「做完了」;`native-poc` 的真实链路验证只能靠它。

---

### Emby 测试服 #2 · 服务端B(更接近原版的那台)

> 原记忆:`emby-test-server-2-<代号B>.md` · 类型:`reference`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

**第 2 台 Emby 测试服务器**(用户 2026-07-15 提供,curl 可实测):
- 地址:`https://<Emby 测试服 B>`
- 账号 `<测试账号>` / 密码 `<测试密码>`(纯 ASCII,没有 UHD 那个中文用户名的编码坑)
- 登录:标准 `POST /Users/AuthenticateByName`,body `{"Username":"<测试账号>","Pw":"<测试密码>"}`,
  **只要 Pw,不要 SHA1 Password 字段**(UHD 那台的 fork 才要,这台是正常 Emby)。

**和 [Emby 测试服务器](emby.md)(<Emby 测试服 A>)的关键区别 —— 别混用结论**:
| | UHD(fork) | **测试服 B(更接近原版)** |
|---|---|---|
| ServerName / Version | UHD / 4.9.3.0 | <服务器名> / 4.9.5.0 |
| 条目 id | 带前缀 m…/s…/e… | **纯数字**(180918) |
| Similar/Limit 参数 | (那台没测成,号失效) | **Limit 真生效**(Limit=3 返 3) |
| 图片尺寸参数 maxWidth | **被忽略**(301 跳静态图) | 未测,别假设 |

**踩过的坑**:
- **`UID` 是 bash 只读变量**,别拿它存 userId,覆盖失败会让后续全崩。用 `MUID` 之类。
- **urllib 被这台 403**(大概过滤 UA),**必须用 curl**。凭据存 scratchpad 文件,别 echo token
  (连 `${TOK:0:12}` 截断片段都会被安全分类器拦 —— partial 也算暴露)。
- Windows python 读中文 JSON 必须 `PYTHONUTF8=1` + `encoding='utf-8'`,见 [PowerShell GBK/UTF-8 坑](build-release.md)。

##### Similar API 实测定论(2026-07-15,全 HTTP 200)
`GET /Items/{id}/Similar?UserId={uid}&Limit=12&Fields=Genres,ProductionYear,CommunityRating,BackdropImageTags`
- 返回**标准** `{"Items":[...],"TotalRecordCount":N}`(不是裸数组)。
- **相似度靠谱**:剧集「被逐出勇者小队」→ 鬼灭/JOJO/在地下城(同题材动画);
  电影「怪奇物语幕后」→ 海豚湾/登山家(纪录片,题材匹配)。可能混 Series+Movie。
- **Limit 生效**(Limit=3 实测返 3 条)。条目带 `ImageTags.Primary` + `BackdropImageTags`(各 1)。
- 剧集返 12 条,电影返 6 条(相似纪录片本就少)。TotalRecordCount 就是返回条数,没见分页需求。
- 旧 Flutter 栈既定口径一致(`git show HEAD:lib/core/api/emby_api.dart` getSimilarItems)。

**How to apply**:改 Emby 核层/UI,这台和 UHD 都能测;但结论**分开记**——
UHD 是 fork,它的怪癖(忽略 maxWidth、分集无 backdrop、id 带前缀)不代表原版 Emby。

---

### Library filter panel

> 原记忆:`library-filter-panel.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

媒体库详情页筛选面板,三端已接(mobile/desktop/TV)。

- Facet 来自各**分面专用端点**并行取:`/Genres` `/Years` `/Tags` `/Studios` `/OfficialRatings`(都带 `?ParentId&UserId&Recursive`,解析 `Items[].Name`),**不逐页拉全量**。`LibraryApi.getFilters`(`_fetchFacetNames` 通用辅助,各自吞错互不拖垮)+ `filtersProvider`。
- **不再用 `/Items/Filters`**:实测某 Emby 4.9.5(ZzzのTest)该端点恒 404,`/Users/{uid}/Items/Filters2` 又 500(Unrecognized Guid format,该服务器库 id 是数字"3"非 guid)。分面专用端点在标准 Emby 上也都在,兼容性更好。
- 过滤是服务端的:选中值经 `getLibraryItems` 回传 `/Items`(Genres/Tags 竖线分隔按名、Years 逗号分隔)。**工作室必须用 `StudioIds` 不能用 `Studios=名`**(实测 Emby 4.9.5 `Studios=名` 被忽略、`StudioIds=45`→命中);故 `Filters` 多带 `studioIds`(名→Id)映射、`LibraryFilterValue` 多存 `studioId`、选中名后查映射取 Id。
- **评分=区间筛选**(不在排序里):`LibraryFilterValue.ratingMin/ratingMax`(double);下界走服务端 `MinCommunityRating`,上界客户端兜底(Emby 无 `MaxCommunityRating`,无评分项视为不在区间)。移动/桌面 `_RatingRow` 两个数字框(回车套用);TV 暂未加(遥控器输入差)。
- **排序栏在**(不是固定 SortName——那条旧笔记已过时):`kLibrarySortOptions`(更新时间=DateCreated/标题=SortName/官方评级=OfficialRating),`_SortRow`(移动+桌面共用 `library_filter_bar.dart`),TV 自己的 `_buildSortRow`。点选中项切升降序,点新字段用其默认序(`LibraryFilterValue.toggledSort`)。
- **排序持久化(2026-07-07)**:排序原本只存在各详情页临时 `_filter`(StatefulWidget state),退出播放器返回=State 重建→回默认 SortName。修复:`media_providers.dart` `librarySortProvider`(`PreferenceNotifier<LibrarySortPref{sortBy,descending}>`,键 `linplayer_library_sort_by/_desc`)落盘,三端 `initState` 种子 `_filter`、排序变化时回写。**只持久化排序**;类型/标签/年份等筛选仍每次进页面重置(临时态)。
- **UI=每维度一行**(类型/标签/工作室/时间),默认显示「全部」,点该行弹窗(移动/桌面=showModalBottomSheet,TV=showDialog 焦点 Wrap)单选,选中回显该行;再选「全部」清除。取值列表用 `sortByPinyin`(lib/core/utils/library_filter_utils.dart,依赖 `lpinyin` 包,中文转拼音英文原样)排序;年份不排序用 `buildYearChips` 顺序。**取代了旧的一排排平铺 chip**(工作室项太多会把面板撑爆)。
- 面板组:类型=Genres、标签=Tags、**工作室=Studios**、时间=Years(`buildYearChips` 当前十年逐年+更早按"xx年代"分桶)。
- **Emby 没有"地区/country"分面端点**——地区只能借 Tags(国产刮削器常写进 Tags),没做真正的地区分面。
- **工作室**:`GET /Studios?ParentId&Recursive`(跟其它分面端点 `Future.wait` 并行,失败吞错返空);过滤用 `/Items?Studios=名称`。
- **合集(Collections)= 独立入口**(没进筛选面板):`getCollections`(一次 `/Users/{uid}/Items?IncludeItemTypes=BoxSet&Recursive`)+ `collectionsProvider`;三端首页**最底部**一行"合集"横向卡片(mobile `CollectionsSection`/desktop `_CollectionsSection` 用 `MediaPoster`、TV `_collectionCards` 用 `TvContentRow`)。点开**复用媒体库详情**展示成员:mobile/desktop `/library/{boxSetId}`(getLibraryItems 的 ParentId 吃 BoxSet id),TV `/tv/library?libraryId={id}&title={name}`(给 `TvLibraryScreen.initialTitle` 兜底标题,否则合集 id 不在 libs 里会显示错库名)。
- 纯逻辑在 `lib/core/utils/library_filter_utils.dart`(`buildYearChips` + `LibraryFilterValue`,有 test)。共用 Material 面板 `lib/ui/widgets/common/library_filter_bar.dart`(移动+桌面);TV 用自己的 `TvFocusable`+`_chip` 在 `tv_library_screen.dart`。
- 每组**单选**(再点取消)。未做:多选、"即将上线"(需 MinPremiereDate 日期过滤)。
- **媒体库详情列表拉全量(2026-07-03 修)**:`getLibraryItems` 旧默认 `limit=50` 把详情页截成 50 条不能下滑。改为 `limit<=0` 省略 `Limit` 参数(Emby 省略即返回全部),`libraryItemsProvider` 传 `limit:0`;三端共用此 provider 一处修复。GridView.builder 懒构建 + 图懒加载扛得住,超大库(上万条)若卡再上游标分页(StartIndex 增量+触底加载)。

---

### 媒体库屏蔽

> 原记忆:`library-blocklist.md` · 类型:`project`

2026-08-02 落地。用户:「给媒体库加上屏蔽功能,PC 端右键,移动端和 TV 端长按卡片。
屏蔽之后不在首页显示、详情、播放记录、不参与搜索」。

##### 过滤放核层,不放页面
「首页 / 相似推荐 / 播放记录 / 搜索」在三端各是不同页面、不同组件,十几个渲染点。
放前端 = 十几份 `.filter()`,漏一处就是"屏蔽了还看得见",而且静默。
落点是 `crates/core/src/emby.rs` 的 **`fetch_items`** 一个函数 —— 继续观看 / 接下来看 /
随机推荐 / 收藏 / 合集 / 搜索 / 相似 / 演员参演 / 分集全走它,三端一行都不用改。
`latest()` 是裸数组不走 fetch_items,单独补了一句(漏了的表现:别的行都干净了,
唯独首页「最新更新」还挂着)。观看记录在两端的 `watch_history_list` **命令里**滤,
**不**动 `Store::load_scope/load_all` —— 跨服续播匹配也读它们,在那儿滤会把
「屏蔽」悄悄变成「顺便把进度弄丢」。

##### 媒体库网格**故意不滤**
`items()` 走 `fetch_page` 而不是 `fetch_items`,所以屏蔽项仍留在媒体库里,只打「已屏蔽」
角标 + 去色压暗。滤掉的话点错一次就再也找不回来解除。三端的解除入口都在这一页。

##### 存储与匹配
`crates/core/src/blocklist.rs`,落 `data/blocklist.json`(不进 config.json —— 那里装着
全部账号令牌,不该为一次点「屏蔽」整份重写)。内存缓存常驻(过滤是热路)。
一条记录 = `{id, name, at}`,**id 和名字都要**:
- 条目列表按 id 比(准),并额外比 `series_id` —— 只比 item.id 的话,屏蔽整部剧后
  "继续观看"里的**分集**会全部漏出来(分集 id ≠ 剧 id),那是首页最显眼的一行;
- 观看记录/跨服按**名字**比 —— 同一部剧在 A 服和 B 服 id 不同,只有名字对得上。
前端存名字发命令时:分集卡必须传 `series_name`,不是「第 35 集」。传错不报错,
只是播放记录那条比对永远命中不了。

##### 屏蔽整个媒体库(2026-08-02 补,用户点名我漏了)
第一版只做了**条目**。库卡片走的是**另一套右键菜单**,而且桌面媒体库页那套原来是
`if (!admin) return` 的 admin-only —— 非管理员右键连菜单都不弹。我的 CDP 自检只右键了
条目卡(`.pitem`),没右键过库卡,所以**全绿而功能是缺的**。教训:一个功能有几套入口,
就得每套都点一遍;"同一个菜单"这个前提本身要先验证。

做法:`blocklist::is_blocked_id` + `views` 命令加 `include_blocked`(缺省过滤)。
★ 库**只按 id 判,不按名字** —— 两台服务器上都叫「电影」的库是两个不同的库。
屏蔽后首页的媒体库轨 + 它那条「最新」行一起消失;**媒体库页仍然列出它**并打标
(唯一能解除的地方)。api.ts 的 `views` 拆两个缓存键(`views` / `views:all`),
`setBlocked` 落地后一起清 —— 共用一个键的话「屏蔽了回首页它还在,再刷新才没」。
**能力边界**:屏蔽库不会自动屏蔽库里的片子(item→library 的归属 Emby 不随条目返回,
要么 N 倍请求要么缓存成员集合,都不划算)。弹窗文案里明说,不假装。

##### 「一处过滤」的反噬:屏蔽库之后自己也解除不了(2026-08-02 当天返工)
`emby::views()` 也走 `fetch_items` —— 而名单里装的正是被屏蔽的**库 id**,于是库在
`views()` **内部**就被滤掉了,命令层的 `include_blocked` 是个摆设。用户屏蔽两个库后
首页没有它(对)、媒体库页也没有它(错),**没有任何地方能解除**。
修:`views()` 改走 `fetch_page`,滤不滤交给命令层。
★ 教训:把过滤塞进一个**共享的取数函数**,收益是"三端零改动",代价是
  **每一个碰巧路过的调用者都被顺带改了行为**。加这类横切逻辑时要把调用者列一遍
  (`grep fetch_items(`),逐个问"它该不该被滤"。`views` 就是那个不该的。
★ 护栏必须走**真 HTTP**:纯逻辑测不到"views 用了哪个取数函数",而那正是出问题的地方。
  `emby::tests::views_never_applies_the_blocklist` 起本地 TcpListener 扮演 /Users/{id}/Views。
★ 退路:**设置 → 已屏蔽的内容**(PC 侧栏 / 手机设置子页)一次看全 + 逐条解除。
  屏蔽的东西按设计会从首页消失,能解除它的地方只剩"原来那张卡片" —— 任何
  「隐藏/屏蔽/忽略」类功能都必须配一个集中列表,否则一定会有人问"那我怎么恢复"。

##### 三端入口
- PC:收进 `useCardActions` 的右键菜单(首页/媒体库/收藏/搜索四处网格自动都有);
  首页 `onBlockChanged` 直接整页重拉(六份 items 副本挨个过滤 = 把核层规则在前端再抄一遍)。
- 手机:`ui/mobile/components/BlockCard.tsx` 的 `useBlockCard`,长按卡片弹**居中**确认弹窗
  (长按误触率最高,而后果是"东西从首页消失了")。已接首页 + 媒体库。
- TV:`ui/tv/components/BlockDialog.tsx` + `FocusItem` 新增 `onLongEnter`。
  ★ 传了 `onLongEnter`,`onEnter` 就改成**松手才触发**(onEnterRelease),否则长按会先开
  详情页再弹屏蔽框。没传的 FocusItem 行为一字不变。norigin 的 `onEnterPress` 在按键
  自动重复时会一直发,靠"定时器已存在就不重起"去重。

护栏:`blocklist.rs` 五条单测(分集漏网那条**必须**把 series_name 传 None ——
第一版传了剧名,摘掉 series_id 判据照样绿,那条护栏一个字节都没在守);
右键菜单 + set_blocked 参数由 `ui/shared/player-chrome.check.mjs` 真渲染断言。

---

### 库内搜索

> 原记忆:`library-scoped-search.md` · 类型:`project`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。

2026-08-17。媒体库顶栏那个「库内搜索…」点开的是**全局搜索浮层**:
前端三个入口(首页 / 库列表 / 库内)共用同一个无参 `onSearch`,核层 `search` 也压根没有范围参数。
按钮名字在骗人 —— 在「电影」库里能搜出别的库的剧集。

**修法**:`emby::search_url` 加 `ParentId`(+ `Recursive=true` 保持);
`search` 命令/`api.ts` 加 `parentId`;`SearchOverlay` 加 `scope` prop
(有 scope 就**不出聚合开关** —— 聚合是跨服务器,和「只在本库」是反义词),
范围徽标 + placeholder 都要写清楚,否则搜不到时用户以为坏了;
`Shell` 持 `searchScope`,**关浮层必须清**(否则下次 Ctrl K 静默沿用上次的库)。
★ `onClick={onSearch}` 会把点击事件当 scope 灌进去,必须 `onClick={() => onSearch(view)}`。

**两台服务器结论相反,别互相签字**(2026-08-17 curl 实测):
- `<Emby 测试服 B>`(4.9.5 接近原版):ParentId 完全生效,12 个库搜同一关键词**两两零重叠**。
- `<用户主力 Emby 服(UHD fork)>`(fork):**带 SearchTerm 时把所有筛选参数一起忽略** ——
  ParentId / AncestorIds / **Ids** / NameStartsWith / NameContains / `/Search/Hints?ParentId=` 全无效,
  12 个库回同一堆。不带 SearchTerm 时 ParentId 是好的,所以不是权限/id 问题。
  和它「带 SearchTerm 时忽略 IncludeItemTypes」是同一个毛病。
  **那台上库内搜索做不到**:没有任何服务端参数能收窄,客户端只剩「全量拉库本地过滤」
  (正是这段代码当初废掉的写法)。不为一台 fork 把架构改回去。

**前端接线只有 CDP 真渲染能验**(单测/tsc 全绿):驱动真 exe 点进库 → 点「库内搜索…」→
原生 setter 改 input 再 dispatch `input` 事件 → 断言渲染条数 == 带 parentId 搜的条数 且 < 全局条数。
★ monkey-patch `window.__TAURI_INTERNALS__.invoke` **拦不到** —— 打包后的 @tauri-apps/api
在模块初始化时就把它取走了,别再按 invoke 参数断言,按渲染结果对账。

##### 「包括集」开关(2026-08-17 同批加)
搜索浮层顶栏第二个开关,**默认关** = 只搜 Movie/Series;开 = 加 Episode,
分集**单独一栏**用 `Poster variant="thumb"` 横版剧照画(和竖海报混一格必然高矮不齐)。
- 前端**必须显式传 types**:不传时核层默认 `Movie,Series,Episode` = 开关恒开。
- 聚合那条也要带上(`aggregateSearch(kw, withEp)`),否则开了它照样不出分集;
  **不传 = 关**,所以跨服 SourcePicker 那条老路一字未变(2026-07-16 口径没被推翻)。
- 这个开关**进 effect 依赖**(一拨就重搜),和聚合开关故意不同 —— 聚合一次打 N 台服务器
  所以不重搜,这个只多打一次当前服,不重搜才是坏的。
- `emby::search` 里加了 `filter_types`:显式点了名的类型自己再滤一遍。
  光靠 IncludeItemTypes 在那个 fork 上会让开关变成摆设。
  **只测 filter_types 本身是假绿**(删掉调用照样过),测试里必须一并钉调用点。

见 [正则筛选前端接线](ui-desktop.md) [UHD fork 无视收藏 SortBy](emby.md) 「emby-test-server-2-测试服 B」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)

---

### 未看集数角标

> 原记忆:`unwatched-episode-badge.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

剧集/季封面右上角小数字角标（2026-07-07）：原本显示**总集数**(`recursiveItemCount??childCount`)且看完不减。改为显示**未看集数**(像 Emby)。

- 数据：`UserData` 加 `unplayedItemCount`(api_interfaces.dart)，`emby_api.dart` `_parseMediaItem` 解析 `ud['UnplayedItemCount']`(Emby `/Users/{uid}/Items` 默认就返回 UserData，`isWatched` 本就依赖它)。
- 角标：`media_widgets.dart` `MediaCard` `episodeCount = item.userData?.unplayedItemCount ?? recursiveItemCount ?? childCount`；全看完=0→不显示数字(改由已看勾选标记体现，`_CountBadge` 条件 `>0`)。
- 移动端 `MediaCard` 角标在**右上角**；桌面 `desktop_media_card.dart` 后来补了**左下角**同款角标(2026-07-08)——把 `_CountBadge` 提为 public `CountBadge`(media_widgets.dart)复用,桌面 Stack 里 `Positioned(bottom: showProgress&&progress!=null?16:8, left:8)` 避开底部进度条。TV `tv_poster_card.dart` 仍没有。
- 看完自动减：仅移动端网格 `onStop` 后 invalidate 会重取;桌面 autoDispose provider 同理需回列表重取。
- 看完自动减：`libraryItemsProvider` 是 autoDispose 但网格页常驻→不会自动重取。移动端播放器 `player_screen_state.dart` `onStop`(上报+scrobble 之后)`ref.invalidate(libraryItemsProvider)`，返回网格即重取拿到 -1 后的计数。参见 [Library filter panel](emby.md)。

---

### Batch add & deeplink

> 原记忆:`batch-add-and-deeplink.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

一套「让用户/Emby服主一键把服务器加进来」的能力,核心是**通用解析引擎 + 多入口复用**。

**解析引擎(纯逻辑,可测,无 Riverpod):**
- `lib/core/utils/server_batch_parser.dart` — `ServerBatchParser.parse(text)` 把机场/Emby 分享文本结构化成 `List<ParsedServerBlock>`(每块:username/password + 服务器线路 + 弹幕线路)。多账号块按「创建用户/用户名」标记切分;弹幕线路靠 label/URL 含 danmu·danmaku·弹幕 识别。**坑:`用户密码` 同时含「用户」「密码」,必须先判密码键再判用户名键**,否则密码漏进 username。
- `lib/core/utils/server_batch_adder.dart` — `authenticateBlock()` 逐线路尝试登录(成功即返回带全部线路、activeLineIndex 的已鉴权 ServerConfig),自动取 Emby `serverName` 与图标 `{base}/web/touchicon.png`(取不到 UI 回退内置图标);`danmakuSourcesOf()` 把弹幕线路转成全局 `DanmakuSourceConfig`(authType=none,用户可改)。弹幕源是**全局**的不是 per-server(「plugin-system」(该条不在本库,多为 Flutter 时代的旧记忆,已作废) 无关)。

**入口(都复用上面两个):**
- 通用 UI `lib/ui/widgets/server/batch_parse_view.dart`(Material):粘贴→解析→「统一用户名一键套用所有块」→一键添加。接进移动添加页(批量解析 tab,替换了旧的单服务器多线路正则)和桌面添加页(AppBar「批量解析」action)。
- TV:侧边栏新增**「扫码」**项(`tv_sidebar`/`tv_shell`/`tv_router`,index 3,设置在 4),指向 LAN 遥控页(原 `/tv/lan-control` 复用为 `/tv/scan`)。手机扫码打开的 LAN 网页(`lib/tv/services/lan_remote.dart` 内嵌 HTML)「服务器」标签加了「批量解析添加」框 → POST `/api/server-add` → TV 端解析+登录+落库。
- **深链** `lib/core/services/deep_link_service.dart`:`linplayer://add-server?name=&user=&pwd=&line=&line=&danmaku=&text=`(多 line/danmaku;或整段 text)。`app_links` 包;main.dart runApp 后 `DeepLinkService(container).init()`。跳首页按平台:tvRouter / desktopRouterProvider('/') / appRouterProvider('/home')。原生清单:Android intent-filter(scheme=linplayer)、iOS+macOS `CFBundleURLTypes`、**Windows 用 `reg add` 写 HKCU\Software\Classes\linplayer 指向 exe**(url_protocol 依赖 win32 v2 与项目 v5 冲突,故自己注册)。
- `oauth-proxy/public/convert/index.html`:Emby 服主填线路+账号或粘整段文本→生成 `linplayer://add-server?...` 一键打开;支持 `?line=&user=...` 预填。

URL scheme/密码策略由用户拍板:**自定义协议**(非 https 中转)、**链接里带密码一键登录**。MediaStream 解析见 [Dolby auto decode](player-mpv.md) 同期。

---

## 跨域交叉引用

这些条目和本领域强相关,但正文放在别的文件里(一条经验只存一份正文):

- [网盘/strm 播放两大坑](player-mpv.md) — strm 条目的 PlaybackInfo 返回空 MediaStreams
- [跨服请求生命周期](network.md) — 跨服聚合/搜索的并发与取消口径
- [预取落盘环形缓存+302一次](network.md) — 只代理 Emby 直传流;多线程收益高度依赖服务端
- [卡片看完打勾/悬停/角标](ui-desktop.md) — UserData 字段在 PC 卡片上的呈现
- [Emby PlaySessionId 续播](emby.md) — 本页内:上报三件套必须带 PlaySessionId
