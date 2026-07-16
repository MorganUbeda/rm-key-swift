import Foundation

// MARK: - Deployer

/// Deploys the Qt injector to the Paper Pro.
///
/// Creates a temporary SSH connection, uploads the injector .so,
/// installs a systemd drop-in, restarts xochitl, and polls for
/// the injector TCP port.
struct Deployer {
    let injectorPort = 31338
    let xochitlService = "xochitl.service"
    let dropinDir = "/run/systemd/system/xochitl.service.d"
    let dropinPath = "/run/systemd/system/xochitl.service.d/rm-key.conf"
    let remoteInjectorPath = "/tmp/librmkey_qt_inject.so"

    /// Deploy the injector and return true on success.
    func deploy(host: String, password: String, localInjectorPath: String) async -> Bool {
        // Validate local injector exists
        guard FileManager.default.fileExists(atPath: localInjectorPath) else {
            print("[rm-key] Injector not found at \(localInjectorPath)")
            return false
        }

        let actor = SSHActor()
        do {
            // 1. Connect
            try await actor.connect(host: host, password: password)

            // 2. Upload to staging path
            let stagingPath = "\(remoteInjectorPath).new"
            try await actor.uploadFile(localPath: localInjectorPath, remotePath: stagingPath)

            // 3. chmod + mv into place
            _ = try await actor.runCommand("chmod +x \(shlexQuote(stagingPath))")
            _ = try await actor.runCommand("mv -f \(shlexQuote(stagingPath)) \(shlexQuote(remoteInjectorPath))")

            // 4. Install systemd drop-in
            let dropin = """
                [Service]
                Environment=LD_PRELOAD=\(remoteInjectorPath)

                """
            let dropinCommand = """
                mkdir -p \(shlexQuote(dropinDir)) && \
                cat > \(shlexQuote(dropinPath)) << 'RM_KEY_EOF'
                \(dropin)RM_KEY_EOF
                """
            _ = try await actor.runCommand(dropinCommand)
            _ = try await actor.runCommand("systemctl daemon-reload")

            // 5. Stop xochitl (including orphan processes from old deploys)
            _ = try? await actor.runCommand("systemctl stop \(xochitlService) || true")
            _ = try? await actor.runCommand("killall xochitl || true")
            try await Task.sleep(nanoseconds: 2_000_000_000)

            // 6. Restart xochitl
            _ = try await actor.runCommand("systemctl restart \(xochitlService)")

            // 7. Poll for injector port
            let success = await pollForPort(actor: actor)

            await actor.disconnect()

            if success {
                print("[rm-key] Injector deployed successfully")
            } else {
                print("[rm-key] Injector port not ready after timeout")
            }

            return success

        } catch {
            print("[rm-key] Deployment failed: \(error)")
            await actor.disconnect()
            return false
        }
    }

    // MARK: - Port polling

    private func pollForPort(actor: SSHActor) async -> Bool {
        let timeout: TimeInterval = 30
        let interval: UInt64 = 2_000_000_000
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            do {
                // A successful direct-tcpip connection means the injector is
                // listening and ready to accept normal protocol frames.
                try await actor.openInjectorChannel()
                await actor.closeInjectorChannel()
                return true
            } catch {
                print("[rm-key] Injector port not ready, retrying...")
                try? await Task.sleep(nanoseconds: interval)
            }
        }

        return false
    }

    // MARK: - Helpers

    private func shlexQuote(_ string: String) -> String {
        // Single-quote for shell safety
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
