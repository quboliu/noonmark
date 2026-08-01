import Foundation
@testable import NoonmarkDiagnostics
import XCTest

final class DiagnosticRecordingBootstrapTests: XCTestCase {
    func testProductionPreparationFallsBackToAppleOnlyRecorder() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-diagnostic-bootstrap-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data("not-a-directory".utf8).write(to: rootURL)

        let bootstrap = await DiagnosticRecordingBootstrap.prepare(
            rootURL: rootURL,
            appIdentity: .testFixture
        )

        XCTAssertTrue(bootstrap.recorder is AppleOnlyDiagnosticRecorder)
        XCTAssertNil(bootstrap.localRecorder)
    }

    func testFallbackRecordsTypedConstructionFailure() async {
        let fallbackRecorder = InMemoryDiagnosticRecorder()

        let bootstrap = await DiagnosticRecordingBootstrap.prepare(
            localRecorder: {
                throw DiagnosticStorageError.invalidRoot
            },
            fallbackRecorder: {
                fallbackRecorder
            }
        )

        XCTAssertNil(bootstrap.localRecorder)
        let events = fallbackRecorder.snapshot().map(\.event)
        XCTAssertEqual(
            events.map(\.code),
            [.sessionStarted, .operationStarted, .operationFailed]
        )
        XCTAssertEqual(events.last?.operationKind, .persistence)
        XCTAssertEqual(
            events.last?.failure,
            DiagnosticFailure(domain: .diagnostics, code: 1)
        )
    }
}
