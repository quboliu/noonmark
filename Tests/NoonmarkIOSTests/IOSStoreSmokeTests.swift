import Foundation
import XCTest

final class IOSStoreSmokeTests: XCTestCase {
    func testIOSTargetOwnsAnIsolatedDevelopmentBundleIdentifier() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let text = try String(contentsOf: project, encoding: .utf8)
        XCTAssertTrue(text.contains("app.noonmark.ios.development"))
        XCTAssertFalse(text.contains("app.noonmark.mac"))
    }
}
