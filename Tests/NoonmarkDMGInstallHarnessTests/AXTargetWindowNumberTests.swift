import ApplicationServices
@testable import NoonmarkDMGInstallHarness
import XCTest

final class AXTargetWindowNumberTests: XCTestCase {
    func testWindowNumberComesDirectlyFromTheExactAXWindow() {
        let target = AXTarget(pid: getpid())

        let number = target.windowNumber(target.application) { _, output in
            output.pointee = 42
            return .success
        }

        XCTAssertEqual(number, 42)
    }

    func testWindowNumberRejectsAnAXFailureOrNullIdentity() {
        let target = AXTarget(pid: getpid())

        XCTAssertNil(
            target.windowNumber(target.application, resolver: nil)
        )
        XCTAssertNil(
            target.windowNumber(target.application) { _, output in
                output.pointee = 42
                return .cannotComplete
            }
        )
        XCTAssertNil(
            target.windowNumber(target.application) { _, output in
                output.pointee = 0
                return .success
            }
        )
    }
}
