import NoonmarkSync

struct SQLiteSyncDependencyFact {
    let kind: String
    let id: String

    var auditDescription: String {
        kind == "currentSnapshotIntegrity" ? kind : "\(kind):\(id)"
    }
}

extension SyncRecordDependency {
    var sqliteFact: SQLiteSyncDependencyFact {
        switch self {
        case .day, .taskChain, .taskDefinition, .dayTrace, .subtask:
            sqliteEntityFact
        case .category, .label, .classificationEvent,
             .classificationCommit, .classificationRevision,
             .currentSnapshotIntegrity:
            sqliteClassificationFact
        }
    }

    private var sqliteEntityFact: SQLiteSyncDependencyFact {
        switch self {
        case let .day(date):
            SQLiteSyncDependencyFact(kind: "day", id: date.description)
        case let .taskChain(id):
            SQLiteSyncDependencyFact(kind: "taskChain", id: id.description)
        case let .taskDefinition(id):
            SQLiteSyncDependencyFact(
                kind: "taskDefinition",
                id: id.description
            )
        case let .dayTrace(id):
            SQLiteSyncDependencyFact(kind: "dayTrace", id: id.description)
        case let .subtask(id):
            SQLiteSyncDependencyFact(kind: "subtask", id: id.description)
        case .category, .label, .classificationEvent,
             .classificationCommit, .classificationRevision,
             .currentSnapshotIntegrity:
            preconditionFailure("classification dependency reached entity encoder")
        }
    }

    private var sqliteClassificationFact: SQLiteSyncDependencyFact {
        switch self {
        case let .category(id):
            SQLiteSyncDependencyFact(kind: "category", id: id.description)
        case let .label(id):
            SQLiteSyncDependencyFact(kind: "label", id: id.description)
        case let .classificationEvent(id):
            SQLiteSyncDependencyFact(
                kind: "classificationEvent",
                id: id.uuidString
            )
        case let .classificationCommit(id):
            SQLiteSyncDependencyFact(
                kind: "classificationCommit",
                id: id.uuidString
            )
        case let .classificationRevision(revision):
            SQLiteSyncDependencyFact(
                kind: "classificationRevision",
                id: revision.description
            )
        case .currentSnapshotIntegrity:
            SQLiteSyncDependencyFact(
                kind: "currentSnapshotIntegrity",
                id: "snapshot"
            )
        case .day, .taskChain, .taskDefinition, .dayTrace, .subtask:
            preconditionFailure("entity dependency reached classification encoder")
        }
    }
}
