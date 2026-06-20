import SwiftUI
import AVKit

/// 播放内核（对齐桌面/移动端的多内核思路）
/// - av:  系统 AVPlayer（零依赖、包体小；仅支持 mp4/mov/m4v/HLS，放不了 mkv）
/// - mdk: MDK 内核（广格式 + VideoToolbox 硬解；不支持 Anime4K）
/// - mpv: libmpv 内核（全格式 + Anime4K 超分，唯一能跑 Anime4K 的内核）
/// MDK/MPV 接入步骤见 apple_tv/PLAYER_KERNELS.md
enum PlaybackKernel: String, CaseIterable, Identifiable {
    case av, mdk, mpv
    var id: String { rawValue }
    var title: String {
        switch self {
        case .av: return "系统播放器 (AVPlayer)"
        case .mdk: return "MDK (广兼容/硬解)"
        case .mpv: return "MPV (Anime4K 超分)"
        }
    }
}

struct PlayerView: View {
    let item: MediaItem
    let apiClient: EmbyApiClient

    @AppStorage(SettingsKey.playbackKernel) private var kernelRaw = PlaybackKernel.av.rawValue
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playerVM: PlayerViewModel
    @State private var fallbackToAV = false

    init(item: MediaItem, apiClient: EmbyApiClient) {
        self.item = item
        self.apiClient = apiClient
        _playerVM = StateObject(wrappedValue: PlayerViewModel(item: item, apiClient: apiClient))
    }

    private var kernel: PlaybackKernel {
        if fallbackToAV { return .av }
        return PlaybackKernel(rawValue: kernelRaw) ?? .av
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch kernel {
            case .av:
                avPlayerBody
            case .mdk, .mpv:
                NativeKernelHost(
                    kind: kernel,
                    item: item,
                    apiClient: apiClient,
                    onUseSystemPlayer: { fallbackToAV = true },
                    onClose: { dismiss() }
                )
            }
        }
        .onChange(of: playerVM.shouldDismiss) { _, finished in
            if finished { dismiss() }
        }
    }

    @ViewBuilder
    private var avPlayerBody: some View {
        Group {
            if let player = playerVM.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if playerVM.isLoading {
                ProgressView("正在加载...")
                    .tint(AppTheme.brandColor)
                    .foregroundColor(.white)
            } else if let error = playerVM.errorMessage {
                VStack(spacing: AppTheme.Spacing.lg) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundColor(AppTheme.brandColor)
                    Text(error)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    Button("返回") { dismiss() }
                        .brandButton()
                        .buttonStyle(.plain)
                }
            }
        }
        .onAppear { playerVM.setup() }
        .onDisappear { playerVM.cleanup() }
    }
}

// MARK: - 原生内核宿主（MDK / MPV 接入点）
//
// 这里是多内核的「接缝」。在 Xcode 中按 apple_tv/PLAYER_KERNELS.md 添加
// swift-mdk / libmpv 依赖后，把下面的占位视图替换为各自的 Metal 渲染
// UIViewRepresentable（MDKKernelView / MPVKernelView）即可。
// MDK/MPV 都能直接解码 mkv 等容器，因此可继续使用 EmbyApiClient 生成的
// 直连 stream URL，无需服务端转码。

struct NativeKernelHost: View {
    let kind: PlaybackKernel
    let item: MediaItem
    let apiClient: EmbyApiClient
    var onUseSystemPlayer: () -> Void
    var onClose: () -> Void

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .mdk: mdkContent
        case .mpv: mpvContent
        case .av: placeholder // 不会走到（.av 由 PlayerView 直接处理）
        }
    }

    @ViewBuilder
    private var mdkContent: some View {
        #if canImport(swift_mdk)
        if let url = streamURL {
            MDKKernelView(
                url: url,
                startPositionTicks: item.userData?.playbackPositionTicks ?? 0
            )
            .ignoresSafeArea()
        } else {
            placeholder
        }
        #else
        placeholder
        #endif
    }

    @ViewBuilder
    private var mpvContent: some View {
        #if canImport(MPVKit)
        if let url = streamURL {
            MPVKernelView(
                url: url,
                startPositionTicks: item.userData?.playbackPositionTicks ?? 0,
                anime4k: UserDefaults.standard.bool(forKey: SettingsKey.anime4kEnabled)
            )
            .ignoresSafeArea()
        } else {
            placeholder
        }
        #else
        placeholder
        #endif
    }

    /// 直连流（MDK/MPV 可直接解码 mkv，无需服务端转码）
    private var streamURL: URL? {
        apiClient.getVideoStreamURL(itemId: item.id)
    }

    private var placeholder: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Image(systemName: "cpu")
                .font(.system(size: 72))
                .foregroundColor(AppTheme.brandColor)

            Text("\(kind.title) 内核尚未接入")
                .font(.system(size: AppTheme.FontSize.title3, weight: .bold))
                .foregroundColor(.white)

            Text("请在 Xcode 中按 apple_tv/PLAYER_KERNELS.md 添加依赖并接入渲染视图。\n接入后可直接解码 mkv 等格式，无需服务端转码。")
                .font(.system(size: AppTheme.FontSize.caption))
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1000)

            HStack(spacing: AppTheme.Spacing.lg) {
                Button(action: onUseSystemPlayer) {
                    Text("改用系统播放器播放").brandButton()
                }
                .buttonStyle(.plain)

                Button("返回") { onClose() }
                    .font(.system(size: AppTheme.FontSize.body))
                    .foregroundColor(AppTheme.textSecondary)
                    .buttonStyle(.plain)
            }
            .padding(.top, AppTheme.Spacing.md)
        }
        .padding(AppTheme.Spacing.xxl)
    }
}

// MARK: - MDK 内核渲染宿主
//
// 仅在 Xcode 中添加 swift-mdk(SPM)依赖后参与编译；未添加时整段被 canImport 排除，
// App 仍可正常编译运行(走占位 + AVPlayer 回退)。
// 基于 swift-mdk 真实 API：media / videoDecoders / prepare(from:) / state /
// setRenderAPI / setVideoSurfaceSize / renderVideo。MDK 负责广兼容 + 硬解，
// 不支持 Anime4K(Anime4K 见 MPV 内核)。

#if canImport(swift_mdk)
import MetalKit
import swift_mdk

struct MDKKernelView: UIViewRepresentable {
    let url: URL
    let startPositionTicks: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, startPositionTicks: startPositionTicks)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private let player = Player()
        private var renderBound = false

        init(url: URL, startPositionTicks: Int) {
            super.init()
            player.videoDecoders = ["VT", "FFmpeg"]                 // VideoToolbox 硬解，失败回退软解
            player.media = url.absoluteString
            player.prepare(from: Int64(Double(startPositionTicks) / 10_000.0), complete: nil) // ticks(100ns)->ms
            player.state = .Playing
        }

        func stop() { player.state = .Stopped }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            bindRenderAPIIfNeeded(view)
            player.setVideoSurfaceSize(size.width, size.height)
        }

        func draw(in view: MTKView) {
            bindRenderAPIIfNeeded(view)
            _ = player.renderVideo()
        }

        /// 把 MTKView 的 CAMetalLayer 绑定为 MDK 的 Metal 渲染目标。
        /// ⚠️ mdkMetalRenderAPI 的字段名以 mdk/c/RenderAPI.h 为准，若编译报错按头文件微调。
        private func bindRenderAPIIfNeeded(_ view: MTKView) {
            guard !renderBound,
                  let device = view.device,
                  let layer = view.layer as? CAMetalLayer else { return }
            renderBound = true
            var ra = mdkMetalRenderAPI()
            ra.type = MDK_RenderAPI_Metal
            ra.device = Unmanaged.passUnretained(device).toOpaque()
            ra.layer = Unmanaged.passUnretained(layer).toOpaque()
            withUnsafePointer(to: &ra) { player.setRenderAPI($0) }
        }
    }
}
#endif

// MARK: - MPV 内核渲染宿主（MPVKit / libmpv）
//
// 仅在 Xcode 中添加 MPVKit(SPM)依赖后参与编译；未加依赖时整段被排除。
// 采用 libmpv 经典的 OpenGL ES render API 嵌入(GLKViewController)。
// Anime4K = libmpv 原生 glsl-shaders(MDK 没有，这里才有)。
//
// ⚠️ 在 Mac 上需核对：①模块名(若 mpv_* C 符号不可见，追加 `import LibMPV`)；
// ②mpv_opengl_init_params 字段数(新版 libmpv 为 2 个字段)；
// ③若 MPVKit 自带 SwiftUI/Metal 播放视图，优先用它替换本实现。

#if canImport(MPVKit)
import GLKit
import MPVKit

struct MPVKernelView: UIViewControllerRepresentable {
    let url: URL
    let startPositionTicks: Int
    let anime4k: Bool

    func makeUIViewController(context: Context) -> MPVGLViewController {
        MPVGLViewController(url: url, startPositionTicks: startPositionTicks, anime4k: anime4k)
    }

    func updateUIViewController(_ uiViewController: MPVGLViewController, context: Context) {}
}

final class MPVGLViewController: GLKViewController, GLKViewDelegate {
    private var mpv: OpaquePointer?
    private var mpvGL: OpaquePointer?
    private let url: URL
    private let startTicks: Int
    private let anime4k: Bool
    private var glContext: EAGLContext?

    init(url: URL, startPositionTicks: Int, anime4k: Bool) {
        self.url = url
        self.startTicks = startPositionTicks
        self.anime4k = anime4k
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let ctx = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2) else { return }
        glContext = ctx
        EAGLContext.setCurrent(ctx)

        let glkView = GLKView(frame: view.bounds, context: ctx)
        glkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glkView.delegate = self
        self.view = glkView
        preferredFramesPerSecond = 60

        setupMPV()
    }

    private func setupMPV() {
        mpv = mpv_create()
        guard let mpv else { return }
        mpv_set_option_string(mpv, "vo", "libmpv")
        mpv_set_option_string(mpv, "hwdec", "videotoolbox")
        mpv_set_option_string(mpv, "gpu-api", "opengl")
        if startTicks > 0 {
            let seconds = Double(startTicks) / 10_000_000.0
            mpv_set_option_string(mpv, "start", String(format: "+%.3f", seconds))
        }
        mpv_initialize(mpv)

        // Anime4K(仅 mpv 支持)
        if anime4k, let shader = Bundle.main.path(forResource: "Anime4K_Upscale_CNN_x2_M", ofType: "glsl") {
            mpv_set_property_string(mpv, "glsl-shaders", shader)
            mpv_set_property_string(mpv, "scale", "ewa_lanczos")
        }

        // OpenGL render context
        let apiType = UnsafeMutableRawPointer(mutating: ("opengl" as NSString).utf8String)
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
            },
            get_proc_address_ctx: nil
        )
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: &initParams),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        mpv_render_context_create(&mpvGL, mpv, &params)
        mpv_render_context_set_update_callback(mpvGL, { ctx in
            guard let ctx else { return }
            let vc = Unmanaged<MPVGLViewController>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { (vc.view as? GLKView)?.setNeedsDisplay() }
        }, Unmanaged.passUnretained(self).toOpaque())

        var cmd = [strdup("loadfile"), strdup(url.absoluteString), UnsafeMutablePointer<CChar>(nil)]
        mpv_command(mpv, &cmd)
        cmd.forEach { if let p = $0 { free(p) } }
    }

    func glkView(_ view: GLKView, drawIn rect: CGRect) {
        guard let mpvGL else { return }
        var fboInt: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fboInt)
        var fbo = mpv_opengl_fbo(fbo: Int32(fboInt),
                                 w: Int32(view.drawableWidth),
                                 h: Int32(view.drawableHeight),
                                 internal_format: 0)
        var flipY: CInt = 1
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: &fbo),
            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: &flipY),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        mpv_render_context_render(mpvGL, &params)
    }

    deinit {
        if let mpvGL { mpv_render_context_free(mpvGL) }
        if let mpv { mpv_terminate_destroy(mpv) }
    }
}
#endif

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var currentItem: MediaItem
    @Published var player: AVPlayer?
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var shouldDismiss = false

    let apiClient: EmbyApiClient

    private var progressTimer: Timer?
    private var endObserver: NSObjectProtocol?
    private var mediaSourceId: String?

    // 播放偏好（与 SettingsView 共享）
    private var autoPlayNext: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.autoPlayNext) as? Bool ?? true
    }
    private var resumePlayback: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.resumePlayback) as? Bool ?? true
    }
    private var defaultSpeed: Float {
        let v = UserDefaults.standard.double(forKey: SettingsKey.defaultPlaybackSpeed)
        return v == 0 ? 1.0 : Float(v)
    }

    init(item: MediaItem, apiClient: EmbyApiClient) {
        self.currentItem = item
        self.apiClient = apiClient
    }

    func setup() {
        Task { await load(item: currentItem, allowResume: true) }
    }

    func cleanup() {
        teardownCurrent(reportStopped: true)
        player?.pause()
        player = nil
    }

    // MARK: - Loading

    private func load(item: MediaItem, allowResume: Bool) async {
        // 切换剧集前清理上一个的观测/上报
        teardownCurrent(reportStopped: true)

        isLoading = true
        errorMessage = nil
        currentItem = item

        do {
            let info = try await apiClient.getPlaybackInfo(itemId: item.id)
            guard let source = info.mediaSources.first else {
                errorMessage = "没有可用的媒体源"
                isLoading = false
                return
            }

            mediaSourceId = source.id
            guard let url = apiClient.getVideoStreamURL(
                itemId: item.id,
                mediaSourceId: source.id,
                container: source.container
            ) else {
                errorMessage = "无法生成播放链接"
                isLoading = false
                return
            }

            let avPlayer = player ?? AVPlayer()
            avPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))

            if allowResume, resumePlayback,
               let positionTicks = item.userData?.playbackPositionTicks, positionTicks > 0 {
                let seconds = Double(positionTicks) / 10_000_000.0
                await avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 1))
            }

            self.player = avPlayer
            self.isLoading = false
            avPlayer.rate = defaultSpeed

            observeEnd(for: avPlayer)
            try? await apiClient.reportPlaybackStart(itemId: item.id, mediaSourceId: source.id)
            startProgressReporting()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func observeEnd(for avPlayer: AVPlayer) {
        guard let currentPlayerItem = avPlayer.currentItem else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: currentPlayerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handlePlaybackEnded()
            }
        }
    }

    private func handlePlaybackEnded() async {
        if autoPlayNext, currentItem.isEpisode, let next = await fetchNextEpisode() {
            await load(item: next, allowResume: false)
        } else {
            shouldDismiss = true
        }
    }

    /// 同一季内查找下一集
    private func fetchNextEpisode() async -> MediaItem? {
        guard let seriesId = currentItem.seriesId,
              let currentIndex = currentItem.indexNumber else { return nil }
        let seasonId = currentItem.seasonId
        guard let episodes = try? await apiClient.getEpisodes(seriesId: seriesId, seasonId: seasonId) else {
            return nil
        }
        guard let next = episodes.first(where: { ($0.indexNumber ?? -1) == currentIndex + 1 }) else {
            return nil
        }
        return MediaItem.fromEpisode(next, seriesName: currentItem.seriesName)
    }

    // MARK: - Progress reporting

    private func startProgressReporting() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.reportProgress()
            }
        }
    }

    private func reportProgress() async {
        guard let player, let msid = mediaSourceId else { return }
        let ticks = Int(CMTimeGetSeconds(player.currentTime()) * 10_000_000)
        guard ticks > 0 else { return }
        try? await apiClient.reportPlaybackProgress(
            itemId: currentItem.id,
            mediaSourceId: msid,
            positionTicks: ticks,
            isPaused: player.rate == 0
        )
    }

    /// 清理当前剧集的计时器/观测，并上报停止位置
    private func teardownCurrent(reportStopped: Bool) {
        progressTimer?.invalidate()
        progressTimer = nil

        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }

        if reportStopped, let player, let msid = mediaSourceId {
            let ticks = Int(CMTimeGetSeconds(player.currentTime()) * 10_000_000)
            let itemId = currentItem.id
            Task {
                try? await apiClient.reportPlaybackStopped(
                    itemId: itemId, mediaSourceId: msid, positionTicks: ticks)
            }
        }
    }
}
