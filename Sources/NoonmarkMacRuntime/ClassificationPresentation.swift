import NoonmarkCore

public struct ClassificationManagerCopy: Equatable, Sendable {
    private let language: AppLanguage

    init(language: AppLanguage) {
        self.language = language
    }

    public var title: String {
        localized("分组与标签管理", "Manage Groups & Tags")
    }

    public var subtitle: String {
        localized(
            "维护当前分组与标签，不改写任务的历史快照",
            "Maintain current groups and tags without rewriting historical snapshots"
        )
    }

    public var kindPickerTitle: String {
        localized("类型", "Classification type")
    }

    public func kindTitle(_ metric: GroupManagementMetric, count: Int) -> String {
        switch (language, metric) {
        case (.chinese, .category): "分组  \(count)"
        case (.chinese, .label): "标签  \(count)"
        case (.english, .category): "Groups  \(count)"
        case (.english, .label): "Tags  \(count)"
        }
    }

    public var closeAccessibilityLabel: String {
        localized("关闭分组与标签管理", "Close group and tag management")
    }

    public func metricTitle(_ metric: GroupManagementMetric) -> String {
        switch (language, metric) {
        case (.chinese, .category): "分组"
        case (.chinese, .label): "标签"
        case (.english, .category): "Groups"
        case (.english, .label): "Tags"
        }
    }

    public func selectedMetricVerification(_ metric: GroupManagementMetric) -> String {
        switch (language, metric) {
        case (.chinese, .category): "已选择分组"
        case (.chinese, .label): "已选择标签"
        case (.english, .category): "Groups selected"
        case (.english, .label): "Tags selected"
        }
    }

    public func searchPlaceholder(_ metric: GroupManagementMetric) -> String {
        switch (language, metric) {
        case (.chinese, .category): "搜索分组"
        case (.chinese, .label): "搜索标签"
        case (.english, .category): "Search groups"
        case (.english, .label): "Search tags"
        }
    }

    public var clearSearchAccessibilityLabel: String {
        localized("清除搜索", "Clear search")
    }

    public func newItemAction(_ metric: GroupManagementMetric) -> String {
        switch (language, metric) {
        case (.chinese, .category): "新建分组"
        case (.chinese, .label): "新建标签"
        case (.english, .category): "New group"
        case (.english, .label): "New tag"
        }
    }

    public func namePlaceholder(_ metric: GroupManagementMetric) -> String {
        switch (language, metric) {
        case (.chinese, .category): "分组名称"
        case (.chinese, .label): "标签名称"
        case (.english, .category): "Group name"
        case (.english, .label): "Tag name"
        }
    }

    public var createAction: String { localized("创建", "Create") }
    public var colorTitle: String { localized("颜色", "Color") }

    public func chooseColorAccessibilityLabel(_ color: String) -> String {
        localized("选择颜色 \(color)", "Choose color \(color)")
    }

    public func usageRule(_ metric: GroupManagementMetric) -> String {
        switch (language, metric) {
        case (.chinese, .category): "任务至多使用一个分组"
        case (.chinese, .label): "任务可使用多个标签"
        case (.english, .category): "A task can use one group"
        case (.english, .label): "A task can use multiple tags"
        }
    }

    public var activeSectionTitle: String { localized("使用中", "Active") }

    public func emptyActiveMessage(
        _ metric: GroupManagementMetric,
        isSearching: Bool
    ) -> String {
        switch (language, metric, isSearching) {
        case (.chinese, _, false): "还没有使用中的项目"
        case (.chinese, _, true): "没有匹配的使用中项目"
        case (.english, .category, false): "No active groups yet"
        case (.english, .category, true): "No matching active groups"
        case (.english, .label, false): "No active tags yet"
        case (.english, .label, true): "No matching active tags"
        }
    }

    public var archivedSectionTitle: String { localized("已归档", "Archived") }
    public var collapseAction: String { localized("收起", "Collapse") }
    public var expandAction: String { localized("展开", "Expand") }
    public var nameEditorPlaceholder: String { localized("名称", "Name") }
    public var saveAction: String { localized("保存", "Save") }
    public var cancelAction: String { localized("取消", "Cancel") }

    public func currentReferenceCount(_ count: Int) -> String {
        localized("当前 \(count)", "Current \(count)")
    }

    public func historicalReferenceCount(_ count: Int) -> String {
        localized("历史 \(count)", "History \(count)")
    }

    public var renameAction: String { localized("重命名", "Rename") }
    public var approvePresentationAction: String {
        localized("认可并启用颜色", "Approve & Use Color")
    }

    public var archiveAction: String { localized("归档", "Archive") }
    public var restoreAction: String { localized("恢复使用", "Restore") }
    public var deleteGroupAction: String {
        localized("删除分组…", "Delete Group…")
    }

    public func deleteGroupConfirmationTitle(_ name: String) -> String {
        localized("删除分组“\(name)”？", "Delete “\(name)”?")
    }

    public var deleteGroupConfirmationMessage: String {
        localized(
            "今天及未来使用此分组的任务将转为未分组；历史任务仍保留原分组信息。",
            "Tasks using this group today or in the future will become ungrouped. Historical tasks keep the group."
        )
    }

    public var deleteGroupConfirmAction: String {
        localized("删除分组", "Delete Group")
    }

    public var referencedItemsArchiveOnlyNotice: String {
        localized(
            "仍有任务或历史引用，只能归档",
            "Still referenced by tasks or history; archive it instead"
        )
    }

    public var discardAction: String { localized("废弃", "Discard") }

    public var historyNotice: String {
        localized(
            "名称与生命周期可调整；历史引用始终保留。",
            "Names and lifecycle can change; historical references are always preserved."
        )
    }

    private func localized(_ chinese: String, _ english: String) -> String {
        language == .chinese ? chinese : english
    }
}

public struct TaskClassificationEditorCopy: Equatable, Sendable {
    private let language: AppLanguage

    init(language: AppLanguage) {
        self.language = language
    }

    public var categoryTitle: String { localized("分组", "Group") }
    public var labelTitle: String { localized("标签", "Tags") }
    public var groupNamePlaceholder: String { localized("分组名称", "Group name") }
    public var cancelAction: String { localized("取消", "Cancel") }
    public var createAndAddAction: String { localized("创建并加入", "Create & Add") }
    public var noGroupAction: String { localized("不加入分组", "No group") }
    public var newGroupAction: String { localized("新建分组…", "New Group…") }
    public var noGroup: String { localized("无分组", "No group") }
    public var addAction: String { localized("添加", "Add") }
    public var createTagAction: String { localized("新建标签…", "New Tag…") }
    public var allTagsSelected: String {
        localized("所有标签均已选择", "All tags are selected")
    }

    public var tagNamePlaceholder: String {
        localized("输入 # 添加标签", "Type # to add a tag")
    }

    public var emptyGroupNameError: String { localized("请输入分组名称。", "Enter a group name.") }
    public var emptyTagNameError: String { localized("请输入标签名称。", "Enter a tag name.") }

    public func duplicateTagError(_ name: String) -> String {
        localized("标签「\(name)」已经添加。", "The tag “\(name)” is already added.")
    }

    public func createTagFromInput(_ name: String) -> String {
        guard name.isEmpty == false else {
            return localized(
                "输入名称后回车新建标签",
                "Enter a name, then press Return to create a tag"
            )
        }
        return localized(
            "回车新建 #\(name)",
            "Press Return to create #\(name)"
        )
    }

    public func editorAccessibilityLabel(taskTitle: String) -> String {
        localized(
            "任务「\(taskTitle)」的分组与标签编辑器",
            "Group and tag editor for “\(taskTitle)”"
        )
    }

    public func taskGroupAccessibilityLabel(taskTitle: String) -> String {
        localized("任务「\(taskTitle)」的分组", "Group for “\(taskTitle)”")
    }

    public func currentGroupAccessibilityLabel(_ name: String) -> String {
        localized("当前分组：\(name)", "Current group: \(name)")
    }

    public func addTagAccessibilityLabel(taskTitle: String) -> String {
        localized("为任务「\(taskTitle)」添加标签", "Add a tag to “\(taskTitle)”")
    }

    public func savedAccessibilityLabel(taskTitle: String) -> String {
        localized(
            "任务「\(taskTitle)」的分组与标签已保存",
            "Groups and tags for “\(taskTitle)” were saved"
        )
    }

    public func removeTagAccessibilityLabel(
        taskTitle: String,
        tagName: String
    ) -> String {
        localized(
            "从任务「\(taskTitle)」移除标签「\(tagName)」",
            "Remove the tag “\(tagName)” from “\(taskTitle)”"
        )
    }

    public func taskTagAccessibilityLabel(
        taskTitle: String,
        tagName: String
    ) -> String {
        localized(
            "任务「\(taskTitle)」的标签「\(tagName)」",
            "Tag “\(tagName)” on “\(taskTitle)”"
        )
    }

    public func saveFailedAccessibilityLabel(_ message: String) -> String {
        localized("保存失败：\(message)", "Save failed: \(message)")
    }

    private func localized(_ chinese: String, _ english: String) -> String {
        language == .chinese ? chinese : english
    }
}

public struct TaskClassificationBadgesCopy: Equatable, Sendable {
    private let language: AppLanguage

    init(language: AppLanguage) {
        self.language = language
    }

    public var allTagsTitle: String { localized("全部标签", "All Tags") }

    public func containerAccessibilityLabel(
        taskTitle: String,
        isHistorical: Bool
    ) -> String {
        if isHistorical {
            return localized(
                "任务「\(taskTitle)」的当时分组与标签",
                "Historical groups and tags for “\(taskTitle)”"
            )
        }
        return localized(
            "任务「\(taskTitle)」的当前分组与标签",
            "Current groups and tags for “\(taskTitle)”"
        )
    }

    public func taskGroupAccessibilityLabel(
        taskTitle: String,
        groupName: String
    ) -> String {
        localized(
            "任务「\(taskTitle)」的分组「\(groupName)」",
            "Group “\(groupName)” on “\(taskTitle)”"
        )
    }

    public func taskTagAccessibilityLabel(
        taskTitle: String,
        tagName: String
    ) -> String {
        localized(
            "任务「\(taskTitle)」的标签「\(tagName)」",
            "Tag “\(tagName)” on “\(taskTitle)”"
        )
    }

    public func overflowAccessibilityLabel(
        taskTitle: String,
        totalCount: Int,
        hiddenCount: Int
    ) -> String {
        switch language {
        case .chinese:
            return "展开任务「\(taskTitle)」的全部 \(totalCount) 个标签；当前还有 \(hiddenCount) 个未显示"
        case .english:
            let total = totalCount == 1 ? "1 tag" : "\(totalCount) tags"
            let hidden = hiddenCount == 1 ? "1 is" : "\(hiddenCount) are"
            return "Show all \(total) for “\(taskTitle)”; \(hidden) currently hidden"
        }
    }

    public func allTagsAccessibilityLabel(taskTitle: String) -> String {
        localized("任务「\(taskTitle)」的全部标签", "All tags for “\(taskTitle)”")
    }

    private func localized(_ chinese: String, _ english: String) -> String {
        language == .chinese ? chinese : english
    }
}

public extension AppPresentation {
    var classificationManager: ClassificationManagerCopy {
        ClassificationManagerCopy(language: language)
    }

    var taskClassificationEditor: TaskClassificationEditorCopy {
        TaskClassificationEditorCopy(language: language)
    }

    var taskClassificationBadges: TaskClassificationBadgesCopy {
        TaskClassificationBadgesCopy(language: language)
    }
}
