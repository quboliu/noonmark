import Foundation
@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class ClassificationBaselineEnvelopeTests: XCTestCase {
    private let baselineID = UUID(
        uuidString: "54000000-0000-0000-0000-000000000001"
    )!
    private let createdAt = Date(
        timeIntervalSinceReferenceDate: 812_345_678.125
    )

    func testCanonicalRoundTripPreservesExactBaseline() throws {
        let envelope = try ClassificationBaselineEnvelope(
            baselineID: baselineID,
            state: TaskClassificationState(),
            createdAt: createdAt
        )
        let data = try envelope.canonicalData()

        let restored = try ClassificationBaselineEnvelope.decode(data)

        XCTAssertEqual(restored, envelope)
        XCTAssertEqual(
            try restored.classificationState(),
            TaskClassificationState()
        )
        let record = try SyncRecordMapper().record(
            for: restored,
            modifiedBy: SyncDeviceID("baseline-device")
        )
        XCTAssertEqual(record.entityType, .classificationBaseline)
        XCTAssertEqual(record.entityID, baselineID.uuidString)
        XCTAssertEqual(
            try SyncRecordMapper().decodeClassificationBaseline(record),
            envelope
        )
    }

    func testTamperedIntegrityDigestIsRejected() throws {
        let envelope = try ClassificationBaselineEnvelope(
            baselineID: baselineID,
            state: TaskClassificationState(),
            createdAt: createdAt
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try envelope.canonicalData()
            ) as? [String: Any]
        )
        var tampered = object
        tampered["integrityDigest"] = String(repeating: "0", count: 64)
        let tamperedData = try JSONSerialization.data(
            withJSONObject: tampered,
            options: [.sortedKeys]
        )

        XCTAssertThrowsError(
            try ClassificationBaselineEnvelope.decode(tamperedData)
        ) {
            XCTAssertEqual(
                $0 as? ClassificationBaselineEnvelopeError,
                .integrityDigestMismatch
            )
        }
    }

    func testDivergentBaselinesCannotJointlyPretendToCoverMergedHistory()
        throws
    {
        let base = NoonmarkEngine().snapshot()
        let categoryBranch = try NoonmarkEngine(snapshot: base)
        let categoryPlan = try categoryBranch.prepareClassification(
            .createCategory(name: "分支分类", colorHex: "#2A6FDB"),
            source: .userDirect,
            interactionID: UUID(
                uuidString:
                "54000000-0000-0000-0000-000000000010"
            )!,
            now: createdAt.addingTimeInterval(1)
        )
        let categoryReceipt = try categoryBranch
            .commitClassification(
                categoryPlan,
                confirmation: .user(
                    decisionID: UUID(
                        uuidString:
                        "54000000-0000-0000-0000-000000000011"
                    )!
                ),
                now: createdAt.addingTimeInterval(1)
            )
        let categorySnapshot = categoryBranch.snapshot()

        let labelBranch = try NoonmarkEngine(snapshot: base)
        let labelPlan = try labelBranch.prepareClassification(
            .createLabel(name: "分支标签", colorHex: "#0E9488"),
            source: .userDirect,
            interactionID: UUID(
                uuidString:
                "54000000-0000-0000-0000-000000000012"
            )!,
            now: createdAt.addingTimeInterval(2)
        )
        let labelReceipt = try labelBranch.commitClassification(
            labelPlan,
            confirmation: .user(
                decisionID: UUID(
                    uuidString:
                    "54000000-0000-0000-0000-000000000013"
                )!
            ),
            now: createdAt.addingTimeInterval(2)
        )
        let labelSnapshot = labelBranch.snapshot()

        let mapper = SyncRecordMapper()
        let categoryCommit = try ClassificationCommitEnvelope(
            before: base.classifications,
            after: categorySnapshot.classifications,
            changeRecord: try XCTUnwrap(
                categorySnapshot.classifications.changeRecords.first {
                    $0.id == categoryReceipt.changeRecordID
                }
            )
        )
        let labelCommit = try ClassificationCommitEnvelope(
            before: base.classifications,
            after: labelSnapshot.classifications,
            changeRecord: try XCTUnwrap(
                labelSnapshot.classifications.changeRecords.first {
                    $0.id == labelReceipt.changeRecordID
                }
            )
        )
        let merged = try SyncRecordMerger(mapper: mapper).merge(
            records: [
                try mapper.record(
                    for: categoryCommit,
                    modifiedBy: SyncDeviceID("category-branch")
                ),
                try mapper.record(
                    for: labelCommit,
                    modifiedBy: SyncDeviceID("label-branch")
                )
            ],
            into: base,
            detectedAt: createdAt.addingTimeInterval(3)
        ).snapshot
        XCTAssertEqual(
            merged.classifications.changeRecords.count,
            2
        )

        let divergentBaselines = [
            try mapper.record(
                for: ClassificationBaselineEnvelope(
                    baselineID: UUID(
                        uuidString:
                        "54000000-0000-0000-0000-000000000014"
                    )!,
                    state: categorySnapshot.classifications,
                    createdAt: createdAt.addingTimeInterval(4)
                ),
                modifiedBy: SyncDeviceID("category-branch")
            ),
            try mapper.record(
                for: ClassificationBaselineEnvelope(
                    baselineID: UUID(
                        uuidString:
                        "54000000-0000-0000-0000-000000000015"
                    )!,
                    state: labelSnapshot.classifications,
                    createdAt: createdAt.addingTimeInterval(5)
                ),
                modifiedBy: SyncDeviceID("label-branch")
            )
        ]

        XCTAssertFalse(
            SyncSnapshotBaselineCoverageAuditor().isComplete(
                snapshot: merged,
                journalEntries: [],
                remoteRecords: divergentBaselines
            )
        )
    }

    func testAncestorBaselineAndUnsafeForkCommitsCannotPretendToBeComplete()
        throws
    {
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(
            title: "分类因果闭包",
            now: createdAt
        )
        _ = try commitClassification(
            .createCategory(name: "分叉 A", colorHex: "#2A6FDB"),
            on: source,
            interactionID: uuid(
                "54000000-0000-0000-0000-000000000020"
            ),
            decisionID: uuid(
                "54000000-0000-0000-0000-000000000021"
            ),
            at: createdAt.addingTimeInterval(1)
        )
        _ = try commitClassification(
            .createCategory(name: "分叉 B", colorHex: "#0E9488"),
            on: source,
            interactionID: uuid(
                "54000000-0000-0000-0000-000000000022"
            ),
            decisionID: uuid(
                "54000000-0000-0000-0000-000000000023"
            ),
            at: createdAt.addingTimeInterval(2)
        )
        let ancestor = source.snapshot()
        let categoryAID = try XCTUnwrap(
            ancestor.classifications.categories.values.first {
                $0.name == "分叉 A"
            }?.id
        )
        let categoryBID = try XCTUnwrap(
            ancestor.classifications.categories.values.first {
                $0.name == "分叉 B"
            }?.id
        )

        func makeFork(
            categoryID: TaskCategoryID,
            interactionID: UUID,
            decisionID: UUID,
            at time: Date
        ) throws -> (
            snapshot: NoonmarkSnapshot,
            envelope: ClassificationCommitEnvelope
        ) {
            let branch = try NoonmarkEngine(snapshot: ancestor)
            let before = branch.snapshot().classifications
            let receipt = try commitClassification(
                .setCurrent(
                    TaskClassificationDraft(
                        chainID: chainID,
                        category: .existing(categoryID),
                        labels: []
                    )
                ),
                on: branch,
                interactionID: interactionID,
                decisionID: decisionID,
                at: time
            )
            let snapshot = branch.snapshot()
            let changeRecord = try XCTUnwrap(
                snapshot.classifications.changeRecords.first {
                    $0.id == receipt.changeRecordID
                }
            )
            return (
                snapshot,
                try ClassificationCommitEnvelope(
                    before: before,
                    after: snapshot.classifications,
                    changeRecord: changeRecord
                )
            )
        }

        let forkA = try makeFork(
            categoryID: categoryAID,
            interactionID: uuid(
                "54000000-0000-0000-0000-000000000024"
            ),
            decisionID: uuid(
                "54000000-0000-0000-0000-000000000025"
            ),
            at: createdAt.addingTimeInterval(3)
        )
        let forkB = try makeFork(
            categoryID: categoryBID,
            interactionID: uuid(
                "54000000-0000-0000-0000-000000000026"
            ),
            decisionID: uuid(
                "54000000-0000-0000-0000-000000000027"
            ),
            at: createdAt.addingTimeInterval(4)
        )

        var imported = forkB.snapshot
        imported.classifications.changeRecords =
            try ClassificationAuditCanonicalOrder.changeRecords(
                forkB.snapshot.classifications.changeRecords
                    + [forkA.envelope.changeRecord]
            )
        imported.classifications.committedReceiptsByInteractionID
            .merge(
                forkA.snapshot.classifications
                    .committedReceiptsByInteractionID
            ) { current, _ in current }
        imported.classifications.revision = UInt64(
            imported.classifications.changeRecords.count
                + imported.classifications.snapshotEventsByTraceID
                .values.reduce(0) { $0 + $1.count }
        )
        try imported.validateIntegrity()

        let mapper = SyncRecordMapper()
        let baselineRecord = try mapper.record(
            for: ClassificationBaselineEnvelope(
                baselineID: uuid(
                    "54000000-0000-0000-0000-000000000028"
                ),
                state: ancestor.classifications,
                createdAt: createdAt.addingTimeInterval(5)
            ),
            modifiedBy: SyncDeviceID("ancestor")
        )
        let forkRecords = try [forkA.envelope, forkB.envelope].map {
            try mapper.record(
                for: $0,
                modifiedBy: SyncDeviceID("fork")
            )
        }
        let ordinaryEntries = try SyncSnapshotBaselineBuilder()
            .journalEntries(
                from: imported,
                modifiedBy: SyncDeviceID("ordinary"),
                createdAt: createdAt.addingTimeInterval(6)
            )
            .filter { $0.entityType != .classificationBaseline }
        let ordinaryRecords = try SyncRecordMaterializer().records(
            for: ordinaryEntries,
            in: imported
        )
        let evidence = ordinaryRecords + [baselineRecord] + forkRecords

        let receiver = try SyncRecordMerger(mapper: mapper).merge(
            records: evidence,
            into: NoonmarkEngine().snapshot(),
            detectedAt: createdAt.addingTimeInterval(7)
        )
        XCTAssertEqual(
            receiver.conflicts.filter {
                $0.type == .classificationCommitRejected
            }.count,
            2
        )
        XCTAssertNotEqual(
            receiver.snapshot.classifications,
            imported.classifications
        )

        XCTAssertFalse(
            SyncSnapshotBaselineCoverageAuditor().isComplete(
                snapshot: imported,
                journalEntries: [],
                remoteRecords: evidence
            )
        )

        let unsafeSuccessorResult = try SyncRecordMerger(
            mapper: mapper
        ).merge(
            records: [
                try mapper.record(
                    for: ClassificationBaselineEnvelope(
                        baselineID: uuid(
                            "54000000-0000-0000-0000-000000000029"
                        ),
                        state: imported.classifications,
                        createdAt: createdAt.addingTimeInterval(8)
                    ),
                    modifiedBy: SyncDeviceID("unsafe-successor")
                )
            ],
            into: forkA.snapshot,
            detectedAt: createdAt.addingTimeInterval(9)
        )
        XCTAssertEqual(
            unsafeSuccessorResult.conflicts.filter {
                $0.type == SyncConflictType
                    .classificationBaselineRejected
            }.count,
            1
        )
        XCTAssertEqual(
            unsafeSuccessorResult.snapshot.classifications,
            forkA.snapshot.classifications
        )
    }

    func testBaselinesWithTheSameHistoryButDifferentCurrentProjectionConflict()
        throws
    {
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(
            title: "分类投影分叉",
            now: createdAt
        )
        _ = try commitClassification(
            .createCategory(name: "投影 A", colorHex: "#2A6FDB"),
            on: source,
            interactionID: uuid(
                "54000000-0000-0000-0000-000000000030"
            ),
            decisionID: uuid(
                "54000000-0000-0000-0000-000000000031"
            ),
            at: createdAt.addingTimeInterval(1)
        )
        _ = try commitClassification(
            .createCategory(name: "投影 B", colorHex: "#0E9488"),
            on: source,
            interactionID: uuid(
                "54000000-0000-0000-0000-000000000032"
            ),
            decisionID: uuid(
                "54000000-0000-0000-0000-000000000033"
            ),
            at: createdAt.addingTimeInterval(2)
        )
        let ancestor = source.snapshot()
        let categoryAID = try XCTUnwrap(
            ancestor.classifications.categories.values.first {
                $0.name == "投影 A"
            }?.id
        )
        let categoryBID = try XCTUnwrap(
            ancestor.classifications.categories.values.first {
                $0.name == "投影 B"
            }?.id
        )

        func makeFork(
            categoryID: TaskCategoryID,
            interactionID: UUID,
            decisionID: UUID,
            at time: Date
        ) throws -> NoonmarkSnapshot {
            let branch = try NoonmarkEngine(snapshot: ancestor)
            _ = try commitClassification(
                .setCurrent(
                    TaskClassificationDraft(
                        chainID: chainID,
                        category: .existing(categoryID),
                        labels: []
                    )
                ),
                on: branch,
                interactionID: interactionID,
                decisionID: decisionID,
                at: time
            )
            return branch.snapshot()
        }

        let forkA = try makeFork(
            categoryID: categoryAID,
            interactionID: uuid(
                "54000000-0000-0000-0000-000000000034"
            ),
            decisionID: uuid(
                "54000000-0000-0000-0000-000000000035"
            ),
            at: createdAt.addingTimeInterval(3)
        )
        let forkB = try makeFork(
            categoryID: categoryBID,
            interactionID: uuid(
                "54000000-0000-0000-0000-000000000036"
            ),
            decisionID: uuid(
                "54000000-0000-0000-0000-000000000037"
            ),
            at: createdAt.addingTimeInterval(4)
        )

        func addAuditFacts(
            from other: NoonmarkSnapshot,
            to selected: NoonmarkSnapshot
        ) throws -> NoonmarkSnapshot {
            var combined = selected
            combined.classifications.changeRecords =
                try ClassificationAuditCanonicalOrder.changeRecords(
                    selected.classifications.changeRecords
                        + other.classifications.changeRecords.filter {
                            selected.classifications.changeRecords
                                .contains($0) == false
                        }
                )
            combined.classifications.committedReceiptsByInteractionID
                .merge(
                    other.classifications
                        .committedReceiptsByInteractionID
                ) { current, _ in current }
            combined.classifications.revision = UInt64(
                combined.classifications.changeRecords.count
                    + combined.classifications.snapshotEventsByTraceID
                    .values.reduce(0) { $0 + $1.count }
            )
            try combined.validateIntegrity()
            return combined
        }

        let projectionA = try addAuditFacts(from: forkB, to: forkA)
        let projectionB = try addAuditFacts(from: forkA, to: forkB)
        XCTAssertNotEqual(
            projectionA.classifications,
            projectionB.classifications
        )
        XCTAssertTrue(
            projectionA.classifications.containsClassificationHistory(
                from: projectionB.classifications
            )
        )
        XCTAssertTrue(
            projectionB.classifications.containsClassificationHistory(
                from: projectionA.classifications
            )
        )

        let mapper = SyncRecordMapper()
        let records = try [
            ClassificationBaselineEnvelope(
                baselineID: uuid(
                    "54000000-0000-0000-0000-000000000038"
                ),
                state: projectionA.classifications,
                createdAt: createdAt.addingTimeInterval(5)
            ),
            ClassificationBaselineEnvelope(
                baselineID: uuid(
                    "54000000-0000-0000-0000-000000000039"
                ),
                state: projectionB.classifications,
                createdAt: createdAt.addingTimeInterval(6)
            )
        ].map {
            try mapper.record(
                for: $0,
                modifiedBy: SyncDeviceID("projection-fork")
            )
        }
        var emptyReceiver = ancestor
        emptyReceiver.classifications = TaskClassificationState()
        let result = try SyncRecordMerger(mapper: mapper).merge(
            records: records,
            into: emptyReceiver,
            detectedAt: createdAt.addingTimeInterval(7)
        )

        XCTAssertEqual(
            result.conflicts.filter {
                $0.type == SyncConflictType.classificationBaselineRejected
            }.count,
            1
        )
        XCTAssertEqual(
            result.snapshot.classifications,
            projectionA.classifications
        )
    }

    func testDefaultLookingPreferencesWithAdvancedClockStillRequireEvidence()
        throws
    {
        var snapshot = NoonmarkEngine().snapshot()
        snapshot.preferences = AppPreferences(
            theme: .coolGray,
            language: .chinese,
            themeLanguageUpdatedAt: createdAt,
            themeLanguageWriterID:
            AppPreferences.bootstrapThemeLanguageWriterID
        )
        try snapshot.validateIntegrity()
        let auditor = SyncSnapshotBaselineCoverageAuditor()

        XCTAssertFalse(
            auditor.isComplete(
                snapshot: snapshot,
                journalEntries: []
            )
        )

        let entries = try SyncSnapshotBaselineBuilder()
            .journalEntries(
                from: snapshot,
                modifiedBy: SyncDeviceID("baseline-device"),
                createdAt: createdAt
            )
        XCTAssertTrue(
            auditor.isComplete(
                snapshot: snapshot,
                journalEntries: entries
            )
        )
    }

    private func commitClassification(
        _ intent: ClassificationIntent,
        on engine: NoonmarkEngine,
        interactionID: UUID,
        decisionID: UUID,
        at now: Date
    ) throws -> ClassificationReceipt {
        let plan = try engine.prepareClassification(
            intent,
            source: .userDirect,
            interactionID: interactionID,
            now: now
        )
        return try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: decisionID),
            now: now
        )
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
