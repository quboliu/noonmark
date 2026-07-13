import NoonmarkCore
import NoonmarkMacUIContract
import SwiftUI

struct ClassificationManagerButton: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var isHovered = false

    let title: String
    let prominent: Bool

    init(title: String = "管理", prominent: Bool = false) {
        self.title = title
        self.prominent = prominent
    }

    var body: some View {
        Button {
            store.showingClassificationManager = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                if prominent {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(prominent ? Theme.accent : Theme.text2)
            .padding(.horizontal, prominent ? 10 : 7)
            .frame(height: prominent ? 30 : 24)
            .background {
                if prominent || isHovered {
                    RoundedRectangle(cornerRadius: 7).fill(
                        prominent
                            ? Theme.accentSoft.opacity(isHovered ? 0.88 : 0.64)
                            : Theme.controlFill
                    )
                }
            }
            .overlay {
                if prominent {
                    RoundedRectangle(cornerRadius: 7).stroke(Theme.accent.opacity(0.20))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("classification.manager.open")
    }
}

struct ClassificationManagementDialog: View {
    private static let palette = ["#D87831", "#2A6FDB", "#0E9488", "#B44D5E", "#7C5CFF", "#D1477A"]

    @EnvironmentObject private var store: NoonmarkStore
    let close: () -> Void
    @State private var kind: ClassificationItemKind = CommandLine.arguments.contains(
        "--e2e-classification-manager-labels"
    ) ? .label : .category
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
    @FocusState private var isSearchFocused: Bool

    private var catalog: ClassificationCatalogProjection? {
        store.classificationCatalog()
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
            Divider()
            toolbar
            if isCreating {
                creationEditor
                Divider()
            }
            itemList
            if let message {
                Divider()
                errorBanner(message)
            }
            Divider()
            footer
        }
        .frame(
            width: CGFloat(MacUIClassificationLayout.managerWidth),
            height: CGFloat(MacUIClassificationLayout.managerHeight)
        )
        .background(Theme.panel)
        .defaultFocus($isSearchFocused, true)
        .accessibilityIdentifier("classification.manager.dialog")
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: kind) { _, _ in
            editingID = nil
            message = nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("分类管理")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.text1)
                Text("维护当前分类，不改写任务的历史快照")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            Picker("类型", selection: $kind) {
                Text("分组  \(categoryCount)").tag(ClassificationItemKind.category)
                Text("标签  \(labelCount)").tag(ClassificationItemKind.label)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 178)
            .accessibilityIdentifier("classification.manager.kind")
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.controlFill))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("classification.manager.close")
            .accessibilityLabel("关闭分类管理")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text3)
                TextField(kind == .category ? "搜索分组" : "搜索标签", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($isSearchFocused)
                if search.isEmpty == false {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.controlFill))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line.opacity(0.72)))
            .accessibilityIdentifier("classification.manager.search")

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isCreating.toggle()
                    message = nil
                }
            } label: {
                Label(kind == .category ? "新建分组" : "新建标签", systemImage: isCreating ? "xmark" : "plus")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isCreating ? Theme.text2 : Theme.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(
                                isCreating
                                    ? Theme.controlFill
                                    : Theme.accentSoft.opacity(isCreateButtonHovered ? 0.92 : 0.62)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(isCreating ? Theme.line : Theme.accent.opacity(0.22))
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
                TextField(kind == .category ? "分组名称" : "标签名称", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.35)))
                    .onSubmit(createItem)

                Button("创建", action: createItem)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .disabled(ClassificationNameCanonicalizer.displayName(newName).isEmpty)
            }

            HStack(spacing: 9) {
                Text("颜色")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.text3)
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
                    .buttonStyle(.plain)
                    .accessibilityLabel("选择颜色 \(color)")
                }
                Spacer()
                Text(kind == .category ? "任务至多使用一个分组" : "任务可使用多个标签")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.accentSoft.opacity(0.22))
        .accessibilityIdentifier("classification.manager.create.editor")
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionHeader(title: "使用中", count: activeItems.count)
                if activeItems.isEmpty {
                    emptyRow(search.isEmpty ? "还没有使用中的项目" : "没有匹配的使用中项目")
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
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.text3)
            Text("\(count)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
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
            withAnimation(.easeInOut(duration: 0.16)) {
                showsArchived.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(showsArchived ? 90 : 0))
                Text("已归档")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.7)
                Text("\(archivedItems.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Capsule().fill(Theme.chip))
                Spacer()
                Text(showsArchived ? "收起" : "展开")
                    .font(.system(size: 9.5))
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
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
    }

    private func itemRow(_ item: ClassificationCatalogItemProjection) -> some View {
        let canDiscard = item.currentUsageCount == 0 && item.historicalUsageCount == 0
        return HStack(spacing: 9) {
            itemSymbol(item)
            if editingID == item.id {
                TextField("名称", text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .onSubmit { rename(item) }
                Button("保存") { rename(item) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Button("取消") { editingID = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            } else {
                Text(item.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(item.lifecycle == .active ? Theme.text1 : Theme.text3)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 5) {
                    Text("当前 \(item.currentUsageCount)")
                    Text("·")
                    Text("历史 \(item.historicalUsageCount)")
                }
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.text3)
                .accessibilityIdentifier("classification.manager.references.\(item.id)")

                Menu {
                    Button("重命名", systemImage: "pencil") {
                        editingID = item.id
                        editingName = item.name
                    }
                    .accessibilityIdentifier(
                        "\(MacUIClassificationAccessibility.renameActionPrefix).\(item.id)"
                    )
                    if item.lifecycle == .active {
                        Button("归档", systemImage: "archivebox") { archive(item) }
                            .accessibilityIdentifier(
                                "\(MacUIClassificationAccessibility.archiveActionPrefix).\(item.id)"
                            )
                    } else {
                        Button("恢复使用", systemImage: "arrow.uturn.backward") { restore(item) }
                            .accessibilityIdentifier(
                                "\(MacUIClassificationAccessibility.restoreActionPrefix).\(item.id)"
                            )
                    }
                    Divider()
                    if canDiscard == false {
                        Text("仍有任务或历史引用，只能归档")
                    }
                    Button(role: .destructive) { discard(item) } label: {
                        Label("废弃", systemImage: "trash")
                    }
                    .disabled(canDiscard == false)
                    .accessibilityIdentifier(
                        "\(MacUIClassificationAccessibility.discardActionPrefix).\(item.id)"
                    )
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: CGFloat(MacUIClassificationLayout.managerRowHeight))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.line.opacity(0.72))
                .frame(height: 1)
                .padding(.leading, 48)
        }
        .accessibilityIdentifier("classification.manager.item.\(item.id)")
    }

    @ViewBuilder
    private func itemSymbol(_ item: ClassificationCatalogItemProjection) -> some View {
        let color = classificationUIColor(item.colorHex)
        if kind == .category {
            Image(systemName: "folder.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.09)))
        } else {
            Text("#")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.09)))
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10.5, weight: .semibold))
            Text("名称与生命周期可调整；历史引用始终保留。")
                .font(.system(size: 10))
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(Theme.text3)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .accessibilityIdentifier("classification.manager.history-notice")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10.5, weight: .semibold))
            Text(message)
                .font(.system(size: 10))
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

    private func restore(_ item: ClassificationCatalogItemProjection) {
        guard let id = UUID(uuidString: item.id) else { return }
        mutate(kind == .category ? .restoreCategory(TaskCategoryID(id)) : .restoreLabel(TaskLabelID(id)))
    }

    private func discard(_ item: ClassificationCatalogItemProjection) {
        guard let id = UUID(uuidString: item.id) else { return }
        mutate(kind == .category ? .hardDeleteCategory(TaskCategoryID(id)) : .hardDeleteLabel(TaskLabelID(id)))
    }

    private func mutate(_ intent: ClassificationIntent) {
        do {
            _ = try store.applyClassificationIntent(intent)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
