import Foundation
import NoonmarkCore
import SwiftUI

struct TaskClassificationEditor: View {
    private static let animationDuration = 0.18
    private static let newLabelColorHex = "#0E9488"
    private static let newGroupColorHex = "#D87831"

    @EnvironmentObject private var store: NoonmarkStore

    let chainID: TaskChainID
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("当前任务")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.7)
                Spacer()
                ClassificationManagerButton()
            }
            categorySection
            labelSection

            HStack {
                Spacer(minLength: 0)
                savedStatus
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Theme.line.opacity(0.8), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("classification.editor.\(chainID.description)")
        .accessibilityLabel("任务「\(taskTitle)」的分类编辑器")
        .onAppear(perform: loadDraft)
        .onChange(of: chainID) { _, _ in
            loadDraft()
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("分组")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.5)
                Spacer()
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
                    Text(selectedCategoryID == nil ? "加入分组" : "更换")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityIdentifier("classification.editor.category.\(chainID.description)")
                .accessibilityLabel("任务「\(taskTitle)」的分组")
            }

            if let selectedCategory {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(classificationUIColor(selectedCategory.colorHex))
                    Text(selectedCategory.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Spacer()
                    Text("每项任务只能属于一个分组")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                }
            } else if isCreatingGroup == false {
                Text("尚未加入分组")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
            }

            if isCreatingGroup {
                HStack(spacing: 8) {
                    Circle()
                        .fill(classificationUIColor(Self.newGroupColorHex))
                        .frame(width: 8, height: 8)
                    TextField("分组名称", text: $newGroupName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .onSubmit(createAndSelectGroup)
                    Button("取消") {
                        newGroupName = ""
                        isCreatingGroup = false
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text3)
                    Button("创建并加入", action: createAndSelectGroup)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.line).frame(height: 1)
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

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("标签")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.5)

            if selectedLabels.isEmpty {
                Text("尚未添加标签")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .padding(.vertical, 2)
            } else {
                ClassificationEditorFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(selectedLabels) { label in
                        labelChip(label)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextField("输入标签名称，回车保存", text: $labelInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text1)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.controlFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(labelError == nil ? Theme.line.opacity(0.8) : Theme.warn, lineWidth: 1)
                )
                .onSubmit(addLabelFromInput)
                .accessibilityIdentifier("classification.editor.label-input.\(chainID.description)")
                .accessibilityLabel("为任务「\(taskTitle)」添加标签")

            if let labelError {
                editorError(labelError)
            }
        }
    }

    private var savedStatus: some View {
        Label("已保存", systemImage: "checkmark.circle.fill")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.ok)
            .opacity(showsSavedStatus ? 1 : 0)
            .accessibilityHidden(showsSavedStatus == false)
            .accessibilityIdentifier("classification.editor.save-status.\(chainID.description)")
            .accessibilityLabel("任务「\(taskTitle)」的分类已保存")
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
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(color)
            Text(label.name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)

            Button {
                removeLabel(label)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
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
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.10)))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(color.opacity(0.48), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("classification.editor.label-chip.\(chainID.description).\(label.id)")
        .accessibilityLabel("任务「\(taskTitle)」的标签「\(label.name)」")
    }

    private func editorError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.warn)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("保存失败：\(message)")
    }

    private func loadDraft() {
        guard let projection = store.currentClassification(for: chainID),
              let catalog = store.classificationCatalog()
        else {
            categoryError = "无法读取当前分类，请稍后重试。"
            return
        }

        activeCategories = catalog.categories.filter { $0.lifecycle == .active }
        activeLabels = catalog.labels.filter { $0.lifecycle == .active }
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
            "分类名称无效。"
        case .chainAbandoned:
            "已放弃的任务不能修改分类。"
        case .immutableHistory:
            "历史分类不能直接改写。"
        case .lockedDay:
            "历史日期已经锁定。"
        case .activeTraceAlreadyExists,
             .noActiveTrace,
             .futurePlanCannotComplete,
             .historicalCompletionCannotBeUndone,
             .openSubtasksPreventCompletion:
            "当前任务状态不允许修改分类。"
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
            "分类资料无效，请重新打开任务后再试。"
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
