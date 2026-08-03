import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkMacRuntime

enum IdeaDraftClassificationError: Error, Equatable {
    case unresolved([String])
}

/// User-selected classification filter on the Ideas page: exactly one group
/// or one label at a time, AND-combined with the substring filter text.
enum IdeaClassificationFilterSelection: Equatable {
    case category(TaskCategoryID)
    case label(TaskLabelID)
}

/// One clickable classification component on an idea card.
struct IdeaClassificationComponent: Equatable {
    let selection: IdeaClassificationFilterSelection
    let displayName: String

    var anchorSuffix: String {
        switch selection {
        case .category:
            "category"
        case let .label(id):
            "label.\(id.description)"
        }
    }
}

extension NoonmarkStore {
    var ideaTimelineFilter: IdeaTimelineFilter {
        var filter = IdeaTimelineFilter(
            text: ideaFilterText.isEmpty ? nil : ideaFilterText
        )
        switch ideaClassificationFilter {
        case let .category(id):
            filter.categoryID = id
        case let .label(id):
            filter.labelID = id
        case nil:
            break
        }
        return filter
    }

    var ideaTimelineGroups: [IdeaDayGroup] {
        engine.ideaTimelineByDay(filter: ideaTimelineFilter)
    }

    var pinnedIdeas: [IdeaEntry] {
        engine.pinnedIdeas(filter: ideaTimelineFilter)
    }

    var ideaTrashItems: [IdeaEntry] {
        engine.ideaTrash()
    }

    /// Total active ideas regardless of filter: distinguishes "no ideas at
    /// all" from "no filter match" for the empty state.
    var visibleIdeaCount: Int {
        engine.ideaTimeline().count + engine.pinnedIdeas().count
    }

    var hasVisibleIdeas: Bool {
        pinnedIdeas.isEmpty == false || ideaTimelineGroups.isEmpty == false
    }

    var activeIdeaClassificationFilterName: String? {
        let catalog = classificationCatalog()
        switch ideaClassificationFilter {
        case let .category(id):
            guard let match = catalog?.categories.first(where: {
                $0.id == id.description
            }) else { return nil }
            return "@\(match.name)"
        case let .label(id):
            guard let match = catalog?.labels.first(where: {
                $0.id == id.description
            }) else { return nil }
            return "#\(match.name)"
        case nil:
            return nil
        }
    }

    func selectIdeaClassificationFilter(
        _ component: IdeaClassificationComponent
    ) {
        ideaClassificationFilter = component.selection
    }

    func clearIdeaClassificationFilter() {
        ideaClassificationFilter = nil
    }

    func isIdeaClassificationFilterActive(
        _ component: IdeaClassificationComponent
    ) -> Bool {
        ideaClassificationFilter == component.selection
    }

    func ideaClassificationComponents(
        for idea: IdeaEntry
    ) -> [IdeaClassificationComponent] {
        let catalog = classificationCatalog()
        var components: [IdeaClassificationComponent] = []
        if let categoryID = idea.categoryID {
            if let match = catalog?.categories.first(where: {
                $0.id == categoryID.description
            }) {
                components.append(
                    IdeaClassificationComponent(
                        selection: .category(categoryID),
                        displayName: "@\(match.name)"
                    )
                )
            }
        }
        for labelID in idea.labelIDs {
            guard let match = catalog?.labels.first(where: {
                $0.id == labelID.description
            }) else { continue }
            components.append(
                IdeaClassificationComponent(
                    selection: .label(labelID),
                    displayName: "#\(match.name)"
                )
            )
        }
        return components
    }

    func ideaClassificationLine(for idea: IdeaEntry) -> String? {
        let components = ideaClassificationComponents(for: idea)
        return components.isEmpty
            ? nil
            : components.map(\.displayName).joined(separator: "  ")
    }

    func ideaDraftIssueMessage(for draft: String) -> String? {
        switch parsedTaskDraft(draft).issue {
        case .multipleCategories:
            copy.ideaMultipleCategories
        case nil:
            nil
        }
    }

    @discardableResult
    func appendIdeaFromComposer() -> Bool {
        let draft = parsedTaskDraft(ideaText)
        guard commitIdeaDraft(draft) else { return false }
        ideaText = ""
        return true
    }

    /// Plain-text entry point for the global idea-capture panel; shares the
    /// composer's parser, classification resolution and mutation discipline.
    @discardableResult
    func appendIdea(text: String) -> Bool {
        commitIdeaDraft(parsedTaskDraft(text))
    }

    private func commitIdeaDraft(_ draft: NewTaskDraft) -> Bool {
        guard draft.issue == nil else {
            showToast(copy.ideaMultipleCategories)
            return false
        }
        guard draft.title.isEmpty == false else { return false }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.addIdea)
            ) { candidate, moment in
                let resolution = resolveIdeaDraftClassification(
                    draft,
                    in: candidate
                )
                guard resolution.unresolvedNames.isEmpty else {
                    throw IdeaDraftClassificationError
                        .unresolved(resolution.unresolvedNames)
                }
                return try candidate.appendIdea(
                    body: draft.title,
                    categoryID: resolution.categoryID,
                    labelIDs: resolution.labelIDs,
                    now: moment.instant
                )
            }
            resolveOperationFailure(.ideaMutation)
            showToast(copy.ideaSavedToast)
            return true
        } catch let error as IdeaDraftClassificationError {
            if case let .unresolved(names) = error {
                showToast(copy.ideaUnresolvedClassification(names))
            }
            return false
        } catch {
            showOperationFailure(.ideaMutation, error: error)
            return false
        }
    }

    func beginIdeaEdit(_ idea: IdeaEntry) {
        editingIdeaID = idea.id
        ideaEditText = idea.body
    }

    func cancelIdeaEdit() {
        editingIdeaID = nil
        ideaEditText = ""
    }

    @discardableResult
    func commitIdeaEdit() -> Bool {
        guard let id = editingIdeaID else { return false }
        let body = ideaEditText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else {
            return deleteIdea(id)
        }
        guard body != engine.ideas[id]?.body else {
            cancelIdeaEdit()
            return true
        }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.editIdea)
            ) { candidate, moment in
                try candidate.editIdea(
                    id: id,
                    body: body,
                    now: moment.instant
                )
            }
            cancelIdeaEdit()
            resolveOperationFailure(.ideaMutation)
            return true
        } catch {
            showOperationFailure(.ideaMutation, error: error)
            return false
        }
    }

    @discardableResult
    func deleteIdea(_ id: IdeaID) -> Bool {
        guard engine.ideas[id]?.isDeleted == false else { return false }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.deleteIdea)
            ) { candidate, moment in
                try candidate.deleteIdea(id: id, now: moment.instant)
            }
            if editingIdeaID == id {
                cancelIdeaEdit()
            }
            resolveOperationFailure(.ideaMutation)
            showToast(copy.ideaDeletedToast)
            return true
        } catch {
            showOperationFailure(.ideaMutation, error: error)
            return false
        }
    }

    @discardableResult
    func pinIdea(_ id: IdeaID) -> Bool {
        guard engine.ideas[id]?.isDeleted == false else { return false }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.pinIdea)
            ) { candidate, moment in
                try candidate.pinIdea(id: id, now: moment.instant)
            }
            resolveOperationFailure(.ideaMutation)
            showToast(copy.ideaPinnedToast)
            return true
        } catch {
            showOperationFailure(.ideaMutation, error: error)
            return false
        }
    }

    @discardableResult
    func unpinIdea(_ id: IdeaID) -> Bool {
        guard engine.ideas[id]?.isDeleted == false else { return false }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.unpinIdea)
            ) { candidate, moment in
                try candidate.unpinIdea(id: id, now: moment.instant)
            }
            resolveOperationFailure(.ideaMutation)
            showToast(copy.ideaUnpinnedToast)
            return true
        } catch {
            showOperationFailure(.ideaMutation, error: error)
            return false
        }
    }

    /// Tombstones normalize body, category and labels away, so a restore
    /// always asks the user to retype the content before it is committed.
    func beginIdeaRestore(_ idea: IdeaEntry) {
        restoringIdeaID = idea.id
        ideaRestoreText = ""
    }

    func cancelIdeaRestore() {
        restoringIdeaID = nil
        ideaRestoreText = ""
    }

    @discardableResult
    func commitIdeaRestore() -> Bool {
        guard let id = restoringIdeaID else { return false }
        let body = ideaRestoreText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard body.isEmpty == false else { return false }
        guard engine.ideas[id]?.isDeleted == true else {
            cancelIdeaRestore()
            return false
        }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.restoreIdea)
            ) { candidate, moment in
                try candidate.restoreIdea(
                    id: id,
                    body: body,
                    now: moment.instant
                )
            }
            cancelIdeaRestore()
            resolveOperationFailure(.ideaMutation)
            showToast(copy.ideaRestoredToast)
            return true
        } catch {
            showOperationFailure(.ideaMutation, error: error)
            return false
        }
    }

    private func resolveIdeaDraftClassification(
        _ draft: NewTaskDraft,
        in candidate: NoonmarkEngine
    ) -> (
        categoryID: TaskCategoryID?,
        labelIDs: [TaskLabelID],
        unresolvedNames: [String]
    ) {
        let catalog: ClassificationCatalogProjection? = if case let .catalog(
            projection
        ) = try? candidate.classification(.catalog) {
            projection
        } else {
            nil
        }
        var unresolvedNames: [String] = []

        var categoryID: TaskCategoryID?
        if let categoryName = draft.categoryName {
            let key = ClassificationNameCanonicalizer.canonicalKey(categoryName)
            if let match = catalog?.categories.first(where: {
                $0.lifecycle == .active
                    && ClassificationNameCanonicalizer.canonicalKey($0.name) == key
            }), let id = UUID(uuidString: match.id) {
                categoryID = TaskCategoryID(id)
            } else {
                unresolvedNames.append("@\(categoryName)")
            }
        }

        var labelIDs: [TaskLabelID] = []
        for labelName in draft.labelNames {
            let key = ClassificationNameCanonicalizer.canonicalKey(labelName)
            if let match = catalog?.labels.first(where: {
                $0.lifecycle == .active
                    && ClassificationNameCanonicalizer.canonicalKey($0.name) == key
            }), let id = UUID(uuidString: match.id) {
                let labelID = TaskLabelID(id)
                if labelIDs.contains(labelID) == false {
                    labelIDs.append(labelID)
                }
            } else {
                unresolvedNames.append("#\(labelName)")
            }
        }
        return (categoryID, labelIDs, unresolvedNames)
    }
}
