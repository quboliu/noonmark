import Foundation
import SuntraceCore

public enum TraceClassificationEventEnvelopeError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case invalidEvent(String)
    case noncanonicalPayload
}

/// 一条 immutable 的轨迹分类快照事件。事件 UUID 是独立 wire identity，
/// `predecessorEventID` 则把同一 trace 的 append-only 历史连成显式因果链。
public struct TraceClassificationEventEnvelope: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case event
        case predecessorEventID
    }

    public let formatVersion: Int
    public let event: TraceClassificationSnapshot
    public let predecessorEventID: UUID?

    public init(
        event: TraceClassificationSnapshot,
        predecessorEventID: UUID?
    ) throws {
        formatVersion = Self.currentFormatVersion
        self.event = event
        self.predecessorEventID = predecessorEventID
        try validateStandaloneFacts()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == Self.currentFormatVersion else {
            throw TraceClassificationEventEnvelopeError.unsupportedFormatVersion(
                formatVersion
            )
        }
        self.formatVersion = formatVersion
        event = try container.decode(
            TraceClassificationSnapshot.self,
            forKey: .event
        )
        predecessorEventID = try container.decodeIfPresent(
            UUID.self,
            forKey: .predecessorEventID
        )
        try validateStandaloneFacts()
    }

    public func encode(to encoder: Encoder) throws {
        try validateStandaloneFacts()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(event, forKey: .event)
        try container.encodeIfPresent(
            predecessorEventID,
            forKey: .predecessorEventID
        )
    }

    public static func decode(_ data: Data) throws -> Self {
        let envelope = try decoder().decode(Self.self, from: data)
        guard try envelope.canonicalData() == data else {
            throw TraceClassificationEventEnvelopeError.noncanonicalPayload
        }
        return envelope
    }

    public func canonicalData() throws -> Data {
        try validateStandaloneFacts()
        return try Self.encoder().encode(self)
    }

    private func validateStandaloneFacts() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw TraceClassificationEventEnvelopeError.unsupportedFormatVersion(
                formatVersion
            )
        }
        guard event.revision > 0 else {
            throw TraceClassificationEventEnvelopeError.invalidEvent(
                "trace classification event revision must be positive"
            )
        }
        guard event.capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw TraceClassificationEventEnvelopeError.invalidEvent(
                "trace classification event capturedAt must be finite"
            )
        }
        guard Set(event.labels.map(\.id)).count == event.labels.count else {
            throw TraceClassificationEventEnvelopeError.invalidEvent(
                "trace classification event labels must be unique"
            )
        }
        guard predecessorEventID != event.id else {
            throw TraceClassificationEventEnvelopeError.invalidEvent(
                "trace classification event cannot precede itself"
            )
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let seconds = date.timeIntervalSinceReferenceDate
            guard seconds.isFinite else {
                throw EncodingError.invalidValue(
                    date,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "event date must be finite"
                    )
                )
            }
            try container.encode(seconds.bitPattern)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let seconds = Double(bitPattern: try container.decode(UInt64.self))
            guard seconds.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "event date must be finite"
                )
            }
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return decoder
    }
}
