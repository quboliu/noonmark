import Foundation
import NoonmarkCore

enum TaskNoteEntryMergeError: Error, Equatable {
    case invalidEntries(TaskNoteEntryValidationIssue)
    case createdAtCollision(TaskNoteEntryID)
}

struct TaskNoteEntryMerger {
    func merge(
        _ lhs: [TaskNoteEntry],
        _ rhs: [TaskNoteEntry]
    ) throws -> [TaskNoteEntry] {
        if let issue = TaskNoteEntryValidator.firstIssue(in: lhs) {
            throw TaskNoteEntryMergeError.invalidEntries(issue)
        }
        if let issue = TaskNoteEntryValidator.firstIssue(in: rhs) {
            throw TaskNoteEntryMergeError.invalidEntries(issue)
        }

        var entriesByID = Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, $0) })
        for incomingEntry in rhs {
            guard let existingEntry = entriesByID[incomingEntry.id] else {
                entriesByID[incomingEntry.id] = incomingEntry
                continue
            }
            guard existingEntry.createdAt == incomingEntry.createdAt else {
                throw TaskNoteEntryMergeError.createdAtCollision(incomingEntry.id)
            }
            entriesByID[incomingEntry.id] = preferred(existingEntry, incomingEntry)
        }

        return entriesByID.values.sorted(by: entryComesBefore)
    }

    private func preferred(
        _ lhs: TaskNoteEntry,
        _ rhs: TaskNoteEntry
    ) -> TaskNoteEntry {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt ? lhs : rhs
        }
        if lhs.isDeleted != rhs.isDeleted {
            return lhs.isDeleted ? lhs : rhs
        }
        return Data(lhs.body.utf8).lexicographicallyPrecedes(Data(rhs.body.utf8))
            ? rhs
            : lhs
    }

    private func entryComesBefore(
        _ lhs: TaskNoteEntry,
        _ rhs: TaskNoteEntry
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.description < rhs.id.description
    }
}
