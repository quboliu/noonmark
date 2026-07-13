import CryptoKit
import Darwin
import Foundation

public actor LocalFolderSyncTransport: SyncRecordTransport {
    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let currentRecordMerger: CurrentSyncRecordMerger

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        currentRecordMerger = CurrentSyncRecordMerger()
    }

    public func push(_ records: [SyncRecord]) async throws {
        try prepareRepository()
        guard records.isEmpty == false else { return }

        try withExclusiveRepositoryLock {
            let existingRecords = try storedRecords()
            try ImmutableSyncRecordCASPreflight.validate(
                existing: try existingRecords.map {
                    ImmutableSyncRecordCASCandidate(
                        record: $0,
                        exactData: try Data(
                            contentsOf: recordURL(for: $0.id)
                        )
                    )
                },
                incoming: try records.map {
                    ImmutableSyncRecordCASCandidate(
                        record: $0,
                        exactData: try encoder.encode($0)
                    )
                }
            )
            let batch = try currentRecordMerger.prepareTransportBatch(
                existingRecords: existingRecords,
                incomingRecords: records
            )

            var publishedRecords: [SyncRecord] = []
            for record in batch.records {
                if let published = try pushRecord(
                    record,
                    context: batch.mergeContext
                ) {
                    publishedRecords.append(published)
                }
            }

            guard publishedRecords.isEmpty == false else { return }
            let deviceID = records.first?.modifiedByDeviceID ?? SyncDeviceID("unknown")
            let snapshot = try SyncRepositorySnapshotBuilder().snapshot(
                records: publishedRecords,
                deviceID: deviceID
            )
            try pushSnapshot(snapshot)
        }
    }

    public func fetchAll() async throws -> [SyncRecord] {
        try prepareRepository()
        return try storedRecords()
    }

    private func storedRecords() throws -> [SyncRecord] {
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

    private func pushRecord(
        _ record: SyncRecord,
        context: CurrentSyncRecordMergeContext
    ) throws -> SyncRecord? {
        let destinationURL = recordURL(for: record.id)
        let stagingURL = recordsURL.appendingPathComponent(
            ".\(UUID().uuidString).staging"
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        let data = try encoder.encode(record)
        try data.write(to: stagingURL, options: [.atomic])
        guard try publishExclusively(from: stagingURL, to: destinationURL) == false else {
            return record
        }

        guard let existingData = try? Data(contentsOf: destinationURL),
              let existing = try? decoder.decode(SyncRecord.self, from: existingData)
        else {
            throw SyncRecordTransportError.immutableRecordCollision(recordID: record.id)
        }

        let requiresImmutableCAS = existing.entityType.requiresImmutableRecordPayload
            || record.entityType.requiresImmutableRecordPayload
        if requiresImmutableCAS {
            guard record.exactlyMatches(existing), existingData == data else {
                throw SyncRecordTransportError.immutableRecordCollision(recordID: record.id)
            }
            return nil
        }

        let merged: SyncRecord
        do {
            merged = try currentRecordMerger.merge(
                existing: existing,
                incoming: record,
                context: context
            )
        } catch {
            throw SyncRecordTransportError.invalidCurrentRecordMerge(recordID: record.id)
        }
        guard merged.exactlyMatches(existing) == false else {
            return nil
        }
        try encoder.encode(merged).write(to: destinationURL, options: [.atomic])
        return merged
    }

    private func publishExclusively(from sourceURL: URL, to destinationURL: URL) throws -> Bool {
        let failureCode = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return EINVAL }
                guard renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) != 0 else {
                    return 0
                }
                return errno
            }
        }

        switch failureCode {
        case 0:
            return true
        case EEXIST:
            return false
        default:
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(failureCode),
                userInfo: [
                    NSFilePathErrorKey: destinationURL.path
                ]
            )
        }
    }

    private func withExclusiveRepositoryLock<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        let descriptor = repositoryLockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else {
            throw posixError(code: errno, path: repositoryLockURL.path)
        }
        defer { close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw posixError(code: errno, path: repositoryLockURL.path)
            }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func posixError(code: Int32, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
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

    private var repositoryLockURL: URL {
        rootURL.appendingPathComponent(".repository.lock")
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
