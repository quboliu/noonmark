import NoonmarkDiagnostics
@testable import NoonmarkSync
import XCTest

final class DiagnosticFailureMappingTests: XCTestCase {
    func testICloudEndpointFailuresHaveStableSafeCodes() {
        XCTAssertEqual(
            ICloudDriveSyncTransportError.accountUnavailable
                .diagnosticFailure,
            DiagnosticFailure(domain: .syncProtocol, code: 102)
        )
        XCTAssertEqual(
            ICloudDriveSyncTransportError.driveUnavailable
                .diagnosticFailure,
            DiagnosticFailure(domain: .syncProtocol, code: 103)
        )
    }

    func testCloudKitAssociatedTextDoesNotCrossMappingBoundary() {
        let canary = "PRIVATE-TASK-TITLE-7Q9X"
        let failure = CloudKitSyncEngineTransportError
            .cloudKitFailure(canary).diagnosticFailure
        let event = EvidenceEvent.persistenceFailed(
            failure: failure,
            incidentID: DiagnosticIncidentID()
        )

        XCTAssertEqual(
            failure,
            DiagnosticFailure(domain: .cloudKit, code: 309)
        )
        XCTAssertFalse(
            DiagnosticEvidenceTextRenderer.render([event]).contains(canary)
        )
    }

    func testRecordIdentityDoesNotCrossTransportFailureMapping() {
        let canary = "PRIVATE-TASK-TITLE-7Q9X"
        let failure = SyncRecordTransportError.immutableRecordCollision(
            recordID: SyncRecordID(canary)
        )
        .diagnosticFailure

        XCTAssertEqual(
            failure,
            DiagnosticFailure(domain: .syncProtocol, code: 201)
        )
    }
}
