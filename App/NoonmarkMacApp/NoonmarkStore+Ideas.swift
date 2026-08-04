import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDiagnostics
import NoonmarkMacRuntime

enum IdeaDraftClassificationError:
    Error, Equatable, DiagnosticFailureProviding
{
    case unresolved([String])

    var diagnosticFailure: DiagnosticFailure {
        switch self {
        case .unresolved:
            DiagnosticFailure(domain: .domainValidation, code: 821)
        }
    }
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

/// A stable Flylight browsing position. Source navigation and temporary
/// classification collections may replace the visible collection, but they
/// never destroy the user's prior filter, review seed, or selection.
struct IdeaBrowseLocation: Equatable {
    let filterText: String
    let classificationFilter: IdeaClassificationFilterSelection?
    let browseMode: IdeaBrowseMode
    let reviewSeed: UInt64
    let selectedIdeaID: IdeaID?
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
        if ideaBrowseMode != .recent {
            invalidateIdeaBrowseReturnLocations()
        }
        ideaBrowseMode = .recent
        return true
    }

    @discardableResult
    func dismissIdeaSearch() -> Bool {
        guard prepareForIdeaContextChange() else { return false }
        if ideaFilterText.isEmpty == false {
            invalidateIdeaBrowseReturnLocations()
        }
        ideaFilterText = ""
        return true
    }

    @discardableResult
    func showIdeaReview() -> Bool {
        guard prepareForIdeaContextChange() else { return false }
        invalidateIdeaBrowseReturnLocations()
        ideaFilterText = ""
        ideaClassificationFilter = nil
        ideaBrowseMode = .review
        return true
    }

    @discardableResult
    func refreshIdeaReview() -> Bool {
        guard prepareForIdeaContextChange() else { return false }
        invalidateIdeaBrowseReturnLocations()
        ideaReviewSeed &+= 1
        return true
    }

    func updateIdeaFilterText(_ text: String) {
        guard ideaFilterText != text else { return }
        guard prepareForIdeaContextChange() else { return }
        invalidateIdeaBrowseReturnLocations()
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
        ideaSourceBrowseReturnLocation = nil
        if ideaClassificationBrowseReturnLocation == nil {
            ideaClassificationBrowseReturnLocation = currentIdeaBrowseLocation
        }
        ideaBrowseMode = .recent
        ideaClassificationFilter = component.selection
        return true
    }

    @discardableResult
    func clearIdeaClassificationFilter() -> Bool {
        guard prepareForIdeaContextChange() else { return false }
        if let location = ideaClassificationBrowseReturnLocation {
            ideaClassificationBrowseReturnLocation = nil
            applyIdeaBrowseLocation(location)
        } else {
            ideaSourceBrowseReturnLocation = nil
            ideaClassificationFilter = nil
        }
        return true
    }

    var canRestoreIdeaBrowseLocation: Bool {
        ideaSourceBrowseReturnLocation != nil
    }

    @discardableResult
    func restoreIdeaBrowseLocation() -> Bool {
        guard prepareForIdeaContextChange(),
              let location = ideaSourceBrowseReturnLocation
        else { return false }
        ideaSourceBrowseReturnLocation = nil
        applyIdeaBrowseLocation(location)
        return true
    }

    /// Navigation has already run the editor preflight. Restore without a
    /// second blur/save attempt so leaving a source reveal is deterministic.
    func restoreIdeaBrowseLocationForNavigation() {
        guard let location = ideaSourceBrowseReturnLocation else { return }
        ideaSourceBrowseReturnLocation = nil
        applyIdeaBrowseLocation(location)
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
            recordIdeaEditorFailure(error)
            return false
        } catch {
            if let message = ideaEditorFailureMessage(for: error) {
                ideaComposerSession.setFailureMessage(message)
            }
            recordIdeaEditorFailure(error)
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
            recordIdeaEditorFailure(error)
            return false
        } catch {
            if let message = ideaEditorFailureMessage(for: error) {
                ideaInlineEditorSession.setFailureMessage(message)
            }
            recordIdeaEditorFailure(error)
            return false
        }
    }

    /// Composer and inline edit already own an in-place recovery surface.
    /// Preserve diagnostic evidence without stacking a second global failure
    /// notice over the actionable editor state.
    private func recordIdeaEditorFailure(_ error: Error) {
        _ = recordOperationFailureEvidence(
            .ideaMutation,
            error: error
        )
    }

    /// Editor-owned recovery UI keeps typed, actionable gate guidance while
    /// arbitrary persistence errors stay behind the privacy-filtered generic
    /// failure copy and diagnostic incident.
    private func ideaEditorFailureMessage(for error: Error) -> String? {
        guard let gateError = error as? StoreMutationGateError else {
            return nil
        }
        switch gateError {
        case .pendingZhulongApplication:
            return AppPresentation(
                language: engine.preferences.language
            ).zhulong.pendingApplicationMutationBlocked
        case .exclusiveOperationInProgress:
            return gateError.errorDescription
        }
    }

    private func editableIdeaDraft(for idea: IdeaEntry) -> String {
        let catalog = classificationCatalog()
        let categoryName = idea.categoryID.flatMap { categoryID in
            catalog?.categories.first(where: {
                $0.id == categoryID.description
            })?.name
        }
        let labelNames = idea.labelIDs.compactMap { labelID in
            catalog?.labels.first(where: {
                $0.id == labelID.description
            })?.name
        }
        return IdeaDraftParser.editableText(
            body: idea.body,
            categoryName: categoryName,
            labelNames: labelNames
        )
    }

    @discardableResult
    func deleteIdea(_ id: IdeaID) -> Bool {
        guard engine.ideas[id]?.isDeleted == false else { return false }
        guard prepareForIdeaContextChange() else { return false }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.deleteIdea)
            ) { candidate, moment in
                try candidate.deleteIdea(id: id, now: moment.instant)
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
        if ideaSourceBrowseReturnLocation == nil {
            ideaSourceBrowseReturnLocation = currentIdeaBrowseLocation
        }
        ideaFilterText = ""
        ideaClassificationFilter = nil
        ideaBrowseMode = .recent
        page = .ideas
        selectedIdeaID = id
    }

    private var currentIdeaBrowseLocation: IdeaBrowseLocation {
        IdeaBrowseLocation(
            filterText: ideaFilterText,
            classificationFilter: ideaClassificationFilter,
            browseMode: ideaBrowseMode,
            reviewSeed: ideaReviewSeed,
            selectedIdeaID: selectedIdeaID
        )
    }

    private func applyIdeaBrowseLocation(_ location: IdeaBrowseLocation) {
        ideaFilterText = location.filterText
        ideaClassificationFilter = location.classificationFilter
        ideaBrowseMode = location.browseMode
        ideaReviewSeed = location.reviewSeed
        selectedIdeaID = location.selectedIdeaID
    }

    /// Search, review and other explicit collection choices become the new
    /// browsing baseline. A later clear, restore or page transition must not
    /// resurrect a return location captured before that user choice.
    private func invalidateIdeaBrowseReturnLocations() {
        ideaClassificationBrowseReturnLocation = nil
        ideaSourceBrowseReturnLocation = nil
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
