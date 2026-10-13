import Foundation

protocol ECAIService {
    func send(message: String, bearerToken: String?) async throws -> String
}

struct StubECAIService: ECAIService {
    func send(message: String, bearerToken: String?) async throws -> String {
        try await Task.sleep(nanoseconds: 250_000_000)
        return "ECAI backend is not configured yet. Stub received: \(message)"
    }
}

struct HTTPECAIService: ECAIService {
    let client: APIClient

    func send(message: String, bearerToken: String?) async throws -> String {
        let data = try await client.send(
            path: AppConfig.ecaiChatPath,
            method: "POST",
            jsonBody: ["message": message],
            bearerToken: bearerToken
        )

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidJSON
        }

        for key in ["message", "reply", "content", "response"] {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        throw APIError.missingField("message/reply/content/response")
    }
}

enum ECAIServiceFactory {
    static func make() -> any ECAIService {
        guard let baseURL = AppConfig.ecaiBaseURL else {
            return StubECAIService()
        }
        return HTTPECAIService(client: APIClient(baseURL: baseURL))
    }
}
