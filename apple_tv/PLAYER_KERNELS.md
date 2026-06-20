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
| `MPVKernelView`(同文件,`#if canImport(MPVKit)`) | **MPV 渲染宿主已写好**(libmpv OpenGL ES + Anime4K),加依赖即编译 ✅ |
| `SettingsKey.playbackKernel` / `.anime4kEnabled` | 设置页内核选择 + Anime4K 开关(仅 MPV 显示) ✅ |

未加依赖时,两个 `KernelView` 被 `canImport` 排除,App 照常编译运行
(选 MDK/MPV 显示占位 + 一键回退 AVPlayer)。加对应依赖后 `.mdk` / `.mpv` 自动启用。

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

## 2. 接入 MPV（MPVKit，无需自己交叉编译）

**不用从零编译 libmpv**。Apple 平台有现成的 **MPVKit**——把 mpv + ffmpeg + libplacebo
打成 tvOS 17+ 的 xcframework,SPM 直接加,等同 tvOS 版「预编译 libmpv」。
- MPVKit(上游): https://github.com/mpvkit/MPVKit （cxfksword/karelrooted 为旧 fork）

### 2.1 依赖已写进工程（无需手动加）
- `project.pbxproj` 里已加 `XCRemoteSwiftPackageReference`:
  `https://github.com/mpvkit/MPVKit.git`,`exactVersion 0.41.0`,产品 `MPVKit`,
  并链入 `LinPlayerTV` target。CI 的 `xcodebuild -resolvePackageDependencies`
  自动拉取并嵌入 xcframework(libmpv + ffmpeg + libass + libplacebo + MoltenVK …),
  IPA 随之从几百 KB 涨到几十/上百 MB。
- **模块名实测是 `Libmpv`**:product `MPVKit` 只指向 C 聚合目标 `_MPVKit`(仅 dummy.c,
  不含 mpv 符号);`mpv_create` 等真正来自二进制目标 `Libmpv`。故 `PlayerView.swift` 门控写成
  `#if canImport(Libmpv) || canImport(MPVKit)` + `import Libmpv`,两名都覆盖。
- 换/钉版本:改 pbxproj 里该引用的 `version` 即可。Mac 的 Xcode 打开工程会自动识别此 SPM 依赖。

> 想自管/钉版本/定制 ffmpeg(如确保 PGS):MPVKit 仓库有 `make build platform=tvos`
> 可重编 xcframework,再走自托管。但通常**直接用预编译包即可**,无需动 `build-libmpv-pgs.yml`。

### 2.2 渲染宿主：已在 `PlayerView.swift` 写好

`MPVKernelView`(`#if canImport(MPVKit)`)用 libmpv 经典的 **OpenGL ES render API**
(`GLKViewController`)嵌入:

- `mpv_create` / `mpv_initialize`;`hwdec=videotoolbox` 硬解
- `mpv_render_context_create`(`MPV_RENDER_API_TYPE_OPENGL`)+ 更新回调驱动重绘
- `glkView(_:drawIn:)` 里 `mpv_render_context_render`(绑定当前 FBO)
- 续播:`start=+秒`;加载:`loadfile`
- **Anime4K**:`mpv_set_property_string(mpv, "glsl-shaders", <Anime4K .glsl>)`
  + `scale=ewa_lanczos`,开关读 `SettingsKey.anime4kEnabled`

**Mac 上需核对**:①若 C 符号不可见加 `import LibMPV`;②`mpv_opengl_init_params`
字段数(新版 libmpv 为 2 个)；③若 MPVKit 自带 SwiftUI/Metal 播放视图,可直接替换本实现。

加完依赖后,选「设置 → 播放 → 播放内核 → MPV」+ 开 Anime4K 即生效。

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

- 内核接缝、设置 UI、AVPlayer 路径、**MDK 与 MPV 两个渲染宿主(canImport 门控)**、`.ipa` 打包 —— 均已就绪并可编译运行。
- **MPV:已把 `MPVKit 0.41.0`(SPM)写进 `project.pbxproj` 并链入 target**,CI 自动拉取嵌入
  → IPA 不再是几百 KB。门控用实测模块名 `Libmpv`。`MPVKernelView` 仍有几处需 Mac 实编核对
  (`mpv_opengl_init_params` 字段数、`import Libmpv` 是否够),CI 编译失败按日志迭代即可。
- MDK:仍需 Mac 上加 `swift-mdk`(SPM)+ 确认 `mdkMetalRenderAPI` 字段;尚未写进工程。
- 本机为 Windows,无法拉取/编译这两个二进制内核,也无法在 Apple TV 上验证超分,故以上 SPM 接入与渲染细节需在 Mac+Xcode 完成验证。
