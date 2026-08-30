# 弹幕 / 弹弹Play / Bangumi / Trakt / 日历 / 排行榜

**这个领域最容易踩的坑:**
1. **弹弹Play 从不用 HTTP 状态码报错**,一律 200 + body 里的 `errorCode`;不看它就会把「配额 429」显示成「未找到弹幕」。
2. **发行包里的密钥是可提取的**(AES 口令是同一二进制里的硬编码常量),客户端限流拦不住外人;`AppSecret` 还可能是多串换行分隔,整坨拿去签名必 403。
3. **写接口路径要按官方 openapi 核**:Bangumi 单集写入的 subject 位必须是字面 `-`,写成 subject_id 永远 404。
4. **别让同步类调用返回裸 `bool`** —— 它会把 404 吞掉好几个月。
5. **付费墙是用户要的,别自作主张删**;「解锁后免登录能看」不等于「免费」。

> 本文件共 **9** 条。每条都标了它的原记忆文件名与类型;正文按原样搬运,未做压缩或改写。

## 本页条目

- 弹弹Play 三个静默失败 — `dandanplay-silent-failures.md`
- 弹弹配额被刷完 — `dandan-quota-drain.md`
- 弹弹多密钥轮换 — `dandan-multi-secret-rotation.md`
- 弹弹/Bangumi/日历(PC) — `danmaku-bangumi-calendar-poc.md`
- Bangumi 点格子恒 false — `bangumi-episode-grid-404.md`
- Trakt/Bangumi 深度同步 — `trakt-bangumi-deep-sync.md`
- 付费追剧日历(爱发电) — `paid-calendar-afdian.md`
- Ranking architecture — `ranking-architecture.md`

---

### 弹弹Play 三个静默失败

> 原记忆:`dandanplay-silent-failures.md` · 类型:`project`

2026-08-01。用户报「弹弹play 搜索不到弹幕、自动匹配不到，需要匹配算法」。
挂真接口(官方 AppId + 真签名,凭据在 `hjbl.env`,已 gitignore)一发就现形 —— **三条全是我们自己的静默失败**：

1. **弹弹Play 系接口从不用 HTTP 状态码报错**，一律 `200` + body 里的 `errorCode`。
   不看它 → `animes` 键不存在 → 解析成空表 → 界面说「未找到匹配的弹幕」。
   实测当天两个 search 端点**全部**回 `{"errorCode":429,"errorMessage":"已达到接口调用配额上限"}`。
   → 界面给的失败原因是假的。这类「界面在撒谎」见 [界面在撒谎:当前版本](ui-desktop.md)、[「待接」多半是谎](methodology.md)。

2. **`/match` 要求 `fileHash` 是形状合法的 32 位 hex**，空串直接 `errorCode:2 参数不符合规则`。
   A/B 实测(同文件名同签名)：空 hash **0 条** / 任意 32 位 hex **25 条且第一条就对**。
   `matchMode` 给不给、给哪个值结果**一模一样** —— 决定成败的只有 hash 的形状。
   → 这条「文件识别」路从接进来那天起没通过过一次。修法=文件名派生的确定性占位 hash。
   **另一个关键实测：`/match` 和 search 的配额是分开的**，search 429 时 /match 照常工作。

3. **前端把 `file_name` 传成 `it.name`**，对剧集就是「第 35 集」。
   而 `/match` 正是**按文件名做跨语种解析**的那条路(实测英文名 `Frieren...S01E03`、
   日文名 `葬送のフリーレン 第3話` 都能正确对到中文条目)。
   喂它条目名整条路白跑 —— 实测「第 35 集」返回的第一名是《NHK特集手塚治虫》。
   真文件名来源：Emby 的 `MediaSource.Name`(不含扩展名的真文件名)/ 网盘下载的 `path` basename。

**匹配算法本体**照 `D:\xiaochengxu\bangumi2anibt` 的 `matcher.c` 重写(归一化折叠 + Levenshtein
比率 + 长度加权包含下限)。旧的字符二元组 Jaccard×0.6 **天花板就是 0.6 而自动挂载门槛是 0.5**：
「葬送的芙莉莲」vs「葬送之芙莉莲」一字之差实测只给 **0.257**。另外它不做任何字形折叠
(全角/大小写/片假名平假名/标点全当不同字符)。
新增两路独立信号：**季号**(剥掉季号后同名条目相似度完全一样，分不开 → 第二季配第一季弹幕)、
**alt_titles**(弹弹Play 条目只有一个标题没有别名表，平行语料只能由我们这边给)。

**查法**：`node` 直接打 `api.dandanplay.net`，签名 `base64(sha256(AppId+ts+path+Secret))`。
别信 HTTP 200 —— 永远先打印 `errorCode`/`errorMessage`。

---

### 弹弹配额被刷完

> 原记忆:`dandan-quota-drain.md` · 类型:`project`

2026-08-02 用户:「我的默认弹幕源弹弹API 有人在刷我的配额,经常用完」。

##### ★ 结论先行:密钥在发行包里是**可提取**的
`crates/core/build.rs` 把 `DANDANPLAY_APP_SECRET` 用 AES-256-CBC 加密后编译进产物,
而**解密口令是同一个二进制里的硬编码常量**(`OBF_KEY`,secrets.rs 和 build.rs 各一份,
必须逐字节一致)。build.rs 自己的注释就写着「混淆级(抬高门槛),非绝对安全」。
AppId 更是明文(它本来就随 `X-AppId` 头发出去)。签名 `base64(sha256(AppId+ts+path+Secret))`
**全在客户端本地算**,没有任何服务端代理(oauth-proxy 只管 Trakt/Bangumi)。

→ 任何人拿到我们的 exe/APK 都能把密钥完整取出来直接用我们的配额。
→ **客户端限流只管得住我们自己的用户,拦不住外人。** 别把限流当成堵漏。
→ 真要堵只有把签名挪到服务端(客户端调我们的接口,secret 只在服务器上)。

##### 我们自己烧掉的三份(都已修,82043159)
1. **`is_anime` 写了却从没有人调过** —— 宿主三处 `danmaku_sources(state, true)` 全写死。
   播欧美剧/综艺/纪录片照样打一整轮(`/match` + 最多 4 次 `/search/episodes`),
   而弹弹Play 根本不收录这些,一条候选都不可能有。
   ★ 判据必须是「**确信不是番**才排除」:`genres` 为空 = 没刮到元数据 = 不知道 → 放行。
   反过来写(空表就排除)会让所有没刮削的库弹幕**静默死掉**,比烧配额严重得多。
2. **桌面端 autoLoad 返回 null 后又原样调一次 danmakuMatch** —— 同入参同判据,
   而 `danmaku_auto_load` 内部刚跑完 `match_all` 并且已用 `MIN_AUTO_SCORE` 筛过,
   那一轮的 `top.score >= 门槛` 恒为 false。每次没匹配上的起播 = 双倍配额、零收益。
3. **主动搜索零频率限制**。现加 5 秒最小间隔,★ 只在会打到官方源时才拦
   (自建源是用户自己的服务器,给它限速纯属添堵);手动「重新匹配」共用同一闸门。
   选**拒绝**不选排队:连按五下会排出 25 秒的队,比报错难受。

##### 顺带抓到的第四个:半失败被吞成「没搜到」
`/search` 和 `/match` 的配额是**分开的**,一路 429、另一路正常回空是**实测常态**
(真机同一入参连打四次,第四次静默变 null)。`match_one` 旧判据是「两路都失败才报错」,
于是这种半失败一路传到界面 → 「未找到匹配的弹幕」。
那正是 2026-08-01 修过的那句谎话,**从另一条岔路长回来了**。
改成「零候选 **且** 任一路失败」就报。参见 [弹弹Play 三个静默失败](danmaku-sync.md)。

##### 护栏怎么钉的
- 「函数写了没人调」纯逻辑单测**照不到**(`is_anime` 自己的单测一直是绿的,
  它就是这么活下来的)。所以**两个宿主各钉一条源码级断言**:
  `danmaku_auto_load` 必须出现 `allow_official_for(&input.genres)`。
  两端各一份,合并成一条的话删掉其中一端不会红。同 [「待接」多半是谎](methodology.md)。
- 半失败那条走**真 HTTP**(本地 TcpListener 扮演 `/search` 回 429、`/match` 回空):
  要真有一路 Err 一路 Ok 才复现得出来。
- `ui/shared/danmaku-quota.check.mjs` 挂真实 exe 走 CDP。
  ★ 判据用**耗时**不用「有没有拿到弹幕」—— 上游不稳,拿它当判据会随机红,
  而随机红的门禁等于没有门禁([测试必须先红](methodology.md))。
  被门控挡掉时核层一个字节都不发(实测 33ms),真出网最快也 200~470ms,差一个数量级。
  这个脚本自己会打真接口,**别放进 CI 循环跑**,那是自己刷自己的配额。

相关:[弹弹多密钥轮换](danmaku-sync.md)(同一套凭据的另一个坑)、[CI 漏传编译期凭据](build-release.md)。

---

### 弹弹多密钥轮换

> 原记忆:`dandan-multi-secret-rotation.md` · 类型:`project`

**弹弹Play 允许一个 AppId 配多个 AppSecret 做配额轮换,换行分隔。**
GitHub Secret `DANDANPLAY_APP_SECRET` 里放的就是两串。
签名只能用**其中一串**,`sha256(appid+ts+path+"S1\nS2")` 必然签出一个谁也认不出的签名 → **HTTP 403**。

2026-07-21 事故:两条路径处理不一致 ——
- 弹幕 `danmaku::auth_parts`:有 `.split('\n').find(非空)` → 正常
- 排行榜 `ranking::fetch_dandan` → `dandan_creds()` → **整坨直接签** → 403 → 整页空白

**表现极具误导性**:"同一个 AppId、同一个密钥、都在 Repository secrets 里,
弹幕好好的,唯独排行榜不行" —— 看起来像弹弹平台不给排行榜权限、或者密钥填错了。
我一度签字说"GH secret 是错的",被用户的反例(弹幕能用)当场推翻。**用户是对的。**

**已修**:拆分下沉到 `secrets::dandan_app_secret()`(调用方只该关心"给我一个能用的密钥");
danmaku 那边的 split 保留,对单串是恒等变换。测试
`multi_secret_rotation_takes_only_the_first` 覆盖 CRLF / 前导空行 / 单串恒等,
反向注入验证过。CI 用真 GH secret 实测:修前 `HTTP 403`,修后 `返回 50 条`。

**定位手法(可复用,且不接触凭据内容)**:
AES-CBC 的**密文长度暴露明文长度**(补齐到 16 的倍数)。
比对两个构建里嵌入的 base64 密文串**长度**即可反推明文有多长 ——
本地 64 字符密文(=32 字符明文,一串)vs CI 产物约 108 字符(≈65 字符明文,两串+换行)。
全程只打印长度,不解密、不打印内容(直接扫描解密所有 base64 blob 会被安全策略拦,也确实不该做)。
定位密文位置的锚点:`OBF_KEY` 字面量,密文串就紧挨在它前面。

配套:[Ranking architecture](danmaku-sync.md)、[CI 漏传编译期凭据](build-release.md)、[测试必须先红](methodology.md)。

---

### 弹弹/Bangumi/日历(PC)

> 原记忆:`danmaku-bangumi-calendar-poc.md` · 类型:`project`

native-poc(PC React+Tauri)三件相关同步/弹幕事(2026-07-16 落):

##### 弹弹Play 默认源 = **编译期凭据门控,不是缺代码**
签名鉴权(X-AppId/X-Timestamp/X-Signature = base64(sha256(AppId+ts+path+Secret)))**全链已实现**
(`crates/core/src/danmaku/mod.rs` 的 `auth_parts`/`signature`,base=`api.dandanplay.net`),官方源由
`src-tauri/src/lib.rs::official_danmaku_cfg()` 在每次请求时**自动注入**(不落 config)。
唯一开关:`crates/core/build.rs` 读环境变量 **`DANDANPLAY_APP_ID`(明文)+ `DANDANPLAY_APP_SECRET`(编译期 AES 加密)**。
两者非空才注入,缺则 `dandan_creds()→None`→官方源不出现→「未配置弹幕服务器」。
→ **本地 `npx tauri build` 不带这俩环境变量 = 用户测的包里默认源不工作**。要么 CI 注入 secret,
要么本机 build 前 `export DANDANPLAY_APP_ID=.. DANDANPLAY_APP_SECRET=..`(是注册开发者才有的凭据,Claude 无法伪造)。

##### Bangumi:官方 API + anibt 图片(用户实测 anibt 的 API 反代过不了 CF、官方 API 没问题)
`crates/core/src/sync/bangumi.rs`:`API_BASE` 改回 `BANGUMI_API_OFFICIAL`(api.bgm.tv);
`build_authorize_url` 独立指 `BANGUMI_OAUTH_OFFICIAL`(bgm.tv,授权在主站不在 api 子域);
图片单独 `mirror_image()` 把 `lain.bgm.tv`→ **`bgmimg.anibt.net`**(新常量 `BANGUMI_IMG_MIRROR`,官方图国内不通)。
anibt 图片反代通、API 反代不通;所以是「API 官方 + 图片 anibt」这个反直觉组合。需真机验证 CF。

##### 追剧日历:提到侧栏 + 通用放送表免登录免付费
- 侧栏项(`nav.ts` NAV 加 `calendar`+`IconCalendar`);从 设置 移除(SettingsPage 删 CalendarPane/nav 项/onOpenCalendar,Shell `<CalendarPage/>` 无 props)。
- 默认 `source="bangumi"` + `onlyMine=false`。后端 `bangumi_calendar` 命令:无账号且 `!only_mine` 时用**匿名账号**拉公开 `/calendar`;`fetch_anime_calendar` 把 `ensure_valid` 收进 `only_mine` 分支(公开放送表不需 token)。
- **付费墙保留**(Afdian 软锁 gate 仍在)——用户 2026-07-16 明确「肯定还要付费才能用」。我一度误删了 gate,被当场骂回:「放出来又免费吗?逗我呢」。用户要的是「**解锁后**免登录也能看放送表」,不是免费。别再删 gate。真正的修 = 上面那三个默认值改对(默认 bangumi+不看我追的+后端公开 /calendar),让解锁后不登 Bangumi 也直接出整张放送表。见 [付费追剧日历(爱发电)](danmaku-sync.md)、[别过度解读需求](methodology.md)。

##### 放送时刻:Bangumi 官方 API 根本没有(2026-07-16 实测,别再去翻了)
curl 实证:`/calendar` 条目只有 `air_date`(**日期无时刻**)+`air_weekday`;subject 详情的完整
infobox 也只有「放送开始/放送星期/播放电视台」,**任何端点都没有 hh:mm**。用 air_date 硬凑 = 显示 00:00 假时间。
→ 用户选了接 **bangumi-data**(`unpkg.com/bangumi-data@0.3/dist/data.json`,7.4MB):
它的 `broadcast` 是 RFC5545 `R/<ISO UTC 起始>/P7D`,且条目自带 `sites[].site=="bangumi"` 的 subject id
→ **能精确对上,不靠标题模糊匹配**。实测本周覆盖 **72/111≈64%**,没覆盖的**不显示时刻不编**。
实现:`bangumi.rs` 拉大文件→只留 `id→broadcast起始` 小索引(~1800条)写盘缓存(TTL 7d,路径
`<config>/LinPlayer/bangumi_broadcast.json`)+ 进程内 OnceCell;新字段 `CalendarEntry.broadcast_at`
(ISO UTC),前端换算**本地**时分显示成封面左上角角标。有测试钉 `broadcast_start`/`mirror_image`。
★ `air_date` 对 Bangumi 必须保持 None:它是**首播日**不是本周这集的日期,传上去前端拿它跟本周比对会整条丢掉→放送表全空。

##### Trakt 放送表:图靠 TMDB,时间它自己有
`trakt.rs` 原来写死 `image_url: None` —— **Trakt 自己不发图**,只给 `ids.tmdb`。已加 `tmdb_poster()`
(按 tmdb_id 去重后并发查 `/3/tv/{id}` 的 poster_path)。**依赖编译期 `TMDB_API_KEY`**(与排行榜同源),
没 key 就没图(和弹弹凭据同一类 build-cred 门控)。Trakt 的 `first_aired` 本身是精确时刻,时间不缺。

相关:「danmaku-architecture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)、[Trakt/Bangumi 深度同步](danmaku-sync.md)、[「待接」多半是谎](methodology.md)、[Ranking architecture](danmaku-sync.md)

---

### Bangumi 点格子恒 false

> 原记忆:`bangumi-episode-grid-404.md` · 类型:`project`

2026-08-01。用户报「Bangumi 只有『在看』能成,点格子(标单集看过)恒 false」。三个真因,全在我们这边:

1. **路径根本不存在**。旧代码打 `PUT /v0/users/-/collections/{subject_id}/episodes/{episode_id}` —— 官方 openapi 实证:
   单集写入是 `PUT /v0/users/-/collections/-/episodes/{episode_id}`(subject 位是**字面 `-`**),
   带 subject_id 的只有批量 `PATCH .../{subject_id}/episodes`(body `{episode_id:[...], type}`)。
   永远 404。「在看」用的 `POST /v0/users/-/collections/{subject_id}` 恰好是对的,所以只有它能成。
   已改走批量 PATCH(两个参数都用得上,且官方注明它**重算条目完成度**,单集 PUT 没这句)。
   EpisodeCollectionType:0未收藏 1想看 2看过 3抛弃(和 SubjectCollectionType 不是一套,后者 3=在看)。

2. **`-> bool` 把原因吞了**。404 活了几个月没人看见,因为 `.map(|r| r.status().is_success()).unwrap_or(false)`。
   已改 `Result<(), String>`,失败带状态码 + 响应体前 200 字。**别再让同步类调用返回裸 bool。**

3. **匹配器从不比标题**。`bangumi_matcher::search_subject` 旧规则:日期对得上取最近的,**对不上无条件 `results[0]`**。
   已改成复用弹幕那套评分(`danmaku::title_score`/`season_term`/`core_name`,已是 `pub(crate)`) ——
   `MatchInput` 本来就是 pub 的,装上 title + 原名 + core_name 当平行语料即可,不要造第二套。
   低于 `MIN_TITLE_SCORE=0.45` 判「没匹配上」:**标错条目比不标更坏**(往用户账号里写别人的番)。
   门槛先筛再按总分排,反过来会让日期碰巧对上的噪声挤掉真本体然后整条判失败。

另:手动「标为看完」(`set_played` 命令)以前**只写 Emby**,只有播到 80% 走 stop_playback 才同步 Bangumi。
已在两端 `set_played` 里接上(played=true 时后台 spawn 反查+标记,别让 UI 的勾等三次 API)。

安卓侧交叉编译验证:`LP_ANDROID_PKG=linplayer-android bash scripts/build-android.sh arm64-v8a`
(裸 `cargo check --target aarch64-linux-android` 会死在 **host** rquickjs-sys 的 bindgen 缺 WinSDK 头,
那个脚本从 vcvars64 灌 INCLUDE 才过,见 [安卓能本地构建](android.md))。

相关:[弹弹Play 三个静默失败](danmaku-sync.md) [Trakt/Bangumi 深度同步](danmaku-sync.md) [「待接」多半是谎](methodology.md) [测试必须先红](methodology.md)

---

### Trakt/Bangumi 深度同步

> 原记忆:`trakt-bangumi-deep-sync.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

三端 Trakt/Bangumi 同步的深度适配分三层，2026-07-10 定的范围。

**第1层（已实现）**——真进度同步 + 两家招牌能力，几乎不动 UI：
- Trakt 改用 **Scrobble API**（`/scrobble/start|pause|stop`，见 `trakt_sync_service.dart` `scrobble()`）：起播发 start（账号显示「正在观看」），停止发 stop 带真实 progress%，Trakt 自动在 ≥80% 判定看过、<80% 存续播点。取代了旧的 `/sync/history` 完播打卡。**未接 pause**（无 onPause 钩子；start+stop 已够，退出即 stop 自纠正）。
- Bangumi：`scrobbleStop` 里达阈值时先 `setCollectionType(subject, 3)` 设**在看**再更新单集——顺带修了旧 bug（未收藏的番直接更单集会失败）。单集顺序标记天然累积出正确进度。**每次写在看**，重看已「看过」的番会被降回在看（罕见，可接受）。
- 接入点：`onStart`→`scrobbleStart`；`onStop`→`scrobbleStop`。桌面/移动 `player_screen_state.dart`(`_scrobbleOnStop`)、TV `tv_player_screen.dart`(`_maybeScrobble`)。核心逻辑集中在 `sync_scrobble_service.dart`。
- 无需改 oauth-proxy：scrobble/收藏都用用户 bearer token 直连，代理只管带 client_secret 的登录/刷新。

**Bangumi 登录深链回填（已实现）**：`bangumi.html` 授权后自动唤起 `linplayer://sync-bangumi?code=...`（`deep_link_service.dart` `_handleBangumiSync`，弹确认防 drive-by 绑号后复用 `connectBangumiWithCode`），省掉「复制授权码→回 App 粘贴」。复制粘贴保留为兜底。用同一 `linplayer` scheme(跟 add-server)，三端 manifest 已注册、平台配置不用改；proxy functions 不涉及。Trakt 是设备码不受影响。

**第2层（推迟）**：播完评分弹窗(Trakt/Bangumi 1-10)、设置页同步开关、详情页反向显示状态(Trakt 已看/评分、Bangumi 在看 X/Y)。要三端各加 UI。

**第3层（推迟，YAGNI）**：想看单/收藏管理、吐槽、标签、批量集数进度(`PATCH episodes`，仅跳集观看才需要)、看到最后一集自动设「看过」(需拿总集数)。

相关：[网盘/strm 播放两大坑](player-mpv.md) 「cross-server-resume」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)

---

### 付费追剧日历(爱发电)

> 原记忆:`paid-calendar-afdian.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

第一个付费功能：追剧日历，用爱发电(Afdian)订单号校验解锁。

**架构（软锁，honor system；开源客户端里「已解锁」判断可被改，故意不加固）：**
- 后端：`oauth-proxy/functions/api/afdian/verify.js` —— POST `{out_trade_no}` → afdian `query-order`(md5 签名，复用 sponsors.svg.js 同一套 `AFDIAN_USER_ID`/`AFDIAN_TOKEN` 环境变量) → `{valid, planTitle, amount}`。受 `_middleware.js` 的 `X-LinPlayer-Key` 保护。
- 客户端校验：`lib/core/services/afdian_service.dart`(`AfdianService.verifyOrder` POST `$kSyncProxyBaseUrl/afdian/verify`) + `lib/core/providers/afdian_providers.dart`(`afdianOrderProvider` 存已校验订单号到 SharedPreferences 明文；`premiumUnlockedProvider` = 订单号非空)。
- 日历数据：Trakt `/calendars/{my|all}/shows`(精确日期,all 截断200) / Bangumi 在看∩ 或 整张 `/calendar`(只有星期,仅当季在放送)。右上角切换「只看我追的/整季全部」；`calendarEntriesProvider` 家族键 `(source, onlyMine)`。
- Trakt 无图 → 用条目 `show.ids.tmdb` 从 TMDB 补封面：`lib/core/services/tmdb_image_service.dart`(复用影视榜 `TMDB_API_KEY_ENC` AES 密钥+`buildSourceDio`,内存缓存去重限并发)，在 `SyncController._enrichTraktPosters` 接线。方法加在 `trakt_sync_service.dart`/`bangumi_sync_service.dart`，经 `SyncController.fetchCalendar` + `calendar_providers.dart`(源选择+FutureProvider.family)暴露。归组纯逻辑 `groupCalendarEntries` 在 `calendar_models.dart`(三端共用，有 test)。
- UI：移动/桌面共用 `lib/ui/screens/calendar/calendar_screen.dart`(+`AfdianUnlockDialog`)，入口在设置首页「追剧日历」卡片；TV `lib/tv/screens/calendar/tv_calendar_screen.dart`(+`TvAfdianUnlockPanel`)，路由 `/tv/calendar`，入口在 TV 同步设置页。

**部署前 dev 待办：**① `afdian_service.dart` 的 `kAfdianSponsorUrl` 换成自己的爱发电主页；② 确认 CF Pages 已配 `AFDIAN_USER_ID`/`AFDIAN_TOKEN`(sponsors.svg 已用则已配)；③ 部署 oauth-proxy。

**已知边界(都留了升级路径注释)：** 解锁标记 per-device(换设备要重新填订单号)；订单号可转发(未做设备绑定)；Bangumi 已完结的在看番不进日历。相关：[Trakt/Bangumi 深度同步](danmaku-sync.md) 「cf-proxy-architecture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)

---

### Ranking architecture

> 原记忆:`ranking-architecture.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

⚠️ 2026-07-21 按 Rust 栈重写。老版本描述的 `lib/core/api/ranking/` + `rankingEnabledProvider`
是 Flutter 时代的,**全部作废**(路径换算见 [仓库结构(2026-07重构后)](build-release.md))。

现在:`crates/core/src/ranking.rs` 一个文件,两端命令 `ranking_categories` / `ranking_fetch`,
UI 在 `ui/desktop/pages/RankingsPage.tsx` 和 `ui/tv/pages/DiscoverPage.tsx`(rank 页签)。

**没有开关。** Rust 栈里不存在 `rankingEnabledProvider` 之类的设置项 ——
分类为空的**唯一**原因是打包时没注入凭据。TV 端曾留着一句
「排行榜默认是关的,去设置里打开」,用户照着找只会在设置页里翻空,已改掉。
写这类提示前先 grep 确认那个设置真的存在([「待接」多半是谎](methodology.md) 的同款陷阱)。

**数据源**
- 动漫 = 弹弹Play `/api/v2/trending/all/{hot,rising}/{week,month,quarter}` 与
  `/api/v2/trending/new-anime/hot/{current-season,previous-season}`。
  **需签名**,复用 `danmaku::signature`(签名路径 = 请求路径,含 `/api/v2` 前缀,不含 query)。
  端点/字段名(`bangumiList`/`animeId`/`animeTitle`/`imageUrl`)与官方
  swagger(`api.dandanplay.net/swagger/v2/swagger.json`)逐个核对过,是对的。
  匿名请求一律 403 `X-Error-Message: Missing Authentication Headers`。
- 影视 = TMDB,自动识别 v4 Bearer(含点)/v3 api_key。

**凭据链路**:GH secret 明文 → job env → `crates/core/build.rs` 编译期 AES-256-CBC 加密
→ `option_env!("DANDAN_APP_SECRET_ENC")` → `secrets.rs::decrypt`。AppId 走明文。
**三个构建 job 都要传**,漏了就静默残废 —— 已设闸门,见 [CI 漏传编译期凭据](build-release.md)。

**fetch 返回 `Result<_, String>`**,不再吞成空数组;失败信息带 errorCode/errorMessage/
HTTP 状态/缺哪个环境变量。前端 catch 分支直接显示。
另有 `dandan_trending_smoke`(默认 `#[ignore]`)+ build-linux 的诊断步骤
(`continue-on-error`,不是闸门)拿真凭据打一次,把服务端原话打进 CI 日志。

**弹弹排行榜 403 已定性并修复(2026-07-21)**:根因是 GH Secret 里放的是**两串换行分隔的
轮换密钥**,而排行榜把整坨拿去签名(弹幕那边有拆分所以一直正常)。
**是我们自己的 bug,不是密钥错、也不是平台不给权限** —— 详见 [弹弹多密钥轮换](danmaku-sync.md)。
CI 用真 GH secret 实测:修前 `HTTP 403`,修后 `返回 50 条`。

排查中被**排除**的假设(都验过,别再走回头路):凭据没注入(13 个分类全亮)、
签名算法错(弹幕同一个 `signature()` 能过)、UA(补了 `api_user_agent` 后 CI 仍 403)、
CI 机房 IP(build592 在本机也空)、GH Secret 填错/需手动加密
(`build.rs` 编译期加密,GH 里就该填**明文**;实测本地包里搜不到明文只搜得到密文)。

顺带修掉的另一件事(与本问题无关):`http::client()` 一个 UA 都不发 → 见 [不发 UA 就吃 403](network.md)。

关联 「danmaku-architecture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)、[Git workflow](methodology.md)。

---

## 跨域交叉引用

这些条目和本领域强相关,但正文放在别的文件里(一条经验只存一份正文):

- [CI 漏传编译期凭据](build-release.md) — 弹幕/排行榜的凭据是编译期注入的,漏传就静默残废
- [本周看板定案+PC视觉自检](methodology.md) — 追剧日历本周看板的版式定案与视觉自检法
- [mpv 字幕属性实测](player-mpv.md) — 弹幕曾占用次字幕位,受 secondary-* 属性限制
