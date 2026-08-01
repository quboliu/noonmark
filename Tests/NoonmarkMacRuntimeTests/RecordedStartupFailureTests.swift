import NoonmarkDiagnostics
@testable import NoonmarkMacRuntime
import XCTest

final class RecordedStartupFailureTests: XCTestCase {
    func testResolverCarriesRecordedIncidentToPresentationWithoutRecordingAgain() throws {
        let recorder = InMemoryDiagnosticRecorder()
        let diagnosticFailure = DiagnosticFailure(
            domain: .sqlite,
            code: 14
        )
        let operation = recorder.startOperation(kind: .persistence)
        operation.stage(.localLoad)
        let incidentID = operation.fail(diagnosticFailure)
        let failure = RecordedStartupFailure(
            diagnosticFailure: diagnosticFailure,
            diagnosticIncidentID: incidentID
        )
        let recordedEvidenceCount = recorder.snapshot().count
        var fallbackRecordingCount = 0

        let presentationIncidentID = StartupFailureIncidentResolver.resolve(
            for: failure
        ) {
            fallbackRecordingCount += 1
            return DiagnosticIncidentID()
        }

        XCTAssertEqual(presentationIncidentID, incidentID)
        XCTAssertEqual(fallbackRecordingCount, 0)
        XCTAssertEqual(failure.diagnosticFailure, diagnosticFailure)
        XCTAssertEqual(recorder.snapshot().count, recordedEvidenceCount)
    }

    func testResolverRecordsUnrecordedStartupFailureExactlyOnce() {
        let expectedIncidentID = DiagnosticIncidentID()
        var fallbackRecordingCount = 0

        let presentationIncidentID = StartupFailureIncidentResolver.resolve(
            for: UnrecordedTestFailure()
        ) {
            fallbackRecordingCount += 1
            return expectedIncidentID
        }

        XCTAssertEqual(presentationIncidentID, expectedIncidentID)
        XCTAssertEqual(fallbackRecordingCount, 1)
    }
}

private struct UnrecordedTestFailure: Error {}
