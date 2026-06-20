# tvOS 多播放内核接入指南（MDK / MPV）

LinPlayer 桌面/移动端用 mpv + 原生 mpv + ExoPlayer 多内核兼顾「广格式兼容」与
「mpv Anime4K 超分」。tvOS 同样思路,在系统 **AVPlayer** 之外接入两个内核:

| 内核 | 职责 | Anime4K |
|------|------|:---:|
| **AVPlayer**(系统) | 零依赖、包体小;**仅** mp4/mov/m4v/HLS,放不了 mkv | ❌ |
| **MDK** | 广格式兼容 + VideoToolbox 硬解 + HDR | ❌(MDK 不支持用户着色器) |
| **MPV**(libmpv) | 全格式 + **Anime4K 超分**(唯一能跑 Anime4K 的) | ✅ |

> **重要更正**:MDK 官方特性列表里**没有** mpv 风格用户着色器 / Anime4K / 超分,
> 它的 shader 只用于内部色彩/HDR 渲染。**Anime4K 只能靠 MPV(libmpv)的 `glsl-shaders`**。
> 所以两内核分工:MDK 保兼容、MPV 吃 Anime4K。

> 关键收益:MDK / MPV 都能**客户端直接解码 MKV 等容器**,继续用
> `EmbyApiClient.getVideoStreamURL` 的直连 URL,**完全不依赖 Emby 服务端转码**。

---

## 0. 代码里的「接缝」已经就位

| 位置 | 状态 |
|------|------|
| `PlaybackKernel`(`Views/Player/PlayerView.swift`) | 内核枚举 `av`/`mdk`/`mpv` ✅ |
| `NativeKernelHost`(同文件) | MDK/MPV 宿主;`.mdk` 已接 `MDKKernelView`(canImport 门控) ✅ |
| `MDKKernelView`(同文件,`#if canImport(swift_mdk)`) | **MDK 渲染宿主已写好**,加依赖即编译 ✅ |
| `SettingsKey.playbackKernel` / `.anime4kEnabled` | 设置页内核选择 + Anime4K 开关(仅 MPV 显示) ✅ |

未加 swift-mdk 依赖时,`MDKKernelView` 被 `canImport` 排除,App 照常编译运行
(选 MDK/MPV 显示占位 + 一键回退 AVPlayer)。加依赖后 `.mdk` 自动启用。

---

## 1. 接入 MDK（推荐先做，渲染宿主已写好）

MDK 官方支持 tvOS(xcframework),且有官方 Swift 绑定 `swift-mdk`,走 SPM 最省事。
- SDK: https://github.com/wang-bin/mdk-sdk (tvOS 见 Wiki / Issue #294)
- Swift 绑定: https://github.com/wang-bin/swift-mdk

### 1.1 添加依赖（Mac 的 Xcode 里）
1. 打开 `apple_tv/LinPlayerTV.xcodeproj`。
2. File → Add Package Dependencies… → `https://github.com/wang-bin/swift-mdk` → 加到 `LinPlayerTV` target。
3. 若遇 Xcode 15+ 的 `sandbox rsync` 报错(swift-mdk README 注明):
   Build Settings 设 `ENABLE_USER_SCRIPT_SANDBOXING = NO`。
4. CI 无需改:`build.yml` 的 `build-tvos` 已含 `xcodebuild -resolvePackageDependencies`。

### 1.2 渲染宿主：已在 `PlayerView.swift` 写好

`MDKKernelView`(`#if canImport(swift_mdk)`)基于 swift-mdk 真实 API 实现:

- `player.videoDecoders = ["VT", "FFmpeg"]` — VideoToolbox 硬解,失败回退软解
- `player.media = url` + `player.prepare(from: ms)` — 设源 + 续播(ticks/10000 → ms)
- `player.state = .Playing / .Stopped`
- `MTKView` + `MTKViewDelegate`:`setVideoSurfaceSize` / `renderVideo()`
- `setRenderAPI(_:)` 绑定 `CAMetalLayer`

**唯一需在 Mac 上确认的一处**:`mdkMetalRenderAPI` 的字段名(`type` / `device` / `layer`)。
对照 SDK 头文件 `mdk/c/RenderAPI.h`;若该版本用 `currentRenderTarget` 回调而非 `layer`
字段,改成回调返回 `view.currentDrawable?.texture` 即可。其余逻辑无需改。

加完依赖后,选「设置 → 播放 → 播放内核 → MDK」即走 MDK 解码,可直接放 mkv。

---

## 2. 接入 MPV（libmpv，Anime4K 来源）

libmpv 没有现成 tvOS 包,需自行交叉编译 `mpv + ffmpeg` 为 `appletvos`/`appletvsimulator`
的 xcframework,再以 SPM `binaryTarget` 或手动 framework 接入。工程量大于 MDK。

- 构建:mpv + ffmpeg 的 Apple 交叉编译脚本(社区 `mpv-build` / kodi 风格)。
- 渲染:libmpv render API,tvOS 用 Metal(`vo=gpu-next`);`hwdec=videotoolbox`。
- 续播/控制:`mpv_set_property`/`mpv_command`。
- **Anime4K(关键)**:
  ```c
  mpv_set_property_string(mpv, "glsl-shaders", "<Anime4K_Upscale_CNN_x2_M.glsl 路径>");
  mpv_set_property_string(mpv, "scale", "ewa_lanczos");
  ```
  开关对应 `SettingsKey.anime4kEnabled`。

宿主同样是一个 `MTKView` 的 `UIViewRepresentable`,替换 `NativeKernelHost` 的 `.mpv` 分支
(可仿照 `MDKKernelView` 的结构,放在 `#if canImport(<你的 mpv 模块名>)` 下)。

---

## 3. Anime4K 着色器资源（仅 MPV）

1. 从 https://github.com/bloc97/Anime4K 取 GLSL 预设(如 `Anime4K_Upscale_CNN_x2_M.glsl`)。
2. 加入 target 的 Copy Bundle Resources,运行时用 `Bundle.main.path(forResource:ofType:)` 取路径。
3. 喂给 mpv 的 `glsl-shaders`。**MDK 不认这个格式,别往 MDK 上接。**
4. Apple TV **4K(2nd/3rd gen)** 才有足够 GPU 跑超分;Apple TV HD 会卡,
   建议按机型/分辨率降级或关闭。

---

## 4. build.yml 注意事项

- `build-tvos` 已 `-resolvePackageDependencies` + `xcodebuild build`,**加 SPM 依赖后 CI 自动生效**。
- 若改了 `ENABLE_USER_SCRIPT_SANDBOXING = NO`,提交工程设置即可。
- 包体:接入 MDK/MPV 后 `.ipa` 从几百 KB 涨到几十 MB(含 xcframework),正常。
- 仍是**未签名** `.ipa`,分发需签名走 TestFlight/App Store。

---

## 5. 验证清单（必须 Mac + Apple TV 4K）

- [ ] 选 MDK,放 **MKV(H.264/HEVC + AAC/AC3)**,确认直连可播、服务端无转码。
- [ ] 确认 `mdkMetalRenderAPI` 字段与头文件一致,画面正常输出。
- [ ] 选 MPV(若接入),开 Anime4K,确认 `glsl-shaders` 生效且帧率稳定。
- [ ] 续播定位、进度上报、自动下一集在新内核下正常(可把 `PlayerViewModel` 的上报逻辑抽成内核无关协作者复用)。
- [ ] AVPlayer 回退可用;旧机型降级生效。

---

## 现状

- 内核接缝、设置 UI、AVPlayer 路径、**MDK 渲染宿主(canImport 门控)**、`.ipa` 打包 —— 均已就绪并可编译运行。
- MDK:Mac 上加 `swift-mdk` 依赖 + 确认一处 `mdkMetalRenderAPI` 字段即可启用。
- MPV:需自行编译 libmpv for tvOS 并仿照接入(Anime4K 在此)。
- 本机为 Windows,无法拉取/编译这两个二进制内核,也无法在 Apple TV 上验证超分,故以上需在 Mac+Xcode 完成验证。
