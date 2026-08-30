# 网盘 / 局域网源 / 资源站 / 登录逆向 / 凭据

**这个领域最容易踩的坑:**
1. **二手情报说「这家没有逆向登录」要亲自扒官网 JS 验**(139 就是这么攻下来的);调研 agent 给的算法/协议结论也可能是错的(曲线写成 P-256、拿 `strings` 判协议支持)。
2. **一次性 `refresh_token` 刷新后必须回写落盘**,否则「用得好好的重启就要重新授权」且不报错。
3. **`SourceKind` 线上值全小写**,前端写成首字母大写会每处比较恒 false 且两边都不报错。
4. **只判 `current_session` 会把网盘用户永远挡在门外** —— 它滤掉了文件浏览型账号。
5. **观察和推理冲突时先打真接口**(夸克的 `qr_data` 是 PNG 图不是待编码文本)。

> 本文件共 **9** 条。每条都标了它的原记忆文件名与类型;正文按原样搬运,未做压缩或改写。

## 本页条目

- File-browse sources — `file-browse-sources.md`
- 网盘源架构(2026-07-24大改+登录扩容) — `netdisk-sources-via-oplist.md`
- 凭据轮换回写 — `credential-rotation-writeback.md`
- 夸克二维码是图不是文本 — `quark-qr-is-an-image.md`
- 飞牛影视源 — `feiniu-trimemedia-source.md`
- 本地播放 + 局域网源 — `lan-sources-smb-webdav-ftp.md`
- Stremio 插件协议源 — `stremio-addon-source.md`
- SourceKind 线上是小写 — `sourcekind-wire-is-lowercase.md`
- 首登闸口+源表单共用 — `login-gate-and-source-forms.md`

---

### File-browse sources

> 原记忆:`file-browse-sources.md` · 类型:`project`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

新增「文件浏览型源」模式,与 Emby 并存。统一进现有服务器列表,按 `ServerConfig.sourceKind`
(emby/openlist/quark/anirss)分流:Emby→原首页,网盘类→文件浏览页。

**核心层 `lib/core/sources/`**:
- `MediaSourceBackend`(media_source_backend.dart):抽象 listDir/search/resolvePlay;模型 SourceEntry/ResolvedPlay/SourceException。
- `SourceKind`(source_kind.dart,单独成文件避免与 server_providers 循环 import)。ServerConfig 加了 `sourceKind` 字段(序列化向后兼容,缺省 emby)。
- 后端:openlist_backend(账密→token,/api/fs/list,/api/fs/get raw_url)、quark_backend(双模式:Cookie 网页 API drive.quark.cn 或 扫码 TV-API open-api-drive.quark.cn,按附加凭据 refresh_token 分流;转码 play 回退 download;Cookie 模式 __puus 轮换)、quark_tv(TV OAuth 设备码扫码:/oauth/authorize→轮询 /oauth/code→codeApi(api.extscreen.com)/token 兑换+x-pan-token 签名,参考 OpenList quark_uc_tv)、quark_qr_login(扫码状态机)、anirss_backend(见下)。

**Ani-rss 端点以官方 OpenAPI 为准(只有夸克才是逆向),但 `api-docs.json` 含实例 IP(<实例 IP:端口>)已从仓库删除+gitignore(api-docs.json/Swagger UI.html/Swagger UI_files/)。**已用 git-filter-repo 改写全history抹除该文件并 force-push main+security-hardening-batch2(改前备份 bundle 在 scratchpad)**;但 GitHub 残留:旧 commit c09776d 仍被 `refs/pull/36|37/head`(只读不可删)钉住→直链 SHA 仍能取到该 blob,**要彻底清除须联系 GitHub Support GC,且 IP 应视为已泄露(换 IP/防火墙白名单才是根治)**。** 鉴权易错点(**鉴权以服务端源码 ani-rss `AuthUtil`/`Header`/`Form`/`ApiKey` 为准,swagger 的 securityScheme `api-key` 会误导**):① `Login.password` 先取 **MD5 摘要**(32 位小写 hex)再 POST;② 登录返回的令牌=`sha256(json(login))`,**校验走 `Authorization: <token>` 请求头(Header 鉴权)或 `s=<token>` 查询参数(Form 鉴权,用于流/图片 URL 等无法带 header 的场景)。swagger 里的 `api-key` 头是另一套「静态 Config.apiKey」鉴权,我们没那个 key,塞登录令牌进 `api-key` 头会恒判失败→服务端返回 `{code:403,message:'登录已失效'}`(这正是「登录了却说登录失效」的根因,已修)**;③ `PlayItem.filename` 本身就是「路径+文件名」的 base64,取流 `GET /api/file?filename=` 直接用、**勿二次 base64**;④ `proxyImage` 的 `imgUrl` 服务端会 **Base64 解码**,故须先 base64 编码原图地址再传(且鉴权用 `s=` 而非 api-key)。`AniRssAuth.header='Authorization'`、`AniRssAuth.queryAuthKey='s'`。浏览:`POST /api/login`(ResultString=token)→ `POST /api/listAni`(data=ListAni{weekList:[{items:Ani[]}]},取 Ani.image 做封面、cover 是服务端本地路径不可取)列番剧当文件夹 → `POST /api/playList`(body=Ani,回 PlayItem[],含 episode 排序 + subtitles[] 随列表返回不必再调 getSubtitles)列剧集 → /api/file 取流(api-key 走 header 主、URL query 兜底)。深度适配可用的端点还有 proxyImage/torrentsInfos/addAni·setAni·deleteAni/refreshAll/searchBgm·mikan/calendar.ics/config·about 等(swagger 一应俱全)。
- **夸克 TV 扫码二维码不显示的坑(已修)**:`/oauth/authorize` 返回的 `qr_data` **不是待编码文本,而是二维码 PNG 图片的 base64**(裸 base64,`iVBOR...` PNG 签名;实测 ~4868 字符)。原先喂给 `QrImageView(data:)` 去再编码→超 QR 容量→渲染失败二维码不出现。修法:`quark_qr_login_view.dart` 改为检测图片签名(PNG/JPEG/GIF,含 data URI 前缀)→`Image.memory(base64Decode(...))` 直接显示,仅当确是普通文本/URL 才回退 `QrImageView`。三端共用此 view,故三端同修。
- source_registry(选择器描述表 kSourceTypes + 工厂 mediaSourceBackendFor)、source_login_service(登录构造 ServerConfig)、source_credentials(SecureCredentialStore KV 存附加凭据)、source_browse_controller(UI 无关的目录栈/搜索状态机,三端共用)。

**播放器逐流 headers(关键补强)**:VideoPlayerService.initialize 加了 `httpHeaders`/`userAgentOverride`,透传三个适配器:
media_kit mpv 用 `http-header-fields` 属性;native mpv 经 MethodChannel→Kotlin MpvPlayerPlugin.setMpvOptions 设 `http-header-fields`(已加);ExoPlayer 通道已传但 Kotlin 侧未消费(OpenList/Ani-rss 把鉴权放 URL 不需要 header,夸克走 native mpv)。

**播放页复用(2026-06 重构,已删 SourcePlayerScreen)**:直链播放不再用残血专属页,改为**复用各端完整 PlayerScreen/DesktopPlayerScreen/TvPlayerScreen**(弹幕/字幕/手势/倍速/比例/续播全部继承)。载荷 `SourcePlayback`(lib/core/sources/source_playback.dart:server+entry+qualityId)经 go_router `extra` 注入,三端 `/source-player`·`/tv/source-player` 路由直接构建真播放页(传 itemId=`src:serverId:entryId` 合成串 + sourcePlay)。各端 `_initializePlayer` 顶部判 `widget.sourcePlay!=null` → 走 `_initializeSourcePlayer`(backend.resolvePlay 取 URL+headers+UA → VideoPlayerService.initialize,跳过 Emby PlaybackInfo;无续播/无 Emby 上报,与旧残血页行为一致)。夸克 302 短效靠 streamUrlResolver 按当前选中清晰度重解析。

**三端 UI**:选择器(带搜索)/登录页/浏览页各三套;桌面/TV 浏览页嵌入首页壳(DesktopHomeScreen/TvHomeScreen 按 isFileBrowse 分支),移动用 /browse 路由。添加入口改为先进选择器。

**Ani-rss 深度适配(已做,三端)**:sourceKind==anirss 不再走泛用浏览,而是专属 3-Tab 迷你应用(首页海报墙/订阅+下载进度/设置)。注入点都在 isFileBrowse 分支「之前」加 `sourceKind==anirss` 前置分支(移动:`/browse` 路由内 Consumer 分流 AniRssShellScreen;桌面 desktop_home_screen;TV tv_home_screen)。**数据层 `lib/core/sources/anirss/`(三端共用)**:AniRssAuth(从 anirss_backend 抽出的共享 token 生命周期,播放后端与类型化 API 共用一份缓存)、AniRssApi(类型化全端点)、models/*(AniModel **内部存原始 Map 无损回传** addAni/setAni,getter 暴露 UI 字段;TmdbModel/PlayItemModel/TorrentInfoModel/BgmInfoModel/ConfigModel/AboutModel)、anirss_match(torrent→订阅→集数 关联:标签>目录>标题模糊 三层启发式+集号正则,纯函数,test/anirss_match_test.dart 12 例)、anirss_providers(aniList/torrents(3s轮询StreamProvider)/aniDetail(family by AniModel,按 id 值相等)/aniConfig/aniAbout/configDraft)、anirss_config_spec(设置页声明式字段表,未 spec 的 key 原样保留+「高级原始」区兜底)。详情页元数据**优先用 listAni 已带的 Ani.tmdb+score**,TMDB 图走 `AniRssApi.buildProxyImageUrl`(经 ani-rss 服务端代理,免用户 TMDB Key)+ image.tmdb.org 直链兜底。剧/影按 tmdbType==MOVIE||ova 判定。版本选择=同集多 PlayItem(字幕组/清晰度),选中构造 SourceEntry 走 resolvePlay→SourcePlayerScreen(移动/桌面 `/source-player`;**TV 只有 `/tv/source-player`**,详情页用本地 _playTv 推)。getThemoviedbGroup 返回的是剧集「组」非逐集名/剧照,详情页剧集名退回「第N集」。共享控件在 lib/ui/widgets/anirss/(ani_poster_card/anirss_version_picker/config_form,桌面复用 Material 版,TV 自建焦点版)。flutter analyze 全树仅剩既有技术债(native_mpv 等),anirss 新代码 0 issue。

**深度适配第二轮(2026-06,已提交 main,flutter analyze 0 error)**:
- **播放页复用**:删 SourcePlayerScreen,三源直链改用完整 PlayerScreen(见上「播放页复用」)。
- **夸克**:`resolvePlay({qualityId})` 解析转码多档清晰度(low/normal/high/super/2k/4k→流畅/标清/高清/超清/2K/4K,_quarkQualityMeta 排序),**默认选最高档**(修「默认最低」);播放页内 `SourceQualityButton`(lib/ui/widgets/common/,三端,sourcePlayQualitiesProvider/sourceSelectedQualityProvider,切档=记进度重 init 续播);Cookie 模式列目录补 thumbUrl(字段 `thumbnail`/`big_thumbnail`,**逆向猜测,需真号验证**)。
- **源感知重登**(server_list_screen `_relogin`):夸克→扫码(QuarkQrLogin.existingServerId 凭据写回同一 server,**不再弹账密**)、OpenList/Ani-rss→各自后端账密更新同 server、Emby→原样;扫码源无 authToken 也视为已认证(修误判未登录)。
- **浏览(夸克/OpenList 共用,三端)**:文件名完整显示(移动 3 行/桌面·TV 2 行);条形列表⇄封面网格切换(sourceBrowseGridProvider,视频缩略图展示封面);排序名称/大小(sourceBrowseSortProvider+sortSourceEntries);共享 formatSourceFileSize。
- **Ani-rss PC 订阅界面对标原版(2026-06,已提交 main,0 error/warning)**:拉 `wushuo894/ani-rss` 网页源码(Vue3+ElementPlus,`ani-rss-ui/src/home/`)对照。原版订阅模型=每个 Ani 一张横向海报卡(`AniCard.vue`:海报92×130+标签 季/启用/字幕组/cur·total/ova·tv+编辑·删除·playlist),编辑走 `Ani.vue` 两 Tab 表单(基本/自定义)。LinPlayer 落地:① 新增 `lib/desktop/widgets/anirss/desktop_anirss_edit_dialog.dart`(`showDesktopAniRssEditDialog`,Dialog+TabBar 两 Tab 复刻 Ani.vue 全字段;匹配/排除用 `_RegexTagEditor` 标签编辑;TMDB 解析 getThemoviedbName;下载路径 downloadPath 预览;previewAni 预览匹配剧集;刮削;确定=setAni/addAni;`isAdd` 复用同表单)。② 桌面订阅页 `desktop_anirss_subscriptions_tab.dart` 重做为海报卡 SliverGrid(maxCrossAxisExtent 440/mainAxisExtent 176)+顶栏搜索框,卡内内联下载进度(LinPlayer 增值)。**2026-06 二轮(用户反馈「订阅界面没变」)**:对标原版 `List.vue` 的 `weekList` 分组——默认**按周分组**(星期一…星期日+未排期,顶栏 SegmentedButton 可切「平铺」);`AniModel` 新增 `week`(1-7)/`lastDownloadTime`/`hasStandbyRss` getter;卡片补 BGM 评分(粉 0xFFE800A4)+字幕组缺省「未知字幕组」+「备用RSS」标签,贴近 AniCard.vue。(commit fd613b9)③ **数据损坏修复**:`match`/`exclude` 服务端是**字符串数组**(见 ani.js aniData 默认值),旧 mobile 编辑面板按一行字符串读写会污染→改 `_listText`/`_parseList` 按行/逗号拆为 List。**移动端订阅页仍用简版 `anirss_edit_subscription_sheet`(bottom sheet),TV 未做——用户要求「先把 PC 端做好」。** API 全有:setAni/addAni/deleteAni/refreshAni/refreshAll/batchEnable/previewAni/downloadPath/getBgmTitle/getThemoviedbName/refreshCover/scrape/batchScrape/playList/getThemoviedbGroup/searchBgm。
- **Ani-rss**:海报墙入场动效改 `entranceOnce`(按 id 记 seen,回滑不再重复渐显,三端 home tab 改 Stateful);首页海报放大约 50%;新增订阅**编辑**面板 anirss_edit_subscription_sheet(标题/季/总集数/集数偏移/字幕组/包含·排除/全局排除/自定义下载位置/OVA/启用/BGM,setAni 回写),SubscriptionTile 加可选 onEdit,移动+桌面订阅页接入(TV 订阅页用自建 _SubscriptionRow 未接)。**ResolvedPlay 增 qualities/selectedQualityId,resolvePlay 增可选 qualityId(非破坏,四后端同步)。**

**状态**:OpenList/Ani-rss/夸克(Cookie+扫码)三后端 + 三端 UI(选择器/登录含扫码二维码 qr_flutter/浏览/播放)完成,flutter analyze 0 error。夸克接口为逆向(参考 AList 驱动);Ani-rss 有官方 OpenAPI(api-docs.json),已照 spec 校正(MD5 密码/api-key 头/filename 免二次 base64)。两者仍需真实账号·真实服务器实测(本地环境无法连);夸克扫码令牌兑换依赖第三方代理 api.extscreen.com。Android 原生 mpv 的 http-header-fields 已接(MpvPlayerPlugin.kt),ExoPlayer Kotlin 侧 headers 未接(OpenList/Ani-rss 鉴权在 URL 不需要)。相关播放器改动见 「update-architecture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废) 同级的 video_player_service。

---

### 网盘源架构(2026-07-24大改+登录扩容)

> 原记忆:`netdisk-sources-via-oplist.md` · 类型:`project`

**2026-07-24 推翻重来**:上一版靠 `api.oplist.org` 在线令牌中继接 OneDrive/GDrive/Dropbox/阿里/百度。用户实测**中继根本不可用**(闭源单独托管,GFW 阻断/凭据吊销都修不了)。于是:

**洋盘三家(OneDrive/GoogleDrive/Dropbox)整体移除** —— 纯 OAuth 无扫码,唯一非开发者路径是 rclone 内置 client_id + 本地回环授权,用户否掉(国内用得少+常被墙)。连同 `oplist.rs` 一起删干净。

**留下的五家全部自建登录,零中继依赖**(`crates/core/src/source/`):
- **阿里(aliyundrive.rs)**:扫码(passport.aliyundrive.com)→ bizExt 抠 refresh_token → 网页版 `api.aliyundrive.com` + **x-signature(secp256k1 ECDSA,SHA256 预哈希,hex(r‖s)+"01",per-session)**。公钥经 create_session 注册。算法抄 tickstep/aliyunpan-api。**曲线是 secp256k1 不是 P-256**(调研有 agent 说错,靠读 tickstep 源码定死)。
- **百度(baidu.rs)**:扫码(passport.baidu.com)→ BDUSS cookie;或手动粘 Cookie。纯 cookie 无签名,直链 UA=pan.baidu.com。
- **115(pan115.rs)**:Cookie + 私有编解码 m115(1024位模幂,未变)。
- **天翼189(pan189.rs)**:**三种登录**——扫码(getUUID→轮询→getSessionForPC)、**手机号+密码(RSA)**、**手机号+短信验证码**。后两者逆向自官网 platformlogin.js:短信复用账密的 `loginSubmit.do`,靠 `dynamicCheck=TRUE` 区分,短信码走 `epd` 槽位、图形码走 `smsValidateCode`(命名反的);两步交互(sms_send发码打包会话参数进ctx→sms_login提交,lt/paramId必须同会话)。RSA=RSA/ECB/PKCS1,取小写hex前缀`{RSA}`;**不引 rsa crate,用 num-bigint 手做 DER解析+PKCS1v15填充+模幂**(与115同策,躲 rand_core 版本冲突)。每请求另有 **HMAC-SHA1 + AES-128-ECB 参数加密**。APP_ID=8025431004。
- **移动云139(pan139.rs)**:**曾以为无逆向登录,错**——2026-07-24 读 yun.139.com 自己的 Vue SPA(app.5f980ea6.js)攻下:**手机号+短信 / 手机号+密码**,同走 `POST user-njs.yun.139.com/user/thirdlogin`(pintype 区分:短信5/密码9),dycpwd=验证码或密码**明文**,secinfo=`SHA1("fetion.com.cn:"+它).大写`;发码 `/user/sms/getSmsCode`。**关键:Authorization 服务端从不下发,是客户端自算**——`Basic base64("pc:{手机号}:{data.token}")`(enCodeToken逆向),拿到 token 就能离线算,不必再手动抓浏览器(手动粘贴仍保留兜底)。常量:clienttype=670/cpid=292/verType=2/version=mCloud_4.3.0_536(全从bundle grep实证)。登录也要 mcloud-sign(cal_sign==app.js getNewSign)。**扫码也做了**(createLoginQrcode逆向):sID=客户端自生成随机串,二维码内容 `yun.139.com/w/#/qrcLogin?sID=..&dID=..&cType=9`,轮询=反复POST/thirdlogin(type5→pintype21,dycpwd=sID),状态码resultCode 200059548待确认/200059542失效/200059549取消,扫码手机号从响应encryptAccount(base64)解。139 现四路:扫码/短信/密码/手动粘贴。

**扫码统一 plumbing**:`QrStart{image,ctx}`/`QrPoll{pending|confirmed{credentials}|expired}` 在 source/mod.rs;各源导出 `qr_start`/`qr_poll` 自由函数(不进 browse trait);宿主 `source_qr_start`/`source_qr_poll` 两命令按 kind 分派;前端出码→2s 轮询→confirmed 把 credentials 塞进 source_login 落库。阿里/189 出码是**待渲染字符串**,core 用 `qrcode` crate 渲成 SVG data URI(`qr_svg_data_uri`),前端统一 `<img>`。

新增依赖:hmac/sha1/k256/hex/qrcode(svg)/httpdate。SourceKind 加 pan189/pan139,删 onedrive/googledrive/dropbox(BUILTIN+三张契约测试表+两宿主注册+api.ts 联合类型+sourceForms+ServersPage 全同步)。

**待真机验证**(本地证不了,均已在文件头/本条标注):阿里 ECDSA、百度扫码 Set-Cookie、189 AES/HMAC 跨实现、189 账密/短信的 toUrl→getSessionForPC 黑盒段(agent 明标未确认)、189 password 用 `password` 字段(APP流)还是 `epd`(web流)、139 mcloud-sign 是否登录必需+密码明文服务端是否收+extInfo:{}+8位账号pintype未处理、139 token 无刷新端点过期即重登。crypto 单测:189 有 SPKI解析/PKCS1填充/SMS captcha正则、139 有 SHA1 KAT + Authorization KAT(base64("pc:1:2")=cGM6MToy)真绿。**方法论沉淀:二手情报(社区/agent摘要)说"139无扫码无逆向登录"是错的——直接扒官网 JS bundle 才见真章;赌一把读 JS 逆向,赌赢了。**

关联 [凭据轮换回写](sources.md) [分发通道 GitHub 优于 CF](build-release.md) [不发 UA 就吃 403](network.md)。

---

### 凭据轮换回写

> 原记忆:`credential-rotation-writeback.md` · 类型:`project`

**症状**：源用得好好的，一重启就要重新授权，且不报任何错。

**根因**：阿里云盘（refresh_token）、天翼189（access/refresh）、夸克扫码的令牌是**一次性的**——刷新一次旧值当场作废。而 `MediaSourceBackend` 的方法只拿到 `&SourceServer`（只读），后端刷出的新 token 没有回写通道。会话内因内存缓存看不出问题，重启后拿死 token 去刷必失败。（2026-07-24：oplist 系已整体作废，见 [网盘源架构(2026-07-24大改+登录扩容)](sources.md)。）

**统一解法**（2026-07）：trait 加 `take_rotated_credentials(&self, server_id) -> Option<HashMap>`（默认 None）。宿主层 `persist_rotated()`（desktop+android 各一份）在每次 list_dir/search/resolve_play 后取一次，非 None 就并进 `SourceServer.extra` 并 `cfg.save()`。`OplistAuth`（oplist.rs）用 `dirty: HashSet` 标记「变过且未取走」，取走即清——**别每次调用都返回 Some**，否则每个请求都重写一次配置文件。（2026-07-24 oplist.rs 已删,阿里/189 各自用 `rotated: Mutex<HashMap>` map 实现同一契约。）

夸克扫码那笔旧债（`quark.rs` 老 ponytail 注释「刷新后未回写」）同一通道一起还了：`tv_rotated`+`tv_dirty`。

**读取优先级**（current_refresh）：内存轮换值 > extra > token 字段。顺序错了会拿早已作废的旧值去刷，表现为"用一会儿就掉登录"。

关联 [网盘源架构(2026-07-24大改+登录扩容)](sources.md) [「待接」多半是谎](methodology.md)。

---

### 夸克二维码是图不是文本

> 原记忆:`quark-qr-is-an-image.md` · 类型:`project`

夸克 TV OAuth `/oauth/authorize` 我们传的是 `qrcode=1&qr_width=460&qr_height=460` ——
**这两个尺寸参数只有「服务端出图」才讲得通**。返回的 `qr_data` 是一张 PNG 的 base64。

实测取证(2026-07-15,`cargo test -p linplayer-core quark_qr_data_shape -- --ignored --nocapture`):
长度 **4860**,开头 `iVBORw0KGgo` = PNG 文件头。

拿它去 `QRCode.toDataURL()` = 给一张二维码图再编一个二维码,必然
`The amount of data is too big to be stored in a QR Code`(纠错级 M 上限 ~2.3KB)。
正确做法:`<img src={"data:image/png;base64," + qr_data}>` 直出(AddServerPage 的 `ServerQr`)。

**Why:** 排查时子 agent 断言「夸克那条链是干净的、qr_data 是短 URL、物理上不可能超容量」,
把矛头指向了「扫码搬配置」那个真·容量问题。**推理很合理,但和用户的现场观察冲突,而它是错的。**

**How to apply:** 用户报的是**观察**(「夸克网盘根本生不出来二维码」),不是归因。
观察和推理冲突时,先花两分钟去打真接口/看真数据,别用推理覆盖观察 ——
见 [别过度解读需求](methodology.md)。另参 [测试必须先红](methodology.md):那条 `#[ignore]` 的
联网测试就是取证手段,留着,下次怀疑接口形状直接跑。

---

### 飞牛影视源

> 原记忆:`feiniu-trimemedia-source.md` · 类型:`project`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

飞牛影视按「文件浏览型源」接进(第5个,同 [File-browse sources](sources.md) 的 OpenList/夸克/Ani-rss 一条线),
非 Emby 路径。`SourceKind.feiniu`,后端 `lib/core/sources/feiniu_backend.dart`。三端零新 UI——选择器/账密登录页/
浏览页/source-player 全走现有泛用плumbing,只在 kSourceTypes 加描述项 + 3 个登录页 switch + server_list `_relogin` 加 case。

**API 关键(参考实现都不真流,端点从飞牛 PC 版 `QiaoKes/fntv-electron` src/modules/fn_api 逆向;元数据接口对照 MoviePilot v2 `app/modules/trimemedia`;`thshu/fnos-tv` 的 core/Fnos 是 fnOS **系统** WS/RSA 登录,与视频 app 无关别混淆)**:
- base = `http://ip:5666`(用户输,不带 /v),路径前缀 `/v/api/v1`。
- 账密 `POST /login {app_name:'trimemedia-web',username,password}`(**明文密码**,无 RSA/MD5)→ `data.token` 走 `Authorization` 头。
- 每请求另带 **authx 签名头**:`nonce=&timestamp=&sign=md5("<飞牛客户端硬编码常量A>_{带/v/api/v1的路径}_{nonce}_{ts}_{md5(body)}_<飞牛客户端硬编码常量B>")`;GET 时 body 空串。两常量是客户端硬编码非用户密钥。签名拼接顺序已用 openssl 定值向量交叉验证(test 向量 sign=ee30e62139d0530e371f6a1937d33a8e)。POST 体内另塞一个 `nonce`(防重放,与 PC 客户端一致)。
- 浏览层级:根 `GET /mediadb/list`(媒体库,普通用户端点)→ `POST /item/list {ancestor_guid,tags:{type:[Movie,TV,Directory,Video]},exclude_grouped_video:1,...}`(库内)→ TV 项 `GET /season/list/{guid}` → `GET /episode/list/{seasonGuid}`。id 编码 `lib:/dir:/tv:/season:` 前缀区分下一级怎么列;电影/视频/分集是可播文件(id=item guid)。搜索 `GET /search/list?q=`。
- **播放=直连原文件 Range**:`POST /play/info {item_guid}` → `media_guid` → 播放 URL `{base}/v/api/v1/media/range/{media_guid}`,带 Authorization+authx+`Cookie: mode=relay` 头交播放器。内封音轨/字幕 mpv 直接读;外挂字幕 `GET /stream/list/{item_guid}` 里 `subtitle_streams` 挑 `is_external` → `/v/api/v1/subtitle/dl/{guid}`。无续播/无上报(同其他浏览源)。

**未做/待验(真机)**:① **直连 media/range 用静态 authx**(构造播放时算一次),若飞牛服务端校验签名时间戳,长片播到中途可能断——届时升级为本地重签代理(fntv-electron 正是用 127.0.0.1:22345 代理逐请求重签,强暗示流请求要新鲜 authx)。已在 feiniu_backend 顶部留 ponytail 注释。② 海报封面没做:`/sys/img/` 需鉴权头,浏览网格用普通 Image 加载会 401,首版列表用图标不显示封面(用户选了「最省」方案,加封面要给三端浏览图片加载注入 header,二期)。③ 转码多档清晰度没做(只直连原画)。④ 本地无飞牛服务器,登录/浏览/播放全未真机跑过(同夸克/Ani-rss 当初)。

---

### 本地播放 + 局域网源

> 原记忆:`lan-sources-smb-webdav-ftp.md` · 类型:`project`

2026-08-16 **彻底删掉 Stremio**(源文件 + 三端 UI + TV 遥控网页 + 所有注释引用,全仓 grep 归零),
加了「本地播放」+ SMB / WebDAV / FTP。

##### 本地播放 = 一个 `local` 源,不是另开一套页面
用户点「本地播放」→ 系统文件夹选择器 → 选中的目录当成一个源存进服务器表,
之后走**和网盘完全一样**的浏览页/播放链路。做成源就白拿面包屑、搜索、重启免登;
另开一套「本地播放页」等于把这些再实现一遍还得再维护一遍。
- 选择器走 **Rust 侧 `tauri_plugin_dialog`**(`app.dialog().file().pick_folder`)——
  Cargo.toml 里早就有,而 `@tauri-apps/plugin-dialog` **前端包是故意不装的**(仓里三处
  注释写着「不为此加依赖」)。照抄 `plugin_pick_dev_dir` 的 oneshot channel 写法。
  新命令 `pick_local_folder`,**用户按取消返回 None,前端要什么都不做**(取消不是失败)。
- 交给 mpv 的是**裸路径**不是 `file://`:`play_local` 一直就这么干的;自己拼 file://
  要处理盘符、反斜杠、百分号编码三件事,每件都能拼错。
- **必须有越狱闸**:entry.id 是绝对路径,而前端可以回传任意值,一个 `..` 就能从用户挑的
  「电影」目录爬到整块硬盘 —— 用户挑目录这个动作本身就是在划范围。`confine()` 用
  canonicalize 之后比前缀(符号链接、`..`、大小写、Windows 的 `\\?\` 前缀都得先归一)。
- **安卓没做**:manifest 里只有 INTERNET 一条权限,也没有 tauri-plugin-dialog;
  选目录要 SAF(content:// URI,`std::fs` 根本读不了)+ 存储权限。后端两端都注册了,
  但手机端 UI 不给入口 —— 给了就是个点进去必然失败的按钮。

##### 架构三分是**实测 mpv 协议表**定的,不是猜的
用 ctypes 加载 `crates/mpv/libmpv/libmpv-2.dll` 读 `protocol-list` 属性(桌面 68 个协议,
这是权威答案);安卓 .so 用**依赖符号**反查。结论:

| | 桌面 | 安卓 | 于是 |
|---|---|---|---|
| `smb` | **无** | **无** | 必须自己搬字节 → `net/localserve.rs` 本地 HTTP Range 桥 |
| `ftp` | 有 | 有 | `ftp://user:pass@host/path` 直给 mpv,只写列目录 |
| `webdav`/`dav` | 有 | 有 | 本来就是 HTTP,直给 + `Authorization: Basic` |
| `sftp` | 有 | **无**(无 libssh) | 没做 |
| `ftps` | 无 | 无 | **故意不做**:列得出来播不了比没有更糟 |

★ **`strings` 查协议是彻底无效的方法**:`"Samba"` 在**已证实没有 smb 协议**的桌面 DLL 里
也在;nul 分隔的 `smb`/`sftp` 在安卓 .so 里也在,但它没有 libsmbclient / libssh 符号。
派出去的 agent 就是靠 grep 字符串得出「smb 两端都支持」的**错误**结论,照着做会整个架构走反。
可靠信号只有:桌面读 `protocol-list`,安卓查**依赖库符号**(`smbc_open` / `ssh_connect`)。

##### 选型
- `smb2` 0.18.1 —— 纯 Rust 无 build.rs,安卓交叉编译过。关键是 `FileReader::read_at(offset,len)`
  + `size()`,**视频要 seek,只能顺读的实现等于不能用**。还自带 `list_shares()` 和
  `rpc::srvsvc::filter_disk_shares()`(滤 IPC$/ADMIN$)。代价:拖进一套更新的 crypto crate
  (aes 0.9 / sha2 0.11 / hmac 0.13),和仓里旧版并存。
- `suppaftp` 10.x,`default-features=false, features=["tokio"]`(不开 TLS,理由见上表)。
- WebDAV **不用 reqwest_dav**:本仓 client 挂着按 host 的自签名证书白名单 + 代理设置,
  现成 crate 自己 build client 会**全绕过** —— 而对端典型就是自签名的 NAS。DIY 百来行。

##### 五个只有真跑才现形的坑(都写了钉子测试)
1. **quick-xml 0.41 把实体拆成独立事件**:`Tom &amp; Jerry` = Text + `Event::GeneralRef` + Text。
   赋值式解析只剩最后一截;而且**不能开 `trim_text`**(逐事件 trim 会把 "Tom " 的尾空格吃掉,
   拼回来成 `Tom&Jerry`)。解法:不 trim + 追加 + 自己还原五个预定义实体,最后统一 trim。
2. **`suppaftp` 的 `line.parse::<File>()` 有宽松兜底**:链是 posix→dos→mlsd→**mlst**,
   最后那个能把任意一行文本认成文件名。于是 `total 42`、欢迎语、乱码全变成**假条目**。
   解法:按来源指定解析器(MLSD 走 `parse_mlsd`;LIST 只走 `parse_posix`/`parse_dos`),
   并且**优先 MLSD**(机器可读)退回 LIST。
3. **WebDAV 的 `href` 是服务端绝对路径**(已含 base_url 里那截前缀)。拿它去接 base_url
   会拼出 `/dav/dav/剧集` —— **根目录能列,点进任何子目录才 404**,Nextcloud 全中招。
   解法:`split_base()` 拆出 origin,entry.id 统一用服务端绝对路径,拼 URL 只接 origin。
4. **测试自己打架**:`local.rs` 四条测试共用一棵按进程号命名的临时目录树,而 cargo 默认并行 ——
   「删掉文件看报错」那条一动手,正在列目录的那条当场少一个文件。红的是测试不是产品。
   这类用临时目录的测试**必须每条各用各的目录**。
5. 本地桥必须回 **`Connection: close`**,且越界判定要在钳位**之前**——两条都是从
   `net/prefetch.rs` 抄来的血教训(见 [预取代理吞 seek(已修)](network.md))。
   桥没复用预取代理:那边取数焊死在 HTTP Range + 环形缓存上,改可插拔要动最不该碰的播放链路。

##### 自检
`npm run check:lan`(`ui/shared/lan-sources.check.mjs`)—— CDP 真渲染,断言落在
**发出去的 `source_login` 参数**上;本地播放那段把「点按钮 → 调起 pick_local_folder → 路径显示出来 → 提交」整条走通(选择器在 stub 里返回固定路径)。反向注入验过:主按钮 switch 删掉 `case "smb"` 时
**tsc + vite 全绿**而它红,这正是它存在的理由。参考 [挂真机 CDP 调试](methodology.md)。

##### 顺带
- 删源要连**分类入口**一起删:Stremio 一走「插件协议」那一类就空了,留着=点进去一片空白。
- 老的 stremio 账号**不静默删**:`SourceKind` 是开放键,配置照常读回,只是点进去报
  「该源类型暂未接入」,用户自己在服务器页删。见 [SourceKind 线上是小写](sources.md)。

---

### Stremio 插件协议源

> 原记忆:`stremio-addon-source.md` · 类型:`project`

> **⚠️ 已下线(2026-08-16)**:`crates/core/src/source/stremio.rs` 连同 UI 一起删了,
> 换成了 SMB / WebDAV / FTP 三个局域网源(见 [本地播放 + 局域网源](sources.md))。
> 本文留作**方法参考**(虚拟路径折叠、分页从响应学),文中的文件路径已不存在。

2026-07-23 接入 Stremio(第 6 个 SourceKind)。三层元数据(catalog→meta→stream)**折成虚拟路径**塞进
既有 `MediaSourceBackend`,换来零新增 Tauri 命令、零新增前端页面(桌面 NetdiskPage 网格模式白送海报墙)。

**协议文档举的数字不能当规格用。**
- SDK 文档 catalog 分页举例 `skip=100`,**实测 Cinemeta 每页只回 46~51 条且不固定**。
  按 100 判满页 → 永远不挂「下一页」,用户只看得到第一页而且**完全不报错**。
  分页步长必须按「这一页实际拿到几条」走。同理别拿「比上一页少」当结尾——条数本来就跳。
- enginefs 播种子的 URL 只有 `{server}/{infoHash}/{fileIndex}` 这一种有出处的形式。
  fileIdx 缺省时填 `null`/`-1`/省略段全是猜的 → 宁可置灰说明原因,也别发来路不明的 URL。

**资源 URL 的两个硬约束**(错了表现是「电影正常、电视剧一个流都没有」):
- id 里的 `:` 必须原样留(`/stream/series/tt0108778:1:5.json`),转成 `%3A` 有 addon 不解码。
- extra 是**路径段**不是 query:`/catalog/movie/top/skip=100.json`,写成 `?skip=100` 所有 addon 都当没传。

**catalog 必须过滤 `extra.isRequired`**:Cinemeta 的 `lastVideos`/`calendarVideos` 要求传 ids,
裸请求返回空 —— 不过滤根目录就挂两个点进去永远空的文件夹。
另外它四个目录叫 Popular/Popular/Featured/Featured,名字**必须补类型**否则分不清电影剧集。

**安卓侧原本是两个洞**(不只影响 Stremio,所有浏览型源都中):`source_login` 根本没注册,
`source_play` 是写死报错的桩。已一并补齐。TV 上加源只能走 companion 手机网页
(遥控器打多行 URL 是灾难),见 [TV 端 UI 选型](ui-tv.md)。

选型:`stremio-core` 是完整 Redux 客户端框架且**没上 crates.io**,Rust 生态无 addon client crate → 自撸。
相关:[File-browse sources](sources.md) [测试必须先红](methodology.md) [挂真机 CDP 调试](methodology.md)

---

### SourceKind 线上是小写

> 原记忆:`sourcekind-wire-is-lowercase.md` · 类型:`reference`

**`SourceKind` 的线上值是全小写**:`emby` / `openlist` / `quark` / `anirss` / `feiniu` /
`stremio`,插件源是 `plugin:<插件id>/<源id>`。核层是 `#[serde(transparent)]` 的 newtype
(它还是 enum 的年代也是 `rename_all="lowercase"`)。

**Why:** 2026-07-23 发现 `ui/shared/api.ts` 里整个联合写成首字母大写的
`"Emby" | "Openlist" | …`。后果全部**静默**:
- `sourceLogin("Openlist", …)` 送出后端不认识的 kind
- 服务器卡的 `KIND_LABEL[a.source_kind]` 恒 undefined → 六张卡徽标全空白
- `a.source_kind === "Anirss"` 恒 false → Ani-RSS 卡点进去落到网盘页
- TV 端 `=== "Emby"` 同样恒 false

**How to apply:** 新增源类型时**两边都要动**,并且靠
`apps/desktop/src/lib.rs::api_contract_tests::source_kind_wire_strings_match_the_frontend_union`
把 `SourceKind::BUILTIN` 和 api.ts 的联合对一遍(TS 没有测试环境,让 Rust 当守门人)。
api.ts 那个联合是**开放**的(`| (string & {})`),别改回 `Record<SourceKind, …>` 那种要求穷举的写法,
插件源进不去。

见 [「待接」多半是谎](methodology.md)、[插件 v2 市场与声明式 UI](plugins.md)。

---

### 首登闸口+源表单共用

> 原记忆:`login-gate-and-source-forms.md` · 类型:`project`

2026-07-23 重建 PC 首次登录页(commit b6414acc)。草稿 `docs/login-drafts.html`(不入库)。

##### 数据源表单只有一份实现

`ui/desktop/pages/sources/sourceForms.tsx` 的 `useSourceForms()` —— **登录闸口和添加服务器页共用**。
`AddServerPage` 从 864 行降到 88 行,只剩版式(面包屑 + 主从两栏);`LoginPage` 是居中卡片 + 顶部芯片。

- **新增源类型只改 `BUILTIN_SOURCES` 一条**,两页同时生效。各写一份必漏一边且**两边都不报错**。
- hook 把渲染拆成 `heading()` / `fields()` / `primary(label)` 三段,好让闸口跳过标题、自己摆按钮。
- `exclude` 参数屏蔽某些源(闸口屏了 `qrsync` 和 `batch`)。

##### ⚠️ current_session 滤掉文件浏览型账号

核层 `current_session` 是 `.filter(|a| !a.is_file_browse())` —— 只连了**网盘/Stremio/插件源**的用户
在那儿**永远返回 null**。前端只判 session 就是「加成功了还是回登录页,加一次挡一次」,
7 个源里 5 个是废的。老登录页只能连 Emby 所以这条从没暴露过。

正解:`currentSession()` 和 `currentSource()` **一起拉**(`reloadEntry`),进门判「有没有活跃账号」;
没有 Emby 会话时给 `Shell` 合成一个 `{server: srcAcc.server, token:"", user_id:"", user_name}`,
并 `initialPage="netdisk"`(网盘用户的首页是空的)。`current_source` 核层早就有、前端一直没接,
是 [「待接」多半是谎](methodology.md) 的又一例。

##### 改名:source_login 拿不到账号键

`source_login` 是 `-> ()`。要给刚加的源改名,得登录成功后用 `current_source()` 回读拿键再 `updateAccount`。
**五条登录路径都要补**(内置源 / 插件源 / Stremio / 夸克 Cookie / 夸克扫码轮询回调),
少补一条那个源就还是显示地址。改名失败**不能阻断** —— 名字没改上顶多显示成地址,
不该让「加成功了」变成「报错了」。

服务器名称字段必须在**地址上面**且添加时就能填:不填则显示名回落成 host,侧栏/服务器页
到处是真实地址,截图即暴露;事后改还得专门跑一趟服务器页(用户 2026-07-23 原话)。

##### 版式口径(用户定的,别自作主张改回去)

- 标题下**不写承诺句**(「连上媒体服务器或网盘就能开始看」那类)—— 芯片行已经把能连什么列全了。
- 所有可点控件 + 输入框**统一 8px 直角**。`.btn.big` 原来是 10px,已全局改齐。
- 测试结果**长在按钮上**(测试连接 → 测试中… → ✓ 连接成功),不另起回执块 ——
  回执块一出现会把主按钮整体推下去。失败**仍走**独立红块(要写清怎么办,按钮宽度装不下)。
- 芯片行**横向滚动不换行**:插件源数量运行时才知道,换行会让卡片高度跟着插件数抖。
- 表单区 `min-height:300px`:扫码态和表单态高度差一大截,不定高点一下芯片整张卡就弹一次。

**Why:** 老登录页 67 行只能连 Emby,是「像测试版」的根因 —— 不是样式问题是能力问题。
**How to apply:** 见 [对着桌面草稿做](ui-desktop.md)(先出草稿再落码)、[本周看板定案+PC视觉自检](methodology.md)
(无头 Edge 渲染真 DOM 自检)、[挂真机 CDP 调试](methodology.md)(本次两个真 bug 只有挂真 exe 才现形:
`.btn.big` 残留 10px、批量导入出现两遍)。

---

## 跨域交叉引用

这些条目和本领域强相关,但正文放在别的文件里(一条经验只存一份正文):

- [网盘/strm 播放两大坑](player-mpv.md) — 网盘/strm 的两个播放坑
- [起播不露视频窗](player-mpv.md) — source_play 从来没调过 show_video,网盘/资源站一起中招
- [VOD 资源站插件](plugins.md) — 资源站(VOD)以插件形态接入,协议细节在插件页
- [设置/服务器/添加服务器重构](ui-mobile.md) — 扫码型源的「重新登录」在 PC 上是残缺的
- [UHD 插件](plugins.md) — 插件源的 httpAllowedHosts 是 fail-closed
