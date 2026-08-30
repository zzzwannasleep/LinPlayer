# 架构决策与端范围

**这个领域最容易踩的坑:**
1. **端范围已定:Android 手机 / Android TV / Win / Linux,苹果全线彻底不做。** 别再提「三端」「四端」以外的组合。
2. **技术栈已定过两轮,别再论证要不要迁**:先否 RN → Rust 核 + React/TS + Tauri(已跑通并发行);2026-08-30 又定了 Go 核心 + 三端原生 UI(文档在 `docs/go-migration/`)。
3. **「跑通」≠「能力搬全」**:上一轮迁移按模块勾 ✅,实测旧栈 ~150 个能力只覆盖了 ~44。粒度必须到能力清单。
4. **合成缝的解法是结构性的**:mpv 独立顶层窗口垫在透明窗口下对齐,不是子窗口,也不是纹理合成。
5. **迁移期旧版必须冻结功能** —— 允许它继续加功能是所有重写项目的头号死因。

> 本文件共 **3** 条。每条都标了它的原记忆文件名与类型;正文按原样搬运,未做压缩或改写。

## 本页条目

- 换栈定案:Go核心+三端原生UI — `go-core-native-ui-decision.md`
- 重构决策(已定+PoC已验) — `rn-migration-evaluation.md`
- 端范围已定 — `platform-scope-decision.md`

---

### 换栈定案:Go核心+三端原生UI

> 原记忆:`go-core-native-ui-decision.md` · 类型:`project`

2026-08-30 用户决定放弃 Rust+React/Tauri,换成 **Go 核心 + 各端原生 UI**。
规格/迁移/TODO/命令契约已写在 `docs/go-migration/`(SPEC 985 行、MIGRATION 340、TODO 463、COMMANDS 377 自动生成)。

**为什么是 Go——这是约束算出来的,不是偏好。** 核心层要被 Kotlin(JNI)、Swift、C#(P/Invoke)
同时加载 → 必须能编译成 C ABI 库 → 候选只有 Go / Rust / C++。排除 Rust(用户不喜欢)
与 C++ 后只剩 Go。**C# 当不了核心层**:`.NET on Android` 是应用模型不是可嵌入库,
选它等于连 UI 层选择权一起吃掉(退化成 Avalonia 全端)。

UI:Kotlin+Compose(Android 手机+TV,`androidx.tv` 白送焦点)/ C#+Avalonia(Win+Linux)/
SwiftUI(Apple 后置)。**不要为 iOS 付溢价**——本 App 带网盘/资源站,App Store 大概率不给上,
"以后加苹果"实际含义是 macOS。

**架构的核心简化是三通道**:① 控制=C ABI/JSON 全异步+事件队列(只有 7 个导出函数)
② 数据=本地 HTTP(图片/资源/字幕/流,三端用各自的图片加载器,零 marshal)
③ 视频=一个 surface 句柄 int64。**mpv 归核心层管**(播放器知识写一遍,不是三遍)。

**唯一可能推翻选型的风险 = SPIKE-1**:Win/Linux 上视频能不能合成进 UI 场景
(Android SurfaceView / Apple CAMetalLayer 天生行,Win/Linux 不行)。
默认赌 mpv render API + 纹理互操作;失败则退 WinUI3+SwapChainPanel(不影响核心层一行)。

**验收主手段是差分对账**,不是单测:Rust 版当黄金实现,加 `LP_RECORD` 录制,
Go 版回放 diff。单测只证明 Go 版自洽,证明不了它和 Rust 版一致。
**迁移期 Rust 版功能必须冻结**——允许它继续加功能是所有重写项目的头号死因。

现有代码盘点(2026-08-30):crates 41.7k 行 Rust / apps 16.5k / ui 47.4k TS+CSS;
桌面注册 266 条命令、安卓 249(差 29 条);19 个源后端;插件引擎是 rquickjs(QuickJS)
→ Go 侧对应 `buke/quickjs-go`,**插件包零改动存活**(ABI 是 JS)。

相关:[仓库结构(2026-07重构后)](build-release.md) [重构决策(已定+PoC已验)](decisions.md) [端范围已定](decisions.md)
[PC 播放页独立窗口](player-mpv.md) [TV 端 UI 选型](ui-tv.md) [测试必须先红](methodology.md)

---

### 重构决策(已定+PoC已验)

> 原记忆:`rn-migration-evaluation.md` · 类型:`project`
>
> 🔒 原文含真实地址/账号等具体值,已替换为占位符(原文含具体值,已脱敏)。
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

用户 2026-07-14 起讨论把 LinPlayer 从 Flutter 重构。评估→拍板全程:

**1. 先否决 RN**:8 子agent逐域清点(功能全清单落 `docs/MIGRATION_RN_PLAN.md` §1,防遗忘底账)+ RN生态调研,结论 RN 不行——Linux无官方支持、mpv/PGS/超分主流RN库全缺、CF反代socket做不了、桌面原生UI无等价物、插件单VM卡死。

**2. 用户核心诉求逐步澄清**:① 已受够 Flutter 的 Win 端(media_kit陈旧+切UI闪屏「mediakit-texture-flash-swtexture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废),根因=视频过Skia/ANGLE合成器当纹理,结构性无解);② 只做 **Android(手机+TV)+Win+Linux**,无苹果设备;③ 前端要**华丽/动效/流畅**(前端不是薄层,是产品的脸);④ 体积尽量小;⑤ 信 TS 生态,起初怕 Rust(嫌先进/以为Win10不支持/嫌生态弱——均已纠正:Rust在Win10好好的,后端/网络/mpv生态很硬)。

**3. 已锁定技术栈**(方案落 `docs/RUST_MIGRATION_PLAN.md`):
- 前端 UI = **React + TypeScript**(web,跑webview;React⟺TS不可分,想华丽就得用它)
- 桌面壳 = **Tauri v2**(小体积,系统WebView2,Win10✅)
- 后端/核心 = **Rust**(单核,原生无运行时最省体积,交叉编译桌面+安卓两吃;socket钉IP+SNI/mpv是主场)
- 视频 = **libmpv-rs 驱动原生子窗口**,垫在透明webview下(**视频永不进webview**,同 Jellyfin Media Player/Plex 的 QtWebEngine+mpv 架构,可参考其壳兜底)→ 结构性免闪
- 安卓/TV UI 待定(留Flutter走flutter_rust_bridge 或 webview走uniffi),Rust核复用
- 插件系统用 **rquickjs**(Rust绑QuickJS)重建,JS插件API保留「plugin-system」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)

**Phase 0 PoC 已跑通并验证(2026-07-14)**,工程在 `native-poc/`(Tauri v2 + React/TS + Rust,手写 libmpv FFI)。已证:Rust核Emby登录/浏览/播放(走PlaybackInfo取DirectStreamUrl,别用野拼的/Videos/{id}/stream会404)、原生mpv画面+声音、**透明React UI叠mpv不闪**、release包小可跑。

**★合成缝的解法(全项目#1风险,已破,记死)**:Windows 上**不能用子窗口**(子窗口进不了逐像素透明窗口→只透到桌面看不到视频)。必须让 **mpv 用独立顶层无边框窗口(WS_POPUP+WS_EX_TOOLWINDOW|NOACTIVATE)垫在透明Tauri窗口正下方**,SetWindowPos(video, tauri_hwnd, ...) 置于其下并按 window.inner_position/inner_size 对齐,窗口Resized/Moved/Focused时重对齐。顶层↔顶层DWM正常合成,mpv自持swapchain=结构性不闪。这正是Flutter/media_kit给不了的(「mediakit-texture-flash-swtexture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废) 「native-rendering-project」(该条不在本库,多为 Flutter 时代的旧记忆,已作废) 的M2硬骨头在这被绕过)。mpv.lib由libmpv-2.dll经dumpbin+lib生成,.def必须写`LIBRARY libmpv-2`否则导入名错成mpv.dll。

**Phase 1 地基已落(2026-07-14,`cargo check`+完整`tauri build` release 双证)**:PoC 从单 Tauri 二进制重构成 **cargo workspace**——`crates/core`(`linplayer-core`,**零 tauri/windows 依赖**=桌面安卓两吃的命脉,含 http.rs 统一UA/config.rs 账号持久化重启免登/emby.rs)+ `src-tauri`(桌面壳,只剩薄命令桥+mpv.rs)。Emby 客户端迁进核并把假身份`LinPlayerPoC`换成真`LinPlayer`+统一UA(对应「unified-ua-and-prefs」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)的CDN空白坑)+持久 DeviceId。**往后每迁一模块都进 core,零返工。**
**凭据落盘决策**:token 先明文存 `config.json`(dirs::config_dir/LinPlayer/),**用户已拍板"先明文后期再升"**;config.rs 已留 Store 缝,加固放 Phase 6 备份加密时统一做(keyring 有 Linux无头/安卓Keystore 适配代价,故未上)。

**进度(2026-07-14 一口气推到 Phase 3,均编译+单测背书,逐 commit 直推 main)**:
- **Phase 1 ✅** 地基(见上)。
- **Phase 2 ✅** 播放完整度:PlaySessionId 上报三件套同 id([Emby PlaySessionId 续播](emby.md))+续播(mpv `start` 选项起播)+语言选轨(core/media.rs pick_tracks,记住手动切轨)。片头跳/ASS→SRT 推迟。
- **Phase 3 ✅ 全部完成**:core/source/ 抽象(MediaSourceBackend trait)+ 5源:OpenList/ani-rss/飞牛(authx签名)/夸克(Cookie __puus轮换 **+ TV扫码open-api x-pan-token签名+extscreen换token**)+ Emby。桌面命令桥+后端注册表(Arc<dyn>持token)+ mpv load_with_headers(逐流头)/add_subtitle。前端 Emby/网盘分页+浏览+Cookie粘贴+**扫码(qrcode渲染+轮询)**。尾巴4项已补:**302重签**(mpv事件循环END_FILE=error→重解析续播,连续3次上限防死循环)、**聚合多服搜索**(aggregate_search遍历config.accounts并行扇出+set_active_server跨服点播+前端＋服务器多账号)、**源外挂字幕**(ani-rss自鉴权URL接mpv;飞牛头鉴权受mpv全局header限制未接需重签代理)、**夸克扫码**。⚠️夸克TV/扫码是逆向接口,无真号+手机未实测。

**Why:** 该项目价值=重原生播放+含Linux全平台;这套栈让TS管脸、Rust管里子,兼顾华丽UI与真mpv与小体积。
- **Phase 4 ✅ 弹幕完成**:core/danmaku(弹弹play签名 Base64(SHA256(AppId+Ts+Path+Secret))+自建源3鉴权path/header/queryToken+p字段解析)+ 前端 src/Danmaku.tsx canvas引擎(rAF自跑,时间从500ms轮询插值平滑同步mpv;滚/顶/底三模式+描边+分道防重叠+seek大跳重置)+ config DanmakuServer + danmaku_search/load命令 + 播放页「弹」开关/「≡」搜索面板。PoC无弹弹play官方凭据→走自建源(兼容/api/v2)实测,官方源需CI注入AppId/Secret。

- **Phase 5 ✅ 网络重活(Rust 主场)全落**:核 `net/prefetch`(2-4并发Range worker超前拉流+128MB读前缓冲+seek作废在途watch-gen+302重签回调+手写最小HTTP/1.1喂mpv,仅直传流走代理转码回退直连)、`net/cf`(ranges v4/v6段采样用原生u128免BigInt+xorshift64免rand;speedtest握手延迟tokio+校验/下载测速reqwest.resolve钉IP;proxy本地钉IP反代=**reqwest.resolve(host,ip:443)一步做到钉IP+保SNI+连接池**,省掉Dart手写TLS/ByteReader/chunked——这正是Flutter HttpClient做不到的点)、`download`(单文件串行+段内1-4并发Range+partN断点续传+拼接+index.json持久化)、`config.ProxyConfig`+`http`全局代理(HTTP/SOCKS5 reqwest "socks"特性原生+mpv media挂http-proxy)。命令齐:cf_speed_test/cf_proxy_*/download_*/get|set_proxy。单测18过。⚠️CF「唯一choke point」全量改写Emby base未接(命令+能力已就绪);state.http是启动期单例,代理live切换只覆盖新建客户端(重启彻底生效)。

- **Phase 6 ✅ 同步/周边(功能全落)**:核 `ranking`(弹弹动漫榜+TMDB影视榜双源;13分类;dandan复用danmaku::signature;TMDB用AES-256-CBC/PKCS7解TMDB_API_KEY_ENC;凭据编译期option_env注入,PoC无凭据→分类空honest;6h文件缓存)、`sync`(基座:CF oauth-proxy常量<自建 oauth-proxy 域名>/api+共享密钥头+XOR混淆解client_id;SyncAccount令牌模型;**afdian_verify付费软锁走代理运行时可跑**)、`sync/trakt`(设备码登录+刷新+scrobble start/pause/stop+追剧日历,走已部署代理)、`sync/bangumi`(授权码登录+收藏/单集进度+追番日历,默认国内加速反代)、`sync/calendar`(CalendarEntry+civil_from_days免chrono)。config持久化sync_trakt/sync_bangumi。命令齐全。单测23过。**⚠️尾巴3项待**:①backup_crypto(GCM+PBKDF2,legacy-import低值)②配置迁移扫码(CommonConfig AES+gzip)③凭据加固keyring(Linux无头/安卓Keystore适配代价,一直推迟)。**播放期自动同步已接**:emby::fetch_scrobble_info抓ProviderIds+SeriesName/季/集/首播日;play→Trakt scrobble start(有外部id才发),stop→Trakt stop + Bangumi(progress≥80%触发bangumi_matcher反查subject/episode→收藏在看→单集看过,先收藏后更集)。**配置迁移扫码已落**(config_transfer:Richasy CommonConfig容器AES-256-CBC+gzip+base64url前缀LPSYNC1:,命令config_export_qr/import_qr,载荷不含明文token)。bangumi_matcher纯在线(搜番+±180天日期择优+续集链+按集号取ep)。ranking/calendar归组逻辑留前端TS。**刻意不港(非遗漏)**:backup_crypto GCM(Dart标注legacy仅向后兼容导入,新Rust端无H12历史可导→YAGNI)、keyring加固(原方案既定推迟,平台适配代价)。

- **凭据加密注入 + Trakt钩子 + 官方弹幕(2026-07-14补)**:`crates/core/build.rs`编译期读GH环境变量`DANDANPLAY_APP_SECRET`/`TMDB_API_KEY`→内置口令AES-256-CBC加密注入密文(`DANDAN_APP_SECRET_ENC`/`TMDB_API_KEY_ENC`),`DANDANPLAY_APP_ID`公开明文;`crate::secrets`运行时解密。**明文密钥不进二进制**已实证(release里明文各0命中)。弹弹签名按官方规范核对无误。Trakt播放期自动scrobble已接(`emby::fetch_scrobble_info`抓ProviderIds→play上报start/stop上报stop);Bangumi自动收藏仍缺集数matcher(命令可手动调)。官方弹幕源:有凭据回落官方弹弹Play。**⚠️构建约定**:build.rs读的是环境变量,本地/CI构建native-poc前须`export DANDANPLAY_APP_ID/APP_SECRET/TMDB_API_KEY`(缺则honest回退未配置);PoC暂无CI,接Phase8打包时把这仨env喂给cargo/tauri构建步骤即可。单测25过。

- **Phase 7 ◑ 插件系统(Rust 引擎+命令已证死,React 宿主UI待接)**:QuickJS 从 flutter_qjs 迁到 **rquickjs**,并借机**重写实现形态**(用户明确要更好的形态,非照抄):不再走 Dart 那套 `__lp_host(channel,method,argsJson)` 字符串编组(那是跨 isolate 只能传简单类型逼出来的)——改为**Rust async 函数原生绑进 ctx 返回真 Promise**(`Async(fn)`+自定义 `JsOut` 在 `into_js` 里 `Exception::throw_message` 抛真 Error),插件回调用 `Persistent<Function>` 存下直接调。**引导脚本 227 行→1 行**(只剩 `__lp_call` 包 Promise)。核 `plugins/`:manifest/permission/storage(5MB)/extensions(注册表)/host(平台缝 trait,单一 `call(channel,method,args)`)/convert(js↔json+函数抽 handler 标记)/state(权限门控+HTTPS白名单+**空转看门狗**:interrupt 只在 JS 真跑时触发,等宿主 await 期不触发=天然区分等待与死循环)/ctx(原生绑全能力,host路由类收敛到一个 `host_fn`)/engine(AsyncRuntime+内存限64MB+Drop 清 Persistent 防 abort)/installer(.ipk=zip)/**worker(专用线程 actor:QuickJS 单线程,引擎钉线程永不跨线程,manager 只持 Send 命令通道——正是 Dart isolate-per-plugin 模型;`parallel` 特性无用因 Persistent 含裸指针非 Send)**/manager(Send+Sync 门面)。**只支持 runtime:js**(data/addon 是 iOS App Store 合规专用,无 Apple 已砍,manifest 直接拒绝)。src-tauri:`DesktopPluginHost`(player→mpv/emby→当前账号/ui→事件+oneshot待回/cfproxy最小)+10 个 `plugin_*` 命令+play/stop 钩 onPlay/onPlayEnd。**证死**:单测 39 过(+8:**真 hello 插件逐字不改跑通全生命周期**——引擎启动/ctx.log/storage读写/extensions动态注册函数handler/ui.showForm宿主/manifest静态settingsPages具名handler/onEnable+权限拒绝),app release 绿。**⚠️待接(下一步)**:React 宿主 UI(渲染 showForm/showDialog/showList/showProgress 并调 `plugin_ui_respond` 回填;渲染 homeStats/sidebarItems/settingsPages 扩展点;插件管理页+权限弹窗);getCredentials 因 PoC 不存密码返 Err;cfproxy 重活未接(命令壳在)。**现有 JS 插件全兼容不用改**。

- **Phase 8 ◑ 安卓交叉编译已证死(Linux 待 Linux 机)**:`cargo ndk -t arm64-v8a build --release -p linplayer-core` 产 `liblinplayer_core.rlib`(8.6MB,readobj 验 EM_AARCH64),**整核含 rustls/tokio/数据源/网络/QuickJS 插件全套**都过。可复现脚本 **`native-poc/scripts/build-android.sh`**(全新环境+清 bindgen 缓存 exit=0 实证)。Windows 宿主 bindgen 坑(脚本已封):①reqwest 切 **rustls-tls**(default-features=false)去 openssl-sys——桌面亦通用,CF `.resolve()` 钉IP在 rustls 照常,`cargo test -p linplayer-core` 39 过+`app` release 绿无回归;②rquickjs-sys 无 android bindings→`[target.'cfg(target_os="android")']` 开 `bindgen`,经 proc-macro `rquickjs-macro`(编 host)传导 **host+android 两 bindgen 都要喂**;③需**带 libclang.dll 的 NDK**(30.x 有/27.x 无);libclang 当 DLL 加载 InstalledDir 空→显式 `-resource-dir` 补 stdbool,host(msvc)从 vcvars64 灌 `%INCLUDE%` 补 stdio,预置 `BINDGEN_EXTRA_CLANG_ARGS_<triple>` 后 cargo-ndk 不补 sysroot 故自带 `--sysroot`。**⚠️坑复盘**:脚本变量别叫 `TMP`(Windows 临时目录env,覆盖成文件→link.exe LNK1104);`export VAR-带横杠` bash 拒→用 `env` 前缀;vswhere 默认不列 BuildTools→直接 glob vcvars64.bat;`%INCLUDE%` 在 `cmd /c` 解析期就展开(空)→必须临时 .bat 逐行运行取。**⬜ 真出 .so 需 cdylib 绑定壳(core 是 rlib)+定安卓 UI**;⬜ Linux GL 子窗口合成需 webkit2gtk+Linux target,Win 上无法验。

##### ⚠️ 2026-07-15 大翻车:「Phase X ✅」全是虚的,别信

**根因:`docs/RUST_MIGRATION_PLAN.md` 的颗粒度停在「模块」,没有「能力清单」** → 照它勾 ✅,实际大面积漏搬。用户原话:「为什么会有接口缺少 移植文档里面没写吗」。

**实锤**(拿旧 Dart 逐方法对出来的):
- **Phase 2「播放完整度」✅ → 实为 ◑**:旧契约 `lib/core/services/video_player_service.dart` 有 30+ 能力,新栈只搬了 10 个(load/pause/seek/track)。**倍速/音量/截图/画面比例/音频延迟/字幕延迟/字幕样式/次字幕/外挂字幕/超分/mpv属性直通 全漏** → UI 上一排「点了没反应」的死按钮。**而它自己列的「片头跳」当时也没做。**(现已补齐 18 个命令 + `src-tauri/src/shaders.rs` Anime4K)
- **Phase 4「弹幕」✅ → ◑**:正文写的「匹配/缓存/过滤」**代码 0 行**。
- **Phase 3「数据源」✅ → ◑**:ani-rss 旧 `anirss_api.dart` **47 个方法**,新栈只搬 login+浏览,**管理接口 0 个**;源服务器**纯内存不持久化,重启全丢**。
- **Phase 1「配置」✅ → ◑**:`Account` 4 字段 vs 旧 `ServerConfig` **14 字段**(缺 name/remark/icon/**lines**/source_kind/allow_insecure_tls…)→ 服务器页 6 条 P0 的**公共根因**,且 **CF 优选没有 choke point 可挂**。
- **Phase 5「网络」✅ → ◑**:引擎全在,**出口没接**(`completed_path` 写了没暴露 → 下载页 ▶ 必死);预取线程/上限写死。
- **文档压根没写的整块**:字幕翻译(`lib/core/services/translation/` 6 子模块含 Whisper)、**本地观看记录/跨服续播**(`watch_history/` 6 文件,技术选型表提过一句但 8 个 Phase 无一认领)、Emby 客户端补完(旧 `emby_api.dart` 35 方法)、服务器管理(线路/图标/备注/排序/批量/深链)。已在文档补 Phase 6.5/6.6/6.7。

**合计:旧栈 ~150 个非播放器能力 → 新栈覆盖 ~44,缺 ~106。**

**规矩(已写进文档 §5 抬头)**:① **旧 Dart 代码是权威,文档不是**;动手前先列对应 Dart 服务/抽象类的公开方法当清单。② **能力粒度,没有「能力→Dart契约→Rust命令→状态」表就不许打 ✅**。③ UI 侧权威是 `native-poc/docs/desktop-drafts.html`,它会要求文档没写的桌面新交互,两边都得对。④ 禁止摆控件不接线,禁止把有后端的写成「待接」(先 grep `#[tauri::command]` 全表)。

##### 真实服务器实测推翻的三条(纸上谈兵会错)
拿 [Emby 测试服务器](emby.md) curl 打出来的,**别信任何"应该"**:
1. **Emby 单次请求硬上限 200**:`Limit=500/1000` 一律只回 200,省略 `Limit` 只回 20,`Limit=0` 也是 20。→ 旧代码 `favorites` 写 `Limit=300`、`episodes` 写 `Limit=500` 全是**静默丢内容**(库实测 4043 条只拿 200)。**唯一正解是 StartIndex 翻页**(已加 `fetch_all_paged`,真机验过:两页交集 0、合并去重 400、StartIndex=4000 正确返末尾 43 条)。`ItemPage{items,total}` 的 total 就是为翻页返的。
2. **`searchTerm` 小写被服务端静默忽略** → 原实现**一直在吐全库前 50 条冒充搜索结果**(`TotalRecordCount=25596`)。必须 `SearchTerm` 大写。这是只有实测才抓得到的真 bug。
3. **服务端过滤是假的**:`Genres`/`GenreIds`/`Years`/`MinCommunityRating` 全被忽略(total 与不筛完全一致)→ 必须客户端复筛兜底。且 **`/Items/Filters` 在这台(Emby 4.9.3)404**,`/Years` `/Tags` `/OfficialRatings` 也 404(**旧 Dart 的年份/标签分面其实一直是空的**),只有 `/Genres` `/Studios` 通。

**How to apply:** Phase1-6「跑通」+Phase7 Rust侧证死+Phase8 安卓交叉编译证死(共27+ commit直推main)。**但「跑通」≠「能力搬全」,见上。**核模块:`http/emby/config/config_transfer/media/danmaku/download/ranking/secrets/sync(trakt|bangumi|bangumi_matcher|calendar)/net(prefetch|cf)/source(×5)/plugins(engine|ctx|host|worker|manager|manifest|permission|storage|extensions|convert|installer)`。单测39过。**别重港已完成的/别重搭workspace/别港已决定不港的(backup GCM/keyring)**。下一步:**Phase7 React 宿主UI**(接 `plugin://ui-request` 事件+`plugin_ui_respond` 命令,渲染扩展点+管理页,管道已铺好)+ 用户要自己动手做 PC 端 UI;安卓 UI/Linux 合成留后。别再论证要不要迁/用什么栈——已定并验证。

---

### 端范围已定

> 原记忆:`platform-scope-decision.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

2026-07-15 用户定：**PC 端只做 Win + Linux。**

已就地执行（commit `1e152712`，173 个文件）：
- 删 `ios/` `macos/` `apple_tv/`（tvOS 的 SwiftPM 工程）
- 删 `lib/desktop/` `windows/` `linux/`
- 删 CI 五个 job：build-ios / build-tvos / build-macos / build-windows / build-linux
- 删 pubspec 三个桌面依赖：fluent_ui / macos_ui / window_manager

**现存端**：Android 手机 + Android TV（Flutter，仍在维护，以后也会迁 Rust）；
Win + Linux（Rust+React+Tauri，见 「pc-ui-react-build」(该条不在本库,多为 Flutter 时代的旧记忆,已作废) 与 [重构决策(已定+PoC已验)](decisions.md)）。

**Why**：PC 迁 Tauri 已定且 PoC 跑通；苹果线投入产出不划算，索性砍干净而不是留着腐烂。

**How to apply**：
- 别再提「三端」「四端」——现在是 Android手机/AndroidTV/Win/Linux 四个，且**无苹果**。
- 见到 `Platform.isMacOS` / `isIOS` / `isDesktopPlatform` 分支：那是删剩的死代码，
  不必特意清（无害），但**别再往里加东西**。
- 顺带弃掉的：Flutter 原生渲染 M1（`windows/runner/native_mpv_render.*` +
  `windows_native_mpv_adapter.dart`，从未入库）。它与 Tauri 栈治同一个病
  （开面板整屏闪/ANGLE 逐帧税），Tauri PoC 已赢。「native-rendering-project」(该条不在本库,多为 Flutter 时代的旧记忆,已作废) 已作废。
- `windows/mpv-config/` 曾是 **uosc v5.12.1（GPL-3.0）**，vendor 无许可证，
  而 CMakeLists 声称「无第三方」。已随删除绕开该合规问题。日后若再引第三方，
  先带 LICENSE 再说。

---

## 跨域交叉引用

这些条目和本领域强相关,但正文放在别的文件里(一条经验只存一份正文):

- [仓库结构(2026-07重构后)](build-release.md) — 2026-07 重构后的目录结构与路径换算表
- [TV 端 UI 选型](ui-tv.md) — TV 端 UI 选型(已落地)
- [PC 播放页独立窗口](player-mpv.md) — PC 播放页独立窗口
- [端范围已定](decisions.md) — 本页内:端范围与苹果全线不做
