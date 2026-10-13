import SwiftUI

struct DamageRootView: View {
    @EnvironmentObject private var session: DamageSessionStore

    var body: some View {
        Group {
            if session.isAuthenticated {
                DamageMainTabView()
            } else {
                DamageLoginView()
            }
        }
        .task {
            await session.restore()
        }
    }
}

private struct DamageMainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                FeatureRunnerView()
            }
            .tabItem {
                Label("Runner", systemImage: "bolt.badge.checkmark")
            }

            NavigationStack {
                AccountView()
            }
            .tabItem {
                Label("Account", systemImage: "person.crop.circle")
            }
        }
    }
}
