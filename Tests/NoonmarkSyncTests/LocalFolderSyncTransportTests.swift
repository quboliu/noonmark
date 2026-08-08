@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class LocalFolderSyncTransportTests: XCTestCase {
    private let epochA = UUID(
        uuidString: "A0000000-0000-0000-0000-000000000001"
    )!
    private let epochB = UUID(
        uuidString: "B0000000-0000-0000-0000-000000000002"
    )!

    func testPushPublishesOneImmutableBatchAndOneHead() async throws {
        let root = makeFolderURL()
        let transport = LocalFolderSyncTransport(
            rootURL: root,
            producerEpochID: epochA
        )
        let record = try preferenceRecord(index: 1)

        let receipt = try await transport.pushAccepting([record])
        let page = try await transport.pull(after: .origin, limit: 100)

        XCTAssertEqual(receipt.confirmation, .confirmed)
        XCTAssertEqual(receipt.batches.count, 1)
        XCTAssertEqual(page.records, [record])
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.openedBatchCount, 1)
        XCTAssertEqual(try headFiles(in: root).count, 1)
        XCTAssertEqual(try batchFiles(in: root).count, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("records").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("refs").path
            )
        )
    }

    func testSteadyStatePullOpensOnlyUnseenBatches() async throws {
        let root = makeFolderURL()
        let producer = LocalFolderSyncTransport(
            rootURL: root,
            producerEpochID: epochA
        )
        for index in 0 ..< 200 {
            try await producer.push([try preferenceRecord(index: index)])
        }

        let bootstrap = try await producer.pull(after: .origin, limit: 10_000)
        XCTAssertEqual(bootstrap.openedBatchCount, 200)
        let unchanged = try await producer.pull(
            after: bootstrap.frontier,
            limit: 10_000
        )
        XCTAssertTrue(unchanged.records.isEmpty)
        XCTAssertEqual(unchanged.openedBatchCount, 0)
        XCTAssertEqual(unchanged.observedProducerCount, 1)

        try await producer.push([try preferenceRecord(index: 200)])
        let incremental = try await producer.pull(
            after: bootstrap.frontier,
            limit: 10_000
        )
        XCTAssertEqual(incremental.records.count, 1)
        XCTAssertEqual(incremental.openedBatchCount, 1)
        XCTAssertEqual(try batchFiles(in: root).count, 201)
    }

    func testIndependentProducerChainsInterleaveWithoutSharedHead() async throws {
        let root = makeFolderURL()
        let first = LocalFolderSyncTransport(
            rootURL: root,
            producerEpochID: epochA
        )
        let second = LocalFolderSyncTransport(
            rootURL: root,
            producerEpochID: epochB
        )
        try await first.push([try preferenceRecord(index: 1)])
        try await second.push([try preferenceRecord(index: 2)])
        try await first.push([try preferenceRecord(index: 3)])

        var frontier = SyncTransportFrontier.origin
        var fetched: [SyncRecord] = []
        while true {
            let page = try await second.pull(after: frontier, limit: 1)
            fetched.append(contentsOf: page.records)
            frontier = page.frontier
            guard page.hasMore else { break }
        }

        XCTAssertEqual(fetched.count, 3)
        XCTAssertEqual(frontier.positions.count, 2)
        XCTAssertEqual(try headFiles(in: root).count, 2)
        XCTAssertEqual(try batchFiles(in: root).count, 3)
    }

    func testCrashAfterBatchWriteRetriesExactSequenceAndPublishesHead()
        async throws
    {
        let root = makeFolderURL()
        let record = try preferenceRecord(index: 1)
        let interrupted = LocalFolderSyncTransport(
            rootURL: root,
            producerEpochID: epochA
        ) { point in
            if point == .didPublishBatch {
                throw InjectedPublicationError.interrupted
            }
        }
        await XCTAssertThrowsErrorAsync(
            try await interrupted.push([record])
        )
        XCTAssertEqual(try batchFiles(in: root).count, 1)
        XCTAssertTrue(try headFiles(in: root).isEmpty)

        let recovered = LocalFolderSyncTransport(
            rootURL: root,
            producerEpochID: epochA
        )
        try await recovered.push([record])
        let page = try await recovered.pull(after: .origin, limit: 10)
        XCTAssertEqual(page.records, [record])
        XCTAssertEqual(try batchFiles(in: root).count, 1)
        XCTAssertEqual(try headFiles(in: root).count, 1)
    }

    func testLostReceiptAfterHeadPublicationRetriesIdempotently()
        async throws
    {
        let root = makeFolderURL()
        let record = try preferenceRecord(index: 1)
        let interrupted = LocalFolderSyncTransport(
            rootURL: root,
            producerEpochID: epochA
        ) { point in
            if point == .didPublishHead {
                throw InjectedPublicationError.interrupted
            }
        }
        await XCTAssertThrowsErrorAsync(
            try await interrupted.push([record])
        )
        XCTAssertEqual(try batchFiles(in: root).count, 1)
        XCTAssertEqual(try headFiles(in: root).count, 1)

        let recovered = LocalFolderSyncTransport(
            rootURL: root,
            producerEpochID: epochA
        )
        let receipt = try await recovered.pushAccepting([record])
        XCTAssertEqual(receipt.batches.first?.sequence, 1)
        XCTAssertEqual(try batchFiles(in: root).count, 1)
        XCTAssertEqual(try headFiles(in: root).count, 1)
    }

    func testMissingSequenceBlocksFrontierAdvancement() async throws {
        let root = makeFolderURL()
        let transport = LocalFolderSyncTransport(
            rootURL: root,
            producerEpochID: epochA
        )
        try await transport.push([try preferenceRecord(index: 1)])
        try await transport.push([try preferenceRecord(index: 2)])
        let firstBatch = try XCTUnwrap(try batchFiles(in: root).first)
        try FileManager.default.removeItem(at: firstBatch)

        await XCTAssertThrowsErrorAsync(
            try await transport.pull(after: .origin, limit: 10)
        ) { error in
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .missingBatch(
                    producerID: self.epochA.uuidString.lowercased(),
                    sequence: 1
                )
            )
        }
    }

    func testTamperedTipBatchFailsHashValidation() async throws {
        let root = makeFolderURL()
        let transport = LocalFolderSyncTransport(
            rootURL: root,
            producerEpochID: epochA
        )
        try await transport.push([try preferenceRecord(index: 1)])
        let batch = try XCTUnwrap(try batchFiles(in: root).first)
        var bytes = try Data(contentsOf: batch)
        bytes.append(0x20)
        try bytes.write(to: batch)

        await XCTAssertThrowsErrorAsync(
            try await transport.pull(after: .origin, limit: 10)
        ) { error in
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .invalidBatchHash(
                    producerID: self.epochA.uuidString.lowercased(),
                    sequence: 1
                )
            )
        }
    }

    func testTamperedNonTipBatchFailsBeforeItsRecordsAreApplied()
        async throws
    {
        let root = makeFolderURL()
        let transport = LocalFolderSyncTransport(
            rootURL: root,
            producerEpochID: epochA
        )
        try await transport.push([try preferenceRecord(index: 0)])
        try await transport.push([try preferenceRecord(index: 1)])
        let firstBatch = try XCTUnwrap(try batchFiles(in: root).first)
        let original = try String(
            decoding: Data(contentsOf: firstBatch),
            as: UTF8.self
        )
        let tampered = original.replacingOccurrences(
            of: "coolGray",
            with: "warmPaper"
        )
        XCTAssertNotEqual(tampered, original)
        try Data(tampered.utf8).write(to: firstBatch)

        await XCTAssertThrowsErrorAsync(
            try await transport.pull(after: .origin, limit: 1)
        ) { error in
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .invalidBatchHash(
                    producerID: self.epochA.uuidString.lowercased(),
                    sequence: 1
                )
            )
        }
    }

    func testLegacyRepositoryIsRejectedInsteadOfMixed() async throws {
        let root = makeFolderURL()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("refs"),
            withIntermediateDirectories: true
        )
        let transport = LocalFolderSyncTransport(
            rootURL: root,
            producerEpochID: epochA
        )

        await XCTAssertThrowsErrorAsync(
            try await transport.pull(after: .origin, limit: 10)
        ) { error in
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .repositoryFormatMismatch
            )
        }
    }

    func testCanonicalBatchPreservesExactDateBits() async throws {
        let root = makeFolderURL()
        let transport = LocalFolderSyncTransport(
            rootURL: root,
            producerEpochID: epochA
        )
        let date = Date(
            timeIntervalSinceReferenceDate: Double(
                bitPattern: 0x41D9_54FC_4030_39BD
            )
        )
        let record = try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .chinese,
                updatedAt: date
            ),
            modifiedBy: SyncDeviceID("exact-date")
        )
        try await transport.push([record])

        let restored = try XCTUnwrap(
            try await transport.pull(after: .origin, limit: 10)
                .records.first
        )
        XCTAssertEqual(
            restored.modifiedAt.timeIntervalSinceReferenceDate.bitPattern,
            record.modifiedAt.timeIntervalSinceReferenceDate.bitPattern
        )
    }

    private func preferenceRecord(index: Int) throws -> SyncRecord {
        try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: index.isMultiple(of: 2) ? .coolGray : .warmPaper,
                language: index.isMultiple(of: 3) ? .english : .chinese,
                updatedAt: Date(
                    timeIntervalSinceReferenceDate: Double(index + 1)
                )
            ),
            modifiedBy: SyncDeviceID("device-\(index)")
        )
    }

    private func headFiles(in root: URL) throws -> [URL] {
        let directory = root.appendingPathComponent("heads")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }

    private func batchFiles(in root: URL) throws -> [URL] {
        let directory = root.appendingPathComponent("batches")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        let producers = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return try producers.flatMap { producer in
            try FileManager.default.contentsOfDirectory(
                at: producer,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
        }.sorted { $0.path < $1.path }
    }

    private func makeFolderURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-incremental-sync-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private enum InjectedPublicationError: Error {
    case interrupted
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
