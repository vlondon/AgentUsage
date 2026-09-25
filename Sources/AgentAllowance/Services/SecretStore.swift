import Foundation
import Security

protocol SecretStore: Sendable {
    /// Returns nil when there is no entry; throws when the entry exists but cannot be read.
    func read(_ account: String) throws -> String?
    /// Stores `value` for `account`; an empty value deletes the entry.
    func write(_ value: String, for account: String) throws
}

struct KeychainSecretStore: SecretStore {
    let service: String

    init(service: String = "com.vlondon.AgentAllowance.push") {
        self.service = service
    }

    func read(_ account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Self.error(status) }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, for account: String) throws {
        let query = baseQuery(account)
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
            return
        }

        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Self.error(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw Self.error(updateStatus)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func error(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
