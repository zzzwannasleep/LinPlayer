# 媒体源与登录逆向知识

> 供 Go 核心层重写使用。所有结论带 `文件:行号` 出处。
> **本文不复制任何主机名、端口、UA、AppId、密钥、公钥、XOR 表、Cookie 值。**
> 需要逐字节一致的常量，一律给出「在哪一行」，由移植者从源码直接抄——
> 手抄进文档再抄回代码是错字的唯一来源，而这批常量抄错的后果全都是**静默失败**
> （服务端不报错、日志无痕、只表现为"登录不上/播不了"）。

**占位符对照**（值在源码里，本文只给位置）：

| 占位符 | 源码位置 |
|---|---|
| `<SECINFO_PREFIX>` | `crates/core/src/source/pan139.rs:317`（139 `secinfo` 的 SHA1 前缀串） |
| `<固定中继标记>` | `crates/core/src/source/feiniu.rs:657`（飞牛请求恒带的那个 Cookie） |
| `<回环地址>` | `crates/core/src/net/localserve.rs:53`（本地桥只监听回环） |
| `<APP_ID>` / `<CLIENT_ID>` / `<SIGN_KEY>` / `<SIGN_SECRET>` / `<API_KEY>` | 见 §8.2 逐字节对账表 |
| 各家主机名 / UA | 各后端文件顶部的 `const` 区，见 §8.2 |

> 文中出现的 `example.com` / `evil-example.com` 是 RFC 2606 保留示例域名，来自测试语料，不是真实地址。

---

## 0. 一句话

**`MediaSourceBackend` 是一个三方法接口（列目录 / 搜索 / 解析播放），十几个网盘、局域网协议、
本机文件夹和插件源全都塞得进去；真正难的不是接口，是每个源各自的签名算法、扫码状态机，
以及"mpv 到底认不认这个协议"这条把架构劈成三半的实测结论。**

---

## 1. `MediaSourceBackend` 接口契约

定义：`crates/core/src/source/mod.rs:414-509`。

### 1.1 必须实现的两个

| 方法 | 签名要点 | 契约 |
|---|---|---|
| `kind()` | `-> SourceKind` | 见 §1.5 |
| `list_dir(http, server, dir_id: Option<&str>)` | `-> Vec<SourceEntry>` | `dir_id = None` **表示根目录**（`mod.rs:418`）。各源对"根"的定义不同：SMB 根 = 共享列表、阿里根 = 盘列表、飞牛根 = 媒体库列表、FTP 根 = `base_url` 里带的子路径 |
| `resolve_play(http, server, entry, quality_id)` | `-> ResolvedPlay` | 把条目变成**可播 URL + 逐流 headers**。注释明说「短效直链过期后播放层回调重解析」（`mod.rs:436`）——即调用方（302 看门狗）会拿**同一个 entry** 再调一次，所以实现**不能依赖 `entry.raw` 一定有值**（见 §7-#8） |

### 1.2 有默认实现的六个——`unsupported` 与真错误的分界

这是整个接口设计里最容易在 Go 侧丢掉的语义。

| 方法 | 默认实现 | 默认值的含义 |
|---|---|---|
| `search` | `Err(SourceError::unsupported())` | `mod.rs:427-434`。注释：「无源端搜索能力的实现返回 unsupported，**UI 退回本地过滤**」 |
| `report_progress` | `Ok(())` | `mod.rs:449-459`。注释：「失败一律吞掉不打断播放——**进度没记上是小事，把正在看的片子打断是大事**」。调用节奏由调用方定：播放中 5s 一拍，停止时以 `finished=true` 再调一次（`mod.rs:447`） |
| `take_rotated_credentials` | `None` | 见 §1.4 |
| `categories` / `catalog` / `media_detail` | `Err(unsupported_feature("影视目录"))` | `mod.rs:478-508`。见 §1.6 |

**两种"失败"必须能被调用方分开**（`mod.rs:249-251, 383-393`）：

```
SourceError { message: String, is_auth: bool }
  ├─ is_auth = true   → 鉴权失效，UI 引导重新登录
  ├─ message 含 "__LP_UNSUPPORTED__" → 「这个源没有这个能力」，UI 静默退回另一条路径
  └─ 其余                            → 真错误，弹给用户
```

`UNSUPPORTED_PREFIX` 是**稳定的魔法字符串**，理由写在 `mod.rs:249-250`：

> 命令层把 `SourceError` 拍成字符串交给前端，前端只能靠文案判断 —— **靠中文提示语判断会在改文案时静默失效**，所以给个标记。

同一个标记在插件侧叫 `UNSUPPORTED_MARKER`，值相同（`crates/core/src/plugins/ctx.rs:21`），
JS 里 `ctx.errors.unsupported()` 抛出后由 `plugin_source.rs:63-79` 还原。

> **Go 侧**：`SourceError` 建议做成实现 `error` 的具体类型，带 `IsAuth() bool` 和 `IsUnsupported() bool`；
> 但**线上表示仍必须是同一个前缀字符串**，因为前端在按它判断。

### 1.3 数据模型

```
SourceEntry { id, name, is_dir, is_video, size: Option<i64>, thumb_url, raw: Option<Json> }
```
`mod.rs:177-189`。三个字段的语义陷阱：

- **`id` 是源自定的不透明串**，各源含义完全不同（注释 `mod.rs:180`：「OpenList=完整路径，夸克=fid，Ani-rss=filename」）。
  实际还有更极端的：SMB 是 `共享名/子路径`（`smb.rs:72-73`）、阿里是 `drive_id:file_id`（`aliyundrive.rs:323-327`）、
  飞牛是 `lib:|tv:|season:|dir:` 前缀 + guid（`feiniu.rs:128-150`）、Ani-RSS 根层直接把**整个 Ani 对象的 JSON** 塞进 id（前缀 `ani:`）。
- **`raw` 是"避免二次请求"的口袋**（`mod.rs:187`），但它**不保证在重解析时还在**——302 看门狗重签时 raw 是空的，
  所以 115（`pan115.rs:112-137`）和百度（`baidu.rs:116-134`）都写了"按 id 反查一次"的兜底。
- `size` 一律 `Option`，多个源把 `size==0` 归一成 `None`（如 `smb.rs:201`、`ftp.rs:123`、`local.rs:74`）。

```
ResolvedPlay { url, title, http_headers, user_agent_override, subtitles, qualities, selected_quality_id }
```
`mod.rs:208-232`，`ResolvedPlay::simple()` 是三字段快捷构造。
`user_agent_override` 与 `http_headers["User-Agent"]` **同时存在且都要给**——115 和百度两个源都是这么写的
（`pan115.rs:272-280`、`baidu.rs:209-247`），因为播放层的 UA 属性和逐流 header 是两条通道。

### 1.4 `take_rotated_credentials`——凭据轮换回写通道

`mod.rs:461-471`，注释是全文件最要紧的一段：

> 存在的理由：trait 只拿得到 `&SourceServer`（**只读**），而 oplist 系与阿里云盘的 refresh_token 是**一次性的**——
> 刷新一次旧值当场作废。不回写的话内存里能用，**一重启就拿着死 token 去刷，表现为「用得好好的，重开就要重新授权」，且不报错。**

契约：
- 调用方在**每次** `list_dir` / `search` / `resolve_play` 之后取一次；
  实测命令层在 `list_dir / search / categories / catalog / media_detail / play` **六条命令后都调了**
  （`apps/desktop/src/lib.rs:3670, 3686, 3702, 3720, 3735, 3765` → `persist_rotated()` `:3634-3657`）。
- 返回的 map 并进 `SourceServer.extra` 后**落进账号表并 `cfg.save()`**，同时刷新内存里的活跃源（`:3648-3656`）。
- **take 语义**：取走即清空。三个实现都是 `remove`（`pan189.rs:411`、`aliyundrive.rs:554`），
  夸克更进一步用一张 `tv_dirty: HashSet` 当脏标记（`quark.rs:29-30, 466-472`），注释写明理由：
  「没有它，**每个请求后都会重写一次配置文件**」。

**哪些源需要**：

| 源 | 轮换什么 | 出处 |
|---|---|---|
| 阿里云盘 | `refresh_token`（刷 token 时轮换）+ 首次生成的 `device_id` | `aliyundrive.rs:123-138, 553-555` |
| 天翼 189 | `access_token`，以及服务端换新时的 `refresh_token` | `pan189.rs:140-153, 410-412` |
| 夸克（TV/扫码模式） | `refresh_token` | `quark.rs:251-265, 466-472` |
| 其余全部 | 不需要（用默认 `None`） | — |

> ⚠️ 夸克 Cookie 模式的 `__puus/__pus` 轮换**没走**这个通道，只写进内存 `cookie_cache`
> （`quark.rs:134-151`）——重启后回落到存盘的初始 Cookie。这是**已知的不对称**，见 §10。

### 1.5 `SourceKind`——从封闭 enum 到开放键

`mod.rs:23-163`。这是 2026-07-23 的一次专门改造，注释把动机、线上表示、兼容三件事都写死了。

**为什么改**（`mod.rs:25-26`）：
> 封闭 enum 意味着加一个源必须改 Rust 重新编译，**插件永远塞不进 `HashMap<SourceKind, Arc<dyn MediaSourceBackend>>` 那张分派表**。

**线上值是裸小写字符串**（`mod.rs:28-29, 37-39`）：`#[serde(transparent)]` 的单字段 newtype，
序列化后与改造前**逐字节相同**。契约测试 `kind_wire_format_is_bare_lowercase_string`（`mod.rs:592-629`）
逐条钉住 14 个内置值，并断言表长 == `BUILTIN.len()`，防止"新增源没补测试 = 无人把关"。

`transparent` 对单字段 newtype 是**冗余的**（注释 `mod.rs:33-36` 明说实测去掉不会红），
留着当**编译期钉子**：谁加第二个字段会当场编译报错，而不是悄悄把线上表示从字符串变成对象。

**插件源怎么编码进去**（`mod.rs:60-61, 131-145`）：
```
plugin:<插件id>/<源id>        例：plugin:com.example.foo/mysrc
```
`as_plugin()` **残缺键一律返回 None**（`mod.rs:136-141`）：`plugin:x/`、`plugin:/y`、`plugin:nosep`、`plugin:` 全部不拆。
理由：「拆出空 id 会让上层去问一个不存在的插件，**错误信息还会指向错的地方**」。

**老账号兼容**（`mod.rs:147-162`）：`legacy_debug_label()` 逐字复刻老封闭 enum 的派生 `Debug`
（首字母大写：`quark` → `Quark`）。为什么必须留：

> 改成 newtype 后 Debug 变成 `SourceKind("quark")` —— 直接沿用会让老账号在 `upsert` 时匹配不上、变成重复项，**旧账号成孤儿**。

它的真实用途是 **base_url 为空的源（夸克 Cookie 模式）的账号 id 和用户名**——
命令层 `source_login` 里 `id = base_url.is_empty() ? kind.legacy_debug_label() : base_url`
（`apps/desktop/src/lib.rs:3527-3532`），用户名也用它兜底（`:3564`）。测试 `mod.rs:671-698` 钉住全部 14 个。

**未知 kind 必须能反序列化**（`mod.rs:704-709`）：
> 装过插件源的配置，在插件被禁用/卸载后仍能读回**整个账号**，而不是让整份 config 反序列化失败、把所有服务器一起带走。

**`is_emby()`**（`mod.rs:126-129`）：Emby 是**唯一的非文件浏览型源**，它在 `SourceKind` 表里但**没有 `MediaSourceBackend` 实现**，
全仓多处靠这个方法分叉。`SourceKind::default()` 也是 emby——「没有 source_kind 字段的老账号全靠它兜底」（`mod.rs:626-627`）。

### 1.6 影视目录能力（catalog）——三个可选方法

`mod.rs:234-247` 那段块注释是这套设计的全部理由：

> **网盘是文件树，资源站是影视目录，这是两种东西。** 文件树一行只需要「名字 + 是不是文件夹 + 多大」，`SourceEntry` 就够了；
> 影视目录一张卡要海报、标题、「更新至17集」、年份、评分，还要分类和无限翻页。
> 把这些字段硬塞进 `SourceEntry`，代价是**十个网盘后端（40 处构造点）全得陪着改**，还要背一堆它们永远填 None 的字段。

三个方法的语义：

| 方法 | 语义 |
|---|---|
| `categories(server)` | 分类树。「只有两级，再深也照收，前端自己决定画几级」（`mod.rs:253`）。**它同时是能力探测点**：前端进一个源先探它，通了走影视浏览页，不通走文件浏览页（`mod.rs:474-475`） |
| `catalog(server, category_id, keyword, page)` | 目录的一页。`category_id=None` = 全站最新；`keyword` 非空 = 搜索。**搜索和浏览故意共用一个方法**（`mod.rs:486-488`）：「分成两条路径的话，翻页逻辑就得写两遍，而**少写的那遍就是「搜索只有第一页」**」 |
| `media_detail(server, id)` | 详情：简介 / 演职员 / **线路 → 分集**。`MediaEpisode.raw` 原样回传给 `resolve_play`，所以播放链路一行不用改（`mod.rs:287`） |

数据模型 `mod.rs:254-319`。两个字段设计上的硬要求：

- `MediaCard.badge` **必须是独立字段**（`mod.rs:267-270`）：
  > 没有它的时候只能拼进标题，卡片下面就变成「神之水滴 · 更新至17集 · 2026」——那不是标题，是把三样东西塞进一个格子。
- `MediaPage.has_more`（`mod.rs:277-278`）：
  > 「下一页」不该是列表里的一个条目，那是**把翻页伪装成内容**。

### 1.7 `probe_backend`——添加服务器时的能力探测

`mod.rs:332-347`。这是 2026-08-01 的一个 P0 修复：

> ★ **不能只试 `list_dir`。** 影视目录型的源（资源站）根本不实现它 ⋯⋯ 只探 `list_dir` 的话那一整类源在添加这一步就被判死，
> 报的还是一句「插件数据源必须返回数组」，**完全看不出是探测方式选错了**（真踩到：插件装好了、目录也能列，就是加不进服务器表）。

规则：`list_dir` 或 `categories` **任意一条通就算能用**；两条都不通时**报文件树那条的错**——
「用户填错地址时那句通常更具体，而目录那条往往只是句「不支持」」（`mod.rs:343-345`）。

放在核层而不是各端命令里的理由（`mod.rs:330-331`）：
> 桌面和安卓的 `source_login` 是**两份手工拷贝**，这种「探测口径」放在两边迟早只改一边。

三条回归测试：`mod.rs:761-785`。

### 1.8 共用工具（Go 侧要一并搬）

| 函数 | 行为 | 出处 |
|---|---|---|
| `normalize_base_url` | trim → 缺协议补 **https** → 去掉全部尾斜杠 | `mod.rs:514-526` |
| `qr_svg_data_uri` | 把文本渲成二维码 SVG 的 `data:` URI。**阿里/189 的接口给的是待渲染字符串不是图**，统一在核层渲，前端不带 JS 二维码库 | `mod.rs:528-544` |
| `is_video_file_name` | 24 个扩展名的小写匹配表（含 `m3u8` 和 `iso`） | `mod.rs:546-557` |
| `sort_entries` | **文件夹优先，各自按 `name.to_lowercase()` 比** | `mod.rs:559-571` |

> ⚠️ `normalize_base_url` 缺协议补 **https**，所以 **FTP 后端不能用它**——
> 「拿去连 FTP 会得到「host 是 https」这种解析结果」（`ftp.rs:28-29`）。FTP 自己拆地址。

> ⚠️ Ani-RSS 的根层排序**故意不用** `sort_entries`，走的是裸 `name.cmp`（见 §7-#20）。

### 1.9 账号表与源服务器的关联（`config.rs`）

**Emby 和浏览型源共用同一张账号表**——`crates/core/src/config.rs:17-19`：
> 统一承载 Emby 与浏览型源（靠 `source_kind` 区分），对齐 Dart 的 ServerConfig——旧栈只有一张服务器表，新栈也只能有一张。
> **身份键仍是 `server`**（归一化后不带尾斜杠）：前端既有的 `server_id` 参数就是它，**别换**。

```rust
pub struct Account {
    pub server: String,                  // 身份键
    ...
    #[serde(default)] pub source_kind: SourceKind,          // config.rs:47-51
    #[serde(default)] pub source: Option<SourceServer>,     // config.rs:52-54
}
```
- **serde 属性只有 `#[serde(default)]`，没有 rename/alias**；默认值由 `impl Default for SourceKind` 给出 = `emby`（`mod.rs:165-169`）。
- 老配置回归 `old_config_json_still_loads`（`config.rs:1019-1032`）断言「老账号必须默认当 Emby」且 `source` 为 None。
- 分叉判据 `Account::is_file_browse()` = `!source_kind.is_emby()`（`config.rs:98-100`）。

**硬关联：`Account.server == SourceServer.id`**，三处依赖它：
写入 `apps/desktop/src/lib.rs:3563`；轮换回写查表 `:3650`；切服还原 `:651`。

**id 规则**（`apps/desktop/src/lib.rs:3527-3531`，安卓 `apps/android/src/lib.rs:361-365` 同构）：
```
id = base_url.trim().is_empty() ? kind.legacy_debug_label() : base_url
user_name 同样回落 legacy_debug_label()      (:3564)
```

**Emby 会话与源必须互斥**——两处成对逻辑：

| 位置 | 内容 |
|---|---|
| 启动重建 `apps/desktop/src/lib.rs:5744-5753`（安卓 `4694-4700` 同构） | 「活跃的是 Emby 就装 session，是浏览型源就装 source ——**两者互斥，别同时留着**」 |
| 运行时切服 `set_active_server` `:630-663` | 「一张表两种形态，切换必须两边都对齐，否则会**留着上一个服的会话在那儿（切服失败还打错服务器）**」。缺凭据报「该源缺少登录凭据,请重新登录」（`:649`） |

`upsert`（`config.rs:608-627`）按 `server` 去重，命中时**保留用户侧编辑**（name / remark / icon_url / lines / active_line / allow_insecure_tls）。
`remove`（`config.rs:645-676`）两个坑：活跃被删要回落第一个、**删别人时靠 server 重新定位下标别让下标漂移串台**；
并顺带 `prefs.prefetch_servers.retain`——不清的话「重新加同一地址会**自己就开着**」（`:665-666`）。

**聚合视界**（`apps/desktop/src/lib.rs:554-627`）：文件浏览型源返回零值 base 但**仍出现在列表里**——
「藏起来只会让人以为『我的网盘丢了』」（`:577`）。注意该命令返回里 `source_kind` 被拍平成 `String`（`:597`）。

---

## 2. 架构三分（直给 mpv / 本地桥 / 其它）

### 2.1 三分是**实测 mpv `protocol-list` 定的**，不是推断的

原始结论在两处，措辞一致：

`crates/core/src/net/localserve.rs:3-8`
> 实测本仓打包的 libmpv（**桌面 DLL 用 ctypes 读 `protocol-list`，安卓 .so 用依赖符号反查**）**没有 smb 协议**：
> desktop **68 个协议**里没有 `smb`/`cifs`，两侧也都不含 libsmbclient 的符号。
> 所以 SMB 上的片子没法把 `smb://…` 直接甩给播放器，必须由我们读字节、用 HTTP 喂过去。
> （WebDAV 和 FTP 不走这里：前者本来就是 HTTP，后者 mpv 自带 `ftp` 协议。）

`crates/core/src/source/smb.rs:3-8` 同一结论的第二份记录。

`crates/core/src/source/ftp.rs:1-6`
> mpv 自带 ftp 协议（实测 libmpv 的 protocol-list 里有 `ftp`，**桌面和安卓两侧都在**），
> 所以播放是把 `ftp://用户:密码@主机/路径` 直接交给它，取流那一大套（Range / seek / 重连）由 ffmpeg 自己扛。
> ★ **不开 TLS**：同一张 protocol-list 里**没有 `ftps`**。**列得出来却播不了的源比没有这个源更糟**，
> 所以宁可不给 FTPS，也不做一个点进去必然黑屏的功能。

**"用 `strings` 查协议完全无效"这条教训**：本仓在 `source/` 下**没有**留下这句话的原文
（记忆索引 `lan-sources-smb-webdav-ftp` 里有：「`strings` 查协议完全无效——没 smb 的 DLL 里照样有 "Samba"」）。
代码里留下的是**替代做法**：桌面用 **ctypes 读 libmpv 的 `protocol-list` 属性**，安卓用**依赖符号反查**
（`localserve.rs:4-6`）。旁证：`crates/core/src/mpv-release-hygiene` 系注释在别处也记过 `strings` 会静默返回空
（`grep` 命中 `crates/core/build.rs:2`：「明文永不落进产物（防 strings/反编译直接捞）」）。

> **Go 侧的等价查法**：不要用 `strings`。加载目标 libmpv 后用 `mpv_get_property_string(ctx, "protocol-list")`
> 打印真表；Android 侧用 `readelf -d` / `nm -D` 看有没有 libsmbclient 的符号依赖。
> **这条必须在每次换 libmpv 版本后重跑**——协议表是编译期决定的。

### 2.2 三条道各有谁

| 道 | 源 | resolve_play 交给 mpv 的东西 |
|---|---|---|
| **A. 直给 mpv（HTTP/HTTPS 直链 + 逐流 headers）** | openlist / quark / feiniu / aliyundrive / baidu / pan115 / pan189 / pan139 / anirss / webdav / 全部插件源 | 远端 URL + `http_headers` +（有些还带）`user_agent_override` |
| **B. 直给 mpv（非 HTTP 协议）** | **ftp** | `ftp://用户:密码@主机:端口/路径`（凭据百分号编码进 userinfo，`ftp.rs:132-151`） |
| **C. 本地桥** | **smb** | `http://<回环地址>:<系统分配端口>/stream`（`smb.rs:236-243`） |
| **D. 裸路径** | **local** | **裸文件路径，不是 `file://` URL**（`local.rs:9-12, 127-131`） |

**为什么 local 是裸路径**（`local.rs:9-12`）：
> 播放链路最后一句是 `p.load_with_headers(&resolved.url, …)`，而 **mpv 吃裸路径**——旁边的 `play_local` 一直就是直接把 `D:\片子\a.mkv` 喂进去的。
> 自己拼 `file://` 反而要处理**盘符、反斜杠、百分号编码**三件事，每件都能拼错。
测试 `local.rs:221` 反向断言：`assert!(!r.url.starts_with("file://"))`。

### 2.3 本地 Range 桥（`net/localserve.rs`）

**为什么不复用预取代理**（`localserve.rs:10-18`）：
> 那个代理的取数是**焊死在 HTTP Range 上**的：它自己发 reqwest 请求、跟 302、读 Content-Range 探大小，外面还套着磁盘环形缓存和多线程预取窗口。
> 把它改成可插拔上游要动 fetch/probe/重签三处核心，而那三处正是播放链路最不该乱碰的地方（「有流量没画面」那几个坑全在里面）。
> 这里要的只是「一个请求一段字节」，独立一个小服务器反而互不牵连。
> **只有 HTTP 应答那半边是照着 prefetch 抄的**——那些头（206 / Content-Range / **Connection: close**）是踩出来的，不是设计出来的。

设计要点：

| 点 | 内容 | 出处 |
|---|---|---|
| 抽象 | `trait RangeSource { fn size() -> u64; async fn read_at(offset, len) -> Vec<u8> }`。**开播前必须已知总长**——「mpv 拿不到总长就没法算进度条，更没法 seek」 | `localserve.rs:25-32` |
| 一片一端口 | 只服务**一个文件**，换片就丢旧 handle。「省下了「按路径路由 + 会话表 + 过期回收」那一整套，而我们同一时刻本来就只放一片」 | `localserve.rs:47-50` |
| 只听回环 | 「这条流带着用户 NAS 的内容，**不该出网卡**」；端口交给系统挑（bind port 0） | `localserve.rs:52-54` |
| 每连接一 task | 「mpv 会为 seek 另开连接（我们回的是 Connection: close），**串行处理的话新连接要等旧连接把整段喂完 —— 那就是 seek 卡死**」 | `localserve.rs:62-66` |
| URL 带扩展名 | `/stream`——「ffmpeg 会拿 URL 尾巴猜容器格式，光一个 `/` 会让它少一条线索」 | `localserve.rs:71-73` |
| `drop` 即关 | `BridgeHandle` 的 `Drop` abort accept 循环；端口和那条 SMB 连接一起收 | `localserve.rs:34-45`，测试 `:256-267` |
| **416 必须在钳位之前判** | 「prefetch 那边踩过：**先 min 再判，分支永远进不去**，越界请求被悄悄挪回最后一字节回 206 —— 播放器拿到「有效但错位」的数据」 | `localserve.rs:82-91`，测试 `:224-230` |
| **`Connection: close` 不是可选项** | 见 §6.1 | `localserve.rs:110-114` |
| 分块读发 512KB | 「一次性把整段（可能是几百 MB）读进内存会直接把手机撑爆」 | `localserve.rs:123-124` |
| 读失败即断开 | 「硬撑着不回等于让播放器干等到超时，断开它至少会重试或报错，**用户看得见**」 | `localserve.rs:129-132` |

桥的持有者是 **`SmbBackend` 自己**（`bridge: Mutex<Option<BridgeHandle>>`，`smb.rs:30-35`）：
> `resolve_play` 只能返回一个 URL —— **handle 没人持有的话，函数一返回桥就没了，mpv 拿到的会是个已经关掉的端口。**

---

## 3. 源能力矩阵表

「源」= `SourceKind::BUILTIN` 的 14 个（`mod.rs:64-70`）+ 插件源。其中 **emby 没有 `MediaSourceBackend` 实现**，
所以文件浏览型后端实为 **13 个内置 + 1 个插件桥**（`plugin_source.rs`）；仓库内自带 2 个插件数据源
（`plugin:com.linplayer.vod/site`、`plugin:com.linplayer.m3u/playlist`）。

| 源 kind | 登录方式 | 源端搜索 | 影视目录 | 进度上报 | 凭据轮换 | 播放道 |
|---|---|---|---|---|---|---|
| `emby` | 账密（非本 trait） | — | — | 走 Emby 自己那套 | — | 直给 |
| `openlist` | **账密**（JWT，401 自动重登） | ✅ `/api/fs/search` | ✗ | ✗ | ✗ | 直给 |
| `quark` | **Cookie**（网页）/ **扫码**（TV OAuth） | ✅（**仅 Cookie 模式**，TV 模式如实报 unsupported） | ✗ | ✗ | ✅（TV 的 refresh_token） | 直给 |
| `feiniu` | **账密**（token + authx 签名） | ✅ `/search/list` | ✗ | ✅ **本仓唯一实现它的源** | ✗ | 直给 |
| `anirss` | **账密**（密码 MD5，令牌走 header + `?s=`） | ✗（默认 unsupported） | ✗ | ✗ | ✗ | 直给 |
| `aliyundrive` | **扫码** | ✅ `file/search`（逐盘打一遍） | ✗ | ✗ | ✅ refresh_token + device_id | 直给 |
| `baidu` | **扫码** / **手动粘 Cookie(BDUSS)** | ✅ `/api/search` | ✗ | ✗ | ✗ | 直给 |
| `pan115` | **手动粘 Cookie**（须含 UID 或 SEID） | ✅ `/files/search` | ✗ | ✗ | ✗ | 直给 |
| `pan189` | **扫码** / **手机号+密码(RSA)** | ✗ | ✗ | ✗ | ✅ access_token(+refresh) | 直给 |
| `pan139` | **扫码** / **手机号+密码** / 手动粘 Authorization | ✗ | ✗ | ✗ | ✗ | 直给 |
| `smb` | 地址 + 账密（支持 `域\用户`） | ✗ | ✗ | ✗ | ✗ | **本地桥** |
| `webdav` | 地址 + Basic（可匿名） | ✗ | ✗ | ✗ | ✗ | 直给（同一 URL + Basic 头） |
| `ftp` | 地址 + 账密（**空账号 → 匿名**） | ✗ | ✗ | ✗ | ✗ | 直给（`ftp://`，非 HTTP） |
| `local` | 系统文件夹选择器（无凭据） | ✗ | ✗ | ✗ | ✗ | **裸路径** |
| `plugin:*` | 插件 manifest 声明的表单字段 | 插件决定（未实现→Null→unsupported） | 插件决定 | ✗ | ✗ | 插件返回什么就是什么 |

登录方式的**命令层落点**（`apps/desktop/src/lib.rs`）：
- 表单登录 → `source_login`（`:3515`），四个扫码源以外全走它
- 扫码 → `source_qr_start` / `source_qr_poll`（`:3581, 3595`），只认 **baidu / aliyundrive / pan189 / pan139**
- 账密（手机号）→ `source_password_login`（`:3614`），只认 **pan189 / pan139**
- **夸克 TV 扫码是另一对独立命令** `quark_scan_start` / `quark_scan_poll`（`:3807, 3818`），**不走** `source_qr_*`，理由见 §5.6

---

## 4. 签名与加密算法

> **每个算法的常量（模数、公钥、XOR 表、AppId、SignKey、UA）都不复制到本文。**
> 表里给出常量所在行，Go 侧从源码逐字抄。

### 4.1 115 网盘：**不是 secp256k1**——是"名叫 RSA 实为混淆"的公钥模幂（m115）

⚠️ **纠正 `docs/go-migration/MIGRATION.md:165` 的库选型**：那行写着 115 用 `decred/.../secp256k1`。
**代码里 115 一个椭圆曲线都没用。** 依据 `pan115_crypto.rs:1-9`：

> 名叫 RSA，实为混淆：**加密和解密都用公钥做模幂**（m^E mod N），全程没有私钥参与。
> 所以这里不引 `rsa` crate —— 那套私钥/OAEP/签名校验一个都用不上，要的只有一次大数模幂。
> ★ **别被"接 115 要移植一大堆密码学"带偏**：115driver 里那套 ec115（ECDH / P-224 / AES / LZ4）**只用于上传**；
> 下载走的是这里的 m115。**播放器不上传**，所以 P-224 曲线在 RustCrypto 有没有对应 crate 这个问题跟我们无关。

（真正用 secp256k1 的是**阿里云盘**，见 §4.5。）

**常量位置**：模数 `pan115_crypto.rs:17-22`、指数 `:23`、`XOR_KEY_SEED[144]` `:27-37`、`XOR_CLIENT_KEY[12]` `:39-41`。

**推导量**（`:60-63`，测试 `:161-168` 钉死）：
```
key_len   = N.bits() / 8 = 128 字节   ← 是 1024 位，不是 2048
slice_max = key_len - 11 = 117 字节   ← 不是 245
```
> 这条钉的是调研里被写错的那个常数。二手情报说这套是「256 字节 / 2048 位 RSA、分块 245」。
> **抄成 256 的后果：分块长度全错，请求发得出去、服务端静默拒绝，没有任何一行报错指向真因。**（`:158-160`）

**`xor_derive_key(seed, size)`**（`:65-72`）
```
for i in 0..size:
    key[i] = (seed[i] + SEED[size*i]) mod 256      // wrapping_add
    key[i] ^= SEED[size*(size-i-1)]
```
size 最大 12 → 最大下标 132，故表必须 ≥133 字节（实际 144）。

**`xor_transform(data, key)`**——**错位是算法的一部分，不是笔误**（`:74-85`）
```
head = len(data) % 4
for i in 0..head:      data[i] ^= key[i % len(key)]
for i in head..len:    data[i] ^= key[(i - head) % len(key)]
```
> 简化成 `key[i % k]` 会让整段密文对不上。（`:75`）

**`rsa_encrypt(input)`**（`:87-112`）：按 `slice_max` 切块，每块做 PKCS#1 v1.5 **type-2** 填充后 `m^E mod N`：
```
block = [0x00, 0x02] ++ PS(pad_size 字节，每字节 = rand % 0xff + 0x01) ++ [0x00] ++ chunk
pad_size = key_len - len(chunk) - 3
out += 左侧补零到 key_len 的 (block^E mod N)     ← 补零必做
```
> `to_bytes_be` 会吃掉前导零，**必须补回定长，否则下一块的起点就错位了**。（`:107`）

**`rsa_decrypt(input)`**（`:114-125`）：按 `key_len` 切块 → `c^E mod N` → 找**第一个下标非 0 的 0x00** 分隔符，取其后。

**`encode(input, key16)` → form 字段 `data`**（`:127-136`）
```
buf = key16 ++ input
xor_transform(buf[16..], xor_derive_key(key16, 4))
reverse(buf[16..])
xor_transform(buf[16..], XOR_CLIENT_KEY)
return base64(rsa_encrypt(buf))
```

**`decode(b64, key16)`**（`:138-152`）
```
data = rsa_decrypt(base64_decode(b64))        // 必须 > 16 字节
out  = data[16..]
xor_transform(out, xor_derive_key(data[..16], 12))   // 注意 size=12，且种子是响应头 16 字节
reverse(out)
xor_transform(out, xor_derive_key(key16, 4))          // size=4，种子是请求时那把
```

**★ encode 与 decode 不是互逆运算**（`:243-252`）——这条必须原样带进 Go：
> 直觉上会想写"encode 出去再 decode 回来 == 原文"，但 **encode 处理的是发往服务端的请求体**（服务端有对应的 decode），
> **decode 处理的是服务端发回的响应体**（服务端有对应的 encode）。两者是两条独立的数据流，客户端侧串起来不构成 roundtrip
> ——**实测串起来确实不还原（这个假设试过、红了）**。
> 因此本模块**无法纯本地自证算法与服务端一致**，端到端正确性只有挂真实账号才能确认。

**用法**（`pan115.rs:229-256`）：`key = random 16 字节` → `payload = {"pickcode": <pc>}` →
`POST <115 直链主机>/app/chrome/downurl?t=<unix秒>`，form `data=<encode 结果>` →
响应 `data` 是密文 → `decode` → JSON 形如 `{"<file_id>": {file_name, file_size, url:{url}}}`，
**键名是文件 id，事先不知道，故取第一个值**（`:260-266`）。

**Go 库**：`math/big`（`Int.Exp`）+ `crypto/rand`。**不要引 `crypto/rsa`**——它不做无私钥的公钥模幂。

### 4.2 天翼 189：会话签名（AES-ECB 参数 + HMAC-SHA1）

`pan189.rs:6-9` 的头注释就是完整规格（「算法逐字节抄自 OpenList 189pc/help.go」）。

**参数加密 `encrypt_params`**（`:231-257`）
```
若 params 为空 → 返回空串（不加密，也不进签名）
sorted = params 按 key 升序
plain  = join("&", "k=" + urlencode(v))
key    = sessionSecret 的前 16 字节（不足补零，不 panic）
data   = PKCS7(plain, 16)
输出   = UPPER(hex(AES-128-ECB-Encrypt(key, data)))     ← 逐块 ECB
```

**签名 `sign_hmac`**（`:259-278`）
```
data = "SessionKey={sk}&Operate={GET}&RequestURI={path}&Date={date}"
若 enc_params 非空: data += "&params=" + enc_params
输出 = UPPER(hex(HMAC-SHA1(sessionSecret, data)))
```
> 「参数非空时**必须追加** `&params=`；这段漏了服务端算出的签名对不上，**全 401**」（测试 `:821-830`）。

**请求头**（`:192-200`）：`Date`（RFC1123 GMT，**与签名明文里那个必须同一个值**）、`SessionKey`、`Signature`、`X-Request-ID`（UUIDv4，`:287-298`，服务端不校验强度）、`Accept`。
`params` 和固定后缀 `CLIENT_SUFFIX`（`:31-36`）作为 query。

**会话建立**（`:65-110`）：`accessToken` → `GET /getSessionForPC.action` → `sessionKey` + `sessionSecret`。
失败时**第一轮**用 `refresh_token` 换新 access（`:100-105`），换到就记进 `rotated`（`:140-153`）。
`res_code != 0` 且消息含 `session`/`Session`/`InvalidSessionKey` → 清缓存重建一次（`:208-220`）。

**Go 库**：`crypto/aes`（`NewCipher` + 手写 ECB 逐块）、`crypto/hmac` + `crypto/sha1`、`net/http` 的 `http.TimeFormat`（就是 RFC1123 GMT）。
⚠️ Go 标准库**没有 ECB 模式**（故意的），必须自己 `for` 循环调 `block.Encrypt`。

### 4.3 天翼 189：账密登录的 RSA（手做，非 `crypto/rsa`）

`pan189.rs:542-549` 头注释：
> 逐步照 cloudpan189-api/login.go + AList 189pc/utils.go 落：
> `unifyLoginForPC` 抠 lt/paramId/captchaToken → `encryptConf` 拿 RSA 公钥 → RSA 加密账号密码 → `needcaptcha` 判图形码 → `loginSubmit` 拿 toUrl → `getSessionForPC` 换令牌。
> RSA 是 **RSA/ECB/PKCS1**，密文取**小写 hex**，前缀 `{RSA}`（**开源的 `b64tohex(base64(ct))` 净效果就是 `hex(ct)`**）。
> `ponytail:` 不引 rsa crate —— 只需公钥加密，填充+模幂用已在树里的 num-bigint/rand 手做（与 115 同策）。

三个手写件：

1. **DER TLV 读取 `der_read`**（`:684-707`）：只覆盖 SPKI 里出现的短/长形式，长度字节数 >4 直接 None。
2. **SPKI 解析 `parse_spki_rsa`**（`:709-731`）：
   `SEQ{ SEQ{OID,NULL}, BITSTRING{ SEQ{INT n, INT e} } }`；**BIT STRING 首字节是 unused-bits 计数，要跳过**（`:720`）。
3. **PKCS#1 v1.5 填充 `pkcs1v15_pad`**（`:733-759`）：
   `EM = 0x00 || 0x02 || PS(≥8 字节，全部非零随机) || 0x00 || M`，总长 = k；`len(M)+11 > k` 直接拒绝。

`rsa_encrypt_field`（`:761-786`）：
```
清洗公钥（容忍 PEM 头尾/换行/空白）→ base64 decode → parse_spki_rsa → (n, e)
k  = (n.bits() + 7) / 8
em = pkcs1v15_pad(明文, k)
c  = em^e mod n，左侧补零到 k
返回 pre + LOWER(hex(c))          // pre 通常是 "{RSA}"
```
公钥来源（`:660-682`）：`POST /api/logbox/config/encryptConf.do` 取 `data.pubKey` / `data.pre`；
**任何一步失败退回内置常量**（`RSA_PUBKEY_FALLBACK`，`pan189.rs:552`，1024 位 SPKI base64）。

登录提交表单字段见 `:622-637`；关键：`accountType`、`validateCode` 空、`captchaToken` 从登录页正则抠、
`mailSuffix`、**`dynamicCheck` = `"FALSE"`**、`isOauth2`、`state` 空。
`result != 0` → auth 错误；成功取 `toUrl` → 与扫码**共用** `exchange_session`（`:513-540`）。

图形验证码（`:595-614`）：`needcaptcha.do` 返回非 `"0"` → **直接让用户改走扫码**（本 MVP 不接图形码 UI 往返）。

**Go 库**：这条在 Go 里**可以大幅简化**——`encoding/asn1` + `crypto/x509.ParsePKIXPublicKey` 拿 `*rsa.PublicKey`，
再 `rsa.EncryptPKCS1v15(rand.Reader, pub, msg)`，然后 `hex.EncodeToString`。
⚠️ 但**必须逐字节对账**：Go 的 `EncryptPKCS1v15` 输出定长 k 字节（和这里补零后一致），前缀和大小写要手工加。

### 4.4 移动云 139：`mcloud-sign` + 本地算 Authorization

`pan139.rs:1-18` 头注释是完整规格。

**`cal_sign(body, ts, randStr)`**（`:450-462`）
```
enc    = encodeURIComponent(body)          ← JS 口径，见下
chars  = enc 的字符逐个排序（升序）
b64    = base64(join(chars))
part1  = md5_hex(b64)
part2  = md5_hex(ts + ":" + randStr)
sign   = UPPER(md5_hex(part1 + part2))
header: mcloud-sign: "{ts},{randStr},{sign}"
```
`ts` = 毫秒时间戳，`randStr` = 8 随机字节的 hex（`:464-468`）。

**`encode_uri_component`——不能用通用 urlencode**（`:434-448`）
> JS `encodeURIComponent` 的忠实复刻：只放行 `A-Za-z0-9` 与 `-_.!~*'()`，其余按 UTF-8 字节百分号**大写**十六进制编码。
> **不能用通用 urlencode**（那会把 `!~*'()` 也编码，签名就对不上服务端）。

排序说明（`:454`）：encodeURIComponent 输出纯 ASCII，按 char 排序 == 按字节排序。

**Authorization 是客户端自算的**（`:6-9, 224-229`）——这是本源最重要的逆向成果：
```
Authorization = "Basic " + base64("pc:" + 手机号 + ":" + data.token)
```
> **服务端从不下发现成串**，是客户端自算的（逆向自 `enCodeToken`）。所以拿到 token 就能离线算出 Authorization，
> **不必再手动抓浏览器**（手动粘贴保留兜底）。

已知答案测试 `:531-540`：`compute_authorization("1","2") == "Basic cGM6MToy"`。
归一化（`:44-59`）：用户可能只贴 base64 主体，也可能带 `Basic ` 前缀，统一补上。

**登录 `/thirdlogin`**（`:298-337`）：密码与扫码**同端点**，靠 `pintype` 区分（**密码 9 / 扫码 21**）；
`dycpwd` 装**密码明文**或**扫码会话 ID**；`secinfo = UPPER(hex(SHA1(<SECINFO_PREFIX> + ":" + dycpwd)))`（`:217-222, 317`）。
成功后 `data.token` → 本地算 Authorization。

> ⚠️ 文件头注释 `:5, :17` 写的是 `pintype=9` / `type=5`，与实现里的 `9` / `21` 有出入。**以代码为准**（`:295, :378`）。

**响应成功判定 `resp_ok`**（`:231-244`）：`success` 布尔优先 → `code` ∈ {`0`, `"0"`, `"000000"`, `"S000000"`} → **无 code 字段不算失败**（以 `data.token` 存在为准）。

**Go 库**：`crypto/md5`、`crypto/sha1`、`encoding/base64`。
⚠️ `encodeURIComponent` 必须自己写，`net/url.QueryEscape` 和 `PathEscape` 都**不对**。

### 4.5 阿里云盘：secp256k1 ECDSA `x-signature`

`aliyundrive.rs:1-11` 头注释：
> 拿不到开放平台 token（那要开发者 App），只能走网页版 API，代价是必须复刻 2023-02-13 起强制的 `x-signature`：
> **secp256k1 ECDSA（SHA256 预哈希）**对 `"{AppId}:{DeviceId}:{UserId}:{Nonce}"` 签名，
> 输出 `hex(r‖s) + "01"`；公钥（未压缩 `04‖x‖y`）先经 `create_session` 注册到 device_id 上。
> 算法逐字节抄自 tickstep/aliyunpan-api（Go）+ 其 secp256k1 库，**曲线/预哈希/字节序都核过**。

```
key       = 随机 32 字节私钥（必须落在 [1,n)，超界重摇）          :353-362
pub_hex   = hex(未压缩公钥)  = "04" + x + y = 130 hex 字符        :364-368
data      = "{APP_ID}:{device_id}:{user_id}:{nonce}"             :372
signature = hex(r‖s) + "01"  = 128 + 2 = 130 字符                :374-375
```
`SigningKey::sign()` **内部先做 SHA256 再签**，与 Go 侧一致（`:373`）。
形状测试 `:693-704`：公钥 130 且以 `04` 开头，签名 130 且以 `01` 收尾。

**签名是 per-session 的**（`:51-52`）：`nonce` 固定 0，`CalcNextSignature` 在上游源码里注释掉了，**换会话才重签**。

`device_id`：24 位字母数字随机串（`:378-384`），**首次生成后必须持久化**（走 `take_rotated_credentials`，`:131-138`）。

**会话建立四步**（`:93-171`）：
1. `POST /v2/account/token` （`refresh_token` + `api_id` + `grant_type`）→ `access_token` / `user_id`；**refresh_token 变了就记进 rotated**（一次性）
2. 取或生成 `device_id`
3. 生成密钥 + 签名
4. `POST /users/v1/users/device/create_session`，`Bearer` + `x-device-id` + `x-signature` header，body `{deviceName, modelName, pubKey}`。
   **失败要抛**——「不注册后续全 401」（`:145`）。注意：`success` 字段可能缺失，只有显式 `false` 才判失败（`:162-166`）。

后续每个请求：`Bearer access_token` + `x-device-id` + `x-signature`（`:199-207`）。
401 或 400 且 code 含 `Device`/`Signature`/`Token` → 重建会话重试一次（`:210-225`）。

**Go 库**：`decred/dcrd/dcrec/secp256k1/v4`（含 `ecdsa` 子包）或 `ethereum/go-ethereum/crypto`。
⚠️ 输出必须是 **raw `r‖s` 各 32 字节定长**，**不是 DER**；末尾那个 `01` 是恢复位/版本位，手工拼。

### 4.6 飞牛影视：`authx`（纯 md5 拼接）

`feiniu.rs:47-64`
```
nonce      = 6 位数字（纳秒派生，服务端只校验 sign 内一致性，不验随机质量，:38-45）
ts         = 毫秒时间戳
data_hash  = md5_hex(body)              // GET 时 body 是空串 → md5("")
sign       = md5_hex(join("_", [SIGN_SECRET, path, nonce, ts, data_hash, API_KEY]))
header authx: "nonce={nonce}&timestamp={ts}&sign={sign}"
```
`path` 是**带 `/v/api/v1` 前缀的完整 API 路径**（`:47`）。
常量 `SIGN_SECRET` / `API_KEY` 在 `feiniu.rs:15-16`（注释注明是**飞牛客户端硬编码，非用户密钥**）。

**★ authx 不能带在 `media/range` 上**（`feiniu.rs:560-563, 652-659`）——本源最贵的坑：
> 它是**构造时算死的一次性签名**，而取流是几小时的长连接——过期后服务端拒收，**表现为"看着看着断流"**。
> 官方客户端的 `media/range` 本就只发 `Authorization` + `Cookie`，**authx 是多发的，发了才是病根**。

反例对照：**字幕下载可以带静态 authx**，因为它是一次性下载（`:201-203`）。
专门抽出 `media_range_headers()` 一个函数就是为了让测试 `:693-703` 钉死这两个头、断言 `len == 2`。

登录（`:223-258`）：`POST /v/api/v1/login`，body `{app_name, username, password, nonce}`，
**密码明文**（`:231`：「与飞牛 web/PC 一致，无 RSA/MD5 预处理」），header `Cookie: <固定中继标记>` + `authx`。
响应 `{code,msg,data}`，`code != 0` 即错（`:66-73`）。

`/stream` 的 `ip` 参数（`:661-671`）：**不是真 IP**，是**账号派生的稳定标识**——`md5(username)` 排成 UUID 形状。

**Go 库**：`crypto/md5`，无第三方依赖。

### 4.7 夸克 TV OAuth：`x-pan-token`

`quark_tv.rs:47-57`
```
tm     = 毫秒时间戳
req_id = md5_hex(device_id + tm)
token  = sha256_hex(method + "&" + pathname + "&" + tm + "&" + SIGN_KEY)
headers: x-pan-tm: tm / x-pan-token: token / x-pan-client-id: CLIENT_ID
```
常量 `CLIENT_ID` / `SIGN_KEY` / `APP_VER` / `CHANNEL` 在 `quark_tv.rs:11-16`。
`device_id` = `md5_hex("linplayer-quark-" + 纳秒)`，**每安装生成一次并存进凭据**（`:38-45`）。
公共 query 是一整套伪装成某型安卓 TV 的设备字段（`:59-78`）。

**令牌兑换走第三方代理**（`:3, :180-217`）：`POST <代理主机>/token`，
body 里 `code`（首次）或 `refresh_token`（刷新）二选一，其余设备字段与公共 query 同构。
注释直言「TV 驱动既定做法」「**全逆向接口，需真机+扫码验证**」。

**Go 库**：`crypto/md5`、`crypto/sha256`。

### 4.8 夸克 Cookie 模式：无签名，只有 Cookie 轮换

`quark.rs:153-211`：query 固定带 `pr`/`fr` 两个参数，header 带 `Cookie` / `Referer` / 客户端 UA。
**每次响应都要吸收 `Set-Cookie` 里的 `__puus` / `__pus` 写回内存 Cookie**（`:134-151`，`replace_cookie` `:33-50`）。
成功判据 `data.status == 200`；`status==400` 且 `code ∈ {31001,31002,31003,31023}` → `is_auth`（`:198-203`）。

### 4.9 WebDAV / FTP / SMB / OpenList / Ani-RSS

| 源 | 鉴权 | 出处 |
|---|---|---|
| WebDAV | `Authorization: Basic base64("user:pass")`，**用户名为空 = 匿名，不发这个头** | `webdav.rs:34-46` |
| FTP | 凭据进 URL userinfo，**必须百分号编码** | `ftp.rs:132-151` |
| SMB | 用户名里的 `域\用户` 要拆成 `domain` + `username` 两个字段，「整串塞进 username 认证必失败」 | `smb.rs:89-93` |
| OpenList | `POST /api/auth/login` 拿 JWT，放 `Authorization`（**裸 token，无 Bearer**）；`code==401` 自动重登一次 | `openlist.rs:23-49, 86-123` |
| Ani-RSS | `POST /api/login`，密码 **md5 hex 小写**，`data` 是登录令牌；header 带令牌，**URL 类资源走 `?s=<令牌>`**（URL 带不了 header） | `anirss.rs:32-59, 352-358` |

---

## 5. 扫码登录状态机

统一契约（`mod.rs:349-368`）：

```
QrStart { image: String, ctx: String }
  image —— 既可能是 data URI（核层自己渲的二维码），也可能是一个图片 URL（网盘直接给图）
  ctx   —— 轮询上下文（uuid/sign/sid…）的 JSON 字符串，前端不解读只回传

QrPoll (serde tag = "state", snake_case)
  ├─ Pending                          还没扫 / 已扫未确认 → 前端继续轮询
  ├─ Confirmed { credentials: Map }   凭据到手，直接并进新建 SourceServer 的 extra 后落盘
  └─ Expired                          二维码过期 → 前端重新 start
```

### 5.1 阿里云盘

```
start: GET <passport>/newlogin/qrcode/generate.do?appName=&fromSite=&appEntrance=&_bx-v=
       → content.data.{codeContent, t, ck}
       image = qr_svg_data_uri(codeContent)          ← 核层渲，codeContent 是待渲染文本
       ctx   = {t, ck}                                ← t 是数字，原样 to_string
poll : POST <passport>/newlogin/qrcode/query.do   form{t, ck, appName}
       content.data.qrCodeStatus:
         "CONFIRMED"           → 从 bizExt 抠 refresh_token → Confirmed{refresh_token}
         "EXPIRED" | "CANCELED"→ Expired
         其它（NEW / SCANED）  → Pending
```
`aliyundrive.rs:560-618`。

**`bizExt` 的解码**（`:620-643`）——一个有意的取巧：
> `bizExt = base64(可能 gzip 的 JSON，昵称字段可能是 **GB18030**)`。
> refreshToken 本身是 ASCII，**直接在 lossy 文本上正则抠，绕开整段 charset 解码**。
判 gzip 靠魔数 `1f 8b`。测试 `:716-732` 两种形态都钉了。

### 5.2 天翼 189

```
start: 1) GET <web>/api/portal/unifyLoginForPC.action  → HTML，正则抠 lt / paramId / reqId
       2) POST <auth>/api/logbox/oauth2/getUUID.do  form{appId}  header{Referer, lt, REQID}
          → {uuid, encryuuid}
       3) image = qr_svg_data_uri(uuid)              ← 二维码内容就是 uuid 本身
          ctx   = {uuid, encryuuid, paramId, lt, reqId}
poll : POST <auth>/api/logbox/oauth2/qrcodeLoginState.do
          form{appId, clientType, returnUrl, paramId, uuid, encryuuid, date, timeStamp}
          header{Referer, lt, REQID}
       status:  0      → 取 redirectUrl → exchange_session → Confirmed{access_token[, refresh_token]}
               -11001  → Expired
               其它    → Pending  （-106 待扫 / -11002 待确认）
```
`pan189.rs:418-511`。`exchange_session`（`:513-540`）**与账密登录共用**——
`POST /getSessionForPC.action?redirectURL=…` 换 `accessToken` / `refreshToken`。

### 5.3 百度

```
start: GET <passport>/v2/api/getqrcode?apiver&tpl&lp&qrloginfrom&gid   （gid 自造，UUID 版式大写 hex）
       → {sign, imgurl}
       image = imgurl（**网盘直接给图**；imgurl 是无协议相对地址，补 https）
       ctx   = {sign, gid}
poll : 1) GET <passport>/channel/unicast?apiver&tpl&gid&channel_id=sign&_sdkFrom
          → channel_v 是**一个 JSON 字符串**，要二次 parse
          channel_v 为空 → Pending（还没扫）
          status: 0 → 继续；1 → Pending（扫了未确认）；其它 → Pending
          取 v = bduss_code
       2) GET <passport>/v3/login/main/qrbdusslogin?bduss=<code>&u=&loginVersion&qrcode&tpl&apiver
          **读原始 Set-Cookie 响应头**，只保留 BDUSS / STOKEN / PTOKEN / PANWEB / BDUSS_BFESS
          拼成 "k=v; k=v" → Confirmed{cookie}
          拼不出 BDUSS → Pending（code 还没生效或已过期）
```
`baidu.rs:276-386`。`gen_gid` `:259-273`。

⚠️ 头注释自标 **UNVERIFIED**（`:255-257`）：
> 百度扫码是 JSONP 老接口，gid/tt/回调那套**没有官方文档**，只能靠社区脚本复刻。
> 真机跑不通时，**手动粘贴 BDUSS Cookie 那条路仍在**，不至于把用户堵死。

### 5.4 移动云 139

```
start: **不请求服务端。** sID / dID 客户端自生成随机串
       二维码内容 = "<139 网页版 qrcLogin 地址>?sID={sid}&dID={did}&cType=9"
       image = qr_svg_data_uri(该文本)
       ctx   = {sID}
poll : POST <user 主机>/user/thirdlogin  {msisdn:"", dycpwd: sID, pintype: 21,
                                          secinfo: SHA1_UPPER(<SECINFO_PREFIX> + ":" + sID), …}
       resp_ok 且 data.token 非空 →
           手机号从 data.encryptAccount（**base64 的真实手机号**）解出，缺失退回 simplifyAccount（脱敏）
           → Confirmed{authorization = compute_authorization(手机号, token)}
       data.result.resultCode（可能是字符串或数字）:
           已失效码 / 已取消码 → Expired
           其它（含"已扫待确认"码）→ Pending
```
`pan139.rs:339-424`。具体三个 resultCode 数值在 `:345, :405`。

### 5.5 各家状态机的形状差异（Go 侧要按源分别建模，不要抽公共枚举）

| 源 | 二维码内容来源 | 状态字段 | Pending 的表示 |
|---|---|---|---|
| 阿里 | 服务端给待渲染文本 | 字符串枚举 | `NEW` / `SCANED` |
| 189 | 服务端给 uuid（就是内容） | 有符号整数 | 负数码 |
| 百度 | **服务端给图 URL** | 嵌套 JSON 字符串里的 `status` | 字段缺失 / 1 |
| 139 | **客户端自造 URL** | 嵌套 `result.resultCode`（字符串或数字） | 除两个终态码外全是 |
| 夸克 TV | **服务端给 base64 PNG** | 无状态字段，靠"取 code 是否为空" | `get_code` 报错或空 |

### 5.6 夸克 TV：`qr_data` 是 **base64 PNG 不是文本**，且走独立命令对

这是一个用户可见故障的完整闭环记录。

**现象**（`quark_tv.rs:356-357`）：用户报「夸克网盘根本生不出来二维码，报错 *The amount of data is too big to be stored in a QR Code*」。

**推理**（`:357-359`）：我们向 `/oauth/authorize` 传了 `qrcode=1&qr_width=&qr_height=`——
> 这两个参数**只有在「服务端渲染一张图」时才有意义**。若 `qr_data` 是 base64 图，那前端再拿它去 `QRCode.toDataURL()`
> 就是**给一张二维码图再编一个二维码**，必然超容量。

**验证**（`:363-382`）：写了一条 `#[ignore]` 的联网测试 `quark_qr_data_shape` 打真接口打印形状，
判据是「二维码（纠错级 M）物理上限约 2.3KB，超过就说明它不是待编码的文本」。
跑法：`cargo test -p linplayer-core quark_qr_data_shape -- --ignored --nocapture`。

**实测结论**（记在前端 `ui/desktop/pages/sources/sourceForms.tsx:124-132`）：
> 长度 **4860**，开头 `iVBORw0KGgo` = **PNG 文件头**。喂给 `QRCode.toDataURL` 必然报容量超限（纠错级 M 上限 ~2.3KB）。
> 用户报的「夸克网盘根本生不出来二维码」就是这个，**和「扫码搬配置」那个容量问题无关**。

**修法**：前端拆成三个组件（`sourceForms.tsx:133-152`）——
- `ServerQr({b64})` → `<img src="data:image/png;base64,…">`，**夸克专用**
- `SourceQr({src})` → 核层已渲成 data URI（阿里/189 是 SVG）或直接给图 URL（百度），**原样当 `src`，前端不再编码**
- `Qr({data})` → **只给真·文本载荷用**（如扫码搬配置的同步串）

**命令层也是独立的**：`quark_scan_start` / `quark_scan_poll`（`apps/desktop/src/lib.rs:3807, 3818`），
返回 `{device_id, qr_data, query_token}` 而不是 `QrStart`。`quark_scan_poll` 成功后**直接把源设成活跃源**
（id 固定为一个常量串，`base_url` 为空，`:3833-3841`），不走 `source_login`。

> **Go 侧**：`QrStart.image` 的"既可能是 data URI 也可能是 URL"这条多态必须保留；
> 夸克那条**要么并进 `QrStart` 并在核层包成 `data:image/png;base64,`**，要么照样独立。
> 无论哪种，**核层都不能把已经是图的东西再编码一次**。

---

## 6. 协议适配坑

### 6.1 SMB 桥：`Connection: close` 不是可选项

`localserve.rs:110-113`
> 我们每条连接只读一个请求，而 HTTP/1.1 默认长连接——**不写这个头就是在向播放器承诺「还能再发」**。
> ffmpeg 一 seek（**MKV 索引在末尾，起播必 seek**）就把下一个 Range 管线化到同一条 socket 上，
> **那个请求没人读，响应永远不来 = 有流量、黑屏无声。prefetch 那边就是这么炸的。**

测试 `always_declares_connection_close`（`localserve.rs:233-241`）。

### 6.2 SMB：为什么是 `smb2` 这个 crate

`smb.rs:10-13`
> 纯 Rust、无 build.rs、无 C 依赖——**安卓交叉编译能过**（已用 `scripts/check-android.sh` 验）。
> 更关键的是它有 `FileReader::read_at(offset, len)`：**视频要 seek，只能顺读的实现等于不能用**。
> libsmbclient 系（pavao）是 C FFI，**安卓上这条路直接堵死**。

其它 SMB 细节：
- 地址四种写法都要认（`smb://` / 裸 host / UNC `\\host\share` / `host:port`），`host_port` `:48-70`，测试 `:270-282`
  理由：「用户会从四个地方抄地址来：资源管理器（UNC）、别的播放器、自己记的 IP、带端口的」
- **根目录必须过滤管理共享**（`:129-133`）：「IPC$ / ADMIN$ / C$ 这类点进去不是权限不足就是空的，
  **摆在第一屏只会让用户以为源坏了**」。用 crate 自带的 `filter_disk_shares`，「免得自己把 STYPE 的位运算抄错」
- 连接策略：**不做连接池**（`:15-18`，带 `ponytail:` 标注）
- `auto_reconnect: true` 的理由（`:101-103`）：「Wi-Fi 漫游、NAS 硬盘转起来这类断连在家用环境里是常态，
  而它**只会重放「重放了也不改变语义」的操作**（读、列目录），不会替我们重发写操作」
- 超时用 15 秒而非 5 秒（`:96-97`）：「5 秒对局域网够，但**对刚从休眠里醒过来的 NAS 偏紧**」
- 鉴权失败要标 `is_auth`——靠错误消息关键词识别（`:113-127`）

### 6.3 WebDAV：href 双前缀（只有子目录才 404）

`webdav.rs:69-77`——本源最贵的坑：
> ★ 拼的是 **origin**，不是 `base_url`。`entry.id` 来自响应里的 `href`，而 **href 是服务端绝对路径**（已经含了 `base_url` 里那截前缀）。
> 拿它去接 `base_url` 会拼出 `/dav/dav/剧集` 这种双前缀——**根目录能列、点进任何子目录必 404**，
> 而且**只在「base_url 带路径」的服务端上犯**（Nextcloud 全中，群晖常中）。

修法：`split_base()` 把 base_url 拆成 `(origin, 根路径)`（`:48-67`），`url_for()` 只拼 origin（`:78-86`）。
`dir_id` 一律用**服务端绝对路径**，与 href 口径统一（`:297-298`）。
测试 `entry_id_round_trips_when_base_url_has_a_path`（`:415-433`）做完整往返。

**其它 WebDAV 坑**：

| # | 坑 | 出处 |
|---|---|---|
| a | **不能用现成 dav crate**：本仓 reqwest client 挂着按 host 的自签名证书白名单（`HostAllowlistVerifier`）+ 全局代理，现成 crate 自建 Client 会**全部绕过**——而 WebDAV 的典型对端就是**家里那台自签名证书的 NAS** | `webdav.rs:4-10`；verifier 在 `crates/core/src/http.rs:136-185` |
| b | **不能按 `d:response` 这种带前缀的字面量匹配**：前缀是各家自选的（Apache `D:`、Nextcloud `d:`、也有设成默认命名空间不带前缀）。一律取**本地名**再比 | `webdav.rs:129-131, 145-148`；测试 `:384-389` |
| c | **不能开 `trim_text`**：quick-xml 0.41 把 `Tom &amp; Jerry` 拆成 `Text("Tom ") + GeneralRef + Text(" Jerry")`，两截各自被 trim 掉尾空格，拼回来变成「Tom&Jerry」——**名字里的空格就这么没了，还不报错** | `webdav.rs:133-136` |
| d | **实体必须自己拼回去**：0.41 起实体不再并进 Text 而是单独发 `GeneralRef` 事件。写成赋值而不是**追加**，文件名就只剩最后一截，**不报任何错**。具名实体只认 XML 预定义的五个，其余原样留着别猜 | `webdav.rs:192-212`；测试 `:394-409`（连 `getcontentlength` 被实体打断丢值也钉了） |
| e | **路径逐段编码，斜杠不能编码**：整串 encode 会把 `/` 变成 `%2F`，「服务端看到的就成了一个名字里带斜杠的文件，必 404」 | `webdav.rs:76-77`；测试 `:446-451` |
| f | **Depth:1 的第一条永远是被请求的目录自己，必须剔掉**：「不剔掉的话点进任何目录都会看到一个指向自己的条目，**一路点下去无限套娃**」 | `webdav.rs:255-259` |
| g | **href 是百分号编码的，要解回真实路径**才能当下一次 PROPFIND 的入参，否则**二次编码** | `webdav.rs:249-252`；测试 `:374-377` |
| h | 只问四个属性不要 `<allprop>`：「某些服务端（**Nextcloud 尤其**）会把一大堆自有属性一起塞回来，响应体大好几倍还更容易解析出岔子」 | `webdav.rs:19-24` |
| i | 405 要给专门提示：「这个地址不支持 PROPFIND，可能不是 WebDAV 服务」——基本都是把普通 http 服务当 WebDAV 填了 | `webdav.rs:114-119` |

### 6.4 FTP：`parse::<FtpFile>()` 的 MLST 兜底会造假文件

`ftp.rs:94-99`——
> ★ **不能用 `line.parse::<FtpFile>()`。** 它的链是 posix → dos → mlsd → **mlst**，
> 而最后那个 `parse_mlst` 是给「查单个文件」用的**宽松格式：随便一行文本都能被它认成一个名字**。
> 于是 `total 42` 这种 LIST 头、服务端的欢迎语、乱码行，**统统会变成目录里一个假文件，点进去必然播放失败**。
> 所以这里**按来源指定解析器**，不给兜底那条留门。

实现：`mlsd=true` → 只用 `parse_mlsd`；否则 `parse_posix` 失败再试 `parse_dos`（`:100-130`）。
解析不了的行**跳过而不是报错**——「LIST 没有标准格式，一行解不动不该让整个目录列不出来」（`:92-93`）。
测试 `parses_posix_listing_and_drops_junk_lines`（`:247-268`）在语料里**故意放了 `total 42` 和一行乱码**，断言只剩 3 条。

**其它 FTP 坑**：

| # | 坑 | 出处 |
|---|---|---|
| a | **先 MLSD 再退 LIST**：MLSD（RFC3659）是机器可读的，类型和大小都是带名字的字段；LIST 是给人看的 `ls -l`，各家格式不一，「**猜错列就会把日期当成文件名**」。老服务端不认 MLSD 所以必须留退路。判据是 `Ok(l) if !l.is_empty()` | `ftp.rs:179-192` |
| b | **必须显式切二进制**：「ASCII 模式下服务端会改写换行，**视频文件当场损坏**——而 RFC959 规定的**默认就是 ASCII**，不显式切就是踩着默认值发车」 | `ftp.rs:84-88` |
| c | **凭据必须百分号编码进 userinfo**：「密码里一个 `@` 或 `:` 就会把 URL 切在错的地方——表现是「**密码里带符号的人永远登录失败**」，而且报的是连接错误，看不出是自己拼错了 URL」 | `ftp.rs:134-136`；测试 `:288-300` 顺带断言 `u.matches('@').count() == 1` |
| d | **空账号 = 匿名**：「不少 NAS/公共站就是这么开的，**硬塞空账号会被拒**」 | `ftp.rs:65-72` |
| e | **不能走 `normalize_base_url`**（它补 https） | `ftp.rs:28-29` |
| f | QUIT 失败无所谓：「目录已经拿到了，为了一句 QUIT 让整次浏览失败不划算」 | `ftp.rs:193-194` |
| g | MLSD 的 `type=cdir` 条目要剔掉 | 测试 `:281` |

### 6.5 本地播放的越狱闸

`local.rs:28-36`——
> ★ `entry.id` 是绝对路径，而**前端可以把任意 id 传回来**（浏览页的面包屑、历史记录、将来某个手滑拼出来的路径）。
> 不做这道闸，**一个 `..` 就能从用户挑的「电影」目录跑到整块硬盘上去**——这不是「反正是他自己的电脑」能糊弄过去的：
> **用户挑一个目录的动作本身就是在划范围。**
> 用 `canonicalize` 而不是纯字符串比较：**符号链接、`..`、大小写、Windows 的 `\\?\` 前缀**都得先归一，
> 不然「看着在里面、实际在外面」照样能过。

```
confine(root, target):
    root_real   = canonicalize(root)     // 失败 → "文件夹打不开(...)"
    target_real = canonicalize(target)   // 失败 → "路径打不开(...)"
    if !target_real.starts_with(root_real): Err("这个路径不在你选的文件夹里")
    return target_real
```
**两个入口都要过闸**：`list_dir`（`:108`）和 `resolve_play`（`:119`）。
测试 `cannot_escape_the_chosen_folder`（`:195-207`）。

其它：隐藏文件（`.` 开头）跳过（`:60-62`）；符号链接**按它指向的东西算**，越狱靠 confine 挡（`:65-70`）；
单条读失败只跳过这一条——「一个权限不足的子目录不该把旁边二十部片子一起拖下水」（`:51-52`）；
`resolve_play` 要**确认文件还在**（`:120-126`），「索引里有不代表文件还在（用户可能删了/挪走了/U盘拔了）」。

> ⚠️ **安卓侧没做 local 源**（记忆索引 `lan-sources-smb-webdav-ftp`：「安卓没做（只有 INTERNET 权限）」）。
> 本次未在 `apps/android` 中验证，标为**未确认**。

### 6.6 影视目录（VOD）：`ac=detail` vs `ac=list`

参考实现在仓库自带插件 `dist-portable/LinPlayer/userdata/data/plugins/plugins/com.linplayer.vod/main.js`（357 行）。

**为什么只用 `ac=detail`**（`main.js:23-28`）：
> `ac=list` 返回的每条**只有 8 个字段：没有 `vod_pic`，也没有 `vod_play_url`**。
> 拿它当列表就必须「列 20 条 → 再打 20 次详情」才能出海报，慢且容易被站点限流。
> 实测（三站一致）`ac=detail` **同样吃 `t` 和 `pg`**，一次请求就给回 **20 条 × 83 字段**，海报、备注、年份、播放地址全在里面。
> 实测两者耗时几乎一样（0.83s vs 0.75s）：**瓶颈是 RTT 不是体积，换轻接口省不下来**。

**搜索只有 `ac=detail&wd=`**（`main.js:249-250`）：
> `ac=list&wd=` 会**返回全站内容**，看起来像搜到了一堆，其实一条都没匹配——**这个坑很安静，别改**。

**分页大小要从响应学**（`main.js:262-267`）：
```
pagecount = Number(d.pagecount) || 0
hasMore   = pagecount ? page < pagecount : items.length >= 20
```
> `pagecount` 缺失时退回「这一页满 20 条就可能还有」——**比直接说没有更接近真相**。

> 📌 这条经验的更强版本来自**已删除的 Stremio 源**（记忆索引 `stremio-addon-source`）：
> 「**分页大小必须从响应学**（Cinemeta 每页 46~51 不是文档的 100，**写死 = 永远只看得到第一页还不报错**）」。
> 该源已于 2026-08-16 从仓库删净（`git log 4f521eb4`；全仓 grep `stremio` 零命中），只留作方法论。

**其它 VOD 坑**：

| # | 坑 | 出处 |
|---|---|---|
| a | 宿主 `ctx.http` **默认一个头都不发**，不少采集站（尤其挂 CF 的）会直接 403，**而报错看起来像鉴权失败**。必须自己带 UA | `main.js:36-39` |
| b | 响应体两种真实故障必须**分开报**：站点返回 HTML 错误页/CF 拦截页；站点把 JSON **截断**了（实测在 9 万字符处断掉）。混成一句「解析失败」，用户分不清是地址填错还是站点抽风 | `main.js:79-104` |
| c | `code` 缺省不能一刀切：「采集站正常恒 `code:1`。**非 1 且没给 `list`** 才算真失败」 | `main.js:100-103` |
| d | **有的站给的是网页播放页不是流**：某线路给 `/share/<hash>`，GET 回来是 `<!doctype html>`；同一部片的另一条线路才是真 m3u8。「两条线路并排列出来的话，**用户有一半概率点到黑屏**」。判据只能是扩展名（HEAD 太慢且很多站不认），**且只用于同片线路之间取舍，不单独否决谁**——全部认不出时一条都不丢 | `main.js:109-160` |
| e | `vod_play_from` / `vod_play_url` 的分隔符：多线路 `$$$`，集与集 `#`，集名与地址 `$`。两边 `$$$` 分组数实测 1:1 对齐 | `main.js:124-128` |
| f | 有的站的 `class` **没有 `type_pid`**。`Number(undefined)` 是 NaN，`|| 0` 会把整棵树压平成一层——**那正是想要的降级行为**：「猜不出父子关系时老老实实全铺在第一级，**别编一个假层级出来**」 | `main.js:215-218` |
| g | `vod_year` / `vod_score` 里的 **0 是「没有」不是数值**，不该显示 | `main.js:168-173` |
| h | `vod_content` 带 HTML 标签，宿主按纯文本渲染，插件侧先剥干净 | `main.js:303-304` |
| i | **白名单只有 `$sourceServer`** → 一个服务器只能打它自己那个域名；想用多个资源站就加多个服务器。海报和 m3u8 在别的域名上，但那两样分别是**界面和播放器直接去取的，不走 `ctx.http`** | `main.js:30-33` |
| j | **故意不实现 `listDir` / `search`**——「这个源不是文件树，不该假装是」 | `main.js:21, 344-345` |

**v1 → v2 的那次推翻**（`main.js:9-21`）值得原样记住：
> v1 实现的是 `listDir/search/resolvePlay`——那是**文件树**的契约。资源站硬套文件树的代价是每一样东西都得伪装成文件：
> 分类 → 伪装成文件夹；翻页 → 伪装成一个叫「下一页」的文件夹；「更新至17集」→ 只能拼进文件名；打开 → 文件管理器的双击语义。
> **全是错的。**

---

## 7. 踩坑清单

> 格式：**症状 / 真因 / 现在怎么处理 / Go 侧怎么落 / 出处**

**#1 「用得好好的，重开就要重新授权」，且不报错**
真因：阿里/189/夸克 TV 的 `refresh_token` 是一次性的，刷一次旧值当场作废；trait 只拿得到只读 `&SourceServer`，刷出来的新值没有回写通道。
现在：`take_rotated_credentials` + 命令层 `persist_rotated` 在六条命令后各取一次并 `cfg.save()`。
Go：接口上保留这个方法；**六个调用点一个都不能漏**——漏哪条，只用那条命令的用户就会掉登录。
`mod.rs:461-471`｜`apps/desktop/src/lib.rs:3629-3657`

**#2 「每个请求后都重写一次配置文件」**
真因：`take_rotated_credentials` 只要有缓存值就一直返回 Some。
现在：夸克额外加 `tv_dirty: HashSet<serverId>` 脏标记，取走即 `remove`。
Go：用 `map[string]bool` 脏集或让 take 真正清空 map。
`quark.rs:29-30, 466-472`

**#3 「插件装好了、目录也能列，就是加不进服务器表」，报「插件数据源必须返回数组」**
真因：`probe_backend` 只试了 `list_dir`，而影视目录型源根本不实现它。
现在：`list_dir || categories` 任一通过；两条都不通报**文件树**那条的错。
Go：同样两条探测；且**必须放在核心层**，因为桌面/安卓的 `source_login` 是两份手工拷贝。
`mod.rs:322-347, 711-785`

**#4a 「网盘/资源站起播后 mpv 在放、有声音、进度也在走，画面窗口从头到尾没露过面」**
真因：`show_video(&state, true)` 从 `4f72060c` 引入起就**漏在 `source_play` 这条路上**（`play` / `play_local` 都补了）。
「编译期一声不吭，单测也照不到——**Win32 窗口显隐没有返回值可断言**」。
背景：视频窗是独立顶层窗口，**平时必须藏着**（`:303-306`：不藏的话「主窗一最小化就是一个黑窗留在桌面」+「主窗透明，视频窗那块黑会把 UI 半透明效果整个压死」）。
现在：`source_play` 末尾补上，且**必须在播放器锁之外**（`show_video` 自己要拿这把锁）；
守门测试 `every_play_command_reveals_the_video_window`（`:6693-6739`）——扫本文件所有 `p.load_at(` / `p.load_with_headers(`，
往回定位所在顶层 fn，断言函数体含 `show_video(&state, true)`。**唯一豁免 `source_watchdog` 必须登记在测试的 `not_a_start` 白名单里**（`:6706-6707`），
兜底断言 `seen.len() >= 4` 防解析坏掉后形同虚设。
Go：每新增一条起播命令都要过那条测试。
`apps/desktop/src/lib.rs:307-311, 3785-3790, 6693-6739`

**#4b 同一症状的第二根因：前端绕开了独立播放窗**
真因：起播那条路**不止 invoke 一次 `source_play`**——桌面端要先 `playerWindowOpen` 把独立播放窗拉起来（视频窗焊在它背面、OSD 也在那个窗里）。
2026-08-16 抓到 `VodPage` 自己 `invoke("source_play")`；同层 `NetdiskPage` 拿的是 `onPlay`，而 `SourceBrowsePage` **只把 `onPlay` 传给了 NetdiskPage**。
后果：播放窗根本没开，**用户点了「播放」什么也没出现**。
手机端是同根因的另一半：起播完只 `back()` 不导航到播放页 → 画面走 webview **底下**那层 SurfaceView，不透明的目录页一直盖着 → 同样"有声音没画面"。
现在：`App.tsx` 的 `playSource` 是唯一入口；测试 `source_pages_start_playback_through_the_app`（`:6749-6784`）同时钉桌面和手机端（后者断言 `playSource` 必须含 `push({ page: "player"`）。
Go：这条约束在前端，但**守门人在核层测试里**——重写后必须保留同款源码扫描测试。
`apps/desktop/src/lib.rs:6740-6784`｜`ui/shared/api.ts:1118-1125`

**#5 「任何需要 `$sourceServer` 的插件数据源永远添加不上」，报「域名不在白名单内」**
真因：授权原本写在 `source_login` **末尾（账号落盘之后）**，而验证用的 `probe_backend` 是插件的第一次出网，撞在授权之前。
> P1 的端到端演示插件没撞上，因为它的 `listDir` 返回写死数据、**一个请求都不发**。
现在：**先授权再验证**；验证没过就 `sync_plugin_source_grants` 按已落盘账号重算一遍，把临时授权撤掉。
Go：授权表更新 → 探测 → 失败回滚，顺序不能变。
`apps/desktop/src/lib.rs:3543-3558`

**#6 「有流量、黑屏无声」（SMB 桥 / 预取代理同因）**
真因：没回 `Connection: close`，ffmpeg 把 seek 的下一个 Range 管线化到同一条 socket，那个请求没人读。
现在：桥的每个响应（含 416）都写 `Connection: close`，每条连接一个 task。
Go：`net/http` 的 Server 要显式 `w.Header().Set("Connection","close")` 或用 `Server.SetKeepAlivesEnabled(false)`。
`localserve.rs:110-114, 233-241`

**#7 越界 Range 被"悄悄挪回最后一字节回 206"，播放器拿到"有效但错位"的数据**
真因：**先 `min` 钳位再判越界**，那个分支永远进不去（prefetch 上踩过）。
现在：416 的判断放在钳位**之前**。
Go：同序；测试要用超出总长的 Range 断言 416 而非 206。
`localserve.rs:82-91, 224-230`

**#8 302 重签时 `entry.raw` 是空的，取不到直链钥匙**
真因：看门狗重解析只传 id + name（`source_play` 构造的 entry 里 `raw` 来自前端，重签路径没有）。
现在：115 按 `file_id` 反查 `pick_code`（`/files/file`），百度按父目录列一次找回 `fs_id`。
Go：凡是"直链钥匙不等于 entry.id"的源，`resolve_play` 都要写这条兜底。
`pan115.rs:112-137`｜`baidu.rs:116-134`

**#9 「小文件能播大文件不能」（百度）**
真因：直链**绑 UA**，用浏览器 UA 取 ≥20MB 的文件直接 403。
现在：直链专用 UA（**不是浏览器 UA**，见 `baidu.rs:22`）+ `Referer` + `Cookie`，且同时写进 `http_headers` 和 `user_agent_override`。
Go：这是全项目 UA 口径的第四条（前三条见 `crates/core/src/http.rs:7-15`）。
`baidu.rs:9-10, 21-23, 208-247`

**#10 115 直链换个 UA 去取流直接 403**
真因：直链绑定**取链请求时用的那个 UA**。
现在：取链和喂播放器用同一个常量 UA，Cookie 也逐字一致。
Go：这两处必须引用同一个常量，不能各写各的。
`pan115.rs:7-8, 271-274`

**#11 115 抄成「2048 位 / 分块 245」**
真因：二手情报写错，而后果是**分块长度全错、请求发得出去、服务端静默拒绝、零日志指向真因**。
现在：`modulus_is_1024_bit_not_2048` 逐条钉 256 hex 字符 / 1024 位 / 128 字节 / 117 明文 / e=65537。
Go：这条测试原样搬过去。
`pan115_crypto.rs:14-15, 158-168`

**#12 115 的 XOR 错位被"顺手简化"成 `key[i % k]`**
真因：XOR 是对合运算，**做两次都还原，所以往返测试抓不住下标映射错误**。
现在：另写一条 `xor_transform_offsets_by_len_mod_four_not_by_raw_index`，取长度 5（余数 1）**逐字节写死期望值**，并断言它与朴素实现**不同**（「分不开这条测试就是摆设」）。
Go：这是"测试必须有区分力"的教科书案例，照搬。
`pan115_crypto.rs:210-228`

**#13 189 签名少了 `&params=` → 全 401**
真因：参数非空时签名明文必须追加该段。
现在：`sign_appends_params_only_when_present` 断言带/不带两种签名不同。
Go：同。
`pan189.rs:271-273, 821-830`

**#14 189 参数顺序不同导致密文/签名对不上**
真因：AES 明文是 `k=v&k=v` 拼串，**必须内部按 key 排序**。
现在：`encrypt_params` 先 `sort_by(key)`，测试断言两种入参顺序结果相同。
Go：`sort.Slice`；另注意输出必须**大写 hex**。
`pan189.rs:236-237, 809-819`

**#15 139 签名对不上服务端**
真因：用了通用 urlencode——它会把 `!~*'()` 也编码，而 JS `encodeURIComponent` 不编码这六个。
现在：手写 `encode_uri_component`，已知答案测试三条。
Go：**绝不能用 `url.QueryEscape` / `url.PathEscape`**，手写。
`pan139.rs:434-448, 481-489`

**#16 139「无逆向登录」的误判**
真因：把 139 当成走统一认证，没去扒官网自己的 SPA。
现在：扒 Vue bundle 后攻下**密码 + 扫码**两条路；且发现 **Authorization 服务端从不下发**，客户端拿 token 就能离线算出。
Go：常量从 `pan139.rs:212-215` 抄。
`pan139.rs:1-9`；教训见记忆索引 `netdisk-sources-via-oplist`：「二手情报说"没有"要亲自扒 JS 验」

**#17 飞牛「看着看着断流」**
真因：`media/range` 带了 authx，而 authx 是**构造时算死的一次性签名**，几小时的长连接中途过期被服务端拒收。
现在：单抽 `media_range_headers()` 只回两个头，测试断言 `len == 2` 且**不含 authx**（「防止有人"顺手补齐签名"把病根加回来」）。
Go：同样单抽一个函数 + 同样的反向断言。
`feiniu.rs:560-563, 652-659, 690-703`

**#18 飞牛封面恒为 None**
真因：**不是接口没有，是没去读 `poster` 字段**——服务端给的已经是完整可直接取的 URL。
现在：`poster()` 读 `poster` / `posters`，空串当没有；目录（媒体库/季）也要有封面。
Go：同。**注意 `docs/go-migration/MIGRATION.md:174` 仍把封面列为待办，那条已过时。**
`feiniu.rs:99-107, 705-717`

**#19 飞牛「挂网盘的片子很可能根本播不了」**
真因：此前**无条件走 `media/range`**。
现在：`direct_link_qualities` 非空即走云盘直链（判据抄自客户端源码里那个 if），并带上服务端指定的 Cookie（不带就 403）。
Go：同。档位**按码率排序不按分辨率名**——「分辨率是自由文本（1080P/1080p/FHD 各服务端不一），按名字映射迟早漏一种然后**静默排错**；码率是数字，永远可比」。
`feiniu.rs:153-154, 526-556`

**#20 Ani-RSS 根层排序不走公共 helper**
真因：`sort_entries` 是"文件夹优先 + 小写比较"，而 Ani-RSS 根层全是文件夹，需要的是裸 name 序。
现在：`entries.sort_by(|x,y| x.name.cmp(&y.name))`。
Go：照抄这一行，别顺手换成公共排序。
`anirss.rs:289`

**#21 Ani-RSS「刚登录过，管理页还说未登录」**
真因：管理接口（listAni/config/…）**不在 trait 上，trait object 取不到**，所以宿主另存一份具体类型的 `Arc`。
若那不是**同一个 Arc**，浏览时重登拿到的 token 和管理接口用的是**两套缓存**。
现在：`AppState` 里存的是同一个 `Arc` clone 后 unsize 成 `dyn`。
Go：后端必须是**单例指针**，注册表里的接口值和管理接口持有的具体值指向同一对象；token map 带锁。
**这不是性能优化——切两份不会编译报错、不会有日志。**
`apps/android/src/lib.rs:94, 4666-4669`｜`apps/desktop/src/lib.rs:5716-5719`

**#22 Ani-RSS 把 Ani/Config 收窄成 struct → 静默抹掉用户的服务端设置**
真因：`Ani` 有 55 字段、`Config` 约 123 字段且**随服务端版本增删**，而 `setAni`/`setConfig` 要**整个对象回传**。
现在：全程 `serde_json::Value` 进 `Value` 出。
Go：`map[string]any` 或 `json.RawMessage`，**禁止定义 struct**。
`anirss.rs:399-407`｜`apps/desktop/src/lib.rs:3900-3906`

**#23 Ani-RSS 评分丢失**
真因：`as_i64` 对 `8.5` 返回 None → 兜底 0。Dart 的 `num.toInt()` 是截断。
现在：`as_int` 先按 f64 取再截断。
Go：`json.Number` 或先 `float64` 再 `int`。
`anirss.rs:203-207, 1179-1186`

**#24 Ani-RSS 空 query 时 URL 被追加一个裸 `?`**
真因：无条件调 `query_pairs_mut`。
现在：空 query 时不碰它，专门一条测试钉。
Go：`url.Values.Encode()` 空表返回空串，天然满足；但要确认调用点没无脑拼 `"?"+q`。
`anirss.rs:126, 1257-1265`

**#25 插件源「不支持搜索」被弹成红字**
真因：JS 侧 `ctx.errors.unsupported()` 抛出的异常若被当普通错误，**每个不支持搜索的插件源都会在用户每次搜索时糊一脸错误**。
现在：`js_error_to_source_error` 按 `UNSUPPORTED_MARKER` 前缀还原；rquickjs 抛出的文案带前后缀，所以是"包含"而不是"等于"。
Go：JS 引擎换了以后这个"包含"判据要重新确认。
`plugin_source.rs:58-79, 436-451`

**#26 插件未实现某方法时被当成"空结果"**
真因：handler 派发返回 `Null`（不是抛错）。当成空数组的话「**用户会以为搜到了 0 条**」；影视目录三件套则会让「前端把「这个源是网盘」当成「这个源坏了」」。
现在：`out.is_null()` → 还原成 `unsupported` / `unsupported_feature`。
Go：同——**Null 与空数组必须区分**。
`plugin_source.rs:327-335, 366-368, 377-378, 397-398, 425-426`

**#27 插件一条畸形记录让整个目录打不开**
真因：整表校验。
现在：`filter_map` 逐条跳过；但**整体不是数组**就报错（那是插件写错了）。
Go：同。
`plugin_source.rs:125-131, 482-497`

**#28 插件源 `isVideo` 各自维护扩展名表 → 漂移**
真因：插件自己判。后果是「**某种格式在内置源能播、在插件源里根本不显示**」。
现在：`isVideo` 缺省用**宿主那份**扩展名表；插件显式给了才以插件为准（strm/无扩展名直链靠它）。
Go：同。
`plugin_source.rs:94-97, 462-479`

**#29 插件白名单被一个字符击穿**
真因：`*.example.com` 的通配匹配若允许裸 `*`，`suffix` 为空 → `ends_with` 恒真 → **fail-closed 变成放行全网**。
现在：只认 `*.` 开头，且要求 `h.len() > suffix.len()`（防 `evil-example.com` 命中）。
Go：同两条守卫。
`crates/core/plugins/state.rs:83-88`

**#30 强制 https 让局域网源开箱即拒**
真因：自建 OpenList/飞牛绝大多数是局域网明文地址。
现在：`allow_http` **跟着用户自己填的协议走**，且**只对用户亲手输入过的 origin 放行**；manifest 里硬编码的域名仍然 https-only。
Go：同——`SourceHostGrant{host, allow_http}` 这个结构要保留。
`crates/core/plugins/state.rs:23-45, 96-131`

**#31 没配任何源时 `$sourceServer` 展开为空**
真因：令牌声明了但展开表空。
现在：**fail-closed**——展开为空 = 拒绝一切（测试 `state.rs:362-372` 专门钉）。
Go：同。别为了"方便调试"给空表放行。

**#32 `SourceKind` 前端整套写成首字母大写**
真因：线上值是**小写**，而前端按派生 Debug 的形状写了首字母大写。三个后果**全部静默**（`apps/desktop/src/lib.rs:6258-6264`）：
① `sourceLogin("Openlist", …)` 送出一个后端不认识的 kind；
② 服务器卡的类型徽标 `KIND_LABEL[a.source_kind]` **恒 undefined，六张卡全空白**；
③ `a.source_kind === "Anirss"` **恒 false**，Ani-RSS 卡点进去落到网盘页。
现在：`source_kind_wire_strings_match_the_frontend_union`（`apps/desktop/src/lib.rs:6265-6295`）——
`include_str!` 读 `ui/shared/api.ts`，截 `export type SourceKind =` 到第一个 `;`，
用 `match_indices('"').chunks(2)` 取引号内片段（**不用正则**，末行 `(string & {})` 不带引号自然跳过），
**正反双向断言**：BUILTIN 每项都在联合里 ∧ 联合里每项 `is_builtin()`。
> **「TS 那边没有测试环境，就让 Rust 当这份跨语言契约的守门人。」**
Go：新增源类型必须过同款契约测试。
`apps/desktop/src/lib.rs:6258-6295`｜`ui/shared/api.ts:366-381`

**#33 起播不清上下文 → 记错账**
真因：`source_play` 若不清 `scrobble_ctx` / `wh_ctx` / `playback`，网盘进度会被记到**上一部 Emby 片**上，Trakt/Bangumi 也记成看了那一部。
现在：`:3748-3749` 清前两个，`:3791` 清 `playback`（"网盘源不走 Emby 上报"）。
Go：三个都要清；这是"不报错但记错账"的静默 bug。
`apps/desktop/src/lib.rs:3748-3749, 3791`

**#34 302 重签死循环**
真因：文件本身放不了（不是直链过期）时，看门狗会无限重签。
现在：`resign_count` 钳 3 次，超限清 `source_play_entry` + 日志 + 放弃；`source_play` 成功时归零。
Go：两个动作成对，缺哪个都会出问题（只钳不归零 = 跨片累计后永久放弃）。
`apps/desktop/src/lib.rs:3793, 3865-3870`

**#35 广播命令名写错 → 侧栏永远不刷新**
真因：`ui/shared/api.ts` 的 `ACCOUNT_MUTATIONS` 里写了一个**根本不存在的命令名**（真名是 `source_login`，而它恰好就是添加网盘的入口）。
名字写错 = 永远不广播 = 侧栏永远不刷新，**不报任何错**（前端零 store、各持 useState 副本，靠 invoke 层广播同步）。
现在：`frontend_account_mutation_list_names_only_real_commands`（`:6536-6584`）把该集合 ∩ `generate_handler![...]` 注册块做交叉校验。
Go：同款测试必须移植。
`apps/desktop/src/lib.rs:6241-6244, 6536-6584`｜`ui/shared/api.ts:21-35`

---

## 8. Go 侧移植要点

### 8.1 库选型表

| 需求 | Rust 现用 | Go 建议 | 备注 |
|---|---|---|---|
| 大数模幂（115 m115） | `num-bigint` | `math/big`（`Int.Exp`） | **不要用 `crypto/rsa`**，它不做无私钥的公钥模幂 |
| 189 RSA 公钥加密 | `num-bigint` 手做 SPKI-DER + PKCS1v15 | `crypto/x509.ParsePKIXPublicKey` + `crypto/rsa.EncryptPKCS1v15` | Go 侧可大幅简化；**但输出必须补零到 k 并转小写 hex，前缀手工加** |
| 189 参数加密 | `aes` crate 逐块 | `crypto/aes` + **手写 ECB 循环** | Go 标准库**故意没有 ECB**，必须自己 for-loop `block.Encrypt` |
| 189 签名 | `hmac` + `sha1` | `crypto/hmac` + `crypto/sha1` | 输出**大写 hex** |
| 189 Date 头 | `httpdate` | `http.TimeFormat`（就是 RFC1123 GMT） | 头里和签名明文里**必须是同一个字符串** |
| 阿里 x-signature | `k256`（RustCrypto） | `decred/dcrd/dcrec/secp256k1/v4` 或 `ethereum/go-ethereum/crypto` | **raw `r‖s` 定长 32+32，不是 DER**；末尾 `01` 手工拼 |
| 139 / 飞牛 / 夸克 TV 签名 | `md5` / `sha1` / `sha2` | `crypto/md5` `crypto/sha1` `crypto/sha256` | 139 的 `encodeURIComponent` **必须手写** |
| SMB | `smb2`（纯 Rust） | `cloudsoda/go-smb2` | 必须有 **`ReaderAt` 语义**——只能顺读的实现等于不能用 |
| FTP | `suppaftp` | `jlaffaye/ftp` | **必须能分别调 MLSD 解析器与 LIST 解析器**；不要用"自动猜格式"的 API（见 §6.4） |
| WebDAV | 手写 PROPFIND + `quick-xml` | **建议继续手写** + `encoding/xml` | 用现成 dav 库会绕过自签名证书白名单与全局代理（§6.3-a）。`encoding/xml` 默认就解实体，没有 quick-xml 那个拆事件的坑，但**命名空间要按 `Name.Local` 比** |
| 二维码渲染 | `qrcode` crate | `skip2/go-qrcode` | 渲成 SVG 或 PNG 都行，注意 §5.6 |
| gzip（阿里 bizExt） | `flate2` | `compress/gzip` | 判魔数 `1f 8b` |
| HTTP | `reqwest` + 自定义 rustls verifier | `net/http` + 自定义 `tls.Config.VerifyPeerCertificate` | 三条 UA 道 + 全局代理 + 按 host 的自签名白名单要一起搬（`crates/core/src/http.rs`） |

### 8.2 必须逐字节对账的清单

**这些抄错全部是静默失败**（服务端不报错、日志无痕）：

| 项 | 位置 | 对账方式 |
|---|---|---|
| 115 模数 / 指数 | `pan115_crypto.rs:17-23` | 断言 hex 长度 256、bits 1024、key_len 128、slice_max 117、e=65537 |
| 115 XOR 表（144 字节）+ client key（12 字节） | `pan115_crypto.rs:27-41` | 断言表长、首字节、下标 132、下标 143（防整表少抄一行）+ 全零种子的派生指纹 |
| 115 `xor_transform` 的 `len%4` 错位 | `pan115_crypto.rs:74-85` | 长度 5 逐字节写死期望，并断言**不等于**朴素实现 |
| 189 内置公钥 | `pan189.rs:552` | 断言 e=65537、模数 128 字节 |
| 189 签名明文模板 | `pan189.rs:268-273` | 断言带/不带 params 的签名不同、长度 40、全大写 |
| 189 客户端固定参数（appId / clientType / version / channelId / returnURL） | `pan189.rs:25-36` | 无法本地验证，只能真机 |
| 139 `encodeURIComponent` 放行集 | `pan139.rs:440` | 已知答案：`-_.!~*'()` 原样、空格 → `%20`、`/` → `%2F`、中文按 UTF-8 大写 hex |
| 139 secinfo 前缀串 `<SECINFO_PREFIX>` | `pan139.rs:317` | SHA1 已知向量 + 拼接顺序 |
| 飞牛恒带的 Cookie `<固定中继标记>` | `feiniu.rs:242, 329, 336, 657` | `media_range_headers` 断言 `len==2` 且两个 key 都对 |
| 139 Authorization 拼法 | `pan139.rs:225-228` | 已知答案 `("1","2") → "Basic cGM6MToy"` |
| 139 登录固定字段（cpid / clienttype / version / pintype） | `pan139.rs:213-215, 295, 378` | 只能真机 |
| 阿里 APP_ID / API_ID | `aliyundrive.rs:27-28` | 只能真机；形状：公钥 130 hex 且 `04` 开头、签名 130 且 `01` 收尾 |
| 飞牛 SIGN_SECRET / API_KEY / 拼接分隔符 | `feiniu.rs:15-16, 48-64` | md5 已知向量 + authx 三段形状 |
| 夸克 TV CLIENT_ID / SIGN_KEY / 设备字段全表 | `quark_tv.rs:11-16, 59-78` | 形状：token 64 hex、req_id 32 hex |
| 全部 `SourceKind` 线上字面量 | `mod.rs:42-58` | `kind_wire_format_is_bare_lowercase_string` + 跨语言契约测试 |
| `legacy_debug_label` 的 14 个输出 | `mod.rs:156-162` | `legacy_debug_label_reproduces_old_enum_debug_exactly` |
| `UNSUPPORTED_PREFIX` 字符串 | `mod.rs:251`、`plugins/ctx.rs:21` | 两处必须相同；前端也在按它判断 |

### 8.3 命令层形状（Go 的 FFI 边界照此切）

以桌面为准（`apps/desktop/src/lib.rs`）；**安卓是一份手工拷贝**，注释多处提醒"改这里要同步改那里"（如 `:3693`）。

```
source_backend(kind) -> Arc<dyn MediaSourceBackend>            :3492-3513
    插件源：现建现用，不进静态表
      理由：PluginSourceBackend 无状态（只有 plugin_id + src_id + Weak），建一个成本可忽略；
            而往这张会被播放链路读的表里动态增删要引入锁和生命周期同步，是白挨的复杂度。
            插件被禁用时自然失效——贡献点注册表里查不到，调用直接报错。
    内置源：查 state.source_backends（静态 HashMap<SourceKind, Arc<dyn …>>）
```

| 命令 | 关键行为 | 行号 |
|---|---|---|
| `source_login(kind, base_url, username, password, cookie, extra)` | id = base_url 为空则 `legacy_debug_label()`；**先授权插件白名单 → probe_backend → 落进账号表 → 设为活跃源 → 作废 Emby 会话 → 同步插件授权** | `:3515-3576` |
| `source_list_dir(dir_id)` / `source_search(query)` | 取活跃源 → 分派 → 调 → **`persist_rotated`** | `:3659-3688` |
| `source_categories` / `source_catalog(category_id, keyword, page)` / `source_media_detail(id)` | 同上；`keyword` 空白串归一成 None；`page.max(1)` | `:3695-3737` |
| `source_play(entry_id, entry_name, resume_secs, raw)` | 清 Trakt/观看记录上下文 → 构造 entry（`raw` 透传）→ `resolve_play` → `persist_rotated` → 加载 mpv（url + headers + UA override）→ **挂外挂字幕** → **`show_video(true)`（必须在播放器锁外）** → 清 Emby 上报上下文 → 记住 entry 供看门狗 → 重签计数归零 | `:3739-3795` |
| `source_qr_start(kind)` / `source_qr_poll(kind, ctx)` | 只认 baidu / aliyundrive / pan189 / pan139，其余报"该源不支持扫码登录" | `:3578-3609` |
| `source_password_login(kind, username, password)` | 只认 pan189 / pan139；**返回 credentials 交给前端塞进 `source_login` 的 extra** | `:3611-3627` |
| `quark_scan_start` / `quark_scan_poll(device_id, query_token)` | 夸克 TV 专用；poll 成功**直接设活跃源**，不走 `source_login` | `:3797-3843` |
| `source_watchdog(pos)` | 302 失效重签，返回"是否重签了"；**连续 3 次仍失败即放弃**（防死循环）；**唯一一条调 backend 却不调 `persist_rotated` 的路径** | `:3847-3891` |

**分派表**（`apps/desktop/src/lib.rs:69, 5714-5739, 5773`）：
`source_backends: HashMap<SourceKind, Arc<dyn MediaSourceBackend>>`，长驻（持 token 缓存），
**14 个内置 kind 只注册 13 个实例**——emby 不注册后端。

**Ani-RSS 的双持有**（`:70-74, 5717-5719, 5774`）：`Arc<AniRssBackend>` 建**一次**，
注册表里当 `dyn` 走浏览/播放，`AppState.anirss` 里当具体类型走管理接口。
`clone` 只加引用计数（**不复制 token_cache**），两条路共用同一份登录令牌。见 §7-#21。

**插件源授权的两个辅助函数**（不是命令）：

| 函数 | 行为 | 出处 |
|---|---|---|
| `grant_plugin_source_host(kind, base_url)` | 在**已落盘账号的基础上临时追加一条**授权。理由：给 `source_login` 的验证请求用——那一刻账号还没入库，只按 config 算的话新地址不在里面。非插件源直接跳过（它们出网走宿主自己的 http 客户端） | `:135-154` |
| `sync_plugin_source_grants()` | 按 config 里全部账号**重算并整体替换**每个插件的授权表。整体替换而非追加：「用户删掉一个源之后那台机器必须**立刻**不再可达」。已启用但一个源都没配的插件也要**显式清空**，否则上一轮授权会留着 | `:120-124, 156-178` |

必须调用的时机（`:120-121`）：**登录、删除、导入配置、启动**（启动那次在 `:5902`，PluginManager 建好后立刻调）。

**内部函数 `report_source_progress`**（`:1866-1906`，不是命令）：被 `report_progress`（`:1854-1865`）
在"没有 Emby playback target"时兜底调用（`:1859`），停播那次在 `:2197`。
用 `source_play_entry` 重组 entry，时长从播放器现读；
`finished = is_stop && duration>0 && pos >= duration*0.9`（`:1901`，"判据与 Emby 一致 90%，只在停止那一次判"）；**一律吞错**。

**活跃源的存放**：`state.source: Mutex<Option<(SourceKind, SourceServer)>>`。
所有源命令的第一句都是 `state.source.lock()...ok_or("未登录源")?`——即**同一时刻只有一个活跃源**。

**与 Emby 的互斥**：切到源时 `*state.session.lock() = None`（`:3572`）；
`source_play` 里 `*state.playback.lock() = None`（`:3791`）。启动重建与切服见 §1.9。

**预取代理（多线程加载）只在 Emby 的 `play()` 路径上**（`apps/desktop/src/lib.rs:1696-1733`），
**`source_play` 不走它**。Go 侧不要把两条混起来。

**⚠️ `quark_scan_poll` 成功时不落盘**（`:3828-3839`）：它直接把一个 `SourceServer` 装进 `state.source`，
**没有 `cfg.upsert`**——与 `source_login` 不同。

### 8.3.1 桌面 vs 安卓：机械 diff 的结果

对账方式：提取两文件全部 `source_*` / `persist_rotated` 函数体，剥注释和空行后**逐行 diff**（不是眼看）。

**命令集合完全一致，一条不缺**（各 11 条 `source_*` + 2 条 `quark_scan_*`；
desktop 注册 `:5999-6011`，android 注册 `apps/android/src/lib.rs:4800-4808, 4850, 4897`）。

**函数体 4 处差异**：

| # | 函数 | 差异 | 性质 |
|---|---|---|---|
| 1 | `source_backend` | 安卓对任何 `is_plugin()` 的 kind 直接 `Err("安卓端暂未接入插件系统,该源无法使用")` | **已声明**的平台差（`apps/android/src/lib.rs:1841-1848`，且明确「报错而不是回落成『该源类型暂未接入』」） |
| 2 | `source_login` | 安卓无三处插件授权调用，`probe_backend` 直接 `?` | 与 #1 一致 |
| 3 | `source_play` | 见下 | **含真缺口** |
| 4 | `source_watchdog` | 安卓多一个 `ps: State<PlayerState>` 参数、锁 `ps.player` | 纯架构差（安卓播放器在独立 State） |

`source_play` 逐项（desktop `:3740-3797` vs android `:301-343`）：

| 语义 | desktop | android | 判定 |
|---|---|---|---|
| 清 `scrobble_ctx` | `:3748` | `:309` | 一致 |
| 清 `wh_ctx` | `:3749` | 无 | 安卓无观看记录上下文（`:303-304` 声明） |
| `apply_playback_defaults` | `:3772` | 无 | **已声明**（硬解/杜比档位是桌面设置项） |
| `show_video` | `:3793` | 无 | **已声明**（安卓是 SurfaceView，一直在，`:261`） |
| `persist_rotated` | `:3765` | `:324` | 一致 |
| `playback = None` | `:3794` | `:341` | 一致 |
| **`source_play_entry = Some(...)`** | `:3795` | **无** | ⚠️ 缺口，见 §10.3-i |
| **`resign_count.store(0)`** | `:3796` | **无** | ⚠️ 缺口，见 §10.3-i |

### 8.4 三个不要抽象过头的地方

1. **不要给扫码状态机抽公共枚举**——五个源的状态字段类型、位置、Pending 表示全不同（§5.5）。
   共享的只有 `QrStart`/`QrPoll` 这两个**出口类型**。
2. **不要把影视目录字段并进 `SourceEntry`**——理由见 `mod.rs:234-247`，代价是 40 处构造点。
3. **不要给源加连接池 / 全局重试中间件**——SMB 明确写了"现连现用"并带 `ponytail:` 标注（`smb.rs:15-18`）；
   各源的重试是**语义化的**（189 看 res_message 里的 session 关键词、夸克看 code、飞牛"不明确区分鉴权错误码所以非零 code 统一重登兜底一次"），
   抽成通用中间件会把这些差异抹平。

### 8.5 必须原样搬过去的调用序

```
source_login:
    算 id（base_url 空 → legacy_debug_label）
    → grant_plugin_source_host（插件白名单临时授权）
    → probe_backend（list_dir || categories）
        失败 → sync_plugin_source_grants 撤销临时授权 → 返回错误
    → cfg.upsert(Account) + cfg.save()
    → 装 state.source + 清 state.session
    → sync_plugin_source_grants

每条 backend 调用之后（六条命令，watchdog 除外）:
    → persist_rotated：kind 匹配 → take_rotated_credentials → extra.extend
                       → 写回 accounts[server == id].source → cfg.save() → 刷新内存活跃源

source_play:
    清 scrobble_ctx / wh_ctx
    → resolve_play → persist_rotated
    → [播放器锁内] take_error_eof → apply_playback_defaults
                   → load_with_headers(url, resume, headers, ua) → set_pause(false) → add_subtitle*
    → [锁外] show_video(true)
    → 清 playback → 记 source_play_entry → resign_count 归零
```

**这三个序列里每一步的位置都是某个故障的修复结果**（分别见 §7-#5、#1、#4a/#33）。
Go 侧重排任意一步之前，先回去读对应那条。

### 8.6 双端拷贝这件事本身

Go 重写的核心机会：**把口径下沉到 core，两端只调**。
`probe_backend` 是仓库里唯一做对的示范，理由写在 `mod.rs:329-331`；
而没下沉的那些（`source_play` 的上下文清理、`report_progress` 的源兜底、`source_play_entry` 的写入）
已经在安卓侧产生了三个静默缺口（§10.3.1）。

---

## 9. 现有测试的价值

**能直接翻译成 Go 表驱动测试的（高价值，建议全搬）**：

| 文件 | 测试 | 钉住什么 |
|---|---|---|
| `mod.rs:592-629` | `kind_wire_format_is_bare_lowercase_string` | 14 个线上字面量 + **表长 == BUILTIN.len()**（防"新增源没补测试" ） |
| `mod.rs:634-665` | `plugin_kind_roundtrips_and_never_collides_with_builtin` | 插件键往返 + **遍历 BUILTIN**（新增源自动纳入）+ 键重复检测 + 4 种残缺键 |
| `mod.rs:671-698` | `legacy_debug_label_reproduces_old_enum_debug_exactly` | 老账号 id 兼容 |
| `mod.rs:704-709` | `unknown_kind_deserializes_instead_of_failing` | 插件卸载后账号不掉 |
| `mod.rs:761-785` | 三条 `probe_*` | 文件树源 / 只有目录的源 / 两条都不通时报哪条错 |
| `pan115_crypto.rs:161-271` | 5 条 | 见 §8.2；**特别是 `xor_transform_offsets_by_len_mod_four_not_by_raw_index`** |
| `pan189.rs:809-914` | 8 条 | 参数排序/大写 hex/签名 params 段/SPKI 解析/PKCS1v15 结构/密文形状/PEM 容忍 |
| `pan139.rs:481-564` | 7 条 | encodeURIComponent 已知答案 / calSign 形状 / Authorization 已知答案 / resp_ok 多态 |
| `aliyundrive.rs:649-732` | 6 条 | id 往返 / 跨盘条目取自己的 drive_id / 档位排序 / 签名与公钥形状 / bizExt 明文+gzip |
| `feiniu.rs:676-795` | 6 条 | **`media_range_headers_must_not_carry_authx`** / 封面 / watched 归零 / 码率排序 / 只挂外挂非位图字幕 / ip 稳定 |
| `webdav.rs:363-467` | 7 条 | Apache+Nextcloud 两种前缀 / 实体拼接 / **base_url 带路径的完整往返** / 逐段编码 |
| `ftp.rs:217-307` | 6 条 | 地址解析 / **垃圾行不变假文件** / MLSD / 凭据编码 / 匿名兜底 |
| `smb.rs:269-317` | 3 条 | 四种地址写法 / 共享名拆分 / 播共享要给人话 |
| `local.rs:163-246` | 5 条 | 列目录 / 下钻 / **越狱闸** / 裸路径 + 存在性 / 根目录不存在 |
| `localserve.rs:190-267` | 6 条 | 200/206/开区间/**416 不钳位**/**Connection: close**/跨块拼接/drop 关端口 |
| `plugin_source.rs:438-577` | 8 条 | unsupported 还原 / auth 识别 / isVideo 默认 / 畸形行跳过 / 完整映射 / 无 url 报错 / **server 字段白名单** / 死 manager 不 panic |
| `plugins/state.rs:343-410` | `$sourceServer` 系 | 令牌展开 / **空表拒绝一切** / http 只对用户填过的放行 |

**语料本身就是知识的（照抄语料，别自己造）**：
- `ftp.rs:249-255`：**故意混入 `total 42` 和一行乱码** —— 不放这两行的测试就是假绿
- `webdav.rs:338-361`：Apache（大写 `D:`）与 Nextcloud（小写 `d:`）两份**真实形状**的 XML
- `webdav.rs:395-403`：文件名里带 `&` 的 XML
- `pan115.rs:296-325` / `baidu.rs:412-440`：`isdir`/`size` 的**数字与字符串两种类型**

**三条跨语言契约测试——TS 侧没有测试环境，Rust 是唯一守门人（Go 重写必须先移植这三条）**：

| 测试 | 校验什么 | 出处 |
|---|---|---|
| `source_kind_wire_strings_match_the_frontend_union` | `ui/shared/api.ts:366-381` 的 `SourceKind` 联合 ↔ `SourceKind::BUILTIN`，**正反双向** | `apps/desktop/src/lib.rs:6265-6295` |
| `frontend_account_mutation_list_names_only_real_commands` | `ui/shared/api.ts:21-35` 的 `ACCOUNT_MUTATIONS` ⊆ `generate_handler![...]` 真注册命令 | `:6536-6584` |
| `every_frontend_invoke_names_a_registered_command` | 前端每个 `invoke<T>("xxx")` 都真注册过。先 `strip_android_only(...)` 剪掉 `@shell-only:android` 区块——**安卓侧有一条对称测试只查那个区块，两条合起来才覆盖全 api.ts，谁也别单独放宽** | `:6590+` |

> ⚠️ `apps/desktop/src/lib.rs:6265` 这个 fn 头上**堆了三段互不相干的 doc 注释**（`:6240-6245` 属于 `ACCOUNT_MUTATIONS` 那条、
> `:6246-6257` 属于 OSD 白名单那条，真身都在别处）。Rust 会把三段全挂到 `6265`。
> **读那里的注释会读到两段属于别人的故障史**，别归错账。

**测试自身的元教训（写 Go 测试时会再踩）**：

| 教训 | 出处 |
|---|---|
| **源码扫描类测试必须先把 CRLF 归一成 LF**——这些测试按 `\n}\n` 字面量解析自身源码，而 Windows 上 git autocrlf 把文件整份变 CRLF（实测 6789 个 CRLF、0 个裸 LF）。needle 全部落空 → 要么 panic，**要么更糟：静默匹配到 0 处而断言恒真**。表现是 Linux CI 全绿、**Windows CI 恒红**，本地 `cargo check` 一声不吭。修法 `include_str!(...).replace("\r\n","\n")` | `apps/desktop/src/lib.rs:6218-6224` |
| **切源码字符串要按 `chars()` 不能按字节**——切在半个汉字上当场 panic（2026-08-17 真踩过） | `apps/desktop/src/lib.rs:6229-6230` |
| **解析式测试必须加下界断言**，否则解析坏掉后断言恒真、形同虚设（现有 `seen.len()>=4` / `listed.len()>=10` / `checked>=2`） | `:6285-6289, 6733-6738` |
| **每个测试各用各的临时目录**——上一版用进程号当名字，四条测试共用一棵树，而 cargo 默认多线程并跑，「删掉 movie.mkv 看报错」那条一动手，正在列目录的那条当场少一个文件。**红的是测试自己打架** | `local.rs:142-145` |
| **假服务器要读到完整请求**（头 + `Content-Length` 指定的 body）——「避免 header/body 分包导致漏读」 | `anirss.rs:1085-1110` |
| **对合运算的往返测试没有区分力**——必须另写一条逐字节钉映射的 | `pan115_crypto.rs:210-212` |
| **联网测试要 `#[ignore]` 并写清跑法** | `quark_tv.rs:361-365` |
| **进程级全局缓存的测试必须加锁串行**——实测全量套件连跑 20 次红 1 次 | `crates/core/src/http.rs:286-297` |

**故意没有的测试（Go 侧也不要写）**：
`pan115_crypto.rs:243-252` —— encode/decode **不是互逆运算**，串起来的 roundtrip 测试**实测会红**。
「本模块无法纯本地自证算法与服务端一致，只能证内部各环节自洽。端到端正确性只有挂真实账号才能确认。」

---

## 10. 已知未解决 / 存疑

### 10.1 与 `MIGRATION.md` 冲突、以本文为准的三条

| # | `MIGRATION.md` 的说法 | 代码里的事实 | 证据 |
|---|---|---|---|
| 1 | `:165` 115 → `decred/.../secp256k1` | **115 一个椭圆曲线都没用**。它是公钥模幂（m115），Go 侧用 `math/big`。真正用 secp256k1 的是**阿里云盘**（`:163` 那行是对的） | `pan115_crypto.rs:1-9` |
| 2 | `:167` 189「短信走 `dynamicCheck=TRUE` + epd 槽位」；`:166` 139「短信 + 密码两条路」 | **当前代码树里没有任何短信登录**。全仓 grep `sms` / `dynamicCheck` / `epd` 只命中 `pan189.rs:632` 的 `dynamicCheck="FALSE"`（账密路径）。短信实现只存在于 `5369be7b`，而 **`git merge-base --is-ancestor 5369be7b HEAD` = NO** —— 那个提交被 `99e141c6`（"账密"版，是 HEAD 祖先）取代了 | `git log`；`grep -rn "sms\|dynamicCheck\|epd"` |
| 3 | `:174` 飞牛「**封面**/长播 authx 过期待办」 | **封面已修**（`poster()` 直接读服务端给的完整 URL，注释「此前这里恒为 None——不是接口没有，是没去读这个字段」）；**长播 authx 也已修**（`media_range_headers` + 反向断言测试）。这两条都不再是待办 | `feiniu.rs:99-107, 652-703` |

### 10.2 代码里自标 UNVERIFIED / 待真机的

| 项 | 说明 | 出处 |
|---|---|---|
| 百度扫码整条链 | 「JSONP 老接口，gid/tt/回调那套**没有官方文档**，只能靠社区脚本复刻。真机跑不通时手动粘贴 BDUSS 那条路仍在」 | `baidu.rs:255-257` |
| 139 根目录 id | 「UNVERIFIED：OpenList 用 `dir.GetID()`，**根对象 ID 未在取到的源码片段里**，按社区约定用 `root`；填错可在表单 `extra.root_id` 覆盖」 | `pan139.rs:32-34` |
| 夸克 TV 整套 | 「**全逆向接口，需真机+扫码验证**」；令牌兑换还经**第三方代理** | `quark_tv.rs:3` |
| 115 端到端 | encode/decode 不互逆 → 本地无法自证与服务端一致 | `pan115_crypto.rs:250-252` |
| 189 AES-ECB 跨实现对齐 | 「这里只验证「同一 key+明文恒定输出」+ 形状，**真正的跨实现对齐留给真机**」 | `pan189.rs:836-837` |
| 189 图形验证码 | `needcaptcha` 非 `"0"` 时**直接让用户改走扫码**；「真机若高频命中再补 `picCaptcha` 往返」 | `pan189.rs:611-614` |

### 10.3 已知不对称 / 缺口

| # | 内容 | 影响 | 出处 |
|---|---|---|---|
| a | **夸克 Cookie 模式的 `__puus`/`__pus` 轮换只进内存，不走 `take_rotated_credentials`** | 重启后回落到存盘的初始 Cookie；TV 模式则有回写 | `quark.rs:22-30, 466-472` |
| b | **`report_progress` 全仓只有飞牛实现了** | 其余源看到一半退出无服务端续播（`entry.raw` 里带 `ts` 的只有飞牛） | `feiniu.rs:604-649`；grep 全仓仅此一处覆写 |
| c | **桌面 / 安卓的 `source_*` 命令是两份手工拷贝**，注释多处提醒同步 | 影视目录三条命令的注释直接写了「★ 这三条在安卓侧有一份独立拷贝，改这里要同步改那里」；局域网源后端表也有同款警告（`:5722-5725`：只加桌面这边的后果是「源加得进去、点进去报『该源类型暂未接入』」，**而且编译全绿**） | `apps/desktop/src/lib.rs:3690-3693, 5722-5725` |
| d | **`local` 源安卓侧未做**（记忆索引称"只有 INTERNET 权限"） | 本次未在 `apps/android` 验证，标**未确认** | — |
| e | **Ani-RSS 的 `cache_token()` 全仓无宿主调用方**（只有测试用） | 是否为预留口子读不出来，标**未确认** | `anirss.rs:100-106` |
| f | **`list_dir` / `resolve_play` 两个 trait 方法在 Ani-RSS 上零测试** | `"ani:"` 前缀往返、episode 排序（INFINITY 沉底）、字幕 URL 的 `?`/`&` 选择、`safe_decode` 兜底全部无守卫 | `anirss.rs:263-396` |
| g | **`preview_items` 依赖 Map 遍历序**（serde_json 是有序 BTreeMap，Dart 是插入序，**Go 的 map 是随机序**） | 若 data 里同时存在多个"对象数组"，Go 侧选中的可能与现实现不同。注释说实测只有一个 | `anirss.rs:1036-1039` |
| h | **三个 reqwest client 一个 timeout 都没设** | 上游黑洞时永远吊着且零日志（记忆索引 `prefetch-fetch-needs-idle-timeout` 记录已在预取侧修为**空闲超时**，但 `http.rs` 的 `cached()` 构造里确实没有 timeout） | `crates/core/src/http.rs:255-282` |

### 10.3.1 ⚠️ 本次对账新发现的三个安卓侧缺口（尚未修复）

这三条都是"双端手工拷贝"这个架构决策的**必然产物**，不是偶发失误。
它们能长期存活是因为同时满足三个条件：**编译绿 + 单测照不到 + 前端 `.catch(() => false)` 吞掉**（`ui/shared/api.ts:1145`）。

**i. 安卓的 302 看门狗是死的**
证据（grep 全量写入点，非推断）——`apps/android/src/lib.rs` 里 `source_play_entry` 只出现在：
`:97` 字段定义 / `:289` `play_local` 置 None / `:3729` watchdog 读 / `:3738` watchdog 置 None / `:4722` 初始化 None。
**没有任何一处写入 `Some(...)`**（desktop 的唯一写入点是 `:3795`，而安卓 `source_play` 没有这一句）。
后果链：`source_watchdog` 读到的 entry 恒 None → let-else 恒 `return Ok(false)` →
**安卓上网盘直链 302 过期后永远不会重签**，表现是播到一半黑掉/停住。
`resign_count` 同理不清零——即使补上 entry 写入，跨片累计到 3 就永久放弃。

**ii. 安卓上浏览型源的服务端进度从不上报**
desktop `report_progress`（`:1854-1865`）在无 Emby target 时 `return report_source_progress(...)`（`:1859`）；
安卓 `report_progress`（`apps/android/src/lib.rs:639-653`）在 `:648` 处 `let Some(t) = target else { return Ok(()) }` **直接返回**，
全文件 grep `report_source_progress` **零出现**。
后果：`MediaSourceBackend::report_progress` 这条通道在安卓上完全没接——受影响的正是飞牛（trait doc 点名的那个源）。

**iii. 安卓的 `sync_plugin_source_grants` 对源而言是死代码**
`apps/android/src/lib.rs:2601-2623` 有完整实现、`:4755` 在 setup 里调用，
但 `source_backend`（`:1846-1848`）对任何插件 kind 直接报错——**插件源在安卓上根本进不到出网那一步**。
（插件系统其它贡献点是否用到这些 grant：**未确认**，本次未读 `crates/core/src/plugins/` 的安卓调用侧。）

> **对 Go 重写的直接结论**：仓库自己在两处贴了「★ 安卓侧有一份独立拷贝，改这里要同步改那里」的警告，
> **而警告没拦住——因为它靠人眼**。核层已经做对的示范是 `probe_backend`：把口径**下沉到 core，两端只调**
> （理由写在 `mod.rs:329-331`）。Go 重写若保留双端各写一份命令层，这类缺口会继续按同样的方式产生。

### 10.4 未确认项（查了哪里，不编）

| 项 | 查过哪里 |
|---|---|
| **`current_source` 命令**：记忆索引 `login-gate-and-source-forms` 说「首登闸口的 `current_session` 必须连 `current_source` 一起拉，否则网盘用户永远进不了门」 | `apps/desktop/src/lib.rs` grep 不到同名 `#[tauri::command]`。源/会话互斥的实现集中在 `set_active_server`（`:632-663`）与启动重建（`:5744-5753`）。需读 `current_session` 命令本体 + `ui/shared/api.ts` 的闸口调用点才能定论 |
| **安卓 `sync_plugin_source_grants` 对插件系统其它贡献点是否有效** | 只读了 `apps/android/src/lib.rs` 与 `crates/core/src/source/`，未读 `crates/core/src/plugins/` 的安卓调用侧。就**源**而言它是死代码（`apps/android/src/lib.rs:1846-1848` 拦死） |
| **`local` 源在安卓侧是否存在** | 记忆索引称"安卓没做（只有 INTERNET 权限）"，本次未在 `apps/android` 中验证 |
| **Ani-RSS 的 `cache_token()`** | 全仓 grep 无宿主调用方（只有测试用）。是否为预留口子读不出来 |

### 10.5 本次没查到原文的一条

**"用 `strings` 查协议完全无效"**：记忆索引 `lan-sources-smb-webdav-ftp` 里有这条（「没 smb 的 DLL 里照样有 "Samba"」），
但**当前代码树的 `source/` 和 `net/` 下没有这句话的原文**。代码里留下的是**替代做法**
（桌面 ctypes 读 `protocol-list`、安卓依赖符号反查，`localserve.rs:4-6`）。
旁证只有 `crates/core/build.rs:2` 的「防 strings/反编译直接捞」和记忆索引 `mpv-release-hygiene` 的「strings 会静默返回空」。
**结论仍然成立且必须遵守，但出处是记忆索引而非本仓注释。**
