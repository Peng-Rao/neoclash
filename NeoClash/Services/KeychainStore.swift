import Foundation
import Security

public enum SecretStoreError: Error, Equatable, LocalizedError {
    case notFound
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Secret not found."
        case .unexpectedStatus(let status):
            "Keychain operation failed with status \(status)."
        case .invalidData:
            "Stored secret data is invalid."
        }
    }
}

public protocol SecretStore: Sendable {
    func save(_ value: String, service: String, account: String) throws
    func load(service: String, account: String) throws -> String
    func delete(service: String, account: String) throws
}

public struct KeychainStore: SecretStore {
    public init() {}

    public func save(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(service: service, account: account)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    public func load(service: String, account: String) throws -> String {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            throw SecretStoreError.notFound
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.invalidData
        }
        return value
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        if status == errSecItemNotFound {
            return
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(_ value: String, service: String, account: String) {
        lock.withLock {
            storage[key(service: service, account: account)] = value
        }
    }

    public func load(service: String, account: String) throws -> String {
        try lock.withLock {
            guard let value = storage[key(service: service, account: account)] else {
                throw SecretStoreError.notFound
            }
            return value
        }
    }

    public func delete(service: String, account: String) {
        lock.withLock {
            storage.removeValue(forKey: key(service: service, account: account))
        }
    }

    private func key(service: String, account: String) -> String {
        "\(service)::\(account)"
    }
}

