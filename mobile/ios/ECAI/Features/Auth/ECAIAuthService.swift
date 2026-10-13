import Foundation

struct ECAIAuthSession {
    let accessToken: String
    let accountName: String
    let isStub: Bool
}

protocol ECAIAuthService {
    func login(identifier: String, password: String) async throws -> ECAIAuthSession
}

struct StubECAIAuthService: ECAIAuthService {
    func login(identifier: String, password: String) async throws -> ECAIAuthSession {
        guard !identifier.isEmpty, !password.isEmpty else {
            throw APIError.invalidCredentials
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        return ECAIAuthSession(
            accessToken: "ecai-stub-session",
            accountName: identifier,
            isStub: true
        )
    }
}

struct HTTPECAIAuthService: ECAIAuthService {
    let client: APIClient

    func login(identifier: String, password: String) async throws -> ECAIAuthSession {
        let data = try await client.send(
            path: AppConfig.ecaiAuthPath,
            method: "POST",
            jsonBody: [
                "username": identifier,
                "password": password
            ]
        )

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidJSON
        }

        let token = ["access_token", "token", "session_token"]
            .compactMap { object[$0] as? String }
            .first { !$0.isEmpty }

        guard let token else {
            throw APIError.missingField("access_token/token/session_token")
        }

        let accountName = (object["username"] as? String)
            ?? (object["name"] as? String)
            ?? identifier

        return ECAIAuthSession(
            accessToken: token,
            accountName: accountName,
            isStub: false
        )
    }
}

enum ECAIAuthServiceFactory {
    static func make() -> any ECAIAuthService {
        guard let baseURL = AppConfig.ecaiBaseURL else {
            return StubECAIAuthService()
        }
        return HTTPECAIAuthService(client: APIClient(baseURL: baseURL))
    }
}
