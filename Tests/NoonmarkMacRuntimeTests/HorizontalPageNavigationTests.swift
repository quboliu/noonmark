import Foundation
@testable import NoonmarkMacRuntime
import XCTest

@MainActor
final class HorizontalPageNavigationTests: XCTestCase {
    func testDeviceDeltaIgnoresSystemScrollDirectionPreference() {
        XCTAssertEqual(
            HorizontalPageNavigationDeviceDelta.normalized(
                20,
                isDirectionInvertedFromDevice: false
            ),
            20
        )
        XCTAssertEqual(
            HorizontalPageNavigationDeviceDelta.normalized(
                -20,
                isDirectionInvertedFromDevice: true
            ),
            20
        )
        XCTAssertEqual(
            HorizontalPageNavigationDeviceDelta.normalized(
                20,
                isDirectionInvertedFromDevice: true
            ),
            -20
        )
    }

    func testBookDirectionKeepsLeftSwipeAsNextPage() {
        XCTAssertEqual(
            HorizontalPageNavigationSwipeDirection.book
                .resolve(.next),
            .next
        )
        XCTAssertEqual(
            HorizontalPageNavigationSwipeDirection.book
                .resolve(.previous),
            .previous
        )
    }

    func testReversedDirectionInvertsBothSwipeDirections() {
        XCTAssertEqual(
            HorizontalPageNavigationSwipeDirection.reversed
                .resolve(.next),
            .previous
        )
        XCTAssertEqual(
            HorizontalPageNavigationSwipeDirection.reversed
                .resolve(.previous),
            .next
        )
    }

    func testSwipeDirectionRepositoryDefaultsToBookAndPersistsLocally() {
        let suiteName = "HorizontalPageNavigationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = HorizontalSwipePreferenceRepository(
            defaults: defaults
        )

        XCTAssertEqual(repository.load(), .book)

        repository.save(.reversed)

        XCTAssertEqual(repository.load(), .reversed)
        defaults.set(
            "unsupported",
            forKey: HorizontalSwipePreferenceRepository
                .defaultStorageKey
        )
        XCTAssertEqual(repository.load(), .book)
    }

    func testLeftwardGestureNavigatesToNextPageOnce() {
        var recognizer = HorizontalPageNavigationRecognizer()

        XCTAssertNil(recognizer.consume(sample(phase: .began, x: 6, y: 1)))
        XCTAssertNil(recognizer.consume(sample(phase: .changed, x: 22, y: 2)))
        XCTAssertEqual(
            recognizer.consume(sample(phase: .changed, x: 24, y: 2)),
            .next
        )
        XCTAssertNil(recognizer.consume(sample(phase: .changed, x: 40, y: 1)))
        XCTAssertNil(recognizer.consume(sample(phase: .ended)))
    }

    func testRightwardGestureNavigatesToPreviousPage() {
        var recognizer = HorizontalPageNavigationRecognizer()

        XCTAssertNil(recognizer.consume(sample(phase: .began, x: -12, y: 1)))
        XCTAssertEqual(
            recognizer.consume(sample(phase: .changed, x: -38, y: 2)),
            .previous
        )
    }

    func testVerticalAndDiagonalScrollingDoNotNavigate() {
        var vertical = HorizontalPageNavigationRecognizer()
        XCTAssertNil(vertical.consume(sample(phase: .began, x: 2, y: 14)))
        XCTAssertNil(vertical.consume(sample(phase: .changed, x: 60, y: 1)))

        var directionChanged = HorizontalPageNavigationRecognizer()
        XCTAssertNil(
            directionChanged.consume(sample(phase: .began, x: 10, y: 1))
        )
        XCTAssertNil(
            directionChanged.consume(sample(phase: .changed, x: 40, y: 60))
        )

        var diagonal = HorizontalPageNavigationRecognizer()
        XCTAssertNil(diagonal.consume(sample(phase: .began, x: 16, y: 15)))
        XCTAssertNil(diagonal.consume(sample(phase: .changed, x: 34, y: 23)))
        XCTAssertNil(diagonal.consume(sample(phase: .ended)))
    }

    func testSubthresholdGestureDoesNotNavigate() {
        var recognizer = HorizontalPageNavigationRecognizer()

        XCTAssertNil(recognizer.consume(sample(phase: .began, x: 10, y: 1)))
        XCTAssertNil(recognizer.consume(sample(phase: .changed, x: 30, y: 2)))
        XCTAssertNil(recognizer.consume(sample(phase: .ended)))
    }

    func testNonPreciseAndStandaloneMomentumEventsAreIgnored() {
        var recognizer = HorizontalPageNavigationRecognizer()

        XCTAssertNil(
            recognizer.consume(
                sample(phase: .began, x: 60, isPrecise: false)
            )
        )
        XCTAssertNil(
            recognizer.consume(
                sample(phase: .changed, x: 60)
            )
        )

        var standaloneMomentum = HorizontalPageNavigationRecognizer()
        XCTAssertNil(
            standaloneMomentum.consume(
                sample(phase: .began, x: 60, isMomentum: true)
            )
        )
    }

    func testMomentumContinuationCanCompleteStartedGestureOnce() {
        var recognizer = HorizontalPageNavigationRecognizer()

        XCTAssertNil(recognizer.consume(sample(phase: .began, x: 2)))
        XCTAssertNil(recognizer.consume(sample(phase: .changed)))
        XCTAssertNil(recognizer.consume(sample(phase: .ended)))
        XCTAssertNil(
            recognizer.consume(
                sample(phase: .began, x: 25, isMomentum: true)
            )
        )
        XCTAssertEqual(
            recognizer.consume(
                sample(phase: .changed, x: 30, isMomentum: true)
            ),
            .next
        )
        XCTAssertNil(
            recognizer.consume(
                sample(phase: .changed, x: 500, isMomentum: true)
            )
        )
        XCTAssertNil(
            recognizer.consume(
                sample(phase: .ended, isMomentum: true)
            )
        )
    }

    func testMomentumDoesNotNavigateAgainAfterPhysicalGestureTriggered() {
        var recognizer = HorizontalPageNavigationRecognizer()

        XCTAssertEqual(
            recognizer.consume(sample(phase: .began, x: 50)),
            .next
        )
        XCTAssertNil(recognizer.consume(sample(phase: .ended)))
        XCTAssertNil(
            recognizer.consume(
                sample(phase: .began, x: 500, isMomentum: true)
            )
        )
    }

    func testChangedEventWithoutGestureStartIsIgnored() {
        var recognizer = HorizontalPageNavigationRecognizer()

        XCTAssertNil(recognizer.consume(sample(phase: .changed, x: 60)))
    }

    func testEndedGestureResetsRecognizerForNextGesture() {
        var recognizer = HorizontalPageNavigationRecognizer()

        XCTAssertEqual(
            recognizer.consume(sample(phase: .began, x: 50)),
            .next
        )
        XCTAssertNil(recognizer.consume(sample(phase: .ended)))
        XCTAssertEqual(
            recognizer.consume(sample(phase: .began, x: -50)),
            .previous
        )
    }

    private func sample(
        phase: HorizontalPageNavigationPhase,
        x: Double = 0,
        y: Double = 0,
        isMomentum: Bool = false,
        isPrecise: Bool = true
    ) -> HorizontalPageNavigationSample {
        HorizontalPageNavigationSample(
            deltaX: x,
            deltaY: y,
            phase: phase,
            isMomentum: isMomentum,
            isPrecise: isPrecise
        )
    }
}
