import CryptoKit
import Foundation

public final class LocalDiagnosticRecorder: DiagnosticRecording, @unchecked Sendable {
    public let sessionID: DiagnosticSessionID

    private struct QueuedEvidence {
        let event: EvidenceEvent
        let timestamp: Date
        let estimatedBytes: Int
    }

    private let configuration: DiagnosticStorageConfiguration
    private let appleLogger: AppleDiagnosticLogger?
    private let ioQueue = DispatchQueue(
        label: "app.noonmark.diagnostics.writer",
        qos: .utility
    )
    private let bufferLock = NSLock()
    private let diskStore: DiagnosticDiskStore
    private var buffered: [QueuedEvidence] = []
    private var bufferedBytes = 0
    private var pendingDroppedCount = 0
    private var pendingDroppedCriticalCount = 0
    private var pendingOversizedCount = 0
    private var drainScheduled = false

    public convenience init(
        rootURL: URL,
        appIdentity: DiagnosticAppIdentity = .current,
        configuration: DiagnosticStorageConfiguration = .production,
        sessionID: DiagnosticSessionID = DiagnosticSessionID()
    ) throws {
        try self.init(
            rootURL: rootURL,
            appIdentity: appIdentity,
            configuration: configuration,
            sessionID: sessionID,
            appleLogger: AppleDiagnosticLogger(),
            now: { Date() }
        )
    }

    public static func prepare(
        rootURL: URL,
        configuration: DiagnosticStorageConfiguration = .production,
        sessionID: DiagnosticSessionID = DiagnosticSessionID()
    ) async throws -> LocalDiagnosticRecorder {
        try await prepare(
            rootURL: rootURL,
            configuration: configuration,
            sessionID: sessionID,
            currentAppIdentityObserver: {}
        )
    }

    static func prepare(
        rootURL: URL,
        configuration: DiagnosticStorageConfiguration = .production,
        sessionID: DiagnosticSessionID = DiagnosticSessionID(),
        currentAppIdentityObserver: @escaping @Sendable () -> Void
    ) async throws -> LocalDiagnosticRecorder {
        try await prepare(
            rootURL: rootURL,
            appIdentityProvider: {
                currentAppIdentityObserver()
                return .current
            },
            configuration: configuration,
            sessionID: sessionID,
            initializationObserver: {}
        )
    }

    public static func prepare(
        rootURL: URL,
        appIdentity: DiagnosticAppIdentity,
        configuration: DiagnosticStorageConfiguration = .production,
        sessionID: DiagnosticSessionID = DiagnosticSessionID()
    ) async throws -> LocalDiagnosticRecorder {
        try await prepare(
            rootURL: rootURL,
            appIdentityProvider: { appIdentity },
            configuration: configuration,
            sessionID: sessionID,
            initializationObserver: {}
        )
    }

    static func prepare(
        rootURL: URL,
        appIdentity: DiagnosticAppIdentity,
        configuration: DiagnosticStorageConfiguration = .production,
        sessionID: DiagnosticSessionID = DiagnosticSessionID(),
        initializationObserver: @escaping @Sendable () -> Void
    ) async throws -> LocalDiagnosticRecorder {
        try await prepare(
            rootURL: rootURL,
            appIdentityProvider: { appIdentity },
            configuration: configuration,
            sessionID: sessionID,
            initializationObserver: initializationObserver
        )
    }

    private static func prepare(
        rootURL: URL,
        appIdentityProvider: @escaping @Sendable () -> DiagnosticAppIdentity,
        configuration: DiagnosticStorageConfiguration,
        sessionID: DiagnosticSessionID,
        initializationObserver: @escaping @Sendable () -> Void
    ) async throws -> LocalDiagnosticRecorder {
        try await Task.detached(priority: .utility) {
            initializationObserver()
            return try LocalDiagnosticRecorder(
                rootURL: rootURL,
                appIdentity: appIdentityProvider(),
                configuration: configuration,
                sessionID: sessionID
            )
        }.value
    }

    convenience init(
        rootURL: URL,
        appIdentity: DiagnosticAppIdentity,
        configuration: DiagnosticStorageConfiguration,
        sessionID: DiagnosticSessionID = DiagnosticSessionID(),
        unifiedLoggingEnabled: Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        try self.init(
            rootURL: rootURL,
            appIdentity: appIdentity,
            configuration: configuration,
            sessionID: sessionID,
            appleLogger: unifiedLoggingEnabled
                ? AppleDiagnosticLogger()
                : nil,
            now: now
        )
    }

    private init(
        rootURL: URL,
        appIdentity: DiagnosticAppIdentity,
        configuration: DiagnosticStorageConfiguration,
        sessionID: DiagnosticSessionID,
        appleLogger: AppleDiagnosticLogger?,
        now: @escaping @Sendable () -> Date
    ) throws {
        self.sessionID = sessionID
        self.configuration = configuration
        self.appleLogger = appleLogger
        diskStore = try DiagnosticDiskStore(
            rootURL: rootURL,
            appIdentity: appIdentity,
            configuration: configuration,
            now: now
        )
    }

    public func record(_ event: EvidenceEvent, at timestamp: Date) {
        appleLogger?.record(event)
        let estimatedBytes = configuration.maximumEventBytes
        var shouldSchedule = false

        bufferLock.lock()
        if queueWouldOverflow(addingBytes: estimatedBytes),
           let evictionIndex = queueEvictionIndex(for: event)
        {
            let evicted = buffered.remove(at: evictionIndex)
            bufferedBytes -= evicted.estimatedBytes
            registerQueueDrop(of: evicted.event)
        }
        if queueWouldOverflow(addingBytes: estimatedBytes) {
            registerQueueDrop(of: event)
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

    private func queueWouldOverflow(addingBytes byteCount: Int) -> Bool {
        buffered.count >= configuration.maximumQueuedEvents
            || bufferedBytes + byteCount
            > configuration.maximumQueuedBytes
    }

    private func queueEvictionIndex(for incoming: EvidenceEvent) -> Int? {
        let incomingPriority = incoming.retentionPriority
        return buffered.indices
            .filter {
                buffered[$0].event.retentionPriority < incomingPriority
            }
            .min {
                buffered[$0].event.retentionPriority
                    < buffered[$1].event.retentionPriority
            }
    }

    private func registerQueueDrop(of event: EvidenceEvent) {
        pendingDroppedCount += 1
        if event.isRetentionCritical {
            pendingDroppedCriticalCount += 1
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

    public func persistedSyncFailureCorrelation(
        failure: DiagnosticFailure,
        failedAt: Date
    ) async -> DiagnosticOperationCorrelation? {
        await flush()
        return await withCheckedContinuation { continuation in
            ioQueue.async { [self] in
                continuation.resume(
                    returning: diskStore.persistedSyncFailureCorrelation(
                        failure: failure,
                        failedAt: failedAt
                    )
                )
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
            activeOperationCount: package.activeOperations.count,
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
        guard data.count <= 8 * 1024 * 1024 else {
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
            let droppedCriticalCount: Int
            let oversizedCount: Int

            bufferLock.lock()
            guard buffered.isEmpty == false
                || pendingDroppedCount > 0
                || pendingDroppedCriticalCount > 0
                || pendingOversizedCount > 0
            else {
                drainScheduled = false
                bufferLock.unlock()
                return
            }
            batch = buffered
            droppedCount = pendingDroppedCount
            droppedCriticalCount = pendingDroppedCriticalCount
            oversizedCount = pendingOversizedCount
            buffered = []
            bufferedBytes = 0
            pendingDroppedCount = 0
            pendingDroppedCriticalCount = 0
            pendingOversizedCount = 0
            bufferLock.unlock()

            diskStore.persist(
                batch.map { ($0.event, $0.timestamp) },
                sessionID: sessionID,
                droppedCount: droppedCount,
                droppedCriticalCount: droppedCriticalCount,
                oversizedCount: oversizedCount
            )
        }
    }

    private static let exportEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

private extension EvidenceEvent {
    var retentionPriority: Int {
        switch code {
        case .operationFailed, .previousSessionInterrupted:
            4
        case .operationSucceeded:
            3
        case .operationStarted:
            2
        default:
            isRetentionCritical ? 1 : 0
        }
    }

    var isRetentionCritical: Bool {
        switch code {
        case .operationStage, .operationHeartbeat:
            false
        case .persistenceCheckpoint:
            severity != .information
        case .sessionStarted, .cleanShutdown,
             .previousSessionInterrupted, .operationStarted,
             .operationSucceeded, .operationFailed, .mutationRejected,
             .persistenceFailed, .persistedSyncFailureLoaded,
             .recordsDropped, .corruptRecordExcluded,
             .oversizedEventDropped, .oversizedMetricPayloadDropped:
            true
        }
    }
}

public enum DiagnosticStorageError: Error, Equatable, Sendable {
    case invalidRoot
    case exportTooLarge
    case allocatedSizeUnavailable
}

extension DiagnosticStorageError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .invalidRoot: 1
        case .exportTooLarge: 2
        case .allocatedSizeUnavailable: 3
        }
        return DiagnosticFailure(domain: .diagnostics, code: code)
    }
}

private final class DiagnosticDiskStore {
    private struct LossCounts: Codable {
        var droppedRecordCount = 0
        var droppedCriticalRecordCount = 0
        var compactedCriticalEvidenceCount = 0
        var evictedMetricPayloadCount = 0
        var corruptRecordCount = 0
        var oversizedEventCount = 0
        var oversizedMetricPayloadCount = 0
        var maximumObservedAllocatedBytes: Int64 = 0

        var isEmpty: Bool {
            droppedRecordCount == 0
                && droppedCriticalRecordCount == 0
                && compactedCriticalEvidenceCount == 0
                && evictedMetricPayloadCount == 0
                && corruptRecordCount == 0
                && oversizedEventCount == 0
                && oversizedMetricPayloadCount == 0
                && maximumObservedAllocatedBytes == 0
        }

        mutating func add(_ other: Self) {
            droppedRecordCount = Self.saturatingSum(
                droppedRecordCount,
                other.droppedRecordCount
            )
            droppedCriticalRecordCount = Self.saturatingSum(
                droppedCriticalRecordCount,
                other.droppedCriticalRecordCount
            )
            compactedCriticalEvidenceCount = Self.saturatingSum(
                compactedCriticalEvidenceCount,
                other.compactedCriticalEvidenceCount
            )
            evictedMetricPayloadCount = Self.saturatingSum(
                evictedMetricPayloadCount,
                other.evictedMetricPayloadCount
            )
            corruptRecordCount = Self.saturatingSum(
                corruptRecordCount,
                other.corruptRecordCount
            )
            oversizedEventCount = Self.saturatingSum(
                oversizedEventCount,
                other.oversizedEventCount
            )
            oversizedMetricPayloadCount = Self.saturatingSum(
                oversizedMetricPayloadCount,
                other.oversizedMetricPayloadCount
            )
            maximumObservedAllocatedBytes = max(
                maximumObservedAllocatedBytes,
                other.maximumObservedAllocatedBytes
            )
        }

        mutating func normalize() {
            droppedRecordCount = max(0, droppedRecordCount)
            droppedCriticalRecordCount = max(0, droppedCriticalRecordCount)
            compactedCriticalEvidenceCount = max(
                0,
                compactedCriticalEvidenceCount
            )
            evictedMetricPayloadCount = max(0, evictedMetricPayloadCount)
            corruptRecordCount = max(0, corruptRecordCount)
            oversizedEventCount = max(0, oversizedEventCount)
            oversizedMetricPayloadCount = max(
                0,
                oversizedMetricPayloadCount
            )
            maximumObservedAllocatedBytes = max(
                0,
                maximumObservedAllocatedBytes
            )
        }

        private static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? Int.max : max(0, sum)
        }
    }

    private struct LossBucket: Codable {
        let utcDayStart: Date
        var firstOccurredAt: Date?
        var lastOccurredAt: Date?
        var counts: LossCounts
    }

    private enum LossKind {
        case droppedRecord
        case droppedCriticalRecord
        case compactedCriticalEvidence
        case evictedMetricPayload
        case corruptRecord
        case oversizedEvent
        case oversizedMetricPayload
    }

    private struct MetricReconciliation {
        let attachments: [DiagnosticMetricAttachment]
    }

    private enum ManagedDirectoryStatus: Equatable {
        case absent
        case ownedDirectory
        case invalidEntry
    }

    private struct PersistentState: Codable {
        var schemaVersion = RecordedEvidence.currentSchemaVersion
        var currentSegment = 0
        var nextSequence: UInt64 = 1
        var segmentPayloadBytes: [Int64]
        var segmentRecordCounts: [Int]
        var segmentFirstSequences: [UInt64]
        var droppedRecordCount: Int?
        var corruptRecordCount: Int?
        var oversizedEventCount: Int?
        var oversizedMetricPayloadCount: Int?
        var droppedCriticalRecordCount: Int?
        var compactedCriticalEvidenceCount: Int?
        var evictedMetricPayloadCount: Int?
        var lossBuckets: [LossBucket]?
        var maximumObservedAllocatedBytes: Int64?
        var fileSinkDisabled = false

        init(segmentCount: Int) {
            segmentPayloadBytes = Array(repeating: 0, count: segmentCount)
            segmentRecordCounts = Array(repeating: 0, count: segmentCount)
            segmentFirstSequences = Array(repeating: 0, count: segmentCount)
        }
    }

    private let rootDirectory: DiagnosticOwnedDirectory
    private let appIdentity: DiagnosticAppIdentity
    private let configuration: DiagnosticStorageConfiguration
    private let now: @Sendable () -> Date
    private var state: PersistentState
    private var activeOperations: [DiagnosticActiveOperation]
    private var operationCapsules: [DiagnosticOperationCapsule]
    private var metricsDirectory: DiagnosticOwnedDirectory?
    private var currentMetricCorruptRecordCount = 0

    init(
        rootURL: URL,
        appIdentity: DiagnosticAppIdentity,
        configuration: DiagnosticStorageConfiguration,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard rootURL.isFileURL,
              rootURL.standardizedFileURL.path != "/"
        else {
            throw DiagnosticStorageError.invalidRoot
        }
        let standardizedRootURL = rootURL.standardizedFileURL
        self.appIdentity = appIdentity
        self.configuration = configuration
        self.now = now
        rootDirectory = try DiagnosticOwnedDirectory.openRoot(
            at: standardizedRootURL,
            permissions: 0o700,
            fileManager: fileManager
        )
        state = Self.loadJSON(
            PersistentState.self,
            named: "index.json",
            in: rootDirectory
        ) ?? PersistentState(segmentCount: configuration.eventSegmentCount)
        state = Self.normalized(
            state,
            segmentCount: configuration.eventSegmentCount
        )
        activeOperations = Self.loadJSON(
            [DiagnosticActiveOperation].self,
            named: "active-operations.json",
            in: rootDirectory
        ) ?? []
        operationCapsules = Self.loadJSON(
            [DiagnosticOperationCapsule].self,
            named: "operation-capsules.json",
            in: rootDirectory
        ) ?? []
        metricsDirectory = try rootDirectory.openChildDirectory(
            named: metricsDirectoryName,
            createIfMissing: true,
            permissions: 0o700
        )
        guard metricsDirectory != nil else {
            throw DiagnosticStorageError.invalidRoot
        }
        try removeAtomicTemporaryFiles()
        let initializationTime = now()
        let legacyEvidenceTime = min(
            (try? rootDirectory.entryInformation(named: indexName))?
                .modificationDate ?? initializationTime,
            initializationTime
        )
        migrateLegacyLossCounters(at: legacyEvidenceTime)
        try rebuildStateFromSegments()
        try pruneExpiredEvidence(now: initializationTime)
        try saveMetadata()
        try enforcePersistentCap()
    }

    func startSession(sessionID: DiagnosticSessionID, timestamp: Date) {
        do {
            try pruneExpiredEvidence(now: now())
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
        droppedCriticalCount: Int,
        oversizedCount: Int
    ) {
        do {
            incrementLoss(.droppedRecord, by: droppedCount)
            incrementLoss(
                .droppedCriticalRecord,
                by: droppedCriticalCount
            )
            incrementLoss(.oversizedEvent, by: oversizedCount)
            if droppedCount > 0 {
                try persistOne(
                    .recordsDropped(count: droppedCount),
                    timestamp: now(),
                    sessionID: sessionID
                )
            }
            if oversizedCount > 0 {
                try persistOne(
                    .oversizedEventDropped(byteCount: Int64(oversizedCount)),
                    timestamp: now(),
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
            try pruneExpiredEvidence(now: now())
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
            try pruneExpiredEvidence(now: now())
            let rawJSONWasDropped = rawJSON.count
                > configuration.maximumMetricPayloadBytes
            if rawJSONWasDropped {
                incrementLoss(.oversizedMetricPayload, by: 1)
                try persistOne(
                    .oversizedMetricPayloadDropped(
                        byteCount: Int64(rawJSON.count)
                    ),
                    timestamp: receivedAt,
                    sessionID: sessionID
                )
            }
            let metricsDirectory = try prepareMetricsDirectory()
            let sanitizedJSON: Data?
            if rawJSONWasDropped {
                sanitizedJSON = nil
            } else {
                do {
                    sanitizedJSON = try MetricKitJSONSanitizer.sanitize(
                        rawJSON
                    )
                } catch {
                    incrementLoss(.corruptRecord, by: 1)
                    try persistOne(
                        .corruptRecordExcluded(count: 1),
                        timestamp: receivedAt,
                        sessionID: sessionID
                    )
                    sanitizedJSON = nil
                }
            }
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
            let stored = MetricKitStoredPayload(
                receivedAt: receivedAt,
                summary: normalizedSummary,
                sanitizedJSON: sanitizedJSON,
                redactionVersion: MetricKitJSONSanitizer.redactionVersion
            )
            let data = try Self.encoder.encode(stored)
            try pruneMetricPayloads(reserving: Int64(data.count))
            try reserveCapacity(forAdditionalBytes: Int64(data.count))
            let entryName = "metric-\(UUID().uuidString).json"
            try writeData(data, named: entryName, in: metricsDirectory)
            try saveMetadata()
            try enforcePersistentCap()
        } catch {
            state.fileSinkDisabled = true
        }
    }

    func health() -> DiagnosticHealth {
        do {
            try pruneExpiredEvidence(now: now())
            try saveMetadata()
            try enforcePersistentCap()
        } catch {
            state.fileSinkDisabled = true
        }
        let snapshot = readRecords()
        let metricCount = (try? metricEntryNames().count) ?? 0
        let allocated = (try? allocatedBytes())
            ?? configuration.maximumPersistentBytes + 1
        let logical = (try? logicalBytes()) ?? 0
        let lossCounts = currentLossCounts
        let maximumObserved = max(
            lossCounts.maximumObservedAllocatedBytes,
            allocated
        )
        return DiagnosticHealth(
            allocatedBytes: allocated,
            maximumObservedAllocatedBytes: maximumObserved,
            logicalBytes: logical,
            recordCount: snapshot.records.count,
            oldestRecordAt: snapshot.records.map(\.timestamp).min(),
            newestRecordAt: snapshot.records.map(\.timestamp).max(),
            activeOperationCount: activeOperations.count,
            operationCapsuleCount: operationCapsules.count,
            metricPayloadCount: metricCount,
            droppedRecordCount: lossCounts.droppedRecordCount,
            droppedCriticalRecordCount:
            lossCounts.droppedCriticalRecordCount,
            compactedCriticalEvidenceCount:
            lossCounts.compactedCriticalEvidenceCount,
            evictedMetricPayloadCount:
            lossCounts.evictedMetricPayloadCount,
            corruptRecordCount: lossCounts.corruptRecordCount
                + snapshot.corruptCount
                + currentMetricCorruptRecordCount,
            oversizedEventCount: lossCounts.oversizedEventCount,
            oversizedMetricPayloadCount:
            lossCounts.oversizedMetricPayloadCount,
            fileSinkDisabled: state.fileSinkDisabled
        )
    }

    func snapshotPackage() throws -> DiagnosticExportPackage {
        try pruneExpiredEvidence(now: now())
        try saveMetadata()
        try enforcePersistentCap()
        let snapshot = readRecords()
        if snapshot.corruptCount > 0 {
            incrementLoss(.corruptRecord, by: snapshot.corruptCount)
            try? saveMetadata()
        }
        let metricReconciliation = try reconcileMetricPayloads(now: now())
        let metrics = metricReconciliation.attachments
        let records = snapshot.records.sorted {
            if $0.sequence == $1.sequence {
                return $0.eventID.uuidString < $1.eventID.uuidString
            }
            return $0.sequence < $1.sequence
        }
        let health = health()
        let manifest = DiagnosticExportManifest(
            schemaVersion: RecordedEvidence.currentSchemaVersion,
            generatedAt: now(),
            appIdentity: appIdentity,
            recordCount: records.count,
            activeOperationCount: activeOperations.count,
            operationCapsuleCount: operationCapsules.count,
            metricPayloadCount: metrics.count,
            oldestRecordAt: records.map(\.timestamp).min(),
            newestRecordAt: records.map(\.timestamp).max(),
            droppedRecordCount: health.droppedRecordCount,
            droppedCriticalRecordCount:
            health.droppedCriticalRecordCount,
            compactedCriticalEvidenceCount:
            health.compactedCriticalEvidenceCount,
            evictedMetricPayloadCount:
            health.evictedMetricPayloadCount,
            corruptRecordCount: health.corruptRecordCount,
            oversizedEventCount: health.oversizedEventCount,
            oversizedMetricPayloadCount:
            health.oversizedMetricPayloadCount,
            maximumObservedAllocatedBytes:
            health.maximumObservedAllocatedBytes,
            redactionVersion: MetricKitJSONSanitizer.redactionVersion,
            collectionWasPartial: health.droppedRecordCount > 0
                || health.droppedCriticalRecordCount > 0
                || health.compactedCriticalEvidenceCount > 0
                || health.evictedMetricPayloadCount > 0
                || health.corruptRecordCount > 0
                || health.oversizedEventCount > 0
                || health.oversizedMetricPayloadCount > 0
                || health.fileSinkDisabled
        )
        return DiagnosticExportPackage(
            manifest: manifest,
            records: records,
            activeOperations: activeOperations.sorted {
                $0.startedAt < $1.startedAt
            },
            operationCapsules: operationCapsules,
            metricAttachments: metrics
        )
    }

    func persistedSyncFailureCorrelation(
        failure: DiagnosticFailure,
        failedAt: Date
    ) -> DiagnosticOperationCorrelation? {
        let matches = operationCapsules.filter { capsule in
            capsule.kind == .localFirstSync
                && capsule.outcome == .failed
                && capsule.failure == failure
                && capsule.finishedAt == failedAt
                && capsule.incidentID != nil
        }
        guard matches.count == 1,
              let match = matches.first,
              let incidentID = match.incidentID
        else { return nil }
        return DiagnosticOperationCorrelation(
            operationID: match.operationID,
            incidentID: incidentID
        )
    }

    func clear() throws {
        for entryName in try managedRootEntryNames() {
            try rootDirectory.removeEntryIfPresent(named: entryName)
        }
        switch metricDirectoryStatus() {
        case .absent:
            break
        case .ownedDirectory:
            guard let metricsDirectory else {
                throw DiagnosticStorageError.invalidRoot
            }
            for entryName in try metricEntryNames() {
                try metricsDirectory.removeEntryIfPresent(named: entryName)
            }
        case .invalidEntry:
            try rootDirectory.removeEntryIfPresent(named: metricsDirectoryName)
        }
        state = PersistentState(
            segmentCount: configuration.eventSegmentCount
        )
        activeOperations = []
        operationCapsules = []
        currentMetricCorruptRecordCount = 0
    }

    private func persistOne(
        _ event: EvidenceEvent,
        timestamp: Date,
        sessionID: DiagnosticSessionID
    ) throws {
        updateOperationState(for: event, timestamp: timestamp)
        guard state.fileSinkDisabled == false else { return }
        let sequence = state.nextSequence
        let (nextSequence, overflow) = sequence.addingReportingOverflow(1)
        guard overflow == false else {
            state.fileSinkDisabled = true
            return
        }
        let record = RecordedEvidence(
            sequence: sequence,
            timestamp: timestamp,
            sessionID: sessionID,
            event: event
        )
        var data = try Self.encoder.encode(record)
        data.append(0x0A)
        guard data.count <= configuration.maximumEventBytes else {
            incrementLoss(.oversizedEvent, by: 1)
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
        try rootDirectory.appendFile(
            named: segmentName(segment),
            data: data
        )
        try observeAllocatedBytes()
        if state.segmentRecordCounts[segment] == 0 {
            state.segmentFirstSequences[segment] = sequence
        }
        state.segmentPayloadBytes[segment] += Int64(data.count)
        state.segmentRecordCounts[segment] += 1
        state.nextSequence = nextSequence
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
            trimActiveOperations()
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
                / 1000
            operationCapsules.append(
                DiagnosticOperationCapsule(
                    operationID: operationID,
                    incidentID: event.incidentID,
                    kind: kind,
                    endpoint: event.endpoint ?? active?.endpoint ?? .none,
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
        while operationCapsules.count > 8 {
            let removalIndex = operationCapsules.indices.min { lhs, rhs in
                let left = capsuleRetentionPriority(
                    operationCapsules[lhs].outcome
                )
                let right = capsuleRetentionPriority(
                    operationCapsules[rhs].outcome
                )
                if left == right {
                    return operationCapsules[lhs].finishedAt
                        < operationCapsules[rhs].finishedAt
                }
                return left < right
            } ?? operationCapsules.startIndex
            operationCapsules.remove(at: removalIndex)
            incrementCompactedCriticalEvidence(by: 1)
        }
    }

    private func trimActiveOperations() {
        while activeOperations.count > 8 {
            let removalIndex = activeOperations.indices.min {
                activeOperations[$0].updatedAt
                    < activeOperations[$1].updatedAt
            } ?? activeOperations.startIndex
            activeOperations.remove(at: removalIndex)
            incrementCompactedCriticalEvidence(by: 1)
        }
    }

    private func capsuleRetentionPriority(
        _ outcome: DiagnosticOperationOutcome
    ) -> Int {
        switch outcome {
        case .succeeded:
            0
        case .interrupted:
            1
        case .failed:
            2
        }
    }

    private func rotateSegment() throws {
        state.currentSegment = (state.currentSegment + 1)
            % configuration.eventSegmentCount
        try discardSegment(
            state.currentSegment,
            countAsCapacityEviction: true
        )
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
        try discardSegment(oldest, countAsCapacityEviction: true)
        return true
    }

    private func discardSegment(
        _ index: Int,
        countAsCapacityEviction: Bool
    ) throws {
        let entryName = segmentName(index)
        if try rootDirectory.entryInformation(named: entryName) != nil {
            if countAsCapacityEviction {
                let lines = try rootDirectory.readFile(
                    named: entryName,
                    maximumByteCount: configuration.maximumPersistentBytes
                ).split(separator: 0x0A)
                var discardedCount = 0
                var discardedCriticalCount = 0
                var corruptCount = 0
                for line in lines {
                    guard let record = try? Self.decoder.decode(
                        RecordedEvidence.self,
                        from: Data(line)
                    ), Self.isValidPersistedRecord(record)
                    else {
                        corruptCount += 1
                        continue
                    }
                    discardedCount += 1
                    if record.event.isRetentionCritical {
                        discardedCriticalCount += 1
                    }
                }
                incrementLoss(.droppedRecord, by: discardedCount)
                incrementLoss(
                    .droppedCriticalRecord,
                    by: discardedCriticalCount
                )
                incrementLoss(.corruptRecord, by: corruptCount)
            }
            try rootDirectory.removeEntryIfPresent(named: entryName)
        }
        state.segmentPayloadBytes[index] = 0
        state.segmentRecordCounts[index] = 0
        state.segmentFirstSequences[index] = 0
    }

    private func removeOldestMetricPayload() throws -> Bool {
        let entryNames = try metricEntryNames()
        guard let oldest = try entryNames.min(by: {
            try metricModificationDate(of: $0)
                < metricModificationDate(of: $1)
        }) else {
            return false
        }
        guard let metricsDirectory else {
            throw DiagnosticStorageError.invalidRoot
        }
        try metricsDirectory.removeEntryIfPresent(named: oldest)
        incrementLoss(.evictedMetricPayload, by: 1)
        return true
    }

    private func incrementCompactedCriticalEvidence(by count: Int) {
        incrementLoss(.compactedCriticalEvidence, by: count)
    }

    private func pruneMetricPayloads(reserving byteCount: Int64) throws {
        while try metricLogicalBytes() + byteCount
            > configuration.metricCacheBytes
        {
            guard try removeOldestMetricPayload() else { break }
        }
    }

    private func reconcileMetricPayloads(now: Date) throws
        -> MetricReconciliation
    {
        switch metricDirectoryStatus() {
        case .absent:
            currentMetricCorruptRecordCount = 0
            return MetricReconciliation(attachments: [])
        case .invalidEntry:
            do {
                try rootDirectory.removeEntryIfPresent(
                    named: metricsDirectoryName
                )
                incrementLoss(.corruptRecord, by: 1)
                currentMetricCorruptRecordCount = 0
                try? saveMetadata()
                return MetricReconciliation(attachments: [])
            } catch {
                state.fileSinkDisabled = true
                currentMetricCorruptRecordCount = 1
                return MetricReconciliation(attachments: [])
            }
        case .ownedDirectory:
            break
        }
        guard let metricsDirectory else {
            throw DiagnosticStorageError.invalidRoot
        }
        let metricSnapshot = MetricKitExportEnvelopeReader.read(
            from: try metricEntryNames(),
            in: metricsDirectory,
            policy: MetricKitExportEnvelopeReadPolicy(
                cutoff: now.addingTimeInterval(
                    -configuration.retentionInterval
                ),
                now: now,
                maximumStoredEnvelopeBytes: max(
                    1024,
                    configuration.metricCacheBytes
                ),
                maximumSanitizedJSONBytes:
                configuration.maximumMetricPayloadBytes
            )
        )
        var currentCorruptRecordCount = 0
        for exclusion in metricSnapshot.exclusions {
            do {
                try metricsDirectory.removeEntryIfPresent(
                    named: exclusion.entryName
                )
                if exclusion.isCurrentCorruption {
                    incrementLoss(.corruptRecord, by: 1)
                }
            } catch {
                state.fileSinkDisabled = true
                if exclusion.isCurrentCorruption {
                    currentCorruptRecordCount += 1
                }
            }
        }
        currentMetricCorruptRecordCount = currentCorruptRecordCount
        if metricSnapshot.exclusions.isEmpty == false {
            do {
                try saveMetadata()
            } catch {
                state.fileSinkDisabled = true
            }
        }
        return MetricReconciliation(attachments: metricSnapshot.attachments)
    }

    private func pruneExpiredRecords(now: Date) throws {
        let cutoff = now.addingTimeInterval(-configuration.retentionInterval)
        for index in 0 ..< configuration.eventSegmentCount {
            let entryName = segmentName(index)
            guard try rootDirectory.entryInformation(named: entryName) != nil
            else { continue }
            let allLines = try rootDirectory.readFile(
                named: entryName,
                maximumByteCount: configuration.maximumPersistentBytes
            ).split(separator: 0x0A)
            var corruptCount = 0
            let retained = allLines.compactMap { line -> Data? in
                guard let record = try? Self.decoder.decode(
                    RecordedEvidence.self,
                    from: Data(line)
                ), Self.isValidPersistedRecord(record)
                else {
                    corruptCount += 1
                    return nil
                }
                guard record.timestamp >= cutoff else { return nil }
                var data = Data(line)
                data.append(0x0A)
                return data
            }
            incrementLoss(.corruptRecord, by: corruptCount)
            guard retained.count != allLines.count else { continue }
            if retained.isEmpty {
                try rootDirectory.removeEntryIfPresent(named: entryName)
                state.segmentPayloadBytes[index] = 0
                state.segmentRecordCounts[index] = 0
                state.segmentFirstSequences[index] = 0
            } else {
                let data = retained.reduce(into: Data()) { $0.append($1) }
                try writeDataAtomically(data, named: entryName)
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

    private func pruneExpiredEvidence(now: Date) throws {
        let cutoff = now.addingTimeInterval(-configuration.retentionInterval)
        pruneLossBuckets(cutoff: cutoff, now: now)

        try pruneExpiredRecords(now: now)
        _ = try reconcileMetricPayloads(now: now)
        activeOperations.removeAll { $0.updatedAt < cutoff }
        operationCapsules.removeAll { $0.finishedAt < cutoff }
        trimActiveOperations()
        trimCapsules()
    }

    private func migrateLegacyLossCounters(at timestamp: Date) {
        let legacy = LossCounts(
            droppedRecordCount: state.droppedRecordCount ?? 0,
            droppedCriticalRecordCount:
            state.droppedCriticalRecordCount ?? 0,
            compactedCriticalEvidenceCount:
            state.compactedCriticalEvidenceCount ?? 0,
            evictedMetricPayloadCount:
            state.evictedMetricPayloadCount ?? 0,
            corruptRecordCount: state.corruptRecordCount ?? 0,
            oversizedEventCount: state.oversizedEventCount ?? 0,
            oversizedMetricPayloadCount:
            state.oversizedMetricPayloadCount ?? 0,
            maximumObservedAllocatedBytes:
            state.maximumObservedAllocatedBytes ?? 0
        )
        state.droppedRecordCount = nil
        state.droppedCriticalRecordCount = nil
        state.compactedCriticalEvidenceCount = nil
        state.evictedMetricPayloadCount = nil
        state.corruptRecordCount = nil
        state.oversizedEventCount = nil
        state.oversizedMetricPayloadCount = nil
        state.maximumObservedAllocatedBytes = nil
        guard legacy.isEmpty == false else { return }
        mergeLossCounts(legacy, at: timestamp)
    }

    private func incrementLoss(_ kind: LossKind, by count: Int) {
        guard count > 0 else { return }
        var increment = LossCounts()
        switch kind {
        case .droppedRecord:
            increment.droppedRecordCount = count
        case .droppedCriticalRecord:
            increment.droppedCriticalRecordCount = count
        case .compactedCriticalEvidence:
            increment.compactedCriticalEvidenceCount = count
        case .evictedMetricPayload:
            increment.evictedMetricPayloadCount = count
        case .corruptRecord:
            increment.corruptRecordCount = count
        case .oversizedEvent:
            increment.oversizedEventCount = count
        case .oversizedMetricPayload:
            increment.oversizedMetricPayloadCount = count
        }
        mergeLossCounts(increment, at: now())
    }

    private func recordMaximumObservedAllocatedBytes(_ byteCount: Int64) {
        guard byteCount > 0 else { return }
        var observation = LossCounts()
        observation.maximumObservedAllocatedBytes = byteCount
        mergeLossCounts(observation, at: now())
    }

    private func mergeLossCounts(_ counts: LossCounts, at timestamp: Date) {
        let cutoff = timestamp.addingTimeInterval(
            -configuration.retentionInterval
        )
        pruneLossBuckets(cutoff: cutoff, now: timestamp)
        let dayStart = Self.utcCalendar.startOfDay(for: timestamp)
        var normalizedCounts = counts
        normalizedCounts.normalize()
        var buckets = state.lossBuckets ?? []
        if let index = buckets.firstIndex(where: {
            $0.utcDayStart == dayStart
        }) {
            buckets[index].counts.add(normalizedCounts)
            buckets[index].firstOccurredAt = min(
                buckets[index].firstOccurredAt ?? timestamp,
                timestamp
            )
            buckets[index].lastOccurredAt = max(
                buckets[index].lastOccurredAt ?? timestamp,
                timestamp
            )
        } else {
            buckets.append(
                LossBucket(
                    utcDayStart: dayStart,
                    firstOccurredAt: timestamp,
                    lastOccurredAt: timestamp,
                    counts: normalizedCounts
                )
            )
        }
        buckets.sort { $0.utcDayStart < $1.utcDayStart }
        if buckets.count > 8 {
            buckets.removeFirst(buckets.count - 8)
        }
        state.lossBuckets = buckets
    }

    private func pruneLossBuckets(cutoff: Date, now: Date) {
        let cutoffDayStart = Self.utcCalendar.startOfDay(for: cutoff)
        let oldestRetainedDay: Date = if cutoff == cutoffDayStart {
            cutoffDayStart
        } else {
            Self.utcCalendar.date(
                byAdding: .day,
                value: 1,
                to: cutoffDayStart
            ) ?? cutoffDayStart.addingTimeInterval(24 * 60 * 60)
        }
        let newestRetainedDay = Self.utcCalendar.startOfDay(for: now)
        let normalizedBuckets = (state.lossBuckets ?? []).compactMap {
            bucket -> LossBucket? in
            guard bucket.utcDayStart.timeIntervalSinceReferenceDate.isFinite,
                  bucket.firstOccurredAt?
                  .timeIntervalSinceReferenceDate.isFinite ?? true,
                  bucket.lastOccurredAt?
                  .timeIntervalSinceReferenceDate.isFinite ?? true
            else {
                return nil
            }
            var counts = bucket.counts
            counts.normalize()
            let dayStart = Self.utcCalendar.startOfDay(
                for: bucket.utcDayStart
            )
            let nextDay = Self.utcCalendar.date(
                byAdding: .day,
                value: 1,
                to: dayStart
            ) ?? dayStart.addingTimeInterval(24 * 60 * 60)
            let firstOccurredAt = bucket.firstOccurredAt ?? dayStart
            let lastOccurredAt = bucket.lastOccurredAt ?? firstOccurredAt
            guard bucket.utcDayStart == dayStart,
                  firstOccurredAt >= dayStart,
                  lastOccurredAt >= firstOccurredAt,
                  lastOccurredAt < nextDay,
                  lastOccurredAt <= now
            else {
                return nil
            }
            return LossBucket(
                utcDayStart: dayStart,
                firstOccurredAt: firstOccurredAt,
                lastOccurredAt: lastOccurredAt,
                counts: counts
            )
        }
        var byDay: [Date: LossBucket] = [:]
        for bucket in normalizedBuckets {
            if var existing = byDay[bucket.utcDayStart] {
                existing.counts.add(bucket.counts)
                existing.firstOccurredAt = min(
                    existing.firstOccurredAt ?? bucket.utcDayStart,
                    bucket.firstOccurredAt ?? bucket.utcDayStart
                )
                existing.lastOccurredAt = max(
                    existing.lastOccurredAt ?? bucket.utcDayStart,
                    bucket.lastOccurredAt ?? bucket.utcDayStart
                )
                byDay[bucket.utcDayStart] = existing
            } else {
                byDay[bucket.utcDayStart] = bucket
            }
        }
        var buckets = Array(byDay.values)
        buckets.removeAll {
            $0.utcDayStart < oldestRetainedDay
                || $0.utcDayStart > newestRetainedDay
        }
        if buckets.count > 8 {
            buckets = Array(buckets.sorted {
                $0.utcDayStart < $1.utcDayStart
            }.suffix(8))
        }
        state.lossBuckets = buckets
    }

    private var currentLossCounts: LossCounts {
        (state.lossBuckets ?? []).reduce(into: LossCounts()) {
            $0.add($1.counts)
        }
    }

    private func rebuildStateFromSegments() throws {
        var maximumSequence: UInt64 = 0
        for index in 0 ..< configuration.eventSegmentCount {
            let entryName = segmentName(index)
            guard try rootDirectory.entryInformation(named: entryName) != nil
            else {
                state.segmentPayloadBytes[index] = 0
                state.segmentRecordCounts[index] = 0
                state.segmentFirstSequences[index] = 0
                continue
            }
            let data = try rootDirectory.readFile(
                named: entryName,
                maximumByteCount: configuration.maximumPersistentBytes
            )
            let records = data.split(separator: 0x0A).compactMap {
                line -> RecordedEvidence? in
                guard let record = try? Self.decoder.decode(
                    RecordedEvidence.self,
                    from: Data(line)
                ), Self.isValidPersistedRecord(record)
                else { return nil }
                return record
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
        let (rebuiltNextSequence, overflow) = maximumSequence
            .addingReportingOverflow(1)
        guard overflow == false else {
            state.fileSinkDisabled = true
            return
        }
        state.nextSequence = max(state.nextSequence, rebuiltNextSequence)
        if state.nextSequence == .max {
            state.fileSinkDisabled = true
        }
    }

    private func readRecords() -> (
        records: [RecordedEvidence],
        corruptCount: Int
    ) {
        let cutoff = now().addingTimeInterval(
            -configuration.retentionInterval
        )
        var byEventID: [UUID: RecordedEvidence] = [:]
        var corruptCount = 0
        for index in 0 ..< configuration.eventSegmentCount {
            guard let data = try? rootDirectory.readFile(
                named: segmentName(index),
                maximumByteCount: configuration.maximumPersistentBytes
            ) else { continue }
            for line in data.split(separator: 0x0A) {
                guard let record = try? Self.decoder.decode(
                    RecordedEvidence.self,
                    from: Data(line)
                ), Self.isValidPersistedRecord(record)
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
        try removeAtomicTemporaryFiles()
        let activeData = try encodedMetadata(
            Array(activeOperations.suffix(8))
        )
        let capsuleData = try encodedMetadata(
            Array(operationCapsules.suffix(8))
        )
        var indexData = try encodedMetadata(state)
        var reservedBytes: Int64 = 0
        for _ in 0 ..< 3 {
            let requiredBytes = try atomicMetadataBudget(
                activeData: activeData,
                capsuleData: capsuleData,
                indexData: indexData
            )
            if requiredBytes > reservedBytes {
                try reserveCapacity(forAdditionalBytes: requiredBytes)
                reservedBytes = requiredBytes
                indexData = try encodedMetadata(state)
                continue
            }
            break
        }
        try writeDataAtomicallyPrepared(
            activeData,
            named: activeOperationsName
        )
        try writeDataAtomicallyPrepared(
            capsuleData,
            named: operationCapsulesName
        )
        indexData = try encodedMetadata(state)
        guard roundedAllocation(Int64(indexData.count)) <= reservedBytes else {
            throw DiagnosticStorageError.allocatedSizeUnavailable
        }
        try writeDataAtomicallyPrepared(indexData, named: indexName)
    }

    private func atomicMetadataBudget(
        activeData: Data,
        capsuleData: Data,
        indexData: Data
    ) throws -> Int64 {
        let replacements = [
            (activeOperationsName, activeData),
            (operationCapsulesName, capsuleData),
            (indexName, indexData)
        ]
        let allocations = replacements.map {
            roundedAllocation(Int64($0.1.count))
        }
        let replacementGrowth = try zip(replacements, allocations)
            .reduce(into: Int64(0)) { total, pair in
                let existing = try allocatedRootBytes(of: pair.0.0)
                let growth = max(0, pair.1 - existing)
                let (sum, overflow) = total.addingReportingOverflow(growth)
                guard overflow == false else {
                    throw DiagnosticStorageError.allocatedSizeUnavailable
                }
                total = sum
            }
        let maximumTemporary = allocations.max() ?? 0
        let (budget, overflow) = replacementGrowth.addingReportingOverflow(
            maximumTemporary
        )
        guard overflow == false else {
            throw DiagnosticStorageError.allocatedSizeUnavailable
        }
        return budget
    }

    private func encodedMetadata(_ value: some Encodable) throws -> Data {
        let data = try Self.encoder.encode(value)
        guard data.count <= 128 * 1024 else {
            throw DiagnosticStorageError.exportTooLarge
        }
        return data
    }

    private func writeDataAtomically(_ data: Data, named entryName: String) throws {
        try reserveCapacity(forAdditionalBytes: Int64(data.count))
        try writeDataAtomicallyPrepared(data, named: entryName)
    }

    private func writeDataAtomicallyPrepared(
        _ data: Data,
        named entryName: String
    ) throws {
        let temporaryName = ".\(entryName).\(UUID().uuidString).tmp"
        do {
            try writeData(data, named: temporaryName, in: rootDirectory)
            try rootDirectory.renameEntry(
                named: temporaryName,
                to: entryName
            )
            try rootDirectory.synchronize()
        } catch {
            try? rootDirectory.removeEntryIfPresent(named: temporaryName)
            throw error
        }
        try observeAllocatedBytes()
    }

    private func writeData(
        _ data: Data,
        named entryName: String,
        in directory: DiagnosticOwnedDirectory
    ) throws {
        try directory.writeNewFile(named: entryName, data: data)
        do {
            try observeAllocatedBytes()
        } catch {
            try? directory.removeEntryIfPresent(named: entryName)
            throw error
        }
    }

    private func removeAtomicTemporaryFiles() throws {
        for entryName in try atomicTemporaryEntryNames() {
            try rootDirectory.removeEntryIfPresent(named: entryName)
        }
    }

    private func observeAllocatedBytes() throws {
        let allocated = try allocatedBytes()
        recordMaximumObservedAllocatedBytes(allocated)
        guard allocated <= configuration.maximumPersistentBytes else {
            state.fileSinkDisabled = true
            throw DiagnosticStorageError.allocatedSizeUnavailable
        }
    }

    private func allocatedBytes() throws -> Int64 {
        var total: Int64 = 0
        for entryName in try managedRootEntryNames() {
            if let information = try rootDirectory.entryInformation(
                named: entryName
            ) {
                total = try addingAllocatedBytes(
                    information.allocatedByteCount,
                    to: total
                )
            }
        }
        if metricDirectoryStatus() == .ownedDirectory,
           let metricsDirectory
        {
            for entryName in try metricEntryNames() {
                guard let information = try metricsDirectory
                    .entryInformation(named: entryName)
                else { continue }
                total = try addingAllocatedBytes(
                    information.allocatedByteCount,
                    to: total
                )
            }
        }
        return total
    }

    private func allocatedRootBytes(of entryName: String) throws -> Int64 {
        try rootDirectory.entryInformation(named: entryName)?
            .allocatedByteCount ?? 0
    }

    private func logicalBytes() throws -> Int64 {
        var total: Int64 = 0
        for entryName in try managedRootEntryNames() {
            guard let information = try rootDirectory.entryInformation(
                named: entryName
            ) else { continue }
            total = try addingAllocatedBytes(
                information.logicalByteCount,
                to: total
            )
        }
        if metricDirectoryStatus() == .ownedDirectory,
           let metricsDirectory
        {
            for entryName in try metricEntryNames() {
                guard let information = try metricsDirectory
                    .entryInformation(named: entryName)
                else { continue }
                total = try addingAllocatedBytes(
                    information.logicalByteCount,
                    to: total
                )
            }
        }
        return total
    }

    private func metricLogicalBytes() throws -> Int64 {
        guard metricDirectoryStatus() == .ownedDirectory,
              let metricsDirectory
        else { return 0 }
        return try metricEntryNames().reduce(into: Int64(0)) {
            guard let information = try metricsDirectory.entryInformation(
                named: $1
            ) else { return }
            $0 = try addingAllocatedBytes(
                information.logicalByteCount,
                to: $0
            )
        }
    }

    private func roundedAllocation(_ byteCount: Int64) -> Int64 {
        let blockSize = rootDirectory.fileSystemBlockSize() ?? 4096
        return ((max(1, byteCount) + blockSize - 1) / blockSize)
            * blockSize
    }

    private func addingAllocatedBytes(
        _ byteCount: Int64,
        to total: Int64
    ) throws -> Int64 {
        let (sum, overflow) = total.addingReportingOverflow(byteCount)
        guard overflow == false, sum >= 0 else {
            throw DiagnosticStorageError.allocatedSizeUnavailable
        }
        return sum
    }

    private func managedRootEntryNames() throws -> [String] {
        managedRootFixedEntryNames + (try atomicTemporaryEntryNames())
    }

    private var managedRootFixedEntryNames: [String] {
        [indexName, activeOperationsName, operationCapsulesName]
            + (0 ..< configuration.eventSegmentCount).map(segmentName)
    }

    private func atomicTemporaryEntryNames() throws -> [String] {
        let targets = managedRootFixedEntryNames
        return try rootDirectory.entryNames().filter { entryName in
            targets.contains { target in
                if entryName == ".\(target).tmp" { return true }
                let prefix = ".\(target)."
                guard entryName.hasPrefix(prefix),
                      entryName.hasSuffix(".tmp")
                else { return false }
                let uuidStart = entryName.index(
                    entryName.startIndex,
                    offsetBy: prefix.count
                )
                let uuidEnd = entryName.index(
                    entryName.endIndex,
                    offsetBy: -".tmp".count
                )
                return UUID(uuidString: String(entryName[uuidStart ..< uuidEnd]))
                    != nil
            }
        }
    }

    private func metricEntryNames() throws -> [String] {
        guard metricDirectoryStatus() == .ownedDirectory else {
            return []
        }
        guard let metricsDirectory else {
            throw DiagnosticStorageError.invalidRoot
        }
        return try metricsDirectory.entryNames()
            .filter(isMetricCandidateName)
            .sorted()
    }

    private func metricDirectoryStatus() -> ManagedDirectoryStatus {
        if metricsDirectory != nil { return .ownedDirectory }
        do {
            metricsDirectory = try rootDirectory.openChildDirectory(
                named: metricsDirectoryName,
                createIfMissing: false,
                permissions: 0o700
            )
            return metricsDirectory == nil ? .absent : .ownedDirectory
        } catch {
            return .invalidEntry
        }
    }

    private func prepareMetricsDirectory() throws -> DiagnosticOwnedDirectory {
        switch metricDirectoryStatus() {
        case .ownedDirectory:
            guard let metricsDirectory else {
                throw DiagnosticStorageError.invalidRoot
            }
            return metricsDirectory
        case .absent:
            guard let directory = try rootDirectory.openChildDirectory(
                named: metricsDirectoryName,
                createIfMissing: true,
                permissions: 0o700
            ) else {
                throw DiagnosticStorageError.invalidRoot
            }
            metricsDirectory = directory
            return directory
        case .invalidEntry:
            throw DiagnosticStorageError.invalidRoot
        }
    }

    private func metricModificationDate(of entryName: String) throws -> Date {
        guard let metricsDirectory,
              let information = try metricsDirectory.entryInformation(
                  named: entryName
              )
        else { return .distantPast }
        return information.modificationDate
    }

    private func isMetricCandidateName(_ entryName: String) -> Bool {
        entryName.hasPrefix("metric-")
            && entryName.hasSuffix(".json")
    }

    private func segmentName(_ index: Int) -> String {
        String(format: "events-%02d.ndjson", index)
    }

    private var indexName: String {
        "index.json"
    }

    private var activeOperationsName: String {
        "active-operations.json"
    }

    private var operationCapsulesName: String {
        "operation-capsules.json"
    }

    private var metricsDirectoryName: String {
        "metrics"
    }

    private static func loadJSON<T: Decodable>(
        _ type: T.Type,
        named entryName: String,
        in directory: DiagnosticOwnedDirectory
    ) -> T? {
        guard let data = try? directory.readFile(
            named: entryName,
            maximumByteCount: 128 * 1024
        )
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
        var normalizedState = state
        if normalizedState.nextSequence == 0
            || normalizedState.nextSequence == .max
        {
            normalizedState.fileSinkDisabled = true
        }
        return normalizedState
    }

    private static func isValidPersistedRecord(
        _ record: RecordedEvidence
    ) -> Bool {
        record.schemaVersion == RecordedEvidence.currentSchemaVersion
            && record.sequence > 0
            && record.sequence < .max
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
}
