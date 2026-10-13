import Foundation

enum AppConfig {
    /// DamageBDD node/API base URL. Change this to your deployed node.
    static let damageBaseURL = URL(string: "https://damagebdd.com")!

    /// Set this when the ECAI HTTP contract is available.
    /// Leaving it nil keeps the standalone ECAI app functional in stub mode.
    static let ecaiBaseURL: URL? = nil

    /// Placeholder paths for the replaceable ECAI adapters.
    static let ecaiAuthPath = "/auth"
    static let ecaiChatPath = "/chat"
}
