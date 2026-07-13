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
        XCTAssertEqual(object["formatVersion"] as? Int, 1)
        XCTAssertNotNil(object["snapshot"] as? [String: Any])

        let restored = try NoonmarkEngine(snapshot: NoonmarkDataPackage.decode(data))

        XCTAssertEqual(restored.snapshot(), engine.snapshot())
    }

    func testJSONDataPackageRejectsUnknownTaskTagsFieldInPreferences() throws {
        let canonical = try NoonmarkDataPackage.encode(try makeEngine().snapshot())
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        var snapshot = try XCTUnwrap(envelope["snapshot"] as? [String: Any])
        var preferences = try XCTUnwrap(snapshot["preferences"] as? [String: Any])
        preferences["taskTags"] = [Any]()
        snapshot["preferences"] = preferences
        envelope["snapshot"] = snapshot
        let data = try canonicalJSON(envelope)

        XCTAssertEqual(data, try canonicalJSON(data))
        XCTAssertThrowsError(try NoonmarkDataPackage.decode(data)) { error in
            XCTAssertEqual(
                error as? DataPackageError,
                .malformedDataPackage("数据包不符合 current v1 的 canonical 结构与编码")
            )
        }
    }

    func testJSONDataPackageRejectsUnknownTagAssignmentsFieldInChain() throws {
        let canonical = try NoonmarkDataPackage.encode(try makeEngine().snapshot())
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        var snapshot = try XCTUnwrap(envelope["snapshot"] as? [String: Any])
        var chains = try XCTUnwrap(snapshot["chains"] as? [[String: Any]])
        chains[0]["tagAssignments"] = [Any]()
        snapshot["chains"] = chains
        envelope["snapshot"] = snapshot
        let data = try canonicalJSON(envelope)

        XCTAssertEqual(data, try canonicalJSON(data))
        XCTAssertThrowsError(try NoonmarkDataPackage.decode(data)) { error in
            XCTAssertEqual(
                error as? DataPackageError,
                .malformedDataPackage("数据包不符合 current v1 的 canonical 结构与编码")
            )
        }
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
                .malformedDataPackage("数据包不符合 current v1 的 canonical 结构与编码")
            )
        }
    }

    func testJSONDataPackageRejectsUnsupportedFormatVersionBeforePayloadDecode() {
        let data = Data(#"{"formatVersion":3,"snapshot":{}}"#.utf8)

        XCTAssertThrowsError(try NoonmarkDataPackage.decode(data)) { error in
            XCTAssertEqual(error as? DataPackageError, .unsupportedFormatVersion(3))
            XCTAssertEqual(error.localizedDescription, "无法导入数据包：不支持格式版本 3。")
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
        let data = Data(#"{"formatVersion":1}"#.utf8)

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

    func testJSONDataPackageRejectsUnversionedRawSnapshot() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(try makeEngine().snapshot())

        XCTAssertThrowsError(try NoonmarkDataPackage.decode(data)) { error in
            XCTAssertEqual(error as? DataPackageError, .malformedFormatVersion)
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
        return try encoder.encode(CurrentDataPackageFixture(formatVersion: 1, snapshot: snapshot))
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
            note: "必须保留引用完整性。",
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
        engine.settleDays(upTo: LocalDate("2026-07-06"), now: now)
        return engine
    }
}

private struct CurrentDataPackageFixture: Encodable {
    let formatVersion: Int
    let snapshot: NoonmarkSnapshot
}
