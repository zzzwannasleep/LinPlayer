# Emby 协议与适配知识

> 来源:`crates/core/src/emby.rs`(2923 行)、`media.rs`、`blocklist.rs`、`watch_history*.rs`、
> `server_batch.rs`、`apps/desktop/src/lib.rs`、`apps/desktop/src/imgcache.rs`、`crates/core/src/http.rs`。
> 每条结论后面的 `文件:行号` 就是出处。读不出来的写「未确认」并说明查过哪里。
> 本文不含任何真实域名/IP/账号/token —— 涉及具体服务器的地方一律写成 `服务器A/B/C`(见 §6 开头对照)。

## 0. 一句话

Emby 的**协议本身**很简单(REST + `X-Emby-Token`),难的是**没有一台服务器完整实现它** ——
这份代码里超过一半的分支不是在实现协议,是在绕某台 fork 的怪癖;而这些怪癖的共同表现是
**不报错、只是悄悄少做了**,所以 Go 版必须把每一条绕法逐字节搬过去,而不是「按文档重写一遍」。

---

## 1. 认证与会话

### 1.1 两个鉴权头,用途不同

```
X-Emby-Authorization: MediaBrowser Client="LinPlayer", Device="<主机名>", DeviceId="<持久化ID>", Version="<APP版本>"
X-Emby-Token: <AccessToken>
```

- 头的拼法:`emby.rs:5-11`。`CLIENT_NAME = "LinPlayer"`、`APP_VERSION = env!("CARGO_PKG_VERSION")`,均在 `http.rs:4-5`。
- `Device` 取本机主机名:`COMPUTERNAME` → `HOSTNAME` → 字面量 `"PC"`(`http.rs:39-43`)。
- **`X-Emby-Authorization` 不是每个请求都发。** 实际只有 7 处发它:
  `media_versions`(`emby.rs:431-432`)、`login`(`emby.rs:485`)、`logout`(`emby.rs:1499-1500`)、
  `ext_domains`(`emby.rs:1566-1567`)、`server_info` 探测(`emby.rs:1610`)、
  `chapters`(`emby.rs:1837-1838`)、`resolve_stream`(`emby.rs:2120-2121`)、上报三件套(`emby.rs:2260-2261`)。
  其余全部只发 `X-Emby-Token`(如 `emby.rs:549`、`710`、`792`、`924`、`951`、`999`、`1044`、`1182`、`1375`、`1434`、`1484`、`1668`、`1716`)。
  **Go 侧不要「统一都发」也不要「统一都不发」——原样照搬这张表**,这是与真实服务器对账过的现状。
- 第三条路:URL 里的 `?api_key=<token>`。凡是地址要交给**不是我们自己的 HTTP 客户端**的场合
  (mpv 取流、`<img src>`、外挂字幕),只能用 query 参数带 token:
  `abs_url` 统一补(`emby.rs:1952-1966`,已含 `api_key=` 就不重复补)、
  章节图(`emby.rs:1861`)、外挂字幕兜底路径(`emby.rs:1774-1776`)、直拼兜底流地址(`emby.rs:2231`)。

### 1.2 登录

- `POST {server}/Users/AuthenticateByName`,body `{"Username":..., "Pw":...}`(`emby.rs:481-483`)。
  **只带 `X-Emby-Authorization`,不带 token**(这会儿还没有)——`emby.rs:485`。
- server 归一化:`trim()` + 去掉所有尾部 `/`(`emby.rs:469-471`)。Session 里存的永远是归一化后的值(`emby.rs:13-19`)。
- 响应取四个字段:`AccessToken` / `User.Id` / `User.Name` / `User.PrimaryImageTag`(`emby.rs:30-46`)。
  `PrimaryImageTag` 必须解:很多 Emby 服把品牌 logo 设成用户头像,不解这个字段服务器图标只能退
  `/web/touchicon.png` —— 能用,但**悄悄降级**(`emby.rs:41-44`)。

### 1.3 device_id

- 首次运行生成 `linplayer-{纳秒时间戳:十六进制}`,之后持久化不变(`config.rs:524-532`);
  `AppConfig::load()` 保证非空,新生成立即落盘(`config.rs:535-545`)。
- 三个用途:① `X-Emby-Authorization` 的 `DeviceId`;
  ② `PlaySessionId` 的兜底前缀 `{device_id}-{item_id}`(`emby.rs:2135-2138`);
  ③ 观看记录回传用的 `{device_id}-wh-{item_id}`(`watch_history_sync.rs:204`)。
- Go 侧注意:device_id 变了 = Emby 会把你当成一台新设备,会话表里会多一行。别在迁移时重新生成。

### 1.4 token 生命周期

- **没有自动刷新,没有 401 拦截器。** 全文件搜 `401` 在 `emby.rs` 里只有一处,
  且是 `ext_domains` 的线路服务(`emby.rs:1577-1579`),不是 Emby 本体。
- 探测账号是否还活着走 `GET {base}/System/Info?api_key={token}`,三态映射:
  2xx → Ok,401/403 → Reauth(需重登),其它/网络错 → Down(`lib.rs:1069-1076`)。
  **不能用 `/System/Info/Public`**:它不校验 token,token 失效也回 200,黄灯永远探不出来(`lib.rs:1067-1068`)。
- 探测必须走 `active_line_url()` 而不是账号主键:用户切备用线路正是因为主线不通,
  拿主线探会把好服务器判成灰(`lib.rs:1053-1056`)。
- 登出是**尽力而为**:某台 fork 上 `POST /Sessions/Logout` 返 404 且 token 登出后仍可用,
  所以它的失败不能挡住本地删账号,调用方忽略返回值(`emby.rs:1493-1496`;调用点 `lib.rs:1580`)。

### 1.5 重新登录为什么不能复用 login

`lib.rs:394-407` 把原因写死了:

- `login` 是按**登录时用的那个地址**(`result.server`)做 `upsert` 的(`lib.rs:352-386`)。
- 而「重新登录」认证走的是 `direct_line_url()`(可能是某条 CDN 线路),它 **≠ 账号主键 `a.server`**。
- 拿 `login` 顶替 → upsert 命中不到原账号 → **凭空多出一台服务器**,原账号还在,
  用户以为重登好了,其实是加了一台。
- 正确做法:`find_mut` 定点只改 `token / user_id / user_name / password` 四个字段,
  **不动 server/name/remark/icon/lines/active_line**(那些是用户的编辑)——`lib.rs:427-434`。
- 改了账号名 = 换了个人,`token`/`user_id` 全得换,必须真登一次;只改 `user_name` 会造成
  「显示是新账号、看到的还是旧账号的媒体库」的静默错位(`lib.rs:402-406`)。
- 重登后若该账号是当前活跃账号,**内存里的 Session 也要换**,否则后续请求还在拿旧 token 打 401(`lib.rs:435-446`)。

### 1.6 Session.server 必须是「当前生效线路」

- `current_session` 返回的 `server` 用的是 `a.active_line_url()` 而非账号主键 `a.server`,
  因为前端拿它直接拼封面/背景图地址;用主键会导致「切到备用线路后 API 走新线、封面还打老线」,
  表现是**封面全白但不报错**(`lib.rs:453-464`)。
- 聚合搜索同理:每台服务器的 Session 也用 `active_line_url()`,否则连不上的那台会
  `unwrap_or_default()` 成空结果从搜索里静默消失(`lib.rs:509-517`)。
- `active_line_url()` 是 CF 优选反代的**唯一 choke point**,开着优选时它返回 `http://127.0.0.1:<port>/...`
  (`config.rs:70-82`)。需要原始上游地址时用 `direct_line_url()`(`config.rs:58-67`)。
- `current_session` 会滤掉浏览型源账号(它没有 Emby token,吐个空 token 的会话会让前端打 401)——
  前端判断"要不要进登录页"应看 `list_accounts` 是否为空(`lib.rs:448-451`)。

### 1.7 HTTP 客户端本身的口径

- 访问 Emby 的客户端 UA = `LinPlayer/{版本}`,开 gzip+brotli(`http.rs:233-235`、`265`)。
- 预取代理 UA = `LinPlayerPreload/{版本}`,**显式关压缩**:它拉的是视频字节流,
  透明解压会把 `Content-Length` 变成解压后长度甚至抹掉,分段会错位(`http.rs:239-250`)。
- reqwest `default-features = false` 时**一个 `Accept-Encoding` 字节都不发**,Emby 只能原样吐明文;
  必须同时勾 crate feature 和 builder 开关,少一个「代码照编、测试照过、请求里一个字节都没有」(`http.rs:244-246`、`502-508`)。

---

## 2. Items 查询参数矩阵

### 2.1 端点全表(`emby.rs` 里出现过的每一条)

| 端点 | 方法 | 出处 | 备注 |
|---|---|---|---|
| `/Users/AuthenticateByName` | POST | `emby.rs:481` | 登录 |
| `/Users/{uid}/Views` | GET | `emby.rs:520` | 媒体库列表。**绝不能过屏蔽名单**,见 §7 |
| `/Items/Counts?UserId={uid}` | GET | `emby.rs:546` | 一次拿全库规模,`UserId` 必带 |
| `/Users/{uid}/Items` | GET | `emby.rs:644` 等 | 主力列表端点 |
| `/Users/{uid}/Items/Latest` | GET | `emby.rs:705` | **返回裸数组**,不是 `{Items}` 包裹 |
| `/Users/{uid}/Items/{id}` | GET | `emby.rs:787`/`1179`/`1370`/`1429`/`1832` | 单条,Fields 各不相同 |
| `/Users/{uid}/Items/Resume` | GET | `emby.rs:867` | 继续观看 |
| `/Users/{uid}/FavoriteItems/{id}` | POST/DELETE | `emby.rs:921` | 加/取消收藏 |
| `/Users/{uid}/PlayedItems/{id}` | POST/DELETE | `emby.rs:1481` | 标已看/未看,两者均返 200 + 更新后 UserData |
| `/Users/{uid}` | GET | `emby.rs:948` | 读 `Policy.IsAdministrator` |
| `/Items/{id}/Refresh` | POST | `emby.rs:986` | 刷新/重刮 |
| `/Library/Refresh` | POST | `emby.rs:992` | 扫描**整台服务器** |
| `/Shows/NextUp?UserId=` | GET | `emby.rs:1468` | 接下来播放,返回 Episode |
| `/Items/{id}/Similar?UserId=` | GET | `emby.rs:1334` | 相似推荐,`{Items,TotalRecordCount}` 同构 |
| `/Items/{id}/PlaybackInfo?UserId=` | POST | `emby.rs:426`/`2088` | 取流 + 取版本,同一端点两条路 |
| `/Sessions/Playing`、`/Progress`、`/Stopped` | POST | `emby.rs:2257` | 上报三件套 |
| `/Sessions/Logout` | POST | `emby.rs:1498` | 尽力而为 |
| `/System/Info/Public` | GET | `emby.rs:1607` | **无需登录**,登录前探测 |
| `/System/Info?api_key=` | GET | `lib.rs:1069` | 需鉴权,账号三态探测 |
| `/Genres` `/Tags` `/Studios` `/OfficialRatings` | GET | `emby.rs:1665` | 分面,**各自吞错** |
| `/Items/{id}/Images/{kind}` | GET | `imgcache.rs:164` | 见 §4 |
| `/Videos/{id}/{msid}/Subtitles/{idx}/0/Stream.{ext}` | GET | `emby.rs:1775` | 外挂字幕兜底路径 |
| `/Videos/{id}/stream.{container}?static=true` | GET | `emby.rs:2231` | 取流最终兜底 |
| `/emby/System/Ext/ServerDomains` | GET | `emby.rs:1560` | **非 Emby 本体**,服主自建的线路表小服务 |

### 2.2 `Fields` 实际使用的全部取值

代码里出现过的 Fields 组合(`grep -o "Fields=[A-Za-z,]*" crates/core/src/emby.rs` 的完整结果):

| Fields 值 | 拿来干什么 | 出处 |
|---|---|---|
| `PrimaryImageAspectRatio` | 海报比例,几乎所有列表都带 | `emby.rs:644`、`705`、`867` 等 |
| `Genres,ProductionYear,CommunityRating` | 卡片角标 + **客户端兜底复筛的判据** | `emby.rs:96-103`、`644` |
| `ProviderIds,PresentationUniqueKey,Path` | 跨服续播强匹配判据 | `emby.rs:104-112` |
| `SeriesId` | 拿它去查剧的 TMDB id | `emby.rs:113-115` |
| `MediaSources` | 分集卡的「2160p · 45M · 18.4G」 | `emby.rs:93-95`、`1082`、`1099` |
| `DateCreated,DateLastMediaAdded,SortName` | 收藏页本地排序 | `emby.rs:116-124`、`908` |
| `Overview` / `PremiereDate` / `People` | 详情页 | `emby.rs:787` |
| `Taglines,OfficialRating,Status,ChildCount` | 详情页第二批(2026-07-28 加) | `emby.rs:787` |
| `EndDate,ProductionLocations` | 演职员详情(卒年/出生地) | `emby.rs:1370` |
| `OriginalTitle` | Bangumi 反查 | `emby.rs:1179` |
| `Chapters` | 章节(跳片头 + 进度条缩略图共用) | `emby.rs:1832` |
| `ProductionYear` 单独 | 年份区间探针 | `emby.rs:1696` |

**跨服续播那四项被封装成常量,别手抄**:`HISTORY_FIELDS = "ProviderIds,PresentationUniqueKey,Path,SeriesId"`(`emby.rs:1316`)。

**不合法/不存在的 Fields(反面清单)**:
- `UserData` 和 `SeriesName` **不是**合法的 Fields 值 —— 它们默认就在响应里,不用请求
  (`UserData.UnplayedItemCount` 的注释写明「Emby 默认就带,不必请求任何 Fields」——`emby.rs:133-136`;
  `SeriesName` 在 `RawItem` 里直接解析,没有任何一条 URL 请求过它 —— `emby.rs:86-88`)。
- `EnableTotalRecordCount` 在 Emby 里不存在(那是 Jellyfin)。**代码里一次都没出现过**
  (`grep EnableTotalRecordCount` 全仓只命中 `docs/go-migration/MIGRATION.md:19` 这条警示文字)。
- 判据:全仓 `grep -rn "Fields=UserData\|Fields=SeriesName"` 零命中。

### 2.3 分页:`Limit` 的真实语义

`SERVER_PAGE_CAP = 200`(`emby.rs:586`)。三条实测结论写在 `emby.rs:568-573`:

1. **省略 `Limit` 不等于"不限"** —— 实测某 fork(Emby 4.9.3)省略 `Limit` 只返 **20** 条;
2. `Limit=0` 也是 20 条;
3. `Limit=201/250/500/1000` 一律被硬顶到 **200**(`emby.rs:584-585`)。

所以:
- 「不限」在单次请求里**根本不存在**,超过 200 条的库只能靠 `StartIndex` 翻页;
- 前端要知道翻到哪就必须有 `TotalRecordCount`,它**独立于本页 `Items.len()`**(`emby.rs:48-55`、`58-64`);
- 想要"全部"就得自己翻到底:`fetch_all_paged` 每轮 `&StartIndex={已拿到的条数}&Limit=200`,
  不足一页即到底(`emby.rs:878-899`);
- `max` 是安全闸,到闸**返回已拿到的且不报错** —— 对收藏/分集这两个场景,拿到前 max 条远好过整页失败
  (`emby.rs:874-877`;收藏 max=2000 见 `emby.rs:913`,分集 max=3000 见 `emby.rs:1101`)。
- 历史教训:收藏页原本写 `Limit=300`、分集原本写 `Limit=500` —— 服务端夹到 200,
  超出部分**静默丢失**,用户看不到也无从察觉(`emby.rs:900-902`、`emby.rs:1088-1090`)。

### 2.4 排序

- **`SortOrder` 必须跟着 `SortBy` 一起发**:实测只发 `StartIndex` 不发 `SortOrder` 时排序不稳,
  翻页会拿到重复/错位的条目(`emby.rs:650-652`)。默认 `SortBy=SortName&SortOrder=Ascending`(`emby.rs:653-656`)。
- 分集固定 `SortBy=ParentIndexNumber,IndexNumber&SortOrder=Ascending`(`emby.rs:1082`、`1099`)。
- 季固定 `SortBy=IndexNumber`(`emby.rs:1039`);合集固定 `SortBy=SortName`(`emby.rs:1459`);
  演员参演固定 `SortBy=PremiereDate&SortOrder=Descending`(`emby.rs:1411-1412`)。
- 随机 Hero 用 `SortBy=Random` 且 `ImageTypes=Backdrop`(只要有剧照的,否则 Hero 是空的)(`emby.rs:463`)。
- **收藏页的排序不走服务端**,理由见 §6。

### 2.5 筛选参数的分隔符与拼法

- `Genres` / `Tags` / `Studios`:**竖线 `|` 分隔**,每个值单独转义(`emby.rs:658-660`、`push_list` 在 `emby.rs:679-683`)。
- `Years`:**逗号 `,` 分隔**,不转义(纯数字)(`emby.rs:661-664`)。
- 评分:**Emby 只有下界 `MinCommunityRating`,没有 `MaxCommunityRating`** —— 上界只能靠客户端复筛(`emby.rs:666-669`)。
- `Filters=IsFavorite` 取收藏(`emby.rs:908`)。
- `PersonIds=` 取某人参演,**不能用 `Person=<名字>`**:同名演员在库里是两个人,按名字筛会把两个人的作品混在一起,而且不报错(`emby.rs:1400-1402`)。
- `ParentId` + `Recursive=true` = 只在这棵库树里递归找(`emby.rs:1288-1292`)。
  **空串必须当没传**:前端传 `""` 比传 `null` 更常见,拼上去会变成「在 id 为空的库里搜」= 恒零结果(`emby.rs:1292-1293`、`1310-1313`)。
- `GroupItems=true` 让 Latest 把剧集归并到剧,避免刷一堆单集(`emby.rs:703-706`)。

### 2.6 URL 转义:必须逐字节对账的一处

`enc()` = `urlencoding::encode`(`emby.rs:685-687`)。该 crate 的保留集是
`0-9 A-Z a-z - . _ ~`,其余全部大写十六进制百分号编码,**空格 → `%20`**
(实证:`urlencoding-2.1.3/src/enc.rs:103` 的字符集 + `:132-137` 的 `to_hex_digit` 用大写)。

**Go 的 `url.QueryEscape` 把空格编成 `+`**,保留集相同。
所以 Go 侧必须写 `strings.ReplaceAll(url.QueryEscape(s), "+", "%20")`,直接用 `QueryEscape` 是字节级不一致。
(搜索关键词、Genres、Studios、SortBy 全走这一条路。)

### 2.7 `SearchTerm` 三条硬规矩

1. **大写 `S`**。实测小写 `searchTerm` 被服务端**静默忽略** → 返回全库前 N 条冒充搜索结果
   (某 fork 上 `searchTerm=<词>` 回 `TotalRecordCount=25596`(整个服务器),`SearchTerm=<词>` 回 6 条正确结果)。
   出处 `emby.rs:1279-1284`,测试 `emby.rs:2772-2800`。
2. **默认类型集必须含 `Episode`**:旧实现写死 `Movie,Series`,分集搜不到(`emby.rs:1271-1274`、断言 `emby.rs:2789`)。
3. **服务端过滤靠不住,显式点名的类型要在客户端再滤一遍**(`filter_types`,`emby.rs:1250-1265`)。
   `types=None` 是「默认全要」,不是「一个都不要」——滤成空集会让 `watch_history_sync` 静默失灵(`emby.rs:1256-1257`)。

---

## 3. 取流与 PlaybackInfo

### 3.1 一个端点,两条路

`POST /Items/{id}/PlaybackInfo?UserId={uid}` 被两个函数打:

- `media_versions`(`emby.rs:419-448`):body 是**空对象 `{}`**,只为拿版本列表给 UI 显示;
- `resolve_stream`(`emby.rs:2078-2247`):body 带完整 `DeviceProfile`,拿真播放地址。

**两条路必须打同一批 MediaSource、用同一套匹配文本**,否则界面说在放第一条、实际在放另一条(见 §7-7)。
注释把这条契约写死在 `emby.rs:414-418`。

### 3.2 DeviceProfile:宽松声明 + 字幕声明

`emby.rs:2090-2117`。要点:

```
MaxStreamingBitrate: 120000000
MaxStaticBitrate:    100000000
DirectPlayProfiles:  [{Type:"Video"}, {Type:"Audio"}]   ← 声明啥都能直连,促使服务器给 DirectStreamUrl
TranscodingProfiles: []
ContainerProfiles:   []
CodecProfiles:       []
SubtitleProfiles:    [srt/subrip/ass/ssa/vtt/webvtt/sub/idx/smi → External,
                      pgssub/dvdsub → Embed]
```

**`SubtitleProfiles` 原来是 `[]`,那是「外挂字幕不加载」的源头。**
空表 = 告诉服务器「本客户端一种字幕都不支持」,服务器于是把 `DeliveryMethod` 判成 `Encode`/`Drop`
且 **`DeliveryUrl` 返 null** —— 从源头就没有地址可挂(`emby.rs:2100-2103`)。
实测对照写在测试注释里(`emby.rs:2486-2492`):带 `{Format:"ass",Method:"External"}` 时
返回 `DeliveryUrl=/Videos/{id}/{msid}/Subtitles/{idx}/0/Stream.ass?api_key=...`;
`SubtitleProfiles:[]` 时返回 `DeliveryMethod=Encode, DeliveryUrl=null`。

### 3.3 选哪个 MediaSource

`emby.rs:2138-2154`,优先级严格如下:

1. 调用方显式传了 `media_source_id` → 找它;**找不到就报错,绝不静默回落第一个**。
   静默回落会让用户以为在看 4K、实际放的是 1080p 且毫无提示(`emby.rs:2072-2075`)。
2. 没传 → 版本筛选正则 `pick_index(texts, version_regex)` 命中哪条用哪条;
3. 正则空/非法/没命中 → `unwrap_or(0)`,取服务器返回顺序的第一条。

### 3.4 版本正则匹配的是什么文本

`source_match_text`(`emby.rs:2050-2075`)把一个 MediaSource 拼成一段可匹配文本:

```
Name + Container + (每条 Video 流的) DisplayTitle + Codec + Profile + VideoRange + VideoRangeType
                 + "{Height} {Height}p"  + 口语档位别名
```

- **口语档位别名只补两档**:`Height>=4320 → "8K"`,`Height>=2160 → "4K"`(`emby.rs:2065-2071`)。
- 为什么非补不可:Emby 只给 `Height=2160`,DisplayTitle 未必带 "4K" 字样;
  不补别名,「优先 4K 片源」这条最常用的正则**永远不命中而且一声不吭**(`emby.rs:2046-2049`)。
- 这条别名有独立测试钉住(`emby.rs:2450-2455`)——因为 `4K|2160` 那条里 `2160` 分支自己就能命中,
  删掉别名照样绿,所以专门写了只有 `4K` 的断言。

### 3.5 `preferred` 标记

`media_versions` 用**同一个** `source_match_text` + `pick_index` 算出命中下标,把那一条标 `preferred=true`
(`emby.rs:441-446`)。前端唯一算法:`defaultVersion = vs.find(v => v.preferred) ?? vs[0] ?? null`
(`ui/shared/api.ts:150-151`)。正则留空/没命中 → 全 false → 回落第一条,与核层一致(`emby.rs:395-401`)。

### 3.6 `PlaySessionId`

- 服务器发的优先;缺失/空串则本地兜底生成 `{device_id}-{item_id}`(`emby.rs:2134-2138`)。
- **同一次播放的 start/progress/stopped 三次上报必须是同一个 id**,否则服务器不认这次上报,
  续播进度不落地(`emby.rs:1783-1785`)。
- 观看记录恢复/回传没有真实取流会话,但同样要三次同 id,所以一次造好传三遍,
  格式 `{device_id}-wh-{item_id}`(`watch_history_sync.rs:194-209`)。

### 3.7 `MediaSourceId` 的意义

- 它是上报三件套的必填项(`emby.rs:2277`、`2296`、`2315`),服务器靠它知道你在放哪个版本。
- 无真实媒体源时(恢复/回传)**用 itemId 顶替**(`watch_history_sync.rs:202-203`)。
- 预取代理的 URL 重签回调**必须钉住 media_source_id**:不带的话 URL 过期重签会悄悄退回默认版本,
  用户选的 4K 播到一半变 1080p 且无任何提示(`lib.rs:4709-4726`)。

### 3.8 DirectStreamUrl 是相对路径 —— 以及那条 Range 前缀探测

三种地址来源,按顺序(`emby.rs:2217-2236`):

| 来源 | play_method | 处理 |
|---|---|---|
| `DirectStreamUrl` 非空 | `DirectStream` | 先过 `seekable_path` 再 `abs_url` |
| 否则 `TranscodingUrl` 非空 | `Transcode` | 只过 `abs_url`(**不做 Range 探测**) |
| 都没有 | `DirectStream` | 直拼 `/Videos/{id}/stream.{container}?static=true&mediaSourceId=&api_key=` |

`DirectStreamUrl` 形如 `/videos/16612/original.mkv?...`,是**相对路径**,我们把它拼在服务器根上。
Emby 本体在根和 `/emby/` 两个前缀上都提供 API,所以整套接口一直工作正常 ——
但**某些反代只在 `/emby/` 路由上正确处理 Range**:根路径下的同一个地址收到 `Range:` 也回
`200 OK` + 完整 `Content-Length`。实测对照(`emby.rs:1969-1986`):

```
GET /videos/{id}/original.mkv       Range: bytes=1000000-1000099  -> 200(整个文件)
GET /emby/videos/{id}/original.mkv  Range: bytes=1000000-1000099  -> 206 bytes 1000000-1000099/977548032
```

ffmpeg 拿不到 206 就只能从当前位置**顺读丢弃**到目标字节 —— 往前跳 9 分钟就是 370MB;
mpv 日志里是 `https: Unexpected offset: expected N, got 0` + `Seek failed`。
别的播放器没事,是因为它们按 Emby 惯例把相对地址拼在 `/emby` API 根上。

**解法不是写死前缀,是各发一次 `Range: bytes=0-0` 实测**(`emby.rs:1981-1986`):
写死 `/emby` 会在 Jellyfin(没有这个前缀)和带 base path 的部署上把好地址改坏。

- 决策表 `choose_prefix(plain_ok, emby_ok)`(`emby.rs:2005-2007`):
  原地址能 Range → `""`(**别动**,最少惊讶);原地址不行而 `/emby` 行 → `"/emby"`;
  两条都不行 → `""`(换前缀只是换一种坏法)。
- 候选生成 `emby_prefixed`(`emby.rs:1991-2000`):已带 `/emby/`、或本来就是绝对地址 → 没有第二个候选,**不叠加**。
- 探测代价 = 一个字节(`bytes=0-0`),**每台服务器每次运行只探一次,结果按 `s.server` 缓存**
  (`RANGE_PREFIX`,`emby.rs:1987-1988`、`2020-2043`)。
- 探测**绝不能挡住起播**:任何失败一律回原样(`emby.rs:2017-2019`)。
- 注意 `supports_range` 用的是裸 `http.get(url)`,**不带任何鉴权头**(`emby.rs:2010-2016`)——
  能通是因为 `abs_url` 已经把 `api_key=` 拼进 URL 了。

### 3.9 外挂字幕

`emby.rs:2175-2215`。筛选条件 `Type=="Subtitle" && IsExternal==true`。

- **图形字幕跳过**:`pgssub|pgs|dvdsub|dvbsub` 直接 return None —— 外挂形态少见且 mpv 挂载后多半不可用(`emby.rs:2185-2188`)。
- **扩展名不是 codec 原值**:`subrip→srt`、`webvtt→vtt`,其余原样(`emby.rs:2189-2194`)。
- 地址:有 `DeliveryUrl` 就 `abs_url` 它;没有就按标准路由自拼
  `/Videos/{itemId}/{mediaSourceId}/Subtitles/{index}/0/Stream.{ext}?api_key={token}`(`emby.rs:1774-1776`)。
  中间那个 `/0` 是 StartPositionTicks 段,**少了会 404**;把 codec 直接当扩展名也会 404(`emby.rs:2490-2492`)。
- **`Path` 字段不能当 URL**:那是**服务端本地文件系统路径**(如 `/media/x.ass`),客户端取不到,拿来当 URL 只会 404
  (`emby.rs:381-383`)。
- 标题回落链:`DisplayTitle` → `Language` → `外挂字幕 {index}`(`emby.rs:2204-2209`)。
- 宿主侧:外挂字幕**不在容器里**,mpv 的 track-list 根本看不到,必须播放器起来后逐条 `sub-add`,
  且**必须排在 `load_at` 之后**(先挂会被 loadfile 冲掉)——`lib.rs:1753-1760`。

### 3.10 杜比视界判定

判定顺序从最权威到最兜底(`emby.rs:325-345`):

1. `VideoRangeType` 含 `dovi`/`dolby`(取值域 `DOVI / HDR10 / HLG / HDR10Plus`,`emby.rs:285-288`);
2. `Codec` 含 `dvhe` / `dvh1` / `dav1`;
3. `Profile` 含 `dolby vision`(老服务器只在人类可读串里体现)。

**只看 `VideoRange=HDR` 会把 HDR10 一起误判成 DV**,白白掉进软解(`emby.rs:329`)。
`resolve_stream` 里另有一份同逻辑的内联实现(`emby.rs:2156-2173`)——
在取流这一跳顺手判,因为 `MediaStreams` 就在同一份响应里,不用再打一次服务器(`emby.rs:2156`)。
**Go 侧应当收敛成一个函数**,但行为必须与这两处完全一致(见 §8)。

历史根因:`MediaSource` 曾被建了**两份模型**,取流那条路上 `MediaStreams` 被静默丢弃,
于是「杜比视界自动软解」永远判不出 DV —— 数据一直在线上,只是没人接(`emby.rs:249-252`)。

### 3.11 只有 DirectStream 走预取代理

`lib.rs:1712`:`if (pf_on || warm_hit) && target.play_method == "DirectStream"`。
转码 URL 是分段流,跳过直连(`lib.rs:1698-1699`)。
代理起服失败一律回退直连(`lib.rs:1728-1731`)。
预取代理探到上游**不支持 Range** 时必须拒绝起服(返 None)让调用方回退,
否则拿不到 `Content-Range` → 分段定位全错 → 喂给播放器就是黑屏(`net/prefetch.rs:2196-2202`)。

---

## 4. 图片 API

### 4.1 有没有图:两个字段,不是一个

- **Primary(海报)看 `ImageTags.Primary` 是否存在**(`emby.rs:182-186`,详情页同款 `emby.rs:849`)。
- **Backdrop(剧照)看 `BackdropImageTags` —— 它是个数组,不在 `ImageTags` 里**
  (`emby.rs:850`:`j["BackdropImageTags"].as_array().map(|a| !a.is_empty())`)。
  把 Backdrop 当成 `ImageTags` 的一个键去查,恒为 false,表现是「所有条目都没有剧照」。
- `is_folder` 的判据是 `IsFolder || CollectionType.is_some()`(`emby.rs:187`)——
  媒体库(CollectionFolder)不一定带 `IsFolder`。

### 4.2 分集没有 backdrop 怎么办

用**它所属剧的 id** 去取:`const bgId = d?.series_id ?? item.id`(`ui/desktop/pages/DetailPage.tsx:317`)。
覆盖率注释写在 `DetailPage.tsx:587-589`(剧集/电影 100%/92%,分集靠 SeriesId)。
取不到就露出纯色底,**不再回落 poster** —— 海报已经在左边单独画了一张,背景再放一张就重复了
(`DetailPage.tsx:588-589`)。这是一个明确的产品决定,不是遗漏。

### 4.3 实际请求的地址

图片不由前端直接 `<img src>` 打服务器,而是走自定义协议 `lpimg` 由 Rust 代取(`imgcache.rs:1-20`)。
最终打给 Emby 的是(`imgcache.rs:162-176`):

```
{base}/Items/{id}/Images/{seg}?quality=90[&maxHeight=..][&maxWidth=..]
seg = "Backdrop/0"(Backdrop 要带序号) | "Primary" | "Logo"
鉴权走 header X-Emby-Token,不是 api_key
```

- kind 白名单只认 `Primary` / `Backdrop` / `Logo`,其余拒绝(`imgcache.rs:113-118`)。
- itemId 只放行 `[0-9a-zA-Z-]`,堵死 `../`、`?`、`&`(`imgcache.rs:122-125`,测试 `imgcache.rs:245-261`)。
- 尺寸参数只放行 `h`/`w` 且值必须全数字,映射成 `maxHeight`/`maxWidth`(`imgcache.rs:165-176`)。
- 前端默认尺寸:poster `h=480`、thumb `w=640`、backdrop `w=1600`、logo `h=150`、person `h=160`
  (`ui/shared/api.ts:919-921`、`1951-1969`)。

### 4.4 `maxWidth` 被忽略的情况

**某台 fork 的 `/Items/{id}/Images/Backdrop/0` 会 301 跳到静态文件**(形如 `/img/i/fanart/{id}.jpg`)
(`imgcache.rs:178-182`)。静态文件不经过图片缩放管线,尺寸参数在那条路上没有作用。
两条直接后果:

1. **不能关掉 redirect 跟随**。不跟跳只会拿到 79 字节的 HTML,然后被 `sniff` 判成 octet-stream ——
   表现是「图不显示但也不报错」(`imgcache.rs:178-182`)。reqwest 默认跟 301,这里**依赖**这个行为。
2. **不能信上游的 `Content-Type`**。反代经常把它抹成 `application/octet-stream`,
   浏览器不认,图就是不显示且不报错。所以按魔数嗅 MIME(`imgcache.rs:214-224`,测试 `imgcache.rs:230-236`)。

### 4.5 缓存键的三条纪律(`imgcache.rs:145-148`)

```
key = "{账号主键}|{itemId}|{kind}|{query}"
```

- 用**账号主键 `a.server`**,不是当前线路地址 —— 同一张图换条线路拉还是同一张图,
  用线路地址当键,用户一切线路整盘缓存全部落空;
- **更不能用完整上游 URL** —— 那里面有 `api_key`,重登一次 token 变了,缓存全废。

### 4.6 并发闸与超时

- 同时最多 **6** 张图在回源(`FETCH_SLOTS`,`imgcache.rs:30-43`)。理由不是省流量:
  封面和 `item_detail`/`views`/`list_latest` 这些 JSON **走同一个 HTTP 客户端、同一个连接池、同一台服务器**;
  首页一屏三十几张封面同时回源时,后面点进详情页要的那条 JSON 排在它们后头 ——
  用户看到的是「简介也加载得很慢」,而简介只有几 KB。
- **有闸就必须有超时**:一条卡死的连接会把名额**永久**占住,六条卡死 = 再也加载不出任何一张图,
  而且一声不吭。上限 20s(`imgcache.rs:45-49`)。
- **缓存命中不占名额**(先查缓存,命中直接 return,`imgcache.rs:150-160`、`183-186`)。
- 失败必须回 **404 而不是 200+空体**:空体会被当成一张坏图,前端 `onError` 也不触发(`imgcache.rs:87-94`)。
- 响应必须带 `Access-Control-Allow-Origin: *`:详情页要把海报画进 canvas 取主色,
  不同源时 `getImageData` 抛 SecurityError,被 try 吞掉后一点痕迹都没有(`imgcache.rs:76-83`)。

### 4.7 其它图片端点

- **章节缩略图**:`/Items/{id}/Images/Chapter/{序号}?tag={ImageTag}&maxWidth={w}&api_key={token}`
  (`emby.rs:1858-1864`)。**必须带 api_key**,否则前端 `<img>` 直接 401、缩略图静默全白;
  服务端没生成图(无 `ImageTag`)时必须是 `None`,不能拼出一个必然 404 的地址(`emby.rs:2590-2593`)。
- **用户头像(= 服务器图标)**:`{base}/Users/{uid}/Images/Primary?tag={tag}`(`server_batch.rs:305-318`)。
  用户头像在 Emby 是公开资源(登录选人界面免登录就显示),**无需 api_key**(`server_batch.rs:304-306`)。
- 没头像时该函数回落 `{base}/web/touchicon.png`(`server_batch.rs:316`),
  **但登录路径故意不用这个兜底**:那玩意常 404,宁可留空 `icon_url` 由 UI 回落内置图标(`lib.rs:364-367`)。
- 服务器图标**只在首次添加账号时设**:`upsert` 对已存在账号是 `acc.icon_url.or(old)`,
  传 Some 会盖掉用户自定义的图标(`lib.rs:359-362`)。

---

## 5. 播放上报

三个端点都是 `POST {server}/Sessions/Playing{后缀}`,统一走 `post_report`
(`emby.rs:2251-2270`),都带 `X-Emby-Token` + `X-Emby-Authorization`。
时间统一 `secs * 1e7` 取整,负数夹到 0(`secs_to_ticks`,`emby.rs:1947-1949`)。

| | 端点后缀 | body 字段 | 出处 |
|---|---|---|---|
| start | (空) | `ItemId` `MediaSourceId` `PlaySessionId` `PlayMethod` `PositionTicks` `CanSeek:true` `IsPaused:false` | `emby.rs:2272-2288` |
| progress | `/Progress` | `ItemId` `MediaSourceId` `PlaySessionId` `PlayMethod` `PositionTicks` `IsPaused` `EventName:"timeupdate"` | `emby.rs:2290-2307` |
| stopped | `/Stopped` | `ItemId` `MediaSourceId` `PlaySessionId` `PositionTicks` | `emby.rs:2309-2321` |

**三处差异必须照搬,不要"统一"**:

- `stopped` **没有** `PlayMethod`,也**没有** `IsPaused`;
- `progress` 的 `EventName` 固定 `"timeupdate"`;
- `start` 的 `CanSeek` 恒 `true`。

调用时机(桌面端,安卓同构):

- start:`play()` 里起播后调,**失败不阻断播放**,只写日志(`lib.rs:1773-1776`)。
- progress:前端每 ~5s 及暂停切换时调;**一律吞错**(`let _ =`),同时落本地观看记录(`lib.rs:1854-1864`)。
- stopped:`stop_playback` 里调,失败只写日志(`lib.rs:2185-2193`)。
  最终进度必须先 `capture_history(force=true)` 绕开 10s 节流落本地,否则看一半退出这段就丢了(`lib.rs:2186-2188` 上方 `lib.rs:2187`)。

恢复/回传路径把三件套当成一个原子操作:`start(0) → progress(pos, paused=true) → stopped(pos)`,
任一步失败即整体失败(`watch_history_sync.rs:211-223`)。
「标记已看」失败时的兜底是 `start(0) → stopped(总时长)`,让服务器自己判已看 ——
仅对本地已看完的记录成立,且拿不到时长就没法兜底(`watch_history_sync.rs:114-122`、`341-350`)。

已看/未看是另一条路,不走上报:`POST|DELETE /Users/{uid}/PlayedItems/{id}`(`emby.rs:1474-1491`)。
看过阈值本地判定用 90%,注释写明「与 Emby 默认一致」(`lib.rs:1914-1916`)。

---

## 6. 服务端差异与绕法

> **服务器代号**(本文不写真实域名):
> - **服务器A** = 某 Emby fork(自报 `Version 4.9.3.0`,`ServerName`/`Id` 均为同一个短名),
>   代码注释里以 `smart.*` 出现;
> - **服务器B** = 同一家的另一台 fork(代码注释里以 `v1.*` 出现);
> - **服务器C** = 接近原版的 Emby(4.9.5),对照组。
> **纪律:两台服务器结论相反是常态,别拿一台的结果给另一台签字**(`emby.rs:1294-1303` 明写)。

### 6-1 省略 Limit 只返 20,Limit>200 被夹到 200

- **症状**:媒体库明明 3276 条,列表只出 20 条 / 写 `Limit=1000` 只回 200。
- **真因**:服务端对 `Limit` 的处理:省略 → 20;`0` → 20;`>200` → 硬顶 200(服务器A 实测)。
- **绕法**:`limit.unwrap_or(200).min(200)`,「不限」不存在,超过 200 靠 `StartIndex` 翻页;
  `TotalRecordCount` 独立解析出来给前端算页数。
- **出处**:`emby.rs:568-573`、`584-586`、`645-648`;测试 `emby.rs:2654-2661`。

### 6-2 服务端筛选是假的(Genres/Years/评分一律忽略)

- **症状**:筛选面板选了「喜剧」,返回的 `TotalRecordCount` 与不筛完全一致(3276),头几条根本没有喜剧标签。
- **真因**:服务器A 对 `Genres`/`GenreIds`/`Years`/`MinCommunityRating` 一律忽略。
- **绕法**:参数照发(标准 Emby/Jellyfin 认,能少传数据),**同时在客户端按同样条件复筛一遍**
  (`ItemQuery::needs_local_filter` / `matches`,`emby.rs:589-628`;调用 `emby.rs:670-681`)。
  认参数的服务器上复筛是 no-op。
- **已知代价**(代码里标了 `ponytail:`):复筛只作用于当前这一页,3276 条的库筛「喜剧」只会得到
  前 200 条里的喜剧。**宁可少给,不能给错**(`emby.rs:632-635`)。
- **复筛动过手时 `total` 改成本页实际条数**,免得前端按 3276 画出永远翻不满的页码(`emby.rs:674-679`)。
- **`tags` 不参与客户端复筛**:`Item` 不带 `Tags` 字段,判不了,交给服务端(`emby.rs:598-600`)。
- **出处**:`emby.rs:629-635`;测试 `emby.rs:2699-2733`、`2735-2742`。

### 6-3 带 SearchTerm 时把所有筛选参数一起忽略

- **症状**:在「电影」库里搜,能搜出别的库的剧集;搜索浮层的「包括集」开关点了没反应还不报错。
- **真因**:服务器B(fork)**带 `SearchTerm` 时把筛选参数整片忽略** ——
  2026-08-17 curl 实测:`ParentId` / `AncestorIds` / `Ids` / `NameStartsWith` / `NameContains` 全无效,
  连 `/Search/Hints?ParentId=` 也一样,12 个库回的是同一堆。
  **不带 `SearchTerm` 时 `ParentId` 是好的**,所以不是权限或 id 的问题。
  同一批实测里 `IncludeItemTypes` 一并中招(传 `Episode` 照样只回 `Series`/`Movie`)。
  对照:服务器C 上 `ParentId` 完全生效 —— 同一关键词在 12 个库里搜,回来的集合两两零重叠。
- **绕法**:① 参数照发(给标准 Emby/Jellyfin 用);② 显式点名的类型在客户端再滤一遍
  (`filter_types`,`emby.rs:1250-1265`)。
- **做不到的部分,代码里如实承认**:「这台上库内搜索做不到 —— 没有任何服务端参数能收窄,
  客户端要么全量拉库(每敲一键拉一遍整个库),要么就是搜不准。不为一台 fork 把架构改回去」(`emby.rs:1299-1303`)。
- **出处**:`emby.rs:1229-1234`、`1288-1303`;测试 `emby.rs:2802-2838`、`2840-2858`。

### 6-4 `searchTerm`(小写)被静默忽略

- **症状**:搜索永远返回一堆和关键词无关的结果。
- **真因**:Emby 的 query 参数**大小写敏感**;小写 `searchTerm` 服务端不认,当成没传 → 返回全库前 N 条。
  实测某 fork 上小写回 `TotalRecordCount=25596`(整个服务器),大写回 6 条正确结果。
- **绕法**:只能写 `SearchTerm`。有专门的测试防手滑改回小写。
- **出处**:`emby.rs:1279-1284`;测试 `emby.rs:2771-2800`。

### 6-5 分面端点大面积 404

- **症状**:媒体库筛选面板里「年份」「标签」「分级」永远是空的。
- **真因**:服务器A 实测 —— `/Items/Filters`、`/Users/{u}/Items/Filters2`、`/Years`、`/Tags`、
  `/OfficialRatings` 全 404;只有 `/Genres`、`/Studios` 返 200。
  旧 Dart 实现也在拉那三个并**吞错**,所以年份/标签分面一直是空的、没人发现。
- **绕法**:
  - 五路 `tokio::join!` 并行,**各自吞错**,某个分面 404/500 只让它自己为空(`emby.rs:1646-1653`、`facet` 在 `emby.rs:1663-1691`);
  - 年份没有可用端点 → 按 `ProductionYear` 正/倒排各取 1 条(`Limit=1`)拿最早/最晚年,铺成倒序区间
    (`year_range`,`emby.rs:1693-1711`)。标了 `ponytail:`:区间里可能混入该库没有的年份(选了就是空结果),
    换取 2 次请求而非 17 次。
- **`/Genres` 的 `Id` 是数字不是 GUID**,所以只取 `Name` 才不踩类型坑(测试 `emby.rs:2757-2771`)。
- **出处**:`emby.rs:1636-1644`。

### 6-6 收藏查询上无视 SortBy/SortOrder

- **症状**:收藏页排序切换没有任何效果。
- **真因**:服务器B 在 `Filters=IsFavorite` 查询上直接无视 `SortBy`/`SortOrder` ——
  实测 `SortBy=SortName&Ascending` 与 `SortBy=CommunityRating&Descending` 返回**完全相同**的顺序
  (恒为 DateCreated 降序)。**原版(服务器C)是认的**。
- **绕法**:收藏排序**不走服务端**,只负责把 Fields 要全,排序交给前端本地做(收藏封顶 2000 条,本地排毫无压力)。
- **要改回服务端排序,先在目标服务器上验证**(注释指明用日志里的 `[TRACE favorites url]` 手法)。
- **出处**:`emby.rs:903-913`。

### 6-7 `/Sessions/Logout` 404 且 token 登出后仍可用

- **症状**:退出登录报错 / 或以为登出了其实 token 还能用。
- **真因**:服务器A 上该端点 404,且 token 登出后仍可用。
- **绕法**:**不能**让它的失败挡住本地删账号,调用方忽略返回值。
- **出处**:`emby.rs:1493-1496`;调用点 `lib.rs:1580`。

### 6-8 反代只在 `/emby/` 下处理 Range

见 §3.8。**出处**:`emby.rs:1969-1986`;测试 `emby.rs:2337-2363`。

### 6-9 图片 301 跳静态文件

见 §4.4。**出处**:`imgcache.rs:178-182`。

### 6-10 `DateLastMediaAdded` 恒为 null

- **症状**:按「更新时间」排序时剧集不动。
- **真因**:该字段只有部分服务端给,某 fork 上实测恒为 null。
- **绕法**:`date_updated = DateLastMediaAdded.or(DateCreated)`(`emby.rs:226`),字段注释在 `emby.rs:116-121`、`173-175`。
- ISO8601 字符串,同一台服务器格式一致 → 前端直接字符串比较,不必解析成时间(`emby.rs:174`)。

### 6-11 `/Items/Counts` 不能假设存在

- **真因**:该端点在服务器C 上实测 200,但**别假设所有 fork 都有** ——
  同一文件里 `/Items/Filters`、`/Years`、`/Tags` 就都是 404。
- **绕法**:调用方必须容忍它失败,统计条是锦上添花,不该让首页整个报错(`emby.rs:539-543`;
  调用点用 `tokio::join!` 且失败降级成 `Counts::default()`,`lib.rs:598-616`)。
- **顺带一条**:`UserId` 必须带。不带的话服务端把**该用户看不到的库**也算进去。
  服务器C 实测差值:带 UserId → Movie 1579 / Series 2393 / Episode 98476;
  不带 → Movie 1618 / Series 2652 / Episode 99346。差 39 部电影、259 部剧、870 集 ——
  数字看着都"像那么回事",所以漏了不会有人发现(`emby.rs:531-538`)。

### 6-12 直传流 302 跳 CDN

- **症状**:开了多线程加载反而更慢(3 线程 4.0MB/s 慢于单连接 4.3MB/s)。
- **真因**:服务器B 那类的直传流是 302 跳 CDN,而预取的每段都是独立请求 →
  **每 4MB 重走一遍 302**,实测 0.67s/段,占单段 TTFB(1.4s)的一半。
  原版 Emby 无重定向(实测 redirect=0.000000)。
- **绕法**:跟随一次后缓存**最终地址**,worker 优先打它;CDN 直链自带时效签名,
  过期即失效 → 失败时清空回退原 URL 重新解析(`net/prefetch.rs:166-179`)。
- **重签必须钉 media_source_id**,见 §3.7。

### 6-13 分集的 ProviderIds 经常是空的

- **症状**:Trakt 上报对番剧集全部静默失败。
- **真因**:Emby 分集的 `ProviderIds` 经常为空,此时 `ids` 是空对象,scrobble 被 `has_trakt_ids()` 挡掉且一声不吭。
- **绕法**:分集额外再拉一次**剧**的 `ProviderIds`(多一次请求),
  用 `{"show":{ids},"episode":{season,number}}` 这种 Trakt 更认的形态兜底(`emby.rs:1128-1135`、`1196-1209`、`1146-1163`)。
- `ProviderIds` 键名大小写不一(`Imdb`/`Tmdb`/`Tvdb`),必须归一小写;`tmdb`/`tvdb` 要转成数字(Trakt 要 int),
  `imdb` 保持字符串(`emby.rs:1166-1189`)。

### 6-14 无 body 的 POST 需要显式 `Content-Length: 0`

- **真因**:管理动作是无 body 的 POST,少了这个头**有的反代直接 411**。
- **绕法**:`post_admin` 固定加 `Content-Length: 0`(`emby.rs:1001`)。
- 同一函数把 403 单独翻译成「服务器拒绝:当前账号没有管理员权限」(`emby.rs:1005-1008`)。

### 6-15 `/System/Info/Public` 不校验 token

- 见 §1.4。**出处**:`lib.rs:1067-1068`。

### 6-16 线路表端点是服主自建的,404 是常态

- `/emby/System/Ext/ServerDomains` **不是 Emby 本体的端点**,是服主自己部署的一个 Go 小服务,
  用 nginx 精确匹配挂在自己 Emby 域名的**同一 origin** 下 —— 所以「匹配」是**隐式同源**的,
  没有 key、没有 ID、没有分组,**别去设计什么匹配逻辑,不存在**(`emby.rs:1523-1541`)。
- 用户填的地址可能已经带了 `/emby`(反代常见写法),直接拼会变成 `/emby/emby/…` → 404;
  故先削掉结尾的 `/emby` 再拼(`emby.rs:1553-1558`)。
- **`Ok(vec![])` 与 `Err` 的分界**:绝大多数服务器没装这玩意 —— 404/超时/解析不了 → `Ok(vec![])`,
  让 UI 说「这台服务器没提供线路表」而不是弹红色报错;**只有 401 才 Err**(`emby.rs:1546-1550`、`1571-1587`)。
- **信任边界**:回来的 `url` 是服主在自己配置里自填的裸字符串,上游零校验,而它会被我们直接当 baseUrl
  拼 API + 带 token 请求 —— 配错或被投毒就等于把 token 发到任意地址。
  故只收 `http(s)://` 且能解析成合法 URL(`emby.rs:1588-1600`)。
- 超时 10s(上游 nginx `proxy_read_timeout` 10s,且它每次都回源校验 token 不缓存)(`emby.rs:1561-1570`)。

---

## 7. 踩坑清单(上:数据与列表)

### 7-1 屏蔽了一个媒体库,然后再也解除不了

- **症状**:用户原话「我在首页屏蔽完了,媒体库的也不见了,那我怎么恢复呢?」(2026-08-02 真发生过)。
- **真因**:`views()` 当时走的是 `fetch_items`,而**那条路会套用屏蔽名单**,名单里装的正是被屏蔽的**库 id**。
  于是屏蔽一个库之后连媒体库页自己那份列表都把它滤掉了。命令层新加的 `include_blocked` 参数
  完全是个摆设 —— 东西在更下面一层就已经没了。
- **现在怎么处理**:`views()` 走 `fetch_page`(**不过滤**),如实返回服务器给的全部库;
  该不该滤是**命令层**的决定(`emby.rs:513-522`)。命令层:缺省过滤,`include_blocked=true` 才给全量(`lib.rs:665-678`)。
- **Go 侧怎么落**:把「取数」和「过滤」彻底分成两层函数,`views` 只能调不过滤的那层。
  过滤开关必须在**命令签名**上,不能在数据层。
- **出处**:`emby.rs:513-522`;测试 `emby.rs:2864-2921`(**走真 HTTP** —— 纯逻辑测不到「views 用了哪个取数函数」这件事)。

### 7-2 媒体库网格故意不过滤

- **真因**:屏蔽的卡片必须留在媒体库里,否则用户点错一次就再也找不到那部剧去解除屏蔽了。
- **现在怎么处理**:`fetch_items`(过滤)只服务「首页 + 搜索 + 推荐」这一族:
  继续观看 / 接下来看 / 随机推荐 / 收藏 / 合集 / 搜索 / 相似推荐 / 演员参演 / 分集;
  **媒体库网格直接调 `fetch_page`**(`emby.rs:1731-1742`)。
- **Go 侧怎么落**:同上,两层函数。别做成「一个函数 + bool 参数」——那个 bool 会被漏传。
- **出处**:`emby.rs:1731-1742`;设计理由 `blocklist.rs:6-11`。

### 7-3 `/Items/Latest` 是裸数组,过滤要单独补一句

- **症状**:首页别的行都干净了,唯独「最新更新」里还挂着被屏蔽的条目。
- **真因**:Latest 端点直接返回**裸数组**(非 `{Items}` 包裹),走不了 `fetch_items`。
- **现在怎么处理**:自己解析成 `Vec<RawItem>` 后手动补一句 `blocklist::filter`(`emby.rs:696-716`)。
- **Go 侧怎么落**:响应形状不同的端点一定要在类型上区分开,别指望「都走同一个 helper」。
- **出处**:`emby.rs:711-715`。

### 7-4 「一处过滤」的反噬:横切逻辑必须 grep 一遍调用者

- 屏蔽功能的设计初衷是「一处顶十几处」(`blocklist.rs:6-11`)。但同一个决定同时制造了 7-1:
  `views` 也走 `fetch_items` → 屏蔽库后自己也解除不了。
- **教训**:加横切逻辑时必须 grep 一遍全部调用者,逐个判断它该不该被切。
- **另一处同类**:观看记录列表**只滤展示**,不动 Store 里的记录,也不动 `load_scope`/`load_all` 本身 ——
  跨服续播的匹配也读它们,在那儿滤会把「屏蔽」悄悄变成「顺便把进度也弄丢」。
  屏蔽是"别让我看见",不是"删掉"(`lib.rs:1934-1939`)。

### 7-5 屏蔽的三条判据缺一不可

- **真因**:① 卡片本身;② 它所属的剧(`series_id`)—— 屏蔽一部剧却在"继续观看"里看见它的分集,
  是用户第一眼就会发现的漏网;③ 剧名对上 —— 跨服的同一部剧 id 不同,只有名字对得上。
- **媒体库(CollectionFolder)另走一套 `is_blocked_id`,只按 id 判,且不能按名字判**:
  两台服务器上都叫「电影」的库是两个不同的库,按名字会一屏两台一起屏蔽(`blocklist.rs:131-136`)。
- **空名字永不命中**,否则一条脏数据能把整个库屏蔽掉(`blocklist.rs:126-129`)。
- **出处**:`blocklist.rs:105-129`;测试 `blocklist.rs:183-236`。
- **测试自身的教训**(`blocklist.rs:190-195`):`blocks_episodes_of_a_blocked_series` 第一版给了
  `series_name: Some(...)`,摘掉 `series_id` 那条判据**照样绿** —— 因为名字那条把它兜住了,
  这条护栏其实一个字节都没在守。必须给 `None` 才是真实的漏网形态。

### 7-6 版本正则「设了没反应」的四个真因(全在前端,核层单测照不到)

`ui/shared/regex-filters.check.mjs:1-27` 逐条列出:

1. 详情页无论用户有没有手动选版本,都把 `versions[0].id` 传给核层 `play()` ——
   核层看见 `media_source_id=Some(..)` 就走「手动优先」分支 → **版本正则从上线起一次都没跑过**;
2. 手机端「高级筛选规则」的保存按钮只改了 React state,**从没调 `set_track_regexes`** → 关掉面板就没了;
3. 起播后的 `apply_prefs` 只在 1.2s 打一枪,网络流那会儿 track-list 还没 demux 出内封轨
   → 字幕/音频正则匹配了个空表;
4. 详情页/播放器面板的「当前版本」写死回落列表第一条,而实际在播的是正则挑中的那条 ——
   **起播其实已经对了,界面却全程在说「在放第一条」**,用户据此判定「正则根本没生效」。
- **Go 侧怎么落**:核层给出 `preferred` 标记(`emby.rs:395-401`),前端只允许有**一个**算法
  `defaultVersion`(`ui/shared/api.ts:150-151`)。断言的落点必须是**发给核层的调用参数**,不是 UI 上有没有输入框。

### 7-7 「显示哪条」和「播哪条」必须是同一条

- **真因**:起播按正则挑了第二条,而详情页/播放器面板照样高亮第一条。
- **现在怎么处理**:`media_versions` 和 `resolve_stream` 打同一个 PlaybackInfo 端点、同一批 MediaSource、
  同一套 `source_match_text` + `pick_index`(`emby.rs:414-418`、`441-446`、`2145-2148`)。
- **出处**:测试 `emby.rs:2461-2491`(专门钉这两条路得出同一下标)。

### 7-8 Rust regex 与 JS RegExp 语法集不同

- **症状**:用户按浏览器 RegExp 的写法设了正则,存下了却永不命中,而且一声不吭。
- **真因**:Rust 的 `regex` crate 有线性时间保证,**不支持** `(?=)` `(?!)` `\1`;Dart 版用的是 JS 系正则。
- **现在怎么处理**:设置页的合法性校验**必须问 Rust**(`validate_track_regex`,`media.rs:52-59`;
  命令 `lib.rs:2999-3003`);非法正则一律**当作没设**回退默认行为,不崩(`media.rs:41-50`)。
- **Go 侧怎么落**:Go 的 `regexp` 是 RE2,**同样不支持前后瞻与反向引用** —— 这条约束天然对齐,
  但仍必须保留「校验走后端」这条链路,不能让前端用 JS RegExp 判合法。
  大小写不敏感在 Rust 是 `case_insensitive(true)`(`media.rs:49`),Go 侧要写成 `(?i)` 前缀。
- **出处**:`media.rs:10-13`;测试 `media.rs:194-209`(`(?=chi)` 必须**报错**而不是静默吞掉)。

### 7-9 选轨优先级:正则 > 语言,不是"正则能匹配"

- 优先级(对齐 wiki):**手动切过的轨 ＞ 正则命中 ＞ 首选语言/服务端默认**(手动那层在前端)(`media.rs:68-70`)。
- 匹配文本 = `title + lang + codec (+ "{n}ch")`(`media.rs:30-39`)。
- 版本的匹配文本是另一套(见 §3.4),两者**口径不同,别混**(`media.rs:6-8`)。
- `sub_enabled=false` 时直接返回 `Some("no")` 关字幕,不参与正则(`media.rs:83-87`)。
- 返回值三态:`Some(id)` 切到该轨 / `Some("no")` 关字幕 / `None` **保持不变**(`media.rs:80`)。
- **出处**:`media.rs:79-110`;测试 `media.rs:155-177`(故意让语言偏好指向另一条轨,
  哪天有人把正则挪到语言之后这条会红)。

### 7-10 `apply_prefs` 的时机:必须轮询,不能起播后拉一次

- **症状**:字幕/音频正则「设了没反应」;TV 端「字幕选项里没有外挂字幕」。
- **真因**:网络流的 demux 是渐进的,音轨常先于字幕出来;外挂字幕更晚(独立文件,
  核层要等 mpv 的 `FILE_LOADED` 才能 `sub-add`,慢服务器上是起播后好几秒的事)。
  在那之前的任何一次快照都是「没有字幕」。
- **现在怎么处理**:`pollTracks` 每 700ms 一轮、最多 20 轮(~14s),**轨表一变就重调一次 `apply_prefs`**;
  停止条件是轨数连续两次不变(`ui/shared/track-poll.ts:19-55`)。
  轨表稳定后循环自己会停,所以不会一直顶掉用户播放中手动切的轨(`track-poll.ts:41-42`)。
- **两端分叉是这个 bug 的成因**:这份逻辑原来只长在桌面 `App.tsx` 里,TV 端另写了一个残缺版(`track-poll.ts:14-15`)。
- **Go 侧怎么落**:这是宿主/UI 层逻辑,核层只提供 `pick_tracks`。但**轮询必须在共享层**,三端不许各写一份。

---

## 7(下). 踩坑清单:跨服续播、上报、其它

### 7-11 跨服匹配的判据靠三个 Fields,漏了会**静默降级**

- **症状**:跨服续播「看起来能用」,实际经常匹配不上,不报错。
- **真因**:`Item` 默认不带 `ProviderIds`/`PresentationUniqueKey`/`Path`,
  没有 TMDB id 就只能靠「剧名+季集号」猜,猜错不报错(`emby.rs:104-106`、`167-168`)。
  没带 Fields 的列表端点(`resume`/`latest`)取到的 `Item` 这三项就是 `None`(`watch_history.rs:238-242`)。
- **现在怎么处理**:凡是要参与匹配的取数点都拼上 `HISTORY_FIELDS`
  (`search` — `emby.rs:1305`;`similar` — `emby.rs:1334`;`item_for_history` — `emby.rs:1429`)。
  取不到就自动降级到「剧名+季集号」,**不崩**(`watch_history.rs:206-210`)。
- **Go 侧怎么落**:把这四个字段做成一个常量,别在 URL 里手抄(`emby.rs:1316`)。
  为「降级路径」写测试(`watch_history.rs:1820-1821` 那条回归)。

### 7-12 canonicalKey:跨服匹配的地基

优先级 **TMDB > PUK > 标题(+年份/季集号) > itemId**(`watch_history.rs:359-406`),形状固定:

```
movie:tmdb:{id}                     movie:puk:{puk}
movie:title:{归一标题}:year:{年|unknown}      movie:item:{itemId}
series:tmdb:{剧tmdb}:s{SS}:e{EE}    episode:tmdb:{集tmdb}:s{SS}:e{EE}
episode:puk:{puk}                   episode:title:{归一剧名}:s{SS}:e{EE}
episode:item:{itemId}
```

- 季集号**两位零填充**(`pad_index`,`watch_history.rs:355-357`)。
- 标题归一化:小写 → 去 `[..]` 和 `(..)` → 把非「字母数字汉字」折成空格 → 压空白
  (`normalize_text`,`watch_history.rs:324-335`;三个正则在 `watch_history.rs:311-322`,
  汉字区间是 `\u{4e00}-\u{9fff}`)。
- `normalize_path_stem` 与 Dart 的**一处有意差异**:两种路径分隔符都认(`/` 和 `\`)——
  记录里存的是**服务器端**路径,与客户端平台无关(`watch_history.rs:342-344`)。
  `.hidden`(点在首位)不算扩展名(`watch_history.rs:347-351`)。
- `scopeKey = "{server}:{user_id}"`;还原 server 必须按**最后一个**冒号切,
  因为 server 是 URL(自带 `https://` 甚至端口)(`watch_history.rs:416-430`)。

### 7-13 置信度:只有 strong/possible 可信

- 序 `None < Weak < Possible < Strong`,**派生的 `Ord` 依赖变体顺序,别调换**(`watch_history.rs:69-80`)。
- 跨服续播和回传两处都只认 `strong`/`possible`(`is_trusted`,`watch_history.rs:83-87`)。
- `unique_candidate=true`(候选池里只有它)会把 `weak` 提升成 `possible`(`watch_history.rs:503-505`)。
- `PresentationUniqueKey` 一致 = 同一台服务器上的同一条目,**无视其它一切直接 strong**(`watch_history.rs:519-526`)。
- `same_some`:两个 `Option` 都有值且相等才算匹配,**`None == None` 不算**(`watch_history.rs:536-539`)。
  这是最容易写错的一行 —— 两边都没 TMDB 时会互相"匹配上"。
- 匹配规则表:电影 `watch_history.rs:541-565`,剧集 `watch_history.rs:567-598`。
- `restore_action` 把不可信的匹配一律判 `Ignore`:**静默乱写别人条目的进度比不写糟得多**
  (`watch_history_sync.rs:82-92`;测试 `watch_history_sync.rs:549-568`)。

### 7-14 续播位置 = 取最大值,但「已看完」优先级更高

`resolve_resume_position_ticks`(`watch_history.rs:767-812`):

1. **远端 `played=true` → 直接返回 None**,连本地记录都不看(`watch_history.rs:781-783`);
2. 本服本地记录 `played` → 只信远端(避免跨服记录覆盖用户在本服的「已看完」)(`watch_history.rs:793-795`);
3. 否则取 `远端进度 ∪ 本服记录 ∪ (开关打开时) 其它服务器记录` 的**最大值**;
4. 进度 `<=0` 视为「没有进度」(None,不是 `Some(0)`),有时长则夹到时长内(`watch_history.rs:969-976`)。

跨服扫描跳过 `record.played` 或 `last_position_ticks<=0` 的记录(`watch_history.rs:830-833`)。

### 7-15 进度写盘节流 10s,但收尾必须 force

- 播放期每秒都可能调 `capture_playback`,同一条记录 10s 内重复调直接返回既有记录不落盘
  (`watch_history.rs:852-855`、`926-931`)。`force` / `increment_play_count` 例外。
- **`stop_playback` 必须 `force=true`**,否则看一半退出这段就丢了(`lib.rs:2186-2188`)。

### 7-16 canonicalKey 变了要删旧记录

- 这次终于查到 TMDB id → key 变 → 不删旧的就是**一份内容两条记录**(`watch_history.rs:922-928`)。
- 节流表里的旧 key 也要一起 remove(`watch_history.rs:929-935`)。

### 7-17 回传:必须按整个 scope 配对,不能只按 server

- **与 Dart 的一处有意差异**:Dart 只按 serverId 找服务器,再拿该服**当前配置的** userId 发请求 ——
  换过登录用户就会把进度写到别人账号上。这里按整个 scope(server+user)配对,
  配不上的进 `skipped` 而不是静默丢弃(`watch_history_sync.rs:140-143`、`170-176`)。
- 每台服务器最多一条目标,取该服最近看的那条(`writeback_targets`,`watch_history.rs:1102-1113`)。
- 会话内去重键 = `{server}|{itemId}|{played}|{进度分钟桶}`(`watch_history.rs:1140-1146`)。
- **去重集按「一次播放」计生命周期**:不清的话,看完第二集时第一集的去重键还在,
  同一台服务器会被判成"已回传过"而跳过 —— 静默漏传(`lib.rs:1830-1832` 上方 `lib.rs:1831`)。
- 单台失败不毁整轮,但必须进 `report.errors` 看得见(`watch_history_sync.rs:484-486`)。
  这个模块**最危险的 bug 是「不崩,只是悄悄少恢复了几条」**(`watch_history_sync.rs:41-43`)。

### 7-18 恢复扫描:先试旧 itemId,再搜

- `MAX_SCAN_RECORDS = 15`(`watch_history.rs:23-24`)。
- 顺序:`last_emby_item_id` 取详情 → 匹配(`unique=true`)→ none 才改走搜索(`watch_history_sync.rs:366-395`)。
  条目被删/换库很正常 → **不算错**,但要留痕,免得整轮静默变空(`watch_history_sync.rs:390-391`)。
- 搜索结果**先按类型过滤 + 取前 10 再查 TMDB** —— 否则 50 条结果就是 50 个请求;
  这一步与 `pick_restore_candidate` 内部的 filter/take **同规则,所以下标对得上**(`watch_history_sync.rs:405-407`)。
- 挑候选规则(逐字对齐 Dart):恰好 1 个 strong → 选它;**多个 strong → 放弃**(分不清);
  非 strong 且只剩 1 个 → 用 `unique=true` 重算后选它;否则放弃(`watch_history.rs:1039-1082`)。
- 剧的 TMDB id 按 `series_id` 缓存,**含负缓存**(查过但没有),别对没刮削的剧反复打服务器
  (`watch_history_sync.rs:225-242`;宿主侧 `lib.rs:1826-1836`)。

### 7-19 起播时两条路必须并发,但并发的前提是"不跨 await 持锁"

- `build_wh_ctx` 与 `resolve_stream` 互不依赖,曾经串着 await,白白多等 1~2 个 RTT
  (远程 Emby 每个 100~300ms)才轮到 mpv loadfile(`lib.rs:1638-1650`)。
- **能 `join!` 的前提**:这两条路上没有跨 await 持有的锁。
  `join!` 把两个 future 放同一线程轮询,一方持锁 await、另一方去抢同一把锁 = 自我死锁,
  症状是起播直接吊死、不报错(`lib.rs:1643-1647`)。
  所以版本正则要在 `await` 之前从 config 取出来(`lib.rs:1651-1653`)。
- **Go 侧怎么落**:goroutine + WaitGroup 天然没有这个问题,但「先把配置读出来再进并发」的习惯要保留。

### 7-20 管理动作:三个名字,两个端点,参数写反会覆盖用户数据

| UI 名字 | 真实端点 | 模式 |
|---|---|---|
| 刷新媒体库 | `POST /Items/{id}/Refresh` | `Default`(只补缺失) |
| 扫描媒体库 | `POST /Library/Refresh` | 整台服务器找新文件 |
| 刷新元数据 | `POST /Items/{id}/Refresh` | `FullRefresh` + `ReplaceAllMetadata=true` |

- 前两项**不是**一回事:一个作用于选中的库/条目,一个作用于整台服务器(`emby.rs:934-940`)。
- `Recursive=true` 必带:对库卡片来说不递归等于什么都没做(库本身没有元数据可刮)(`emby.rs:968-970`)。
- **`ReplaceAllImages` 恒 false**:用户自己换过的封面不该被一次「刷新元数据」抹掉(`emby.rs:970`)。
- 参数写反的话「刷新媒体库」会覆盖用户改过的元数据,而界面上只写着「刷新」(测试 `emby.rs:2377-2396`)。

### 7-21 管理员判定不能从登录响应取

- **真因**:配置里存下来的老账号根本不会再走一次 login,那样升级后老账号会**永远判成非管理员**
  (菜单静默不出现,还以为是权限没给)(`emby.rs:941-945`)。
- **现在怎么处理**:每次现打 `GET /Users/{uid}` 读 `Policy.IsAdministrator`;
  **缺 Policy / 缺字段一律判否**,宁可少给按钮(`emby.rs:960-968`;测试 `emby.rs:2365-2379`)。

### 7-22 章节:两个功能一次请求,且都必须能静默不工作

- 「跳过片头/片尾」和「进度条缩略图预览」共用同一份 `Fields=Chapters` 数据(`emby.rs:1795-1806`)。
- 三条现实边界:章节是**服务端**生成的,没刮削过 → 空表 → 两个功能都自动静默不工作;
  章节图要服务端开了「章节图片提取」才有 `ImageTag`;片头识别靠**章节名**,认不出就不跳。
- **短词必须整词匹配**:`op`/`ed` 用 `contains` 会把 "Opera"、"Stop Motion"、"Wedding" 当成片头,
  **把正片开头切掉** —— 这是本功能最贵的一类误伤(`emby.rs:1866-1881`;测试 `emby.rs:2549-2572`)。
- 片头只在**前 40%** 里找(有些剧集把片尾曲也叫 "OP"),且时长 >5 分钟判为误命名的正片章节(`emby.rs:1900-1928`)。
- 片尾只在**后 25%** 里找,且**只有片尾后面还有内容(下集预告)时才返回 Some** ——
  片尾是最后一个章节的话,跳过去等于把这一集直接结束掉,那是另一件事(`emby.rs:1930-1945`)。
  落点太贴近结尾(<5s)也当没内容。
- 判定放核层不放前端:前端那份总时长在 500ms 轮询的闭包里会过期,拿旧值去判迟早判错,
  而**错的方式是误跳**,最难受的那种(`emby.rs:1936-1938`)。

### 7-23 `Episode.Name` 只有「第 N 集」

- 剧名单独在 `SeriesName`;继续观看/收藏/搜索等混排列表必须靠它才说得清是哪部剧(`emby.rs:143-146`)。
- 电影没有 `SeriesName`,**不该冒出空串**(前端靠 null 判断要不要拼前缀)——
  代码用 `.filter(|s| !s.is_empty())` 归一(`emby.rs:216`;测试 `emby.rs:2627-2634`)。
- `/Shows/NextUp` 返回的是 Episode,同样靠 `SeriesName` 才认得出(`emby.rs:1465`)。

### 7-24 手机端详情页不能全量拉分集

- 实测某服务器上最长的剧 2648 集:全量拉 **1813.9KB / 1841ms**,分页 30 条 **20.0KB / 435ms**。
  `content-visibility` 只省渲染,省不掉这 1.8MB 的下载和解析(`emby.rs:766-773`)。
- 桌面/TV 传 `with_children=true`,手机传 `false` 走 `season_episodes` 分页(`emby.rs:765-770`)。
- **有些剧没有季**(单季番剧直接挂集):`seasons()` 返回空 Vec,调用方必须回落到
  「拿 seriesId 当 parent 直接分页拉集」,不回落的表现是"点进去一集都没有"且不报错(`emby.rs:1030-1034`)。
- 季名**必须用服务器返回的 `Name`,不要自己拼「第 N 季」**:实测真名是 "全 1 季" / "果宝特攻2" /
  "怪奇物语 4",自己拼在真机上对不上(`emby.rs:1013-1016`)。

### 7-25 插件的 `emby.apiRequest` 必须防 SSRF

- 解析后的 URL 必须仍指向同一 scheme+host+port,否则拒绝 —— 避免 `X-Emby-Token` 外泄
  (`apps/desktop/src/plugins_host.rs:128-136`)。
- 权限分两档:`emby.read`(不危险)与 `emby.api`(危险)(`crates/core/src/plugins/permission.rs:27-30`)。
- `emby.credentials` 权限**已被删除**,宿主不再持久化明文密码给插件(`permission.rs:44-47`)。

---

## 8. Go 侧移植要点

### 8.1 直译还是重写

| 部分 | 结论 | 理由 |
|---|---|---|
| URL 拼装、Fields、参数分隔符 | **逐字节直译** | 每个字符都被真实服务器验过,改一个字就静默退化 |
| 绕 fork 的分支(§6 全部) | **逐条直译** | 删任何一条 = 某台服务器上功能静默失灵 |
| `source_match_text` / `pick_index` | **逐字节直译** | 它是用户正则的输入,变一个空格就有人的正则失效 |
| canonicalKey / normalize_* | **逐字节直译** | 它是**磁盘上已有数据的键**,变了 = 全体用户历史记录对不上 |
| 上报三件套 body | **逐字段直译**(含三处差异) | §5 |
| 两份 DV 判定 | **合成一份**,行为不变 | `emby.rs:325-345` 与 `emby.rs:2156-2173` 目前重复 |
| `RawItem`/`RawMediaSource` 模型 | **一个 JSON 对象只建一份模型** | 两份模型正是 DV 判不出的根因(`emby.rs:249-252`) |
| 图片缓存/闸/超时 | 重写(Go 有更自然的写法) | 但 6 并发、20s 超时、缓存键三条纪律要保留(§4.5/§4.6) |

### 8.2 需要什么库

**只需要标准库**:`net/http` + `encoding/json` + `net/url` + `regexp` + `strings`。
理由:`crates/core/Cargo.toml` 里 emby 这条路上用到的第三方只有 `reqwest`(HTTP)、
`serde/serde_json`(JSON)、`urlencoding`(转义)、`regex`(正则),Go 标准库全覆盖。
不需要 SDK,不需要 ORM,不需要第三方 HTTP 库。

配套要点:
- **压缩**:Go 的 `http.Transport` 默认对 `Accept-Encoding: gzip` 自动协商并解压。
  但**预取那条路必须显式关掉**(`DisableCompression: true`),理由见 §1.7 / `http.rs:246-250`。
- **重定向**:Go 默认最多跟 10 跳,与 reqwest 一致 —— 图片那条路**依赖**这个行为(§4.4)。
- **TLS**:自签名放行必须按 **host 白名单**做在 `tls.Config.VerifyPeerCertificate` 里,
  **绝不能全局 `InsecureSkipVerify`** —— 那等于把公网所有 HTTPS 的中间人防护一起关了且不报错
  (`http.rs:90-99` 记录的正是这个历史错误)。
- **代理**:`Proxy` 函数里必须把回环(`localhost`/`127.*`/`::1`)排除 ——
  否则用户一开代理就把本地 CF 反代/预取代理打死(`http.rs:63-88`)。

### 8.3 必须逐字节对账的清单

1. **URL 转义**:`strings.ReplaceAll(url.QueryEscape(s), "+", "%20")`,不能直接用 `QueryEscape`(§2.6)。
2. **`source_match_text` 的拼接顺序与空格**:`Name Container [DisplayTitle Codec Profile VideoRange VideoRangeType "{h} {h}p" ("4K"|"8K")]`,
   空串要 `retain` 掉再 `join(" ")`(`emby.rs:2050-2075`)。
3. **`subtitle_path` 的字节**:`/Videos/{item}/{msid}/Subtitles/{idx}/0/Stream.{ext}?api_key={token}`
   —— 少 `/0` 或用 codec 当扩展名都 404(测试 `emby.rs:2493-2500`)。
4. **canonicalKey 全部 7 种形状 + 两位零填充**(§7-12)。
5. **`normalize_text` 的三步与汉字区间** `[^a-z0-9\x{4e00}-\x{9fff}]+`(`watch_history.rs:319-322`)。
   Go 正则写 `\x{4e00}` 而非 `\u{4e00}`。
6. **上报三件套的字段集合**(§5),尤其 stopped 少两个字段。
7. **`refresh_url` 的六个参数**(`emby.rs:983-989`)。
8. **`Item` 的空串→null 归一**:`series_name`/`presentation_unique_key`/`path`/`series_id`/`date_updated`/`sort_name`
   全部 `filter(|s| !s.is_empty())`(`emby.rs:216`、`223-227`);
   `video_range`/`video_range_type` 还要额外剔除字面量 `"Unknown"`(`emby.rs:373-374`)。

### 8.4 并发

- **图片**:6 路信号量 + 20s 超时,缓存命中不占名额(§4.6)。
- **分面**:5 路并行各自吞错(`emby.rs:1646-1653`)。
- **年份探针**:2 路并行(`emby.rs:1707`)。
- **首页**:`counts` 与 `resume` 并行(`lib.rs:615`)。
- **聚合搜索**:每台服务器一个 goroutine,**单台失败隔离**(`lib.rs:498-548`)。
  跨服元数据请求**不加并发上限**(元数据本轻),靠取消令牌离页杀请求。
- **恢复扫描 / 回传**:代码里标了 `ponytail:` 明说是**逐条串行**(与 Dart 一致),
  15 条 × 数个请求后台跑得起;要改并发,`series_tmdb` 缓存得换成共享的(`watch_history_sync.rs:250-252`、`420-422`)。
- **写盘串行**:`watch_history.json` 和 `blocklist.json` 的所有写都是「读-改-写」,
  必须整段串行,否则两次并发写互相吃掉对方的记录(`watch_history.rs:619-621`、`blocklist.rs:49-53`)。

### 8.5 分层纪律(照搬)

- 纯逻辑(匹配/挑候选/该不该回写/去重键)全在 `watch_history.rs`,**已单测**;
  需要 HTTP 的那层只回答三个问题:**打哪些请求 / 打给谁 / 失败了算什么**(`watch_history_sync.rs:5-12`)。
- 核层**不读全局配置、不碰存盘路径**:session/scope/开关全从参数进来(`watch_history_sync.rs:12-13`)。
- `views(include_blocked)` 这种「该不该过滤」的决定属于**命令层**,不属于数据层(§7-1)。

---

## 9. 现有测试的价值

`emby.rs` 有 28 个 `#[test]`(1 个是 `#[tokio::test]`)。分三档:

### 真门禁(改坏必红,且钉的是真实故障)

| 测试 | 钉住什么 | 行号 |
|---|---|---|
| `range_probe_only_switches_prefix_when_it_actually_helps` | 前缀探测的四种组合 + 不叠加。注释里写了**三条反向注入方法** | `2337-2363` |
| `search_term_must_be_capitalized` | 大写 `SearchTerm` + 默认含 Episode + 全局搜索不带 ParentId | `2771-2800` |
| `explicit_types_are_enforced_client_side_too` | **连调用点一起钉**:用 `include_str!` 读自身源码断言 `search` 里真的调了 `filter_types` | `2802-2838` |
| `library_scoped_search_pins_parent_id` | 库内搜索必带 ParentId + Recursive;空串不拼 | `2840-2858` |
| `views_never_applies_the_blocklist` | **走真 HTTP** 起本地服务器扮演 `/Views`,断言原样返回 | `2864-2921` |
| `subtitle_fallback_path_matches_real_server` | 兜底字幕路径与真服 DeliveryUrl 字节一致 | `2493-2500` |
| `playback_info_keeps_media_streams_for_dolby_check` | MediaStreams 与 DirectStreamUrl 都不能在合并模型时丢 | `2397-2421` |
| `preferred_marks_the_same_source_resolve_stream_would_pick` | 「显示哪条」= 「播哪条」 | `2461-2491` |
| `version_regex_matches_wiki_examples` | wiki 四类写法 + **单独一条只写 `4K`** 钉别名 | `2422-2459` |
| `hdr10_is_not_mistaken_for_dolby_vision` | HDR10 ≠ DV,codec/profile 兜底,音频轨不参与 | `2524-2549` |
| `intro_detection_does_not_eat_the_feature` / `intro_range_rejects_late_and_overlong_matches` | 整词匹配 + 前 40%/后 25% 闸 + 片尾后无内容不跳 | `2549-2589` |
| `refresh_modes_do_not_swap` | 两个模式的六个参数不许写反 | `2377-2396` |
| `admin_flag_defaults_to_no_when_unknown` | 缺 Policy/缺字段必须判否 | `2365-2379` |
| `local_filter_rejects_non_matching_items` / `empty_filter_vecs_are_not_filters` | 客户端复筛真能挡 + 空 vec 不算筛选 | `2699-2742` |

`blocklist.rs` 的 6 条同属真门禁,尤其 `blocks_episodes_of_a_blocked_series`(`184-200`)——
它的注释记录了「第一版测试其实一个字节都没在守」的教训(§7-5)。
`media.rs` 的 `regex_beats_lang`(`155-177`)钉的是**优先级**而不是"能匹配",也是真门禁。

### 载荷回归(值,但只测解析)

`episode_carries_series_name`(`2609-2625`)、`page_total_is_independent_of_page_len`(`2638-2653`)、
`played_flag_flows_through_funnel`(`2662-2674`)、`unplayed_count_flows_through_funnel`(`2685-2699`)、
`missing_user_data_defaults_to_unplayed`(`2674-2685`)、`movie_has_no_series_name`(`2627-2634`)、
`parses_public_server_info`(`2742-2757`)、`parses_genre_facet_with_numeric_ids`(`2757-2771`)、
`chapter_image_url_is_authenticated_and_optional`(`2590-2608`)。
**载荷全部来自真机实抓**(注释里写了日期),Go 版可以**直接把这些 JSON 字面量搬过去**当 golden。

### 摆设 / 价值有限

- `limit_is_clamped_to_server_cap`(`2654-2661`):它断言的是 `Option::unwrap_or(200).min(200)` 这个
  **表达式本身**,而不是 `items()` 里真的这么写了。把 `items()` 改成别的,这条照样绿。
- `year_range_is_descending_and_inclusive`(`2859-2864`):断言的是 `(1922..=2026).rev()` 这个
  Rust 迭代器,与 `year_range()` 函数无关。
- `chapter_image_url_is_authenticated_and_optional` 的名字说的是 URL,实际只断言了
  `ImageTag` 的解析和 ticks 换算,**没有一条断言碰到那个 URL 字符串**(`2594-2608`)。

**Go 侧结论**:上面「真门禁」那一栏必须先在 Go 里复现一遍并**反向注入验证它会红**,
再谈移植完成;「摆设」那三条不要照抄,要重写成对函数本身的断言。

---

## 10. 已知未解决 / 存疑

1. **服务器B 上的库内搜索做不到**。代码明确承认:没有任何服务端参数能收窄,
   客户端要么全量拉库(每敲一键拉一遍整个库),要么就是搜不准(`emby.rs:1299-1303`)。Go 版不会变好。
2. **筛选复筛只覆盖当前页**。3276 条的库筛「喜剧」只得到前 200 条里的喜剧;
   要完整结果需服务端支持,或改成翻页累加(17 次请求)(`emby.rs:632-635`)。
3. **年份分面是猜的**。区间里可能混入该库没有的年份,选了就是空结果(`emby.rs:1699-1701`)。
4. **`tags` 无法在客户端复筛**:`Item` 不带 `Tags` 字段(`emby.rs:598-600`)。要修得先给 `Item` 加字段。
5. **DV 判定逻辑有两份**(`emby.rs:325-345` 与 `emby.rs:2156-2173`),目前行为一致但没有测试钉住"两份一致"。
6. **`Item` 没有 `has_logo` 标志位**,前端只能靠 `<img onError>` 兜底回文字标题(`ui/shared/api.ts:1966-1969`)。
7. **插件 `emby.apiRequest` 用的是 `account.server`(账号主键)而非 `active_line_url()`**
   (`plugins_host.rs:105-119`)——与 §1.6 定的口径不一致。**未确认**这是有意还是遗漏:
   查了 `plugins_host.rs` 全文和 `permission.rs`,没有解释这一选择的注释。
8. **没有 401 自动重登链路**。`emby.rs` 里对 Emby 本体的 401 不做任何特殊处理,
   只有账号列表页的三态探测会显示"需重登"(`lib.rs:1069-1076`),用户得自己去点重新登录。
9. **`ranking.rs` 与 Emby 无关**。全文 `grep emby|Emby|Items|Users/` 零命中 ——
   它是弹弹Play + TMDB 双源排行榜(`ranking.rs:1-6`),本文不涉及。
10. **`server_batch.rs` 与 Emby 的接触面只有一处**:`build_icon_url`(`server_batch.rs:305-318`)。
    其余是分享文本解析和深链,与 Emby 协议无关。
11. **`X-Emby-Authorization` 只发给 7 个端点**这件事,代码里没有任何注释解释为什么是这 7 个。
    **未确认**是有意设计还是历史累积;查了 `emby.rs` 全文注释与 `git log` 未覆盖的范围,没有依据。
    Go 版建议**先原样照搬**,想统一发要在真机 A/B 验证过再改。
