# 安卓平台(打包 / 签名 / 资源限定符 / R8 / LFS / 主题)

**这个领域最容易踩的坑:**
1. **这里几乎所有失败模式都是「构建绿、装机废」**:未签名 APK、缺 `touchscreen required=false`、libmpv 是 LFS 指针、R8 裁掉 JNI 回调 —— 全部要验成品不验中间状态。
2. **`-night` 的优先级高于 `-vXX`**,按 API 加主题属性必须建 `values-vXX` 和 `values-night-vXX` 两份,同名 style 是整条替换不是叠加。
3. **「有声音没画面」先查 Activity 主题的 `windowBackground`**,别先怀疑 mpv;透出链有四层。
4. **`cargo check -p app` 只编 Windows**,`crates/mpv` 的 overlay 有四个 cfg 变体,兜底桩任何 CI 目标都编不到、会静默烂掉。
5. **别再说「本机没 NDK 跑不了」** —— 仓库自带 `scripts/build-android-apk.sh`,裸 cargo check 会死在 host bindgen 缺 WinSDK 头。

> 本文件共 **36** 条。开头 8 条标了原记忆文件名与类型,是从 memory 搬过来的;
> 其余都是 Go 核心 + Compose 手机端落地时(2026-09-06 起)新踩的,标着日期。

## 本页条目

> 只列从 memory 搬来的那几条 —— 带日期的按时间排在正文里,不重复索引一遍。

- 安卓端身份 — `android-app-identity.md`
- APK 未签名陷阱 — `android-apk-unsigned-trap.md`
- 安卓能本地构建 — `android-local-build-works.md`
- 桌面 check 照不到安卓 — `desktop-check-misses-android.md`
- 安卓TV宿主壳与出包 — `android-tv-host-build.md`
- Android R8 JNI keep — `android-r8-jni-keep.md`
- 安卓资源限定符优先级 — `android-resource-qualifier-precedence.md`
- 安卓视频透出四层 — `android-video-transparency-chain.md`

---

### 安卓端身份

> 原记忆:`android-app-identity.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

安卓端（TV 与将来的移动端同一个壳）在设备上的身份，用户 2026-07-21 明确要求
**沿用删 Flutter 之前那套**，不要 Tauri 按 TV 配置生成的默认值：

| | 之前(要用回的) | Tauri 默认(错的) |
|---|---|---|
| applicationId | `xyz.linplayer.app` | `xyz.linplayer.tv` |
| 启动器名 | `0Player` | `LinPlayer TV` |
| 图标 | LinPlayer 青色播放键(同桌面) | Tauri 模板的青黄「8」 |

**换包名的动机是覆盖升级** —— 包名一变，在设备上就是另一个 App，老用户收不到更新。
⚠️ 签名也必须和老包一致，否则同包名不同签名 = 装不上，用户得先卸载。

**改包名必须同时改三处**，少一处 `tauri android build` 直接报
`Project directory ... app/src/main/java/xyz/linplayer/app does not exist`：
1. `gen/android/app/build.gradle.kts` 的 `namespace` + `applicationId`
2. Kotlin 源码目录 `app/src/main/java/xyz/linplayer/<name>/`（连同各文件的 `package` 声明）
3. `apps/android/tauri.conf.json` 的 `identifier`

`generated/` 和 `proguard-tauri.pro` 是 gitignore 的，Tauri 每次构建按 identifier 重新生成，不用手工搬。

**Android TV 还要 `android:banner`**（320x180，放 `drawable-xhdpi/tv_banner.png`）——
leanback launcher 用它显示磁贴，缺了就是一块空白，观感上等同「默认图标」。
顺带 `android:roundIcon`。启动器名的真正来源是 `res/values/strings.xml` 的 `app_name`，
不是 tauri.conf.json 的 productName。

CI 已加 `Assert APK identity` 断言这三项。相关 [APK 未签名陷阱](android.md)。

---

### APK 未签名陷阱

> 原记忆:`android-apk-unsigned-trap.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

TV/安卓包「安装包无效 / 解析软件包时出现问题」= **APK 完全未签名**，不是密钥缺失。

**坑的形状**：`ANDROID_KEYSTORE_BASE64` 等四个 secret 都在，CI 日志也打了
「有签名密钥 → 出 release APK」，`keystore.properties` 也写进去了 ——
但 **Tauri 生成的 `gen/android/app/build.gradle.kts` 默认不读那个文件**，
release 变体连 `signingConfig` 都没有，gradle 于是吐 `app-universal-release-unsigned.apk`，
CI 全程绿灯。**写了配置 ≠ 用了配置**；CI 里那条「仓库还没有这个 secret」的注释过时后，
反而让人以为 gradle 那半是有意留着的。

**取证手法（不用 Android 工具也能查）**：下载 CI 产物用 python zipfile 检查
- v1：`META-INF/` 下有没有 `.RSA/.SF/MANIFEST.MF`
- v2/v3：整个文件里搜 `APK Sig Block 42` 魔数
三种全无 = 必然装不上。有 SDK 就直接 `apksigner verify --verbose`。

**修法**：build.gradle.kts 读 keystore.properties 建 release signingConfig；
**没密钥时退回 debug 签名**，绝不出未签名包（debug 签名至少能装能测）。
字段名必须和 workflow 的 Write keystore 一字不差：`storeFile/storePassword/keyAlias/password`。

**防复发**：CI 加成品闸门 `Assert APK is signed` + `Assert APK identity`。
这类缺陷源码里肉眼审不出，只有装到设备上才暴露 —— 必须验成品不验中间状态。
相关 [Android libmpv LFS in CI](android.md)、[安卓端身份](android.md)。

---

### 安卓能本地构建

> 原记忆:`android-local-build-works.md` · 类型:`feedback`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

**安卓端可以在这台 Windows 机器上本地构建出 APK。别再声称"本机无 NDK，交叉编译跑不了"。**

**Why**：2026-07-21 我交付时写了「本机无 NDK，交叉编译跑不了，只能等 CI」——
**没验证就下的结论**，踩了「未验证归因」红线。用户反问「需要什么 NDK 我装就是了」，
一查：NDK 装了三个、rustup 四个安卓 target 全在、JDK 21 也在，
**唯一缺的只是当前 shell 没设环境变量**。仓库还早就自带了 `scripts/build-android-apk.sh`。

**How to apply** —— 本地出 APK：
```bash
export ANDROID_HOME="C:/Users/65282/AppData/Local/Android/Sdk"
export JAVA_HOME="/c/Program Files/Zulu/zulu-21"
export PATH="$JAVA_HOME/bin:$PATH"
bash scripts/build-android-apk.sh --release
# 产物: apps/android/gen/android/app/build/outputs/apk/universal/release/app-universal-release.apk
```
脚本自己会挑带 `libclang.dll` 的 NDK（要 30+）并处理 bindgen 的
libclang/resource-dir/sysroot/INCLUDE 那一整套 Windows 坑。

**先决条件**：`libmpv.so` 不入库（红线：脚本能拉的别入库），本地要手动拉一次，
否则出的 APK 缺 libmpv、装上一播放就 UnsatisfiedLinkError：
```bash
curl -fsSL -o /tmp/libmpv.jar https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.11/full-armeabi-v7a.jar
unzip -o -j /tmp/libmpv.jar "lib/armeabi-v7a/libmpv.so" -d apps/android/gen/android/app/src/main/jniLibs/armeabi-v7a
```

**验收 APK**（SDK build-tools 里就有）：
`apksigner verify --verbose <apk>` 看签名，`aapt2 dump badging <apk>` 看包名/应用名/banner。
相关 [APK 未签名陷阱](android.md)、[安卓TV宿主壳与出包](android.md)。

---

### 桌面 check 照不到安卓

> 原记忆:`desktop-check-misses-android.md` · 类型:`feedback`

2026-08-02:**连着三个提交** CI 上四个安卓 job 全红,而本地全绿。
根因是 `crates/mpv/src/lib.rs` 的 `mod overlay` 有**四个 cfg 变体**
(Windows / Linux-X11 / Android / 兜底桩),加 `is_host` 时只补了前两个。

**Why:** `cargo check -p app` 只编 Windows 目标 —— 它对另外三个变体一无所知。
而出整个 APK 要好几分钟,于是每次都「下次再验」,于是就没有下次。
兜底桩更隐蔽:**任何 CI 目标都编不到它**(三个 cfg 全挡掉),它会静默烂掉 ——
发现时已经缺了三个函数。

**How to apply:**
- 推之前跑 **`bash scripts/check-android.sh`**(2026-08-02 新增):只 cargo check
  armv7 + aarch64 两个目标、不出 APK,约 30 秒。改了 `crates/mpv`、`crates/core`、
  或任何 cfg 分平台的代码就必须跑。
- 直接 `cargo check --target <android>` 比走 tauri/cargo-ndk 多两样要自己给:
  cc-rs 要 NDK 的 `<prefix><API>-clang.cmd`(CC_<target> + linker);
  rquickjs-sys 在 **target 侧**现跑 bindgen,要 `BINDGEN_EXTRA_CLANG_ARGS_<target>`
  带 `--sysroot`,否则连 `stdio.h` 都找不到(通用的那个变量是给 host bindgen 的)。
- 给 `overlay` 加函数**必须四个变体一起加**,兜底桩最容易忘。
- 相关:[安卓能本地构建](android.md)、[PC 播放页独立窗口](player-mpv.md)、[测试必须先红](methodology.md)

---

### 安卓TV宿主壳与出包

> 原记忆:`android-tv-host-build.md` · 类型:`project`

**2026-07-20 建**。`apps/android` = Tauri 2 安卓 TV 宿主,包名 `linplayer-android`,
identifier `xyz.linplayer.tv`,窗口加载 `index-tv.html`。只依赖 `linplayer-core`,
**不依赖 `apps/desktop`**(那个包绑死 mpv / Win32 / X11)。
出包脚本 `scripts/build-android-apk.sh`,CI 在 `build.yml` 的 `build-android` job。

##### 命令层:按 UI 真实调用面建,不照抄桌面

225 个 tauri 命令全在 `apps/desktop/src/lib.rs`(桌面专属,`crates/core` 故意不依赖 tauri)。
安卓壳**没有照抄**,而是从 `ui/tv` 的真实 import 反推出 **63 个**(53 真实现 + 10 播放器桩)。
`apps/android/tv-commands.txt` 是清单,有单测做 **清单 × generate_handler! × api.ts** 三方对账。
⚠️ 漏注册一个命令**构建照样绿**,用户走到那页才 `command not found` —— 这条测试就是把它提前。

##### 五个坑(都不是看文档能避开的)

1. **APK 曾经 105MB**。根 `Cargo.toml` 的 `[profile.release] debug="line-tables-only"`
   是为 Windows Sentry 加的 —— MSVC 把调试信息放进独立 `.pdb`,**exe 体积不变**,划算;
   **ELF 不是**,调试信息留在 `.so` 里一起进 APK。
   解法:调用侧按 `CARGO_PROFILE_RELEASE_DEBUG=false`(105MB → 21MB),
   **不要改 Cargo.toml** —— 那是全 workspace 的,一改就把桌面崩溃报告打回「只知道在哪个函数」。
   cargo profile 没有 per-target 覆盖,只能在调用侧按住。**脚本和 CI 两处都要写,改要一起改。**
   CI 里配了 60MB 体积闸门兜底(失效时构建仍然绿,只有用户下载才发现)。

2. **`tauri android init` 必须用 `npx tauri`,不能用 `node node_modules/.../tauri.js`**。
   生成的 `BuildTask.kt` 会把当时的可执行文件**硬编进去**:用 node 调会写死
   `executable = """D:\Nodejs\node"""` + `args=["run","--","tauri",...]`,
   gradle 一跑就 `Cannot find module 'apps/android/tauri'`。删 `gen/` 用 npx 重 init 才对。

3. **Android TV manifest 缺 `android.hardware.touchscreen required="false"` = 装了找不到**。
   Android 默认认为应用需要触摸屏,不写这条,机顶盒被判「设备不兼容」——
   Play 上搜不到,旁加载装上有些 TV 桌面也不显示图标。
   **构建全绿、APK 正常、装机就是没有**,是最难自查的一类失败。
   CI 有硬断言校验 `LEANBACK_LAUNCHER` / `android.software.leanback` / `touchscreen` 三条。
   (还缺 `android:banner`,TV 桌面可能只显示默认图 —— 待补。)

4. **vite 会监听 `apps/android/gen/` 的 gradle 构建树,被正在写入的 `.so` EBUSY 崩掉整个 dev server**。
   报错在 chokidar 深处(`errno -4082`),症状是「跑着跑着前端就没了」,很难联想到安卓构建。
   `vite.config.ts` 的 `server.watch.ignored` 必须含 `**/apps/android/gen/**`。

5. **仓库里有两个 `tauri.conf.json`**(desktop + android),tauri CLI 自动发现会挑到哪个不确定。
   所有安卓命令必须 **`cd apps/android` 再跑**,这是唯一不含糊的写法。

##### 交叉编译环境(Windows 宿主)

`scripts/build-android.sh` 已经把坑全趟平了(rquickjs-sys 在安卓要现跑 bindgen,
libclang 当 DLL 加载时 `InstalledDir` 为空找不到 `stdbool.h` → 显式 `-resource-dir`;
host 侧 bindgen 还要从 vcvars64 灌 `INCLUDE`)。**读它,别重踩。**
支持 `LP_ANDROID_PKG=linplayer-android` 换包。

★ **CI 跑 ubuntu 不跑 windows**:上面那堆全是 Windows 宿主特有的,Linux 上没有,
runner 还便宜一半。别照着那个脚本往 windows runner 上搬。

##### 当前边界

- ★ **写桩的两条原则**(通用,与当时那批播放器桩无关 —— 那批已接上真 libmpv):
  桩不能省略不注册(命令不存在时 invoke 抛通用错误,难定位),
  也不能假装成功返回空数据(上层会以为播起来了)。
- **APK 未签名**。CI 无 keystore secret 时走 debug 签名分支(可直接安装)。
  真出签名包**光写 `keystore.properties` 不够** —— Tauri 生成的 `build.gradle.kts`
  默认不读它,要加 `signingConfigs` 并引用。
- **没上真机验证过遥控焦点**。

**Why:** 这五条里有四条的失败模式都是「构建绿、装机废」,静态检查和本地编译都发现不了。
**How to apply:** 改安卓构建前先读本条 + `scripts/build-android.sh` 头部注释;
CI 里那三道闸门(命令对账 / TV manifest / 体积)是防回归的,别删。
相关:[TV 端 UI 选型](ui-tv.md)(TV 前端与焦点)、[仓库卫生红线](build-release.md)(构建产物不进仓库)。

---

### Android R8 JNI keep

> 原记忆:`android-r8-jni-keep.md` · 类型:`project`
>
> ⚠️ 本条含 Flutter 时代 / `native-poc/` 时代的路径。2026-07-19 仓库重构后这些路径已作废(换算表见 [仓库结构(2026-07重构后)](build-release.md))。**原文按要求原样保留,未做改写。**

Flutter 的 **release 构建默认开启 R8**(代码压缩+混淆)。只被**原生(JNI)调用、无 Java 引用**的方法,R8 看不到调用方,会当垃圾删掉/改名。

**坑(native MPV 崩溃链的第二层):** `libplayer.so`(mpv-android JNI 桥)在 `MPVLib.create()` 里用 `GetStaticMethodID` 按名反查 `is.xyz.mpv.MPVLib` 的回调 `eventProperty(String)/(String,Z)/(String,J)/(String,D)/(String,String)`、`event(I)`、`logMessage(...)`。R8 把这些删了 → 运行时 `java.lang.NoSuchMethodError: ...eventProperty...` → 原生 **SIGABRT** 整个 App 崩。判定证据:反编译 release APK 的 classes.dex,发现 MPVLib 的 native 方法都在(JNI 符号不能改名),但字段被改名成 `a/b/c/d`、`eventProperty`/`event`/`logMessage` 整段消失。

**修复(已落地):**
- 新增 `android/app/proguard-rules.pro`:`-keep class is.xyz.mpv.MPVLib { *; }` + 观察者接口 + `-keepclasseswithmembernames class * { native <methods>; }`。
- `android/app/build.gradle.kts` 的 release buildType 用 `proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")` 接入。覆盖 mobile + tv 两个 flavor。
- 验证:dexdump build325 的 DEX,5 个 eventProperty + event + logMessage 全回来且名字未混淆。

**Why:** build.gradle 里**没有**任何 `minifyEnabled` 设置,R8 是 Flutter 默认开的,极易漏判;本地 debug 构建不混淆所以一直「正常」,只有 release/CI 包崩。

**How to apply:** 任何「Java 方法只被 native 回调」的场景(JNI bridge、反射、序列化)在 release 都要 keep。新增类似原生内核(如 TV 的其它 JNI)记得补 keep。诊断手法:`dexdump -d classes.dex` 看目标类方法在不在、有没有被改名。

排错顺序参考 [Android libmpv LFS in CI](android.md)(同一崩溃链第一层:LFS 指针);崩溃取证见 「android-storage-and-mpv-logs」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)。

---

### 安卓资源限定符优先级

> 原记忆:`android-resource-qualifier-precedence.md` · 类型:`project`

安卓挑资源目录的**限定符优先级**里,**夜间模式(`-night`)排在平台版本(`-vXX`)前面**。
后果:`values-night/` 会**整份压过** `values-v31/`。

2026-08-01 为治「开屏图标被放大得很大」只建了 `values-v31/themes.xml` ——
浅色模式确实好了,**默认深色的手机一台都没修到**(命中的是 `values-night/`,
那份里一条开屏配置都没有 → 图标回落系统默认铺满图标槽、底色回落到透明的
`windowBackground`)。用户只会报「还是没修好」,而我这边"测过是好的"。

规矩:凡是**按 API 版本**加的主题属性,必须建**两份** —— `values-vXX/` 和
`values-night-vXX/`,内容逐条一致。同名 style 在这些目录里是**整条替换不是叠加**,
所以 `windowBackground:transparent` 这种"跟开屏无关"的项也得每份都写
(漏了就是[安卓视频透出四层](android.md) 那条链断一层 = 有声音没画面)。

★ 已在 `apps/android/src/lib.rs` 加 `splash_config_covers_both_ui_modes` 钉住。
  **第一版写假绿了**:needle 只搜属性名,而那两个文件的长注释里就把三个属性名
  逐个写了一遍 —— 把 `<item>` 整行删掉测试照样绿。改成连 `<item name="android:` 一起匹配
  才反向注入验红。见 [测试必须先红](methodology.md)。

★ 系统开屏的**退场动画**(Android 12+ 把图标放大并淡出)和我们自己那块 `#boot`
  是两段互不相干的动画,接缝必然看得见一次跳变。`splashScreen.setOnExitAnimationListener
  { it.remove() }` 直接撤掉,配合三处底色 `#0e0e13` 逐位一致,交接就完全看不出来。

---

### 安卓视频透出四层

> 原记忆:`android-video-transparency-chain.md` · 类型:`project`

安卓上视频是垫在 WebView 底下的 **SurfaceView**（非 ZOrderOnTop，从窗口**下面**透上来）。
透出链**四层**，任何一层不透明 = 有声音没画面，**且一句日志都没有**：

1. `values/themes.xml` + `values-night/themes.xml` → `android:windowBackground` 必须透明
2. `apps/android/tauri.conf.json` → 窗口 `"transparent": true`
3. `MainActivity.onWebViewCreate` → `setBackgroundColor(Color.TRANSPARENT)`，**且要在 `webView.post{}` 里再刷一次**（Wry 之后会按窗口配置回头设一次，把第一次覆盖掉）
4. `tv.css` 的 `html.playing` 三条（html / body / .tv-app）

**2026-07-21 栽的就是第 1 层**：父主题 `Theme.MaterialComponents.DayNight.NoActionBar`，
`windowBackground` 跟系统深浅色走 → **浅色一片白、深色一片黑**。
症状描述「深色黑屏／浅色白屏」几乎就是这一层的指纹 —— 下次听到这句先查主题，别去查 mpv。

排错顺序（血泪）：**先排除上层遮挡，再怀疑 mpv**。当时 mpv 侧全是对的
（Surface 非 0、JavaVM 已登记、音频正常），我却先去猜 mpv 配置，白烧一轮。
判据：**有声音 = mpv 起来了、文件加载了**，那就基本不是 mpv 的事。

守门：`apps/android/src/lib.rs` 的 `video_transparency_chain_is_intact` 测试钉住四层，
删任一层 CI 当场红。改动其中任何一层都要回真机确认画面还在。

诊断能力：`Status.video`（`VideoDiag`，见 crates/mpv）回读 `current-vo` / `dwidth` /
`video-codec` / `hwdec-current`，播放页把「vo 没起来」和「起来了但没吐帧」分开显示。
**但它只覆盖 mpv 自己没出画面，盖不住「出了画面但被上面某层挡住」** —— 那一类仍然只能靠眼睛。

相关：[测试必须先红](methodology.md)、[安卓TV宿主壳与出包](android.md)、[「黑屏」多半是 JS 崩了](ui-desktop.md)

---

### Compose 下 SurfaceView 上面不许刷不透明底色 — 2026-09-06

旧栈那条「透出链四层」是 WebView 时代的说法,Compose 版的等价物只剩**一条**,
但它更容易被顺手写出来:

```kotlin
Box(Modifier.fillMaxSize().background(Color.Black)) {   // ← 就是它
    VideoSurface(core, Modifier.fillMaxSize())
}
```

`SurfaceView`(非 ZOrderOnTop)的画面是从**窗口下面**透上来的,
靠它自己在 View 树上按 `PorterDuff.CLEAR` 抠一个洞。在它上面刷一层不透明底色
就是把那个洞重新填死 —— 表现是**有声音、没画面、一条错都不报**,
和旧栈「透出链」记的是同一件事。黑底交给 Activity 的 `windowBackground`,
它在整棵 View 树**下面**,不挡洞。

**排错顺序照旧**:有声音 = mpv 起来了、文件加载了 → **先排除上层遮挡,再怀疑 mpv**。

**配套**:`player.opts` 补了 `current-vo` / `dwidth` / `dheight` / `last_error`,
播放页失败屏直接把它们写出来。这三条是这类问题的分诊表:
current-vo 空 = vo 没建;建了而 dwidth 为 0 = 一帧没解出来;
两者都有值 = 画面出来了但被挡住(那一类只能靠眼睛)。
不给的话这三种在界面上长一个样,每次都要来回好几轮 —— 上一版那句
「原因在日志里(设置 → 关于 → 导出诊断信息)」实测就是这么白烧的。


---

### ExoPlayer 内核的两个出厂缺省 — 2026-09-06

**画面被拉伸**:裸 `SurfaceView` 把画面铺满整个 View,不管片源比例。
`media3-ui` 的 `AspectRatioFrameLayout` 能治,但为它多引一个包不值当
(还会顺带拖进一整套用不上的控制条)。改法是 `onVideoSizeChanged` 的宽高
配 `Modifier.aspectRatio(ratio)` —— 它单独用就是 FIT。
两条要点:**必须乘 `pixelWidthHeightRatio`**(非方形像素的片源否则算出瘦长画面);
**不许再叠 `fillMaxSize()`**,叠上去两个约束都被钉死,比例当场失效。

**一条字幕都没有**:`DefaultTrackSelector` 默认只在「语言命中 `preferredTextLanguage`」
或「系统开了无障碍字幕」时才启用文本轨,而那个偏好是空的 ——
内封字幕明明在,`onCues` 一次都不回调。
改法三层:`setPreferredTextLanguage(prefs.sub_lang)` +
`setSelectUndeterminedTextLanguage(true)` + `onTracksChanged` 里兜底
(有文本轨又一条没选中就选第一条)。渲染要**同时画文本 cue 和 bitmap cue**,
只画一种的表现是「有的片有字幕有的没有」,看着像片源问题。

**特效字幕**:见下面那条 —— 已经接上 libass 了,不再是「切 MP 内核」。


---

### ExoPlayer 接 libass:借 libmpv 的符号,别再编一份 — 2026-09-06

**结论先说**:`libmpv.so`(media-kit full 变体)**自己导出了 191 个 `ass_*` 符号**,
`ass_library_init` / `ass_renderer_init` / `ass_new_track` / `ass_process_codec_private` /
`ass_process_chunk` / `ass_set_frame_size` / `ass_render_frame` / `ass_read_memory`
一条不缺(`llvm-nm -D --defined-only` 查得到)。Kotlin 侧 `System.loadLibrary("mpv")`
排在 `lpcore` 之前,符号进全局命名空间 —— 所以**只声明不链接**就能用,
和 `mpv_*`、`av_jni_set_java_vm` 同一条路,`CGO_LDFLAGS` 里不必加 `-lass`。
再引一份 libass(比如 libass-android)等于把包里已有的东西又编一遍。

**四个只有查过才知道、猜必错的点:**

**① media3 1.11 的字幕解析在解封装阶段,不在 TextRenderer。**
`TextRenderer` 已经没有 `SubtitleParser.Factory` 这个构造参数了(只剩 legacy 的
`SubtitleDecoderFactory`),唯一的注入点是
`DefaultMediaSourceFactory.setSubtitleParserFactory`。换错层的表现是
「libass 初始化成功,但一条事件都没进去」—— 看着像 libass 没接上。
副作用:那一层会把**所有**文本轨都解一遍,不只是选中那条,所以要按
`Format.id` 分桶存、切轨时重放。

**② media3 给的不是标准 ASS 行。**
`MatroskaExtractor` 把每个 SSA 样本重写成 `Dialogue: <Start>,<End>,` + 原始
Matroska 事件体,配的是一条自定义 Format:
`Start, End, ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text`
(常量原文 `SSA_PREFIX = "Dialogue: 0:00:00:00,0:00:00:00,"`,反编译 class 核对过)。
字段顺序和标准 ASS 的 `Layer,Start,End,Style,…` **不是一回事** ——
直接丢给 `ass_process_data` 会把 Layer 当成 Style,样式全错而且不报错。
**切掉前两个字段之后剩下的正好是 `ass_process_chunk` 要的那串**,
因为 libass 自己读掉 ReadOrder 和 Layer,再按 `n_ignored=3` 跳过 Format 里的
Layer/Start/End(读的是 libass 的 `ass.c` 原文,不是记忆)。
时间戳格式是 `H:MM:SS:CC`,**最后一段的分隔符是冒号不是点**。

**③ 没有 fontconfig。** 这份 libmpv 里一个 `Fc*` 符号都没有,
字体只能走 libass 的**目录提供者**:`ass_set_fonts_dir("/system/fonts")`。
和 mpv 那条路的 `sub-fonts-dir` 是同一件事 —— 不给的话一个字都不显示,不报错。

**④ `ASS_Image` 的布局不能赌。** 自己声明 ABI 就得逐字对(`w,h,stride,bitmap,
color,dst_x,dst_y,next,type`),错一个字段是花屏或 SIGSEGV。
所以 `lpa_init_locked` 里按 `ass_library_version()` 卡了一道区间闸,
超出就**拒绝渲染并写日志**,不去赌。

**渲染怎么落地**:libass 出的是一串 8bit alpha 小图 + `0xRRGGBBAA` 颜色
(**AA 是透明度不是不透明度**)。叠进 Kotlin 分配的 ARGB_8888 位图,native 直接
`AndroidBitmap_lockPixels`(要 `-ljnigraphics`),写的是**预乘**值 ——
写非预乘的表现是描边和阴影偏亮糊成一团。`unlockPixels` 会 bump 位图的
generation id,Skia 纹理缓存据此失效。
`ass_render_frame` 的 `detect_change` 为 0 时**一个字节都不碰位图**:
对白字幕一秒才变几次,每帧清屏重画是纯烧电;卡拉OK 那种自然每帧返回 1。

**叠加层必须和画面共用同一个 `Modifier.aspectRatio`** —— 差一个黑边的高度,
`\pos` 定死的字就整体错位。

**顺带补的**:OSD 的音轨/字幕面板原来只问 `player.tracks`(mpv 专属命令),
Exo 内核下那两个面板**恒空且点了没反应**。已改成 Exo 时读 `exo.currentTracks`,
轨道 id 用 `groupIndex:trackIndex` 而不是 `Format.id`(后者允许为 null 也允许重复,
拿它当主键的表现是「选了第二条,生效的是第一条」),字幕多一项「关闭字幕」——
关的时候必须**同时** `Libass.deactivate()`,只 disable ExoPlayer 的文本轨的话
画面上的特效字幕纹丝不动。

**仍然没有的**:MKV 内嵌附件字体(ExoPlayer 不把 attachments 透出来,
`ass_set_extract_fonts` 已经开着,等哪天能拿到 attachment 就接 `ass_add_font`)。

---

### 「有声音、没画面、一直正在缓冲」= 状态事件在安卓上一条都没发 — 2026-09-07

**症状**(用户原话):MP 内核有声音、没画面、没字幕,一直显示「正在缓冲」;
**但退回集详情页的那段过场动画里能瞥见几帧真实画面**。

那最后半句就是判据:画面一直在画,只是被挡着。mpv 一侧完全正常,别去查 vo。

**根因**在 `core/player/player.go` 的 `pumpStatus`:

```go
if !rctxSet.Load() { continue }        // ← 错的
if !videoOutReady() { continue }       // ← 对的
```

`rctxSet` 是**桌面通道 B**(GL render context)的标志,只有 `GLInit` 会置位。
安卓走通道 A(SurfaceView / `wid`),`GLInit` 一次都不调 ——
于是这道闸恒真,`player.status` **在安卓上一条都发不出去**。
UI 那边 `position` 永远是 0,`everMoved` 永远是 false,
起播黑幕(`background(Color.Black)` 铺满)就永远撤不掉。

**为什么本机测不出来**:桌面构建里 `videoOutReady()` 的实现**就是**
`rctxSet.Load()` —— 两者行为完全一致。任何跑在本机的行为测试都照不到这一条。
钉它只能读源码(`status_test.go` 里那条 `TestPumpStatusGateIsPlatformAbstract`)。
凡是「平台各一份实现」的判据,都有这个性质:**在开发机上两条分支是同一条**。

**顺带暴露的**:`pumpStatus` 从来就没发过 `paused` 和 `buffering` 两个字段,
而 UI 一直在读。表现是暂停按钮状态恒反、起播那句 4 秒兜底
(`if (!buffering) everMoved = true`)永远不成立。
字段名拼错同样不报错,所以那张表抽成了纯函数 `statusFields` 让单测钉。

**结构上的教训**:一块**不透明的**全屏布,它的撤除条件挂在一个可能失效的信号上 ——
这是「一个 bug 变成完全不可用」的放大器。现在多了一条 12 秒无条件死线:
真没画面时用户看到的和以前一样(黑 + 缓冲提示),而画面其实在的时候他至少看得见。

---

### 下排按钮点不到 = 进度条的 Slider 盖在上面 — 2026-09-07

横屏 OSD 九宫格里,下面三组按钮都写着 `align(BottomXxx).padding(bottom = 44.dp)`,
而进度条是 `align(BottomCenter).fillMaxWidth()` 且**是最后一个子节点**(在最上层)。
M3 `Slider` 的命中区是 48dp、通栏,正好压在那 44dp 上 ——
**按钮看得见、没禁用、点不动**。

「靠 padding 数值互相躲开」这种布局,改任何一处高度都会重新撞上。
现在下排和进度条叠成同一个 `Column`,这类事**结构上不可能再发生**。

同一批还改掉:`Chip` 的命中区靠**外**边距撑(`padding(6.dp).clip().pressable()`),
撑大的是间隙不是命中区,实测可点高度只有 28dp。要撑得用 `heightIn(min = Dim.tap)`。

顺带:「更多」面板走的是 `pick()`,而 `pick` 的 `when` 里根本没有 `"more"` 这一支,
落到 `else -> Unit` —— **点什么都没反应**。它现在是跳板(换面板),不是设置项。

---

### Exo 内核的图形字幕(PGS/SUP)自带坐标,不能拉满宽度 — 2026-09-07

media3 1.11 **本来就支持 PGS**:`DefaultSubtitleParserFactory` 里有
`application/pgs -> PgsParser`,`MatroskaExtractor` 认 `S_HDMV/PGS`
(两条都是反编译 `media3-extractor-1.11.0` 核对的,不是文档)。
所以蓝光原盘那种字幕轨不用自己解码 —— **别去写解析器**。

要改的是画法:`PgsParser` 给的 `Cue` 里 `position` / `line` / `size` /
`bitmapHeight` 都是**相对视频画面的比例**。上一版一律 `fillMaxWidth()`,
表现是字幕被横向拉成一条、还盖在画面正中。

两个坑:

- `Cue.DIMEN_UNSET` 是 `Float.MIN_VALUE`,**不是 0 也不是 -1**。
  拿 `<= 0` 判会把它当成合法的 0,字幕贴到左上角去。
- 叠加层的坐标系**必须和画面严格重合**:它和 libass 层、SurfaceView 共用同一个
  `Modifier.aspectRatio`。铺满全屏的话上下黑边被算进比例,整体偏。

---

### MKV 内嵌字体:ExoPlayer 不透出附件,只能自己抠 — 2026-09-07

特效字幕十有八九指名一个压制组塞进容器里的字体。没有它 libass 回落系统字体 ——
**特效和位置都对,字形不对**,而且不报错。mpv 那条路没这个问题(libavformat 透给 libass)。

`MatroskaExtractor` 完全不解析 Attachments。做法是宿主自己按 EBML 抠
(`ui/player/MkvFonts.kt`),走 HTTP Range 只读需要的那几段:
先读头部 256 KB 找 `Attachments`(0x1941A469),找不到就去 `SeekHead` 查它的位置再定点取。

四条实测出来的:

- **`SeekPosition` 是相对 Segment 的「数据起点」**,不是文件绝对偏移。当成绝对的
  表现是读回一段垃圾,解析静默返回空。
- **长度的首字节要抹掉长度标记位,而元素 ID 不抹** —— 两者规则不同。混用的表现是
  每个元素都大出一大截,解析当场跑飞,一句错都不报。
- **不能只信 MIME**:实测封装工具写的五花八门(`application/x-truetype-font` /
  `application/vnd.ms-opentype` / `application/octet-stream` / 空串),后缀也得算一条。
- **服务端不回 206 就整个放弃**:回 200 意味着它在给整部片,那比没有字体糟得多。

libass 侧:`ass_add_font` 之后**必须重跑 `ass_set_fonts(..., update=1)`**。
字体选择器是渲染器建立时从库里快照出来的,之后加的它看不见 ——
表现是「字体灌进去了,画出来还是系统字体」。加完还要**强制重画一帧**:
换字体不算「事件变化」,不强制的话要等下一句台词才换过来。

---

### 挂了 `setSubtitleParserFactory` 之后,轨道格式的 mime 被改写了 — 2026-09-07

「libass 完全没生效,ASS 字幕直接消失」的根因,一行:

```kotlin
fun isAss(f: Format?) = f?.sampleMimeType == MimeTypes.TEXT_SSA   // 恒 false
```

`SubtitleTranscodingTrackOutput.format()` 在把轨道格式交给下游之前会改写它 ——
`setSampleMimeType("application/x-media3-cues")` 紧跟着 `setCodecs(原 sampleMimeType)`
(media3-extractor 1.11.0 字节码,`javap -c` 逐条核对)。

于是**两侧看到的 Format 不是同一个**:

| 位置 | sampleMimeType | codecs |
|---|---|---|
| `SubtitleParser.Factory.create()` | `text/x-ssa` | null |
| 轨道选择 / `Tracks` / `onTracksChanged` | `application/x-media3-cues` | `text/x-ssa` |

只比 sampleMimeType 的话,解析器那侧一直是对的(所以事件确实被我们吃掉了),
而接 libass 那侧恒 false —— **字幕被吃掉了却没人画,一句错都不报**。
判据抽成 `isAssMime(sampleMime, codecs)` 一处,三个调用点(切轨、`onTracksChanged`、
面板上的「特效」标)共用。

---

### libass 的 `ass_set_frame_size` 必须在**开轨之后**再补一次 — 2026-09-07

`ass_set_frame_size` 没设过 = 往一张 0×0 的画布上渲染,`ass_render_frame` 回空 ——
**「libass 开起来了,一个字都没有」**。

而这一层的调用顺序**不由我们定**:画布尺寸是 Compose 布局完才有的,
轨道是 ExoPlayer 解完封装才有的,外挂字幕更是起播之后才装。
`setSize` 里那句 `if (opened)` 看着无害,实际是「谁先到谁被丢掉」。
解法是把尺寸**记下来**,`activateTrack` / `activateFile` 成功之后各补一次。

同一类的还有 `ass_add_font` 之后要重跑 `ass_set_fonts(update=1)` —— 都是
「这一层的状态要在另一层就绪时重放一遍」。

---

### 画面比例交给 `Modifier.aspectRatio` = 交给一条验不了的链 — 2026-09-07

用户为「画面被拉伸」报了两轮。问题不在 `aspectRatio` 本身对不对,在于
**对不对只有真机肉眼看得出来** —— 编译绿、单测绿、静态门禁绿,一路照不到。

现在尺寸由纯函数 `videoRect(boxW, boxH, videoAr, fit)` 算,JVM 单测直接钉。
凡是「只有肉眼能验」的几何,先想办法把算式拧成纯函数,再谈实现。

三条实测:

- **Cover(铺满裁切)那一档必须用 `requiredSize` 不能用 `size`**:后者会被父约束
  夹回容器大小,那一档就退化成和「原始」一模一样,而且看不出来。
- 视频层和**两个**字幕层(libass 画布、PGS/文本层)共用同一个尺寸 Modifier。
  各写一遍的两处早晚会漂,漂了的表现是「字幕比画面宽一截」。
- 监听器只管「以后」:`DisposableEffect` 里注册 `Player.Listener` 之前
  先取一次 `player.videoSize`。这个 effect 的 key 一变就重挂一次,
  漏掉当前值的表现是比例永远 0 = 铺满 = 和「没算比例」长得一样。

mpv 那侧同一张档位表:「铺满裁切」不是一个宽高比,是 `panscan=1`;
换回别的档要把 `panscan` 归零,不然裁过一次就再也回不去。

---

### 字幕不要黑底,要描边 — 2026-09-07

给每句话垫一块半透明黑板,白字确实看得清 —— 代价是画面下方常年被切掉一条,
亮场景里那块板比字还显眼(用户原话:「播放 SRT 字幕会带黑色遮罩背景」)。
正解是黑色描边先画一遍、白字再压上去(`TextStyle.drawStyle = Stroke`):
字外面一个像素都不占,压在雪地上和压在夜景上一样清楚。libass 那条路默认就是这么做的。

图形字幕(PGS)另有一条:它的坐标是相对**片源画面**的,而叠加层是**显示出来**的
那块 —— 裁切档下两者不等长,原样贴会把整条推到画面外。落点要夹回矩形内;
双语 PGS 是一张图两行字,推出去的正好是下面那行英文。

---

### `HorizontalPager` 默认不预挂相邻页 — 2026-09-07

首页 Hero「切封面时有一块黑色遮罩,好像和艺术字一块」,两个原因叠在一起:

1. `beyondViewportPageCount` 默认 **0** —— 下一页是**开始滑的那一刻**才组合的,
   背景图这时才开始下载。滑进来的是一块空页,上面压着渐变幕布和已经从缓存里
   出来的艺术字,图晚半秒才补上。设成 1,图在上一页还在看的时候就取好了。
2. 翻页视差把图往反方向挪了 35%,而 Ken Burns 最多放大 10% ——
   挪出去的那 25% 底下什么都没有,露出来的就是幕布本身。
   **位移量不能超过缩放留出的余量**,否则「视差」就是「露底」。

---

### 播放页要沉浸式,两个内核都要 — 2026-09-07

隐藏的是 `WindowInsetsCompat.Type.systemBars()`,不能只隐藏 statusBars ——
手势条压在底排按钮上,而且那条白杠在深色画面上比状态栏还显眼。
行为用 `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE`(划一下还能叫回来),
`onDispose` 里必须 `show` 回去 —— 不还原的话回到首页也是没有状态栏。

---

### 真机上没有日志 = 每一轮都在猜 — 2026-09-07

用户原话:「我都不知道怎么让你更好的修问题了」。当时的状态是:

- `Android/data/xyz.linplayer.app/` **这个目录压根不存在** —— 应用从来没调过
  `getExternalFilesDir`,而那个调用本身就是目录被创建出来的时机。
- 日志只进 logcat,而 `Log.d` 在 release 里连 logcat 都不进;用户手上跑的**只有** release。
- 设置里那条「导出诊断信息」写进的是应用私有目录,弹一句「已导出到数据目录」——
  那个目录任何文件管理器都进不去。**用户点了、看见成功、然后什么也拿不到**。
  而且 `system.exportDiagnostics` 只是**返回一个 map**,它一个文件都没写过。

三条叠起来的后果不是「不方便」,是**所有只在真机上现形的问题都只能靠读源码猜**。
ASS 字幕这一条为此白烧了三轮。

现在:`core/Logs.kt` 落盘到 `getExternalFilesDir/logs/`(轮转两份、每份 512KB),
核心层的 `log` 事件**不看构建类型**一律落盘,未捕获异常也进去。
导出走 SAF(`ActivityResultContracts.CreateDocument`)让用户自己挑位置,
内容 = 我们写的两份 + `logcat -d`。**带 logcat 是必须的**:libass(`lp-libass`)、
mpv、MediaCodec、native 崩溃栈全在那一半,进程读自己的 logcat 不需要任何权限。

### 「开轨」和「第一批字幕数据」谁先到是不定的 — 2026-09-07

ASS 字幕在 Exo 内核上不出来的**第二个**根因(第一个是 mime 被改写)。

`syncLibassTrack` 挂在 `onTracksChanged` 上,而事件是解封装时一条条来的。
轨道表**往往先到** —— 那一刻 `bufs[id]` 是空的,`activateTrack` 直接
`?: return false` 走人,**再没有任何东西会重试**。于是:解析器照常把 ASS 事件
吃掉(不 output 是故意的,否则画两遍),libass 一次都没开过,屏幕上一个字都没有,
一句错都不报。偶尔能出是因为预缓冲刚好赶在了前面,或者用户手动切了一次轨。

修法是**两边都能触发开轨**:`activateTrack` 只记下「要哪条」,
`header()` / `chunk()` 到货时发现还没开就自己补开。开失败(`assOpen != 0`)是硬失败,
要把「想要」一起清掉 —— 不清的话每来一条字幕就重试一次,日志刷屏。

一般化:**凡是「A 到了就用 B」的两个异步来源,判据不能写在其中一边**。
写在一边的那半边永远有一个「我先到,对面还没来」的分支,而那个分支通常被写成放弃。

### `Modifier.heightIn` 约束的是框,不是图 — 2026-09-07

用户报「有些艺术字和下面的标签离得很远」。`Image(painter, …,
Modifier.heightIn(max=92.dp).widthIn(max=320.dp), contentScale = Fit)`:
宽长条的片名先顶到 320 的宽度上限,布局框的**高度仍然是 92**,而 `Fit` 画出来的
只有五十几 —— 差出来那三十几 dp 是**框里的空白**,看起来就是标题和标签中间空一块。

`heightIn`/`widthIn` 只给约束,不会把框收到内容大小。要么自己按原图比例算尺寸
(现在是 `artLogoSize`,纯函数,`LogicTest` 钉着),要么别用 `Fit`。

### Hero 上不要常驻动效 — 2026-09-07

先后被用户否掉两次:翻页视差(35% 位移对 10% 的缩放余量,挪出去的部分底下是空的,
露出的是幕布)、Ken Burns 恒速缓推(原话「为什么封面右边会有自动推拉」)。

还有一条:`pager.animateScrollToPage` **默认是 spring**,大图翻页时尾巴长还回弹
(原话「最垃圾的推拉效果」)。自动换片要显式给一条短 tween。

结论:**封面本身不动,只在到点换片时推一次**。

### 服务器图标底下不许垫底色 — 2026-09-07

两处都犯了。首页顶栏那颗胶囊更离谱 —— 图标位是**一块渐变色块**,
不是「图标没加载出来」,是压根没去取过图标(`account.icon` 一次都没调)。
服务器页则是 `background(accDim)` + `ContentScale.Crop`:
服务器图标基本都带透明通道,垫一块琥珀色等于给每台服务器套一个不是它的方框,
`Crop` 还会把非方形的切掉两边。透明底 + `Fit`。

### 画面比例:`videoSize` 要等首帧,而首帧之前 0 的含义是「铺满」 — 2026-09-07

「画面被拉伸铺满整个屏幕,哪怕选了原始比例」用户报了三轮。前两轮修的都是**算式**
(`videoRect` 已经有单测钉着,一直是对的),而真正的洞在**比例什么时候到手**:

- `ExoPlayer.videoSize` 要等**首帧解出来**才有值(硬解冷启动实测好几秒);
- 监听器还会随 `subOff` 重挂、随进程重建 —— 错过那一次事件就永远是 0;
- `videoRect` 里 `ar <= 0` 的分支是「先铺满」,而**铺满和拉伸在屏幕上长得一模一样**。

一般化:**一个「还不知道」的值和一个「已知的错值」在界面上往往没有区别**,
所以兜底分支必须能被外部看出来。三条来源按到手的早晚排:
`emby.itemMedia` 的 Video 流宽高(**按下播放之前**就有,和判断横竖屏是同一份数据)→
`Tracks` 里的 `Format.width/height`(解封装完就有)→ `videoSize`(要等首帧)。
非方形像素记得乘 `pixelWidthHeightRatio`。

**PGS 位图字幕被拉伸是同一个根因。** `PgsParser` 给的 `Cue` 里
`position` / `line` / `size` / `bitmapHeight` 全是**相对片源画面的比例**
(反编译 `PgsParser$CueBuilder.build()` 核对:锚点常量都是 0 =
`ANCHOR_TYPE_START` / `LINE_TYPE_FRACTION`),所以只要字幕层和视频层共用同一块
矩形就一定对齐 —— 而那块矩形算错的时候,字幕跟着一起错。

### 截屏不能用 `View.draw`,也不能用核心层那条 — 2026-09-07

`SurfaceView` 的画面不在 View 树里,View 树那一块是被 `PorterDuff.CLEAR` 抠出来的
**透明洞** —— `View.draw()` 截出来是一片空。唯一能读回它的是
`PixelCopy.request(surfaceView, bitmap, …)`(API 24+),而且两个内核都是 SurfaceView,
所以这一条路两边通用。

核心层的 `player.screenshot` 用不了:它是 mpv 的 `screenshot-to-file`,
ExoPlayer 内核下 mpv 手里根本没有这一片;而且它写进应用私有目录,
用户拿不到文件(和「导出诊断信息」是同一类安慰剂)。
落盘走 MediaStore 的 `RELATIVE_PATH=Pictures/LinPlayer`(API 29+ 免权限);
API 28 及以下写相册要 `WRITE_EXTERNAL_STORAGE`,为一颗截图按钮去要全盘写权限不值,
那些机器落到 `Android/data/<包名>/files/Pictures/shots`。

### 一颗「点开永远是空的」按钮比没有它更糟 — 2026-09-07

同一批里用户点掉了三处:

- 详情页那颗「选集」:它只是把页面滚到同一页再往下两屏的选集栏;
- 播放页电影的「选集」:电影没有 `season_id`,点开必然空表;
- 比例面板里的「片源未知」:那行字是**给我自己看的自检**,用户切比例时读到它
  只会以为自己弄坏了什么。自检该进日志(`lp-exo` 已经在打),不该摆在选项旁边。

判据:**这个控件在最常见的情况下会给出什么?** 答案是「什么都没有」就别画它。

### M3 的 `DropdownMenu` 和这套皮不是一回事 — 2026-09-07

用户原话「长按出现的编辑列表太丑了,没有做适配软件的 UI 和动效」。
Material 自带的下拉是方盘 + 一条平淡的 fade,夹在玻璃面里像贴上去的另一款应用。
换成自己的 `LpMenu`(`Popup` + 同一块 `glass` + 从锚点那一角长出来的缩放),
卡片长按菜单、服务器长按菜单、首页换服务器三处共用一份 —— 各页自己拼一套
必然长出三种间距。

顺带:**换服务器不该是弹窗。** 弹窗是「打断你,让你回答一个问题」;
换服务器是顶栏那颗按钮的**展开态**,它不该盖住整页。

### 固定 dp 的版面高度在两台机器上是两种版面 — 2026-09-07

首页 Hero 原本写死 392dp。用户报「占首屏的比例有点低」—— 在他那台长屏上它只有
三分之一,而在小屏上早就过半了。版面高度(不是间距)要写成**屏高的比例**再上下夹一下。

同一条的另一面:顶栏那颗服务器胶囊后面跟了个 `Spacer(weight(1f))`,自己不带权重,
Row 于是「要多少给多少」量它 —— 长服务器名把右边两颗按钮整个挤出屏幕。
**Row 里会变长的那一项必须自己带 weight**,不能靠后面的 Spacer 顶。

## 跨域交叉引用

这些条目和本领域强相关,但正文放在别的文件里(一条经验只存一份正文):

- [Android mpv subtitle fonts](player-mpv.md) — 安卓 libass 缺字体导致文本字幕整段不渲染
- [TV 端 UI 选型](ui-tv.md) — TV 前端与焦点库的硬约束
- [手机端 UI(ui/mobile)](ui-mobile.md) — 单 APK 靠 UA 标分流 TV/手机
- [同步命令里裸 tokio::spawn](network.md) — 两端共有的「一点下载就闪退」

---

### Go 核心层接上安卓:五条只有装机才现形的

*(2026-09-06 手机端 Compose 版整轮落地时踩的。类型:project)*

**① mpv 的 `--wid` 在安卓上要的是 `android.view.Surface` 的 jobject,不是 `ANativeWindow*`。**
传后者进去,libmpv 会**在自己的线程上**再对它调一次 `ANativeWindow_fromSurface`,当场:

```
JNI DETECTED ERROR IN APPLICATION: jobject is an invalid JNI transition
frame reference … in call to GetObjectField        → SIGABRT
```

栈顶指着 `libandroid.so` 的 `ANativeWindow_fromSurface`,**看起来像宿主的错**。
正确做法:JNI 层持一个 Surface 的 global ref,把那个引用的地址交给 `wid`;
同一个 Surface 只是尺寸变了就**别重设 wid**(重设会让 vo 整个重建,转屏黑一帧),
改设 `android-surface-size`。解绑顺序:先 `lp_set_surface(0)` 阻塞返回,**再** `DeleteGlobalRef`。

**② 没有 `JNI_OnLoad` 注册 JavaVM,起播必失败。**
mpv 的 android GPU 上下文要经 JNI 问 Surface 的尺寸与格式,ffmpeg 的 mediacodec 也要 JavaVM。
两者都从 `av_jni_get_java_vm()` 拿,而那个全局只能由宿主注册一次。
症状是 `"No Java virtual machine has been registered"` → `"Could not attach java VM."`
→ `"Failed initializing any suitable GPU context!"`,而界面上只有黑屏。
`av_jni_set_java_vm` 由 libmpv.so 导出,直接声明就能调。

**③ mpv 的 error 日志原来一个字都没往外走。**
`core/player` 只留了 shader 编译错误,别的全丢。上面两条能被定位,靠的就是把
`MPV_EVENT_LOG_MESSAGE` 整条转成核心层日志。**「起播失败」在界面上只是黑屏,
而 mpv 明明在报原因** —— 和「核心层日志一开始一个字都没往外走」是同一个坑。

**④ 安卓设不了环境变量,所以 debug 构建里核心层日志要默认开。**
`LP_CORELOG=1` 那条门控在 PC 上好用,在安卓上等于永远关着 —— 而它是排查唯一的出口。

**⑤ cgo 的 C 前导住在一个块注释里,里面不能再出现块注释的结束符。**
连中文说明里、连 `/* 变量名 */` 这种行内注释里都不行:出现了就提前把前导关掉,
报一串看不懂的 Go 语法错(`unexpected >` / `string not terminated`)。**同一天踩了三次。**

**失效条件**:①② 是 mpv 的契约,换 libmpv 构建也成立;
③④ 是本仓库的实现选择;⑤ 是 cgo 的语法事实。

---

### 出包与签名:minSdk ≥24 时 AGP 默认只签 v2/v3

*(2026-09-06。类型:project)*

判据写成「`unzip -l` 看得到 `META-INF` 证书」时,**那条判据永远过不了,而包其实是签了的** ——
AGP 在 minSdk ≥ 24 时默认关掉 v1(JAR)签名。要让两条判据都成立就显式
`enableV1Signing = true`;顺带它也是侧载到老 ROM / 第三方安装器的唯一凭据,
而「装不上」在用户那头没有任何线索。

**ABI 必须拆包。** 一个 ABI 的 native 就有 34 MB(`liblpcore.so` 18.4 + `libmpv.so` 16.1,
已 strip),两个塞一个包是 **103 MB**,而任何一台设备只用得上一半。
`isUniversalApk = false` —— 留着那个「什么都有」的包,早晚有一次发布传的是它。
★ ABI 名单只许写在 `splits` 一处:同时写 `ndk.abiFilters` 的话 AGP 直接拒绝构建,
**而那是对的**,两份名单必然漂移。

**失效条件**:AGP 9.x 的行为;v1 默认关是 minSdk ≥24 才有的。

---

### 安卓 surface 换绑:`vo` 必须走 property,不能走 option

*(2026-09-06。类型:project)*

**症状**:第一部片好好的,退出去再进第二部 —— **有声音,没画面**,一条错都不报。

**原因**:mpv 初始化**之后**,`mpv_set_option_string` 会被转成 `options/<name>` ——
那只改存着的选项值,**不会拆掉/重建已经跑起来的 vo**。于是:
第一部正常(vo 还没建,`loadfile` 时才读选项)→ 解绑那一步的 `vo=null` 其实没生效 →
第二部重新绑上的 `wid` 也没人读 → 旧 vo 还攥着一个已经销毁的 Surface。

**做法**(照 mpv-android,它是这个库在安卓上的参考实现):

| 动作 | 调用 |
|---|---|
| 解绑 | `vo=null`(**property**)→ `force-window=no` → `wid=0` |
| 绑定 | `wid=<jobject>` → `force-window=yes` → `vo=gpu`(**property**) |
| 只改尺寸 | `android-surface-size`(**property**),**不重设 wid** |

`wid` 是唯一必须留在 option 接口的:它不是运行期属性,vo 建立时才读它。
`force-window` 不切的话,vo 拆掉之后没东西把输出链重新拉起来。

**失效条件**:libmpv 的行为(实测口径为 mpv 0.3x/0.4x 系)。
未在真机复现过 —— 这条是**照参考实现对齐**,不是被断点验证过的修复。

---

### 第二个播放内核(ExoPlayer):分叉点只有「谁解码渲染」

*(2026-09-06。类型:project)*

用户要 mpv / ExoPlayer 两个内核可切(mpv 在部分机型上出「有声音没画面」)。
**换的只是解码渲染那一段**,前面那一整条不能换:版本正则、跨服续播取最大、
「看完了的再点播放从头开始」、预取代理、start/stop 上报 —— 各写一份的下场是
「换个内核续播位置就不对了」,而两条路各自看都对。

所以核心层的 `player.play` 加了一个 `engine` 参数,`Play` 和 `PlayResolve`
共用同一个 `play(..., useMpv bool)`,只在最后三行分叉;`engine=exo` 时
把算好的 `play_url` 回给 UI,由 ExoPlayer 去 load。

☠ **地址一律用核心层回的那个,UI 不许自己拼** —— 反代只在 `/emby/` 前缀下处理
Range,拼错的表现是「跳到没缓冲的位置就卡死」(见 `network.md`)。

安卓侧同理:整页只有三处 `if`(视频层 / 状态从哪来 / 控制发给谁)。
`engine` 进播放页时读一次就钉住 —— 播到一半换内核会让状态来源整套换掉。

---

### `//go:build android` 的文件,整套门禁一处都不编

*(2026-09-06。类型:project)*

`check-core.sh` 只编宿主平台。`core/player/surface_android.go`、
`core/ffi/jni_android.go` 这类带 `//go:build android` 的文件,
**本机跑完所有门禁全绿,推上去 CI 才红** —— 这一轮就是这么红的一次
(一个 `setProp` 撞名,五行报错)。

本机唯一能照到它的一条命令(约 1 分钟,NDK 装 Android Studio 就有):

```bash
source scripts/env.sh
ANDROID_HOME=<SDK 路径> bash scripts/build-core-android.sh arm64-v8a
```

**改过 android 专属文件就跑它,再推。** 这和「桌面 check 照不到安卓」
是同一个洞在 Go 栈上的形态 —— 那次连红三个提交。

---

### 一轮六件:受控开关、手指落点、轨道名、续播 — 2026-09-07

*(类型:project)*

用户一次报了六件事,里面有四件是**同一类**:界面上摆着一个东西,
它看起来在工作,实际上什么都没接。

#### 受控开关不回填 = 「点不开」

设置页的三个开关拨过去就弹回来。根因**不是点击没生效**,是
`LpCell(switch = prefs.bool(k))` 显示的永远是本地那份 `prefs`,
而 `setPref` 只发命令、从不把新值写回去。乐观更新 + 失败回滚(`prefs.setPrefetchSettings`
那一页早就是这么写的),这类事结构上就不会再发生。

同一批里还有更糟的一层:`background_play` / `auto_next` 这两个键
**核心层里连字段都没有** —— `setPlaybackPrefs` 收下、返回成功、一个字节都不改。
`check-android-args.py` 当时是 62 条,照不到它们,因为那个门禁只扫「命令的参数名」,
而这两个是塞在 `settings` 里的**内嵌键**。删掉换成核心层真读的那几项之后是 64 条。

#### 长按菜单要从手指底下长出来

`LpMenu(open, onDismiss, Alignment.Center)` 挂在卡片外面那个 `Box` 上,
于是不管点哪儿都从卡片正中间冒出来。解法是把手势从 `combinedClickable`
换成 `pointerInput { detectTapGestures(onLongPress = { ... }) }` 拿到落点,
再 `Popup(Alignment.TopStart, IntOffset(落点))`。

☠ **坐标要补偿。** 手势挂在 Row 上(Panel 里面),Popup 的父级是外面那个 Box ——
两者差一圈 `Panel` 的外边距,不补的话菜单整体偏左上一个边距。

#### `display_title` 不是轨道名

Emby 的 `MediaStream.DisplayTitle` 是**服务器自己拼的**「语言 + 格式」
(`Chinese - PGS`),压制组写的「简体中文特效」在 `Title` 里。
`core/emby/mediainfo.go` 原来只映射前者,于是三端的字幕列表整张表都是格式标签。
两个字段都要透出,回落顺序 `title → display_title → 自己拼`。

改这个字段会让 `check-core.sh` 第 5 关(差分对账)红一条 ——
语料录的是黄金实现的输出,而黄金实现没有这个字段。**这是有意的分歧,改语料的 `expect`**,
不要往 `knownDiffs` 里塞(那是给「还没修的差异」用的,要带到期日)。

#### 续播判据必须在核心层

安卓两个内核都从头播放。根因:`PlayerPage` 起播时压根没传 `resume_secs`,
而 `player.play` 把「没传」当成了 0。桌面端传了,所以只有手机端不续播。

判据放核心层(`resumeFor`:调用方 <= 0 就用 `candidate.PositionTicks`)。
**让每个调用方各自记得传**的写法,漏一处就是那一端整个不续播,而且不报错。

#### Exo 的画面比例:`VideoSize.UNKNOWN` 会把已知值抹掉

`onVideoSizeChanged` 在换轨 / 渲染器重建时会发一次 0×0,而上一版是无条件
`ratio = r` —— 刚从 `Tracks` 里算出来的正确比例被一个 0 覆盖,而那条
「拿到就停」的轮询早退出了,再没有人纠正。`videoRect` 里 `ar<=0` 走的是「先铺满」,
铺满和拉伸在屏幕上长得一模一样。

两条一起改才行:**拿不到就别写**,以及**轮询不退出**(没在等的时候一秒一次)。

#### 内封 ASS 和外挂 ASS 抢同一个渲染器

`libass` 这一层只有一个 `g_track`。外挂要走一趟网络(几百毫秒),内封等解封装,
**谁后到谁赢**;而外挂那条还顺手把 `wanted` 清空,内封再也开不回来。
规矩定死:选中的内封轨说了算,外挂只在 `wanted == null` 时补空缺。

### 「空的语言偏好」不等于「关了字幕」 — 2026-09-08

#### 一个判据写反,整条字幕链被关死

真机日志原话:`libass 不走这条路: available=true subOff=true`,三次全是它,
`选中字幕轨 …` 一行都没有 —— 因为在它前面就 return 了。

`PlayerPage` 里写的是 `subOff = subLangPref == ""`,而核心层的 `sub_lang` 是
`*string`、**默认 null**,含义是「没有偏好,随便挑一条」。真正的开关是
`sub_enabled`(默认 true)。于是**从没设过字幕语言的人**(绝大多数)一进播放页
就被判成「用户关了字幕」:libass 不开、`pickSubtitleTrack` 不兜底、外挂 ASS 不取。

一句错都不报,而且 PGS 图形字幕**照常显示**(它走 media3 自己那条路,
和 subOff 无关)—— 所以现象是「别的字幕有,就特效 ASS 没有」,
看着像 libass 没接上,其实 libass 一次都没被调用。

**查法**:先看有没有 `选中字幕轨` 那一行。没有 = 根本没走到判断,别去查 libass。

#### PGS 的比例是相对「字幕平面」的,不是相对画面的

`PgsParser` 交出来的 `position/line/size/bitmapHeight` 全是拿**字幕平面**的宽高
除出来的,而平面是原盘那一帧(蓝光一律 1920×1080)。2.35:1 的片子重编码成
3840×1632 之后画面不带黑边了、平面还带着:拿画面框(2460×1046)当平面用,
横向不变、竖向被压掉 1046/1384 = 0.756,屏幕上就是**字幕向两边拉伸**。

平面尺寸能从 cue 自己反推:平面宽 = 位图宽 / `size`,平面高 = 位图高 / `bitmapHeight`。
按**宽度**把平面贴到画面上(PGS 平面横向总是铺满原帧,多的是上下黑边),
平面和画面同比例时算式自动退化成原样。`cueRect` 是纯函数,`LogicTest` 钉住。

#### 画面几何这一环,日志已经自证是对的

同一份日志里 `画面 Source 容器 2460×1080 → 画到 2460×1046(比例 2.3529)` ——
3840×1632 的片源算出来分毫不差。**用户说的「画面也被拉伸」是字幕层带来的错觉**;
`R16x9` / `Cover` 两档本来就会形变,那是档位的定义不是 bug。
下次再报比例,先看这一行:它对了就别再动 `videoRect`。

#### media3 给的 `initializationData[0]` 不是 ASS 头

`MatroskaExtractor` 对 `S_TEXT/ASS` 塞的是**两条**(1.11.0 字节码
`ImmutableList.of(SSA_DIALOGUE_FORMAT, getCodecPrivate(codecId))`):

- `[0]` = 它自己拼的 `Format: Start, End, ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text`,**恒 90 字节**
- `[1]` = MKV 的 CodecPrivate,也就是带 `[Script Info]`(PlayResX/PlayResY)和 `[V4+ Styles]` 的真头

拿了 `[0]` 的表现是 libass **开得起来**(`ass_process_codec_private` 不报错、`rc=0`),
但样式表是空的、PlayRes 也没有 —— 事件的 Style 索引全落在表外,渲染那一步整条跳过。
屏幕上就是「特效字幕完全不显示」,一句错都不报。

**指纹是日志里那句「头 90 字节」**:`len("Format: Start, End, …, Text") == 90`,
对得上就是这条错。现在按内容认(挑含 `[Script Info]` 的那条),`LogicTest` 钉住。

顺带记两个数:`第一条事件进 libass`、`libass 画出第一帧`。这条链上
「开起来了但一个字没有」有四五种成因(头不对 / 事件没喂进去 / 画布 0×0 /
字体缺 / 时间轴偏),不记这两个数只能一轮一轮试。

#### 一个副产物:`图形字幕平面 1920×1080` 实测坐实了 PGS 那条

同一份日志里画面是 `2460×1046`(片源 3840×1632)而字幕平面是 `1920×1080` ——
两者比例 2.35 vs 1.78,竖向差 24%。这不是推测,是打出来的数。

#### media3 的 `Dialogue:` 行里**没有**开始时间

`MatroskaExtractor` 拼的前缀是常量 `Dialogue: 0:00:00:00,0:00:00:00,`,
之后只回填**第二格**、填的还是 `blockDurationUs`
(1.11.0 字节码:`setSubtitleEndTime(codecId, blockDurationUs, data)` 往偏移 21 写)。
所以那一行的形状是「**0,时长,正文**」,第一格从头到尾是那个常量 0。

真正的播放时刻在**样本**上,由 `SubtitleTranscodingTrackOutput` 按
`timeUs + CuesWithTiming.startTimeUs` 定位;而 `SubtitleParser.parse()` 收到的
`OutputOptions` 是 `allCues()`,**一个时间戳都不带**。也就是说解析器那一侧
根本不可能知道这条什么时候播。

上一版把第一格那个 0 当成事件起点喂给 `ass_process_chunk` —— 整片字幕全排在片头,
播到哪儿都是空的。指纹是日志里那句 `第一条事件进 libass @0ms`(当时播到 730s)。

**解法:让事件搭 media3 的 cue 便车。** 解析器输出一条带记号的 cue
(`startTimeUs=0`,时长照填),media3 自己加上样本时间;`onCues` 在**播到那一刻**
收下、拆出正文喂 libass、再把这条从可见 cue 里摘掉。
副作用全是好的:切轨不用自己重放(media3 会从当前位置重新派发),
per-track 事件缓存和 8MB 闸门整套可以删掉。

#### 「自适应」档会把字幕一起裁出屏幕,还会让 libass 拉宽字

`画面 Cover 容器 2460×1080 → 画到 2460×1384`:画面矩形比容器**大**。
字幕层跟着用这块矩形,底部那行就摆到屏幕外面 —— 这一档下字幕整条不见。
字幕的可视范围要取「画面矩形 ∩ 容器」。

裁完还有第二层:`ass_set_storage_size` 是**粘的**,画布和片源不再等比时
还留着上一次那份 storage,libass 会当成非方像素去补偿,字被横向拉宽。
裁过就传 `0` 明确告诉它按方像素算,而且**必须无条件下发**
(`if (w>0&&h>0)` 那种写法根本清不掉旧值)。

## 2026-09-08 · Exo 内核画 ASS 特效字幕掉帧:两处都在,只修一处不够

用户报「ASS 字幕随着屏幕移动而移动时掉帧卡顿」。两个原因叠在一起,
对白字幕看不出来(靠 `detect_change` 跳过了),字幕一动就同时爆发:

1. **渲染循环跑在主线程上。** `ExoEngine.kt` 的 `LibassLayer` 用
   `LaunchedEffect` 起循环 —— 它的默认调度器就是主线程。字幕一动
   `detect_change` 恒 1,于是每 33ms 在 UI 线程上做一次完整的软件渲染。
   改 `Dispatchers.Default`。
2. **每帧 `memset` 整块画布。** `core/ffi/libass_android.go` 的 `lp_ass_render`
   无条件清整张位图 —— 1080p 竖屏是 2400×1080×4 ≈ **10MB**,而字幕实际
   占不到画布的 15%。改成只清「上一帧写过的那一块」(`g_dirty_*`,
   由 `lpa_blend` 累积)。

挪到后台线程**必须配双缓冲**:单张位图在 Skia 读的同时写,表现是字幕撕成两半
(比掉帧更难看,而且看着像字幕本身坏了)。

☠ 双缓冲带来一个不显眼的连锁:后备那张装的是**上上帧**。
- 拿 `force=false` 去画 → libass 说「没变」→ 后备那张的内容是错的,屏幕在两帧之间跳。
- 拿 `force=true` 去画 → 每帧整块清屏重画,对白字幕那点省电全没了。

解法是把「变了没有」和「画」拆成两次调用:新增 `assChanged(posMs)`
(只跑 `ass_render_frame` 读 `changed`,**一个字节的位图都不碰**),
变了才画、画就 `force`。libass 内部有缓存,重复问不贵。

### 字幕样式在安卓这边有三个消费者

| 内核 | 谁画 | 认哪几项 |
|---|---|---|
| mpv | libmpv | 五项全认(核心层设 mpv 属性) |
| Exo · ASS | libass(`Native.assSetStyle`) | 只有大小和位置 |
| Exo · SRT/VTT | Compose 的 `TextCue` | 大小 / 描边 / 粗体 |

☠ **libass 的 `ass_set_line_position` 和 mpv 的 `sub-pos` 方向是反的**:
mpv 是 0 顶 / 100 底,libass 是 0 = 底部默认、越大越往上。换算写在
`assSetStyle` 里(`100 - position`)。两端各错一次会互相抵消,
所以文本字幕那一侧的 `bottomPadFraction` 单独有测试钉住方向。

`SubStyle.set()` **必须两边都推**:只落库的话 Exo 内核下一点反应都没有,
而 ASS 特效字幕走的正是那条路。

---

## 弹幕画在 View 层,和内核无关(2026-09-10)

弹幕**不走 mpv**。渲染在 `ui/player/DanmakuLayer.kt`:一个 Compose `Canvas`,
盖在 `SurfaceView` / `ExoSurface` 上面,用 `withFrameNanos` 自己走帧。
所以 mpv 和 Exo 两个内核下都有,播放页那一项不再按内核分支。

排版仍在核心层(`player.danmakuLayout` 一次取走),UI 只做两件事:
按帧插 x、把字画上去。**两端各写一份排版会漂**,这条口径不能松。

三件只有画在 View 层才成立的事:

- **位置得自己对表。** `player.status` 4Hz 一拍,直接拿它画的表现是弹幕每秒只动
  4 下、一格一格地跳。做法是每收到一拍就对一次表,两拍之间按帧时钟往前推,
  倍速要乘进去,暂停要停。
- **两支 `Paint` 跨帧复用**(`remember`)。每帧新建的话 GC 直接落进渲染帧里。
- **不能遍历全表。** 一集上万条,靠「按时刻升序 + 二分找起点 + `t > now` 就 break」
  把每帧的活压到几十条。

---

## 参数闸门的盲区:`args(*buildMap.toList().toTypedArray())`(2026-09-10)

`check-android-args.py` 靠正则从 `call("x.y", args("k" to …))` 里抠参数名。
仓库里有三处是**动态拼**的 —— `buildMap { put("k", …) }` 再展开成 `args(*…)`,
正则一个都看不到。三处里两处是真错的,而且两边都不报错:

| 调用点 | 传的 | 核心层读的 | 用户看到的 |
|---|---|---|---|
| `emby.listItemsPage` | `view_id` + 平铺的分页/排序 | `parent_id` + **嵌套的 `query` 对象** | **点进每个媒体库出来的都是同一份全站列表** |
| `emby.search` | `view_id` | `parent_id` | 「在这个库里搜」搜的是全站 |

闸门已经补上(`SPREAD` 正则 + `build_map_keys` 花括号配对),补完当场红了 8 条。
**认不出来的写法一律跳过,不算红** —— 假红会训练人无视闸门。

同一批还捞出第三件事:`args()` 把非 `Number`/`Boolean` 的值一律 `toString()`,
所以 `JsonArray` 会变成一个**字符串**。核心层的 `strList` 只认 JSON 数组,
拿到字符串当空表 —— 表现是搜索页那个「包括集」开关点了没反应。
`args()` 现在有一支 `is JsonElement -> v` 原样透传,数组用 `jsonArrayOf(...)` 构。

## 弹窗宽度按屏幕比例给,不写死上限(2026-09-10)

`LpDialog` 原来是「最宽 420dp,否则铺满」。**同一个数字在两种屏上各给出一种毛病**:
手机(360dp)上等于满幅,几个选项占掉一整屏;平板(800dp)上 420dp 只占半屏多一点,
小得像个错位的提示框。用户原话:「我在平板用的时候小小一个,手机用的时候大大一个」。

改成 `dialogWidth(screenWidthDp) = 屏宽 × 0.82`,夹在 `[280, 600]`,
再夹一次不许超过屏宽(分屏窗口)。上下限不是审美是可用性:窄于 280dp 输入框
放不下一行地址,宽于 600dp 一行字要横扫整个平板。

## 长截屏是自己滚自己拼,不指望系统那颗「捕获更多」(2026-09-10)

Compose 1.12 的 `ui` 里确实带着 `androidx.compose.ui.scrollcapture.*`,
`AndroidComposeView` 也实现了 `onScrollCaptureSearch` —— 但**那颗按钮出不出、
截到哪一段,全由系统截屏 UI 说了算**,而且只有 Android 12+ 的部分 ROM 有。
演示要的是「按一下拿到整页」,所以自己做:`ui/components/LongShot.kt`。

三条只有真拼过才知道的事:

- **贴的是「真滚掉的距离」,不是「请求的距离」。** `ScrollableState.scrollBy` 回的是
  实际消费掉的像素;到底那一帧请求 800 只走 120,按 800 贴会在长图里留一条
  680 像素高的空白,而那看起来像截图坏了。
- **第一帧整张,之后每帧只取最底下的 d 行。** 每帧都整张贴的话重叠区盖掉上一帧,
  长图里同一屏内容出现两次。
- **底栏必须让开。** 它是浮在内容上的一层,留着的话**每一片切片里各印一条**。
  截取中 `LongShot.capturing` 置位,`PhoneRoot` 据此不画底栏,按钮自己也藏起来。

页面用 `LongShotTarget(state)` 一行登记自己的滚动容器,离开就摘掉。
登记表用 `mutableStateOf` 不用普通字段 —— 按钮要跟着换页出现和消失。

## 转屏那一下要黑,不要「转过去」(2026-09-12)

用户:「从集/电影详情页进入到播放页,会有一段从竖屏转向横屏的画面,反之也有…
用户只会觉得卡」。两条,合起来才是那一段:

**① 方向定得太晚。** 播放页进来之后才 `emby.itemMedia` 问一次宽高,拿到才转 ——
一次网络往返之后,竖版的播放页早就画完了。而**详情页手里本来就有**这份数据
(`Version.streams` 的 Video 流带 width/height,选版本那一套已经在用)。
改成经 `Route.Player.ar` 带过来,拿到就在第一次组合里定方向,拿不到(strm / 网盘源)
才回落成原来那条异步路。

**② 系统转屏动画拍的是「转之前那一帧」。** 所以只要那一帧是一整块黑,转屏就是
黑转黑,看不见 —— 不必去动 `rotationAnimation`(它要求窗口带 `FLAG_FULLSCREEN`,
而本页用的是 `WindowInsetsControllerCompat.hide`,给不给得上得挂真机才知道)。
黑幕本来就铺着,差的只有 OSD:

- 进场:方向没落定就不画 OSD(`turningTo(want, portrait)`)。
  **必须带放弃计时**(900ms):分屏 / 折叠屏 / 无视方向请求的 ROM 上永远落不定,
  不设上限的话那台设备顶栏再也出不来。
- 退场:**先松方向锁、等 150ms 再 `popBackStack()`**。直接 pop 的话系统拍到的是
  详情页横着的第一帧,转过来就是用户说的「反之也有」。等的这一下顺手把 OSD 撤掉。
  代价是所有退出路径都得走同一个 `leave()` —— 播完、eof、返回键、错误页、OSD 返回键,
  五处。漏一处就漏一处的观感。

`turningTo` 里 `want == null` 必须返回 false:不知道方向却把界面黑起来,
是拿一个猜测去换一段黑屏。

## 采样挂在 OSD 里 = 每次叫出顶栏都从零数一秒(2026-09-12)

用户:「网速显示要常驻…不需要打开再统计再显示,跟随状态栏显隐就行了」。
`NetSpeed()` 原来是个自带 `LaunchedEffect` 的 Composable,而它长在 `Osd()` 里,
`Osd()` 又包在 `AnimatedVisibility` 里 —— **收起来就退出组合,协程当场取消**。
于是每叫出一次顶栏:先空着(第一秒没有两次采样算不出速度),再跳出一个数。

改法是把「数」和「画」拆开:`sampleNetSpeed()` 挂在**播放页**这一层,
`NetSpeed(text)` 只管画。显隐还是跟着顶栏走,读数不跟。

> 通例:凡是「要花时间才有第一个值」的东西(采样、计时、动画进度),
> 都不能挂在会被 `AnimatedVisibility` / `if` 摘掉的那一层。

## Kotlin 的块注释会嵌套(2026-09-12)

注释里写了 `image/` 加一个星号,那个 `/` + `*` **在 Kotlin 里是一个合法的注释开始** ——
块注释可嵌套,于是后面那个 `*/` 只关掉了里层,外层一路吞到文件末尾。
编译器报的是二十几条「Expecting a top level declaration」,指向的行**离真正的病灶几十行远**。

写注释要提 MIME 通配符时,用文字描述,别把那两个字符原样写进块注释。
(行注释 `//` 没这个问题。)

## 安卓端的服务器图标(2026-09-12)

用户:「服务器编辑的弹窗增加编辑图标功能,支持本地添加、网络源添加……
允许用户自己添加网络源」。安卓端此前**一个图标入口都没有**(`grep iconLibrary` 零命中),
桌面端那套(图标库页 + 本地上传)一直在。

三条:

- **SAF 给的是 `content://`,核心层要的是真路径。** `account.setAccountIconFile` 收
  `file_path`,所以要先复制到私有目录再交过去。旧的顺手删掉,不然会攒一堆。
- **文件类型过滤放到最宽。** 实测各家文件管理器给图片的 MIME 五花八门,
  按图片类型筛的表现是「选择器里一张图都看不见」—— 一个打不开的入口。
  是不是真图片由核心层那一步判。和换界面字体那条同一个坑。
- **先 `clearAccountIcon` 再写 `icon_url`。** 不清的话旧图标还在缓存里,
  选了新的也不换 —— 表现是「点了没反应」,而配置其实已经改了。

## 安卓端的更新设置(2026-09-12)

「更新渠道 / 启动时自动检查 / GitHub 代理」这三项此前**只有桌面端有**。
安卓端能查、能下、能装,但这三项一个都改不了 —— 也就是安卓用户只能走
正式版直连 GitHub,而直连 GitHub 恰恰是这条链路在国内最常断的那一段。
核心层的 `prefs.getUpdateSettings` / `setUpdateSettings` 从落地那天起就在,没人接。

- **`update_auto_check_optin` 在安卓端从来没有任何人读过。** 桌面端 6 秒后查一次
  (`MainWindow.AutoCheckUpdate`),安卓端一次都不查。落了库、没人消费的偏好
  比没有更糟:它在配置文件里看着像个功能。补的入口在 `MainShell` 里,
  放在登录判定**之后** —— 没进门就先弹更新是打扰。
- **下载要跑在 `AppState.bg` 上,不是 `rememberCoroutineScope()`。** 后者随页面一起死,
  用户退出设置页就再也等不到那句「跳到系统安装界面」。
- **取消按钮只发 `system.cancelUpdate`,不自己关窗。** 核心层把档位改成 `idle` 之后
  轮询那一头会自己收尾并回调;抢先关窗的话,关掉的是一个还在下载的任务。
- **渠道线上值是 `prerelease` 不是 `preview`。** 写错的话核心层回「未知的更新渠道」,
  渠道从来就切不过去,而界面上那一格看起来切好了。码↔中文两个方向必须
  互为反函数,`LogicTest` 拿它来回走一遍钉住(同 `cornerLabel` 那条)。
- **代理 chip 上只放主机名。** 一整条 `https://…` 在手机上会把那一排撑出屏幕。
