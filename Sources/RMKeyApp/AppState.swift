import Foundation
import Observation

@Observable
final class AppState {
    enum ConnectionState {
        case disconnected
        case connecting
        case sshConnected       // SSH alive, no injector channel
        case connected          // SSH + injector channel ready
    }

    var connectionState: ConnectionState = .disconnected
    var statusMessage: String = ""
    var lastTypedKey: String = ""
    var captureWindowOpen = false

    var ipAddress: String
    var password: String

    let credentialStore = CredentialStore()
    let sshActor = SSHActor()
    let deployer = Deployer()

    init() {
        self.ipAddress = credentialStore.loadIP()
        self.password = credentialStore.loadPassword()
    }

    var statusText: String {
        switch connectionState {
        case .disconnected: return "● Disconnected"
        case .connecting:   return "● Connecting..."
        case .sshConnected: return "● SSH Connected"
        case .connected:    return "● Connected"
        }
    }

    // MARK: - Actions

    func updateCredentials(ip: String, password: String) {
        self.ipAddress = ip
        self.password = password
        try? credentialStore.save(ip: ip, password: password)
        setStatusMessage("Credentials saved")
    }

    /// Ensure SSH is connected and injector channel is open.
    /// Called when opening the capture window.
    func ensureConnected() async {
        guard connectionState != .connecting else { return }

        if connectionState == .connected {
            setConnectionState(.connected) // already good
            return
        }

        setConnectionState(.connecting)

        do {
            if await sshActor.isConnected == false {
                try await sshActor.connect(host: ipAddress, password: password)
            }

            if await sshActor.isInjectorReady == false {
                try await sshActor.openInjectorChannel()
            }

            setConnectionState(.connected)
        } catch {
            if await sshActor.isConnected {
                setConnectionState(.sshConnected)
            } else {
                setConnectionState(.disconnected)
            }
            setStatusMessage("Connection failed: \(error.localizedDescription)")
        }
    }

    /// Full reconnect: disconnect everything, then reconnect.
    func reconnect() async {
        setConnectionState(.connecting)
        await sshActor.disconnect()
        setConnectionState(.disconnected)

        do {
            try await sshActor.connect(host: ipAddress, password: password)
            setConnectionState(.sshConnected)
            try await sshActor.openInjectorChannel()
            setConnectionState(.connected)
            setStatusMessage("Reconnected")
        } catch {
            setConnectionState(.disconnected)
            setStatusMessage("Reconnect failed: \(error.localizedDescription)")
        }
    }

    func uploadInjector() async {
        setStatusMessage("Uploading daemon...")

        let injectorPath = Bundle.main.path(
            forResource: "librmkey_qt_inject",
            ofType: "so"
        ) ?? "result/librmkey_qt_inject.so"

        let success = await deployer.deploy(
            host: ipAddress,
            password: password,
            localInjectorPath: injectorPath
        )

        if success {
            do {
                await sshActor.disconnect()
                try await sshActor.connect(host: ipAddress, password: password)
                setConnectionState(.sshConnected)
                try await sshActor.openInjectorChannel()
                setConnectionState(.connected)
                setStatusMessage("Daemon uploaded — connected")
            } catch {
                setConnectionState(.sshConnected)
                setStatusMessage("Daemon uploaded — click Start Capture")
            }
        } else {
            setStatusMessage("Upload failed")
        }
    }

    // MARK: - Internal

    private func setConnectionState(_ state: ConnectionState) {
        connectionState = state
    }

    private func setStatusMessage(_ message: String) {
        statusMessage = message
        let captured = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if statusMessage == captured {
                statusMessage = ""
            }
        }
    }
}
