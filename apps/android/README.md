# apps/android —— Android 宿主壳(TV + 手机,同一个 APK)

Tauri 2 mobile 壳。**一个 APK 同时装电视和手机** —— manifest 里 `leanback` 和
`touchscreen` 都是 `required="false"`,`LAUNCHER` 和 `LEANBACK_LAUNCHER` 两个 category 都有。

壳打开的是 `dist/index-android.html`(几行的**分流 shim**),不是桌面那套 `index.html`:
`MainActivity` 判 `UiModeManager.currentModeType`,是电视就给 WebView 的 UA 加一个
` LinPlayerTV` 标,shim 据此 `location.replace()` 到 `index-tv.html` 或 `index-mobile.html`。

★ **不出第二个 APK。** `applicationId` 是 `xyz.linplayer.app` 且被 `build.yml` 硬校验 ——
换包名等于老用户收不到覆盖升级。两个包名还要多一套签名、多一条 CI、多一个装错的机会,
而省下的只是几百 KB 的前端 bundle(APK 体积的大头是 libmpv)。

★ UA 标必须在 `onWebViewCreate` 里打,不能放进那个 `post{}` —— 那时 shim 已经跑完了,
表现是电视上永远进手机 UI,而且不报错。

## 怎么出包

```bash
bash scripts/build-android-apk.sh            # release APK
bash scripts/build-android-apk.sh --debug    # debug APK
LP_ANDROID_PKG=linplayer-android bash scripts/build-android.sh   # 只验交叉编译,不打包
```

产物:`gen/android/app/build/outputs/apk/universal/release/app-universal-release-unsigned.apk`

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
     的 `full-armeabi-v7a.jar` 拉进 `jniLibs/`(gitignore)。选 full 是为了 PGS 图形字幕。
     ★ **TV 包是 32 位(armeabi-v7a)**:机顶盒里 32 位用户空间仍是主流,而 32 位包
     在 64 位设备上也能跑(反过来不行)。arm64 留给将来的安卓移动端。
     换 ABI 要**四处一起改**:CI 的 jar/DEST、`--target`、rust targets、产物文件名,
     以及 scripts/build-android-apk.sh。漏一处 = APK 里的 .so 和代码不是同一个 ABI,
     构建绿、装得上、一播放就 UnsatisfiedLinkError。
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
