import Foundation
import Security

public enum ZhulongSidecarKeyError: Error, Equatable {
    case invalidStoredKey
    case randomGenerationFailed(OSStatus)
    case keychainFailure(OSStatus)
}

public struct KeychainZhulongSidecarKeySource: ZhulongSidecarKeySource {
    public static let defaultService = "app.noonmark.zhulong.sidecar-key"
    public static let defaultAccount = "sidecar-encryption-key-v1"

    public let service: String
    public let account: String

    public init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKey() throws -> Data {
        switch try loadKey() {
        case let .some(key):
            return key
        case nil:
            let key = try generateKey()
            let status = SecItemAdd(addQuery(key: key) as CFDictionary, nil)
            if status == errSecSuccess {
                return key
            }
            if status == errSecDuplicateItem, let existing = try loadKey() {
                return existing
            }
            throw ZhulongSidecarKeyError.keychainFailure(status)
        }
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ZhulongSidecarKeyError.keychainFailure(status)
        }
    }

    private func loadKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw ZhulongSidecarKeyError.keychainFailure(status)
        }
        guard let key = item as? Data, key.count == 32 else {
            throw ZhulongSidecarKeyError.invalidStoredKey
        }
        return key
    }

    private func generateKey() throws -> Data {
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, bytes.count, address)
        }
        guard status == errSecSuccess else {
            throw ZhulongSidecarKeyError.randomGenerationFailed(status)
        }
        return key
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func addQuery(key: Data) -> [String: Any] {
        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }
}
