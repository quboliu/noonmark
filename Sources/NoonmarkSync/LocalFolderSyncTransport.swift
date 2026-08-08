import CryptoKit
import Darwin
import Foundation
import NoonmarkDiagnostics

enum LocalFolderSyncPublicationPoint: Equatable {
    case willPublishBatch
    case didPublishBatch
    case willPublishHead
    case didPublishHead
}

/// Append-only incremental repository used by Local Folder and iCloud Drive.
///
/// Each installation owns one producer epoch and therefore one immutable hash
/// chain. Producers never update each other's files. A reader enumerates only
/// `heads/`, then opens the exact sequences after its durable frontier.
public actor LocalFolderSyncTransport: SyncRecordTransport {
    public nonisolated static let formatVersion = 1

    private struct RepositoryBatch: Codable {
        let formatVersion: Int
        let epochID: String
        let sequence: UInt64
        let previousHash: String?
        let records: [SyncRecord]
        /// Hash of the canonical semantic body. The exact-file hash remains
        /// the chain link and receipt; this body hash lets a paged reader
        /// reject corruption before applying a non-tip batch.
        let bodyHash: String
    }

    private struct RepositoryBatchBody: Codable {
        let formatVersion: Int
        let epochID: String
        let sequence: UInt64
        let previousHash: String?
        let records: [SyncRecord]
    }

    private struct RepositoryHead: Codable {
        let tipSequence: UInt64
        let tipHash: String
    }

    private struct ObservedHead {
        let epochID: String
        let value: RepositoryHead
    }

    public nonisolated let rootURL: URL
    public nonisolated let producerEpochID: UUID
    public nonisolated let frontierNamespace: String

    public nonisolated static func frontierNamespace(
        for rootURL: URL
    ) -> String {
        "folder-" + sha256Hex(
            Data(rootURL.standardizedFileURL.path.utf8)
        )
    }

    private let fileManager: FileManager
    private let diagnosticOperation: DiagnosticOperation?
    private let publicationFault: @Sendable (
        LocalFolderSyncPublicationPoint
    ) throws -> Void
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        rootURL: URL,
        producerEpochID: UUID = UUID(),
        fileManager: FileManager = .default,
        diagnosticOperation: DiagnosticOperation? = nil
    ) {
        self.rootURL = rootURL
        self.producerEpochID = producerEpochID
        frontierNamespace = Self.frontierNamespace(for: rootURL)
        self.fileManager = fileManager
        self.diagnosticOperation = diagnosticOperation
        publicationFault = { _ in }
        (encoder, decoder) = Self.canonicalCodecs()
    }

    init(
        rootURL: URL,
        producerEpochID: UUID = UUID(),
        fileManager: FileManager = .default,
        diagnosticOperation: DiagnosticOperation? = nil,
        publicationFault: @escaping @Sendable (
            LocalFolderSyncPublicationPoint
        ) throws -> Void
    ) {
        self.rootURL = rootURL
        self.producerEpochID = producerEpochID
        frontierNamespace = Self.frontierNamespace(for: rootURL)
        self.fileManager = fileManager
        self.diagnosticOperation = diagnosticOperation
        self.publicationFault = publicationFault
        (encoder, decoder) = Self.canonicalCodecs()
    }

    public func pushAccepting(
        _ records: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt {
        let startedAt = ProcessInfo.processInfo.systemUptime
        try prepareRepositoryForWriting()
        guard records.isEmpty == false else {
            return SyncTransportPushReceipt(
                batches: [],
                confirmation: .confirmed
            )
        }
        let producerID = producerEpochID.uuidString.lowercased()
        return try withExclusiveRepositoryLock {
            let previousHead = try readHead(epochID: producerID)
            let orderedRecords = sortedRecords(records)
            if let previousHead {
                let previousBatchData = try Data(
                    contentsOf: batchURL(
                        epochID: producerID,
                        sequence: previousHead.tipSequence
                    )
                )
                let previousBatch = try decodeBatch(
                    previousBatchData,
                    producerID: producerID,
                    sequence: previousHead.tipSequence
                )
                try validate(
                    batch: previousBatch,
                    hash: Self.sha256Hex(previousBatchData),
                    expectedEpochID: producerID,
                    expectedSequence: previousHead.tipSequence,
                    expectedPreviousHash: previousBatch.previousHash,
                    head: previousHead
                )
                if previousBatch.records == orderedRecords {
                    return pushReceipt(
                        producerID: producerID,
                        sequence: previousHead.tipSequence,
                        batchHash: previousHead.tipHash
                    )
                }
            }
            let sequence = try nextSequence(after: previousHead)
            let body = RepositoryBatchBody(
                formatVersion: Self.formatVersion,
                epochID: producerID,
                sequence: sequence,
                previousHash: previousHead?.tipHash,
                records: orderedRecords
            )
            let batch = RepositoryBatch(
                formatVersion: body.formatVersion,
                epochID: body.epochID,
                sequence: body.sequence,
                previousHash: body.previousHash,
                records: body.records,
                bodyHash: Self.sha256Hex(try encoder.encode(body))
            )
            let batchData = try encoder.encode(batch)
            let batchHash = Self.sha256Hex(batchData)
            let batchURL = self.batchURL(
                epochID: producerID,
                sequence: sequence
            )
            let headURL = self.headURL(epochID: producerID)

            try publicationFault(.willPublishBatch)
            try publishImmutable(data: batchData, to: batchURL)
            try publicationFault(.didPublishBatch)

            try publicationFault(.willPublishHead)
            try publishHead(
                RepositoryHead(
                    tipSequence: sequence,
                    tipHash: batchHash
                ),
                to: headURL
            )
            try publicationFault(.didPublishHead)

            diagnosticOperation?.stage(
                .upload,
                progress: DiagnosticProgress(
                    recordCount: records.count,
                    fileCount: 2,
                    byteCount: Int64(batchData.count)
                ),
                durationMilliseconds: Self.durationMilliseconds(
                    since: startedAt
                )
            )
            return pushReceipt(
                producerID: producerID,
                sequence: sequence,
                batchHash: batchHash
            )
        }
    }

    private func pushReceipt(
        producerID: String,
        sequence: UInt64,
        batchHash: String
    ) -> SyncTransportPushReceipt {
        SyncTransportPushReceipt(
            batches: [
                SyncTransportBatchReference(
                    producerID: producerID,
                    sequence: sequence,
                    contentHash: batchHash,
                    artifactPaths: [
                        relativeBatchPath(
                            epochID: producerID,
                            sequence: sequence
                        ),
                        relativeHeadPath(epochID: producerID)
                    ]
                )
            ],
            confirmation: .confirmed
        )
    }

    public func pull(
        after frontier: SyncTransportFrontier,
        limit: Int
    ) async throws -> SyncTransportChangePage {
        let startedAt = ProcessInfo.processInfo.systemUptime
        try prepareRepositoryForReading()
        let heads = try observedHeads()
        try validate(frontier: frontier, against: heads)

        let pageLimit = max(limit, 1)
        var nextFrontier = frontier
        var records: [SyncRecord] = []
        var references: [SyncTransportBatchReference] = []
        var byteCount: Int64 = 0
        var openedBatchCount = 0

        producerLoop: for head in heads {
            var position = frontier.position(for: head.epochID)
            var sequence = position?.sequence ?? 0
            var previousHash = position?.contentHash
            while sequence < head.value.tipSequence {
                let nextSequence = sequence + 1
                let url = batchURL(
                    epochID: head.epochID,
                    sequence: nextSequence
                )
                guard fileManager.fileExists(atPath: url.path) else {
                    throw SyncRecordTransportError.missingBatch(
                        producerID: head.epochID,
                        sequence: nextSequence
                    )
                }
                let data = try Data(contentsOf: url)
                openedBatchCount += 1
                let (nextByteCount, overflow) = byteCount
                    .addingReportingOverflow(Int64(data.count))
                byteCount = overflow ? Int64.max : nextByteCount
                let decoded = try decodeBatch(
                    data,
                    producerID: head.epochID,
                    sequence: nextSequence
                )
                let hash = Self.sha256Hex(data)
                try validate(
                    batch: decoded,
                    hash: hash,
                    expectedEpochID: head.epochID,
                    expectedSequence: nextSequence,
                    expectedPreviousHash: previousHash,
                    head: head.value
                )
                if records.isEmpty == false,
                   records.count + decoded.records.count > pageLimit
                {
                    break producerLoop
                }
                records.append(contentsOf: decoded.records)
                references.append(
                    SyncTransportBatchReference(
                        producerID: head.epochID,
                        sequence: nextSequence,
                        contentHash: hash,
                        artifactPaths: [
                            relativeBatchPath(
                                epochID: head.epochID,
                                sequence: nextSequence
                            )
                        ]
                    )
                )
                let advancedPosition = SyncTransportPosition(
                    sequence: nextSequence,
                    contentHash: hash
                )
                nextFrontier = nextFrontier.advancing(
                    producerID: head.epochID,
                    to: advancedPosition
                )
                position = advancedPosition
                sequence = nextSequence
                previousHash = hash
                if records.count >= pageLimit {
                    if nextSequence < head.value.tipSequence {
                        let successorURL = batchURL(
                            epochID: head.epochID,
                            sequence: nextSequence + 1
                        )
                        guard fileManager.fileExists(atPath: successorURL.path) else {
                            throw SyncRecordTransportError.missingBatch(
                                producerID: head.epochID,
                                sequence: nextSequence + 1
                            )
                        }
                        let successorData = try Data(contentsOf: successorURL)
                        openedBatchCount += 1
                        let successor = try decodeBatch(
                            successorData,
                            producerID: head.epochID,
                            sequence: nextSequence + 1
                        )
                        guard successor.previousHash == hash else {
                            throw SyncRecordTransportError.invalidBatchHash(
                                producerID: head.epochID,
                                sequence: nextSequence
                            )
                        }
                        let (nextByteCount, overflow) = byteCount
                            .addingReportingOverflow(Int64(successorData.count))
                        byteCount = overflow ? Int64.max : nextByteCount
                    }
                    break producerLoop
                }
            }
        }

        let hasMore = heads.contains { head in
            (nextFrontier.position(for: head.epochID)?.sequence ?? 0)
                < head.value.tipSequence
        }
        diagnosticOperation?.stage(
            .transportFetch,
            progress: DiagnosticProgress(
                recordCount: records.count,
                fileCount: heads.count + references.count,
                byteCount: byteCount
            ),
            durationMilliseconds: Self.durationMilliseconds(
                since: startedAt
            )
        )
        return SyncTransportChangePage(
            records: records,
            frontier: nextFrontier,
            hasMore: hasMore,
            batches: references,
            observedProducerCount: heads.count,
            openedBatchCount: openedBatchCount,
            openedByteCount: byteCount
        )
    }

    /// Test and migration evidence helper. It is intentionally implemented in
    /// terms of the incremental protocol and is not used by the coordinator.
    public func fetchSnapshots() async throws -> [SyncRepositorySnapshot] {
        var frontier = SyncTransportFrontier.origin
        var snapshots: [SyncRepositorySnapshot] = []
        // `prepareTransportBatch` canonicalizes its incoming evidence, but its
        // result intentionally does not include an older persisted winner.
        // Snapshot evidence must instead fold every immutable record observed
        // so far; producer traversal order is not a causal order.
        var observedRecords: [SyncRecord] = []
        while true {
            let page = try await pull(after: frontier, limit: 512)
            for reference in page.batches {
                let url = batchURL(
                    epochID: reference.producerID,
                    sequence: reference.sequence
                )
                let batch = try decodeBatch(
                    Data(contentsOf: url),
                    producerID: reference.producerID,
                    sequence: reference.sequence
                )
                let deviceID = batch.records.first?.modifiedByDeviceID
                    ?? SyncDeviceID("unknown")
                observedRecords.append(contentsOf: batch.records)
                let currentRecords = try CurrentSyncRecordMerger()
                    .prepareTransportBatch(
                        existingRecords: [],
                        incomingRecords: observedRecords
                    ).records
                snapshots.append(
                    try SyncRepositorySnapshotBuilder().snapshot(
                        records: currentRecords,
                        deviceID: deviceID
                    )
                )
            }
            guard page.hasMore else { return snapshots }
            guard page.frontier != frontier else {
                throw SyncRecordTransportError.frontierDidNotAdvance
            }
            frontier = page.frontier
        }
    }

    private func prepareRepositoryForReading() throws {
        for legacyName in ["records", "indexes", "refs"] {
            if fileManager.fileExists(
                atPath: rootURL.appendingPathComponent(legacyName).path
            ) {
                throw SyncRecordTransportError.repositoryFormatMismatch
            }
        }
        try fileManager.createDirectory(
            at: headsURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: batchesURL,
            withIntermediateDirectories: true
        )
    }

    private func prepareRepositoryForWriting() throws {
        try prepareRepositoryForReading()
        try fileManager.createDirectory(
            at: producerBatchesURL(
                epochID: producerEpochID.uuidString.lowercased()
            ),
            withIntermediateDirectories: true
        )
    }

    private func observedHeads() throws -> [ObservedHead] {
        try fileManager.contentsOfDirectory(
            at: headsURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .map { url in
            let epochID = url.deletingPathExtension().lastPathComponent
            guard let uuid = UUID(uuidString: epochID),
                  uuid.uuidString.lowercased() == epochID
            else {
                throw SyncRecordTransportError.repositoryFormatMismatch
            }
            let head = try decodeHead(Data(contentsOf: url))
            guard head.tipSequence > 0,
                  Self.isSHA256Hex(head.tipHash)
            else {
                throw SyncRecordTransportError.repositoryFormatMismatch
            }
            return ObservedHead(epochID: epochID, value: head)
        }
        .sorted { $0.epochID < $1.epochID }
    }

    private func validate(
        frontier: SyncTransportFrontier,
        against heads: [ObservedHead]
    ) throws {
        let headsByEpoch = Dictionary(
            uniqueKeysWithValues: heads.map { ($0.epochID, $0.value) }
        )
        for (producerID, position) in frontier.positions {
            guard let head = headsByEpoch[producerID],
                  position.sequence > 0,
                  position.sequence <= head.tipSequence,
                  Self.isSHA256Hex(position.contentHash)
            else {
                throw SyncRecordTransportError.invalidFrontier
            }
            if position.sequence == head.tipSequence,
               position.contentHash != head.tipHash
            {
                throw SyncRecordTransportError.producerFork(
                    producerID: producerID,
                    sequence: position.sequence
                )
            }
        }
    }

    private func validate(
        batch: RepositoryBatch,
        hash: String,
        expectedEpochID: String,
        expectedSequence: UInt64,
        expectedPreviousHash: String?,
        head: RepositoryHead
    ) throws {
        let previousHashShapeIsValid = if expectedSequence == 1 {
            batch.previousHash == nil
        } else if let previousHash = batch.previousHash {
            Self.isSHA256Hex(previousHash)
        } else {
            false
        }
        guard batch.formatVersion == Self.formatVersion,
              batch.epochID == expectedEpochID,
              batch.sequence == expectedSequence,
              batch.records.isEmpty == false,
              batch.previousHash == expectedPreviousHash,
              previousHashShapeIsValid
        else {
            throw SyncRecordTransportError.producerFork(
                producerID: expectedEpochID,
                sequence: expectedSequence
            )
        }
        let body = RepositoryBatchBody(
            formatVersion: batch.formatVersion,
            epochID: batch.epochID,
            sequence: batch.sequence,
            previousHash: batch.previousHash,
            records: batch.records
        )
        guard Self.isSHA256Hex(batch.bodyHash),
              Self.sha256Hex(try encoder.encode(body)) == batch.bodyHash
        else {
            throw SyncRecordTransportError.invalidBatchHash(
                producerID: expectedEpochID,
                sequence: expectedSequence
            )
        }
        guard expectedSequence != head.tipSequence
                || hash == head.tipHash
        else {
            throw SyncRecordTransportError.invalidBatchHash(
                producerID: expectedEpochID,
                sequence: expectedSequence
            )
        }
    }

    private func readHead(epochID: String) throws -> RepositoryHead? {
        let url = headURL(epochID: epochID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let head = try decodeHead(Data(contentsOf: url))
        guard head.tipSequence > 0,
              Self.isSHA256Hex(head.tipHash)
        else {
            throw SyncRecordTransportError.repositoryFormatMismatch
        }
        let tipURL = batchURL(
            epochID: epochID,
            sequence: head.tipSequence
        )
        guard fileManager.fileExists(atPath: tipURL.path) else {
            throw SyncRecordTransportError.missingBatch(
                producerID: epochID,
                sequence: head.tipSequence
            )
        }
        let data = try Data(contentsOf: tipURL)
        guard Self.sha256Hex(data) == head.tipHash else {
            throw SyncRecordTransportError.invalidBatchHash(
                producerID: epochID,
                sequence: head.tipSequence
            )
        }
        return head
    }

    private func nextSequence(
        after head: RepositoryHead?
    ) throws -> UInt64 {
        guard let head else { return 1 }
        let (next, overflow) = head.tipSequence.addingReportingOverflow(1)
        guard overflow == false else {
            throw SyncRecordTransportError.repositoryFormatMismatch
        }
        return next
    }

    private func decodeBatch(
        _ data: Data,
        producerID: String,
        sequence: UInt64
    ) throws -> RepositoryBatch {
        do {
            return try decoder.decode(RepositoryBatch.self, from: data)
        } catch let error as SyncRecordTransportError {
            throw error
        } catch {
            throw SyncRecordTransportError.invalidBatchHash(
                producerID: producerID,
                sequence: sequence
            )
        }
    }

    private func decodeHead(_ data: Data) throws -> RepositoryHead {
        do {
            return try decoder.decode(RepositoryHead.self, from: data)
        } catch let error as SyncRecordTransportError {
            throw error
        } catch {
            throw SyncRecordTransportError.repositoryFormatMismatch
        }
    }

    private func publishImmutable(data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: [.withoutOverwriting])
            try synchronizeFile(at: url)
            try synchronizeDirectory(at: url.deletingLastPathComponent())
        } catch let error as CocoaError
            where error.code == .fileWriteFileExists
        {
            guard try Data(contentsOf: url) == data else {
                let producerID = url.deletingLastPathComponent()
                    .lastPathComponent
                let sequence = UInt64(
                    url.deletingPathExtension().lastPathComponent
                ) ?? 0
                throw SyncRecordTransportError.producerFork(
                    producerID: producerID,
                    sequence: sequence
                )
            }
        }
    }

    private func publishHead(
        _ head: RepositoryHead,
        to destination: URL
    ) throws {
        let data = try encoder.encode(head)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
            )
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.withoutOverwriting])
        try synchronizeFile(at: temporary)
        let renameResult: Int32 = temporary.withUnsafeFileSystemRepresentation {
            sourcePath in
            destination.withUnsafeFileSystemRepresentation {
                destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw posixError(code: errno)
        }
        try synchronizeDirectory(at: destination.deletingLastPathComponent())
    }

    private func synchronizeFile(at url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else { throw posixError(code: errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(code: errno) }
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else { throw posixError(code: errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(code: errno) }
    }

    private func withExclusiveRepositoryLock<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        let descriptor = repositoryLockURL
            .withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return open(
                    path,
                    O_CREAT | O_RDWR,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
        guard descriptor >= 0 else { throw posixError(code: errno) }
        defer { close(descriptor) }

        let waitStartedAt = ProcessInfo.processInfo.systemUptime
        diagnosticOperation?.stage(.transportLockWait)
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw posixError(code: errno) }
        }
        diagnosticOperation?.stage(
            .transportLockAcquired,
            durationMilliseconds: Self.durationMilliseconds(
                since: waitStartedAt
            )
        )
        defer {
            _ = flock(descriptor, LOCK_UN)
            diagnosticOperation?.stage(.transportLockReleased)
        }
        return try operation()
    }

    private static func canonicalCodecs() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(
                date.timeIntervalSinceReferenceDate.bitPattern
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let bits = try container.decode(UInt64.self)
            let seconds = Double(bitPattern: bits)
            guard seconds.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "non-finite canonical date"
                )
            }
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return (encoder, decoder)
    }

    private func sortedRecords(_ records: [SyncRecord]) -> [SyncRecord] {
        records.sorted {
            let left = SyncRecordEvidenceID(record: $0).rawValue
            let right = SyncRecordEvidenceID(record: $1).rawValue
            return left < right
        }
    }

    private nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private nonisolated static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private nonisolated static func durationMilliseconds(
        since startedAt: TimeInterval
    ) -> Int64 {
        let duration = max(
            0,
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        )
        guard duration < Double(Int64.max) else { return Int64.max }
        return Int64(duration.rounded())
    }

    private func posixError(code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private var headsURL: URL {
        rootURL.appendingPathComponent("heads", isDirectory: true)
    }

    private var batchesURL: URL {
        rootURL.appendingPathComponent("batches", isDirectory: true)
    }

    private func producerBatchesURL(epochID: String) -> URL {
        batchesURL.appendingPathComponent(epochID, isDirectory: true)
    }

    private func headURL(epochID: String) -> URL {
        headsURL.appendingPathComponent(epochID)
            .appendingPathExtension("json")
    }

    private func batchURL(epochID: String, sequence: UInt64) -> URL {
        producerBatchesURL(epochID: epochID)
            .appendingPathComponent(Self.sequenceFileStem(sequence))
            .appendingPathExtension("json")
    }

    private func relativeHeadPath(epochID: String) -> String {
        "heads/\(epochID).json"
    }

    private func relativeBatchPath(
        epochID: String,
        sequence: UInt64
    ) -> String {
        "batches/\(epochID)/\(Self.sequenceFileStem(sequence)).json"
    }

    private nonisolated static func sequenceFileStem(
        _ sequence: UInt64
    ) -> String {
        String(format: "%020llu", sequence)
    }

    private var repositoryLockURL: URL {
        rootURL.appendingPathComponent(".repository.lock")
    }
}
