import SwiftUI

/// 媒体库网格（可独立使用；当前主入口为首页的媒体库快速入口）
struct LibraryListView: View {
    let apiClient: EmbyApiClient
    @State private var libraries: [MediaLibrary] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(AppTheme.brandColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 400), spacing: AppTheme.Spacing.xl)],
                            spacing: AppTheme.Spacing.xl
                        ) {
                            ForEach(libraries) { lib in
                                NavigationLink(destination: LibraryDetailView(library: lib, apiClient: apiClient)) {
                                    LibraryCard(library: lib, apiClient: apiClient)
                                }
                                .buttonStyle(TVCardButtonStyle())
                            }
                        }
                        .padding(AppTheme.Spacing.xxl)
                    }
                }
            }
            .background(AppTheme.background)
            .task {
                do { libraries = try await apiClient.getLibraries() } catch {}
                isLoading = false
            }
        }
    }
}

struct LibraryCard: View {
    let library: MediaLibrary
    let apiClient: EmbyApiClient

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: apiClient.primaryImageURL(library.id, tag: library.primaryImageTag, maxWidth: 800)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Rectangle().fill(AppTheme.cardColor)
                }
            }
            .frame(height: 220)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius))

            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius))

            VStack(alignment: .leading, spacing: 4) {
                Text(library.name)
                    .font(.system(size: AppTheme.FontSize.title3, weight: .bold))
                    .foregroundColor(.white)
                Text(libraryTypeLabel)
                    .font(.system(size: AppTheme.FontSize.caption))
                    .foregroundColor(AppTheme.textSecondary)
            }
            .padding(AppTheme.Spacing.lg)
        }
        .frame(height: 220)
    }

    private var libraryTypeLabel: String {
        switch library.collectionType {
        case "movies": return "电影"
        case "tvshows": return "剧集"
        case "music": return "音乐"
        case "homevideos": return "家庭视频"
        default: return "媒体"
        }
    }
}

// MARK: - 媒体库浏览（排序 + 密度，对齐安卓 TV 端）

/// 排序选项
private struct SortOption: Identifiable, Equatable {
    let id: String
    let label: String
    let sortBy: String
    let sortOrder: String
}

/// 网格密度（影响海报宽度）
private enum GridDensity: Int, CaseIterable {
    case sparse, medium, dense

    var minWidth: CGFloat {
        switch self {
        case .sparse: return 320
        case .medium: return 250
        case .dense: return 200
        }
    }

    var icon: String {
        switch self {
        case .sparse: return "square.grid.2x2"
        case .medium: return "square.grid.3x3"
        case .dense: return "square.grid.4x3.fill"
        }
    }
}

struct LibraryDetailView: View {
    let library: MediaLibrary
    let apiClient: EmbyApiClient

    @State private var items: [MediaItem] = []
    @State private var isLoading = true
    @State private var currentPage = 0
    @State private var hasMore = true
    private let pageSize = 60

    @State private var selectedSort: SortOption
    @State private var density: GridDensity = .medium

    private let sortOptions: [SortOption] = [
        SortOption(id: "name", label: "名称", sortBy: "SortName", sortOrder: "Ascending"),
        SortOption(id: "added", label: "最近添加", sortBy: "DateCreated", sortOrder: "Descending"),
        SortOption(id: "rating", label: "评分", sortBy: "CommunityRating", sortOrder: "Descending"),
        SortOption(id: "premiere", label: "首播日期", sortBy: "PremiereDate", sortOrder: "Descending"),
    ]

    init(library: MediaLibrary, apiClient: EmbyApiClient) {
        self.library = library
        self.apiClient = apiClient
        _selectedSort = State(initialValue: SortOption(
            id: "name", label: "名称", sortBy: "SortName", sortOrder: "Ascending"))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                header
                sortBar

                if isLoading && items.isEmpty {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(AppTheme.brandColor)
                        .frame(maxWidth: .infinity, minHeight: 400)
                } else if items.isEmpty {
                    emptyState
                } else {
                    grid
                    if isLoading {
                        ProgressView()
                            .tint(AppTheme.brandColor)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
            }
            .padding(.bottom, AppTheme.Spacing.xxl)
        }
        .background(AppTheme.background)
        .task { await loadItems(reset: true) }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(library.name)
                .font(.system(size: AppTheme.FontSize.title1, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            densityToggle
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
        .padding(.top, AppTheme.Spacing.lg)
    }

    private var densityToggle: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ForEach(GridDensity.allCases, id: \.rawValue) { d in
                Button {
                    density = d
                } label: {
                    Image(systemName: d.icon)
                        .font(.system(size: 28))
                        .foregroundColor(density == d ? .white : AppTheme.textSecondary)
                        .padding(AppTheme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                                .fill(density == d ? AppTheme.brandColor : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sortBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.md) {
                ForEach(sortOptions) { option in
                    Button {
                        guard option != selectedSort else { return }
                        selectedSort = option
                        Task { await loadItems(reset: true) }
                    } label: {
                        Text(option.label)
                            .font(.system(size: AppTheme.FontSize.caption, weight: .medium))
                            .foregroundColor(option == selectedSort ? .white : AppTheme.textSecondary)
                            .padding(.horizontal, AppTheme.Spacing.lg)
                            .padding(.vertical, AppTheme.Spacing.sm)
                            .background(
                                Capsule().fill(
                                    option == selectedSort ? AppTheme.brandColor : Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xxl)
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: density.minWidth), spacing: AppTheme.Spacing.xl)],
            spacing: AppTheme.Spacing.xl
        ) {
            ForEach(items) { item in
                NavigationLink(destination: DetailView(itemId: item.id, apiClient: apiClient)) {
                    PosterCard(item: item, apiClient: apiClient, width: density.minWidth)
                }
                .buttonStyle(TVCardButtonStyle())
                .onAppear {
                    if item.id == items.last?.id && hasMore && !isLoading {
                        Task { await loadItems(reset: false) }
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 60))
                .foregroundColor(AppTheme.textTertiary)
            Text("此媒体库暂无内容")
                .font(.system(size: AppTheme.FontSize.body))
                .foregroundColor(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    private func loadItems(reset: Bool) async {
        if reset {
            await MainActor.run {
                items = []
                currentPage = 0
                hasMore = true
            }
        }
        guard hasMore else { return }
        await MainActor.run { isLoading = true }

        do {
            let startIndex = currentPage * pageSize
            let newItems = try await apiClient.getLibraryItems(
                libraryId: library.id,
                sortBy: selectedSort.sortBy,
                sortOrder: selectedSort.sortOrder,
                startIndex: startIndex,
                limit: pageSize
            )
            await MainActor.run {
                if reset {
                    items = newItems
                } else {
                    items.append(contentsOf: newItems)
                }
                currentPage += 1
                hasMore = newItems.count >= pageSize
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}
