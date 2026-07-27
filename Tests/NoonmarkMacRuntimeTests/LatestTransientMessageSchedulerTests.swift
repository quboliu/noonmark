@testable import NoonmarkMacRuntime
import XCTest

@MainActor
final class LatestTransientMessageSchedulerTests: XCTestCase {
    func testReplacingMessagePreventsCancelledExpiryFromClearingLatestMessage() {
        let expirySchedule = ControlledExpirySchedule()
        let scheduler = LatestTransientMessageScheduler(
            scheduleExpiry: expirySchedule.schedule
        )
        var expired: [String] = []

        scheduler.replace(after: .milliseconds(20)) {
            expired.append("first")
        }
        scheduler.replace(after: .milliseconds(45)) {
            expired.append("second")
        }

        expirySchedule.fire(index: 0)
        XCTAssertTrue(expired.isEmpty)

        expirySchedule.fire(index: 1)
        XCTAssertEqual(expired, ["second"])
    }

    func testCancelInvalidatesPendingExpiry() {
        let expirySchedule = ControlledExpirySchedule()
        let scheduler = LatestTransientMessageScheduler(
            scheduleExpiry: expirySchedule.schedule
        )
        var didExpire = false

        scheduler.replace(after: .milliseconds(15)) {
            didExpire = true
        }
        scheduler.cancel()
        expirySchedule.fire(index: 0)

        XCTAssertFalse(didExpire)
    }
}

@MainActor
private final class ControlledExpirySchedule {
    private var actions: [@MainActor () -> Void] = []

    func schedule(
        _: Duration,
        _ action: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        actions.append(action)
        return Task {}
    }

    func fire(index: Int) {
        actions[index]()
    }
}
