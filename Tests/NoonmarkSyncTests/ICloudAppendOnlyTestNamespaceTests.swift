@testable import NoonmarkSync
import XCTest

final class ICloudAppendOnlyTestNamespaceTests: XCTestCase {
    func testSessionAndEveryRoundMustBeExclusiveNewDirectories() throws {
        let cloudRoot = try makeCloudRoot()
        let sessionID = UUID(
            uuidString: "A1000000-0000-0000-0000-000000000001"
        )!
        let firstRoundID = UUID(
            uuidString: "A2000000-0000-0000-0000-000000000001"
        )!
        let secondRoundID = UUID(
            uuidString: "A2000000-0000-0000-0000-000000000002"
        )!
        let session = try ICloudAppendOnlyTestNamespace.beginSession(
            cloudDocumentsRoot: cloudRoot,
            sessionID: sessionID
        )
        let first = try ICloudAppendOnlyTestNamespace.createRound(
            in: session,
            roundID: firstRoundID
        )
        let second = try ICloudAppendOnlyTestNamespace.createRound(
            in: session,
            roundID: secondRoundID
        )

        XCTAssertTrue(first.rootURL.path.hasSuffix(
            "Noonmark-E2E/AppendOnlyLiveTests/\(sessionID.uuidString.lowercased())/\(firstRoundID.uuidString.lowercased())"
        ))
        XCTAssertNotEqual(first.rootURL, second.rootURL)
        XCTAssertThrowsError(
            try ICloudAppendOnlyTestNamespace.createRound(
                in: session,
                roundID: firstRoundID
            )
        ) { error in
            XCTAssertEqual(
                error as? ICloudAppendOnlyNamespaceError,
                .pathAlreadyExists
            )
        }
        XCTAssertThrowsError(
            try ICloudAppendOnlyTestNamespace.beginSession(
                cloudDocumentsRoot: cloudRoot,
                sessionID: sessionID
            )
        ) { error in
            XCTAssertEqual(
                error as? ICloudAppendOnlyNamespaceError,
                .pathAlreadyExists
            )
        }
    }

    func testRestartReopensOnlyTheExactExistingRoundWithoutCreatingAnything()
        throws
    {
        let cloudRoot = try makeCloudRoot()
        let sessionID = UUID(
            uuidString: "A1000000-0000-0000-0000-000000000002"
        )!
        let roundID = UUID(
            uuidString: "A2000000-0000-0000-0000-000000000003"
        )!
        let session = try ICloudAppendOnlyTestNamespace.beginSession(
            cloudDocumentsRoot: cloudRoot,
            sessionID: sessionID
        )
        let created = try ICloudAppendOnlyTestNamespace.createRound(
            in: session,
            roundID: roundID
        )

        let reopened = try ICloudAppendOnlyTestNamespace.reopenRound(
            cloudDocumentsRoot: cloudRoot,
            sessionID: sessionID,
            roundID: roundID
        )

        XCTAssertEqual(reopened.sessionID, sessionID)
        XCTAssertEqual(reopened.roundID, roundID)
        XCTAssertEqual(reopened.rootURL, created.rootURL)
        XCTAssertThrowsError(
            try ICloudAppendOnlyTestNamespace.reopenRound(
                cloudDocumentsRoot: cloudRoot,
                sessionID: sessionID,
                roundID: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error as? ICloudAppendOnlyNamespaceError,
                .invalidBoundary
            )
        }
    }

    private func makeCloudRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-icloud-append-only-namespace-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}
