@testable import NoonmarkSync
import XCTest

final class ICloudDriveRepositoryLocatorTests: XCTestCase {
    func testRootResolverRequiresAnAvailableAppleAccount() {
        XCTAssertThrowsError(
            try ICloudDriveRepositoryLocator.resolvedRootURL(
                repositoryName: "Noonmark/SyncRepository",
                ubiquitousContainerURL: URL(fileURLWithPath: "/ubiquity", isDirectory: true),
                cloudDocsURL: URL(fileURLWithPath: "/CloudDocs", isDirectory: true),
                hasICloudAccount: false,
                cloudDocsExists: true
            )
        ) { error in
            XCTAssertEqual(
                error as? ICloudDriveRepositoryLocationError,
                .accountUnavailable
            )
        }
    }

    func testRootResolverPrefersTheEntitledUbiquityContainer() throws {
        let rootURL = try ICloudDriveRepositoryLocator.resolvedRootURL(
            repositoryName: "Noonmark/SyncRepository",
            ubiquitousContainerURL: URL(fileURLWithPath: "/ubiquity", isDirectory: true),
            cloudDocsURL: URL(fileURLWithPath: "/CloudDocs", isDirectory: true),
            hasICloudAccount: true,
            cloudDocsExists: true
        )

        XCTAssertEqual(rootURL.path, "/ubiquity/Documents/Noonmark/SyncRepository")
    }

    func testRootResolverUsesCloudDocsForTheAdHocDevelopmentBundle() throws {
        let rootURL = try ICloudDriveRepositoryLocator.resolvedRootURL(
            repositoryName: "Noonmark/SyncRepository",
            ubiquitousContainerURL: nil,
            cloudDocsURL: URL(fileURLWithPath: "/CloudDocs", isDirectory: true),
            hasICloudAccount: true,
            cloudDocsExists: true
        )

        XCTAssertEqual(rootURL.path, "/CloudDocs/Noonmark/SyncRepository")
    }

    func testRootResolverRejectsACloudDocsFallbackThatIsNotPresent() {
        XCTAssertThrowsError(
            try ICloudDriveRepositoryLocator.resolvedRootURL(
                repositoryName: "Noonmark/SyncRepository",
                ubiquitousContainerURL: nil,
                cloudDocsURL: URL(fileURLWithPath: "/CloudDocs", isDirectory: true),
                hasICloudAccount: true,
                cloudDocsExists: false
            )
        ) { error in
            XCTAssertEqual(
                error as? ICloudDriveRepositoryLocationError,
                .driveUnavailable
            )
        }
    }
}
