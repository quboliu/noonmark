import CoreGraphics
@testable import NoonmarkMacE2ESupport
import XCTest

final class ScopedWindowServerLookupTests: XCTestCase {
    func testLookupRequestsOnlyTheExactKnownWindowNumber() throws {
        var observedWindowIDs: [CGWindowID] = []

        let snapshot = try XCTUnwrap(
            ScopedWindowServerLookup.snapshot(windowNumber: 42) { windowIDs in
                observedWindowIDs = windowIDs
                return [Self.record(windowNumber: 42)]
            }
        )

        XCTAssertEqual(observedWindowIDs, [42])
        XCTAssertEqual(snapshot.windowNumber, 42)
        XCTAssertEqual(snapshot.ownerProcessID, 123)
        XCTAssertEqual(snapshot.title, "Help")
        XCTAssertEqual(snapshot.layer, 0)
        XCTAssertTrue(snapshot.isOnscreen)
        XCTAssertEqual(snapshot.alpha, 1)
        XCTAssertEqual(snapshot.frame, CGRect(x: 10, y: 20, width: 800, height: 600))
    }

    func testLookupRejectsAnythingOtherThanOneExactReturnedWindow() {
        XCTAssertNil(
            ScopedWindowServerLookup.snapshot(windowNumber: 42) { _ in [] }
        )
        XCTAssertNil(
            ScopedWindowServerLookup.snapshot(windowNumber: 42) { _ in
                [Self.record(windowNumber: 41)]
            }
        )
        XCTAssertNil(
            ScopedWindowServerLookup.snapshot(windowNumber: 42) { _ in
                [
                    Self.record(windowNumber: 42),
                    Self.record(windowNumber: 42)
                ]
            }
        )
    }

    private static func record(windowNumber: CGWindowID) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: windowNumber),
            kCGWindowOwnerPID as String: NSNumber(value: 123),
            kCGWindowName as String: "Help",
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowIsOnscreen as String: NSNumber(value: true),
            kCGWindowAlpha as String: NSNumber(value: 1.0),
            kCGWindowBounds as String: [
                "X": NSNumber(value: 10),
                "Y": NSNumber(value: 20),
                "Width": NSNumber(value: 800),
                "Height": NSNumber(value: 600)
            ]
        ]
    }
}
