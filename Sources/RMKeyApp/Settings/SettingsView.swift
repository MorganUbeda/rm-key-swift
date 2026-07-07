import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var ipInput: String
    @State private var passwordInput: String
    @State private var showPassword = false

    init(appState: AppState) {
        self.appState = appState
        self._ipInput = State(initialValue: appState.ipAddress)
        self._passwordInput = State(initialValue: appState.password)
    }

    var body: some View {
        VStack(spacing: 12) {
            // IP address
            HStack {
                Text("Tablet IP:")
                    .frame(width: 100, alignment: .trailing)
                TextField("10.11.99.1", text: $ipInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            // Password
            HStack {
                Text("Root password:")
                    .frame(width: 100, alignment: .trailing)
                HStack(spacing: 0) {
                    if showPassword {
                        TextField("", text: $passwordInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("", text: $passwordInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, 4)
                }
            }

            // Save credentials
            Button(action: saveCredentials) {
                Text("Update Credentials")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            // Upload Daemon
            Button(action: { Task { await uploadDaemon() } }) {
                Text("Upload Daemon")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Button(action: { Task { await appState.reconnect() } }) {
                Text("Reconnect")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            // Status
            if !appState.statusMessage.isEmpty {
                Text(appState.statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 380)
    }

    private func saveCredentials() {
        let ip = ipInput.trimmingCharacters(in: .whitespaces).isEmpty
            ? "10.11.99.1"
            : ipInput.trimmingCharacters(in: .whitespaces)
        appState.updateCredentials(ip: ip, password: passwordInput)
    }

    private func uploadDaemon() async {
        saveCredentials()
        await appState.uploadInjector()
    }
}
