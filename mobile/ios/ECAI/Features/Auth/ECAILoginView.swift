import SwiftUI

struct ECAILoginView: View {
    @EnvironmentObject private var session: ECAISessionStore
    @State private var identifier = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("ECAI")
                        .font(.largeTitle.bold())
                    Text("Sign in to the standalone ECAI chat app.")
                        .foregroundStyle(.secondary)
                }

                if AppConfig.ecaiBaseURL == nil {
                    Section {
                        Label("Stub mode: any non-empty credentials open the local chat shell.", systemImage: "hammer")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("ECAI account") {
                    TextField("Account or email", text: $identifier)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $password)
                        .textContentType(.password)

                    Button {
                        Task { await session.login(identifier: identifier, password: password) }
                    } label: {
                        HStack {
                            Spacer()
                            if session.isBusy {
                                ProgressView()
                            } else {
                                Text("Sign In")
                            }
                            Spacer()
                        }
                    }
                    .disabled(identifier.isEmpty || password.isEmpty || session.isBusy)
                }

                if let error = session.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section("Server") {
                    LabeledContent(
                        "ECAI API",
                        value: AppConfig.ecaiBaseURL?.absoluteString ?? "Not configured (stub)"
                    )
                }
            }
            .navigationTitle("Sign In")
        }
    }
}
