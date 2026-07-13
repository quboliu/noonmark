import Foundation
import NoonmarkCore
import SwiftUI

struct TaskClassificationEditor: View {
    private static let animationDuration = 0.18
    private static let newLabelColorHex = "#0E9488"
    private static let newGroupColorHex = "#D87831"
    private static let fieldLabelWidth: CGFloat = 36

    @EnvironmentObject private var store: NoonmarkStore

    let chainID: TaskChainID
    let taskTitle: String

    @State private var activeCategories: [ClassificationCatalogItemProjection] = []
    @State private var activeLabels: [ClassificationCatalogItemProjection] = []
    @State private var selectedCategoryID: String?
    @State private var selectedLabels: [EditorLabel] = []
    @State private var labelInput = ""
    @State private var isAddingLabel = CommandLine.arguments.contains("--e2e-open-classification-label-editor")
    @State private var isCreatingGroup = false
    @State private var newGroupName = ""
    @State private var categoryError: String?
    @State private var labelError: String?
    @State private var showsSavedStatus = false
    @State private var saveStatusGeneration = UUID()
    @FocusState private var isLabelInputFocused: Bool

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
        .accessibilityIdentifier("classification.editor.\(chainID.description)")
        .accessibilityLabel("任务「\(taskTitle)」的分组与标签编辑器")
        .onAppear(perform: loadDraft)
        .onChange(of: chainID) { _, _ in
            resetTransientEditorState()
            loadDraft()
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                editorFieldLabel("分组")

                if let selectedCategory {
                    categoryChip(selectedCategory)
                } else {
                    Text("无分组")
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text3)
                }

                Spacer(minLength: 6)
                if showsSavedStatus {
                    savedStatus
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
                categoryMenu
                ClassificationManagerButton()
                    .fixedSize(horizontal: true, vertical: false)
            }

            if isCreatingGroup {
                HStack(spacing: 7) {
                    Color.clear.frame(width: Self.fieldLabelWidth, height: 1)
                    Circle()
                        .fill(classificationUIColor(Self.newGroupColorHex))
                        .frame(width: 8, height: 8)
                    TextField("分组名称", text: $newGroupName)
                        .textFieldStyle(.plain)
                        .font(.noonmarkSystem(size: 11.5, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.controlFill))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line.opacity(0.8)))
                        .onSubmit(createAndSelectGroup)
                    Button("取消") {
                        newGroupName = ""
                        isCreatingGroup = false
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text3)
                    Button("创建并加入", action: createAndSelectGroup)
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

    private var categoryMenu: some View {
        Menu {
            Button("不加入分组") { selectCategory(nil) }
            if activeCategories.isEmpty == false { Divider() }
            ForEach(activeCategories) { category in
                Button(category.name) { selectCategory(category.id) }
            }
            Divider()
            Button("新建分组…", systemImage: "plus") {
                isCreatingGroup = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedCategoryID == nil ? "选择" : "更换")
                Image(systemName: "chevron.down")
                    .font(.noonmarkSystem(size: 7, weight: .bold))
            }
            .font(.noonmarkSystem(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accentSoft.opacity(0.52)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("classification.editor.category.\(chainID.description)")
        .accessibilityLabel("任务「\(taskTitle)」的分组")
    }

    private func categoryChip(_ category: ClassificationCatalogItemProjection) -> some View {
        let color = classificationUIColor(category.colorHex)
        return HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.noonmarkSystem(size: 9.5, weight: .semibold))
                .foregroundStyle(color)
            Text(category.name)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)
                .help(category.name)
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .frame(maxWidth: 92)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.09)))
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当前分组：\(category.name)")
    }

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                editorFieldLabel("标签")
                ClassificationEditorFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(selectedLabels) { label in
                        labelChip(label)
                    }

                    if isAddingLabel == false {
                        Button {
                            isAddingLabel = true
                            Task { @MainActor in isLabelInputFocused = true }
                        } label: {
                            Label("添加", systemImage: "plus")
                                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 7)
                                .frame(height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Theme.accentSoft.opacity(0.46))
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("classification.editor.add-label.\(chainID.description)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isAddingLabel {
                HStack(spacing: 7) {
                    Color.clear.frame(width: Self.fieldLabelWidth, height: 1)
                    TextField("输入标签名称", text: $labelInput)
                        .textFieldStyle(.plain)
                        .font(.noonmarkSystem(size: 11.5))
                        .foregroundStyle(Theme.text1)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.controlFill))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(labelError == nil ? Theme.line.opacity(0.8) : Theme.warn, lineWidth: 1)
                        )
                        .focused($isLabelInputFocused)
                        .onSubmit(addLabelFromInput)
                        .accessibilityIdentifier("classification.editor.label-input.\(chainID.description)")
                        .accessibilityLabel("为任务「\(taskTitle)」添加标签")
                    Button("取消") {
                        labelInput = ""
                        labelError = nil
                        isAddingLabel = false
                    }
                    .buttonStyle(.plain)
                    .font(.noonmarkSystem(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    Button("添加", action: addLabelFromInput)
                        .buttonStyle(.plain)
                        .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }

            if let labelError {
                editorError(labelError)
            }
        }
    }

    private var savedStatus: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.noonmarkSystem(size: 10, weight: .semibold))
            .foregroundStyle(Theme.ok)
            .frame(width: 14, height: 24)
            .accessibilityIdentifier("classification.editor.save-status.\(chainID.description)")
            .accessibilityLabel("任务「\(taskTitle)」的分组与标签已保存")
    }

    private func editorFieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.noonmarkSystem(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .frame(width: Self.fieldLabelWidth, height: 24, alignment: .leading)
    }

    private func resetTransientEditorState() {
        labelInput = ""
        isAddingLabel = false
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
            categoryError = "请输入分组名称。"
            return
        }
        do {
            let labels = try selectedLabels.map { try $0.choice }
            _ = try store.replaceTaskClassification(
                chainID: chainID,
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
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("classification.editor.remove-label.\(chainID.description).\(label.id)")
            .accessibilityLabel("从任务「\(taskTitle)」移除标签「\(label.name)」")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.10)))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("classification.editor.label-chip.\(chainID.description).\(label.id)")
        .accessibilityLabel("任务「\(taskTitle)」的标签「\(label.name)」")
    }

    private func editorError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.noonmarkSystem(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.warn)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("保存失败：\(message)")
    }

    private func loadDraft() {
        guard let projection = store.currentClassification(for: chainID),
              let catalog = store.classificationCatalog()
        else {
            categoryError = "无法读取当前分组与标签，请稍后重试。"
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
        let name = normalizedLabelName(labelInput)
        guard name.isEmpty == false else {
            labelError = "请输入标签名称。"
            return
        }

        let key = ClassificationNameCanonicalizer.canonicalKey(name)
        let candidate: EditorLabel = if let existing = activeLabels.first(where: {
            ClassificationNameCanonicalizer.canonicalKey($0.name) == key
        }) {
            .existing(existing)
        } else {
            .new(name: name, colorHex: Self.newLabelColorHex)
        }

        guard selectedLabels.contains(where: { $0.matches(candidate) }) == false else {
            labelError = "标签「\(name)」已经添加。"
            return
        }

        selectedLabels.append(candidate)
        labelError = nil
        saveDraft(errorPlacement: .label, clearsLabelInputOnSuccess: true)
        if labelError == nil {
            isAddingLabel = false
        }
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
            _ = try store.replaceTaskClassification(
                chainID: chainID,
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
        withAnimation(.easeInOut(duration: Self.animationDuration)) {
            showsSavedStatus = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard saveStatusGeneration == generation else { return }
            withAnimation(.easeInOut(duration: Self.animationDuration)) {
                showsSavedStatus = false
            }
        }
    }

    private func normalizedLabelName(_ name: String) -> String {
        ClassificationNameCanonicalizer.displayName(name)
    }

    private func editorErrorMessage(_ error: Error) -> String {
        switch error as? NoonmarkError {
        case let .invalidInput(message), let .invalidTransition(message), let .notFound(message):
            message
        case .invalidTitle:
            "分组或标签名称无效。"
        case .chainAbandoned:
            "已放弃的任务不能修改分组与标签。"
        case .immutableHistory:
            "历史分组与标签不能直接改写。"
        case .lockedDay:
            "历史日期已经锁定。"
        case .activeTraceAlreadyExists,
             .noActiveTrace,
             .futurePlanCannotComplete,
             .historicalCompletionCannotBeUndone,
             .openSubtasksPreventCompletion:
            "当前任务状态不允许修改分组与标签。"
        case nil:
            error.localizedDescription
        }
    }
}

private extension TaskClassificationEditor {
    enum ErrorPlacement {
        case category
        case label
    }

    enum ClassificationEditorError: LocalizedError {
        case invalidIdentifier

        var errorDescription: String? {
            "分组与标签资料无效，请重新打开任务后再试。"
        }
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
