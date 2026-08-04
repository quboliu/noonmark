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
            return collection.groups.first?.ideas.first
        }
        return idea
    }

    @discardableResult
    func showRecentIdeas() -> Bool {
        guard prepareForIdeaContextChange() else { return false }
        ideaBrowseMode = .recent
        return true
    }

    @discardableResult
    func dismissIdeaSearch() -> Bool {
        guard prepareForIdeaContextChange() else { return false }
        ideaFilterText = ""
        return true
    }

    @discardableResult
    func showIdeaReview() -> Bool {
        guard prepareForIdeaContextChange() else { return false }
        ideaFilterText = ""
        ideaClassificationFilter = nil
        ideaBrowseMode = .review
        return true
    }

    @discardableResult
    func refreshIdeaReview() -> Bool {
        guard prepareForIdeaContextChange() else { return false }
        ideaReviewSeed &+= 1
        return true
    }

    func updateIdeaFilterText(_ text: String) {
        guard ideaFilterText != text else { return }
        guard prepareForIdeaContextChange() else { return }
        ideaFilterText = text
        if text.isEmpty == false {
            ideaBrowseMode = .recent
        }
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

    /// Selected projection rendered by Sticky Note. `pinnedAt` remains the
    /// storage compatibility fact; product code speaks in Sticky Note intent.
    var stickyNoteIdeas: [IdeaEntry] {
        engine.pinnedIdeas()
    }

    /// Total active ideas regardless of filter: distinguishes "no ideas at
    /// all" from "no filter match" for the empty state.
    var visibleIdeaCount: Int {
        engine.ideaCollection(.recent, today: today).ideas.count
    }

    var hasVisibleIdeas: Bool {
        ideaTimelineGroups.isEmpty == false
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

    @discardableResult
    func selectIdeaClassificationFilter(
        _ component: IdeaClassificationComponent
    ) -> Bool {
        guard prepareForIdeaContextChange() else { return false }
        ideaBrowseMode = .recent
        ideaClassificationFilter = component.selection
        return true
    }

    @discardableResult
    func clearIdeaClassificationFilter() -> Bool {
        guard prepareForIdeaContextChange() else { return false }
        ideaClassificationFilter = nil
        return true
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
            ideaComposerSession.setFailureMessage(
                copy.ideaMultipleCategories
            )
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
            return true
        } catch let error as IdeaDraftClassificationError {
            if case let .unresolved(names) = error {
                ideaComposerSession.setFailureMessage(
                    copy.ideaUnresolvedClassification(names)
                )
            }
            return false
        } catch {
            showOperationFailure(.ideaMutation, error: error)
            return false
        }
    }

    @discardableResult
    func beginIdeaEdit(_ idea: IdeaEntry) -> Bool {
        if let activeID = ideaInlineEditorSession.ideaID {
            if activeID == idea.id {
                return true
            }
            guard endIdeaEdit(reason: .navigation) else {
                return false
            }
        }
        return ideaInlineEditorSession.begin(
            id: idea.id,
            body: editableIdeaDraft(for: idea)
        )
    }

    /// Every mutation that can hide the active card goes through this gate.
    /// A failed save leaves both the editor and its current context intact.
    @discardableResult
    func prepareForIdeaContextChange() -> Bool {
        guard ideaInlineEditorSession.ideaID != nil else { return true }
        return endIdeaEdit(reason: .navigation)
    }

    func cancelIdeaEdit() {
        _ = endIdeaEdit(reason: .explicitCancel)
    }

    @discardableResult
    func commitIdeaEdit() -> Bool {
        endIdeaEdit(reason: .submit)
    }

    @discardableResult
    func endIdeaEdit(reason: IdeaInlineEditorEndReason) -> Bool {
        ideaInlineEditorSession.end(reason: reason) { [self] id, body in
            persistIdeaEdit(id: id, body: body)
        }
    }

    private func persistIdeaEdit(id: IdeaID, body: String) -> Bool {
        let draft = IdeaDraftParser.parse(body)
        guard draft.issue == nil else {
            ideaInlineEditorSession.setFailureMessage(
                copy.ideaMultipleCategories
            )
            return false
        }
        guard draft.body.isEmpty == false else { return false }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.editIdea)
            ) { candidate, moment in
                let resolution = resolveIdeaDraftClassification(
                    draft,
                    in: candidate
                )
                guard resolution.unresolvedNames.isEmpty else {
                    throw IdeaDraftClassificationError
                        .unresolved(resolution.unresolvedNames)
                }
                try candidate.editIdea(
                    id: id,
                    body: draft.body,
                    categoryID: resolution.categoryID,
                    labelIDs: resolution.labelIDs,
                    now: moment.instant
                )
            }
            resolveOperationFailure(.ideaMutation)
            return true
        } catch let error as IdeaDraftClassificationError {
            if case let .unresolved(names) = error {
                ideaInlineEditorSession.setFailureMessage(
                    copy.ideaUnresolvedClassification(names)
                )
            }
            return false
        } catch {
            showOperationFailure(.ideaMutation, error: error)
            return false
        }
    }

    private func editableIdeaDraft(for idea: IdeaEntry) -> String {
        let classification = ideaClassificationComponents(for: idea)
            .map(\.displayName)
            .joined(separator: " ")
        guard classification.isEmpty == false else { return idea.body }
        return "\(idea.body)\n\(classification)"
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
    func addIdeaToStickyNotes(_ id: IdeaID) -> Bool {
        guard engine.ideas[id]?.isDeleted == false else { return false }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.pinIdea)
            ) { candidate, moment in
                try candidate.pinIdea(id: id, now: moment.instant)
            }
            resolveOperationFailure(.ideaMutation)
            showToast(copy.addedToStickyNotesToast)
            return true
        } catch {
            showOperationFailure(.ideaMutation, error: error)
            return false
        }
    }

    @discardableResult
    func removeIdeaFromStickyNotes(_ id: IdeaID) -> Bool {
        guard engine.ideas[id]?.isDeleted == false else { return false }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.unpinIdea)
            ) { candidate, moment in
                try candidate.unpinIdea(id: id, now: moment.instant)
            }
            resolveOperationFailure(.ideaMutation)
            showToast(copy.removedFromStickyNotesToast)
            return true
        } catch {
            showOperationFailure(.ideaMutation, error: error)
            return false
        }
    }

    func openIdeaInFlylight(_ id: IdeaID) {
        guard engine.ideas[id]?.isDeleted == false else { return }
        ideaFilterText = ""
        clearIdeaClassificationFilter()
        ideaBrowseMode = .recent
        page = .ideas
        selectedIdeaID = id
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
