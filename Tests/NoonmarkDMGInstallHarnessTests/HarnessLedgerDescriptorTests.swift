import Darwin
import Foundation
@testable import NoonmarkDMGInstallHarness
import XCTest

final class HarnessLedgerDescriptorTests: XCTestCase {
    func testDescriptorLedgerCreatesOwnerOnlyFileAndAppendsWithinCap() throws {
        let fixture = try LedgerFixture()
        defer { fixture.remove() }
        let ledger = try fixture.ledger()

        try ledger.pass("proof", "descriptor-bound")

        var status = stat()
        XCTAssertEqual(lstat(fixture.ledgerURL.path, &status), 0)
        XCTAssertEqual(
            status.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO),
            mode_t(S_IRUSR | S_IWUSR)
        )
        let value = try String(contentsOf: fixture.ledgerURL, encoding: .utf8)
        XCTAssertTrue(value.contains("\tPASS\tproof\tdescriptor-bound\n"))
    }

    func testDescriptorLedgerRejectsFIFOWithoutMutatingIt() throws {
        let fixture = try LedgerFixture()
        defer { fixture.remove() }
        XCTAssertEqual(mkfifo(fixture.ledgerURL.path, 0o644), 0)
        var before = stat()
        XCTAssertEqual(lstat(fixture.ledgerURL.path, &before), 0)

        XCTAssertThrowsError(try fixture.ledger())

        var after = stat()
        XCTAssertEqual(lstat(fixture.ledgerURL.path, &after), 0)
        XCTAssertEqual(after.st_mode, before.st_mode)
        XCTAssertEqual(after.st_ino, before.st_ino)
    }

    func testDescriptorLedgerRejectsHardLinkWithoutMutatingSource() throws {
        let fixture = try LedgerFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("source")
        try Data("protected".utf8).write(to: source)
        XCTAssertEqual(chmod(source.path, 0o600), 0)
        XCTAssertEqual(
            source.path.withCString { sourcePath in
                fixture.ledgerURL.path.withCString { ledgerPath in
                    Darwin.link(sourcePath, ledgerPath)
                }
            },
            0
        )

        XCTAssertThrowsError(try fixture.ledger())
        XCTAssertEqual(try Data(contentsOf: source), Data("protected".utf8))
        var status = stat()
        XCTAssertEqual(lstat(source.path, &status), 0)
        XCTAssertEqual(
            status.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO),
            mode_t(S_IRUSR | S_IWUSR)
        )
    }

    func testDescriptorLedgerRejectsOversizedOrNonOwnerOnlyExistingFile() throws {
        let fixture = try LedgerFixture()
        defer { fixture.remove() }
        try Data(repeating: 0x41, count: 4 * 1024 * 1024 + 1).write(
            to: fixture.ledgerURL
        )
        XCTAssertEqual(chmod(fixture.ledgerURL.path, 0o600), 0)
        XCTAssertThrowsError(try fixture.ledger())

        try FileManager.default.removeItem(at: fixture.ledgerURL)
        try Data().write(to: fixture.ledgerURL)
        XCTAssertEqual(chmod(fixture.ledgerURL.path, 0o644), 0)
        XCTAssertThrowsError(try fixture.ledger())
    }

    func testDescriptorLedgerRejectsNameReplacementBeforeAppend() throws {
        let fixture = try LedgerFixture()
        defer { fixture.remove() }
        let ledger = try fixture.ledger()
        let displaced = fixture.root.appendingPathComponent("displaced")
        try FileManager.default.moveItem(at: fixture.ledgerURL, to: displaced)
        try Data().write(to: fixture.ledgerURL)
        XCTAssertEqual(chmod(fixture.ledgerURL.path, 0o600), 0)

        XCTAssertThrowsError(try ledger.pass("must", "fail"))
    }
}

private struct LedgerFixture {
    let root: URL
    let ledgerURL: URL

    init() throws {
        root = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(".build/test-fixtures", isDirectory: true)
        .appendingPathComponent(
            "noonmark-bound-ledger-\(UUID().uuidString)",
            isDirectory: true
        )
        ledgerURL = root.appendingPathComponent("ledger.tsv")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func ledger() throws -> HarnessLedger {
        let directory = try DescriptorBoundDirectory(
            path: CanonicalAbsolutePath(root.path)
        )
        return try HarnessLedger(directory: directory, fileName: "ledger.tsv")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
