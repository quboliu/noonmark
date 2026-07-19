import CryptoKit
import Foundation
import NoonmarkCore

public struct ZhulongTodoDiffID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongTodoDiffItemID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongTodoWriteAuthorizationID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongTodoApplyReceiptID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongPlannedSubtaskDraft: Codable, Equatable, Sendable {
    public let title: String
    public let difficulty: SubtaskDifficulty

    public init(title: String, difficulty: SubtaskDifficulty) throws {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { throw ZhulongTodoDiffError.invalidOperation }
        self.title = normalized
        self.difficulty = difficulty
    }
}

public enum ZhulongTodoDiffOperation: Codable, Equatable, Sendable {
    case createTask(
        title: String,
        descriptionText: String?,
        initialNoteBody: String?,
        plannedSubtasks: [ZhulongPlannedSubtaskDraft],
        targetDate: LocalDate?
    )
    case addSubtask(traceID: DayTraceID, title: String, difficulty: SubtaskDifficulty)
    case scheduleFromPool(chainID: TaskChainID, targetDate: LocalDate)
    case continueTrace(traceID: DayTraceID, targetDate: LocalDate)
    case abandonChain(traceID: DayTraceID)
}

public struct ZhulongTodoDiffItem: Codable, Equatable, Sendable {
    public let id: ZhulongTodoDiffItemID
    public let operation: ZhulongTodoDiffOperation

    public init(
        id: ZhulongTodoDiffItemID = ZhulongTodoDiffItemID(),
        operation: ZhulongTodoDiffOperation
    ) {
        self.id = id
        self.operation = operation
    }
}

public enum ZhulongTodoDiffSource: Codable, Equatable, Sendable {
    case providerOriginal
    case userRevision(parentDraftID: ZhulongTodoDiffID, modifiedItemIDs: [ZhulongTodoDiffItemID])
}

public enum ZhulongTodoDiffError: Error, Equatable, Sendable {
    case emptyDiff
    case duplicateItem
    case invalidOperation
    case invalidRevision
    case invalidTime
    case planningDateMismatch
    case staleDraft
    case authorizationMismatch
    case authorizationConsumed
    case digestFailure
    case sessionBindingMismatch
    case todoDiffRequired
}

public struct ZhulongTodoDiffDraft: Codable, Equatable, Sendable {
    public let id: ZhulongTodoDiffID
    public let sessionID: ZhulongSessionID
    public let planArtifactID: ZhulongPlanArtifactID
    public let planArtifactVersion: Int
    public let version: Int
    public let source: ZhulongTodoDiffSource
    public let planningDate: LocalDate
    public let sourceSnapshotDigest: String
    public let createdAt: Date
    public let items: [ZhulongTodoDiffItem]

    public init(
        id: ZhulongTodoDiffID = ZhulongTodoDiffID(),
        sessionID: ZhulongSessionID,
        planArtifactID: ZhulongPlanArtifactID,
        planArtifactVersion: Int,
        planningDate: LocalDate,
        sourceSnapshot: NoonmarkSnapshot,
        createdAt: Date = Date(),
        items: [ZhulongTodoDiffItem]
    ) throws {
        self.id = id
        self.sessionID = sessionID
        self.planArtifactID = planArtifactID
        self.planArtifactVersion = planArtifactVersion
        version = 1
        source = .providerOriginal
        self.planningDate = planningDate
        sourceSnapshotDigest = try ZhulongTodoDigest.snapshot(sourceSnapshot)
        self.createdAt = createdAt
        self.items = items
        try validate()
    }

    func isValidRevision(of parent: ZhulongTodoDiffDraft) -> Bool {
        guard sessionID == parent.sessionID,
              planArtifactID == parent.planArtifactID,
              planArtifactVersion == parent.planArtifactVersion,
              version == parent.version + 1,
              sourceSnapshotDigest == parent.sourceSnapshotDigest,
              createdAt > parent.createdAt,
              case let .userRevision(parentDraftID, modifiedItemIDs) = source,
              parentDraftID == parent.id
        else { return false }
        let previous = Dictionary(uniqueKeysWithValues: parent.items.map { ($0.id, $0.operation) })
        let current = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.operation) })
        let expected = Set(previous.keys).union(current.keys).filter {
            previous[$0] != current[$0]
        }
        return Set(modifiedItemIDs) == Set(expected) && modifiedItemIDs.count == expected.count
    }

    public init(
        id: ZhulongTodoDiffID = ZhulongTodoDiffID(),
        revising parent: ZhulongTodoDiffDraft,
        createdAt: Date = Date(),
        items: [ZhulongTodoDiffItem]
    ) throws {
        try parent.validate()
        guard Set(items.map(\.id)).count == items.count else {
            throw ZhulongTodoDiffError.duplicateItem
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              createdAt > parent.createdAt
        else {
            throw ZhulongTodoDiffError.invalidTime
        }
        let previous = Dictionary(uniqueKeysWithValues: parent.items.map { ($0.id, $0.operation) })
        let current = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.operation) })
        let changedItemIDs = Set(previous.keys).union(current.keys)
            .filter { previous[$0] != current[$0] }
            .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        self.id = id
        sessionID = parent.sessionID
        planArtifactID = parent.planArtifactID
        planArtifactVersion = parent.planArtifactVersion
        version = parent.version + 1
        source = .userRevision(
            parentDraftID: parent.id,
            modifiedItemIDs: changedItemIDs
        )
        planningDate = parent.planningDate
        sourceSnapshotDigest = parent.sourceSnapshotDigest
        self.createdAt = createdAt
        self.items = items
        try validate()
    }

    public func integrityDigest() throws -> String {
        try validate()
        return try ZhulongTodoDigest.value(self)
    }

    func validate() throws {
        guard planArtifactVersion > 0, version > 0 else {
            throw ZhulongTodoDiffError.invalidRevision
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ZhulongTodoDiffError.invalidTime
        }
        guard Set(items.map(\.id)).count == items.count else {
            throw ZhulongTodoDiffError.duplicateItem
        }
        switch source {
        case .providerOriginal:
            guard version == 1 else { throw ZhulongTodoDiffError.invalidRevision }
        case let .userRevision(parentDraftID, modifiedItemIDs):
            guard version > 1,
                  parentDraftID != id,
                  modifiedItemIDs.isEmpty == false,
                  Set(modifiedItemIDs).count == modifiedItemIDs.count
            else {
                throw ZhulongTodoDiffError.invalidRevision
            }
        }
        guard items.allSatisfy({ Self.isValid($0.operation) }) else {
            throw ZhulongTodoDiffError.invalidOperation
        }
    }

    private static func isValid(_ operation: ZhulongTodoDiffOperation) -> Bool {
        switch operation {
        case let .createTask(title, descriptionText, initialNoteBody, plannedSubtasks, _):
            return hasContent(title) &&
                optionalContentIsValid(descriptionText) &&
                optionalContentIsValid(initialNoteBody) &&
                plannedSubtasks.allSatisfy { hasContent($0.title) } &&
                Set(plannedSubtasks.map(\.title)).count == plannedSubtasks.count
        case let .addSubtask(_, title, _):
            return hasContent(title)
        case .scheduleFromPool, .continueTrace, .abandonChain:
            return true
        }
    }

    private static func hasContent(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func optionalContentIsValid(_ value: String?) -> Bool {
        value == nil || hasContent(value ?? "")
    }
}

public enum ZhulongTodoWriteAuthorizationStatus: Codable, Equatable, Sendable {
    case active
    case consumed(receiptID: ZhulongTodoApplyReceiptID, consumedAt: Date)
}

public struct ZhulongTodoWriteAuthorization: Codable, Equatable, Sendable {
    public let id: ZhulongTodoWriteAuthorizationID
    public let draftID: ZhulongTodoDiffID
    public let draftVersion: Int
    public let draftDigest: String
    public let sourceSnapshotDigest: String
    public let planningDate: LocalDate
    public let grantedAt: Date
    public private(set) var status: ZhulongTodoWriteAuthorizationStatus

    fileprivate init(
        id: ZhulongTodoWriteAuthorizationID = ZhulongTodoWriteAuthorizationID(),
        draft: ZhulongTodoDiffDraft,
        draftDigest: String,
        grantedAt: Date
    ) {
        self.id = id
        draftID = draft.id
        draftVersion = draft.version
        self.draftDigest = draftDigest
        sourceSnapshotDigest = draft.sourceSnapshotDigest
        planningDate = draft.planningDate
        self.grantedAt = grantedAt
        status = .active
    }

    fileprivate mutating func consume(
        receiptID: ZhulongTodoApplyReceiptID,
        at date: Date
    ) {
        status = .consumed(receiptID: receiptID, consumedAt: date)
    }
}

public enum ZhulongTodoApplyItemResult: Codable, Equatable, Sendable {
    case createdTask(
        chainID: TaskChainID,
        traceID: DayTraceID?,
        plannedSubtaskIDs: [PlannedSubtaskID]
    )
    case addedSubtask(SubtaskID)
    case scheduled(DayTraceID)
    case continued(DayTraceID)
    case abandoned(TaskChainID)
}

public struct ZhulongTodoApplyReceiptItem: Codable, Equatable, Sendable {
    public let diffItemID: ZhulongTodoDiffItemID
    public let result: ZhulongTodoApplyItemResult
}

public struct ZhulongTodoApplyReceipt: Codable, Equatable, Sendable {
    public let id: ZhulongTodoApplyReceiptID
    public let authorizationID: ZhulongTodoWriteAuthorizationID
    public let draftID: ZhulongTodoDiffID
    public let draftVersion: Int
    public let beforeSnapshotDigest: String
    public let afterSnapshotDigest: String
    public let appliedAt: Date
    public let items: [ZhulongTodoApplyReceiptItem]
}

public struct ZhulongTodoDiffApplier: Sendable {
    public init() {}

    public func authorize(
        _ draft: ZhulongTodoDiffDraft,
        against engine: NoonmarkEngine,
        today: LocalDate,
        now: Date = Date()
    ) throws -> ZhulongTodoWriteAuthorization {
        try draft.validate()
        try validateFinite(now)
        guard draft.items.isEmpty == false else { throw ZhulongTodoDiffError.emptyDiff }
        guard now > draft.createdAt else { throw ZhulongTodoDiffError.invalidTime }
        guard draft.planningDate == today else {
            throw ZhulongTodoDiffError.planningDateMismatch
        }
        guard try ZhulongTodoDigest.snapshot(engine.snapshot()) == draft.sourceSnapshotDigest else {
            throw ZhulongTodoDiffError.staleDraft
        }
        return try ZhulongTodoWriteAuthorization(
            draft: draft,
            draftDigest: draft.integrityDigest(),
            grantedAt: now
        )
    }

    public func apply(
        _ draft: ZhulongTodoDiffDraft,
        authorization: inout ZhulongTodoWriteAuthorization,
        to engine: inout NoonmarkEngine,
        today: LocalDate,
        now: Date = Date()
    ) throws -> ZhulongTodoApplyReceipt {
        try draft.validate()
        try validateFinite(now)
        guard draft.items.isEmpty == false else { throw ZhulongTodoDiffError.emptyDiff }
        guard authorization.grantedAt.timeIntervalSinceReferenceDate.isFinite,
              now > authorization.grantedAt,
              authorization.grantedAt > draft.createdAt
        else {
            throw ZhulongTodoDiffError.invalidTime
        }
        guard authorization.status == .active else {
            throw ZhulongTodoDiffError.authorizationConsumed
        }
        guard draft.planningDate == today, authorization.planningDate == today else {
            throw ZhulongTodoDiffError.planningDateMismatch
        }
        let draftDigest = try draft.integrityDigest()
        guard authorization.draftID == draft.id,
              authorization.draftVersion == draft.version,
              authorization.draftDigest == draftDigest,
              authorization.sourceSnapshotDigest == draft.sourceSnapshotDigest
        else {
            throw ZhulongTodoDiffError.authorizationMismatch
        }
        let before = try ZhulongTodoDigest.snapshot(engine.snapshot())
        guard before == draft.sourceSnapshotDigest else {
            throw ZhulongTodoDiffError.staleDraft
        }

        let staged = try NoonmarkEngine(snapshot: engine.snapshot())
        var results: [ZhulongTodoApplyReceiptItem] = []
        for item in draft.items {
            let result = try apply(item.operation, to: staged, today: today, now: now)
            results.append(ZhulongTodoApplyReceiptItem(diffItemID: item.id, result: result))
        }
        let after = try ZhulongTodoDigest.snapshot(staged.snapshot())
        let receiptID = ZhulongTodoApplyReceiptID()
        let receipt = ZhulongTodoApplyReceipt(
            id: receiptID,
            authorizationID: authorization.id,
            draftID: draft.id,
            draftVersion: draft.version,
            beforeSnapshotDigest: before,
            afterSnapshotDigest: after,
            appliedAt: now,
            items: results
        )
        authorization.consume(receiptID: receiptID, at: now)
        engine = staged
        return receipt
    }

    private func apply(
        _ operation: ZhulongTodoDiffOperation,
        to engine: NoonmarkEngine,
        today: LocalDate,
        now: Date
    ) throws -> ZhulongTodoApplyItemResult {
        switch operation {
        case let .createTask(title, descriptionText, initialNoteBody, plannedSubtasks, targetDate):
            let chainID = try engine.createPoolTask(
                title: title,
                descriptionText: descriptionText,
                initialNoteBody: initialNoteBody,
                now: now
            )
            let plannedSubtaskIDs = try plannedSubtasks.map { subtask in
                try engine.addPlannedSubtask(
                    chainID: chainID,
                    title: subtask.title,
                    difficulty: subtask.difficulty,
                    now: now
                )
            }
            let traceID = try targetDate.map { targetDate in
                try engine.scheduleFromPool(
                    chainID: chainID,
                    date: targetDate,
                    today: today,
                    now: now
                )
            }
            return .createdTask(
                chainID: chainID,
                traceID: traceID,
                plannedSubtaskIDs: plannedSubtaskIDs
            )
        case let .addSubtask(traceID, title, difficulty):
            return try .addedSubtask(
                engine.addSubtask(
                    traceID: traceID,
                    title: title,
                    difficulty: difficulty,
                    now: now
                )
            )
        case let .scheduleFromPool(chainID, targetDate):
            return try .scheduled(
                engine.scheduleFromPool(
                    chainID: chainID,
                    date: targetDate,
                    today: today,
                    now: now
                )
            )
        case let .continueTrace(traceID, targetDate):
            return try .continued(
                engine.continueTrace(
                    traceID: traceID,
                    targetDate: targetDate,
                    today: today,
                    now: now
                )
            )
        case let .abandonChain(traceID):
            let chainID = try engine.traces[traceID].map(\.chainID)
                ?? { throw NoonmarkError.notFound("day trace") }()
            try engine.abandonChain(from: traceID, now: now)
            return .abandoned(chainID)
        }
    }

    private func validateFinite(_ date: Date) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw ZhulongTodoDiffError.invalidTime
        }
    }
}

public extension ZhulongSession {
    var currentTodoDiff: ZhulongTodoDiffDraft? {
        guard let artifact = effectivePlanArtifact else { return nil }
        return todoDiffDrafts.last {
            $0.planArtifactID == artifact.id && $0.planArtifactVersion == artifact.version
        }
    }

    mutating func publishTodoDiff(
        _ draft: ZhulongTodoDiffDraft,
        now: Date = Date()
    ) throws {
        guard workspaceStatus == .active,
              phase == .draftReview,
              let artifact = effectivePlanArtifact,
              draft.sessionID == id,
              draft.planArtifactID == artifact.id,
              draft.planArtifactVersion == artifact.version,
              draft.version == 1,
              draft.source == .providerOriginal,
              draft.createdAt == now,
              currentTodoDiff == nil,
              todoDiffDrafts.contains(where: { $0.id == draft.id }) == false
        else {
            throw ZhulongTodoDiffError.sessionBindingMismatch
        }
        try draft.validate()
        try validateActivityTime(now)
        todoDiffDrafts.append(draft)
        appendEvent(
            .todoDiffPublished,
            summary: "已发布可编辑 Todo 变更 diff",
            reference: .todoDiff(draft.id),
            now: now
        )
    }

    mutating func reviseTodoDiff(
        _ revision: ZhulongTodoDiffDraft,
        now: Date = Date()
    ) throws {
        guard workspaceStatus == .active,
              phase == .draftReview,
              let parent = currentTodoDiff,
              revision.sessionID == id,
              revision.planArtifactID == parent.planArtifactID,
              revision.planArtifactVersion == parent.planArtifactVersion,
              revision.version == parent.version + 1,
              revision.createdAt == now,
              case let .userRevision(parentDraftID, _) = revision.source,
              parentDraftID == parent.id,
              todoWriteAuthorizations.contains(where: {
                  $0.draftID == parent.id && $0.status == .active
              }) == false,
              todoApplyReceipts.contains(where: { $0.draftID == parent.id }) == false,
              todoDiffDrafts.contains(where: { $0.id == revision.id }) == false
        else {
            throw ZhulongTodoDiffError.sessionBindingMismatch
        }
        try revision.validate()
        try validateActivityTime(now)
        todoDiffDrafts.append(revision)
        appendEvent(
            .todoDiffRevised,
            summary: "用户已建立 Todo 变更 diff 修订版本",
            reference: .todoDiff(revision.id),
            now: now
        )
    }

    @discardableResult
    mutating func authorizeTodoWrite(
        against engine: NoonmarkEngine,
        today: LocalDate,
        now: Date = Date()
    ) throws -> ZhulongTodoWriteAuthorization {
        guard workspaceStatus == .active,
              phase == .draftReview,
              let draft = currentTodoDiff,
              todoApplyReceipts.contains(where: { $0.draftID == draft.id }) == false,
              todoWriteAuthorizations.contains(where: {
                  $0.draftID == draft.id && $0.status == .active
              }) == false
        else {
            throw ZhulongTodoDiffError.todoDiffRequired
        }
        try validateActivityTime(now)
        let authorization = try ZhulongTodoDiffApplier().authorize(
            draft,
            against: engine,
            today: today,
            now: now
        )
        todoWriteAuthorizations.append(authorization)
        appendEvent(
            .todoWriteAuthorized,
            summary: "用户已对当前 Todo diff 授予一次性写入授权",
            reference: .todoWriteAuthorization(authorization.id),
            now: now
        )
        return authorization
    }

    @discardableResult
    mutating func applyAuthorizedTodoDiff(
        to engine: inout NoonmarkEngine,
        today: LocalDate,
        now: Date = Date()
    ) throws -> ZhulongTodoApplyReceipt {
        guard workspaceStatus == .active,
              phase == .draftReview,
              let draft = currentTodoDiff,
              let index = todoWriteAuthorizations.lastIndex(where: {
                  $0.draftID == draft.id && $0.status == .active
              })
        else {
            throw ZhulongTodoDiffError.todoDiffRequired
        }
        try validateActivityTime(now)
        var authorization = todoWriteAuthorizations[index]
        let receipt = try ZhulongTodoDiffApplier().apply(
            draft,
            authorization: &authorization,
            to: &engine,
            today: today,
            now: now
        )
        todoWriteAuthorizations[index] = authorization
        todoApplyReceipts.append(receipt)
        appendEvent(
            .todoBatchApplied,
            summary: "已原子应用 Todo diff，共 \(receipt.items.count) 项",
            reference: .todoApplyReceipt(receipt.id),
            now: now
        )
        return receipt
    }
}

enum ZhulongTodoDigest {
    static func snapshot(_ snapshot: NoonmarkSnapshot) throws -> String {
        try value(ZhulongTodoFactSnapshot(snapshot))
    }

    static func value(_ value: some Encodable) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
                try container.encode(milliseconds / 1000)
            }
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } catch {
            throw ZhulongTodoDiffError.digestFailure
        }
    }
}

private struct ZhulongTodoFactSnapshot: Encodable {
    let days: [Day]
    let chains: [TaskChain]
    let definitions: [TaskDefinition]
    let traces: [DayTrace]
    let subtasks: [Subtask]
    let classifications: TaskClassificationState

    init(_ snapshot: NoonmarkSnapshot) {
        days = snapshot.days
        chains = snapshot.chains
        definitions = snapshot.definitions
        traces = snapshot.traces
        subtasks = snapshot.subtasks
        classifications = snapshot.classifications
    }
}
