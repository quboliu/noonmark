import NoonmarkCore
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import SwiftUI

struct ClassificationManagerButton: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var isHovered = false

    let title: String?
    let prominent: Bool

    init(title: String? = nil, prominent: Bool = false) {
        self.title = title
        self.prominent = prominent
    }

    private var resolvedTitle: String {
        title ?? AppPresentation(
            language: store.engine.preferences.language
        ).groupManagement.manageShortAction
    }

    var body: some View {
        Button {
            store.showingClassificationManager = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                Text(resolvedTitle)
                    .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                if prominent {
                    MicroLabel(
                        systemImage: "chevron.right",
                        color: prominent ? Theme.accent : Theme.text2
                    )
                }
            }
            .foregroundStyle(prominent ? Theme.accent : Theme.text2)
            .padding(.horizontal, prominent ? 10 : 7)
            .frame(height: prominent ? 30 : 24)
            .background {
                if prominent || isHovered {
                    RoundedRectangle(cornerRadius: 7).fill(
                        prominent
                            ? (isHovered ? Theme.accentSoftStrong : Theme.accentSoftMuted)
                            : Theme.controlFill
                    )
                }
            }
            .overlay {
                if prominent {
                    RoundedRectangle(cornerRadius: 7).stroke(Theme.accentStroke)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("classification.manager.open")
        .background {
            AppE2EViewAnchor(
                identifier: "classification.manager.open",
                verificationText: resolvedTitle
            )
        }
    }
}

struct ClassificationManagementDialog: View {
    private static let palette = ["#D87831", "#2A6FDB", "#0E9488", "#B44D5E", "#7C5CFF", "#D1477A"]

    @EnvironmentObject private var store: NoonmarkStore
    let close: () -> Void
    @State private var kind: ClassificationItemKind = .category
    @State private var search = ""
    @State private var isCreating = false
    @State private var newName = ""
    @State private var selectedColor = "#2A6FDB"
    @State private var editingID: String?
    @State private var editingName = ""
    @State private var showsArchived = false
    @State private var isCreateButtonHovered = false
    @State private var isArchivedHeaderHovered = false
    @State private var message: String?
    @State private var pendingCategoryDeletion:
        ClassificationCatalogItemProjection?
    @FocusState private var isSearchFocused: Bool

    private var catalog: ClassificationCatalogProjection? {
        store.classificationCatalog()
    }

    private var presentation: AppPresentation {
        AppPresentation(language: store.engine.preferences.language)
    }

    private var copy: ClassificationManagerCopy {
        presentation.classificationManager
    }

    private var selectedMetric: GroupManagementMetric {
        metric(for: kind)
    }

    private var categoryCount: Int {
        catalog?.manageableItems(for: .category).count ?? 0
    }

    private var labelCount: Int {
        catalog?.manageableItems(for: .label).count ?? 0
    }

    private var items: [ClassificationCatalogItemProjection] {
        let available = catalog?.manageableItems(for: kind) ?? []
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return available }
        return available.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var activeItems: [ClassificationCatalogItemProjection] {
        items.filter { $0.lifecycle == .active }
    }

    private var archivedItems: [ClassificationCatalogItemProjection] {
        items.filter { $0.lifecycle == .archived }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            RailDivider()
            toolbar
            if isCreating {
                creationEditor
                RailDivider()
            }
            itemList
            if let message {
                RailDivider()
                errorBanner(message)
            }
            RailDivider()
            footer
        }
        .frame(
            width: CGFloat(MacUIClassificationLayout.managerWidth),
            height: CGFloat(MacUIClassificationLayout.managerHeight)
        )
        .background(Theme.panel)
        .defaultFocus($isSearchFocused, true)
        .accessibilityIdentifier("classification.manager.dialog")
        .background {
            AppE2EViewAnchor(
                identifier: "classification.manager.dialog",
                verificationText: copy.title
            )
        }
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: kind) { _, _ in
            editingID = nil
            message = nil
        }
        .alert(
            pendingCategoryDeletion.map {
                copy.deleteGroupConfirmationTitle($0.name)
            } ?? "",
            isPresented: Binding(
                get: { pendingCategoryDeletion != nil },
                set: { isPresented in
                    if isPresented == false {
                        pendingCategoryDeletion = nil
                    }
                }
            ),
            presenting: pendingCategoryDeletion
        ) { item in
            Button(copy.cancelAction, role: .cancel) {
                pendingCategoryDeletion = nil
            }
            Button(copy.deleteGroupConfirmAction, role: .destructive) {
                deleteCategory(item)
            }
            .accessibilityIdentifier(
                "classification.manager.delete-category.confirm"
            )
        } message: { _ in
            Text(copy.deleteGroupConfirmationMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.title)
                    .font(.noonmarkSystem(size: 15, weight: .bold))
                    .foregroundStyle(Theme.text1)
                Text(copy.subtitle)
                    .font(.noonmarkSystem(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            Picker(copy.kindPickerTitle, selection: $kind) {
                Text(copy.kindTitle(.category, count: categoryCount))
                    .tag(ClassificationItemKind.category)
                Text(copy.kindTitle(.label, count: labelCount))
                    .tag(ClassificationItemKind.label)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 178)
            .accessibilityIdentifier("classification.manager.kind")
            .overlay {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        classificationKindAnchor(
                            kind: .category,
                            width: proxy.size.width / 2,
                            height: proxy.size.height
                        )
                        classificationKindAnchor(
                            kind: .label,
                            width: proxy.size.width / 2,
                            height: proxy.size.height
                        )
                    }
                }
                .allowsHitTesting(false)
            }
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.noonmarkSystem(size: 9, weight: .bold))
                    .foregroundStyle(Theme.text3)
                    .frame(
                        width: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize),
                        height: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize)
                    )
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.controlFill))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("classification.manager.close")
            .accessibilityLabel(copy.closeAccessibilityLabel)
            .background {
                AppE2EViewAnchor(
                    identifier: "classification.manager.close",
                    verificationText: copy.closeAccessibilityLabel
                )
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private func classificationKindAnchor(
        kind anchorKind: ClassificationItemKind,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            AppE2EViewAnchor(
                identifier: "classification.manager.kind.\(anchorKind.rawValue)",
                verificationText: copy.metricTitle(metric(for: anchorKind))
            )
            if kind == anchorKind {
                AppE2EViewAnchor(
                    identifier: "classification.manager.kind.selected.\(anchorKind.rawValue)",
                    verificationText: copy.selectedMetricVerification(
                        metric(for: anchorKind)
                    )
                )
            }
        }
        .frame(width: width, height: height)
    }

    private func metric(
        for kind: ClassificationItemKind
    ) -> GroupManagementMetric {
        kind == .category ? .category : .label
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.noonmarkSystem(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text3)
                TextField(copy.searchPlaceholder(selectedMetric), text: $search)
                    .textFieldStyle(.plain)
                    .font(.noonmarkSystem(size: 11.5))
                    .focused($isSearchFocused)
                if search.isEmpty == false {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.noonmarkSystem(size: 10.5))
                            .foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copy.clearSearchAccessibilityLabel)
                    .background {
                        AppE2EViewAnchor(
                            identifier: "classification.manager.search.clear",
                            verificationText: copy.clearSearchAccessibilityLabel
                        )
                    }
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.controlFill))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.lineSubtle))
            .accessibilityIdentifier("classification.manager.search")

            Button {
                withAnimation(Theme.shouldReduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isCreating.toggle()
                    message = nil
                }
            } label: {
                Label(
                    copy.newItemAction(selectedMetric),
                    systemImage: isCreating ? "xmark" : "plus"
                )
                    .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                    .foregroundStyle(isCreating ? Theme.text2 : Theme.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(
                                isCreating
                                    ? Theme.controlFill
                                    : (isCreateButtonHovered ? Theme.accentSoftStrong : Theme.accentSoftMuted)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(isCreating ? Theme.line : Theme.accentStroke)
                    )
            }
            .buttonStyle(.plain)
            .onHover { isCreateButtonHovered = $0 }
            .accessibilityIdentifier("classification.manager.create.toggle")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var creationEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(copy.namePlaceholder(selectedMetric), text: $newName)
                    .textFieldStyle(.plain)
                    .font(.noonmarkSystem(size: 11.5, weight: .medium))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accentStroke))
                    .onSubmit(createItem)

                TextActionButton(copy.createAction, action: createItem)
                    .disabled(ClassificationNameCanonicalizer.displayName(newName).isEmpty)
            }

            HStack(spacing: 8) {
                Text(copy.colorTitle)
                    .font(.noonmarkSystem(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                HStack(spacing: 2) {
                    ForEach(Self.palette, id: \.self) { color in
                        Button {
                            selectedColor = color
                        } label: {
                            Circle()
                                .fill(classificationUIColor(color))
                                .frame(width: 15, height: 15)
                                .overlay {
                                    if selectedColor == color {
                                        Circle().stroke(.white, lineWidth: 2)
                                        Circle().stroke(classificationUIColor(color), lineWidth: 1).padding(-2)
                                    }
                                }
                        }
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                        .accessibilityLabel(copy.chooseColorAccessibilityLabel(color))
                    }
                }
                Spacer()
                Text(copy.usageRule(selectedMetric))
                    .font(.noonmarkSystem(size: 9.5))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.accentSoftWash)
        .accessibilityIdentifier("classification.manager.create.editor")
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionHeader(title: copy.activeSectionTitle, count: activeItems.count)
                if activeItems.isEmpty {
                    emptyRow(
                        copy.emptyActiveMessage(
                            selectedMetric,
                            isSearching: search.isEmpty == false
                        )
                    )
                } else {
                    ForEach(activeItems) { item in
                        itemRow(item)
                    }
                }

                if archivedItems.isEmpty == false {
                    archivedHeader
                    if showsArchived {
                        ForEach(archivedItems) { item in
                            itemRow(item)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("classification.manager.list")
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.noonmarkSystem(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.text3)
            Text("\(count)")
                .font(.noonmarkSystem(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Capsule().fill(Theme.chip))
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Theme.panel2.opacity(0.45))
    }

    private var archivedHeader: some View {
        Button {
            withAnimation(Theme.shouldReduceMotion ? nil : .easeInOut(duration: 0.16)) {
                showsArchived.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                MicroLabel(systemImage: "chevron.right")
                    .rotationEffect(.degrees(showsArchived ? 90 : 0))
                Text(copy.archivedSectionTitle)
                    .font(.noonmarkSystem(size: 9.5, weight: .bold))
                    .tracking(0.6)
                Text("\(archivedItems.count)")
                    .font(.noonmarkSystem(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Capsule().fill(Theme.chip))
                Spacer()
                Text(showsArchived ? copy.collapseAction : copy.expandAction)
                    .font(.noonmarkSystem(size: 9.5))
            }
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isArchivedHeaderHovered ? Theme.controlFill : Theme.panel2.opacity(0.45))
        .onHover { isArchivedHeaderHovered = $0 }
        .accessibilityIdentifier("classification.manager.archived.toggle")
    }

    private func emptyRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .foregroundStyle(Theme.text3)
            Text(text)
                .font(.noonmarkSystem(size: 11))
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
    }

    private func itemRow(_ item: ClassificationCatalogItemProjection) -> some View {
        let canDiscard = item.currentUsageCount == 0 && item.historicalUsageCount == 0
        return HStack(spacing: 8) {
            itemSymbol(item)
            if editingID == item.id {
                TextField(copy.nameEditorPlaceholder, text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.noonmarkSystem(size: 11.5, weight: .medium))
                    .onSubmit { rename(item) }
                TextActionButton(copy.saveAction) { rename(item) }
                TextActionButton(copy.cancelAction, tone: .neutral) { editingID = nil }
            } else {
                let titleColor = kind == .category
                    ? item.categoryPresentationColor
                    : (item.lifecycle == .active ? Theme.text1 : Theme.text3)
                Text(item.name)
                    .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                    .foregroundStyle(item.lifecycle == .active ? titleColor : Theme.text3)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 4) {
                    Text(copy.currentReferenceCount(item.currentUsageCount))
                    Text("·")
                    Text(copy.historicalReferenceCount(item.historicalUsageCount))
                }
                .font(.noonmarkSystem(size: 9.5))
                .foregroundStyle(Theme.text3)
                .accessibilityIdentifier("classification.manager.references.\(item.id)")

                Menu {
                    if kind == .category,
                       item.presentationApproval == .pendingAIReview,
                       item.lifecycle == .active
                    {
                        Button(copy.approvePresentationAction, systemImage: "checkmark.seal") {
                            approvePresentation(item)
                        }
                        .accessibilityIdentifier(
                            "classification.manager.approve-presentation.\(item.id)"
                        )
                        Divider()
                    }
                    Button(copy.renameAction, systemImage: "pencil") {
                        editingID = item.id
                        editingName = item.name
                    }
                    .accessibilityIdentifier(
                        "\(MacUIClassificationAccessibility.renameActionPrefix).\(item.id)"
                    )
                    if item.lifecycle == .active {
                        Button(copy.archiveAction, systemImage: "archivebox") {
                            archive(item)
                        }
                        .accessibilityIdentifier(
                            "\(MacUIClassificationAccessibility.archiveActionPrefix).\(item.id)"
                        )
                        if kind == .category {
                            Button(role: .destructive) {
                                pendingCategoryDeletion = item
                            } label: {
                                Label(
                                    copy.deleteGroupAction,
                                    systemImage: "trash"
                                )
                            }
                            .accessibilityIdentifier(
                                "classification.manager.delete-category.\(item.id)"
                            )
                        }
                    } else {
                        Button(copy.restoreAction, systemImage: "arrow.uturn.backward") {
                            restore(item)
                        }
                        .accessibilityIdentifier(
                            "\(MacUIClassificationAccessibility.restoreActionPrefix).\(item.id)"
                        )
                    }
                    if kind == .label || item.lifecycle != .active {
                        Divider()
                        if canDiscard == false {
                            Text(copy.referencedItemsArchiveOnlyNotice)
                        }
                        Button(role: .destructive) {
                            discard(item)
                        } label: {
                            Label(copy.discardAction, systemImage: "trash")
                        }
                        .disabled(canDiscard == false)
                        .accessibilityIdentifier(
                            "\(MacUIClassificationAccessibility.discardActionPrefix).\(item.id)"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.noonmarkSystem(size: 11, weight: .bold))
                        .foregroundStyle(Theme.text3)
                        .frame(
                            width: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize),
                            height: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize)
                        )
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .overlay {
                    AppE2EViewAnchor(
                        identifier: "classification.manager.actions.\(item.id)"
                    )
                }
                .accessibilityIdentifier(
                    "classification.manager.actions.\(item.id)"
                )
            }
        }
        .padding(.horizontal, 14)
        .frame(height: CGFloat(MacUIClassificationLayout.managerRowHeight))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.lineSubtle)
                .frame(height: 1)
                .padding(.leading, 48)
        }
        .accessibilityIdentifier("classification.manager.item.\(item.id)")
    }

    @ViewBuilder
    private func itemSymbol(_ item: ClassificationCatalogItemProjection) -> some View {
        let color = kind == .category
            ? item.categoryPresentationColor
            : classificationUIColor(item.colorHex)
        if kind == .category {
            Image(systemName: "folder.fill")
                .font(.noonmarkSystem(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            item.usesApprovedCategoryPresentation
                                ? color.opacity(0.09)
                                : Theme.controlFill
                        )
                )
        } else {
            Text("#")
                .font(.noonmarkSystem(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.09)))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
            Text(copy.historyNotice)
                .font(.noonmarkSystem(size: 10))
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(Theme.text3)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .accessibilityIdentifier("classification.manager.history-notice")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
            Text(message)
                .font(.noonmarkSystem(size: 10))
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(Theme.warn)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Theme.warn.opacity(0.06))
        .accessibilityIdentifier("classification.manager.error")
    }

    private func createItem() {
        let name = ClassificationNameCanonicalizer.displayName(newName)
        guard name.isEmpty == false else { return }
        let intent: ClassificationIntent = kind == .category
            ? .createCategory(name: name, colorHex: selectedColor)
            : .createLabel(name: name, colorHex: selectedColor)
        mutate(intent)
        if message == nil {
            newName = ""
            isCreating = false
        }
    }

    private func rename(_ item: ClassificationCatalogItemProjection) {
        let name = ClassificationNameCanonicalizer.displayName(editingName)
        guard name.isEmpty == false, let id = UUID(uuidString: item.id) else { return }
        mutate(kind == .category
            ? .renameCategory(TaskCategoryID(id), to: name)
            : .renameLabel(TaskLabelID(id), to: name))
        if message == nil { editingID = nil }
    }

    private func archive(_ item: ClassificationCatalogItemProjection) {
        guard let id = UUID(uuidString: item.id) else { return }
        mutate(kind == .category ? .archiveCategory(TaskCategoryID(id)) : .archiveLabel(TaskLabelID(id)))
    }

    private func approvePresentation(_ item: ClassificationCatalogItemProjection) {
        guard let id = UUID(uuidString: item.id) else { return }
        mutate(.approveCategoryPresentation(TaskCategoryID(id)))
    }

    private func restore(_ item: ClassificationCatalogItemProjection) {
        guard let id = UUID(uuidString: item.id) else { return }
        mutate(kind == .category ? .restoreCategory(TaskCategoryID(id)) : .restoreLabel(TaskLabelID(id)))
    }

    private func discard(_ item: ClassificationCatalogItemProjection) {
        guard let id = UUID(uuidString: item.id) else { return }
        mutate(kind == .category ? .hardDeleteCategory(TaskCategoryID(id)) : .hardDeleteLabel(TaskLabelID(id)))
    }

    private func deleteCategory(
        _ item: ClassificationCatalogItemProjection
    ) {
        defer { pendingCategoryDeletion = nil }
        guard let id = UUID(uuidString: item.id) else { return }
        do {
            _ = try store.deleteTaskCategoryFromToday(
                TaskCategoryID(id)
            )
            message = nil
        } catch {
            let failure = AppPresentation.classify(
                error,
                for: .classificationMutation
            )
            message = presentation.message(for: failure)
        }
    }

    private func mutate(_ intent: ClassificationIntent) {
        do {
            _ = try store.applyClassificationIntent(intent)
            message = nil
        } catch {
            let failure = AppPresentation.classify(error, for: .classificationMutation)
            message = presentation.message(for: failure)
        }
    }
}
