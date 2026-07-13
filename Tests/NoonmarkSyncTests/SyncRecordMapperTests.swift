@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class SyncRecordMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testSnapshotRecordsRoundTripThroughGenericPayloads() throws {
        let engine = try makeEngine()
        let mapper = SyncRecordMapper()
        let deviceID = SyncDeviceID("mac-a")

        let records = try mapper.records(from: engine.snapshot(), modifiedBy: deviceID, preferencesUpdatedAt: now)

        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("day:") && $0.entityType == .day })
        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("chain:") && $0.entityType == .taskChain })
        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("definition:") && $0.entityType == .taskDefinition })
        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("trace:") && $0.entityType == .dayTrace })
        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("subtask:") && $0.entityType == .subtask })
        XCTAssertTrue(records.contains { $0.id.rawValue == "preferences:default" && $0.entityType == .appPreferences })
        XCTAssertTrue(records.allSatisfy { $0.modifiedByDeviceID == deviceID })

        let traceRecord = try XCTUnwrap(records.first { $0.entityType == .dayTrace })
        let decodedTrace = try mapper.decodeDayTrace(traceRecord)

        XCTAssertEqual(decodedTrace, try XCTUnwrap(engine.snapshot().traces.first))
    }

    func testDecodeRejectsMismatchedEntityType() throws {
        let engine = try makeEngine()
        let mapper = SyncRecordMapper()
        let dayRecord = try XCTUnwrap(try mapper.records(from: engine.snapshot(), modifiedBy: SyncDeviceID("mac-a")).first { $0.entityType == .day })

        XCTAssertThrowsError(try mapper.decodeDayTrace(dayRecord)) { error in
            XCTAssertEqual(
                error as? SyncRecordMapperError,
                .entityTypeMismatch(expected: .dayTrace, actual: .day)
            )
        }
    }

    func testOrdinaryPayloadUsesRequiredCanonicalCurrentEnvelopeAndExactDates() throws {
        let mapper = SyncRecordMapper()
        let exactNow = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7)
        let chain = TaskChain(now: exactNow)
        let record = try mapper.record(
            for: chain,
            modifiedBy: SyncDeviceID("mac-current")
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: record.payload) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["formatVersion", "payload"])
        XCTAssertEqual(object["formatVersion"] as? Int, 1)
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertNil(payload["tagAssignments"])

        let restored = try mapper.decodeTaskChain(record)
        XCTAssertEqual(
            restored.createdAt.timeIntervalSinceReferenceDate.bitPattern,
            exactNow.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(
            restored.updatedAt.timeIntervalSinceReferenceDate.bitPattern,
            exactNow.timeIntervalSinceReferenceDate.bitPattern
        )
    }

    func testOrdinaryPayloadRejectsUnversionedPreviousGenerationShapes() throws {
        let mapper = SyncRecordMapper()
        let chainRecord = try mapper.record(
            for: TaskChain(now: now),
            modifiedBy: SyncDeviceID("mac-current")
        )
        let chainEnvelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: chainRecord.payload) as? [String: Any]
        )
        var previousChain = try XCTUnwrap(chainEnvelope["payload"] as? [String: Any])
        previousChain["tagAssignments"] = []
        var previousChainRecord = chainRecord
        previousChainRecord.payload = try JSONSerialization.data(
            withJSONObject: previousChain,
            options: [.sortedKeys]
        )
        assertInvalidPayload(previousChainRecord, type: .taskChain) {
            try mapper.decodeTaskChain(previousChainRecord)
        }

        let preferencesRecord = try mapper.record(
            for: AppPreferencesEnvelope(preferences: AppPreferences(), updatedAt: now),
            modifiedBy: SyncDeviceID("mac-current")
        )
        let preferencesEnvelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: preferencesRecord.payload) as? [String: Any]
        )
        var previousPreferences = try XCTUnwrap(
            preferencesEnvelope["payload"] as? [String: Any]
        )
        var preferences = try XCTUnwrap(
            previousPreferences["preferences"] as? [String: Any]
        )
        preferences["taskTags"] = []
        previousPreferences["preferences"] = preferences
        var previousPreferencesRecord = preferencesRecord
        previousPreferencesRecord.payload = try JSONSerialization.data(
            withJSONObject: previousPreferences,
            options: [.sortedKeys]
        )
        assertInvalidPayload(previousPreferencesRecord, type: .appPreferences) {
            try mapper.decodeAppPreferences(previousPreferencesRecord)
        }
    }

    func testOrdinaryPayloadRejectsUnknownVersionShapeAndNoncanonicalBytes() throws {
        let mapper = SyncRecordMapper()
        let current = try mapper.record(
            for: TaskChain(now: now),
            modifiedBy: SyncDeviceID("mac-current")
        )
        let currentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: current.payload) as? [String: Any]
        )

        var unknownVersion = currentObject
        unknownVersion["formatVersion"] = 2
        var unknownVersionRecord = current
        unknownVersionRecord.payload = try JSONSerialization.data(
            withJSONObject: unknownVersion,
            options: [.sortedKeys]
        )
        assertInvalidPayload(unknownVersionRecord, type: .taskChain) {
            try mapper.decodeTaskChain(unknownVersionRecord)
        }

        var missingVersion = currentObject
        missingVersion.removeValue(forKey: "formatVersion")
        var missingVersionRecord = current
        missingVersionRecord.payload = try JSONSerialization.data(
            withJSONObject: missingVersion,
            options: [.sortedKeys]
        )
        assertInvalidPayload(missingVersionRecord, type: .taskChain) {
            try mapper.decodeTaskChain(missingVersionRecord)
        }

        var unknownShape = currentObject
        var payload = try XCTUnwrap(unknownShape["payload"] as? [String: Any])
        payload["unexpected"] = true
        unknownShape["payload"] = payload
        var unknownShapeRecord = current
        unknownShapeRecord.payload = try JSONSerialization.data(
            withJSONObject: unknownShape,
            options: [.sortedKeys]
        )
        assertInvalidPayload(unknownShapeRecord, type: .taskChain) {
            try mapper.decodeTaskChain(unknownShapeRecord)
        }

        var prettyPrintedRecord = current
        prettyPrintedRecord.payload = try JSONSerialization.data(
            withJSONObject: currentObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        assertInvalidPayload(prettyPrintedRecord, type: .taskChain) {
            try mapper.decodeTaskChain(prettyPrintedRecord)
        }
    }

    func testClassificationCommitUsesCanonicalUnifiedTypedDeltaPayload() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "映射分类提交", now: now)
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
            interactionID: UUID(uuidString: "34000000-0000-0000-0000-000000000001")!,
            now: now
        )
        let receipt = try engine.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(uuidString: "34000000-0000-0000-0000-000000000002")!
            ),
            now: now
        )
        let after = engine.snapshot().classifications
        let changeRecord = try XCTUnwrap(
            after.changeRecords.first { $0.id == receipt.changeRecordID }
        )
        let envelope = try ClassificationCommitEnvelope(
            before: before,
            after: after,
            changeRecord: changeRecord
        )
        let mapper = SyncRecordMapper()

        let record = try mapper.record(
            for: envelope,
            modifiedBy: SyncDeviceID("mac-a")
        )

        XCTAssertEqual(record.entityType, .classificationCommit)
        XCTAssertEqual(record.entityID, changeRecord.id.uuidString)
        XCTAssertEqual(record.id.rawValue, "classification-commit:\(changeRecord.id.uuidString)")
        XCTAssertEqual(record.payload, try envelope.canonicalData())
        XCTAssertEqual(try mapper.decodeClassificationCommit(record), envelope)
        XCTAssertEqual(
            try mapper.payload(from: record),
            .classificationCommit(envelope)
        )

        var unknownFieldObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: record.payload) as? [String: Any]
        )
        unknownFieldObject["unexpected"] = true
        var unknownFieldRecord = record
        unknownFieldRecord.payload = try JSONSerialization.data(
            withJSONObject: unknownFieldObject,
            options: [.sortedKeys]
        )
        assertInvalidPayload(unknownFieldRecord, type: .classificationCommit) {
            try mapper.decodeClassificationCommit(unknownFieldRecord)
        }

        var prettyPrintedRecord = record
        prettyPrintedRecord.payload = try JSONSerialization.data(
            withJSONObject: try JSONSerialization.jsonObject(with: record.payload),
            options: [.prettyPrinted, .sortedKeys]
        )
        assertInvalidPayload(prettyPrintedRecord, type: .classificationCommit) {
            try mapper.decodeClassificationCommit(prettyPrintedRecord)
        }
    }

    func testSnapshotMappingFailsClosedRatherThanDroppingClassification() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "不可静默漏同步", now: now)
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "工程", colorHex: "#2A6FDB"),
                    labels: [.new(name: "同步", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(uuidString: "34000000-0000-0000-0000-000000000003")!,
            now: now
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(uuidString: "34000000-0000-0000-0000-000000000004")!
            ),
            now: now
        )

        XCTAssertThrowsError(
            try SyncRecordMapper().records(
                from: engine.snapshot(),
                modifiedBy: SyncDeviceID("mac-a")
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncRecordMapperError,
                .classificationStateRequiresCommitRecords
            )
        }
    }

    func testTraceClassificationEventUsesUniqueCanonicalImmutablePayload() throws {
        let event = TraceClassificationSnapshot(
            id: UUID(uuidString: "75000000-0000-0000-0000-000000000001")!,
            traceID: DayTraceID(
                UUID(uuidString: "75000000-0000-0000-0000-000000000002")!
            ),
            status: .continued,
            category: nil,
            labels: [],
            capturedAt: Date(
                timeIntervalSinceReferenceDate: 812_345_678.123_456_7
            ),
            revision: 7
        )
        let predecessorID = UUID(
            uuidString: "75000000-0000-0000-0000-000000000003"
        )!
        let envelope = try TraceClassificationEventEnvelope(
            event: event,
            predecessorEventID: predecessorID
        )
        let mapper = SyncRecordMapper()

        let record = try mapper.record(
            for: envelope,
            modifiedBy: SyncDeviceID("mac-a")
        )

        XCTAssertEqual(record.entityType, .traceClassificationEvent)
        XCTAssertEqual(
            record.id.rawValue,
            "trace-classification-event:\(event.id.uuidString)"
        )
        XCTAssertEqual(record.entityID, event.id.uuidString)
        XCTAssertEqual(record.payload, try envelope.canonicalData())
        XCTAssertEqual(try mapper.decodeTraceClassificationEvent(record), envelope)
        XCTAssertEqual(
            try mapper.payload(from: record),
            .traceClassificationEvent(envelope)
        )
        XCTAssertEqual(
            try mapper.decodeTraceClassificationEvent(record)
                .event.capturedAt.timeIntervalSinceReferenceDate.bitPattern,
            event.capturedAt.timeIntervalSinceReferenceDate.bitPattern
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: record.payload) as? [String: Any]
        )
        object["unexpected"] = true
        var noncanonical = record
        noncanonical.payload = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        assertInvalidPayload(noncanonical, type: .traceClassificationEvent) {
            try mapper.decodeTraceClassificationEvent(noncanonical)
        }
    }

    private func makeEngine() throws -> NoonmarkEngine {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "同步 mapper 测试", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "生成同步记录", difficulty: .medium, now: now)
        engine.updateDailyReview(date: today, summary: "完成同步记录 round-trip。", unfinishedReason: nil, tomorrowNote: nil, now: now)
        return engine
    }

    private func assertInvalidPayload(
        _ record: SyncRecord,
        type: SyncEntityType,
        operation: () throws -> some Any
    ) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(
                error as? SyncRecordMapperError,
                .invalidPayload(type),
                "record=\(record.id.rawValue)"
            )
        }
    }
}
