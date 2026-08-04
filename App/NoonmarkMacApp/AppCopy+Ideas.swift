extension AppCopy {
    // MARK: - Ideas（想法记录）

    var navIdeas: String { language == .chinese ? "想法" : "Ideas" }

    var ideasSubtitle: String {
        language == .chinese
            ? "先记下来，再决定它要去哪里。"
            : "Capture it first, then decide where it belongs."
    }

    var ideaComposerPlaceholder: String {
        language == .chinese
            ? "记录一个想法，可用 #标签、@分组，⌘回车保存；草稿自动保留"
            : "Capture an idea; use #labels or @group, ⌘Return to save; drafts persist"
    }

    var ideaFilterPlaceholder: String {
        language == .chinese ? "搜索正文或标签…" : "Search text or labels…"
    }

    var ideaSearchAction: String {
        language == .chinese ? "搜索" : "Search"
    }

    var ideaReviewAction: String {
        language == .chinese ? "回看" : "Review"
    }

    func ideaRecentContext(_ count: Int) -> String {
        language == .chinese ? "最近 · \(count)" : "Recent · \(count)"
    }

    func ideaReviewContext(_ count: Int) -> String {
        language == .chinese
            ? "回看 · 来自一周以前 · \(count)"
            : "Review · older than one week · \(count)"
    }

    var ideaReviewRefreshAction: String {
        language == .chinese ? "换一组" : "Refresh"
    }

    var ideaInspectorTitle: String {
        language == .chinese ? "想法详情" : "Idea details"
    }

    var ideaInspectorRecordedAt: String {
        language == .chinese ? "记录时间" : "Captured"
    }

    var ideaInspectorClassification: String {
        language == .chinese ? "分类" : "Classification"
    }

    var ideaInspectorActions: String {
        language == .chinese ? "操作" : "Actions"
    }

    var ideaInspectorEmptyState: String {
        language == .chinese ? "选择一条想法查看详情。" : "Select an idea to inspect it."
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

    var ideaReviewEmptyState: String {
        language == .chinese
            ? "暂时没有一周以前的想法可回看。"
            : "No ideas older than one week are ready to review."
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

    var ideaEditSaveFailed: String {
        language == .chinese
            ? "保存失败，修改仍保留在这里，请重试。"
            : "Save failed. Your edit is still here; try again."
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
            ? "想法会进入「想法」时间线；回车换行，⌘回车保存，Esc 关闭。"
            : "Saved to Ideas. Return adds a line, ⌘Return saves, Esc closes."
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
