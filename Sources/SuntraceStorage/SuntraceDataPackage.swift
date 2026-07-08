import Foundation
import SuntraceCore

public enum SuntraceDataPackage {
    public static func encode(_ snapshot: SuntraceSnapshot) throws -> Data {
        try validate(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    public static func decode(_ data: Data) throws -> SuntraceSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(SuntraceSnapshot.self, from: data)
        try validate(snapshot)
        return snapshot
    }

    public static func write(_ snapshot: SuntraceSnapshot, to url: URL) throws {
        try encode(snapshot).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> SuntraceSnapshot {
        try decode(Data(contentsOf: url))
    }
}

public enum DataPackageError: LocalizedError, Equatable {
    case duplicateField(String)
    case missingReference(String)

    public var errorDescription: String? {
        switch self {
        case let .duplicateField(field):
            return "导入数据包含重复字段：\(field)"
        case let .missingReference(reference):
            return "导入数据引用不完整：\(reference)"
        }
    }
}

private extension SuntraceDataPackage {
    static func validate(_ snapshot: SuntraceSnapshot) throws {
        try requireUnique(snapshot.days.map(\.date), label: "days.date")
        try requireUnique(snapshot.chains.map(\.id), label: "task_chains.id")
        try requireUnique(snapshot.definitions.map(\.id), label: "task_definitions.id")
        try requireUnique(snapshot.traces.map(\.id), label: "day_traces.id")
        try requireUnique(snapshot.subtasks.map(\.id), label: "subtasks.id")
        try requireUnique(snapshot.preferences.taskTags.map(\.id), label: "task_tags.id")
        try requireUnique(snapshot.preferences.taskTags.map { $0.name.lowercased() }, label: "task_tags.name")

        let chainIDs = Set(snapshot.chains.map(\.id))
        let definitionIDs = Set(snapshot.definitions.map(\.id))
        let traceIDs = Set(snapshot.traces.map(\.id))
        let subtaskIDs = Set(snapshot.subtasks.map(\.id))
        let tagIDs = Set(snapshot.preferences.taskTags.map(\.id))

        for chain in snapshot.chains {
            try require(chain.tagAssignments.count <= 3, "chain has more than three tags")
            try requireUnique(chain.tagAssignments.map(\.slot), label: "task_tag_assignments.slot")
            try requireUnique(chain.tagAssignments.map(\.tagID), label: "task_tag_assignments.tag_id")
            for assignment in chain.tagAssignments {
                try require(tagIDs.contains(assignment.tagID), "task tag assignment references missing tag")
            }
        }

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
            if let continuedFromTraceID = trace.continuedFromTraceID {
                try require(traceIDs.contains(continuedFromTraceID), "trace references missing continued-from trace")
            }
            if let changedToTraceID = trace.changedToTraceID {
                try require(traceIDs.contains(changedToTraceID), "trace references missing changed-to trace")
            }
        }
        for subtask in snapshot.subtasks {
            try require(traceIDs.contains(subtask.traceID), "subtask references missing trace")
            if let continuedFromSubtaskID = subtask.continuedFromSubtaskID {
                try require(subtaskIDs.contains(continuedFromSubtaskID), "subtask references missing continued-from subtask")
            }
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
