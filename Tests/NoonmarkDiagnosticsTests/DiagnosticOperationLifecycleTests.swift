@testable import NoonmarkDiagnostics
import XCTest

final class DiagnosticOperationLifecycleTests: XCTestCase {
    func testOperationEmitsOneCorrelatedLifecycleWithoutUserContent() throws {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = InMemoryDiagnosticRecorder(
            sessionID: DiagnosticSessionID(
                rawValue: try XCTUnwrap(
                    UUID(uuidString: "00000000-0000-0000-0000-000000000001")
                )
            )
        )

        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive,
            at: startedAt
        )
        operation.stage(
            .transportFetch,
            progress: DiagnosticProgress(
                recordCount: 8,
                byteCount: 1024
            ),
            at: startedAt.addingTimeInterval(1)
        )
        let incidentID = operation.fail(
            DiagnosticFailure(domain: .posix, code: 60),
            at: startedAt.addingTimeInterval(2)
        )

        let records = recorder.snapshot()
        XCTAssertEqual(
            records.map(\.event.code),
            [.operationStarted, .operationStage, .operationFailed]
        )
        XCTAssertEqual(Set(records.map(\.sessionID)), [recorder.sessionID])
        XCTAssertEqual(Set(records.compactMap(\.event.operationID)).count, 1)
        XCTAssertEqual(records[1].event.stage, .transportFetch)
        XCTAssertEqual(records[1].event.progress?.recordCount, 8)
        XCTAssertEqual(records[1].event.progress?.byteCount, 1024)
        XCTAssertEqual(records[2].event.incidentID, incidentID)
        XCTAssertEqual(records[2].event.failure?.domain, .posix)
        XCTAssertEqual(records[2].event.failure?.code, 60)
        XCTAssertEqual(records[2].event.durationMilliseconds, 2000)
    }

    func testOperationPublishesOnlyOneTerminalEvent() {
        let recorder = InMemoryDiagnosticRecorder()
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .localFolder
        )

        operation.succeed()
        operation.fail(DiagnosticFailure(domain: .unknown, code: 0))

        XCTAssertEqual(
            recorder.snapshot().filter { $0.event.code.isTerminal }.count,
            1
        )
    }

    func testHeartbeatRequiresThresholdAndChangedTypedProgress() {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = InMemoryDiagnosticRecorder()
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive,
            at: startedAt
        )

        operation.stage(
            .transportFetch,
            progress: DiagnosticProgress(recordCount: 2),
            at: startedAt.addingTimeInterval(1)
        )
        operation.heartbeat(
            at: startedAt.addingTimeInterval(29)
        )
        operation.heartbeat(
            at: startedAt.addingTimeInterval(30)
        )
        operation.observeHeartbeatProgress(
            DiagnosticProgress(recordCount: 3)
        )
        operation.heartbeat(
            at: startedAt.addingTimeInterval(31)
        )
        operation.observeHeartbeatProgress(
            DiagnosticProgress(recordCount: 3)
        )
        operation.heartbeat(
            at: startedAt.addingTimeInterval(32)
        )
        operation.observeHeartbeatProgress(
            DiagnosticProgress(recordCount: 4)
        )
        operation.heartbeat(
            at: startedAt.addingTimeInterval(60)
        )
        operation.heartbeat(
            at: startedAt.addingTimeInterval(61)
        )
        operation.succeed(at: startedAt.addingTimeInterval(62))
        operation.heartbeat(
            at: startedAt.addingTimeInterval(92)
        )

        let records = recorder.snapshot()
        XCTAssertEqual(
            records.map(\.event.code),
            [
                .operationStarted,
                .operationStage,
                .operationHeartbeat,
                .operationHeartbeat,
                .operationSucceeded
            ]
        )
        let heartbeats = records.filter {
            $0.event.code == .operationHeartbeat
        }
        XCTAssertEqual(
            heartbeats.map(\.event.durationMilliseconds),
            [31000, 61000]
        )
        XCTAssertEqual(
            heartbeats.map { $0.event.progress?.recordCount },
            [3, 4]
        )
        XCTAssertEqual(
            Set(heartbeats.compactMap(\.event.operationID)),
            [operation.id]
        )
    }

    func testConcurrentTerminalCannotBeRecordedBeforeAcceptedHeartbeat()
        async
    {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = TerminalRaceDiagnosticRecorder()
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            at: startedAt
        )
        operation.stage(.upload)
        operation.observeHeartbeatProgress(
            DiagnosticProgress(recordCount: 1)
        )

        let heartbeatTask = Task.detached {
            operation.heartbeat(
                at: startedAt.addingTimeInterval(31)
            )
        }
        XCTAssertEqual(
            recorder.waitUntilHeartbeatIsRecording(),
            .success
        )
        let failureTask = Task.detached {
            operation.fail(
                DiagnosticFailure(domain: .syncProtocol, code: 7),
                at: startedAt.addingTimeInterval(32)
            )
        }

        await heartbeatTask.value
        _ = await failureTask.value

        XCTAssertEqual(
            recorder.snapshot().suffix(2).map(\.event.code),
            [.operationHeartbeat, .operationFailed]
        )
    }

    func testPersistedFailureLoadedCarriesRecoveredCorrelation() {
        let operationID = DiagnosticOperationID()
        let incidentID = DiagnosticIncidentID()
        let event = EvidenceEvent.persistedSyncFailureLoaded(
            failure: DiagnosticFailure(domain: .syncProtocol, code: 7),
            operationID: operationID,
            incidentID: incidentID
        )

        XCTAssertEqual(event.operationID, operationID)
        XCTAssertEqual(event.incidentID, incidentID)
        XCTAssertEqual(event.failure?.domain, .syncProtocol)
        XCTAssertEqual(event.failure?.code, 7)
    }

    func testOperationFailureKeepsCanonicalFailureAndTypedDetail() throws {
        let recorder = InMemoryDiagnosticRecorder()
        let operation = recorder.startOperation(kind: .localFirstSync)
        let incidentID = operation.fail(
            DiagnosticFailure(domain: .syncProtocol, code: 7),
            detail: DiagnosticFailure(domain: .posix, code: 60)
        )

        let terminal = try XCTUnwrap(recorder.snapshot().last)
        XCTAssertEqual(terminal.event.incidentID, incidentID)
        XCTAssertEqual(
            terminal.event.failure,
            DiagnosticFailure(domain: .syncProtocol, code: 7)
        )
        XCTAssertEqual(
            terminal.event.failureDetail,
            DiagnosticFailure(domain: .posix, code: 60)
        )
    }
}

private final class TerminalRaceDiagnosticRecorder:
    DiagnosticRecording,
    @unchecked Sendable
{
    let sessionID = DiagnosticSessionID()

    private let lock = NSLock()
    private let heartbeatStarted = DispatchSemaphore(value: 0)
    private let terminalRecorded = DispatchSemaphore(value: 0)
    private var nextSequence: UInt64 = 1
    private var records: [RecordedEvidence] = []

    func record(_ event: EvidenceEvent, at timestamp: Date) {
        if event.code == .operationHeartbeat {
            heartbeatStarted.signal()
            _ = terminalRecorded.wait(timeout: .now() + 0.5)
        }
        lock.lock()
        records.append(
            RecordedEvidence(
                sequence: nextSequence,
                timestamp: timestamp,
                sessionID: sessionID,
                event: event
            )
        )
        nextSequence += 1
        lock.unlock()
        if event.code.isTerminal {
            terminalRecorded.signal()
        }
    }

    func waitUntilHeartbeatIsRecording() -> DispatchTimeoutResult {
        heartbeatStarted.wait(timeout: .now() + 1)
    }

    func snapshot() -> [RecordedEvidence] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}
