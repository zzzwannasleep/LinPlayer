# 开发与技术

> 仓库结构、本地开发与构建、技术栈。主文档见 [README](../README.md)。

## 技术栈

| 层 | 用什么 | 为什么 |
|:--|:--|:--|
| 业务核心 | [Rust](https://www.rust-lang.org/) + [Tokio](https://tokio.rs) + [reqwest](https://github.com/seanmonstar/reqwest)（rustls） | 一份代码各端共用；rustls 而非 native-tls，是为了去掉 openssl-sys，安卓交叉编译免装 OpenSSL |
| 桌面壳 | [Tauri 2](https://tauri.app) | 窗口 / IPC / 打包；前端用系统 WebView，不捆浏览器 |
| UI | [React 19](https://react.dev) + [TypeScript](https://www.typescriptlang.org) + [Vite](https://vite.dev) | 每端一套 UI，共用 `ui/shared` 的 API 桥与设计 token |
| 播放 | [libmpv](https://github.com/mpv-player/mpv)（原生窗口，非纹理回读） | 全格式、libass 完整字幕特效、GLSL 着色器 |
| 插件 | [QuickJS](https://bellard.org/quickjs/) | 逐插件隔离，崩溃/超时不影响宿主 |
| 遥测 | [Sentry](https://sentry.io)（前端 + Rust 双侧） | 崩溃堆栈与匿名活跃统计 |

## 仓库结构

```
crates/
  core/            各端共用的业务核心(数据源/网络/配置/同步/下载/插件)——不依赖任何平台专属 crate
  mpv/             libmpv 封装 + 各平台渲染面(桌面顶层叠加窗 / 安卓 Surface),桌面与安卓共用
apps/
  desktop/         Tauri 桌面壳 —— Windows / Linux
  android/         安卓壳 —— 手机 / Android TV
ui/
  shared/          各端共用前端层:api.ts(命令桥+类型) / theme.ts / tokens.css
  desktop/         桌面 UI
  tv/              TV UI(焦点走 norigin-spatial-navigation)
  mobile/          待建
public/            前端静态资源
scripts/           构建与校验脚本
oauth-proxy/       Cloudflare Pages Functions(OAuth 中转 / 徽章 / 赞助名单)
```

> `crates/mpv` 为什么单独一个 crate:`crates/core` 的契约是「平台无关」,而 mpv 这层**必然**要
> Win32 / X11 / JNI。也不能让 `apps/android` 直接依赖 `apps/desktop`(那个包绑死 tauri /
> windows-sys / x11-dl,交叉编译第一步就死)。所以:**平台相关但两端共用的东西,单独成 crate**。

根级 `Cargo.toml` 是 workspace，`package.json` / `vite.config.ts` / `tsconfig.json` / `index.html` 是前端入口。

### 两条容易踩的约定

**`@shared` 别名定义在两个地方，必须逐字一致**——`vite.config.ts` 的 `resolve.alias` 与 `tsconfig.json` 的 `compilerOptions.paths`。只改一边的话 vite 构建是绿的、`tsc` 直接红，而 `npm run build` 是 `tsc && vite build`。

**版本的唯一权威是 `apps/desktop/tauri.conf.json` 的 `version`**。`build.rs` 拿它注入 `LP_VERSION` 给 Sentry release，`vite.config.ts` 拿它做 sourcemap release，`scripts/pack-portable.ps1` 拿它给 zip 命名。`Cargo.toml` 里的 version 不参与，两者没有任何同步机制——现在都是 `0.1.0` 纯属巧合。

## 本地开发

### 环境要求

- [Rust](https://rustup.rs/) stable
- **Node.js 24+**——`npm run check:telemetry` 让 node 直接跑 `.ts`（类型擦除，换来零测试框架）。Node 20 会报 `ERR_UNKNOWN_FILE_EXTENSION ".ts"`
- Tauri 2 的[平台依赖](https://tauri.app/start/prerequisites/)（Windows 需 WebView2 + MSVC 工具链；Linux 需 webkit2gtk 等）
- libmpv——两端拿法不同，见下节

### libmpv

#### Windows：自备 DLL

`apps/desktop/libmpv/libmpv-2.dll`——**117MB，不入库，需自备**。

必须是 **shinchiro 的完整构建**：自带完整 ffmpeg，含 PGS/SUP 图形字幕解码器（`hdmv_pgs_subtitle`）。精简版能编译、能播放、**蓝光字幕一片空白**。

从 [shinchiro/mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake/releases/latest) 下最新的 `mpv-dev-x86_64-*.7z`，把 `libmpv-2.dll` 放进 `apps/desktop/libmpv/`。CI 每次构建会自动拉取（见 `.github/workflows/build.yml`），并断言体积 ≥ 60MB——少了 DLL 的话 exe 照样编得出来、照样打得成包，用户双击才发现「找不到 libmpv-2.dll」。

#### Linux：libmpv 是运行时 dlopen 的，构建期什么都不用装

```bash
# Debian / Ubuntu（CI 用的就是这一串，见 build.yml 的 build-linux）
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev \
                 libayatana-appindicator3-dev libxrandr-dev
# 想在本机真的把视频跑起来，再装运行时库（构建不需要它）
sudo apt install libmpv2      # 旧版本叫 libmpv1，两个 soname 都认
```

- **是 `libwebkit2gtk-4.1-dev`，不是 4.0**——Tauri v2 要 4.1，装错包名的表现是一堆 pkg-config 找不到。
- **注意列表里没有 `libmpv-dev`**，这是有意的。libmpv 在非 Windows 上走运行时 `dlopen`（`crates/mpv/src/lib.rs` 的 `mod ffi`），`build.rs` 只在 Windows 发 `rustc-link-lib=dylib=mpv`。

  发行版之间 libmpv 的 soname 是分裂的——22.04 是 `libmpv.so.1`（mpv 0.34），24.04/Fedora/Arch 是 `libmpv.so.2`（0.36+）。链接期绑死任一个，另一半系统就直接起不来；而绑 `.so.2` 又得换更新的构建机，glibc 抬到 2.39 反过来砍掉老系统。dlopen 把这个选择推迟到运行时，一个包通吃。

  > CI 里有一条**反向断言**：`readelf -d` 里出现 `NEEDED ... libmpv` 就让 job 红。因为一旦有人把 link-lib 加回来，构建机上只要恰好装了 `.so` 就会「碰巧编过」，ELF 里被钉死一个 soname，而 CI 全绿、本机也照跑——只有用户那边炸。这类回归必须在构建期拦住，光靠注释是纸糊的。

- 发行二进制写了 `$ORIGIN` rpath，`dlopen` 不带路径，所以**可执行文件同级目录的 `libmpv.so.2` 会优先于系统库**——本地想换 libmpv 版本，丢一个到 `target/release/` 即可。

#### Linux 运行时的两条硬约束

- **必须 X11**。`run()` 在 GTK 初始化前设 `GDK_BACKEND=x11`（Wayland 会话经 XWayland）。原因不是偷懒：视频是一个由程序**自己定位**的独立顶层窗口，垫在透明 UI 窗口正下方，而 Wayland 协议不提供「应用定位自己的顶层窗口」的能力，mpv 的 `wid` 在 Wayland 上也不受支持。
- **必须有合成器**。裸 WM 下 UI 窗口的透明区域不会真的透出下面的视频。

合成方案本身两端同构，只是系统 API 不同（`crates/mpv/src/lib.rs` 的 `overlay` 模块）。为什么不能用子窗口：Windows 上子窗口进不了逐像素透明的分层窗口，X11 上兄弟窗口之间根本不做 alpha 混合（合成器只合成顶层窗口）。两边都只有「顶层垫顶层」这一条路。

X11 那半有个必须知道的坑：层叠不能拿 Tauri 的 client window 直接当兄弟——重定向式 WM（绝大多数）会把它 reparent 进装饰框里，于是它和我们那个 override-redirect 视频窗口**不是兄弟**，`XConfigureWindow` 会 `BadMatch`。必须先顺 parent 链上溯到 root 的直接子窗口。而 Xlib 默认错误处理器**会 abort 整个进程**，所以还得先把它换掉。

### 跑起来

```bash
npm install
npm run tauri dev          # 开发模式（前端 HMR + Rust 热重启）
npm run build              # tsc && vite build，只构前端
npm run tauri build        # 完整构建，产物在 target/release/
```

### 校验

```bash
cargo test --workspace                        # Rust 全量测试
npm run check:telemetry                       # 遥测脱敏断言
bash scripts/check-commands.sh                # 命令表定义/注册一致性
node scripts/check-calendar-grouping.mjs      # 日历归组逻辑
node ui/shared/favorites-sort.test.mjs        # 收藏排序
node ui/shared/plugin-ui.test.mjs             # 插件声明式 UI 契约
```

部分 Rust 测试用 `include_str!` **直接读前端源码**做一致性断言（`apps/desktop/src/lib.rs`）。移动前端文件时要同步改这些路径，否则 `cargo build` 绿而 `cargo test` 红。

### 编译期凭据

弹弹play 默认弹幕源与 TMDB 排行榜需要编译期注入凭据，`crates/core/build.rs` 读这三个环境变量：

```
DANDANPLAY_APP_ID / DANDANPLAY_APP_SECRET / TMDB_API_KEY
```

**不给也能构建**，只是这两个功能静默缺席（UI 走诚实空态）。本地开发把它们放进仓库根的 `hjbl.env`（已 gitignore），`scripts/pack-portable.ps1` 会自动加载。

## 发布

只出**绿色免安装包**，不做 setup（`tauri.conf.json` 里 `bundle.active = false`）。

```powershell
npm run pack        # 完整：读 hjbl.env → 构建 → 传符号 → zip → 解压到测试目录
npm run pack:fast   # 跳过 zip，只刷新测试目录
```

脚本把 `dist-portable/` 分成三个互不重叠的目录——`build/`（干净产物，每次清空）、`.zip`（发给用户）、`LinPlayer/`（你自己测试的地方，保留 `userdata/`）。**分开是这个脚本的全部意义**：App 把账号和 token 写在 exe 同级的 `userdata/`，构建目录和测试目录一旦合并，要么打包清空你的登录态，要么**你的账号和 token 被打进 zip 发给所有人**。两种都真实发生过。

> `scripts/pack-portable.ps1` 必须是**纯 ASCII**：PowerShell 5.1 会把不带 BOM 的 UTF-8 中文当 GBK 读，直接解析失败。

CI（`.github/workflows/build.yml`）推 `main` 触发，产出 `v<ver>-pre` 预发布 = App 内的「预览版」渠道；`publish.yml` 手动把它提升为正式 Release = 「稳定版」渠道。两个渠道的定义就落在这两个文件上。

## 安卓端

壳在 `apps/android`，TV UI 在 `ui/tv`（14 页，已接真后端）；手机 UI（`ui/mobile`）待建。

```bash
bash scripts/build-android-apk.sh --release   # 出 APK
bash scripts/build-android.sh                 # 只交叉编译 .so(上面那个会复用它导出的环境)
```

不能直接 `npx tauri android build`：gradle 会转手调 cargo 编安卓目标，而 `rquickjs-sys` 在安卓
要现跑 bindgen —— libclang / resource-dir / sysroot / INCLUDE 那一整套坑见
`scripts/build-android.sh` 顶部的逐条说明。

已定的两条：

- 直接链**现成的 libmpv `.so`**，不再自建 JNI 封装。
- `crates/core` 不依赖 tauri / windows-sys / 任何桌面专属 crate，就是为了能交叉编译成安卓 `.so`。改核心时请守住这条。

功能全清单见 [MIGRATION_RN_PLAN.md](MIGRATION_RN_PLAN.md)，落地记录见 [RUST_MIGRATION_PLAN.md](RUST_MIGRATION_PLAN.md)。
桌面视频合成（两个顶层窗口、层级维持、录屏限制）见 [NATIVE_RENDERING.md](NATIVE_RENDERING.md)。

> Flutter 时代的构建方式（`flutter build apk` 等）已全部失效，代码见 tag `flutter-final`。
