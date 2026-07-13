@testable import SuntraceCore
@testable import SuntraceStorage
import SuntraceSync
import XCTest

final class SQLiteSyncTerminalLedgerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testRejectedClassificationParentTerminatesChildAfterCoordinatorRestart() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let fixture = try makeClassificationCausalConflictFixture()
        try engineRepository.save(fixture.receiverSnapshot)

        let transport = InMemorySyncTransport(records: [fixture.parentRecord])
        let first = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(20))

        XCTAssertEqual(first.appliedCount, 0)
        XCTAssertEqual(first.waitingCount, 0)
        XCTAssertEqual(first.conflictCount, 1)
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        XCTAssertEqual(try syncRepository.terminalRejections().count, 1)

        await transport.removeAll()
        try await transport.push([fixture.childRecord])
        let afterRestart = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(30))

        XCTAssertEqual(afterRestart.appliedCount, 0)
        XCTAssertEqual(afterRestart.waitingCount, 0)
        XCTAssertEqual(afterRestart.conflictCount, 1)
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        XCTAssertEqual(try engineRepository.load().snapshot(), fixture.receiverSnapshot)
        XCTAssertEqual(try syncRepository.terminalRejections().count, 2)

        let reconciledLocal = try engineRepository.load()
        _ = try commitClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: fixture.chainID,
                    category: nil,
                    labels: []
                )
            ),
            to: reconciledLocal,
            interactionID: uuid("B1000000-0000-0000-0000-000000000013"),
            decisionID: uuid("B1000000-0000-0000-0000-000000000014"),
            at: now.addingTimeInterval(40)
        )
        try engineRepository.save(reconciledLocal.snapshot())
        XCTAssertNil(
            try engineRepository.load().snapshot()
                .classifications.currentByChainID[fixture.chainID]?.categoryID
        )

        await transport.removeAll()
        try await transport.push([fixture.parentRecord])
        let retransmittedParent = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(50))

        XCTAssertEqual(retransmittedParent.appliedCount, 0)
        XCTAssertEqual(retransmittedParent.waitingCount, 0)
        XCTAssertEqual(retransmittedParent.conflictCount, 1)
        XCTAssertNil(
            try engineRepository.load().snapshot()
                .classifications.currentByChainID[fixture.chainID]?.categoryID
        )
        XCTAssertEqual(try syncRepository.terminalRejections().count, 2)
    }

    func testRejectedTraceEventParentTerminatesChildAfterCoordinatorRestart() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "跨重启轨迹事件", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        try engineRepository.save(engine.snapshot())

        let rejectedParent = try traceEvent(
            id: uuid("B2000000-0000-0000-0000-000000000001"),
            traceID: traceID,
            status: .continued,
            revision: 1,
            predecessorID: nil
        )
        let rejectedSibling = try traceEvent(
            id: uuid("B2000000-0000-0000-0000-000000000002"),
            traceID: traceID,
            status: .unfinished,
            revision: 1,
            predecessorID: nil
        )
        let child = try traceEvent(
            id: uuid("B2000000-0000-0000-0000-000000000003"),
            traceID: traceID,
            status: .abandoned,
            revision: 2,
            predecessorID: rejectedParent.event.id
        )
        let mapper = SyncRecordMapper()
        let parentRecord = try mapper.record(
            for: rejectedParent,
            modifiedBy: SyncDeviceID("remote-mac")
        )
        let siblingRecord = try mapper.record(
            for: rejectedSibling,
            modifiedBy: SyncDeviceID("remote-mac")
        )
        let childRecord = try mapper.record(
            for: child,
            modifiedBy: SyncDeviceID("remote-mac")
        )
        let transport = InMemorySyncTransport(records: [siblingRecord, parentRecord])

        let first = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(20))

        XCTAssertEqual(first.appliedCount, 0)
        XCTAssertEqual(first.waitingCount, 0)
        XCTAssertEqual(first.conflictCount, 2)
        XCTAssertEqual(try syncRepository.terminalRejections().count, 2)

        await transport.removeAll()
        try await transport.push([childRecord])
        let afterRestart = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(30))

        XCTAssertEqual(afterRestart.appliedCount, 0)
        XCTAssertEqual(afterRestart.waitingCount, 0)
        XCTAssertEqual(afterRestart.conflictCount, 1)
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        XCTAssertEqual(try syncRepository.terminalRejections().count, 3)
        XCTAssertEqual(try engineRepository.load().snapshot(), engine.snapshot())
    }

    func testExactConflictEvidenceDoesNotMultiplyAndKeepLocalResolutionIsSticky() async throws {
        try await assertExactConflictEvidenceIsSticky(
            resolution: .keepLocal,
            suffix: "keep-local"
        )
    }

    func testExactConflictEvidenceDoesNotMultiplyAndIgnoredResolutionIsSticky() async throws {
        try await assertExactConflictEvidenceIsSticky(
            resolution: .ignored,
            suffix: "ignored"
        )
    }

    private func makeClassificationCausalConflictFixture() throws -> (
        chainID: TaskChainID,
        receiverSnapshot: SuntraceSnapshot,
        parentRecord: SyncRecord,
        childRecord: SyncRecord
    ) {
        let baseEngine = SuntraceEngine()
        let chainID = try baseEngine.createPoolTask(
            title: "跨重启终局分类",
            now: now
        )
        _ = try commitClassification(
            .createCategory(name: "远端分类", colorHex: "#2A6FDB"),
            to: baseEngine,
            interactionID: uuid("B1000000-0000-0000-0000-000000000001"),
            decisionID: uuid("B1000000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        _ = try commitClassification(
            .createCategory(name: "本地分类", colorHex: "#0E9488"),
            to: baseEngine,
            interactionID: uuid("B1000000-0000-0000-0000-000000000003"),
            decisionID: uuid("B1000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(2)
        )
        _ = try commitClassification(
            .createLabel(name: "后代标签", colorHex: "#7C5CFF"),
            to: baseEngine,
            interactionID: uuid("B1000000-0000-0000-0000-000000000005"),
            decisionID: uuid("B1000000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(3)
        )
        let base = baseEngine.snapshot()
        let remoteCategoryID = try XCTUnwrap(
            base.classifications.categories.values.first { $0.name == "远端分类" }?.id
        )
        let localCategoryID = try XCTUnwrap(
            base.classifications.categories.values.first { $0.name == "本地分类" }?.id
        )
        let labelID = try XCTUnwrap(base.classifications.labels.values.first?.id)

        let sender = try SuntraceEngine(snapshot: base)
        let beforeParent = sender.snapshot().classifications
        let parentReceipt = try commitClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(remoteCategoryID),
                    labels: []
                )
            ),
            to: sender,
            interactionID: uuid("B1000000-0000-0000-0000-000000000007"),
            decisionID: uuid("B1000000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(4)
        )
        let afterParent = sender.snapshot().classifications
        let parentEnvelope = try envelope(
            before: beforeParent,
            after: afterParent,
            receipt: parentReceipt
        )
        let childReceipt = try commitClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(remoteCategoryID),
                    labels: [.existing(labelID)]
                )
            ),
            to: sender,
            interactionID: uuid("B1000000-0000-0000-0000-000000000009"),
            decisionID: uuid("B1000000-0000-0000-0000-000000000010"),
            at: now.addingTimeInterval(5)
        )
        let afterChild = sender.snapshot().classifications
        let childEnvelope = try envelope(
            before: afterParent,
            after: afterChild,
            receipt: childReceipt
        )
        XCTAssertTrue(
            childEnvelope.delta.mutation.predecessorChangeRecordIDs.contains(
                parentReceipt.changeRecordID
            )
        )

        let receiver = try SuntraceEngine(snapshot: base)
        _ = try commitClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(localCategoryID),
                    labels: []
                )
            ),
            to: receiver,
            interactionID: uuid("B1000000-0000-0000-0000-000000000011"),
            decisionID: uuid("B1000000-0000-0000-0000-000000000012"),
            at: now.addingTimeInterval(6)
        )

        let mapper = SyncRecordMapper()
        return try (
            chainID,
            receiver.snapshot(),
            mapper.record(
                for: parentEnvelope,
                modifiedBy: SyncDeviceID("remote-mac")
            ),
            mapper.record(
                for: childEnvelope,
                modifiedBy: SyncDeviceID("remote-mac")
            )
        )
    }

    private func envelope(
        before: TaskClassificationState,
        after: TaskClassificationState,
        receipt: ClassificationReceipt
    ) throws -> ClassificationCommitEnvelope {
        try ClassificationCommitEnvelope(
            before: before,
            after: after,
            changeRecord: try XCTUnwrap(after.changeRecords.first {
                $0.id == receipt.changeRecordID
            })
        )
    }

    private func traceEvent(
        id: UUID,
        traceID: DayTraceID,
        status: TraceStatus,
        revision: UInt64,
        predecessorID: UUID?
    ) throws -> TraceClassificationEventEnvelope {
        try TraceClassificationEventEnvelope(
            event: TraceClassificationSnapshot(
                id: id,
                traceID: traceID,
                status: status,
                category: nil,
                labels: [],
                capturedAt: now.addingTimeInterval(TimeInterval(revision)),
                revision: revision
            ),
            predecessorEventID: predecessorID
        )
    }

    private func assertExactConflictEvidenceIsSticky(
        resolution: SyncConflictResolution,
        suffix: String
    ) async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        try engineRepository.save(SuntraceEngine().snapshot())
        let remoteRecord = SyncRecord(
            id: SyncRecordID("day:\(suffix)"),
            entityType: .day,
            entityID: suffix,
            modifiedAt: now,
            modifiedByDeviceID: SyncDeviceID("remote-mac"),
            payload: Data([0x00, 0x7F, 0x80, 0xFF])
        )
        let transport = InMemorySyncTransport(records: [remoteRecord])

        let first = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(1))
        let firstConflict = try XCTUnwrap(syncRepository.unresolvedConflicts().first)
        XCTAssertEqual(first.conflictCount, 1)
        XCTAssertEqual(firstConflict.remoteRecord, remoteRecord)

        let repeated = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(2))
        let repeatedConflicts = try syncRepository.unresolvedConflicts()
        XCTAssertEqual(repeated.conflictCount, 1)
        XCTAssertEqual(repeatedConflicts.map(\.id), [firstConflict.id])

        try syncRepository.resolveConflict(
            id: firstConflict.id,
            resolution: resolution,
            resolvedAt: now.addingTimeInterval(3)
        )
        _ = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(4))

        XCTAssertTrue(try syncRepository.unresolvedConflicts().isEmpty)
    }

    @discardableResult
    private func commitClassification(
        _ intent: ClassificationIntent,
        to engine: SuntraceEngine,
        interactionID: UUID,
        decisionID: UUID,
        at time: Date
    ) throws -> ClassificationReceipt {
        let plan = try engine.prepareClassification(
            intent,
            source: .userDirect,
            interactionID: interactionID,
            now: time
        )
        return try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: decisionID),
            now: time
        )
    }

    private func makeDatabaseURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("suntrace-terminal-ledger-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func uuid(_ rawValue: String) -> UUID {
        guard let value = UUID(uuidString: rawValue) else {
            preconditionFailure("invalid test UUID: \(rawValue)")
        }
        return value
    }
}
