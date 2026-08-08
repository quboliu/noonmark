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

    func testIncrementalTransportFailuresHaveStableSafeCodes() {
        let producerCanary = "PRIVATE-ACCOUNT-NAME-7Q9X"
        let expected: [(SyncRecordTransportError, Int)] = [
            (.invalidFrontier, 203),
            (.frontierDidNotAdvance, 204),
            (.repositoryFormatMismatch, 205),
            (
                .producerFork(
                    producerID: producerCanary,
                    sequence: 7
                ),
                206
            ),
            (
                .missingBatch(
                    producerID: producerCanary,
                    sequence: 8
                ),
                207
            ),
            (
                .invalidBatchHash(
                    producerID: producerCanary,
                    sequence: 9
                ),
                208
            )
        ]

        for (error, code) in expected {
            let failure = error.diagnosticFailure
            XCTAssertEqual(
                failure,
                DiagnosticFailure(domain: .syncProtocol, code: code)
            )
            let evidence = EvidenceEvent.persistenceFailed(
                failure: failure,
                incidentID: DiagnosticIncidentID()
            )
            XCTAssertFalse(
                DiagnosticEvidenceTextRenderer.render([evidence])
                    .contains(producerCanary)
            )
        }
    }

    func testMergeFailureReasonsHaveStableSafeCodes() {
        let expected: [SyncRecordMergeFailureReason: Int] = [
            .unknown: 202,
            .inconsistentRecordHeaders: 250,
            .invalidContentClock: 251,
            .taskCycleSeriesIdentityCollision: 252,
            .taskChainIdentityCollision: 253,
            .taskDefinitionIdentityCollision: 254,
            .dayTraceIdentityCollision: 255,
            .invalidReactivationWitnesses: 256,
            .invalidNoteEntries: 257,
            .noteEntryCreatedAtCollision: 258,
            .invalidRecordPayload: 259
        ]

        XCTAssertEqual(
            Set(SyncRecordMergeFailureReason.allCases),
            Set(expected.keys)
        )
        for (reason, code) in expected {
            XCTAssertEqual(
                SyncRecordTransportError.invalidCurrentRecordMerge(
                    recordID: SyncRecordID("day:2026-08-04"),
                    reason: reason
                )
                .diagnosticFailure,
                DiagnosticFailure(domain: .syncProtocol, code: code),
                "\(reason.rawValue) 必须有稳定诊断码"
            )
        }
    }

    func testMergeFailureReasonDoesNotLeakRecordIdentity() {
        let canary = "PRIVATE-TASK-TITLE-7Q9X"
        let failure = SyncRecordTransportError.invalidCurrentRecordMerge(
            recordID: SyncRecordID(canary),
            reason: .invalidContentClock
        )
        .diagnosticFailure
        let event = EvidenceEvent.persistenceFailed(
            failure: failure,
            incidentID: DiagnosticIncidentID()
        )

        XCTAssertEqual(
            failure,
            DiagnosticFailure(domain: .syncProtocol, code: 251)
        )
        XCTAssertFalse(
            DiagnosticEvidenceTextRenderer.render([event]).contains(canary)
        )
    }
}
