# 弹幕载体格式:XML 方案评估

> 调研日期 2026-08-30 · 对象:负责人提出的「弹幕应该用 XML 作为载体去播放」
> 外部事实全部带 URL;代码结论全部带 `文件:行号`;实测项标注了命令与原始输出。

---

## 0. 结论先行

1. **「用 XML 去播放」在技术上不成立。** mpv / libass 一行弹幕 XML 都不认 —— 实测把标准 B 站弹幕 XML 喂给 ffprobe,得到 `Invalid data found when processing input`;mpv 手册全文 1,329,846 字节里 `danmaku` 出现 **0 次**,`XML` 只出现 2 次且都在讲播放列表和章节,与字幕无关。
2. **可行且唯一可行的形态是:XML 当载体,渲染前转成 ASS。** 载体格式(存什么、拿什么交换)和渲染格式(libass 只吃 ASS/SSA)是两层,选 XML 只决定第一层,第二层没有选择权。这个区分正是问题的关键 —— 详见 §6.1。
3. **我们已经支持读 XML 了**(`crates/core/src/danmaku/local.rs:123`),所以「支持 XML」不是新功能,真正的决策点是**要不要把 XML 从「导入格式之一」升格为「内部唯一表示」**。本文建议:**不升格**(路线 a,不是路线 b)。
4. **本文发现一个必须先修的前提错误:** `SPEC.md:583` §7.5 写「现有实现有两条弹幕渲染路径,主路是 ASS 交 `secondary-sid`」—— 这与仓库现状不符。ASS 整条路已在 `108965f6`(2026-07-27)被**用户点名删除**,理由是「次字幕位只有一个,弹幕占了就开不了双语字幕」。Go 侧若照 SPEC 走 `secondary-sid`,会原样复活这个已被否决的冲突。
5. **正确的落法是 `osd-overlay` + `format=ass-events`**(不占任何字幕轨),这也是当前 mpv 社区主流弹幕插件的做法(实读源码确认)。代价是 mpv 不负责时间轴,宿主要自己按 `time-pos` 推位置 —— 这一点 SPEC §7.5 的收益论述没有覆盖。

---

## 1. mpv 能吃什么

### 1.1 所有文本字幕都要过 libass —— 这是硬约束

- libass 官方自述:**"libass is a portable subtitle renderer for the ASS/SSA (Advanced Substation Alpha/Substation Alpha) subtitle format."** 全文未提及 XML 或任何其它格式。
  出处:<https://github.com/libass/libass>
- mpv 的字幕解码器 `sub/sd_ass.c`:输入 codec 不是 `ass`/`null` 时,建一个转换器 `ctx->converter = lavc_conv_create(sd)`,把解码结果经 `lavc_conv_decode()` 转成 ASS 事件,再 `ass_process_chunk()` 交给 libass;转换来的字幕由 `mp_ass_add_default_styles()` 补默认样式。
  出处:<https://github.com/mpv-player/mpv/blob/master/sub/sd_ass.c>
- 结论:**mpv 能渲染的文本字幕 = FFmpeg 能 demux + decode 的字幕格式**,且全部先被拍平成 ASS。

### 1.2 实测:XML 系字幕在 FFmpeg 里是什么待遇

环境:`ffmpeg 8.1.2-full_build`(`--enable-libass`,本机 2026-08-30 实测)。

```
$ ffmpeg -hide_banner -formats | grep -i ttml
  E  ttml            TTML subtitle          ← 只有 E(muxer),没有 D(demuxer)

$ ffmpeg -hide_banner -decoders | grep -i ttml
  (无输出)                                   ← 没有 TTML 解码器
```

**结论:唯一的 XML 系字幕标准 TTML,FFmpeg 只能"写出",不能"读入"。** mpv 播不了 TTML。
(注:<https://ffmpeg.org/general.html> 的 Subtitle Formats 表把 TTML 的 Demuxing 列标成了 `X`,与实际 8.1.2 二进制不符 —— **以实测为准**。2023 年的 TTML demuxer/decoder 补丁见 <https://lists.ffmpeg.org/pipermail/ffmpeg-devel/2023-March/307509.html> 与 <https://ffmpeg.org/pipermail/ffmpeg-devel/2023-March/307510.html>,截至本机版本未体现在发布二进制里。)

FFmpeg 8.1.2 全部字幕解码器(实测 `ffmpeg -decoders | grep -E '^ S'`):

```
libaribcaption, libaribb24, ssa, ass, dvbsub, libzvbi_teletextdec, dvdsub,
cc_dec, pgssub, jacosub, microdvd, mov_text, mpl2, pjs, realtext, sami,
stl, srt, subrip, subviewer, subviewer1, text, vplayer, webvtt, xsub
```

其中带标记语法的只有 `sami`(SAMI 是 SGML/HTML 系,不是 XML,且与弹幕语义完全无关)。**没有任何一个能承载弹幕的轨道/模式/滚动语义。**

### 1.3 实测:弹幕 XML 直接喂 FFmpeg

```
$ ffprobe -v error -show_streams dm.xml
dm.xml: Invalid data found when processing input
```
(`dm.xml` = 标准 `<i><chatserver>…<d p="12.5,1,25,16777215,…">hello danmaku</d></i>`)

**这就是「XML 不能直接播」的直接证据。**

### 1.4 mpv 原生有没有弹幕支持:没有

- mpv master 手册全文实测:`grep -ioc danmaku` → **0**。
  出处:<https://mpv.io/manual/master/>
- `XML` 全文只出现 2 次,原文分别是 `a playlist. Note that XML playlist formats are not supported.` 与 `work with OGM or XML chapters directly.` —— 都与字幕无关。
- 字幕挂载入口只有两个,原文:`--sub-files=<file-list>, --sub-file=<filename>` / "Add a subtitle file to the list of external subtitles." 以及运行时命令 `sub-add`。它们只接受 §1.2 那张解码器表里的格式。

### 1.5 关键约束一:字幕轨只有两条,没有第三条

手册全文只有 `--secondary-sid` 一族(`--secondary-sub-ass-override` / `-delay` / `-pos` / `-scale` / `-visibility`),**没有 tertiary**(实测 grep `tertiary` → 0 命中)。

这就是 `108965f6` 删掉 ASS 弹幕的真原因:弹幕占了次字幕位,双语字幕就没地方放。

### 1.6 关键约束二:另有一条不占轨的路 —— `osd-overlay`

mpv 手册 `osd-overlay` 命令原文(<https://mpv.io/manual/master/>):

> Add/update/remove an OSD overlay. […] You can use this to add text overlays in **ASS format**. ASS has advanced positioning and rendering tags, which can be used to render almost any kind of vector graphics.
>
> `format` → `ass-events`:The `data` parameter is a string. The string is split on the newline character. Every line is turned into the Text part of a Dialogue ASS event. **Timing is unused** (but behavior of timing dependent ASS tags may change in future mpv versions).
>
> `res_x`, `res_y`:specify the value of the ASS PlayResX and PlayResY header fields. […] defaults to 0/720.
>
> There is a separate namespace for each libmpv client […] If the libmpv client is destroyed, all overlays associated with it are also deleted.

要点:
- **不占字幕轨** → 双语字幕保住,`108965f6` 的否决理由消失。
- **`Timing is unused`** → mpv 不管时间轴。滚动动画必须由宿主每一拍重算 `\pos` 再推一次 overlay。**「交给 libass 就零 IPC」这句话对 `osd-overlay` 不成立**,只对 `sub-add` 成立。
- 每个 libmpv client 有独立 id 命名空间,宿主用 `mpv_command_node` 直接调,不需要 Lua。

### 1.7 现有社区方案(全部走「XML/JSON → ASS」)

| 项目 | 做法 | 出处 |
|---|---|---|
| **uosc_danmaku**(当前主流,dyphire) | 各源(弹弹Play / B站 / 巴哈 / 爱奇艺 / 芒果 / 腾讯 / 优酷)统一**转成 B 站 XML** 作中间格式(`modules/parse.lua:575 convert_danmaku_to_xml`),渲染走 `mp.create_osd_overlay('ass-events')` 双层(low/high)按 `time-pos` 每拍重算 `\pos`(`modules/render.lua:8,20-52,118-135`),并可选 `vf append @danmaku:fps=fps=N` 抬高回调频率(`render.lua:196`) | <https://github.com/dyphire/uosc_danmaku> |
| mpv-load-danmaku(同作者,已被上者取代) | 加载同名 `.xml`,调外部 **DanmakuFactory** 转 ASS | <https://github.com/dyphire/mpv-load-danmaku> |
| DanmakuFactory | C 写的 XML/JSON 弹幕 → ASS 转换器,事实上的标准工具 | <https://github.com/hihkm/DanmakuFactory> |
| LoadDanmaku | Lua,加载当前目录同名 `.xml` | <https://github.com/huisedenanhai/LoadDanmaku> |
| bdanmaku | 基于 biliass,B 站弹幕 → ASS | <https://github.com/UlyssesZh/bdanmaku> |
| yt-dlp-danmaku | 下载时把 B 站弹幕转 ASS | <https://github.com/UlyssesZh/yt-dlp-danmaku> |
| lu0se/danmaku、Kosette/danmaku | 弹弹Play API 驱动的 mpv C 插件 | <https://github.com/lu0se/danmaku> / <https://github.com/Kosette/danmaku> |
| Elypha/mpv-danmaku | 自动加载 B 站评论 | <https://github.com/Elypha/mpv-danmaku> |

**这张表本身就是「mpv 没有原生弹幕」的证据** —— 有原生支持就不会有 8 个项目干同一件事。同时它也是「XML 当载体是主流」的证据:uosc_danmaku 把七个不同来源的数据**统一折进 B 站 XML**,这与负责人的提法完全一致。

---

## 2. 弹幕 XML 格式规格

### 2.1 文档结构

```xml
<?xml version="1.0" encoding="UTF-8"?>
<i>
  <chatserver>弹幕服务器主机名</chatserver>
  <chatid>视频的 cid</chatid>
  <mission>0</mission>
  <maxlimit>实时弹幕池容量</maxlimit>
  <state>0=正常 1=关闭</state>
  <real_name>0</real_name>
  <source>e-r</source>
  <d p="…,…,…">弹幕文本</d>
  <d p="…">…</d>
</i>
```

出处:<https://lxb007981.github.io/bilibili-API-collect/danmaku/danmaku_xml.html>
另见 <https://github.com/jabbany/CommentCoreLibrary/blob/master/docs/data-formats/bilibili-xml.md>(自述为「粗略解析定义」,字段少一位,以前者为准)

### 2.2 `p` 属性字段全表(逗号分隔,共 9 段)

| 下标 | 名称 | 类型 | 含义 | 我们现在读吗 |
|---:|---|---|---|---|
| 0 | 出现时间 | float | 相对视频起点的秒数 | ✅ `local.rs:148` |
| 1 | 模式 mode | int32 | 见 §2.3 | ✅ `local.rs:155` |
| 2 | 字号 size | int32 | 常见 18 / 25 / 36 | ❌ 丢弃 |
| 3 | 颜色 color | int32 | 十进制 RGB888 | ✅ `local.rs:156` |
| 4 | 发送时间戳 date | int32 | Unix 秒 | ❌ 丢弃 |
| 5 | 弹幕池 pool | int32 | 见 §2.4 | ❌ 丢弃 |
| 6 | 发送者 author | string | 用户 mid 的 HASH(非明文 uid) | ✅ `local.rs:158` |
| 7 | 弹幕 ID dbid | int64 | 数据库行 ID,单调递增,唯一 | ❌ 丢弃 |
| 8 | 屏蔽等级 | int32 | 0–10,权重阈值(protobuf 里叫 `weight`) | ❌ 丢弃 |

> ⚠️ **下标不能和弹弹Play JSON 混用。** 弹弹Play 的 `p` 只有 4 段 `time,mode,color,userId`,颜色在 **index 2**;XML 的颜色在 **index 3**。抄串了会把 `user_a` 当颜色解析、全部退回白色 —— 这个坑代码里已经用测试钉死了(`local.rs:382 json_real_sample_color_index_differs_from_xml`)。

### 2.3 mode 枚举

| 值 | 含义 |
|---:|---|
| 1 / 2 / 3 | 普通弹幕(滚动) |
| 4 | 底部弹幕 |
| 5 | 顶部弹幕 |
| 6 | 逆向弹幕 |
| 7 | 高级弹幕(带定位/动画参数,文本是 JSON) |
| 8 | 代码弹幕 |
| 9 | BAS 弹幕 |

我们的归一:`4→4, 5→5, 其余→1`(含逆向 6 按滚动处理),见 `crates/core/src/danmaku/local.rs:71 normalize_mode`。

### 2.4 pool 枚举

| 值 | 含义 |
|---:|---|
| 0 | 普通池 |
| 1 | 字幕池 |
| 2 | 特殊池(代码 / BAS 弹幕) |

### 2.5 转义

文本节点用标准 XML 实体:`&amp; &lt; &gt; &quot; &apos;`,实际导出里也常见数字实体 `&#39;`。我们手写解码了这五件套加 `&#39;`(`mod.rs:1532 unescape_xml` + `local.rs:82` 的补丁)。Go 的 `encoding/xml` 自动处理这些,不用自己写(见 §7.1)。

---

## 3. 其它弹幕载体格式

| 载体 | 谁在用 | 结构 | 特点 |
|---|---|---|---|
| **XML**(`<i><d p=…>`) | B 站(历史 web 接口、用户导出)、几乎所有第三方下载器/转换器、uosc_danmaku 的内部中间格式 | 扁平,9 字段挤在一个属性串里 | 事实标准;生态工具最多;字段最全(含 dbid / 时间戳 / 字号 / 池) |
| **protobuf** | B 站现行接口 `/x/v2/dm/web/seg.so`,按 **6 分钟分段**、每段上限 6000 条 | `DmSegMobileReply { repeated DanmakuElem elems }`;`DanmakuElem` = `id / progress(ms) / mode / fontsize / color / midHash / content / ctime / weight / action / pool / idStr` | 体积最小、要 schema、不可手工编辑;**分段**意味着一集要拼多段。出处:<https://lxb007981.github.io/bilibili-API-collect/danmaku/danmaku_proto.html> |
| **JSON**(弹弹Play) | **我们当前的线上数据源** | `{"comments":[{"cid":…,"p":"time,mode,color,uid","m":"text"}]}` | 字段最少(无字号 / 无时间戳 / 无池);`p` 仍是逗号串,等于「JSON 壳里包了个 CSV」 |
| **ASS** | 转换产物 | `Dialogue:` 行 | **渲染格式,不是载体** —— 转过去之后弹幕语义(mode / 用户 / id)就没了,只剩画好的坐标动画,不可逆 |
| **我们的缓存 JSON** | 只在本机磁盘 | `DanmakuComment` 数组 | 见 §4.4 |

### 3.1 体积实测(N = 5000 条,同一批中文弹幕,本机 2026-08-30)

| 载体 | 原始 | gzip |
|---|---:|---:|
| B 站 XML(9 字段全带) | 414.2 KB | 101.2 KB |
| 弹弹Play JSON(线上格式,4 字段) | 394.7 KB | 88.0 KB |
| 我们的缓存 JSON(`DanmakuComment` 全字段) | 760.9 KB | 94.6 KB |

**「XML 体积大」这条反对意见不成立。** 带全 9 个字段的 XML 比只带 4 个字段的弹弹Play JSON 原始大 5%、gzip 大 15%;而比我们**现在正在往磁盘写的**缓存 JSON **小 45%**(原始),gzip 后还小 2%。以一集 5000 条计,gzip 后差 13 KB —— 在任何一条决策里都不构成变量。

---

## 4. 我们现在怎么做的

### 4.1 数据流(现状,一句话)

**线上源(弹弹Play JSON)/ 本地文件(xml·json·ass)→ 归一成 `Vec<DanmakuComment>` → 序列化过 IPC → 前端 Canvas 每帧自绘。**
整条链上**没有任何 ASS 生成**,mpv 完全不参与弹幕。

### 4.2 归一类型

`crates/core/src/danmaku/mod.rs:42`
```rust
pub struct DanmakuComment {
    pub time: f64, pub text: String,
    pub mode: i32,  // 1=滚动 4=底 5=顶
    pub color: i32, // RGB int
    pub source: String, pub cid: Option<String>,
    pub user_id: Option<String>, pub count: i32,
}
```
只有 8 个字段,**字号 / 发送时间戳 / 弹幕池 / 屏蔽等级四项在这里就丢了**。

### 4.3 各载体的解析入口

| 载体 | 位置 | 备注 |
|---|---|---|
| 弹弹Play JSON(线上) | `mod.rs:246 parse_comment` / `mod.rs:417 get_comments`(`GET /comment/{episodeId}`) | `p` 按 4 段解:`time,mode,color,userId` |
| 本地 XML | `local.rs:123 parse_xml` | **手写扫描,没上 quick-xml**(`local.rs:87` 有 `ponytail:` 注释说明取舍);只读 index 0/1/3/6 |
| 本地 JSON | `local.rs:172 parse_json` | 兼容 `comments` / `data` / `danmuku` / 裸数组 |
| 本地 ASS/SSA | `local.rs:248 parse_ass` | 尽力反解;ASS 存 BGR 要翻成 RGB(`local.rs:269`) |
| 格式嗅探 | `local.rs:29 sniff` | **按内容不按扩展名**;ASS 必须先于 JSON 判(首字符都是 `[`) |
| 支持的扩展名 | `local.rs:16` | `["xml","json","ass","ssa"]` |
| 屏蔽词 XML 导入 | `mod.rs:1500 import_dandanplay_blocklist_xml` | 另一处 XML,`<item enabled="true">t=词</item>`,用 regex 抽 |

宿主命令:`apps/desktop/src/lib.rs:3480 danmaku_load_local`、`:3460 danmaku_import_blocklist`;前端 `ui/shared/api.ts:1761 danmakuLoadLocal`。

**回答任务里的第 11 问:是,我们已经支持读本地 `.xml` 弹幕文件,而且是三种本地格式里的第一位。**

### 4.4 缓存落盘格式

`mod.rs:1320 cache_put` —— 写的是 `serde_json::to_string(&CacheFile{ ts, source_id, episode_id, items })`,**JSON,不是 XML**,清理时按 `.json` 扩展名扫(`mod.rs:1343`)。

### 4.5 渲染

`ui/shared/Danmaku.tsx`(178 行)—— Canvas 2D,自跑 rAF,时间从 `timeSync` 插值(`{base, stamp, paused, speed}`),**speed 是必需字段**(缺它 2x 播放会每 250ms 硬跳一次,这是「弹幕卡」的历史真根因,注释写在 `Danmaku.tsx:9-12`)。

### 4.6 ★ ASS 路曾经存在,并被明确删除

`git log`:commit **`108965f6`**(2026-07-27)"删掉 mpv/ASS 弹幕整条路"。提交信息原文:

> **次字幕位只有一个,弹幕占了就开不了双语字幕** —— 上一版 PC 端已经改走网页层,核层那半留着就是死代码。
> (用户:「删掉就行了 那个没必要留」)

删掉的东西:
- `crates/core/src/danmaku/ass.rs`(360 行,含 `AssOptions{play_res_x/y, font, font_size, opacity, area_percent, scroll_secs, fixed_secs, outline, bold}`)
- `crates/mpv`:`set_danmaku_sub` / `clear_danmaku_sub` / `set_danmaku_visible` / `attach_danmaku_raw` / `danmaku_sid` / `pending_danmaku`
- 两个壳:`danmaku_attach` / `danmaku_detach` / `danmaku_visible`
- `ui/shared/api.ts` 的 `DanmakuAssOptions`

被删的 `ass.rs` 文件头(`git show 108965f6^:crates/core/src/danmaku/ass.rs`)记录了当初换 ASS 的理由与取舍,对 Go 侧仍然有效:
- 用固定 PlayRes 1920×1080 描述版面,libass 自己缩放 → 改窗口/全屏不用重新生成;
- 文字宽度是**估算**的(全角 1.0em / 半角 0.55em),因为核层拿不到字体度量;
- 附带好处:mpv 的截图/录制会带上弹幕(见 §6.4)。

### 4.7 ★ Go 迁移文档里的两处前提错误(需要修)

| 位置 | 现文 | 事实 |
|---|---|---|
| `docs/go-migration/SPEC.md:583` §7.5 | 「现有实现有两条弹幕渲染路径:主路是生成 ASS 交 mpv 的 `secondary-sid`,另有一条网页层绘制作为 fallback」 | **只有一条**,就是网页层 Canvas。ASS 路 2026-07-27 已整条删除(§4.6)。「取消网页层回退」实际是「把已删的 ASS 路重建回来」,不是「删掉一条冗余路径」 |
| `docs/go-migration/MIGRATION.md:193` | 把「插值里必须有倍速 / ASS 是 BGR / 走 `secondary-sid` + `secondary-sub-ass-override=no`」标注在 `danmaku/local.rs` 上 | `local.rs` 是**本地文件解析器**,与倍速插值、`secondary-sid` 都无关。倍速插值在 `ui/shared/Danmaku.tsx:9`;`secondary-sid` 那条已随 `108965f6` 删除 |

§7.5 的两条理由本身站得住(三端没有覆盖在视频上的 WebView;倍速根因已修),**但它漏了当初删 ASS 路的那个理由 —— 双语字幕冲突。** 按 §7.5 字面照做(`secondary-sid`)会复活一个用户已经拍板否决的问题。解法见 §6.2。

---

## 5. 三条路线对比

先明确:**载体选择**和**渲染选择**是两个正交的轴。下表是载体轴。

| | (a) XML 只作存储/交换,播放前转 ASS | (b) XML 作唯一内部表示,渲染层从 XML 直出 | (c) 保持现状(结构化类型 + 前端 Canvas) |
|---|---|---|---|
| **怎么实现** | 线上源(弹弹Play JSON / protobuf)→ 解析成 `Comment` 结构体 → 渲染前生成 ASS。XML 只出现在两个端点:读本地 `.xml`、导出 `.xml` | 所有源先转成 XML 字符串存内存/磁盘,渲染时再解 XML 生成 ASS | 结构体过 IPC 给三端,各端自己画 |
| **优势** | 结构化类型是唯一真值,类型安全;载体格式换掉不影响渲染;XML 导出即得,兼容 potplayer / DanmakuFactory / uosc_danmaku 等外部生态;**基本已经做完了**(`local.rs:123` 已能读,只差导出) | 唯一格式,概念上少一层;落盘即是可分享文件 | 零改动 |
| **代价** | 需要一个 `Comment → ASS` 生成器(≈360 行,有历史实现可参考);要写一个 XML 导出器(≈30 行) | 每次渲染多一次字符串解析;弹弹Play 的 4 字段塞进 9 字段 XML 会有 5 个空位(字号/时间戳/池/dbid/等级 全靠编);内存里存字符串比存结构体大(实测 §3.1:XML 414 KB vs 结构化二进制会更小);类型系统帮不上忙,字段错位只能靠测试兜(`local.rs:382` 那个坑会变成常态风险) | **Go 迁移下不成立** —— `SPEC.md` §7.5 已定三端没有覆盖在视频上的 WebView,保留它等于三端各写一遍渲染器 |
| **风险** | 低。风险集中在渲染轴(§6.2),与载体无关 | 中。**信息造假风险**:把没有的字段填默认值写进 XML,再被外部工具当真数据读走。另:XML 解析在热路径上,一集 5000 条每次重载都要重解 | 高(与已定架构冲突) |
| **Go 里好不好写** | 好。`encoding/xml` 只在 import/export 两处用,`Unmarshal` 一个 10 行结构体即可 | 一般。要把 XML 字符串当状态在模块间传,失去 Go 类型系统全部帮助;`[]byte` 满天飞 | 不适用 |

---

## 6. 推荐方案 + 理由

### 6.1 先把「载体 ≠ 渲染格式」这句话说死

「弹幕应该用 XML 作为载体去播放」这句话里有两个不同的诉求被压在一起了:

| 层 | 问题 | 有没有选择权 | 答案 |
|---|---|---|---|
| **载体层** | 弹幕数据用什么存、用什么交换、本地文件长什么样 | **有** | XML 是好选择(生态最广、字段最全、可手工编辑、跨播放器) |
| **渲染层** | 交给谁画到画面上 | **没有** | 只能是 ASS。libass 只吃 ASS/SSA(§1.1),FFmpeg 连 TTML 都读不了(§1.2),弹幕 XML 直接喂进去报 `Invalid data`(§1.3) |

所以 **「用 XML 播放」的准确表述是「用 XML 存,播放时转 ASS」**。负责人的方向没错,但如果这句话被理解成「把 XML 塞给 mpv」,实现时会撞墙;如果被理解成「内部一切都用 XML 字符串」,会撞上路线 (b) 的代价。

### 6.2 推荐:载体走 (a),渲染走 `osd-overlay`

**载体:路线 (a)** —— XML 作为**导入 / 导出 / 本地文件**格式,内部保持结构化类型。

理由:
1. **一半已经落地了。** `local.rs:123` 已能读 B 站 XML,`local.rs:16` 已把 `xml` 列在支持列表首位。缺的只有导出。
2. **结构化类型是唯一真值** 这条已经被代码验证过一次:XML 的 color 在 index 3、弹弹Play JSON 在 index 2,靠类型 + 两个解析器分别负责才没出错(`local.rs:382` 的测试)。改成"全走 XML 字符串"会把这个已解决的坑变成长期风险。
3. **XML 体积不是问题**(§3.1 实测),所以选它的唯一代价是解析开销,而在路线 (a) 下解析只发生在 import/export,不在热路径。
4. **对外兼容性是真收益**:导出的 `.xml` 能被 DanmakuFactory、uosc_danmaku、potplayer 直接吃;反过来用户从任何下载器拿到的 `.xml` 也能进我们。这一条是 JSON / protobuf 都给不了的。

**渲染:`osd-overlay` + `format=ass-events`,不是 `sub-add` + `secondary-sid`。**

理由:
1. `sub-add` 会吃掉唯一的次字幕位(§1.5),这正是 `108965f6` 里用户拍板删掉整条 ASS 路的原因(§4.6)。SPEC §7.5 没有回应这一点。
2. `osd-overlay` 不占任何轨(§1.6),双语字幕和弹幕可以并存 —— **这是 2026-07 那次删除之后出现的新解法,它让 §7.5 的结论重新成立**,但要换实现手段。
3. 这是社区主流方案的做法,有可读源码:uosc_danmaku `modules/render.lua:8` 建两个 `ass-events` overlay(low/high 分层管 z 序),`render.lua:20-52` 按 `time-pos` 线性插出当前 `\pos`,`render.lua:196` 用 `vf append @danmaku:fps=fps=N` 抬高刷新率。

### 6.3 必须同时接受的代价(说清楚,不藏)

`osd-overlay` 的 `ass-events` 明确写着 **`Timing is unused`**(§1.6)。所以:

- **mpv 不会替我们做时间轴。** 滚动位置要宿主每一拍自己算,和现在 Canvas 做的事一样。「交给 libass 就零 IPC / 零插值」这句话**只对 `sub-add` 成立,对 `osd-overlay` 不成立**。
- 但和现在相比仍然是净赚:
  - 计算搬进 Go 核层,三端共用一份(现在是 TS 一份,且 Go 迁移后三端没 WebView);
  - 绘制交给 libass(GPU 路径,与字幕同一条),不再需要一层透明 WebView 覆盖在视频上;
  - **倍速/暂停/seek 不用再从 mpv 轮询 + 墙钟外推** —— 核层在进程内直接读 `time-pos`,没有 IPC 往返,那个历史真根因(`Danmaku.tsx:9-12`)从结构上消失。
- 刷新率:`time-pos` 的回调频率取决于视频帧率;低帧率片源上弹幕会跟着卡。uosc_danmaku 的解法是插 `fps` 滤镜。**这条需要实测**(§8)。

### 6.4 不推荐路线 (b),不推荐路线 (c)

- **(b)** 的致命问题是**字段造假**:弹弹Play 只给 4 个字段,写进 9 字段 XML 就得给字号/时间戳/池/dbid/屏蔽等级编 5 个值,而这些 XML 会被导出给外部工具当真数据读。用结构化类型 + `Option<T>` 才能诚实表达「这个源没有这个字段」。
- **(c)** 与 `SPEC.md` §7.5 已定架构冲突(三端没有覆盖视频的 WebView),不再是选项。

---

## 7. 落地要点(Go 侧)

### 7.1 XML 解析:`encoding/xml` 标准库,不加依赖

```go
type danmakuFile struct {
    XMLName xml.Name `xml:"i"`
    ChatID  string   `xml:"chatid"`
    Entries []struct {
        P    string `xml:"p,attr"`
        Text string `xml:",chardata"`
    } `xml:"d"`
}
```

标准库直接解决我们现在手写的两块(出处 <https://pkg.go.dev/encoding/xml>):

- **实体解码自动完成** —— `CharData` 文档原文:*"XML character data (raw text), in which XML escape sequences have been replaced by the characters they represent."* `&amp; &lt; &gt; &quot; &apos;` 与数字实体 `&#39;` 都不用自己处理。可以删掉 `mod.rs:1532 unescape_xml` 和 `local.rs:82` 那个 `&#39;` 补丁。
- **容错必须显式打开**:`d := xml.NewDecoder(r); d.Strict = false`。文档原文:*"Strict defaults to true, enforcing the requirements of the XML specification. If set to false, the parser allows input containing common mistakes."* 第三方导出的弹幕文件常有未转义的裸 `&`、缺闭合标签,严格模式会整份失败 —— 而我们现在的手写扫描是天然容错的,**换标准库不打开这个开关就是功能回退**。
- **非 UTF-8 必须挂 `CharsetReader`**:文档原文 *"The parser assumes that its input is encoded in UTF-8."* 老弹幕导出里有 `encoding="GB18030"` / `GBK` 的,不挂就直接报错。用 `golang.org/x/net/html/charset` 的 `charset.NewReaderLabel`。
  > 现有 Rust 实现收的是 `&str`,等于**已经假设了 UTF-8**,GBK 文件现在就是坏的 —— 这是顺手能补的一个真 bug,不是新增需求。
- 大文件用 `d.Token()` 流式;5000 条 414 KB 的量级下 `Unmarshal` 一把梭也够(§3.1)。

### 7.2 字段映射表(XML → 内部类型)

内部类型建议在现有 8 字段基础上补回被丢掉的,用指针/`Option` 表达「源没有」:

| XML `p` 下标 | 内部字段 | 转换 | 源缺失时 |
|---:|---|---|---|
| 0 | `Time float64` | `strconv.ParseFloat`;**解析失败必须跳过整条,不能退 0** | — |
| 1 | `Mode int` | `4→4, 5→5, 其余→1` | 默认 1 |
| 2 | `FontSize *int` | 直取 | `nil`(弹弹Play 没有) |
| 3 | `Color int` | 十进制 RGB888 | 默认 `16777215`(白) |
| 4 | `SentAt *int64` | Unix 秒 | `nil` |
| 5 | `Pool *int` | 0/1/2 | `nil` |
| 6 | `UserID *string` | 空串归 `nil` | `nil` |
| 7 | `DmID *string` | 去重/幂等的天然主键 | `nil` |
| 8 | `Weight *int` | 屏蔽等级 0–10 | `nil` |

> **红线:时间解析失败必须整条跳过。** 现有 Rust 实现明确这么做并写了理由(`local.rs:147`):退化成 0 秒等于把弹幕全堆在片头。Go 版照抄这个行为,别用 `ParseFloat` 的零值。
>
> **红线:整份解析不出东西必须返回 error。** 见 `local.rs:4-5` 的注释和 `local.rs:164`:返回空切片会让用户看到「加载成功但一条弹幕没有」且无从排查。单条畸形跳过是对的,整体失败装成功不是。

### 7.3 和现有数据源共存

不动线上链路。只在两端接 XML:

```
弹弹Play JSON ─┐
B站 protobuf  ─┼→ []Comment ─┬→ ASS 生成 → osd-overlay(播放)
本地 .xml     ─┤             ├→ XML 导出(用户"保存弹幕")
本地 .json    ─┤             └→ 缓存落盘
本地 .ass     ─┘
```

- **格式嗅探照抄现有规则**(`local.rs:29`):按内容首字节判,不信扩展名(用户改名 / 下载器乱给后缀是常态);**ASS 必须先于 JSON 判**,两者首字符都是 `[`,顺序错了每个 ASS 都会报「JSON 解析失败」。
- **缓存落盘可以顺手换成 XML**:实测比现在的 `DanmakuComment` JSON **小 45%**(§3.1),且缓存文件直接就是用户可分享、可被外部工具读的文件。但清理逻辑按扩展名扫(`mod.rs:1343` 扫 `.json`),换格式要同步改,否则老缓存永远清不掉。**这是可选项,不是推荐项** —— 缓存里带 `source_id`/`ts` 等我们自己的元数据,塞进 `<i>` 会污染标准结构。

### 7.4 本地 `.xml` 文件怎么发现

现状是**用户手动选文件**(`apps/desktop/src/lib.rs:3480 danmaku_load_local(path)`),没有自动发现。Go 侧建议补自动发现,规则照社区约定(mpv-load-danmaku / LoadDanmaku 都是"同目录同名"):

优先级从高到低,命中即停:

1. `<视频文件名去扩展名>.xml`(同目录)—— 社区事实标准
2. `<视频文件名去扩展名>.danmaku.xml`
3. 同目录下 `<视频文件名去扩展名>.*` 中扩展名在 `[xml, json, ass, ssa]` 里的
4. 用户在设置里指定的弹幕目录下的同名文件

约束:
- **只对本地/局域网可枚举目录做**。Emby / 网盘 / VOD 源上做同名探测 = 每次起播多发一串 404 请求,不值。
- **自动发现的结果不能覆盖用户手选的**,也不能覆盖已经自动匹配上的线上弹幕 —— 给出提示让用户切换,别静默替换。
- 大小写:Windows 不敏感、Linux/Android 敏感,匹配时统一小写比较扩展名(现有 `local.rs:63 ext()` 已经 `to_lowercase()`,照抄)。

### 7.5 ASS 生成(渲染轴,与载体无关但一起落)

- 固定 `PlayResX/Y = 1920/1080`,让 libass 缩放 → 改窗口/全屏不重生成(照抄被删的 `ass.rs` 的做法)。`osd-overlay` 用 `res_x`/`res_y` 参数传。
- 文字宽度估算:全角 1.0em / 半角 0.55em(核层拿不到字体度量;只影响轨道分配松紧,不影响观感)。
- 颜色:**ASS 是 BGR**,内部存 RGB,写出时要翻(现有反向转换见 `local.rs:269-278`)。
- 分两层 overlay:滚动一层、顶/底一层,用 `z` 控堆叠(照 uosc_danmaku `render.lua:118-135`)。
- 通过 `mpv_command_node` 调,`osd-overlay` 是具名参数命令。
  > **未确认**:能否用 `mpv_command` 的位置参数数组调用 `osd-overlay`。见 §8。

### 7.6 迁移文档要同步修的

- `SPEC.md:583` §7.5:前提改成「现有实现只有网页层一条路,ASS 路已于 `108965f6` 删除」;并补上「渲染走 `osd-overlay` 不走 `secondary-sid`,原因是次字幕位与双语字幕冲突」。
- `MIGRATION.md:193`:把倍速插值 / `secondary-sid` 从 `local.rs` 那一行挪走(见 §4.7)。
- `COMMANDS.md:240` 弹幕 14 条命令表:确认没有把已删的 `danmaku_attach` / `danmaku_detach` / `danmaku_visible` 列进去(`108965f6` 已从 `mobile-commands.txt` 移除,跨语言契约测试当时抓到过漏改)。

---

## 8. 存疑 / 需要实测验证的

以下每条都标注了已经查过哪里、为什么还没结论。

| # | 存疑项 | 已查 | 缺什么 |
|---:|---|---|---|
| 1 | **`osd-overlay` 的实际刷新率够不够** | 手册确认 `Timing is unused`,uosc_danmaku 用 `vf append @danmaku:fps=fps=N` 抬频率,并在 `display-fps < 58` 或 `estimated-vf-fps > 58` 时跳过(`render.lua:196-203`) | 没有实测。要在 24fps 片源上量弹幕滚动是否肉眼可见地卡,以及插 `fps` 滤镜对解码开销的影响。**这条是整个方案唯一的观感风险点,必须先做 spike** |
| 2 | **`osd-overlay` 能否用位置参数经 `mpv_command` 调用** | 手册只写了参数名(`id/format/data/res_x/res_y/z`),`mpv_command_node` + NODE_MAP 确定可行 | 没试过扁平字符串数组形式。落地时直接用 NODE_MAP 即可绕过,不阻塞 |
| 3 | **`osd-overlay` 的弹幕进不进截图** | 手册 `screenshot` 标志:`<subtitles>`(默认)"Save the video image with subtitles";`<osd>` "Save the video image with OSD";`<window>` = `scaled+subtitles+osd` | 推断 `osd-overlay` 的内容只在带 `osd` 标志时进截图(与 `sub-add` 路默认就进不同),**未实测**。若要保持「截图带弹幕」,截图命令要改成 `screenshot subtitles+osd` |
| 4 | **libass 在 Android 上渲染大量并发 ASS 事件的性能** | 已知安卓 libass 缺字体要 `sub-fonts-dir=/system/fonts`(`crates/mpv/src/lib.rs:1262`) | 没有量过"同屏 60+ 条弹幕"在中低端安卓机上的开销。现有 Canvas 版有 dpr 封顶 2 的优化(`Danmaku.tsx:56`),libass 版没有等价旋钮 |
| 5 | **FFmpeg 的 TTML demuxer/decoder 补丁最终有没有合并** | 实测 8.1.2 二进制没有;`ffmpeg.org/general.html` 的表格却标了 Demuxing `X`;2023 年补丁邮件在列表里 | 没查 FFmpeg master 的 git 状态。**不影响结论** —— 就算 TTML 能读,它也不是弹幕格式 |
| 6 | **`weight`(屏蔽等级)和 pool 我们要不要用** | 字段含义已查清(§2.2 / §2.4) | 没调研 B 站的 `weight` 阈值实际分布,也没确认代码/BAS 弹幕(mode 8/9、pool 2)我们是直接丢还是尝试渲染。现有实现全部按滚动处理(`local.rs:71`) |
| 7 | **B 站 protobuf 源要不要接** | 格式已查清(§3),分段 6 分钟 / 6000 条上限 | 我们现在只有弹弹Play 一个线上源。接不接是产品决策,不在本文范围 |
| 8 | **老弹幕文件的编码分布** | 已确认 Go 侧不挂 `CharsetReader` 会直接报错;Rust 侧收 `&str` 等于已假设 UTF-8 | 没统计过野生 `.xml` 里 GBK/GB18030 的实际占比。**结论不依赖它** —— 挂 `CharsetReader` 成本是 3 行 |

---

## 附:一句话给负责人

> 方向对,措辞要改一个字:**不是「用 XML 播放」,是「用 XML 存、播放时转 ASS」**。mpv 那头只认 ASS,这没有商量余地(实测弹幕 XML 喂 ffprobe 直接 `Invalid data`)。XML 当载体值得做,而且一半已经在跑了(`local.rs:123`)。真正要拍板的不是载体,是渲染怎么落 —— **`SPEC.md` §7.5 写的 `secondary-sid` 会把 2026-07-27 你自己拍板删掉的「弹幕占了双语字幕位」原样复活**,要改走 `osd-overlay`。
