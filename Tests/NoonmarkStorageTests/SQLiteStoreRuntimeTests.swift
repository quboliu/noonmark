import Foundation
@testable import NoonmarkStorage
import NoonmarkCore
import NoonmarkSync
import XCTest

final class SQLiteStoreRuntimeTests: XCTestCase {
    func testAllRepositoriesShareOneProcessWriterLane() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Noonmark.sqlite")
        defer {
            try? FileManager.default.removeItem(
                at: databaseURL.deletingLastPathComponent()
            )
        }
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(NoonmarkEngine())

        let operationCount = 96
        let startGate = DispatchSemaphore(value: 0)
        let finished = expectation(description: "all SQLite writers finished")
        finished.expectedFulfillmentCount = operationCount
        let failures = FailureCounter()
        let queue = DispatchQueue(
            label: "app.noonmark.tests.sqlite-writer-lane",
            attributes: .concurrent
        )

        for index in 0 ..< operationCount {
            queue.async {
                startGate.wait()
                defer { finished.fulfill() }
                do {
                    switch index % 6 {
                    case 0:
                        try SQLiteEngineRepository(databaseURL: databaseURL)
                            .save(NoonmarkEngine())
                    case 1:
                        _ = try SQLiteReplicationLedger(databaseURL: databaseURL)
                            .loadOrInstallActiveProducerID(
                                suggestedProducerID: UUID(),
                                installedAt: Date(
                                    timeIntervalSinceReferenceDate: 810_000_000
                                )
                            )
                    case 2:
                        try SQLiteSyncRepository(databaseURL: databaseURL)
                            .saveMetadata(
                                SyncMetadataEntry(
                                    key: "writer-lane-\(index)",
                                    value: Data([UInt8(index)]),
                                    updatedAt: Date(
                                        timeIntervalSinceReferenceDate:
                                            810_000_000 + Double(index)
                                    )
                                )
                            )
                    case 3:
                        _ = try SQLiteEngineRepository(databaseURL: databaseURL)
                            .load()
                    case 4:
                        _ = try SQLiteReplicationLedger(databaseURL: databaseURL)
                            .cleanCutAuthority()
                    default:
                        _ = try SQLiteSyncRepository(databaseURL: databaseURL)
                            .metadata(for: "writer-lane-2")
                    }
                } catch {
                    failures.record(error, operation: index % 3)
                }
            }
        }
        for _ in 0 ..< operationCount {
            startGate.signal()
        }

        wait(for: [finished], timeout: 30)
        XCTAssertEqual(
            failures.count,
            0,
            "SQLite codes: \(failures.sqliteCodes.sorted { $0.key < $1.key }); "
                + "operations: \(failures.operations.sorted { $0.key < $1.key })"
        )
        for index in 0 ..< operationCount where index % 6 == 2 {
            XCTAssertNotNil(
                try SQLiteSyncRepository(databaseURL: databaseURL)
                    .metadata(for: "writer-lane-\(index)")
            )
        }
    }
}

private final class FailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    private var codeStorage: [Int32: Int] = [:]
    private var operationStorage: [Int: Int] = [:]

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var sqliteCodes: [Int32: Int] {
        lock.lock()
        defer { lock.unlock() }
        return codeStorage
    }

    var operations: [Int: Int] {
        lock.lock()
        defer { lock.unlock() }
        return operationStorage
    }

    func record(_ error: Error, operation: Int) {
        lock.lock()
        storage += 1
        operationStorage[operation, default: 0] += 1
        if let code = sqliteCode(error) {
            codeStorage[code, default: 0] += 1
        }
        lock.unlock()
    }

    private func sqliteCode(_ error: Error) -> Int32? {
        guard let error = error as? SQLiteRepositoryError else { return nil }
        switch error {
        case let .openFailed(_, code), let .prepareFailed(_, code),
             let .executeFailed(_, code), let .stepFailed(_, code),
             let .backupFailed(_, code):
            return code
        case .transientContention, .invalidStoredValue:
            return nil
        }
    }
}
