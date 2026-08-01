import Foundation
@testable import NoonmarkDiagnostics
import XCTest

final class DiagnosticPrivacyBoundaryTests: XCTestCase {
    func testMutationRejectionCarriesTypedPersistenceFailureWithoutText() {
        let recorder = InMemoryDiagnosticRecorder()
        let incidentID = DiagnosticIncidentID()

        recorder.record(
            .mutationRejected(
                context: .task,
                reason: .persistenceFailure,
                operationID: nil,
                incidentID: incidentID,
                failure: DiagnosticFailure(domain: .sqlite, code: 13)
            )
        )

        let event = recorder.snapshot().first?.event
        XCTAssertEqual(event?.incidentID, incidentID)
        XCTAssertEqual(event?.mutationRejectionReason, .persistenceFailure)
        XCTAssertEqual(event?.failure, DiagnosticFailure(domain: .sqlite, code: 13))
    }

    func testPersistenceCheckpointKeepsOnlyTypedJournalEvidence() {
        let event = EvidenceEvent.persistenceCheckpoint(
            component: .zhulongApplicationJournal,
            operation: .prepare,
            phase: .temporaryFullSync,
            resolution: .fileSyncFallback,
            failure: DiagnosticFailure(domain: .posix, code: 45)
        )

        XCTAssertEqual(event.code, .persistenceCheckpoint)
        XCTAssertEqual(event.persistenceComponent, .zhulongApplicationJournal)
        XCTAssertEqual(event.persistenceOperation, .prepare)
        XCTAssertEqual(event.persistencePhase, .temporaryFullSync)
        XCTAssertEqual(event.persistenceResolution, .fileSyncFallback)
        XCTAssertEqual(event.failure, DiagnosticFailure(domain: .posix, code: 45))
        XCTAssertEqual(event.severity, .notice)
    }

    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    func testNSErrorUserInfoCannotCrossTypedEvidenceOrExportBoundary() async throws {
        let canaries = [
            "PRIVATE-TASK-TITLE-7Q9X",
            "sk-live-THIS-MUST-NOT-LEAK",
            "Bearer secret-access-token",
            "/Users/private-user/Documents/Noonmark.sqlite",
            "owner@example.invalid",
            "203.0.113.42",
            "https://example.invalid/sync?token=private"
        ]
        let sourceError = NSError(
            domain: NSCocoaErrorDomain,
            code: 513,
            userInfo: [
                NSLocalizedDescriptionKey: canaries.joined(separator: " "),
                NSFilePathErrorKey: canaries[3]
            ]
        )
        let rootURL = temporaryDirectory(named: "privacy")
        let exportURL = temporaryDirectory(named: "privacy-export")
            .appendingPathComponent("evidence.noonmarkdiagnostics")
        let recorder = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture
        )

        recorder.startSession(at: Date(timeIntervalSince1970: 1_800_000_000))
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive,
            at: Date(timeIntervalSince1970: 1_800_000_001)
        )
        operation.fail(
            DiagnosticFailure(domain: .syncProtocol, code: 7),
            detail: DiagnosticSystemFailureMapper.map(
                domain: sourceError.domain,
                code: sourceError.code
            ),
            at: Date(timeIntervalSince1970: 1_800_000_002)
        )
        await recorder.flush()
        _ = try await recorder.export(to: exportURL)

        let packageData = try Data(contentsOf: exportURL)
        let packageText = String(decoding: packageData, as: UTF8.self)
        let diskText = try diagnosticFileText(in: rootURL)
        let rendered = await DiagnosticEvidenceTextRenderer.render(
            try recorder.snapshotPackage().records.map(\.event)
        )
        for canary in canaries {
            XCTAssertFalse(packageText.contains(canary), canary)
            XCTAssertFalse(diskText.contains(canary), canary)
            XCTAssertFalse(rendered.contains(canary), canary)
        }
        XCTAssertTrue(packageText.contains("\"domain\":\"cocoa\""))
        XCTAssertTrue(packageText.contains("\"code\":513"))
        XCTAssertTrue(rendered.contains("error_domain=syncProtocol"))
        XCTAssertTrue(rendered.contains("error_code=7"))
        XCTAssertTrue(rendered.contains("detail_error_domain=cocoa"))
        XCTAssertTrue(rendered.contains("detail_error_code=513"))
    }

    func testUnknownErrorDoesNotExposeThirdPartyDomainOrCode() {
        let failure = DiagnosticSystemFailureMapper.map(
            domain: "com.vendor.PRIVATE-TASK-TITLE-7Q9X",
            code: 98765
        )

        XCTAssertEqual(failure, DiagnosticFailure(domain: .unknown, code: 0))
    }

    func testSystemMapperDoesNotTraverseWrapperUserInfo() {
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EIO),
            userInfo: [NSLocalizedDescriptionKey: "PRIVATE-TASK-TITLE-7Q9X"]
        )
        let wrapper = NSError(
            domain: "app.noonmark.persistence",
            code: 99001,
            userInfo: [
                NSUnderlyingErrorKey: underlying,
                NSLocalizedDescriptionKey: "Bearer secret-access-token"
            ]
        )

        XCTAssertEqual(
            DiagnosticSystemFailureMapper.map(
                domain: wrapper.domain,
                code: wrapper.code
            ),
            DiagnosticFailure(domain: .unknown, code: 0)
        )
    }

    func testDomainOwnedTypedFailureMappingTakesPrecedenceWithoutText() {
        let failure = SafeMappedFailure
            .privatePayload("PRIVATE-TASK-TITLE-7Q9X")
            .diagnosticFailure

        XCTAssertEqual(
            failure,
            DiagnosticFailure(domain: .syncProtocol, code: 701)
        )
    }

    func testSystemMapperKeepsOnlyAllowedDomainAndNumericCode() {
        let expected: [(String, DiagnosticErrorDomain)] = [
            (NSCocoaErrorDomain, .cocoa),
            (NSPOSIXErrorDomain, .posix),
            (NSURLErrorDomain, .url),
            ("CKErrorDomain", .cloudKit)
        ]

        for (domain, expectedDomain) in expected {
            XCTAssertEqual(
                DiagnosticSystemFailureMapper.map(
                    domain: domain,
                    code: 513
                ),
                DiagnosticFailure(domain: expectedDomain, code: 513)
            )
        }
    }

    func testDiagnosticStorageFailuresHaveStableTypedCodes() {
        let expected: [(DiagnosticStorageError, Int)] = [
            (.invalidRoot, 1),
            (.exportTooLarge, 2),
            (.allocatedSizeUnavailable, 3)
        ]

        for (error, code) in expected {
            XCTAssertEqual(
                error.diagnosticFailure,
                DiagnosticFailure(domain: .diagnostics, code: code)
            )
        }
    }

    private func diagnosticFileText(in rootURL: URL) throws -> String {
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        var data = Data()
        for url in urls where url.hasDirectoryPath == false {
            data.append(try Data(contentsOf: url))
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func temporaryDirectory(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-diagnostics-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        temporaryURLs.append(url)
        return url
    }
}

private enum SafeMappedFailure: Error, DiagnosticFailureProviding {
    case privatePayload(String)

    var diagnosticFailure: DiagnosticFailure {
        DiagnosticFailure(domain: .syncProtocol, code: 701)
    }
}
