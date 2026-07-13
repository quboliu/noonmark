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

    func testLocalFolderTransportPreservesModifiedAtBitPatternExactly() async throws {
        let folderURL = makeFolderURL()
        let exactDate = Date(
            timeIntervalSinceReferenceDate: Double(
                bitPattern: 0x41C8_3456_789A_BCDE
            )
        )
        let record = SyncRecord(
            id: SyncRecordID("exact-date"),
            entityType: .appPreferences,
            entityID: "default",
            modifiedAt: exactDate,
            modifiedByDeviceID: SyncDeviceID("mac-exact"),
            payload: Data([0x01])
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
        let first = ordinaryRecord(variant: "first")
        let replacement = ordinaryRecord(variant: "replacement")
        let transport = LocalFolderSyncTransport(rootURL: folderURL)

        try await transport.push([first])
        try await LocalFolderSyncTransport(rootURL: folderURL).push([replacement])

        let restored = try await transport.fetchAll()
        XCTAssertEqual(restored, [replacement])
    }

    func testOrdinaryCurrentRecordIgnoresLateStaleWriteAcrossTransports() async throws {
        let newer = ordinaryRecord(
            modifiedAt: now.addingTimeInterval(10),
            deviceID: "mac-newer",
            payload: Data("newer".utf8)
        )
        let stale = ordinaryRecord(
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

    func testEqualTimeLWWTieBreakConvergesForEveryWritePermutationAcrossTransports() async throws {
        let lowerDevice = ordinaryRecord(
            modifiedAt: now,
            deviceID: "mac-a",
            payload: Data([0xFF])
        )
        let higherDevice = ordinaryRecord(
            modifiedAt: now,
            deviceID: "mac-z",
            payload: Data([0x00])
        )
        let payloadWinner = ordinaryRecord(
            modifiedAt: now,
            deviceID: "mac-z",
            payload: Data([0xFF])
        )

        XCTAssertEqual(
            higherDevice.currentRecordLWWOrder(comparedTo: lowerDevice),
            .after
        )
        XCTAssertEqual(
            payloadWinner.currentRecordLWWOrder(comparedTo: higherDevice),
            .after
        )
        XCTAssertEqual(
            lowerDevice.currentRecordLWWOrder(comparedTo: payloadWinner),
            .before
        )

        for writes in permutations(of: [lowerDevice, higherDevice, payloadWinner]) {
            let folderURL = makeFolderURL()
            let local = LocalFolderSyncTransport(rootURL: folderURL)
            let memory = InMemorySyncTransport()
            for record in writes {
                try await local.push([record])
                try await memory.push([record])
            }

            let localRecords = try await local.fetchAll()
            let memoryRecords = try await memory.fetchAll()
            XCTAssertEqual(localRecords, [payloadWinner])
            XCTAssertEqual(memoryRecords, [payloadWinner])
        }
    }

    func testConcurrentEqualTimeWritersConvergeAcrossLocalFolderActorsAndInMemory() async throws {
        let baseline = ordinaryRecord(
            modifiedAt: now.addingTimeInterval(-1),
            deviceID: "mac-baseline",
            payload: Data("baseline".utf8)
        )
        let lower = ordinaryRecord(
            modifiedAt: now,
            deviceID: "mac-a",
            payload: Data("lower".utf8)
        )
        let winner = ordinaryRecord(
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

            let memory = InMemorySyncTransport(records: [baseline])
            async let lowerMemoryPush: Void = memory.push([lower])
            async let winnerMemoryPush: Void = memory.push([winner])
            _ = try await (lowerMemoryPush, winnerMemoryPush)

            let memoryRecords = try await memory.fetchAll()
            XCTAssertEqual(memoryRecords, [winner])
        }
    }

    func testLocalFolderRejectsCrossTypeReuseOfImmutableRecordIDInBothDirections() async throws {
        for entityType in immutableEntityTypes {
            let immutableFirstFolder = makeFolderURL()
            let recordID = "cross-type-\(entityType.rawValue)"
            let immutable = immutableRecord(
                entityType: entityType,
                id: recordID,
                variant: "first"
            )
            let ordinary = ordinaryRecord(id: recordID, variant: "replacement")
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
        let recordID = "in-memory-cross-type"
        let immutable = immutableRecord(
            entityType: .classificationCommit,
            id: recordID,
            variant: "first"
        )
        let ordinary = ordinaryRecord(id: recordID, variant: "replacement")
        let immutableFirst = InMemorySyncTransport(records: [immutable])
        let ordinaryFirst = InMemorySyncTransport(records: [ordinary])

        await assertCollision(pushing: ordinary, through: immutableFirst)
        await assertCollision(pushing: immutable, through: ordinaryFirst)

        let immutableFirstRestored = try await immutableFirst.fetchAll()
        let ordinaryFirstRestored = try await ordinaryFirst.fetchAll()
        XCTAssertEqual(immutableFirstRestored, [immutable])
        XCTAssertEqual(ordinaryFirstRestored, [ordinary])
    }

    private var immutableEntityTypes: [SyncEntityType] {
        [.classificationCommit, .traceClassificationEvent]
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
        id: String = "ordinary-current-record",
        variant: String
    ) -> SyncRecord {
        SyncRecord(
            id: SyncRecordID(id),
            entityType: .appPreferences,
            entityID: "default",
            modifiedAt: Date(
                timeIntervalSinceReferenceDate: variant == "first" ? 333.5 : 444.75
            ),
            modifiedByDeviceID: SyncDeviceID("device-\(variant)"),
            payload: Data("payload-\(variant)".utf8)
        )
    }

    private func ordinaryRecord(
        id: String = "ordinary-current-record",
        modifiedAt: Date,
        deviceID: String,
        payload: Data
    ) -> SyncRecord {
        SyncRecord(
            id: SyncRecordID(id),
            entityType: .appPreferences,
            entityID: "default",
            modifiedAt: modifiedAt,
            modifiedByDeviceID: SyncDeviceID(deviceID),
            payload: payload
        )
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

    private func storedRecordData(in folderURL: URL) throws -> Data {
        try Data(contentsOf: storedRecordURL(in: folderURL))
    }

    private func storedRecordURL(in folderURL: URL) throws -> URL {
        let recordURLs = try FileManager.default.contentsOfDirectory(
            at: folderURL.appendingPathComponent("records", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        return try XCTUnwrap(recordURLs.only)
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

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
