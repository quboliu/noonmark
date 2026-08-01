import Foundation
@testable import NoonmarkDiagnostics
import XCTest

final class DiagnosticPrivacyBoundaryTests: XCTestCase {
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
            DiagnosticFailureClassifier.classify(sourceError),
            at: Date(timeIntervalSince1970: 1_800_000_002)
        )
        await recorder.flush()
        _ = try await recorder.export(to: exportURL)

        let packageData = try Data(contentsOf: exportURL)
        let packageText = String(decoding: packageData, as: UTF8.self)
        let diskText = try diagnosticFileText(in: rootURL)
        let rendered = DiagnosticEvidenceTextRenderer.render(
            try await recorder.snapshotPackage().records.map(\.event)
        )
        for canary in canaries {
            XCTAssertFalse(packageText.contains(canary), canary)
            XCTAssertFalse(diskText.contains(canary), canary)
            XCTAssertFalse(rendered.contains(canary), canary)
        }
        XCTAssertTrue(packageText.contains("\"domain\":\"cocoa\""))
        XCTAssertTrue(packageText.contains("\"code\":513"))
    }

    func testUnknownErrorDoesNotExposeThirdPartyDomainOrCode() {
        let failure = DiagnosticFailureClassifier.classify(
            NSError(
                domain: "com.vendor.PRIVATE-TASK-TITLE-7Q9X",
                code: 98_765,
                userInfo: [NSLocalizedDescriptionKey: "sk-live-secret"]
            )
        )

        XCTAssertEqual(failure, DiagnosticFailure(domain: .unknown, code: 0))
    }

    func testRecognizedUnderlyingSystemFailureSurvivesSafeWrapper() {
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EIO),
            userInfo: [NSLocalizedDescriptionKey: "PRIVATE-TASK-TITLE-7Q9X"]
        )
        let wrapper = NSError(
            domain: "app.noonmark.persistence",
            code: 99_001,
            userInfo: [
                NSUnderlyingErrorKey: underlying,
                NSLocalizedDescriptionKey: "Bearer secret-access-token"
            ]
        )

        XCTAssertEqual(
            DiagnosticFailureClassifier.classify(wrapper),
            DiagnosticFailure(domain: .posix, code: Int(EIO))
        )
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
