import Foundation

public protocol DiagnosticRecording: Sendable {
    var sessionID: DiagnosticSessionID { get }

    func record(_ event: EvidenceEvent, at timestamp: Date)

    func persistedSyncFailureCorrelation(
        failure: DiagnosticFailure,
        failedAt: Date
    ) async -> DiagnosticOperationCorrelation?

    func latestInterruptedOperation(
        kind: DiagnosticOperationKind
    ) async -> DiagnosticOperationCapsule?
}

public extension DiagnosticRecording {
    func record(_ event: EvidenceEvent) {
        record(event, at: Date())
    }

    func persistedSyncFailureCorrelation(
        failure _: DiagnosticFailure,
        failedAt _: Date
    ) async -> DiagnosticOperationCorrelation? {
        nil
    }

    func latestInterruptedOperation(
        kind _: DiagnosticOperationKind
    ) async -> DiagnosticOperationCapsule? {
        nil
    }

    func startOperation(
        kind: DiagnosticOperationKind,
        endpoint: DiagnosticEndpoint = .none,
        at startedAt: Date = Date()
    ) -> DiagnosticOperation {
        let operationID = DiagnosticOperationID()
        record(
            .operationStarted(
                id: operationID,
                kind: kind,
                endpoint: endpoint
            ),
            at: startedAt
        )
        return DiagnosticOperation(
            recorder: self,
            id: operationID,
            kind: kind,
            endpoint: endpoint,
            startedAt: startedAt
        )
    }
}

public final class InMemoryDiagnosticRecorder: DiagnosticRecording, @unchecked Sendable {
    public let sessionID: DiagnosticSessionID

    private let lock = NSLock()
    private var nextSequence: UInt64 = 1
    private var records: [RecordedEvidence] = []

    public init(sessionID: DiagnosticSessionID = DiagnosticSessionID()) {
        self.sessionID = sessionID
    }

    public func record(_ event: EvidenceEvent, at timestamp: Date) {
        lock.lock()
        defer { lock.unlock() }
        records.append(
            RecordedEvidence(
                sequence: nextSequence,
                timestamp: timestamp,
                sessionID: sessionID,
                event: event
            )
        )
        nextSequence += 1
    }

    public func snapshot() -> [RecordedEvidence] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

public struct DiagnosticOperation: Sendable {
    public static let minimumHeartbeatInterval: TimeInterval = 30

    public let id: DiagnosticOperationID

    private let recorder: any DiagnosticRecording
    private let kind: DiagnosticOperationKind
    private let endpoint: DiagnosticEndpoint
    private let startedAt: Date
    private let state: State
    private let emissionLane: EmissionLane

    fileprivate init(
        recorder: any DiagnosticRecording,
        id: DiagnosticOperationID,
        kind: DiagnosticOperationKind,
        endpoint: DiagnosticEndpoint,
        startedAt: Date
    ) {
        self.recorder = recorder
        self.id = id
        self.kind = kind
        self.endpoint = endpoint
        self.startedAt = startedAt
        state = State()
        emissionLane = EmissionLane()
    }

    public func stage(
        _ stage: DiagnosticOperationStage,
        progress: DiagnosticProgress? = nil,
        durationMilliseconds: Int64? = nil,
        at timestamp: Date = Date()
    ) {
        emissionLane.perform {
            guard state.move(to: stage, progress: progress) else { return }
            recorder.record(
                .operationStage(
                    id: id,
                    kind: kind,
                    stage: stage,
                    progress: progress,
                    durationMilliseconds: durationMilliseconds
                ),
                at: timestamp
            )
        }
    }

    public func heartbeat(
        at timestamp: Date = Date()
    ) {
        emissionLane.perform {
            let durationMilliseconds = elapsedMilliseconds(at: timestamp)
            guard durationMilliseconds >= Int64(
                Self.minimumHeartbeatInterval * 1000
            ),
                let snapshot = state.heartbeatSnapshot(
                    at: timestamp,
                    minimumInterval: Self.minimumHeartbeatInterval
                )
            else { return }
            recorder.record(
                .operationHeartbeat(
                    id: id,
                    kind: kind,
                    stage: snapshot.stage,
                    progress: snapshot.progress,
                    durationMilliseconds: durationMilliseconds
                ),
                at: timestamp
            )
        }
    }

    public func observeHeartbeatProgress(
        _ progress: DiagnosticProgress
    ) {
        state.observeHeartbeatProgress(progress)
    }

    public func succeed(
        progress: DiagnosticProgress? = nil,
        at timestamp: Date = Date()
    ) {
        emissionLane.perform {
            guard state.finish(incidentID: nil) else { return }
            recorder.record(
                .operationSucceeded(
                    id: id,
                    kind: kind,
                    endpoint: endpoint,
                    durationMilliseconds: elapsedMilliseconds(at: timestamp),
                    progress: progress
                ),
                at: timestamp
            )
        }
    }

    @discardableResult
    public func fail(
        _ failure: DiagnosticFailure,
        detail failureDetail: DiagnosticFailure? = nil,
        at timestamp: Date = Date()
    ) -> DiagnosticIncidentID {
        emissionLane.perform {
            let incidentID = DiagnosticIncidentID()
            guard state.finish(incidentID: incidentID) else {
                return state.incidentID ?? incidentID
            }
            recorder.record(
                .operationFailed(
                    id: id,
                    incidentID: incidentID,
                    kind: kind,
                    endpoint: endpoint,
                    failure: failure,
                    failureDetail: failureDetail == failure
                        ? nil
                        : failureDetail,
                    durationMilliseconds: elapsedMilliseconds(at: timestamp),
                    stage: state.lastStage
                ),
                at: timestamp
            )
            return incidentID
        }
    }

    public func failWithCorrelation(
        _ failure: DiagnosticFailure,
        detail failureDetail: DiagnosticFailure? = nil,
        at timestamp: Date = Date()
    ) -> DiagnosticOperationCorrelation {
        DiagnosticOperationCorrelation(
            operationID: id,
            incidentID: fail(
                failure,
                detail: failureDetail,
                at: timestamp
            )
        )
    }

    private func elapsedMilliseconds(at timestamp: Date) -> Int64 {
        let seconds = max(0, timestamp.timeIntervalSince(startedAt))
        let milliseconds = seconds * 1000
        guard milliseconds < Double(Int64.max) else { return Int64.max }
        return Int64(milliseconds.rounded())
    }
}

private extension DiagnosticOperation {
    final class EmissionLane: @unchecked Sendable {
        private let lock = NSLock()

        func perform<Result>(_ body: () -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    struct HeartbeatSnapshot: Equatable {
        let stage: DiagnosticOperationStage
        let progress: DiagnosticProgress?
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var terminal = false
        private var storedLastStage: DiagnosticOperationStage?
        private var storedLastProgress: DiagnosticProgress?
        private var storedIncidentID: DiagnosticIncidentID?
        private var heartbeatEvidenceSnapshot: HeartbeatSnapshot?
        private var heartbeatProgressChanged = false
        private var lastHeartbeatAt: Date?

        var lastStage: DiagnosticOperationStage? {
            lock.lock()
            defer { lock.unlock() }
            return storedLastStage
        }

        var incidentID: DiagnosticIncidentID? {
            lock.lock()
            defer { lock.unlock() }
            return storedIncidentID
        }

        func move(
            to stage: DiagnosticOperationStage,
            progress: DiagnosticProgress?
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard terminal == false else { return false }
            storedLastStage = stage
            storedLastProgress = progress
            heartbeatEvidenceSnapshot = HeartbeatSnapshot(
                stage: stage,
                progress: progress
            )
            heartbeatProgressChanged = false
            return true
        }

        func observeHeartbeatProgress(_ progress: DiagnosticProgress) {
            lock.lock()
            defer { lock.unlock() }
            guard terminal == false,
                  let stage = storedLastStage
            else { return }
            storedLastProgress = progress
            let snapshot = HeartbeatSnapshot(
                stage: stage,
                progress: progress
            )
            heartbeatProgressChanged = snapshot
                != heartbeatEvidenceSnapshot
        }

        func heartbeatSnapshot(
            at timestamp: Date,
            minimumInterval: TimeInterval
        ) -> HeartbeatSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            guard terminal == false,
                  let stage = storedLastStage,
                  heartbeatProgressChanged
            else { return nil }
            if let lastHeartbeatAt,
               timestamp.timeIntervalSince(lastHeartbeatAt)
               < minimumInterval
            {
                return nil
            }
            let snapshot = HeartbeatSnapshot(
                stage: stage,
                progress: storedLastProgress
            )
            guard snapshot != heartbeatEvidenceSnapshot else {
                heartbeatProgressChanged = false
                return nil
            }
            heartbeatEvidenceSnapshot = snapshot
            heartbeatProgressChanged = false
            lastHeartbeatAt = timestamp
            return snapshot
        }

        func finish(incidentID: DiagnosticIncidentID?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard terminal == false else { return false }
            terminal = true
            storedIncidentID = incidentID
            return true
        }
    }
}
