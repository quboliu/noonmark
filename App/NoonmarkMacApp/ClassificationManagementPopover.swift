import NoonmarkCore
import SwiftUI

struct ClassificationManagerButton: View {
    @State private var isPresented = CommandLine.arguments.contains("--e2e-open-classification-manager")

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("管理", systemImage: "slider.horizontal.3")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("classification.manager.open")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ClassificationManagementPopover()
        }
    }
}

private struct ClassificationManagementPopover: View {
    private static let palette = ["#D87831", "#2A6FDB", "#0E9488", "#B44D5E", "#7C5CFF", "#D1477A"]

    @EnvironmentObject private var store: NoonmarkStore
    @State private var kind: ClassificationItemKind = CommandLine.arguments.contains(
        "--e2e-classification-manager-labels"
    ) ? .label : .category
    @State private var search = ""
    @State private var isCreating = false
    @State private var newName = ""
    @State private var selectedColor = "#2A6FDB"
    @State private var editingID: String?
    @State private var editingName = ""
    @State private var message: String?

    private var items: [ClassificationCatalogItemProjection] {
        let catalog = store.classificationCatalog()
        let source = kind == .category ? catalog?.categories : catalog?.labels
        let available = source?.filter { $0.mergedIntoID == nil } ?? []
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return available }
        return available.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    itemSection("使用中", lifecycle: .active)
                    itemSection("已归档", lifecycle: .archived)
                }
                .padding(14)
            }
            if let message {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.warn)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: 540, height: 470)
        .background(Theme.panel)
        .accessibilityIdentifier("classification.manager.popover")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("组织管理")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.text1)
                Text("全局维护分组与标签，不改变历史快照。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            Picker("类型", selection: $kind) {
                Text("分组").tag(ClassificationItemKind.category)
                Text("标签").tag(ClassificationItemKind.label)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 150)
        }
        .padding(14)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.text3)
                TextField(kind == .category ? "搜索分组" : "搜索标签", text: $search)
                    .textFieldStyle(.plain)
                Button {
                    isCreating.toggle()
                } label: {
                    Label(kind == .category ? "新建分组" : "新建标签", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.controlFill))

            if isCreating {
                HStack(spacing: 8) {
                    TextField(kind == .category ? "分组名称" : "标签名称", text: $newName)
                        .textFieldStyle(.plain)
                        .onSubmit(createItem)
                    ForEach(Self.palette, id: \.self) { color in
                        Button {
                            selectedColor = color
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(classificationUIColor(color))
                                .frame(width: 18, height: 18)
                                .overlay {
                                    if selectedColor == color {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 8, weight: .black))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    Button("创建", action: createItem)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func itemSection(_ title: String, lifecycle: ClassificationLifecycle) -> some View {
        let sectionItems = items.filter { $0.lifecycle == lifecycle }
        if sectionItems.isEmpty == false {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.text3)
                .padding(.top, 5)
            ForEach(sectionItems) { item in
                itemRow(item)
            }
        }
    }

    private func itemRow(_ item: ClassificationCatalogItemProjection) -> some View {
        let canDiscard = item.currentUsageCount == 0 && item.historicalUsageCount == 0
        return HStack(spacing: 9) {
            itemSymbol(item)
            if editingID == item.id {
                TextField("名称", text: $editingName)
                    .textFieldStyle(.plain)
                    .onSubmit { rename(item) }
                Button("保存") { rename(item) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(item.lifecycle == .active ? Theme.text1 : Theme.text3)
                    Text("当前 \(item.currentUsageCount) · 历史 \(item.historicalUsageCount)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.text3)
                }
                Spacer()
                Menu {
                    Button("重命名", systemImage: "pencil") {
                        editingID = item.id
                        editingName = item.name
                    }
                    if item.lifecycle == .active {
                        Button("归档", systemImage: "archivebox") { archive(item) }
                    } else {
                        Button("恢复使用", systemImage: "arrow.uturn.backward") { restore(item) }
                    }
                    Divider()
                    if canDiscard == false {
                        Text("仍有任务或历史引用，只能归档")
                    }
                    Button(role: .destructive) { discard(item) } label: {
                        Label("废弃", systemImage: "trash")
                    }
                    .disabled(canDiscard == false)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.controlFill.opacity(0.55)))
    }

    @ViewBuilder
    private func itemSymbol(_ item: ClassificationCatalogItemProjection) -> some View {
        let color = classificationUIColor(item.colorHex)
        if kind == .category {
            Image(systemName: "folder.fill")
                .foregroundStyle(color)
                .frame(width: 24)
        } else {
            Text("#")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.10)))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(color.opacity(0.50), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
        }
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
