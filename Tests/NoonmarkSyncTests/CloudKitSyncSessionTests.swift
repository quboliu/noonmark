import CloudKit
@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class CloudKitSyncSessionTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(zoneName: "NoonmarkUserDataV1")

    func testLocalStagePersistsBeforeProvidingCloudRecord() async throws {
        let persistence = SessionPersistence()
        let codec = CloudKitSyncRecordCodec(zoneID: zoneID)
        let session = CloudKitSyncSession(
            persistence: persistence,
            codec: codec
        )
        let local = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-a"
        )

        let pendingIDs = try await session.stageLocal([local])
        let provided = try await session.cloudRecord(
            for: codec.recordID(for: local.id)
        )
        let persisted = await persistence.current
        let saveCount = await persistence.saveCount

        XCTAssertEqual(pendingIDs, [codec.recordID(for: local.id)])
        XCTAssertEqual(try provided.map(codec.decode), local)
        XCTAssertEqual(persisted.records.map(\.record), [local])
        XCTAssertEqual(saveCount, 1)
    }

    func testFetchedBatchIsAtomicWhenOneRecordIsInvalid() async throws {
        let persistence = SessionPersistence()
        let codec = CloudKitSyncRecordCodec(zoneID: zoneID)
        let session = CloudKitSyncSession(
            persistence: persistence,
            codec: codec
        )
        let baseline = try preferenceRecord(
            theme: .coolGray,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-a"
        )
        _ = try await session.stageLocal([baseline])
        let valid = try codec.encode(try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            deviceID: "mac-b"
        ))
        let invalid = try codec.encode(baseline)
        invalid["wireSHA256"] = "tampered" as CKRecordValue
        let saveCountBefore = await persistence.saveCount

        do {
            _ = try await session.applyFetched([valid, invalid])
            XCTFail("one invalid CloudKit record must reject the whole fetched batch")
        } catch {
            XCTAssertEqual(
                error as? CloudKitSyncRecordCodecError,
                .digestMismatch
            )
        }

        let recordsAfterFailure = try await session.records()
        XCTAssertEqual(recordsAfterFailure, [baseline])
        let saveCountAfter = await persistence.saveCount
        XCTAssertEqual(saveCountAfter, saveCountBefore)
    }

    func testPersistenceFailureDoesNotPublishStagedLocalRecord() async throws {
        let persistence = SessionPersistence()
        await persistence.failNextSave()
        let session = CloudKitSyncSession(
            persistence: persistence,
            codec: CloudKitSyncRecordCodec(zoneID: zoneID)
        )
        let local = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-a"
        )

        do {
            _ = try await session.stageLocal([local])
            XCTFail("staging must fail when durable persistence fails")
        } catch {
            XCTAssertEqual(error as? SessionPersistence.Failure, .injected)
        }

        let recordsAfterFailure = try await session.records()
        XCTAssertTrue(recordsAfterFailure.isEmpty)
    }

    func testAccountSwitchFailsClosedWithoutClearingMirror() async throws {
        let persistence = SessionPersistence()
        let session = CloudKitSyncSession(
            persistence: persistence,
            codec: CloudKitSyncRecordCodec(zoneID: zoneID)
        )
        let local = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-a"
        )
        _ = try await session.stageLocal([local])
        try await session.bindAccount(recordName: "account-a")

        do {
            try await session.bindAccount(recordName: "account-b")
            XCTFail("account switch must require an explicit reset")
        } catch {
            XCTAssertEqual(
                error as? CloudKitSyncEngineTransportError,
                .accountChanged(previous: "account-a", current: "account-b")
            )
        }

        let recordsAfterSwitch = try await session.records()
        XCTAssertEqual(recordsAfterSwitch, [local])
        let persisted = await persistence.current
        XCTAssertEqual(persisted.accountRecordName, "account-a")
    }

    func testFetchedServerSystemFieldsAreReusedForNextSave() async throws {
        let persistence = SessionPersistence()
        let codec = CloudKitSyncRecordCodec(zoneID: zoneID)
        let systemFieldsCodec = CloudKitRecordSystemFieldsCodec()
        let session = CloudKitSyncSession(
            persistence: persistence,
            codec: codec,
            systemFieldsCodec: systemFieldsCodec
        )
        let server = try codec.encode(try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            deviceID: "mac-server"
        ))

        _ = try await session.applyFetched([server])
        let candidate = try await session.cloudRecord(for: server.recordID)
        let provided = try XCTUnwrap(candidate)

        XCTAssertEqual(provided.recordID, server.recordID)
        XCTAssertEqual(provided.recordType, server.recordType)
        XCTAssertEqual(
            try systemFieldsCodec.encode(provided),
            try systemFieldsCodec.encode(server)
        )
    }

    func testRemoteDeletionBlockSurvivesSessionRestart() async throws {
        let persistence = SessionPersistence()
        let firstSession = CloudKitSyncSession(
            persistence: persistence,
            codec: CloudKitSyncRecordCodec(zoneID: zoneID)
        )
        try await firstSession.block(
            .unexpectedRemoteRecordDeletion("sync-deleted")
        )
        let restartedSession = CloudKitSyncSession(
            persistence: persistence,
            codec: CloudKitSyncRecordCodec(zoneID: zoneID)
        )

        do {
            try await restartedSession.blockingErrorIfPresent()
            XCTFail("a remote deletion block must survive restart")
        } catch {
            XCTAssertEqual(
                error as? CloudKitSyncEngineTransportError,
                .unexpectedRemoteRecordDeletion("sync-deleted")
            )
        }
    }

    func testCloudKitScopeChangeFailsClosedWithoutClearingMirror() async throws {
        let persistence = SessionPersistence()
        let session = CloudKitSyncSession(
            persistence: persistence,
            codec: CloudKitSyncRecordCodec(zoneID: zoneID)
        )
        let originalScope = CloudKitSyncScopeIdentity(
            containerIdentifier: "iCloud.app.noonmark.mac",
            zoneName: "NoonmarkUserDataV1",
            environment: .development
        )
        let changedScope = CloudKitSyncScopeIdentity(
            containerIdentifier: "iCloud.app.noonmark.mac",
            zoneName: "NoonmarkUserDataV1",
            environment: .production
        )
        let local = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-a"
        )
        try await session.bindScope(originalScope)
        _ = try await session.stageLocal([local])

        do {
            try await session.bindScope(changedScope)
            XCTFail("CloudKit state must never cross container environments")
        } catch {
            XCTAssertEqual(
                error as? CloudKitSyncEngineTransportError,
                .syncScopeChanged(
                    previous: originalScope,
                    current: changedScope
                )
            )
        }

        let persisted = await persistence.current
        XCTAssertEqual(persisted.scope, originalScope)
        XCTAssertEqual(persisted.records.map(\.record), [local])
    }

    func testUnscopedPersistedStateIsNotAdoptedIntoACloudKitEnvironment() async throws {
        let local = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-a"
        )
        let unscoped = try CloudKitSyncPersistenceSnapshot(
            records: [
                CloudKitMirroredSyncRecord(
                    record: local,
                    serverRecordSystemFields: nil
                )
            ]
        )
        let persistence = SessionPersistence(current: unscoped)
        let session = CloudKitSyncSession(
            persistence: persistence,
            codec: CloudKitSyncRecordCodec(zoneID: zoneID)
        )

        do {
            try await session.bindScope(CloudKitSyncScopeIdentity(
                containerIdentifier: "iCloud.app.noonmark.mac",
                zoneName: "NoonmarkUserDataV1",
                environment: .development
            ))
            XCTFail("unscoped engine data must not be adopted as current state")
        } catch {
            XCTAssertEqual(
                error as? CloudKitSyncPersistenceError,
                .invalidSnapshot
            )
        }

        let persisted = await persistence.current
        XCTAssertEqual(persisted, unscoped)
    }

    func testConcurrentSessionMutationsWaitForTheCurrentDurableCommit() async throws {
        let persistence = SuspendingSessionPersistence()
        let session = CloudKitSyncSession(
            persistence: persistence,
            codec: CloudKitSyncRecordCodec(zoneID: zoneID)
        )
        let firstRecord = try taskChainRecord()
        let secondRecord = try taskChainRecord()

        let firstMutation = Task {
            _ = try await session.stageLocal([firstRecord])
        }
        try await persistence.waitUntilFirstSaveStarts()

        let secondMutation = Task {
            _ = try await session.stageLocal([secondRecord])
        }
        try await Task.sleep(for: .milliseconds(20))

        let savesBeforeRelease = await persistence.saveInvocationCount
        XCTAssertEqual(
            savesBeforeRelease,
            1,
            "a second session transaction must not enter persistence while the first commit is suspended"
        )

        await persistence.releaseFirstSave()
        _ = try await firstMutation.value
        _ = try await secondMutation.value

        let sessionRecordIDs = await Set(try session.records().map(\.id))
        XCTAssertEqual(
            sessionRecordIDs,
            Set([firstRecord.id, secondRecord.id])
        )
        let persisted = await persistence.current
        XCTAssertEqual(
            Set(persisted.records.map(\.record.id)),
            Set([firstRecord.id, secondRecord.id])
        )
    }

    private func preferenceRecord(
        theme: AppTheme,
        modifiedAt: Date,
        deviceID: String
    ) throws -> SyncRecord {
        try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: theme,
                language: .chinese,
                updatedAt: modifiedAt
            ),
            modifiedBy: SyncDeviceID(deviceID)
        )
    }

    private func taskChainRecord() throws -> SyncRecord {
        try SyncRecordMapper().record(
            for: TaskChain(
                now: Date(timeIntervalSinceReferenceDate: 10)
            ),
            modifiedBy: SyncDeviceID("mac-a")
        )
    }
}

private actor SessionPersistence: CloudKitSyncPersistence {
    enum Failure: Error, Equatable {
        case injected
    }

    private(set) var current: CloudKitSyncPersistenceSnapshot = .empty
    private(set) var saveCount = 0
    private var shouldFailNextSave = false

    init(current: CloudKitSyncPersistenceSnapshot = .empty) {
        self.current = current
    }

    func load() async throws -> CloudKitSyncPersistenceSnapshot {
        current
    }

    func save(_ snapshot: CloudKitSyncPersistenceSnapshot) async throws {
        if shouldFailNextSave {
            shouldFailNextSave = false
            throw Failure.injected
        }
        current = snapshot
        saveCount += 1
    }

    func failNextSave() {
        shouldFailNextSave = true
    }
}

private actor SuspendingSessionPersistence: CloudKitSyncPersistence {
    enum Failure: Error {
        case firstSaveDidNotStart
    }

    private(set) var current: CloudKitSyncPersistenceSnapshot = .empty
    private(set) var saveInvocationCount = 0
    private var firstSaveContinuation: CheckedContinuation<Void, Never>?

    func load() async throws -> CloudKitSyncPersistenceSnapshot {
        current
    }

    func save(_ snapshot: CloudKitSyncPersistenceSnapshot) async throws {
        saveInvocationCount += 1
        if saveInvocationCount == 1 {
            await withCheckedContinuation { continuation in
                firstSaveContinuation = continuation
            }
        }
        current = snapshot
    }

    func waitUntilFirstSaveStarts() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while saveInvocationCount == 0 {
            guard clock.now < deadline else {
                throw Failure.firstSaveDidNotStart
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstSave() {
        firstSaveContinuation?.resume()
        firstSaveContinuation = nil
    }
}
