import CryptoKit
import Foundation
import NoonmarkCore

public enum ClassificationBaselineEnvelopeError:
    Error,
    Equatable,
    Sendable
{
    case unsupportedFormatVersion(Int)
    case invalidCreatedAt
    case invalidClassificationState
    case integrityDigestMismatch
    case nonCanonicalEncoding
}

/// 首次同步一份既存分类历史时使用的不可变基线。
///
/// 普通分类修改仍由 `ClassificationCommitEnvelope` 和
/// `TraceClassificationEventEnvelope` 表达；本类型只解决“完整历史已经存在，
/// 但本机没有旧 mutation journal”的空接收端 bootstrap 边界。它不携带
/// 可重放 delta，因此不得整块推进已经拥有分类历史的接收端。
public struct ClassificationBaselineEnvelope:
    Codable,
    Equatable,
    Sendable
{
    public static let currentFormatVersion = 1

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case baselineID
        case createdAtBitPattern
        case classificationPayload
        case integrityDigest
    }

    public let formatVersion: Int
    public let baselineID: UUID
    public let createdAt: Date
    private let classificationPayload: Data
    public let integrityDigest: String

    public init(
        baselineID: UUID = UUID(),
        state: TaskClassificationState,
        createdAt: Date = Date()
    ) throws {
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ClassificationBaselineEnvelopeError.invalidCreatedAt
        }
        do {
            try state.validateIntegrity()
        } catch {
            throw ClassificationBaselineEnvelopeError
                .invalidClassificationState
        }

        formatVersion = Self.currentFormatVersion
        self.baselineID = baselineID
        self.createdAt = createdAt
        classificationPayload = try Self.encodeState(state)
        integrityDigest = Self.digest(
            formatVersion: formatVersion,
            baselineID: baselineID,
            createdAt: createdAt,
            classificationPayload: classificationPayload
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(
            Int.self,
            forKey: .formatVersion
        )
        guard formatVersion == Self.currentFormatVersion else {
            throw ClassificationBaselineEnvelopeError
                .unsupportedFormatVersion(formatVersion)
        }
        let baselineID = try container.decode(
            UUID.self,
            forKey: .baselineID
        )
        let createdAtSeconds = Double(
            bitPattern: try container.decode(
                UInt64.self,
                forKey: .createdAtBitPattern
            )
        )
        guard createdAtSeconds.isFinite else {
            throw ClassificationBaselineEnvelopeError.invalidCreatedAt
        }
        let createdAt = Date(
            timeIntervalSinceReferenceDate: createdAtSeconds
        )
        let classificationPayload = try container.decode(
            Data.self,
            forKey: .classificationPayload
        )
        let integrityDigest = try container.decode(
            String.self,
            forKey: .integrityDigest
        )
        guard integrityDigest == Self.digest(
            formatVersion: formatVersion,
            baselineID: baselineID,
            createdAt: createdAt,
            classificationPayload: classificationPayload
        ) else {
            throw ClassificationBaselineEnvelopeError
                .integrityDigestMismatch
        }

        let state = try Self.decodeState(classificationPayload)
        do {
            try state.validateIntegrity()
        } catch {
            throw ClassificationBaselineEnvelopeError
                .invalidClassificationState
        }

        self.formatVersion = formatVersion
        self.baselineID = baselineID
        self.createdAt = createdAt
        self.classificationPayload = classificationPayload
        self.integrityDigest = integrityDigest
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(baselineID, forKey: .baselineID)
        try container.encode(
            createdAt.timeIntervalSinceReferenceDate.bitPattern,
            forKey: .createdAtBitPattern
        )
        try container.encode(
            classificationPayload,
            forKey: .classificationPayload
        )
        try container.encode(integrityDigest, forKey: .integrityDigest)
    }

    public func classificationState() throws -> TaskClassificationState {
        guard integrityDigest == Self.digest(
            formatVersion: formatVersion,
            baselineID: baselineID,
            createdAt: createdAt,
            classificationPayload: classificationPayload
        ) else {
            throw ClassificationBaselineEnvelopeError
                .integrityDigestMismatch
        }
        return try Self.decodeState(classificationPayload)
    }

    public func canonicalData() throws -> Data {
        _ = try classificationState()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(
        _ data: Data
    ) throws -> ClassificationBaselineEnvelope {
        let envelope = try JSONDecoder().decode(Self.self, from: data)
        guard try envelope.canonicalData() == data else {
            throw ClassificationBaselineEnvelopeError.nonCanonicalEncoding
        }
        return envelope
    }

    private static func encodeState(
        _ state: TaskClassificationState
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    private static func decodeState(
        _ data: Data
    ) throws -> TaskClassificationState {
        do {
            return try JSONDecoder().decode(
                TaskClassificationState.self,
                from: data
            )
        } catch {
            throw ClassificationBaselineEnvelopeError
                .invalidClassificationState
        }
    }

    private static func digest(
        formatVersion: Int,
        baselineID: UUID,
        createdAt: Date,
        classificationPayload: Data
    ) -> String {
        var evidence = Data(
            "noonmark.classification-baseline.v1".utf8
        )
        func append(_ data: Data) {
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) {
                evidence.append(contentsOf: $0)
            }
            evidence.append(data)
        }
        append(Data(String(formatVersion).utf8))
        append(Data(baselineID.uuidString.utf8))
        var dateBits = createdAt.timeIntervalSinceReferenceDate
            .bitPattern.bigEndian
        withUnsafeBytes(of: &dateBits) {
            append(Data($0))
        }
        append(classificationPayload)
        return SHA256.hash(data: evidence)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

extension TaskClassificationState {
    /// 判断接收端状态是否保留了基线中的全部不可变历史证据。
    ///
    /// 当前 category / label / relation 值可以继续演进；是否属于同一条历史，
    /// 由 commit、receipt、tombstone、merge 和 trace event 的精确包含关系决定。
    func containsClassificationHistory(
        from baseline: TaskClassificationState
    ) -> Bool {
        guard revision >= baseline.revision,
              baseline.changeRecords.allSatisfy(changeRecords.contains),
              baseline.relationHistory.allSatisfy(
                  relationHistory.contains
              ),
              baseline.categoryMerges.allSatisfy({
                  categoryMerges[$0.key] == $0.value
              }),
              baseline.labelMerges.allSatisfy({
                  labelMerges[$0.key] == $0.value
              }),
              baseline.categoryDeletionTombstones.allSatisfy({
                  categoryDeletionTombstones[$0.key] == $0.value
              }),
              baseline.labelDeletionTombstones.allSatisfy({
                  labelDeletionTombstones[$0.key] == $0.value
              }),
              baseline.committedReceiptsByInteractionID.allSatisfy({
                  committedReceiptsByInteractionID[$0.key] == $0.value
              })
        else {
            return false
        }

        return baseline.snapshotEventsByTraceID.allSatisfy {
            let localEvents = snapshotEventsByTraceID[$0.key] ?? []
            return localEvents.count >= $0.value.count
                && Array(localEvents.prefix($0.value.count)) == $0.value
        }
    }
}
