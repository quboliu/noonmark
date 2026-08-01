import NoonmarkDiagnostics
@testable import NoonmarkSync
import XCTest

final class DiagnosticFailureMappingTests: XCTestCase {
    func testICloudEndpointFailuresHaveStableSafeCodes() {
        XCTAssertEqual(
            DiagnosticFailureClassifier.classify(
                ICloudDriveSyncTransportError.accountUnavailable
            ),
            DiagnosticFailure(domain: .syncProtocol, code: 102)
        )
        XCTAssertEqual(
            DiagnosticFailureClassifier.classify(
                ICloudDriveSyncTransportError.driveUnavailable
            ),
            DiagnosticFailure(domain: .syncProtocol, code: 103)
        )
    }

    func testCloudKitAssociatedTextDoesNotCrossMappingBoundary() {
        let canary = "PRIVATE-TASK-TITLE-7Q9X"
        let failure = DiagnosticFailureClassifier.classify(
            CloudKitSyncEngineTransportError.cloudKitFailure(canary)
        )
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
        let failure = DiagnosticFailureClassifier.classify(
            SyncRecordTransportError.immutableRecordCollision(
                recordID: SyncRecordID(canary)
            )
        )

        XCTAssertEqual(
            failure,
            DiagnosticFailure(domain: .syncProtocol, code: 201)
        )
    }
}
