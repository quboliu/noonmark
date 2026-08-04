import CryptoKit
import Foundation
import NoonmarkCore

public struct DataPackageWriteReceipt: Equatable, Sendable {
    public let byteCount: Int
    public let sha256: String

    public init(byteCount: Int, sha256: String) {
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public enum NoonmarkDataPackage {
    public static let legacyFormatVersion = 6
    public static let currentFormatVersion = 7

    public static func encode(_ snapshot: NoonmarkSnapshot) throws -> Data {
        try validate(snapshot)
        return try currentJSON(for: snapshot).data
    }

    public static func decode(_ data: Data) throws -> NoonmarkSnapshot {
        let header = try JSONDecoder().decode(DataPackageHeader.self, from: data)
        let decoder = ExactDateJSONCoding.decoder(
            nonFiniteDateDescription: "data package date must be finite"
        )
        let snapshot: NoonmarkSnapshot
        let encodedJSON: (data: Data, object: Any)
        switch header.formatVersion {
        case currentFormatVersion:
            snapshot = try decoder.decode(DataPackageEnvelope.self, from: data)
                .snapshot
            encodedJSON = try currentJSON(for: snapshot)
        case legacyFormatVersion:
            let legacyEnvelope = try decoder.decode(
                LegacyV6DataPackageEnvelope.self,
                from: data
            )
            snapshot = legacyEnvelope.snapshot.currentSnapshot
            encodedJSON = try legacyV6JSON(for: snapshot)
        default:
            throw DataPackageError.unsupportedFormatVersion(header.formatVersion)
        }
        try validate(snapshot)
        let inputJSON = try canonicalJSON(from: data)
        guard inputJSON.data == data,
              try jsonShape(of: inputJSON.object) == jsonShape(of: encodedJSON.object)
        else {
            throw DataPackageError.malformedDataPackage(
                "数据包不符合已支持格式的 canonical 结构与编码"
            )
        }
        return snapshot
    }

    @discardableResult
    public static func write(
        _ snapshot: NoonmarkSnapshot,
        to url: URL
    ) throws -> DataPackageWriteReceipt {
        let encoded = try encode(snapshot)
        try encoded.write(to: url, options: .atomic)
        let persisted = try Data(contentsOf: url)
        guard persisted == encoded else {
            throw DataPackageError.writeVerificationFailed
        }
        _ = try decode(persisted)
        let digest = SHA256.hash(data: persisted)
            .map { String(format: "%02x", $0) }
            .joined()
        return DataPackageWriteReceipt(
            byteCount: persisted.count,
            sha256: digest
        )
    }

    public static func read(from url: URL) throws -> NoonmarkSnapshot {
        try decode(Data(contentsOf: url))
    }

    private static func currentJSON(
        for snapshot: NoonmarkSnapshot
    ) throws -> (data: Data, object: Any) {
        let encoder = ExactDateJSONCoding.encoder(
            nonFiniteDateDescription: "data package date must be finite"
        )
        let encoded = try encoder.encode(
            DataPackageEnvelope(formatVersion: currentFormatVersion, snapshot: snapshot)
        )
        return try canonicalJSON(from: encoded)
    }

    private static func legacyV6JSON(
        for snapshot: NoonmarkSnapshot
    ) throws -> (data: Data, object: Any) {
        let encoder = ExactDateJSONCoding.encoder(
            nonFiniteDateDescription: "data package date must be finite"
        )
        let encoded = try encoder.encode(
            LegacyV6DataPackageEnvelope(snapshot: snapshot)
        )
        return try canonicalJSON(from: encoded)
    }

    private static func canonicalJSON(from data: Data) throws -> (data: Data, object: Any) {
        let object = try JSONSerialization.jsonObject(with: data)
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DataPackageError.malformedDataPackage("数据包根节点不是 JSON object")
        }
        let canonicalData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return (canonicalData, object)
    }

    private static func jsonShape(of value: Any) throws -> String {
        if value is NSNull {
            return "null"
        }
        if let object = value as? [String: Any] {
            let fields = try object.keys.sorted().map { key -> String in
                let valueShape = try jsonShape(of: object[key] as Any)
                return lengthPrefixed(key) + lengthPrefixed(valueShape)
            }
            return "object" + lengthPrefixed(fields.joined())
        }
        if let array = value as? [Any] {
            // Codable dictionaries with non-String keys become order-unstable JSON arrays.
            // Comparing their element shapes as a multiset keeps nested key checks exact.
            let elementShapes = try array.map(jsonShape).sorted()
            return "array" + lengthPrefixed(elementShapes.map(lengthPrefixed).joined())
        }
        if value is String {
            return "string"
        }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number"
        }
        throw DataPackageError.malformedDataPackage("数据包包含不支持的 JSON 值")
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}

public enum DataPackageError: LocalizedError, Equatable {
    case duplicateField(String)
    case malformedDataPackage(String)
    case malformedFormatVersion
    case missingReference(String)
    case unsupportedFormatVersion(Int)
    case writeVerificationFailed

    public var errorDescription: String? {
        switch self {
        case let .duplicateField(field):
            return "导入数据包含重复字段：\(field)"
        case let .malformedDataPackage(reason):
            return "无法导入数据包：\(reason)。"
        case .malformedFormatVersion:
            return "无法导入数据包：formatVersion 缺失或不是整数。"
        case let .missingReference(reference):
            return "导入数据引用不完整：\(reference)"
        case let .unsupportedFormatVersion(version):
            return "无法导入数据包：不支持格式版本 \(version)。"
        case .writeVerificationFailed:
            return "数据包写入后校验失败，未确认导出成功。"
        }
    }
}

private struct DataPackageHeader: Decodable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion
    }

    let formatVersion: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.formatVersion) else {
            throw DataPackageError.malformedFormatVersion
        }
        do {
            formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        } catch {
            throw DataPackageError.malformedFormatVersion
        }
    }
}

private struct DataPackageEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case snapshot
    }

    let formatVersion: Int
    let snapshot: NoonmarkSnapshot

    init(formatVersion: Int, snapshot: NoonmarkSnapshot) {
        self.formatVersion = formatVersion
        self.snapshot = snapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard container.contains(.snapshot),
              try container.decodeNil(forKey: .snapshot) == false
        else {
            throw DataPackageError.malformedDataPackage("数据包缺少 snapshot")
        }
        snapshot = try container.decode(
            DataPackageSnapshot.self,
            forKey: .snapshot
        ).snapshot
    }
}

private struct LegacyV6DataPackageEnvelope: Codable {
    let formatVersion: Int
    let snapshot: LegacyV6DataPackageSnapshot

    init(snapshot: NoonmarkSnapshot) {
        formatVersion = NoonmarkDataPackage.legacyFormatVersion
        self.snapshot = LegacyV6DataPackageSnapshot(snapshot)
    }
}

private struct DataPackageSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case days
        case taskCycleSeries
        case chains
        case definitions
        case traces
        case subtasks
        case preferences
        case classifications
        case ideas
    }

    let snapshot: NoonmarkSnapshot

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let missingKey = CodingKeys.allCases.first(where: { container.contains($0) == false }) {
            throw DataPackageError.malformedDataPackage(
                "snapshot 缺少必需字段：\(missingKey.rawValue)"
            )
        }
        snapshot = try NoonmarkSnapshot(
            days: container.decode([Day].self, forKey: .days),
            taskCycleSeries: container.decode(
                [TaskCycleSeries].self,
                forKey: .taskCycleSeries
            ),
            chains: container.decode([TaskChain].self, forKey: .chains),
            definitions: container.decode([TaskDefinition].self, forKey: .definitions),
            traces: container.decode([DayTrace].self, forKey: .traces),
            subtasks: container.decode([Subtask].self, forKey: .subtasks),
            preferences: container.decode(AppPreferences.self, forKey: .preferences),
            classifications: container.decode(TaskClassificationState.self, forKey: .classifications),
            ideas: container.decode([IdeaEntry].self, forKey: .ideas)
        )
    }
}

private struct LegacyV6DataPackageSnapshot: Codable {
    let days: [Day]
    let taskCycleSeries: [TaskCycleSeries]
    let chains: [TaskChain]
    let definitions: [TaskDefinition]
    let traces: [DayTrace]
    let subtasks: [Subtask]
    let preferences: AppPreferences
    let classifications: TaskClassificationState

    init(_ snapshot: NoonmarkSnapshot) {
        days = snapshot.days
        taskCycleSeries = snapshot.taskCycleSeries
        chains = snapshot.chains
        definitions = snapshot.definitions
        traces = snapshot.traces
        subtasks = snapshot.subtasks
        preferences = snapshot.preferences
        classifications = snapshot.classifications
    }

    var currentSnapshot: NoonmarkSnapshot {
        NoonmarkSnapshot(
            days: days,
            taskCycleSeries: taskCycleSeries,
            chains: chains,
            definitions: definitions,
            traces: traces,
            subtasks: subtasks,
            preferences: preferences,
            classifications: classifications,
            ideas: []
        )
    }
}

private extension NoonmarkDataPackage {
    static func validate(_ snapshot: NoonmarkSnapshot) throws {
        try validateUniqueFields(snapshot)

        let chainIDs = Set(snapshot.chains.map(\.id))
        let traceIDs = Set(snapshot.traces.map(\.id))
        try validateClassificationManagementFacts(snapshot.classifications, chainIDs: chainIDs)
        try validateTodoReferences(snapshot)
        try validateIdeaReferences(snapshot)
        try validateCurrentClassifications(snapshot, chainIDs: chainIDs)
        try validateClassificationSnapshots(snapshot, traceIDs: traceIDs)
        try validateClassificationEvents(snapshot, traceIDs: traceIDs)
        try snapshot.classifications.validateIntegrity()
        do {
            try snapshot.validateIntegrity()
        } catch let error as NoonmarkError {
            throw DataPackageError.malformedDataPackage(
                error.localizedDescription
            )
        }
    }

    static func validateUniqueFields(_ snapshot: NoonmarkSnapshot) throws {
        try requireUnique(snapshot.days.map(\.date), label: "days.date")
        try requireUnique(
            snapshot.taskCycleSeries.map(\.id),
            label: "task_cycle_series.id"
        )
        try requireUnique(snapshot.chains.map(\.id), label: "task_chains.id")
        try requireUnique(snapshot.definitions.map(\.id), label: "task_definitions.id")
        try requireUnique(snapshot.traces.map(\.id), label: "day_traces.id")
        try requireUnique(snapshot.subtasks.map(\.id), label: "subtasks.id")
        try requireUnique(snapshot.ideas.map(\.id), label: "idea_entries.id")
        let classificationEvents = snapshot.classifications.snapshotEventsByTraceID.values.flatMap { $0 }
        try requireUnique(classificationEvents.map(\.id), label: "trace_classification_events.id")
    }

    static func validateTodoReferences(_ snapshot: NoonmarkSnapshot) throws {
        let chainIDs = Set(snapshot.chains.map(\.id))
        let definitionIDs = Set(snapshot.definitions.map(\.id))
        let traceIDs = Set(snapshot.traces.map(\.id))
        let subtaskIDs = Set(snapshot.subtasks.map(\.id))
        for definition in snapshot.definitions {
            try require(chainIDs.contains(definition.chainID), "definition references missing chain")
            if let supersededByDefinitionID = definition.supersededByDefinitionID {
                try require(
                    definitionIDs.contains(supersededByDefinitionID),
                    "definition references missing superseding definition"
                )
            }
        }
        for trace in snapshot.traces {
            try require(chainIDs.contains(trace.chainID), "trace references missing chain")
            try require(definitionIDs.contains(trace.definitionID), "trace references missing definition")
            if let carriedFromTraceID = trace.carriedFromTraceID {
                try require(traceIDs.contains(carriedFromTraceID), "trace references missing continued-from trace")
            }
            if let changedToTraceID = trace.changedToTraceID {
                try require(traceIDs.contains(changedToTraceID), "trace references missing changed-to trace")
            }
        }
        for subtask in snapshot.subtasks {
            try require(traceIDs.contains(subtask.traceID), "subtask references missing trace")
            if let carriedFromSubtaskID = subtask.carriedFromSubtaskID {
                try require(subtaskIDs.contains(carriedFromSubtaskID), "subtask references missing continued-from subtask")
            }
        }
    }

    static func validateIdeaReferences(_ snapshot: NoonmarkSnapshot) throws {
        let categoryIDs = Set(snapshot.classifications.categories.keys)
        let labelIDs = Set(snapshot.classifications.labels.keys)
        for idea in snapshot.ideas where idea.isDeleted == false {
            if let categoryID = idea.categoryID {
                try require(
                    categoryIDs.contains(categoryID),
                    "idea references missing category"
                )
            }
            for labelID in idea.labelIDs {
                try require(labelIDs.contains(labelID), "idea references missing label")
            }
        }
    }

    static func validateCurrentClassifications(
        _ snapshot: NoonmarkSnapshot,
        chainIDs: Set<TaskChainID>
    ) throws {
        let categoryIDs = Set(snapshot.classifications.categories.keys)
        let labelIDs = Set(snapshot.classifications.labels.keys)
        for (chainID, classification) in snapshot.classifications.currentByChainID {
            try require(chainIDs.contains(chainID), "task classification references missing chain")
            if let categoryID = classification.categoryID {
                try require(
                    categoryIDs.contains(categoryID),
                    "task classification references missing category"
                )
            }
            for labelID in classification.labelIDs {
                try require(labelIDs.contains(labelID), "task classification references missing label")
            }
        }
    }

    static func validateClassificationSnapshots(
        _ snapshot: NoonmarkSnapshot,
        traceIDs: Set<DayTraceID>
    ) throws {
        let categoryIDs = Set(snapshot.classifications.categories.keys)
        let labelIDs = Set(snapshot.classifications.labels.keys)
        for (traceID, classification) in snapshot.classifications.snapshotsByTraceID {
            try require(traceIDs.contains(traceID), "classification snapshot references missing trace")
            try require(
                classification.traceID == traceID,
                "classification snapshot key does not match trace"
            )
            if let category = classification.category {
                try require(
                    categoryIDs.contains(category.id),
                    "classification snapshot references missing category"
                )
            }
            try requireUnique(
                classification.labels.map(\.id),
                label: "trace_classification_snapshots.label_id"
            )
            for label in classification.labels {
                try require(
                    labelIDs.contains(label.id),
                    "classification snapshot references missing label"
                )
            }
        }
    }

    static func validateClassificationEvents(
        _ snapshot: NoonmarkSnapshot,
        traceIDs: Set<DayTraceID>
    ) throws {
        let categoryIDs = Set(snapshot.classifications.categories.keys)
        let labelIDs = Set(snapshot.classifications.labels.keys)
        for (traceID, events) in snapshot.classifications.snapshotEventsByTraceID {
            try require(traceIDs.contains(traceID), "classification event references missing trace")
            try require(events.isEmpty == false, "classification event stream is empty")
            try require(
                snapshot.classifications.snapshotsByTraceID[traceID] == events.last,
                "classification event stream latest snapshot does not match"
            )
            for event in events {
                try require(event.traceID == traceID, "classification event key does not match trace")
                if let category = event.category {
                    try require(
                        categoryIDs.contains(category.id),
                        "classification event references missing category"
                    )
                }
                try requireUnique(event.labels.map(\.id), label: "trace_classification_events.label_id")
                for label in event.labels {
                    try require(
                        labelIDs.contains(label.id),
                        "classification event references missing label"
                    )
                }
            }
        }
    }

    static func validateClassificationManagementFacts(
        _ classifications: TaskClassificationState,
        chainIDs: Set<TaskChainID>
    ) throws {
        let categoryIDs = Set(classifications.categories.keys)
        let labelIDs = Set(classifications.labels.keys)
        let deletedCategoryIDs = Set(classifications.categoryDeletionTombstones.keys)
        let deletedLabelIDs = Set(classifications.labelDeletionTombstones.keys)
        try require(
            categoryIDs.isDisjoint(with: deletedCategoryIDs),
            "deleted task category identity is still live"
        )
        try require(
            labelIDs.isDisjoint(with: deletedLabelIDs),
            "deleted task label identity is still live"
        )
        try requireUnique(
            classifications.categoryDeletionTombstones.values.map(\.id),
            label: "classification_category_deletion_tombstones.id"
        )
        try requireUnique(
            classifications.labelDeletionTombstones.values.map(\.id),
            label: "classification_label_deletion_tombstones.id"
        )
        try requireUnique(
            classifications.relationHistory.map(\.id),
            label: "classification_relation_history.id"
        )
        for history in classifications.relationHistory {
            try require(chainIDs.contains(history.chainID), "classification relation history references missing chain")
            try require(
                history.createdRevision <= history.removedRevision,
                "classification relation history revision moved backwards"
            )
            try require(
                history.createdAt <= history.removedAt,
                "classification relation history time moved backwards"
            )
        }
        try validateCategoryMerges(classifications)
        try validateLabelMerges(classifications)
        try validateClassificationTombstones(classifications)
    }

    static func validateCategoryMerges(_ classifications: TaskClassificationState) throws {
        for (sourceID, merge) in classifications.categoryMerges {
            try require(merge.sourceID == sourceID, "task category merge source key is inconsistent")
            try require(sourceID != merge.targetID, "task category merge points to itself")
            try require(
                classifications.categories[sourceID]?.lifecycle == .merged,
                "task category merge lifecycle is inconsistent"
            )
            try require(
                classifications.categories[merge.targetID] != nil,
                "task category merge references missing target"
            )
        }
        for category in classifications.categories.values {
            try require(
                (category.lifecycle == .merged) == (classifications.categoryMerges[category.id] != nil),
                "task category merge lifecycle is inconsistent"
            )
        }
        for sourceID in classifications.categoryMerges.keys {
            var visited: Set<TaskCategoryID> = []
            var cursor = sourceID
            while let merge = classifications.categoryMerges[cursor] {
                try require(visited.insert(cursor).inserted, "task category merge graph contains a cycle")
                cursor = merge.targetID
            }
            try require(
                classifications.categories[cursor]?.lifecycle == .active,
                "task category merge does not end at an active target"
            )
        }
    }

    static func validateLabelMerges(_ classifications: TaskClassificationState) throws {
        for (sourceID, merge) in classifications.labelMerges {
            try require(merge.sourceID == sourceID, "task label merge source key is inconsistent")
            try require(sourceID != merge.targetID, "task label merge points to itself")
            try require(
                classifications.labels[sourceID]?.lifecycle == .merged,
                "task label merge lifecycle is inconsistent"
            )
            try require(
                classifications.labels[merge.targetID] != nil,
                "task label merge references missing target"
            )
        }
        for label in classifications.labels.values {
            try require(
                (label.lifecycle == .merged) == (classifications.labelMerges[label.id] != nil),
                "task label merge lifecycle is inconsistent"
            )
        }
        for sourceID in classifications.labelMerges.keys {
            var visited: Set<TaskLabelID> = []
            var cursor = sourceID
            while let merge = classifications.labelMerges[cursor] {
                try require(visited.insert(cursor).inserted, "task label merge graph contains a cycle")
                cursor = merge.targetID
            }
            try require(
                classifications.labels[cursor]?.lifecycle == .active,
                "task label merge does not end at an active target"
            )
        }
    }

    static func validateClassificationTombstones(
        _ classifications: TaskClassificationState
    ) throws {
        let changeRecordIDs = Set(classifications.changeRecords.map(\.id))
        for (itemID, tombstone) in classifications.categoryDeletionTombstones {
            try require(tombstone.itemID == itemID, "task category tombstone key is inconsistent")
            try require(
                changeRecordIDs.contains(tombstone.changeRecordID),
                "task category tombstone references missing change record"
            )
        }
        for (itemID, tombstone) in classifications.labelDeletionTombstones {
            try require(tombstone.itemID == itemID, "task label tombstone key is inconsistent")
            try require(
                changeRecordIDs.contains(tombstone.changeRecordID),
                "task label tombstone references missing change record"
            )
        }
    }

    static func requireUnique(_ values: [some Hashable], label: String) throws {
        guard Set(values).count == values.count else {
            throw DataPackageError.duplicateField(label)
        }
    }

    static func require(_ condition: Bool, _ reference: String) throws {
        guard condition else {
            throw DataPackageError.missingReference(reference)
        }
    }
}
