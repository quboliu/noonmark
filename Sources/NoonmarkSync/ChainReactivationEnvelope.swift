import Foundation
import NoonmarkCore

enum ChainReactivationEnvelopeError: Error, Equatable {
    case unsupportedFormatVersion(Int)
    case invalidWitness(String)
    case noncanonicalPayload
}

/// 一次真实「恢复废弃」或 snapshot redo 操作留下的 immutable 同步见证。
///
/// current chain/trace 只能描述最终状态，无法证明 active/pending 是恢复废弃产生，
/// 还是旧分支经其他操作碰巧形成。见证因此携带操作边界两侧的完整事实；接收端
/// 只有同时观察到精确的废弃前态与恢复后态时，才允许反转废弃历史。
struct ChainReactivationEnvelope: Codable, Equatable {
    static let currentFormatVersion = 2

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case operationID
        case abandonedChain
        case restoredChain
        case abandonedTrace
        case restoredTrace
    }

    let formatVersion: Int
    let operationID: UUID
    let abandonedChain: TaskChain
    let restoredChain: TaskChain
    let abandonedTrace: DayTrace?
    let restoredTrace: DayTrace?

    init(
        operationID: UUID = UUID(),
        abandonedChain: TaskChain,
        restoredChain: TaskChain,
        abandonedTrace: DayTrace? = nil,
        restoredTrace: DayTrace? = nil
    ) throws {
        formatVersion = Self.currentFormatVersion
        self.operationID = operationID
        self.abandonedChain = abandonedChain
        self.restoredChain = restoredChain
        self.abandonedTrace = abandonedTrace
        self.restoredTrace = restoredTrace
        try validateStandaloneFacts()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == Self.currentFormatVersion else {
            throw ChainReactivationEnvelopeError.unsupportedFormatVersion(
                formatVersion
            )
        }
        self.formatVersion = formatVersion
        operationID = try container.decode(UUID.self, forKey: .operationID)
        abandonedChain = try container.decode(
            TaskChain.self,
            forKey: .abandonedChain
        )
        restoredChain = try container.decode(
            TaskChain.self,
            forKey: .restoredChain
        )
        abandonedTrace = try container.decodeIfPresent(
            DayTrace.self,
            forKey: .abandonedTrace
        )
        restoredTrace = try container.decodeIfPresent(
            DayTrace.self,
            forKey: .restoredTrace
        )
        try validateStandaloneFacts()
    }

    func encode(to encoder: Encoder) throws {
        try validateStandaloneFacts()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(abandonedChain, forKey: .abandonedChain)
        try container.encode(restoredChain, forKey: .restoredChain)
        try container.encodeIfPresent(
            abandonedTrace,
            forKey: .abandonedTrace
        )
        try container.encodeIfPresent(
            restoredTrace,
            forKey: .restoredTrace
        )
    }

    static func decode(_ data: Data) throws -> Self {
        let envelope = try decoder().decode(Self.self, from: data)
        guard try envelope.canonicalData() == data else {
            throw ChainReactivationEnvelopeError.noncanonicalPayload
        }
        return envelope
    }

    func canonicalData() throws -> Data {
        try validateStandaloneFacts()
        return try Self.encoder().encode(self)
    }

    var reactivatedAt: Date { restoredChain.updatedAt }

    /// 判断 current records 是否是见证中恢复边界的单向合法后继。
    ///
    /// 首次上传前可以继续编辑，因此接收端不能要求再次看到瞬时 restored
    /// shape；但 current facts 也不能丢失恢复边界已经存在的 note CRDT facts，
    /// 或倒退到更早的 owner clock。
    func authorizesRestoredSuccessor(
        chain currentChain: TaskChain,
        trace currentTrace: DayTrace?
    ) -> Bool {
        guard currentChain.id == restoredChain.id,
              currentChain.createdAt == restoredChain.createdAt,
              currentChain.state == .active,
              currentChain.updatedAt >= restoredChain.updatedAt,
              noteFacts(
                  in: currentChain.noteEntries,
                  contain: restoredChain.noteEntries
              )
        else {
            return false
        }

        guard let restoredTrace else {
            return abandonedTrace == nil && currentTrace == nil
        }
        guard abandonedTrace != nil,
              let currentTrace,
              traceIdentityMatches(currentTrace, restoredTrace),
              currentTrace.contentUpdatedAt
              >= restoredTrace.contentUpdatedAt,
              traceStatusCanFollowRestoration(
                  currentTrace.status,
                  restoredStatus: restoredTrace.status
              ),
              noteFacts(
                  in: currentTrace.noteEntries,
                  contain: restoredTrace.noteEntries
              )
        else {
            return false
        }
        guard currentTrace.contentUpdatedAt == restoredTrace.contentUpdatedAt else {
            return true
        }
        return traceBaseFieldsMatch(currentTrace, restoredTrace)
    }

    private func validateStandaloneFacts() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw ChainReactivationEnvelopeError.unsupportedFormatVersion(
                formatVersion
            )
        }
        guard abandonedChain.id == restoredChain.id,
              abandonedChain.createdAt == restoredChain.createdAt,
              abandonedChain.state == .abandoned,
              restoredChain.state == .active,
              abandonedChain.noteEntries == restoredChain.noteEntries,
              restoredChain.updatedAt > abandonedChain.updatedAt
        else {
            throw ChainReactivationEnvelopeError.invalidWitness(
                "chain facts do not form one reactivation boundary"
            )
        }
        guard (abandonedTrace == nil) == (restoredTrace == nil) else {
            throw ChainReactivationEnvelopeError.invalidWitness(
                "reactivation trace boundary is incomplete"
            )
        }
        guard let abandonedTrace, let restoredTrace else {
            return
        }
        guard abandonedChain.updatedAt
                == abandonedTrace.contentUpdatedAt,
              abandonedChain.updatedAt == abandonedTrace.settledAt,
              restoredChain.updatedAt == restoredTrace.contentUpdatedAt,
              abandonedTrace.chainID == abandonedChain.id,
              restoredTrace.chainID == restoredChain.id
        else {
            throw ChainReactivationEnvelopeError.invalidWitness(
                "trace facts do not share the chain restoration clock"
            )
        }
        if abandonedTrace.status == .abandoned {
            let validRestoredStatus = restoredTrace.status == .pending
                && restoredTrace.settledAt == nil
                || restoredTrace.status == .unfinished
                && restoredTrace.settledAt
                == abandonedTrace.settledAt
            guard validRestoredStatus,
                  traceIdentityAndContentMatch(
                      abandonedTrace,
                      restoredTrace
                  )
            else {
                throw ChainReactivationEnvelopeError.invalidWitness(
                    "trace facts do not form one abandoned reactivation boundary"
                )
            }
            return
        }
        guard abandonedTrace.status == .cancelledDraft,
              restoredTrace.status == .pending,
              abandonedTrace.draftCancellationID != nil,
              abandonedTrace.draftCancelledOn != nil,
              abandonedTrace.settledAt != nil,
              restoredTrace.draftCancellationID
              == abandonedTrace.draftCancellationID,
              restoredTrace.draftCancelledOn == nil,
              restoredTrace.settledAt == nil,
              snapshotUndoTraceIdentityAndContentMatch(
                  abandonedTrace,
                  restoredTrace
              )
        else {
            throw ChainReactivationEnvelopeError.invalidWitness(
                "trace facts do not form one snapshot redo boundary"
            )
        }
    }

    private func traceIdentityAndContentMatch(
        _ abandoned: DayTrace,
        _ restored: DayTrace
    ) -> Bool {
        abandoned.id == restored.id
            && abandoned.chainID == restored.chainID
            && abandoned.definitionID == restored.definitionID
            && abandoned.date == restored.date
            && abandoned.priority == restored.priority
            && abandoned.continuationSeq == restored.continuationSeq
            && abandoned.descriptionText == restored.descriptionText
            && abandoned.noteEntries == restored.noteEntries
            && abandoned.manualProgressPercent == restored.manualProgressPercent
            && abandoned.continuedFromTraceID == restored.continuedFromTraceID
            && abandoned.changedToTraceID == restored.changedToTraceID
            && abandoned.createdAt == restored.createdAt
            && abandoned.completedAt == restored.completedAt
            && abandoned.draftCancellationID == restored.draftCancellationID
            && abandoned.draftCancelledOn == restored.draftCancelledOn
    }

    private func traceIdentityMatches(
        _ current: DayTrace,
        _ restored: DayTrace
    ) -> Bool {
        current.id == restored.id
            && current.chainID == restored.chainID
            && current.continuationSeq == restored.continuationSeq
            && current.continuedFromTraceID == restored.continuedFromTraceID
            && current.createdAt == restored.createdAt
    }

    private func traceStatusCanFollowRestoration(
        _ current: TraceStatus,
        restoredStatus: TraceStatus
    ) -> Bool {
        switch restoredStatus {
        case .pending:
            current != .abandoned
        case .unfinished:
            current == .unfinished || current == .continued
        case .completed, .continued, .changed, .returnedToPool,
             .cancelledDraft, .abandoned:
            false
        }
    }

    private func snapshotUndoTraceIdentityAndContentMatch(
        _ cancelled: DayTrace,
        _ restored: DayTrace
    ) -> Bool {
        cancelled.id == restored.id
            && cancelled.chainID == restored.chainID
            && cancelled.definitionID == restored.definitionID
            && cancelled.date == restored.date
            && cancelled.priority == restored.priority
            && cancelled.continuationSeq == restored.continuationSeq
            && cancelled.descriptionText == restored.descriptionText
            && cancelled.noteEntries == restored.noteEntries
            && cancelled.manualProgressPercent
            == restored.manualProgressPercent
            && cancelled.continuedFromTraceID
            == restored.continuedFromTraceID
            && cancelled.changedToTraceID == restored.changedToTraceID
            && cancelled.createdAt == restored.createdAt
            && cancelled.completedAt == restored.completedAt
    }

    private func traceBaseFieldsMatch(
        _ current: DayTrace,
        _ restored: DayTrace
    ) -> Bool {
        current.definitionID == restored.definitionID
            && current.date == restored.date
            && current.status == restored.status
            && current.priority == restored.priority
            && current.descriptionText == restored.descriptionText
            && current.manualProgressPercent == restored.manualProgressPercent
            && current.changedToTraceID == restored.changedToTraceID
            && current.completedAt == restored.completedAt
            && current.settledAt == restored.settledAt
            && current.draftCancellationID == restored.draftCancellationID
            && current.draftCancelledOn == restored.draftCancelledOn
    }

    private func noteFacts(
        in current: [TaskNoteEntry],
        contain restored: [TaskNoteEntry]
    ) -> Bool {
        let merger = TaskNoteEntryMerger()
        guard let canonicalCurrent = try? merger.merge([], current),
              let joined = try? merger.merge(restored, current)
        else {
            return false
        }
        return joined == canonicalCurrent
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let seconds = date.timeIntervalSinceReferenceDate
            guard seconds.isFinite else {
                throw EncodingError.invalidValue(
                    date,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "reactivation witness date must be finite"
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
                    debugDescription: "reactivation witness date must be finite"
                )
            }
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return decoder
    }
}
