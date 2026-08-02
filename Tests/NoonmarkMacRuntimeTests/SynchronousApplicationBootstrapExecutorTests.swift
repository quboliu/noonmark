import Darwin
import Foundation
@testable import NoonmarkMacRuntime
import XCTest

final class SynchronousApplicationBootstrapExecutorTests: XCTestCase {
    private enum ExpectedFailure: Error {
        case rejected
    }

    private struct PreparedValue: Equatable {
        let value: String
        let ranOnMainThread: Bool
    }

    @MainActor
    func testRunWaitsForAsyncPreparationAwayFromMainThread() throws {
        let prepared = try SynchronousApplicationBootstrapExecutor.run {
            await Task.yield()
            return PreparedValue(
                value: "prepared",
                ranOnMainThread: pthread_main_np() != 0
            )
        }

        XCTAssertEqual(
            prepared,
            PreparedValue(value: "prepared", ranOnMainThread: false)
        )
    }

    @MainActor
    func testRunPropagatesPreparationFailure() {
        let operation: @Sendable () async throws -> Int = {
            await Task.yield()
            throw ExpectedFailure.rejected
        }
        XCTAssertThrowsError(
            try SynchronousApplicationBootstrapExecutor.run(
                operation: operation
            )
        ) { error in
            XCTAssertTrue(error is ExpectedFailure)
        }
    }
}
