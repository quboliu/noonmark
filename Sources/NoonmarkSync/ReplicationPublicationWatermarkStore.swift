import Foundation
import Security

public struct ReplicationPublicationWatermarkScope:
    Hashable,
    Sendable
{
    public let generationID: UUID
    public let producerID: UUID

    public init(generationID: UUID, producerID: UUID) {
        self.generationID = generationID
        self.producerID = producerID
    }
}

public struct ReplicationPublicationWatermark:
    Codable,
    Equatable,
    Sendable
{
    public let sequence: UInt64
    public let sealDigest: ReplicationDigest

    public init(sequence: UInt64, sealDigest: ReplicationDigest) {
        precondition(sequence > 0, "publication watermark sequence must be positive")
        self.sequence = sequence
        self.sealDigest = sealDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sequence = try container.decode(UInt64.self, forKey: .sequence)
        guard sequence > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .sequence,
                in: container,
                debugDescription: "publication watermark sequence must be positive"
            )
        }
        self.sequence = sequence
        sealDigest = try container.decode(
            ReplicationDigest.self,
            forKey: .sealDigest
        )
    }
}

public extension ReplicationPublicationReference {
    var publicationWatermark: ReplicationPublicationWatermark {
        ReplicationPublicationWatermark(
            sequence: sequence,
            sealDigest: sealDigest
        )
    }
}

public enum ReplicationPublicationWatermarkStoreError:
    Error,
    Equatable,
    Sendable
{
    case comparisonFailed
    case nonmonotonicReplacement
}

public protocol ReplicationPublicationWatermarkStore: Sendable {
    func load(
        in scope: ReplicationPublicationWatermarkScope
    ) throws -> ReplicationPublicationWatermark?

    func compareAndSet(
        expected: ReplicationPublicationWatermark?,
        replacement: ReplicationPublicationWatermark,
        in scope: ReplicationPublicationWatermarkScope
    ) throws
}

public final class InMemoryReplicationPublicationWatermarkStore:
    ReplicationPublicationWatermarkStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var watermarks: [
        ReplicationPublicationWatermarkScope: ReplicationPublicationWatermark
    ] = [:]

    public init() {}

    public func load(
        in scope: ReplicationPublicationWatermarkScope
    ) -> ReplicationPublicationWatermark? {
        lock.lock()
        defer { lock.unlock() }
        return watermarks[scope]
    }

    public func compareAndSet(
        expected: ReplicationPublicationWatermark?,
        replacement: ReplicationPublicationWatermark,
        in scope: ReplicationPublicationWatermarkScope
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let stored = watermarks[scope]
        if stored == replacement {
            return
        }
        guard stored == expected else {
            throw ReplicationPublicationWatermarkStoreError.comparisonFailed
        }
        try validateMonotonicReplacement(
            expected: expected,
            replacement: replacement
        )
        watermarks[scope] = replacement
    }
}

public enum KeychainReplicationPublicationWatermarkError:
    Error,
    Equatable,
    Sendable
{
    case invalidStoredWatermark
    case keychainFailure(OSStatus)
}

public final class KeychainReplicationPublicationWatermarkStore:
    ReplicationPublicationWatermarkStore,
    @unchecked Sendable
{
    public let service: String

    private let lock = NSLock()

    public init(service: String) {
        let trimmed = service.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        precondition(trimmed.isEmpty == false, "Keychain service cannot be empty")
        self.service = trimmed
    }

    public func load(
        in scope: ReplicationPublicationWatermarkScope
    ) throws -> ReplicationPublicationWatermark? {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked(in: scope)
    }

    public func compareAndSet(
        expected: ReplicationPublicationWatermark?,
        replacement: ReplicationPublicationWatermark,
        in scope: ReplicationPublicationWatermarkScope
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let stored = try loadUnlocked(in: scope)
        if stored == replacement {
            return
        }
        guard stored == expected else {
            throw ReplicationPublicationWatermarkStoreError.comparisonFailed
        }
        try validateMonotonicReplacement(
            expected: expected,
            replacement: replacement
        )
        let data = try Self.encode(replacement)
        if stored == nil {
            var query = baseQuery(for: scope)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess {
                return
            }
            if status == errSecDuplicateItem,
               try loadUnlocked(in: scope) == replacement
            {
                return
            }
            if status == errSecDuplicateItem {
                throw ReplicationPublicationWatermarkStoreError.comparisonFailed
            }
            throw KeychainReplicationPublicationWatermarkError
                .keychainFailure(status)
        }
        let status = SecItemUpdate(
            baseQuery(for: scope) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecSuccess else {
            throw KeychainReplicationPublicationWatermarkError
                .keychainFailure(status)
        }
    }

    @_spi(Testing)
    public static func account(
        for scope: ReplicationPublicationWatermarkScope
    ) -> String {
        "replication-publication-watermark-v2."
            + scope.generationID.uuidString.lowercased() + "."
            + scope.producerID.uuidString.lowercased()
    }

    @_spi(Testing)
    public func deleteWatermarkForTesting(
        in scope: ReplicationPublicationWatermarkScope
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(baseQuery(for: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainReplicationPublicationWatermarkError
                .keychainFailure(status)
        }
    }

    private func loadUnlocked(
        in scope: ReplicationPublicationWatermarkScope
    ) throws -> ReplicationPublicationWatermark? {
        var query = baseQuery(for: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecSuccess {
                throw KeychainReplicationPublicationWatermarkError
                    .invalidStoredWatermark
            }
            throw KeychainReplicationPublicationWatermarkError
                .keychainFailure(status)
        }
        do {
            let watermark = try JSONDecoder().decode(
                ReplicationPublicationWatermark.self,
                from: data
            )
            guard try Self.encode(watermark) == data else {
                throw KeychainReplicationPublicationWatermarkError
                    .invalidStoredWatermark
            }
            return watermark
        } catch let error as KeychainReplicationPublicationWatermarkError {
            throw error
        } catch {
            throw KeychainReplicationPublicationWatermarkError
                .invalidStoredWatermark
        }
    }

    private func baseQuery(
        for scope: ReplicationPublicationWatermarkScope
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(for: scope),
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static func encode(
        _ watermark: ReplicationPublicationWatermark
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(watermark)
    }
}

private func validateMonotonicReplacement(
    expected: ReplicationPublicationWatermark?,
    replacement: ReplicationPublicationWatermark
) throws {
    guard replacement.sequence == (expected?.sequence ?? 0) + 1 else {
        throw ReplicationPublicationWatermarkStoreError
            .nonmonotonicReplacement
    }
}
