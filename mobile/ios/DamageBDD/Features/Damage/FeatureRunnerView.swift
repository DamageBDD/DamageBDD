import SwiftUI

@MainActor
final class FeatureRunnerViewModel: ObservableObject {
    @Published var feature = """
    Feature: DamageBDD mobile smoke

      Scenario: Read the DamageBDD version endpoint
        Given I am using server "https://damagebdd.com"
        When I make a GET request to "/version/"
        Then the response status must be "200"
    """
    @Published var result = "Run output will appear here."
    @Published var isRunning = false
    @Published var concurrency = 1

    private let service = DamageService()

    func run(token: String) async {
        guard !feature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isRunning = true
        result = "Executing…"
        defer { isRunning = false }

        do {
            result = try await service.executeFeature(
                feature: feature,
                token: token,
                concurrency: concurrency
            )
        } catch {
            result = error.localizedDescription
        }
    }
}

struct FeatureRunnerView: View {
    @EnvironmentObject private var session: DamageSessionStore
    @StateObject private var model = FeatureRunnerViewModel()

    var body: some View {
        Form {
            Section("Feature") {
                TextEditor(text: $model.feature)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 280)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Execution") {
                Stepper("Concurrency: \(model.concurrency)", value: $model.concurrency, in: 1...16)

                Button {
                    guard let token = session.accessToken else { return }
                    Task { await model.run(token: token) }
                } label: {
                    HStack {
                        Spacer()
                        if model.isRunning {
                            ProgressView()
                        } else {
                            Label("Execute Feature", systemImage: "play.fill")
                        }
                        Spacer()
                    }
                }
                .disabled(model.isRunning || session.accessToken == nil)
            }

            Section("Result") {
                ScrollView(.horizontal) {
                    Text(model.result)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("Damage Runner")
    }
}
