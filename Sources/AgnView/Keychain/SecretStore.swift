import Foundation
import Security

protocol SecretStore {
    func get(account: String) throws -> Data?
    func set(_ data: Data, account: String) throws
    func delete(account: String) throws
}

struct KeychainError: Error, Equatable, CustomStringConvertible {
    let status: OSStatus
    var description: String { "KeychainError(status: \(status))" }
}

/// Keychain-backed store. Items are device-only and never synced.
final class KeychainStore: SecretStore {
    static let defaultService = "com.example.agnview.hub"

    private let service: String

    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    func get(account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    func set(_ data: Data, account: String) throws {
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// Volatile store for tests.
final class InMemorySecretStore: SecretStore {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    init() {}

    func get(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }

    func set(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = data
    }

    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = nil
    }
}
