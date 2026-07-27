# apps/ —— 各端宿主壳

壳只负责平台相关的事：窗口/生命周期、原生播放器（mpv）合成、把
`crates/core` 的能力注册成前端可调的命令。业务逻辑不写在这里。

| 目录 | 状态 | 说明 |
|------|------|------|
| `desktop/` | 在用 | Tauri 2 壳，Windows / Linux。前端取 `ui/desktop`，产物 `target/release/app.exe` |
| `android/` | 在用 | Android 壳（Tauri 2 mobile）。同一份代码出 **4 个 APK**：TV / 手机 × arm64 / arm32。TV 包打开 `index-tv.html`、手机包打开 `index-mobile.html`，**出包时定死**（2026-07-27 删掉了原先按 UA 标运行时分流的 shim：设备类型判不准，判反=用户拿到另一端的整套界面）。出 APK 见 `android/README.md` |

> ⚠️ 「播放器还是桩」这句话曾经挂在上面那一格里，**是过时的**：`android/Cargo.toml` 链的就是
> `crates/mpv`（和桌面同一份），真 libmpv + SurfaceView，`MainActivity` 里 `System.loadLibrary("mpv")`
> 那段注释写得很清楚。真正还是桩的只有 `play_local`（播放已下载到本地的文件，`src/lib.rs:172`）。
> 2026-07-26 核实。

## desktop 的几个约定

- **版本的唯一权威是 `desktop/tauri.conf.json` 的 `version`**。`build.rs` 拿它注入
  `LP_VERSION` 给 Sentry，`vite.config.ts` 拿它做 sourcemap release，
  `scripts/pack-portable.ps1` 拿它给 zip 命名。`Cargo.toml` 的 version 不参与，
  两者没有任何同步机制。
- `desktop/libmpv/libmpv-2.dll` 是 117MB 的构建输入，不入库；CI 每次现拉
  （见 `.github/workflows/build.yml`），本地需自备。
- 数据全部落在 exe 同级的 `userdata/`（绿色包），唯一出口是 `crates/core` 的 `paths.rs`。
