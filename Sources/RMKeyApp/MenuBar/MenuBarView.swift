import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(appState.statusText)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            Divider()

            Button(action: { Task { await toggleCaptureWindow() } }) {
                Text(captureButtonLabel)
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 8)

            Button(action: { Task { await appState.reconnect() } }) {
                Text("Reconnect")
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)

            Button(action: { Task { await uploadDaemon() } }) {
                Text("Upload Daemon")
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)

            Divider()

            Button(action: { openWindow(id: "settings") }) {
                Text("Settings...")
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Text("Quit")
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)

            if !appState.statusMessage.isEmpty {
                Divider()
                Text(appState.statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
        .frame(width: 200)
        .padding(.bottom, 6)
    }

    private var statusColor: Color {
        switch appState.connectionState {
        case .disconnected: .red
        case .connecting:   .yellow
        case .sshConnected: .orange
        case .connected:    .green
        }
    }

    private var captureButtonLabel: String {
        appState.captureWindowOpen ? "Stop Capture" : "Start Capture"
    }

    private func toggleCaptureWindow() async {
        if appState.captureWindowOpen {
            await MainActor.run {
                appState.captureWindowOpen = false
                for window in NSApp.windows where window.title == "Capture" {
                    window.close()
                }
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            await appState.ensureConnected()
            if appState.connectionState == .connected {
                await MainActor.run {
                    appState.captureWindowOpen = true
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "capture")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    private func uploadDaemon() async {
        await appState.uploadInjector()
        if appState.connectionState == .connected {
            await MainActor.run {
                appState.captureWindowOpen = true
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "capture")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
