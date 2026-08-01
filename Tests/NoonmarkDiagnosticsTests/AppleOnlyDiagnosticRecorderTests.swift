import Foundation
@testable import NoonmarkDiagnostics
import XCTest

final class AppleOnlyDiagnosticRecorderTests: XCTestCase {
    func testMissingBundleIdentityUsesANonproductionUnifiedLogSubsystem() {
        XCTAssertEqual(
            DiagnosticSubsystemIdentity.resolve(bundleIdentifier: nil),
            "app.noonmark.invalid-runtime"
        )
        XCTAssertEqual(
            DiagnosticSubsystemIdentity.resolve(
                bundleIdentifier: "app.noonmark.mac.e2e"
            ),
            "app.noonmark.mac.e2e"
        )
    }

    func testFallbackRecorderKeepsTypedRecordingAvailableWithoutDiskStorage() {
        let sessionID = DiagnosticSessionID(rawValue: UUID())
        let recorder: any DiagnosticRecording = AppleOnlyDiagnosticRecorder(
            sessionID: sessionID,
            subsystem: "app.noonmark.tests"
        )

        recorder.record(.sessionStarted(), at: Date(timeIntervalSince1970: 10))
        let operation = recorder.startOperation(
            kind: .persistence,
            at: Date(timeIntervalSince1970: 11)
        )
        operation.fail(
            DiagnosticFailure(domain: .cocoa, code: 513),
            at: Date(timeIntervalSince1970: 12)
        )

        XCTAssertEqual(recorder.sessionID, sessionID)
    }
}
