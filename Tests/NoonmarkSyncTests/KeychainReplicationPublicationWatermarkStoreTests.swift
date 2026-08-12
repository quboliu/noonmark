@_spi(Testing) @testable import NoonmarkSync
import Security
import XCTest

final class KeychainReplicationPublicationWatermarkStoreTests: XCTestCase {
    func testKeychainPersistsThisDeviceOnlyWatermarkAndRejectsStaleCAS()
        throws
    {
        let service = "app.noonmark.test.replication-watermark.\(UUID())"
        let store = KeychainReplicationPublicationWatermarkStore(
            service: service
        )
        let scope = ReplicationPublicationWatermarkScope(
            generationID: UUID(
                uuidString: "81000000-0000-0000-0000-000000000001"
            )!,
            producerID: UUID(
                uuidString: "82000000-0000-0000-0000-000000000001"
            )!
        )
        addTeardownBlock {
            try? store.deleteWatermarkForTesting(in: scope)
        }
        let first = ReplicationPublicationWatermark(
            sequence: 1,
            sealDigest: ReplicationDigest(
                rawValue: String(repeating: "a", count: 64)
            )!
        )
        let second = ReplicationPublicationWatermark(
            sequence: 2,
            sealDigest: ReplicationDigest(
                rawValue: String(repeating: "b", count: 64)
            )!
        )

        guard currentApplicationIdentifier() != nil else {
            XCTAssertNil(try store.load(in: scope))
            XCTAssertThrowsError(
                try store.compareAndSet(
                    expected: nil,
                    replacement: first,
                    in: scope
                )
            ) { error in
                XCTAssertEqual(
                    error as? KeychainReplicationPublicationWatermarkError,
                    .keychainFailure(errSecMissingEntitlement)
                )
            }
            return
        }

        XCTAssertNil(try store.load(in: scope))
        try store.compareAndSet(
            expected: nil,
            replacement: first,
            in: scope
        )
        try store.compareAndSet(
            expected: nil,
            replacement: first,
            in: scope
        )
        XCTAssertEqual(try store.load(in: scope), first)
        XCTAssertTrue(
            CFEqual(
                try storedAccessibility(service: service, scope: scope),
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            )
        )

        XCTAssertThrowsError(
            try store.compareAndSet(
                expected: nil,
                replacement: second,
                in: scope
            )
        )
        XCTAssertEqual(try store.load(in: scope), first)

        try store.compareAndSet(
            expected: first,
            replacement: second,
            in: scope
        )
        XCTAssertEqual(try store.load(in: scope), second)
        XCTAssertThrowsError(
            try store.compareAndSet(
                expected: second,
                replacement: first,
                in: scope
            )
        )
        XCTAssertEqual(try store.load(in: scope), second)
    }

    func testInMemoryStoreUsesTheSameIdempotentMonotonicCASContract() throws {
        let store = InMemoryReplicationPublicationWatermarkStore()
        let scope = ReplicationPublicationWatermarkScope(
            generationID: UUID(),
            producerID: UUID()
        )
        let first = ReplicationPublicationWatermark(
            sequence: 1,
            sealDigest: ReplicationDigest(
                rawValue: String(repeating: "c", count: 64)
            )!
        )
        let second = ReplicationPublicationWatermark(
            sequence: 2,
            sealDigest: ReplicationDigest(
                rawValue: String(repeating: "d", count: 64)
            )!
        )

        try store.compareAndSet(
            expected: nil,
            replacement: first,
            in: scope
        )
        try store.compareAndSet(
            expected: nil,
            replacement: first,
            in: scope
        )
        XCTAssertThrowsError(
            try store.compareAndSet(
                expected: nil,
                replacement: second,
                in: scope
            )
        )
        try store.compareAndSet(
            expected: first,
            replacement: second,
            in: scope
        )
        XCTAssertEqual(store.load(in: scope), second)
    }

    private func storedAccessibility(
        service: String,
        scope: ReplicationPublicationWatermarkScope
    ) throws -> CFTypeRef {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String:
                KeychainReplicationPublicationWatermarkStore.account(
                    for: scope
                ),
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let attributes = item as? NSDictionary,
              let accessibility = attributes.object(
                  forKey: kSecAttrAccessible
              )
        else {
            throw KeychainReplicationPublicationWatermarkError
                .keychainFailure(status)
        }
        return accessibility as CFTypeRef
    }

    private func currentApplicationIdentifier() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(
            task,
            "com.apple.application-identifier" as CFString,
            nil
        ) as? String
    }
}
