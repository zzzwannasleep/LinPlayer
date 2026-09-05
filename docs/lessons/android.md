# 安卓平台(打包 / 签名 / 资源限定符 / R8 / LFS / 主题)

**这个领域最容易踩的坑:**
1. **这里几乎所有失败模式都是「构建绿、装机废」**:未签名 APK、缺 `touchscreen required=false`、libmpv 是 LFS 指针、R8 裁掉 JNI 回调 —— 全部要验成品不验中间状态。
2. **`-night` 的优先级高于 `-vXX`**,按 API 加主题属性必须建 `values-vXX` 和 `values-night-vXX` 两份,同名 style 是整条替换不是叠加。
3. **「有声音没画面」先查 Activity 主题的 `windowBackground`**,别先怀疑 mpv;透出链有四层。
4. **`cargo check -p app` 只编 Windows**,`crates/mpv` 的 overlay 有四个 cfg 变体,兜底桩任何 CI 目标都编不到、会静默烂掉。
5. **别再说「本机没 NDK 跑不了」** —— 仓库自带 `scripts/build-android-apk.sh`,裸 cargo check 会死在 host bindgen 缺 WinSDK 头。

> 本文件共 **11** 条。前 9 条标了原记忆文件名与类型;末两条是 2026-09-06
> Go 核心 + Compose 手机端落地时新踩的。

## 本页条目

- 安卓端身份 — `android-app-identity.md`
- APK 未签名陷阱 — `android-apk-unsigned-trap.md`
- 安卓能本地构建 — `android-local-build-works.md`
- 桌面 check 照不到安卓 — `desktop-check-misses-android.md`
- 安卓TV宿主壳与出包 — `android-tv-host-build.md`
- Android R8 JNI keep — `android-r8-jni-keep.md`
- 安卓资源限定符优先级 — `android-resource-qualifier-precedence.md`
- 安卓视频透出四层 — `android-video-transparency-chain.md`
- Go 核心层接上安卓:五条只有装机才现形的 — 2026-09-06
- 出包与签名:minSdk ≥24 时 AGP 默认只签 v2/v3 — 2026-09-06

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
