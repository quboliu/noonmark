@testable import NoonmarkStorage
import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class ReplicationV2BackupDomainStressTests: XCTestCase {
    func testMixedDomainMutationsRemainValidAfterBackupImportAndV2Cutover()
        throws
    {
        let environment = ProcessInfo.processInfo.environment
        let snapshot: NoonmarkSnapshot = if let backupPath = environment[
            "NOONMARK_REPLICATION_V2_STRESS_BACKUP"
        ] {
            try NoonmarkDataPackage.read(
                from: URL(fileURLWithPath: backupPath)
            )
        } else {
            NoonmarkEngine().snapshot()
        }
        let todayValue = environment[
            "NOONMARK_REPLICATION_V2_STRESS_TODAY"
        ] ?? currentLocalDate().description
        let today = try XCTUnwrap(
            LocalDate(validatingISO8601Date: todayValue)
        )
        let databaseURL = makeDatabaseURL()
        let repositoryURL = makeRepositoryURL()
        let generationID = UUID()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        try engineRepository.save(snapshot)
        _ = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: ContentAddressedFileReplicationEndpoint(
                rootURL: repositoryURL,
                generationID: generationID
            ),
            generationID: generationID,
            producerID: UUID(),
            publicationWatermarkStore:
            InMemoryReplicationPublicationWatermarkStore()
        )

        var engine = try engineRepository.load()
        var mutationIndex = 0
        let deviceID = SyncDeviceID("replication-v2-backup-preflight")
        func commit<Result>(
            _ mutation: (NoonmarkEngine, Date) throws -> Result
        ) throws -> Result {
            mutationIndex += 1
            let changedAt = Date().addingTimeInterval(
                Double(mutationIndex) / 1000
            )
            let candidate = NoonmarkEngine(copying: engine)
            let result = try mutation(candidate, changedAt)
            try engineRepository.save(
                candidate.snapshot(),
                recordingChangesFor: deviceID,
                changedAt: changedAt
            )
            engine = candidate
            return result
        }

        var taskIDs: [TaskChainID] = []
        for index in 0 ..< 10 {
            taskIDs.append(
                try commit { candidate, now in
                    try candidate.createPoolTask(
                        title: "Replication V2 preflight task \(index)",
                        now: now
                    )
                }
            )
        }
        for (index, chainID) in taskIDs.enumerated() {
            try commit { candidate, now in
                _ = try candidate.appendPoolNote(
                    chainID: chainID,
                    body: "Replication V2 preflight note \(index)",
                    now: now
                )
            }
            try commit { candidate, now in
                _ = try candidate.addPlannedSubtask(
                    chainID: chainID,
                    title: "Replication V2 preflight subtask \(index)",
                    now: now
                )
            }
        }

        var traceIDs: [DayTraceID] = []
        for chainID in taskIDs {
            traceIDs.append(
                try commit { candidate, now in
                    try candidate.scheduleFromPool(
                        chainID: chainID,
                        date: today,
                        today: today,
                        now: now
                    )
                }
            )
        }
        for traceID in traceIDs.prefix(5) {
            try commit { candidate, now in
                let subtaskIDs = candidate.subtasks.values.filter {
                    $0.traceID == traceID
                }.map(\.id)
                for subtaskID in subtaskIDs {
                    try candidate.completeSubtask(
                        subtaskID,
                        today: today,
                        now: now
                    )
                }
                try candidate.markCompleted(
                    traceID: traceID,
                    today: today,
                    now: now
                )
            }
        }

        var ideaIDs: [IdeaID] = []
        for index in 0 ..< 20 {
            ideaIDs.append(
                try commit { candidate, now in
                    try candidate.appendIdea(
                        body: "Replication V2 preflight flylight \(index)",
                        now: now
                    ).id
                }
            )
        }
        for (index, ideaID) in ideaIDs.prefix(10).enumerated() {
            try commit { candidate, now in
                try candidate.editIdea(
                    id: ideaID,
                    body: "Replication V2 preflight flylight \(index) edited",
                    now: now
                )
            }
        }
        for ideaID in ideaIDs.prefix(5) {
            try commit { candidate, now in
                try candidate.deleteIdea(id: ideaID, now: now)
            }
        }
        try commit { candidate, now in
            let nextTheme: AppTheme = candidate.preferences.theme == .coolGray
                ? .warmPaper
                : .coolGray
            try candidate.updateTheme(
                nextTheme,
                writerID: deviceID.rawValue,
                now: now
            )
        }

        let persisted = try engineRepository.load().snapshot()
        XCTAssertEqual(persisted, engine.snapshot())
        XCTAssertEqual(
            persisted.traces.filter { traceIDs.contains($0.id) }.count,
            10
        )
        XCTAssertEqual(
            persisted.traces.filter {
                traceIDs.contains($0.id) && $0.status == .completed
            }.count,
            5
        )
        XCTAssertEqual(
            persisted.ideas.filter { ideaIDs.contains($0.id) }.count,
            20
        )
        XCTAssertEqual(
            persisted.ideas.filter {
                ideaIDs.contains($0.id) && $0.deletedAt != nil
            }.count,
            5
        )
    }

    private func currentLocalDate() -> LocalDate {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: Date()
        )
        return LocalDate(
            year: components.year!,
            month: components.month!,
            day: components.day!
        )
    }

    private func makeDatabaseURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-replication-v2-backup-preflight-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("Noonmark.sqlite")
    }

    private func makeRepositoryURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-replication-v2-preflight-repository-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
