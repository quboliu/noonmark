import Foundation
@testable import NoonmarkMacRuntime
import XCTest

final class RevisionMemoTests: XCTestCase {
    func testSameRevisionComputesOnlyOnce() {
        var memo = RevisionMemo<UInt64, Int>()
        var computeCount = 0

        let first = memo.value(at: 1) {
            computeCount += 1
            return 10
        }
        let second = memo.value(at: 1) {
            computeCount += 1
            return 20
        }

        XCTAssertEqual(first, 10)
        XCTAssertEqual(second, 10)
        XCTAssertEqual(computeCount, 1)
    }

    func testRevisionChangeRecomputes() {
        var memo = RevisionMemo<UInt64, Int>()
        var computeCount = 0

        let first = memo.value(at: 1) {
            computeCount += 1
            return computeCount
        }
        let second = memo.value(at: 2) {
            computeCount += 1
            return computeCount
        }

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(computeCount, 2)
    }

    func testInvalidateForcesRecomputeAtSameRevision() {
        var memo = RevisionMemo<UInt64, Int>()
        var computeCount = 0

        _ = memo.value(at: 7) {
            computeCount += 1
            return computeCount
        }
        memo.invalidate()
        let value = memo.value(at: 7) {
            computeCount += 1
            return computeCount
        }

        XCTAssertEqual(value, 2)
        XCTAssertEqual(computeCount, 2)
    }

    func testKeyedMemoCachesEachKeyIndependentlyWithinSameRevision() {
        var memo = KeyedRevisionMemo<UInt64, String, Int>()
        var computedKeys: [String] = []

        let a1 = memo.value(for: "a", at: 1) { key in
            computedKeys.append(key)
            return 1
        }
        let b1 = memo.value(for: "b", at: 1) { key in
            computedKeys.append(key)
            return 2
        }
        let a2 = memo.value(for: "a", at: 1) { key in
            computedKeys.append(key)
            return 3
        }

        XCTAssertEqual(a1, 1)
        XCTAssertEqual(b1, 2)
        XCTAssertEqual(a2, 1)
        XCTAssertEqual(computedKeys, ["a", "b"])
    }

    func testKeyedMemoRevisionChangeInvalidatesAllKeys() {
        var memo = KeyedRevisionMemo<UInt64, String, Int>()
        var computeCount = 0

        _ = memo.value(for: "a", at: 1) { _ in
            computeCount += 1
            return computeCount
        }
        _ = memo.value(for: "b", at: 1) { _ in
            computeCount += 1
            return computeCount
        }
        let recomputed = memo.value(for: "a", at: 2) { _ in
            computeCount += 1
            return computeCount
        }

        XCTAssertEqual(recomputed, 3)
        XCTAssertEqual(computeCount, 3)
        XCTAssertEqual(memo.cachedRevision, 2)
    }
}
