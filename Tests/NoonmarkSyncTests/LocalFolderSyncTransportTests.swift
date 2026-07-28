@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class LocalFolderSyncTransportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testLocalFolderTransportPersistsRecordsAndSnapshotIndex() async throws {
        let folderURL = makeFolderURL()
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "文件夹同步", now: now)
        _ = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        let records = try SyncRecordMapper().records(from: engine.snapshot(), modifiedBy: SyncDeviceID("mac-a"))

        let transport = LocalFolderSyncTransport(rootURL: folderURL)
        try await transport.push(records)

        let restored = try await LocalFolderSyncTransport(rootURL: folderURL).fetchAll()
        let snapshots = try await transport.fetchSnapshots()

        XCTAssertEqual(restored, records.sorted {
            if $0.entityType.rawValue != $1.entityType.rawValue {
                return $0.entityType.rawValue < $1.entityType.rawValue
            }
            return $0.id.rawValue < $1.id.rawValue
        })
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.recordCount, records.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("refs/latest").path))
    }

    func testRecurringBatchPublicationIsAllOrNothingAcrossInjectedFailures() async throws {
        let engine = NoonmarkEngine()
        _ = try engine.createTaskCycleSeries(
            title: "四十天复盘",
            startDate: today,
            endDate: LocalDate("2026-08-13"),
            schedule: .daily,
            today: today,
            now: now
        )
        let records = try SyncRecordMapper().records(
            from: engine.snapshot(),
            modifiedBy: SyncDeviceID("mac-cycle")
        )
        XCTAssertGreaterThan(records.count, 100)

        for failurePoint in [
            LocalFolderSyncPublicationPoint.willPublishBatch,
            .didPublishBatch
        ] {
            let folderURL = makeFolderURL()
            let transport = LocalFolderSyncTransport(
                rootURL: folderURL
            ) { point in
                if point == failurePoint {
                    throw InjectedPublicationError.interrupted
                }
            }

            do {
                try await transport.push(records)
                XCTFail("injected publication failure must remain visible")
            } catch {
                XCTAssertEqual(
                    error as? InjectedPublicationError,
                    .interrupted
                )
            }

            let fetched = try await LocalFolderSyncTransport(
                rootURL: folderURL
            ).fetchAll()
            if failurePoint == .willPublishBatch {
                XCTAssertTrue(fetched.isEmpty)
            } else {
                XCTAssertEqual(
                    Set(fetched.map(\.id)),
                    Set(records.map(\.id))
                )
                let mergeResult = SyncRecordMerger().merge(
                    records: fetched,
                    into: try ValidatedSyncSnapshot(
                        NoonmarkEngine().snapshot()
                    ),
                    detectedAt: now.addingTimeInterval(1)
                )
                XCTAssertTrue(mergeResult.conflicts.isEmpty)
                XCTAssertTrue(mergeResult.waitingRecords.isEmpty)
                XCTAssertNoThrow(
                    try mergeResult.snapshot.validateIntegrity()
                )
            }

            let recoveringTransport = LocalFolderSyncTransport(
                rootURL: folderURL
            )
            let snapshotsBeforeRecovery = try await recoveringTransport
                .fetchSnapshots()
            XCTAssertTrue(snapshotsBeforeRecovery.isEmpty)
            try await recoveringTransport.push(records)

            let repaired = try await recoveringTransport.fetchAll()
            let snapshots = try await recoveringTransport.fetchSnapshots()
            XCTAssertEqual(
                Set(repaired.map(\.id)),
                Set(records.map(\.id))
            )
            XCTAssertEqual(snapshots.count, 1)
            XCTAssertEqual(snapshots.first?.recordCount, records.count)
            XCTAssertEqual(try batchURLs(in: folderURL).count, 1)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    at: folderURL.appendingPathComponent(
                        "records",
                        isDirectory: true
                    ),
                    includingPropertiesForKeys: nil
                )
                .filter { $0.pathExtension == "json" }
                .count,
                records.count
            )
            XCTAssertEqual(
                try String(
                    contentsOf: folderURL
                        .appendingPathComponent("refs", isDirectory: true)
                        .appendingPathComponent("latest"),
                    encoding: .utf8
                ),
                snapshots.first?.id
            )
        }
    }

    func testConcurrentCommitHeadsMergeAndTheNextPushJoinsThem() async throws {
        let first = try ordinaryRecord(variant: "first")
        let second = try ordinaryRecord(variant: "second")
        let firstRoot = makeFolderURL()
        let secondRoot = makeFolderURL()
        try await LocalFolderSyncTransport(rootURL: firstRoot)
            .push([first])
        try await LocalFolderSyncTransport(rootURL: secondRoot)
            .push([second])

        let mergedRoot = makeFolderURL()
        let mergedBatches = mergedRoot.appendingPathComponent(
            "batches",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: mergedBatches,
            withIntermediateDirectories: true
        )
        for sourceRoot in [firstRoot, secondRoot] {
            for source in try batchURLs(in: sourceRoot) {
                try FileManager.default.copyItem(
                    at: source,
                    to: mergedBatches.appendingPathComponent(
                        source.lastPathComponent
                    )
                )
            }
        }

        let transport = LocalFolderSyncTransport(rootURL: mergedRoot)
        let merged = try await transport.fetchAll()
        XCTAssertEqual(merged, [second])

        let final = try ordinaryRecord(
            modifiedAt: now.addingTimeInterval(100),
            deviceID: "device-final",
            payload: Data([0xFF])
        )
        try await transport.push([final])

        let converged = try await transport.fetchAll()
        XCTAssertEqual(converged, [final])
        let commits = try batchURLs(in: mergedRoot).map {
            try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: $0)
                ) as? [String: Any]
            )
        }
        XCTAssertEqual(commits.count, 3)
        XCTAssertTrue(commits.contains {
            ($0["parentIDs"] as? [Any])?.count == 2
        })
    }

    func testLocalFolderTransportPreservesModifiedAtBitPatternExactly() async throws {
        let folderURL = makeFolderURL()
        let exactDate = Date(
            timeIntervalSinceReferenceDate: Double(
                bitPattern: 0x41C8_3456_789A_BCDE
            )
        )
        let record = try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: exactDate
            ),
            modifiedBy: SyncDeviceID("mac-exact")
        )

        let transport = LocalFolderSyncTransport(rootURL: folderURL)
        try await transport.push([record])
        let fetched = try await transport.fetchAll()
        let restored = try XCTUnwrap(fetched.first)

        XCTAssertEqual(
            restored.modifiedAt.timeIntervalSinceReferenceDate.bitPattern,
            exactDate.timeIntervalSinceReferenceDate.bitPattern
        )
    }

    func testPreferenceBatchPublishesOneWinnerAndCanonicalSnapshot() async throws {
        let mapper = SyncRecordMapper()
        let first = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .chinese,
                updatedAt: Date(timeIntervalSinceReferenceDate: 10)
            ),
            modifiedBy: SyncDeviceID("mac-first")
        )
        let final = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: Date(timeIntervalSinceReferenceDate: 20)
            ),
            modifiedBy: SyncDeviceID("mac-final")
        )
        let folderURL = makeFolderURL()
        let transport = LocalFolderSyncTransport(rootURL: folderURL)

        try await transport.push([first, final])

        let currentRecords = try await transport.fetchAll()
        let snapshots = try await transport.fetchSnapshots()
        let snapshot = try XCTUnwrap(snapshots.last)
        let reconstructed = try SyncRepositorySnapshotBuilder().snapshot(
            records: currentRecords,
            memo: snapshot.memo,
            createdAt: snapshot.createdAt,
            deviceID: snapshot.deviceID
        )

        XCTAssertEqual(currentRecords, [final])
        XCTAssertEqual(snapshot.recordIDs, [final.id])
        XCTAssertEqual(snapshot.recordCount, 1)
        XCTAssertEqual(snapshot.payloadDigest, reconstructed.payloadDigest)
        XCTAssertEqual(snapshot.id, reconstructed.id)

        let latestRefURL = folderURL
            .appendingPathComponent("refs", isDirectory: true)
            .appendingPathComponent("latest")
        let latestRefBeforeReplay = try Data(
            contentsOf: latestRefURL
        )
        let recordBytesBeforeReplay = try storedRecordData(in: folderURL)
        let snapshotsBeforeReplay = snapshots
        try await transport.push([final, first])

        let replayedRecords = try await transport.fetchAll()
        XCTAssertEqual(replayedRecords, currentRecords)
        XCTAssertEqual(
            try storedRecordData(in: folderURL),
            recordBytesBeforeReplay
        )
        let replayedSnapshots = try await transport.fetchSnapshots()
        XCTAssertEqual(replayedSnapshots, snapshotsBeforeReplay)
        XCTAssertEqual(
            try Data(contentsOf: latestRefURL),
            latestRefBeforeReplay
        )
    }

    func testTransportsRejectPreferenceHeaderPayloadClockMismatch() async throws {
        let mapper = SyncRecordMapper()
        var malformed = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: now
            ),
            modifiedBy: SyncDeviceID("mac-invalid-preferences")
        )
        malformed.modifiedAt = Date(
            timeIntervalSinceReferenceDate: now
                .timeIntervalSinceReferenceDate.nextUp
        )

        let transports: [any SyncRecordTransport] = [
            LocalFolderSyncTransport(rootURL: makeFolderURL()),
            InMemorySyncTransport()
        ]
        for transport in transports {
            await assertInvalidCurrentRecord(
                malformed,
                through: transport
            )
        }
    }

    func testSyncRecordEncodingRejectsNonfiniteModifiedAt() {
        for seconds in [Double.nan, Double.infinity, -Double.infinity] {
            let record = SyncRecord(
                id: SyncRecordID("nonfinite-date"),
                entityType: .appPreferences,
                entityID: "default",
                modifiedAt: Date(timeIntervalSinceReferenceDate: seconds),
                modifiedByDeviceID: SyncDeviceID("mac-exact"),
                payload: Data()
            )

            XCTAssertThrowsError(try JSONEncoder().encode(record)) { error in
                guard case EncodingError.invalidValue = error else {
                    return XCTFail("预期 non-finite modifiedAt fail-closed，实际为 \(error)")
                }
            }
        }
    }

    func testSyncRecordDecodingRejectsNonfiniteModifiedAtBitPattern() throws {
        let record = SyncRecord(
            id: SyncRecordID("nonfinite-date"),
            entityType: .appPreferences,
            entityID: "default",
            modifiedAt: now,
            modifiedByDeviceID: SyncDeviceID("mac-exact"),
            payload: Data()
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(record)
            ) as? [String: Any]
        )
        object["modifiedAt"] = NSNumber(value: Double.infinity.bitPattern)
        let nonfiniteData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(SyncRecord.self, from: nonfiniteData)
        ) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("预期 non-finite modifiedAt fail-closed，实际为 \(error)")
            }
        }
    }

    func testImmutableRecordsReplayExactlyWithoutReplacingStoredBytes() async throws {
        for entityType in immutableEntityTypes {
            let folderURL = makeFolderURL()
            let record = immutableRecord(
                entityType: entityType,
                id: "exact-\(entityType.rawValue)",
                variant: "same"
            )
            let firstTransport = LocalFolderSyncTransport(rootURL: folderURL)
            let replayTransport = LocalFolderSyncTransport(rootURL: folderURL)

            try await firstTransport.push([record])
            let originalData = try storedRecordData(in: folderURL)
            let originalSnapshots = try await firstTransport.fetchSnapshots()
            let originalLatestRef = try Data(
                contentsOf: folderURL.appendingPathComponent("refs/latest")
            )
            try await replayTransport.push([record])

            XCTAssertEqual(try storedRecordData(in: folderURL), originalData)
            let restored = try await replayTransport.fetchAll()
            let replayedSnapshots = try await replayTransport.fetchSnapshots()
            XCTAssertEqual(restored, [record])
            XCTAssertEqual(replayedSnapshots, originalSnapshots)
            XCTAssertEqual(
                try Data(contentsOf: folderURL.appendingPathComponent("refs/latest")),
                originalLatestRef
            )
        }
    }

    func testImmutableRecordCollisionPreservesFirstWriterForEveryImmutableType() async throws {
        for entityType in immutableEntityTypes {
            let folderURL = makeFolderURL()
            let recordID = "collision-\(entityType.rawValue)"
            let first = immutableRecord(entityType: entityType, id: recordID, variant: "first")
            let transport = LocalFolderSyncTransport(rootURL: folderURL)

            try await transport.push([first])
            let originalData = try storedRecordData(in: folderURL)

            var payloadCollision = first
            payloadCollision.payload = Data("different-payload".utf8)
            var metadataCollision = first
            metadataCollision.modifiedAt = Date(timeIntervalSinceReferenceDate: 222.25)
            var identityCollision = first
            identityCollision.entityID = "different-entity"

            for colliding in [payloadCollision, metadataCollision, identityCollision] {
                await assertCollision(
                    pushing: colliding,
                    through: LocalFolderSyncTransport(rootURL: folderURL)
                )
            }

            XCTAssertEqual(try storedRecordData(in: folderURL), originalData)
            let restored = try await transport.fetchAll()
            XCTAssertEqual(restored, [first])
        }
    }

    func testImmutableReplayRejectsUnknownFieldsAndNoncanonicalBytes() async throws {
        for entityType in immutableEntityTypes {
            let folderURL = makeFolderURL()
            let record = immutableRecord(
                entityType: entityType,
                id: "noncanonical-\(entityType.rawValue)",
                variant: "first"
            )
            let transport = LocalFolderSyncTransport(rootURL: folderURL)
            try await transport.push([record])

            let recordURL = try storedRecordURL(in: folderURL)
            let canonicalData = try Data(contentsOf: recordURL)
            let canonicalObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
            )
            var unknownFieldObject = canonicalObject
            unknownFieldObject["unknownTopLevelField"] = "must-fail-closed"
            let unknownFieldData = try JSONSerialization.data(
                withJSONObject: unknownFieldObject,
                options: [.prettyPrinted, .sortedKeys]
            )
            let noncanonicalData = try JSONSerialization.data(
                withJSONObject: canonicalObject,
                options: [.sortedKeys]
            )

            for tamperedData in [unknownFieldData, noncanonicalData] {
                XCTAssertNotEqual(tamperedData, canonicalData)
                try tamperedData.write(to: recordURL, options: [.atomic])

                await assertCollision(
                    pushing: record,
                    through: LocalFolderSyncTransport(rootURL: folderURL)
                )
                XCTAssertEqual(try Data(contentsOf: recordURL), tamperedData)
            }
        }
    }

    func testConcurrentImmutableCollisionPublishesOneCompleteRecordForEveryImmutableType() async throws {
        for entityType in immutableEntityTypes {
            for iteration in 0 ..< 8 {
                let folderURL = makeFolderURL()
                let recordID = "concurrent-\(entityType.rawValue)-\(iteration)"
                let first = immutableRecord(entityType: entityType, id: recordID, variant: "first")
                let second = immutableRecord(entityType: entityType, id: recordID, variant: "second")
                let firstTransport = LocalFolderSyncTransport(rootURL: folderURL)
                let secondTransport = LocalFolderSyncTransport(rootURL: folderURL)
                try await firstTransport.push([])

                async let firstOutcome = immutablePushOutcome(first, through: firstTransport)
                async let secondOutcome = immutablePushOutcome(second, through: secondTransport)
                let outcomes = await (firstOutcome, secondOutcome)

                XCTAssertEqual([outcomes.0, outcomes.1].filter(\.isSuccess).count, 1)
                XCTAssertEqual(
                    [outcomes.0, outcomes.1].filter { $0 == .collision(first.id) }.count,
                    1
                )

                let fetched = try await firstTransport.fetchAll()
                let restored = try XCTUnwrap(fetched.only)
                XCTAssertTrue(restored == first || restored == second)
                if outcomes.0.isSuccess {
                    XCTAssertEqual(restored, first)
                } else {
                    XCTAssertEqual(restored, second)
                }
            }
        }
    }

    func testOrdinaryCurrentRecordStillOverwritesSameRecordID() async throws {
        let folderURL = makeFolderURL()
        let first = try ordinaryRecord(variant: "first")
        let replacement = try ordinaryRecord(variant: "replacement")
        let transport = LocalFolderSyncTransport(rootURL: folderURL)

        try await transport.push([first])
        try await LocalFolderSyncTransport(rootURL: folderURL).push([replacement])

        let restored = try await transport.fetchAll()
        XCTAssertEqual(restored, [replacement])
    }

    func testFetchAllConvergesAnICloudConflictCopyForCurrentRecords() async throws {
        let folderURL = makeFolderURL()
        let first = try ordinaryRecord(variant: "first")
        let replacement = try ordinaryRecord(variant: "replacement")
        let transport = LocalFolderSyncTransport(rootURL: folderURL)
        try await transport.push([first])
        try writeConflictCopy(replacement, to: folderURL)

        let restored = try await transport.fetchAll()

        XCTAssertEqual(restored, [replacement])
    }

    func testFetchAllRejectsADivergentImmutableICloudConflictCopy() async throws {
        let folderURL = makeFolderURL()
        let first = immutableRecord(
            entityType: .classificationCommit,
            id: "icloud-immutable-conflict",
            variant: "first"
        )
        let collision = immutableRecord(
            entityType: .classificationCommit,
            id: "icloud-immutable-conflict",
            variant: "second"
        )
        let transport = LocalFolderSyncTransport(rootURL: folderURL)
        try await transport.push([first])
        try writeConflictCopy(collision, to: folderURL)

        do {
            _ = try await transport.fetchAll()
            XCTFail("不可变 iCloud 冲突副本应 fail-closed")
        } catch {
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .immutableRecordCollision(recordID: first.id)
            )
        }
    }

    func testOrdinaryCurrentRecordIgnoresLateStaleWriteAcrossTransports() async throws {
        let newer = try ordinaryRecord(
            modifiedAt: now.addingTimeInterval(10),
            deviceID: "mac-newer",
            payload: Data("newer".utf8)
        )
        let stale = try ordinaryRecord(
            modifiedAt: now,
            deviceID: "mac-stale",
            payload: Data("stale".utf8)
        )

        let folderURL = makeFolderURL()
        let local = LocalFolderSyncTransport(rootURL: folderURL)
        try await local.push([newer])
        try await LocalFolderSyncTransport(rootURL: folderURL).push([stale])
        let localRecords = try await local.fetchAll()
        XCTAssertEqual(localRecords, [newer])

        let memory = InMemorySyncTransport()
        try await memory.push([newer])
        try await memory.push([stale])
        let memoryRecords = try await memory.fetchAll()
        XCTAssertEqual(memoryRecords, [newer])
    }

    func testEqualTimeWriterTieBreakConvergesForEveryWritePermutationAcrossTransports() async throws {
        let lowerDevice = try ordinaryRecord(
            modifiedAt: now,
            deviceID: "mac-a",
            payload: Data([0xFF])
        )
        let middleDevice = try ordinaryRecord(
            modifiedAt: now,
            deviceID: "mac-m",
            payload: Data([0x00])
        )
        let higherDevice = try ordinaryRecord(
            modifiedAt: now,
            deviceID: "mac-z",
            payload: Data([0xFF])
        )

        XCTAssertEqual(
            middleDevice.currentRecordLWWOrder(comparedTo: lowerDevice),
            .after
        )
        XCTAssertEqual(
            higherDevice.currentRecordLWWOrder(comparedTo: middleDevice),
            .after
        )
        XCTAssertEqual(
            lowerDevice.currentRecordLWWOrder(comparedTo: higherDevice),
            .before
        )

        for writes in permutations(of: [lowerDevice, middleDevice, higherDevice]) {
            let folderURL = makeFolderURL()
            let local = LocalFolderSyncTransport(rootURL: folderURL)
            let memory = InMemorySyncTransport()
            for record in writes {
                try await local.push([record])
                try await memory.push([record])
            }

            let localRecords = try await local.fetchAll()
            let memoryRecords = try await memory.fetchAll()
            XCTAssertEqual(localRecords, [higherDevice])
            XCTAssertEqual(memoryRecords, [higherDevice])
        }
    }

    func testCurrentRecordTotalOrderUsesPayloadBytesAfterHeaderTies() {
        let lowerPayload = SyncRecord(
            id: SyncRecordID("generic:default"),
            entityType: .day,
            entityID: "default",
            operation: .upsert,
            modifiedAt: now,
            modifiedByDeviceID: SyncDeviceID("mac-a"),
            payload: Data([0x00])
        )
        var higherPayload = lowerPayload
        higherPayload.payload = Data([0xFF])

        XCTAssertEqual(
            higherPayload.currentRecordLWWOrder(comparedTo: lowerPayload),
            .after
        )
        XCTAssertEqual(
            lowerPayload.currentRecordLWWOrder(comparedTo: higherPayload),
            .before
        )
    }

    func testConcurrentEqualTimeWritersConvergeAcrossLocalFolderActorsAndInMemory() async throws {
        let baseline = try ordinaryRecord(
            modifiedAt: now.addingTimeInterval(-1),
            deviceID: "mac-baseline",
            payload: Data("baseline".utf8)
        )
        let lower = try ordinaryRecord(
            modifiedAt: now,
            deviceID: "mac-a",
            payload: Data("lower".utf8)
        )
        let winner = try ordinaryRecord(
            modifiedAt: now,
            deviceID: "mac-z",
            payload: Data("winner".utf8)
        )

        for _ in 0 ..< 40 {
            let folderURL = makeFolderURL()
            let local = LocalFolderSyncTransport(rootURL: folderURL)
            try await local.push([baseline])
            let lowerLocal = LocalFolderSyncTransport(rootURL: folderURL)
            let winnerLocal = LocalFolderSyncTransport(rootURL: folderURL)
            async let lowerLocalPush: Void = lowerLocal.push([lower])
            async let winnerLocalPush: Void = winnerLocal.push([winner])
            _ = try await (lowerLocalPush, winnerLocalPush)

            let localRecords = try await local.fetchAll()
            XCTAssertEqual(localRecords, [winner])

            let memory = try InMemorySyncTransport(records: [baseline])
            async let lowerMemoryPush: Void = memory.push([lower])
            async let winnerMemoryPush: Void = memory.push([winner])
            _ = try await (lowerMemoryPush, winnerMemoryPush)

            let memoryRecords = try await memory.fetchAll()
            XCTAssertEqual(memoryRecords, [winner])
        }
    }

    func testTaskChainNotesConvergeForEveryWritePermutationAcrossTransports() async throws {
        let fixture = try makeDivergentChainRecords()
        let mapper = SyncRecordMapper()
        var expectedRecord: SyncRecord?

        for writes in permutations(of: fixture.records) {
            let folderURL = makeFolderURL()
            let local = LocalFolderSyncTransport(rootURL: folderURL)
            let memory = InMemorySyncTransport()
            for record in writes {
                try await local.push([record])
                try await memory.push([record])
            }

            let localRecords = try await local.fetchAll()
            let memoryRecords = try await memory.fetchAll()
            let localRecord = try XCTUnwrap(localRecords.only)
            let memoryRecord = try XCTUnwrap(memoryRecords.only)
            let chain = try mapper.decodeTaskChain(localRecord)

            XCTAssertEqual(localRecord, memoryRecord)
            XCTAssertEqual(
                Set(chain.activeNoteEntries.map(\.body)),
                ["Mac 离线新增", "Phone 离线新增"]
            )
            XCTAssertTrue(
                try XCTUnwrap(
                    chain.noteEntries.first { $0.id == fixture.originalNoteID }
                ).isDeleted
            )
            if let expectedRecord {
                XCTAssertEqual(localRecord, expectedRecord)
            } else {
                expectedRecord = localRecord
            }

            let latestSnapshotID = try String(
                contentsOf: folderURL.appendingPathComponent("refs/latest"),
                encoding: .utf8
            )
            let snapshots = try await local.fetchSnapshots()
            let latestSnapshot = try XCTUnwrap(
                snapshots.first { $0.id == latestSnapshotID }
            )
            let expectedSnapshot = try SyncRepositorySnapshotBuilder().snapshot(
                records: [localRecord],
                createdAt: latestSnapshot.createdAt,
                deviceID: latestSnapshot.deviceID
            )
            XCTAssertEqual(latestSnapshot.payloadDigest, expectedSnapshot.payloadDigest)
        }
    }

    func testPendingTraceNotesConvergeForEveryWritePermutationAcrossTransports() async throws {
        let fixture = try makeDivergentTraceRecords()
        let mapper = SyncRecordMapper()
        var expectedRecord: SyncRecord?

        for writes in permutations(of: fixture.records) {
            let folderURL = makeFolderURL()
            let local = LocalFolderSyncTransport(rootURL: folderURL)
            let memory = InMemorySyncTransport()
            for record in writes {
                try await local.push([record])
                try await memory.push([record])
            }

            let localRecords = try await local.fetchAll()
            let memoryRecords = try await memory.fetchAll()
            let localRecord = try XCTUnwrap(localRecords.only)
            let memoryRecord = try XCTUnwrap(memoryRecords.only)
            let trace = try mapper.decodeDayTrace(localRecord)

            XCTAssertEqual(localRecord, memoryRecord)
            XCTAssertEqual(trace.status, .pending)
            XCTAssertEqual(
                Set(trace.activeNoteEntries.map(\.body)),
                ["Mac 轨迹新增", "Phone 轨迹新增"]
            )
            XCTAssertTrue(
                try XCTUnwrap(
                    trace.noteEntries.first { $0.id == fixture.originalNoteID }
                ).isDeleted
            )
            if let expectedRecord {
                XCTAssertEqual(localRecord, expectedRecord)
            } else {
                expectedRecord = localRecord
            }
        }
    }

    func testPoolTitleAndChainNotesPublishAsIndependentCurrentRecords() async throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(title: "共同标题", now: now)
        let snapshot = base.snapshot()

        let mac = try NoonmarkEngine(snapshot: snapshot)
        try mac.updatePoolTask(
            chainID: chainID,
            title: "Mac 新标题",
            now: now.addingTimeInterval(10)
        )

        let phone = try NoonmarkEngine(snapshot: snapshot)
        try phone.updatePoolTask(
            chainID: chainID,
            title: "共同标题",
            now: now.addingTimeInterval(15)
        )
        _ = try phone.appendPoolNote(
            chainID: chainID,
            body: "Phone 稍后新增附言",
            now: now.addingTimeInterval(20)
        )

        let mapper = SyncRecordMapper()
        let macDefinitionRecord = try mapper.record(
            for: try XCTUnwrap(mac.snapshot().definitions.first),
            modifiedBy: SyncDeviceID("mac-a")
        )
        let phoneChainRecord = try mapper.record(
            for: try XCTUnwrap(phone.snapshot().chains.first),
            modifiedBy: SyncDeviceID("phone-z")
        )

        for writes in permutations(of: [macDefinitionRecord, phoneChainRecord]) {
            let folderURL = makeFolderURL()
            let local = LocalFolderSyncTransport(rootURL: folderURL)
            let memory = InMemorySyncTransport()
            for record in writes {
                try await local.push([record])
                try await memory.push([record])
            }

            let localRecords = try await local.fetchAll()
            let memoryRecords = try await memory.fetchAll()
            XCTAssertEqual(localRecords, memoryRecords)
            let mergedDefinition = try mapper.decodeTaskDefinition(
                XCTUnwrap(localRecords.first { $0.entityType == .taskDefinition })
            )
            let mergedChain = try mapper.decodeTaskChain(
                XCTUnwrap(localRecords.first { $0.entityType == .taskChain })
            )
            XCTAssertEqual(mergedDefinition.title, "Mac 新标题")
            XCTAssertEqual(
                mergedChain.activeNoteEntries.map(\.body),
                ["Phone 稍后新增附言"]
            )
        }
    }

    func testPendingTraceContentChangeSurvivesLaterNoteOnlyChangeAcrossTransports() async throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(title: "轨迹内容", now: now)
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let snapshot = base.snapshot()

        let mac = try NoonmarkEngine(snapshot: snapshot)
        try mac.updateTraceText(
            traceID: traceID,
            descriptionText: "Mac 新描述",
            today: today,
            now: now.addingTimeInterval(10)
        )

        let phone = try NoonmarkEngine(snapshot: snapshot)
        _ = try phone.appendTraceNote(
            traceID: traceID,
            body: "Phone 稍后新增附言",
            today: today,
            now: now.addingTimeInterval(20)
        )

        let mapper = SyncRecordMapper()
        let macRecord = try mapper.record(
            for: try XCTUnwrap(mac.traces[traceID]),
            modifiedBy: SyncDeviceID("mac-a")
        )
        let phoneRecord = try mapper.record(
            for: try XCTUnwrap(phone.traces[traceID]),
            modifiedBy: SyncDeviceID("phone-z")
        )

        for writes in permutations(of: [macRecord, phoneRecord]) {
            let folderURL = makeFolderURL()
            let local = LocalFolderSyncTransport(rootURL: folderURL)
            let memory = InMemorySyncTransport()
            for record in writes {
                try await local.push([record])
                try await memory.push([record])
            }

            let localRecords = try await local.fetchAll()
            let memoryRecords = try await memory.fetchAll()
            let localRecord = try XCTUnwrap(localRecords.only)
            let memoryRecord = try XCTUnwrap(memoryRecords.only)
            let merged = try mapper.decodeDayTrace(localRecord)

            XCTAssertEqual(localRecord, memoryRecord)
            XCTAssertEqual(merged.descriptionText, "Mac 新描述")
            XCTAssertEqual(merged.activeNoteEntries.map(\.body), ["Phone 稍后新增附言"])
        }
    }

    func testCompletedTraceBeatsLaterStalePendingEditAcrossTransports() async throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(title: "完成态优先", now: now)
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let snapshot = base.snapshot()

        let completed = try NoonmarkEngine(snapshot: snapshot)
        try completed.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(20)
        )
        let stale = try NoonmarkEngine(snapshot: snapshot)
        try stale.updateTraceText(
            traceID: traceID,
            descriptionText: "离线设备的迟到描述",
            today: today,
            now: now.addingTimeInterval(30)
        )

        let mapper = SyncRecordMapper()
        let records = [
            try mapper.record(
                for: try XCTUnwrap(completed.traces[traceID]),
                modifiedBy: SyncDeviceID("completed-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(stale.traces[traceID]),
                modifiedBy: SyncDeviceID("stale-device")
            )
        ]

        for writes in permutations(of: records) {
            let folderURL = makeFolderURL()
            let local = LocalFolderSyncTransport(rootURL: folderURL)
            let memory = InMemorySyncTransport()
            for record in writes {
                try await local.push([record])
                try await memory.push([record])
            }
            let localRecords = try await local.fetchAll()
            let memoryRecords = try await memory.fetchAll()
            let localRecord = try XCTUnwrap(localRecords.only)
            let memoryRecord = try XCTUnwrap(memoryRecords.only)
            let merged = try mapper.decodeDayTrace(localRecord)

            XCTAssertEqual(localRecord, memoryRecord)
            XCTAssertEqual(merged.status, .completed)
            XCTAssertNil(merged.descriptionText)
            XCTAssertEqual(merged.contentUpdatedAt, now.addingTimeInterval(20))
        }
    }

    func testCompletedTracePreservesConcurrentPendingNotesAcrossTransports() async throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "跨 transport 完成与附言并发",
            initialNoteBody: "待删除附言",
            now: now
        )
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let baseSnapshot = base.snapshot()
        let originalNoteID = try XCTUnwrap(
            base.traces[traceID]?.activeNoteEntries.first?.id
        )

        let completed = try NoonmarkEngine(snapshot: baseSnapshot)
        try completed.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(20)
        )

        let pending = try NoonmarkEngine(snapshot: baseSnapshot)
        _ = try pending.appendTraceNote(
            traceID: traceID,
            body: "并发新增附言",
            today: today,
            now: now.addingTimeInterval(30)
        )
        try pending.deleteTraceNote(
            traceID: traceID,
            noteID: originalNoteID,
            today: today,
            now: now.addingTimeInterval(40)
        )

        let mapper = SyncRecordMapper()
        let completedRecord = try mapper.record(
            for: try XCTUnwrap(completed.traces[traceID]),
            modifiedBy: SyncDeviceID("completed-device")
        )
        let pendingRecord = try mapper.record(
            for: try XCTUnwrap(pending.traces[traceID]),
            modifiedBy: SyncDeviceID("pending-device")
        )
        var canonicalRecord: SyncRecord?

        for writes in [
            [completedRecord, pendingRecord],
            [pendingRecord, completedRecord]
        ] {
            let local = LocalFolderSyncTransport(rootURL: makeFolderURL())
            let memory = InMemorySyncTransport()
            for record in writes {
                try await local.push([record])
                try await memory.push([record])
            }

            let localRecords = try await local.fetchAll()
            let memoryRecords = try await memory.fetchAll()
            let localRecord = try XCTUnwrap(localRecords.only)
            let memoryRecord = try XCTUnwrap(memoryRecords.only)
            let merged = try mapper.decodeDayTrace(localRecord)
            let tombstone = try XCTUnwrap(
                merged.noteEntries.first { $0.id == originalNoteID }
            )

            XCTAssertEqual(localRecord, memoryRecord)
            XCTAssertEqual(merged.status, .completed)
            XCTAssertEqual(merged.completedAt, now.addingTimeInterval(20))
            XCTAssertEqual(
                merged.activeNoteEntries.map(\.body),
                ["并发新增附言"]
            )
            XCTAssertTrue(tombstone.isDeleted)
            XCTAssertEqual(tombstone.deletedAt, now.addingTimeInterval(40))
            if let canonicalRecord {
                XCTAssertEqual(localRecord, canonicalRecord)
            } else {
                canonicalRecord = localRecord
            }
        }
    }

    func testExplicitCompletionUndoBeatsCompletedTraceAcrossTransports() async throws {
        let completed = NoonmarkEngine()
        let chainID = try completed.createPoolTask(title: "合法撤销完成", now: now)
        let traceID = try completed.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try completed.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(20)
        )
        let restored = try NoonmarkEngine(snapshot: completed.snapshot())
        try restored.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(30)
        )

        let mapper = SyncRecordMapper()
        let records = [
            try mapper.record(
                for: try XCTUnwrap(completed.days[today]),
                modifiedBy: SyncDeviceID("day-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(completed.traces[traceID]),
                modifiedBy: SyncDeviceID("completed-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(restored.traces[traceID]),
                modifiedBy: SyncDeviceID("undo-device")
            )
        ]

        for writes in permutations(of: records) {
            let folderURL = makeFolderURL()
            let local = LocalFolderSyncTransport(rootURL: folderURL)
            let memory = InMemorySyncTransport()
            try await local.push(writes)
            try await memory.push(writes)
            let localRecords = try await local.fetchAll()
            let memoryRecords = try await memory.fetchAll()
            let localRecord = try XCTUnwrap(
                localRecords.first { $0.entityType == .dayTrace }
            )
            let merged = try mapper.decodeDayTrace(localRecord)

            XCTAssertEqual(localRecords, memoryRecords)
            XCTAssertEqual(merged.status, .pending)
            XCTAssertNil(merged.completedAt)
            XCTAssertEqual(merged.contentUpdatedAt, now.addingTimeInterval(30))
        }
    }

    func testLockedDayRejectsCompletionUndoForEveryBatchOrderAcrossTransports() async throws {
        let completed = NoonmarkEngine()
        let chainID = try completed.createPoolTask(title: "锁定日拒绝撤销", now: now)
        let traceID = try completed.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try completed.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(20)
        )

        let restored = try NoonmarkEngine(snapshot: completed.snapshot())
        try restored.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(30)
        )
        let locked = try NoonmarkEngine(snapshot: completed.snapshot())
        try locked.settleDays(
            upTo: LocalDate("2026-07-06"),
            now: now.addingTimeInterval(60)
        )

        let mapper = SyncRecordMapper()
        let records = [
            try mapper.record(
                for: try XCTUnwrap(locked.days[today]),
                modifiedBy: SyncDeviceID("locked-day-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(completed.traces[traceID]),
                modifiedBy: SyncDeviceID("completed-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(restored.traces[traceID]),
                modifiedBy: SyncDeviceID("undo-device")
            )
        ]

        for writes in permutations(of: records) {
            let local = LocalFolderSyncTransport(rootURL: makeFolderURL())
            let memory = InMemorySyncTransport()
            try await local.push(writes)
            try await memory.push(writes)

            let localRecords = try await local.fetchAll()
            let memoryRecords = try await memory.fetchAll()
            let traceRecord = try XCTUnwrap(
                localRecords.first { $0.entityType == .dayTrace }
            )
            let merged = try mapper.decodeDayTrace(traceRecord)

            XCTAssertEqual(localRecords, memoryRecords)
            XCTAssertEqual(merged.status, .completed)
            XCTAssertEqual(merged.completedAt, now.addingTimeInterval(20))
            XCTAssertEqual(merged.contentUpdatedAt, now.addingTimeInterval(20))
        }
    }

    func testExistingLockedDayBeatsIncomingUnlockedDayAndCompletionUndoAcrossTransports() async throws {
        let completed = NoonmarkEngine()
        let chainID = try completed.createPoolTask(title: "远端锁定日优先", now: now)
        let traceID = try completed.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try completed.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(20)
        )
        let unlockedDay = try XCTUnwrap(completed.days[today])

        let restored = try NoonmarkEngine(snapshot: completed.snapshot())
        try restored.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(30)
        )
        let locked = try NoonmarkEngine(snapshot: completed.snapshot())
        try locked.settleDays(
            upTo: LocalDate("2026-07-06"),
            now: now.addingTimeInterval(60)
        )

        let mapper = SyncRecordMapper()
        let baseline = [
            try mapper.record(
                for: try XCTUnwrap(locked.days[today]),
                modifiedBy: SyncDeviceID("locked-day-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(completed.traces[traceID]),
                modifiedBy: SyncDeviceID("completed-device")
            )
        ]
        let incoming = [
            try mapper.record(
                for: unlockedDay,
                modifiedBy: SyncDeviceID("stale-day-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(restored.traces[traceID]),
                modifiedBy: SyncDeviceID("undo-device")
            )
        ]

        for writes in permutations(of: incoming) {
            let local = LocalFolderSyncTransport(rootURL: makeFolderURL())
            let memory = InMemorySyncTransport()
            try await local.push(baseline)
            try await memory.push(baseline)
            try await local.push(writes)
            try await memory.push(writes)

            let localRecords = try await local.fetchAll()
            let memoryRecords = try await memory.fetchAll()
            let traceRecord = try XCTUnwrap(
                localRecords.first { $0.entityType == .dayTrace }
            )
            let merged = try mapper.decodeDayTrace(traceRecord)

            XCTAssertEqual(localRecords, memoryRecords)
            XCTAssertEqual(merged.status, .completed)
            XCTAssertEqual(merged.completedAt, now.addingTimeInterval(20))
        }
    }

    func testLockedDayKeepsLaterOfflineReviewWithoutAllowingCompletionUndoAcrossTransports() async throws {
        let completed = NoonmarkEngine()
        let chainID = try completed.createPoolTask(
            title: "锁定日合并离线复盘",
            now: now
        )
        let traceID = try completed.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try completed.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(20)
        )

        let offline = try NoonmarkEngine(snapshot: completed.snapshot())
        try offline.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(30)
        )
        offline.updateDailyReview(
            date: today,
            summary: "离线补写的复盘",
            unfinishedReason: "离线原因",
            tomorrowNote: "离线明日提醒",
            now: now.addingTimeInterval(100)
        )

        let locked = try NoonmarkEngine(snapshot: completed.snapshot())
        try locked.settleDays(
            upTo: LocalDate("2026-07-06"),
            now: now.addingTimeInterval(60)
        )

        let mapper = SyncRecordMapper()
        let lockedBranch = [
            try mapper.record(
                for: try XCTUnwrap(locked.days[today]),
                modifiedBy: SyncDeviceID("locked-day-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(completed.traces[traceID]),
                modifiedBy: SyncDeviceID("completed-device")
            )
        ]
        let offlineBranch = [
            try mapper.record(
                for: try XCTUnwrap(offline.days[today]),
                modifiedBy: SyncDeviceID("offline-review-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(offline.traces[traceID]),
                modifiedBy: SyncDeviceID("offline-undo-device")
            )
        ]

        for branches in [
            (first: lockedBranch, second: offlineBranch),
            (first: offlineBranch, second: lockedBranch)
        ] {
            for firstWrites in permutations(of: branches.first) {
                for secondWrites in permutations(of: branches.second) {
                    let local = LocalFolderSyncTransport(rootURL: makeFolderURL())
                    let memory = InMemorySyncTransport()
                    try await local.push(firstWrites)
                    try await memory.push(firstWrites)
                    try await local.push(secondWrites)
                    try await memory.push(secondWrites)

                    let localRecords = try await local.fetchAll()
                    let memoryRecords = try await memory.fetchAll()
                    let mergedDay = try mapper.decodeDay(try XCTUnwrap(
                        localRecords.first { $0.entityType == .day }
                    ))
                    let mergedTrace = try mapper.decodeDayTrace(try XCTUnwrap(
                        localRecords.first { $0.entityType == .dayTrace }
                    ))

                    XCTAssertEqual(localRecords, memoryRecords)
                    XCTAssertEqual(mergedDay.lockedAt, now.addingTimeInterval(60))
                    XCTAssertEqual(mergedDay.reviewSummary, "离线补写的复盘")
                    XCTAssertEqual(mergedDay.reviewUnfinishedReason, "离线原因")
                    XCTAssertEqual(mergedDay.reviewTomorrowNote, "离线明日提醒")
                    XCTAssertEqual(mergedTrace.status, .completed)
                    XCTAssertEqual(mergedTrace.completedAt, now.addingTimeInterval(20))
                    XCTAssertEqual(
                        mergedTrace.contentUpdatedAt,
                        now.addingTimeInterval(20)
                    )
                }
            }
        }
    }

    func testMissingDayRetainsCompletionWithoutPoisoningAcrossTransports() async throws {
        let completed = NoonmarkEngine()
        let chainID = try completed.createPoolTask(title: "缺少日上下文", now: now)
        let traceID = try completed.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try completed.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(20)
        )
        let restored = try NoonmarkEngine(snapshot: completed.snapshot())
        try restored.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(30)
        )

        let mapper = SyncRecordMapper()
        let completedRecord = try mapper.record(
            for: try XCTUnwrap(completed.traces[traceID]),
            modifiedBy: SyncDeviceID("completed-device")
        )
        let undoRecord = try mapper.record(
            for: try XCTUnwrap(restored.traces[traceID]),
            modifiedBy: SyncDeviceID("undo-device")
        )
        let dayRecord = try mapper.record(
            for: try XCTUnwrap(completed.days[today]),
            modifiedBy: SyncDeviceID("day-device")
        )

        let local = LocalFolderSyncTransport(rootURL: makeFolderURL())
        let memory = InMemorySyncTransport()
        try await local.push([completedRecord])
        try await memory.push([completedRecord])

        try await local.push([undoRecord])
        try await memory.push([undoRecord])
        let localAfterMissingContext = try await local.fetchAll()
        let memoryAfterMissingContext = try await memory.fetchAll()
        XCTAssertEqual(
            localAfterMissingContext.first { $0.entityType == .dayTrace },
            completedRecord
        )
        XCTAssertEqual(
            memoryAfterMissingContext.first { $0.entityType == .dayTrace },
            completedRecord
        )

        try await local.push([dayRecord])
        try await memory.push([dayRecord])
        let localAfterDay = try await local.fetchAll()
        let memoryAfterDay = try await memory.fetchAll()
        XCTAssertEqual(
            localAfterDay.first { $0.entityType == .dayTrace },
            completedRecord
        )
        XCTAssertEqual(
            memoryAfterDay.first { $0.entityType == .dayTrace },
            completedRecord
        )

        try await local.push([undoRecord])
        try await memory.push([undoRecord])
        let localRecords = try await local.fetchAll()
        let memoryRecords = try await memory.fetchAll()
        let traceRecord = try XCTUnwrap(
            localRecords.first { $0.entityType == .dayTrace }
        )
        let merged = try mapper.decodeDayTrace(traceRecord)

        XCTAssertEqual(localRecords, memoryRecords)
        XCTAssertEqual(merged.status, .pending)
        XCTAssertNil(merged.completedAt)
    }

    func testImmutableCollisionCannotAuthorizeCompletionUndoAcrossTransports() async throws {
        let completed = NoonmarkEngine()
        let chainID = try completed.createPoolTask(title: "CAS 不可授权撤销", now: now)
        let traceID = try completed.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try completed.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(20)
        )
        let restored = try NoonmarkEngine(snapshot: completed.snapshot())
        try restored.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(30)
        )

        let mapper = SyncRecordMapper()
        let completedRecord = try mapper.record(
            for: try XCTUnwrap(completed.traces[traceID]),
            modifiedBy: SyncDeviceID("completed-device")
        )
        let undoRecord = try mapper.record(
            for: try XCTUnwrap(restored.traces[traceID]),
            modifiedBy: SyncDeviceID("undo-device")
        )
        let dayRecord = try mapper.record(
            for: try XCTUnwrap(completed.days[today]),
            modifiedBy: SyncDeviceID("day-device")
        )
        let collidingImmutable = immutableRecord(
            entityType: .classificationCommit,
            id: dayRecord.id.rawValue,
            variant: "first"
        )

        for writes in permutations(of: [undoRecord, dayRecord]) {
            let local = LocalFolderSyncTransport(rootURL: makeFolderURL())
            let memory = InMemorySyncTransport()
            try await local.push([completedRecord, collidingImmutable])
            try await memory.push([completedRecord, collidingImmutable])

            await assertBatchCollision(writes, through: local, recordID: dayRecord.id)
            await assertBatchCollision(writes, through: memory, recordID: dayRecord.id)

            let localRecords = try await local.fetchAll()
            let memoryRecords = try await memory.fetchAll()
            XCTAssertEqual(localRecords, memoryRecords)
            XCTAssertEqual(
                localRecords.first { $0.entityType == .dayTrace },
                completedRecord
            )
        }
    }

    func testAbandonedInverseRequiresCanonicalActiveChainAcrossTransports() async throws {
        let abandoned = NoonmarkEngine()
        let chainID = try abandoned.createPoolTask(title: "恢复废弃任务", now: now)
        let traceID = try abandoned.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try abandoned.abandonChain(
            from: traceID,
            now: now.addingTimeInterval(20)
        )

        let restored = try NoonmarkEngine(snapshot: abandoned.snapshot())
        _ = try restored.reactivateAbandonedChain(
            from: traceID,
            today: today,
            now: now.addingTimeInterval(30)
        )
        let mapper = SyncRecordMapper()
        let abandonedTrace = try mapper.record(
            for: try XCTUnwrap(abandoned.traces[traceID]),
            modifiedBy: SyncDeviceID("abandoned-trace-device")
        )
        let restoredTrace = try mapper.record(
            for: try XCTUnwrap(restored.traces[traceID]),
            modifiedBy: SyncDeviceID("restored-trace-device")
        )
        let abandonedChain = try mapper.record(
            for: try XCTUnwrap(abandoned.chains[chainID]),
            modifiedBy: SyncDeviceID("abandoned-chain-device")
        )
        let reactivationRecords = try SyncRecordMaterializer(mapper: mapper).records(
            for: SyncSnapshotDiffer().journalEntries(
                from: abandoned.snapshot(),
                to: restored.snapshot(),
                changedAt: now.addingTimeInterval(30),
                deviceID: SyncDeviceID("active-chain-device")
            ),
            in: restored.snapshot()
        )
        let activeChain = try XCTUnwrap(
            reactivationRecords.first { $0.entityType == .taskChain }
        )
        var noteHeavyAbandonedChain = try XCTUnwrap(abandoned.chains[chainID])
        noteHeavyAbandonedChain.noteEntries.append(
            try TaskNoteEntry(
                body: "废弃分支较晚附言",
                now: now.addingTimeInterval(40)
            )
        )
        let noteHeavyAbandonedChainRecord = try mapper.record(
            for: noteHeavyAbandonedChain,
            modifiedBy: SyncDeviceID("note-heavy-abandoned-chain-device")
        )

        for contextRecords in [[], [abandonedChain]] {
            for writes in permutations(of: [abandonedTrace, restoredTrace] + contextRecords) {
                let local = LocalFolderSyncTransport(rootURL: makeFolderURL())
                let memory = InMemorySyncTransport()
                try await local.push(writes)
                try await memory.push(writes)

                let localRecords = try await local.fetchAll()
                let memoryRecords = try await memory.fetchAll()
                let traceRecord = try XCTUnwrap(
                    localRecords.first { $0.entityType == .dayTrace }
                )
                let merged = try mapper.decodeDayTrace(traceRecord)

                XCTAssertEqual(localRecords, memoryRecords)
                XCTAssertEqual(merged.status, .abandoned)
                XCTAssertEqual(merged.settledAt, now.addingTimeInterval(20))
            }
        }

        let activeContextRecords = [
            abandonedTrace,
            restoredTrace,
            abandonedChain,
            activeChain,
            noteHeavyAbandonedChainRecord
        ]
        for writes in permutations(of: activeContextRecords) {
            let local = LocalFolderSyncTransport(rootURL: makeFolderURL())
            let memory = InMemorySyncTransport()
            try await local.push(writes)
            try await memory.push(writes)

            let localRecords = try await local.fetchAll()
            let memoryRecords = try await memory.fetchAll()
            let traceRecord = try XCTUnwrap(
                localRecords.first { $0.entityType == .dayTrace }
            )
            let merged = try mapper.decodeDayTrace(traceRecord)
            let chainRecord = try XCTUnwrap(
                localRecords.first { $0.entityType == .taskChain }
            )
            let mergedChain = try mapper.decodeTaskChain(chainRecord)

            XCTAssertEqual(localRecords, memoryRecords)
            XCTAssertEqual(merged.status, .pending)
            XCTAssertNil(merged.settledAt)
            XCTAssertEqual(mergedChain.state, .active)
            XCTAssertEqual(
                mergedChain.activeNoteEntries.map(\.body),
                ["废弃分支较晚附言"]
            )
        }
    }

    func testAbandonedChainRejectsLaterStaleActiveRenameWhileMergingNotesAcrossTransports() async throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "废弃链拒绝旧分支复活",
            now: now
        )
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )

        let abandoned = try NoonmarkEngine(snapshot: base.snapshot())
        try abandoned.abandonChain(
            from: traceID,
            now: now.addingTimeInterval(20)
        )

        let staleActive = try NoonmarkEngine(snapshot: base.snapshot())
        try staleActive.renameTaskTitle(
            chainID: chainID,
            title: "旧分支较晚改名",
            today: today,
            now: now.addingTimeInterval(30)
        )
        var staleActiveChain = try XCTUnwrap(staleActive.chains[chainID])
        staleActiveChain.noteEntries.append(
            try TaskNoteEntry(
                body: "旧 active 分支附言仍需合并",
                now: now.addingTimeInterval(40)
            )
        )

        let mapper = SyncRecordMapper()
        let abandonedBranch = [
            try mapper.record(
                for: try XCTUnwrap(abandoned.chains[chainID]),
                modifiedBy: SyncDeviceID("abandoned-chain-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(abandoned.traces[traceID]),
                modifiedBy: SyncDeviceID("abandoned-trace-device")
            )
        ]
        let staleActiveBranch = [
            try mapper.record(
                for: staleActiveChain,
                modifiedBy: SyncDeviceID("stale-active-chain-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(staleActive.traces[traceID]),
                modifiedBy: SyncDeviceID("stale-active-trace-device")
            )
        ]

        for branches in [
            (first: abandonedBranch, second: staleActiveBranch),
            (first: staleActiveBranch, second: abandonedBranch)
        ] {
            for firstWrites in permutations(of: branches.first) {
                for secondWrites in permutations(of: branches.second) {
                    let local = LocalFolderSyncTransport(rootURL: makeFolderURL())
                    let memory = InMemorySyncTransport()
                    try await local.push(firstWrites)
                    try await memory.push(firstWrites)
                    try await local.push(secondWrites)
                    try await memory.push(secondWrites)

                    let localRecords = try await local.fetchAll()
                    let memoryRecords = try await memory.fetchAll()
                    let mergedChain = try mapper.decodeTaskChain(try XCTUnwrap(
                        localRecords.first { $0.entityType == .taskChain }
                    ))
                    let mergedTrace = try mapper.decodeDayTrace(try XCTUnwrap(
                        localRecords.first { $0.entityType == .dayTrace }
                    ))

                    XCTAssertEqual(localRecords, memoryRecords)
                    XCTAssertEqual(mergedChain.state, .abandoned)
                    XCTAssertEqual(
                        mergedChain.activeNoteEntries.map(\.body),
                        ["旧 active 分支附言仍需合并"]
                    )
                    XCTAssertEqual(mergedTrace.status, .abandoned)
                    XCTAssertEqual(mergedTrace.settledAt, now.addingTimeInterval(20))
                }
            }
        }
    }

    func testExplicitReactivationPairWinsAcrossTransportPushOrders() async throws {
        let abandoned = NoonmarkEngine()
        let chainID = try abandoned.createPoolTask(
            title: "合法恢复跨推送顺序",
            now: now
        )
        let traceID = try abandoned.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try abandoned.abandonChain(
            from: traceID,
            now: now.addingTimeInterval(20)
        )

        let restored = try NoonmarkEngine(snapshot: abandoned.snapshot())
        _ = try restored.reactivateAbandonedChain(
            from: traceID,
            today: today,
            now: now.addingTimeInterval(30)
        )
        let reactivationJournal = try SyncSnapshotDiffer().journalEntries(
            from: abandoned.snapshot(),
            to: restored.snapshot(),
            changedAt: now.addingTimeInterval(30),
            deviceID: SyncDeviceID("restored-device")
        )
        let offlineNoteID = try restored.appendTraceNote(
            traceID: traceID,
            body: "恢复后首次上传前的离线附言",
            today: today,
            now: now.addingTimeInterval(40)
        )

        let mapper = SyncRecordMapper()
        let abandonedBranch = [
            try mapper.record(
                for: try XCTUnwrap(abandoned.chains[chainID]),
                modifiedBy: SyncDeviceID("abandoned-chain-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(abandoned.traces[traceID]),
                modifiedBy: SyncDeviceID("abandoned-trace-device")
            )
        ]
        let restoredBranch = try SyncRecordMaterializer(mapper: mapper).records(
            for: reactivationJournal,
            in: restored.snapshot()
        )

        for branches in [
            (first: abandonedBranch, second: restoredBranch),
            (first: restoredBranch, second: abandonedBranch)
        ] {
            for firstWrites in permutations(of: branches.first) {
                for secondWrites in permutations(of: branches.second) {
                    let local = LocalFolderSyncTransport(rootURL: makeFolderURL())
                    let memory = InMemorySyncTransport()
                    try await local.push(firstWrites)
                    try await memory.push(firstWrites)
                    try await local.push(secondWrites)
                    try await memory.push(secondWrites)

                    let localRecords = try await local.fetchAll()
                    let memoryRecords = try await memory.fetchAll()
                    let mergedChain = try mapper.decodeTaskChain(try XCTUnwrap(
                        localRecords.first { $0.entityType == .taskChain }
                    ))
                    let mergedTrace = try mapper.decodeDayTrace(try XCTUnwrap(
                        localRecords.first { $0.entityType == .dayTrace }
                    ))

                    XCTAssertEqual(localRecords, memoryRecords)
                    XCTAssertEqual(mergedChain.state, .active)
                    XCTAssertEqual(mergedTrace.status, .pending)
                    XCTAssertNil(mergedTrace.settledAt)
                    XCTAssertEqual(mergedTrace.noteEntries.map(\.id), [offlineNoteID])
                    XCTAssertEqual(
                        mergedTrace.activeNoteEntries.map(\.body),
                        ["恢复后首次上传前的离线附言"]
                    )

                    try await local.push(restoredBranch)
                    try await memory.push(restoredBranch)
                    let replayedLocalRecords = try await local.fetchAll()
                    let replayedMemoryRecords = try await memory.fetchAll()
                    XCTAssertEqual(replayedLocalRecords, localRecords)
                    XCTAssertEqual(replayedMemoryRecords, memoryRecords)
                }
            }
        }
    }

    func testStaleCompletionUndoCannotReactivateAbandonedChainAcrossTransports() async throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "跨 transport 拒绝伪造恢复",
            now: now
        )
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )

        let abandoned = try NoonmarkEngine(snapshot: base.snapshot())
        try abandoned.abandonChain(
            from: traceID,
            now: now.addingTimeInterval(20)
        )

        let stale = try NoonmarkEngine(snapshot: base.snapshot())
        try stale.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(30)
        )
        try stale.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(40)
        )

        let mapper = SyncRecordMapper()
        let abandonedBranch = [
            try mapper.record(
                for: try XCTUnwrap(abandoned.chains[chainID]),
                modifiedBy: SyncDeviceID("abandoned-chain-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(abandoned.traces[traceID]),
                modifiedBy: SyncDeviceID("abandoned-trace-device")
            )
        ]
        let staleBranch = [
            try mapper.record(
                for: try XCTUnwrap(stale.chains[chainID]),
                modifiedBy: SyncDeviceID("stale-chain-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(stale.traces[traceID]),
                modifiedBy: SyncDeviceID("stale-trace-device")
            )
        ]
        var canonicalResults: [[SyncRecord]] = []

        for branches in [
            (first: abandonedBranch, second: staleBranch),
            (first: staleBranch, second: abandonedBranch)
        ] {
            for firstWrites in permutations(of: branches.first) {
                for secondWrites in permutations(of: branches.second) {
                    let local = LocalFolderSyncTransport(rootURL: makeFolderURL())
                    let memory = InMemorySyncTransport()
                    try await local.push(firstWrites)
                    try await memory.push(firstWrites)
                    try await local.push(secondWrites)
                    try await memory.push(secondWrites)

                    let localRecords = try await local.fetchAll()
                    let memoryRecords = try await memory.fetchAll()
                    let mergedChain = try mapper.decodeTaskChain(try XCTUnwrap(
                        localRecords.first { $0.entityType == .taskChain }
                    ))
                    let mergedTrace = try mapper.decodeDayTrace(try XCTUnwrap(
                        localRecords.first { $0.entityType == .dayTrace }
                    ))

                    XCTAssertEqual(localRecords, memoryRecords)
                    XCTAssertEqual(mergedChain.state, .abandoned)
                    XCTAssertEqual(mergedTrace.status, .abandoned)
                    XCTAssertEqual(
                        mergedTrace.settledAt,
                        now.addingTimeInterval(20)
                    )
                    canonicalResults.append(localRecords)
                }
            }
        }

        for result in canonicalResults.dropFirst() {
            XCTAssertEqual(result, canonicalResults[0])
        }
    }

    func testFirstHistoricalTraceRecordWithDuplicateNoteIdentityFailsClosed() async throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "历史重复附言",
            initialNoteBody: "唯一附言",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try engine.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(20)
        )
        var malformed = try XCTUnwrap(engine.traces[traceID])
        malformed.noteEntries.append(try XCTUnwrap(malformed.noteEntries.first))
        let record = try SyncRecordMapper().record(
            for: malformed,
            modifiedBy: SyncDeviceID("malformed-device")
        )

        let local = LocalFolderSyncTransport(rootURL: makeFolderURL())
        let memory = InMemorySyncTransport()
        await assertInvalidCurrentRecord(record, through: local)
        await assertInvalidCurrentRecord(record, through: memory)
        let localRecords = try await local.fetchAll()
        let memoryRecords = try await memory.fetchAll()
        XCTAssertTrue(localRecords.isEmpty)
        XCTAssertTrue(memoryRecords.isEmpty)
    }

    func testHistoricalTraceKeepsRecordLevelLWWWithoutNoteUnion() async throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "历史轨迹附言",
            initialNoteBody: "初始附言",
            now: now
        )
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let snapshot = base.snapshot()

        let mac = try NoonmarkEngine(snapshot: snapshot)
        _ = try mac.appendTraceNote(
            traceID: traceID,
            body: "Mac 历史分支",
            today: today,
            now: now.addingTimeInterval(10)
        )
        try mac.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(40)
        )

        let phone = try NoonmarkEngine(snapshot: snapshot)
        _ = try phone.appendTraceNote(
            traceID: traceID,
            body: "Phone 历史分支",
            today: today,
            now: now.addingTimeInterval(20)
        )
        try phone.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(50)
        )

        let mapper = SyncRecordMapper()
        let macRecord = try mapper.record(
            for: try XCTUnwrap(mac.traces[traceID]),
            modifiedBy: SyncDeviceID("mac-a")
        )
        let phoneRecord = try mapper.record(
            for: try XCTUnwrap(phone.traces[traceID]),
            modifiedBy: SyncDeviceID("phone-b")
        )
        let expected = phoneRecord.currentRecordLWWOrder(comparedTo: macRecord) == .after
            ? phoneRecord
            : macRecord

        let folderURL = makeFolderURL()
        let local = LocalFolderSyncTransport(rootURL: folderURL)
        let memory = InMemorySyncTransport()
        try await local.push([macRecord, phoneRecord])
        try await memory.push([macRecord, phoneRecord])

        let localRecords = try await local.fetchAll()
        let memoryRecords = try await memory.fetchAll()
        let localRecord = try XCTUnwrap(localRecords.only)
        let memoryRecord = try XCTUnwrap(memoryRecords.only)
        let restored = try mapper.decodeDayTrace(localRecord)
        XCTAssertEqual(localRecord, expected)
        XCTAssertEqual(memoryRecord, expected)
        XCTAssertEqual(restored.status, .completed)
        XCTAssertFalse(
            Set(restored.activeNoteEntries.map(\.body)).isSuperset(
                of: ["Mac 历史分支", "Phone 历史分支"]
            )
        )
    }

    func testCurrentNoteIdentityCollisionFailsClosedAcrossTransports() async throws {
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(title: "附言身份冲突", now: now)
        let chain = try XCTUnwrap(engine.snapshot().chains.first)
        let collidingID = TaskNoteEntryID()
        var firstChain = chain
        firstChain.noteEntries = [
            try TaskNoteEntry(id: collidingID, body: "first", now: now)
        ]
        var secondChain = chain
        secondChain.noteEntries = [
            try TaskNoteEntry(
                id: collidingID,
                body: "second",
                now: now.addingTimeInterval(1)
            )
        ]
        let mapper = SyncRecordMapper()
        let first = try mapper.record(
            for: firstChain,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let second = try mapper.record(
            for: secondChain,
            modifiedBy: SyncDeviceID("phone-b")
        )

        let folderURL = makeFolderURL()
        let local = LocalFolderSyncTransport(rootURL: folderURL)
        let memory = InMemorySyncTransport()
        try await local.push([first])
        try await memory.push([first])

        for transport in [local as any SyncRecordTransport, memory as any SyncRecordTransport] {
            do {
                try await transport.push([second])
                XCTFail("附言 createdAt 冲突应 fail-closed")
            } catch {
                XCTAssertEqual(
                    error as? SyncRecordTransportError,
                    .invalidCurrentRecordMerge(recordID: first.id)
                )
            }
        }
        let localRecords = try await local.fetchAll()
        let memoryRecords = try await memory.fetchAll()
        XCTAssertEqual(localRecords, [first])
        XCTAssertEqual(memoryRecords, [first])
    }

    func testLocalFolderRejectsCrossTypeReuseOfImmutableRecordIDInBothDirections() async throws {
        for entityType in immutableEntityTypes {
            let immutableFirstFolder = makeFolderURL()
            let recordID = "preferences:default"
            let immutable = immutableRecord(
                entityType: entityType,
                id: recordID,
                variant: "first"
            )
            let ordinary = try ordinaryRecord(
                id: recordID,
                variant: "replacement"
            )
            let immutableFirstTransport = LocalFolderSyncTransport(rootURL: immutableFirstFolder)
            try await immutableFirstTransport.push([immutable])

            await assertCollision(
                pushing: ordinary,
                through: LocalFolderSyncTransport(rootURL: immutableFirstFolder)
            )
            let immutableFirstRestored = try await immutableFirstTransport.fetchAll()
            XCTAssertEqual(immutableFirstRestored, [immutable])

            let ordinaryFirstFolder = makeFolderURL()
            let ordinaryFirstTransport = LocalFolderSyncTransport(rootURL: ordinaryFirstFolder)
            try await ordinaryFirstTransport.push([ordinary])

            await assertCollision(
                pushing: immutable,
                through: LocalFolderSyncTransport(rootURL: ordinaryFirstFolder)
            )
            let ordinaryFirstRestored = try await ordinaryFirstTransport.fetchAll()
            XCTAssertEqual(ordinaryFirstRestored, [ordinary])
        }
    }

    func testInMemoryTransportUsesTheSameImmutableCollisionBoundary() async throws {
        let recordID = "preferences:default"
        let immutable = immutableRecord(
            entityType: .classificationCommit,
            id: recordID,
            variant: "first"
        )
        let ordinary = try ordinaryRecord(
            id: recordID,
            variant: "replacement"
        )
        let immutableFirst = try InMemorySyncTransport(records: [immutable])
        let ordinaryFirst = try InMemorySyncTransport(records: [ordinary])

        await assertCollision(pushing: ordinary, through: immutableFirst)
        await assertCollision(pushing: immutable, through: ordinaryFirst)

        let immutableFirstRestored = try await immutableFirst.fetchAll()
        let ordinaryFirstRestored = try await ordinaryFirst.fetchAll()
        XCTAssertEqual(immutableFirstRestored, [immutable])
        XCTAssertEqual(ordinaryFirstRestored, [ordinary])
    }

    private func makeDivergentChainRecords() throws -> (
        records: [SyncRecord],
        originalNoteID: TaskNoteEntryID
    ) {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "任务池离线附言",
            initialNoteBody: "初始附言",
            now: now
        )
        let baseSnapshot = base.snapshot()
        let originalNoteID = try XCTUnwrap(
            base.taskPool().first?.chain.activeNoteEntries.first?.id
        )

        let mac = try NoonmarkEngine(snapshot: baseSnapshot)
        _ = try mac.appendPoolNote(
            chainID: chainID,
            body: "Mac 离线新增",
            now: now.addingTimeInterval(10)
        )
        try mac.deletePoolNote(
            chainID: chainID,
            noteID: originalNoteID,
            now: now.addingTimeInterval(30)
        )

        let phone = try NoonmarkEngine(snapshot: baseSnapshot)
        _ = try phone.appendPoolNote(
            chainID: chainID,
            body: "Phone 离线新增",
            now: now.addingTimeInterval(20)
        )
        try phone.editPoolNote(
            chainID: chainID,
            noteID: originalNoteID,
            body: "Phone 同刻编辑",
            now: now.addingTimeInterval(30)
        )

        let mapper = SyncRecordMapper()
        let baseChain = try XCTUnwrap(baseSnapshot.chains.first)
        let macChain = try XCTUnwrap(mac.snapshot().chains.first)
        let phoneChain = try XCTUnwrap(phone.snapshot().chains.first)
        return (
            records: [
                try mapper.record(
                    for: baseChain,
                    modifiedBy: SyncDeviceID("baseline")
                ),
                try mapper.record(
                    for: macChain,
                    modifiedBy: SyncDeviceID("mac-a")
                ),
                try mapper.record(
                    for: phoneChain,
                    modifiedBy: SyncDeviceID("phone-z")
                )
            ],
            originalNoteID: originalNoteID
        )
    }

    private func makeDivergentTraceRecords() throws -> (
        records: [SyncRecord],
        originalNoteID: TaskNoteEntryID
    ) {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "当前轨迹离线附言",
            initialNoteBody: "初始附言",
            now: now
        )
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let baseSnapshot = base.snapshot()
        let originalNoteID = try XCTUnwrap(
            base.traces[traceID]?.activeNoteEntries.first?.id
        )

        let mac = try NoonmarkEngine(snapshot: baseSnapshot)
        _ = try mac.appendTraceNote(
            traceID: traceID,
            body: "Mac 轨迹新增",
            today: today,
            now: now.addingTimeInterval(10)
        )
        try mac.deleteTraceNote(
            traceID: traceID,
            noteID: originalNoteID,
            today: today,
            now: now.addingTimeInterval(30)
        )

        let phone = try NoonmarkEngine(snapshot: baseSnapshot)
        _ = try phone.appendTraceNote(
            traceID: traceID,
            body: "Phone 轨迹新增",
            today: today,
            now: now.addingTimeInterval(20)
        )
        try phone.editTraceNote(
            traceID: traceID,
            noteID: originalNoteID,
            body: "Phone 同刻编辑",
            today: today,
            now: now.addingTimeInterval(30)
        )

        let mapper = SyncRecordMapper()
        return (
            records: [
                try mapper.record(
                    for: try XCTUnwrap(base.traces[traceID]),
                    modifiedBy: SyncDeviceID("baseline")
                ),
                try mapper.record(
                    for: try XCTUnwrap(mac.traces[traceID]),
                    modifiedBy: SyncDeviceID("mac-a")
                ),
                try mapper.record(
                    for: try XCTUnwrap(phone.traces[traceID]),
                    modifiedBy: SyncDeviceID("phone-z")
                )
            ],
            originalNoteID: originalNoteID
        )
    }

    private var immutableEntityTypes: [SyncEntityType] {
        [
            .classificationBaseline,
            .classificationCommit,
            .traceClassificationEvent
        ]
    }

    private func immutableRecord(
        entityType: SyncEntityType,
        id: String,
        variant: String
    ) -> SyncRecord {
        SyncRecord(
            id: SyncRecordID(id),
            entityType: entityType,
            entityID: "entity-\(variant)",
            operation: variant == "first" ? .upsert : .delete,
            modifiedAt: Date(
                timeIntervalSinceReferenceDate: variant == "first" ? 111.125 : 222.25
            ),
            modifiedByDeviceID: SyncDeviceID("device-\(variant)"),
            payload: Data("payload-\(variant)".utf8)
        )
    }

    private func ordinaryRecord(
        id: String = "preferences:default",
        variant: String
    ) throws -> SyncRecord {
        try ordinaryRecord(
            id: id,
            modifiedAt: Date(
                timeIntervalSinceReferenceDate: variant == "first"
                    ? 333.5
                    : 444.75
            ),
            deviceID: "device-\(variant)",
            payload: Data("payload-\(variant)".utf8)
        )
    }

    private func ordinaryRecord(
        id: String = "preferences:default",
        modifiedAt: Date,
        deviceID: String,
        payload: Data
    ) throws -> SyncRecord {
        let selector = payload.first ?? 0
        var record = try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: selector >= 0x80 ? .warmPaper : .coolGray,
                language: selector.isMultiple(of: 2) ? .chinese : .english,
                updatedAt: modifiedAt
            ),
            modifiedBy: SyncDeviceID(deviceID)
        )
        record.id = SyncRecordID(id)
        return record
    }

    private func permutations<T>(of values: [T]) -> [[T]] {
        guard let first = values.first else { return [[]] }
        return permutations(of: Array(values.dropFirst())).flatMap { tail in
            (0 ... tail.count).map { index in
                var result = tail
                result.insert(first, at: index)
                return result
            }
        }
    }

    private func assertCollision(
        pushing record: SyncRecord,
        through transport: any SyncRecordTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await transport.push([record])
            XCTFail("immutable record collision 应 fail-closed", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .immutableRecordCollision(recordID: record.id),
                file: file,
                line: line
            )
        }
    }

    private func assertBatchCollision(
        _ records: [SyncRecord],
        through transport: any SyncRecordTransport,
        recordID: SyncRecordID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await transport.push(records)
            XCTFail("immutable batch collision 应 fail-closed", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .immutableRecordCollision(recordID: recordID),
                file: file,
                line: line
            )
        }
    }

    private func assertInvalidCurrentRecord(
        _ record: SyncRecord,
        through transport: any SyncRecordTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await transport.push([record])
            XCTFail("invalid current record 应 fail-closed", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .invalidCurrentRecordMerge(recordID: record.id),
                file: file,
                line: line
            )
        }
    }

    private func storedRecordData(in folderURL: URL) throws -> Data {
        try Data(contentsOf: storedRecordURL(in: folderURL))
    }

    private func batchURLs(in folderURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folderURL.appendingPathComponent(
                "batches",
                isDirectory: true
            ),
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
    }

    private func storedRecordURL(in folderURL: URL) throws -> URL {
        let recordURLs = try FileManager.default.contentsOfDirectory(
            at: folderURL.appendingPathComponent("records", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        return try XCTUnwrap(recordURLs.only)
    }

    private func writeConflictCopy(_ record: SyncRecord, to folderURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let conflictURL = folderURL
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("icloud conflicted copy \(UUID().uuidString).json")
        try encoder.encode(record).write(to: conflictURL, options: .atomic)
    }

    private func makeFolderURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-local-folder-sync-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private enum PushOutcome: Equatable {
    case success
    case collision(SyncRecordID)
    case unexpected(String)

    var isSuccess: Bool {
        self == .success
    }
}

private func immutablePushOutcome(
    _ record: SyncRecord,
    through transport: LocalFolderSyncTransport
) async -> PushOutcome {
    do {
        try await transport.push([record])
        return .success
    } catch let error as SyncRecordTransportError {
        guard error == .immutableRecordCollision(recordID: record.id) else {
            return .unexpected(String(describing: error))
        }
        return .collision(record.id)
    } catch {
        return .unexpected(String(describing: error))
    }
}

private enum InjectedPublicationError: Error {
    case interrupted
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
