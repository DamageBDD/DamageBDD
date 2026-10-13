import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var session: DamageSessionStore
    @State private var balanceText = "Not loaded"
    @State private var isLoadingBalance = false

    private let damageService = DamageService()

    var body: some View {
        Form {
            Section("Session") {
                LabeledContent("Email", value: session.username ?? "—")
                LabeledContent("AE address") {
                    Text(session.address ?? "—")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section("Balance") {
                Text(balanceText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)

                Button("Refresh Balance") {
                    guard let token = session.accessToken else { return }
                    Task {
                        isLoadingBalance = true
                        defer { isLoadingBalance = false }
                        do {
                            balanceText = try await damageService.balance(token: token)
                        } catch {
                            balanceText = error.localizedDescription
                        }
                    }
                }
                .disabled(isLoadingBalance)
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    session.logout()
                }
            }
        }
        .navigationTitle("Account")
    }
}
