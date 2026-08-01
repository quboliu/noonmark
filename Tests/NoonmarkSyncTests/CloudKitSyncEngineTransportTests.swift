@testable import NoonmarkSync
import XCTest

final class CloudKitSyncEngineTransportTests: XCTestCase {
    func testConfigurationRejectsInvalidContainerIdentifiers() {
        XCTAssertThrowsError(
            try CloudKitSyncEngineTransport(
                containerIdentifier: "not-an-icloud-container",
                persistence: TransportPersistence(),
                zoneName: CloudKitSyncEngineTransport.defaultZoneName,
                automaticallySync: false
            )
        ) { error in
            XCTAssertEqual(
                error as? CloudKitSyncEngineTransportError,
                .cloudKitFailure("invalid CloudKit container or zone identifier")
            )
        }
    }

    func testConstructionIsLazyAndDoesNotTouchCloudKit() async throws {
        let persistence = TransportPersistence()
        let transport = try CloudKitSyncEngineTransport(
            containerIdentifier: "iCloud.app.noonmark.mac",
            persistence: persistence,
            zoneName: CloudKitSyncEngineTransport.defaultZoneName,
            automaticallySync: false
        )

        let containerIdentifier = await transport.containerIdentifier
        let zoneID = await transport.zoneID
        let loadCount = await persistence.loadCount()
        XCTAssertEqual(containerIdentifier, "iCloud.app.noonmark.mac")
        XCTAssertEqual(zoneID.zoneName, "NoonmarkUserDataV1")
        XCTAssertEqual(loadCount, 0)
    }

    func testCurrentAdHocProcessRejectsCloudKitBeforeCreatingContainer() async throws {
        let transport = try CloudKitSyncEngineTransport(
            containerIdentifier: "iCloud.app.noonmark.mac",
            persistence: TransportPersistence(),
            zoneName: CloudKitSyncEngineTransport.defaultZoneName,
            automaticallySync: false
        )

        do {
            _ = try await transport.accountAvailability()
            XCTFail("the ad-hoc test process must not claim CloudKit entitlements")
        } catch {
            XCTAssertEqual(
                error as? CloudKitSyncEngineTransportError,
                .missingEntitlement(
                    CloudKitEntitlementProbe.containerIdentifiersKey
                )
            )
        }
    }

    func testEntitlementValidationRequiresEveryCKSyncEngineCapability() throws {
        XCTAssertNoThrow(try CloudKitEntitlementProbe.validate(
            containerIdentifier: "iCloud.app.noonmark.mac",
            containerIdentifiers: ["iCloud.app.noonmark.mac"],
            services: ["CloudKit"],
            environment: "Development",
            remoteNotificationsEnvironment: "development"
        ))

        XCTAssertThrowsError(try CloudKitEntitlementProbe.validate(
            containerIdentifier: "iCloud.app.noonmark.mac",
            containerIdentifiers: ["iCloud.app.noonmark.mac"],
            services: ["CloudKit"],
            environment: "Development",
            remoteNotificationsEnvironment: nil
        )) { error in
            XCTAssertEqual(
                error as? CloudKitSyncEngineTransportError,
                .missingEntitlement(
                    CloudKitEntitlementProbe.remoteNotificationsKey
                )
            )
        }

        XCTAssertThrowsError(try CloudKitEntitlementProbe.validate(
            containerIdentifier: "iCloud.app.noonmark.mac",
            containerIdentifiers: ["iCloud.app.noonmark.mac"],
            services: ["CloudKit"],
            environment: "Production",
            remoteNotificationsEnvironment: "development"
        )) { error in
            XCTAssertEqual(
                error as? CloudKitSyncEngineTransportError,
                .missingEntitlement(
                    CloudKitEntitlementProbe.remoteNotificationsKey
                )
            )
        }
    }

    func testLiveValidationCleanupRejectsTheProductionZoneBeforeCloudKitAccess() async throws {
        let transport = try CloudKitSyncEngineTransport(
            containerIdentifier: "iCloud.app.noonmark.mac",
            persistence: TransportPersistence(),
            zoneName: CloudKitSyncEngineTransport.defaultZoneName,
            automaticallySync: false
        )

        do {
            try await transport.deleteLiveValidationZone()
            XCTFail("the production record zone must never use the E2E cleanup path")
        } catch {
            XCTAssertEqual(
                error as? CloudKitSyncEngineTransportError,
                .liveValidationZoneRequired
            )
        }
    }

    func testRecordSaveFailuresNeverSilentlyRecreateRemoteDeletions() {
        XCTAssertEqual(
            CloudKitRecordSaveFailurePolicy.disposition(
                for: .unknownItem,
                zoneWasProvisioned: true
            ),
            .blockDeletedRecord
        )
        XCTAssertEqual(
            CloudKitRecordSaveFailurePolicy.disposition(
                for: .zoneNotFound,
                zoneWasProvisioned: true
            ),
            .blockDeletedZone
        )
        XCTAssertEqual(
            CloudKitRecordSaveFailurePolicy.disposition(
                for: .zoneNotFound,
                zoneWasProvisioned: false
            ),
            .provisionMissingZone
        )
    }

    func testRecordSaveFailurePolicySeparatesMergeRetryAndTerminalErrors() {
        XCTAssertEqual(
            CloudKitRecordSaveFailurePolicy.disposition(
                for: .serverRecordChanged,
                zoneWasProvisioned: true
            ),
            .mergeServerRecord
        )
        XCTAssertEqual(
            CloudKitRecordSaveFailurePolicy.disposition(
                for: .requestRateLimited,
                zoneWasProvisioned: true
            ),
            .retry
        )
        XCTAssertEqual(
            CloudKitRecordSaveFailurePolicy.disposition(
                for: .quotaExceeded,
                zoneWasProvisioned: true
            ),
            .fail
        )
    }
}

private actor TransportPersistence: CloudKitSyncPersistence {
    private var loads = 0

    func load() async throws -> CloudKitSyncPersistenceSnapshot {
        loads += 1
        return .empty
    }

    func save(_: CloudKitSyncPersistenceSnapshot) async throws {}

    func loadCount() -> Int {
        loads
    }
}
