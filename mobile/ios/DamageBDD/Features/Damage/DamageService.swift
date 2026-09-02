import Foundation

struct DamageService {
    private let client = APIClient(baseURL: AppConfig.damageBaseURL)

    func executeFeature(feature: String, token: String, concurrency: Int = 1) async throws -> String {
        let data = try await client.send(
            path: "/execute_feature/",
            method: "PUT",
            jsonBody: [
                "feature": feature,
                "concurrency": concurrency,
                "stream": false
            ],
            bearerToken: token
        )

        if let pretty = try? APIClient.prettyJSON(data) {
            return pretty
        }
        return String(data: data, encoding: .utf8) ?? "<empty response>"
    }

    func balance(token: String) async throws -> String {
        let data = try await client.send(
            path: "/accounts/balance",
            method: "GET",
            bearerToken: token
        )
        return (try? APIClient.prettyJSON(data)) ?? String(decoding: data, as: UTF8.self)
    }
}
