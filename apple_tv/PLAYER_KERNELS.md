# tvOS 多播放内核接入指南（MDK / MPV）

LinPlayer 桌面/移动端用 mpv + 原生 mpv + ExoPlayer 多内核兼顾「广格式兼容」与
「mpv Anime4K 超分」。本指南把同样的思路落到 tvOS:在系统 **AVPlayer** 之外，
接入 **MDK**(广格式 + 硬解 + mpv 风格用户着色器)与 **MPV**(libmpv，Anime4K 超分)。

> 关键收益:MDK / MPV 都能**客户端直接解码 MKV 等容器**,所以可继续使用
> `EmbyApiClient.getVideoStreamURL` 生成的直连 `stream.<container>` URL,
> **完全不依赖 Emby 服务端转码**。AVPlayer 是唯一需要兼容容器(mp4/mov/m4v/HLS)的内核。

---

## 0. 代码里的「接缝」已经就位

无需改架构,接入点都已留好:

| 位置 | 作用 |
|------|------|
| `PlaybackKernel`(`Views/Player/PlayerView.swift`) | 内核枚举 `av` / `mdk` / `mpv` |
| `NativeKernelHost`(同文件) | MDK/MPV 的宿主视图——**把占位视图替换成 Metal 渲染视图即可** |
| `SettingsKey.playbackKernel` / `.anime4kEnabled`(`Settings/SettingsView.swift`) | 设置页内核选择 + Anime4K 开关(已接 UI) |

用户在「设置 → 播放 → 播放内核」选择内核;选了 MDK/MPV 当前会显示「尚未接入」占位
并可一键回退系统播放器。你要做的就是把 `NativeKernelHost` 里的占位换成真实渲染视图。

---

## 1. 接入 MDK(推荐先做,投入产出比最高)

MDK 官方支持 tvOS(xcframework),且有官方 Swift 绑定 `swift-mdk`,走 SPM 最省事。
- SDK: https://github.com/wang-bin/mdk-sdk (tvOS 支持见 Wiki / Issue #294)
- Swift 绑定: https://github.com/wang-bin/swift-mdk

### 1.1 添加依赖(在 Mac 的 Xcode 里)
1. 打开 `apple_tv/LinPlayerTV.xcodeproj`。
2. File → Add Package Dependencies… → 输入 `https://github.com/wang-bin/swift-mdk` → Add 到 `LinPlayerTV` target。
3. 若遇到 Xcode 15+ 的 `sandbox rsync` 报错(swift-mdk README 已注明):
   Build Settings 把 `ENABLE_USER_SCRIPT_SANDBOXING = NO`。
4. CI 无需改动:`build.yml` 的 `build-tvos` 已含
   `xcodebuild -resolvePackageDependencies`,会自动拉取 SPM 依赖。

### 1.2 Metal 渲染宿主(骨架,需在 Mac 上按 swift-mdk 实际 API 校准)

> 下面是**起步骨架**,方法名需对照 `swift-mdk` 源码/示例核对后再编译。
> MDK 通过 Metal 的 `CAMetalLayer` 输出,核心调用:`setMedia` → 设置 render API(Metal)
> → `setVideoSurfaceSize` → 在 MTKView 的 draw 回调里 `renderVideo` → `set(state: .playing)`。

```swift
import SwiftUI
import MetalKit
import swift_mdk   // 模块名以 swift-mdk 实际为准

struct MDKKernelView: UIViewRepresentable {
    let url: URL
    let startPositionTicks: Int
    let anime4k: Bool

    func makeCoordinator() -> Coordinator { Coordinator(url: url,
                                                         startPositionTicks: startPositionTicks,
                                                         anime4k: anime4k) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.framebufferOnly = false
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        private let player = Player()           // mdk Player
        private let url: URL
        private let startPositionTicks: Int

        init(url: URL, startPositionTicks: Int, anime4k: Bool) {
            self.url = url
            self.startPositionTicks = startPositionTicks
            super.init()
            // 硬解(VideoToolbox);失败自动回退软解
            player.setDecoders(.video, ["VT", "FFmpeg"])
            // Anime4K:加载 mpv 风格 .glsl 用户着色器(见 §3)
            if anime4k, let shader = Bundle.main.path(forResource: "Anime4K_Upscale", ofType: "glsl") {
                // 属性名以 MDK 头文件/Wiki 为准,通常是用户着色器列表
                player.setProperty("video.opengl.shaders", shader)
            }
            player.setMedia(url.absoluteString)
            if startPositionTicks > 0 {
                player.seek(Double(startPositionTicks) / 10_000_000.0)
            }
            player.prepare()
        }

        func attach(to view: MTKView) {
            // 把 MTKView 的 CAMetalLayer 交给 MDK 作为 Metal 渲染目标
            player.setRenderAPI(MetalRenderAPI(layer: view.layer))   // 名称以 swift-mdk 为准
            player.set(state: .playing)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            player.setVideoSurfaceSize(Int(size.width), Int(size.height))
        }

        func draw(in view: MTKView) {
            player.renderVideo()
        }
    }
}
```

### 1.3 接到宿主里
把 `NativeKernelHost.body` 中 `kind == .mdk` 分支的占位替换为:

```swift
if let url = apiClient.getVideoStreamURL(itemId: item.id,
                                         mediaSourceId: item.id,
                                         container: nil) {
    MDKKernelView(url: url,
                  startPositionTicks: item.userData?.playbackPositionTicks ?? 0,
                  anime4k: UserDefaults.standard.bool(forKey: SettingsKey.anime4kEnabled))
        .ignoresSafeArea()
}
```

进度上报/自动下一集可复用 `PlayerViewModel` 的上报方法(把它抽成与内核无关的协作者)。

---

## 2. 接入 MPV(libmpv,纯 Anime4K 体验)

libmpv 没有现成 tvOS 包,需要自行交叉编译 `mpv + ffmpeg` 为 `appletvos`/`appletvsimulator`
的 xcframework,再以 SPM `binaryTarget` 或手动 framework 方式接入。工程量大于 MDK。

- 参考构建:mpv 官方 + ffmpeg 的 Apple 交叉编译脚本(社区有 `mpv-build` / `kodi` 风格脚本)。
- 渲染:libmpv render API,tvOS 用 Metal(`MPV_RENDER_API_TYPE_SW` 仅兜底)。
- 控制:`mpv_command`/`mpv_set_property` 设置 `hwdec=videotoolbox`、`vo=gpu-next`。
- Anime4K:`mpv_set_property_string("glsl-shaders", "<Anime4K .glsl 路径>")`,
  配合 `scale=ewa_lanczos`、`cscale=...`。这是 mpv 超分的「正版」做法。

宿主同样是一个 `MTKView` 的 `UIViewRepresentable`,替换 `NativeKernelHost` 的 `.mpv` 分支。

> 说明:MDK 本身也支持 mpv 风格用户着色器,**多数情况下只接 MDK 就能同时拿到广兼容 + Anime4K**;
> 是否再单独接 libmpv 取决于你对 mpv 渲染管线(gpu-next/着色器链)的依赖程度。

---

## 3. Anime4K 着色器资源

1. 从 https://github.com/bloc97/Anime4K 取 GLSL 预设(如 `Anime4K_Upscale_CNN_x2_M.glsl`)。
2. 放进 `LinPlayerTV/`(会随 `Assets`/资源进包;若用文件夹引用,确保加入 target 的 Copy Bundle Resources)。
3. MDK 用 `setProperty(<用户着色器键>, 路径)`;mpv 用 `glsl-shaders`。
4. Apple TV **4K(2nd/3rd gen)** 才有足够 GPU 跑超分;旧款 Apple TV HD 会卡,建议运行时按机型/分辨率降级或关掉。

---

## 4. build.yml 注意事项

- `build-tvos` 已经 `-resolvePackageDependencies` + `xcodebuild build`,**加 SPM 依赖后 CI 自动生效**,无需改 job。
- 若加了 `ENABLE_USER_SCRIPT_SANDBOXING = NO`,提交工程设置即可(已在 pbxproj 里)。
- 包体:接入 MDK/MPV 后,`.ipa` 会从几百 KB 涨到几十 MB(内含 xcframework),属正常。
- 仍是**未签名** `.ipa`,分发需签名走 TestFlight/App Store。

---

## 5. 验证清单(必须在 Mac + Apple TV 4K 上)

- [ ] 选 MDK,播放一个 **MKV(H.264/HEVC + AAC/AC3)**,确认直连可播、服务端无转码。
- [ ] 选 MDK,开 Anime4K,确认画面超分生效且帧率稳定。
- [ ] 选 MPV(若接入),同上验证 `glsl-shaders` 生效。
- [ ] 续播定位、进度上报、自动下一集在新内核下仍正常。
- [ ] AVPlayer 回退按钮可用;旧机型降级策略生效。

---

## 现状

- 内核「接缝」、设置 UI、AVPlayer 路径、`.ipa` 打包均已就绪并可编译运行。
- MDK/MPV 的实际渲染视图需在 Mac 的 Xcode 中按本指南完成并验证(本机为 Windows,
  无法拉取/编译这两个二进制内核,也无法在 Apple TV 上验证超分)。
