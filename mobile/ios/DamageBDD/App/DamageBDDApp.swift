import SwiftUI

@main
struct DamageBDDApp: App {
    @StateObject private var session = DamageSessionStore()

    var body: some Scene {
        WindowGroup {
            DamageRootView()
                .environmentObject(session)
        }
    }
}
