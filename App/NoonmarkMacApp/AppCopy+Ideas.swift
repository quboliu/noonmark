extension AppCopy {
    // MARK: - Flylight

    var navIdeas: String { language == .chinese ? "飞光" : "Flylight" }

    var navStickyNotes: String { "Sticky Note" }

    var stickyNotesSubtitle: String {
        language == .chinese
            ? "把值得反复看见的飞光留在这里。"
            : "Keep the Flylights worth seeing again close at hand."
    }

    var stickyNotesEmptyState: String {
        language == .chinese
            ? "还没有 Sticky Note。请从飞光中挑选值得常看的条目。"
            : "No Sticky Notes yet. Choose something worth revisiting from Flylight."
    }

    var stickyNoteStreamMode: String {
        language == .chinese ? "清单流" : "Stream"
    }

    var stickyNoteWallMode: String {
        language == .chinese ? "便签墙" : "Note wall"
    }

    var stickyNotePresentationMode: String {
        language == .chinese ? "展示视图" : "Presentation"
    }

    var openInFlylightAction: String {
        language == .chinese ? "在飞光中打开" : "Open in Flylight"
    }

    var ideasSubtitle: String {
        language == .chinese
            ? "先记下来，再决定它要去哪里。"
            : "Capture it first, then decide where it belongs."
    }

    var ideaComposerPlaceholder: String {
        language == .chinese
            ? "记录一条飞光，支持 Markdown、#标签与 @分组；⌘回车保存，草稿自动保留"
            : "Capture a Flylight with Markdown, #labels, or @group; ⌘Return saves and drafts persist"
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
        language == .chinese ? "飞光详情" : "Flylight details"
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
        language == .chinese ? "选择一条飞光查看详情。" : "Select a Flylight to inspect it."
    }

    var ideaEmptyState: String {
        language == .chinese
            ? "还没有飞光。把第一条记录写在上面的速记框里。"
            : "No Flylights yet. Capture the first one above."
    }

    var ideaFilterEmptyState: String {
        language == .chinese
            ? "没有匹配这个飞光过滤词的内容。"
            : "No Flylights match this filter."
    }

    var ideaReviewEmptyState: String {
        language == .chinese
            ? "暂时没有一周以前的飞光可回看。"
            : "No Flylights older than one week are ready to review."
    }

    var ideaMultipleCategories: String {
        language == .chinese
            ? "每条飞光只能有一个分组，请只保留一个 @分组。"
            : "A Flylight can have only one group. Keep a single @group."
    }

    func ideaUnresolvedClassification(_ names: [String]) -> String {
        let joined = names.joined(separator: "、")
        return language == .chinese
            ? "找不到分组或标签：\(joined)。请从候选中选择已有的分组或标签。"
            : "Unknown group or label: \(names.joined(separator: ", ")). Pick an existing one from the suggestions."
    }

    var addIdeaAction: String {
        language == .chinese ? "记录飞光" : "Capture Flylight"
    }

    var ideaPublishAction: String {
        language == .chinese ? "发布" : "Publish"
    }

    var ideaCollapseComposerAction: String {
        language == .chinese ? "收起" : "Collapse"
    }

    var ideaExpandComposerAction: String {
        language == .chinese ? "展开" : "Expand"
    }

    var ideaContinueLaterAction: String {
        language == .chinese ? "稍后继续" : "Continue later"
    }

    var ideaDraftRetainedStatus: String {
        language == .chinese ? "草稿已保留" : "Draft retained"
    }

    var ideaDirtyPublishStatus: String {
        language == .chinese ? "⌘↩ 发布" : "⌘↩ Publish"
    }

    var ideaDirtyEditStatus: String {
        language == .chinese ? "⌘↩ 保存" : "⌘↩ Save"
    }

    var ideaSavingLocallyStatus: String {
        language == .chinese ? "正在写入本机" : "Saving locally"
    }

    var ideaPublishSucceededStatus: String {
        language == .chinese ? "✓ 已记录" : "✓ Captured"
    }

    var ideaEditSucceededStatus: String {
        language == .chinese ? "✓ 已保存" : "✓ Saved"
    }

    var ideaRetryAction: String {
        language == .chinese ? "重试" : "Retry"
    }

    var ideaPublishingStatus: String {
        language == .chinese ? "发布中" : "Publishing"
    }

    var ideaSavingEditStatus: String {
        language == .chinese ? "保存中" : "Saving"
    }

    var ideaPublishFailed: String {
        language == .chinese
            ? "发布失败，草稿仍在这里，请重试。"
            : "Publish failed. Your draft is still here; try again."
    }

    var ideaLabelTool: String {
        language == .chinese ? "插入标签" : "Insert label"
    }

    var ideaCategoryTool: String {
        language == .chinese ? "插入分组" : "Insert group"
    }

    var ideaFormattingTool: String {
        language == .chinese ? "Markdown 格式" : "Markdown formatting"
    }

    var ideaFormatBold: String { language == .chinese ? "加粗" : "Bold" }

    var ideaFormatItalic: String { language == .chinese ? "斜体" : "Italic" }

    var ideaFormatLink: String { language == .chinese ? "链接" : "Link" }

    var ideaFormatInlineCode: String {
        language == .chinese ? "行内代码" : "Inline code"
    }

    func ideaFormatHeading(_ level: Int) -> String {
        language == .chinese ? "\(level) 级标题" : "Heading \(level)"
    }

    var ideaFormatUnorderedList: String {
        language == .chinese ? "无序列表" : "Bulleted list"
    }

    var ideaFormatOrderedList: String {
        language == .chinese ? "有序列表" : "Numbered list"
    }

    var ideaFormatTaskList: String {
        language == .chinese ? "任务列表" : "Task list"
    }

    var ideaFormatQuote: String { language == .chinese ? "引用" : "Quote" }

    var ideaFormatCodeBlock: String {
        language == .chinese ? "代码块" : "Code block"
    }

    var editIdeaAction: String {
        language == .chinese ? "编辑飞光" : "Edit Flylight"
    }

    var deleteIdeaAction: String {
        language == .chinese ? "删除飞光" : "Delete Flylight"
    }

    var ideaActionsAccessibilityLabel: String {
        language == .chinese ? "飞光操作" : "Flylight actions"
    }

    var ideaEditPlaceholder: String {
        language == .chinese
            ? "用 Markdown 编辑飞光；⌘回车保存，Esc 取消"
            : "Edit the Flylight in Markdown; ⌘Return saves, Esc cancels"
    }

    var ideaSaveEditAction: String {
        language == .chinese ? "保存修改" : "Save changes"
    }

    var ideaCancelEditAction: String {
        language == .chinese ? "取消" : "Cancel"
    }

    var ideaDeletedToast: String {
        language == .chinese ? "已删除飞光" : "Flylight deleted"
    }

    var ideaEditSaveFailed: String {
        language == .chinese
            ? "保存失败，修改仍保留在这里，请重试。"
            : "Save failed. Your edit is still here; try again."
    }

    var ideaContentRequired: String {
        language == .chinese
            ? "飞光内容不能为空，修改仍保留在这里。"
            : "Flylight content cannot be empty. Your edit is still here."
    }

    // MARK: - Sticky Note projection

    var addToStickyNotesAction: String {
        language == .chinese ? "加入 Sticky Note" : "Add to Sticky Note"
    }

    var removeFromStickyNotesAction: String {
        language == .chinese ? "从 Sticky Note 移除" : "Remove from Sticky Note"
    }

    var addedToStickyNotesToast: String {
        language == .chinese ? "已加入 Sticky Note" : "Added to Sticky Note"
    }

    var removedFromStickyNotesToast: String {
        language == .chinese ? "已从 Sticky Note 移除" : "Removed from Sticky Note"
    }

    // MARK: - Flylight Classification Filter

    func ideaClassificationFilterIndicator(_ name: String) -> String {
        language == .chinese
            ? "过滤：\(name)"
            : "Filter: \(name)"
    }

    var clearIdeaClassificationFilterAction: String {
        language == .chinese ? "清除分类过滤" : "Clear classification filter"
    }

    // MARK: - Global Flylight Capture

    var ideaCaptureCommand: String {
        language == .chinese ? "记录飞光…" : "Capture Flylight…"
    }

    var ideaCapturePanelTitle: String {
        language == .chinese ? "飞光速记" : "Flylight Capture"
    }

    var ideaCapturePanelHint: String {
        language == .chinese
            ? "内容会进入「飞光」时间线；支持 Markdown，回车换行，⌘回车保存，Esc 关闭。"
            : "Saved to Flylight with Markdown; Return adds a line, ⌘Return saves, Esc closes."
    }

    var ideaCapturePanelPlaceholder: String {
        language == .chinese
            ? "记录一条飞光，支持 Markdown、#标签与 @分组"
            : "Capture a Flylight with Markdown, #labels, and @group"
    }

    var globalIdeaCaptureShortcutTitle: String {
        language == .chinese
            ? "全局飞光速记"
            : "Global Flylight Capture"
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
