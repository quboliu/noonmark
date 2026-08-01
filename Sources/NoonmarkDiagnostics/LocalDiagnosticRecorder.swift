import CryptoKit
import Darwin
import Foundation

public final class LocalDiagnosticRecorder: DiagnosticRecording, @unchecked Sendable {
    public let sessionID: DiagnosticSessionID

    private struct QueuedEvidence: Sendable {
        let event: EvidenceEvent
        let timestamp: Date
        let estimatedBytes: Int
    }

    private let configuration: DiagnosticStorageConfiguration
    private let appleLogger: AppleDiagnosticLogger
    private let ioQueue = DispatchQueue(
        label: "app.noonmark.diagnostics.writer",
        qos: .utility
    )
    private let bufferLock = NSLock()
    private let diskStore: DiagnosticDiskStore
    private var buffered: [QueuedEvidence] = []
    private var bufferedBytes = 0
    private var pendingDroppedCount = 0
    private var pendingOversizedCount = 0
    private var drainScheduled = false

    public init(
        rootURL: URL,
        appIdentity: DiagnosticAppIdentity = .current,
        configuration: DiagnosticStorageConfiguration = .production,
        sessionID: DiagnosticSessionID = DiagnosticSessionID()
    ) throws {
        self.sessionID = sessionID
        self.configuration = configuration
        appleLogger = AppleDiagnosticLogger()
        diskStore = try DiagnosticDiskStore(
            rootURL: rootURL,
            appIdentity: appIdentity,
            configuration: configuration
        )
    }

    public func record(_ event: EvidenceEvent, at timestamp: Date) {
        appleLogger.record(event)
        let estimatedBytes = Self.estimatedEncodedBytes(for: event)
        var shouldSchedule = false

        bufferLock.lock()
        if estimatedBytes > configuration.maximumEventBytes {
            pendingOversizedCount += 1
        } else if buffered.count >= configuration.maximumQueuedEvents
            || bufferedBytes + estimatedBytes
            > configuration.maximumQueuedBytes
        {
            pendingDroppedCount += 1
        } else {
            buffered.append(
                QueuedEvidence(
                    event: event,
                    timestamp: timestamp,
                    estimatedBytes: estimatedBytes
                )
            )
            bufferedBytes += estimatedBytes
        }
        if drainScheduled == false {
            drainScheduled = true
            shouldSchedule = true
        }
        bufferLock.unlock()

        if shouldSchedule {
            ioQueue.async { [self] in
                drainBufferedEvidence()
            }
        }
    }

    public func startSession(at timestamp: Date = Date()) {
        ioQueue.async { [self] in
            diskStore.startSession(
                sessionID: sessionID,
                timestamp: timestamp
            )
        }
    }

    public func recordCleanShutdown(at timestamp: Date = Date()) async {
        record(.cleanShutdown(), at: timestamp)
        await flush()
    }

    func cacheMetricKitPayload(
        _ summary: MetricKitPayloadSummary,
        rawJSON: Data,
        receivedAt: Date = Date()
    ) {
        ioQueue.async { [self] in
            diskStore.storeMetricKitPayload(
                summary,
                rawJSON: rawJSON,
                receivedAt: receivedAt,
                sessionID: sessionID
            )
        }
    }

    public func flush() async {
        await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                drainBufferedEvidence()
                continuation.resume()
            }
        }
    }

    public func health() async -> DiagnosticHealth {
        await flush()
        return await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                continuation.resume(returning: diskStore.health())
            }
        }
    }

    public func preview() async throws -> DiagnosticExportPreview {
        let package = try await snapshotPackage()
        let data = try Self.exportEncoder.encode(package)
        let health = await health()
        return DiagnosticExportPreview(
            schemaVersion: package.manifest.schemaVersion,
            recordCount: package.records.count,
            operationCapsuleCount: package.operationCapsules.count,
            metricPayloadCount: package.metricAttachments.count,
            oldestRecordAt: package.manifest.oldestRecordAt,
            newestRecordAt: package.manifest.newestRecordAt,
            allocatedBytes: health.allocatedBytes,
            estimatedExportBytes: Int64(data.count)
        )
    }

    public func snapshotPackage() async throws -> DiagnosticExportPackage {
        await flush()
        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    continuation.resume(
                        returning: try diskStore.snapshotPackage()
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func export(to destinationURL: URL) async throws
        -> DiagnosticExportReceipt
    {
        let package = try await snapshotPackage()
        let data = try Self.exportEncoder.encode(package)
        guard data.count <= 8 * 1_024 * 1_024 else {
            throw DiagnosticStorageError.exportTooLarge
        }
        let parentURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: destinationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        return DiagnosticExportReceipt(
            byteCount: data.count,
            sha256: digest,
            recordCount: package.records.count,
            generatedAt: package.manifest.generatedAt
        )
    }

    public func clear() async throws {
        await flush()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            ioQueue.async { [self] in
                do {
                    try diskStore.clear()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func drainBufferedEvidence() {
        while true {
            let batch: [QueuedEvidence]
            let droppedCount: Int
            let oversizedCount: Int

            bufferLock.lock()
            guard buffered.isEmpty == false
                || pendingDroppedCount > 0
                || pendingOversizedCount > 0
            else {
                drainScheduled = false
                bufferLock.unlock()
                return
            }
            batch = buffered
            droppedCount = pendingDroppedCount
            oversizedCount = pendingOversizedCount
            buffered = []
            bufferedBytes = 0
            pendingDroppedCount = 0
            pendingOversizedCount = 0
            bufferLock.unlock()

            diskStore.persist(
                batch.map { ($0.event, $0.timestamp) },
                sessionID: sessionID,
                droppedCount: droppedCount,
                oversizedCount: oversizedCount
            )
        }
    }

    private static func estimatedEncodedBytes(for event: EvidenceEvent) -> Int {
        ((try? JSONEncoder().encode(event).count) ?? Int.max) + 256
    }

    private static let exportEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

public enum DiagnosticStorageError: Error, Equatable, Sendable {
    case invalidRoot
    case exportTooLarge
    case allocatedSizeUnavailable
}

private final class DiagnosticDiskStore {
    private struct PersistentState: Codable {
        var schemaVersion = RecordedEvidence.currentSchemaVersion
        var currentSegment = 0
        var nextSequence: UInt64 = 1
        var segmentPayloadBytes: [Int64]
        var segmentRecordCounts: [Int]
        var segmentFirstSequences: [UInt64]
        var droppedRecordCount = 0
        var corruptRecordCount = 0
        var oversizedEventCount = 0
        var oversizedMetricPayloadCount = 0
        var fileSinkDisabled = false

        init(segmentCount: Int) {
            segmentPayloadBytes = Array(repeating: 0, count: segmentCount)
            segmentRecordCounts = Array(repeating: 0, count: segmentCount)
            segmentFirstSequences = Array(repeating: 0, count: segmentCount)
        }
    }

    private struct StoredMetricPayload: Codable {
        let receivedAt: Date
        let summary: MetricKitPayloadSummary
        let rawJSON: Data?
    }

    private let rootURL: URL
    private let appIdentity: DiagnosticAppIdentity
    private let configuration: DiagnosticStorageConfiguration
    private let fileManager: FileManager
    private var state: PersistentState
    private var activeOperations: [DiagnosticActiveOperation]
    private var operationCapsules: [DiagnosticOperationCapsule]

    init(
        rootURL: URL,
        appIdentity: DiagnosticAppIdentity,
        configuration: DiagnosticStorageConfiguration,
        fileManager: FileManager = .default
    ) throws {
        guard rootURL.isFileURL,
              rootURL.standardizedFileURL.path != "/"
        else {
            throw DiagnosticStorageError.invalidRoot
        }
        self.rootURL = rootURL.standardizedFileURL
        self.appIdentity = appIdentity
        self.configuration = configuration
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: self.rootURL.path
        )
        state = Self.loadJSON(
            PersistentState.self,
            from: self.rootURL.appendingPathComponent("index.json"),
            fileManager: fileManager
        ) ?? PersistentState(segmentCount: configuration.eventSegmentCount)
        state = Self.normalized(
            state,
            segmentCount: configuration.eventSegmentCount
        )
        activeOperations = Self.loadJSON(
            [DiagnosticActiveOperation].self,
            from: self.rootURL.appendingPathComponent(
                "active-operations.json"
            ),
            fileManager: fileManager
        ) ?? []
        operationCapsules = Self.loadJSON(
            [DiagnosticOperationCapsule].self,
            from: self.rootURL.appendingPathComponent(
                "operation-capsules.json"
            ),
            fileManager: fileManager
        ) ?? []
        try rebuildStateFromSegments()
        try pruneExpiredRecords(now: Date())
        try saveMetadata()
        try enforcePersistentCap()
    }

    func startSession(sessionID: DiagnosticSessionID, timestamp: Date) {
        do {
            let interrupted = activeOperations
            activeOperations = []
            for operation in interrupted {
                operationCapsules.append(
                    DiagnosticOperationCapsule(
                        operationID: operation.id,
                        incidentID: nil,
                        kind: operation.kind,
                        endpoint: operation.endpoint,
                        startedAt: operation.startedAt,
                        finishedAt: timestamp,
                        lastStage: operation.lastStage,
                        lastProgress: operation.lastProgress,
                        outcome: .interrupted,
                        failure: nil
                    )
                )
                try persistOne(
                    .previousSessionInterrupted(operation: operation),
                    timestamp: timestamp,
                    sessionID: sessionID
                )
            }
            trimCapsules()
            try persistOne(
                .sessionStarted(),
                timestamp: timestamp,
                sessionID: sessionID
            )
            try saveMetadata()
            try enforcePersistentCap()
        } catch {
            state.fileSinkDisabled = true
        }
    }

    func persist(
        _ events: [(EvidenceEvent, Date)],
        sessionID: DiagnosticSessionID,
        droppedCount: Int,
        oversizedCount: Int
    ) {
        do {
            state.droppedRecordCount += droppedCount
            state.oversizedEventCount += oversizedCount
            if droppedCount > 0 {
                try persistOne(
                    .recordsDropped(count: droppedCount),
                    timestamp: Date(),
                    sessionID: sessionID
                )
            }
            if oversizedCount > 0 {
                try persistOne(
                    .oversizedEventDropped(byteCount: Int64(oversizedCount)),
                    timestamp: Date(),
                    sessionID: sessionID
                )
            }
            for (event, timestamp) in events {
                try persistOne(
                    event,
                    timestamp: timestamp,
                    sessionID: sessionID
                )
            }
            try pruneExpiredRecords(now: Date())
            try saveMetadata()
            try enforcePersistentCap()
        } catch {
            state.fileSinkDisabled = true
        }
    }

    func storeMetricKitPayload(
        _ summary: MetricKitPayloadSummary,
        rawJSON: Data,
        receivedAt: Date,
        sessionID: DiagnosticSessionID
    ) {
        do {
            let rawJSONWasDropped = rawJSON.count
                > configuration.maximumMetricPayloadBytes
            if rawJSONWasDropped {
                state.oversizedMetricPayloadCount += 1
                try persistOne(
                    .oversizedMetricPayloadDropped(
                        byteCount: Int64(rawJSON.count)
                    ),
                    timestamp: receivedAt,
                    sessionID: sessionID
                )
            }
            let metricsURL = rootURL.appendingPathComponent(
                "metrics",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: metricsURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try pruneMetricPayloads(reserving: Int64(rawJSON.count))
            let normalizedSummary = MetricKitPayloadSummary(
                kind: summary.kind,
                intervalStart: summary.intervalStart,
                intervalEnd: summary.intervalEnd,
                crashCount: summary.crashCount,
                hangCount: summary.hangCount,
                cpuExceptionCount: summary.cpuExceptionCount,
                diskWriteExceptionCount: summary.diskWriteExceptionCount,
                rawJSONByteCount: rawJSON.count
            )
            let stored = StoredMetricPayload(
                receivedAt: receivedAt,
                summary: normalizedSummary,
                rawJSON: rawJSONWasDropped ? nil : rawJSON
            )
            let data = try Self.encoder.encode(stored)
            let url = metricsURL.appendingPathComponent(
                "metric-\(UUID().uuidString).json"
            )
            try writeData(data, to: url)
            try saveMetadata()
            try enforcePersistentCap()
        } catch {
            state.fileSinkDisabled = true
        }
    }

    func health() -> DiagnosticHealth {
        let snapshot = readRecords()
        let metricCount = (try? metricURLs().count) ?? 0
        let allocated = (try? allocatedBytes())
            ?? configuration.maximumPersistentBytes + 1
        let logical = (try? logicalBytes()) ?? 0
        return DiagnosticHealth(
            allocatedBytes: allocated,
            logicalBytes: logical,
            recordCount: snapshot.records.count,
            oldestRecordAt: snapshot.records.map(\.timestamp).min(),
            newestRecordAt: snapshot.records.map(\.timestamp).max(),
            activeOperationCount: activeOperations.count,
            operationCapsuleCount: operationCapsules.count,
            metricPayloadCount: metricCount,
            droppedRecordCount: state.droppedRecordCount,
            corruptRecordCount: state.corruptRecordCount
                + snapshot.corruptCount,
            oversizedEventCount: state.oversizedEventCount,
            oversizedMetricPayloadCount:
            state.oversizedMetricPayloadCount,
            fileSinkDisabled: state.fileSinkDisabled
        )
    }

    func snapshotPackage() throws -> DiagnosticExportPackage {
        let snapshot = readRecords()
        if snapshot.corruptCount > 0 {
            state.corruptRecordCount += snapshot.corruptCount
            try? saveMetadata()
        }
        let metrics: [DiagnosticMetricAttachment] = try metricURLs()
            .compactMap { url in
            guard let stored = Self.loadJSON(
                StoredMetricPayload.self,
                from: url,
                fileManager: fileManager
            ) else {
                return nil
            }
            return DiagnosticMetricAttachment(
                receivedAt: stored.receivedAt,
                summary: stored.summary,
                rawJSON: stored.rawJSON
            )
            }
        let records = snapshot.records.sorted {
            if $0.sequence == $1.sequence {
                return $0.eventID.uuidString < $1.eventID.uuidString
            }
            return $0.sequence < $1.sequence
        }
        let health = health()
        let manifest = DiagnosticExportManifest(
            schemaVersion: RecordedEvidence.currentSchemaVersion,
            generatedAt: Date(),
            appIdentity: appIdentity,
            recordCount: records.count,
            operationCapsuleCount: operationCapsules.count,
            metricPayloadCount: metrics.count,
            oldestRecordAt: records.map(\.timestamp).min(),
            newestRecordAt: records.map(\.timestamp).max(),
            droppedRecordCount: health.droppedRecordCount,
            corruptRecordCount: health.corruptRecordCount,
            oversizedEventCount: health.oversizedEventCount,
            oversizedMetricPayloadCount:
            health.oversizedMetricPayloadCount,
            collectionWasPartial: health.droppedRecordCount > 0
                || health.corruptRecordCount > 0
                || health.oversizedEventCount > 0
                || health.oversizedMetricPayloadCount > 0
                || health.fileSinkDisabled
        )
        return DiagnosticExportPackage(
            manifest: manifest,
            records: records,
            operationCapsules: operationCapsules,
            metricAttachments: metrics
        )
    }

    func clear() throws {
        for url in managedFileURLs() where fileManager.fileExists(
            atPath: url.path
        ) {
            try fileManager.removeItem(at: url)
        }
        let metricsURL = rootURL.appendingPathComponent(
            "metrics",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: metricsURL.path) {
            for url in try metricURLs() {
                try fileManager.removeItem(at: url)
            }
            try? fileManager.removeItem(at: metricsURL)
        }
        state = PersistentState(
            segmentCount: configuration.eventSegmentCount
        )
        activeOperations = []
        operationCapsules = []
    }

    private func persistOne(
        _ event: EvidenceEvent,
        timestamp: Date,
        sessionID: DiagnosticSessionID
    ) throws {
        updateOperationState(for: event, timestamp: timestamp)
        guard state.fileSinkDisabled == false else { return }
        let record = RecordedEvidence(
            sequence: state.nextSequence,
            timestamp: timestamp,
            sessionID: sessionID,
            event: event
        )
        var data = try Self.encoder.encode(record)
        data.append(0x0A)
        guard data.count <= configuration.maximumEventBytes else {
            state.oversizedEventCount += 1
            return
        }
        if state.segmentPayloadBytes[state.currentSegment]
            + Int64(data.count)
            > configuration.eventSegmentPayloadBytes
        {
            try rotateSegment()
        }
        try reserveCapacity(forAdditionalBytes: Int64(data.count))
        let segment = state.currentSegment
        let url = segmentURL(segment)
        if fileManager.fileExists(atPath: url.path) == false {
            fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        if state.segmentRecordCounts[segment] == 0 {
            state.segmentFirstSequences[segment] = state.nextSequence
        }
        state.segmentPayloadBytes[segment] += Int64(data.count)
        state.segmentRecordCounts[segment] += 1
        state.nextSequence += 1
    }

    private func updateOperationState(
        for event: EvidenceEvent,
        timestamp: Date
    ) {
        guard let operationID = event.operationID else { return }
        switch event.code {
        case .operationStarted:
            guard let kind = event.operationKind,
                  let endpoint = event.endpoint
            else { return }
            activeOperations.removeAll { $0.id == operationID }
            activeOperations.append(
                DiagnosticActiveOperation(
                    id: operationID,
                    kind: kind,
                    endpoint: endpoint,
                    startedAt: timestamp,
                    updatedAt: timestamp,
                    lastStage: nil,
                    lastProgress: nil
                )
            )
            if activeOperations.count > 8 {
                activeOperations.removeFirst(
                    activeOperations.count - 8
                )
            }
        case .operationStage, .operationHeartbeat:
            guard let index = activeOperations.firstIndex(where: {
                $0.id == operationID
            }) else { return }
            activeOperations[index].updatedAt = timestamp
            activeOperations[index].lastStage = event.stage
            activeOperations[index].lastProgress = event.progress
        case .operationSucceeded, .operationFailed:
            let active = activeOperations.first { $0.id == operationID }
            activeOperations.removeAll { $0.id == operationID }
            guard let kind = event.operationKind else { return }
            let duration = TimeInterval(event.durationMilliseconds ?? 0)
                / 1_000
            operationCapsules.append(
                DiagnosticOperationCapsule(
                    operationID: operationID,
                    incidentID: event.incidentID,
                    kind: kind,
                    endpoint: active?.endpoint ?? .none,
                    startedAt: active?.startedAt
                        ?? timestamp.addingTimeInterval(-duration),
                    finishedAt: timestamp,
                    lastStage: event.stage ?? active?.lastStage,
                    lastProgress: event.progress ?? active?.lastProgress,
                    outcome: event.code == .operationSucceeded
                        ? .succeeded
                        : .failed,
                    failure: event.failure
                )
            )
            trimCapsules()
        default:
            break
        }
    }

    private func trimCapsules() {
        if operationCapsules.count > 8 {
            operationCapsules.removeFirst(operationCapsules.count - 8)
        }
    }

    private func rotateSegment() throws {
        state.currentSegment = (state.currentSegment + 1)
            % configuration.eventSegmentCount
        let target = segmentURL(state.currentSegment)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        state.segmentPayloadBytes[state.currentSegment] = 0
        state.segmentRecordCounts[state.currentSegment] = 0
        state.segmentFirstSequences[state.currentSegment] = 0
    }

    private func reserveCapacity(forAdditionalBytes byteCount: Int64) throws {
        let allocation = roundedAllocation(byteCount)
        while try allocatedBytes() + allocation
            > configuration.maximumPersistentBytes
        {
            if try removeOldestMetricPayload() {
                continue
            }
            guard try removeOldestEventSegment(excludingCurrent: true) else {
                state.fileSinkDisabled = true
                throw DiagnosticStorageError.allocatedSizeUnavailable
            }
        }
    }

    private func enforcePersistentCap() throws {
        while try allocatedBytes() > configuration.maximumPersistentBytes {
            if try removeOldestMetricPayload() {
                continue
            }
            guard try removeOldestEventSegment(excludingCurrent: false) else {
                state.fileSinkDisabled = true
                throw DiagnosticStorageError.allocatedSizeUnavailable
            }
        }
    }

    private func removeOldestEventSegment(
        excludingCurrent: Bool
    ) throws -> Bool {
        let candidates = state.segmentFirstSequences.indices.filter { index in
            state.segmentRecordCounts[index] > 0
                && (excludingCurrent == false || index != state.currentSegment)
        }
        guard let oldest = candidates.min(by: {
            state.segmentFirstSequences[$0]
                < state.segmentFirstSequences[$1]
        }) else {
            return false
        }
        let url = segmentURL(oldest)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        state.segmentPayloadBytes[oldest] = 0
        state.segmentRecordCounts[oldest] = 0
        state.segmentFirstSequences[oldest] = 0
        return true
    }

    private func removeOldestMetricPayload() throws -> Bool {
        let urls = try metricURLs()
        guard let oldest = try urls.min(by: {
            try modificationDate(of: $0) < modificationDate(of: $1)
        }) else {
            return false
        }
        try fileManager.removeItem(at: oldest)
        return true
    }

    private func pruneMetricPayloads(reserving byteCount: Int64) throws {
        while try metricLogicalBytes() + byteCount
            > configuration.metricCacheBytes
        {
            guard try removeOldestMetricPayload() else { break }
        }
    }

    private func pruneExpiredRecords(now: Date) throws {
        let cutoff = now.addingTimeInterval(-configuration.retentionInterval)
        for index in 0 ..< configuration.eventSegmentCount {
            let url = segmentURL(index)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let allLines = try Data(contentsOf: url).split(separator: 0x0A)
            var corruptCount = 0
            let retained = allLines.compactMap { line -> Data? in
                guard let record = try? Self.decoder.decode(
                    RecordedEvidence.self,
                    from: Data(line)
                ), record.schemaVersion == RecordedEvidence.currentSchemaVersion
                else {
                    corruptCount += 1
                    return nil
                }
                guard record.timestamp >= cutoff else { return nil }
                var data = Data(line)
                data.append(0x0A)
                return data
            }
            state.corruptRecordCount += corruptCount
            guard retained.count != allLines.count else { continue }
            if retained.isEmpty {
                try fileManager.removeItem(at: url)
                state.segmentPayloadBytes[index] = 0
                state.segmentRecordCounts[index] = 0
                state.segmentFirstSequences[index] = 0
            } else {
                let data = retained.reduce(into: Data()) { $0.append($1) }
                try writeDataAtomically(data, to: url)
                let records = retained.compactMap {
                    try? Self.decoder.decode(
                        RecordedEvidence.self,
                        from: Data($0.dropLast())
                    )
                }
                state.segmentPayloadBytes[index] = Int64(data.count)
                state.segmentRecordCounts[index] = records.count
                state.segmentFirstSequences[index] =
                    records.map(\.sequence).min() ?? 0
            }
        }
    }

    private func rebuildStateFromSegments() throws {
        var maximumSequence: UInt64 = 0
        for index in 0 ..< configuration.eventSegmentCount {
            let url = segmentURL(index)
            guard fileManager.fileExists(atPath: url.path) else {
                state.segmentPayloadBytes[index] = 0
                state.segmentRecordCounts[index] = 0
                state.segmentFirstSequences[index] = 0
                continue
            }
            let data = try Data(contentsOf: url)
            let records = data.split(separator: 0x0A).compactMap {
                try? Self.decoder.decode(
                    RecordedEvidence.self,
                    from: Data($0)
                )
            }
            state.segmentPayloadBytes[index] = Int64(data.count)
            state.segmentRecordCounts[index] = records.count
            state.segmentFirstSequences[index] =
                records.map(\.sequence).min() ?? 0
            maximumSequence = max(
                maximumSequence,
                records.map(\.sequence).max() ?? 0
            )
        }
        state.nextSequence = max(state.nextSequence, maximumSequence + 1)
    }

    private func readRecords() -> (
        records: [RecordedEvidence],
        corruptCount: Int
    ) {
        let cutoff = Date().addingTimeInterval(
            -configuration.retentionInterval
        )
        var byEventID: [UUID: RecordedEvidence] = [:]
        var corruptCount = 0
        for index in 0 ..< configuration.eventSegmentCount {
            let url = segmentURL(index)
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) {
                guard let record = try? Self.decoder.decode(
                    RecordedEvidence.self,
                    from: Data(line)
                ), record.schemaVersion == RecordedEvidence.currentSchemaVersion
                else {
                    corruptCount += 1
                    continue
                }
                guard record.timestamp >= cutoff else { continue }
                byEventID[record.eventID] = record
            }
        }
        return (Array(byEventID.values), corruptCount)
    }

    private func saveMetadata() throws {
        try writeJSON(state, to: indexURL)
        try writeJSON(
            Array(activeOperations.suffix(8)),
            to: activeOperationsURL
        )
        try writeJSON(
            Array(operationCapsules.suffix(8)),
            to: operationCapsulesURL
        )
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try Self.encoder.encode(value)
        guard data.count <= 128 * 1_024 else {
            throw DiagnosticStorageError.exportTooLarge
        }
        try writeDataAtomically(data, to: url)
    }

    private func writeDataAtomically(_ data: Data, to url: URL) throws {
        let temporaryURL = rootURL.appendingPathComponent(
            ".\(url.lastPathComponent).tmp"
        )
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
        try writeData(data, to: temporaryURL)
        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private func allocatedBytes() throws -> Int64 {
        try managedExistingFileURLs().reduce(0) { total, url in
            let values = try url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey
            ])
            guard let size = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
            else {
                throw DiagnosticStorageError.allocatedSizeUnavailable
            }
            return total + Int64(size)
        }
    }

    private func logicalBytes() throws -> Int64 {
        try managedExistingFileURLs().reduce(0) { total, url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return total + Int64(values.fileSize ?? 0)
        }
    }

    private func metricLogicalBytes() throws -> Int64 {
        try metricURLs().reduce(0) { total, url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return total + Int64(values.fileSize ?? 0)
        }
    }

    private func roundedAllocation(_ byteCount: Int64) -> Int64 {
        var information = statfs()
        let blockSize: Int64
        if statfs(rootURL.path, &information) == 0 {
            blockSize = max(4_096, Int64(information.f_bsize))
        } else {
            blockSize = 4_096
        }
        return ((max(1, byteCount) + blockSize - 1) / blockSize)
            * blockSize
    }

    private func managedExistingFileURLs() throws -> [URL] {
        let direct = managedFileURLs().filter {
            fileManager.fileExists(atPath: $0.path)
        }
        return direct + (try metricURLs())
    }

    private func managedFileURLs() -> [URL] {
        [indexURL, activeOperationsURL, operationCapsulesURL]
            + (0 ..< configuration.eventSegmentCount).map(segmentURL)
            + [
                rootURL.appendingPathComponent(".index.json.tmp"),
                rootURL.appendingPathComponent(
                    ".active-operations.json.tmp"
                ),
                rootURL.appendingPathComponent(
                    ".operation-capsules.json.tmp"
                )
            ]
    }

    private func metricURLs() throws -> [URL] {
        let metricsURL = rootURL.appendingPathComponent(
            "metrics",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: metricsURL.path) else {
            return []
        }
        return try fileManager.contentsOfDirectory(
            at: metricsURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter {
            $0.lastPathComponent.hasPrefix("metric-")
                && $0.pathExtension == "json"
        }
    }

    private func modificationDate(of url: URL) throws -> Date {
        try url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate ?? .distantPast
    }

    private func segmentURL(_ index: Int) -> URL {
        rootURL.appendingPathComponent(
            String(format: "events-%02d.ndjson", index)
        )
    }

    private var indexURL: URL {
        rootURL.appendingPathComponent("index.json")
    }

    private var activeOperationsURL: URL {
        rootURL.appendingPathComponent("active-operations.json")
    }

    private var operationCapsulesURL: URL {
        rootURL.appendingPathComponent("operation-capsules.json")
    }

    private static func loadJSON<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        fileManager: FileManager
    ) -> T? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? decoder.decode(type, from: data)
    }

    private static func normalized(
        _ state: PersistentState,
        segmentCount: Int
    ) -> PersistentState {
        guard state.schemaVersion == RecordedEvidence.currentSchemaVersion,
              state.currentSegment >= 0,
              state.currentSegment < segmentCount,
              state.segmentPayloadBytes.count == segmentCount,
              state.segmentRecordCounts.count == segmentCount,
              state.segmentFirstSequences.count == segmentCount
        else {
            return PersistentState(segmentCount: segmentCount)
        }
        return state
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
