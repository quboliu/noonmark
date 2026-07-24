@testable import NoonmarkCore
@testable import NoonmarkStorage
import NoonmarkSync
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

        let transport = try InMemorySyncTransport(
            records: [fixture.parentRecord]
        )
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
        let engine = NoonmarkEngine()
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
            status: .deferred,
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
        let transport = try InMemorySyncTransport(
            records: [siblingRecord, parentRecord]
        )

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

    func testAllRejectedVariantProviderFactsSurviveCoordinatorRestart() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let receiver = NoonmarkEngine()
        let chainID = try receiver.createPoolTask(
            title: "跨重启 provider evidence",
            now: now
        )
        let traceID = try receiver.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let baseline = receiver.snapshot()
        try engineRepository.save(baseline)
        let sharedCommitID = uuid("B3000000-0000-0000-0000-000000000001")
        let firstCategory = TaskCategory(
            id: TaskCategoryID(uuid("B3000000-0000-0000-0000-000000000002")),
            name: "持久 provider 甲",
            colorHex: "#2A6FDB",
            now: now.addingTimeInterval(1)
        )
        let secondCategory = TaskCategory(
            id: TaskCategoryID(uuid("B3000000-0000-0000-0000-000000000003")),
            name: "持久 provider 乙",
            colorHex: "#0E9488",
            now: now.addingTimeInterval(1)
        )
        let firstCommit = try classificationCreateRecord(
            category: firstCategory,
            commitID: sharedCommitID,
            deviceID: "terminal-provider-a"
        )
        let secondCommit = try classificationCreateRecord(
            category: secondCategory,
            commitID: sharedCommitID,
            deviceID: "terminal-provider-b"
        )
        let transport = HostileFixtureSyncTransport(
            uncheckedRecords: [firstCommit, secondCommit]
        )

        let collision = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(10))

        XCTAssertEqual(collision.appliedCount, 0)
        XCTAssertEqual(collision.waitingCount, 0)
        XCTAssertEqual(collision.conflictCount, 2)
        XCTAssertEqual(try syncRepository.unresolvedConflicts().count, 2)

        let mapper = SyncRecordMapper()
        let events = try [
            classificationEventRecord(
                id: uuid("B3000000-0000-0000-0000-000000000004"),
                traceID: traceID,
                category: firstCategory,
                mapper: mapper
            ),
            classificationEventRecord(
                id: uuid("B3000000-0000-0000-0000-000000000005"),
                traceID: traceID,
                category: secondCategory,
                mapper: mapper
            )
        ]
        await transport.removeAll()
        try await transport.push(events)

        let afterRestart = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(20))

        XCTAssertEqual(afterRestart.appliedCount, 0)
        XCTAssertEqual(afterRestart.waitingCount, 0)
        XCTAssertEqual(afterRestart.conflictCount, 2)
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        XCTAssertEqual(try engineRepository.load().snapshot(), baseline)
        XCTAssertEqual(
            try syncRepository.unresolvedConflicts().filter {
                $0.type == .traceClassificationEventRejected
            }.count,
            2
        )
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
        receiverSnapshot: NoonmarkSnapshot,
        parentRecord: SyncRecord,
        childRecord: SyncRecord
    ) {
        let baseEngine = NoonmarkEngine()
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

        let sender = try NoonmarkEngine(snapshot: base)
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

        let receiver = try NoonmarkEngine(snapshot: base)
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
            source: .deterministicDomainAction(reason: "terminal provider test"),
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
            planDigest: String(repeating: "b", count: 64)
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
                    status: .deferred,
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
            modifiedBy: SyncDeviceID("terminal-provider-event")
        )
    }

    private func assertExactConflictEvidenceIsSticky(
        resolution: SyncConflictResolution,
        suffix: String
    ) async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        try engineRepository.save(NoonmarkEngine().snapshot())
        let remoteRecord = SyncRecord(
            id: SyncRecordID("day:\(suffix)"),
            entityType: .day,
            entityID: suffix,
            modifiedAt: now,
            modifiedByDeviceID: SyncDeviceID("remote-mac"),
            payload: Data([0x00, 0x7F, 0x80, 0xFF])
        )
        let transport = HostileFixtureSyncTransport(
            uncheckedRecords: [remoteRecord]
        )

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
        to engine: NoonmarkEngine,
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
            .appendingPathComponent("noonmark-terminal-ledger-\(UUID().uuidString)")
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
