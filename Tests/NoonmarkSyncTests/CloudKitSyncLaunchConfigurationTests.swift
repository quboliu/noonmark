@testable import NoonmarkSync
import XCTest

final class CloudKitSyncLaunchConfigurationTests: XCTestCase {
    func testCloudKitIsDisabledWhenNoLaunchArgumentsArePresent() throws {
        XCTAssertNil(
            try CloudKitSyncLaunchConfiguration.resolve(arguments: ["Noonmark"])
        )
    }

    func testContainerArgumentSelectsDefaultZone() throws {
        let configuration = try XCTUnwrap(
            CloudKitSyncLaunchConfiguration.resolve(arguments: [
                "Noonmark",
                "--cloudkit-container-id",
                "iCloud.app.noonmark.mac"
            ])
        )

        XCTAssertEqual(configuration.containerIdentifier, "iCloud.app.noonmark.mac")
        XCTAssertEqual(configuration.zoneName, CloudKitSyncEngineTransport.defaultZoneName)
    }

    func testExplicitZoneIsPreservedForIsolatedLiveValidation() throws {
        let configuration = try XCTUnwrap(
            CloudKitSyncLaunchConfiguration.resolve(arguments: [
                "Noonmark",
                "--cloudkit-container-id",
                "iCloud.app.noonmark.mac",
                "--cloudkit-zone-name",
                "NoonmarkLiveValidation-20260714"
            ])
        )

        XCTAssertEqual(configuration.zoneName, "NoonmarkLiveValidation-20260714")
    }

    func testMalformedOrAmbiguousArgumentsFailClosed() {
        let invalidArguments = [
            ["Noonmark", "--cloudkit-container-id"],
            ["Noonmark", "--cloudkit-container-id", ""],
            ["Noonmark", "--cloudkit-zone-name", "zone-without-container"],
            [
                "Noonmark",
                "--cloudkit-container-id",
                "iCloud.app.noonmark.mac",
                "--cloudkit-zone-name",
                "arbitrary-zone"
            ],
            [
                "Noonmark",
                "--cloudkit-container-id",
                "iCloud.app.noonmark.mac",
                "--cloudkit-zone-name",
                "NoonmarkLiveValidation-"
            ],
            [
                "Noonmark",
                "--cloudkit-container-id",
                "iCloud.first",
                "--cloudkit-container-id",
                "iCloud.second"
            ],
            [
                "Noonmark",
                "--cloudkit-container-id",
                "iCloud.app.noonmark.mac",
                "--cloudkit-zone-name"
            ]
        ]

        for arguments in invalidArguments {
            XCTAssertThrowsError(
                try CloudKitSyncLaunchConfiguration.resolve(arguments: arguments),
                "expected failure for \(arguments)"
            ) { error in
                XCTAssertEqual(
                    error as? CloudKitSyncLaunchConfigurationError,
                    .invalidArguments
                )
            }
        }
    }
}
