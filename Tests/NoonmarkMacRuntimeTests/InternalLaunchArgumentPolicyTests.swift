import NoonmarkMacRuntime
import XCTest

final class InternalLaunchArgumentPolicyTests: XCTestCase {
    private let processArguments = [
        "/Applications/Noonmark.app/Contents/MacOS/NoonmarkMacApp",
        "--ephemeral",
        "--data-url",
        "/tmp/private.sqlite",
        "--page",
        "settings",
        "--e2e-quit-after-automation"
    ]

    func testE2EBundleCanSeeEveryProcessArgument() {
        XCTAssertEqual(
            InternalLaunchArgumentPolicy.visibleArguments(
                bundleIdentifier: "app.noonmark.mac.e2e",
                processArguments: processArguments
            ),
            processArguments
        )
        XCTAssertTrue(
            InternalLaunchArgumentPolicy.permitsInternalArguments(
                bundleIdentifier: "app.noonmark.mac.e2e"
            )
        )
    }

    func testProductionBundleCannotSeeInternalArgumentsInAnyBuildConfiguration() {
        for buildMarker in ["debug", "release"] {
            let arguments = processArguments + ["--build-marker", buildMarker]

            XCTAssertEqual(
                InternalLaunchArgumentPolicy.visibleArguments(
                    bundleIdentifier: "app.noonmark.mac",
                    processArguments: arguments
                ),
                [processArguments[0]]
            )
        }
        XCTAssertFalse(
            InternalLaunchArgumentPolicy.permitsInternalArguments(
                bundleIdentifier: "app.noonmark.mac"
            )
        )
    }

    func testUnknownAuditAndLookalikeBundlesAreFailClosed() {
        let deniedBundleIdentifiers: [String?] = [
            nil,
            "app.noonmark.mac.audit",
            "app.noonmark.mac.e2e.debug",
            "app.noonmark.mac.e2e-malicious"
        ]

        for bundleIdentifier in deniedBundleIdentifiers {
            XCTAssertEqual(
                InternalLaunchArgumentPolicy.visibleArguments(
                    bundleIdentifier: bundleIdentifier,
                    processArguments: processArguments
                ),
                [processArguments[0]]
            )
            XCTAssertFalse(
                InternalLaunchArgumentPolicy.permitsInternalArguments(
                    bundleIdentifier: bundleIdentifier
                )
            )
        }
    }

    func testSanitizationHandlesMissingExecutableWithoutInventingAnArgument() {
        XCTAssertEqual(
            InternalLaunchArgumentPolicy.visibleArguments(
                bundleIdentifier: nil,
                processArguments: []
            ),
            []
        )
    }
}
