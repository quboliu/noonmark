import Foundation

public protocol DiagnosticRecording: Sendable {
    var sessionID: DiagnosticSessionID { get }

    func record(_ event: EvidenceEvent, at timestamp: Date)
}

public extension DiagnosticRecording {
    func record(_ event: EvidenceEvent) {
        record(event, at: Date())
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
    public let id: DiagnosticOperationID

    private let recorder: any DiagnosticRecording
    private let kind: DiagnosticOperationKind
    private let startedAt: Date
    private let state: State

    fileprivate init(
        recorder: any DiagnosticRecording,
        id: DiagnosticOperationID,
        kind: DiagnosticOperationKind,
        startedAt: Date
    ) {
        self.recorder = recorder
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        state = State()
    }

    public func stage(
        _ stage: DiagnosticOperationStage,
        progress: DiagnosticProgress? = nil,
        durationMilliseconds: Int64? = nil,
        at timestamp: Date = Date()
    ) {
        guard state.move(to: stage) else { return }
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

    public func heartbeat(
        stage: DiagnosticOperationStage,
        progress: DiagnosticProgress? = nil,
        at timestamp: Date = Date()
    ) {
        guard state.isActive else { return }
        recorder.record(
            .operationHeartbeat(
                id: id,
                kind: kind,
                stage: stage,
                progress: progress,
                durationMilliseconds: elapsedMilliseconds(at: timestamp)
            ),
            at: timestamp
        )
    }

    public func succeed(
        progress: DiagnosticProgress? = nil,
        at timestamp: Date = Date()
    ) {
        guard state.finish(incidentID: nil) else { return }
        recorder.record(
            .operationSucceeded(
                id: id,
                kind: kind,
                durationMilliseconds: elapsedMilliseconds(at: timestamp),
                progress: progress
            ),
            at: timestamp
        )
    }

    @discardableResult
    public func fail(
        _ failure: DiagnosticFailure,
        at timestamp: Date = Date()
    ) -> DiagnosticIncidentID {
        let incidentID = DiagnosticIncidentID()
        guard state.finish(incidentID: incidentID) else {
            return state.incidentID ?? incidentID
        }
        recorder.record(
            .operationFailed(
                id: id,
                incidentID: incidentID,
                kind: kind,
                failure: failure,
                durationMilliseconds: elapsedMilliseconds(at: timestamp),
                stage: state.lastStage
            ),
            at: timestamp
        )
        return incidentID
    }

    private func elapsedMilliseconds(at timestamp: Date) -> Int64 {
        let seconds = max(0, timestamp.timeIntervalSince(startedAt))
        let milliseconds = seconds * 1_000
        guard milliseconds < Double(Int64.max) else { return Int64.max }
        return Int64(milliseconds.rounded())
    }
}

private extension DiagnosticOperation {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var terminal = false
        private var storedLastStage: DiagnosticOperationStage?
        private var storedIncidentID: DiagnosticIncidentID?

        var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return terminal == false
        }

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

        func move(to stage: DiagnosticOperationStage) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard terminal == false else { return false }
            storedLastStage = stage
            return true
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
