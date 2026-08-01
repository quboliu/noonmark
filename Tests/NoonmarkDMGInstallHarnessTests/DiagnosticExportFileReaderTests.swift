import Darwin
import Foundation
@testable import NoonmarkDMGInstallHarness
import XCTest

final class DiagnosticExportFileReaderTests: XCTestCase {
    func testReaderReturnsBytesFromOneOwnerOnlyRegularFile() throws {
        let fixture = try DiagnosticFileFixture()
        defer { fixture.remove() }
        let expected = Data("evidence".utf8)
        try fixture.write(expected)

        let actual = try fixture.reader().read(
            atPath: fixture.fileURL.path,
            maximumByteCount: 1024,
            requireOwnerOnlyPermissions: true
        )

        XCTAssertEqual(actual, expected)
    }

    func testReaderRejectsASymbolicLink() throws {
        let fixture = try DiagnosticFileFixture()
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("target")
        try Data("evidence".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.fileURL,
            withDestinationURL: target
        )

        XCTAssertThrowsError(
            try fixture.reader().read(
                atPath: fixture.fileURL.path,
                maximumByteCount: 1024,
                requireOwnerOnlyPermissions: true
            )
        )
    }

    func testReaderRejectsAHardLinkedFile() throws {
        let fixture = try DiagnosticFileFixture()
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("target")
        try Data("evidence".utf8).write(to: target)
        try setOwnerOnlyPermissions(target)
        let result = target.path.withCString { source in
            fixture.fileURL.path.withCString { destination in
                Darwin.link(source, destination)
            }
        }
        XCTAssertEqual(result, 0)

        XCTAssertThrowsError(
            try fixture.reader().read(
                atPath: fixture.fileURL.path,
                maximumByteCount: 1024,
                requireOwnerOnlyPermissions: true
            )
        )
    }

    func testReaderRejectsGroupOrOtherPermissions() throws {
        let fixture = try DiagnosticFileFixture()
        defer { fixture.remove() }
        try fixture.write(Data("evidence".utf8), permissions: 0o644)

        XCTAssertThrowsError(
            try fixture.reader().read(
                atPath: fixture.fileURL.path,
                maximumByteCount: 1024,
                requireOwnerOnlyPermissions: true
            )
        )
    }

    func testBaselineReaderAcceptsReadOnlySharingButRejectsWorldWritableGate() throws {
        let fixture = try DiagnosticFileFixture()
        defer { fixture.remove() }
        let expected = Data("verified-gate".utf8)
        try fixture.write(expected, permissions: 0o644)
        XCTAssertEqual(
            try fixture.reader().read(
                atPath: fixture.fileURL.path,
                maximumByteCount: 1024,
                requireOwnerOnlyPermissions: false
            ),
            expected
        )

        guard chmod(fixture.fileURL.path, mode_t(0o666)) == 0 else {
            throw POSIXError(.EPERM)
        }
        XCTAssertThrowsError(
            try fixture.reader().read(
                atPath: fixture.fileURL.path,
                maximumByteCount: 1024,
                requireOwnerOnlyPermissions: false
            )
        )
    }

    func testReaderRejectsAnInodeMutatedAfterIdentityCapture() throws {
        let fixture = try DiagnosticFileFixture()
        defer { fixture.remove() }
        try fixture.write(Data("evidence".utf8))

        XCTAssertThrowsError(
            try fixture.reader().read(
                atPath: fixture.fileURL.path,
                maximumByteCount: 1024,
                requireOwnerOnlyPermissions: true,
                afterIdentityCapture: {
                    let handle = try FileHandle(forWritingTo: fixture.fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data("-changed".utf8))
                }
            )
        )
    }

    func testReaderRejectsAPathReplacementAfterIdentityCapture() throws {
        let fixture = try DiagnosticFileFixture()
        defer { fixture.remove() }
        let original = Data("original-evidence".utf8)
        try fixture.write(original)
        let displaced = fixture.root.appendingPathComponent("displaced")

        XCTAssertThrowsError(
            try fixture.reader().read(
                atPath: fixture.fileURL.path,
                maximumByteCount: 1024,
                requireOwnerOnlyPermissions: true,
                afterIdentityCapture: {
                    try FileManager.default.moveItem(
                        at: fixture.fileURL,
                        to: displaced
                    )
                    try Data("replacement-data".utf8).write(
                        to: fixture.fileURL
                    )
                    try setOwnerOnlyPermissions(fixture.fileURL)
                }
            )
        )
    }

    func testReaderRejectsAFileLargerThanItsBound() throws {
        let fixture = try DiagnosticFileFixture()
        defer { fixture.remove() }
        try fixture.write(Data(repeating: 0x41, count: 9))

        XCTAssertThrowsError(
            try fixture.reader().read(
                atPath: fixture.fileURL.path,
                maximumByteCount: 8,
                requireOwnerOnlyPermissions: true
            )
        )
    }

    func testReaderRejectsASymbolicLinkInTheAnchoredParentChain() throws {
        let fixture = try DiagnosticFileFixture()
        let actualRoot = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("actual-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: actualRoot)
        }
        try fixture.write(Data("evidence".utf8))
        try FileManager.default.moveItem(at: fixture.root, to: actualRoot)
        try FileManager.default.createSymbolicLink(
            at: fixture.root,
            withDestinationURL: actualRoot
        )

        XCTAssertThrowsError(
            try fixture.reader().read(
                atPath: fixture.fileURL.path,
                maximumByteCount: 1024,
                requireOwnerOnlyPermissions: true
            )
        )
    }

    func testReaderRejectsAnAnchoredParentSwapBeforeFileOpen() throws {
        let fixture = try DiagnosticFileFixture()
        let displacedRoot = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("displaced-\(UUID().uuidString)")
        let replacementRoot = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("replacement-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: displacedRoot)
            try? FileManager.default.removeItem(at: replacementRoot)
        }
        try fixture.write(Data("expected-evidence".utf8))
        try FileManager.default.createDirectory(
            at: replacementRoot,
            withIntermediateDirectories: false
        )
        let replacementFile = replacementRoot.appendingPathComponent(
            fixture.fileURL.lastPathComponent
        )
        try Data("unexpected-evidence".utf8).write(to: replacementFile)
        try setOwnerOnlyPermissions(replacementFile)

        XCTAssertThrowsError(
            try fixture.reader(
                afterDirectoryIdentityCapture: {
                    try FileManager.default.moveItem(
                        at: fixture.root,
                        to: displacedRoot
                    )
                    try FileManager.default.createSymbolicLink(
                        at: fixture.root,
                        withDestinationURL: replacementRoot
                    )
                }
            ).read(
                atPath: fixture.fileURL.path,
                maximumByteCount: 1024,
                requireOwnerOnlyPermissions: true
            )
        )
    }
}

private struct DiagnosticFileFixture {
    let root: URL
    let fileURL: URL

    init() throws {
        root = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(".build/test-fixtures", isDirectory: true)
        .appendingPathComponent(
            "noonmark-diagnostic-file-\(UUID().uuidString)",
            isDirectory: true
        )
        fileURL = root.appendingPathComponent("diagnostics.noonmarkdiagnostics")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func write(_ data: Data, permissions: mode_t = 0o600) throws {
        try data.write(to: fileURL)
        guard chmod(fileURL.path, permissions) == 0 else {
            throw POSIXError(.EPERM)
        }
    }

    func reader(
        afterDirectoryIdentityCapture: () throws -> Void = {}
    ) throws -> DiagnosticExportFileReader {
        try DiagnosticExportFileReader(
            anchoredAtDirectoryPath: root.path,
            afterDirectoryIdentityCapture: afterDirectoryIdentityCapture
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func setOwnerOnlyPermissions(_ url: URL) throws {
    guard chmod(url.path, mode_t(0o600)) == 0 else {
        throw POSIXError(.EPERM)
    }
}
