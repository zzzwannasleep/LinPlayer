import SwiftUI

struct HomeView: View {
    let apiClient: EmbyApiClient

    @State private var resumeItems: [MediaItem] = []
    @State private var nextUpItems: [MediaItem] = []
    @State private var recommendations: [MediaItem] = []
    @State private var libraries: [MediaLibrary] = []
    @State private var latestByLibrary: [String: [MediaItem]] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedPlayItem: MediaItem?
    @State private var showPlayer = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loadingView
                } else if let error = errorMessage {
                    errorView(error)
                } else {
                    contentView
                }
            }
            .background(AppTheme.background)
            .task { await loadData() }
            .fullScreenCover(isPresented: $showPlayer) {
                if let item = selectedPlayItem {
                    PlayerView(item: item, apiClient: apiClient)
                }
            }
        }
    }

    private var contentView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                let heroItems = heroContent
                if !heroItems.isEmpty {
                    HeroBanner(
                        items: heroItems,
                        apiClient: apiClient,
                        onPlay: { item in play(item) }
                    )
                }

                let continueWatching = mergedContinueWatching
                if !continueWatching.isEmpty {
                    WideContentRow(
                        title: "继续观看",
                        items: continueWatching,
                        apiClient: apiClient,
                        destination: { item in detailDestination(for: item) }
                    )
                }

                if !libraries.isEmpty {
                    LibraryQuickAccessRow(libraries: libraries, apiClient: apiClient)
                }

                ForEach(libraries) { lib in
                    if let items = latestByLibrary[lib.id], !items.isEmpty {
                        ContentRow(
                            title: "最新 · \(lib.name)",
                            items: items,
                            apiClient: apiClient,
                            destination: { item in detailDestination(for: item) }
                        )
                    }
                }

                if !recommendations.isEmpty {
                    ContentRow(
                        title: "随机推荐",
                        items: recommendations,
                        apiClient: apiClient,
                        destination: { item in detailDestination(for: item) }
                    )
                }

                Spacer(minLength: AppTheme.Spacing.xxxl)
            }
            .padding(.top, AppTheme.Spacing.lg)
        }
    }

    private func detailDestination(for item: MediaItem) -> some View {
        DetailView(itemId: item.seriesId ?? item.id, apiClient: apiClient)
    }

    /// 播放 Hero 项：剧集需先解析到第一/下一未看集，电影/单集直接播放
    private func play(_ item: MediaItem) {
        guard item.isSeries else {
            selectedPlayItem = item
            showPlayer = true
            return
        }
        Task {
            if let seasons = try? await apiClient.getSeasons(seriesId: item.id),
               let firstSeason = seasons.first,
               let eps = try? await apiClient.getEpisodes(seriesId: item.id, seasonId: firstSeason.id),
               let target = eps.first(where: { !$0.isWatched }) ?? eps.first {
                await MainActor.run {
                    selectedPlayItem = MediaItem.fromEpisode(target, seriesName: item.name)
                    showPlayer = true
                }
            } else {
                await MainActor.run {
                    selectedPlayItem = item
                    showPlayer = true
                }
            }
        }
    }

    /// 继续观看：合并 Resume + NextUp，去重，过滤已看完，按进度排序
    private var mergedContinueWatching: [MediaItem] {
        var seen = Set<String>()
        var result: [MediaItem] = []
        for item in (resumeItems + nextUpItems) where !item.isWatched {
            if seen.insert(item.id).inserted {
                result.append(item)
            }
        }
        return result.sorted {
            ($0.userData?.playbackPositionTicks ?? 0) > ($1.userData?.playbackPositionTicks ?? 0)
        }
    }

    /// Hero：优先随机推荐（更丰富的背景图），无则回退到继续观看
    private var heroContent: [MediaItem] {
        if !recommendations.isEmpty {
            return Array(recommendations.prefix(6))
        }
        if !resumeItems.isEmpty {
            return Array(resumeItems.prefix(6))
        }
        return []
    }

    private var loadingView: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(AppTheme.brandColor)
            Text("加载中...")
                .foregroundColor(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(AppTheme.brandColor)
            Text(message)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await loadData() }
            }
            .brandButton()
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadData() async {
        isLoading = true
        errorMessage = nil

        do {
            async let resumeTask = apiClient.getResumeItems()
            async let nextUpTask = apiClient.getNextUp()
            async let recsTask = apiClient.getRandomRecommendations()
            async let libsTask = apiClient.getLibraries()

            let (resume, nextUp, recs, libs) = try await (resumeTask, nextUpTask, recsTask, libsTask)

            await MainActor.run {
                resumeItems = resume
                nextUpItems = nextUp
                recommendations = recs
                libraries = libs
            }

            for lib in libs {
                if let latest = try? await apiClient.getLatestItems(libraryId: lib.id, limit: 16) {
                    await MainActor.run {
                        latestByLibrary[lib.id] = latest
                    }
                }
            }

            await MainActor.run { isLoading = false }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

// MARK: - 媒体库快速入口（横向 16:9 卡片，点击进入媒体库浏览）

struct LibraryQuickAccessRow: View {
    let libraries: [MediaLibrary]
    let apiClient: EmbyApiClient

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("媒体库")
                .font(.system(size: AppTheme.FontSize.title3, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)
                .padding(.leading, AppTheme.Spacing.xxl)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AppTheme.Spacing.lg) {
                    ForEach(libraries) { lib in
                        NavigationLink(destination: LibraryDetailView(library: lib, apiClient: apiClient)) {
                            LibraryQuickCard(library: lib, apiClient: apiClient)
                        }
                        .buttonStyle(TVCardButtonStyle())
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.xxl)
                .padding(.vertical, AppTheme.Spacing.md)
            }
        }
    }
}

struct LibraryQuickCard: View {
    let library: MediaLibrary
    let apiClient: EmbyApiClient
    var width: CGFloat = 360
    var height: CGFloat = 200

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: apiClient.primaryImageURL(library.id, tag: library.primaryImageTag, maxWidth: 720)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Rectangle().fill(AppTheme.cardColor)
                        .overlay(
                            Image(systemName: "rectangle.stack.fill")
                                .font(.system(size: 44))
                                .foregroundColor(AppTheme.textTertiary)
                        )
                }
            }
            .frame(width: width, height: height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius))

            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius))

            Text(library.name)
                .font(.system(size: AppTheme.FontSize.caption, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(AppTheme.Spacing.md)
        }
        .frame(width: width, height: height)
    }
}
