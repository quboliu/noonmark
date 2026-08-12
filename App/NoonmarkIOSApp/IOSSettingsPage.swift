@_spi(ClassificationUserDecision) import NoonmarkCore
import SwiftUI

struct IOSSettingsPage: View {
    @EnvironmentObject private var store: IOSStore
    @State private var reviewCatalog = false

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: Binding(
                    get: { store.engine.preferences.theme },
                    set: { store.setTheme($0) }
                )) {
                    Text("冷灰").tag(AppTheme.coolGray)
                    Text("暖纸").tag(AppTheme.warmPaper)
                }
                Picker("语言", selection: Binding(
                    get: { store.engine.preferences.language },
                    set: { store.setLanguage($0) }
                )) {
                    Text("中文").tag(AppLanguage.chinese)
                    Text("English").tag(AppLanguage.english)
                }
                Toggle("显示诗句", isOn: Binding(
                    get: { store.engine.preferences.settingsPoemDisplayPolicy.enabled },
                    set: { value in
                        var policy = store.engine.preferences.settingsPoemDisplayPolicy
                        policy.enabled = value
                        store.setPoemPolicy(policy)
                    }
                ))
            }

            Section("数据") {
                Button("导出 Noonmark 数据包") { store.exportDataPackage() }
                    .accessibilityIdentifier("ios.data-package.export")
                Button("导入 Noonmark 数据包") { store.beginDataPackageImport() }
                    .accessibilityIdentifier("ios.data-package.import")
                Button("导出诊断记录") { store.exportDiagnostics() }
                    .accessibilityIdentifier("ios.diagnostics.export")
                Text("导入前会校验完整 snapshot；当前数据不会在校验失败时被替换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let status = store.dataPackageStatusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(IOSTheme.accent)
                        .accessibilityIdentifier("ios.data-package.status")
                }
            }

            Section("备份") {
                Picker("频率", selection: Binding(
                    get: { store.engine.preferences.backupPolicy.frequency },
                    set: { frequency in
                        var policy = store.engine.preferences.backupPolicy
                        policy.frequency = frequency
                        store.setBackupPolicy(policy)
                    }
                )) {
                    Text("关闭").tag(ScheduledBackupFrequency.off)
                    Text("每天").tag(ScheduledBackupFrequency.daily)
                    Text("每周").tag(ScheduledBackupFrequency.weekly)
                }
                Picker("目标", selection: Binding(
                    get: { store.engine.preferences.backupPolicy.destination },
                    set: { destination in
                        var policy = store.engine.preferences.backupPolicy
                        policy.destination = destination
                        store.setBackupPolicy(policy)
                    }
                )) {
                    Text("iCloud Drive").tag(BackupDestinationKind.iCloudDrive)
                }
                if store.engine.preferences.backupPolicy.destination == .s3 {
                    Text("S3 是规划中入口，当前不可用；请选择 iCloud Drive。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("备份只会在目标权限和运行边界通过后执行；当前页面不把本地保存冒充云端完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("同步") {
                Picker("数据模式", selection: Binding(
                    get: { store.engine.preferences.dataMode },
                    set: { store.setDataMode($0) }
                )) {
                    Text("本地优先").tag(AppDataMode.localFirst)
                    Text("在线优先").tag(AppDataMode.onlineFirst)
                }
                Toggle("启用本地优先同步", isOn: Binding(
                    get: { store.engine.preferences.localFirstSyncPolicy.enabled },
                    set: { enabled in
                        var policy = store.engine.preferences.localFirstSyncPolicy
                        policy.enabled = enabled
                        store.setSyncPolicy(policy)
                    }
                ))
                let syncEndpoint = store.engine.preferences.localFirstSyncPolicy.endpoint
                if syncEndpoint == .s3 || syncEndpoint == .webDAV {
                    Text("当前端点是规划中的自定义服务，S3 与 WebDAV 尚未接入。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("切换到 iCloud") {
                        var policy = store.engine.preferences.localFirstSyncPolicy
                        policy.endpoint = .iCloud
                        store.setSyncPolicy(policy)
                    }
                } else {
                    Picker("端点", selection: Binding(
                        get: { store.engine.preferences.localFirstSyncPolicy.endpoint },
                        set: { endpoint in
                            var policy = store.engine.preferences.localFirstSyncPolicy
                            policy.endpoint = endpoint
                            store.setSyncPolicy(policy)
                        }
                    )) {
                        Text("iCloud").tag(CloudSyncEndpointKind.iCloud)
                        Text("本地目录").tag(CloudSyncEndpointKind.localFolder)
                    }
                }
                Picker("模式", selection: Binding(
                    get: { store.engine.preferences.localFirstSyncPolicy.mode },
                    set: { mode in
                        var policy = store.engine.preferences.localFirstSyncPolicy
                        policy.mode = mode
                        store.setSyncPolicy(policy)
                    }
                )) {
                    Text("手动").tag(CloudSyncMode.manual)
                    Text("自动").tag(CloudSyncMode.automatic)
                }
                Stepper(
                    "间隔 \(store.engine.preferences.localFirstSyncPolicy.intervalSeconds) 秒",
                    value: Binding(
                        get: { store.engine.preferences.localFirstSyncPolicy.intervalSeconds },
                        set: { seconds in
                            var policy = store.engine.preferences.localFirstSyncPolicy
                            policy.intervalSeconds = seconds
                            store.setSyncPolicy(policy)
                        }
                    ),
                    in: 30 ... 43200,
                    step: 30
                )
                Toggle("生成冲突副本", isOn: Binding(
                    get: { store.engine.preferences.localFirstSyncPolicy.generateConflictCopy },
                    set: { enabled in
                        var policy = store.engine.preferences.localFirstSyncPolicy
                        policy.generateConflictCopy = enabled
                        store.setSyncPolicy(policy)
                    }
                ))
                Stepper(
                    "保留索引 \(store.engine.preferences.localFirstSyncPolicy.snapshotRetention.indexRetentionDays) 天",
                    value: Binding(
                        get: { store.engine.preferences.localFirstSyncPolicy.snapshotRetention.indexRetentionDays },
                        set: { days in
                            var policy = store.engine.preferences.localFirstSyncPolicy
                            policy.snapshotRetention.indexRetentionDays = days
                            store.setSyncPolicy(policy)
                        }
                    ),
                    in: 1 ... 365,
                    step: 1
                )
                Button("现在同步") { store.requestSync() }
                Text(store.syncMessage ?? "iOS 同步将在 entitlement、账户和 transport 验证完成后开放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("分类目录") {
                if let catalog = store.classificationCatalog {
                    Button("查看分类与标签") { reviewCatalog = true }
                    Text("\(catalog.categories.count) 个分类，\(catalog.labels.count) 个标签")
                        .foregroundStyle(.secondary)
                } else {
                    Text("当前没有分类目录")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("设置")
        .sheet(isPresented: $reviewCatalog) {
            IOSClassificationCatalogPage()
                .environmentObject(store)
        }
    }
}

struct IOSClassificationCatalogPage: View {
    @EnvironmentObject private var store: IOSStore
    @Environment(\.dismiss) private var dismiss
    @State private var editor: ClassificationEditorMode?
    @State private var searchText = ""
    @State private var showsArchived = false
    @State private var pendingMergeSource: ClassificationMergeSource?
    @State private var pendingAlert: ClassificationAlert?

    private enum ClassificationEditorMode: Identifiable {
        case createCategory
        case createLabel
        case edit(ClassificationCatalogItemProjection, isCategory: Bool)

        var id: String {
            switch self {
            case .createCategory: "create-category"
            case .createLabel: "create-label"
            case let .edit(item, isCategory): "edit-\(isCategory)-\(item.id)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let catalog = store.classificationCatalog {
                    Section("分类") {
                        ForEach(items(catalog.categories, includeArchived: false)) { item in
                            catalogRow(item, isCategory: true)
                        }
                    }
                    if showsArchived {
                        Section("已归档分类") {
                            ForEach(items(catalog.categories, includeArchived: true).filter {
                                $0.lifecycle == .archived
                            }) { item in
                                catalogRow(item, isCategory: true)
                            }
                        }
                    }
                    Section("标签") {
                        ForEach(items(catalog.labels, includeArchived: false)) { item in
                            catalogRow(item, isCategory: false)
                        }
                    }
                    if showsArchived {
                        Section("已归档标签") {
                            ForEach(items(catalog.labels, includeArchived: true).filter {
                                $0.lifecycle == .archived
                            }) { item in
                                catalogRow(item, isCategory: false)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索分类与标签")
            .navigationTitle("分类目录")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("新建分类") { editor = .createCategory }
                            .accessibilityIdentifier("ios.classification.catalog.create-category")
                        Button("新建标签") { editor = .createLabel }
                            .accessibilityIdentifier("ios.classification.catalog.create-label")
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("ios.classification.catalog.add")
                }
                ToolbarItem(placement: .automatic) {
                    Button(showsArchived ? "隐藏已归档" : "显示已归档") {
                        showsArchived.toggle()
                    }
                    .accessibilityIdentifier("ios.classification.catalog.archived-toggle")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editor) { mode in
                switch mode {
                case .createCategory:
                    IOSClassificationItemEditor(isCategory: true)
                        .environmentObject(store)
                case .createLabel:
                    IOSClassificationItemEditor(isCategory: false)
                        .environmentObject(store)
                case let .edit(item, isCategory):
                    IOSClassificationItemEditor(item: item, isCategory: isCategory)
                        .environmentObject(store)
                }
            }
            .confirmationDialog(
                "选择合并目标",
                isPresented: Binding(
                    get: { pendingMergeSource != nil },
                    set: {
                        if $0 == false {
                            pendingMergeSource = nil
                        }
                    }
                ),
                presenting: pendingMergeSource
            ) { source in
                ForEach(mergeTargets(for: source)) { target in
                    Button(target.name) {
                        prepareMerge(source: source, target: target)
                    }
                }
                Button("取消", role: .cancel) { pendingMergeSource = nil }
            } message: { source in
                Text("将“\(source.item.name)”合并到一个仍在使用的项目；当前和历史引用会保留并指向目标。")
            }
            .alert(item: $pendingAlert) { alert in
                switch alert {
                case let .delete(request):
                    Alert(
                        title: Text(request.isCategory ? "确认删除分类" : "确认删除标签"),
                        message: Text("删除后不会保留可恢复入口；只有没有当前或历史引用的项目才能删除。"),
                        primaryButton: .destructive(Text("删除")) {
                            if request.isCategory {
                                store.hardDeleteCategory(id: request.item.id)
                            } else {
                                store.hardDeleteLabel(id: request.item.id)
                            }
                        },
                        secondaryButton: .cancel()
                    )
                case let .merge(request):
                    Alert(
                        title: Text("确认合并"),
                        message: Text(
                            "将迁移当前引用 \(request.impact.migratedRelationCount) 项，去重 \(request.impact.deduplicatedRelationCount) 项；历史轨迹不会被删除。"
                        ),
                        primaryButton: .destructive(Text("确认合并")) {
                            store.mergeClassification(
                                sourceID: request.source.id,
                                targetID: request.target.id,
                                isCategory: request.isCategory
                            )
                        },
                        secondaryButton: .cancel()
                    )
                }
            }
        }
    }

    private func items(
        _ source: [ClassificationCatalogItemProjection],
        includeArchived: Bool
    ) -> [ClassificationCatalogItemProjection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return source
            .filter { $0.mergedIntoID == nil }
            .filter { includeArchived ? $0.lifecycle == .active || $0.lifecycle == .archived : $0.lifecycle == .active }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func catalogRow(
        _ item: ClassificationCatalogItemProjection,
        isCategory: Bool
    ) -> some View {
        HStack {
            Circle()
                .fill(Color(hex: item.colorHex))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(item.name)
                Text(item.lifecycle.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("当前 \(item.currentUsageCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("编辑") {
                editor = .edit(item, isCategory: isCategory)
            }
            if isCategory, item.lifecycle == .active {
                Button("从今日移除", role: .destructive) {
                    store.deleteCategoryFromToday(id: item.id)
                }
                .tint(.red)
            }
            if item.lifecycle == .active {
                Button("归档") {
                    if isCategory {
                        store.archiveCategory(id: item.id)
                    } else {
                        store.archiveLabel(id: item.id)
                    }
                }
                .tint(.orange)
                .accessibilityIdentifier("ios.classification.archive.\(item.id)")
            } else if item.lifecycle == .archived {
                Button("恢复") {
                    if isCategory {
                        store.restoreCategory(id: item.id)
                    } else {
                        store.restoreLabel(id: item.id)
                    }
                }
                .tint(.green)
                .accessibilityIdentifier("ios.classification.restore.\(item.id)")
            }
            if item.currentUsageCount == 0, item.historicalUsageCount == 0 {
                Button("删除", role: .destructive) {
                    pendingAlert = .delete(ClassificationDeleteRequest(
                        item: item,
                        isCategory: isCategory
                    ))
                }
                .accessibilityIdentifier("ios.classification.hard-delete.\(item.id)")
            }
            if mergeTargets(for: ClassificationMergeSource(item: item, isCategory: isCategory)).isEmpty == false {
                Button("合并") {
                    pendingMergeSource = ClassificationMergeSource(
                        item: item,
                        isCategory: isCategory
                    )
                }
                .tint(.purple)
            }
            if isCategory, item.presentationApproval == .pendingAIReview,
               item.lifecycle == .active
            {
                Button("批准展示") {
                    store.approveCategoryPresentation(id: item.id)
                }
                .tint(.blue)
            }
        }
    }

    private func mergeTargets(
        for source: ClassificationMergeSource
    ) -> [ClassificationCatalogItemProjection] {
        guard let catalog = store.classificationCatalog else { return [] }
        let candidates = source.isCategory ? catalog.categories : catalog.labels
        return candidates.filter {
            $0.id != source.item.id
                && $0.mergedIntoID == nil
                && $0.lifecycle == .active
        }
    }

    private func prepareMerge(
        source: ClassificationMergeSource,
        target: ClassificationCatalogItemProjection
    ) {
        pendingMergeSource = nil
        guard let impact = store.classificationMergeImpact(
            sourceID: source.item.id,
            targetID: target.id,
            isCategory: source.isCategory
        ) else {
            return
        }
        pendingAlert = .merge(ClassificationMergeRequest(
            source: source.item,
            target: target,
            isCategory: source.isCategory,
            impact: impact
        ))
    }
}

private struct ClassificationDeleteRequest: Identifiable {
    let item: ClassificationCatalogItemProjection
    let isCategory: Bool

    var id: String { "\(isCategory)-\(item.id)" }
}

private struct ClassificationMergeSource: Identifiable {
    let item: ClassificationCatalogItemProjection
    let isCategory: Bool

    var id: String { "\(isCategory)-\(item.id)" }
}

private struct ClassificationMergeRequest: Identifiable {
    let source: ClassificationCatalogItemProjection
    let target: ClassificationCatalogItemProjection
    let isCategory: Bool
    let impact: ClassificationMergeImpact

    var id: String { "\(isCategory)-\(source.id)-\(target.id)" }
}

private enum ClassificationAlert: Identifiable {
    case delete(ClassificationDeleteRequest)
    case merge(ClassificationMergeRequest)

    var id: String {
        switch self {
        case let .delete(request): "delete-\(request.id)"
        case let .merge(request): "merge-\(request.id)"
        }
    }
}

struct IOSClassificationItemEditor: View {
    @EnvironmentObject private var store: IOSStore
    @Environment(\.dismiss) private var dismiss
    let item: ClassificationCatalogItemProjection?
    let isCategory: Bool
    @State private var name = ""
    @State private var colorHex = "#4F46E5"

    init(item: ClassificationCatalogItemProjection? = nil, isCategory: Bool) {
        self.item = item
        self.isCategory = isCategory
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(isCategory ? "分类名称" : "标签名称", text: $name)
                    .accessibilityIdentifier("ios.classification.editor.name")
                if item == nil {
                    TextField("颜色 Hex", text: $colorHex)
                        .textInputAutocapitalization(.characters)
                }
            }
            .navigationTitle(item == nil ? (isCategory ? "新建分类" : "新建标签") : "重命名")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .accessibilityIdentifier("ios.classification.editor.save")
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                name = item?.name ?? ""
                colorHex = item?.colorHex ?? "#4F46E5"
            }
        }
    }

    private func save() {
        if let item {
            if isCategory {
                store.renameCategory(id: item.id, name: name)
            } else {
                store.renameLabel(id: item.id, name: name)
            }
        } else if isCategory {
            store.createCategory(name: name, colorHex: colorHex)
        } else {
            store.createLabel(name: name, colorHex: colorHex)
        }
        dismiss()
    }
}

private extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}
