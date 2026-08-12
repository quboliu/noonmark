import Foundation
import NoonmarkMacRuntime
@_spi(Testing) import NoonmarkSync
import Security

@MainActor
struct ReplicationWatermarkKeychainE2EAutomation:
    LaunchAutomationRunnable
{
    private enum Mode {
        case prepare
        case advance
        case verify
    }

    private enum FailureCode: String, Error {
        case wrongRuntimeProfile = "wrong-runtime-profile"
        case unexpectedWatermark = "unexpected-watermark"
        case staleCASAccepted = "stale-cas-accepted"
        case staleCASWrongError = "stale-cas-wrong-error"
        case missingAttributes = "missing-attributes"
        case wrongAccessibility = "wrong-accessibility"
        case synchronizableItem = "synchronizable-item"
        case cleanupFailed = "cleanup-failed"
    }

    private let mode: Mode
    private let scope: ReplicationPublicationWatermarkScope
    private let resultURL: URL

    static func fromCommandLine() -> Self? {
        let mode: Mode
        if AppLaunchArguments.contains(
            "--e2e-replication-watermark-keychain-prepare"
        ) {
            mode = .prepare
        } else if AppLaunchArguments.contains(
            "--e2e-replication-watermark-keychain-advance"
        ) {
            mode = .advance
        } else if AppLaunchArguments.contains(
            "--e2e-replication-watermark-keychain-verify"
        ) {
            mode = .verify
        } else {
            return nil
        }
        guard
            let generation = AppLaunchArguments.value(
                after:
                "--e2e-replication-watermark-keychain-generation-id"
            ).flatMap(UUID.init(uuidString:)),
            let producer = AppLaunchArguments.value(
                after:
                "--e2e-replication-watermark-keychain-producer-id"
            ).flatMap(UUID.init(uuidString:)),
            let resultPath = AppLaunchArguments.value(
                after: "--e2e-replication-watermark-keychain-result-url"
            )
        else {
            return nil
        }
        return Self(
            mode: mode,
            scope: ReplicationPublicationWatermarkScope(
                generationID: generation,
                producerID: producer
            ),
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    func run(on _: NoonmarkStore) {
        let result: String
        do {
            guard try AppLaunchArguments.runtimeProfile == .e2e else {
                throw FailureCode.wrongRuntimeProfile
            }
            switch mode {
            case .prepare:
                try prepare()
                result = "ok phase=prepare sequence=1"
            case .advance:
                try advance()
                result = "ok phase=advance stale_rejected=true sequence=2 "
                    + "accessibility=after-first-unlock-this-device-only "
                    + "synchronizable=false"
            case .verify:
                try verifyAndCleanup()
                result = "ok phase=verify sequence=2 cleanup=deleted"
            }
        } catch let failure as FailureCode {
            result = "failed code=\(failure.rawValue)"
        } catch let failure as KeychainReplicationPublicationWatermarkError {
            switch failure {
            case .invalidStoredWatermark:
                result = "failed code=invalid-stored-watermark"
            case let .keychainFailure(status):
                result = "failed code=keychain-status-\(status)"
            }
        } catch {
            result = "failed code=unexpected-error"
        }
        try? Data(result.utf8).write(to: resultURL, options: .atomic)
        E2EApplicationTermination.schedule()
    }

    private func prepare() throws {
        let store = makeStore()
        guard try store.load(in: scope) == nil else {
            throw FailureCode.unexpectedWatermark
        }
        try store.compareAndSet(
            expected: nil,
            replacement: Self.first,
            in: scope
        )
        guard try store.load(in: scope) == Self.first else {
            throw FailureCode.unexpectedWatermark
        }
    }

    private func advance() throws {
        let store = makeStore()
        guard try store.load(in: scope) == Self.first else {
            throw FailureCode.unexpectedWatermark
        }
        do {
            try store.compareAndSet(
                expected: nil,
                replacement: Self.second,
                in: scope
            )
            throw FailureCode.staleCASAccepted
        } catch ReplicationPublicationWatermarkStoreError.comparisonFailed {
            // The stale compare is the required result.
        } catch {
            throw FailureCode.staleCASWrongError
        }
        guard try store.load(in: scope) == Self.first else {
            throw FailureCode.unexpectedWatermark
        }
        try store.compareAndSet(
            expected: Self.first,
            replacement: Self.second,
            in: scope
        )
        guard try store.load(in: scope) == Self.second else {
            throw FailureCode.unexpectedWatermark
        }
        try verifySecurityAttributes(service: store.service)
    }

    private func verifyAndCleanup() throws {
        let store = makeStore()
        guard try store.load(in: scope) == Self.second else {
            throw FailureCode.unexpectedWatermark
        }
        try store.compareAndSet(
            expected: Self.first,
            replacement: Self.second,
            in: scope
        )
        guard try store.load(in: scope) == Self.second else {
            throw FailureCode.unexpectedWatermark
        }
        try store.deleteWatermarkForTesting(in: scope)
        guard try store.load(in: scope) == nil else {
            throw FailureCode.cleanupFailed
        }
    }

    private func makeStore()
        -> KeychainReplicationPublicationWatermarkStore
    {
        KeychainReplicationPublicationWatermarkStore(
            service: NoonmarkRuntimeProfile.e2e
                .replicationWatermarkKeychainService
        )
    }

    private func verifySecurityAttributes(service: String) throws {
        var query = Self.baseQuery(service: service, scope: scope)
        query[kSecAttrSynchronizable as String] =
            kSecAttrSynchronizableAny
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let attributes = item as? NSDictionary
        else {
            throw FailureCode.missingAttributes
        }
        guard let accessibility = attributes.object(
            forKey: kSecAttrAccessible
        ), CFEqual(
            accessibility as CFTypeRef,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ) else {
            throw FailureCode.wrongAccessibility
        }

        var synchronizableQuery = Self.baseQuery(
            service: service,
            scope: scope
        )
        synchronizableQuery[kSecAttrSynchronizable as String] = true
        let synchronizableStatus = SecItemCopyMatching(
            synchronizableQuery as CFDictionary,
            nil
        )
        guard synchronizableStatus == errSecItemNotFound else {
            throw FailureCode.synchronizableItem
        }
    }

    private static func baseQuery(
        service: String,
        scope: ReplicationPublicationWatermarkScope
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String:
                KeychainReplicationPublicationWatermarkStore.account(
                    for: scope
                ),
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static let first = ReplicationPublicationWatermark(
        sequence: 1,
        sealDigest: ReplicationDigest(
            rawValue: String(repeating: "1", count: 64)
        )!
    )

    private static let second = ReplicationPublicationWatermark(
        sequence: 2,
        sealDigest: ReplicationDigest(
            rawValue: String(repeating: "2", count: 64)
        )!
    )
}
