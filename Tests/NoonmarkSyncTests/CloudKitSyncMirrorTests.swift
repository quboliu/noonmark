@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class CloudKitSyncMirrorTests: XCTestCase {
    func testOlderServerRecordKeepsLocalWinnerAndRequestsReupload() throws {
        let local = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            deviceID: "mac-local"
        )
        let server = try preferenceRecord(
            theme: .coolGray,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-server"
        )
        var mirror = try CloudKitSyncMirror(snapshot: .empty)
        _ = try mirror.mergeLocal([local])

        let result = try mirror.mergeServer([
            CloudKitMirroredSyncRecord(
                record: server,
                serverRecordSystemFields: Data([0x11])
            )
        ])

        XCTAssertEqual(result.recordIDsNeedingUpload, [local.id])
        XCTAssertEqual(mirror.records, [local])
        XCTAssertEqual(
            mirror.mirroredRecord(for: local.id)?.serverRecordSystemFields,
            Data([0x11])
        )
    }

    func testNewerServerRecordBecomesCanonicalWithoutReupload() throws {
        let local = try preferenceRecord(
            theme: .coolGray,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-local"
        )
        let server = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            deviceID: "mac-server"
        )
        var mirror = try CloudKitSyncMirror(snapshot: .empty)
        _ = try mirror.mergeLocal([local])

        let result = try mirror.mergeServer([
            CloudKitMirroredSyncRecord(
                record: server,
                serverRecordSystemFields: Data([0x22])
            )
        ])

        XCTAssertTrue(result.recordIDsNeedingUpload.isEmpty)
        XCTAssertEqual(mirror.records, [server])
    }

    func testLocalMergePreservesLastKnownServerSystemFields() throws {
        let first = try preferenceRecord(
            theme: .coolGray,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-a"
        )
        let second = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            deviceID: "mac-a"
        )
        let snapshot = try CloudKitSyncPersistenceSnapshot(
            records: [
                CloudKitMirroredSyncRecord(
                    record: first,
                    serverRecordSystemFields: Data([0x33])
                )
            ]
        )
        var mirror = try CloudKitSyncMirror(snapshot: snapshot)

        let result = try mirror.mergeLocal([second])

        XCTAssertEqual(result.recordIDsNeedingUpload, [second.id])
        XCTAssertEqual(mirror.records, [second])
        XCTAssertEqual(
            mirror.mirroredRecord(for: second.id)?.serverRecordSystemFields,
            Data([0x33])
        )
    }

    func testServerBatchCanonicalizesPreferenceWinnerAndItsSystemFields() throws {
        let first = try preferenceRecord(
            theme: .coolGray,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-first"
        )
        let final = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            deviceID: "mac-final"
        )
        var mirror = try CloudKitSyncMirror(snapshot: .empty)

        let result = try mirror.mergeServer([
            CloudKitMirroredSyncRecord(
                record: first,
                serverRecordSystemFields: Data([0x11])
            ),
            CloudKitMirroredSyncRecord(
                record: final,
                serverRecordSystemFields: Data([0x22])
            )
        ])

        XCTAssertTrue(result.recordIDsNeedingUpload.isEmpty)
        XCTAssertEqual(mirror.records, [final])
        XCTAssertEqual(
            mirror.mirroredRecord(for: final.id)?.serverRecordSystemFields,
            Data([0x22])
        )
        XCTAssertEqual(
            try mirror.persistenceSnapshot(
                engineState: nil,
                accountRecordName: nil
            ).records.count,
            1
        )
    }

    func testLocalPreferenceBatchCanonicalizesOneWinnerAndPreservesSystemFields() throws {
        let remote = try preferenceRecord(
            theme: .coolGray,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 5),
            deviceID: "mac-remote"
        )
        let first = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-local"
        )
        let final = try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: Date(timeIntervalSinceReferenceDate: 20)
            ),
            modifiedBy: SyncDeviceID("mac-local")
        )
        let snapshot = try CloudKitSyncPersistenceSnapshot(
            records: [
                CloudKitMirroredSyncRecord(
                    record: remote,
                    serverRecordSystemFields: Data([0x33])
                )
            ]
        )

        for records in [[first, final], [final, first]] {
            var mirror = try CloudKitSyncMirror(snapshot: snapshot)

            let result = try mirror.mergeLocal(records)

            XCTAssertEqual(result.recordIDsNeedingUpload, [final.id])
            XCTAssertEqual(mirror.records, [final])
            XCTAssertEqual(
                mirror.mirroredRecord(for: final.id)?
                    .serverRecordSystemFields,
                Data([0x33])
            )
            XCTAssertEqual(
                try mirror.persistenceSnapshot(
                    engineState: nil,
                    accountRecordName: nil
                ).records.count,
                1
            )
        }
    }

    func testServerSyntheticChainMergeRequestsReuploadInBothOrders() throws {
        let now = Date(timeIntervalSinceReferenceDate: 10)
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "CloudKit synthetic merge",
            now: now
        )
        let baseline = base.snapshot()
        let left = try NoonmarkEngine(snapshot: baseline)
        _ = try left.appendPoolNote(
            chainID: chainID,
            body: "left note",
            now: now.addingTimeInterval(1)
        )
        let right = try NoonmarkEngine(snapshot: baseline)
        _ = try right.appendPoolNote(
            chainID: chainID,
            body: "right note",
            now: now.addingTimeInterval(2)
        )
        let mapper = SyncRecordMapper()
        let leftRecord = try mapper.record(
            for: try XCTUnwrap(left.chains[chainID]),
            modifiedBy: SyncDeviceID("mac-left")
        )
        let rightRecord = try mapper.record(
            for: try XCTUnwrap(right.chains[chainID]),
            modifiedBy: SyncDeviceID("mac-right")
        )

        for candidates in [
            [
                CloudKitMirroredSyncRecord(
                    record: leftRecord,
                    serverRecordSystemFields: Data([0x11])
                ),
                CloudKitMirroredSyncRecord(
                    record: rightRecord,
                    serverRecordSystemFields: Data([0x22])
                )
            ],
            [
                CloudKitMirroredSyncRecord(
                    record: rightRecord,
                    serverRecordSystemFields: Data([0x22])
                ),
                CloudKitMirroredSyncRecord(
                    record: leftRecord,
                    serverRecordSystemFields: Data([0x11])
                )
            ]
        ] {
            var mirror = try CloudKitSyncMirror(snapshot: .empty)

            let result = try mirror.mergeServer(candidates)
            let record = try XCTUnwrap(mirror.records.first)
            let chain = try mapper.decodeTaskChain(record)

            XCTAssertEqual(result.recordIDsNeedingUpload, [record.id])
            XCTAssertEqual(
                Set(chain.activeNoteEntries.map(\.body)),
                ["left note", "right note"]
            )
            XCTAssertEqual(
                mirror.mirroredRecord(for: record.id)?
                    .serverRecordSystemFields,
                Data([0x22])
            )
        }
    }

    func testServerDuplicateExactRecordWithAmbiguousSystemFieldsFailsClosed() throws {
        let record = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            deviceID: "mac-final"
        )

        for fields in [
            [Data([0x11]), Data([0x22])],
            [Data([0x22]), Data([0x11])]
        ] {
            var mirror = try CloudKitSyncMirror(snapshot: .empty)

            XCTAssertThrowsError(try mirror.mergeServer([
                CloudKitMirroredSyncRecord(
                    record: record,
                    serverRecordSystemFields: fields[0]
                ),
                CloudKitMirroredSyncRecord(
                    record: record,
                    serverRecordSystemFields: fields[1]
                )
            ]))
            XCTAssertTrue(mirror.records.isEmpty)
        }
    }

    func testServerBatchFailureRollsBackRecordsMergedEarlierInTheBatch() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "CloudKit batch rollback",
            now: Date(timeIntervalSinceReferenceDate: 10)
        )
        _ = try engine.scheduleFromPool(
            chainID: chainID,
            date: LocalDate("2026-07-17"),
            today: LocalDate("2026-07-17"),
            now: Date(timeIntervalSinceReferenceDate: 11)
        )
        let chainRecord = try SyncRecordMapper().record(
            for: try XCTUnwrap(engine.snapshot().chains.first),
            modifiedBy: SyncDeviceID("mac-chain")
        )
        let baselineRecord = try SyncRecordMapper().record(
            for: try XCTUnwrap(engine.snapshot().days.first),
            modifiedBy: SyncDeviceID("mac-baseline")
        )
        let ambiguous = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            deviceID: "mac-preferences"
        )
        let baseline = try CloudKitSyncPersistenceSnapshot(
            records: [
                CloudKitMirroredSyncRecord(
                    record: baselineRecord,
                    serverRecordSystemFields: Data([0x01])
                )
            ]
        )

        for fields in [
            [Data([0x11]), Data([0x22])],
            [Data([0x22]), Data([0x11])]
        ] {
            var mirror = try CloudKitSyncMirror(snapshot: baseline)
            let before = try mirror.persistenceSnapshot(
                engineState: Data([0xBE, 0xEF]),
                accountRecordName: "rollback-account",
                zoneIsProvisioned: true
            )

            XCTAssertThrowsError(try mirror.mergeServer([
                CloudKitMirroredSyncRecord(
                    record: chainRecord,
                    serverRecordSystemFields: Data([0x10])
                ),
                CloudKitMirroredSyncRecord(
                    record: ambiguous,
                    serverRecordSystemFields: fields[0]
                ),
                CloudKitMirroredSyncRecord(
                    record: ambiguous,
                    serverRecordSystemFields: fields[1]
                )
            ])) { error in
                XCTAssertEqual(
                    error as? CloudKitSyncMirrorError,
                    .ambiguousServerRecordSystemFields(ambiguous.id)
                )
            }

            XCTAssertEqual(
                try mirror.persistenceSnapshot(
                    engineState: Data([0xBE, 0xEF]),
                    accountRecordName: "rollback-account",
                    zoneIsProvisioned: true
                ),
                before
            )
        }
    }

    func testMalformedPersistedCurrentRecordFailsClosedAtMirrorLoad() throws {
        var malformed = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            deviceID: "mac-corrupted"
        )
        malformed.modifiedAt = Date(
            timeIntervalSinceReferenceDate: Double(20).nextUp
        )
        let snapshot = try CloudKitSyncPersistenceSnapshot(
            records: [
                CloudKitMirroredSyncRecord(
                    record: malformed,
                    serverRecordSystemFields: Data([0x33])
                )
            ]
        )

        XCTAssertThrowsError(try CloudKitSyncMirror(snapshot: snapshot))
    }

    func testImmutableIdentityCollisionFailsClosed() throws {
        let id = SyncRecordID("classification-commit:one")
        let first = SyncRecord(
            id: id,
            entityType: .classificationCommit,
            entityID: "one",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            modifiedByDeviceID: SyncDeviceID("mac-a"),
            payload: Data("first".utf8)
        )
        let second = SyncRecord(
            id: id,
            entityType: .classificationCommit,
            entityID: "one",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            modifiedByDeviceID: SyncDeviceID("mac-a"),
            payload: Data("second".utf8)
        )
        var mirror = try CloudKitSyncMirror(snapshot: .empty)
        _ = try mirror.mergeLocal([first])

        XCTAssertThrowsError(try mirror.mergeServer([
            CloudKitMirroredSyncRecord(
                record: second,
                serverRecordSystemFields: Data([0x44])
            )
        ])) { error in
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .immutableRecordCollision(recordID: id)
            )
        }
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
}
