import SwiftUI

struct ServerListView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var authManager: AuthManager
    @State private var showAddServer = false

    var body: some View {
        NavigationStack {
            VStack(spacing: AppTheme.Spacing.xxl) {
                Spacer()

                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(AppTheme.brandColor)

                Text("LinPlayer")
                    .font(.system(size: AppTheme.FontSize.largeTitle, weight: .bold))
                    .foregroundColor(.white)

                Text("选择或添加一个 Emby 服务器")
                    .font(.system(size: AppTheme.FontSize.body))
                    .foregroundColor(AppTheme.textSecondary)

                if serverManager.servers.isEmpty {
                    Button(action: { showAddServer = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            Text("添加服务器")
                        }
                        .brandButton()
                    }
                    .buttonStyle(.plain)
                } else {
                    VStack(spacing: AppTheme.Spacing.md) {
                        ForEach(serverManager.servers, id: \.url) { server in
                            Button(action: {
                                serverManager.selectServer(server)
                                if server.isAuthenticated {
                                    authManager.restoreSession(
                                        serverURL: server.url,
                                        token: server.accessToken!,
                                        userId: server.userId!
                                    )
                                }
                            }) {
                                HStack {
                                    Image(systemName: "server.rack")
                                        .font(.system(size: 30))
                                        .foregroundColor(AppTheme.brandColor)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(server.name)
                                            .font(.system(size: AppTheme.FontSize.body, weight: .semibold))
                                            .foregroundColor(.white)
                                        Text(server.url)
                                            .font(.system(size: AppTheme.FontSize.caption))
                                            .foregroundColor(AppTheme.textSecondary)
                                    }
                                    Spacer()
                                    if server.isAuthenticated {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                                .padding(AppTheme.Spacing.lg)
                                .frame(maxWidth: 600)
                                .background(AppTheme.surfaceColor)
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    serverManager.removeServer(server)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }

                        Button(action: { showAddServer = true }) {
                            HStack(spacing: 8) {
                                Image(systemName: "plus")
                                Text("添加服务器")
                            }
                            .font(.system(size: AppTheme.FontSize.body))
                            .foregroundColor(AppTheme.brandColor)
                            .padding(AppTheme.Spacing.lg)
                            .frame(maxWidth: 600)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()
            }
            .background(AppTheme.background)
            .sheet(isPresented: $showAddServer) {
                AddServerView()
            }
        }
    }
}

struct AddServerView: View {
    @EnvironmentObject var serverManager: ServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Text("添加服务器")
                .font(.system(size: AppTheme.FontSize.title2, weight: .bold))
                .foregroundColor(.white)

            TextField("服务器地址 (例: http://192.168.1.100:8096)", text: $serverURL)
                .font(.system(size: AppTheme.FontSize.body))
                .padding(AppTheme.Spacing.lg)
                .background(AppTheme.surfaceColor)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
                .frame(maxWidth: 700)

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.caption))
                    .foregroundColor(.red)
            }

            HStack(spacing: AppTheme.Spacing.lg) {
                Button("取消") { dismiss() }
                    .font(.system(size: AppTheme.FontSize.body))
                    .foregroundColor(AppTheme.textSecondary)

                Button(action: connect) {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("连接")
                    }
                }
                .brandButton()
                .disabled(isLoading || serverURL.isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xxl)
        .background(AppTheme.background)
    }

    private func connect() {
        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://\(url)"
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let info = try await EmbyApiClient.testConnection(url: url)
                let config = ServerConfig(url: url, name: info.serverName)
                await MainActor.run {
                    serverManager.addServer(config)
                    serverManager.selectServer(config)
                    isLoading = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "连接失败: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - 服务器管理（侧边栏「服务器」入口，对齐安卓 TV 端）

struct ServerManagerView: View {
    let apiClient: EmbyApiClient
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var authManager: AuthManager

    @State private var showAddServer = false
    @State private var editingServer: ServerConfig?
    /// 在线状态探测结果：nil=探测中，true/false=结果
    @State private var reachability: [String: Bool] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    Text("服务器")
                        .font(.system(size: AppTheme.FontSize.title1, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, AppTheme.Spacing.xxl)
                        .padding(.top, AppTheme.Spacing.lg)

                    if serverManager.servers.isEmpty {
                        emptyState
                    } else {
                        ForEach(serverManager.servers, id: \.url) { server in
                            serverRow(server)
                                .padding(.horizontal, AppTheme.Spacing.xxl)
                        }
                    }

                    addButton
                        .padding(.horizontal, AppTheme.Spacing.xxl)
                        .padding(.top, AppTheme.Spacing.md)
                }
                .padding(.bottom, AppTheme.Spacing.xxl)
            }
            .background(AppTheme.background)
            .sheet(isPresented: $showAddServer) { AddServerView() }
            .sheet(item: $editingServer) { server in
                ServerEditView(server: server)
            }
            .task { await probeAll() }
        }
    }

    private func serverRow(_ server: ServerConfig) -> some View {
        let isCurrent = serverManager.currentServer?.url == server.url
        return HStack(spacing: AppTheme.Spacing.lg) {
            Button { switchTo(server) } label: {
                HStack(spacing: AppTheme.Spacing.lg) {
                    statusDot(for: server)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Text(server.name)
                                .font(.system(size: AppTheme.FontSize.body, weight: .bold))
                                .foregroundColor(isCurrent ? AppTheme.brandColor : .white)
                                .lineLimit(1)
                            if isCurrent {
                                Text("当前")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(AppTheme.brandColor))
                            }
                        }
                        Text(server.url)
                            .font(.system(size: AppTheme.FontSize.caption))
                            .foregroundColor(AppTheme.textSecondary)
                            .lineLimit(1)
                        Text(server.isAuthenticated ? "已登录" : "未登录")
                            .font(.system(size: 20))
                            .foregroundColor(server.isAuthenticated ? .green : AppTheme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(AppTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius)
                        .fill(isCurrent ? AppTheme.brandColor.opacity(0.12) : AppTheme.surfaceColor)
                )
            }
            .buttonStyle(.plain)

            Button { editingServer = server } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
                    .padding(AppTheme.Spacing.md)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)

            Button { delete(server) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 28))
                    .foregroundColor(.red)
                    .padding(AppTheme.Spacing.md)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
    }

    private func statusDot(for server: ServerConfig) -> some View {
        let online = reachability[server.url]
        let color: Color = {
            switch online {
            case .some(true): return .green
            case .some(false): return .red
            case .none: return AppTheme.textTertiary
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 20, height: 20)
            .padding(AppTheme.Spacing.md)
            .background(Circle().fill(color.opacity(0.18)))
    }

    private var addButton: some View {
        Button { showAddServer = true } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "plus")
                Text("添加服务器")
            }
            .font(.system(size: AppTheme.FontSize.body, weight: .semibold))
            .foregroundColor(AppTheme.brandColor)
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius)
                    .fill(Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "server.rack")
                .font(.system(size: 60))
                .foregroundColor(AppTheme.textTertiary)
            Text("尚未添加服务器")
                .font(.system(size: AppTheme.FontSize.body))
                .foregroundColor(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    /// 切换到某个服务器：已登录则直接恢复会话，否则注销当前会话回到登录页
    private func switchTo(_ server: ServerConfig) {
        guard serverManager.currentServer?.url != server.url || !authManager.isAuthenticated else { return }
        serverManager.selectServer(server)
        if server.isAuthenticated, let token = server.accessToken, let uid = server.userId {
            authManager.restoreSession(serverURL: server.url, token: token, userId: uid)
            authManager.currentUser = EmbyUser(id: uid, name: server.name)
        } else {
            Task { await authManager.logout() }
        }
    }

    private func delete(_ server: ServerConfig) {
        let wasCurrent = serverManager.currentServer?.url == server.url
        serverManager.removeServer(server)
        if wasCurrent {
            Task { await authManager.logout() }
        }
    }

    private func probeAll() async {
        for server in serverManager.servers {
            let url = server.url
            let ok = (try? await EmbyApiClient.testConnection(url: url)) != nil
            await MainActor.run { reachability[url] = ok }
        }
    }
}

// MARK: - 编辑服务器（名称 / 地址）

struct ServerEditView: View {
    let server: ServerConfig
    @EnvironmentObject var serverManager: ServerManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var url: String

    init(server: ServerConfig) {
        self.server = server
        _name = State(initialValue: server.name)
        _url = State(initialValue: server.url)
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Text("编辑服务器")
                .font(.system(size: AppTheme.FontSize.title2, weight: .bold))
                .foregroundColor(.white)

            VStack(spacing: AppTheme.Spacing.md) {
                TextField("名称", text: $name)
                    .font(.system(size: AppTheme.FontSize.body))
                    .padding(AppTheme.Spacing.lg)
                    .background(AppTheme.surfaceColor)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))

                TextField("服务器地址", text: $url)
                    .font(.system(size: AppTheme.FontSize.body))
                    .padding(AppTheme.Spacing.lg)
                    .background(AppTheme.surfaceColor)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
            }
            .frame(maxWidth: 800)

            HStack(spacing: AppTheme.Spacing.lg) {
                Button("取消") { dismiss() }
                    .font(.system(size: AppTheme.FontSize.body))
                    .foregroundColor(AppTheme.textSecondary)
                    .buttonStyle(.plain)

                Button(action: save) {
                    Text("保存").brandButton()
                }
                .buttonStyle(.plain)
                .disabled(name.isEmpty || url.isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xxl)
        .background(AppTheme.background)
    }

    private func save() {
        var newURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newURL.hasPrefix("http://") && !newURL.hasPrefix("https://") {
            newURL = "http://\(newURL)"
        }
        let urlChanged = newURL != server.url
        if urlChanged {
            // 地址变化视为新服务器身份，需重新登录
            serverManager.removeServer(server)
            serverManager.addServer(ServerConfig(url: newURL, name: name))
        } else {
            serverManager.addServer(ServerConfig(
                url: server.url, name: name,
                userId: server.userId, accessToken: server.accessToken))
        }
        dismiss()
    }
}
