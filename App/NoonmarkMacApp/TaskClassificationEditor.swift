import Foundation
import NoonmarkCore
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import SwiftUI

struct TaskClassificationEditor: View {
    enum Target: Equatable {
        case task(TaskChainID)
        case taskCycle(TaskCycleSeriesID)

        var identifier: String {
            switch self {
            case let .task(id):
                id.description
            case let .taskCycle(id):
                "cycle-\(id.description)"
            }
        }
    }

    private static let animationDuration = 0.18
    private static let newLabelColorHex = "#0E9488"
    private static let newGroupColorHex = "#D87831"
    private static let fieldLabelWidth: CGFloat = 36

    @EnvironmentObject private var store: NoonmarkStore

    let target: Target
    let taskTitle: String

    @State private var activeCategories: [ClassificationCatalogItemProjection] = []
    @State private var activeLabels: [ClassificationCatalogItemProjection] = []
    @State private var selectedCategoryID: String?
    @State private var selectedLabels: [EditorLabel] = []
    @State private var labelInput = ""
    @State private var isCreatingGroup = false
    @State private var newGroupName = ""
    @State private var categoryError: String?
    @State private var labelError: String?
    @State private var showsSavedStatus = false
    @State private var saveStatusGeneration = UUID()
    @FocusState private var isLabelInputFocused: Bool

    init(chainID: TaskChainID, taskTitle: String) {
        target = .task(chainID)
        self.taskTitle = taskTitle
    }

    init(seriesID: TaskCycleSeriesID, taskTitle: String) {
        target = .taskCycle(seriesID)
        self.taskTitle = taskTitle
    }

    private var presentation: AppPresentation {
        AppPresentation(language: store.engine.preferences.language)
    }

    private var copy: TaskClassificationEditorCopy {
        presentation.taskClassificationEditor
    }

    private var accessibilityTaskTitle: String {
        store.copy.displayTaskTitle(taskTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            categorySection
            Rectangle()
                .fill(Theme.line.opacity(0.72))
                .frame(height: 1)
            labelSection
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "classification.editor.\(target.identifier)"
        )
        .background {
            AppE2EViewAnchor(
                identifier:
                "classification.editor.\(target.identifier)",
                verificationText: accessibilityTaskTitle
            )
        }
        .accessibilityLabel(copy.editorAccessibilityLabel(taskTitle: accessibilityTaskTitle))
        .onAppear(perform: loadDraft)
        .onChange(of: target) { _, _ in
            resetTransientEditorState()
            loadDraft()
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                editorFieldLabel(copy.categoryTitle)
                categoryMenu

                Spacer(minLength: 6)
                if showsSavedStatus {
                    savedStatus
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
                ClassificationManagerButton()
                    .fixedSize(horizontal: true, vertical: false)
            }

            if isCreatingGroup {
                HStack(spacing: 7) {
                    Color.clear.frame(width: Self.fieldLabelWidth, height: 1)
                    Circle()
                        .fill(classificationUIColor(Self.newGroupColorHex))
                        .frame(width: 8, height: 8)
                    TextField(copy.groupNamePlaceholder, text: $newGroupName)
                        .textFieldStyle(.plain)
                        .font(.noonmarkSystem(size: 11.5, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.controlFill))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line.opacity(0.8)))
                        .onSubmit(createAndSelectGroup)
                    Button(copy.cancelAction) {
                        newGroupName = ""
                        isCreatingGroup = false
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text3)
                    Button(copy.createAndAddAction, action: createAndSelectGroup)
                        .buttonStyle(.plain)
                        .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }

            if let categoryError {
                editorError(categoryError)
            }
        }
    }

    private var selectedCategory: ClassificationCatalogItemProjection? {
        activeCategories.first { $0.id == selectedCategoryID }
    }

    private var availableLabels: [ClassificationCatalogItemProjection] {
        let selectedIDs = Set(selectedLabels.compactMap(\.existingID))
        let selectedNewKeys = Set(selectedLabels.filter { $0.existingID == nil }.map {
            ClassificationNameCanonicalizer.canonicalKey($0.name)
        })
        return activeLabels.filter {
            selectedIDs.contains($0.id) == false
                && selectedNewKeys.contains(
                    ClassificationNameCanonicalizer.canonicalKey($0.name)
                ) == false
        }
    }

    private var labelInputQuery: TaskLabelInputQuery {
        TaskLabelInputQuery(labelInput)
    }

    private var matchingLabelSuggestions:
        [ClassificationCatalogItemProjection]
    {
        let matchingIDs = Set(
            labelInputQuery.matchingCandidates(
                in: availableLabels.map {
                    TaskLabelInputCandidate(id: $0.id, name: $0.name)
                }
            ).map(\.id)
        )
        return availableLabels.filter {
            matchingIDs.contains($0.id)
        }
    }

    private var categoryMenu: some View {
        Menu {
            Button(copy.noGroupAction) { selectCategory(nil) }
            if activeCategories.isEmpty == false { Divider() }
            ForEach(activeCategories) { category in
                Button(category.name) { selectCategory(category.id) }
            }
            Divider()
            Button(copy.newGroupAction, systemImage: "plus") {
                isCreatingGroup = true
            }
        } label: {
            if let selectedCategory {
                categoryChip(selectedCategory)
            } else {
                HStack(spacing: 5) {
                    Text(copy.noGroup)
                        .font(.noonmarkSystem(size: 11))
                    Image(systemName: "chevron.down")
                        .font(.noonmarkSystem(size: 7, weight: .bold))
                }
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 7)
                .frame(
                    minHeight: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize)
                )
                .contentShape(Rectangle())
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(
            copy.taskGroupAccessibilityLabel(taskTitle: accessibilityTaskTitle)
        )
        .background {
            AppE2EViewAnchor(
                identifier: "classification.editor.category.\(target.identifier)",
                verificationText: selectedCategory?.name ?? copy.noGroup
            )
        }
    }

    private func categoryChip(_ category: ClassificationCatalogItemProjection) -> some View {
        let color = category.categoryPresentationColor
        return HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.noonmarkSystem(size: 9.5, weight: .semibold))
                .foregroundStyle(color)
            Text(category.name)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .help(category.name)
            Image(systemName: "chevron.down")
                .font(.noonmarkSystem(size: 7, weight: .bold))
                .foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 7)
        .frame(
            minHeight: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize)
        )
        .frame(maxWidth: 92)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    category.usesApprovedCategoryPresentation
                        ? color.opacity(0.09)
                        : Theme.controlFill
                )
        )
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.currentGroupAccessibilityLabel(category.name))
    }

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                editorFieldLabel(copy.labelTitle)
                ClassificationEditorFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(selectedLabels) { label in
                        labelChip(label)
                    }
                    labelInputField
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if labelInputQuery.requestsSuggestions {
                labelSuggestionDropdown
            }

            if let labelError {
                editorError(labelError)
            }
        }
    }

    private var labelInputField: some View {
        TextField(copy.tagNamePlaceholder, text: $labelInput)
            .textFieldStyle(.plain)
            .font(.noonmarkSystem(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 8)
            .frame(minWidth: 112, maxWidth: 164)
            .frame(
                minHeight: CGFloat(
                    MacUIAccessibilityLayout.minimumInteractiveTargetSize
                )
            )
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        labelError == nil
                            ? (
                                isLabelInputFocused
                                    ? Theme.accent.opacity(0.42)
                                    : Theme.line.opacity(0.8)
                            )
                            : Theme.warn,
                        lineWidth: 1
                    )
            )
            .focused($isLabelInputFocused)
            .onSubmit(addLabelFromInput)
            .onExitCommand {
                labelInput = ""
                labelError = nil
                isLabelInputFocused = false
            }
            .accessibilityIdentifier(
                "classification.editor.label-input.\(target.identifier)"
            )
            .accessibilityLabel(
                copy.addTagAccessibilityLabel(
                    taskTitle: accessibilityTaskTitle
                )
            )
            .overlay {
                AppE2EViewAnchor(
                    identifier:
                    "classification.editor.label-input.\(target.identifier)",
                    verificationText: copy.tagNamePlaceholder
                )
            }
    }

    private var labelSuggestionDropdown: some View {
        HStack(alignment: .top, spacing: 7) {
            Color.clear.frame(width: Self.fieldLabelWidth, height: 1)
            VStack(alignment: .leading, spacing: 0) {
                if matchingLabelSuggestions.isEmpty {
                    Text(labelSuggestionEmptyText)
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                } else {
                    ForEach(matchingLabelSuggestions.prefix(6)) {
                        label in
                        Button {
                            addExistingLabel(label)
                        } label: {
                            HStack(spacing: 7) {
                                Text("#")
                                    .font(
                                        .noonmarkSystem(
                                            size: 10,
                                            weight: .black,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(
                                        classificationUIColor(
                                            label.colorHex
                                        )
                                    )
                                Text(label.name)
                                    .font(
                                        .noonmarkSystem(
                                            size: 10.5,
                                            weight: .medium
                                        )
                                    )
                                    .foregroundStyle(Theme.text1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "classification.editor.available-label.\(target.identifier).\(label.id)"
                        )
                        .background {
                            AppE2EViewAnchor(
                                identifier:
                                "classification.editor.available-label.\(target.identifier).\(label.id)",
                                verificationText: label.name
                            )
                        }
                    }
                }
            }
            .frame(width: 190)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Theme.line.opacity(0.86))
            )
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            .accessibilityIdentifier(
                "classification.editor.label-suggestions.\(target.identifier)"
            )
            .overlay {
                AppE2EViewAnchor(
                    identifier:
                    "classification.editor.label-suggestions.\(target.identifier)"
                )
            }
            Spacer(minLength: 0)
        }
    }

    private var labelSuggestionEmptyText: String {
        if availableLabels.isEmpty
            && labelInputQuery.normalizedName.isEmpty
        {
            return copy.allTagsSelected
        }
        return copy.createTagFromInput(
            labelInputQuery.normalizedName
        )
    }

    private var savedStatus: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.noonmarkSystem(size: 10, weight: .semibold))
            .foregroundStyle(Theme.ok)
            .frame(width: 14, height: 24)
            .accessibilityIdentifier("classification.editor.save-status.\(target.identifier)")
            .accessibilityLabel(
                copy.savedAccessibilityLabel(taskTitle: accessibilityTaskTitle)
            )
    }

    private func editorFieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.noonmarkSystem(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .frame(width: Self.fieldLabelWidth, height: 24, alignment: .leading)
    }

    private func resetTransientEditorState() {
        labelInput = ""
        newGroupName = ""
        isCreatingGroup = false
        categoryError = nil
        labelError = nil
        showsSavedStatus = false
    }

    private func selectCategory(_ id: String?) {
        guard id != selectedCategoryID else { return }
        selectedCategoryID = id
        categoryError = nil
        saveDraft(errorPlacement: .category)
    }

    private func createAndSelectGroup() {
        let name = ClassificationNameCanonicalizer.displayName(newGroupName)
        guard name.isEmpty == false else {
            categoryError = copy.emptyGroupNameError
            return
        }
        do {
            let labels = try selectedLabels.map { try $0.choice }
            _ = try replaceClassification(
                category: .new(name: name, colorHex: Self.newGroupColorHex),
                labels: labels
            )
            newGroupName = ""
            isCreatingGroup = false
            categoryError = nil
            loadDraft()
            showSavedStatus()
        } catch {
            categoryError = editorErrorMessage(error)
        }
    }

    private func labelChip(_ label: EditorLabel) -> some View {
        let color = classificationUIColor(label.colorHex)
        return HStack(spacing: 4) {
            Text("#")
                .font(.noonmarkSystem(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(color)
            Text(label.name)
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)

            Button {
                removeLabel(label)
            } label: {
                Image(systemName: "xmark")
                    .font(.noonmarkSystem(size: 8, weight: .bold))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 16, height: 16)
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .accessibilityIdentifier(
                "classification.editor.remove-label.\(target.identifier).\(label.accessibilityIdentifierComponent)"
            )
            .accessibilityLabel(
                copy.removeTagAccessibilityLabel(
                    taskTitle: accessibilityTaskTitle,
                    tagName: label.name
                )
            )
        }
        .padding(.leading, 8)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.10))
                .frame(height: 24)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.22), lineWidth: 1)
                .frame(height: 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "classification.editor.label-chip.\(target.identifier).\(label.accessibilityIdentifierComponent)"
        )
        .accessibilityLabel(
            copy.taskTagAccessibilityLabel(
                taskTitle: accessibilityTaskTitle,
                tagName: label.name
            )
        )
    }

    private func editorError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.noonmarkSystem(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.warn)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(copy.saveFailedAccessibilityLabel(message))
    }

    private var classificationProjection: TaskClassificationProjection? {
        switch target {
        case let .task(chainID):
            store.currentClassification(for: chainID)
        case let .taskCycle(seriesID):
            try? store.engine.taskCycleTemplateClassification(
                seriesID: seriesID
            )
        }
    }

    private func replaceClassification(
        category: TaskCategoryChoice?,
        labels: [TaskLabelChoice]
    ) throws {
        switch target {
        case let .task(chainID):
            _ = try store.replaceTaskClassification(
                chainID: chainID,
                category: category,
                labels: labels
            )
        case let .taskCycle(seriesID):
            try store.replaceTaskCycleClassification(
                seriesID: seriesID,
                category: category,
                labels: labels
            )
        }
    }

    private func loadDraft() {
        guard let projection = classificationProjection,
              let catalog = store.classificationCatalog()
        else {
            categoryError = presentation.message(
                for: .classificationCatalogUnavailable
            )
            return
        }

        activeCategories = catalog.activeManageableItems(for: .category)
        activeLabels = catalog.activeManageableItems(for: .label)
        selectedCategoryID = projection.category?.id
        selectedLabels = projection.labels.map(EditorLabel.existing)
        categoryError = nil
        labelError = nil
    }

    private func addLabelFromInput() {
        let candidates = activeLabels.map {
            TaskLabelInputCandidate(id: $0.id, name: $0.name)
        }
        let candidate: EditorLabel
        switch labelInputQuery.submission(in: candidates) {
        case .empty:
            labelError = copy.emptyTagNameError
            return
        case let .existing(id):
            guard let existing = activeLabels.first(where: {
                $0.id == id
            }) else {
                labelError = presentation.message(
                    for: .classificationResourceUnavailable
                )
                return
            }
            candidate = .existing(existing)
        case let .new(name):
            candidate = .new(
                name: name,
                colorHex: Self.newLabelColorHex
            )
        }

        guard selectedLabels.contains(where: { $0.matches(candidate) }) == false else {
            labelError = copy.duplicateTagError(candidate.name)
            return
        }

        selectedLabels.append(candidate)
        labelError = nil
        saveDraft(errorPlacement: .label, clearsLabelInputOnSuccess: true)
    }

    private func addExistingLabel(_ item: ClassificationCatalogItemProjection) {
        let candidate = EditorLabel.existing(item)
        guard selectedLabels.contains(where: { $0.matches(candidate) }) == false else {
            labelError = copy.duplicateTagError(item.name)
            return
        }
        selectedLabels.append(candidate)
        labelError = nil
        saveDraft(
            errorPlacement: .label,
            clearsLabelInputOnSuccess: true
        )
    }

    private func removeLabel(_ label: EditorLabel) {
        selectedLabels.removeAll { $0.id == label.id }
        labelError = nil
        saveDraft(errorPlacement: .label)
    }

    private func saveDraft(
        errorPlacement: ErrorPlacement,
        clearsLabelInputOnSuccess: Bool = false
    ) {
        do {
            let category = try selectedCategoryID.map(categoryChoice)
            let labels = try selectedLabels.map { try $0.choice }
            _ = try replaceClassification(
                category: category,
                labels: labels
            )

            if clearsLabelInputOnSuccess {
                labelInput = ""
            }
            categoryError = nil
            labelError = nil
            loadDraft()
            showSavedStatus()
        } catch {
            let message = editorErrorMessage(error)
            switch errorPlacement {
            case .category:
                categoryError = message
            case .label:
                labelError = message
            }
        }
    }

    private func categoryChoice(for id: String) throws -> TaskCategoryChoice {
        guard let rawValue = UUID(uuidString: id) else {
            throw ClassificationEditorError.invalidIdentifier
        }
        return .existing(TaskCategoryID(rawValue))
    }

    private func showSavedStatus() {
        let generation = UUID()
        saveStatusGeneration = generation
        withAnimation(Theme.shouldReduceMotion ? nil : .easeInOut(duration: Self.animationDuration)) {
            showsSavedStatus = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard saveStatusGeneration == generation else { return }
            withAnimation(Theme.shouldReduceMotion ? nil : .easeInOut(duration: Self.animationDuration)) {
                showsSavedStatus = false
            }
        }
    }

    private func editorErrorMessage(_ error: Error) -> String {
        let failure: AppPresentationError = if error is ClassificationEditorError {
            .classificationResourceUnavailable
        } else {
            AppPresentation.classify(error, for: .classificationMutation)
        }
        return presentation.message(for: failure)
    }
}

private extension TaskClassificationEditor {
    enum ErrorPlacement {
        case category
        case label
    }

    enum ClassificationEditorError: Error {
        case invalidIdentifier
    }

    enum EditorLabelReference: Equatable {
        case existing(String)
        case new(UUID)
    }

    struct EditorLabel: Identifiable, Equatable {
        let reference: EditorLabelReference
        let name: String
        let colorHex: String

        var id: String {
            switch reference {
            case let .existing(id):
                "existing:\(id)"
            case let .new(id):
                "new:\(id.uuidString)"
            }
        }

        var existingID: String? {
            guard case let .existing(id) = reference else { return nil }
            return id
        }

        var accessibilityIdentifierComponent: String {
            let component: String = switch reference {
            case let .existing(id):
                id
            case let .new(id):
                id.uuidString
            }
            assert(
                UUID(uuidString: component) != nil,
                "classification AX identifiers require a canonical UUID component"
            )
            return component
        }

        var choice: TaskLabelChoice {
            get throws {
                switch reference {
                case let .existing(id):
                    guard let rawValue = UUID(uuidString: id) else {
                        throw ClassificationEditorError.invalidIdentifier
                    }
                    return .existing(TaskLabelID(rawValue))
                case .new:
                    return .new(name: name, colorHex: colorHex)
                }
            }
        }

        static func existing(_ item: ClassificationItemProjection) -> EditorLabel {
            EditorLabel(
                reference: .existing(item.id),
                name: item.name,
                colorHex: item.colorHex
            )
        }

        static func existing(_ item: ClassificationCatalogItemProjection) -> EditorLabel {
            EditorLabel(
                reference: .existing(item.id),
                name: item.name,
                colorHex: item.colorHex
            )
        }

        static func new(name: String, colorHex: String) -> EditorLabel {
            EditorLabel(reference: .new(UUID()), name: name, colorHex: colorHex)
        }

        func matches(_ other: EditorLabel) -> Bool {
            switch (reference, other.reference) {
            case let (.existing(lhs), .existing(rhs)) where lhs == rhs:
                return true
            default:
                return ClassificationNameCanonicalizer.canonicalKey(name)
                    == ClassificationNameCanonicalizer.canonicalKey(other.name)
            }
        }
    }
}

private struct ClassificationEditorFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let maximumWidth = proposedWidth(proposal, subviews: subviews)
        let rows = rows(maximumWidth: maximumWidth, subviews: subviews)
        return CGSize(
            width: proposal.width ?? rows.maximumRowWidth,
            height: rows.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func proposedWidth(_ proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        guard let width = proposal.width, width.isFinite else {
            return subviews.reduce(CGFloat.zero) { partial, subview in
                partial + subview.sizeThatFits(.unspecified).width + horizontalSpacing
            }
        }
        return max(0, width)
    }

    private func rows(maximumWidth: CGFloat, subviews: Subviews) -> RowMeasurements {
        var x: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maximumRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maximumWidth {
                maximumRowWidth = max(maximumRowWidth, x - horizontalSpacing)
                totalHeight += rowHeight + verticalSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        if subviews.isEmpty == false {
            maximumRowWidth = max(maximumRowWidth, x - horizontalSpacing)
            totalHeight += rowHeight
        }
        return RowMeasurements(height: totalHeight, maximumRowWidth: maximumRowWidth)
    }

    private struct RowMeasurements {
        let height: CGFloat
        let maximumRowWidth: CGFloat
    }
}
