import CryptoKit
import Foundation

public actor LocalFolderSyncTransport: SyncRecordTransport {
    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func push(_ records: [SyncRecord]) async throws {
        try prepareRepository()
        for record in records {
            let data = try encoder.encode(record)
            try data.write(to: recordURL(for: record.id), options: [.atomic])
        }

        guard records.isEmpty == false else { return }
        let deviceID = records.first?.modifiedByDeviceID ?? SyncDeviceID("unknown")
        let snapshot = try SyncRepositorySnapshotBuilder().snapshot(records: records, deviceID: deviceID)
        try pushSnapshot(snapshot)
    }

    public func fetchAll() async throws -> [SyncRecord] {
        try prepareRepository()
        let recordDirectory = recordsURL
        guard fileManager.fileExists(atPath: recordDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: recordDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .map { try decoder.decode(SyncRecord.self, from: Data(contentsOf: $0)) }
        .sorted {
            if $0.entityType.rawValue != $1.entityType.rawValue {
                return $0.entityType.rawValue < $1.entityType.rawValue
            }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    public func fetchSnapshots() async throws -> [SyncRepositorySnapshot] {
        try prepareRepository()
        guard fileManager.fileExists(atPath: indexesURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: indexesURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .map { try decoder.decode(SyncRepositorySnapshot.self, from: Data(contentsOf: $0)) }
        .sorted { $0.createdAt < $1.createdAt }
    }

    private func pushSnapshot(_ snapshot: SyncRepositorySnapshot) throws {
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL(for: snapshot.id), options: [.atomic])
        try snapshot.id.write(to: latestRefURL, atomically: true, encoding: .utf8)
    }

    private func prepareRepository() throws {
        try fileManager.createDirectory(at: recordsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: indexesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: refsURL, withIntermediateDirectories: true)
    }

    private var recordsURL: URL {
        rootURL.appendingPathComponent("records", isDirectory: true)
    }

    private var indexesURL: URL {
        rootURL.appendingPathComponent("indexes", isDirectory: true)
    }

    private var refsURL: URL {
        rootURL.appendingPathComponent("refs", isDirectory: true)
    }

    private var latestRefURL: URL {
        refsURL.appendingPathComponent("latest")
    }

    private func recordURL(for id: SyncRecordID) -> URL {
        recordsURL.appendingPathComponent("\(stableFileName(for: id.rawValue)).json")
    }

    private func snapshotURL(for id: String) -> URL {
        indexesURL.appendingPathComponent("\(stableFileName(for: id)).json")
    }

    private func stableFileName(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
