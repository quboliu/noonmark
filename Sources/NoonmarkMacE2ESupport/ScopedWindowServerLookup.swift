import CoreGraphics
import Foundation

public struct ScopedWindowServerSnapshot: Equatable {
    public let windowNumber: CGWindowID
    public let ownerProcessID: pid_t?
    public let title: String?
    public let layer: Int?
    public let isOnscreen: Bool
    public let alpha: Double?
    public let frame: CGRect?
}

/// Reads WindowServer metadata only after the caller has obtained one exact
/// window number from its already-scoped AX or AppKit target.
public enum ScopedWindowServerLookup {
    public typealias Query = ([CGWindowID]) -> [[String: Any]]?

    public static func snapshot(
        windowNumber: CGWindowID
    ) -> ScopedWindowServerSnapshot? {
        snapshot(windowNumber: windowNumber) { exactWindowIDs in
            let identifiers = exactWindowIDs.map(NSNumber.init(value:)) as CFArray
            return CGWindowListCreateDescriptionFromArray(
                identifiers
            ) as? [[String: Any]]
        }
    }

    public static func snapshot(
        windowNumber: CGWindowID,
        query: Query
    ) -> ScopedWindowServerSnapshot? {
        guard windowNumber > 0,
              let records = query([windowNumber]),
              records.count == 1
        else {
            return nil
        }
        let record = records[0]
        guard let returnedNumber = (
            record[kCGWindowNumber as String] as? NSNumber
        )?.uint32Value,
            returnedNumber == windowNumber
        else {
            return nil
        }
        return ScopedWindowServerSnapshot(
            windowNumber: returnedNumber,
            ownerProcessID: (
                record[kCGWindowOwnerPID as String] as? NSNumber
            )?.int32Value,
            title: record[kCGWindowName as String] as? String,
            layer: (
                record[kCGWindowLayer as String] as? NSNumber
            )?.intValue,
            isOnscreen: (
                record[kCGWindowIsOnscreen as String] as? NSNumber
            )?.boolValue == true,
            alpha: (
                record[kCGWindowAlpha as String] as? NSNumber
            )?.doubleValue,
            frame: frame(from: record[kCGWindowBounds as String])
        )
    }

    private static func frame(from value: Any?) -> CGRect? {
        guard let bounds = value as? [String: Any],
              let x = (bounds["X"] as? NSNumber)?.doubleValue,
              let y = (bounds["Y"] as? NSNumber)?.doubleValue,
              let width = (bounds["Width"] as? NSNumber)?.doubleValue,
              let height = (bounds["Height"] as? NSNumber)?.doubleValue
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
