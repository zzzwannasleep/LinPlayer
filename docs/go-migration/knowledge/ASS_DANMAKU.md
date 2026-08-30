# ASS 字幕与弹幕渲染知识

> 目的:Rust 核心层重写成 Go 之前,把「ASS 字幕格式 + 弹幕渲染 + mpv 字幕子系统」这一整块摸透。
> 规则:每条结论带 `文件:行号`。读不出来的写「未确认」并说明查过哪里。
> 采集时间:2026-08-30,基于 `main` @ `85b47417`。

---

## 0. 一句话

**弹幕现在是前端 Canvas 画的,不是 ASS**——ASS 生成那条路在 `108965f6` 被整条删除(理由:mpv 只有一个次字幕位,弹幕占了就开不了双语字幕);但 ASS 知识仍然是必需品,因为**字幕**子系统(内封 ASS / 外挂 ASS / 翻译字幕 / 本地弹幕文件导入)全都在跟 ASS 打交道,而且被删的那份生成器是本仓库唯一一份教程级的 ASS 写法参考,Go 侧若要重开这条路必须照抄它的坑。

**读这份文档的最短路径**:
- 只想会写 ASS → 第 1 节(含一份真跑出来的完整样例)+ 第 2 节(布局算法)
- 只关心弹幕能不能匹配上 → 3.2 ~ 3.4 + 坑 13b ~ 13g
- 只关心 mpv 字幕 → 第 4 节(属性表)+ 坑 2 / 3 / 4 / 14 / 15 / 16
- 准备动手写 Go → 第 6 节,再回头看它引用的坑
- **只有 10 分钟** → 直接看第 5 节。那里每一条都是一次真实故障。

---

## 0.1 先纠正三件事(读这份文档前必须知道)

### ① 任务书里说 `crates/core/src/danmaku/local.rs` 是「ASS 生成的核心」——**不是**

`local.rs` 是**解析器**,把用户导入的本地 `.xml` / `.json` / `.ass` 文件转成 `DanmakuComment`
(`crates/core/src/danmaku/local.rs:1-5` 文件头注释自述:「本地弹幕文件解析:用户导入的 .xml / .json / .ass 转 DanmakuComment」)。
它里面一行 ASS 都不生成。

### ② ASS **生成器**存在过,但已被删除

- 文件:`crates/core/src/danmaku/ass.rs`,360 行。
- 删除提交:`108965f6`(2026-07-27)标题即「删掉 mpv/ASS 弹幕整条路」。
- 恢复方式:`git show 108965f6^:crates/core/src/danmaku/ass.rs`。
- 本文第 1、2 节的行号,凡标注 `[已删] ass.rs:N` 的,均指该 blob 内的行号,**不是当前工作区**。

删除时一并拔掉的东西(commit message 原文逐条列出):

| 被删对象 | 位置 |
|---|---|
| `ass.rs` 全文 + `mod` 入口 | `crates/core/src/danmaku/ass.rs`、`crates/core/src/danmaku/mod.rs`(-1 行) |
| `set_danmaku_sub` / `clear_danmaku_sub` / `set_danmaku_visible` / `attach_danmaku_raw` / `danmaku_sid` / `pending_danmaku`,及只服务它的 `set_str_raw` / `get_str_raw` / `last_sub_id_raw` 三个助手 + 一条 `#[ignore]` 集成测试 | `crates/mpv/src/lib.rs`(-192 行) |
| `danmaku_attach` / `danmaku_detach` / `danmaku_visible` 三条命令 + `danmaku_comments` / `danmaku_seq` 两个 state 字段 | `apps/desktop/src/lib.rs`(-76)、`apps/android/src/lib.rs`(-70) |
| `DanmakuAssOptions` + 三个导出 | `ui/shared/api.ts`(-28) |

**删除理由**(commit message 原文):

> 次字幕位只有一个,弹幕占了就开不了双语字幕 —— 上一版 PC 端已经改走网页层,核层那半留着就是死代码。

`ui/desktop/App.tsx:141-149` 把这个决定写死进了代码注释,并且点明了「当初为什么要换成 mpv」这个动机现在已经失效:

> 为什么二选一选的是网页层而不是 mpv:mpv 那条路是把弹幕生成 ASS 挂到 **secondary-sid** 上,而次字幕位只有一个 —— 开了弹幕就没法开双语字幕,反过来也一样。一个设置项换来两个功能互斥,不如把它去掉。
> 当初改用 mpv 是为了治「倍速下弹幕一顿一顿」,但那个 bug 的真因是网页层的墙钟插值里漏了倍速因子(见 Danmaku.tsx 的 TimeSync),那已经修好了,不需要靠换渲染引擎来绕。

### ③ 项目记忆 `danmaku-via-libass-ass.md` 已过期

那条记忆说「现在的方案(2026-07-26):`crates/core/src/danmaku/ass.rs` 生成 ASS → `sub-add` 给 mpv」。
该方案在**次日**(2026-07-27,`108965f6`)就被推翻了。它记录的 mpv 事实(BGR、`secondary-sub-ass-override=no`)仍然正确,但「现在的方案」一节已不成立。

---

## 1. ASS 格式速查

本节写成教程级:看完应当能不看 ASS 规范直接生成一份可用文件。
凡带 `[已删] ass.rs:N` 的是本仓库曾经的真实写法;凡带「规范」的是 ASS/SSA 格式本身的语义,仓库里没有对应出处(已如实标注)。

### 1.1 文件结构

ASS(Advanced SubStation Alpha,`v4.00+`)是纯文本、分节(section)的格式。节名用 `[方括号]` 起头。
本仓库曾经生成的完整骨架 —— `[已删] ass.rs:185-201`:

```
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, ... , Encoding
Style: LP,Microsoft YaHei,48, ... ,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:09.00,LP,,0,0,0,,{...}文本
```

三个节,顺序固定,缺一不可:

#### `[Script Info]`

我们只写了 5 个键(`[已删] ass.rs:186-191`),逐个解释:

| 键 | 我们填的值 | 含义 | 为什么这么填 |
|---|---|---|---|
| `ScriptType` | `v4.00+` | 脚本版本。`v4.00` = 老 SSA,`v4.00+` = ASS | 用 `+` 才能用 `[V4+ Styles]` 那 23 字段的 Style 行和全套覆盖标签 |
| `PlayResX` | `1920` | 版面**虚拟**宽度 | 见 1.1.1 |
| `PlayResY` | `1080` | 版面**虚拟**高度 | 见 1.1.1 |
| `WrapStyle` | `2` | 换行策略。`2` = **不自动换行**,只在显式 `\N` 处断行 | 弹幕是单行横穿,自动换行会把长弹幕折成两行顶乱轨道 |
| `ScaledBorderAndShadow` | `yes` | 描边/阴影粗细是否随缩放一起缩放 | `no` 的话 4K 屏上描边细成一根线,1080 版面放大到 4K 时描边不跟着放大 |

> 未在仓库中出现、但 ASS 规范里常见的键:`Title`、`Collisions`、`Timer`、`YCbCr Matrix`。
> `local.rs` 的测试夹具里出现过 `Title:`(`crates/core/src/danmaku/local.rs:427`),说明解析侧要容忍它们,但生成侧一个都没写。

#### 1.1.1 PlayResX / PlayResY:缩放是怎么发生的

这是 ASS 里最容易搞错的一件事。

`PlayResX/Y` 声明的是**版面坐标系**,不是视频分辨率。`\pos(960,0)` 里的 960 是这个虚拟坐标系里的 960,不是屏幕像素的 960。libass 渲染时会把整个版面等比缩放到实际画面尺寸。

`[已删] ass.rs:14-17` 的原文:

> ## 坐标系
> 用固定的 PlayRes(1920×1080)描述版面,libass 会自己缩放到实际画面 —— 所以窗口大小变化、全屏切换都不用重新生成。

这一条是整个设计的地基:**窗口一变、全屏一切,ASS 文件不用重新生成**。对比 Canvas 版,后者每次 resize 都要重算(`ui/shared/Danmaku.tsx:64` 挂 `ResizeObserver`)。

同一件事在前端的另一半:`ui/desktop/App.tsx:133-137` 的字号表第三列是**ASS 字号**,注释写着:

> 第三列是 **ASS 字号**,活在固定的 1080 坐标系里,所以换窗口大小观感不变 ——「中」= 49 ≈ 老自适应的 canvas.height/22,换渲染引擎不改默认观感。

**Go 侧要点**:字号、坐标、轨道高度全部在 PlayRes 坐标系里算,一次算完永久有效。不要引入任何「当前窗口宽度」。

#### `[V4+ Styles]`

一行 `Format:` 声明字段顺序,后面若干行 `Style:` 按这个顺序填值。
**`Format:` 行不是装饰**——解析器必须按它定位字段,不能按固定下标硬取。仓库的字幕解析器正是这么做的(`crates/core/src/translation.rs:269-278`:先吃 `Format:` 建索引表,再用 `idx("Start")` / `idx("Text")` 取字段)。

#### `[Events]`

同样先 `Format:` 再若干 `Dialogue:` / `Comment:`。
`Comment:` 行是被注释掉的事件,**不渲染**。仓库的解析器只认 `Dialogue:` 前缀(`crates/core/src/danmaku/local.rs:251`),测试专门钉住了这一点(`local.rs:479` 放了一行 `Comment:`,`local.rs:482` 断言只解析出 1 条)。

---

### 1.2 Style 字段全表

`Format:` 行原文(`[已删] ass.rs:194`):

```
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
```

模板原文(`[已删] ass.rs:195`):

```
Style: LP,{font},{font_size},&H{alpha:02X}FFFFFF,&H{alpha:02X}FFFFFF,&H{alpha:02X}000000,&H{alpha:02X}000000,{bold},0,0,0,100,100,0,0,1,{outline:.1},0,7,0,0,0,1
```

23 个字段逐个对照(默认档位:`font=Microsoft YaHei`、`font_size=48`、`opacity=80` → `alpha=0x33`、`bold=false`、`outline=2.0`,见 `[已删] ass.rs:53-69`):

| # | 字段 | 我们填 | 含义 | 为什么 |
|---|---|---|---|---|
| 1 | `Name` | `LP` | 样式名,`Dialogue` 行按名引用 | 只有一个样式,起名 LP(LinPlayer)避免和内封字幕的 `Default` 撞名 |
| 2 | `Fontname` | `Microsoft YaHei` | 字体族名 | `[已删] ass.rs:58`。字体不存在时 libass 回退,不报错 |
| 3 | `Fontsize` | `48` | 字号,**PlayRes 坐标系单位**不是 px | `[已删] ass.rs:59` 注释:「1080p 下 48px ≈ 老 Canvas 版 canvas.height/22 的观感,换栈不改默认观感」 |
| 4 | `PrimaryColour` | `&H33FFFFFF` | 正文填充色 | 白色 + alpha。**真实颜色由每条 `\c` 覆盖**,这里的 FFFFFF 只是兜底 |
| 5 | `SecondaryColour` | `&H33FFFFFF` | 卡拉OK 未唱到部分的颜色 | 我们不用卡拉OK,填成和 Primary 一样 |
| 6 | `OutlineColour` | `&H33000000` | 描边色 | 黑描边。弹幕压在任何画面上都要看得清 |
| 7 | `BackColour` | `&H33000000` | 阴影色(`BorderStyle=1` 时)/ 背景框色(`BorderStyle=3` 时) | 黑,但 `Shadow=0` 所以实际不画 |
| 8 | `Bold` | `-1` 或 `0` | 粗体。**`-1` = 开,`0` = 关** | `[已删] ass.rs:184`:`let bold = if o.bold { -1 } else { 0 };`。ASS 的布尔是 `-1`/`0` 不是 `1`/`0`,填 `1` 在部分渲染器上等于关 |
| 9 | `Italic` | `0` | 斜体 | 不用 |
| 10 | `Underline` | `0` | 下划线 | 不用 |
| 11 | `StrikeOut` | `0` | 删除线 | 不用 |
| 12 | `ScaleX` | `100` | 横向拉伸百分比 | 不变形 |
| 13 | `ScaleY` | `100` | 纵向拉伸百分比 | 不变形 |
| 14 | `Spacing` | `0` | 字间距(额外像素) | 不加 |
| 15 | `Angle` | `0` | 旋转角度(度) | 不转 |
| 16 | `BorderStyle` | `1` | `1` = 描边+阴影;`3` = 不透明底框 | 弹幕要描边不要底框 |
| 17 | `Outline` | `2.0` | 描边粗细 | `[已删] ass.rs:48-49`,可配 |
| 18 | `Shadow` | `0` | 阴影偏移距离 | 关掉。已有描边,再加阴影是白烧填充率 |
| 19 | `Alignment` | `7` | 默认锚点(数字小键盘布局,见 1.5 `\an`) | `7` = 左上。滚动弹幕的 `\move` 坐标按左上角算才好推 |
| 20 | `MarginL` | `0` | 左边距 | 弹幕自己算坐标,不要边距干扰 |
| 21 | `MarginR` | `0` | 右边距 | 同上 |
| 22 | `MarginV` | `0` | 上下边距 | 同上 |
| 23 | `Encoding` | `1` | 字符集。`0`=ANSI,`1`=Default,`134`=GB2312,`128`=Shift-JIS | `1` 交给系统判断 |

**已实测的生成结果**(第 1.6 节是真跑出来的,不是手推):

```
Style: LP,Microsoft YaHei,48,&H33FFFFFF,&H33FFFFFF,&H33000000,&H33000000,0,0,0,0,100,100,0,0,1,2.0,0,7,0,0,0,1
```

---

### 1.3 颜色与 alpha

#### 格式

ASS 颜色写作 `&HAABBGGRR&` 或 `&HBBGGRR&`(6 位形式不带 alpha)。**两个反直觉点**:

1. **字节序是 BGR,不是 RGB。**
2. **alpha 是反的:`00` = 完全不透明,`FF` = 完全透明。**

`[已删] ass.rs:104` 的注释原文:

> RGB int → ASS 的 `&HBBGGRR&`(ASS 是 BGR 序,写反了整片弹幕会红蓝互换)。

#### RGB → ASS(生成侧)

`[已删] ass.rs:105-109`:

```rust
fn ass_color(rgb: i32) -> String {
    let v = rgb & 0xff_ffff;
    let (r, g, b) = ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
    format!("&H{b:02X}{g:02X}{r:02X}&")
}
```

测试钉死(`[已删] ass.rs:284-289`):

- 纯红 `0xFF0000` → `&H0000FF&`
- 纯蓝 `0x0000FF` → `&HFF0000&`

那条测试的注释说明了为什么必须有它:

> ASS 是 BGR 序。写反了整片弹幕红蓝互换,而且看起来「有颜色」所以很难发现。

#### ASS → RGB(解析侧)

`crates/core/src/danmaku/local.rs:270-278`,反向做同一件事,并处理 8 位带 alpha 的形式:

```rust
let bgr = &hex[hex.len() - 6..]; // 8 位形式是 AABBGGRR,丢掉 alpha
let n = |i: usize| i32::from_str_radix(&bgr[i..i + 2], 16).ok();
Some((n(4)? << 16) | (n(2)? << 8) | n(0)?)
```

取末 6 位丢掉 alpha 的做法有测试(`local.rs:472-485`,`{\c&H8000FF00&}` → `65280`)。
正则:`\\c&H([0-9A-Fa-f]{6,8})&`(`local.rs:221`)—— 6 到 8 位都收。

#### 不透明度 → alpha

`[已删] ass.rs:183`:

```rust
let alpha = 255 - (o.opacity.min(100) as u32 * 255 / 100);
```

对照表(测试 `[已删] ass.rs:325-332` 逐条钉死):

| opacity(0~100) | alpha 字节 | 写进 Style |
|---|---|---|
| 100(全不透明) | `00` | `&H00FFFFFF` |
| 80(默认) | `33` | `&H33FFFFFF` |
| 50 | `80` | `&H80FFFFFF` |
| 0(全透明) | `FF` | `&HFFFFFFFF` |

#### ⚠️ 一个必须理解的分工

每条 `Dialogue` 里的 `\c&HBBGGRR&` **只带 6 位,不带 alpha**(`[已删] ass.rs:155`、`ass.rs:171` 的模板都只插 `ass_color()` 的 6 位输出)。
所以:**颜色来自 `\c` 覆盖标签,透明度来自 Style 的 PrimaryColour 高位字节**。两者分居两处。
要做「每条弹幕独立透明度」得改用 `\1a&HAA&` 或 8 位 `\c`——本仓库没有这么做。

> 补充:当前的 Canvas 渲染器完全不碰 ASS alpha,不透明度是给整个 `<div>` 上 CSS
> `opacity`(`ui/desktop/App.tsx:1660`:`style={{ opacity: dmOpacity / 100, ... }}`)。

---

### 1.4 Dialogue 行

`Format:` 行原文(`[已删] ass.rs:198`):

```
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
```

10 个字段:

| # | 字段 | 我们填 | 含义 |
|---|---|---|---|
| 1 | `Layer` | `0` | 层号。数字大的画在上面;同层按出现顺序 |
| 2 | `Start` | `0:00:01.00` | 起始时刻,格式见下 |
| 3 | `End` | `0:00:09.00` | 结束时刻 |
| 4 | `Style` | `LP` | 引用 `[V4+ Styles]` 里的样式名 |
| 5 | `Name` | 空 | 说话人名,纯注释用途,不影响渲染 |
| 6 | `MarginL` | `0` | 覆盖 Style 的左边距;`0` = 用 Style 的 |
| 7 | `MarginR` | `0` | 同上 |
| 8 | `MarginV` | `0` | 同上 |
| 9 | `Effect` | 空 | 老式特效(`Banner` / `Scroll up` 等)。**我们不用**——滚动走 `\move` |
| 10 | `Text` | `{\an7\move(...)\c&H...&}文本` | 正文,前面挂覆盖标签块 |

#### 时间格式 `H:MM:SS.CC`

- 小时:**1 位,不补零**(`0:` 而不是 `00:`)
- 分/秒:2 位补零
- 小数:**恰好 2 位 = 百分秒(centisecond)**,不是毫秒

生成(`[已删] ass.rs:72-77`):

```rust
fn ts(secs: f64) -> String {
    let s = secs.max(0.0);
    let cs = (s * 100.0).round() as i64;
    let (h, m, sec, c) = (cs / 360_000, cs / 6_000 % 60, cs / 100 % 60, cs % 100);
    format!("{h}:{m:02}:{sec:02}.{c:02}")
}
```

测试(`[已删] ass.rs:354-359`):`0.0`→`0:00:00.00`;`1.234`→`0:00:01.23`(**截到百分秒**);`3661.5`→`1:01:01.50`;`-5.0`→`0:00:00.00`(负数夹到 0)。

解析侧有**两份独立实现**,行为不同,Go 侧要注意别合并错:

| | 位置 | 缺字段行为 | `.5` 的含义 | 畸形返回 |
|---|---|---|---|---|
| 弹幕文件导入 | `crates/core/src/danmaku/local.rs:230-246` | 无小数点也接受 | `0.5` 秒 = 500ms | `None`(整条跳过) |
| 字幕翻译 | `crates/core/src/translation.rs:336-348` | 段数 ≠ 3 返回 `0` | 同 | `0` |

`local.rs:229` 的注释点明了为什么必须返回 `None` 而不是 `0`:

> `H:MM:SS.cc` → 秒。畸形返回 None(不是 0 —— 那会把弹幕静默堆到片头)。

测试 `local.rs:492` 专门钉住 `.5` 的语义:`parse_ass_time("0:00:05.5") == Some(5.5)` —— 注释:「.5 是 500ms 不是 5ms」。

#### ⚠️ Text 里的逗号不能被切碎

`Dialogue:` 行的前 9 个字段按逗号切,**第 10 个字段(Text)整块留下**。台词/弹幕里天然带逗号,按逗号全切会把文本切碎。

两处实现,行为一致:

- `crates/core/src/danmaku/local.rs:254`:`body.trim_start().splitn(10, ',')`,注释说明这就是 `translation.rs::split_ass_fields` 的行为,「stdlib 够用,不抄那个私有函数」。
- `crates/core/src/translation.rs:296-314`:`split_ass_fields(input, expected)`,按 `Format:` 声明的字段数动态切。

测试钉住:`local.rs:436` 的夹具里放了一条 `{\move(...)}滚动弹幕,带逗号`,`local.rs:452` 断言解析出的 text 是 `滚动弹幕,带逗号` —— 注释:「特效标签剥掉,Text 里的逗号保住(splitn(10) 的功劳)」。

---

### 1.5 覆盖标签全表

覆盖标签(override tags)写在 `Text` 字段里,用 `{}` 包住,一个 `{}` 块里可以连写多个标签。
标签只对**它之后**的文本生效;`{}` 块可以出现在文本中间。

#### 1.5.1 本仓库**生成**过的标签(有出处)

| 标签 | 语法 | 我们怎么用 | 出处 |
|---|---|---|---|
| `\an` | `\an<1-9>` | `\an7`(滚动,左上锚)/ `\an8`(顶部弹幕,上居中)/ `\an2`(底部弹幕,下居中) | `[已删] ass.rs:149-153`、`ass.rs:171` |
| `\pos` | `\pos(x,y)` | 顶/底固定弹幕定位:`\pos(960, y)` | `[已删] ass.rs:155-159` |
| `\move` | `\move(x1,y1,x2,y2)` | 滚动弹幕:`\move(1920, y, -tw, y)` | `[已删] ass.rs:171-177` |
| `\c` | `\c&HBBGGRR&` | 每条弹幕的颜色 | `[已删] ass.rs:105-109`,插在 `ass.rs:155`/`ass.rs:171` |

##### `\an` 的九宫格

锚点编号照数字小键盘排列。这决定了 `\pos(x,y)` 里的 `(x,y)` 指的是文本框的**哪个角**:

```
7 上左    8 上中    9 上右
4 中左    5 正中    6 中右
1 下左    2 下中    3 下右
```

- 滚动用 `\an7`(上左):`\move` 的 x 就是文本**左边缘**,几何最好推 —— 从 `x=PlayResX` 出发时整条完全在屏外。
- 顶部弹幕用 `\an8`(上中):`\pos` 的 x 给 `PlayResX/2` 即水平居中,y 给轨道顶。
- 底部弹幕用 `\an2`(下中):同样水平居中,y 给轨道**底**。

老式写法 `\a<n>`(SSA v4)语义与 `\an` 不同,解析侧要认(`crates/core/src/danmaku/local.rs:262`:`\a6` / `\a7` 也判为顶部)。

##### `\move` —— 滚动弹幕的全部要点

```
\move(x1, y1, x2, y2)              # 在整个 Dialogue 时长内从 (x1,y1) 线性移到 (x2,y2)
\move(x1, y1, x2, y2, t1, t2)      # 只在 [t1,t2](毫秒,相对 Start)之间移动,前后静止
```

本仓库只用 4 参数形式(`[已删] ass.rs:171`)。

有一条测试专门为这件事存在(`[已删] ass.rs:243-266`),它的注释是整个设计的题眼:

> 滚动弹幕必须用 `\move` 而不是 `\pos` —— 这是「让 mpv 自己动」的全部要点。
> 一旦退回 \pos,弹幕就不动了,而且不报错。

该测试三条断言:①含 `\move(`;②起点 x 是 `1920`(画面右缘外);③终点 x **必须为负**(完全滚出左侧),注释:「否则末尾会卡在屏幕上」。

##### `\c` 与颜色族

ASS 有四个颜色槽,`\c` 是 `\1c` 的简写:

| 标签 | 作用 | 本仓库 |
|---|---|---|
| `\c` / `\1c` | 正文填充色(对应 `PrimaryColour`) | **生成时用**(`[已删] ass.rs:155`、`ass.rs:171`);解析时用正则抓(`local.rs:221`) |
| `\2c` | 卡拉OK 次色(`SecondaryColour`) | 未用 |
| `\3c` | 描边色(`OutlineColour`) | 未用 |
| `\4c` | 阴影色(`BackColour`) | 未用 |

#### 1.5.2 本仓库只**解析/剥离**、从不生成的标签

生成侧不写它们,但解析侧必须容忍——因为用户导入的第三方 ASS 弹幕文件里什么都有。
剥离方式是一刀切的正则 `\{[^}]*\}`,把整个 `{}` 块删掉:

- `crates/core/src/danmaku/local.rs:226`(弹幕导入)
- `crates/core/src/translation.rs:320`(字幕翻译)

测试夹具里出现过、被这条正则吃掉的标签(`crates/core/src/danmaku/local.rs:465`):

```
{\pos(1,2)\fad(200,200)\c&H00FF00&\fs30}干净文本{\r}
```

断言(`local.rs:467`):结果是 `干净文本`,颜色 `65280`。
即:`\pos` `\fad` `\fs` `\r` 全被剥掉,只有 `\c` 被单独抓出来用。

#### 1.5.3 ASS 规范里有、本仓库一次都没碰过的标签

> **无仓库出处**——以下来自 ASS/SSA 格式规范本身,列在这里是为了让 Go 侧重开 ASS 生成时有完整参考。
> 任务书点名问到的 `\fad` `\alpha` `\b` `\fs` `\bord` `\shad` 都在这一格。

| 标签 | 语法 | 作用 |
|---|---|---|
| `\fad` | `\fad(t_in, t_out)` | 淡入/淡出,毫秒。整条 Dialogue 头尾各淡一段 |
| `\fade` | `\fade(a1,a2,a3,t1,t2,t3,t4)` | 七参数完整淡变 |
| `\alpha` | `\alpha&HAA&` | 一次性设四个颜色槽的 alpha |
| `\1a` `\3a` `\4a` | `\1a&HAA&` | 单独设某个槽的 alpha(`\1a` = 正文,`\3a` = 描边) |
| `\b` | `\b1` / `\b0` / `\b700` | 粗体开关或字重。**注意与 Style 的 `Bold=-1` 口径不同** |
| `\i` `\u` `\s` | `\i1` | 斜体 / 下划线 / 删除线 |
| `\fs` | `\fs30` | 字号(PlayRes 单位) |
| `\fn` | `\fnArial` | 字体名 |
| `\bord` | `\bord2` | 描边粗细,覆盖 Style 的 `Outline` |
| `\shad` | `\shad0` | 阴影距离,覆盖 Style 的 `Shadow` |
| `\fsp` | `\fsp2` | 字间距 |
| `\frz` `\frx` `\fry` | `\frz30` | 绕 z/x/y 轴旋转 |
| `\fscx` `\fscy` | `\fscx120` | 横/纵拉伸百分比 |
| `\org` | `\org(x,y)` | 旋转原点 |
| `\clip` `\iclip` | `\clip(x1,y1,x2,y2)` | 矩形/矢量裁剪 |
| `\t` | `\t([t1,t2,][accel,]<标签>)` | 在时间区间内动画化其它标签 |
| `\q` | `\q2` | 覆盖 `WrapStyle` |
| `\r` | `\r` / `\rStyleName` | 重置为 Style 默认 / 切到另一个 Style |
| `\k` `\kf` `\ko` | `\k50` | 卡拉OK 计时 |
| `\p` | `\p1` … `\p0` | 进入/退出矢量绘图模式 |
| `\N` `\n` `\h` | — | 强制换行 / 软换行 / 不断行空格。**`\N` `\n` `\h` 不写在 `{}` 里,直接写在文本中** |

---

### 1.5.4 文本转义

**这一条不做就会被弹幕文本打穿整份文件。** 弹幕正文是用户输入,弹幕站不保证干净。

`[已删] ass.rs:88-102` 的注释和实现:

> ASS 事件文本里的元字符。`{}` 会被当成覆盖标签的括号,`\` 会起转义,换行会截断整条 Dialogue —— 不处理的话一条含 `{` 的弹幕能把后面整行吃掉。

```rust
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '{' => out.push('('),
            '}' => out.push(')'),
            '\\' => out.push('/'),
            '\r' | '\n' => out.push(' '),
            _ => out.push(c),
        }
    }
    out
}
```

**注意这是「替换」不是「转义」**:用户的 `{` 变成 `(`、`\` 变成 `/`,原字符拿不回来。这是有意的取舍——ASS 没有给 `{` `}` 定义转义序列,替换成形近字符是唯一不引入歧义的做法。

测试(`[已删] ass.rs:291-302`)注释:

> 一条带 `{` 或换行的弹幕不处理就能吃掉后面整行 —— 弹幕文本是**用户输入**,站点不保证干净。

三条断言:两条弹幕都在(没被吃掉);第一条的 `{` 计数恰好为 1(只剩我们自己那个覆盖标签块的开括号);换行被换成空格。

#### 反向:`\N` 的处理(解析侧)

`\N` 是 ASS 的强制换行。导入弹幕时把它压成空格(弹幕是单行的),翻译字幕时还原成真换行:

| 用途 | 处理 | 出处 |
|---|---|---|
| 弹幕导入 | `\N` → 空格 | `crates/core/src/danmaku/local.rs:281`,测试 `local.rs:455` 断言 `第一行\N第二行` → `第一行 第二行` |
| 字幕翻译 | `\N` → `\n`(真换行),**大小写不敏感**(`(?i)\\N`) | `crates/core/src/translation.rs:319`、`translation.rs:321` |

---

### 1.6 我们生成的一个真实样例

**这一节不是手推的。** 我把 `108965f6^` 里的 `ass.rs` 从 git 取出、剥掉 serde 依赖、单独 `rustc -O` 编译并执行,下面是它的**真实 stdout**。

输入(6 条弹幕,覆盖滚动/顶/底/转义/乱序四种情况),`AssOptions::default()`:

```rust
c(1.0, "前方高能",              1, 0xFFFFFF),
c(1.2, "这里是滚动弹幕",         1, 0xFF0000),   // 红
c(2.0, "顶部公告",              5, 0x00FF00),   // 绿,顶部
c(2.0, "底部吐槽",              4, 0x0000FF),   // 蓝,底部
c(3.5, r"带{大括号}和\反斜杠",   1, 0xFFFFFF),   // 元字符
c(9.0, "晚来的一条",            1, 0xFFFFFF),
```

输出:

```
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: LP,Microsoft YaHei,48,&H33FFFFFF,&H33FFFFFF,&H33000000,&H33000000,0,0,0,0,100,100,0,0,1,2.0,0,7,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:09.00,LP,,0,0,0,,{\an7\move(1920,0,-192,0)\c&HFFFFFF&}前方高能
Dialogue: 0,0:00:01.20,0:00:09.20,LP,,0,0,0,,{\an7\move(1920,67,-336,67)\c&H0000FF&}这里是滚动弹幕
Dialogue: 0,0:00:02.00,0:00:07.00,LP,,0,0,0,,{\an8\pos(960,0)\c&H00FF00&}顶部公告
Dialogue: 0,0:00:02.00,0:00:07.00,LP,,0,0,0,,{\an2\pos(960,1080)\c&HFF0000&}底部吐槽
Dialogue: 0,0:00:03.50,0:00:11.50,LP,,0,0,0,,{\an7\move(1920,0,-463,0)\c&HFFFFFF&}带(大括号)和/反斜杠
Dialogue: 0,0:00:09.00,0:00:17.00,LP,,0,0,0,,{\an7\move(1920,0,-240,0)\c&HFFFFFF&}晚来的一条
```

#### 这段输出里的每一个数字怎么来的

- **`-192`**:`est_width("前方高能", 48)` = 4 个全角 × 1.0 × 48 = 192,终点 x = `-tw`。
- **`-336`**:`"这里是滚动弹幕"` 7 个全角 × 48 = 336。
- **`-463`**:转义**之后**的 `带(大括号)和/反斜杠` = 8 全角 + 3 半角 = 8×1.0 + 3×0.55 = 9.65 → ×48 = 463.2 → `{:.0}` = 463。
  ⚠️ 注意:宽度是按**转义后**的文本算的(`[已删] ass.rs:133` 先 `escape` 再 `ass.rs:164` `est_width(&text, fs)`),这是对的——转义会改变字符数。
- **`0` / `67`**:轨道 y。`lane_h = 48 × 1.4 = 67.2`,轨 0 → 0,轨 1 → 67.2 → `{:.0}` = 67。
- **`0:00:09.00`**:起 1.0 + `scroll_secs` 8.0。
- **`0:00:07.00`**(顶/底):起 2.0 + `fixed_secs` 5.0。
- **`&H0000FF`**:输入 `0xFF0000`(红)BGR 翻转。
- **`&H33FFFFFF`**:opacity 80 → alpha `255 - 80×255/100 = 51 = 0x33`。
- **`\pos(960, 1080)`**:底部弹幕轨 0,`y = PlayResY - 0×lane_h = 1080`,配 `\an2`(下中)贴着画面下缘。
- **`带(大括号)和/反斜杠`**:`{`→`(`、`}`→`)`、`\`→`/`。

#### 两条从真实输出里读出来的行为

1. **顶部和底部各有独立轨道表**:t=2.0 的顶部和底部弹幕都拿到轨 0(`\pos(960,0)` 和 `\pos(960,1080)`)。因为 `[已删] ass.rs:121-123` 开了三个独立数组 `scroll_free` / `top_free` / `bottom_free`,注释:「滚动与顶/底各自一套(它们不互相挡)」。
2. **轨道会被回收**:t=3.5 和 t=9.0 都落在轨 0。因为 t=1.0 那条在 `1.0 + (192+48)/((1920+192)/8) = 1.909` 秒就把轨 0 让出来了。

---

## 2. 弹幕布局算法

同一套算法有**两份实现**,数学一致但数据结构不同。Go 侧移植以 ASS 版为准(纯函数、有单测),Canvas 版是当前线上跑的。

| | ASS 版(已删) | Canvas 版(线上) |
|---|---|---|
| 位置 | `[已删] ass.rs:112-220` | `ui/shared/Danmaku.tsx:110-137` |
| 坐标系 | PlayRes 1920×1080 固定 | canvas 位图像素(dpr 放大后) |
| 宽度来源 | **估算** `est_width` | `ctx.measureText(...).width` 真量 |
| 轨道表 | `Vec<f64>` 三份 | `laneFree: number[]`(滚动)+ 顶/底用 `Set` 扫在屏弹幕 |
| 时间推进 | libass 自己走 | rAF + 墙钟外推 |

### 2.1 轨道几何

```
lane_h   = font_size × 1.4                      # 行高 = 1.4 倍字号
usable_h = PlayResY × (area_percent / 100)      # 显示区域
lanes    = max(1, floor(usable_h / lane_h))     # 轨道条数
```

- ASS 版:`[已删] ass.rs:113-118`,`area_percent` 先 `clamp(10, 100)`。
- Canvas 版:`ui/shared/Danmaku.tsx:89-90`,`laneH = round(fs * 1.4)`、`numLanes = max(1, floor(canvas.height / laneH))`。

⚠️ **两版的「显示区域」实现方式不同**:
- ASS 版把 `area_percent` 算进 `lanes`(`[已删] ass.rs:115-117`),弹幕物理上不会画到区域外。有测试钉住(`[已删] ass.rs:304-322`,注释:「显示区域 = 只用画面上半部分时,轨道数要跟着减半,弹幕不能画到区域外」)。
- Canvas 版**组件内部完全不知道显示区域**,是外面套一层 CSS `clip-path` 裁的:`ui/desktop/App.tsx:1660` — `clipPath: inset(0 0 ${100 - DM_AREAS[dmArea]}% 0)`。档位表 `DM_AREAS = [25, 50, 75, 100]`(`App.tsx:127`)。
  → 后果:Canvas 版仍然按整屏高度分配轨道,只是下半部分被裁掉不显示。**弹幕会被"吃掉"而不是"挤到上半屏"**。这是两版的真实行为差异,Go 侧若照 ASS 版做会得到不同(更好)的观感。

### 2.2 文字宽度:估算 vs 真量

ASS 版必须估算,因为核心层没有字体度量。`[已删] ass.rs:19-23` 的取舍原文:

> ## 已知取舍
> 文字宽度是**估算**的(全角 1.0em / 半角 0.55em),因为核层拿不到字体度量。
> 估宽只影响轨道分配的松紧和滚出屏幕的余量,偏差几个像素不影响观感;想精确就得把字体加载进核层,不值。

实现(`[已删] ass.rs:80-86`):

```rust
fn est_width(text: &str, font_size: f64) -> f64 {
    let units: f64 = text.chars()
        .map(|c| if (c as u32) < 0x1100 { 0.55 } else { 1.0 })
        .sum();
    units * font_size
}
```

判据是 **码点 < 0x1100 算半角**。这是个粗判(0x1100 是韩文字母 Jamo 起点),把拉丁/希腊/西里尔/标点全算成 0.55 em。

Canvas 版不需要估:`ui/shared/Danmaku.tsx:114` 直接 `ctx.measureText(c.text).width`。

**Go 侧**:如果重开 ASS 生成,同样拿不到字体度量,照抄这个估算即可;它只影响轨道松紧,不影响正确性。

### 2.3 滚动弹幕的运动学

```
tw     = est_width(text, fs)          # 文本宽
dur    = max(scroll_secs, 0.5)        # 在屏时长,下限 0.5s
speed  = (PlayResX + tw) / dur        # px/s —— 总行程 ÷ 时长
起点 x = PlayResX                      # \an7 锚左上,故整条完全在右侧屏外
终点 x = -tw                           # 完全滚出左侧
```

出处:`[已删] ass.rs:164-178`。

推导:文本左缘从 `x=W` 走到 `x=-tw`,总行程 `W + tw`,耗时 `dur` → `speed = (W+tw)/dur`。这保证**不同长度的弹幕在屏时间相同**(都是 `dur`),而不是速度相同。这是弹幕的标准做法:同时出现的长短弹幕会同时消失,不会追尾。

Canvas 版一字不差:`ui/shared/Danmaku.tsx:116` — `const speed = (canvas.width + width) / duration;`,渲染时 `ui/shared/Danmaku.tsx:158` — `x = canvas.width - (t - a.born) * a.speed;`。

### 2.4 防重叠:轨道占用与释放

核心是一张 `free[lane]` 表,记每条轨的**下一次可用时刻**。

#### 滚动弹幕的释放时刻

```
busy_until = t + (tw + fs) / speed
```

`[已删] ass.rs:166-168`,注释:「入口空出时刻:这条的尾巴完全进屏之后,下一条才好接上。」

推导:这条弹幕的**右缘**从 `W+tw` 走到 `W`(即尾巴刚好完全进屏)需要走 `tw`,再留 `fs`(一个字宽)的间隙,合计 `(tw+fs)/speed` 秒。此后同轨放下一条就不会追尾。

⚠️ **这不是「弹幕消失的时刻」**,而是「入口腾出的时刻」——远早于 `t+dur`。这就是为什么同一条轨上可以同时跑好几条弹幕。

Canvas 版同式:`ui/shared/Danmaku.tsx:134` — `st.laneFree[lane] = t + (width + fs) / speed;`

#### 顶/底弹幕的释放时刻

`busy_until = t + fixed_secs`(`[已删] ass.rs:147`)。固定弹幕就是占满整个停留时长。

#### 选轨算法

`[已删] ass.rs:204-220`:

```rust
/// 选一条轨:优先已空出的最上面那条;都占着就选最早空出的(允许重叠,总比丢弹幕好)。
fn pick_lane(free: &mut [f64], now: f64, busy_until: f64) -> usize {
    let mut best = 0usize;
    let mut best_free = f64::INFINITY;
    for (i, f) in free.iter().enumerate() {
        if now >= *f { best = i; break; }        // ① 第一条空闲的,立刻用
        if *f < best_free { best_free = *f; best = i; }  // ② 记住最快空出的
    }
    free[best] = busy_until;
    best
}
```

两段式:**先到先得,满了就挤**。注释写明了取舍:「允许重叠,总比丢弹幕好」。

Canvas 版结构完全一样(`ui/shared/Danmaku.tsx:126-134`),但它带一条性能注释,记录了一次真实的掉帧修复:

> ★ 每条轨的「空出时刻」直接记在 laneFree 里 —— 原来是对**全量在屏弹幕**做 filter+slice(-1),外面还套着轨道数的循环,于是每生成一条弹幕就是 O(轨道数 × 在屏条数)。弹幕一密就是这里在掉帧。

**Go 侧要点**:轨道表必须是 `[]float64` 索引直取,不能每次去扫在屏列表。

#### ⚠️ 一个从代码里读出来的行为怪癖

`free[best] = busy_until` 是**无条件赋值**(`[已删] ass.rs:218`)。在「都占着,选最早空出的那条」这一分支里,新弹幕的 `busy_until` 可能**小于**该轨原有的 `free` 值,于是这次赋值把轨道的占用时间**往前调**了。

- 复现条件:所有轨都忙,且新弹幕短(`(tw+fs)/speed` 很小)而占着那条轨的老弹幕长。
- 后果:轨道比实际更早被判为空闲,叠字概率上升。
- 现状:**没有测试覆盖这一分支**(测试只有 `area_percent_limits_lane_count` 间接压到满轨,但不断言重叠程度)。
- Go 侧建议:`free[best] = max(free[best], busy_until)`。这是一行的事,且不改变「先到先得」那条主路径的行为。

### 2.5 顶/底弹幕的坐标

`[已删] ass.rs:141-160`:

| 模式 | mode | 锚点 | y 坐标 |
|---|---|---|---|
| 顶部 | `5` | `\an8`(上中) | `lane × lane_h` |
| 底部 | `4` | `\an2`(下中) | `PlayResY - lane × lane_h` |

x 恒为 `PlayResX / 2`(`[已删] ass.rs:158`)。

Canvas 版对应 `ui/shared/Danmaku.tsx:149-156`:

```js
if (a.mode === 4) { x = (canvas.width - a.width) / 2; y = canvas.height - (a.lane + 1) * laneH; }
else if (a.mode === 5) { x = (canvas.width - a.width) / 2; y = a.lane * laneH; }
```

⚠️ 底部 y 两版差一个 `laneH`:ASS 版是 `H - lane*lane_h`(配 `\an2` 下对齐),Canvas 版是 `H - (lane+1)*laneH`(配 `textBaseline="top"` 上对齐)。**两者渲染结果等价**,因为锚点不同。Go 侧照 ASS 版写就对了。

Canvas 版的顶/底选轨不用 `laneFree`,而是扫在屏同模式弹幕占用的轨(`ui/shared/Danmaku.tsx:118-120`):

```js
const used = new Set(st.active.filter((a) => a.mode === c.mode).map((a) => a.lane));
while (used.has(lane) && lane < numLanes - 1) lane++;
```

这里的 `lane < numLanes - 1` 是硬上限:轨满之后新弹幕全堆在最后一条轨上互相盖。相关历史:`e71090f5` 的标题是「置顶弹幕互相覆盖不顺延」。

### 2.6 事件必须按时间排序

`[已删] ass.rs:125-128` 生成前先按 `time` 排序:

```rust
let mut idx: Vec<usize> = (0..comments.len()).collect();
idx.sort_by(|&a, &b| comments[a].time.partial_cmp(&comments[b].time).unwrap_or(Ordering::Equal));
```

测试 `[已删] ass.rs:334-345` 的注释解释了为什么这不是「整洁强迫症」:

> 弹幕站返回的顺序不保证按时间。ASS 事件乱序时 libass 仍能放,但轨道分配会算错(后来的弹幕被判成「早就空出来了」),表现为大量重叠。

即:**排序是轨道分配算法的前置条件**,不是输出格式要求。`pick_lane` 用 `now >= free[i]` 判空闲,`now` 倒退就全乱。

解析侧也排:`crates/core/src/danmaku/local.rs:301`(ASS 导入后 `out.sort_by(time)`)。
Canvas 版依赖 `comments` 已有序(`ui/shared/Danmaku.tsx:111` 的 `while (comments[st.cursor].time <= t)` 是单向游标)。

### 2.7 空文本必须丢掉

`[已删] ass.rs:133-136`:`escape(c.text.trim())` 后为空则 `continue`。
测试 `[已删] ass.rs:347-351`:两条输入(一条全空白、一条有内容)只出 1 条事件。
Canvas 版:`ui/shared/Danmaku.tsx:113` — `if (!c.text) continue;`

理由:空的 `Dialogue` 行照样占一条轨、照样参与 `pick_lane`,等于凭空吃掉一条轨还什么都不显示。

---

## 3. 弹幕数据管线

### 3.0 全链路(当前线上,ASS 那条已死)

```
Emby 条目
   ↓  ui/desktop/App.tsx:506-533  /  ui/mobile/pages/PlayerPage.tsx:252-282
   ↓  构造 DanmakuMatchInput
   ↓
danmaku_auto_load(input, options, chConvert, anchorKey)      ← 核层命令
   ↓  ui/shared/api.ts:1745-1756
   ↓  返回 DanmakuComment[] | null(null = 没有够可信的匹配)
   ↓
setDmComments(...)  →  <DanmakuLayer comments={...} timeSync={...} />
   ↓  ui/shared/Danmaku.tsx
   ↓  rAF 循环 + Canvas 2D 绘制
画面
```

`DanmakuComment` 的线上形状(`ui/shared/api.ts:1773-1782`,与核层契约一一对应):

```ts
{ time: number; text: string; mode: number /* 1=滚动 4=底 5=顶 */;
  color: number; source: string; cid: string|null; user_id: string|null; count: number }
```

`ui/shared/Danmaku.tsx:3-6` 有一条历史教训:

> 弹幕类型只保留**一份**(核层契约那份)。这里原本另写了个四字段的窄版本,于是同名两个类型在 App.tsx 里对不上 —— 把同一份数据既喂给这个组件、又喂给 danmaku_attach 时会当场编译错。渲染只用到前四个字段,但类型别再分家。

### 3.1 数据结构(核层契约)

`crates/core/src/danmaku/mod.rs:41-56`:

```rust
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct DanmakuComment {
    pub time: f64,          // 秒
    pub text: String,
    pub mode: i32,          // 1=滚动 4=底 5=顶(mod.rs:45)
    pub color: i32,         // RGB int(mod.rs:46)
    pub source: String,     // 源的显示名
    pub cid: Option<String>,
    pub user_id: Option<String>,
    #[serde(default = "one")] // ★ 见下
    pub count: i32,         // 去重后同一弹幕出现的次数,未去重恒为 1
}
```

`#[serde(default = "one")]`(`mod.rs:51-56`)不是装饰:`Deserialize` 是给**磁盘缓存回读**用的(`mod.rs:40` 注释),老缓存文件里没有 `count` 字段,不给默认值会让整份缓存解析失败;默认成 `0` 又会让去重计数从 0 起跳。

其它公开结构(全部 `Serialize`,直接过 IPC):

| 结构 | 行号 | 用途 |
|---|---|---|
| `DanmakuAuthType` | `mod.rs:17-25` | `None`/`DandanplaySignature`/`PathToken`/`HeaderToken`/`QueryToken`,`camelCase` 上线 |
| `DanmakuSourceConfig` | `mod.rs:27-38` | 一个源的完整配置(含 `official` 标志和 `app_id`/`app_secret`) |
| `DanmakuEpisode` | `mod.rs:58-63` | `episode_id` / `episode_title` / `episode_number` |
| `DanmakuAnime` | `mod.rs:65-75` | 条目 + `episodes`(搜索时恒空) |
| `DanmakuMatchItem` | `mod.rs:78-89` | `/match` 的一条命中,带 `shift`(时间偏移) |
| `DanmakuMatchResult` | `mod.rs:92-96` | `is_matched` + `matches` |
| `DanmakuSourceGroup` | `mod.rs:525-533` | **一源一组**,单源失败只填 `error` 不拖累别人 |
| `DanmakuMatchCandidate` | `mod.rs:674-684` | 带 `score` 的候选 |
| `MatchInput` | `mod.rs:688-715` | 匹配输入,`#[serde(default)]` 在容器上 |
| `FilterOptions` | `mod.rs:1542-1553` | 过滤/去重参数 |
| `DanmakuFilter` | `mod.rs:1407-1411` | 屏蔽器(词 + 用户) |
| `DanmakuFilterImportResult` | `mod.rs:1479-1488` | XML 导入结果 |

`MatchInput` 为什么不认 `emby::Item`(`mod.rs:686-687`):

> core 不认 Emby Item(emby::Item 没有 path 字段,且网盘/聚合源没有 Emby 上下文),由宿主用 `resolve_title` / `resolve_file_name` 装好再传进来。

### 3.2 弹弹Play 协议

#### 签名

```
X-AppId:     {app_id}
X-Timestamp: {unix 秒}
X-Signature: Base64(SHA256(AppId + Timestamp + Path + AppSecret))
```

- 算法:`crates/core/src/danmaku/mod.rs:145-149`(客户端历史实现)与 `crates/danmaku-proxy/src/upstream.rs:17-21`(现在真正发出去的那份)**逐字节一致**,两份共用同一组测试向量(`mod.rs:1814` 与 `upstream.rs:166-173`)。
- 拼接**无分隔符**,直接四段字符串相连(`mod.rs:147`)。
- `Path` 是**不带 query 的** `/api/v2{endpoint}`(`mod.rs:198`)。代理侧 `crates/danmaku-proxy/src/main.rs:296-297` 特意注明:

  > ★ 签名的 path 用**不带 query 的** api_path —— 弹弹Play 的签名口径就是这样,把 query 拼进去会一律 403,而 403 长得跟「凭据无效」一模一样。

- 输出是 base64 的 32 字节 = **44 字符**(测试 `mod.rs:1814` 钉住长度)。

#### AppSecret 可能是多串换行分隔

两侧都做了同一件事:按 `\n` 切,取**首个非空**。

- 客户端:`crates/core/src/danmaku/mod.rs:209-218`,注释「多 secret 换行分隔;取首个非空(轮换是配额分摊,不影响正确性)」。
- 代理:`crates/danmaku-proxy/src/upstream.rs:137-141`,注释更狠:

  > ★ AppSecret 可能是**多串换行分隔**的(同一 AppId 配多个密钥做配额轮换)。整坨拿去 sha256 必然签错,而弹弹只回 403,看起来像「密钥无效」。客户端那边 2026-07-21 因为这个白查了一天,别在服务端重演。

测试 `crates/danmaku-proxy/src/upstream.rs:198-207` 钉住:`"  s1  \ns2\n"` → `"s1"`。

#### 端点表

| 端点 | 方法 | 参数 | 返回 | 出处 |
|---|---|---|---|---|
| `/search/anime` | GET | `keyword`、`v2=true` | 新引擎回 `bangumiList`,老引擎回 `animes`;**条目层不带 episodes** | `mod.rs:354-364` |
| `/bangumi/{animeId}` | GET | — | 集表在 **`bangumi.episodes`** 下面一层 | `mod.rs:378-392` |
| `/search/episodes` | GET | `anime`、`episode` | `animes[]`(**带** episodes) | `mod.rs:395-413` |
| `/comment/{episodeId}` | GET | `withRelated=true`、`chConvert`(非 0 才带) | `comments[]` | `mod.rs:417-431` |
| `/match` | POST | JSON:`fileName`/`fileHash`/`fileSize`/`videoDuration` | `isMatched` + `matches[]` | `mod.rs:434-465` |
| `/trending/...` | GET | — | 排行榜。**实测确认需要签名**(见 3.7) | `crates/danmaku-proxy/src/main.rs:182` 白名单 |

两段式搜索(`/search/anime` → `/bangumi/{id}`)的设计理由(`mod.rs:347-353`):

> 比 `/search/episodes` 快得多(后者要把每部番的整份集表也捞出来)……`v2=true` 是官方新搜索引擎(swagger v2 标注「使用新搜索引擎」);自建源不认这个参数会直接忽略,无害。

`/bangumi/{id}` 拿不到时的退路是**必需的**(`mod.rs:581-582`):

> 退路不是可选的:自建源(huangxd / misaka)不保证实现 `/bangumi/{id}`,没退路的话它们的条目点进去永远是空集表。

退路实现:`episodes_for_anime`(`mod.rs:583-604`)先试 `/bangumi/{id}`,空/失败则 `/search/episodes?anime={title}` 按标题捞,再挑同 `anime_id` 的那部(挑不到退第一部)。

#### `/match` 的 `fileHash` —— 这条路曾经从没通过一次

`crates/core/src/danmaku/mod.rs:467-480`(全仓库信息密度最高的一段注释之一):

> `/match` 的 `fileHash` **必须是形状合法的 32 位十六进制** —— 空串直接被判 `errorCode:2 一个或多个参数不符合规则`,整个响应作废。
>
> 2026-08-01 真接口 A/B 实测(同一文件名、同一签名):
>   `fileHash:""` → errorCode 2,matches 0 条
>   `fileHash:"000...0"`(32 位) → errorCode 0,**matches 25 条,第一条就是对的**
>   `matchMode` 给不给、给哪个值,结果**一模一样** —— 决定成败的只有 hash 的形状。
> 也就是说「①文件识别」这条路从接进来的那天起就没通过一次,而且失败得毫无声响(HTTP 200 + `matches:[]`,和「这个文件真的没匹配上」长得一样)。

解法(`mod.rs:481-489`):我们播的是服务器上的流,拿不到真 hash(dandanplay 的口径是**文件前 16MB 的 md5**,为它多拉 16MB 不值),所以给一个**由文件名派生的确定性占位 hash**:`md5(file_name)`。形状合法、跨会话稳定、撞上真视频 hash 的概率 2^-128 —— 服务端于是退化成按文件名匹配,那正是我们要的。调用方给了真 hash(32 位 hex)就原样透传(小写化),绝不覆盖。

#### UA

`crates/core/src/danmaku/mod.rs` 里的 `get_json` 用的是 `reqwest::Client` 传进来的那份(宿主构建),口径见项目记忆 `ua-policy-three-lanes`:Emby = `LinPlayer/版本`、预取 = `LinPlayerPreload/版本`、其它默认。
代理侧自带独立 UA:`LinPlayerDanmakuProxy/{version}`(`crates/danmaku-proxy/src/main.rs:91`)。

#### 自建源的鉴权:不让用户选,从链接推

`derive_auth`(`mod.rs:122-143`)。查证依据写在 `mod.rs:107-121`(**不是猜的**):

> - huangxd-/danmu_api: `http://host:9321/{TOKEN}/api/v2`(README 原文,默认 token 87654321)
> - l429609201/misaka_danmu_server: `prefix="/{token}/api/v2"`(src/api/dandan/__init__.py 路由定义)
>
> 两家都把 token 放在**路径**里 —— 也就是说它本来就在用户复制的那条链接内,我们原样用就行……(用户 2026-07-19:「用户也不知道啥是鉴权方式」。)

唯一要动手的是 query token(`mod.rs:117-119`):

> 那种 URL 不能原样拼接 —— `base_url()` 会在后面接 `/api/v2`,拼出 `...?token=x/api/v2` 这种废地址。

认三个 key:`token` / `api_key` / `apikey`(`mod.rs:132`),大小写不敏感,空值不算。

URL 归一化(`base_url`,`mod.rs:157-166`):去尾斜杠 → 已是 `/api/v2` 就用它 → 是 `/api/v1` 就换成 v2 → 否则追加 `/api/v2`。
`request_base_url`(`mod.rs:169-183`)只在 `PathToken` 时插 token,且**已含就不重复插**(`base.contains(&format!("/{t}/"))`)。

宿主侧还有一层兼容(`apps/desktop/src/lib.rs:3141-3161`):

> auth_type 为空 = 新源,走推导;非空 = 老源,尊重原值。
> ★ 不能只认空串:老 UI 新建源时写死的就是 `"none"`,全端存量源多半都是它。只认空串的话推导对绝大多数源永远不生效(而且不报错)。

### 3.3 errorCode:界面撒过的那句谎

`crates/core/src/danmaku/mod.rs:303-310`:

> 弹弹Play 系接口**从不用 HTTP 状态码报错** —— 一律 200 + body 里的 `errorCode`。不看这个字段,配额用尽/参数非法/鉴权失败全都长得跟「这个关键词没搜到」一模一样:`animes` 键不存在 → 解析出空表 → 界面说「未找到匹配的弹幕」。
>
> 2026-08-01 实测(官方 AppId,真签名):`/search/anime`、`/search/episodes` 全部回 `{"errorCode":429,"errorMessage":"已达到接口调用配额上限"}`,HTTP 200。
> 也就是说用户报的「弹弹play搜索不到弹幕」,界面上给的原因是**假的**。现在如实抛出去 —— 搜不到和搜不了是两件事,用户有权知道是哪件。

`check_api_error`(`mod.rs:311-323`)的判据:

| `errorCode` | 处理 |
|---|---|
| 字段不存在 | `Ok`(**自建源可能压根没这个字段**,测试 `mod.rs:2015` 钉住) |
| `0` | `Ok` |
| 其它 | `Err("{errorMessage}(错误码 {code})")`,`errorMessage` 空则 `"弹幕接口错误 {code}"` |

已知码:`429` = 配额上限、`2` = 参数不符合规则(`fileHash` 空时 `/match` 回的就是它)、`403` = 签名错/凭据无效(不在测试里,但 `main.rs:297` 和 `44edc610` 提交都实测到过)。

#### 半失败:429 + 空表被吞成「没搜到」

这是**同一句谎话的第二次复发**,修在 `match_one`(`mod.rs:872-878`):

> ★ 判据是「一条候选都没有 **且** 有一路是失败的」,不是「两路都失败」。
> 旧版写的是 `(Err, Err)` 才报错,于是最常见的那种半失败被整个吞掉:`/search/episodes` 回 429 配额用尽(Err),而 `/match` 正常返回空表(Ok)—— 两者配额是分开的,这是**实测的常态**不是理论情况(2026-08-02 真机抓到)。
> 结果 err=None、候选空,一路传到界面变成「未找到匹配的弹幕」。那正是 2026-08-01 那轮修复要杀掉的那句谎话,只是从另一条岔路又长回来了。
> 反过来,只要**有**候选就不该报错 —— 一路通就还有结果可用,那才是双路并跑的意义。

顶层同款判据(`match_all`,`mod.rs:835-840`):

```rust
if all.is_empty() && !errs.is_empty() {
    errs.dedup();
    return Err(errs.join(";"));
}
```

宿主层第三道(`apps/desktop/src/lib.rs:3419-3421`):

> 匹配**打不通**(配额用尽/源挂了)要如实往上抛。返回 None 的语义是「没有够格的匹配」,拿它去盖住「根本没搜成」,前端就会说「未找到匹配的弹幕」——那是句谎话。

**Go 侧要点**:`(空结果, nil)` 和 `(空结果, err)` 是**两个不同的答案**,不能合并。这是本仓库反复复发的一类 bug,复发点在三个不同的抽象层。

### 3.4 匹配算法

#### 双路并跑

`match_one`(`mod.rs:852-885`)用 `tokio::join!` 同时跑两路,合并后按 `{source_id}|{episode_id}` 去重、**保留高分**(`mod.rs:862-871`)。

理由(`mod.rs:846-851`):

> 弹弹Play 官方推荐两条路径都跑:①文件识别 /match ②名字搜索 /search/episodes。
> 返回 (候选, 错误):两路**都**失败才算这个源失败 —— 一路通就还有结果可用。2026-08-01 实测这不是理论情况:官方源 `/search/*` 回 429 配额用尽的同时,`/match` 照常工作(两者配额是分开的)。

#### ②名字搜索:四层召回,命中即停

`search_candidates`(`mod.rs:897-959`)。设计原则写在 `mod.rs:887-896`:

> 召回是分层的,前一层空了才走下一层 —— 因为**能匹配上的前提是先搜得到**(bangumi2anibt README:「accuracy is capped by recall」)。分数再准,候选表是空的也没用:
> ① 原标题 + 集号 —— 最窄,命中率也最高
> ② 原标题(去掉集号约束)—— 有的源不认 episode 参数
> ③ 主名(剥季号/副标题)—— 长标题会把全文检索呛住,只搜主名反而有
> ④ 其它写法(原名/文件名)—— 库里是中文名而弹弹Play 收的是日文名时的救命稻草
> 命中即停:前一层但凡回了东西就用它,后面的层根本不发请求。(官方源有调用配额 —— 2026-08-01 实测整天都在回 429,能少打一次是一次。)

两条过滤规则:候选写法 **< 3 字**不入队(`mod.rs:913-914`,「太短的写法(1~2 字)搜出来全是噪声,不值得多打一次接口」);已在队列里的(大小写不敏感)不重复入队。

#### 评分函数(全部加数)

| 项 | 值域 | 出处 |
|---|---|---|
| `title_score` | 0 ~ 1.0 | `mod.rs:1237-1243` |
| `season_term` | +0.15 / -0.35 / 0 | `mod.rs:1203-1213` |
| 集号命中(名字搜索路) | +0.3 | `mod.rs:955` |
| 文件识别路的固定加成 | +0.2 | `mod.rs:992` |
| 文件识别**唯一命中** | 固定 **1.6** | `mod.rs:989-990` |

`1.6` 这个数是算出来的,不是拍的(`mod.rs:987-988`):

> 文件识别唯一命中最可信:给到高于名字搜索满分(标题 1.0 + 集号 0.3 + 季号 0.15 = 1.45)的分,确保排最前。

**自动挂载门槛**:`MIN_AUTO_SCORE = 0.5`(`mod.rs:718`)。

#### 标题相似度:换掉了二元组 Jaccard

`mod.rs:1038-1056` 完整记录了换算法的三条理由:

> 口径换成 bangumi2anibt(matcher.c)那一套:**归一化折叠 + Levenshtein 比率 + 长度加权的包含下限**,一条代码路径吃所有语种,不写任何按语言分支的规则。
>
> 为什么换掉原来的「字符二元组 Jaccard ×0.6」:
> 1) 它给不出 0.6 以上的分。凡是没有完全相等、也没有包含关系的标题,上限就是 0.6,而 MIN_AUTO_SCORE 是 0.5 —— 差一个字的标题(「葬送的芙莉莲」vs「葬送之芙莉莲」)和毫不相干的标题挤在同一个窄区间里,阈值根本分不开。Levenshtein 比率给的是 **0.86 对 0.1**,这才叫可判。
> 2) 它不做任何字形折叠。全角(ＦＡＴＥ)、片假名/平假名(フリーレン vs ふりーれん)、大小写、标点差异,在二元组集合上全是「不同的字符」,直接把分打到 0。
> 3) 包含关系一律记 0.7,不看长度。于是「刀」落在「刀剑神域」里 = 0.7,「赛马娘」落在「赛马娘 Pretty Derby」里也 = 0.7 —— 后者显然更该信。改成 **0.6 + 0.4×(短/长)**,长度占比自己说话。

##### 归一化折叠 `fold`(`mod.rs:1063-1083`)

做的是「NFKC + casefold 里对标题真正有用的那个子集」:

| 码点范围 | 处理 |
|---|---|
| `0x20 0x09 0x0A 0x0D 0x3000` | 丢弃(各种空白 + 表意空格) |
| `0x21..=0x2F` `0x3A..=0x40` `0x5B..=0x60` `0x7B..=0x7E` | 丢弃(ASCII 标点) |
| `0x3001..=0x303F` | 丢弃(CJK 标点 、。〈〉「」【】〜…) |
| `0x30FB` | 丢弃(片假名中点「・」,**不在片假名区间里,得单独丢**) |
| `0xFF01..=0xFF5E` | 减 `0xFEE0` 变半角,**再递归走一遍**(大写还要转小写、标点还要丢) |
| `0x30A1..=0x30F6` | 减 `0x60`,片假名 → 平假名 |
| 其它 | `to_lowercase()` 取首字符 |

明确**不做**的(`mod.rs:1061-1062`):完整 NFKC、繁→简。理由:「要拖进大张 Unicode 表,不做 —— 下面的 Levenshtein 比率吃得下繁体带来的那几个字的漂移」。

`norm_chars`(`mod.rs:1089-1096`)在折叠前先 `season_re().replace_all(s, "")` 剥季号,并 `.take(MAX_TITLE_CHARS)` 截到 **128 字**(`mod.rs:1085-1086`:「超长标题的尾巴对匹配没有贡献,却让 Levenshtein 变成 O(n²) 的负担」)。

##### `similarity`(`mod.rs:1128-1147`)

```
q, t = norm_chars(query), norm_chars(title)
任一为空          → 0.0
q == t            → 1.0
ratio = 1 - levenshtein(q,t) / max(len(q), len(t))
若短串连续出现在长串里:
    floor = 0.6 + 0.4 × (len(short) / len(long))
    ratio = max(ratio, floor)
clamp(0, 1)
```

Levenshtein 是两行 DP(`mod.rs:1105-1120`),`contains_seq` 用 `windows()` 扫连续子序列(`mod.rs:1123-1125`)。

##### `title_score`(`mod.rs:1237-1243`)

拿 **主标题 + 所有 `alt_titles`** 逐个和候选比,取 `max`。理由(`mod.rs:1231-1236`):

> 这是 bangumi2anibt README 里那句「数据库本身就是平行语料」的镜像 —— 弹弹Play 的条目只有一个标题(没有别名表),平行语料在**我们这边**:媒体库同时握着中文名、原名和发布文件名。谁都可能是能对上的那一个,所以全试。

#### 季号:一路独立的硬信号

`mod.rs:1159-1164`:

> 这是**独立于标题相似度**的一路信号,而且比相似度硬:「孤独摇滚」和「孤独摇滚 第二季」在剥掉季号后是同一个串,相似度分不开;但季号一对,谁是谁立刻清楚。以前没有这一路 —— 第二季的片配上第一季的弹幕,从头到尾对不上,而且**不报错**,看起来就像「弹幕匹配得不准」。

正则(`mod.rs:1149-1157`),三种写法:

```
(?i)第\s*[一二三四五六七八九十两0-9]+\s*[季期部]
  | \bseason\s*[0-9]+\b
  | \b[0-9]+(?:st|nd|rd|th)\s+season\b
```

中文数字解析 `cjk_number`(`mod.rs:1175-1195`)支持「十」「十N」「N十」「N十M」四种写法,注释明说「别的(百/千)动漫季号里不存在」。

`season_term`(`mod.rs:1203-1213`)的**取值优先级**是这条逻辑里最容易写错的地方(`mod.rs:1197-1202`):

> 想要的季号优先取**标题自己带的**:媒体库有两种摆法 ——
> A. 一部剧一个条目、季在里面 → series_name="孤独摇滚",season_no=2
> B. 每季各一个条目 → series_name="孤独摇滚 第二季",season_no=1
> 只认 season_no 的话,B 这种摆法会把正确的「第二季」候选判成错季直接压死。

即 `season_of(input.title).or(input.season_no)`;候选侧读不出季号时按 **1** 处理(`mod.rs:1207`);想要的季号完全不知道 → 返回 `0.0` **不表态**(`mod.rs:1204-1206`)。

#### `core_name`:只扩召回,不参与算分

`mod.rs:1215-1229`。剥季号 + 剥副标题,支持 `-副标题-` / `～副标题～` / `(副标题)` / `(副标题)` / `[副标题]` / `:副标题` / `:副标题`。

> **只用于扩大召回**,不参与算分 —— 所以它宽一点也不会造成错配,最多是多捞几个候选回来让评分去筛。

#### 集号匹配

`episode_matches`(`mod.rs:1017-1031`):先整串 `parse::<i64>`,失败则用 `\d+` 抽首个数字串比对(认「第3话」「03」「 3 」)。`episode_number` 为空/无数字/`ep_num` 为 `None` → 一律 `false`。

`pick_episode`(`mod.rs:1001-1015`)三段回退:
1. 按 `episodeNumber` 命中;
2. 集号在 `1..=len` 范围内 → **按位置取**(`mod.rs:1009`:「部分源 episodeNumber 不规整」);
3. 都不行 → 首集。

#### `is_anime` 与 `allow_official_for`

`is_anime`(`mod.rs:749-758`)是 11 个关键词的**小写子串**匹配:
`动画 动漫 動畫 動漫 番剧 番劇 二次元 卡通 anime アニメ animation`。

`allow_official_for`(`mod.rs:775-777`)= `genres.is_empty() || is_anime(genres)`。它上面那段注释(`mod.rs:760-774`)记录了「配额老被刷完」的第一个真因:

> ★ 背景(2026-08-02,用户报「配额老是被刷完」):`is_anime` 从落地起就**没有任何宿主调用过** —— `danmaku_sources(state, allow_official)` 三处调用点全是写死的 `true`。后果是播好莱坞电影、国产剧、综艺、纪录片……一样往官方接口打一整轮(`/match` + 最多 4 次 `/search/episodes`),而这些内容弹弹Play 根本不收录,一条候选都不可能有。**纯烧配额,零收益**,而且是每次起播都烧。
>
> ★ 判据是「确信不是番」才排除,不是「确信是番」才放行:`genres` 为空 = 元数据没刮到 / 网盘源没有分类信息 = **不知道** → 照常允许。反过来写(空表就排除)会让所有没刮削的库弹幕直接死掉,而且是静默的 —— 用户只会看见「弹幕突然不出来了」,查都没处查。
>
> 手动搜索(`/search/anime`)和手动挑源**不**过这一关:那是用户明确要求的,他说这是番就是番,轮不到我们替他判。

这正是项目记忆 `stale-waijie-lies` 的镜像:核层写完了、注释也写了,**就是没人调**。

### 3.5 多源并行

`parallel_by_source`(`mod.rs:646-669`):

```rust
let mut set = tokio::task::JoinSet::new();
for (i, cfg) in cfgs.iter().enumerate() {
    let fut = f(http.clone(), cfg.clone());
    set.spawn(async move { (i, fut.await) });
}
let mut slots: Vec<Option<T>> = ...;
while let Some(Ok((i, v))) = set.join_next().await { slots[i] = Some(v); }
```

三个要点:
- **结果按 `cfgs` 原顺序归位**(`mod.rs:644`:「JoinSet 完成顺序是乱的」),否则 UI 列表每次刷新都换位置。
- `reqwest::Client` clone 极廉价且**共享同一连接池**(`mod.rs:658`)。
- **没有并发上限**——与项目记忆 `cross-server-request-lifecycle` 一致(元数据请求本轻)。
- **没有独立超时**:超时靠传进来的 `reqwest::Client`。

三个调用者:`search_all_grouped`(`mod.rs:548-576`)、`match_all_grouped`(`mod.rs:607-642`)、`match_all`(`mod.rs:815-844`)。前两个失败降级成 `DanmakuSourceGroup { error: Some(e), .. }`,**单源失败不拖累别人**。

取弹幕正文时**不并行**(`get_comments_from_all`,`mod.rs:1382-1402`):

> 顺序(非并行)——对齐 Dart:命中即停,不给后面的源白发请求。

`preferred` 源排在最前(`mod.rs:1390-1393`),首个非空即返回。

### 3.6 过滤、去重与缓存

#### `apply_filter_and_dedup`(`mod.rs:1569-1587`)

四步,顺序固定:
1. `blockwords` 或 `user_blocklist` 非空 → 装 `DanmakuFilter`,`retain` 掉命中的;
2. `blocked_modes` 非空 → `retain` 掉 `mode` 在表里的;
3. `dedup` 为真 → 走 `dedup(items, dedup_window)`;
4. 返回。

`should_filter`(`mod.rs:1468-1475`):用户 id 在黑名单 → 过滤;或文本 `contains` 任一屏蔽词(**子串匹配,不是全词**)。

`FilterOptions::default()`(`mod.rs:1555-1565`):三个数组空、`dedup: false`、`dedup_window: 10.0`。
⚠️ 注意核层默认 `dedup: false`,而前端的 `defaultDanmakuFilter()`(`ui/shared/api.ts:1769`)传的是 `dedup: true`。**两份默认值不一致**,靠前端每次显式传值兜住。

#### 去重算法(`mod.rs:1590-1614`)

```
按 time 升序排
for i in 0..n:
    if used[i]: continue
    count = 1
    for j in i+1..n:
        if used[j]: continue
        if items[j].time - items[i].time > window: break     // ← 已排序,可以 break
        if 文本相同 且 mode 相同: count += 1; used[j] = true
    result.push(items[i] with count)
```

判据是 **(文本, mode) 相同 且 时间差 ≤ window**。类型不同不合并(测试 `mod.rs:2147-2148` 钉住)。
复杂度 O(n × 窗口内条数),不是 O(n²) —— 因为排序后可以 `break`。

#### 弹弹Play 屏蔽列表 XML 导入(`mod.rs:1500-1530`)

格式:`<item enabled="true">t=词</item>` / `<item enabled="true">x=uid=[平台]用户ID</item>`。
用正则 `(?s)<item([^>]*)>(.*?)</item>` 抽,不上 XML crate(`mod.rs:1498-1499` 的 `ponytail:` 注释:「这文件就这一种扁平结构,为它加个 quick-xml 依赖不值」)。
`enabled="false"` 和空内容都计入 `skipped_count`。

`unescape_xml`(`mod.rs:1532-1538`)—— 五件套,**`&amp;` 必须最后**:

```rust
s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"")
 .replace("&apos;", "'")
 .replace("&amp;", "&") // 必须最后,否则 &amp;lt; 会被二次解码
```

`local.rs:81-83` 复用它,并在前面多加一步 `&#39;` → `'`,注释说明了顺序安全性:「`&amp;#39;` 里不含子串 `&#39;`,不会被这一步误伤」。

#### 缓存:内存 LRU + 磁盘 JSON

`mod.rs:1245-1250`:key = `{sourceId}:{episodeId}`,内存 **40 条**,磁盘 TTL **7 天**,目录 `crate::paths::cache_dir("danmaku")`。

- 内存层是 `Mutex<Vec<(String, Vec<DanmakuComment>)>>`(`mod.rs:1254`),尾部最新。`ponytail:` 注释:「Vec 线性扫,40 条上限下 O(n) 无所谓」。
- 磁盘文件名 = `md5(key).json`(`mod.rs:1272-1276`)—— 因为 `episodeId` 来自网络,不能直接当文件名。
- `cache_get`(`mod.rs:1298-1317`):内存命中直接返回;磁盘命中先判 TTL,**过期就删文件**;空列表当未命中。
- `cache_put`(`mod.rs:1320-1335`):**空列表不写**;磁盘写失败不影响内存缓存与本次播放。
- 同步 `std::fs`(`mod.rs:1297` 的 `ponytail:` 注释:「单集弹幕 JSON 几百 KB,阻塞可忽略」)。

### 3.7 服务端弹幕代理(`crates/danmaku-proxy`,1807 行)

独立部署件,跑在用户自己的服务器上,**和三端客户端没有任何代码依赖**(`crates/danmaku-proxy/Cargo.toml:6-9`)。

#### 它为什么存在

`crates/danmaku-proxy/src/main.rs:3-10`:

> 客户端里的 AppSecret 无论怎么加密都是**可提取**的(解密口令必须和密文一起发出去)。谁拿到安装包都能用我们的配额。挪到服务端之后:
> * 密钥只在这台机器的环境变量里,客户端一个字节都拿不到;
> * **出站闸门**把「收到多少」和「转发多少」解耦 —— 被刷爆的后果退化成「这段时间弹幕慢」,而配额一个不掉;
> * **自托管弹幕库**按 cid 求并集长期留着,过期只是「去看看有没有新的」。

`7a83ae32` 提交把闸门的价值说得最清楚:

> 代理的价值不是抗打,是把「收到多少」和「转发多少」解耦……没有这道闸,代理只是把攻击原样中继过去,换个地方挨打。

`44edc610` 记了一条**和用户判断相反的实测**:

> 用户说排行榜没有配额限制 —— 但那不是重点。**它是那把钥匙唯一还留在客户端的理由**,留着它就等于把 secret 继续留在二进制里,而同一把钥匙照样开 /search 和 /comment。顺带实测确认了排行榜**确实需要签名**:同一台机器同一条路径,裸调 `/api/v2/trending/all/hot/week` → HTTP 403,带签名的真客户端 → 200 / 50 条。

#### 不做鉴权(2026-08-02 的方向调整)

`crates/danmaku-proxy/src/main.rs:12-15`:

> 没有客户端令牌、没有注册流程 —— 用户 2026-08-02 定的。理由成立:真正保住配额的是出站闸门,它对谁来的都一样管用;拦人是 Cloudflare 的活,在这儿再写一套只会更差。令牌唯一独有的能力是归因,由 `sources` 按来源 IP 统计补回来。

#### 路由表

| 路由 | 方法 | 鉴权 | 说明 | 出处 |
|---|---|---|---|---|
| `/healthz` | GET | 无 | 返回 `"ok"` | `main.rs:113` |
| `/api/v2/{*rest}` | any | 无 | 转发主路径 | `main.rs:114` |
| `/admin` | GET | 无(页面本身) | 内嵌单页 HTML | `admin.rs:26` |
| `/admin/api/login` | POST | 密码 | `{password}` → 下发 session cookie | `admin.rs:27,70-87` |
| `/admin/api/state` | GET | cookie | config/governor/cache/store/sources/summary | `admin.rs:28,89-109` |
| `/admin/api/config` | POST | cookie | 保存配置,即时生效 | `admin.rs:29,121-141` |
| `/admin/api/cache/clear` | POST | cookie | 清短期缓存 | `admin.rs:30,143` |
| `/admin/api/store/clear` | POST | cookie | 清弹幕库 | `admin.rs:31,153` |
| `/admin/api/sources/reset` | POST | cookie | 清来源统计 | `admin.rs:32,161` |

#### 转发白名单

`allowed()`(`main.rs:180-184`),六条前缀:`search/anime`、`search/episodes`、`bangumi/`、`comment/`、`match`、`trending/`。
理由(`main.rs:178-179`):

> 不做通配转发 —— 那等于给全世界开了一个带我们签名的弹弹Play 免费代理,配额照样是我们的。

#### 转发流程(`forward`,`main.rs:200-268`)

```
enabled? → 白名单? → 取 client IP → query 用 BTreeMap 已排序
├─ path 以 comment/ 开头(episode_of)
│    store.take(ep) → Fresh 直接返回 (X-LP-Cache: FRESH)
│                   → Stale/Missing:sources.hit(needs_upstream=true)
│                        fetch_upstream 成功 → store.merge → UPDATED / NOCHANGE
│                        失败 → 有存量回 STALE,无存量回错误
└─ 其余
     cache.get(key) 命中 → HIT
     未命中 → fetch_upstream → cache.put → MISS
```

`X-LP-Cache` 六个值的含义写在 `main.rs:321-323`:`FRESH` / `UPDATED` / `NOCHANGE` / `STALE` / `HIT` / `MISS`(另有 `UPSTREAM-ERR`)。注释明说「只为线上自查存在(客户端不看它)」。

#### 业务错误照弹弹Play 的口径回

`biz_err`(`main.rs:159-168`)—— **HTTP 200 + body 里的 errorCode**:

> 不是偷懒 —— 客户端已经有一套 `check_api_error` 在解这个结构,并且会把 errorMessage 原样显示给用户。走同一条路,限流原因("今日配额已用完")就能一字不差地出现在播放器上,不用在三端各写一遍解析。自定义码用 1001+,和弹弹自己的码(429/500…)不撞。

| 码 | 常量 | 含义 |
|---|---|---|
| 1001 | `E_DISABLED` | 总开关关了 |
| 1002 | `E_RATE` | 单 IP 每分钟超限 |
| 1003 | `E_QUOTA` | 出站闸门拦下 |
| 1004 | `E_UPSTREAM` | 上游请求失败 |
| 1005 | `E_PATH` | 不在白名单 |

#### 出站闸门(`upstream.rs:31-113`)

分钟桶 + 天桶,两个都过才放行。天界按 **UTC** 切(`now/86400`),理由(`upstream.rs:29-30`):

> 不按本地时区是因为容器里的时区经常是 UTC 而管理员以为是本地,「配额几点重置」对不上会让人以为闸门坏了。

最关键的一条设计(`upstream.rs:72-74`):

> ★ 名额是**取了就算用掉**,即使上游随后失败。看着亏,但反过来更糟:上游正在 5xx 或超时的时候,「失败不计数」会让我们对着一个坏掉的上游全速重试,把当天配额在几分钟内烧光 —— 那正是要防的场景。

#### 短期缓存(`cache.rs`)

- **落磁盘不落内存**(`cache.rs:6`):「单集弹幕几 MB 很常见,几百集就把内存吃穿了。索引在内存、正文在盘上」。
- 缓存键 = `sha256(method \0 path \0 canonical_query \0 body)`(`cache.rs:38-48`)。`canonical_query` 把参数排序(`cache.rs:52-56`),`?a=1&b=2` 和 `?b=2&a=1` 是同一个 key。
- **键必须排除一切鉴权信息**(`cache.rs:36-37`):

  > 带上它们就等于每个客户端各存一份,缓存命中率归零,而症状只是「配额还是在掉」。

- 文件格式:第一行是过期时刻,`\n` 之后是正文(`cache.rs:125-128`、`strip_header` `cache.rs:181-184`)。重启时扫目录重建索引(`cache.rs:63-75`:「不扫的话重启后容量统计归零,盘会一直涨到写满」)。
- 淘汰(`evict_locked`,`cache.rs:148-164`):已过期的排最前(排序键 `i64::MIN`),其余按上次命中时刻升序。

  **这里藏着一个真 bug 的修复记录**(`cache.rs:143-147`):

  > ★ `now` 必须由调用方传进来,**不能在这里自己读系统时钟**:get/put 收的是参数里的 now,这里再读一次就是两个时钟源。两者一旦不同步(测试注入时间、或跨了闰秒/改过系统时间),全部条目会被判成"已过期"→ 排序键全相等 → 退化成按哈希表顺序乱删,刚写进去的热数据当场被淘汰。这条是本地测试真抓出来的,不是假想。

- 上游错误**绝不入缓存**(`main.rs:272-273`、`looks_like_error` `main.rs:314-319`):

  > 存下来等于在 TTL 内把这个错误钉死,配额恢复了客户端还在看旧错。

  判据是 `errorCode != 0`;**解不出 JSON 不算错误**(`main.rs:384` 的断言注释:「那会让缓存永远不生效」)。

#### 自托管弹幕库(`store.rs`)

与缓存的区别是**语义**(`store.rs:3-8`):

> 缓存过期就丢,弹幕库过期只是「该去看看有没有新的」,本体一直留着。由此换来两件缓存做不到的事:
> * **弹幕只增不减**:每次拉回来按 cid 求并集,上游哪天返回残缺数据也毁不掉历史;
> * **配额烧光了照样有弹幕**:出站闸门关着的时候回存量,而不是回一个错误。

`Entry`(`store.rs:30-42`):`count` / `bytes` / `fetched` / `interval` / `used`。索引 `index.json` 全量落盘。

**合并只增不减**(`merge_comments`,`store.rs:212-236`):按 `cid` 求并集;`cid` 为 `null` 时拿整条内容当身份(`cid_of`,`store.rs:240-245`:「总比全部判成同一条(只留一条)强」)。
两道保命闸:上游解不出内容且我们有存量 → **原样保住存量**(`store.rs:220-223`);上游回空列表同理。

**自适应刷新间隔**(`store.rs:10-22`)—— 用户要的是「当季新番 6 小时、其余 7 天」,实现却**不查任何元数据**:

> 换一个等价但不需要任何元数据的信号:**这一集还在不在长弹幕**。
> * 一次刷新拿回了新弹幕 → 说明还在播/还在被看 → 间隔压回下限(6 小时);
> * 一次刷新一条新的都没有 → 间隔翻倍,直到上限(7 天)。
> 在播的番自然停在 6 小时,老番自然滑到 7 天 —— 而且它还能处理「老番突然翻红」这种按季度判断永远判不出来的情况。
>
> 起始值取**下限**而不是上限:拉取是**惰性**的……反过来从 7 天起步,新番第二天的观众就只能看到首日的弹幕 —— 那是看得见的坏。

实现 `store.rs:136-142`。⚠️ 只在**确实发生了一次上游拉取**时调整(`store.rs:133-135`:「拿缓存命中去调,间隔会在没有任何新信息的情况下乱走」)。

**端到端自检抓到的真 bug**(`store.rs:101-104`):

> ★ `min_i`/`max_i` 是**当前配置**的区间,存量条目的 interval 要按它夹一次再判。不夹的话:条目的 interval 是写入那一刻定死的,管理员把上限从 7 天调到 1 天,已经在库里的条目**要等满 7 天才会按新设置刷新** —— 改了设置看着没反应,而且没有任何地方能看出为什么。

`take` 和 `stats` **必须用同一套判据**(`store.rs:156-157`),否则界面上的「还新鲜 N 集」和实际会不会去上游对不上。

**路径净化**(`store.rs:89-97`):`episodeId` 直接来自 URL,只保留 `[A-Za-z0-9_-]` 并截 64 字符。
**索引有、盘上没了** → 清索引当没存过(`store.rs:117-121`:「否则永远报"有"但读不出来」)。

**容量淘汰**(`evict`,`store.rs:173-196`):按 `used` 升序,最久没人看的先出局。放后台 5 分钟定时跑(`main.rs:99-110`:「淘汰要遍历全表,不该挂在热路上」)。

#### 来源统计(`sources.rs`)

- 记 `requests`(含库命中)和 **`upstream`(真正穿透到上游的次数)**。
- **排序按 `upstream` 不按 `requests`**(`sources.rs:90-91`):

  > 按请求数排会把「一直命中缓存」的重度用户排在前面,那不是要抓的人。

- 表封顶 **5000** 条(`sources.rs:40-42`),满了先丢 `last_seen` 最旧的。
- 明确声明**不作鉴权**(`sources.rs:13-14`):「头是可伪造的,伪造者也就骗过一个本来就不拦人的统计表。真正的硬约束在出站闸门那边,那个伪造不了」。
- `needs_upstream` 由调用方在库里没有可用数据时置 true(`sources.rs:51-52`:「命中不花配额,拿它计数会把正常追番的人误伤成滥用者」)。

#### 客户端 IP(`main.rs:132-155`)

顺序:`CF-Connecting-IP` → `X-Real-IP` → `X-Forwarded-For` 首段 → socket。
注释(`main.rs:134-137`)明说这些头任何人都能伪造,只在「本服务不直接暴露、前面一定有反代」的前提下才有意义,而且**不用于鉴权**。

#### 配置(`config.rs`)

**所有凭据走环境变量,不落配置文件**(`config.rs:1-2`):

> AppId/AppSecret/管理密码一律走环境变量,免得管理界面存盘时把密钥写进一个随手会被 tar 走的 JSON。

| 环境变量 | 用途 | 缺失后果 |
|---|---|---|
| `DANDANPLAY_APP_ID` | 弹弹Play AppId | 启动失败 `exit(2)`(`main.rs:64-71`) |
| `DANDANPLAY_APP_SECRET` | AppSecret(可多串换行) | 同上 |
| `ADMIN_PASSWORD` | 管理界面密码,**至少 8 位** | 启动失败 `exit(2)`(`main.rs:72-77`) |
| `DATA_DIR` | 数据目录,默认 `./data` | — |
| `PORT` | 默认 `8787` | — |
| `BIND` | 默认 `127.0.0.1` | — |
| `UPSTREAM_BASE` | 上游地址覆盖,给端到端测试用假上游(`upstream.rs:117-118`) | 用官方地址 |

`BIND` 默认只绑回环的理由(`main.rs:59-61`):

> 忘了配反代的后果应该是「外面连不上」,而不是「一个没有 TLS、没有防护的服务直接裸奔在公网上」。

配置项(`config.rs:13-45`)与默认值(`config.rs:47-64`):

| 项 | 默认 | 说明 |
|---|---|---|
| `upstream_per_minute` | 30 | 出站闸门,**最重要的一组数** |
| `upstream_per_day` | 3000 | 按官方配额留 20% 余量填 |
| `client_per_minute` | 30 | 单 IP,含库命中 |
| `refresh_min_secs` | 21600(6h) | 弹幕刷新下限 |
| `refresh_max_secs` | 604800(7d) | 弹幕刷新上限 |
| `store_max_mb` | 20480 | 弹幕库磁盘上限 |
| `ttl_search_secs` | 86400 | 搜索/集表缓存 TTL |
| `ttl_trending_secs` | 3600 | 排行榜缓存 TTL |
| `cache_max_mb` | 512 | 短期缓存磁盘上限 |
| `enabled` | true | 总开关 |

`config.rs:4-5` 定了一条硬约束:

> 这份配置管理界面可以改、改完立刻生效并落盘,所以每一项都要能热更新:**别把任何一项在启动时读进局部变量。**

`save_config`(`admin.rs:129-130`)把 `upstream_per_minute` 钉了下限 1:「0 会把闸门变成「全拒」,看起来像服务坏了」。

#### 管理界面鉴权(`admin.rs`)

- 会话 cookie 而非 Basic(`admin.rs:3-4`):「Basic 会让浏览器把密码缓存到关窗为止,而这个界面能改出站闸门、清空整个弹幕库」。
- 会话放模块静态,**重启即清空**(`admin.rs:17-18`:「没有'永久登录'」)。
- 密码**定长比较** `eq_ct`(`admin.rs:36-41`):「密码比较的用时差理论上可被测出来。代价是 5 行」。
- Cookie:`HttpOnly; SameSite=Strict; Max-Age=43200`,**不设 Secure**(`admin.rs:76-78`:「TLS 在反代那一层终结,本进程看到的是明文 HTTP,设了反而会让 cookie 在反代到本进程这一跳被丢掉」)。
- AppId **只露尾巴**(`tail`,`admin.rs:111-118`):`****{末4位}`。

#### 故意不做的(`main.rs:17-19`)

> 只监听回环地址,前面挂用户自己的反代(OpenResty/nginx)+ Cloudflare 橙云。本进程**不做** TLS、不做 IP 封禁、不做 DDoS 防护。

`7a83ae32` 的理由:「反代和 CF 做得比我好,在这里再写一遍只会写出更差的版本」。

### 3.8 `danmaku_auto_load` 的完整流程

`apps/desktop/src/lib.rs:3366-3447`(手机端 `apps/android/src/lib.rs` 同名命令,前端调用点见 3.9)。

```
① allow_official = danmaku::allow_official_for(input.genres)         lib.rs:3377
② sources = danmaku_sources(state, allow_official)                   lib.rs:3378
   空表两种报法(lib.rs:3379-3389):
     - allow_official=true  → Err("未配置弹幕服务器(且无官方弹弹Play凭据)")
     - allow_official=false → Ok(None)   ← 这片本来就不该有弹幕,静默
③ 快路径:锚点 +1                                                     lib.rs:3394-3417
     anchors[key] == (ep-1, id) → 试 id+1
     取到非空 → 更新锚点,返回
④ candidates = danmaku::match_all(...)?     ← 打不通要抛,不能吞      lib.rs:3421
⑤ best = candidates[0],且 score >= MIN_AUTO_SCORE(0.5)              lib.rs:3422
     不够格 → Ok(None)
⑥ raw = get_comments_from_all(sources, best.episode_id, best.source_id)  lib.rs:3426
     空 → Ok(None)
⑦ 记锚点(仅官方源 + episodeId 是纯数字)                              lib.rs:3439-3445
⑧ 返回 apply_filter_and_dedup(raw, options)                          lib.rs:3391
```

#### 快路径的原理与兜底(`lib.rs:3360-3364`)

> 弹弹Play 同一作品的 episodeId 是连号的(第 N 集 +1 = 第 N+1 集)。追番看下一集时直接 +1 取,省一次 match 往返。猜错(跨季/特殊编号)会取到空弹幕,自动退回全量匹配 —— 所以「取到非空」就是这条快路径的兜底校验,别去掉。

#### 两端实现逐行一致(已核实)

我把 `apps/desktop/src/lib.rs:3355-3447` 和 `apps/android/src/lib.rs:3548-3632` 做了 diff:**除注释详略外,代码一行不差**。手机端的注释指回桌面端(`apps/android/src/lib.rs` 的 `danmaku_auto_load` 开头:「判据和取舍见桌面端同名命令的长注释」)。

#### 一条防回归的源码级契约测试

`apps/android/src/lib.rs:5251-5266`(桌面端有同名的一份):

```rust
#[test]
fn auto_match_actually_gates_the_official_danmaku_source() {
    let me = include_str!("lib.rs");
    let auto = me.split_once("async fn danmaku_auto_load(").expect(...).1;
    let body = &auto[..auto.len().min(2000)];
    assert!(body.contains("danmaku::allow_official_for(&input.genres)"), ...);
    assert!(!body.contains("require_danmaku_sources(&state)"), "别退回无条件取全部源(那个函数恒带官方源)");
}
```

它**读自己的源码**来断言「这个命令确实调了门控函数」。理由(`apps/android/src/lib.rs:5246-5249`):

> ★ 官方弹幕配额的护栏……(核层 `is_anime` 写了却从没被任何宿主调用过,非动漫内容照样烧配额)。
> 两端**各钉一份**:合并成一条的话删掉其中一端的调用不会红。

**这是「核层做完了但没人调」这一类 bug 的通用解药**,值得在 Go 侧复刻:普通单测只能证明函数正确,证明不了**有人调它**。
⚠️ 注意项目记忆 `32528fe3`:这类「按 LF 解析自身源码」的契约测试在 Windows 上曾因 CRLF 恒红,Go 侧要么统一 `.gitattributes`,要么解析前先 `strings.ReplaceAll(src, "\r\n", "\n")`。

`anchor_key` = `seriesId|seasonId`;网盘/无剧集上下文传 `None` 即关掉快路径(`lib.rs:3364`)。
锚点表:`AppState.danmaku_anchors: Mutex<HashMap<String, (i64, i64)>>`(`lib.rs:103`),**内存态,重启即失效**。

**只对官方源记锚点**(`lib.rs:3437-3438`):

> 自建源的 id 未必连号,拿去 +1 会取到隔壁作品的弹幕(不报错,只是全篇对不上)。

官方源 id 是 `"official"`,`lib.rs:3176-3178` 特意警告:

> ★ 是 "official",不是 Dart 那边的 "dandanplay" —— 自动挂弹幕的 episodeId 连号快路径要按它认源,写错了不报错,只是快路径永远不命中。

### 3.9 限流:客户端那道拦不住外人

`SEARCH_MIN_INTERVAL = 5 秒`(`mod.rs:782`),状态是**进程内 static**(`mod.rs:784-787`)。

选择「拒绝」而不是「排队等待」(`mod.rs:802-806`):

> 排队的话用户按一下搜索键要盯着转圈五秒,而且连按五下就排出 25 秒的队,比报错难受得多。报错至少说清了还要等几秒。

**只在这次请求会打到官方源时才拦**(`mod.rs:802-803` + `apps/desktop/src/lib.rs:3233-3239`):自建源是用户自己的服务器,没有配额可烧。

**为什么说它拦不住外人**:这道闸活在客户端进程里,而 AppSecret 在 2026-08 之前是编译进发行包的(`crates/danmaku-proxy/src/main.rs:4`:「客户端里的 AppSecret 无论怎么加密都是**可提取**的(解密口令必须和密文一起发出去)」)。拿到密钥的人根本不跑我们的客户端,这道闸对他不存在。
这就是代理存在的全部理由:**唯一拦得住的位置是服务端的出站闸门**。

「配额被刷完」我们自己贡献的三份(项目记忆 `dandan-quota-drain` + 本次核实):
1. `is_anime` 写了没人调 → 非番内容照烧(已修,`mod.rs:760-777` + `lib.rs:3377`);
2. autoLoad 后又重复 match 一轮;
3. 搜索零限流(已修,`mod.rs:779-810`)。
第四个:半失败被吞成「没搜到」(已修,`mod.rs:872-878`)。

### 3.10 匹配输入是怎么拼的(两端必须一字不差)

`ui/mobile/pages/PlayerPage.tsx:250-251` 的注释:

> 弹幕自动匹配。全程 catch:弹幕挂不上绝不能影响播放。
> 口径与桌面端 autoDanmaku 一字不差 —— 两端匹配结果不一致比匹配不上更难查。

三个容易踩的字段(`ui/shared/api.ts:533-554` 的类型注释 + `PlayerPage.tsx:256-275` 的构造逻辑):

| 字段 | 陷阱 | 出处 |
|---|---|---|
| `title` | 剧集必须用 `series_name`,不能用 `Episode.name`——后者是「第 N 集」,搜不到 | `ui/mobile/pages/PlayerPage.tsx:256` |
| `file_name` | 必须是**真实发布文件名**。`/match` 是按文件名做跨语种解析的那条路,喂条目名整条路白跑(注释写「实测返回的第一名是完全无关的片」) | `ui/shared/api.ts:544-546`、`PlayerPage.tsx:257-263` |
| `alt_titles` | 弹弹Play 的条目只有一个标题、没有别名表,所以平行语料只能由我们这边给。库里是中文名而它收日文名时,单靠 `title` 一路恒 0 分 —— 候选捞回来了却被自己的评分扔掉 | `ui/shared/api.ts:536-540` |
| `genres` | **只决定官方弹弹Play 源参不参与自动匹配**,不参与评分。空数组 = 元数据没刮到 = 不知道 → 核层按「允许」处理 | `ui/shared/api.ts:550-553` |

`file_name` 的求法(`ui/mobile/pages/PlayerPage.tsx:260-263`):优先 `item.path` 的 basename;没有就打 `itemMedia(item.id)` 取 `preferred` 版本(没有则第一条)的 `name + "." + container`;再兜底 `item.name`。
注释:「MediaSource.Name 就是不含扩展名的真文件名」。

### 3.11 ⚠️ 过滤参数是死的:`blockwords` / `user_blocklist` / `blocked_modes` 从来没被传过非空值

`DanmakuFilterOptions` 定义(`ui/shared/api.ts:556-563`):

```ts
{ blockwords: string[]; user_blocklist: string[];
  blocked_modes: number[] /* 1=滚动 4=底 5=顶;空=不过滤 */;
  dedup: boolean; dedup_window: number }
```

全仓库对它的调用只有两处,**都传 `defaultDanmakuFilter()`**:

- `ui/desktop/App.tsx:532`
- `ui/mobile/pages/PlayerPage.tsx:276`

而 `defaultDanmakuFilter()`(`ui/shared/api.ts:1765-1771`)返回:

```ts
{ blockwords: [], user_blocklist: [], blocked_modes: [], dedup: true, dedup_window: 10 }
```

我 grep 过全部前端(`ui/**/*.ts{,x}`,排除 `node_modules`):`blockwords` / `user_blocklist` / `blocked_modes` 三个标识符**只出现在 api.ts 的类型定义和默认值里**,没有任何 UI 写入它们。
另外查了两端设置页的「弹幕」面板(`ui/desktop/pages/SettingsPage.tsx:874-929`、`ui/mobile/pages/SettingsPage.tsx:507-698`),里面只有**弹幕源列表**(增删改、优先级排序),没有屏蔽词、没有类型过滤。
仓库里所有「屏蔽」字样都属于**媒体库屏蔽**功能(`ui/desktop/lib/cardActions.tsx:176-181`、`ui/desktop/lib/libBlock.tsx`),和弹幕无关。

**结论**:核层的屏蔽词/用户黑名单/类型过滤三项能力已实现但**前端零接线**,只有 `dedup`(去重)和 `dedup_window` 在以默认值工作。

**两条命令同样零调用**(grep `ui/**` 全仓库,排除 `node_modules`):

| 命令 | 注册处 | 前端调用点 |
|---|---|---|
| `danmaku_filter` | `apps/desktop/src/lib.rs:3450-3456` | **0 处**(`ui/` 里出现的两处全是注释:`ui/desktop/App.tsx:128`、`ui/shared/Danmaku.tsx:20`) |
| `danmaku_import_blocklist` | `apps/desktop/src/lib.rs:3459-3462` | **0 处** |

也就是说 `import_dandanplay_blocklist_xml`(`crates/core/src/danmaku/mod.rs:1500-1530`,连同它那 20 行的 XML 解析和一整条测试)是一条**从核层到命令层都做完、但没有任何入口的功能**。

⚠️ 注意 `apps/desktop/src/lib.rs:3391` 的 `finish` 闭包会把 `options` 用上,所以核层的过滤代码**是在跑的** —— 只是每次都拿着三个空数组跑。这就是它能一直「编译绿、单测绿、看不出问题」的原因。

**并且界面在撒谎**:`ui/mobile/pages/PlayerPage.tsx:1198` 的说明文字写着

> 「匹配规则、屏蔽词、多源优先级在『设置 → 弹幕』里改。」

三样里只有「多源优先级」真的存在。这与项目记忆 [[stale-waijie-lies]] / [[regex-filters-frontend-wiring]] 是同一类故障:**核层做完了,前端没接,而 UI 文案已经把它当成做好了在描述**。

**Go 侧要点**:把 `DanmakuFilterOptions` 迁过去时,顺手确认调用方到底传不传。核层单测再绿也照不到这种断口。

### 3.12 时钟同步:`TimeSync`(这是「弹幕卡」的真根因所在)

见第 5 节踩坑清单第 1 条,那里写全了。

---

## 4. mpv 字幕子系统

### 4.0 一句话

mpv 的字幕属性分两族:**「主/次两位」的位置族**(`sid` / `secondary-sid`)和**「样式」族**(`sub-*`)。
样式族**没有 secondary 版本**——所有 `sub-*` 样式是主次共用的一份;而 ASS 与纯文本对同一个样式属性的响应又不一样。这两件事叠在一起,产生了本仓库历史上最难查的一类字幕故障。

### 4.1 属性总表

下表只列本仓库真正读写过的属性。「对 ASS 有效?」一列的依据是 `crates/mpv/src/lib.rs:1848-1857` 记录的 2026-07-16 ctypes 实测(libmpv v0.41.0-744)。

| 属性 | 我们的封装 | 出处 | 值域/写法 | 对 **ASS** 字幕 | 对**纯文本**字幕 | 坑 |
|---|---|---|---|---|---|---|
| `sid` | `set_track("sub", id)` | `crates/mpv/src/lib.rs:1746-1749` | 轨 id / `"no"` | ✅ | ✅ | 安卓历史上曾用 `command("set_property","sid",..)`,mpv 无此命令,静默失败 |
| `aid` | 同上(`kind=="audio"`) | 同上 | 轨 id | — | — | 天然对照组:它一直是对的 |
| `secondary-sid` | `set_secondary_sub(id)` | `crates/mpv/src/lib.rs:1882-1884` | 轨 id;空串 → `"no"` | ✅ | ✅ | **全 mpv 只有一个次字幕位** |
| `sub-scale` | `set_sub_scale(f64)` | `crates/mpv/src/lib.rs:1858-1860` | `clamp(0.2,4.0)`,格式 `{:.2}` | ✅ | ✅ | **这才是「字幕大小」旋钮** |
| `sub-font-size` | **不用** | — | — | ❌ **完全无视** | ✅ | 见 4.2 |
| `sub-font` | `set_sub_font(&str)` | `crates/mpv/src/lib.rs:1841-1847` | 字体族名 | ❌(`ass-override=scale` 下保样式) | ✅ | 必须挡掉空串和 UI 占位串 `"默认"` |
| `sub-pos` | `set_sub_position(f64)` | `crates/mpv/src/lib.rs:1870-1872` | `clamp(0,100)` **取整** | ⚠️ ASS 自带定位优先 | ✅ | mpv 只收整数 |
| `sub-delay` | `set_sub_delay` / `sub_delay` | `crates/mpv/src/lib.rs:1816-1821` | 秒,可负 | ✅ | ✅ | — |
| `sub-back-color` | `set_sub_background(bool)` | `crates/mpv/src/lib.rs:1873-1876` | `#80000000` / `#00000000` | ❌ | ✅ | 代码注释明写「ASS 自带样式的字幕不受此影响」 |
| `blend-subtitles` | `set_sub_blend_mode(&str)` | `crates/mpv/src/lib.rs:1877-1879` | mpv 枚举 | ✅ | ✅ | 决定字幕在缩放前还是缩放后混合 |
| `sub-ass-override` | **从不设**(吃默认 `scale`) | 仅注释 `crates/mpv/src/lib.rs:1851-1852` | `no`/`scale`/`force`/`strip` | — | — | 默认 `scale` 是上面一半故障的成因 |
| `secondary-sub-ass-override` | `set_secondary_sub_ass_override(&str)` | `crates/mpv/src/lib.rs:1863-1868` | 白名单 4 值 | ✅ | ✅ | 默认 `strip`;**传错值 mpv 静默拒绝**,故封装里先白名单挡一道 |
| `secondary-sub-pos` | `set_secondary_sub_position(f64)` | `crates/mpv/src/lib.rs:1896-1898` | `clamp(0,100)` 取整 | ⚠️ | ✅ | mpv 真默认是 **0**(顶),不是 100 |
| `secondary-sub-delay` | `set_secondary_sub_delay(f64)` | `crates/mpv/src/lib.rs:1893-1895` | 秒 | ✅ | ✅ | — |
| `sub-fonts-dir` | 仅安卓,初始化时设 | `crates/mpv/src/lib.rs:1266` | `/system/fonts` | 见 4.5 | 见 4.5 | 见 4.5 |
| `track-list/N/*` | `tracks()` | `crates/mpv/src/lib.rs:1724-1745` | 读 `type`/`id`/`title`/`lang`/`selected`/`codec`/`demux-channel-count` | — | — | `codec`/`channels` 是给正则筛选用的,漏取会让 `6ch` 这类规则恒不命中 |

命令(不是属性):

| 命令 | 我们的封装 | 出处 |
|---|---|---|
| `sub-add <url> [flags [title]]` | `add_subtitle` / `add_secondary_sub` | `crates/mpv/src/lib.rs:1611`、`1887`、事件线程 `1417` |
| `sub-remove <id>` | **已随弹幕路一起删**;`git show 108965f6^` 里在 `attach_danmaku_raw` | — |

`flags` 恒用 `auto`,含义:挂上但**不自动切**,选哪条仍由用户/语言偏好决定。三处注释一致:`crates/mpv/src/lib.rs:1416`、`1610`、`apps/desktop/src/lib.rs:1761`。

#### `secondary-*` 只有九个,不存在样式属性

`apps/desktop/src/lib.rs:2333-2338` 记录了 2026-07-16 拉 `property-list` 的实测结论:

> ★ 这些 `sub-*` 属性**主次字幕共用** —— 不是偷懒,是 mpv 就没有分开的那一份:
> 2026-07-16 用 ctypes 拉 libmpv 的 `property-list` 实测,`secondary-*` 名下总共只有
> sid / ass-override / delay / pos / visibility / text / start / end / lines,
> **不存在 secondary-sub-font-size / -font / -color**(set 回 -8 property not found)。
> 所以「次字幕单独设字体大小」在 mpv 层面无法实现,UI 上就该如实标成主次共用,别造一个假的次字幕字号 stepper 骗人。

UI 照做了:`ui/desktop/App.tsx:1976` 的分组标题就叫「字幕样式 · 主次共用」。

我另外用二进制字符串比对独立验证了这份清单(方法与结果见 4.6),Windows 版 libmpv 里的 `secondary-*` 字面量恰好是这九个 + `secondary-sub-tracks` / `secondary-subtitle-line`。

### 4.2 `sub-font-size` 对 ASS 无效 —— 完整因果链

`crates/mpv/src/lib.rs:1848-1857` 的原文(这是全仓库关于 mpv 字幕最重要的一段注释):

> 字幕缩放倍率。**这才是「字幕大小」该拧的那颗旋钮**。
>
> 2026-07-16 用 ctypes 直接问 libmpv(v0.41.0-744)实测:
>   - `sub-ass-override` 默认 = `scale` —— 这个模式下 ASS 字幕**只认 `sub-scale`,完全忽略 `sub-font-size`**。而内封字幕(尤其番剧)绝大多数是 ASS。
>   - `secondary-sub-ass-override` 默认 = `strip` —— ASS 标记被剥成纯文本,于是它**反过来只认 `sub-font-size`**。
>
> 合起来正是用户 2026-07-16 报的那个怪象:「只能调次字幕的字体大小,主字幕的调不动」—— 同一个 sub-font-size,对主(ASS 保样式)无效、对次(被 strip 成纯文本)有效。
> `sub-scale` 对 ASS 与纯文本都生效,所以大小统一走它。别再拿 sub-font-size 当大小旋钮。

**一个根因,两个用户可见症状**:

| 用户报的 | 机制 |
|---|---|
| 「主字幕大小调不动」 | 主字幕吃 `sub-ass-override=scale` → 保 ASS 样式 → 无视 `sub-font-size` |
| 「次字幕不渲染样式」 | 次字幕吃 `secondary-sub-ass-override=strip` → ASS 标记被剥光 → 变纯文本 |

修法(两条):
1. 大小统一走 `sub-scale`(`crates/mpv/src/lib.rs:1858`),UI 侧改成百分比 stepper(`ui/desktop/App.tsx:340-342`、`App.tsx:1988-1993`)。
2. `secondary-sub-ass-override` 提成用户可切的开关,默认改成 `scale`(`ui/desktop/App.tsx:349-350`、`App.tsx:2014-2020`)。

`ui/desktop/App.tsx:2012-2013` 还诚实地写了改默认值的**副作用**:

> ⚠️ 保留原样式 = 次字幕按它自己 ASS 里写的位置画,「位置」这项可能就推不动它了(ASS 自带定位优先),而且多半和主字幕挤在底部。真挤了就切回「纯文本」。

### 4.3 `secondary-sid` + `secondary-sub-ass-override=no`:为什么是这个组合

> ⚠️ 这段代码**已被删除**(`108965f6`)。留在这里是因为 Go 侧若重开 ASS 弹幕必须原样照抄,这两句缺一不可。

`git show 108965f6^` 的 `attach_danmaku_raw` 里(`[已删] crates/mpv/src/lib.rs`):

```rust
set_str_raw(ctx, "secondary-sid", &id);
/* mpv 默认 `secondary-sub-ass-override=strip`:把 ASS 标记**剥成纯文本**,
   于是 \move / \pos / \c 全没了,弹幕会变成一行叠在顶上的白字。
   必须显式关掉覆写,让 libass 照我们写的样式渲染。 */
set_str_raw(ctx, "secondary-sub-ass-override", "no");
set_str_raw(ctx, "secondary-sub-visibility", "yes");
```

拆开讲:

**① 为什么走 `secondary-sid` 而不是 `sid`**
函数上方的注释:

> 走 secondary 而不是主字幕位:主位要留给用户真正的字幕轨,否则一开弹幕字幕就没了 —— 那是「修好一个坏掉另一个」。

**② 为什么必须 `=no` 而不是别的值**

| 值 | 行为 | 弹幕能用吗 |
|---|---|---|
| `strip`(mpv 默认) | 剥掉全部 ASS 标记当纯文本画 | ❌ `\move`/`\pos`/`\c` 全没,弹幕变成顶上一行白字 |
| `scale` | 保留 ASS 样式,但套用 mpv 的缩放 | 未确认(仓库从未用它跑过弹幕) |
| `force` | 用 mpv 的样式强制覆盖 ASS | ❌ 定位标签会被顶掉 |
| `no` | **完全不干预**,原样交给 libass | ✅ |

**③ 一个只有真机能发现的事实**

项目记忆 `danmaku-via-libass-ass.md` 记录:

> mpv 源码 `sub/sd_ass.c` 里 `ass_style_override[sd->order]` 对主/次一视同仁 —— 次字幕位**支持完整 ASS 定位**,不是只能显示一行。

即:次字幕位不是「阉割版」,`\move` / `\pos` 在那儿照样工作。挡路的只有默认的 `strip`。

**④ 为什么这条路最终还是被砍了**
不是技术不行,是**产品互斥**:次字幕位全局只有一个,弹幕占了就没法开双语字幕(`ui/desktop/App.tsx:144-146`)。

### 4.4 外挂字幕挂载的时序约束 —— 四条硬约束

这一组是本仓库最反复强调的东西,四条缺一不可。

#### 约束 1:`loadfile` 是异步的,`sub-add` 必须等 `FILE_LOADED`

`crates/mpv/src/lib.rs:33-36`:

> 文件真正打开完毕。★ `loadfile` 是**异步**命令 —— 它只把条目排进 playlist 就返回,此刻并没有「当前文件」。紧跟着发 `sub-add` 必然拿到 -12 error running command(**ctypes 实跑 libmpv v0.41 复现:立刻挂 → 字幕轨 0 条;等到本事件再挂 → 成功 1 条**)。
> 这就是「外挂字幕挂了等于没挂」的根因,而 `let _ =` 把错误吞得一干二净。

`crates/mpv/src/lib.rs:1596-1603` 说明了为什么把这个判断放在 `add_subtitle` 里而不是让调用点各自小心:

> ★ 调用时机不确定,所以由**这里**兜住,而不是让五个调用点各自小心:
>   - 起播路径(两端 play + 网盘源)紧跟在 `load_at` 之后,那时 `loadfile` 还没真正打开文件,直接 sub-add 拿到的是 -12 —— 这就是「外挂字幕全都挂不上」;
>   - 播放中路径(用户手动加字幕、翻译字幕)文件早就开好了,可以当场挂。
> 锁内判一次 loaded 就把两种都覆盖。

#### 约束 2:`loaded` 和 `pending` 必须在同一把锁里(TOCTOU)

`crates/mpv/src/lib.rs:1066-1070`:

> ★ `loaded` 和 `pending` **必须在同一把锁里**,不能拆成 AtomicBool + Mutex<Vec>:那样会有 TOCTOU —— 调用方读到 loaded=false 正准备写 pending,事件线程恰好在这一瞬收到 FILE_LOADED 并取走(空的)pending,字幕就永远没人挂了,而且**一声不吭**。同款竞态在预取环形缓存上真炸过一次,不重复踩。

数据结构(`crates/mpv/src/lib.rs:1071-1080`):

```rust
struct SubState {
    loaded: bool,                    // 当前文件是否已 FILE_LOADED
    pending: Vec<(String, String)>,  // (url, title)
    pending_seek: Option<f64>,       // 起播途中的 seek,同一个坑同一个解法
}
```

#### 约束 3:必须在**事件线程**里挂,不能另开线程

`crates/mpv/src/lib.rs:1404-1410`:

> 就在事件线程里挂,**不要**另开线程:Drop 的顺序是 running=false → join(事件线程) → mpv_terminate_destroy,只有跑在这根线程上才被 join 保护住;另开的线程会绕过它,用户在字幕下载途中关播放器就是 ctx 悬垂。
> 代价是 sub-add 会同步拉取字幕文件(真服实测两条相隔 4s),这期间 END_FILE 只是**延迟**latch(事件在 mpv 队列里不丢),拿几秒的延迟换掉一个 use-after-free,划算。

配套的两处细节:
- `crates/mpv/src/lib.rs:1412-1415`:循环里每条前先看 `running`,正在关闭就 break,让 `join` 早点回来。
- `crates/mpv/src/lib.rs:1056-1057`:事件线程只有裸 `ctx`,所以有个不依赖 `&Player` 的 `cmd_raw`。注释:「libmpv 的 mpv_command 是线程安全的(官方文档明示),从事件线程发命令合法」。

#### 约束 4:返回值不能吞

`crates/mpv/src/lib.rs:1611-1615` 与 `1417-1421` 两处都写了同一句:

> 原来这里是 `let _ =`,失败一声不吭,现象只剩「字幕列表里什么都没有」。

现在两处都 `match` 并 `poclog`。

#### 换片复位

`crates/mpv/src/lib.rs:1572-1580`:

> 字幕状态跟着换片一起复位:loaded 不清的话,下一集的 set_external_subs 会以为文件已经开好而立刻 sub-add(其实新文件还没加载完,又回到 -12);pending 不清的话,上一集没挂成的字幕会漏到这一集。

弹幕版曾经有更严重的一条(`git show 108965f6` 的删除块):

> 弹幕同理,而且更要命:排队中的那份是**上一集**的弹幕,漏到下一集就是「集数对不上的弹幕」——看起来能用,内容全错。

#### 起播路径的挂载顺序

`apps/desktop/src/lib.rs:1758-1764`:

> ★ 外挂字幕(和视频同级的独立 .ass/.srt)**不在容器里**,mpv 拿到视频 URL 后 track-list 里根本看不到它们 —— 这就是「外挂字幕不加载」。必须逐条 sub-add。
> 放在 load_at 之后:sub-add 挂的是**当前文件**,先挂会被 loadfile 冲掉。

即顺序恒为:`load_at()` → `add_subtitle()` × N → `set_pause(false)`。

#### 同一个坑的第二个受害者:seek

`crates/mpv/src/lib.rs:1061-1066`(`pending_seek` 的注释)记录了完全同构的一次故障:

> 和外挂字幕**同一个坑、同一个解法**:`seek` 发在 FILE_LOADED 之前只会拿到「命令失败」——mpv 那会儿还没有文件可跳。而闩在发命令之前就设上了,于是现象是:进度条压着用户拖到的位置 2.5s,然后弹回 `start=` 的续播点,画面从头到尾没跳过。

补发时还要重置 seek 闩的计时起点(`crates/mpv/src/lib.rs:1389-1395`):

> ★ 必须重置闩的计时起点:闩是用户拖的那一刻设的,加载花掉的几秒会让它一进来就判超时,真正的 seek 还没落地进度条就弹回去了。

**Go 侧要点**:这是一个「异步 loadfile + 一切后续命令」的通用模式,不只是字幕。Go 里用 `sync.Mutex` 保护一个 `struct{ loaded bool; pending []sub; pendingSeek *float64 }`,`FILE_LOADED` 时在事件 goroutine 内一次性取走并执行,并让该 goroutine 被 `Close()` 的 `WaitGroup` 覆盖住。

### 4.5 Android:`sub-fonts-dir=/system/fonts`

现状代码(`crates/mpv/src/lib.rs:1262-1266`):

```rust
/* ★ 文本字幕(SRT/ASS)在安卓上不显示 = libass 找不到任何字体。
   安卓没有 fontconfig,不指这一条就是**静默不画字幕**。
   这条在旧 Flutter 版上踩过并记进了 [[android-mpv-subtitle-fonts]],
   换栈之后是同一个 libass,坑原样还在 —— 直接带上,别再踩一次。 */
set("sub-fonts-dir", "/system/fonts");
```

配套的第二道守卫在 `set_sub_font`(`crates/mpv/src/lib.rs:1841-1847`):UI 占位串 `"默认"` 和空串都不能塞给 libass,否则它去找一个叫「默认」的字体族,找不到就不画。

#### 我实测到的东西(以及一条**未确认**)

我用二进制字符串比对查了仓库里两个 libmpv:

| | 版本 | `FcInit` | `FONTCONFIG_FILE` | `fontconfig` | `ass_library_init` |
|---|---|---|---|---|---|
| `apps/android/gen/android/app/src/main/jniLibs/arm64-v8a/libmpv.so` | **v0.36.0**(二进制内含 `v0.36.0` 字符串) | **0** | **0** | 1 | 1 |
| `crates/mpv/libmpv/libmpv-2.dll` | v0.41(依据 `crates/mpv/src/lib.rs:1850` 注释) | 2 | 1 | 17 | 0(Win 版 libass 静态符号名不同) |

**确认**:安卓这颗 libmpv **没有编入 fontconfig**(`FcInit` / `FONTCONFIG_FILE` 一个都没有,而 Windows 版两个都有)。所以「安卓没有 fontconfig」这条前提是真的,libass 只能走它自己的目录 provider。

**未确认**:`sub-fonts-dir` 这个选项在 v0.36 上到底认不认。
我查过:两颗二进制里 `sub-fonts-dir` 全名都**不出现**,但 `fonts-dir` 后缀都恰好出现 1 次(安卓侧上下文是 `draw_bmp.c:377 font fonts-dir \org`,像是选项名表)。**这说明 mpv 的样式类选项是「前缀 + 后缀」在运行时拼出来的,查全名的字符串法对这一族无效**——反证:`sub-font-size` 全名在 Windows DLL 里同样 0 次,而它被 ctypes `property-list` 证实真实存在。
所以我**不能**据此说「安卓上 `sub-fonts-dir` 是 no-op」。要定论只能在真机上 `mpv_get_property_string("sub-fonts-dir")` 回读。

> 旧记忆 `android-mpv-subtitle-fonts.md` 里「grep 全 miss,所以该选项不存在」这一条,用的正是我上面证伪掉的这个方法,**其结论存疑**。它后来的修正版(改用 fontconfig / libass 目录 provider 双铺)基于符号级检查,那部分与我的 `FcInit` 观测一致。

### 4.6 `secondary-*` 在安卓上少了三个(实测差分,可信)

上面那个方法对**非前缀拼接**的属性仍然有效——`secondary-*` 就是这一类(全名在两颗二进制里都直接出现)。同样的方法、同样的命令,差分干净:

| | 安卓 libmpv v0.36 | Windows libmpv v0.41 |
|---|---|---|
| `secondary-sid` | ✅ | ✅ |
| `secondary-sub-visibility` | ✅ | ✅ |
| `secondary-sub-start` / `-end` / `-text` | ✅ | ✅ |
| `secondary-sub-ass-override` | ❌ **无** | ✅ |
| `secondary-sub-delay` | ❌ **无** | ✅ |
| `secondary-sub-pos` | ❌ **无** | ✅ |
| `secondary-sub-lines` / `-tracks` / `secondary-subtitle-line` | ❌ 无 | ✅ |

而 `apps/android/src/lib.rs:3295-3311` 的 `set_secondary_sub_opts` 命令**三项全调**:

```rust
if let Some(d) = delay      { p.set_secondary_sub_delay(d); }
if let Some(pos) = position { p.set_secondary_sub_position(pos); }
if let Some(m) = ass_override { p.set_secondary_sub_ass_override(&m); }
```

三个属性在安卓的 libmpv 上都不存在 → `mpv_set_property_string` 返回 `-8`(property not found)→ 而 `crates/mpv/src/lib.rs:1466-1470` 的 `set_str` **把返回值整个丢掉**:

```rust
fn set_str(&self, name: &str, val: &str) {
    let n = CString::new(name).unwrap();
    let v = CString::new(val).unwrap();
    unsafe { mpv_set_property_string(self.ctx, n.as_ptr(), v.as_ptr()); }
}
```

→ **静默 no-op**。

**严重程度:目前是潜伏,不是活 bug。** 我 grep 过 `ui/mobile/` 和 `ui/tv/`,没有任何地方调 `setSecondarySub` / `set_secondary_sub_opts`(唯一命中是 `ui/mobile/theme/mobile.css:2886` 的一句注释)。命令注册在 `apps/android/src/lib.rs:4886-4887`,但前端没接。手机端一旦接上双字幕面板,这三个旋钮就是死的。

**Go 侧要点(两条,都不贵)**:
1. `set_property` 的返回值必须检查并记日志。这一个改动能让上面整类故障从「一声不吭」变成「日志里一行 -8」。
2. 平台间 libmpv 版本可能差好几个大版本,别假设属性集一致。启动时读一次 `property-list` 存下来,设之前先问。

### 4.7 字幕轨选择

选轨算法在核层,三端共用:`crates/core/src/media.rs:81-110`。

优先级(`crates/core/src/media.rs:68-69` 注释):**手动切过的轨 ＞ 正则命中 ＞ 首选语言/服务端默认**(手动那层在前端,不在核层)。

```rust
pub fn pick_tracks(tracks: &[Track], p: TrackPrefs<'_>) -> (Option<String>, Option<String>) {
    let aid = pick_one(tracks, "audio", p.audio_regex, p.audio_lang);
    let sid = if !p.sub_enabled { Some("no".to_string()) }
              else { pick_one(tracks, "sub", p.sub_regex, p.sub_lang) };
    (aid, sid)
}
```

返回值三态(`crates/core/src/media.rs:80`):`Some(id)` = 切到该轨;`Some("no")` = 关字幕;`None` = **保持不变**。

`pick_one`(`crates/core/src/media.rs:91-110`)两段:
1. 正则匹配 `Track::match_text()`;
2. 落空则用语言/标题**包含**匹配(小写化后 `contains`)。

`match_text()`(`crates/core/src/media.rs:32-38`)= `title + " " + lang + " " + codec`,音轨再追加 ` {channels}ch`。

三条跨语言陷阱:
- **`codec` / `channels` 必须从 mpv 取全**,否则 `6ch`、`ac3` 这类规则恒不命中。`crates/mpv/src/lib.rs:1736-1741` 注释:「正则筛选要匹配编码和声道(wiki regex-filters 的口径),所以这两个必须取」。
- **正则合法性必须问 Rust 不能问 JS**(`apps/desktop/src/lib.rs:2997-2999`):Rust 的 `regex` crate 无前后瞻/反向引用,用 JS 的 `RegExp` 校验会放过 Rust 编译不过的写法,「于是设置存下了却永不命中,还一声不吭」。**Go 的 `regexp`(RE2)与 Rust 的 `regex` 同源同限制,这条口径迁过去正好不用改。**
- **空/非法正则 = 「没启用」不是「没匹配上」**(`crates/core/src/media.rs:62`),两者对调用方都是回退默认,但不能报错。

### 4.8 外挂字幕的上游:Emby 侧四层断口

字幕在 mpv 之前还有四个可能断掉的地方,全在 `crates/core/src/emby.rs`。

#### 断口 1:`SubtitleProfiles: []` 让服务器从源头不发地址

`crates/core/src/emby.rs:2100-2115`:

> ★ 原来这里是 `[]`。空表 = 告诉服务器「本客户端一种字幕都不支持」,服务器于是把 DeliveryMethod 判成 Encode/Drop 且不发 DeliveryUrl,外挂字幕从源头就被掐死。声明 External 后服务器才会给取字幕地址。

现在声明了 9 种 `External` + 2 种 `Embed`(`emby.rs:2103-2115`)。
测试注释(`crates/core/src/emby.rs:2487-2489`)是真服 A/B 实测记录:带 `SubtitleProfiles:[{Format:"ass",Method:"External"}]` 的 PlaybackInfo 返回 `DeliveryUrl=/Videos/50257/mediasource_50257/Subtitles/37/0/Stream.ass?api_key=...`;而 `SubtitleProfiles:[]` 返回 `DeliveryMethod=Encode, DeliveryUrl=null`。

#### 断口 2:`RawStream` 压根没解析 `IsExternal` / `DeliveryUrl`

`crates/core/src/emby.rs:2500` 的测试注释:

> IsExternal / DeliveryUrl 必须真的被解析出来 —— 原来 RawStream 压根没这两个字段。

现在两个字段都在(`crates/core/src/emby.rs:295-297`)。

#### 断口 3:拿 `Path` 当 URL

`crates/core/src/emby.rs:396-398`:

> 只认 DeliveryUrl。Path 是**服务端本地文件系统路径**(如 /media/x.ass),客户端取不到,拿来当 URL 只会 404。

#### 断口 4:字幕根本没进 `PlaybackTarget`

`crates/core/src/emby.rs:2176-2200` 组装 `external_subs`,并在服务器不给 `DeliveryUrl` 时按 index 拼标准路由(`emby.rs:1771-1773` 注释:「格式必须和 Emby 自己发的 DeliveryUrl 一模一样 —— 见 tests 里那条实测断言」)。

两处编码归一(`crates/core/src/emby.rs:2186-2194`):
- 图形字幕 `pgssub`/`pgs`/`dvdsub`/`dvbsub` 直接跳过(「外挂形态少见且 mpv 挂载后多半不可用」);
- `subrip` → `srt`、`webvtt` → `vtt`(「Emby 的 Stream.{ext} 里 ext 用的是封装名」)。

### 4.9 strm / 网盘:MediaStreams 为空时的回退

**当前 Rust/React 栈里,这个回退是「选轨时机」而不是「数据源回退」。**

`ui/mobile/pages/PlayerPage.tsx:330-336`:

> ★ 顺手把**详情页起播前挑好的音轨/字幕**落实到 mpv 上。
> 为什么必须在这里做:详情页看到的是 Emby 的 MediaStreams,而能操作的是 mpv 的 track-list —— 后者要等 demux 完才有(网络流上是起播后几百毫秒到几秒,外挂字幕更晚)。所以"选"和"生效"天然分处两个时刻,中间靠 app/prepick.ts 交接。

也就是说:**播放页的轨道面板本来就只读 mpv 的 `track-list`,不读 Emby 的 `MediaStreams`**,所以 strm 条目 PlaybackInfo 返回 0 条流时,播放页仍然能正常选轨。

`ui/mobile/pages/PlayerPage.tsx:328-329`:

> 轨道要**探到稳定**:外挂字幕要等核层收到 mpv 的 FILE_LOADED 才挂得上,慢服务器上是起播后好几秒的事。三端共用一份逻辑。

配套两条(`ui/mobile/pages/PlayerPage.tsx:334-336`、`347-348`):
- 只在**第一次拿到非空轨表**时应用一次(`preApplied`),之后用户手动切的优先级更高;
- 字幕的两种「选过了」必须分开:`-1` = 明确关闭,`>=0` = 选了第几条。「合成一个值的表现是用户关了字幕、起播后又被 apply_prefs 打开」。

历史背景(项目记忆 `netdisk-strm-playback.md`,Flutter 时代):strm 条目的 `PlaybackInfo` 返回 0 视频/0 音频/0 字幕流(服务器不 ffprobe 远程文件),而 Flutter 版的面板只从 `mediaSource.mediaStreams` 建列表 → 空 → 没法选;当时的修法是面板在 Emby 流为空时回退用 mpv 真轨。
**现在的栈天然免疫**,因为播放页从一开始就只认 mpv 真轨。

> **未确认**:我 grep 过 `crates/` 和 `apps/*/src/`,没有任何「MediaStreams 为空 → 回退」的显式分支代码(唯一命中是 `crates/core/src/source/plugin_source.rs:476` 一句不相关的注释)。上述结论是从「播放页只读 track-list」这一事实推出的架构性免疫,不是某处有一段回退逻辑。

---

## 5. 踩坑清单

格式:**症状 / 真因 / 现在怎么处理 / Go 侧怎么落 / 出处**

---

### 坑 1 ⭐ 「弹幕正常速度也卡、倍速更卡」

- **症状**:1× 下弹幕一顿一顿;2× 下更明显,像每秒抽搐好几次。用户第一反应是「弹幕太多画不动」。
- **真因**:**不是绘制开销,是时间源。** 前端每 250ms(现为 1s)从 mpv 轮询一次播放位置,两拍之间用 `performance.now()` 做墙钟外推——**那段插值里没有倍速这个变量**。2× 播放时弹幕按 1× 爬,每次轮询被真实位置一把拽回去 = 每秒 4 次硬跳;1× 下 `time-pos` 自身的抖动同样以 4Hz 拽扯画面。
  `[已删] ass.rs:5-9` 原文:
  > 老实现是前端 rAF 自己画:每 250ms 从 mpv 轮询一次播放位置,帧间用 `performance.now()` 线性插值。**那段插值里没有倍速这个变量** —— 2x 播放时弹幕按 1x 爬,每 250ms 被真实位置一把拽回去,每秒 4 次硬跳;1x 下 `time-pos` 自身的抖动同样以 4Hz 拽扯画面。用户报的「正常速度也卡、倍速更卡」就是这个,不是绘制开销(纯色滚动弹幕再多也画得动)。
- **走过的弯路**:第一次的修法是**换渲染引擎**——把弹幕生成 ASS 交 libass,让时间轴/倍速/seek/暂停全归 mpv(`4f72060c`)。这确实治好了症状,但代价是占掉唯一的次字幕位。次日(`108965f6`)整条删掉,改回 Canvas 并**真正修掉插值里那个漏掉的因子**。
- **现在怎么处理**:`TimeSync` 结构强制带 `speed`:

  `ui/shared/Danmaku.tsx:8-11`:
  > 播放时钟的快照。`speed` **必须有**:两次轮询之间是用墙钟外推的,没有倍速这个因子,2x 播放时弹幕按 1x 爬,再每 250ms 被真值一把拽回去 —— 那就是用户报的「倍速更卡」,和绘制开销毫无关系。

  ```ts
  export type TimeSync = { base: number; stamp: number; paused: boolean; speed: number };
  ```

  插值(`ui/shared/Danmaku.tsx:94-95`):
  ```js
  // ★ 乘 speed:墙钟外推必须按倍速走,否则每次轮询都要把弹幕硬拽回真实位置。
  const t = ts.paused ? ts.base
          : ts.base + ((performance.now() - ts.stamp) / 1000) * (ts.speed || 1);
  ```

  生产端两处必须同步 `speedRef`:
  - 桌面 `ui/desktop/App.tsx:1046-1047`(注释:「speed 必须带上:两次轮询之间靠墙钟外推,不乘倍速就每 250ms 硬跳一次」)
  - 手机 `ui/mobile/pages/PlayerPage.tsx:304`

  `speedRef` 的三个写入点缺一不可:回读真值 `App.tsx:668` / `PlayerPage.tsx:202`(注释:「连调基准也得跟着回读的真值走,否则长按会从 1.0 起跳」)、倍速面板 `App.tsx:1277`、长按 2× `PlayerPage.tsx:497`。
- **Go 侧怎么落**:如果 Go 核层要吐一个「播放时钟」给 UI,**它必须是三元组 `{base, stamp, speed}` 而不是单个 `time`**。把 `speed` 作为可选项就是重蹈覆辙。
- **出处**:`ui/shared/Danmaku.tsx:8-11,94-95`;`ui/desktop/App.tsx:1046-1047`;`ui/mobile/pages/PlayerPage.tsx:146-148,304`;`[已删] ass.rs:5-9`;`ui/desktop/App.tsx:147-148`

---

### 坑 2 「外挂字幕挂了等于没挂」

- **症状**:字幕列表空的,或者少几条。不报错。
- **真因**:`loadfile` 是异步命令,只把条目排进 playlist 就返回;紧跟的 `sub-add` 必得 `-12 error running command`,而 `let _ =` 把错误吞光。
- **现在怎么处理**:`SubState { loaded, pending }` 同锁排队 + 事件线程在 `FILE_LOADED` 时补挂 + 返回值 `match` 打日志。四条硬约束见 4.4。
- **Go 侧怎么落**:`sync.Mutex` 保护 `{loaded bool; pending []sub}`;`FILE_LOADED` 在事件 goroutine 内 `swap` 取走并执行;该 goroutine 必须被 `Close()` 的 `WaitGroup` 覆盖(对应 Rust 的 `join`);`mpv_command` 的返回值一律检查。
- **出处**:`crates/mpv/src/lib.rs:33-36,1066-1070,1404-1421,1596-1616,1572-1580`;`apps/desktop/src/lib.rs:1758-1764`

---

### 坑 3 「主字幕大小调不动 / 次字幕不渲染样式」

- **症状**:字幕大小 stepper 对内封字幕完全无效,但对次字幕有效;次字幕永远是白色纯文本。
- **真因**:一个根因两个面。`sub-ass-override` 默认 `scale`(ASS 保样式 → 无视 `sub-font-size`),`secondary-sub-ass-override` 默认 `strip`(ASS 被剥成纯文本 → 反而只认 `sub-font-size`)。
- **现在怎么处理**:大小统一走 `sub-scale`;`secondary-sub-ass-override` 提成用户开关,默认 `scale`。UI 分组如实标「主次共用」。
- **Go 侧怎么落**:字幕大小旋钮**只暴露 `sub-scale`**,不要暴露 `sub-font-size`(它只对被 strip 的纯文本有效,是个陷阱)。
- **出处**:`crates/mpv/src/lib.rs:1848-1868`;`apps/desktop/src/lib.rs:2331-2338`;`ui/desktop/App.tsx:340-342,1988-1993,2009-2020`

---

### 坑 4 「面板显示的初值是假读数」

- **症状**:字幕面板一打开就显示「位置 100」,而画面上次字幕明明顶在最上面。
- **真因**:核层没有回读命令,前端只能自己记一份初值,而那份初值是**猜的**。`secondary-sub-pos` 的 mpv 真默认是 `0`(顶),前端曾写死 100。
- **现在怎么处理**:所有初值对齐 2026-07-16 ctypes 实测值(`ui/desktop/App.tsx:334-337`):`sub-scale=1` / `sub-pos=100` / `sub-font=sans-serif` / `secondary-sub-pos=0` / `secondary-sub-ass-override=strip`。注释:「初值和 mpv 真实值对不上 = 面板显示的是假读数,用户还没动就已经在骗他」。
- **Go 侧怎么落**:**给每个可调项配一个 getter**。前端记副本是不得已,不是设计。核层能读就别让前端猜。
- **出处**:`ui/desktop/App.tsx:334-348`

---

### 坑 5 「弹幕文本能吃掉整行」

- **症状**:某一条弹幕之后的所有弹幕消失。
- **真因**:弹幕正文是用户输入。一个 `{` 会被 libass 当成覆盖标签块的开括号,一直吃到下一个 `}`;一个换行会直接截断 `Dialogue` 行。
- **现在怎么处理**:生成前逐字符替换 `{`→`(`、`}`→`)`、`\`→`/`、CR/LF→空格。测试断言「两条弹幕都要在,不能被吃掉」+「用户的 `{` 必须被中和」。
- **Go 侧怎么落**:一模一样,而且**必须在算宽度之前做**(转义会改变字符数,见 1.6 那个 `-463`)。
- **出处**:`[已删] ass.rs:88-102,133,164,291-302`

---

### 坑 6 「整片弹幕红蓝互换」

- **症状**:颜色明明有,但红的显示成蓝的。因为「看起来有颜色」,极难发现。
- **真因**:ASS 颜色是 **BGR** 序,不是 RGB。
- **现在怎么处理**:生成侧 `format!("&H{b:02X}{g:02X}{r:02X}&")`,解析侧反向;两侧都有测试钉死具体值。
- **Go 侧怎么落**:写一对互逆函数并配往返测试(`rgb → ass → rgb == rgb`)。别只测单向。
- **出处**:`[已删] ass.rs:104-109,282-289`;`crates/core/src/danmaku/local.rs:269-278,449,458,468,483`

---

### 坑 7 「每个 ASS 文件都报『JSON 解析失败』」

- **症状**:导入本地 `.ass` 弹幕,报的错误是 JSON 相关的。
- **真因**:格式嗅探按首字符判,而 **ASS 以 `[Script Info]` 开头,首字符也是 `[`**,和 JSON 数组撞了。
- **现在怎么处理**:ASS 判定**必须先于** JSON(`crates/core/src/danmaku/local.rs:26-42`),判据是 `[Script Info]` 前缀或含 `[Events]` 或含 `Dialogue:`。注释原文:
  > 注意 ASS 以 `[Script Info]` 开头,首字符也是 `[` —— 必须先于 JSON 判定,否则每个 ASS 都会被当 JSON 喂给 serde 然后报「JSON 解析失败」。
- **Go 侧怎么落**:嗅探顺序是契约,写成有序的判定链而不是 `switch` 首字节。测试 `local.rs:505-520` 已把顺序钉死(还顺带钉住「扩展名骗人也照样认对内容」)。
- **出处**:`crates/core/src/danmaku/local.rs:26-42,505-520`

---

### 坑 8 「XML 和 JSON 的颜色下标不一样」

- **症状**:导入 B站 XML 正常,导入弹弹Play JSON 后弹幕全是白色(或反之)。不崩、不报错。
- **真因**:两家的 `p` 字段布局不同:
  - B站 XML:`time,mode,fontsize,color,timestamp,pool,userhash,rowid` → **color 在 index 3**(index 2 是字号)
  - 弹弹Play JSON:`time,mode,color,uid` → **color 在 index 2**,只有 4 段、无字号
- **现在怎么处理**:两个解析函数各自取各自的下标,注释互相点名(`crates/core/src/danmaku/local.rs:154`「与弹弹Play JSON 的 p 下标不同,别抄串」;`local.rs:198`「弹弹Play p 只有 4 段且无字号:color 在 index2(XML 是 index3)」)。两条测试各自断言(`local.rs:327`、`local.rs:387`),后者的注释说明了误抄的后果:「若按 XML 的 index3 取会拿到 `user_a` → 全退白色」。
- **Go 侧怎么落**:别抽公共的 `parseP()`。两种格式的 `p` 是**同名不同义**的字段,合并就是给自己埋雷。
- **出处**:`crates/core/src/danmaku/local.rs:151-161,195-208,327,387`

---

### 坑 9 「加载成功但一条弹幕都没有」

- **症状**:导入弹幕文件提示成功,面板里 0 条,无从排查。
- **真因**:解析函数在一条都没解出来时返回**空 Vec** 而不是 `Err`。
- **现在怎么处理**:`crates/core/src/danmaku/local.rs:3-5` 定为红线:
  > 红线:整个文件解析不出东西必须 Err —— 返回空 Vec 会让用户看到「加载成功但一条弹幕没有」且无从排查。单条畸形跳过是对的,整体失败装成功不是。

  三个解析器各自在末尾判空返回 `Err`(`local.rs:163-165`、`local.rs:210-212`、`local.rs:298-300`),错误信息点名格式。
  测试逐条钉死(`local.rs:367-371`、`local.rs:417-421`、`local.rs:499-501`),其中 `local.rs:420` 专门断言「空列表该 Err 而非空 Vec」。
- **同族的第二条**:单条时间解析不出来时**跳过**,不能默认成 0。`local.rs:147`:「时间取不到就跳过:Dart 会退化成 0 秒,那等于把弹幕全堆在片头 —— 宁可少一条」。
- **Go 侧怎么落**:`(nil, error)` 而不是 `([]T{}, nil)`。Go 里返回空切片 + `nil` error 是很自然的写法,这条要专门盯。
- **出处**:`crates/core/src/danmaku/local.rs:3-5,147,163-165,210-212,229,298-300,367-371,417-421,499-501`

---

### 坑 10 「事件乱序 → 大量弹幕重叠」

- **症状**:弹幕互相压在一起,轨道像没起作用。
- **真因**:弹幕站返回的顺序不保证按时间。而 `pick_lane` 用 `now >= free[i]` 判空闲,`now` 一倒退就把已占用的轨判成空闲。libass 本身能正确播放乱序事件,**所以文件看起来是对的**。
- **现在怎么处理**:生成前强制按 `time` 排序;测试断言输出的三条 `Start` 严格递增。
- **Go 侧怎么落**:排序是**算法前置条件**不是输出美观要求,注释要写清楚,否则后人会以为可以省掉。Go 的 `sort.SliceStable` 即可。
- **出处**:`[已删] ass.rs:125-128,334-345`;`crates/core/src/danmaku/local.rs:301`

---

### 坑 11 「换片后挂到新一集头上的是上一集的弹幕/字幕」

- **症状**:弹幕内容和画面完全对不上,但条数正常——比「没有弹幕」更糟,因为看起来是能用的。
- **真因**:排队中的 `pending` / `pending_danmaku` 没在换片时清掉,漏到了下一个文件。
- **现在怎么处理**:`load_inner` 里三样一起复位(`crates/mpv/src/lib.rs:1575-1580`):`loaded=false`、`pending.clear()`、`pending_seek=None`。弹幕版还额外要清 sid(旧 sid 随旧文件作废,不清账下次 `sub-remove` 会打到新文件的某条真字幕上)。
- **反向验证**:被删的那条 `#[ignore]` 测试专门写了这一段(`git show 108965f6` 的删除块),它的注释还提醒了**测试本身的时序陷阱**:
  > (注意第二段的时序 —— 必须在弹幕**还在队列里**时换片,否则测不出任何东西。)

  这正是项目记忆 [[test-must-fail-first]] 里「断言的时序让 bug 没机会发生」那一类假绿。
- **Go 侧怎么落**:换片是一次**状态机复位**,把所有跨文件状态收进一个 struct 一起 `= zero`,别散在各处逐个清。
- **出处**:`crates/mpv/src/lib.rs:1565-1580`;`git show 108965f6 -- crates/mpv/src/lib.rs`

---

### 坑 12 「弹幕层每秒 60 次空转」

- **症状**:暂停看字幕、关掉弹幕之后,GPU/CPU 占用不降。
- **真因**:rAF 循环无条件 `clearRect` + 重画,即使这一帧和上一帧逐像素相同。
- **现在怎么处理**:三道短路(`ui/shared/Danmaku.tsx:67-99`):
  1. `drawnAt` 记上一帧画的时间点,时间没走且尺寸没变 → **整帧跳过**(连 `clearRect` 都省)。注释:「暂停看字幕/挑选集时弹幕层就不该再占 GPU」。
  2. 关闭/无弹幕时只 `clearRect` 一次(哨兵值 `-2`),不一遍遍清。
  3. `dpr` 封顶 2(`Danmaku.tsx:56-59`),注释:「4K 屏上 dpr 常是 2.5~3,不封顶就是按 3 倍分辨率画,比封顶后贵一倍多。文字本来就带描边,2 倍已经看不出锯齿」。
  另有两处热路径优化:`ResizeObserver` 代替每帧 `getBoundingClientRect`(`Danmaku.tsx:51-52`,避免 layout thrash);原地压缩数组代替 `filter`(`Danmaku.tsx:143-144`,「每秒 60 次、弹幕密时上百个元素的热路径」)。
- **Go 侧怎么落**:不适用(渲染在前端)。但若 Go 侧要做服务端渲染或 ASS 增量生成,「相同输入不重算」这条同样成立。
- **出处**:`ui/shared/Danmaku.tsx:51-59,67-99,143-144`

---

### 坑 13 「屏蔽词设了没反应」——实为从未接线

- **症状**:核层有屏蔽词/黑名单/类型过滤,UI 文案也说「在设置里改」,但没有任何入口。
- **真因**:两端调用点都硬传 `defaultDanmakuFilter()`(三个数组恒空),设置页只做了弹幕**源**管理。
- **现在怎么处理**:**没有处理**。这是当前的真实状态。
- **Go 侧怎么落**:迁移时对每个参数问一句「调用方传的是什么」。核层单测再绿也照不到这种断口——同 [[regex-filters-frontend-wiring]]:「核层单测全绿照不到,只有 CDP 真渲染断言 invoke 参数才抓得到」。
- **出处**:`ui/shared/api.ts:556-563,1765-1771`;`ui/desktop/App.tsx:532`;`ui/mobile/pages/PlayerPage.tsx:276,1198`;`ui/desktop/pages/SettingsPage.tsx:874-929`;`ui/mobile/pages/SettingsPage.tsx:507-698`

---

### 坑 13b ⭐ 「弹弹play 搜不到弹幕」——界面在撒谎(复发三次)

- **症状**:播放器说「未找到匹配的弹幕」。用户以为是片名对不上。
- **真因**:弹弹Play **从不用 HTTP 状态码报错**,一律 `200 + body.errorCode`。真实情况是 `429 已达到接口调用配额上限`,而我们不看这个字段 → `animes` 键不存在 → 解析成空表 → 界面说「未找到」。
- **这个 bug 在三个不同抽象层各复发了一次**:
  1. **2026-08-01**:`get_json` 根本不看 `errorCode`。修:加 `check_api_error`(`mod.rs:311-323`)。
  2. **2026-08-02**:`match_one` 判据是「两路都失败才报错」,而实测常态是 `/search` 429 + `/match` 正常回空(**两者配额分开**)→ 半失败被吞。修:改成「零候选 且 任一路失败」(`mod.rs:872-883`)。
  3. **同期**:宿主的 `danmaku_auto_load` 用 `Ok(None)` 盖住了 `match_all` 的 `Err`。修:`?` 直接往上抛(`apps/desktop/src/lib.rs:3419-3421`)。
- **现在怎么处理**:三层各有一道判据 + 一条测试(`mod.rs:2006` 纯逻辑、`mod.rs:1670` 起真 TCP 假上游)。
- **Go 侧怎么落**:见 6.6.1 的三态表。`(nil, nil)` 和 `(nil, err)` 是两个不同的答案。**这是整条弹幕链路上最值得警惕的一个形状。**
- **出处**:`crates/core/src/danmaku/mod.rs:303-310,311-323,835-840,872-883,1659-1721,2001-2018`;`apps/desktop/src/lib.rs:3419-3421`

---

### 坑 13c 「配额老是被刷完」——我们自己烧掉的四份

- **症状**:官方弹弹Play 接口整天回 429。
- **真因**(2026-08-02 排查,四条独立):
  1. **`is_anime` 写了却没有任何宿主调用过**——`danmaku_sources(state, allow_official)` 三处调用点全是写死的 `true`。播欧美剧/综艺/纪录片一样打一整轮(`/match` + 最多 4 次 `/search/episodes`),而这些内容弹弹Play 根本不收录(`mod.rs:762-766`)。
  2. autoLoad 之后又重复 match 一轮(项目记忆 `dandan-quota-drain`)。
  3. 搜索**零限流**——用户可以按住搜索键连点。
  4. `/match` 的 `fileHash` 传空串 → `errorCode 2` → 这条路**从接进来那天起就没通过一次**,每次调用都是纯浪费(`mod.rs:474-475`)。
  5. 最根本的一条:**AppSecret 在发行包里可提取**,外人拿去用,客户端限流对他不存在。
- **现在怎么处理**:
  - ① 修在 `allow_official_for`(`mod.rs:775-777`)+ 宿主真正调它(`lib.rs:3377`)+ **两端各一条读源码的契约测试**(3.8);
  - ③ 修在 `search_gate`(`mod.rs:807-810`),5 秒窗口,**只拦会打到官方源的请求**;
  - ④ 修在 `normalized_file_hash`(`mod.rs:481-489`),给确定性占位 hash;
  - ⑤ 修在**服务端代理**(3.7)——把签名整个挪走,加出站闸门。这是唯一拦得住外人的位置。
- **Go 侧怎么落**:
  - 门控函数写完必须配一条「有人调它」的测试(源码级断言或 mock 调用计数);
  - 「不知道」和「确信不是」必须分开——`allow_official_for` 的空表放行语义不能写反(`mod.rs:768-771`:写反会让所有没刮削的库弹幕**静默死掉**,「用户只会看见弹幕突然不出来,查都没处查」);
  - 任何「客户端限流」都只是礼貌,不是防线。
- **出处**:`crates/core/src/danmaku/mod.rs:467-489,760-777,779-810,1620-1633,1982-1999`;`apps/desktop/src/lib.rs:3233-3239,3373-3377`;`apps/android/src/lib.rs:5246-5266`;`crates/danmaku-proxy/src/main.rs:3-10`

---

### 坑 13d 「第二季的片配上了第一季的弹幕」

- **症状**:弹幕全篇对不上,但条数正常。**不报错**,看起来像「弹幕匹配得不准」。
- **真因**:标题相似度这一路**分不开季**——「孤独摇滚」和「孤独摇滚 第二季」在剥掉季号后是同一个串,分数完全一样。
- **现在怎么处理**:季号提成**独立的一路硬信号**(`season_of` / `season_term`,`mod.rs:1159-1213`),对季 +0.15、错季 **-0.35**、不知道 0。
- **最容易写错的一点**:想要的季号必须**优先取标题自己带的**,`season_of(input.title).or(input.season_no)`。因为媒体库有两种摆法(`mod.rs:1198-1202`),摆法 B(每季各一个条目)下 `season_no` 恒为 1,只认它会把正确的候选判成错季**直接压死**。
- **Go 侧怎么落**:照抄那个 `.or()` 的优先级。测试 `mod.rs:1924-1946` 把两种摆法都钉住了,原样翻译。
- **出处**:`crates/core/src/danmaku/mod.rs:1149-1213,1920-1946`

---

### 坑 13e 「一个字之差的标题匹配不上」

- **症状**:「葬送的芙莉莲」匹配不到「葬送之芙莉莲」;`ＳＰＹ×ＦＡＭＩＬＹ` 匹配不到 `SPY×FAMILY`。
- **真因**:旧算法是**字符二元组 Jaccard ×0.6**,三个结构性缺陷(`mod.rs:1044-1053`):
  1. 天花板就是 0.6,而自动挂载门槛是 0.5 → 「差一个字」和「毫不相干」挤在同一个窄区间;
  2. 不做任何字形折叠 → 全角/片假名/大小写/标点全算不同字符,分数直接 0;
  3. 包含关系一律 0.7 不看长度 → 「刀」在「刀剑神域」里和「赛马娘」在「赛马娘 Pretty Derby」里同分。
- **现在怎么处理**:换成 **归一化折叠 + Levenshtein 比率 + 长度加权的包含下限**(口径来自 bangumi2anibt 的 `matcher.c`)。实测:一字之差从「≤0.6」变成 **0.86 对 0.1**。
- **Go 侧怎么落**:`fold` 的四段码点区间一段都不能漏(3.4 的表);Levenshtein **必须对 `[]rune` 做**,对 `string` 按字节做会把中文拆成 3 个编辑单位(见 6.6.3)。
- **出处**:`crates/core/src/danmaku/mod.rs:1038-1147,1896-1918`

---

### 坑 13f 「跨语种一路 0 分:候选捞回来了却被自己的评分扔掉」

- **症状**:库里是中文名而弹弹Play 收录的是日文名(或反过来)时,搜索**明明搜到了**,却因为分数不够门槛而不自动挂。
- **真因**:弹弹Play 的条目**只有一个标题,没有别名表**,所以平行语料只能由我们这边给——媒体库同时握着中文名、原名和发布文件名。
- **现在怎么处理**:`MatchInput.alt_titles`(`mod.rs:693-699`),`title_score` 拿**所有写法**去比取 max(`mod.rs:1237-1243`)。前端负责装载(`ui/mobile/pages/PlayerPage.tsx:266`:`[fileName, item.name]` 去掉与 title 重复的)。
- **Go 侧怎么落**:`title_score` 的 `chain` 不能省。测试 `mod.rs:1952-1962` 有一条容易漏的断言:**加了 alt_titles 之后主标题这一路不能变差**(取 max 而不是取平均)。
- **出处**:`crates/core/src/danmaku/mod.rs:693-699,1231-1243,1948-1962`;`ui/shared/api.ts:536-540`

---

### 坑 13g 「`/match` 这条路从接进来那天起就没通过一次」

- **症状**:文件识别永远回 0 条,且**完全无声**(HTTP 200 + `matches:[]`,和「这个文件真的没匹配上」长得一模一样)。
- **真因**:`fileHash` 传空串 → 服务端判 `errorCode:2 一个或多个参数不符合规则` → 整个响应作废。
- **A/B 实测**(`mod.rs:470-473`,同一文件名、同一签名):`fileHash:""` → 0 条;`fileHash:"000...0"`(32 位)→ **25 条,第一条就是对的**。而 `matchMode` 给不给、给哪个值,结果一模一样——**决定成败的只有 hash 的形状**。
- **现在怎么处理**:`normalized_file_hash`(`mod.rs:481-489`)给 `md5(file_name)` 作占位——形状合法、跨会话稳定、撞真 hash 概率 2^-128,服务端退化成按文件名匹配。真 hash 原样透传。
- **配套的第二个坑**:`file_name` 必须是**真实发布文件名**不是条目名。喂「第 35 集」整条路白跑(`ui/shared/api.ts:544-546`,注释写「实测返回的第一名是完全无关的片」)。
- **Go 侧怎么落**:形状校验 = 长度 32 且全是 hex(`mod.rs:483`),不合形状一律当没给。别只判空串。
- **出处**:`crates/core/src/danmaku/mod.rs:433-489,1982-1999`;`ui/mobile/pages/PlayerPage.tsx:257-263`

---

### 坑 13h 「上游回空/回错误页,把用户这一集的弹幕永久清零」(代理侧)

- **症状**:自托管弹幕库里某一集的弹幕突然变成 0 条,再也回不来。
- **真因**:合并写成了**替换**。而我们是这份弹幕的**最后一份拷贝**——上游偶尔回空列表、回错误页、连接被截断,替换的写法当场把历史毁掉。
- **现在怎么处理**:`merge_comments`(`crates/danmaku-proxy/src/store.rs:212-236`)按 `cid` 求并集,且加了一道保命闸(`store.rs:220-223`):上游解不出内容而我们有存量 → **原样返回存量**。
- **Go 侧怎么落**:任何「我们是最后一份拷贝」的存储,写入路径必须是 merge 不是 replace,并且**解析失败要走保守分支**。测试 `store.rs:275-293` 三种坏输入(部分重叠 / 空列表 / 非 JSON)都钉住了。
- **出处**:`crates/danmaku-proxy/src/store.rs:3-8,126-128,212-236,271-293`

---

### 坑 13i 「缓存淘汰把刚写进去的热数据删了」(代理侧,单测抓到的真 bug)

- **症状**:缓存命中率异常低,刚写入的条目下一秒就没了。
- **真因**:`evict` 自己读系统时钟,而 `get`/`put` 收的是参数里的 `now`——**两个时钟源**。一旦不同步,全部条目被判「已过期」→ 排序键全相等 → 退化成按 HashMap 遍历顺序乱删。
- **现在怎么处理**:`now` 一律由调用方传入(`crates/danmaku-proxy/src/cache.rs:143-148`)。
- **Go 侧怎么落**:同一条逻辑链上的时间必须是**同一个参数**传下去,不要在下层随手 `time.Now()`。Go 里这个诱惑更大(`time.Now()` 无需引入任何东西)。
- **出处**:`crates/danmaku-proxy/src/cache.rs:141-164`;`7a83ae32` 提交 message

---

### 坑 14 「安卓上次字幕的三个旋钮是死的」(潜伏)

- **症状**:尚未暴露(手机端还没接双字幕面板)。
- **真因**:安卓 libmpv 是 **v0.36**,不含 `secondary-sub-ass-override` / `secondary-sub-delay` / `secondary-sub-pos` 三个属性;而 `set_str` 丢掉 `mpv_set_property_string` 的返回值,`-8 property not found` 被完全吞掉。
- **现在怎么处理**:未处理。命令已注册(`apps/android/src/lib.rs:3295-3311,4886-4887`),前端尚未调用。
- **Go 侧怎么落**:① 检查 `set_property` 返回值并记日志;② 启动时读一次 `property-list` 建集合,设之前先判存在。两条都是几行的事,能把整类「静默失效」变成日志里一行。
- **出处**:`crates/mpv/src/lib.rs:1466-1470,1893-1898,1863-1868`;`apps/android/src/lib.rs:3295-3311`;实测差分见 4.6

---

### 坑 15 「用二进制字符串查 mpv 选项存不存在」——方法本身不可靠

- **症状**:得出「某个 mpv 选项在这个 build 里不存在」的错误结论。
- **真因**:mpv 的**样式类选项是「前缀 + 后缀」在运行时拼出来的**,二进制里只有后缀(`font`、`font-size`、`fonts-dir`、`back-color`…),没有全名。
- **反证(我实测的)**:`sub-font-size` 全名在 Windows libmpv-2.dll 里出现 **0 次**,而它被 ctypes `property-list` 证实**真实存在**。
- **什么时候还能用**:非前缀拼接的属性(如 `secondary-*` 那一族)全名直接出现,差分有效——4.6 那张表就是这么来的。
- **正确做法**:`mpv_get_property_string(h, "property-list")` 拉权威清单(方法见 `mpv-subtitle-property-truths.md`,不需要 mpv.exe,ctypes 直接 `CDLL` 就能问)。
- **Go 侧怎么落**:同样用 `property-list`。Go 里用 cgo 或 `purego` 调 `mpv_get_property_string` 即可。
- **出处**:本次实测;`crates/mpv/src/lib.rs:1850`(ctypes 实测的来源标注)

---

### 坑 16 「安卓文本字幕整段空白」

- **症状**:选了字幕轨,`sid` 也设上了,画面上一个字都没有。位图字幕(PGS)正常。
- **真因**:Android 没有 fontconfig,libass 找不到任何字体。
- **现在怎么处理**:`crates/mpv/src/lib.rs:1266` 设 `sub-fonts-dir=/system/fonts`;`crates/mpv/src/lib.rs:1843` 挡掉 UI 占位串 `"默认"`(否则 libass 去找一个叫「默认」的字体族)。
- **我核实到的**:安卓这颗 libmpv(**v0.36**)确实**没有 fontconfig**(`FcInit` / `FONTCONFIG_FILE` 均 0 次,Windows 版分别是 2 / 1 次)。这条前提为真。
- **未确认**:`sub-fonts-dir` 在 v0.36 上认不认。查全名的字符串法对这一族无效(坑 15),必须真机回读定论。旧记忆里「该选项不存在」的结论用的正是被证伪的那个方法。
- **Go 侧怎么落**:安卓字体这一步**设完必须回读确认**,不能设了就走。
- **出处**:`crates/mpv/src/lib.rs:1262-1266,1841-1847`;本次二进制差分实测

---

### 坑 17 「弹幕/字幕类型分家两份」

- **症状**:同名类型在两个文件各定义一份,把同一份数据同时喂给两个消费者时当场编译错。
- **真因**:渲染组件只用到前四个字段,于是有人给它另写了个窄版本。
- **现在怎么处理**:`ui/shared/Danmaku.tsx:6` 直接 `export type { DanmakuComment } from "@shared/api";` 转出核层契约那份。注释:「渲染只用到前四个字段,但类型别再分家」。
- **Go 侧怎么落**:核层契约类型只有一个定义点。Go 里没有 TS 那种结构类型,分家会更早炸——但也更容易被「反正字段够用」的心态诱导去定义局部 struct。
- **出处**:`ui/shared/Danmaku.tsx:3-7`

---

## 6. Go 侧移植要点

### 6.1 优先级判断

| 模块 | 现状 | Go 侧建议 |
|---|---|---|
| ASS **生成**(`ass.rs`) | 已删除 | **不要默认重建**。它当初存在只为治坑 1,而坑 1 已在 Canvas 侧真正修好。除非要做「弹幕进截图/录制」或服务端渲染,否则重建等于重新引入「弹幕和双语字幕互斥」。若要建,照第 1、2 节 1:1 抄,含那 10 个测试。 |
| ASS **解析**(`local.rs` / `translation.rs`) | 在用,两份 | **必须迁**。可以合并成一份吗?——`local.rs:252-254` 已经明确说过「stdlib 够用,不抄那个私有函数」,两份的差异是有意的(见 1.4 时间解析对比表)。Go 侧建议保留两份,或合并后用两套测试同时钉住两种错误语义。 |
| 弹幕管线(`mod.rs`) | 在用 | **必须迁**,见 6.6 |
| mpv 封装(`crates/mpv`) | 在用 | 见 6.3 |
| 弹幕代理(`danmaku-proxy`) | 独立服务 | 见 6.7。**可以最后迁,甚至可以不迁**——它和客户端零代码依赖 |

### 6.2 ASS 生成器的 Go 骨架

如果要重建,签名照抄即可(纯函数、无 IO、易测):

```go
type ASSOptions struct {
    PlayResX, PlayResY int     // 1920, 1080
    Font               string  // "Microsoft YaHei"
    FontSize           int     // 48 —— PlayRes 单位不是 px
    Opacity            uint8   // 0~100
    AreaPercent        uint8   // 25/50/75/100,内部 clamp(10,100)
    ScrollSecs         float64 // 8.0,内部 max(0.5)
    FixedSecs          float64 // 5.0
    Outline            float64 // 2.0
    Bold               bool    // → Style 里写 -1/0,不是 1/0
}

func ToASS(comments []DanmakuComment, o ASSOptions) string
```

九条不能省的实现细节(每条都有测试对应):

1. 先按 `time` **稳定排序**(坑 10)
2. `escape()` **在** `estWidth()` **之前**(1.6 的 `-463`)
3. 空文本 `continue`(2.7)
4. 颜色 BGR + alpha 反向(1.3)
5. `Bold` 写 `-1`/`0`(1.2 #8)
6. 时间戳**百分秒**,小时不补零,负数夹 0(1.4)
7. 滚动用 `\move` 且终点 x **必须为负**(1.5.1)
8. 顶/底/滚动**三张独立轨道表**(1.6 观察 1)
9. `free[best] = max(free[best], busyUntil)`——修掉 2.4 那个怪癖

Go 的 `strings.Builder` 对应 Rust 的 `String::with_capacity`;`fmt.Sprintf("&H%02X%02X%02X&", b, g, r)` 对应 `format!`。
`{:.0}` → `strconv.FormatFloat(v, 'f', 0, 64)`,**注意 Rust 的 `{:.0}` 是四舍五入到偶数(banker's)还是就近?** —— 实测 `67.2 → 67`、`463.2 → 463` 两个样本都不足以区分,Go 的 `%.0f` 用的是就近舍入到偶数,与 Rust 的 `{:.0}` 行为一致(两者都遵循 IEEE 754 roundTiesToEven)。差 1 像素不影响观感,但要知道这里有个口径。

### 6.3 mpv 封装的 Go 侧四条

1. **`set_property` 的返回值必须检查。** 现在整个 `set_str` 把它丢了(`crates/mpv/src/lib.rs:1466-1470`),坑 14 / 坑 16 的「静默」全来自这里。
2. **启动时拉一次 `property-list` 建集合。** 属性集跨平台跨版本会差(4.6 实测:安卓 v0.36 少三个 `secondary-*`)。
3. **异步 `loadfile` 的排队模式要通用化。** 现在 `SubState` 同时管字幕 `pending` 和 `pending_seek`,说明这不是字幕专属。Go 侧建议做成一个 `pendingOps []func(ctx)`,`FILE_LOADED` 时一次性 drain。
4. **事件 goroutine 必须被 `Close()` 等到。** 对应 Rust 的 `running=false → join → mpv_terminate_destroy` 三步(`crates/mpv/src/lib.rs:1404-1410`)。Go 里 `context.CancelFunc` + `WaitGroup.Wait()` 再 `mpv_terminate_destroy`。

### 6.4 正则:Go 天然对齐

`crates/core/src/media.rs:10-13` 记录了 Rust regex 与 JS RegExp 的差异(无前后瞻/反向引用)以及由此产生的「JS 校验放过、Rust 编译不过、设了没反应」故障。
**Go 的 `regexp` 也是 RE2,限制完全相同**,所以这条口径迁过去零成本:校验必须走 Go 侧,不能走浏览器。

### 6.5 一条口径确认

「弹幕的**显示速度 / 字体大小 / 不透明度 / 显示区域**是前端渲染参数,核层不管。」

出处:`ui/shared/Danmaku.tsx:19-21`(「核层 danmaku_filter 只管过滤/去重,文档里写明渲染归前端,所以调节点在这儿,不是缺核层命令」)、`ui/desktop/App.tsx:151-157`(「这五项**全是前端渲染参数** … Rust 侧从头到尾用不到它们 … 已 grep 确认」)。

持久化在 `localStorage`(`ui/desktop/App.tsx:158` `DM_KEY = "player:danmaku"`),**故意不进核层 Prefs**。
但注意 `ui/desktop/App.tsx:157` 的补充:「★ 但『用不到』不等于『可以不存』:换片会重建整个播放器状态,不落盘就每集都要重调。」

**Go 侧要点**:别为这五项在 Go 的 config 里加字段。但如果重建 ASS 生成路,`AssOptions` 里的 `font_size` / `opacity` / `area_percent` / `scroll_secs` 就**必须**跨语言传进来——那时它们才第一次成为核层的输入。

### 6.6 弹幕管线的 Go 侧对照

| Rust | Go | 注意 |
|---|---|---|
| `tokio::task::JoinSet` + `slots[i]` 归位(`mod.rs:646-669`) | `errgroup` 或裸 `sync.WaitGroup` + `results := make([]T, len(cfgs))`,**按下标写**不要 append | 下标写入天然免锁且保序;`append` 到共享切片既要锁又会乱序 |
| `tokio::join!(a, b)`(`mod.rs:857`) | 两个 goroutine + `WaitGroup`,或 `errgroup.Go` ×2 | — |
| `reqwest::Client` clone 共享连接池 | `*http.Client` 直接共用(本身并发安全) | Go 更简单,但**必须设 `Timeout`**——见项目记忆 `prefetch-fetch-needs-idle-timeout`,那次三个 client 一个 timeout 都没设 |
| `Result<T, String>` | `(T, error)` | ⚠️ 见 6.6.1 |
| `OnceLock<Regex>` | `regexp.MustCompile` 包级变量 | Go 的 `regexp` 是 RE2,与 Rust `regex` 同源同限制 |
| `Mutex<Vec<(String, Vec<C>)>>` LRU | `container/list` + `map`,或直接 `[]entry` 线性扫 | 40 条上限下线性扫足够,别上依赖 |
| `md5::Md5` | `crypto/md5` | — |
| `Sha256` + `base64::STANDARD` | `crypto/sha256` + `encoding/base64.StdEncoding` | 签名向量:`base64(sha256("appid0/api/v2/xsecret"))`,两边必须一致 |
| `serde_json::Value` 松散取字段 | `map[string]any` 或 `json.RawMessage` | 弹弹Play 的 id 有时是数字有时是字符串(`mod.rs:492-497` 的 `str_of`),Go 里建议用 `json.Number` 或自定义 `UnmarshalJSON` |
| `#[serde(default)]` 在容器上 | Go 的零值天然就是这个行为 | 但 `count` 的默认值是 **1 不是 0**(`mod.rs:51`),必须自定义 `UnmarshalJSON` 或后处理 |
| `f64::max` 折叠 | `math.Max` | — |

#### 6.6.1 三态语义必须保住

这是本仓库在弹幕链路上**复发过三次**的同一个 bug(3.3):

```go
// 错:把两种答案压成一种
func matchAll(...) ([]Candidate, error) {
    ...
    return candidates, nil   // ← 候选空 + 有源报错时,调用方以为是「没搜到」
}
```

Go 的惯例 `(nil, nil)` 表示「没有,也没出错」,这在这条链路上是**一个必须显式区分的第三态**:

| 状态 | 语义 | 界面该说 |
|---|---|---|
| `(结果, nil)` | 搜到了 | 显示弹幕 |
| `(nil, nil)` | 搜过了,确实没有 | 「这一集没有匹配到弹幕」 |
| `(nil, err)` | **没搜成**(配额/源挂了/签名错) | 把 `err` 原样显示给用户 |

判据照 `mod.rs:837`:**结果为空 且 有任何一路报错 → 返回 err**。不是「所有路都报错」。

`danmaku_auto_load` 那一层则是 `(*[]Comment, error)`:`nil` 指针 = 没有够格的匹配(不是错误),`error` = 打不通(`apps/desktop/src/lib.rs:3419-3420`)。

#### 6.6.2 必须原样搬过去的常量

| 常量 | 值 | 出处 | 改了会怎样 |
|---|---|---|---|
| `MIN_AUTO_SCORE` | `0.5` | `mod.rs:718` | 调高 = 大量番不自动挂;调低 = 错配弹幕上屏 |
| 文件识别唯一命中分 | `1.6` | `mod.rs:989` | 必须 > 名字搜索满分 1.45 |
| 名字搜索集号命中加成 | `0.3` | `mod.rs:955` | — |
| 文件识别固定加成 | `0.2` | `mod.rs:992` | — |
| 季号对/错 | `+0.15` / `-0.35` | `mod.rs:1209,1211` | 错季扣分必须够狠,否则第二季配第一季弹幕 |
| 包含下限 | `0.6 + 0.4×(短/长)` | `mod.rs:1143` | 换回固定 0.7 = 退回旧算法的第 3 条毛病 |
| 召回写法最短长度 | `3` 字 | `mod.rs:914` | — |
| `MAX_TITLE_CHARS` | `128` | `mod.rs:1086` | — |
| `SEARCH_MIN_INTERVAL` | `5s` | `mod.rs:782` | 用户点名的数 |
| `MEM_CAPACITY` / `TTL_SECS` | `40` / `7天` | `mod.rs:1249-1250` | — |
| `fold` 的四段码点区间 | 见 3.4 | `mod.rs:1063-1083` | 漏一段 = 那类字形折不掉 → 分数打到 0 |

#### 6.6.3 Go 侧比 Rust 好写的两处

1. **`fold` 的全角递归**(`mod.rs:1075`)在 Go 里同样一行:`return fold(r - 0xFEE0)`;`unicode.ToLower` 直接可用。
2. **Levenshtein** 两行 DP(`mod.rs:1105-1120`)照抄即可,`[]rune` 对应 `Vec<char>`。⚠️ Go 里**一定要转 `[]rune`**,直接对 `string` 按字节做会把每个中文字拆成 3 个编辑距离单位,相似度全错而且不报错。

### 6.7 弹幕代理的 Go 侧对照

这个 crate 是整个仓库里**最适合迁 Go 的一块**(纯 HTTP 服务、无 FFI、无平台代码):

| Rust | Go |
|---|---|
| `axum` Router + `State<Shared>` | `net/http` + `http.ServeMux`(Go 1.22 起支持 `GET /path/{id}` 模式),状态放闭包捕获 |
| `tokio::main` + `axum::serve` + `with_graceful_shutdown` | `http.Server.Shutdown(ctx)` + `signal.NotifyContext` |
| `reqwest::Client`(rustls) | `http.Client`(Go 自带 TLS,**镜像更小**——Rust 那边选 rustls 就是为了这个,`Cargo.toml:19`) |
| `Mutex<HashMap>` | `sync.Mutex` + `map`,或 `sync.Map` |
| `RwLock<Config>` 热更新(`config.rs:69`) | `atomic.Pointer[Config]`,读侧零锁 |
| `serde(default)` 容忍旧配置(`config.rs:12`) | `encoding/json` 天然忽略未知字段、缺失字段留零值。⚠️ **但零值不是默认值**——必须先填默认结构体再 `Unmarshal` 覆盖,否则 `upstream_per_day` 会变成 0 = 闸门全拒(`config.rs:118-127` 那条测试钉的就是这个) |
| 内嵌 HTML(`admin.rs:62` 的 `PAGE`) | `//go:embed admin.html` |
| `rand` 生成 session token | `crypto/rand`(**不要用 `math/rand`**) |
| 定长比较 `eq_ct`(`admin.rs:36-41`) | `crypto/subtle.ConstantTimeCompare` —— 标准库直接有,比 Rust 那 5 行还省 |

**Go 侧唯一需要额外小心的**:`cache.rs:143-147` 那个「两个时钟源」的 bug 在 Go 里同样容易犯——`evict` 里顺手写个 `time.Now()` 就中招。**`now` 必须是参数**。

---

## 7. 现有测试的价值

### 7.1 `crates/core/src/danmaku/local.rs` —— 14 个测试(当前存在)

| # | 测试名 | 行号 | 钉住的契约 | 反向注入什么会红 |
|---|---|---|---|---|
| 1 | `xml_real_sample` | 320 | B站 XML 的 8 段 `p` 布局,**color 在 index3** | 把 color 改读 index2 → 拿到字号 25 |
| 2 | `xml_escapes_are_decoded` | 336 | 五件套实体 + `&#39;`;且 `&amp;lt;` 不被二次解码 | 去掉 `&#39;` 预处理,或改成循环解码 |
| 3 | `xml_malformed_entries_skipped_not_defaulted` | 346 | 非数字时间**跳过不默认 0**;`<data>` 不被当 `<d>`;自闭合标签跳过后能继续扫 | 时间解析失败改成 `unwrap_or(0.0)` → times 多出一堆 0 |
| 4 | `xml_without_any_d_node_is_err` | 366 | 红线:解析不出必须 `Err` | 末尾改成返回空 `Vec` |
| 5 | `json_real_sample_color_index_differs_from_xml` | 381 | 弹弹Play JSON 的 4 段 `p`,**color 在 index2** | 改读 index3 → 拿到 `"user_a"` → 全退白 |
| 6 | `json_bare_array_and_data_key` | 395 | 三种容器形态:裸数组 / `comments` / `data` | 只认 `comments` |
| 7 | `json_malformed_entries_and_file_level_errors` | 404 | 单条畸形跳过 + 四种文件级 `Err`(含**空列表必须 Err**) | 空列表返回 `Ok(vec![])` |
| 8 | `ass_real_sample` | 442 | ASS 四条:排序 / `\an2`→mode4 / BGR 颜色 / **Text 里的逗号保住** / `\N`→空格 | `splitn(10)` 改成 `split(',')` → 逗号那条被切碎 |
| 9 | `ass_override_tags_fully_stripped` | 463 | `\pos` `\fad` `\fs` `\r` 全剥掉,只 `\c` 被单独抓出 | 去掉 `{[^}]*}` 正则 |
| 10 | `ass_alpha_color_and_malformed_lines` | 472 | 8 位 `AABBGGRR` 丢 alpha;畸形时间跳过;字段不足跳过;纯标签行(剥完为空)跳过;**`Comment:` 行不算弹幕** | 前缀判断改成 `contains("Dialogue")` → `Comment:` 那行被吃进来 |
| 11 | `ass_time_forms` | 487 | 7 种时间形态,含 **`.5` = 500ms 不是 5ms**;`bad`/`0:00`/`x:00:01.00` → `None` | 小数解析改成 `parse::<u64>() * 10` |
| 12 | `ass_no_dialogue_is_err` | 498 | 只有头没有 `Dialogue:` 必须 `Err` | 同 #4 |
| 13 | `sniff_by_content_not_extension` | 505 | **ASS 判定先于 JSON**;扩展名骗人也认对内容;无后缀也行 | 把 ASS 分支挪到 JSON 之后 → `sniff(ASS)` 变 `Json` |
| 14 | `parse_empty_and_unknown_are_err` | 522 | 空/全空白/不可识别必须 `Err`;错误信息**要点名格式** | 空文件返回 `Ok(vec![])` |

**价值评估**:这 14 个是**高价值**测试,几乎每一个都对应一次真实故障(测试注释里直接写着后果)。Go 侧应当先把这 14 个翻译成 Go 表驱动测试,再写实现——它们就是规格说明。

### 7.2 `[已删] ass.rs` —— 10 个测试(已随文件删除,可从 git 取回)

| # | 测试名 | 行号 | 钉住的契约 |
|---|---|---|---|
| 1 | `header_declares_playres_and_style` | 235 | 头部四要素:`PlayResX/Y`、`Style: LP,...`、`[Events]` |
| 2 | `scroll_uses_move_from_right_edge_to_offscreen_left` | 246 | **滚动必须 `\move` 不能 `\pos`**;起点 x=1920;**终点 x 必须为负**;起止时刻 |
| 3 | `fixed_modes_are_centered_and_anchored` | 269 | 顶=`\an8` 底=`\an2`;`\pos(960,` 居中;固定弹幕**不该有 `\move`**;停留 `fixed_secs` |
| 4 | `color_is_bgr_not_rgb` | 284 | 纯红 → `&H0000FF&`,纯蓝 → `&HFF0000&` |
| 5 | `escapes_ass_metacharacters` | 294 | 两条都在(没被吃掉);用户的 `{` 计数被中和为 1;换行→空格 |
| 6 | `area_percent_limits_lane_count` | 306 | 50% 区域的最大 y < 100% 的;且 ≤ `1080*0.5` |
| 7 | `opacity_maps_to_style_alpha` | 325 | 100→`00`、50→`80`、0→`FF` |
| 8 | `events_are_emitted_in_time_order` | 337 | 乱序输入 → 输出 `Start` 严格递增 |
| 9 | `empty_text_is_dropped_not_emitted_blank` | 348 | 全空白那条不出事件 |
| 10 | `timestamps_use_centiseconds` | 354 | 4 种时间,含负数夹 0 |

**价值评估**:这 10 个是**教程级测试**——每一条的注释都解释了「不这么做会怎样」,而不是「这么做是对的」。第 2、4、5、8 四条尤其宝贵,它们钉住的都是「不报错但错」的静默故障。Go 侧若重建生成器,这 10 条应原样翻译。

**没有覆盖的**(第 2 节读出来的):
- `pick_lane` 满轨分支的重叠程度(2.4 那个 `free[best]` 无条件回写的怪癖)
- `est_width` 的 0x1100 判据边界(希腊/西里尔被算成半角是否合理)
- `WrapStyle: 2` 的效果(长弹幕不换行)

### 7.3 `crates/mpv/src/lib.rs` —— 时序测试

| 测试 | 行号 | 类型 | 钉住的契约 |
|---|---|---|---|
| `external_subtitle_survives_async_loadfile` | 2075 | `#[ignore]` 集成 | `loadfile` 后立刻 `add_subtitle`,轮询 `tracks()` 直到出现,断言标题匹配 |
| `SubState::queue_seek` 那条 | 2223+ | 单元 | `loaded=false` 时入队不发;`FILE_LOADED` 后当场发 |
| (已删)`danmaku_sub_queues_until_file_loaded_and_never_leaks_across_files` | — | `#[ignore]` 集成 | 排队路径 + 换片不泄漏,两条反向注入都验过红 |

`crates/mpv/src/lib.rs:2063-2072` 写明了反向验证法:

> 反向验证方式:把 add_subtitle 里的 `if !st.loaded { …排队…; return; }` 删掉(退回成无条件立刻 sub-add),这条测试立刻红。
> 跑:`cargo test -p linplayer-mpv --lib external_subtitle -- --ignored --nocapture`

**价值评估**:`#[ignore]` 意味着它们**不在 CI 里跑**。这是有意的(要真 libmpv + 桌面会话),但也意味着这两条契约在 CI 上是裸奔的。Go 侧同样会面临这个问题:排队逻辑本身可以纯单测(像 `queue_seek` 那条),**只有真正的 `sub-add` 时序需要真机**。建议 Go 侧把排队状态机抽成无 mpv 依赖的纯类型,让 CI 能覆盖 80%。

### 7.4 `crates/core/src/media.rs` —— 选轨测试

`crates/core/src/media.rs:112-190`,覆盖:正则优先于语言(`media.rs:143`)、`sub_enabled=false` → `Some("no")`(`media.rs:147`)、语言兜底(`media.rs:151`)、按声道匹配 `8ch`(`media.rs:187`)。
**Go 侧直接可用**(RE2 语义相同)。

### 7.5 `crates/core/src/danmaku/mod.rs` —— 29 个测试

按主题分组。**「反向注入」一列凡是带 ★ 的,都是代码注释里作者自己写明的反向验证方式**,不是我推的。

#### 配额与限流(2 条,2026-08-02 那轮修复留下的)

| # | 测试名 | 行号 | 钉住的契约 | 反向注入 |
|---|---|---|---|---|
| 1 | `official_source_skipped_only_when_we_know_it_is_not_anime` | 1626 | 是番/英文分类 → 带官方源;确信不是番 → 不带;**空表必须放行** | 把「空表就排除」写进去 → 最后一条断言红 |
| 2 | `search_gate_enforces_min_interval` | 1639 | 5 秒窗口的四个边界 + **放行后要重新计时** | ★ 去掉 `if elapsed < SEARCH_MIN_INTERVAL` |

第 2 条用**注入时钟**而不是 `sleep`(`mod.rs:1636`:「睡 5 秒的测试没人会留着」),且开头/结尾各清一次 static(同进程共享)。

#### errorCode 与半失败(2 条)

| # | 测试名 | 行号 | 钉住的契约 | 反向注入 |
|---|---|---|---|---|
| 3 | `one_failed_path_with_no_candidates_is_reported_not_swallowed` | 1670 | **一路 429 + 零候选必须报错**;报错要带上游原因 | ★ 把 `if by_ep.is_empty()` 改回 `(Err, Err)` 双失败判据 |
| 4 | `api_error_code_is_not_swallowed` | 2006 | 429/2/500 都要报;`errorCode=0` 和**字段不存在**都算成功 | 让 `check_api_error` 恒 `Ok` |

第 3 条是**唯一一条起真 TCP 服务器的测试**(`mod.rs:1669-1721`),理由写在 `mod.rs:1666-1667`:

> 走**真 HTTP**:这条测的是 match_one 里两个 Result 怎么合并,而那正是纯逻辑测不到的地方(要真有一路 Err 一路 Ok 才复现得出来)。

假上游按路径分流:`/search/episodes` → 429,`/match` → `{"errorCode":0,"isMatched":false,"matches":[]}`。**这是真机抓到的常态形态的忠实复刻**。

#### 源配置与鉴权推导(3 条)

| # | 测试名 | 行号 | 钉住的契约 |
|---|---|---|---|
| 5 | `derive_auth_handles_path_token_servers_verbatim` | 1729 | 两个主流自建端的**原样地址**判 `None` 且 URL 不变;尾斜杠要吃掉;省略 token 的写法也认 |
| 6 | `derive_auth_splits_query_token_out_of_url` | 1787 | `?token=` / `?api_key=` 拆出来;**空值不算** |
| 7 | `base_url_and_pathtoken` | 1818 | `https://d.example.com/` → `/api/v2`;PathToken 插成 `/tok123/api/v2` |

第 5 条的用例注释(`mod.rs:1723-1727`)明说地址是从两个自建端 README/源码里抄的原样地址,**不是编的**。

#### 协议解析(4 条)

| # | 测试名 | 行号 | 钉住的契约 |
|---|---|---|---|
| 8 | `parses_both_v2_bangumi_list_and_legacy_animes` | 1754 | 新引擎 `bangumiList` + 老引擎 `animes` 都收;`animeId` 数字转字符串;**条目层不该带集表** |
| 9 | `parses_episodes_from_bangumi_detail` | 1771 | 集表在 `bangumi` **下面一层** |
| 10 | `parse_and_sign` | 1804 | `p` 四段解析 + 签名长度 44 |
| 11 | `match_result_parses_real_payload` | 2054 | `/match` 真实响应形状(id 是**数字**不是字符串);空响应不 panic |

第 8 条注释(`mod.rs:1748-1752`)说明了为什么钉的是文档载荷形状而不是真接口:「真接口要签名(裸 curl 一律 403 Missing Authentication Headers,2026-07-19 实测)」。

#### 匹配算法(7 条 —— 本文件最核心的一组)

| # | 测试名 | 行号 | 钉住的契约 | 反向注入 |
|---|---|---|---|---|
| 12 | `episode_number_forms` | 1840 | `3`/`03`/`第3话`/`" 3 "` 都认;空/`OVA`/无集号一律不匹配 | 去掉 `\d+` 抽取 |
| 13 | `pick_episode_by_number_then_position` | 1855 | 三段回退:按号 → 按位置 → 首集;空表 `None` | 去掉按位置那段 |
| 14 | `title_score_forms` | 1874 | 相等/剥季号后相等/包含按占比/无交集低分/空串 0 | — |
| 15 | `similarity_beats_the_old_bigram_jaccard` | 1900 | 五条新口径才做得到的事 | ★ 换回 bigram Jaccard×0.6,**每一条都红** |
| 16 | `season_signal_separates_same_named_cours` | 1924 | 五种季号写法 + **摆法 A/B 两种媒体库布局** + 不知道时不表态 | ★ 让 `season_term` 恒 0.0 |
| 17 | `alt_titles_carry_cross_language_matches` | 1952 | 跨语种单靠 title 恒低分;给 alt_titles 就 1.0;**主标题不能因此变差** | ★ 去掉 `title_score` 里的 `chain` |
| 18 | `core_name_strips_season_and_subtitle` | 1967 | 四种副标题写法;**没有可剥的就原样返回** | — |
| 19 | `normalize_strips_punct_and_season` | 1977 | 全角冒号/方括号/年份括号/感叹号全折叠 | — |

第 15 条的五条断言值得单列 —— 它们是「换算法值不值」的量化证据:

| 断言 | 期望 | 旧算法(bigram Jaccard×0.6) |
|---|---|---|
| `葬送的芙莉莲` vs `葬送之芙莉莲` | > 0.8 | 天花板 0.6 |
| `ＳＰＹ×ＦＡＭＩＬＹ` vs `SPY×FAMILY` | **1.0** | 全角当不同字符 → 接近 0 |
| `ＳＰＹ×ＦＡＭＩＬＹ` vs `SPY x FAMILY` | > 0.85 | 同上 |
| `フリーレン` vs `ふりーれん` | **1.0** | 片/平假名当不同字符 → 0 |
| `赛马娘 Pretty Derby` 系 vs `刀`/`刀剑神域` | 前者比后者高 0.2+ | 都是 0.7 |

`mod.rs:1906` 还留了一条易错点:「×(U+00D7)和字母 x 是**两个字符**,不该折成一个 —— 但一字之差仍要高分」。

#### 输入归一化(3 条)

| # | 测试名 | 行号 | 钉住的契约 |
|---|---|---|---|
| 20 | `file_hash_is_always_well_formed` | 1986 | 32 位 hex;同名恒定;不同名相异;**真 hash 原样透传**;形状不对当没给 |
| 21 | `resolve_title_and_file_name` | 2021 | 剧集用 seriesName;Windows/Unix 两种分隔符都取 basename |
| 22 | `ticks_and_anime_detection` | 2042 | ticks→秒;`is_anime` 大小写不敏感 + 子串命中 |

#### 过滤与去重(5 条)

| # | 测试名 | 行号 | 钉住的契约 |
|---|---|---|---|
| 23 | `filter_blocks_words_users_modes` | 2097 | 三种屏蔽各自生效;**不配置就原样返回** |
| 24 | `dedup_merges_within_window_only` | 2130 | 窗口内同文同 mode 合并计数;**类型不同不合并**;超窗口不合并;结果按时间升序 |
| 25 | `dedup_off_keeps_everything` | 2154 | 关去重时 `count` 恒 1 |
| 26 | `filter_add_remove_dedupes_entries` | 2162 | 重复不入、空不入、增删对称 |
| 27 | `import_dandanplay_xml_blocklist` | 2180 | `t=` / `x=uid=` 两种;`enabled="false"` 和空内容都跳过;`&amp;` 解码 |

#### 缓存(2 条)

| # | 测试名 | 行号 | 钉住的契约 |
|---|---|---|---|
| 28 | `cache_mem_roundtrip_and_lru_cap` | 2204 | 内存往返;空 source/episode 不写不读;空列表不写;**LRU 上限 + 最老的被挤出** |
| 29 | `cache_file_name_is_stable_md5` | 2225 | 同 key 稳定、不同 key 相异(「换机/重启后仍命中同一文件」) |

第 28 条注释(`mod.rs:2205`)说明了为什么只验内存层:「磁盘层依赖 config_dir,CI 上不该乱写盘」。

**整体价值评估**:29 条里有 **8 条**(#1 #2 #3 #4 #15 #16 #17 #20)的注释直接写着「这条钉的是哪次真实故障 + 反向注入什么会红」。这不是常规单测,是**故障档案**。Go 侧应当先把这 8 条翻译过去,它们比实现代码更值钱。

**没有覆盖的**:
- `parallel_by_source` 的顺序归位(`mod.rs:644` 的注释说了 JoinSet 完成顺序是乱的,但没有测试钉住 `slots[i]` 这个归位)
- `get_comments_from_all` 的 `preferred` 优先顺序
- `fold` 的边界(`0x30FB` 单独丢、`0xFF01..=0xFF5E` 递归)只被 #15 #19 间接压到
- `MAX_TITLE_CHARS = 128` 截断

### 7.6 `crates/danmaku-proxy` —— 18 条单测 + 端到端

| 文件 | 测试 | 行号 | 钉住的契约 | 反向注入 |
|---|---|---|---|---|
| `main.rs` | `only_the_endpoints_clients_actually_use_are_forwarded` | 351 | 六条白名单放行;`""`/`login`/`user/profile`/`../admin`/`v2/search/anime` 全拒 | ★ `allowed()` 改恒 true |
| `main.rs` | `only_comment_requests_go_to_the_danmaku_store` | 365 | 只有 `comment/` 走弹幕库;多余路径段不混进 id;空 id 不当一集 | — |
| `main.rs` | `upstream_errors_are_never_stored` | 376 | 429/500 是错误;`errorCode=0`、字段缺失、**解不出 JSON** 都不是 | ★ `looks_like_error` 恒 false |
| `main.rs` | `ttl_is_picked_per_endpoint_class` | 388 | trending 用 trending TTL | — |
| `main.rs` | `client_ip_prefers_the_closest_trusted_hop` | 396 | CF → X-Real-IP → XFF 首段 → socket | — |
| `upstream.rs` | `signature_matches_the_client_implementation` | 166 | **与 core 侧同一组向量**,固定值 `base64(sha256("appid0/api/v2/xsecret"))` | 改拼接顺序 |
| `upstream.rs` | `governor_stops_at_both_limits` | 178 | 分钟/天两道闸各自拦住;**拒绝的那次不计进已用量** | ★ 去掉 `s.minute_used >= per_minute` |
| `upstream.rs` | `multi_secret_rotation_takes_only_the_first` | 198 | `"  s1  \ns2\n"` → `"s1"`;凭据缺失要报错不能静默跑起来 | 整坨拿去签名 |
| `store.rs` | `merging_only_ever_adds_never_loses` | 275 | 并集;**上游回空不清存量**;**非 JSON 更不能覆盖** | ★ merge 改成直接写 fresh |
| `store.rs` | `refresh_interval_tracks_whether_the_episode_is_still_growing` | 299 | 首次从下限起步;无新弹幕翻倍;**有新弹幕压回下限**;停在上限不无限翻 | ★ interval 恒设成 min_i |
| `store.rs` | `take_distinguishes_fresh_stale_and_missing` | 324 | 三态分清 —— **过期 ≠ 没有**(那是回存量的依据) | — |
| `store.rs` | `changing_the_bounds_takes_effect_on_existing_entries_immediately` | 337 | 管理员改区间,存量条目**立刻**按新区间判 | ★ 去掉 `take` 里的 `.clamp(min_i,max_i)` |
| `store.rs` | `episode_id_never_escapes_the_store_directory` | 355 | `../../etc/passwd` 和 `..\..\Windows\x` 都被净化;沙箱上两层零多余条目 | ★ 去掉 `file()` 的净化 → 实得 `["index.json"]` |
| `store.rs` | `eviction_drops_the_least_recently_watched` | 381 | 最久没看的先出局,刚看过的留着 | — |
| `store.rs` | `stats_report_what_the_admin_asked_for` | 395 | 集数/总条数/字节/新鲜集数;过了间隔就不新鲜 | — |
| `cache.rs` | `key_ignores_param_order_and_separates_real_differences` | 206 | 参数顺序不影响 key | — |
| `cache.rs` | `expired_entries_are_a_miss_and_get_dropped` | 225 | 过期算 miss **并当场删** | — |
| `cache.rs` | `eviction_keeps_disk_under_the_cap` | 237 | 淘汰把盘压到上限内 | — |
| `cache.rs` | `index_is_rebuilt_from_disk_on_restart` | 255 | 重启扫盘重建索引 | 去掉 `open()` 里的扫描 |
| `sources.rs` | `top_talkers_are_ranked_by_quota_actually_burned` | 117 | **按 upstream 排,不按 requests** | ★ 排序键换成 requests |
| `sources.rs` | `per_minute_limit_is_enforced_and_resets` | 129 | 分钟窗口拦住并重置 | — |
| `sources.rs` | `tracked_sources_are_capped` | 142 | 5000 条封顶 | ★ 去掉封顶 |
| `admin.rs` | `session_cookie_is_parsed_out_of_a_real_cookie_header` | 185 | 从真实 Cookie 头里抠出 `lp_admin=` | — |
| `admin.rs` | `password_compare_is_exact` | 200 | 定长比较仍然是精确比较 | — |
| `admin.rs` | `app_id_is_never_printed_in_full` | 208 | 只露末 4 位 | — |

#### 端到端 `crates/danmaku-proxy/e2e.mjs`(10.9 KB,起真进程走真 HTTP)

**自带假上游**,靠 `UPSTREAM_BASE` 顶上去(`upstream.rs:117-118`)。假上游**会校验签名头**(`e2e.mjs:45-47`):

> 代理必须签名。不签这里就报 403 —— 「有没有真签」不靠读代码,靠上游说话。

23 条断言,按主题:

| 主题 | 断言 | 行号 |
|---|---|---|
| 无鉴权 | 裸请求就能用(用户 2026-08-02 定的) | 120 |
| 白名单 | 白名单外回 `errorCode 1005` | 124 |
| 缓存 | 首次 MISS / 第二次 HIT | 128,135 |
| **签名** | ★ 假上游校验通过才回得出「假的番」 | 130-133 |
| **参数归一化** | ★ 换参数顺序仍然 HIT(「不归一化 = 白掏配额」) | 139-142 |
| 错误透传 | 429 原样给客户端 | 146 |
| **错误不入缓存** | ★ 下一次不是 HIT | 147-150 |
| 弹幕库 | 首次 UPDATED + cids `1,2,3`;间隔内 FRESH | 155,157 |
| **只增不减** | ★ 过期后拉取按 cid 求并集 → `1,2,3,4,5` | 169-172 |
| NOCHANGE | 一条没长标 NOCHANGE,存量一条不少 | 178,179 |
| **上游挂了回存量** | ★ 过期 + 429 → 回 STALE 且 cids 完整 | 186-189 |
| 无存量仍报错 | 库里根本没有的那一集要如实报 429 | 192 |
| 统计 | 集数 2 / 总条数 8 / 字节 > 0 / 新鲜 2 | 199-202 |
| 管理界面 | 页面可访问;未登录 401;密码错 401;下发 cookie | 206-209 |
| 来源统计 | 统计到了上游穿透次数 | 214 |
| **闸门** | ★ 超每日上限回 1003;★ **一个字节都没发给上游**;拦住时给人话 | 220-222 |
| **闸门关着照发** | ★ 弹幕库里的照样发 | 224 |
| 清理 | 清缓存不动弹幕库;清弹幕库才是真的全删 | 230,237 |

⚠️ 第 221 条断言(`upstreamCalls === before`)是这份 e2e 里**最有价值**的一条:它不是断言「返回了 1003」,而是断言**真的没有发出去**。只测返回码的话,一个「先发再拦」的实现照样绿。

`44edc610` 提交记录了 e2e **抓到的真 bug**:条目的刷新间隔是写入那一刻定死的,管理员改了上限对存量条目不生效(修在 `store.rs:112`、`store.rs:165` 各夹一次 `.clamp`)。这条单测抓不到——必须端到端改配置再读。

#### ⚠️ `episode_id_never_escapes_the_store_directory` 的假红事故(`ec523969`)

第一版断言写的是 `assert!(!temp_dir.join("../../etc").exists())`。

`ec523969` 提交原文:

> 不是代码问题,是这条测试自己写坏了:它断言 `temp_dir/../../etc` **不存在**,而 Linux 上 `std::env::temp_dir()` 是 `/tmp`,往上两层就是 `/`,`/etc` 本来就在。Windows 上恒绿、Linux 上恒红,而它守的那个性质(文件名净化)两边都是好的。
>
> **教训:测试里不要探测真实系统路径。它在一个平台上恒真、另一个平台上恒假,而两种情况都和被测的性质无关 —— 一个是假绿,一个是假红。**

修法(`store.rs:352-353`):把库套进 `root/a/b/store` 三层目录,`../..` 也跑不出沙箱;然后只断言 ①产出的文件名里没有任何分隔符 ②沙箱的上层目录一个多余条目都没有。

这是项目记忆 `test-must-fail-first` 里「环境不同 → 假绿/假红」那一类的教科书案例,**Go 侧写路径净化测试时会遇到一模一样的诱惑**(`os.TempDir()` 在 Linux 上同样是 `/tmp`)。

---

## 8. 已知未解决 / 存疑

### 8.1 明确的未解决项

| # | 事项 | 证据 | 影响 |
|---|---|---|---|
| 1 | **弹幕屏蔽词/黑名单/类型过滤前端零接线**;`danmaku_filter` / `danmaku_import_blocklist` 两条命令也零调用;而 UI 文案已在描述这个不存在的设置 | 3.11;`ui/mobile/pages/PlayerPage.tsx:1198`;`apps/desktop/src/lib.rs:3450-3462` | 用户被文案误导去设置页找一个不存在的入口 |
| 2 | **安卓 libmpv 是 v0.36,缺三个 `secondary-*` 属性**,而 `set_secondary_sub_opts` 命令三项全调 | 4.6 | 潜伏。手机端一接双字幕面板就是三个死按钮 |
| 3 | **`set_str` 丢弃 `mpv_set_property_string` 返回值** | `crates/mpv/src/lib.rs:1466-1470` | 所有属性设置失败(`-8`/`-9`)一律静默 |
| 4 | **`pick_lane` 满轨分支会把轨道占用时间往前调** | 2.4 | 弹幕密时叠字概率高于预期。无测试覆盖 |
| 5 | **两处 ASS 时间解析行为不一致**(畸形返回 `None` vs `0`) | 1.4 对比表 | 合并时若不慎会把「跳过」变成「堆在片头」 |
| 6 | **Canvas 版的「显示区域」是 CSS 裁剪不是轨道限制** | 2.1 | 超出区域的弹幕被裁掉而不是挤上去;与 ASS 版行为不同 |
| 7 | **`crates/mpv` 的两条关键时序测试是 `#[ignore]`,CI 不跑** | 7.3 | 这两条契约在 CI 上裸奔 |
| 8 | **`dedup` 的默认值两端不一致**:核层 `FilterOptions::default()` 是 `false`,前端 `defaultDanmakuFilter()` 是 `true` | `crates/core/src/danmaku/mod.rs:1561`;`ui/shared/api.ts:1769` | 目前靠前端每次显式传值兜住。任何走核层默认值的新调用方会得到「不去重」 |
| 9 | **弹幕锚点表是纯内存态,重启即失效** | `apps/desktop/src/lib.rs:103` | 重启后追番的第一集必然走全量匹配(多一次 `/match` 往返)。不是 bug,但迁移时若改成落盘要注意跨版本 episodeId 可能已变 |
| 10 | **`parallel_by_source` 没有并发上限也没有独立超时** | `crates/core/src/danmaku/mod.rs:646-669` | 源多时会同时发 N 个请求;超时完全依赖调用方给的 `reqwest::Client` |
| 11 | **`get_comments` 未接自建源的 taskId 异步轮询** | `crates/core/src/danmaku/mod.rs:416` 的 `ponytail:` 注释 | misaka 风格的自建源如果走异步任务返回,我们直接读 `comments` 会拿到空 |

### 8.2 存疑 / 未确认(已说明查了哪里)

| # | 问题 | 查过什么 | 为什么定不了 |
|---|---|---|---|
| 1 | `sub-fonts-dir` 在安卓 libmpv v0.36 上到底认不认 | 两颗二进制的字符串差分;`crates/mpv/src/lib.rs:1262-1266` 注释;记忆 `android-mpv-subtitle-fonts.md` | 查全名的字符串法对**前缀拼接**的样式类选项无效(坑 15,已用 Windows DLL 反证)。定论只能真机 `mpv_get_property_string("sub-fonts-dir")` 回读 |
| 2 | `secondary-sub-ass-override=scale` 用于弹幕能不能工作 | `crates/mpv/src/lib.rs:1864` 的白名单;被删的 `attach_danmaku_raw` 只用过 `no` | 仓库从未用 `scale` 跑过弹幕。`ui/desktop/App.tsx:2012-2013` 只说了它对**字幕**的副作用(ASS 自带定位优先) |
| 3 | Windows libmpv-2.dll 的确切版本号 | `grep -a "mpv 0\.[0-9]+"` 无匹配;`crates/mpv/src/lib.rs:1850` 注释写 v0.41.0-744 | 二进制里查不到版本串,只有代码注释这一个来源 |
| 4 | 是否存在「MediaStreams 为空 → 回退 mpv 真轨」的显式代码 | grep `crates/`、`apps/*/src/`、`ui/` 全部 | 没有这样的分支。4.9 的结论是架构性免疫(播放页只读 `track-list`),不是某处有回退逻辑 |
| 5 | ASS 版 vs Canvas 版底部弹幕 y 坐标差一个 `laneH` 是否真等价 | 2.5 的锚点分析 | 纸面分析等价(`\an2` 下对齐 vs `textBaseline=top` 上对齐),但**没有逐像素比对过**。两版从未同时在线 |
| 6 | `est_width` 的 `0x1100` 判据对希腊/西里尔是否合适 | `[已删] ass.rs:80-86` | 无测试覆盖。作者已声明是估算且「偏差几个像素不影响观感」 |
> 8.2 原有的第 7、8、9 条(手机端 `danmaku_auto_load` 是否一致、`e2e.mjs` 断言、`admin.html` 内容)在本次工作中已全部核实并写进正文,不再是存疑项。

### 8.3 本次工作的方法论收获(值得进项目记忆)

**「用 `grep`/`strings` 查 mpv 选项存不存在」是无效方法,而且会给出自信的错误答案。**

我差点据此报告「安卓上 `sub-fonts-dir` 是 no-op、`sub-back-color` 也不存在」——直到拿 Windows DLL 做对照组:`sub-font-size` 在那里同样查不到,而它被 ctypes `property-list` 证实存在。
根因是 mpv 的样式类选项按「前缀 + 后缀」在运行时拼名,二进制里只有后缀。
**这个方法只在非前缀拼接的属性上有效**(`secondary-*` 那一族全名直接出现,4.6 的差分因此可信)。
旧记忆 `android-mpv-subtitle-fonts.md` 里「grep 全 miss 所以选项不存在」那条结论,用的正是这个被证伪的方法。

---

## 附:本文引用的文件清单

| 文件 | 状态 | 本文用到的范围 |
|---|---|---|
| `crates/core/src/danmaku/ass.rs` | **已删**(`git show 108965f6^:...`) | 全文 360 行 |
| `crates/core/src/danmaku/local.rs` | 在用 | 全文 532 行 |
| `crates/core/src/danmaku/mod.rs` | 在用 | 全文 2231 行 |
| `crates/core/src/translation.rs` | 在用 | 1-15、250-348、2397-2446 |
| `crates/core/src/media.rs` | 在用 | 1-190 |
| `crates/core/src/emby.rs` | 在用 | 295-297、380-400、1768-1773、2090-2200、2484-2509 |
| `crates/mpv/src/lib.rs` | 在用 | 25-60、1056-1110、1240-1300、1375-1440、1466-1470、1560-1660、1700-1920、2063-2103、2223-2240 |
| `crates/mpv/src/lib.rs` @ `108965f6^` | **已删部分** | `attach_danmaku_raw` / `set_danmaku_sub` / `clear_danmaku_sub` / `set_danmaku_visible` / 那条 `#[ignore]` 测试 |
| `apps/desktop/src/lib.rs` | 在用 | 1720-1800、2330-2412、2560-2591、2960-3042 |
| `apps/android/src/lib.rs` | 在用 | 3290-3330、4886-4887 |
| `ui/shared/Danmaku.tsx` | 在用 | 全文 178 行 |
| `ui/shared/api.ts` | 在用 | 483-563、1710-1782 |
| `ui/desktop/App.tsx` | 在用 | 127-178、319-350、506-533、647、668、1046-1047、1277、1440、1650-1671、1975-2025、2087-2092 |
| `ui/mobile/pages/PlayerPage.tsx` | 在用 | 140-215、245-360、497-581、701、1192-1215 |
| `crates/danmaku-proxy/src/main.rs` | 在用 | 全文 406 行 |
| `crates/danmaku-proxy/src/upstream.rs` | 在用 | 全文 208 行 |
| `crates/danmaku-proxy/src/store.rs` | 在用 | 1-260、270-406 |
| `crates/danmaku-proxy/src/cache.rs` | 在用 | 1-195 |
| `crates/danmaku-proxy/src/sources.rs` | 在用 | 1-115 |
| `crates/danmaku-proxy/src/config.rs` | 在用 | 全文 128 行 |
| `crates/danmaku-proxy/src/admin.rs` | 在用 | 1-130、185-212 |
| `crates/danmaku-proxy/src/admin.html` | 在用 | 结构核对(283 行,5 个 `<h2>` 分区) |
| `crates/danmaku-proxy/e2e.mjs` | 在用 | 断言清单(10.9 KB) |
| `crates/danmaku-proxy/Cargo.toml` | 在用 | 全文 |
| `apps/android/src/lib.rs` | 在用 | 3295-3311、3548-3632、4886-4887、5235-5290 |

### 本文用到的 git 对象

| 提交 | 内容 |
|---|---|
| `108965f6` | 删掉 mpv/ASS 弹幕整条路(本文第 0.1、1、2 节的材料来源) |
| `4f72060c` | 上一版:弹幕改交 libass |
| `7a83ae32` | 弹幕代理:服务端签名 |
| `44edc610` | 弹幕代理:去客户端凭据 + 自托管弹幕库 |
| `ec523969` | 路径穿越那条测试在拿环境当断言(7.6 的假红事故) |
| `82043159` | 配额被刷完:我们自己贡献了三份 |
| `5a3dcf0c` | 弹幕搜不到的三个真因全在我们这边 |
| `e71090f5` | 置顶弹幕互相覆盖不顺延 |

### 本文中我实际执行过的验证

1. **把 `108965f6^` 的 `ass.rs` 取出、剥 serde、`rustc -O` 编译并运行**,第 1.6 节是真实 stdout,不是手推。
2. **两颗 libmpv 的二进制字符串差分**(`apps/android/.../libmpv.so` v0.36 vs `crates/mpv/libmpv/libmpv-2.dll`),得出 4.6 的 `secondary-*` 差异表,并**用 Windows DLL 反证了这个方法对前缀拼接选项无效**(坑 15)。
3. **`FcInit` / `FONTCONFIG_FILE` 符号差分**,确认安卓 libmpv 无 fontconfig(4.5)。
4. **全前端 grep** `blockwords` / `user_blocklist` / `blocked_modes` / `danmaku_filter` / `danmaku_import_blocklist` / `setSecondarySub`,确认零接线(3.11、坑 14)。
5. **diff 两端 `danmaku_auto_load`**,确认逻辑逐行一致(3.8)。
