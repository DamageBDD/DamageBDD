import Foundation

enum APIError: LocalizedError {
    case invalidResponse
    case http(status: Int, body: String)
    case invalidJSON
    case missingField(String)
    case invalidCredentials

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an invalid response."
        case let .http(status, body):
            return "HTTP \(status): \(body)"
        case .invalidJSON:
            return "The server returned invalid JSON."
        case let .missingField(field):
            return "The response is missing required field: \(field)."
        case .invalidCredentials:
            return "Enter both an account identifier and password."
        }
    }
}
