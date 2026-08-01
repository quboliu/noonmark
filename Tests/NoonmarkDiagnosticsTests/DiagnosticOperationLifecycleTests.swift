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
                byteCount: 1_024
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
        XCTAssertEqual(records[1].event.progress?.byteCount, 1_024)
        XCTAssertEqual(records[2].event.incidentID, incidentID)
        XCTAssertEqual(records[2].event.failure?.domain, .posix)
        XCTAssertEqual(records[2].event.failure?.code, 60)
        XCTAssertEqual(records[2].event.durationMilliseconds, 2_000)
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
}
