extension AppCopy {
    // MARK: - Ideas（想法记录）

    var navIdeas: String { language == .chinese ? "想法" : "Ideas" }

    var ideasSubtitle: String {
        language == .chinese
            ? "随手记下还没决定去向的灵感，不打断当前工作。"
            : "Capture thoughts before you decide where they go."
    }

    var ideaComposerPlaceholder: String {
        language == .chinese
            ? "记录一个想法，可用 #标签、@分组，⌘回车保存，Esc 清空"
            : "Capture an idea; use #labels, @group, ⌘Return to save, Esc to clear"
    }

    var ideaFilterPlaceholder: String {
        language == .chinese ? "过滤想法…" : "Filter ideas…"
    }

    var ideaEmptyState: String {
        language == .chinese
            ? "还没有想法。把第一个灵感记在上面的速记框里。"
            : "No ideas yet. Capture the first one in the composer above."
    }

    var ideaFilterEmptyState: String {
        language == .chinese
            ? "没有匹配这个想法过滤词的内容。"
            : "No ideas match this filter."
    }

    var ideaMultipleCategories: String {
        language == .chinese
            ? "每条想法只能有一个分组，请只保留一个 @分组。"
            : "An idea can have only one group. Keep a single @group."
    }

    func ideaUnresolvedClassification(_ names: [String]) -> String {
        let joined = names.joined(separator: "、")
        return language == .chinese
            ? "找不到分组或标签：\(joined)。请从候选中选择已有的分组或标签。"
            : "Unknown group or label: \(names.joined(separator: ", ")). Pick an existing one from the suggestions."
    }

    var addIdeaAction: String {
        language == .chinese ? "记录想法" : "Capture idea"
    }

    var editIdeaAction: String {
        language == .chinese ? "编辑想法" : "Edit idea"
    }

    var deleteIdeaAction: String {
        language == .chinese ? "删除想法" : "Delete idea"
    }

    var ideaActionsAccessibilityLabel: String {
        language == .chinese ? "想法操作" : "Idea actions"
    }

    var ideaEditPlaceholder: String {
        language == .chinese
            ? "编辑想法，⌘回车保存，Esc 取消"
            : "Edit the idea; ⌘Return to save, Esc to cancel"
    }

    var ideaSaveEditAction: String {
        language == .chinese ? "保存" : "Save"
    }

    var ideaCancelEditAction: String {
        language == .chinese ? "取消" : "Cancel"
    }

    var ideaDeletedToast: String {
        language == .chinese ? "已删除想法" : "Idea deleted"
    }

    var ideaSavedToast: String {
        language == .chinese ? "已记录想法" : "Idea captured"
    }

    // MARK: - 想法置顶（Pinned Ideas）

    var ideasPinnedSectionTitle: String {
        language == .chinese ? "已置顶" : "Pinned"
    }

    var pinIdeaAction: String {
        language == .chinese ? "置顶想法" : "Pin idea"
    }

    var unpinIdeaAction: String {
        language == .chinese ? "取消置顶" : "Unpin idea"
    }

    var ideaPinnedToast: String {
        language == .chinese ? "已置顶想法" : "Idea pinned"
    }

    var ideaUnpinnedToast: String {
        language == .chinese ? "已取消置顶" : "Idea unpinned"
    }

    // MARK: - 想法回收站（Idea Trash）

    var ideasTrashSectionTitle: String {
        language == .chinese ? "回收站" : "Trash"
    }

    var expandIdeasTrash: String {
        language == .chinese ? "展开回收站" : "Expand trash"
    }

    var collapseIdeasTrash: String {
        language == .chinese ? "收起回收站" : "Collapse trash"
    }

    var ideasTrashEmptyState: String {
        language == .chinese ? "回收站为空。" : "Trash is empty."
    }

    var restoreIdeaAction: String {
        language == .chinese ? "恢复想法" : "Restore idea"
    }

    var ideaRestorePlaceholder: String {
        language == .chinese
            ? "输入恢复后的想法内容，⌘回车恢复，Esc 取消"
            : "Retype the idea to restore; ⌘Return to restore, Esc to cancel"
    }

    var ideaRestoredToast: String {
        language == .chinese ? "已恢复想法" : "Idea restored"
    }

    func ideaTrashDeletionLabel(_ timestamp: String) -> String {
        language == .chinese
            ? "删除于 \(timestamp)"
            : "Deleted \(timestamp)"
    }

    // MARK: - 想法分类过滤（Idea Classification Filter）

    func ideaClassificationFilterIndicator(_ name: String) -> String {
        language == .chinese
            ? "过滤：\(name)"
            : "Filter: \(name)"
    }

    var clearIdeaClassificationFilterAction: String {
        language == .chinese ? "清除分类过滤" : "Clear classification filter"
    }

    // MARK: - 全局想法速记（Global Idea Capture）

    var ideaCaptureCommand: String {
        language == .chinese ? "记录想法…" : "Capture Idea…"
    }

    var ideaCapturePanelTitle: String {
        language == .chinese ? "想法速记" : "Idea Capture"
    }

    var ideaCapturePanelHint: String {
        language == .chinese
            ? "想法会进入「想法」页面时间线；回车保存，Esc 关闭。"
            : "Saved to the Ideas timeline. Return to save, Esc to close."
    }

    var ideaCapturePanelPlaceholder: String {
        language == .chinese
            ? "记录一个想法，可用 #标签、@分组"
            : "Capture an idea; use #labels and @group"
    }

    var globalIdeaCaptureShortcutTitle: String {
        language == .chinese
            ? "全局想法速记"
            : "Global Idea Capture"
    }

    var globalIdeaCaptureShortcutRestoreDefault: String {
        language == .chinese
            ? "恢复默认 ⌃⇧I"
            : "Restore default ⌃⇧I"
    }

    var globalIdeaCaptureShortcutRunningBoundary: String {
        language == .chinese
            ? "晷迹运行时，即使主窗口关闭也可使用；完全退出晷迹后失效。"
            : "Works while Noonmark is running, even with its main window closed. It stops after you quit Noonmark."
    }
}
