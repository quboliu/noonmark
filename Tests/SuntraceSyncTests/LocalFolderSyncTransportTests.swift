@testable import SuntraceCore
@testable import SuntraceSync
import XCTest

final class LocalFolderSyncTransportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testLocalFolderTransportPersistsRecordsAndSnapshotIndex() async throws {
        let folderURL = makeFolderURL()
        let engine = SuntraceEngine()
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

    private func makeFolderURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("suntrace-local-folder-sync-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
