import SwiftUI

struct ECAIRootView: View {
    @EnvironmentObject private var session: ECAISessionStore

    var body: some View {
        Group {
            if session.isAuthenticated {
                NavigationStack {
                    ECAIChatView()
                }
            } else {
                ECAILoginView()
            }
        }
        .task {
            await session.restore()
        }
    }
}
