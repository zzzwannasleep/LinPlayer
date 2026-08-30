# 矛盾条目裁决记录

> 2026-08-30。记忆库迁移时机械比对出 11 组「互相矛盾」的条目,迁移 agent 按纪律只列不判。
> 本文是逐条查证后的裁决,**每条都对着当前代码验过**。

## 总结论:11 组里,真矛盾 0 组

全部落进四类:

| 类 | 组数 | 含义 |
|---|---:|---|
| **A · 已被后续事实推翻** | 2 | 旧条目写于方案变更之前,没标作废 |
| **B · 描述的是不同层 / 不同量** | 4 | 两条都对,只是在说不同的东西 |
| **C · 时间演进** | 2 | 数字随版本变化,并列时容易误读 |
| **D · 环境不同** | 1 | 两台服务器行为本就不同 |
| **E · 决策更新** | 2 | 新决定覆盖旧决定 |

**这说明记忆库的问题不是"记错了",是"记的是快照而没记版本"。**
`docs/lessons/` 取代它之后,每条经验都应带**生效时间与失效条件**,否则同样的误读会再来一次。

---

## 逐条裁决

### #1 弹幕渲染路径 — A 类(已推翻)

| 条目 | 说法 |
|---|---|
| `danmaku-via-libass-ass`(07-26) | 走 mpv ASS + `secondary-sid` |
| `pc-shortcuts-and-mpvconf`(07-27) | 用户拍板全删,只剩网页 Canvas |

**裁决:后者对。** `crates/core/src/danmaku/ass.rs`(360 行)于 commit `108965f6`
(2026-07-27)整条删除,提交信息原文:「次字幕位只有一个,弹幕占了就开不了双语字幕」,
用户原话「删掉就行了 那个没必要留」。

当前 `crates/core/src/danmaku/` 只剩 `local.rs` + `mod.rs`,其中 `parse_ass` 是**解析器**
(读 `.ass` 当弹幕导入源),不是渲染用的生成器。唯一渲染路径是 `ui/shared/Danmaku.tsx`。

**仍然有效的部分:**倍速插值根因、ASS 是 BGR、`secondary-sub-ass-override` 默认 `strip` ——
这些是 mpv / ASS 本身的事实,与我们用不用那条路无关。

新架构方案见 `docs/go-migration/SPEC.md` §7.5(走 `osd-overlay`,不占字幕轨)。

### #2 画质档位表 — B 类(两层键空间)

**两条都对,说的是不同层:**

- `modeA..modeAC` 是**历史键名**。`apps/desktop/src/shaders.rs:192` 明写:
  「键名 modeA..modeAC 是历史键,**与内容无关** —— 别为了『名字对得上』去改键」
- `ak_` / `fsr_` / `nv_` 是**预设键**,在 `shaders.rs:208` 起的 `Preset` 分派表里

一个是对外的档位 id,一个是内部的预设名。**改任一层都不要试图让它们"对上"。**

### #3 超分卡的真凶 — B 类(三次不同的卡)

三种归因并存,但**不是互斥,是三次不同的故障各自的根因**:

| 归因 | 现状 |
|---|---|
| 跑在核显上(`hybrid-gpu-must-pin-dgpu`) | **已修**。`NvOptimusEnablement` 现存 2 处(`apps/desktop/`) |
| ANGLE / 出画管线 | **已修**。Win 默认改 `d3d11va` 零拷贝(`crates/mpv/src/lib.rs:1829`) |
| shader 算力 / 自带默认太保守 | **已改**。加了第四族「锐化专精」+ ArtCNN |

**排查顺序仍然有效:先确认跑在哪块 GPU 上(回读 mpv 日志的 Device Name),再谈档位。**

### #4 安卓播放器是不是桩 — A 类(已推翻)

**裁决:不是桩。**

- `apps/android/src/lib.rs:163` 的 `async fn play(...)` 有真实参数(item_id / resume_secs / …)
- 该文件 6 处引用 `linplayer_mpv` / `mpv::`

`android-tv-host-build` 那条写于安卓壳刚建起来的时候,**当时**播放命令确实是桩,
后来接上了但那条没更新。`mobile-ui-build`(明确说「不是桩」)是对的。

### #5 libmpv 怎么入库 — A 类(已推翻)+ 发现一处文档错误

**裁决:不入库。**

- `git ls-files` 里**没有任何 `.so` / `.dll`**;版本控制里与 mpv 相关的只有
  `crates/mpv/Cargo.toml` / `build.rs` / `libmpv/client.h` 等头文件
- 实际存在的 `libmpv.so` 全在 `apps/android/gen/android/app/build/...` —— **构建产物**
- CI 注释也写着「不需要 lfs」

三条记忆里 `android-local-build-works`(不入库,要手动拉)是对的;LFS 那条整体作废。

> ⚠️ **顺带发现一处文档错误:** `.gitattributes` 的注释写着
> 「原生库直接以普通 Git 对象存放在仓库内(不再走 Git LFS)」——
> **前半句与事实不符**,库里根本没有原生库。已在本轮修正。

### #6 苹果端 — E 类(决策更新)

- `platform-scope-decision`:苹果全线彻底不做(旧)
- `go-core-native-ui-decision`:SwiftUI(Apple 后置)(新)

**裁决:新的覆盖旧的。** 用户 2026-08-30 明确提出「最好也有苹果系列」。
但注意 `docs/go-migration/SPEC.md` §11.4 的限定仍然成立:
**iOS 是「技术上支持」,不承诺分发**(App Store 大概率不给上),实际含义更接近 macOS。

> 附:插件 manifest 的 `targets` 至今仍**显式拒绝 `ios`**
> (`crates/core/src/plugins/manifest.rs:486` 有测试钉住)。苹果端真开做时这里要一起改。

### #7 插件可用端 — B 类(平台能力 ≠ 插件声明)

**两条都对:**

- 「手机端能装能用」= **宿主平台的能力**
- 「官方插件 targets 一律只写 pc」= **那批插件自己的声明**

`targets` 是真机制(`manifest.rs:162` 解析,`:368` 有测试),合法值含 `pc` / `tv`,
`ios` 被显式拒绝。**官方插件没写 android,不等于 android 装不了。**

### #8 预取缓存上限 — B 类(三个不同的量)

三条记忆各说一个量,都对:

| 量 | 值 | 出处 |
|---|---|---|
| **预读窗口** `MAX_READ_AHEAD` | 64 MB | `crates/core/src/net/prefetch.rs:44` |
| **磁盘环形缓存大小** `prefetch_cache_bytes` | 用户可设 | `crates/core/src/config.rs:225` |
| **旧配置的校验区间** | 16~32 MB | `config.rs:711`(老配置存的 1GB 会被夹到这个区间) |

**「上限」这个词在这三处指的不是同一件事。** 移植时逐个对号,别合并。

### #9 多线程加载门控 — B 类(UI 入口 ≠ 运行行为)

- 「不给全开入口」= UI 层不暴露把线程数拉满的开关
- 「开预加载则起播一律经代理」= 运行时行为

并发数确认 `clamp(2,4)`(`crates/core/src/config.rs:210` 注释)。两条不冲突。

### #10 Emby 分面端点 — D 类(两台服务器不同)

- `library-filter-panel`:`/Years` `/Tags` 可用
- `rn-migration-evaluation`:那台上全 404

**裁决:两条都对,是两台服务器。** 这正好印证本仓库反复出现的那条纪律:
**别拿一台服务器的结论替另一台签字。**

详见 `docs/go-migration/knowledge/EMBY.md` §6(16 条 fork 差异,每条标明是哪台)。

### #11 安卓命令数 — C 类(时间演进)

233/249(2026-07-28)vs 249、桌面 266、差 29(2026-08-30)。
**同一个量在不同时间点的值**,不是矛盾。以最新为准。

---

## 这次裁决本身的教训

**记忆库真正的缺陷不是"记错了",是"记的是快照而没记版本"。**

11 组「矛盾」里 8 组的成因是同一个:**条目写下时是对的,后来事实变了,旧条目没标作废。**
读的人把两个时间点的快照并排看,就成了矛盾。

`docs/lessons/` 要避免重蹈覆辙,每条经验应当带:

1. **生效时间**(已有:`> 原记忆:xxx.md`)
2. **失效条件** —— 什么情况下这条不再成立
3. **被推翻就删掉**(用户 2026-08-30 定):留着占地方,还会被下一个人当成有效结论再读一遍

本轮已删除:

| 删了什么 | 在哪 | 为什么安全 |
|---|---|---|
| 「弹幕交给 libass」整条(59 行) | `danmaku-sync.md` | 仍有效的 mpv/ASS 事实在 `knowledge/ASS_DANMAKU.md` 里密度更高(BGR 8:2、`sub-ass-override` 17:2) |
| 「Android libmpv LFS in CI」整条(25 行) | `android.md` | 前提(走 LFS)已不成立,`git ls-files` 无任何 `.so` |
| 「播放不可用 / 10 个播放器桩」 | `android.md` | 已接真 libmpv;只保留「写桩的两条原则」这个通用部分 |
| 「苹果的所有产品都不做了」 | `decisions.md` | 被 2026-08-30 决策覆盖 |
| 「两处必修」旧字体方案(6 行) | `player-mpv.md` | 被本条自己的双铺更正取代 |
