import Foundation
@testable import NoonmarkMacE2ESupport
import XCTest

final class OpenPanelPhysicalInputProtocolTests: XCTestCase {
    func testReadyAndCompletionRoundTripThroughOwnerOnlyFiles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let ready = try OpenPanelPhysicalInputReady(
            launchToken: "11111111-2222-3333-4444-555555555555",
            targetPID: 101,
            appPath: fixture.app.path,
            panelWindowNumber: 202,
            panelLayer: 8,
            panelTitle: "选择晷迹数据包",
            selectedPath: fixture.selected.path,
            interactionLabel: "duplicate-subtask-identity"
        )
        try OpenPanelPhysicalInputProtocolFile.publish(
            ready,
            to: fixture.ready
        )
        XCTAssertEqual(
            try OpenPanelPhysicalInputProtocolFile.readReady(from: fixture.ready),
            ready
        )

        let completion = try OpenPanelPhysicalInputCompletion(
            launchToken: ready.launchToken,
            helperPID: 303,
            targetPID: ready.targetPID,
            panelWindowNumber: ready.panelWindowNumber,
            selectedPath: ready.selectedPath,
            interactionLabel: ready.interactionLabel,
            buttonTitle: "打开",
            leftButtonUp: true
        )
        try OpenPanelPhysicalInputProtocolFile.publish(
            completion,
            to: fixture.completion
        )
        XCTAssertEqual(
            try OpenPanelPhysicalInputProtocolFile.readCompletion(
                from: fixture.completion
            ),
            completion
        )
        XCTAssertEqual(try permissions(of: fixture.ready), 0o600)
        XCTAssertEqual(try permissions(of: fixture.completion), 0o600)
    }

    func testProtocolFilesCannotBeOverwrittenOrRedirectedThroughSymlinks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let ready = try OpenPanelPhysicalInputReady(
            launchToken: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            targetPID: 101,
            appPath: fixture.app.path,
            panelWindowNumber: 202,
            panelLayer: 8,
            panelTitle: "Choose a Noonmark data package",
            selectedPath: fixture.selected.path,
            interactionLabel: "confirm"
        )
        try OpenPanelPhysicalInputProtocolFile.publish(ready, to: fixture.ready)
        XCTAssertThrowsError(
            try OpenPanelPhysicalInputProtocolFile.publish(ready, to: fixture.ready)
        )

        let canary = fixture.root.appendingPathComponent("canary.txt")
        try Data("unchanged".utf8).write(to: canary)
        let redirected = fixture.root.appendingPathComponent("redirected.json")
        try FileManager.default.createSymbolicLink(
            at: redirected,
            withDestinationURL: canary
        )
        XCTAssertThrowsError(
            try OpenPanelPhysicalInputProtocolFile.publish(ready, to: redirected)
        )
        XCTAssertEqual(try String(contentsOf: canary, encoding: .utf8), "unchanged")
    }

    func testDecoderRejectsNoncanonicalAndInvalidCompletionPayloads() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let invalid = """
        {"appPath":"\(fixture.app.path)","interactionLabel":"confirm","launchToken":"not-a-token","panelTitle":"Choose a Noonmark data package","panelWindowNumber":202,"schemaVersion":1,"selectedPath":"\(fixture.selected.path)","status":"ready","targetPID":101}
        """
        try Data(invalid.utf8).write(to: fixture.ready)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.ready.path
        )
        XCTAssertThrowsError(
            try OpenPanelPhysicalInputProtocolFile.readReady(from: fixture.ready)
        )

        XCTAssertThrowsError(
            try OpenPanelPhysicalInputCompletion(
                launchToken: "11111111-2222-3333-4444-555555555555",
                helperPID: 303,
                targetPID: 101,
                panelWindowNumber: 202,
                selectedPath: fixture.selected.path,
                interactionLabel: "confirm",
                buttonTitle: "Open",
                leftButtonUp: false
            )
        )
    }

    private struct Fixture {
        let root: URL
        let app: URL
        let selected: URL
        let ready: URL
        let completion: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noonmark-open-panel-protocol-\(UUID().uuidString)",
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
        return Fixture(
            root: root.standardizedFileURL.resolvingSymlinksInPath(),
            app: app.standardizedFileURL.resolvingSymlinksInPath(),
            selected: selected.standardizedFileURL.resolvingSymlinksInPath(),
            ready: root.appendingPathComponent("ready.json"),
            completion: root.appendingPathComponent("completion.json")
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}
