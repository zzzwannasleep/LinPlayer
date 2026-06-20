import SwiftUI

struct LoginView: View {
    let server: ServerConfig
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var authManager: AuthManager
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Spacer()

            Image(systemName: "person.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(AppTheme.brandColor)

            Text("登录到 \(server.name)")
                .font(.system(size: AppTheme.FontSize.title2, weight: .bold))
                .foregroundColor(.white)

            Text(server.url)
                .font(.system(size: AppTheme.FontSize.caption))
                .foregroundColor(AppTheme.textSecondary)

            VStack(spacing: AppTheme.Spacing.md) {
                TextField("用户名", text: $username)
                    .font(.system(size: AppTheme.FontSize.body))
                    .padding(AppTheme.Spacing.lg)
                    .background(AppTheme.surfaceColor)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))

                SecureField("密码", text: $password)
                    .font(.system(size: AppTheme.FontSize.body))
                    .padding(AppTheme.Spacing.lg)
                    .background(AppTheme.surfaceColor)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
            }
            .frame(maxWidth: 500)

            if let error = authManager.errorMessage {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.caption))
                    .foregroundColor(.red)
            }

            Button(action: login) {
                if authManager.isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text("登录")
                }
            }
            .brandButton()
            .disabled(authManager.isLoading || username.isEmpty)

            Button("切换服务器") {
                serverManager.currentServer = nil
            }
            .font(.system(size: AppTheme.FontSize.caption))
            .foregroundColor(AppTheme.textSecondary)

            Spacer()
        }
        .background(AppTheme.background)
    }

    private func login() {
        Task {
            await authManager.login(
                serverURL: server.url,
                username: username,
                password: password,
                allowInsecureTLS: server.allowInsecureTLS
            )
            if authManager.isAuthenticated {
                serverManager.updateServerAuth(
                    url: server.url,
                    token: authManager.apiClient?.accessToken ?? "",
                    userId: authManager.apiClient?.userId ?? ""
                )
            }
        }
    }
}
