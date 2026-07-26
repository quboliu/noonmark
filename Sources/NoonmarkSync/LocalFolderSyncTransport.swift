import CryptoKit
import Darwin
import Foundation

enum LocalFolderSyncPublicationPoint: Equatable {
    case willPublishBatch
    case didPublishBatch
}

public actor LocalFolderSyncTransport: SyncRecordTransport {
    private struct StoredRecordFile {
        var url: URL
        var data: Data
        var record: SyncRecord
    }

    private struct RepositoryCommit: Codable {
        var id: UUID
        var parentIDs: [UUID]
        var records: [SyncRecord]
        var publishedRecords: [SyncRecord]
        var snapshot: SyncRepositorySnapshot
    }

    private struct StoredRepositoryState {
        var commits: [RepositoryCommit]
        var headIDs: [UUID]
        var recordFiles: [StoredRecordFile]
    }

    private struct AppliedRecordBatch {
        var currentRecords: [SyncRecord]
        var publishedRecords: [SyncRecord]
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let currentRecordMerger: CurrentSyncRecordMerger
    private let publicationFault: @Sendable (
        LocalFolderSyncPublicationPoint
    ) throws -> Void

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        currentRecordMerger = CurrentSyncRecordMerger()
        publicationFault = { _ in }
    }

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        publicationFault: @escaping @Sendable (
            LocalFolderSyncPublicationPoint
        ) throws -> Void
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        currentRecordMerger = CurrentSyncRecordMerger()
        self.publicationFault = publicationFault
    }

    public func push(_ records: [SyncRecord]) async throws {
        try prepareRepository()
        guard records.isEmpty == false else { return }

        try withExclusiveRepositoryLock {
            let repositoryState = try storedRepositoryState()
            let storedFiles = repositoryState.recordFiles
                + (try externalConflictRecordFiles())
            let mirrorFiles = try recordMirrorFiles()
            let existingRecords = try canonicalRecords(from: storedFiles)
            try ImmutableSyncRecordCASPreflight.validate(
                existing: [],
                incoming: (storedFiles + mirrorFiles).map {
                    ImmutableSyncRecordCASCandidate(
                        record: $0.record,
                        exactData: $0.data
                    )
                } + records.map {
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

            let applied = try applying(
                batch.records,
                to: existingRecords,
                context: batch.mergeContext
            )
            guard applied.publishedRecords.isEmpty == false else {
                try repairDerivedArtifacts(
                    currentRecords: existingRecords,
                    commits: repositoryState.commits
                )
                return
            }
            let deviceID = records.first?.modifiedByDeviceID
                ?? SyncDeviceID("unknown")
            let snapshot = try SyncRepositorySnapshotBuilder().snapshot(
                records: applied.publishedRecords,
                deviceID: deviceID
            )
            let commit = repositoryCommit(
                records: applied.currentRecords,
                publishedRecords: applied.publishedRecords,
                snapshot: snapshot,
                parentIDs: repositoryState.headIDs
            )
            try publishBatch(commit)
            try repairDerivedArtifacts(
                currentRecords: applied.currentRecords,
                commits: repositoryState.commits + [commit]
            )
        }
    }

    public func fetchAll() async throws -> [SyncRecord] {
        try prepareRepository()
        return try withExclusiveRepositoryLock {
            try storedRecords()
        }
    }

    private func storedRecords() throws -> [SyncRecord] {
        let repositoryState = try storedRepositoryState()
        return try canonicalRecords(
            from: repositoryState.recordFiles
                + externalConflictRecordFiles()
        )
    }

    private func storedRepositoryState() throws -> StoredRepositoryState {
        guard fileManager.fileExists(atPath: batchesURL.path) else {
            return StoredRepositoryState(
                commits: [],
                headIDs: [],
                recordFiles: []
            )
        }
        let commits = try fileManager.contentsOfDirectory(
            at: batchesURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .map { url -> (URL, RepositoryCommit) in
            (
                url,
                try decoder.decode(
                    RepositoryCommit.self,
                    from: Data(contentsOf: url)
                )
            )
        }
        let commitIDs = Set(commits.map { $0.1.id })
        guard commitIDs.count == commits.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let parentIDs = Set(commits.flatMap { $0.1.parentIDs })
        let heads = commits.filter {
            parentIDs.contains($0.1.id) == false
        }
        guard commits.isEmpty || heads.isEmpty == false else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let recordFiles = try heads.flatMap {
            url,
            commit -> [StoredRecordFile] in
            try commit.records.map {
                StoredRecordFile(
                    url: url,
                    data: try encoder.encode($0),
                    record: $0
                )
            }
        }
        return StoredRepositoryState(
            commits: commits.map(\.1).sorted {
                $0.id.uuidString < $1.id.uuidString
            },
            headIDs: heads.map { $0.1.id }.sorted {
                $0.uuidString < $1.uuidString
            },
            recordFiles: recordFiles
        )
    }

    private func repositoryCommit(
        records: [SyncRecord],
        publishedRecords: [SyncRecord],
        snapshot: SyncRepositorySnapshot,
        parentIDs: [UUID]
    ) -> RepositoryCommit {
        RepositoryCommit(
            id: UUID(),
            parentIDs: parentIDs.sorted {
                $0.uuidString < $1.uuidString
            },
            records: sortedRecords(records),
            publishedRecords: sortedRecords(publishedRecords),
            snapshot: snapshot
        )
    }

    private func sortedRecords(_ records: [SyncRecord]) -> [SyncRecord] {
        records.sorted {
            if $0.entityType.rawValue != $1.entityType.rawValue {
                return $0.entityType.rawValue < $1.entityType.rawValue
            }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    private func recordMirrorFiles() throws -> [StoredRecordFile] {
        guard fileManager.fileExists(atPath: recordsURL.path) else {
            return []
        }
        return try fileManager.contentsOfDirectory(
            at: recordsURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .map {
            let data = try Data(contentsOf: $0)
            return StoredRecordFile(
                url: $0,
                data: data,
                record: try decoder.decode(SyncRecord.self, from: data)
            )
        }
    }

    private func externalConflictRecordFiles() throws -> [StoredRecordFile] {
        try recordMirrorFiles().filter {
            isManagedRecordFileName($0) == false
        }
    }

    private func canonicalRecords(
        from storedFiles: [StoredRecordFile]
    ) throws -> [SyncRecord] {
        let grouped = Dictionary(grouping: storedFiles, by: { $0.record.id })
        for (recordID, candidates) in grouped where candidates.count > 1 {
            guard let first = candidates.first else { continue }
            let requiresImmutableCAS = candidates.contains {
                $0.record.entityType.requiresImmutableRecordPayload
            }
            if requiresImmutableCAS {
                guard candidates.dropFirst().allSatisfy({ candidate in
                    candidate.record.exactlyMatches(first.record)
                        && candidate.data == first.data
                }) else {
                    throw SyncRecordTransportError.immutableRecordCollision(
                        recordID: recordID
                    )
                }
            }
        }

        let batch = try currentRecordMerger.prepareTransportBatch(
            existingRecords: [],
            incomingRecords: storedFiles.map(\.record)
        )
        var canonicalByID: [SyncRecordID: SyncRecord] = [:]
        for record in batch.records {
            guard let existing = canonicalByID[record.id] else {
                canonicalByID[record.id] = record
                continue
            }
            let requiresImmutableCAS = existing.entityType.requiresImmutableRecordPayload
                || record.entityType.requiresImmutableRecordPayload
            if requiresImmutableCAS {
                continue
            }
            do {
                canonicalByID[record.id] = try currentRecordMerger.merge(
                    existing: existing,
                    incoming: record,
                    context: batch.mergeContext
                )
            } catch {
                throw SyncRecordTransportError.invalidCurrentRecordMerge(
                    recordID: record.id
                )
            }
        }

        return canonicalByID.values.sorted {
            if $0.entityType.rawValue != $1.entityType.rawValue {
                return $0.entityType.rawValue < $1.entityType.rawValue
            }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    private func applying(
        _ records: [SyncRecord],
        to existingRecords: [SyncRecord],
        context: CurrentSyncRecordMergeContext
    ) throws -> AppliedRecordBatch {
        var currentByID = Dictionary(
            uniqueKeysWithValues: existingRecords.map { ($0.id, $0) }
        )
        var published: [SyncRecord] = []
        for record in records {
            guard let existing = currentByID[record.id] else {
                currentByID[record.id] = record
                published.append(record)
                continue
            }
            if existing.entityType.requiresImmutableRecordPayload
                || record.entityType.requiresImmutableRecordPayload
            {
                continue
            }
            let merged: SyncRecord
            do {
                merged = try currentRecordMerger.merge(
                    existing: existing,
                    incoming: record,
                    context: context
                )
            } catch {
                throw SyncRecordTransportError.invalidCurrentRecordMerge(
                    recordID: record.id
                )
            }
            guard merged.exactlyMatches(existing) == false else {
                continue
            }
            currentByID[record.id] = merged
            published.append(merged)
        }
        return AppliedRecordBatch(
            currentRecords: currentByID.values.sorted {
                if $0.entityType.rawValue != $1.entityType.rawValue {
                    return $0.entityType.rawValue
                        < $1.entityType.rawValue
                }
                return $0.id.rawValue < $1.id.rawValue
            },
            publishedRecords: published
        )
    }

    private func publishBatch(_ commit: RepositoryCommit) throws {
        try publicationFault(.willPublishBatch)
        let batchURL = batchesURL
            .appendingPathComponent(commit.id.uuidString)
            .appendingPathExtension("json")
        try encoder.encode(commit).write(
            to: batchURL,
            options: [.atomic]
        )
        try publicationFault(.didPublishBatch)
    }

    private func repairDerivedArtifacts(
        currentRecords: [SyncRecord],
        commits: [RepositoryCommit]
    ) throws {
        for record in currentRecords {
            try encoder.encode(record).write(
                to: recordURL(for: record.id),
                options: [.atomic]
            )
        }

        let orderedSnapshots = commits.map(\.snapshot).sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id < $1.id
        }
        for snapshot in orderedSnapshots {
            let data = try encoder.encode(snapshot)
            try data.write(
                to: snapshotURL(for: snapshot.id),
                options: [.atomic]
            )
        }
        if let latestSnapshot = orderedSnapshots.last {
            try latestSnapshot.id.write(
                to: latestRefURL,
                atomically: true,
                encoding: .utf8
            )
        }
    }

    public func fetchSnapshots() async throws -> [SyncRepositorySnapshot] {
        try prepareRepository()
        return try withExclusiveRepositoryLock {
            guard fileManager.fileExists(atPath: indexesURL.path)
            else {
                return []
            }
            return try fileManager.contentsOfDirectory(
                at: indexesURL,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
            .map {
                try decoder.decode(
                    SyncRepositorySnapshot.self,
                    from: Data(contentsOf: $0)
                )
            }
            .sorted { $0.createdAt < $1.createdAt }
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
        try fileManager.createDirectory(at: batchesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: indexesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: refsURL, withIntermediateDirectories: true)
    }

    private var batchesURL: URL {
        rootURL.appendingPathComponent("batches", isDirectory: true)
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

    private func isManagedRecordFileName(
        _ file: StoredRecordFile
    ) -> Bool {
        let stem = file.url.deletingPathExtension().lastPathComponent
        return stem.count == 64
            && stem.allSatisfy {
                $0.isNumber || ("a" ... "f").contains($0)
            }
    }
}
