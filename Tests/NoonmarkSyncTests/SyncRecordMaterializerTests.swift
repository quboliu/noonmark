@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class SyncRecordMaterializerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testPreferenceJournalPayloadDoesNotChangeTransportCASPolicy() {
        XCTAssertFalse(
            SyncEntityType.appPreferences.requiresImmutableRecordPayload
        )
        XCTAssertFalse(
            SyncJournalEntry.hasValidJournalPayloadShape(
                entityType: .appPreferences,
                recordPayload: nil
            )
        )
        XCTAssertTrue(
            SyncJournalEntry.hasValidJournalPayloadShape(
                entityType: .appPreferences,
                recordPayload: Data([0x01])
            )
        )
    }

    func testMaterializesJournalEntryFromCurrentSnapshot() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "生成上传记录", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        let entry = SyncJournalEntry(
            entityType: .dayTrace,
            entityID: traceID.rawValue.uuidString,
            changedAt: now,
            deviceID: SyncDeviceID("mac-a")
        )

        let record = try SyncRecordMaterializer().record(for: entry, in: engine.snapshot())

        XCTAssertEqual(record.id.rawValue, "trace:\(traceID.rawValue.uuidString)")
        XCTAssertEqual(record.entityType, .dayTrace)
        XCTAssertEqual(record.modifiedByDeviceID, SyncDeviceID("mac-a"))
    }

    func testMissingEntityFailsClosed() {
        let entry = SyncJournalEntry(
            entityType: .subtask,
            entityID: UUID().uuidString,
            changedAt: now,
            deviceID: SyncDeviceID("mac-a")
        )

        XCTAssertThrowsError(try SyncRecordMaterializer().record(for: entry, in: NoonmarkEngine().snapshot())) { error in
            XCTAssertEqual(error as? SyncRecordMaterializerError, .missingEntity(.subtask, entry.entityID))
        }
    }

    func testDeleteOperationFailsClosedUntilTombstonesExist() {
        let entry = SyncJournalEntry(
            entityType: .day,
            entityID: today.description,
            operation: .delete,
            changedAt: now,
            deviceID: SyncDeviceID("mac-a")
        )

        XCTAssertThrowsError(try SyncRecordMaterializer().record(for: entry, in: NoonmarkEngine().snapshot())) { error in
            XCTAssertEqual(error as? SyncRecordMaterializerError, .unsupportedDelete(.day, today.description))
        }
    }

    func testClassificationCommitMaterializesFromImmutableJournalPayload() throws {
        let envelope = try makeClassificationEnvelope()
        let payload = try envelope.canonicalData()
        let entry = SyncJournalEntry(
            entityType: .classificationCommit,
            entityID: envelope.changeRecord.id.uuidString,
            changedAt: envelope.changeRecord.committedAt,
            deviceID: SyncDeviceID("mac-a"),
            recordPayload: payload
        )

        let record = try SyncRecordMaterializer().record(
            for: entry,
            in: NoonmarkEngine().snapshot()
        )

        XCTAssertEqual(record.entityType, .classificationCommit)
        XCTAssertEqual(record.payload, payload)
        XCTAssertEqual(record.modifiedAt, envelope.changeRecord.committedAt)
    }

    func testMalformedClassificationJournalPayloadFailsClosed() {
        let recordID = UUID(uuidString: "35000000-0000-0000-0000-000000000001")!
        let entry = SyncJournalEntry(
            entityType: .classificationCommit,
            entityID: recordID.uuidString,
            changedAt: now,
            deviceID: SyncDeviceID("mac-a"),
            recordPayload: Data("not-an-envelope".utf8)
        )

        XCTAssertThrowsError(
            try SyncRecordMaterializer().record(
                for: entry,
                in: NoonmarkEngine().snapshot()
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncRecordMaterializerError,
                .invalidImmutablePayload(.classificationCommit, recordID.uuidString)
            )
        }
    }

    func testTraceClassificationEventMaterializesFromImmutableJournalPayload() throws {
        let event = TraceClassificationSnapshot(
            id: UUID(uuidString: "76000000-0000-0000-0000-000000000001")!,
            traceID: DayTraceID(
                UUID(uuidString: "76000000-0000-0000-0000-000000000002")!
            ),
            status: .unfinished,
            category: nil,
            labels: [],
            capturedAt: now,
            revision: 1
        )
        let envelope = try TraceClassificationEventEnvelope(
            event: event,
            predecessorEventID: nil
        )
        let payload = try envelope.canonicalData()
        let entry = SyncJournalEntry(
            entityType: .traceClassificationEvent,
            entityID: event.id.uuidString,
            changedAt: event.capturedAt,
            deviceID: SyncDeviceID("mac-a"),
            recordPayload: payload
        )

        let record = try SyncRecordMaterializer().record(
            for: entry,
            in: NoonmarkEngine().snapshot()
        )

        XCTAssertEqual(record.entityType, .traceClassificationEvent)
        XCTAssertEqual(record.payload, payload)
        XCTAssertEqual(record.modifiedAt, event.capturedAt)
        XCTAssertEqual(
            try SyncRecordMapper().decodeTraceClassificationEvent(record),
            envelope
        )
    }

    func testPreferenceJournalMaterializesItsHistoricalMutationInsteadOfCurrentSnapshot() throws {
        let deviceID = SyncDeviceID("mac-preferences")
        let firstClock = now.addingTimeInterval(10)
        let secondClock = now.addingTimeInterval(20)
        let engine = NoonmarkEngine()
        let base = engine.snapshot()
        try engine.updateTheme(
            .warmPaper,
            writerID: deviceID.rawValue,
            now: firstClock
        )
        let firstSnapshot = engine.snapshot()
        let firstEntry = try XCTUnwrap(
            try SyncSnapshotDiffer().journalEntries(
                from: base,
                to: firstSnapshot,
                changedAt: firstClock,
                deviceID: deviceID
            ).first
        )
        try engine.updateLanguage(
            .english,
            writerID: deviceID.rawValue,
            now: secondClock
        )

        let record = try SyncRecordMaterializer().record(
            for: firstEntry,
            in: engine.snapshot()
        )
        let envelope = try SyncRecordMapper().decodeAppPreferences(record)

        XCTAssertEqual(record.modifiedByDeviceID, deviceID)
        XCTAssertEqual(record.payload, firstEntry.recordPayload)
        XCTAssertEqual(envelope.theme, .warmPaper)
        XCTAssertEqual(envelope.language, .chinese)
        XCTAssertEqual(
            envelope.updatedAt.timeIntervalSinceReferenceDate.bitPattern,
            firstClock.timeIntervalSinceReferenceDate.bitPattern
        )
    }

    func testPreferenceJournalRejectsMalformedOrClockMismatchedPayload() throws {
        let mapper = SyncRecordMapper()
        let validRecord = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: now
            ),
            modifiedBy: SyncDeviceID("mac-preferences")
        )
        let malformed = SyncJournalEntry(
            entityType: .appPreferences,
            entityID: "default",
            changedAt: now,
            deviceID: SyncDeviceID("mac-preferences"),
            recordPayload: Data("not-canonical-json".utf8)
        )
        let mismatched = SyncJournalEntry(
            entityType: .appPreferences,
            entityID: "default",
            changedAt: now.addingTimeInterval(1),
            deviceID: SyncDeviceID("mac-preferences"),
            recordPayload: validRecord.payload
        )

        for entry in [malformed, mismatched] {
            XCTAssertThrowsError(
                try SyncRecordMaterializer().record(
                    for: entry,
                    in: NoonmarkEngine().snapshot()
                )
            ) { error in
                XCTAssertEqual(
                    error as? SyncRecordMaterializerError,
                    .invalidJournalPayload(.appPreferences, "default")
                )
            }
        }
    }

    private func makeClassificationEnvelope() throws -> ClassificationCommitEnvelope {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "物化分类提交", now: now)
        let before = engine.snapshot().classifications
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "工程", colorHex: "#2A6FDB"),
                    labels: [.new(name: "同步", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(uuidString: "35000000-0000-0000-0000-000000000002")!,
            now: now
        )
        let receipt = try engine.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(uuidString: "35000000-0000-0000-0000-000000000003")!
            ),
            now: now
        )
        let after = engine.snapshot().classifications
        let record = try XCTUnwrap(
            after.changeRecords.first { $0.id == receipt.changeRecordID }
        )
        return try ClassificationCommitEnvelope(
            before: before,
            after: after,
            changeRecord: record
        )
    }
}
