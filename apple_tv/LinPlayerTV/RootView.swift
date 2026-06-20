import SwiftUI

struct RootView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var authManager: AuthManager

    @AppStorage("onboarding_done") private var onboardingDone = false
    @State private var didRestore = false

    var body: some View {
        Group {
            if !onboardingDone {
                OnboardingView { onboardingDone = true }
            } else if authManager.isAuthenticated, let client = authManager.apiClient {
                MainShellView(apiClient: client)
                    .id(client.baseURL) // 切换服务器时重建框架，确保内容随新会话刷新
            } else if let server = serverManager.currentServer {
                LoginView(server: server)
            } else {
                ServerListView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: authManager.isAuthenticated)
        .animation(.easeInOut(duration: 0.3), value: onboardingDone)
        .task { restoreIfPossible() }
    }

    /// 启动时自动恢复已登录的会话，避免每次都要重新登录
    private func restoreIfPossible() {
        guard !didRestore else { return }
        didRestore = true
        guard !authManager.isAuthenticated,
              let server = serverManager.currentServer,
              server.isAuthenticated,
              let token = server.accessToken,
              let userId = server.userId else { return }
        authManager.restoreSession(serverURL: server.url, token: token, userId: userId)
        authManager.currentUser = EmbyUser(id: userId, name: server.name)
    }
}

// MARK: - Onboarding（对齐安卓 TV 端的三页引导）

struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var page = 0

    private struct Page {
        let icon: String
        let title: String
        let subtitle: String
    }

    private let pages: [Page] = [
        Page(icon: "hand.tap.fill",
             title: "使用遥控器导航",
             subtitle: "用方向键移动焦点，确认键选择，菜单键返回"),
        Page(icon: "sidebar.left",
             title: "左侧导航栏",
             subtitle: "在侧边栏与内容之间按左右键切换；侧栏获焦时自动展开"),
        Page(icon: "scope",
             title: "焦点指示",
             subtitle: "高亮且放大的项目即为当前焦点位置"),
    ]

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(spacing: AppTheme.Spacing.xxl) {
                Spacer()

                Image(systemName: pages[page].icon)
                    .font(.system(size: 120))
                    .foregroundColor(AppTheme.brandColor)

                Text(pages[page].title)
                    .font(.system(size: AppTheme.FontSize.title1, weight: .bold))
                    .foregroundColor(.white)

                Text(pages[page].subtitle)
                    .font(.system(size: AppTheme.FontSize.body))
                    .foregroundColor(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)

                HStack(spacing: 10) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? AppTheme.brandColor : Color.white.opacity(0.3))
                            .frame(width: i == page ? 36 : 12, height: 12)
                            .animation(.easeInOut(duration: 0.2), value: page)
                    }
                }
                .padding(.top, AppTheme.Spacing.md)

                Button(action: advance) {
                    Text(page == pages.count - 1 ? "开始使用" : "下一步")
                        .brandButton()
                }
                .buttonStyle(.plain)

                if page < pages.count - 1 {
                    Button("跳过") { onFinish() }
                        .font(.system(size: AppTheme.FontSize.caption))
                        .foregroundColor(AppTheme.textSecondary)
                        .buttonStyle(.plain)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func advance() {
        if page < pages.count - 1 {
            withAnimation { page += 1 }
        } else {
            onFinish()
        }
    }
}
