import Foundation
import Clibssh2
import Darwin

// MARK: - Error types

enum SSHActorError: LocalizedError {
    case notConnected
    case noInjectorChannel
    case initFailed
    case sessionFailed
    case handshakeFailed(String)
    case authFailed
    case channelFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "SSH is not connected"
        case .noInjectorChannel: "No injector channel open"
        case .initFailed: "Failed to initialize libssh2"
        case .sessionFailed: "Failed to create SSH session"
        case .handshakeFailed(let msg): "SSH handshake failed: \(msg)"
        case .authFailed: "Authentication failed"
        case .channelFailed(let msg): "Channel error: \(msg)"
        case .commandFailed(let msg): "Command failed: \(msg)"
        }
    }
}

// libssh2 constants not exposed as C macros
private let SSH_DISCONNECT_BY_APPLICATION: CInt = 11
private let LIBSSH2_ERROR_EAGAIN = -37
private let LIBSSH2_CHANNEL_WINDOW_DEFAULT: CUnsignedInt = 2 * 1024 * 1024
private let LIBSSH2_CHANNEL_PACKET_DEFAULT: CUnsignedInt = 32768

// MARK: - SSHActor

/// Manages a persistent SSH connection using libssh2.
///
/// All libssh2 calls run directly from actor-isolated methods.
/// Uses the `_ex` variants because libssh2 convenience macros
/// are not available to Swift.
actor SSHActor {
    private static var initialized = false

    private var sock: Int32 = -1
    private var session: OpaquePointer?
    private var injectorChannel: OpaquePointer?

    var isConnected: Bool { session != nil }
    var isInjectorReady: Bool { injectorChannel != nil }

    // MARK: - Connection lifecycle

    func connect(host: String, password: String) async throws {
        disconnect()

        if !Self.initialized {
            guard libssh2_init(0) == 0 else {
                throw SSHActorError.initFailed
            }
            Self.initialized = true
        }

        // Create socket
        let newSock = socket(AF_INET, SOCK_STREAM, 0)
        guard newSock >= 0 else { throw SSHActorError.sessionFailed }
        self.sock = newSock

        // Set socket timeout
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(newSock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(newSock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Resolve host
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "22", &hints, &result) == 0, let addr = result else {
            cleanupConnection()
            throw SSHActorError.handshakeFailed("DNS resolution failed")
        }
        defer { freeaddrinfo(result) }

        let connectRc = addr.pointee.ai_addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
            Darwin.connect(newSock, ptr, addr.pointee.ai_addrlen)
        }
        guard connectRc == 0 else {
            cleanupConnection()
            throw SSHActorError.handshakeFailed("Connection refused")
        }

        // Create session (use _ex variant, macro not available)
        guard let newSession = libssh2_session_init_ex(nil, nil, nil, nil) else {
            cleanupConnection()
            throw SSHActorError.sessionFailed
        }
        self.session = newSession
        libssh2_session_set_blocking(newSession, 1)

        guard libssh2_session_handshake(newSession, newSock) == 0 else {
            let msg = lastError(session: newSession)
            cleanupConnection()
            throw SSHActorError.handshakeFailed(msg)
        }

        // Authenticate (use _ex variant)
        let authRc = password.withCString { pwPtr in
            libssh2_userauth_password_ex(
                newSession, "root", UInt32(strlen("root")),
                pwPtr, UInt32(strlen(pwPtr)), nil
            )
        }
        guard authRc == 0 else {
            cleanupConnection()
            throw SSHActorError.authFailed
        }
    }

    func disconnect() {
        if let ch = injectorChannel {
            libssh2_channel_free(ch)
            injectorChannel = nil
        }
        if let session {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
            libssh2_session_free(session)
            self.session = nil
        }
        if sock >= 0 {
            close(sock)
            sock = -1
        }
    }

    // MARK: - Injector channel

    func openInjectorChannel() async throws {
        guard let session else { throw SSHActorError.notConnected }

        if let ch = injectorChannel {
            libssh2_channel_free(ch)
            injectorChannel = nil
        }

        guard let channel = libssh2_channel_direct_tcpip_ex(
            session, "127.0.0.1", 31338, "127.0.0.1", 0
        ) else {
            throw SSHActorError.channelFailed(lastError(session: session))
        }
        self.injectorChannel = channel
    }

    func closeInjectorChannel() {
        if let ch = injectorChannel {
            libssh2_channel_free(ch)
            injectorChannel = nil
        }
    }

    func sendFrame(_ data: Data) async throws {
        guard let channel = injectorChannel else {
            throw SSHActorError.noInjectorChannel
        }

        let sent = data.withUnsafeBytes { ptr in
            libssh2_channel_write_ex(
                channel, 0,
                ptr.baseAddress?.assumingMemoryBound(to: CChar.self),
                data.count
            )
        }
        guard sent == data.count else {
            throw SSHActorError.channelFailed("Short write: \(sent)/\(data.count)")
        }
    }

    // MARK: - Command execution

    func runCommand(_ command: String) async throws -> String {
        guard let session else { throw SSHActorError.notConnected }

        guard let channel = libssh2_channel_open_ex(
            session, "session", UInt32(strlen("session")),
            LIBSSH2_CHANNEL_WINDOW_DEFAULT, LIBSSH2_CHANNEL_PACKET_DEFAULT,
            nil, 0
        ) else {
            throw SSHActorError.channelFailed(lastError(session: session))
        }
        defer { libssh2_channel_free(channel) }

        let execRc = command.withCString { cmdPtr in
            libssh2_channel_process_startup(
                channel, "exec", UInt32(strlen("exec")),
                cmdPtr, UInt32(strlen(cmdPtr))
            )
        }
        guard execRc == 0 else {
            throw SSHActorError.commandFailed(lastError(session: session))
        }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let rc = libssh2_channel_read_ex(channel, 0, &buffer, buffer.count)
            if rc > 0 {
                output.append(contentsOf: buffer[0..<Int(rc)])
            } else if rc == LIBSSH2_ERROR_EAGAIN {
                usleep(10000)
                continue
            } else {
                break
            }
        }

        libssh2_channel_wait_closed(channel)
        let exitCode = libssh2_channel_get_exit_status(channel)

        guard exitCode == 0 else {
            let outStr = String(data: output, encoding: .utf8) ?? ""
            throw SSHActorError.commandFailed("exit \(exitCode): \(outStr)")
        }

        return String(data: output, encoding: .utf8) ?? ""
    }

    // MARK: - File upload via exec channel

    func uploadFile(localPath: String, remotePath: String) async throws {
        guard let session else { throw SSHActorError.notConnected }

        let fileData = try Data(contentsOf: URL(fileURLWithPath: localPath))

        guard let channel = libssh2_channel_open_ex(
            session, "session", UInt32(strlen("session")),
            LIBSSH2_CHANNEL_WINDOW_DEFAULT, LIBSSH2_CHANNEL_PACKET_DEFAULT,
            nil, 0
        ) else {
            throw SSHActorError.channelFailed(lastError(session: session))
        }
        defer { libssh2_channel_free(channel) }

        let cmd = "cat > \(remotePath)"
        let execRc = cmd.withCString { cmdPtr in
            libssh2_channel_process_startup(
                channel, "exec", UInt32(strlen("exec")),
                cmdPtr, UInt32(strlen(cmdPtr))
            )
        }
        guard execRc == 0 else {
            throw SSHActorError.commandFailed(lastError(session: session))
        }

        try fileData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let bytes = ptr.baseAddress?.assumingMemoryBound(to: CChar.self)
            var written = 0
            while written < fileData.count {
                let rc = libssh2_channel_write_ex(
                    channel, 0, bytes?.advanced(by: written),
                    fileData.count - written
                )
                if rc < 0 { throw SSHActorError.channelFailed("Upload write failed") }
                written += rc
            }
        }

        libssh2_channel_send_eof(channel)
        libssh2_channel_wait_closed(channel)

        let exitCode = libssh2_channel_get_exit_status(channel)
        guard exitCode == 0 else {
            throw SSHActorError.commandFailed("cat exited with \(exitCode)")
        }
    }

    // MARK: - Internal

    private func lastError(session: OpaquePointer) -> String {
        var msgPtr: UnsafeMutablePointer<CChar>?
        var msgLen: Int32 = 0
        libssh2_session_last_error(session, &msgPtr, &msgLen, 0)
        if let msgPtr, msgLen > 0 {
            return String(cString: msgPtr)
        }
        return "unknown libssh2 error"
    }

    private func cleanupConnection() {
        if let ch = injectorChannel {
            libssh2_channel_free(ch)
            injectorChannel = nil
        }
        if let session {
            libssh2_session_free(session)
            self.session = nil
        }
        if sock >= 0 {
            close(sock)
            sock = -1
        }
    }
}
