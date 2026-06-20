import Foundation
import SwiftUI

final class AuthManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: EmbyUser?
    @Published var apiClient: EmbyApiClient?
    @Published var isLoading = false
    @Published var errorMessage: String?

    func login(serverURL: String, username: String, password: String, allowInsecureTLS: Bool = false) async {
        await MainActor.run { isLoading = true; errorMessage = nil }

        do {
            let client = EmbyApiClient(baseURL: serverURL, allowInsecureTLS: allowInsecureTLS)
            let result = try await client.login(username: username, password: password)
            await MainActor.run {
                self.apiClient = client
                self.currentUser = result.user
                self.isAuthenticated = true
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func restoreSession(serverURL: String, token: String, userId: String, allowInsecureTLS: Bool = false) {
        let client = EmbyApiClient(baseURL: serverURL, accessToken: token, userId: userId, allowInsecureTLS: allowInsecureTLS)
        self.apiClient = client
        self.isAuthenticated = true
    }

    func logout() async {
        try? await apiClient?.logout()
        await MainActor.run {
            self.apiClient = nil
            self.currentUser = nil
            self.isAuthenticated = false
        }
    }
}
