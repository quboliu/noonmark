@testable import NoonmarkCore
@testable import NoonmarkStorage
@testable import NoonmarkSync
import XCTest

final class SQLiteImmutableIdentityCollisionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDownloadPersistsBothCollisionVariantsWithOneDeterministicTerminalAnchor() async throws {
        let fixture = try makeFixture()
        let permutations = [
            [fixture.firstVariant, fixture.secondVariant],
            [fixture.secondVariant, fixture.firstVariant]
        ]
        var terminalAnchorIDs: [UUID] = []

        for records in permutations {
            let databaseURL = makeDatabaseURL()
            let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
            let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
            try engineRepository.save(fixture.baseSnapshot)
            let coordinator = SQLiteSyncDownloadCoordinator(
                databaseURL: databaseURL,
                transport: ImmutableCollisionTransport(records: records)
            )

            let first = try await coordinator.downloadAndMerge(
                detectedAt: now.addingTimeInterval(10)
            )

            XCTAssertEqual(
                first,
                SQLiteSyncDownloadResult(
                    fetchedCount: 2,
                    appliedCount: 0,
                    waitingCount: 0,
                    conflictCount: 2
                )
            )
            XCTAssertEqual(
                try engineRepository.load().snapshot(),
                fixture.baseSnapshot
            )
            XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
            let firstConflicts = try syncRepository.unresolvedConflicts()
            XCTAssertEqual(firstConflicts.count, 2)
            XCTAssertEqual(Set(firstConflicts.map(\.id)).count, 2)
            for record in records {
                XCTAssertTrue(
                    firstConflicts.contains {
                        $0.remoteRecord.exactlyMatches(record)
                    }
                )
            }
            let firstTerminal = try XCTUnwrap(
                syncRepository.terminalRejections().only
            )
            XCTAssertEqual(
                firstTerminal.identity,
                .classificationCommit(fixture.parentChangeRecordID)
            )
            XCTAssertTrue(
                firstConflicts.contains { $0.id == firstTerminal.conflict.id }
            )

            let replay = try await coordinator.downloadAndMerge(
                detectedAt: now.addingTimeInterval(20)
            )

            XCTAssertEqual(
                replay,
                SQLiteSyncDownloadResult(
                    fetchedCount: 2,
                    appliedCount: 0,
                    waitingCount: 0,
                    conflictCount: 2
                )
            )
            XCTAssertEqual(
                Set(try syncRepository.unresolvedConflicts().map(\.id)),
                Set(firstConflicts.map(\.id))
            )
            let replayTerminal = try XCTUnwrap(
                syncRepository.terminalRejections().only
            )
            XCTAssertEqual(replayTerminal.conflict.id, firstTerminal.conflict.id)
            XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
            XCTAssertEqual(
                try engineRepository.load().snapshot(),
                fixture.baseSnapshot
            )
            terminalAnchorIDs.append(firstTerminal.conflict.id)
        }

        XCTAssertEqual(
            Set(terminalAnchorIDs).count,
            1,
            "terminal anchor must not depend on transport record order"
        )
    }

    private func makeFixture() throws -> SQLiteImmutableCollisionFixture {
        let source = NoonmarkEngine()
        let baseSnapshot = source.snapshot()
        let before = baseSnapshot.classifications
        let plan = try source.prepareClassification(
            .createCategory(name: "SQLite 不可变碰撞", colorHex: "#2A6FDB"),
            source: .userDirect,
            interactionID: UUID(uuidString: "74100000-0000-0000-0000-000000000001")!,
            now: now.addingTimeInterval(1)
        )
        let receipt = try source.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(uuidString: "74100000-0000-0000-0000-000000000002")!
            ),
            now: now.addingTimeInterval(1)
        )
        let after = source.snapshot().classifications
        let envelope = try ClassificationCommitEnvelope(
            before: before,
            after: after,
            changeRecord: try XCTUnwrap(
                after.changeRecords.first { $0.id == receipt.changeRecordID }
            )
        )
        let mapper = SyncRecordMapper()
        let firstVariant = try mapper.record(
            for: envelope,
            modifiedBy: SyncDeviceID("sqlite-immutable-device-a")
        )
        let secondVariant = try mapper.record(
            for: envelope,
            modifiedBy: SyncDeviceID("sqlite-immutable-device-b")
        )
        XCTAssertEqual(firstVariant.id, secondVariant.id)
        XCTAssertFalse(firstVariant.exactlyMatches(secondVariant))

        return SQLiteImmutableCollisionFixture(
            baseSnapshot: baseSnapshot,
            parentChangeRecordID: receipt.changeRecordID,
            firstVariant: firstVariant,
            secondVariant: secondVariant
        )
    }

    private func makeDatabaseURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-immutable-collision-\(UUID().uuidString)"
            )
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private struct SQLiteImmutableCollisionFixture {
    let baseSnapshot: NoonmarkSnapshot
    let parentChangeRecordID: UUID
    let firstVariant: SyncRecord
    let secondVariant: SyncRecord
}

private struct ImmutableCollisionTransport: SyncRecordTransport {
    let records: [SyncRecord]

    func push(_: [SyncRecord]) async throws {}

    func fetchAll() async throws -> [SyncRecord] {
        records
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
