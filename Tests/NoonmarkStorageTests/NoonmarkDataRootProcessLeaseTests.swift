import Darwin
import Foundation
@testable import NoonmarkStorage
import XCTest

final class NoonmarkDataRootProcessLeaseTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-data-root-lease-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testSameRootRejectsSecondLeaseUntilFirstReleases() throws {
        var first: NoonmarkDataRootProcessLease? = try .acquire(
            dataRootURL: temporaryRoot
        )
        XCTAssertNotNil(first)
        let lockURL = temporaryRoot.appendingPathComponent(
            NoonmarkDataRootProcessLease.lockFileName
        )

        XCTAssertThrowsError(
            try NoonmarkDataRootProcessLease.acquire(
                dataRootURL: temporaryRoot
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkDataRootProcessLeaseError,
                .alreadyHeld(path: lockURL.path)
            )
        }

        first = nil
        XCTAssertNoThrow(
            try NoonmarkDataRootProcessLease.acquire(
                dataRootURL: temporaryRoot
            )
        )
    }

    func testDifferentRootsAcquireIndependently() throws {
        let otherRoot = temporaryRoot.appendingPathComponent(
            "other",
            isDirectory: true
        )
        let first = try NoonmarkDataRootProcessLease.acquire(
            dataRootURL: temporaryRoot
        )
        let second = try NoonmarkDataRootProcessLease.acquire(
            dataRootURL: otherRoot
        )

        XCTAssertNotEqual(first.lockFileURL, second.lockFileURL)
    }

    func testExistingLockFilePermissionsAreTightened() throws {
        let lockURL = temporaryRoot.appendingPathComponent(
            NoonmarkDataRootProcessLease.lockFileName
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: lockURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o666]
        ))

        let lease = try NoonmarkDataRootProcessLease.acquire(
            dataRootURL: temporaryRoot
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: lease.lockFileURL.path
        )

        XCTAssertEqual(
            attributes[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o600)
        )
    }

    func testGroupOrWorldWritableDataRootFailsClosed() throws {
        XCTAssertEqual(chmod(temporaryRoot.path, mode_t(0o777)), 0)
        defer { _ = chmod(temporaryRoot.path, mode_t(0o700)) }

        XCTAssertThrowsError(
            try NoonmarkDataRootProcessLease.acquire(
                dataRootURL: temporaryRoot
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkDataRootProcessLeaseError,
                .invalidDataRoot(path: temporaryRoot.path)
            )
        }
    }

    func testOpenFailurePreservesPOSIXErrno() throws {
        XCTAssertEqual(chmod(temporaryRoot.path, mode_t(0o500)), 0)
        defer { _ = chmod(temporaryRoot.path, mode_t(0o700)) }
        let lockURL = temporaryRoot.appendingPathComponent(
            NoonmarkDataRootProcessLease.lockFileName
        )

        XCTAssertThrowsError(
            try NoonmarkDataRootProcessLease.acquire(
                dataRootURL: temporaryRoot
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkDataRootProcessLeaseError,
                .posixFailure(
                    operation: "open-lock",
                    code: EACCES,
                    path: lockURL.path
                )
            )
        }
    }

    func testDataRootCreationFailurePreservesUnderlyingPOSIXErrno() throws {
        let deniedParent = temporaryRoot.appendingPathComponent(
            "denied",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: deniedParent,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(deniedParent.path, mode_t(0o500)), 0)
        defer { _ = chmod(deniedParent.path, mode_t(0o700)) }
        let missingRoot = deniedParent.appendingPathComponent(
            "missing",
            isDirectory: true
        )

        XCTAssertThrowsError(
            try NoonmarkDataRootProcessLease.acquire(
                dataRootURL: missingRoot
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkDataRootProcessLeaseError,
                .posixFailure(
                    operation: "create-data-root",
                    code: EACCES,
                    path: missingRoot.path
                )
            )
        }
    }

    func testSymlinkAndNonregularLockFilesFailClosed() throws {
        let lockURL = temporaryRoot.appendingPathComponent(
            NoonmarkDataRootProcessLease.lockFileName
        )
        let targetURL = temporaryRoot.appendingPathComponent("target")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: targetURL.path,
            contents: Data()
        ))
        try FileManager.default.createSymbolicLink(
            at: lockURL,
            withDestinationURL: targetURL
        )

        XCTAssertThrowsError(
            try NoonmarkDataRootProcessLease.acquire(
                dataRootURL: temporaryRoot
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkDataRootProcessLeaseError,
                .invalidLockFile(path: lockURL.path)
            )
        }

        try FileManager.default.removeItem(at: lockURL)
        XCTAssertEqual(mkfifo(lockURL.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(
            try NoonmarkDataRootProcessLease.acquire(
                dataRootURL: temporaryRoot
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkDataRootProcessLeaseError,
                .invalidLockFile(path: lockURL.path)
            )
        }
    }

    func testSymlinkDataRootFailsClosed() throws {
        let realRoot = temporaryRoot.appendingPathComponent(
            "real",
            isDirectory: true
        )
        let linkedRoot = temporaryRoot.appendingPathComponent(
            "linked",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: realRoot
        )

        XCTAssertThrowsError(
            try NoonmarkDataRootProcessLease.acquire(
                dataRootURL: linkedRoot
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkDataRootProcessLeaseError,
                .invalidDataRoot(path: linkedRoot.path)
            )
        }
    }
}
