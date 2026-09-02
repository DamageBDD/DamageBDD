import Foundation

struct AuthResponse: Decodable {
    let status: String
    let accessToken: String
    let address: String

    enum CodingKeys: String, CodingKey {
        case status
        case accessToken = "access_token"
        case address
    }
}
