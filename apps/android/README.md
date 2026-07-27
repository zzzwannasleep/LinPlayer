# apps/android —— Android 宿主壳(TV 包 + 手机包)

Tauri 2 mobile 壳。同一份 Rust/Kotlin 代码出 **4 个 APK**:TV / 手机 × arm64 / arm32。

## TV 和手机是两个包(2026-07-27 改的)

在那之前是「一个 APK + `index-android.html` 按 UA 标 `location.replace`」,已经删了。
**设备类型运行时判不准**:大屏平板、投屏一体机、模拟器都可能被判成电视,而判反的表现
不是小 bug,是用户拿到**另一端的整套界面**。

现在壳打开哪个 html 在出包时定死,两个包**只差一个配置**:

| 包 | 入口 | 怎么出 |
|---|---|---|
| TV | `index-tv.html` | `apps/android/tauri.conf.json` 的默认值 |
| 手机 | `index-mobile.html` | 额外挂 `--config tauri.phone.conf.json` 覆盖窗口 url |

★ **两个包的 `applicationId` 仍是同一个 `xyz.linplayer.app`,故意的。** 一台设备只会装
其中一个,包名一致才保得住老用户的覆盖升级(`build.yml` 里有硬校验)。副作用只有
「手机包装到盒子上会顶掉 TV 包」,那本来也是用户主动选的。

★ manifest 只有一份:`leanback` 和 `touchscreen` 都是 `required="false"`,
`LAUNCHER` 和 `LEANBACK_LAUNCHER` 两个 category 都有。两个包共用它 ——
手机包里多一个 leanback category 不影响任何东西,不值得为它拆两份 manifest。

★ **CI 里有入口闸门**(`Assert APK entry point`):从成品 APK 里读
`assets/tauri.conf.json` 比对窗口 url。`--config` 一旦失效,出来的手机包会照样构建成功、
照样签名、照样装得上,打开却是整套 TV 界面 —— 源码里看不出来。

## ABI:arm64 和 arm32 都出

arm64 是 2026-07-27 才加的。在那之前只出 `armeabi-v7a` —— 盒子无所谓(32 位包能跑在
64 位设备上),但**手机不行**:8 Gen 4 / 天玑 9400 这一代 SoC 已经彻底砍掉 AArch32,
32 位包装上去直接起不来。

## 怎么出包

```bash
bash scripts/build-android-apk.sh                    # TV + arm64(默认)
bash scripts/build-android-apk.sh --phone --arm64    # 手机 + arm64
bash scripts/build-android-apk.sh --phone --arm32 --debug
LP_ANDROID_PKG=linplayer-android bash scripts/build-android.sh   # 只验交叉编译,不打包
```

⚠️ 脚本**不拉 `libmpv.so`**(CI 那步会拉)。本地第一次跑要手动放一份到
`gen/android/app/src/main/jniLibs/<abi>/libmpv.so`,ABI 要和 `--arm64/--arm32` 对上,
否则包出得来、装得上、一播放就 `UnsatisfiedLinkError`。

产物:`gen/android/app/build/outputs/apk/universal/release/app-universal-release.apk`
(名字里的 `universal` 是 gradle 的 flavor 名,不代表它含多个 ABI ——
一次只编一个 `--target`,所以里面就一个 ABI。)

**不要直接 `npx tauri android build`**:gradle 会转手调 cargo 编安卓目标,而
rquickjs-sys 在安卓必须现跑 bindgen —— libclang/resource-dir/sysroot/INCLUDE
那一整套 Windows 宿主特有的坑,逐条说明写在 `scripts/build-android.sh` 顶部。
上面那个脚本就是把那批环境变量喂给 tauri CLI。

## 几个不能想当然的地方

- **数据根必须由宿主显式喂。** 安卓没有 XDG/AppData,更没有「exe 同级 userdata/」,
  `paths::root()` 的默认解析会落到进程无权写的地方。壳在 `setup()` 里拿沙盒目录调
  `paths::set_root()`,而它**只在 `root()` 第一次被调用之前有效** —— 所以整块状态
  初始化(含 `AppConfig::load()`)都搬进了 setup,不能像桌面那样在 `run()` 顶部做。
- **APK 体积要按住 `CARGO_PROFILE_RELEASE_DEBUG=false`。** 根 `Cargo.toml` 的
  `debug = "line-tables-only"` 是给 Windows/Sentry 的,MSVC 把调试信息放独立 .pdb
  所以 exe 体积不变;ELF 会把它留在 `.so` 里一起打进 APK。实测 105MB → 21MB。
- **播放器已接原生 libmpv**(2026-07-20),与桌面共用 `crates/mpv`。四条缺一不可,
  少任何一条的表现都是「不报错但黑屏」,所以逐条记在这里:
  1. **`libmpv.so` 不入库**,由 CI 从 media-kit/libmpv-android-video-build v1.1.11
     的 `full-<abi>.jar` 拉进 `jniLibs/`(gitignore)。选 full 是为了 PGS 图形字幕。
     ABI 由 `build.yml` 的矩阵给(`arm64-v8a` / `armeabi-v7a`),四处必须对上:
     矩阵里的 `jni_abi`/`elf_class`/`elf_machine`、`rust_target`、`tauri_target`、产物文件名。
     漏一处 = APK 里的 .so 和代码不是同一个 ABI,构建绿、装得上、一播放就
     UnsatisfiedLinkError(所以 CI 里既验 libmpv.so 的 ELF 头,也验成品的 `native-code:`)。
     没跑这一步 → APK 照常绿,装上去按播放报「APK 里没有 libmpv.so」。
  2. **必须调 `av_jni_set_java_vm`**。这个二进制**没有导出 `JNI_OnLoad`**
     (`llvm-nm -D` 实测),所以 `System.loadLibrary("mpv")` 并不会替它登记 JavaVM。
     由 `MainActivity.nativeSetSurface` → `crates/mpv::set_android_java_vm` 完成。
     漏了它:库加载成功、`mpv_create` 成功、`loadfile` 成功,然后黑屏,不报错。
     CI 有一条符号断言盯着,换 libmpv 版本时它会先红。
  3. **渲染面是 SurfaceView**,插在 WebView **下面**(index 0,默认 z 序,
     不能 `setZOrderOnTop`)。Surface 由系统异步给,所以 `Player` 是**懒创建**的。
  4. **整条 CSS 渲染链要透明**(`html.playing`,见 `ui/tv/theme/tv.css` 末尾)。
     `html`/`body`/`.tv-app` 原本都是不透明的,漏掉任何一层都会把视频整个盖住 ——
     其中 `html` 最容易漏(body 背景透明时画布会回退用 html 的背景)。

  仍是明确报错的:`play_local`(本地下载)和 `source_play`(网盘/聚合源)。
  先把 Emby 直连这条走通,再铺开源类型。

  ⚠️ **未经真机验证** —— 首次上机若黑屏/无声,先 `adb logcat -s mpv`。

- **`gen/android/` 的工程骨架入库、构建产物不入库**(见根 `.gitignore`)。
  Tauri 的模板已经带了 `LEANBACK_LAUNCHER`,不用手改 manifest。

## 命令清单

`tv-commands.txt` 是 TV UI 真实会调的 63 个命令,由 `ui/tv` 的 import 反推得到。
`src/lib.rs` 的单测拿它和 `generate_handler!` 逐条对账 —— 漏注册**不会编译报错**,
只在用户走到那个页面时炸,所以让测试当守门人。

签名和返回类型是从 `apps/desktop/src/lib.rs` **逐字照抄**的:前端
`ui/shared/api.ts` 的 TS 类型和它们逐字段对应,改个名字前端就静默拿到 undefined。
