import SwiftUI

struct DetailView: View {
    let itemId: String
    let apiClient: EmbyApiClient

    @State private var item: MediaItem?
    @State private var seasons: [Season] = []
    @State private var episodes: [Episode] = []
    @State private var selectedSeason: Season?
    @State private var similarItems: [MediaItem] = []
    @State private var isLoading = true
    @State private var isFavorite = false
    @State private var showPlayer = false
    @State private var playEpisode: Episode?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(AppTheme.brandColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let item = item {
                detailContent(item)
            }
        }
        .background(AppTheme.background)
        .task { await loadDetails() }
        .fullScreenCover(isPresented: $showPlayer) {
            if let episode = playEpisode {
                PlayerView(
                    item: MediaItem.fromEpisode(episode, seriesName: item?.name),
                    apiClient: apiClient
                )
            } else if let item = item {
                PlayerView(item: item, apiClient: apiClient)
            }
        }
    }

    private func detailContent(_ item: MediaItem) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                headerSection(item)

                if item.isSeries && !seasons.isEmpty {
                    seasonsSection
                }

                if !episodes.isEmpty {
                    episodesSection
                }

                if let people = item.people, !people.isEmpty {
                    castSection(people)
                }

                if !similarItems.isEmpty {
                    ContentRow(
                        title: "相似推荐",
                        items: similarItems,
                        apiClient: apiClient,
                        destination: { DetailView(itemId: $0.id, apiClient: apiClient) }
                    )
                }

                Spacer(minLength: AppTheme.Spacing.xxxl)
            }
        }
    }

    private func headerSection(_ item: MediaItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            let backdropURL: URL? = {
                if let tag = item.backdropImageTag {
                    return apiClient.backdropImageURL(item.id, tag: tag, maxWidth: 1920)
                }
                return apiClient.primaryImageURL(item.id, tag: item.primaryImageTag, maxWidth: 1920)
            }()

            AsyncImage(url: backdropURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Rectangle().fill(AppTheme.surfaceColor)
                }
            }
            .frame(height: 650)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(
                colors: [.clear, AppTheme.background.opacity(0.5), AppTheme.background],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: AppTheme.Spacing.xl) {
                AsyncImage(url: apiClient.primaryImageURL(item.id, tag: item.primaryImageTag, maxWidth: 400)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(AppTheme.cardColor)
                    }
                }
                .frame(width: 220, height: 330)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.posterCornerRadius))

                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text(item.name)
                        .font(.system(size: AppTheme.FontSize.title1, weight: .bold))
                        .foregroundColor(.white)

                    HStack(spacing: AppTheme.Spacing.md) {
                        if let rating = item.communityRating {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .foregroundColor(AppTheme.brandColor)
                                Text(String(format: "%.1f", rating))
                            }
                        }
                        if let year = item.productionYear {
                            Text("\(year)")
                        }
                        if let runtime = item.formattedRuntime {
                            Text(runtime)
                        }
                        if let rating = item.officialRating {
                            Text(rating)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .font(.system(size: AppTheme.FontSize.body))
                    .foregroundColor(AppTheme.textSecondary)

                    if let genres = item.genres, !genres.isEmpty {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            ForEach(genres.prefix(5), id: \.self) { genre in
                                Text(genre)
                                    .font(.system(size: 22))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }

                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: AppTheme.FontSize.caption))
                            .foregroundColor(AppTheme.textSecondary)
                            .lineLimit(3)
                            .frame(maxWidth: 700, alignment: .leading)
                    }

                    HStack(spacing: AppTheme.Spacing.md) {
                        Button(action: { playPrimary(item) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                Text(primaryPlayLabel(item))
                            }
                            .brandButton()
                        }
                        .buttonStyle(.plain)

                        Button(action: { toggleFavorite() }) {
                            HStack(spacing: 8) {
                                Image(systemName: isFavorite ? "heart.fill" : "heart")
                                Text(isFavorite ? "已收藏" : "收藏")
                            }
                            .font(.system(size: AppTheme.FontSize.body, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, AppTheme.Spacing.xl)
                            .padding(.vertical, AppTheme.Spacing.md)
                            .background(Color.white.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, AppTheme.Spacing.sm)
                }
            }
            .padding(AppTheme.Spacing.xxl)
        }
    }

    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("季")
                .font(.system(size: AppTheme.FontSize.title3, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)
                .padding(.leading, AppTheme.Spacing.xxl)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.md) {
                    ForEach(seasons) { season in
                        Button(action: {
                            selectedSeason = season
                            Task { await loadEpisodes(seasonId: season.id) }
                        }) {
                            Text(season.name)
                                .font(.system(size: AppTheme.FontSize.body))
                                .foregroundColor(selectedSeason?.id == season.id ? .white : AppTheme.textSecondary)
                                .padding(.horizontal, AppTheme.Spacing.lg)
                                .padding(.vertical, AppTheme.Spacing.md)
                                .background(
                                    selectedSeason?.id == season.id
                                        ? AppTheme.brandColor
                                        : Color.white.opacity(0.1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.xxl)
            }
        }
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("剧集")
                .font(.system(size: AppTheme.FontSize.title3, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)
                .padding(.leading, AppTheme.Spacing.xxl)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AppTheme.Spacing.lg) {
                    ForEach(episodes) { episode in
                        Button(action: {
                            playEpisode = episode
                            showPlayer = true
                        }) {
                            EpisodeCard(episode: episode, apiClient: apiClient, seriesId: item?.id ?? "")
                        }
                        .buttonStyle(TVCardButtonStyle())
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.xxl)
                .padding(.vertical, AppTheme.Spacing.md)
            }
        }
    }

    private func castSection(_ people: [PersonInfo]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("演员")
                .font(.system(size: AppTheme.FontSize.title3, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)
                .padding(.leading, AppTheme.Spacing.xxl)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AppTheme.Spacing.lg) {
                    ForEach(people.filter { $0.type == "Actor" }.prefix(20)) { person in
                        VStack(spacing: AppTheme.Spacing.sm) {
                            AsyncImage(url: apiClient.primaryImageURL(person.id, tag: person.primaryImageTag, maxWidth: 200)) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().aspectRatio(contentMode: .fill)
                                default:
                                    Circle().fill(AppTheme.cardColor)
                                        .overlay(
                                            Image(systemName: "person.fill")
                                                .foregroundColor(AppTheme.textTertiary)
                                        )
                                }
                            }
                            .frame(width: 120, height: 120)
                            .clipShape(Circle())

                            Text(person.name)
                                .font(.system(size: 20))
                                .foregroundColor(AppTheme.textPrimary)
                                .lineLimit(1)

                            if let role = person.role, !role.isEmpty {
                                Text(role)
                                    .font(.system(size: 18))
                                    .foregroundColor(AppTheme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 130)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.xxl)
                .padding(.vertical, AppTheme.Spacing.md)
            }
        }
    }

    private func loadDetails() async {
        do {
            let detail = try await apiClient.getItemDetails(itemId: itemId)
            await MainActor.run {
                item = detail
                isFavorite = detail.userData?.isFavorite ?? false
            }

            if detail.isSeries {
                let s = try await apiClient.getSeasons(seriesId: itemId)
                await MainActor.run { seasons = s }
                if let firstSeason = s.first {
                    await MainActor.run { selectedSeason = firstSeason }
                    await loadEpisodes(seasonId: firstSeason.id)
                }
            }

            let similar = try await apiClient.getSimilarItems(itemId: itemId)
            await MainActor.run {
                similarItems = similar
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    private func loadEpisodes(seasonId: String) async {
        guard let seriesId = item?.id ?? item?.seriesId else { return }
        do {
            let eps = try await apiClient.getEpisodes(seriesId: seriesId, seasonId: seasonId)
            await MainActor.run { episodes = eps }
        } catch {}
    }

    /// 主播放按钮文案：剧集显示「播放/继续观看」，电影按进度显示
    private func primaryPlayLabel(_ item: MediaItem) -> String {
        if item.isSeries {
            if let target = firstUnwatchedEpisode(), target.progress ?? 0 > 0 {
                return "继续观看"
            }
            return "播放"
        }
        return (item.progress ?? 0) > 0 ? "继续观看" : "播放"
    }

    /// 剧集首选未看完的一集，否则第一集
    private func firstUnwatchedEpisode() -> Episode? {
        episodes.first(where: { !$0.isWatched }) ?? episodes.first
    }

    private func playPrimary(_ item: MediaItem) {
        if item.isSeries {
            playEpisode = firstUnwatchedEpisode()
        } else {
            playEpisode = nil
        }
        showPlayer = true
    }

    private func toggleFavorite() {
        guard let item = item else { return }
        let newState = !isFavorite
        isFavorite = newState
        Task {
            do {
                if newState {
                    try await apiClient.addFavorite(itemId: item.id)
                } else {
                    try await apiClient.removeFavorite(itemId: item.id)
                }
            } catch {
                await MainActor.run { isFavorite = !newState }
            }
        }
    }
}

struct EpisodeCard: View {
    let episode: Episode
    let apiClient: EmbyApiClient
    let seriesId: String

    private var thumbURL: URL? {
        if let tag = episode.primaryImageTag {
            return apiClient.primaryImageURL(episode.id, tag: tag, maxWidth: 480)
        }
        if let thumbId = episode.parentThumbItemId, let tag = episode.parentThumbImageTag {
            return apiClient.thumbImageURL(thumbId, tag: tag, maxWidth: 480)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(AppTheme.surfaceColor)
                            .overlay(
                                Image(systemName: "play.rectangle")
                                    .font(.system(size: 30))
                                    .foregroundColor(AppTheme.textTertiary)
                            )
                    }
                }
                .frame(width: 360, height: 200)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.posterCornerRadius))

                if let progress = episode.progress, progress > 0 {
                    ProgressBarOverlay(progress: progress)
                }

                if episode.isWatched {
                    WatchedBadge()
                }
            }

            HStack {
                if let num = episode.indexNumber {
                    Text("第 \(num) 集")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(AppTheme.brandColor)
                }
                Text(episode.name)
                    .font(.system(size: 22))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: 360, alignment: .leading)

            if let runtime = episode.formattedRuntime {
                Text(runtime)
                    .font(.system(size: 20))
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }
}
