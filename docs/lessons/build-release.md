# 构建 / CI / 发布 / 版本 / 打包 / 仓库卫生

**这个领域最容易踩的坑:**
1. **版本号的唯一权威是 `apps/desktop/tauri.conf.json`**,仓库重组会静默把它顶退(1.0.0→0.1.0 = 老用户永远收不到更新);GitHub `/releases` 的返回顺序也不可依赖。
2. **构建 job 漏传编译期凭据 = 功能静默残废而 CI 全绿**,看起来像「功能没做」。
3. **PowerShell 5.1 按 GBK 读无 BOM 的 UTF-8**:批量重写中文源码会乱码,`.ps1` 含非 ASCII 不带 BOM 会吞掉下一行代码而 CI 照样绿。
4. **禁用 `git add -A`**;构建产物必须 gitignore,反向也要查「漏提整个目录」。
5. **数据全在 exe 同级 `userdata/`**,唯一出口是 `paths.rs`;WebView2 profile 和进程 TEMP 会绕过它,必须单独按住。

> 本文件共 **11** 条。每条都标了它的原记忆文件名与类型;正文按原样搬运,未做压缩或改写。

## 本页条目

- 仓库结构(2026-07重构后) — `repo-layout-2026-07.md`
- 仓库卫生红线 — `repo-hygiene.md`
- 脚本能拉的别入库 — `dont-commit-fetchable-artifacts.md`
- PC 绿色包单一数据根 — `pc-single-data-root.md`
- 发布版本单调性 — `release-version-monotonicity.md`
- CI 漏传编译期凭据 — `ci-missing-compiletime-secrets.md`
- 分发通道 GitHub 优于 CF — `dist-channel-github-over-cf.md`
- PC 端接入 Linux — `linux-desktop-integration.md`
- Linux 选外部播放器列不出文件 — `linux-executable-picker-filter.md`
- PowerShell GBK/UTF-8 坑 — `powershell-gbk-utf8-corruption.md`
- Bash 别用 PS heredoc — `bash-no-powershell-heredoc.md`

---

### 仓库结构(2026-07重构后)

> 原记忆:`repo-layout-2026-07.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

**2026-07-19 全面重构落地(commit 0dd295fe)。Flutter/Dart 499 个文件 + 苹果全线已从仓库删除,原 `native-poc/` 提到仓库根。** 回滚点:`git tag flutter-final`(已推远端)。

##### 现在的结构

```
crates/core/       各端共用的 Rust 业务核心(数据源/网络/配置/播放控制)
apps/desktop/      Tauri 2 桌面壳(原 native-poc/src-tauri) —— Win/Linux
apps/android/      待建。直接链现成 libmpv .so,不自建 JNI 封装(用户 2026-07-19 定)
ui/shared/         各端共用前端层:api.ts / theme.ts / tokens.css
ui/desktop/        PC UI(原 native-poc/src)
ui/mobile/ ui/tv/  待建
public/ scripts/ docs/ oauth-proxy/
根级:Cargo.toml(workspace) package.json vite.config.ts tsconfig.json index.html
```

##### 路径映射(读老记忆时按这个换算)

| 老路径 | 新路径 |
|---|---|
| `native-poc/src/lib/api.ts` | `ui/shared/api.ts` |
| `native-poc/src/theme/theme.ts`、`tokens.css` | `ui/shared/` |
| `native-poc/src/**` 其余 | `ui/desktop/**` |
| `native-poc/src-tauri/**` | `apps/desktop/**` |
| `native-poc/crates/core` | `crates/core` |
| `native-poc/docs/desktop-drafts.html` | `docs/desktop-drafts.html`(仍不入库) |
| `lib/`、`android/`、`windows/`、`linux/`、`ios/`、`macos/`、`third_party/` | **已删除** |

##### @shared 别名

前端跨层引用一律 `@shared/api`、`@shared/tokens.css`,不写相对路径(各端目录深度不同)。别名定义在**两个地方,必须逐字同步**:`vite.config.ts` 的 `resolve.alias` 与 `tsconfig.json` 的 `compilerOptions.paths`。只改一边 → vite 绿、`tsc` 红,而 `npm run build` 是 `tsc && vite build`。

##### 「两处只改了一处」是本仓库的高发病(全部已有 cargo test 守卫)

跨文件必须逐字同步的地方,漂移**都不报错**,只是某一边静默失效。已栽过四次,现在每处都有测试钉:

| 两处 | 漂移后果 | 守卫测试 |
|---|---|---|
| `vite.config.ts` 的 alias / `tsconfig.json` 的 paths | vite 绿、`tsc` 红 | (见本文上方 @shared 段) |
| 核层 `shaders::levels()` 家族名 / `App.tsx` 的 `SHADER_FAMILIES` | 那一族**整组从面板消失** | `shader_family_groups_match_the_core_level_table` |
| `tauri.conf.json` 的 `mainBinaryName` / `build.yml` 两个 job 的产物路径 | **改名只改一半**:Windows 绿、Linux 炸「缺少产物」 | `ci_binary_paths_match_main_binary_name` |
| `scripts/pack-portable.ps1` 的 ASCII-only 约定 | 见 [PowerShell GBK/UTF-8 坑](build-release.md) | `pack_script_stays_ascii_only` |

**教训**:`d9a24706` 加 `mainBinaryName` 时以为只影响 Windows —— 它对**所有平台**生效。
Windows job 先跑完且绿,红的是后面的 Linux job,**只看一个平台绿会漏判**。
`.pdb` 跟的是 **crate 名(app)** 不是 mainBinaryName(MSVC 规矩),守卫里显式放行,别"顺手改整齐"。

写这类守卫时注意:**扫描器会扫到你自己注释里的字面量**(我写的注释含旧路径,当场被自己的测试抓红)。

##### 已作废的记忆

Flutter 时代的这些条目现在只有历史价值,**别照着它们找文件**:「desktop-native-ui-architecture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)、[Android libmpv LFS in CI](android.md)、[Android R8 JNI keep](android.md)、[Android mpv subtitle fonts](player-mpv.md)、「android-storage-and-mpv-logs」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)、「windows-libmpv-clean-build-gotcha」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)、「windows-gradle-cross-drive-fix」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)、「mediakit-texture-flash-swtexture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)、「tv-mobile-look-refactor」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)、「tdesign-integration」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)、「motion-system」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)。安卓/TV 端 UI 要重建时,功能清单仍看 `docs/MIGRATION_RN_PLAN.md`,但实现路径一律作废。

##### 踩过的坑(重构当天)

- **`sed` 的 `#` 分隔符和注释里的 `#` 撞车**,一条命令把 build.yml 整个写烂(每处 6 空格被替换)。批量改带中文注释的文件用 Python 显式 `str.replace`,别玩分隔符轮盘赌。同理 `sed` 的替换串里 `\t` 会被当制表符 —— Windows 路径 `apps\desktop\tauri.conf.json` 被写成 `appsdesktop<TAB>auri.conf.json`。**每次批量替换后必须回读校验**,两次都是这么抓到的。
- **`target/` 里缓存着旧的绝对路径**,tauri 的 build script 报 `failed to read plugin permissions: ...native-poc/target/...`。改目录名后 `cargo clean -p app -p tauri`。
- **Rust 测试用 `include_str!` 直接读前端源码**做一致性断言(`apps/desktop/src/lib.rs` 4 处)。移动前端目录必须同步改,否则 `cargo test` 红而 `cargo build` 绿。

**Why:** 新栈一直寄生在 Flutter 工程里当二等公民 —— 根目录是 pubspec.yaml,真正在演进的代码缩在一个叫 "poc" 的子目录,名不副实的结构会持续误导每一次改动。
**How to apply:** 见 [端范围已定](decisions.md) 确认端范围;PC UI 继续在 `ui/desktop` 逐页接线,见 「pc-ui-react-build」(该条不在本库,多为 Flutter 时代的旧记忆,已作废);仓库卫生红线(禁 `git add -A`)见 [仓库卫生红线](build-release.md)。

---

### 仓库卫生红线

> 原记忆:`repo-hygiene.md` · 类型:`feedback`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

用户 2026-07-15 明确：**「不是必要的肯定不提交到仓库啊？」**

**Why**：我用 `git add -A` 差点把 244MB 构建产物 + 一个无关的 `Hills_1.7.2.apk.apks`
提上去。事后 reset 挡住了，但把「别提错」寄托在自己复查上本身就是错的。
而顺着这句查下去，发现**方向是反的**：不该进的差点进，该进的一直没进
——`native-poc/src/` 的 37 个 React 文件从未入库，只活在一台机器的磁盘上。

**How to apply**：
- **禁用 `git add -A` / `git add .`**。这个仓库长期有大量无关脏改动（多条工作线并行），
  一律逐个 `git add <path>` 显式列举。
- 提交前跑一遍：`git status --porcelain | grep "^[AM]"` 自己核一遍清单。
- **构建产物必须 gitignore**，别靠人眼躲：
  - `native-poc/dist-portable/`（pack-portable.ps1 输出，240MB）—— 原 `dist` 匹配不到它
  - `*.apks` —— 原有 `*.apk` **匹配不到** bundletool 的 APK Set，差一个字母
- 用户明确**不入库**的本地工作材料：`native-poc/docs/desktop-drafts.html`（UI 原稿）、
  `native-poc/scripts/pack-portable.ps1`（打包脚本）。理由：GitHub 工作流用不上。
- 反向也要查：`git ls-files <dir> | wc -l` 对比磁盘文件数，能揪出「漏提整个目录」。

**验证 gitignore 必须正反两面**：既验垃圾被命中，也验源码没被误伤
（`git check-ignore -v <junk>` 与 `git check-ignore -q <源码> && echo 误伤`）。

**2026-07-17 补（用户）**：「不要把构建产物和仓库无关产物提交上去就行；很多改动都是有必要的，
你不知道不清楚的可以问我。」→ **无脑排除的只有构建产物/无关产物这一类**；其余拿不准的
**别自作主张**（既别硬塞、也别硬排除），**问用户**。用 AskUserQuestion 按组列清单让他勾。
- 教训同一天两次：① 整体 `git add native-poc/` 把 `desktop-drafts.html`+`pack-portable.ps1`
  （本条上面明确「不入库」）又扫进 209d0f56 —— 广加目录会重犯这条红线，**新增文件必须逐个过眼**。
  ② 差点把整摊 Flutter/原生渲染源码当"非本轮"跳过，其实是必要改动。
- 分组判据:构建产物(ios/Generated*、GeneratedPluginRegistrant、*/build、ephemeral)=排除;
  第三方可拉取(uosc=windows/mpv-config)=按 [脚本能拉的别入库](build-release.md) 默认不提、问用户;
  手写源码(lib/*.dart、windows/runner/native_mpv_render.*、.glsl)=提。

相关：[Git workflow](methodology.md)（直接提 main 不开分支）、[脚本能拉的别入库](build-release.md)

---

### 脚本能拉的别入库

> 原记忆:`dont-commit-fetchable-artifacts.md` · 类型:`project`

TV 的 mihomo 内核 + zashboard 面板（38MB / 311 文件）曾被误提进仓库，
而它们自己的 README 白纸黑字写着「获取方式（**不入库，按需拉取**）」。
已出库（commit `22582092`）：`git rm --cached` + `.gitignore` + **CI 补 fetch 步骤**。

**Why 三件事必须同时做**：CI 的 `build-android-tv` 确实打 `--flavor tv`，却从没跑过
`scripts/fetch_mihomo_tv.ps1`。单删文件的话 —— 构建照样绿、APK 照样能装，
只是包里没内核，TV 代理功能**悄悄失灵**。这是本项目最危险的那类 bug。

**How to apply**：
- `.github/workflows/build.yml` 的 TV job 里，`flutter build` 前有
  `Fetch TV proxy kernel` 步骤。**刻意不加 `|| true`** —— 拉取失败必须让 job 红。
- `scripts/fetch_mihomo_tv.ps1` 的两个坑（已修，别改回去）：
  - **不能用 `$env:TEMP`**：Linux/macOS 的 pwsh 上它是空的，`Join-Path $null` 直接抛错。
    CI 是 ubuntu-latest，用 `[System.IO.Path]::GetTempPath()`。
  - 脚本自带校验：内核 <1MB 或 zashboard 缺 index.html 即 `throw`。内核不入库后，
    这脚本是「包里有没有 mihomo」的唯一保证，拉个空壳必须当场炸。
- 本机验这个脚本要用 **pwsh 7**（已装）。PowerShell 5.1 按 GBK 读 UTF-8 无 BOM 的
  .ps1 → 中文注释乱码 → 解析失败，那是假故障，见 [PowerShell GBK/UTF-8 坑](build-release.md)。
- **删 CI job 后必须查 `needs` 悬空**：`create-prerelease` 两次都还 `needs` 已删的 job，
  GitHub 会让整个 workflow 直接报错。用 yaml.safe_load 解析后逐个对 job 名。

相关：[仓库卫生红线](build-release.md)、[端范围已定](decisions.md)、「tv-native-mpv-and-mihomo」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)

---

### PC 绿色包单一数据根

> 原记忆:`pc-single-data-root.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

**PC 端(Rust+Tauri)是压缩包/绿色包分发的**(用户 2026-07-17 明确:「我分发都是压缩包的形式…userdata 也好 temp 也好 cache 也罢 都得在这个压缩包里面」)。
解压即用、**删文件夹即卸载**。落盘路径唯一出口 = `native-poc/crates/core/src/paths.rs`。

**根**:`<exe 同级>/userdata/`(默认,不需要任何 marker)。
优先级 `set_root()` > `LP_DATA_DIR` > exe 同级 > 系统目录(**仅** exe 目录不可写时的兜底,
`RootKind::SystemFallback`,设置页必须显眼告警)。可写性用**写探针文件**判定,不能只看
`create_dir_all` —— Program Files 的 UAC 虚拟化会让建目录"成功"却把写入重定向到 VirtualStore。

布局:`config.json`+`translation.json` / `data/`(观看记录·plugins·whisper-models·bin)/
`cache/` / `temp/` / `webview2/` / `logs/` / `downloads/`。
`data` vs `cache` 分开是为了让清缓存 = `remove_dir_all(cache)+temp` 一句话。

##### 三个绕过 paths.rs 的坑(光收拢 dirs:: 调用管不到)
1. **WebView2 profile**:不是我们代码写的,是运行时自己建的,默认落 `%LOCALAPPDATA%\<identifier>\EBWebView`,
   **实测 126MB**,且装着前端 localStorage(弹幕设置/搜索历史,所以**不能**放 cache/)。
   必须在 Rust 侧 `WebviewWindowBuilder::data_directory(paths::webview_dir())` —— 为此主窗口
   从 tauri.conf.json 挪到 `lib.rs` setup() 里建(conf 的 dataDirectory 只吃相对路径且强制拼在 %LOCALAPPDATA% 下)。
2. **进程 TEMP**:`redirect_process_dirs()` 在 run() 第一句把 TEMP/TMP/TMPDIR 指到 userdata/temp。
   改环境变量是结构性的 —— 逐个改自家 temp_dir() 是白名单,管不到第三方库和 ffmpeg/whisper 子进程。
   (edition 2021,set_var 安全;必须在起线程前调)
3. **identifier 根有两个**:插件在 Roaming 侧 `com.linplayer.poc\plugins_root`,EBWebView 在 Local 侧。

##### 迁移(migrate_from,旧根全从参数注入)
- 挂在 `root()` 首次调用上,**不能**是 run() 里的显式一句:曾经写成显式调用而 `AppConfig::load()` 排在前面 →
  load 读不到就 gen device_id 并 save() 落个空 config → 迁移见目标已存在就跳过 → **升级即掉账号,且不报错**。
- 先接"上一版系统根"(`data_local_dir()/LinPlayer` 新布局)再搬更老的 Roaming 布局。这条也覆盖
  SystemFallback→Portable 回流(用户把包从 Program Files 挪到 D 盘,数据得跟回来)。
- Windows 上 `cache_dir()/LinPlayer` **就是**旧的系统根,清理只能按确切名字删;收尾用 `remove_dir`(只对空目录成功)。
- **`migrate_legacy` 里有 `if cfg!(test) { return; }`**:本次重构中一次普通 `cargo test` 就把开发者真实的
  config.json(2 个带 token 的账号)从 %APPDATA% 搬走了 —— image_cache 测试会调 cache_dir()→root()→迁移。
  root 默认 exe 同级后,测试 exe 在 target/ 下,于是 `cargo clean` = 删账号。**别摘这个守卫**。

8 条测试全部按 [测试必须先红](methodology.md) 反向注入验证过会红。已真机跑 app.exe 端到端验证:
userdata/ 落在 exe 同级、webview2/EBWebView 进包、系统里 com.linplayer.poc 归零、2 个真账号+6.6KB 观看记录接回。

##### 老 Flutter 桌面版遗留(`<LinPlayer>/Linplayer/`)的处理界线
迁移**只清它的纯缓存**(Local 侧 `persistent_image_cache` 实测 60MB + `video_stream_cache`),
**绝不碰 Roaming 侧的用户数据**(`shared_preferences.json` 实测存着 5 台服务器 /
`flutter_secure_storage.dat` 凭据 / `watch_history.json`)—— 替别的应用删缓存可以,删数据不行,
用户还可能回退用旧版。有测试钉这条界线。Roaming 侧那 125K 至今保留,要不要导入这 5 台服务器是**待决**。

##### 已知遗留
- 旧 `<exe同级>\downloads` 的文件+index.json 不搬(可能跨盘几 GB,启动复制会卡死),旧下载不进列表。
- 截图仍落 `图片\LinPlayer`(用户预期位置,不算乱拉)。
- **dev 构建的数据在 `target/debug/userdata`,`cargo clean` 会连账号一起删** —— 开发时想保命就设 LP_DATA_DIR。
相关:[仓库卫生红线](build-release.md) [端范围已定](decisions.md) [PC 窗口 chrome](ui-desktop.md)

##### 系统里只留一个注册表键(用户 2026-07-19 定案:保留)

`paths.rs` 把落盘全收进 `userdata/` 了(temp/webview2 也按住了),但 **`linplayer://` 协议注册
是往 HKCU\Software\Classes\linplayer 写注册表键**,删文件夹带不走 —— 实测开发机上这个键
确实还在。而存储设置页当时写着「**不往系统任何地方写**」,是个做不到的承诺。

**用户定案:这个键保留,不给开关** —— 「不算残留 就一个而已,关掉了深链接怎么自动打开」。
我一度做了 `Prefs.deep_link_scheme` 开关 + `reg delete`,已按用户意见整体撤回
(教训:发现「承诺与事实不符」时,该改的是**那句承诺**,不是急着加开关让用户去关功能)。
保留的做法:存储设置页如实写明键的位置与用途,不再吹「不往系统任何地方写」。

**截图定案:默认系统图片文件夹,且可自选目录。** `Prefs.screenshot_dir: Option<String>`
(None=`dirs::picture_dir()/LinPlayer`),命令 `get/set_screenshot_dir`,设置页填路径+保存
(核层当场 create_dir_all 验证可写,不可写直接报错,不等用户按了截图键才发现)。
★ `screenshot` 命令原来直接回落 picture_dir(),**等于把设置项架空**(前端 screenshot() 从不传 dir)
—— 加设置项时必须同步改真正的消费点,否则就是又一个 [「待接」多半是谎](methodology.md)。
原生目录选择器已加(用户 2026-07-19 要的):`tauri-plugin-dialog`,
★ **只用它的 Rust API**,包进我们自己的 `pick_directory` 命令 —— 于是
**不用装 npm 包、也不用往 capabilities 加 dialog 权限**(那些只在前端直接 invoke 插件命令时才要)。
这个包法值得复用:以后要文件/目录对话框都照这个来,别习惯性地走「npm 包 + capabilities」三件套。
路径框保留手填(粘贴/网络路径比翻对话框快),选择器 set_directory 定位到当前值。

查法:`reg query "HKEY_CURRENT_USER\Software\Classes\linplayer"`。

**新增跨语言守门人**:`every_frontend_invoke_names_a_registered_command`(src-tauri/src/lib.rs)——
扫 api.ts 里所有 `invoke<T>("cmd")`,断言每个名字都在 `generate_handler!` 注册过。
漏注册不会编译报错,只在用户点到时抛 command not found。反向注入(删一行注册)验证必红。

##### 本地打包三段式 + 构建凭据(用户 2026-07-19 两次点名)

**凭据**:仓库根 `D:\LinPlayer\hjbl.env`(已 gitignore `*.env`,未跟踪)存
`DANDANPLAY_APP_ID / DANDANPLAY_APP_SECRET / TMDB_API_KEY` —— 正是
`crates/core/build.rs` 消费的三个名字。**不加载它构建出来的是残废版**:
默认弹弹源不工作、TMDB 影视榜不亮,而且**不报错**(option_env! 缺省=未配置)。
我连续几次交给用户的包都是没带凭据的,用户点名:「我给过你 env 文件 你自己找一下」。
→ `scripts/pack-portable.ps1` 现在自己加载 env 再 build(所以 npm script 不能再先跑 tauri build)。
→ 构建后**回读校验**:在 exe 字节里搜 app_id(明文注入的公开标识),找到才报
  `credentials baked in`;否则 WARN。别再「以为带了」。

**三段式**(用户原话:「先在一个目录构建出来 然后打包成适合分发的zip 然后用一个目录解压出来 我去里面测试」):
```
dist-portable/build/      构建产物,只有 exe+dll,每次清空重建(应用从没在这跑过)
dist-portable/*.zip       从 build/ 打 —— 结构上不可能混进个人数据
dist-portable/LinPlayer/  真解压 zip 得到,用户在这测;userdata/ 跨次保留
```
**为什么必须三个目录**:app 把 `userdata/`(账号+token)写在 exe 旁边。构建目录和测试目录
合一时只能二选一地烂 —— 要么打包清空它(用户登录没了),要么把它压进 zip
(**用户的账号和 token 发给所有人**)。这两种我都犯过。分开之后 zip 的来源目录
从没跑过应用,想混进去都没机会;而测试目录是真解压 zip,测的就是用户拿到的东西。

**别再犯**:`npm run pack` / `pack:fast` 必须在 `native-poc/` 下跑(仓库根没有 package.json)。

---

### 发布版本单调性

> 原记忆:`release-version-monotonicity.md` · 类型:`project`

2026-07-19 用户发现「v1.0.0-build557-pre 排在 v0.1.0-build566-pre 前面」,查出两个真 bug。

##### 1. 版本号被仓库重组静默顶退

`0dd295fe 重组为 apps/+ui/+crates/` 把 native-poc 的 `tauri.conf.json`(version `0.1.0`)
提到 `apps/desktop/`,**顶掉了原来 `1.0.0` 的口径**。没有任何报错。

后果:`compare_versions` 先比 major → `0.1.0-buildN` 对装了 `1.0.0` 的用户**永远不算更新**,
界面显示「已是最新」。整整 6 个预发布包(build561~566)对老用户是隐形的。

**教训**:版本号的唯一权威是 `apps/desktop/tauri.conf.json` 的 `version`
(build.rs 注入 Sentry release / vite 做 sourcemap release / CI 命名 zip 全读它)。
**搬动或替换这个文件时必须回读 version** —— 它退一位,发布链路就断,而且全程零报错。

##### 2. GitHub `/releases` 的返回顺序不可依赖

`update.rs` 原注释:「GitHub 按时间倒序返回,取第一个非草稿的」—— **这句话是错的**。
2026-07-19 实测(真实仓库):

| tag | id | created_at | published_at |
|---|---|---|---|
| v1.0.0-build557-pre | 356263112 | 05:05 | 05:17 | ← 排第 1 |
| v0.1.0-build566-pre | 356398423 | 17:35 | 17:43 | ← 排第 2 |

**id / created_at / published_at 三个键都是后者更大或更晚**,却排在后面;
而 v1.0.0-build556 又落到第 7 位,连 semver 排序也不自洽。

后果是「**降级伪装成升级**」:把代码更旧、版本号更大的包当最新版推给用户。

**修法**:预览版渠道改用自己的 `compare_versions` 取最大值
(抽成纯函数 `pick_newest_release`,因为 `check()` 要联网测不动)。
发布链路的正确性不该寄托在第三方一个没写进文档的返回顺序上。

新测试按 [测试必须先红](methodology.md) 做了反向验证:换回 `.find(第一个)` 确认变红,
报错正是 `left="v1.0.0-build557-pre" right="v1.0.2-build566-pre"`,精确复现降级场景。

##### 泛化

这两条都属于同一类:**静默失效,CI 全绿,只有用户那边不对**。
本仓库这类坑已经反复出现(见 [「待接」多半是谎](methodology.md)、[PC 端接入 Linux](build-release.md) 的
libmpv soname)。凡是「发布链路 / 版本比较 / 平台依赖」的假设,要么用真数据验证,
要么在 CI 里加断言,别靠注释 —— 注释正是这次被证伪的那个东西。

---

### CI 漏传编译期凭据

> 原记忆:`ci-missing-compiletime-secrets.md` · 类型:`project`

**编译期注入的凭据漏配,是一类「没有任何运行时信号」的故障。**
`crates/core/build.rs` 读不到 `DANDANPLAY_APP_ID/APP_SECRET`、`TMDB_API_KEY` 就**静默不注入**,
运行时 `available_categories()` 返回空 → 前端诚实显示「没有可用的榜单」。
于是:CI 全绿、包正常出、装得上跑得起来,**看着像功能没做**。

2026-07-21 实例:`build-android` job 从建起来那天就没传这三个变量
(Windows/Linux 两个 job 一直有)→ TV 端排行榜整页空白。

**已设闸门**:`scripts/check-workflows.sh` 尾部——凡是 `run:` 里含 `tauri build` /
`tauri android build` 的步骤,三个变量一个都不能少(step env 和 job env 都算)。
它挂在 version job 的 "Check workflow shell syntax" 上,最先跑、最便宜。
反向验证过:摘掉安卓那段 env → exit 1;恢复 → exit 0,识别到 3 个构建步骤。
**新增构建 job 时它会自动覆盖**(按 run 内容识别,不是写死 job 名)。

**排查手法(不需要本地有凭据)**:用 [挂真机 CDP 调试](methodology.md) 挂**已发布的正式包**
——它自带凭据——直接 `invoke('ranking_categories')`。这一步就把
「密钥没注进去」和「注进去了但请求失败」彻底切开。再拿同一套凭据的另一条链路做 A/B
(弹幕 `danmaku_search` 与排行榜共用 AppId/Secret 和 `danmaku::signature`),
一次就定位到是**某一族接口**的问题而非凭据/签名/网络。

**同族教训**:错误不许吞成空集合。原 `fetch_dandan` 有 6 条 `return vec![]`
(缺凭据/请求失败/非 JSON/success=false/缺字段),五种成因长得一模一样。
已改成 `Result<_, String>` 并带上 errorCode/errorMessage/HTTP 状态/缺哪个环境变量。
见 [测试必须先红](methodology.md)、[Ranking architecture](danmaku-sync.md)。

---

### 分发通道 GitHub 优于 CF

> 原记忆:`dist-channel-github-over-cf.md` · 类型:`feedback`

**用户 2026-07-23 口径：「国内网络更适合 GitHub，CF 有地方会阻断，GitHub 反而不会。」**

我当时的直觉判断是反的 —— 以为 `raw.githubusercontent.com` 在国内不可达、应该把插件包挪到 Cloudflare Pages 同域取。
用户当场纠正：**方向反了**。

##### 落到具体决策

| 资产 | 通道 | 备注 |
|---|---|---|
| 插件 `.ipk` 包 | **GitHub raw** | 保持现状，别动 |
| `registry.json` | **GitHub raw** | 同上 |
| 插件图标 | **构建时压成 data URI 内联进 registry.json** | 绕开一切网络问题；SVG 1–3KB，几十个插件也就几十 KB |
| 市场网站 | Cloudflare Pages | 不变。网站可达性不影响 App —— App 只读 registry 和包 |

**Why:** 「国内访问 GitHub 慢/不通」是个过时的刻板印象，会导致把工作量花在反方向的"优化"上，
还可能把本来能用的通道换成实际更差的。这类可达性判断**必须问用户实测口径，不要凭常识推断**。

**How to apply:** 以后凡是决定资产托管在哪（图标、安装包、更新源、字体、CDN），先问，别默认"CF 更快"。
静态资源能内联就内联，内联是唯一不受任何网络环境影响的方案。
插件系统的完整规划见 `docs/PLUGINS_V2_PLAN.md` 的 D9 和 6.4 节；相关见 「cf-proxy-architecture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)、[Stremio 插件协议源](sources.md)。

---

### PC 端接入 Linux

> 原记忆:`linux-desktop-integration.md` · 类型:`project`

2026-07-19 给 PC 端(Rust+React+Tauri)接入 Linux。合成方案与 Windows **同构**:
独立顶层无边框窗口垫在透明主窗口正下方(`apps/desktop/src/mpv.rs` 的 `overlay` 模块,
Win32 / X11 两份实现)。子窗口路线两端都死:Windows 子窗口进不了逐像素透明的分层窗口,
X11 兄弟窗口之间根本不做 alpha 混合(合成器只合成顶层)。

**四个只有真跑 CI 才会暴露的坑**(全部实证,非推断):

1. **libmpv soname 在发行版之间是分裂的** —— ubuntu-22.04 是 `libmpv.so.1`(mpv 0.34),
   24.04/Fedora/Arch 是 `libmpv.so.2`。链接期绑死任一个,另一半系统直接起不来;
   绑 .so.2 又得换新构建机,glibc 抬到 2.39 反过来砍老系统。**解法=运行时 dlopen**
   (仅非 Windows;Windows 保持 mpv.lib 链接期绑定)。CI 里有条**反向断言**:
   `readelf -d` 出现 `NEEDED ... libmpv` 就让 job 红 —— 否则有人加回 link-lib 时
   构建机上恰好有 .so 就「碰巧编过」,CI 全绿只有用户炸。

2. **`data_directory()` 两端都有效,别给它加平台门** —— 核对 tauri-2.11.5
   `webview_window.rs:1022` / `mod.rs:961`,方法上**没有任何 cfg**;
   `tauri-runtime-wry:4793` 拿它当 WebContext key,Linux 由 wry
   (`webkitgtk/web_context.rs:32`)转成 WebsiteDataManager 的
   `base_data_directory`/`base_cache_directory`。直接调用即可保住 [PC 绿色包单一数据根](build-release.md)。
   > ⚠️ 教训比结论重要:我曾听信「它是 `#[cfg(windows)]` 方法」这条**未经核实的二手结论**,
   > 给它加了 cfg 门 → 为填坑劫持 XDG_{DATA,CACHE}_HOME → 劫持 XDG 又让整个进程的
   > `dirs::*` 说谎(深链的 .desktop 差点写进包里、桌面环境永远扫不到)→ 再打补丁。
   > **一条假前提滚出三层复杂度。** 涉及第三方 API 的门控断言,必须自己读 registry 源码确认。

3. **`tauri_build` 即使 `bundle.active=false` 也会校验 `resources` 路径** ——
   `"resources": ["libmpv/libmpv-2.dll"]` 是条死配置(不走 bundler),但在没有该 DLL 的
   Linux 构建机上直接把 build.rs 干失败。已删,理由钉在 build.rs 拷 DLL 那段旁边。

4. **`apps/desktop` 的 reqwest 漏了 `default-features = false`** —— reqwest 0.12 默认特性含
   `default-tls` = native-tls → openssl,而 cargo 特性**全图合并**,把整个 workspace 拖进
   OpenSSL。core 那边一直是对的。Windows 上看不出来(native-tls 走 SChannel),
   Linux 上是实的:多链 libssl.so.3/libcrypto.so.3 + 多编一堆 C。

**其它已处理**:`APP_EXE` 按平台取名;zip **不还原 Unix 权限位**,更新覆盖后必须补回可执行位
(否则「更新成功、下次启动 Permission denied」);Unix 先 unlink 再写绕开 ETXTBSY;
`create_overlay` 失败必须当场报错(带 `wid=0` 走下去 mpv 会配合 `force-window=yes`
**自己弹一个不受控的独立窗口**);前端 hwdec「零拷贝」档 Linux 给 vaapi、字幕字体档位分平台。

**硬约束**:Linux 端强制 `GDK_BACKEND=x11`(Wayland 协议不提供「应用定位自己的顶层窗口」,
mpv 的 `wid` 在 Wayland 上也不支持),且需要合成器。
X11 层叠有个必踩的坑:**不能拿 Tauri 的 client window 当层叠兄弟** —— 重定向式 WM 会把它
reparent 进装饰框,和我们那个 override-redirect 视频窗口不是兄弟,`XConfigureWindow` 会
BadMatch;必须先顺 parent 链上溯到 root 的直接子窗口。而 Xlib 默认错误处理器**会 abort 进程**,
必须先换掉。

**Linux 的「便携」只覆盖数据,不覆盖运行库。** 真包 `readelf -d` 实测 15 条 DT_NEEDED:
`libwebkit2gtk-4.1.so.0` / `libjavascriptcoregtk-4.1.so.0` / `libsoup-3.0.so.0` /
`libgtk-3.so.0` / libgdk-3 / libcairo / libglib / libgio / libdbus …
Tauri 在 Linux 上就是 GTK3 + WebKitGTK,**不自带内核**。必须是 webkit2gtk **4.1**(配 libsoup3)
不是 4.0 —— 这条把**系统下限**钉在 Ubuntu≥22.04 / Debian≥12 / Fedora≥36。
CI 会打印 DT_NEEDED 清单,谁引入新硬依赖一眼可见。
> 别只验证「编译链接打包绿」就对运行时依赖签字 —— 这正是本次被用户当场抓到的错。

**ELF 必须 strip**:根 Cargo.toml 的 `debug="line-tables-only"` 注释「exe 体积不变」
**只对 MSVC 成立**(调试信息在独立 .pdb),ELF 是塞进二进制本身 —— 未 strip 实测 **191MB**。
在 Sentry 符号上传**之后** `strip --strip-debug`(符号化靠 build-id,不受影响)。

**透明合成在 WebKitGTK 上成立**(已核源码):tao-0.35.3 `linux/window.rs:131` 对
`transparent` 取 `screen.rgba_visual()` + `set_visual` + `app_paintable`;
wry-0.55.1 `webkitgtk/mod.rs:289` 把 webview 背景设成 `RGBA(0,0,0,0)`。

**发行包**:`LinPlayer-Linux-v<ver>.zip`(**必须 zip 不是 tar.gz** —— 应用内更新器解包走
`core/update.rs` 的 `extract_zip`;资产名含 "linux" 供 `asset_keywords()` 匹配)。
不打包 libmpv(`$ORIGIN` rpath 会让自带的那份永远压过系统的,在别的发行版上反而更坏)。

⚠️ **CI 绿只证明编译+链接+打包**。透明 UI 压在独立视频窗口上的真实合成效果、
XWayland 下的表现,headless CI 验证不了,仍需真机过一眼。见 [每次都要出可测 exe](methodology.md)。

---

### Linux 选外部播放器列不出文件

> 原记忆:`linux-executable-picker-filter.md` · 类型:`project`

2026-08-17。`SettingsPage.pickExternal` 写死 `pickFile(cur, "可执行文件", ["exe"])`。
Linux 的可执行文件(`/usr/bin/mpv`)**没有后缀** → GTK/XDG 选择器一个文件都列不出来,
看着就是选择器坏了。

**修法**:按平台给过滤 —— `navigator.userAgent.includes("Windows")` 为真才传
`"可执行文件" / ["exe"]`,否则两个参数都不传(`pick_file` 只有两个都给才 `add_filter`)。
顺手把 Linux 上没设过时的起始目录定位到 `/usr/bin`。

**这是「只有真跑 Linux 才现形」的一类**:Windows 上开发、Windows 上自测,
永远复现不出来,`cargo check` / `tsc` 全绿。已在 desktop 的 `api_contract_tests` 里
钉了源码级守门 `external_player_picker_must_not_filter_exe_off_windows`。

见 [PC 端接入 Linux](build-release.md) [桌面 check 照不到安卓](android.md)

---

### PowerShell GBK/UTF-8 坑

> 原记忆:`powershell-gbk-utf8-corruption.md` · 类型:`feedback`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

在本机(Windows 11 中文 locale)用 Windows PowerShell 5.1 的 `Get-Content -Raw` + `[System.IO.File]::WriteAllText` 批量重写含**中文注释**的 UTF-8 源码文件，会按系统 GBK 解码读入 → 中文变乱码(如 `CORE_LIB锛`)并冲乱代码结构，编译报一堆 Unresolved reference。改包名那次(xyz.linplayer.app)第一轮 Android CI 就这么挂的。

**Why:** PS5.1 的 `Get-Content` 默认编码是系统 ANSI(中国区=GBK)，不是 UTF-8。

**How to apply:** 批量替换源码里的 ASCII 串时，走 Bash/git-bash 的 `sed`(按字节操作，多字节 UTF-8 不受影响)，或直接从 `git show <sha>:<path>` 取原始 blob 重定向写出，全程不经 PowerShell 编码往返。要单点改就用 Edit 工具。相关：「windows-gradle-cross-drive-fix」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)

**⚠️ 同坑另一面：App 运行时生成给 PS5.1 跑的 `.ps1` 必须带 UTF-8 BOM(2026-07-11)**。
Windows 覆盖更新的自更新脚本 `windows_self_updater.dart` 含中文注释/Log，Dart `writeAsString`
写「无 BOM UTF-8」→ PS5.1 按 GBK 读 → 中文乱码撑爆引号/大括号 → **整段 ParserError 脚本
根本不执行**(连第一行 Log 都没到,故 `linplayer_update.log` 全程空) → exe/data 从没被覆盖
→ 用户「更新了不重启、重开还提示更新」。修法:`writeAsBytes([0xEF,0xBB,0xBF, ...utf8.encode(script)])`。
复现判据:PS `[System.Management.Automation.PSParser]::Tokenize` 无 BOM 报 UnexpectedToken,加 BOM PARSE OK。
凡是 App 落盘 .ps1/.bat/.cmd 交给 PowerShell 跑且含非 ASCII 的，一律带 BOM。见 「update-architecture」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)

**⚠️ 第三次踩:仓库里的 `scripts/pack-portable.ps1`(2026-07-20 修)**。
症状:`npm run pack` 一上来就死在 `Join-Path : Cannot bind argument to parameter 'Path' because it is null`。
根因不是 Join-Path,是**上面两行**:该文件无 BOM,0dd295fe 重构时给它加了一行中文注释,
PS5.1 按 GBK 解码后字节错位、**把行尾换行一起吃掉**,紧随其后的
`$root = Split-Path -Parent $PSScriptRoot` 整行被吸进注释 → `$repoRoot` 恒 null。
讽刺的是该文件**自己的文件头就写着** "ASCII-only on purpose: PS 5.1 misreads
UTF-8-without-BOM Chinese as GBK" —— 写了规矩没人执行等于没有。

**为什么很久没人发现**:CI 是自己组包的(df89d598),根本不跑这个脚本 → CI 全绿,只有本地出包坏。
**所以守卫必须在 `cargo test` 里,不能指望流水线**:已加
`api_contract_tests::pack_script_stays_ascii_only`(include_str! 扫非 ASCII,反向注入验过红)。

查法(别靠肉眼看文件,乱码在编辑器里是正常的):
```powershell
$b=[IO.File]::ReadAllBytes($p); $b[0..2]            # EF BB BF 才是有 BOM
[Text.Encoding]::GetEncoding(936).GetString($b)     # 按 PS5.1 的眼睛看一遍,被吞的行当场现形
```

---

### Bash 别用 PS heredoc

> 原记忆:`bash-no-powershell-heredoc.md` · 类型:`feedback`

在 **Bash 工具**里写多行 git commit message 时，绝不要用 PowerShell 的 here-string 语法 `git commit -m @'...'@`。Bash 不认识它——开头的 `@` 和结尾的 `@` 会被当成消息的字面内容：`@` 单独成第一行（git 折叠显示成 `@ 标题`），闭合的 `@` 又成了 body 末尾一行。结果 7 条提交标题全变成 `@ chore: ...`，事后要 rebase 清理。

##### 更大的教训：别把正则替换塞进 Bash heredoc（2026-07-20 再次翻车）

`python - <<'PY' ... re.subn(pat, '\\1 ', s) ... PY` —— **反斜杠被吃掉一层**，Python 实际收到 `'\1 '`，
即控制字符 SOH（`\x01`），于是 7 处 `<div><b>标题</b>` 被整段替换成一个不可见控制符。
文件看起来正常、grep 也搜不到，只有渲染出来才发现卡片标题凭空消失。

**规矩：任何带反斜杠反向引用、或含引号/中文标点的批量替换，一律先 `Write` 成 `.py` 文件再 `python file.py`，
不走 heredoc。**

##### 更常犯的一个：非贪婪 `.*?` 咬错闭合标签（2026-07-20 一天内栽了四次）

改 HTML 时反复写出 `<div class="X">.*?\n      </div>\n(?=...)` 这类模式，四次全出事：

| 症状 | 真因 |
|---|---|
| 三整页凭空消失 | 某个块后面不是预期的 lookahead 目标，`.*?` 就跨页吃到下一个匹配点 |
| 播放页被替换成导航轨 | 同上，块长 11673 字符（正常 900） |
| 电影页出现两组版本卡 | `\n        </div>` 先撞上 rowhead 自己的闭合（同缩进），只换了标题行 |

**两条硬规矩**：
① **不要用 lookahead 定块尾**，改用缩进层级 —— 容器闭合的缩进比其子元素少 2，匹配到那一层即可；
② **替换前断言块长度上限**（`assert max(len(b)) < 1500`）和**块数 == 目标标记数**。
断言比事后回读便宜得多，而且这类损坏 grep 搜不出来、截图也看不见（少掉的页不会出现在视野里）。 同源事故见 [PowerShell GBK/UTF-8 坑](build-release.md)（sed 分隔符）与
[TV 端 UI 选型](ui-tv.md)（正则 `.*?` 跨页吃掉三整页）。三次都是"批量替换 + 没回读校验"。

**Why:** `@'...'@` 只在 PowerShell 里是 here-string；Bash 里 `@` 是普通字符。

**How to apply:** Bash 工具里多行 message 用 `$'line1\nline2'`（ANSI-C 转义）或普通 heredoc（`git commit -F -  <<'EOF' ... EOF`）。只有 PowerShell 工具才用 `@'...'@`。清理已污染的历史：`git rebase <base> --exec 'git commit --amend -m "$(git log --format=%B -1 | sed "/^@\$/d")" >/dev/null'`（删掉所有单独成行的 `@`），再 `push --force-with-lease`。相关：[Git workflow](methodology.md)。

---

## 跨域交叉引用

这些条目和本领域强相关,但正文放在别的文件里(一条经验只存一份正文):

- [每次都要出可测 exe](methodology.md) — 改完 PC 端必须出可测 exe,光报编译绿 = 没交付
- [APK 未签名陷阱](android.md) — release 变体没 signingConfig 会出未签名包
- [Android libmpv LFS in CI](android.md) — CI 产物里的 .so 要校验 ELF magic
- [桌面 check 照不到安卓](android.md) — 推前跑 scripts/check-android.sh
- [测试必须先红](methodology.md) — 长期红的门禁 = 没有门禁
