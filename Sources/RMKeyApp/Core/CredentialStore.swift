import Foundation
import Security

/// Stores and retrieves IP address and password from the macOS Keychain.
struct CredentialStore {
    private let service = "rm-key"
    private let ipAccount = "ip"
    private let passwordAccount = "root"

    /// Load saved IP address (defaults to "10.11.99.1").
    func loadIP() -> String {
        load(account: ipAccount) ?? "10.11.99.1"
    }

    /// Load saved root password (empty string if none).
    func loadPassword() -> String {
        load(account: passwordAccount) ?? ""
    }

    /// Save IP and password to the keychain.
    func save(ip: String, password: String) throws {
        try save(account: ipAccount, value: ip)
        try save(account: passwordAccount, value: password)
    }

    // MARK: - Private

    private func save(account: String, value: String) throws {
        // Delete existing item first
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        guard let data = value.data(using: .utf8) else {
            throw CredentialError.encodingFailed
        }

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.keychainError(status)
        }
    }

    private func load(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return string
    }
}

enum CredentialError: LocalizedError {
    case encodingFailed
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode credentials"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        }
    }
}
