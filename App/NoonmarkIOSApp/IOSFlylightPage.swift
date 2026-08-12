import SwiftUI
import NoonmarkCore

struct IOSFlylightPage: View {
    @EnvironmentObject private var store: IOSStore
    @State private var searchText = ""
    @State private var editor: FlylightEditorMode?

    private enum FlylightEditorMode: Identifiable {
        case create
        case edit(IdeaEntry)

        var id: String {
            switch self {
            case .create: "create"
            case let .edit(idea): "edit-\(idea.id)"
            }
        }
    }

    private var entries: [IdeaEntry] {
        let query: IdeaCollectionQuery = searchText.isEmpty
            ? .recent
            : .search(text: searchText)
        return store.engine.ideaCollection(query, today: store.today).ideas
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        editor = .create
                    } label: {
                        Label("新建飞光", systemImage: "plus")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("时间线")
                        .font(.headline)
                    if entries.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "wind")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("还没有飞光")
                                .font(.headline)
                            Text("把稍纵即逝的想法先记下来。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { idea in
                                ideaRow(idea)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .searchable(text: $searchText, prompt: "搜索飞光")
        .navigationTitle("飞光")
        .sheet(item: $editor) { mode in
            switch mode {
            case .create:
                IOSFlylightEditor()
                    .environmentObject(store)
            case let .edit(idea):
                IOSFlylightEditor(idea: idea)
                    .environmentObject(store)
            }
        }
        .onAppear {
            guard let selectedIdeaID = store.selectedIdeaID,
                  let idea = store.engine.ideas[selectedIdeaID]
            else { return }
            editor = .edit(idea)
            store.selectedIdeaID = nil
        }
    }

    private func ideaRow(_ idea: IdeaEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(idea.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let category = categoryName(for: idea) {
                Text(category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(idea.createdAt, style: .date)
                Spacer()
                Button("编辑") { editor = .edit(idea) }
                Button(idea.pinnedAt == nil ? "加入 Sticky Note" : "移出 Sticky Note") {
                    store.toggleSticky(idea)
                }
                Button("删除", role: .destructive) { store.deleteFlylight(idea) }
                    .accessibilityIdentifier("ios.flylight.delete.\(idea.body)")
            }
            .font(.caption)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func categoryName(for idea: IdeaEntry) -> String? {
        guard let id = idea.categoryID?.description,
              let item = store.classificationCatalog?.categories.first(where: { $0.id == id })
        else { return nil }
        return "#\(item.name)"
    }
}

struct IOSFlylightEditor: View {
    @EnvironmentObject private var store: IOSStore
    @Environment(\.dismiss) private var dismiss
    let idea: IdeaEntry?
    @State private var bodyText = ""
    @State private var categoryID: String?
    @State private var labelIDs: Set<String> = []

    init(idea: IdeaEntry? = nil) {
        self.idea = idea
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("正文") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 140)
                        .accessibilityIdentifier("ios.flylight.editor")
                }
                if let catalog = store.classificationCatalog {
                    Section("分类") {
                        Picker("类别", selection: $categoryID) {
                            Text("未分类").tag(String?.none)
                            ForEach(catalog.categories.filter { $0.lifecycle == .active }) { item in
                                Text(item.name).tag(Optional(item.id))
                            }
                        }
                        ForEach(catalog.labels.filter { $0.lifecycle == .active }) { item in
                            Toggle(item.name, isOn: Binding(
                                get: { labelIDs.contains(item.id) },
                                set: { enabled in
                                    if enabled {
                                        labelIDs.insert(item.id)
                                    } else {
                                        labelIDs.remove(item.id)
                                    }
                                }
                            ))
                        }
                    }
                }
            }
            .navigationTitle(idea == nil ? "新建飞光" : "编辑飞光")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func save() {
        let category = categoryID.flatMap { value in
            UUID(uuidString: value).map(TaskCategoryID.init)
        }
        let labels = labelIDs.compactMap { value in
            UUID(uuidString: value).map(TaskLabelID.init)
        }
        if let idea {
            store.editFlylight(idea, body: bodyText, categoryID: category, labelIDs: labels)
        } else {
            store.flylightDraft = bodyText
            store.addFlylight(categoryID: category, labelIDs: labels)
        }
        dismiss()
    }

    private func load() {
        guard let idea else { return }
        bodyText = idea.body
        categoryID = idea.categoryID?.description
        labelIDs = Set(idea.labelIDs.map(\.description))
    }
}
