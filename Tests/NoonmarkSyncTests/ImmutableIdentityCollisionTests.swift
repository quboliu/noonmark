@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class ImmutableIdentityCollisionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRejectedCreateCommitVariantsTerminallyRejectEveryProvidedCategory() throws {
        let receiver = NoonmarkEngine()
        let chainID = try receiver.createPoolTask(
            title: "不可变 provider index",
            now: now
        )
        let date = LocalDate("2027-01-15")
        let traceID = try receiver.scheduleFromPool(
            chainID: chainID,
            date: date,
            today: date,
            now: now
        )
        let baseSnapshot = receiver.snapshot()
        let sharedCommitID = uuid("75000000-0000-0000-0000-000000000001")
        let firstCategory = TaskCategory(
            id: TaskCategoryID(uuid("75000000-0000-0000-0000-000000000002")),
            name: "碰撞分类甲",
            colorHex: "#2A6FDB",
            now: now.addingTimeInterval(1)
        )
        let secondCategory = TaskCategory(
            id: TaskCategoryID(uuid("75000000-0000-0000-0000-000000000003")),
            name: "碰撞分类乙",
            colorHex: "#0E9488",
            now: now.addingTimeInterval(1)
        )
        let mapper = SyncRecordMapper()
        let firstCommit = try classificationCreateRecord(
            category: firstCategory,
            commitID: sharedCommitID,
            deviceID: "immutable-provider-a"
        )
        let secondCommit = try classificationCreateRecord(
            category: secondCategory,
            commitID: sharedCommitID,
            deviceID: "immutable-provider-b"
        )
        let firstEvent = try classificationEventRecord(
            id: uuid("75000000-0000-0000-0000-000000000004"),
            traceID: traceID,
            category: firstCategory,
            mapper: mapper
        )
        let secondEvent = try classificationEventRecord(
            id: uuid("75000000-0000-0000-0000-000000000005"),
            traceID: traceID,
            category: secondCategory,
            mapper: mapper
        )

        let result = try SyncRecordMerger(mapper: mapper).merge(
            records: [firstCommit, secondCommit, firstEvent, secondEvent],
            into: baseSnapshot,
            detectedAt: now.addingTimeInterval(10)
        )

        XCTAssertEqual(result.snapshot, baseSnapshot)
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertTrue(
            result.waitingRecords.isEmpty,
            "dependencies supplied only by terminal evidence must not wait forever"
        )
        XCTAssertEqual(result.conflicts.count, 4)
        XCTAssertEqual(
            result.conflicts.filter {
                $0.type == .classificationCommitRejected
            }.count,
            2
        )
        XCTAssertEqual(
            result.conflicts.filter {
                $0.type == .traceClassificationEventRejected
            }.count,
            2
        )
    }

    func testClassificationCommitIdentityCollisionTerminallyRejectsCausalDescendant() throws {
        let fixture = try makeFixture()
        let permutations = [
            [fixture.firstParent, fixture.secondParent, fixture.descendant],
            [fixture.secondParent, fixture.firstParent, fixture.descendant]
        ]
        let merger = SyncRecordMerger()
        let detectedAt = now.addingTimeInterval(10)
        var expected: SyncMergeResult?

        for records in permutations {
            let result = try merger.merge(
                records: records,
                into: fixture.baseSnapshot,
                detectedAt: detectedAt
            )

            XCTAssertEqual(result.snapshot, fixture.baseSnapshot)
            XCTAssertTrue(result.appliedRecordIDs.isEmpty)
            XCTAssertTrue(
                result.waitingRecords.isEmpty,
                "a descendant of terminally rejected immutable evidence must not wait forever"
            )
            XCTAssertEqual(result.conflicts.count, 3)
            XCTAssertEqual(
                Set(result.conflicts.map(\.type)),
                [.classificationCommitRejected]
            )
            for record in [
                fixture.firstParent,
                fixture.secondParent,
                fixture.descendant
            ] {
                XCTAssertTrue(
                    result.conflicts.contains {
                        $0.remoteRecord.exactlyMatches(record)
                    },
                    "every exact immutable variant and causal descendant needs terminal evidence"
                )
            }
            XCTAssertNoThrow(try result.snapshot.validateIntegrity())

            if let expected {
                XCTAssertEqual(
                    result,
                    expected,
                    "immutable collision closure and conflict order must be canonical"
                )
            } else {
                expected = result
            }
        }
    }

    private func makeFixture() throws -> ImmutableCollisionFixture {
        let source = NoonmarkEngine()
        let baseSnapshot = source.snapshot()
        let parentBefore = baseSnapshot.classifications
        let parentPlan = try source.prepareClassification(
            .createCategory(name: "不可变碰撞父提交", colorHex: "#2A6FDB"),
            source: .userDirect,
            interactionID: UUID(uuidString: "74000000-0000-0000-0000-000000000001")!,
            now: now.addingTimeInterval(1)
        )
        let parentReceipt = try source.commitClassification(
            parentPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "74000000-0000-0000-0000-000000000002")!
            ),
            now: now.addingTimeInterval(1)
        )
        let afterParent = source.snapshot()
        let parentEnvelope = try ClassificationCommitEnvelope(
            before: parentBefore,
            after: afterParent.classifications,
            changeRecord: try XCTUnwrap(
                afterParent.classifications.changeRecords.first {
                    $0.id == parentReceipt.changeRecordID
                }
            )
        )
        let categoryID = try XCTUnwrap(
            afterParent.classifications.categories.keys.first
        )

        let descendantPlan = try source.prepareClassification(
            .renameCategory(categoryID, to: "不可变碰撞后代"),
            source: .userDirect,
            interactionID: UUID(uuidString: "74000000-0000-0000-0000-000000000003")!,
            now: now.addingTimeInterval(2)
        )
        let descendantReceipt = try source.commitClassification(
            descendantPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "74000000-0000-0000-0000-000000000004")!
            ),
            now: now.addingTimeInterval(2)
        )
        let afterDescendant = source.snapshot()
        let descendantEnvelope = try ClassificationCommitEnvelope(
            before: afterParent.classifications,
            after: afterDescendant.classifications,
            changeRecord: try XCTUnwrap(
                afterDescendant.classifications.changeRecords.first {
                    $0.id == descendantReceipt.changeRecordID
                }
            )
        )
        XCTAssertEqual(
            descendantEnvelope.delta.mutation.predecessorChangeRecordIDs,
            [parentReceipt.changeRecordID]
        )

        let mapper = SyncRecordMapper()
        let firstParent = try mapper.record(
            for: parentEnvelope,
            modifiedBy: SyncDeviceID("immutable-parent-device-a")
        )
        let secondParent = try mapper.record(
            for: parentEnvelope,
            modifiedBy: SyncDeviceID("immutable-parent-device-b")
        )
        let descendant = try mapper.record(
            for: descendantEnvelope,
            modifiedBy: SyncDeviceID("immutable-descendant-device")
        )
        XCTAssertEqual(firstParent.id, secondParent.id)
        XCTAssertFalse(firstParent.exactlyMatches(secondParent))

        return ImmutableCollisionFixture(
            baseSnapshot: baseSnapshot,
            firstParent: firstParent,
            secondParent: secondParent,
            descendant: descendant
        )
    }

    private func classificationCreateRecord(
        category: TaskCategory,
        commitID: UUID,
        deviceID: String
    ) throws -> SyncRecord {
        let before = TaskClassificationState()
        let changeRecord = ClassificationChangeRecord(
            id: commitID,
            planID: UUID(),
            interactionID: UUID(),
            source: .deterministicDomainAction(reason: "immutable provider test"),
            decisionID: nil,
            changes: [
                .create(
                    kind: .category,
                    itemID: category.id.description,
                    name: category.name,
                    colorHex: category.colorHex
                )
            ],
            committedAt: category.createdAt,
            revision: 1,
            planDigest: String(repeating: "a", count: 64)
        )
        let after = TaskClassificationState(
            revision: 1,
            categories: [category.id: category],
            changeRecords: [changeRecord]
        )
        return try SyncRecordMapper().record(
            for: ClassificationCommitEnvelope(
                before: before,
                after: after,
                changeRecord: changeRecord
            ),
            modifiedBy: SyncDeviceID(deviceID)
        )
    }

    private func classificationEventRecord(
        id: UUID,
        traceID: DayTraceID,
        category: TaskCategory,
        mapper: SyncRecordMapper
    ) throws -> SyncRecord {
        try mapper.record(
            for: TraceClassificationEventEnvelope(
                event: TraceClassificationSnapshot(
                    id: id,
                    traceID: traceID,
                    status: .continued,
                    category: HistoricalCategoryValue(
                        id: category.id,
                        name: category.name,
                        colorHex: category.colorHex
                    ),
                    labels: [],
                    capturedAt: now.addingTimeInterval(2),
                    revision: 1
                ),
                predecessorEventID: nil
            ),
            modifiedBy: SyncDeviceID("immutable-provider-event")
        )
    }

    private func uuid(_ value: String) -> UUID {
        guard let id = UUID(uuidString: value) else {
            preconditionFailure("invalid test UUID: \(value)")
        }
        return id
    }
}

private struct ImmutableCollisionFixture {
    let baseSnapshot: NoonmarkSnapshot
    let firstParent: SyncRecord
    let secondParent: SyncRecord
    let descendant: SyncRecord
}
