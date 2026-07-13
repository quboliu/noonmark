@testable import SuntraceCore
@testable import SuntraceSync
import XCTest

final class SyncRecordMaterializerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testMaterializesJournalEntryFromCurrentSnapshot() throws {
        let engine = SuntraceEngine()
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

        XCTAssertThrowsError(try SyncRecordMaterializer().record(for: entry, in: SuntraceEngine().snapshot())) { error in
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

        XCTAssertThrowsError(try SyncRecordMaterializer().record(for: entry, in: SuntraceEngine().snapshot())) { error in
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
            in: SuntraceEngine().snapshot()
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
                in: SuntraceEngine().snapshot()
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
            in: SuntraceEngine().snapshot()
        )

        XCTAssertEqual(record.entityType, .traceClassificationEvent)
        XCTAssertEqual(record.payload, payload)
        XCTAssertEqual(record.modifiedAt, event.capturedAt)
        XCTAssertEqual(
            try SyncRecordMapper().decodeTraceClassificationEvent(record),
            envelope
        )
    }

    private func makeClassificationEnvelope() throws -> ClassificationCommitEnvelope {
        let engine = SuntraceEngine()
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
