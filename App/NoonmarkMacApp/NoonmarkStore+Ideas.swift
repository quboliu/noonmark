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

enum IdeaBrowseMode: Equatable {
    case recent
    case review
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
    private var recentIdeaCollectionQuery: IdeaCollectionQuery {
        let filter = ideaTimelineFilter
        switch (filter.text, filter.categoryID, filter.labelID) {
        case (nil, nil, nil):
            return .recent
        case let (text?, nil, nil):
            return .search(text: text)
        case let (nil, categoryID?, nil):
            return .category(categoryID)
        case let (nil, nil, labelID?):
            return .label(labelID)
        default:
            return .filtered(filter)
        }
    }

    private var recentIdeaCollection: IdeaCollectionProjection {
        engine.ideaCollection(recentIdeaCollectionQuery, today: today)
    }

    var displayedIdeaCollection: IdeaCollectionProjection {
        switch ideaBrowseMode {
        case .recent:
            recentIdeaCollection
        case .review:
            engine.ideaCollection(
                .review(
                    seed: ideaReviewSeed,
                    count: 5,
                    excludingRecentDays: 7
                ),
                today: today
            )
        }
    }

    var displayedIdeaGroups: [IdeaDayGroup] {
        displayedIdeaCollection.groups
    }

    var selectedIdea: IdeaEntry? {
        let collection = displayedIdeaCollection
        let visibleIDs = Set(collection.ideas.map(\.id))
        guard let selectedIdeaID,
              visibleIDs.contains(selectedIdeaID),
              let idea = engine.ideas[selectedIdeaID],
              idea.isDeleted == false
        else {
            return collection.pinnedIdeas.first
                ?? collection.groups.first?.ideas.first
        }
        return idea
    }

    func showRecentIdeas() {
        ideaBrowseMode = .recent
    }

    func dismissIdeaSearch() {
        ideaFilterText = ""
    }

    func showIdeaReview() {
        ideaFilterText = ""
        clearIdeaClassificationFilter()
        ideaBrowseMode = .review
    }

    func refreshIdeaReview() {
        ideaReviewSeed &+= 1
    }

    func selectIdea(_ id: IdeaID) {
        selectedIdeaID = id
    }

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
        recentIdeaCollection.groups
    }

    var pinnedIdeas: [IdeaEntry] {
        recentIdeaCollection.pinnedIdeas
    }

    var ideaTrashItems: [IdeaEntry] {
        engine.ideaCollection(.trash, today: today).ideas
    }

    /// Total active ideas regardless of filter: distinguishes "no ideas at
    /// all" from "no filter match" for the empty state.
    var visibleIdeaCount: Int {
        engine.ideaCollection(.recent, today: today).ideas.count
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
        ideaBrowseMode = .recent
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
        switch IdeaDraftParser.parse(draft).issue {
        case .multipleCategories:
            copy.ideaMultipleCategories
        case nil:
            nil
        }
    }

    @discardableResult
    func appendIdeaFromComposer() -> Bool {
        ideaComposerSession.submit { [self] body in
            commitIdeaDraft(IdeaDraftParser.parse(body))
        }
    }

    /// Plain-text entry point for the global idea-capture panel; shares the
    /// composer's parser, classification resolution and mutation discipline.
    @discardableResult
    func appendIdea(text: String) -> Bool {
        commitIdeaDraft(IdeaDraftParser.parse(text))
    }

    private func commitIdeaDraft(_ draft: IdeaDraft) -> Bool {
        guard draft.issue == nil else {
            showToast(copy.ideaMultipleCategories)
            return false
        }
        guard draft.body.isEmpty == false else { return false }
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
                    body: draft.body,
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
        ideaInlineEditorSession.begin(id: idea.id, body: idea.body)
    }

    func cancelIdeaEdit() {
        ideaInlineEditorSession.cancel()
    }

    @discardableResult
    func commitIdeaEdit() -> Bool {
        ideaInlineEditorSession.save { [self] id, body in
            persistIdeaEdit(id: id, body: body)
        }
    }

    private func persistIdeaEdit(id: IdeaID, body: String) -> Bool {
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
        _ draft: IdeaDraft,
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
