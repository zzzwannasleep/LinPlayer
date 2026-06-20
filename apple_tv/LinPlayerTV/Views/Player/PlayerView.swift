import SwiftUI
import AVKit

struct PlayerView: View {
    let item: MediaItem
    let apiClient: EmbyApiClient

    @Environment(\.dismiss) private var dismiss
    @StateObject private var playerVM: PlayerViewModel

    init(item: MediaItem, apiClient: EmbyApiClient) {
        self.item = item
        self.apiClient = apiClient
        _playerVM = StateObject(wrappedValue: PlayerViewModel(item: item, apiClient: apiClient))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

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
                    Button("返回") { dismiss() }
                        .brandButton()
                        .buttonStyle(.plain)
                }
            }
        }
        .onAppear { playerVM.setup() }
        .onDisappear { playerVM.cleanup() }
        .onChange(of: playerVM.shouldDismiss) { _, dismissFlag in
            if dismissFlag { dismiss() }
        }
    }
}

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
