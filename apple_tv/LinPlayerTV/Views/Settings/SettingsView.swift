import SwiftUI

/// 播放偏好键（与 PlayerView 共享）
enum SettingsKey {
    static let autoPlayNext = "autoPlayNext"
    static let resumePlayback = "resumePlayback"
    static let watchedThreshold = "watchedThreshold"
    static let defaultPlaybackSpeed = "defaultPlaybackSpeed"
    static let updateChannel = "updateChannel"
}

struct SettingsView: View {
    var apiClient: EmbyApiClient?
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var authManager: AuthManager

    @AppStorage(SettingsKey.autoPlayNext) private var autoPlayNext = true
    @AppStorage(SettingsKey.resumePlayback) private var resumePlayback = true
    @AppStorage(SettingsKey.watchedThreshold) private var watchedThreshold = 0.9
    @AppStorage(SettingsKey.defaultPlaybackSpeed) private var defaultSpeed = 1.0
    @AppStorage(SettingsKey.updateChannel) private var updateChannel = "stable"

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                playbackSection
                aboutSection
            }
            .background(AppTheme.background)
        }
    }

    // MARK: - 账户

    private var accountSection: some View {
        Section("账户") {
            if let user = authManager.currentUser {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(AppTheme.brandColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name)
                            .font(.system(size: AppTheme.FontSize.body, weight: .semibold))
                        if let server = serverManager.currentServer {
                            Text(server.name)
                                .font(.system(size: AppTheme.FontSize.caption))
                                .foregroundColor(AppTheme.textSecondary)
                        }
                    }
                }
            }

            if let server = serverManager.currentServer {
                LabeledContent("服务器地址") {
                    Text(server.url).foregroundColor(AppTheme.textSecondary)
                }
            }

            Button(role: .destructive) {
                Task { await authManager.logout() }
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    // MARK: - 播放

    private var playbackSection: some View {
        Section("播放") {
            Toggle(isOn: $resumePlayback) {
                Label("从上次位置继续", systemImage: "memorychip")
            }

            Toggle(isOn: $autoPlayNext) {
                Label("自动播放下一集", systemImage: "forward.end.fill")
            }

            Picker(selection: $defaultSpeed) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Text("\(speed, specifier: "%g")x").tag(speed)
                }
            } label: {
                Label("默认倍速", systemImage: "speedometer")
            }

            Picker(selection: $watchedThreshold) {
                ForEach([0.75, 0.8, 0.85, 0.9, 0.95], id: \.self) { t in
                    Text("\(Int(t * 100))%").tag(t)
                }
            } label: {
                Label("标记为已看的进度阈值", systemImage: "checkmark.circle")
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            Picker(selection: $updateChannel) {
                Text("稳定版").tag("stable")
                Text("预览版").tag("pre")
            } label: {
                Label("更新通道", systemImage: "arrow.triangle.2.circlepath")
            }

            LabeledContent("版本") {
                Text("1.0.0").foregroundColor(AppTheme.textSecondary)
            }
            LabeledContent("平台") {
                Text("Apple TV (tvOS)").foregroundColor(AppTheme.textSecondary)
            }
        }
    }
}
