import Foundation
import Combine

@MainActor
final class DamageSessionStore: ObservableObject {
    @Published private(set) var accessToken: String?
    @Published private(set) var address: String?
    @Published private(set) var username: String?
    @Published var isBusy = false
    @Published var errorMessage: String?

    private let authService = DamageAuthService()
    private let tokenKey = "damage_access_token"

    var isAuthenticated: Bool {
        guard let accessToken else { return false }
        return !accessToken.isEmpty
    }

    func restore() async {
        guard accessToken == nil else { return }
        accessToken = KeychainStore.read(account: tokenKey)
        address = UserDefaults.standard.string(forKey: "damage.address")
        username = UserDefaults.standard.string(forKey: "damage.username")
    }

    func login(username: String, password: String) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let response = try await authService.login(username: username, password: password)
            try KeychainStore.save(response.accessToken, account: tokenKey)
            UserDefaults.standard.set(response.address, forKey: "damage.address")
            UserDefaults.standard.set(username, forKey: "damage.username")

            accessToken = response.accessToken
            address = response.address
            self.username = username
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        KeychainStore.delete(account: tokenKey)
        UserDefaults.standard.removeObject(forKey: "damage.address")
        UserDefaults.standard.removeObject(forKey: "damage.username")
        accessToken = nil
        address = nil
        username = nil
        errorMessage = nil
    }
}
