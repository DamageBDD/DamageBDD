import SwiftUI

@MainActor
final class ECAIChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = [
        ChatMessage(role: .assistant, text: "ECAI chat shell ready.")
    ]
    @Published var draft = ""
    @Published var isSending = false

    private let service: any ECAIService

    init(service: any ECAIService = ECAIServiceFactory.make()) {
        self.service = service
    }

    func send(token: String?) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        draft = ""
        messages.append(ChatMessage(role: .user, text: text))
        isSending = true
        defer { isSending = false }

        do {
            let reply = try await service.send(message: text, bearerToken: token)
            messages.append(ChatMessage(role: .assistant, text: reply))
        } catch {
            messages.append(
                ChatMessage(role: .assistant, text: "Error: \(error.localizedDescription)")
            )
        }
    }
}

struct ECAIChatView: View {
    @EnvironmentObject private var session: ECAISessionStore
    @StateObject private var model = ECAIChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.messages.count) { _ in
                    if let id = model.messages.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message ECAI", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                Button {
                    Task { await model.send(token: session.accessToken) }
                } label: {
                    if model.isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .disabled(
                    model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isSending
                )
            }
            .padding()
        }
        .navigationTitle("ECAI")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if AppConfig.ecaiBaseURL == nil || session.isStubSession {
                    Text("STUB")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }

                Button("Sign Out") {
                    session.logout()
                }
            }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble
                Spacer(minLength: 44)
            } else {
                Spacer(minLength: 44)
                bubble
            }
        }
    }

    private var bubble: some View {
        Text(message.text)
            .textSelection(.enabled)
            .padding(12)
            .background(
                message.role == .assistant
                    ? Color.secondary.opacity(0.12)
                    : Color.accentColor.opacity(0.16)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
