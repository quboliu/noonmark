import Foundation

public enum ScopedWindowServerSnapshotEncodingFailure: Error, Equatable {
    case invalidMaximumByteCount
    case exceedsMaximumByteCount(actual: Int, maximum: Int)
}

public struct ScopedWindowServerFrameEnvelope: Encodable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct ScopedWindowServerSnapshotEnvelope: Encodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let windowNumber: UInt32
    public let ownerProcessIdentifier: Int32?
    public let title: String?
    public let layer: Int?
    public let isOnscreen: Bool
    public let alpha: Double?
    public let frame: ScopedWindowServerFrameEnvelope?

    public init(snapshot: ScopedWindowServerSnapshot) {
        schemaVersion = 1
        windowNumber = snapshot.windowNumber
        ownerProcessIdentifier = snapshot.ownerProcessID
        title = snapshot.title
        layer = snapshot.layer
        isOnscreen = snapshot.isOnscreen
        alpha = snapshot.alpha
        frame = snapshot.frame.map {
            ScopedWindowServerFrameEnvelope(
                x: $0.origin.x,
                y: $0.origin.y,
                width: $0.size.width,
                height: $0.size.height
            )
        }
    }

    public func canonicalJSONData(
        maximumByteCount: Int = 4095
    ) throws -> Data {
        guard maximumByteCount > 0 else {
            throw ScopedWindowServerSnapshotEncodingFailure
                .invalidMaximumByteCount
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= maximumByteCount else {
            throw ScopedWindowServerSnapshotEncodingFailure
                .exceedsMaximumByteCount(
                    actual: data.count,
                    maximum: maximumByteCount
                )
        }
        return data
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case windowNumber = "window_number"
        case ownerProcessIdentifier = "owner_process_identifier"
        case title
        case layer
        case isOnscreen = "is_onscreen"
        case alpha
        case frame
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(windowNumber, forKey: .windowNumber)
        if let ownerProcessIdentifier {
            try container.encode(
                ownerProcessIdentifier,
                forKey: .ownerProcessIdentifier
            )
        } else {
            try container.encodeNil(forKey: .ownerProcessIdentifier)
        }
        if let title {
            try container.encode(title, forKey: .title)
        } else {
            try container.encodeNil(forKey: .title)
        }
        if let layer {
            try container.encode(layer, forKey: .layer)
        } else {
            try container.encodeNil(forKey: .layer)
        }
        try container.encode(isOnscreen, forKey: .isOnscreen)
        if let alpha {
            try container.encode(alpha, forKey: .alpha)
        } else {
            try container.encodeNil(forKey: .alpha)
        }
        if let frame {
            try container.encode(frame, forKey: .frame)
        } else {
            try container.encodeNil(forKey: .frame)
        }
    }
}
