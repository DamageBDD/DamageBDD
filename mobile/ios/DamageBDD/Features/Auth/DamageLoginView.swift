import SwiftUI

struct DamageLoginView: View {
    @EnvironmentObject private var session: DamageSessionStore
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("DamageBDD")
                        .font(.largeTitle.bold())
                    Text("Authenticate to execute human-readable Gherkin features against a DamageBDD node.")
                        .foregroundStyle(.secondary)
                }

                Section("Account") {
                    TextField("Email", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)

                    SecureField("Password", text: $password)
                        .textContentType(.password)

                    Button {
                        Task { await session.login(username: username, password: password) }
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
                    .disabled(username.isEmpty || password.isEmpty || session.isBusy)
                }

                if let error = session.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section("Server") {
                    LabeledContent("Damage API", value: AppConfig.damageBaseURL.absoluteString)
                }
            }
            .navigationTitle("Sign In")
        }
    }
}
