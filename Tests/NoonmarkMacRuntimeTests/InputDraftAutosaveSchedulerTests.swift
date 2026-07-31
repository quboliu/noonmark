import NoonmarkMacRuntime
import XCTest

@MainActor
final class InputDraftAutosaveSchedulerTests: XCTestCase {
    func testLatestScheduleRunsAfterBurstReplacesEarlierSchedules()
        async throws
    {
        var gate = IMETextDraftAutosaveGate(
            ownerID: "task:one:title"
        )
        let schedules = try (0 ..< 25).map { _ in
            try XCTUnwrap(gate.draftDidChange())
        }
        let expected = try XCTUnwrap(schedules.last)
        let fired = expectation(description: "latest schedule fired")
        var observed: [IMETextDraftAutosaveGate.Schedule] = []
        let scheduler = InputDraftAutosaveScheduler(
            delay: { _ in }
        )

        for schedule in schedules {
            scheduler.replace(with: schedule) { actual in
                observed.append(actual)
                fired.fulfill()
            }
        }

        await fulfillment(of: [fired], timeout: 1)
        await Task.yield()

        XCTAssertEqual(observed, [expected])
    }
}
