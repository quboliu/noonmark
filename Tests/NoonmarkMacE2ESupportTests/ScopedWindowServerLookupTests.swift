import CoreGraphics
@testable import NoonmarkMacE2ESupport
import XCTest

final class ScopedWindowServerLookupTests: XCTestCase {
    func testLookupRequestsOnlyTheExactKnownWindowNumber() throws {
        var observedWindowID: CGWindowID?

        let snapshot = try XCTUnwrap(
            ScopedWindowServerLookup.snapshot(windowNumber: 42) { windowID in
                observedWindowID = windowID
                return [Self.record(windowNumber: 42)]
            }
        )

        XCTAssertEqual(observedWindowID, 42)
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

    func testExactLookupReportsEvidenceGradeFailureStages() {
        XCTAssertThrowsError(
            try ScopedWindowServerLookup.exactSnapshot(windowNumber: 0) { _ in
                XCTFail("invalid input must not reach the WindowServer query")
                return []
            }
        ) { error in
            XCTAssertEqual(
                error as? ScopedWindowServerLookupFailure,
                .invalidWindowNumber
            )
        }
        XCTAssertThrowsError(
            try ScopedWindowServerLookup.exactSnapshot(windowNumber: 42) { _ in
                nil
            }
        ) { error in
            XCTAssertEqual(
                error as? ScopedWindowServerLookupFailure,
                .queryUnavailable
            )
        }
        XCTAssertThrowsError(
            try ScopedWindowServerLookup.exactSnapshot(windowNumber: 42) { _ in
                []
            }
        ) { error in
            XCTAssertEqual(
                error as? ScopedWindowServerLookupFailure,
                .unexpectedRecordCount(0)
            )
        }
        XCTAssertThrowsError(
            try ScopedWindowServerLookup.exactSnapshot(windowNumber: 42) { _ in
                [Self.record(windowNumber: 41)]
            }
        ) { error in
            XCTAssertEqual(
                error as? ScopedWindowServerLookupFailure,
                .windowNumberMismatch
            )
        }
    }

    func testSnapshotEnvelopeUsesOneCanonicalBoundedSchema() throws {
        let snapshot = try ScopedWindowServerLookup.exactSnapshot(
            windowNumber: 42
        ) { _ in
            [Self.record(windowNumber: 42)]
        }
        let data = try ScopedWindowServerSnapshotEnvelope(
            snapshot: snapshot
        ).canonicalJSONData()

        XCTAssertEqual(
            try XCTUnwrap(String(bytes: data, encoding: .utf8)),
            "{\"alpha\":1,\"frame\":{\"height\":600,\"width\":800,"
                + "\"x\":10,\"y\":20},\"is_onscreen\":true,\"layer\":0,"
                + "\"owner_process_identifier\":123,\"schema_version\":1,"
                + "\"title\":\"Help\",\"window_number\":42}"
        )
        XCTAssertLessThan(data.count, 4096)
    }

    func testSnapshotEnvelopeRejectsOutputBeyondItsHardLimit() throws {
        let snapshot = try ScopedWindowServerLookup.exactSnapshot(
            windowNumber: 42
        ) { _ in
            [
                Self.record(
                    windowNumber: 42,
                    title: String(repeating: "x", count: 4096)
                )
            ]
        }

        XCTAssertThrowsError(
            try ScopedWindowServerSnapshotEnvelope(
                snapshot: snapshot
            ).canonicalJSONData()
        ) { error in
            guard let failure =
                error as? ScopedWindowServerSnapshotEncodingFailure
            else {
                return XCTFail("unexpected encoding error: \(error)")
            }
            guard case let .exceedsMaximumByteCount(actual, maximum) =
                failure
            else {
                return XCTFail("unexpected encoding error: \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, 4095)
        }
    }

    private static func record(
        windowNumber: CGWindowID,
        title: String = "Help"
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: windowNumber),
            kCGWindowOwnerPID as String: NSNumber(value: 123),
            kCGWindowName as String: title,
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
