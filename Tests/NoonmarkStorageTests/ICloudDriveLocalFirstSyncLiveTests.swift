import CryptoKit
import Darwin
@testable import NoonmarkStorage
import NoonmarkCore
import NoonmarkSync
import XCTest

final class ICloudDriveLocalFirstSyncLiveTests: XCTestCase {
    private enum LiveTestError: Error {
        case convergenceDeadlineExceeded
    }

    private struct RoundEvidence {
        let round: ICloudAppendOnlyTestRound
        let objectDigests: [String: String]
    }

    private let now = Date(timeIntervalSinceReferenceDate: 810_200_000)
    private let publicationWatermarkStore =
        InMemoryReplicationPublicationWatermarkStore()

    func testMultipleFreshRoundsConvergeThroughRealICloudWithoutMutation()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NOONMARK_LIVE_ICLOUD_SYNC"] == "1" else {
            throw XCTSkip(
                "Set NOONMARK_LIVE_ICLOUD_SYNC=1 to run this explicit live test."
            )
        }
        let sessionID = try requiredUUID(
            environment["NOONMARK_ICLOUD_APPEND_ONLY_SESSION_ID"]
        )
        let roundIDs = try requiredRoundIDs(
            environment["NOONMARK_ICLOUD_APPEND_ONLY_ROUND_IDS"]
        )
        let session = try ICloudAppendOnlyTestNamespace.beginSession(
            sessionID: sessionID
        )
        var completed: [RoundEvidence] = []

        for (index, roundID) in roundIDs.enumerated() {
            let round = try ICloudAppendOnlyTestNamespace.createRound(
                in: session,
                roundID: roundID
            )
            XCTAssertTrue(try regularFiles(in: round.rootURL).isEmpty)

            let sourceURL = makeDatabaseURL("source-\(index)")
            let targetURL = makeDatabaseURL("target-\(index)")
            let sourceRepository = SQLiteEngineRepository(
                databaseURL: sourceURL
            )
            let targetRepository = SQLiteEngineRepository(
                databaseURL: targetURL
            )
            try sourceRepository.save(NoonmarkEngine().snapshot())
            try targetRepository.save(NoonmarkEngine().snapshot())

            let expectedTitle = "Append-only live round \(index + 1)"
            let sourceEngine = NoonmarkEngine()
            _ = try sourceEngine.createPoolTask(
                title: expectedTitle,
                now: now.addingTimeInterval(TimeInterval(index))
            )
            try sourceRepository.save(
                sourceEngine.snapshot(),
                recordingChangesFor: SyncDeviceID("append-only-source"),
                changedAt: now.addingTimeInterval(TimeInterval(index))
            )

            let sourceProducerID = UUID()
            let targetProducerID = UUID()
            let source = try makeRuntime(
                databaseURL: sourceURL,
                round: round,
                producerID: sourceProducerID
            )
            let sourceResult = try await reconcileUntilConverged(
                source,
                startingAt: now.addingTimeInterval(
                    TimeInterval(index * 100 + 1)
                )
            )
            XCTAssertGreaterThanOrEqual(
                sourceResult.maximumConfirmedLocalPublicationCount,
                1
            )

            let sourceEvidence = try immutableObjectDigests(
                in: round.rootURL
            )
            XCTAssertEqual(sourceEvidence.count, 10)
            XCTAssertTrue(try mutableHeadFiles(in: round.rootURL).isEmpty)

            let target = try makeRuntime(
                databaseURL: targetURL,
                round: round,
                producerID: targetProducerID
            )
            let targetResult = try await reconcileUntilConverged(
                target,
                startingAt: now.addingTimeInterval(
                    TimeInterval(index * 100 + 20)
                )
            )
            XCTAssertGreaterThanOrEqual(
                targetResult.maximumAppliedRemotePublicationCount,
                1
            )
            XCTAssertEqual(
                try targetRepository.load().taskPool().map(
                    \.definition.title
                ),
                [expectedTitle]
            )

            let restartedTarget = try makeRuntime(
                databaseURL: targetURL,
                round: round,
                producerID: targetProducerID
            )
            let restartResult = try await reconcileUntilConverged(
                restartedTarget,
                startingAt: now.addingTimeInterval(
                    TimeInterval(index * 100 + 40)
                )
            )
            XCTAssertEqual(
                restartResult.maximumAppliedRemotePublicationCount,
                0
            )
            let finalEvidence = try immutableObjectDigests(
                in: round.rootURL
            )
            for (path, digest) in sourceEvidence {
                XCTAssertEqual(finalEvidence[path], digest)
            }
            XCTAssertTrue(try mutableHeadFiles(in: round.rootURL).isEmpty)

            completed.append(
                RoundEvidence(
                    round: round,
                    objectDigests: finalEvidence
                )
            )
            for evidence in completed {
                XCTAssertEqual(
                    try immutableObjectDigests(
                        in: evidence.round.rootURL
                    ),
                    evidence.objectDigests
                )
            }
        }

        XCTAssertEqual(completed.count, roundIDs.count)
        XCTAssertTrue(completed.allSatisfy { $0.objectDigests.count >= 10 })
        print(
            "Live iCloud evidence: round_count=\(completed.count) "
                + "repository_file_counts="
                + completed.map { String($0.objectDigests.count) }
                .joined(separator: ",")
                + " mutable_head_count=0"
        )
    }

    func testStressRoundConvergesIntoIndependentSQLiteAndRestartsWithoutReplay()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NOONMARK_LIVE_ICLOUD_SYNC"] == "1",
              environment["NOONMARK_REPLICATION_V2_STRESS_SECONDARY"] == "1"
        else {
            throw XCTSkip(
                "Set the explicit stress-secondary live iCloud gates to run this test."
            )
        }
        let sessionID = try requiredUUID(
            environment["NOONMARK_ICLOUD_APPEND_ONLY_SESSION_ID"]
        )
        let roundID = try requiredUUID(
            environment["NOONMARK_ICLOUD_APPEND_ONLY_ROUND_ID"]
        )
        let sourceDatabaseURL = try requiredRegularDatabaseURL(
            environment["NOONMARK_REPLICATION_V2_STRESS_SOURCE_DATABASE"]
        )
        let round = try ICloudAppendOnlyTestNamespace.reopenRound(
            sessionID: sessionID,
            roundID: roundID
        )
        let inventoryBefore = try immutableObjectDigests(in: round.rootURL)
        let expected = try SQLiteEngineRepository(
            databaseURL: sourceDatabaseURL
        ).load().snapshot()
        let targetURL = makeDatabaseURL("stress-secondary")
        let targetRepository = SQLiteEngineRepository(databaseURL: targetURL)
        try targetRepository.save(NoonmarkEngine().snapshot())
        let targetLocalPreferences = try targetRepository.load().snapshot()
            .preferences
        let expectedOnTarget = snapshot(
            expected,
            preservingLocalPreferencesFrom: targetLocalPreferences
        )
        let targetProducerID = UUID()
        let target = try makeRuntime(
            databaseURL: targetURL,
            round: round,
            producerID: targetProducerID
        )

        let first = try await reconcileUntilConverged(
            target,
            startingAt: now.addingTimeInterval(10000)
        )
        XCTAssertGreaterThan(first.maximumAppliedRemotePublicationCount, 0)
        try assertSnapshotsExactlyEqual(
            try targetRepository.load().snapshot(),
            expectedOnTarget
        )
        let inventoryAfterApply = try immutableObjectDigests(
            in: round.rootURL
        )
        assertInventory(
            inventoryAfterApply,
            preserves: inventoryBefore
        )

        let restarted = try makeRuntime(
            databaseURL: targetURL,
            round: round,
            producerID: targetProducerID
        )
        let second = try await reconcileUntilConverged(
            restarted,
            startingAt: now.addingTimeInterval(20000)
        )
        XCTAssertEqual(second.maximumAppliedRemotePublicationCount, 0)
        try assertSnapshotsExactlyEqual(
            try targetRepository.load().snapshot(),
            expectedOnTarget
        )
        let inventoryAfterRestart = try immutableObjectDigests(
            in: round.rootURL
        )
        XCTAssertEqual(inventoryAfterRestart, inventoryAfterApply)
        print(
            "Stress secondary iCloud evidence: preserved_file_count="
                + "\(inventoryBefore.count) final_file_count="
                + "\(inventoryAfterRestart.count) first_apply_positive=true "
                + "restart_apply_count=0"
        )
    }

    private func makeRuntime(
        databaseURL: URL,
        round: ICloudAppendOnlyTestRound,
        producerID: UUID
    ) throws -> LocalFirstReplication {
        let endpoint = try ICloudDriveReplicationEndpoint(round: round)
        return try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: endpoint.generationID,
            producerID: producerID,
            publicationWatermarkStore: publicationWatermarkStore,
            installedAt: now
        )
    }

    private func reconcileUntilConverged(
        _ runtime: LocalFirstReplication,
        startingAt now: Date
    ) async throws -> (
        maximumConfirmedLocalPublicationCount: Int,
        maximumAppliedRemotePublicationCount: Int
    ) {
        let deadline = Date().addingTimeInterval(120)
        var attempt = 0
        var maximumConfirmed = 0
        var maximumApplied = 0
        var lastState: LocalFirstReplicationState?
        while Date() < deadline {
            let attemptStartedAt = Date()
            do {
                let state = try await runtime.send(
                    .reconcile(
                        now: now.addingTimeInterval(TimeInterval(attempt))
                    )
                )
                lastState = state
                maximumConfirmed = max(
                    maximumConfirmed,
                    state.confirmedLocalPublicationCount
                )
                maximumApplied = max(
                    maximumApplied,
                    state.appliedRemotePublicationCount
                )
                print(
                    "Stress secondary reconcile: attempt=\(attempt) "
                        + "elapsed_ms=\(Int(Date().timeIntervalSince(attemptStartedAt) * 1000)) "
                        + "convergence=\(state.convergence.rawValue) "
                        + "pending=\(state.pendingLocalPublicationCount) "
                        + "confirmed=\(state.confirmedLocalPublicationCount) "
                        + "applied=\(state.appliedRemotePublicationCount) "
                        + "waiting=\(state.waitingRecordCount) "
                        + "incident=\(state.incident?.rawValue ?? "none")"
                )
                if state.convergence == .converged {
                    return (maximumConfirmed, maximumApplied)
                }
                XCTAssertNil(state.incident)
            } catch let error as ICloudDriveReplicationEndpointError
                where error == .downloadIncomplete
            {
                // A query deadline is a failed attempt, never upload success.
            }
            attempt += 1
            try await Task.sleep(for: .seconds(1))
        }
        if let lastState {
            print(
                "Stress secondary timeout: attempts=\(attempt) "
                    + "convergence=\(lastState.convergence.rawValue) "
                    + "pending=\(lastState.pendingLocalPublicationCount) "
                    + "confirmed=\(lastState.confirmedLocalPublicationCount) "
                    + "applied=\(lastState.appliedRemotePublicationCount) "
                    + "waiting=\(lastState.waitingRecordCount) "
                    + "incident=\(lastState.incident?.rawValue ?? "none")"
            )
        }
        XCTFail("real iCloud replication did not converge before the gate deadline")
        throw LiveTestError.convergenceDeadlineExceeded
    }

    private func requiredUUID(_ value: String?) throws -> UUID {
        try XCTUnwrap(
            value.flatMap(UUID.init(uuidString:)),
            "a new append-only iCloud session UUID is required"
        )
    }

    private func requiredRoundIDs(_ value: String?) throws -> [UUID] {
        let ids = value?.split(separator: ",").compactMap {
            UUID(uuidString: String($0))
        } ?? []
        guard ids.count >= 2,
              Set(ids).count == ids.count
        else {
            XCTFail("at least two distinct append-only iCloud round UUIDs are required")
            return []
        }
        return ids
    }

    private func requiredRegularDatabaseURL(_ value: String?) throws -> URL {
        let path = try XCTUnwrap(value)
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var metadata = stat()
        guard url.path.hasPrefix("/"),
              lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & S_IFMT != S_IFLNK
        else {
            XCTFail("stress source database must be an absolute regular file")
            throw ICloudAppendOnlyNamespaceError.invalidBoundary
        }
        return url
    }

    private func assertInventory(
        _ current: [String: String],
        preserves previous: [String: String]
    ) {
        for (path, digest) in previous {
            XCTAssertEqual(current[path], digest)
        }
        XCTAssertGreaterThanOrEqual(current.count, previous.count)
    }

    private func regularFiles(in rootURL: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw ICloudAppendOnlyNamespaceError.invalidBoundary
            }
            return values.isRegularFile == true ? url : nil
        }
    }

    private func immutableObjectDigests(
        in rootURL: URL
    ) throws -> [String: String] {
        let rootPath = rootURL.standardizedFileURL.path + "/"
        return try Dictionary(
            uniqueKeysWithValues: regularFiles(in: rootURL).map { url in
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath) else {
                    throw ICloudAppendOnlyNamespaceError.invalidBoundary
                }
                let data = try Data(contentsOf: url)
                let digest = SHA256.hash(data: data).map {
                    String(format: "%02x", $0)
                }.joined()
                return (String(path.dropFirst(rootPath.count)), digest)
            }
        )
    }

    private func mutableHeadFiles(in rootURL: URL) throws -> [URL] {
        let heads = rootURL.appendingPathComponent("v2/heads")
        guard FileManager.default.fileExists(atPath: heads.path) else {
            return []
        }
        return try regularFiles(in: heads)
    }

    private func assertSnapshotsExactlyEqual(
        _ actual: NoonmarkSnapshot,
        _ expected: NoonmarkSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard actual != expected else { return }
        let summaries = try [
            entityDifference(
                name: "days",
                actual: actual.days,
                expected: expected.days,
                id: { $0.id.description }
            ),
            entityDifference(
                name: "taskCycleSeries",
                actual: actual.taskCycleSeries,
                expected: expected.taskCycleSeries,
                id: { $0.id.description }
            ),
            entityDifference(
                name: "chains",
                actual: actual.chains,
                expected: expected.chains,
                id: { $0.id.description }
            ),
            entityDifference(
                name: "definitions",
                actual: actual.definitions,
                expected: expected.definitions,
                id: { $0.id.description }
            ),
            entityDifference(
                name: "traces",
                actual: actual.traces,
                expected: expected.traces,
                id: { $0.id.description }
            ),
            entityDifference(
                name: "subtasks",
                actual: actual.subtasks,
                expected: expected.subtasks,
                id: { $0.id.description }
            ),
            valueDifference(
                name: "preferences",
                actual: actual.preferences,
                expected: expected.preferences
            ),
            classificationDifference(
                actual: actual.classifications,
                expected: expected.classifications
            ),
            entityDifference(
                name: "ideas",
                actual: actual.ideas,
                expected: expected.ideas,
                id: { $0.id.description }
            )
        ].compactMap { $0 }
        XCTFail(
            "snapshot mismatch: " + summaries.joined(separator: "; "),
            file: file,
            line: line
        )
    }

    private func snapshot(
        _ source: NoonmarkSnapshot,
        preservingLocalPreferencesFrom target: AppPreferences
    ) -> NoonmarkSnapshot {
        var expected = source
        expected.preferences = AppPreferences(
            theme: source.preferences.theme,
            language: source.preferences.language,
            themeLanguageUpdatedAt: source.preferences
                .themeLanguageUpdatedAt,
            themeLanguageWriterID: source.preferences.themeLanguageWriterID,
            dataMode: target.dataMode,
            backupPolicy: target.backupPolicy,
            localFirstSyncPolicy: target.localFirstSyncPolicy,
            settingsPoemDisplayPolicy: target.settingsPoemDisplayPolicy,
            syncEndpointOptions: target.syncEndpointOptions
        )
        return expected
    }

    private func entityDifference<Value: Encodable>(
        name: String,
        actual: [Value],
        expected: [Value],
        id: (Value) -> String
    ) throws -> String? {
        let actualOrder = actual.map(id)
        let expectedOrder = expected.map(id)
        let actualByID = try Dictionary(
            uniqueKeysWithValues: actual.map { value in
                (id(value), try encodedDigest(value))
            }
        )
        let expectedByID = try Dictionary(
            uniqueKeysWithValues: expected.map { value in
                (id(value), try encodedDigest(value))
            }
        )
        guard actualOrder != expectedOrder || actualByID != expectedByID else {
            return nil
        }
        let actualIDs = Set(actualByID.keys)
        let expectedIDs = Set(expectedByID.keys)
        let missing = expectedIDs.subtracting(actualIDs).sorted()
        let extra = actualIDs.subtracting(expectedIDs).sorted()
        let changed = actualIDs.intersection(expectedIDs).filter {
            actualByID[$0] != expectedByID[$0]
        }.sorted()
        let reordered = missing.isEmpty && extra.isEmpty && changed.isEmpty
            && actualOrder != expectedOrder
        return "\(name){actual=\(actual.count),expected=\(expected.count),"
            + "missing=\(boundedIDs(missing)),extra=\(boundedIDs(extra)),"
            + "changed=\(boundedIDs(changed)),reordered=\(reordered)}"
    }

    private func valueDifference<Value: Encodable & Equatable>(
        name: String,
        actual: Value,
        expected: Value
    ) throws -> String? {
        guard actual != expected else { return nil }
        return "\(name){actualDigest=\(try encodedDigest(actual)),"
            + "expectedDigest=\(try encodedDigest(expected))}"
    }

    private func classificationDifference(
        actual: TaskClassificationState,
        expected: TaskClassificationState
    ) throws -> String? {
        guard actual != expected else { return nil }
        return "classifications{actualRevision=\(actual.revision),"
            + "expectedRevision=\(expected.revision),"
            + "actualCategories=\(actual.categories.count),"
            + "expectedCategories=\(expected.categories.count),"
            + "actualLabels=\(actual.labels.count),"
            + "expectedLabels=\(expected.labels.count),"
            + "actualCurrent=\(actual.currentByChainID.count),"
            + "expectedCurrent=\(expected.currentByChainID.count),"
            + "actualHistory=\(actual.relationHistory.count),"
            + "expectedHistory=\(expected.relationHistory.count),"
            + "actualChanges=\(actual.changeRecords.count),"
            + "expectedChanges=\(expected.changeRecords.count),"
            + "actualDigest=\(try encodedDigest(actual)),"
            + "expectedDigest=\(try encodedDigest(expected))}"
    }

    private func encodedDigest(
        _ value: some Encodable
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func boundedIDs(_ ids: [String]) -> String {
        let limit = 12
        let shown = ids.prefix(limit).joined(separator: ",")
        if ids.count <= limit {
            return "[\(shown)]"
        }
        return "[\(shown),...+\(ids.count - limit)]"
    }

    private func makeDatabaseURL(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-icloud-v2-live-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("Noonmark.sqlite")
    }
}
