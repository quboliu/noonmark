import Foundation
@testable import NoonmarkDMGInstallHarness
import NoonmarkMacE2ESupport
import XCTest

final class OpenPanelConfigurationTests: XCTestCase {
    func testConfigurationIsDerivedFromCanonicalReadyPayload() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let configuration = try NoonmarkDMGInstallHarness.Configuration.parse(
            arguments(fixture: fixture)
        )
        XCTAssertEqual(configuration.mode, .e2eOpenPanel)
        XCTAssertEqual(configuration.pid, 101)
        XCTAssertEqual(configuration.appPath, fixture.app.path)
        XCTAssertEqual(configuration.windowNumber, 202)
        XCTAssertEqual(configuration.windowTitle, "选择晷迹数据包")
        XCTAssertEqual(configuration.openPanelReady, fixture.readyPayload)
        XCTAssertEqual(configuration.openPanelReadyPath, fixture.ready.path)
        XCTAssertEqual(configuration.completionPath, fixture.completion.path)
    }

    func testConfigurationRejectsTokenAndCompletionNameDrift() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var mismatchedToken = arguments(fixture: fixture)
        let tokenIndex = try XCTUnwrap(
            mismatchedToken.firstIndex(of: "--launch-token")
        ) + 1
        mismatchedToken[tokenIndex] = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        XCTAssertThrowsError(
            try NoonmarkDMGInstallHarness.Configuration.parse(mismatchedToken)
        )

        var wrongCompletion = arguments(fixture: fixture)
        let completionIndex = try XCTUnwrap(
            wrongCompletion.firstIndex(of: "--completion")
        ) + 1
        wrongCompletion[completionIndex] = fixture.root
            .appendingPathComponent("wrong.completion.json").path
        XCTAssertThrowsError(
            try NoonmarkDMGInstallHarness.Configuration.parse(wrongCompletion)
        )
    }

    private struct Fixture {
        let root: URL
        let app: URL
        let ready: URL
        let completion: URL
        let ledger: URL
        let startGate: URL
        let readyPayload: OpenPanelPhysicalInputReady
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noonmark-open-panel-configuration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        let app = root.appendingPathComponent("NoonmarkE2E.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app,
            withIntermediateDirectories: false
        )
        let selected = root.appendingPathComponent("fixture.json")
        try Data("{}".utf8).write(to: selected)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let ready = canonicalRoot.appendingPathComponent("confirm.ready.json")
        let completion = canonicalRoot.appendingPathComponent(
            "confirm.completion.json"
        )
        let readyPayload = try OpenPanelPhysicalInputReady(
            launchToken: "11111111-2222-3333-4444-555555555555",
            targetPID: 101,
            appPath: app.standardizedFileURL.resolvingSymlinksInPath().path,
            panelWindowNumber: 202,
            panelLayer: 8,
            panelTitle: "选择晷迹数据包",
            selectedPath: selected.standardizedFileURL.resolvingSymlinksInPath().path,
            interactionLabel: "confirm"
        )
        try OpenPanelPhysicalInputProtocolFile.publish(readyPayload, to: ready)
        return Fixture(
            root: canonicalRoot,
            app: app.standardizedFileURL.resolvingSymlinksInPath(),
            ready: ready,
            completion: completion,
            ledger: canonicalRoot.appendingPathComponent("ledger.tsv"),
            startGate: canonicalRoot.appendingPathComponent("observer.txt"),
            readyPayload: readyPayload
        )
    }

    private func arguments(fixture: Fixture) -> [String] {
        [
            "--mode", "e2e-open-panel",
            "--ledger", fixture.ledger.path,
            "--launch-token", fixture.readyPayload.launchToken,
            "--start-gate", fixture.startGate.path,
            "--ready", fixture.ready.path,
            "--completion", fixture.completion.path
        ]
    }
}
