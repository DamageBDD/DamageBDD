import Foundation
import Combine

@MainActor
final class ECAISessionStore: ObservableObject {
    @Published private(set) var accessToken: String?
    @Published private(set) var accountName: String?
    @Published private(set) var isStubSession = false
    @Published var isBusy = false
    @Published var errorMessage: String?

    private let authService: any ECAIAuthService
    private let tokenKey = "ecai_access_token"

    init(authService: any ECAIAuthService = ECAIAuthServiceFactory.make()) {
        self.authService = authService
    }

    var isAuthenticated: Bool {
        guard let accessToken else { return false }
        return !accessToken.isEmpty
    }

    func restore() async {
        guard accessToken == nil else { return }
        accessToken = KeychainStore.read(account: tokenKey)
        accountName = UserDefaults.standard.string(forKey: "ecai.account_name")
        isStubSession = UserDefaults.standard.bool(forKey: "ecai.stub_session")
    }

    func login(identifier: String, password: String) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let response = try await authService.login(identifier: identifier, password: password)
            try KeychainStore.save(response.accessToken, account: tokenKey)
            UserDefaults.standard.set(response.accountName, forKey: "ecai.account_name")
            UserDefaults.standard.set(response.isStub, forKey: "ecai.stub_session")

            accessToken = response.accessToken
            accountName = response.accountName
            isStubSession = response.isStub
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        KeychainStore.delete(account: tokenKey)
        UserDefaults.standard.removeObject(forKey: "ecai.account_name")
        UserDefaults.standard.removeObject(forKey: "ecai.stub_session")
        accessToken = nil
        accountName = nil
        isStubSession = false
        errorMessage = nil
    }
}
