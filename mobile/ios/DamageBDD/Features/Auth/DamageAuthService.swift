import Foundation

struct DamageAuthService {
    private let client = APIClient(baseURL: AppConfig.damageBaseURL)

    func login(username: String, password: String) async throws -> AuthResponse {
        let data = try await client.send(
            path: "/accounts/auth/",
            method: "POST",
            jsonBody: [
                "username": username,
                "password": password
            ]
        )
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }
}
