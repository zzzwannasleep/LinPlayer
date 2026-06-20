import SwiftUI

/// 侧边栏导航项（对齐安卓 TV 端：首页 / 搜索 / 服务器 / 设置）
enum SidebarTab: Int, CaseIterable, Identifiable {
    case home, search, server, settings

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .search: return "搜索"
        case .server: return "服务器"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .server: return "server.rack"
        case .settings: return "gearshape.fill"
        }
    }
}

/// 主框架：左侧边栏 + 右侧内容区。
/// 与安卓 TV 端一致——侧栏获焦时展开（图标 + 文字），内容获焦时折叠为图标。
struct MainShellView: View {
    let apiClient: EmbyApiClient

    @State private var selection: SidebarTab = .home
    @FocusState private var sidebarFocus: SidebarTab?

    /// 没有任何侧栏项获焦时（焦点在内容区）折叠侧栏
    private var collapsed: Bool { sidebarFocus == nil }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .defaultFocus($sidebarFocus, selection)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            brandHeader
                .padding(.bottom, AppTheme.Spacing.xl)

            ForEach(SidebarTab.allCases) { tab in
                sidebarButton(tab)
            }

            Spacer()
        }
        .padding(AppTheme.Spacing.lg)
        .frame(
            width: collapsed ? AppTheme.sidebarCollapsedWidth : AppTheme.sidebarWidth,
            alignment: .leading
        )
        .frame(maxHeight: .infinity)
        .background(AppTheme.surfaceColor.ignoresSafeArea())
        .focusSection()
        .animation(.easeInOut(duration: 0.22), value: collapsed)
    }

    private var brandHeader: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 44))
                .foregroundColor(AppTheme.brandColor)
            if !collapsed {
                Text("LinPlayer")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
        }
        .padding(.leading, AppTheme.Spacing.sm)
        .padding(.top, AppTheme.Spacing.md)
    }

    private func sidebarButton(_ tab: SidebarTab) -> some View {
        let isFocused = sidebarFocus == tab
        let isSelected = selection == tab

        return Button {
            selection = tab
        } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: tab.icon)
                    .font(.system(size: 32))
                    .frame(width: 48)
                if !collapsed {
                    Text(tab.title)
                        .font(.system(size: 28, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .foregroundColor(isFocused || isSelected ? .white : AppTheme.textSecondary)
            .padding(.vertical, AppTheme.Spacing.md)
            .padding(.horizontal, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .fill(
                        isFocused
                            ? AppTheme.brandColor
                            : (isSelected ? AppTheme.brandColor.opacity(0.30) : Color.clear)
                    )
            )
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($sidebarFocus, equals: tab)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        switch selection {
        case .home:
            HomeView(apiClient: apiClient)
        case .search:
            SearchView(apiClient: apiClient)
        case .server:
            ServerManagerView(apiClient: apiClient)
        case .settings:
            SettingsView(apiClient: apiClient)
        }
    }
}
