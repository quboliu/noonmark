@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class SyncRecordMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testSnapshotRecordsRoundTripThroughGenericPayloads() throws {
        let engine = try makeEngine()
        try engine.updateTheme(
            .warmPaper,
            writerID: "mac-a",
            now: now
        )
        let mapper = SyncRecordMapper()
        let deviceID = SyncDeviceID("mac-a")

        let records = try mapper.records(
            from: engine.snapshot(),
            modifiedBy: deviceID
        )

        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("day:") && $0.entityType == .day })
        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("chain:") && $0.entityType == .taskChain })
        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("definition:") && $0.entityType == .taskDefinition })
        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("trace:") && $0.entityType == .dayTrace })
        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("subtask:") && $0.entityType == .subtask })
        XCTAssertTrue(records.contains { $0.id.rawValue == "preferences:default" && $0.entityType == .appPreferences })
        XCTAssertTrue(records.allSatisfy { $0.modifiedByDeviceID == deviceID })

        let traceRecord = try XCTUnwrap(records.first { $0.entityType == .dayTrace })
        let preferenceRecord = try XCTUnwrap(
            records.first { $0.entityType == .appPreferences }
        )
        let decodedTrace = try mapper.decodeDayTrace(traceRecord)
        let decodedPreferences = try mapper.decodeAppPreferences(
            preferenceRecord
        )

        XCTAssertEqual(decodedTrace, try XCTUnwrap(engine.snapshot().traces.first))
        XCTAssertEqual(
            preferenceRecord.modifiedAt.timeIntervalSinceReferenceDate
                .bitPattern,
            now.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(
            decodedPreferences.updatedAt.timeIntervalSinceReferenceDate
                .bitPattern,
            now.timeIntervalSinceReferenceDate.bitPattern
        )
    }

    func testPreferenceRecordContainsOnlyCrossDeviceAppearanceFields() throws {
        var preferences = AppPreferences(
            theme: .warmPaper,
            language: .english,
            themeLanguageUpdatedAt: now,
            themeLanguageWriterID: "mac-private-config",
            dataMode: .onlineFirst
        )
        preferences.localFirstSyncPolicy = LocalFirstCloudSyncPolicy(
            enabled: true,
            endpoint: .localFolder,
            mode: .automatic
        )
        let mapper = SyncRecordMapper()
        let record = try mapper.record(
            for: AppPreferencesEnvelope(preferences: preferences),
            modifiedBy: SyncDeviceID("mac-private-config")
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: record.payload) as? [String: Any]
        )
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        let decoded = try mapper.decodeAppPreferences(record)

        XCTAssertEqual(
            Set(payload.keys),
            ["theme", "language", "updatedAt", "writerDeviceID"]
        )
        XCTAssertEqual(decoded.theme, .warmPaper)
        XCTAssertEqual(decoded.language, .english)
        XCTAssertEqual(decoded.updatedAt, now)
        XCTAssertEqual(
            decoded.writerDeviceID,
            SyncDeviceID("mac-private-config")
        )
    }

    func testPreferenceRecordRejectsWriterHeaderMismatch() {
        XCTAssertThrowsError(
            try SyncRecordMapper().record(
                for: AppPreferencesEnvelope(
                    theme: .warmPaper,
                    language: .english,
                    updatedAt: now,
                    writerDeviceID: SyncDeviceID("mac-payload")
                ),
                modifiedBy: SyncDeviceID("mac-header")
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncRecordMapperError,
                .invalidPayload(.appPreferences)
            )
        }
    }

    func testPreferenceRecordRejectsHeaderPayloadClockMismatch() throws {
        let mapper = SyncRecordMapper()
        let exactClock = Date(
            timeIntervalSinceReferenceDate: 805_912_493.447_825
        )
        var record = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: exactClock
            ),
            modifiedBy: SyncDeviceID("mac-clock-mismatch")
        )
        record.modifiedAt = Date(
            timeIntervalSinceReferenceDate: exactClock
                .timeIntervalSinceReferenceDate.nextUp
        )

        XCTAssertThrowsError(
            try mapper.decodeAppPreferences(record)
        ) { error in
            XCTAssertEqual(
                error as? SyncRecordMapperError,
                .invalidPayload(.appPreferences)
            )
        }
    }

    func testNoteMutationTimeDrivesTaskChainAndTraceRecordFreshness() throws {
        let noteUpdatedAt = now.addingTimeInterval(90)
        let chainEngine = NoonmarkEngine()
        let chainID = try chainEngine.createPoolTask(
            title: "附言同步时间",
            initialNoteBody: "修改前",
            now: now
        )
        let chainNoteID = try XCTUnwrap(
            chainEngine.taskPool().first?.chain.activeNoteEntries.first?.id
        )
        try chainEngine.editPoolNote(
            chainID: chainID,
            noteID: chainNoteID,
            body: "修改后",
            now: noteUpdatedAt
        )
        let chain = try XCTUnwrap(chainEngine.chains[chainID])

        let traceEngine = NoonmarkEngine()
        let traceChainID = try traceEngine.createPoolTask(
            title: "附言同步时间",
            initialNoteBody: "修改前",
            now: now
        )
        let traceNoteID = try XCTUnwrap(
            traceEngine.taskPool().first?.chain.activeNoteEntries.first?.id
        )
        let traceID = try traceEngine.scheduleFromPool(
            chainID: traceChainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try traceEngine.editTraceNote(
            traceID: traceID,
            noteID: traceNoteID,
            body: "修改后",
            today: today,
            now: noteUpdatedAt
        )
        let trace = try XCTUnwrap(traceEngine.traces[traceID])
        let mapper = SyncRecordMapper()
        let deviceID = SyncDeviceID("mac-a")

        let chainRecord = try mapper.record(
            for: chain,
            modifiedBy: deviceID
        )
        let traceRecord = try mapper.record(for: trace, modifiedBy: deviceID)

        XCTAssertEqual(chainRecord.modifiedAt, noteUpdatedAt)
        XCTAssertEqual(traceRecord.modifiedAt, noteUpdatedAt)
    }

    func testSubtaskUpdatedAtDrivesRecordFreshnessAndRoundTripsExactly() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "子任务同步时间",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let subtaskID = try engine.addSubtask(
            traceID: traceID,
            title: "调整难度",
            now: now
        )
        let updatedAt = now.addingTimeInterval(10.125)
        try engine.updateSubtaskDifficulty(
            subtaskID,
            difficulty: .hard,
            today: today,
            now: updatedAt
        )
        let mapper = SyncRecordMapper()
        let record = try mapper.record(
            for: try XCTUnwrap(engine.subtasks[subtaskID]),
            modifiedBy: SyncDeviceID("mac-subtask")
        )
        let restored = try mapper.decodeSubtask(record)

        XCTAssertEqual(record.modifiedAt, updatedAt)
        XCTAssertEqual(
            restored.updatedAt.timeIntervalSinceReferenceDate.bitPattern,
            updatedAt.timeIntervalSinceReferenceDate.bitPattern
        )

        var forgedHeader = record
        forgedHeader.modifiedAt = updatedAt.addingTimeInterval(1)
        assertInvalidPayload(forgedHeader, type: .subtask) {
            try mapper.decodeSubtask(forgedHeader)
        }
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
        XCTAssertEqual(object["formatVersion"] as? Int, 5)

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

    func testDayTracePinQueueRoundTripsThroughCurrentSyncPayload() throws {
        let mapper = SyncRecordMapper()
        let trace = DayTrace(
            chainID: TaskChainID(),
            definitionID: TaskDefinitionID(),
            date: today,
            priority: 3,
            pinOrder: 2,
            now: now
        )

        let record = try mapper.record(
            for: trace,
            modifiedBy: SyncDeviceID("mac-pin")
        )
        let restored = try mapper.decodeDayTrace(record)

        XCTAssertEqual(restored, trace)
        XCTAssertEqual(restored.pinOrder, 2)
    }

    func testCancelledDeferredTargetKeepsItsSourceThroughCurrentSyncPayload() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "同步延期目标回池",
            now: now
        )
        let sourceTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let futureDate = LocalDate("2026-07-06")
        let targetTraceID = try engine.deferCurrentTrace(
            traceID: sourceTraceID,
            targetDate: futureDate,
            today: today,
            now: now.addingTimeInterval(2)
        )
        try engine.returnToPool(
            traceID: targetTraceID,
            today: today,
            now: now.addingTimeInterval(3)
        )
        let target = try XCTUnwrap(engine.traces[targetTraceID])

        let mapper = SyncRecordMapper()
        let record = try mapper.record(
            for: target,
            modifiedBy: SyncDeviceID("mac-return")
        )
        let restored = try mapper.decodeDayTrace(record)

        XCTAssertEqual(restored, target)
        XCTAssertEqual(restored.status, .cancelledDraft)
        XCTAssertEqual(restored.carriedFromTraceID, sourceTraceID)
        XCTAssertEqual(restored.draftCancelledOn, today)
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
        unknownVersion["formatVersion"] = 1
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

        var forgedClockRecord = record
        forgedClockRecord.modifiedAt = Date(
            timeIntervalSinceReferenceDate: record.modifiedAt
                .timeIntervalSinceReferenceDate.nextUp
        )
        assertInvalidPayload(
            forgedClockRecord,
            type: .classificationCommit
        ) {
            try mapper.decodeClassificationCommit(forgedClockRecord)
        }

        var nonfiniteClockRecord = record
        nonfiniteClockRecord.modifiedAt = Date(
            timeIntervalSinceReferenceDate: .nan
        )
        assertInvalidPayload(
            nonfiniteClockRecord,
            type: .classificationCommit
        ) {
            try mapper.decodeClassificationCommit(nonfiniteClockRecord)
        }

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
            status: .deferred,
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

        var forgedClockRecord = record
        forgedClockRecord.modifiedAt = Date(
            timeIntervalSinceReferenceDate: record.modifiedAt
                .timeIntervalSinceReferenceDate.nextUp
        )
        assertInvalidPayload(
            forgedClockRecord,
            type: .traceClassificationEvent
        ) {
            try mapper.decodeTraceClassificationEvent(forgedClockRecord)
        }

        var nonfiniteClockRecord = record
        nonfiniteClockRecord.modifiedAt = Date(
            timeIntervalSinceReferenceDate: .infinity
        )
        assertInvalidPayload(
            nonfiniteClockRecord,
            type: .traceClassificationEvent
        ) {
            try mapper.decodeTraceClassificationEvent(nonfiniteClockRecord)
        }

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
