import Foundation
@testable import NoonmarkDMGInstallHarness
import XCTest

final class HarnessLedgerContractTests: XCTestCase {
    func testShellContractMatchesProducerContractForEveryLedgerMode() throws {
        let shellContract = try loadShellContract()
        let modes: [NoonmarkDMGInstallHarness.Mode] = [
            .preflight,
            .exercise,
            .restart,
            .e2eInspect,
            .e2eMenuCommand,
            .e2eOpenPanel,
            .diagnosticExport
        ]

        XCTAssertEqual(Set(shellContract.keys), Set(modes.map(\.rawValue)))
        for mode in modes {
            XCTAssertEqual(
                shellContract[mode.rawValue],
                HarnessLedgerContract.expectedPassSteps(for: mode),
                "ledger contract drifted for \(mode.rawValue)"
            )
        }
        XCTAssertTrue(
            HarnessLedgerContract.expectedPassSteps(
                for: .diagnosticExportScope
            ).isEmpty
        )
    }

    func testProducerRejectsMissingReorderedAndExtraPassSteps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noonmark-ledger-contract-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let missing = try HarnessLedger(
            path: root.appendingPathComponent("missing.tsv").path,
            expectedPassSteps: ["arguments", "complete"]
        )
        XCTAssertThrowsError(try missing.pass("complete", "mode=fixture"))

        let reordered = try HarnessLedger(
            path: root.appendingPathComponent("reordered.tsv").path,
            expectedPassSteps: ["arguments", "process"]
        )
        try reordered.pass("arguments", "mode=fixture")
        XCTAssertThrowsError(try reordered.pass("complete", "mode=fixture"))

        let extra = try HarnessLedger(
            path: root.appendingPathComponent("extra.tsv").path,
            expectedPassSteps: ["arguments"]
        )
        try extra.pass("arguments", "mode=fixture")
        XCTAssertThrowsError(try extra.pass("complete", "mode=fixture"))
    }

    private func loadShellContract() throws -> [String: [String]] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contractURL = repositoryRoot
            .appendingPathComponent("scripts/dmg-harness-ledger-contract.tsv")
        let content = try String(contentsOf: contractURL, encoding: .utf8)
        var result: [String: [String]] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                continue
            }
            let fields = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            )
            guard fields.count == 2 else {
                XCTFail("invalid shell ledger contract row: \(line)")
                continue
            }
            let mode = String(fields[0])
            let steps = fields[1].split(separator: ",").map(String.init)
            XCTAssertNil(result.updateValue(steps, forKey: mode))
        }
        return result
    }
}
