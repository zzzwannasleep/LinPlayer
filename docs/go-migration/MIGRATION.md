# 迁移方案 · Rust + React/Tauri → Go + 各端原生 UI

> 状态:草案 v0.1 · 2026-08-30
> 目标架构见 `SPEC.md`。任务清单见 `TODO.md`。

---

## 1. 迁移的三条原则

### P1 · 黄金实现原则

**现有 Rust 版是黄金实现,不是待淘汰的旧代码。**

它承载了两年的踩坑结论。Go 版的验收标准不是"跑起来了",是"**和 Rust 版输出一致**"。
任何"我觉得这样更好"的行为改动,必须单独立一条 issue,不许夹带在移植里。

> 反例:移植 `emby.rs` 时顺手"优化"了 `Fields` 参数。
> 而 `UserData` / `SeriesName` 根本不是合法的 Fields 值、
> `EnableTotalRecordCount` 在 Emby 里不存在(那是 Jellyfin)——
> 这类知识只存在于现有代码里,改一个字就静默退化。

### P2 · 分层先于功能

先把**三条通道**(FFI / 本地 HTTP / 视频 surface)打通,再谈业务模块。

一个能 `lp_call("system.ping")` 拿到 pong、能从 `/img` 取到一张图、
能在窗口里放出一段视频的空壳,比十个移植好但接不上的业务包有价值得多。

### P3 · 风险前置

四个 SPIKE(`TODO.md` §1)必须在写第二行业务代码之前全部有结论。
它们中任何一个失败都会改变架构,而越晚发现改起来越贵。

---

## 2. 阶段划分

不按时间划分(没有工期),按**依赖与验收判据**划分。
每个阶段有明确的"做完了"信号,没达到不进下一阶段。

```
阶段 0  风险验证 ─────────► 四个 SPIKE 全有结论
   │
阶段 1  骨架 ─────────────► 空壳三端能起、能 ping、能取图、能放视频
   │
阶段 2  录制与对账设施 ───► Rust 版能录、Go 版能回放对账
   │
阶段 3  核心层移植 ───────► 所有模块差分对账通过
   │
   ├── 阶段 4a  Android UI ──► 功能集合表全绿
   ├── 阶段 4b  Windows UI ──► 功能集合表全绿
   └── 阶段 4c  Linux 验证 ──► 与 Windows 同一份代码跑通(差异清单见 SPEC §15)
   │
阶段 5  切换与下线 ───────► 旧栈删除
   │
阶段 6  Apple ───────────► macOS 优先
```

### 阶段 0 · 风险验证

见 `TODO.md` §1。四个 SPIKE 并行做,互不依赖。

**出口判据:** 四份 SPIKE 报告,每份含实测数据 + 结论 + 若失败的备选方案。
**不允许**用"应该可以"结题 —— 未验证的归因不是结论。

### 阶段 1 · 骨架

目标是一个**能端到端跑通三条通道的空壳**。

| 交付 | 判据 |
|---|---|
| `core/ffi` 七个导出函数 | C 头文件生成,三端各自能 dlopen / LoadLibrary |
| `core/bus` 命令分派 + 事件队列 | `system.ping` 往返;`lp_cancel` 能真取消一个 sleep 5s 的假命令 |
| `core/net/localserve` | `/img` 能代理一张图并落缓存 |
| `core/player` 最小可播 | 硬编码一个本地文件,在窗口里出画面 |
| Android 空壳 | Compose 空页 + SurfaceView,能播 |
| Windows 空壳 | Avalonia 空窗 + 视频层,能播 + OSD 能盖在上面 |

**这一阶段结束时,`SPEC.md` §5 和 §7.2 的契约就冻结了。** 之后改要走变更流程。

### 阶段 2 · 录制与对账设施

这是整个迁移的**质量地基**,值得单独一个阶段。见 §4。

| 交付 | 判据 |
|---|---|
| Rust 侧 `LP_RECORD=<dir>` | 跑一遍真实使用,产出可回放的录制包 |
| Go 侧回放器 | 吃同一份录制,输出 diff 报告 |
| 对账在 CI 里跑 | 故意改坏 Go 侧一个字段,CI 变红(**先红**验证) |

### 阶段 3 · 核心层移植

按 §3 的映射表逐模块做。顺序按依赖:

```
paths → config → http → emby ──┬─► source/* ──► plugins ──► 其余
                               └─► net/prefetch ──► player 完整化
```

**每个模块的完成定义:**
1. Go 实现完成
2. 单元测试(含**先红**验证)
3. 差分对账通过
4. 该模块涉及的命令在 `COMMANDS.md` 里标记为 ✅

### 阶段 4 · UI

三端可并行。**Android 优先**,理由:

- 它是两个平台(手机 + TV),覆盖面最大
- SurfaceView 路径无风险,不会被 SPIKE-1 的结果影响
- Compose TV 焦点是最大的收益点,早验证早安心

**PC 端(4b / 4c)的规格已经写死在 [`UI_PC.md`](UI_PC.md)** —— 设计系统、动效、
组件状态矩阵、快捷键全表、18 页逐页契约、播放页 OSD、无障碍、性能预算、验收清单。
做 Windows UI 之前先把 §11 的验收清单抄成逐页 checklist,**不要边做边想判据**。

**4c 不是"顺手验一下"。** `SPEC.md` §15 列了 20 处 Windows / Linux 真实分叉,
其中 6 处的现有注释明写「只有真跑 Linux 才现形」,3 处会让 Linux 侧的应用内更新
**100% 失败**。`TODO.md` §5.3b 是这一段的任务组。

### 阶段 5 · 切换与下线

| 步骤 | 判据 |
|---|---|
| 灰度:新旧包并存发布 | 新包在真机跑满一周无 P0 |
| 数据迁移验证 | 旧 `config.json` 被新版直接读取,账号 / 线路 / 偏好零丢失 |
| 删除 `ui/`、`apps/`、`crates/` | 仓库只剩 `core/` + 三端 UI |

### 阶段 6 · Apple

macOS 优先。iOS 只做到"能装",不承诺分发。

---

## 3. 模块映射表

> **列说明**
> `坑` 列记录的是**移植时必须保留的行为**,不是可选的优化建议。
> 每一条背后都有一次真实故障。

### 3.1 基础设施

| Rust | 行数 | Go 包 | 依赖选型 | 坑 |
|---|---:|---|---|---|
| `paths.rs` | 626 | `core/paths` | stdlib | 数据根在 Android/Apple 由宿主传入,**核心层不猜**;迁移逻辑挂在 root() 首次调用,漏了会升级掉账号 |
| `config.rs` | 1083 | `core/config` | `encoding/json` | 字段名必须与现有 serde 输出一致;全字段 default;`active_line` 是下标不是 id |
| `config_transfer.rs` | 266 | `core/config` | | 备份/恢复格式见 `docs/BACKUP_FORMAT.md`,格式不许变 |
| `http.rs` | 557 | `core/httpx` | stdlib | **三个客户端都必须设空闲超时**(不是整体超时 —— 慢链路拉 4MB 合法要 29~62s);UA 三分口径(Emby / 预取 / 默认)不能串 |
| `secrets.rs` | 114 | `core/secrets` | `-ldflags -X` | CI 漏传 = 功能静默残废 + 构建全绿 |
| `update.rs` | 603 | `core/update` | stdlib | GitHub `/releases` 返回顺序**不可依赖**(id/created/published 三键实测全反),必须自己按版本号取最大 |

### 3.2 Emby 与媒体

| Rust | 行数 | Go 包 | 依赖选型 | 坑 |
|---|---:|---|---|---|
| `emby.rs` | 2923 | `core/emby` | stdlib | `Fields` 合法值有官方 swagger 约束;`EnableTotalRecordCount` 在 Emby 不存在;Backdrop 在 `BackdropImageTags` 数组不在 `ImageTags`;必须显式设 `Accept-Encoding`;`PlaySessionId` 三件套必须同 id 否则续播不落地 |
| `media.rs` | 230 | `core/media` | | 版本/音轨/字幕的正则筛选;**preferred 标记必须由核心层给**,不能让 UI 各自回落 `versions[0]` |
| `blocklist.rs` | 237 | `core/blocklist` | | 过滤点在 `emby.fetchItems` 一处;`latest` 是裸数组要单独补;**媒体库网格故意不滤**否则解除不了;`views` 加 `include_blocked` |
| `watch_history.rs` | 1876 | `core/history` | | 跨服续播;`series_tmdb` 缓存 |
| `watch_history_sync.rs` | 719 | `core/history` | | 回传去重集一次播放会话内不重复 |
| `server_batch.rs` | 689 | `core/serverbatch` | | 批量解析引擎 + 深链 + 图标 URL 构造 |
| `ranking.rs` | 382 | `core/ranking` | | **没有"排行榜开关"**这种东西;fetch 返回 error 不许吞 |
| `icon_cache.rs` / `icon_library.rs` / `image_cache.rs` | 848 | `core/net/localserve` | | 合并进数据通道;**不做服务端缩放**(用户已否);某些 fork 完全忽略 `maxWidth` |

### 3.3 媒体源

| Rust | 行数 | Go 包 | 依赖选型 | 坑 |
|---|---:|---|---|---|
| `source/mod.rs` | 786 | `core/source` | | `SourceKind` 线上是**小写**;`take_rotated_credentials` 回写通道必须保留(一次性 refresh_token 不回写 = 重启掉登录且不报错) |
| `source/aliyundrive.rs` | 733 | `core/source/aliyun` | **`decred/dcrd/dcrec/secp256k1`** | 扫码 + **secp256k1 ECDSA**(SHA256 预哈希),签名是 raw `r‖s` 再补 `01`。**真正用 secp256k1 的是这个源,不是 115** |
| `source/baidu.rs` | 451 | `core/source/baidu` | | 扫码 BDUSS |
| `source/pan115.rs` + `_crypto.rs` | 616 | `core/source/pan115` | **`math/big`**(不是 secp256k1) | ⚠️ **v0.1 库选型写错了**。m115 是「名叫 RSA 实为混淆」的**公钥模幂**(`m^E mod N`),全程无私钥,Go 侧 `math/big` 足够。`pan115_crypto.rs:1-9` 明写:ECDH/P-224 那套**只用于上传**,播放器不上传。注意 `len%4` 错位 |
| `source/pan139.rs` | 565 | `core/source/pan139` | | `Authorization` 本地算 `Basic base64("pc:<手机号>:<token>")`;手写 `encodeURIComponent`(与标准库行为不同,别换)。⚠️ **短信那条路同 189,不在当前树** |
| `source/pan189.rs` | 915 | `core/source/pan189` | `crypto/rsa`, `math/big` | RSA 手做,结果必须逐字节对账;`&params=` 是追加不是替换。⚠️ **v0.1 写的「短信走 `dynamicCheck=TRUE` + epd 槽位」不在当前代码树**——那套只存在于 `5369be7b`,已被 `99e141c6`(账密版)取代(`git merge-base --is-ancestor 5369be7b HEAD` = 否;全仓 `epd`/`sms` 零命中)。**要不要重新做短信登录是产品决策,不是移植任务** |
| `source/quark.rs` / `quark_tv.rs` | 856 | `core/source/quark` | | 二维码是 **base64 PNG 不是文本**,不要再编码一次 |
| `source/openlist.rs` | 259 | `core/source/openlist` | | |
| `source/smb.rs` | 318 | `core/source/smb` | `cloudsoda/go-smb2` | **mpv 两端都没有 smb 协议** → 必须自建本地 Range 桥;桥必须回 `Connection: close` |
| `source/webdav.rs` | 468 | `core/source/webdav` | `studio-b12/gowebdav` 或自写 | href 双前缀(只有子目录才 404);XML 实体可能被拆成多个事件 |
| `source/ftp.rs` | 308 | `core/source/ftp` | `jlaffaye/ftp` | `MLST` 兜底会把垃圾行变成假文件 |
| `source/local.rs` | 247 | `core/source/local` | stdlib | 交 mpv 裸路径;**必须有越狱闸**;安卓侧未做(只有 INTERNET 权限) |
| `source/feiniu.rs` | 796 | `core/source/feiniu` | `crypto/md5` | authx 签名(拼接顺序敏感)。⚠️ **v0.1 写的「封面/长播 authx 过期是已知待办」已作废——两条都修了**且有反向断言测试(`feiniu.rs:700`:media/range 不能带 authx,静态签名会在长播途中过期导致断流) |
| `source/anirss.rs` | 1368 | `core/source/anirss` | | 管理接口不在 backend 接口上,要另存具体类型并**共享同一份 token 缓存** |
| `source/plugin_source.rs` | 578 | `core/source/pluginsrc` | | `$sourceServer` 展开表必须在每次账号变动后同步,否则 fail-closed 发不出请求 |

### 3.4 网络

| Rust | 行数 | Go 包 | 依赖选型 | 坑 |
|---|---:|---|---|---|
| `net/prefetch.rs` | 2586 | `core/net/prefetch` | stdlib + `os.File` | 本迁移**收益最大**的一块。已知必须保留的行为:①边收边吐,不能把预取粒度当供给粒度 ②seek 不回退边界 ③尾部走直连(同槽会把头顶掉) ④必须回 `Connection: close`(否则播放器把 seek 管线化到同一 socket 被吞,退化成整片线性下载) ⑤302 只跟随一次 ⑥环形缓存占用恒 = 上限 ⑦读写要防 TOCTOU 串数据、防段被挤掉无人重拉 |
| `net/preload.rs` | 246 | `core/net/preload` | | 预热的字节必须能被起播复用 —— **起播不能新起句柄**(旧句柄 Drop 会删缓存,预热全白做) |
| `net/cf/*` | 1178 | `core/net/cf` | | 路由改写表与代理句柄要同步开关 |
| `net/localserve.rs` | 268 | `core/net/localserve` | stdlib | 扩成数据通道总入口(见 SPEC §6),加 token 与 src 白名单 |
| `companion.rs` | 280 | `core/companion` | stdlib | 电视端开机即起的局域网小网页 |

### 3.5 弹幕与同步

| Rust | 行数 | Go 包 | 坑 |
|---|---:|---|---|
| `danmaku/mod.rs` | 2231 | `core/danmaku` | `errorCode` 必须看(实测整天 429 却显示"未找到");`/match` 的 `fileHash` 空串是参数非法,这条路从没通过;`file_name` 不能传成"第 35 集";多密钥可能是换行分隔,整坨签名必 403 |
| `danmaku/local.rs` | 532 | `core/danmaku` | **本地弹幕文件解析器**(xml / ass / json),不是渲染器。`parse_xml` 已支持 B 站 XML;Go 侧 `encoding/xml` 必须 `Strict=false` + 挂 `CharsetReader`(现版本收 `&str`,GBK 文件是坏的) |
| `ui/shared/Danmaku.tsx` | 前端 | `core/danmaku` 渲染层 | **插值里必须有倍速**(这是"弹幕卡"的真根因,不是绘制开销):两次轮询之间靠墙钟外推,没有倍速因子则 2x 播放时弹幕按 1x 爬。渲染方案见 `SPEC.md` §7.5 —— **不要走 `secondary-sid`**,那是 2026-07-27 被用户否决的方案 |
| `sync/trakt.rs` | 485 | `core/sync/trakt` | Scrobble 生命周期 |
| `sync/bangumi.rs` | 534 | `core/sync/bangumi` | 单集写入路径 subject 位必须是字面 `-`;不发 UA 会吃 CF 403(伪装成"AccessToken 无效") |
| `sync/bangumi_matcher.rs` | 437 | `core/sync/bangumi` | 从不比标题,复用弹幕评分 |
| `sync/calendar.rs` | 110 | `core/sync/calendar` | 付费墙:通用放送表免登录 |

### 3.6 插件

| Rust | 行数 | Go 包 | 依赖选型 | 坑 |
|---|---:|---|---|---|
| `plugins/engine.rs` | 225 | `core/plugins/engine` | `buke/quickjs-go` | 内存 64MB、看门狗 30s、`__lp_call` 前奏逐条对齐 |
| `plugins/ctx.rs` | 420 | `core/plugins/ctx` | | 宿主 API 语义零改动 |
| `plugins/manifest.rs` | 488 | `core/plugins/manifest` | | 格式零改动 |
| `plugins/registry_index.rs` | 434 | `core/plugins/registry` | | 键 snake_case + author 为字符串是**硬契约**;产物必须可复现(无时间戳、强制 LF) |
| `plugins/permission.rs` | 126 | `core/plugins/permission` | | |
| `plugins/manager.rs` / `state.rs` / `storage.rs` / `worker.rs` / `installer.rs` / `host.rs` / `convert.rs` / `contributions.rs` / `assets.rs` | 2000 | `core/plugins/*` | | 逃生舱必须是**独立 origin**,否则权限模型是摆设 |
| `plugins/hello_it.rs` | 433 | 测试夹具 | | |

### 3.7 其它

| Rust | 行数 | Go 包 | 处置 |
|---|---:|---|---|
| `download.rs` | 839 | `core/download` | 多线程 Range 下载 + 权限门控 |
| `translation.rs` | 2827 | `core/translation` | **桌面独占**。Whisper 依赖下载 / 模型管理 / 实时预读翻译。移植优先级最低(阶段 3 末尾),但**不许砍** |
| `crates/mpv/lib.rs` | 2245 | `core/player` | 约 700 行(Win/Linux 独立顶层窗口的对齐、z 序钩子、WM_WINDOWPOSCHANGED 子类化、`is_overlay_host`、`set_overlay_top_inset`)**整段删除** —— 视频在窗口内合成后这些全部不需要。剩下 ~1500 行是真正的 mpv 知识,逐条移植 |
| ~~`crates/danmaku-proxy`~~ | 1779 | **不迁** | 2026-09-02 已删:弹幕改回客户端内置(用户决定) |

### 3.8 不移植的

| 现有 | 处置 |
|---|---|
| `apps/desktop/src/lib.rs` 的窗口管理(~1500 行) | 删。下沉到 Avalonia |
| `ui/**/*.css` 10.4k 行 | 删 |
| `ui/**/*.tsx` 37k 行 | 删,三端重写 |
| Tauri capabilities / 权限清单 | 删。C ABI 没有这层 |
| CDP 自检台脚本 | 删,换成各端原生 UI 测试 |
| `norigin-spatial-navigation` 及 `ui/tv/components/Focus.tsx` 556 行 | 删。Compose TV 焦点白送 |

---

## 4. 差分对账机制

### 4.1 为什么必须有

单元测试证明 Go 版**自洽**,证明不了它和 Rust 版**一致**。
而这次迁移的全部价值在于"行为不变"。

本项目历史上最贵的一类 bug 是"核层单测全绿,功能从上线起一次都没跑过"
(版本正则默认传了 `versions[0].id`,正则从没生效过)。
迁移会把这类风险放大一个数量级 —— 差分对账是唯一的解。

### 4.2 录制层(Rust 侧)

在现有 Rust 版加一个环境变量开关,**不改任何业务逻辑**:

```
LP_RECORD=<dir>
```

录三样东西:

| 录什么 | 文件 | 用途 |
|---|---|---|
| 每次出网请求 / 响应(含 header、body、耗时) | `http/NNNN.json` | Go 版回放时当 mock 上游 |
| 每条命令的入参 / 出参 | `cmd/NNNN.json` | 对账的黄金输出 |
| 配置快照(前后) | `config/NNNN.json` | 验证副作用一致 |

**脱敏在录制时做,不在事后做。** token / 密码 / Cookie 一律替换成稳定占位符
(同一个原值映射到同一个占位符,保证签名逻辑仍能对账)。

### 4.3 回放层(Go 侧)

```
go run ./cmd/diffcheck --record <dir>
```

1. 起一个 mock 上游,按 `http/` 里的请求指纹返回录好的响应
2. 按 `cmd/` 顺序重放命令
3. diff 输出;差异分三类:

| 类别 | 处置 |
|---|---|
| **语义差异** | 红。必须修 |
| **已知可接受差异**(如 map 顺序、时间戳) | 归一化后再比 |
| **Rust 侧的已知 bug** | 白名单,注明 issue 号,Go 版**保持一致**不顺手修 |

第三类要特别克制:顺手修 bug 会让对账失去意义。修 bug 走独立提交,两边同时改。

### 4.4 先红验证

对账设施本身也要"先红":故意在 Go 侧改坏一个字段名,确认 diffcheck 报红。
不做这一步,你不知道对账是不是在空跑。

---

## 5. 并行期策略

迁移期两套核心并存。规则:

| 事项 | 规则 |
|---|---|
| 新功能 | **只在 Go 版做**。Rust 版功能冻结 |
| P0 bug | 两边都修,Rust 版先修(用户在用) |
| P1/P2 bug | 只在 Go 版修,Rust 版挂 issue |
| 录制包 | 每修一个 P0,补一份对应的录制,防回归 |

**冻结是硬性的。** 允许 Rust 版继续加功能 = Go 版永远追不上 = 迁移永远做不完。
这是所有重写项目的头号死因。

---

## 6. 回滚点

| 阶段 | 能否回滚 | 说明 |
|---|---|---|
| 0–2 | ✅ 完全可回滚 | 只加了录制开关,产品无变化 |
| 3 | ✅ 可回滚 | Go 核心未接入任何发布产物 |
| 4 | ⚠️ 部分 | 新 UI 已可用但旧栈仍在;两个包并存发布 |
| 5 | ❌ 单向门 | 删除旧栈。**在此之前必须有一周真机零 P0 的证据** |

阶段 5 是**唯一的单向门**。删除旧栈的提交必须单独一个 PR,commit message 里写清
"新包已在真机运行 N 天,零 P0",并附对账全绿的 CI 链接。

---

## 7. 这次迁移会顺手消灭的一批历史问题

不是承诺,是架构变化带来的必然结果:

| 历史问题 | 为什么会消失 |
|---|---|
| 全屏白边、Alt-Tab 后视频窗位置不对、DPI 变化后画面偏 | 视频在窗口内合成,几何由 OS 管 |
| WM_WINDOWPOSCHANGED 钩子重入爆栈 | 钩子整个不需要了 |
| 播放窗标题栏要在两个几何入口都减 36px | 不需要让位 |
| 透明窗口 + JS 崩溃 = 一片黑 | 没有 WebView 也没有 JS |
| CSS flex / auto-fill / transform 关键帧毁 fixed 定位 | 没有 CSS |
| React effect 依赖与 DOM 时序打架、`hidden` 被命令式改动打架 | 没有 React |
| TV 焦点矩形膨胀、焦点贴裁剪边、`.hscroll` 负 margin | 框架接管焦点 |
| Tauri capabilities 漏配导致全黑不报错 | 没有这层 |
| 前端各持 useState 副本要靠 invoke 层广播 | `config.changed` 是核心层主动事件 |

| 历史问题 | 为什么**不会**消失 |
|---|---|
| Emby fork 的各种 API 怪癖 | 服务端的事 |
| 网盘凭据轮换、扫码登录时序 | 协议的事 |
| mpv 字幕 / EOF / seek 的那批约束 | mpv 的事,原样移植 |
| 编译期凭据在 CI 漏传 | 流程的事,靠门禁 |
| "一个功能几套入口就得每套点一遍" | 三端 UI 只会让这条更重要 |
