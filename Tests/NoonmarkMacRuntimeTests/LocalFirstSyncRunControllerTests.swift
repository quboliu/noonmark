@testable import NoonmarkMacRuntime
import XCTest

@MainActor
final class LocalFirstSyncRunControllerTests: XCTestCase {
    func testStopCancelsTheActiveRunAndWaitsForItsCompletion() async {
        let controller = LocalFirstSyncRunController<Int>()
        let started = expectation(description: "sync operation started")
        var completion: Result<Int, any Error>?

        XCTAssertTrue(
            controller.start(
                operation: {
                    started.fulfill()
                    try await Task.sleep(for: .seconds(60))
                    return 42
                },
                completion: { result in
                    completion = result
                }
            )
        )
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(controller.state, .running)

        await controller.stop()

        XCTAssertEqual(controller.state, .idle)
        guard case let .failure(error) = completion else {
            return XCTFail("cancelled run did not report its completion")
        }
        XCTAssertTrue(error is CancellationError)
    }

    func testStartingWhileARunIsActiveIsRejected() async {
        let controller = LocalFirstSyncRunController<Int>()
        let started = expectation(description: "sync operation started")

        XCTAssertTrue(
            controller.start(
                operation: {
                    started.fulfill()
                    try await Task.sleep(for: .seconds(60))
                    return 1
                },
                completion: { _ in }
            )
        )
        await fulfillment(of: [started], timeout: 1)

        XCTAssertFalse(
            controller.start(
                operation: { 2 },
                completion: { _ in }
            )
        )
        await controller.stop()
    }
}
