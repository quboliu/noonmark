@testable import NoonmarkMacRuntime
import XCTest

@MainActor
final class LatestTransientMessageSchedulerTests: XCTestCase {
    func testReplacingMessagePreventsCancelledExpiryFromClearingLatestMessage() async throws {
        let scheduler = LatestTransientMessageScheduler()
        var expired: [String] = []

        scheduler.replace(after: .milliseconds(20)) {
            expired.append("first")
        }
        try await Task.sleep(for: .milliseconds(5))
        scheduler.replace(after: .milliseconds(45)) {
            expired.append("second")
        }

        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(expired.isEmpty)

        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(expired, ["second"])
    }

    func testCancelInvalidatesPendingExpiry() async throws {
        let scheduler = LatestTransientMessageScheduler()
        var didExpire = false

        scheduler.replace(after: .milliseconds(15)) {
            didExpire = true
        }
        scheduler.cancel()
        try await Task.sleep(for: .milliseconds(25))

        XCTAssertFalse(didExpire)
    }
}
