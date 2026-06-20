import SwiftUI

struct SearchView: View {
    let apiClient: EmbyApiClient

    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var history: [String] = SearchHistoryStore.load()

    var body: some View {
        NavigationStack {
            VStack(spacing: AppTheme.Spacing.xl) {
                searchField

                if isSearching {
                    Spacer()
                    ProgressView().scaleEffect(1.5).tint(AppTheme.brandColor)
                    Spacer()
                } else if !results.isEmpty {
                    resultsGrid
                } else if hasSearched {
                    emptyResults
                } else {
                    historySection
                }
            }
            .background(AppTheme.background)
        }
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundColor(AppTheme.textSecondary)

            TextField("搜索电影、剧集...", text: $query)
                .font(.system(size: AppTheme.FontSize.title3))
                .foregroundColor(.white)
                .onSubmit { performSearch(query) }

            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    hasSearched = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
        .padding(.horizontal, AppTheme.Spacing.xxl)
        .padding(.top, AppTheme.Spacing.xl)
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250), spacing: AppTheme.Spacing.xl)],
                spacing: AppTheme.Spacing.xl
            ) {
                ForEach(results) { item in
                    NavigationLink(destination: DetailView(itemId: item.seriesId ?? item.id, apiClient: apiClient)) {
                        PosterCard(item: item, apiClient: apiClient, width: 250)
                    }
                    .buttonStyle(TVCardButtonStyle())
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xxl)
        }
    }

    private var emptyResults: some View {
        VStack {
            Spacer()
            VStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 60))
                    .foregroundColor(AppTheme.textTertiary)
                Text("未找到结果")
                    .font(.system(size: AppTheme.FontSize.body))
                    .foregroundColor(AppTheme.textSecondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if history.isEmpty {
            VStack {
                Spacer()
                VStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: "tv")
                        .font(.system(size: 60))
                        .foregroundColor(AppTheme.textTertiary)
                    Text("输入关键词搜索")
                        .font(.system(size: AppTheme.FontSize.body))
                        .foregroundColor(AppTheme.textSecondary)
                }
                Spacer()
            }
        } else {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                HStack {
                    Text("搜索历史")
                        .font(.system(size: AppTheme.FontSize.title3, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button("清空") {
                        history = []
                        SearchHistoryStore.clear()
                    }
                    .font(.system(size: AppTheme.FontSize.caption))
                    .foregroundColor(AppTheme.brandColor)
                    .buttonStyle(.plain)
                }

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280), spacing: AppTheme.Spacing.md)],
                        spacing: AppTheme.Spacing.md
                    ) {
                        ForEach(history, id: \.self) { term in
                            Button {
                                query = term
                                performSearch(term)
                            } label: {
                                HStack(spacing: AppTheme.Spacing.sm) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 24))
                                        .foregroundColor(AppTheme.textSecondary)
                                    Text(term)
                                        .font(.system(size: AppTheme.FontSize.caption))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(AppTheme.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppTheme.surfaceColor)
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xxl)
            .padding(.top, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func performSearch(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        hasSearched = true
        history = SearchHistoryStore.add(trimmed)
        Task {
            do {
                let items = try await apiClient.search(query: trimmed)
                await MainActor.run {
                    results = items
                    isSearching = false
                }
            } catch {
                await MainActor.run { isSearching = false }
            }
        }
    }
}

// MARK: - 搜索历史持久化

enum SearchHistoryStore {
    private static let key = "search_history"
    private static let maxCount = 12

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    @discardableResult
    static func add(_ term: String) -> [String] {
        var list = load().filter { $0 != term }
        list.insert(term, at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        UserDefaults.standard.set(list, forKey: key)
        return list
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
