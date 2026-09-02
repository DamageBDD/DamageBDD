import SwiftUI

@main
struct ECAIApp: App {
    @StateObject private var session = ECAISessionStore()

    var body: some Scene {
        WindowGroup {
            ECAIRootView()
                .environmentObject(session)
        }
    }
}
