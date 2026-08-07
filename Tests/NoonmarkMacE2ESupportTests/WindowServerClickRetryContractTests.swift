import NoonmarkMacE2ESupport
import XCTest

final class WindowServerClickRetryContractTests: XCTestCase {
    func testPostMouseDownActivationFailureCannotPostASecondMouseDown() {
        var mouseDownCount = 0
        let failurePhases: [WindowServerClickFailurePhase] = [
            .afterMouseDown,
            .afterMouseDown
        ]

        for (attemptIndex, phase) in failurePhases.enumerated() {
            mouseDownCount += 1
            guard WindowServerClickRetryContract.shouldRetry(
                failurePhase: phase,
                attemptIndex: attemptIndex,
                maximumAttempts: 3
            ) else {
                break
            }
        }

        XCTAssertEqual(mouseDownCount, 1)
    }

    func testTypedCleanupFailurePreservesPostMouseDownPhase() {
        let error: Error = FixtureFailure(phase: .afterMouseDown)

        XCTAssertEqual(
            WindowServerClickRetryContract.failurePhase(for: error),
            .afterMouseDown
        )
        XCTAssertFalse(
            WindowServerClickRetryContract.shouldRetry(
                failurePhase: WindowServerClickRetryContract.failurePhase(
                    for: error
                ),
                attemptIndex: 0,
                maximumAttempts: 3
            )
        )
    }

    func testPreMouseDownActivationFailureAllowsOneBoundedRetry() {
        XCTAssertTrue(
            WindowServerClickRetryContract.shouldRetry(
                failurePhase: .beforeMouseDown,
                attemptIndex: 0,
                maximumAttempts: 3
            )
        )
        XCTAssertFalse(
            WindowServerClickRetryContract.shouldRetry(
                failurePhase: .beforeMouseDown,
                attemptIndex: 2,
                maximumAttempts: 3
            )
        )
    }

    func testUnphasedFailureIsUnknownAndCannotRetry() {
        let phase = WindowServerClickRetryContract.failurePhase(
            for: UnphasedFailure()
        )

        XCTAssertEqual(phase, .unknown)
        XCTAssertFalse(
            WindowServerClickRetryContract.shouldRetry(
                failurePhase: phase,
                attemptIndex: 0,
                maximumAttempts: 3
            )
        )
    }

    func testExplicitPreMouseDownFailureSurvivesErrorErasure() {
        let error: Error = FixtureFailure(phase: .beforeMouseDown)

        XCTAssertEqual(
            WindowServerClickRetryContract.failurePhase(for: error),
            .beforeMouseDown
        )
    }

    private struct FixtureFailure: WindowServerClickPhasedFailure {
        let clickFailurePhase: WindowServerClickFailurePhase

        init(phase: WindowServerClickFailurePhase) {
            clickFailurePhase = phase
        }
    }

    private struct UnphasedFailure: Error {}
}
