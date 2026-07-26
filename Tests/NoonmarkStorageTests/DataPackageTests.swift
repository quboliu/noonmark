import CryptoKit
@testable import NoonmarkCore
@testable import NoonmarkStorage
import XCTest

final class DataPackageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testJSONDataPackageEncodesCurrentEnvelopeAndRoundTripsSnapshot() throws {
        let engine = try makeEngine()

        let data = try NoonmarkDataPackage.encode(engine.snapshot())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["formatVersion", "snapshot"])
        XCTAssertEqual(object["formatVersion"] as? Int, 6)
        let snapshotObject = try XCTUnwrap(
            object["snapshot"] as? [String: Any]
        )
        let preferencesObject = try XCTUnwrap(
            snapshotObject["preferences"] as? [String: Any]
        )
        XCTAssertNotNil(preferencesObject["themeLanguageUpdatedAt"])
        XCTAssertNotNil(preferencesObject["themeLanguageWriterID"])

        let restored = try NoonmarkEngine(snapshot: NoonmarkDataPackage.decode(data))

        XCTAssertEqual(restored.snapshot(), engine.snapshot())
    }

    func testDataPackagePreservesTaskCycleParentCancellationAndFullTrack() throws {
        let engine = NoonmarkEngine()
        let endDate = LocalDate("2026-07-09")
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日导出复盘",
            startDate: today,
            endDate: endDate,
            schedule: .daily,
            today: today,
            now: now
        )
        try engine.skipTaskCycleOccurrence(
            seriesID: seriesID,
            occurrenceDate: LocalDate("2026-07-06"),
            today: today,
            now: now.addingTimeInterval(1)
        )

        let restored = try NoonmarkEngine(
            snapshot: NoonmarkDataPackage.decode(
                NoonmarkDataPackage.encode(engine.snapshot())
            )
        )
        let track = try XCTUnwrap(
            restored.taskCycleTracks(today: today).first {
                $0.id == seriesID
            }
        )

        XCTAssertEqual(track.days.count, 5)
        XCTAssertEqual(track.scheduledCount, 5)
        XCTAssertEqual(
            restored.taskCycleSeries[seriesID]?.cancellationFacts.count,
            1
        )
        XCTAssertTrue(
            restored.taskCycleSeries[seriesID]?
                .isOccurrenceSkipped(LocalDate("2026-07-06")) == true
        )
        XCTAssertEqual(restored.snapshot(), engine.snapshot())
    }

    func testDataPackagePreservesForwardGroupDeletionAndHistoricalFacts() throws {
        let engine = NoonmarkEngine()
        let pastChainID = try engine.createPoolTask(
            title: "导出历史分组",
            now: now
        )
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: pastChainID,
                    category: .new(name: "导出前删除", colorHex: "#2A6FDB"),
                    labels: []
                )
            ),
            to: engine,
            at: now
        )
        let categoryID = try XCTUnwrap(
            engine.snapshot().classifications.categories.keys.first
        )
        let pastTraceID = try engine.scheduleFromPool(
            chainID: pastChainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try engine.abandonChain(
            from: pastTraceID,
            now: now.addingTimeInterval(2)
        )

        let deletionDay = LocalDate("2026-07-06")
        let currentChainID = try engine.createPoolTask(
            title: "导出当前未分组",
            now: now.addingTimeInterval(3)
        )
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: currentChainID,
                    category: .existing(categoryID),
                    labels: []
                )
            ),
            to: engine,
            at: now.addingTimeInterval(3)
        )
        _ = try engine.deleteTaskCategoryFromToday(
            categoryID,
            today: deletionDay,
            decisionID: UUID(),
            now: now.addingTimeInterval(4)
        )

        let restored = try NoonmarkDataPackage.decode(
            NoonmarkDataPackage.encode(engine.snapshot())
        )

        XCTAssertEqual(restored, engine.snapshot())
        XCTAssertEqual(
            restored.classifications.categories[categoryID]?.lifecycle,
            .archived
        )
        XCTAssertNil(
            restored.classifications.currentByChainID[currentChainID]?
                .categoryID
        )
        XCTAssertEqual(
            restored.classifications.snapshotEventsByTraceID[pastTraceID]?
                .first?.category?.id,
            categoryID
        )
        XCTAssertNoThrow(try restored.validateIntegrity())
    }

    func testDataPackagePreservesSnapshotUndoCancellationWitnesses() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "数据包撤销子任务",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let before = engine.snapshot()
        let subtaskID = try engine.addSubtask(
            traceID: traceID,
            title: "隐藏取消事实",
            now: now.addingTimeInterval(1)
        )
        let undone = try NoonmarkEngine(snapshot: before)
        try undone.prepareSnapshotUndo(
            replacing: engine.snapshot(),
            now: now.addingTimeInterval(2)
        )

        let restored = try NoonmarkDataPackage.decode(
            NoonmarkDataPackage.encode(undone.snapshot())
        )
        let subtask = try XCTUnwrap(
            restored.subtasks.first { $0.id == subtaskID }
        )

        XCTAssertEqual(subtask.status, .cancelledDraft)
        XCTAssertEqual(
            subtask.draftCancellationID,
            undone.subtasks[subtaskID]?.draftCancellationID
        )
        XCTAssertEqual(restored, undone.snapshot())
    }

    func testJSONDataPackagePreservesNestedSubMillisecondDatesBitExactly() throws {
        let createdAt = Date(timeIntervalSinceReferenceDate: 805_912_493.447_825)
        let noteUpdatedAt = createdAt.addingTimeInterval(1.000_173)
        let plannedAt = createdAt.addingTimeInterval(2.000_347)
        let preferenceUpdatedAt = createdAt.addingTimeInterval(3.000_521)
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "精确数据包嵌套时间",
            initialNoteBody: "附言精确时间",
            now: createdAt
        )
        let noteID = try XCTUnwrap(
            engine.chains[chainID]?.activeNoteEntries.first?.id
        )
        try engine.editPoolNote(
            chainID: chainID,
            noteID: noteID,
            body: "附言精确编辑时间",
            now: noteUpdatedAt
        )
        let plannedSubtaskID = try engine.addPlannedSubtask(
            chainID: chainID,
            title: "计划子任务精确时间",
            now: plannedAt
        )
        try engine.updateLanguage(
            .english,
            writerID: "mac-data-package-writer",
            now: preferenceUpdatedAt
        )

        let restored = try NoonmarkDataPackage.decode(
            NoonmarkDataPackage.encode(engine.snapshot())
        )
        let restoredChain = try XCTUnwrap(
            restored.chains.first(where: { $0.id == chainID })
        )
        let restoredNote = try XCTUnwrap(
            restoredChain.noteEntries.first(where: { $0.id == noteID })
        )
        let restoredPlannedSubtask = try XCTUnwrap(
            restored.definitions
                .first(where: { $0.chainID == chainID })?
                .plannedSubtasks
                .first(where: { $0.id == plannedSubtaskID })
        )

        XCTAssertEqual(
            restoredNote.createdAt.timeIntervalSinceReferenceDate.bitPattern,
            createdAt.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(
            restoredNote.updatedAt.timeIntervalSinceReferenceDate.bitPattern,
            noteUpdatedAt.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(
            restoredPlannedSubtask.createdAt.timeIntervalSinceReferenceDate.bitPattern,
            plannedAt.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(
            restored.preferences.themeLanguageUpdatedAt
                .timeIntervalSinceReferenceDate.bitPattern,
            preferenceUpdatedAt.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(
            restored.preferences.themeLanguageWriterID,
            "mac-data-package-writer"
        )
    }

    func testWriteVerifiesThePersistedPackageAndReturnsItsDigest() throws {
        let snapshot = try makeEngine().snapshot()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-data-package-\(UUID().uuidString).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }

        let receipt = try NoonmarkDataPackage.write(snapshot, to: url)
        let persisted = try Data(contentsOf: url)
        let expectedDigest = SHA256.hash(data: persisted)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(receipt.byteCount, persisted.count)
        XCTAssertEqual(receipt.sha256, expectedDigest)
        XCTAssertEqual(try NoonmarkDataPackage.read(from: url), snapshot)
    }

    func testJSONDataPackageRequiresChainNoteEntries() throws {
        let canonical = try NoonmarkDataPackage.encode(try makeEngine().snapshot())
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        var snapshot = try XCTUnwrap(envelope["snapshot"] as? [String: Any])
        var chains = try XCTUnwrap(snapshot["chains"] as? [[String: Any]])
        chains[0].removeValue(forKey: "noteEntries")
        snapshot["chains"] = chains
        envelope["snapshot"] = snapshot

        XCTAssertThrowsError(
            try NoonmarkDataPackage.decode(try canonicalJSON(envelope))
        )
    }

    func testJSONDataPackageRejectsNonCanonicalBytesForCurrentSnapshot() throws {
        let canonical = try NoonmarkDataPackage.encode(try makeEngine().snapshot())
        let canonicalText = try XCTUnwrap(String(data: canonical, encoding: .utf8))
        let data = Data(canonicalText.replacingOccurrences(of: "\n", with: "").utf8)

        XCTAssertNotEqual(data, canonical)
        XCTAssertEqual(try canonicalJSON(data), canonical)
        XCTAssertThrowsError(try NoonmarkDataPackage.decode(data)) { error in
            XCTAssertEqual(
                error as? DataPackageError,
                .malformedDataPackage("数据包不符合 current v6 的 canonical 结构与编码")
            )
        }
    }

    func testJSONDataPackageRejectsUnsupportedFormatVersionBeforePayloadDecode() {
        let data = Data(#"{"formatVersion":7,"snapshot":{}}"#.utf8)

        XCTAssertThrowsError(try NoonmarkDataPackage.decode(data)) { error in
            XCTAssertEqual(error as? DataPackageError, .unsupportedFormatVersion(7))
            XCTAssertEqual(error.localizedDescription, "无法导入数据包：不支持格式版本 7。")
        }
    }

    func testJSONDataPackageRejectsLegacyV1BeforePayloadDecode() {
        let data = Data(#"{"formatVersion":1,"snapshot":{}}"#.utf8)

        XCTAssertThrowsError(try NoonmarkDataPackage.decode(data)) { error in
            XCTAssertEqual(
                error as? DataPackageError,
                .unsupportedFormatVersion(1)
            )
        }
    }

    func testJSONDataPackageRejectsMalformedFormatVersion() {
        let malformedVersions = [#""2""#, "2.5", "true", "null"]

        for malformedVersion in malformedVersions {
            let data = Data(
                "{\"formatVersion\":\(malformedVersion),\"snapshot\":{}}".utf8
            )
            XCTAssertThrowsError(try NoonmarkDataPackage.decode(data)) { error in
                XCTAssertEqual(error as? DataPackageError, .malformedFormatVersion)
                XCTAssertEqual(
                    error.localizedDescription,
                    "无法导入数据包：formatVersion 缺失或不是整数。"
                )
            }
        }
    }

    func testJSONDataPackageRejectsCurrentEnvelopeWithoutSnapshot() {
        let data = Data(#"{"formatVersion":6}"#.utf8)

        XCTAssertThrowsError(try NoonmarkDataPackage.decode(data)) { error in
            XCTAssertEqual(
                error as? DataPackageError,
                .malformedDataPackage("数据包缺少 snapshot")
            )
            XCTAssertEqual(
                error.localizedDescription,
                "无法导入数据包：数据包缺少 snapshot。"
            )
        }
    }

    func testJSONDataPackageRejectsEnvelopeMissingFormatVersion() throws {
        let encoded = try NoonmarkDataPackage.encode(try makeEngine().snapshot())
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        envelope.removeValue(forKey: "formatVersion")
        let data = try JSONSerialization.data(withJSONObject: envelope)

        XCTAssertThrowsError(try NoonmarkDataPackage.decode(data)) { error in
            XCTAssertEqual(error as? DataPackageError, .malformedFormatVersion)
            XCTAssertEqual(
                error.localizedDescription,
                "无法导入数据包：formatVersion 缺失或不是整数。"
            )
        }
    }

    func testJSONDataPackageRejectsSnapshotMissingRequiredClassificationPayload() throws {
        let encoded = try NoonmarkDataPackage.encode(try makeEngine().snapshot())
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var snapshot = try XCTUnwrap(envelope["snapshot"] as? [String: Any])
        snapshot.removeValue(forKey: "classifications")
        envelope["snapshot"] = snapshot
        let data = try JSONSerialization.data(withJSONObject: envelope)

        XCTAssertThrowsError(try NoonmarkDataPackage.decode(data)) { error in
            XCTAssertEqual(
                error as? DataPackageError,
                .malformedDataPackage("snapshot 缺少必需字段：classifications")
            )
        }
    }

    func testJSONDataPackageRejectsTraceClassificationEventWithoutRevisionFact() throws {
        let encoded = try NoonmarkDataPackage.encode(try makeEngine().snapshot())
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var snapshot = try XCTUnwrap(envelope["snapshot"] as? [String: Any])
        var classifications = try XCTUnwrap(snapshot["classifications"] as? [String: Any])
        var streams = try XCTUnwrap(
            classifications["snapshotEventsByTraceID"] as? [Any]
        )
        var events = try XCTUnwrap(streams[1] as? [[String: Any]])
        events[0].removeValue(forKey: "revision")
        streams[1] = events
        classifications["snapshotEventsByTraceID"] = streams
        snapshot["classifications"] = classifications
        envelope["snapshot"] = snapshot

        XCTAssertThrowsError(
            try NoonmarkDataPackage.decode(
                JSONSerialization.data(withJSONObject: envelope)
            )
        )
    }

    func testJSONDataPackageRejectsNonFiniteDateFacts() throws {
        var snapshot = try makeEngine().snapshot()
        snapshot.days[0].updatedAt = Date(timeIntervalSinceReferenceDate: .nan)
        XCTAssertThrowsError(try NoonmarkDataPackage.encode(snapshot))

        let encoded = try NoonmarkDataPackage.encode(try makeEngine().snapshot())
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var encodedSnapshot = try XCTUnwrap(envelope["snapshot"] as? [String: Any])
        var days = try XCTUnwrap(encodedSnapshot["days"] as? [[String: Any]])
        days[0]["updatedAt"] = NSNumber(value: Double.nan.bitPattern)
        encodedSnapshot["days"] = days
        envelope["snapshot"] = encodedSnapshot

        XCTAssertThrowsError(
            try NoonmarkDataPackage.decode(
                JSONSerialization.data(withJSONObject: envelope)
            )
        )
    }

    func testJSONDataPackageRoundTripsMergeRelationHistoryAndDeletionTombstone() throws {
        let engine = try makeEngine()
        let sourceID = try XCTUnwrap(engine.snapshot().classifications.categories.keys.first)
        let targetPlan = try engine.prepareClassification(
            .createCategory(name: "统一工程", colorHex: "#D1477A"),
            source: .userDirect,
            interactionID: UUID(uuidString: "EFEFEFEF-0000-0000-0000-000000000001")!,
            now: now.addingTimeInterval(10)
        )
        _ = try engine.commitClassification(
            targetPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "EFEFEFEF-0000-0000-0000-000000000002")!
            ),
            now: now.addingTimeInterval(10)
        )
        let targetID = try XCTUnwrap(
            engine.snapshot().classifications.categories.values.first(where: { $0.name == "统一工程" })?.id
        )
        let mergePlan = try engine.prepareClassification(
            .mergeCategory(source: sourceID, into: targetID),
            source: .userDirect,
            interactionID: UUID(uuidString: "EFEFEFEF-0000-0000-0000-000000000003")!,
            now: now.addingTimeInterval(20)
        )
        _ = try engine.commitClassification(
            mergePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "EFEFEFEF-0000-0000-0000-000000000004")!
            ),
            now: now.addingTimeInterval(20)
        )

        let temporaryPlan = try engine.prepareClassification(
            .createLabel(name: "临时导出标签", colorHex: "#E0851B"),
            source: .userDirect,
            interactionID: UUID(uuidString: "EFEFEFEF-0000-0000-0000-000000000005")!,
            now: now.addingTimeInterval(30)
        )
        _ = try engine.commitClassification(
            temporaryPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "EFEFEFEF-0000-0000-0000-000000000006")!
            ),
            now: now.addingTimeInterval(30)
        )
        let temporaryID = try XCTUnwrap(
            engine.snapshot().classifications.labels.values.first(where: { $0.name == "临时导出标签" })?.id
        )
        let deletePlan = try engine.prepareClassification(
            .hardDeleteLabel(temporaryID),
            source: .userDirect,
            interactionID: UUID(uuidString: "EFEFEFEF-0000-0000-0000-000000000007")!,
            now: now.addingTimeInterval(40)
        )
        _ = try engine.commitClassification(
            deletePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "EFEFEFEF-0000-0000-0000-000000000008")!
            ),
            now: now.addingTimeInterval(40)
        )

        let data = try NoonmarkDataPackage.encode(engine.snapshot())
        let restored = try NoonmarkDataPackage.decode(data)

        XCTAssertEqual(restored, engine.snapshot())
    }

    func testCurrentDataPackagePreservesSubMillisecondClassificationAuditTimes() throws {
        let engine = NoonmarkEngine()
        let committedAt = now.addingTimeInterval(0.123_456_789)
        let plan = try engine.prepareClassification(
            .createCategory(name: "亚毫秒审计", colorHex: "#2A6FDB"),
            source: .userDirect,
            interactionID: UUID(uuidString: "EAEAEAEA-0000-0000-0000-000000000001")!,
            now: committedAt
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(uuidString: "EAEAEAEA-0000-0000-0000-000000000002")!
            ),
            now: committedAt
        )

        let encoded = try NoonmarkDataPackage.encode(engine.snapshot())
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let snapshotObject = try XCTUnwrap(envelope["snapshot"] as? [String: Any])
        let classificationsObject = try XCTUnwrap(
            snapshotObject["classifications"] as? [String: Any]
        )
        let records = try XCTUnwrap(
            classificationsObject["changeRecords"] as? [[String: Any]]
        )
        let recordData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(records.first))
        let recordDecoder = JSONDecoder()
        recordDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(
                timeIntervalSinceReferenceDate: Double(
                    bitPattern: try container.decode(UInt64.self)
                )
            )
        }
        let decodedRecord = try recordDecoder.decode(ClassificationChangeRecord.self, from: recordData)
        let originalRecord = try XCTUnwrap(engine.snapshot().classifications.changeRecords.first)
        XCTAssertEqual(decodedRecord, originalRecord)
        XCTAssertTrue(decodedRecord.hasValidIntegrityDigest())

        let restored = try NoonmarkDataPackage.decode(encoded)

        XCTAssertEqual(restored.classifications, engine.snapshot().classifications)
        XCTAssertEqual(
            restored.classifications.changeRecords.first?.committedAt.timeIntervalSinceReferenceDate.bitPattern,
            committedAt.timeIntervalSinceReferenceDate.bitPattern
        )
    }

    func testJSONDataPackageRejectsDuplicateKeys() throws {
        let engine = try makeEngine()
        var snapshot = engine.snapshot()
        snapshot.days.append(try XCTUnwrap(snapshot.days.first))

        XCTAssertThrowsError(try NoonmarkDataPackage.encode(snapshot)) { error in
            XCTAssertEqual(error as? DataPackageError, .duplicateField("days.date"))
        }
    }

    func testJSONDataPackageRejectsBrokenReferencesOnImport() throws {
        let engine = try makeEngine()
        var snapshot = engine.snapshot()
        snapshot.chains.removeAll()

        let data = try encodeCurrentFixture(snapshot)

        XCTAssertThrowsError(try NoonmarkDataPackage.decode(data)) { error in
            XCTAssertEqual(error as? DataPackageError, .missingReference("definition references missing chain"))
        }
    }

    func testJSONDataPackageRejectsCancelledDraftWithoutRestorationWitness() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "取消草稿数据包",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: LocalDate("2026-07-06"),
            today: today,
            now: now.addingTimeInterval(1)
        )
        try engine.returnToPool(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(2)
        )
        var snapshot = engine.snapshot()
        let traceIndex = try XCTUnwrap(
            snapshot.traces.firstIndex { $0.id == traceID }
        )
        XCTAssertNil(
            TrajectoryTopologyValidator.firstSelfContainedIssue(
                in: snapshot.traces[traceIndex]
            )
        )
        snapshot.traces[traceIndex].draftCancellationID = nil
        XCTAssertEqual(
            TrajectoryTopologyValidator.firstSelfContainedIssue(
                in: snapshot.traces[traceIndex]
            ),
            .invalidTraceStatusFacts(traceID)
        )

        XCTAssertThrowsError(try NoonmarkDataPackage.encode(snapshot)) { error in
            guard let dataPackageError = error as? DataPackageError,
                  case .malformedDataPackage = dataPackageError
            else {
                return XCTFail("expected malformed data package, got \(error)")
            }
        }
    }

    func testCurrentDataPackageDecodeStillValidatesWholeSnapshot() throws {
        let engine = try makeEngine()
        var snapshot = engine.snapshot()
        snapshot.chains.removeAll()
        let data = try encodeCurrentFixture(snapshot)

        XCTAssertThrowsError(try NoonmarkDataPackage.decode(data)) { error in
            XCTAssertEqual(error as? DataPackageError, .missingReference("definition references missing chain"))
        }
    }

    func testJSONDataPackageRejectsBrokenClassificationReferences() throws {
        let engine = try makeEngine()
        var snapshot = engine.snapshot()
        let chainID = try XCTUnwrap(snapshot.chains.first?.id)
        snapshot.classifications.currentByChainID[chainID] = CurrentTaskClassification(
            category: TaskCategoryRelation(
                categoryID: TaskCategoryID(),
                source: .deterministicDomainAction(reason: "invalid reference fixture"),
                decisionID: nil,
                createdAt: now,
                updatedAt: now,
                revision: snapshot.classifications.revision
            ),
            labels: []
        )

        XCTAssertThrowsError(try NoonmarkDataPackage.encode(snapshot)) { error in
            XCTAssertEqual(
                error as? DataPackageError,
                .missingReference("task classification references missing category")
            )
        }
    }

    func testJSONDataPackageRejectsLiveClassificationIdentityWithDeletionTombstone() throws {
        let engine = try makeEngine()
        var snapshot = engine.snapshot()
        let categoryID = try XCTUnwrap(snapshot.classifications.categories.keys.first)
        let changeRecordID = try XCTUnwrap(snapshot.classifications.changeRecords.first?.id)
        snapshot.classifications.categoryDeletionTombstones[categoryID] = TaskCategoryDeletionTombstone(
            itemID: categoryID,
            deletedAt: now,
            revision: snapshot.classifications.revision,
            changeRecordID: changeRecordID
        )

        XCTAssertThrowsError(try NoonmarkDataPackage.encode(snapshot)) { error in
            XCTAssertEqual(
                error as? DataPackageError,
                .missingReference("deleted task category identity is still live")
            )
        }
    }

    func testJSONDataPackageRejectsMergeWhoseSourceIsNotMarkedMerged() throws {
        let engine = try makeEngine()
        var snapshot = engine.snapshot()
        let sourceID = try XCTUnwrap(snapshot.classifications.categories.keys.first)
        let targetID = TaskCategoryID()
        snapshot.classifications.categories[targetID] = TaskCategory(
            id: targetID,
            name: "另一个分类",
            colorHex: "#7C5CFF",
            now: now
        )
        let changeRecordID = try XCTUnwrap(snapshot.classifications.changeRecords.first?.id)
        snapshot.classifications.categoryMerges[sourceID] = TaskCategoryMerge(
            sourceID: sourceID,
            targetID: targetID,
            mergedAt: now,
            revision: snapshot.classifications.revision,
            changeRecordID: changeRecordID
        )

        XCTAssertThrowsError(try NoonmarkDataPackage.encode(snapshot)) { error in
            XCTAssertEqual(
                error as? DataPackageError,
                .missingReference("task category merge lifecycle is inconsistent")
            )
        }
    }

    private func encodeCurrentFixture(_ snapshot: NoonmarkSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate.bitPattern)
        }
        return try encoder.encode(CurrentDataPackageFixture(formatVersion: 6, snapshot: snapshot))
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        try canonicalJSON(JSONSerialization.jsonObject(with: data))
    }

    private func canonicalJSON(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func makeEngine() throws -> NoonmarkEngine {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "数据包测试",
            descriptionText: "用于导出导入测试。",
            initialNoteBody: "必须保留引用完整性。",
            now: now
        )
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "写 JSON 测试", difficulty: .hard, now: now)
        let classificationPlan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "工程", colorHex: "#2A6FDB"),
                    labels: [
                        .new(name: "导出", colorHex: "#0E9488"),
                        .new(name: "完整性", colorHex: "#7C5CFF")
                    ]
                )
            ),
            source: .userDirect,
            interactionID: UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!,
            now: now
        )
        _ = try engine.commitClassification(
            classificationPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "CDCDCDCD-CDCD-CDCD-CDCD-CDCDCDCDCDCD")!
            ),
            now: now
        )
        engine.updateDailyReview(
            date: today,
            summary: "数据包 round-trip。",
            unfinishedReason: "无。",
            tomorrowNote: "继续验证导入。",
            now: now
        )
        try engine.settleDays(upTo: LocalDate("2026-07-06"), now: now)
        return engine
    }

    @discardableResult
    private func commit(
        _ intent: ClassificationIntent,
        to engine: NoonmarkEngine,
        at date: Date
    ) throws -> ClassificationReceipt {
        let plan = try engine.prepareClassification(
            intent,
            source: .userDirect,
            interactionID: UUID(),
            now: date
        )
        return try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: UUID()),
            now: date
        )
    }
}

private struct CurrentDataPackageFixture: Encodable {
    let formatVersion: Int
    let snapshot: NoonmarkSnapshot
}
