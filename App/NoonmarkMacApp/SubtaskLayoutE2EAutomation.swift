import AppKit
import Foundation
import NoonmarkCore

@MainActor
struct SubtaskLayoutE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case exercise(
            poolScreenshotURL: URL,
            inlineEditScreenshotURL: URL
        )
        case verifyRestart
    }

    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): message
            }
        }
    }

    private static let editedTitle = "测试主列表展开子任务可编辑"

    private let resultURL: URL
    private let mode: Mode

    static func fromCommandLine() -> Self? {
        guard let resultPath = AppLaunchArguments.value(
            after: "--e2e-subtask-layout-result-url"
        ) else {
            return nil
        }
        if AppLaunchArguments.contains(
            "--e2e-subtask-layout-restart-verify"
        ) {
            return Self(
                resultURL: URL(fileURLWithPath: resultPath),
                mode: .verifyRestart
            )
        }
        guard let poolScreenshotPath = AppLaunchArguments.value(
            after: "--e2e-subtask-layout-screenshot-url"
        ), let inlineEditScreenshotPath = AppLaunchArguments.value(
            after: "--e2e-subtask-inline-edit-screenshot-url"
        ) else {
            return nil
        }
        return Self(
            resultURL: URL(fileURLWithPath: resultPath),
            mode: .exercise(
                poolScreenshotURL: URL(
                    fileURLWithPath: poolScreenshotPath
                ),
                inlineEditScreenshotURL: URL(
                    fileURLWithPath: inlineEditScreenshotPath
                )
            )
        )
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                switch mode {
                case let .exercise(
                    poolScreenshotURL,
                    inlineEditScreenshotURL
                ):
                    try await exercise(
                        on: store,
                        poolScreenshotURL: poolScreenshotURL,
                        inlineEditScreenshotURL: inlineEditScreenshotURL
                    )
                case .verifyRestart:
                    try await verifyRestart(on: store)
                }
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                if case let .exercise(_, inlineEditScreenshotURL) = mode {
                    try? captureMainWindow(to: inlineEditScreenshotURL)
                }
                try? writeResult("failed: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }

    private func exercise(
        on store: NoonmarkStore,
        poolScreenshotURL: URL,
        inlineEditScreenshotURL: URL
    ) async throws {
        let chainID = try preparePoolFixture(on: store)
        let plannedIDs = try plannedSubtaskIDs(
            chainID: chainID,
            store: store
        )
        try await verifyLayout(
            namespace: "pool",
            itemIDs: plannedIDs.map(\.description),
            newEditorIdentifier: "pool.subtask.\(chainID.description).new"
        )
        try captureMainWindow(to: poolScreenshotURL)

        store.schedulePoolTask(chainID, date: store.today)
        guard let traceID = store.selectedTraceID else {
            throw Failure.failed("计划子任务排期后没有选中 Day Todo 轨迹")
        }
        let subtaskIDs = store.subtasks(for: traceID).map(\.id.description)
        try await verifyLayout(
            namespace: "day",
            itemIDs: subtaskIDs,
            newEditorIdentifier: "day.subtask.\(traceID.description).new"
        )
        store.expandedTraceIDs.insert(traceID)
        try await verifyInlineEditing(
            subtaskID: try firstSubtaskID(
                traceID: traceID,
                store: store
            ),
            store: store
        )
        try captureMainWindow(to: inlineEditScreenshotURL)
    }

    private func verifyRestart(on store: NoonmarkStore) async throws {
        let matches = store.engine.subtasks.values.filter {
            $0.title == Self.editedTitle
        }
        guard matches.count == 1, let subtask = matches.first,
              let trace = store.engine.traces[subtask.traceID]
        else {
            throw Failure.failed(
                "重启后没有唯一回读已编辑子任务：\(matches.count)"
            )
        }

        store.page = .day
        store.selectedDate = trace.date
        store.selectedCalendarDate = trace.date
        store.isDetailRailExpanded = true
        store.selectTrace(trace.id)
        store.expandedTraceIDs.insert(trace.id)

        let listInputIdentifier =
            "day-list.subtask.\(subtask.id.description).title.input"
        let detailInputIdentifier =
            "day.subtask.\(subtask.id.description).title.input"
        try await waitUntil("重启后主列表与详情栏没有同时回读子任务标题") {
            guard let listEditor = AppViewTreeE2E.view(
                identifier: listInputIdentifier
            ) as? NSTextView,
                let detailEditor = AppViewTreeE2E.view(
                    identifier: detailInputIdentifier
                ) as? NSTextView
            else {
                return false
            }
            return listEditor.string == Self.editedTitle
                && detailEditor.string == Self.editedTitle
                && store.engine.subtasks[subtask.id]?.title == Self.editedTitle
        }
    }

    private func preparePoolFixture(
        on store: NoonmarkStore
    ) throws -> TaskChainID {
        store.page = .pool
        store.clearSelection()
        store.isDetailRailExpanded = true
        store.poolText = "E2E 多行子任务布局"
        store.addPoolTask()
        guard let chainID = store.selectedPoolChainID else {
            throw Failure.failed("无法建立任务池布局 fixture")
        }

        let titles = [
            "索引与排序（ORDER BY、NULLS 处理）需要验证多行布局",
            "联合查询、子查询中的索引使用需要验证多行布局",
            "使用 EXPLAIN／ANALYZE 判断索引失效并记录结论"
        ]
        for title in titles {
            store.detailSubtaskText = title
            store.addPoolPlannedSubtask(chainID: chainID)
        }
        store.selectPool(chainID)
        return chainID
    }

    private func plannedSubtaskIDs(
        chainID: TaskChainID,
        store: NoonmarkStore
    ) throws -> [PlannedSubtaskID] {
        guard let task = store.engine.taskPool().first(where: {
            $0.chain.id == chainID
        }) else {
            throw Failure.failed("任务池布局 fixture 不在任务池")
        }
        let ids = task.definition.plannedSubtasks
            .sorted { $0.position < $1.position }
            .map(\.id)
        guard ids.count == 3 else {
            throw Failure.failed("任务池布局 fixture 子任务数量错误：\(ids.count)")
        }
        return ids
    }

    private func firstSubtaskID(
        traceID: DayTraceID,
        store: NoonmarkStore
    ) throws -> SubtaskID {
        guard let subtaskID = store.subtasks(for: traceID).first?.id else {
            throw Failure.failed("Day Todo 主列表缺少可编辑子任务")
        }
        return subtaskID
    }

    private func verifyInlineEditing(
        subtaskID: SubtaskID,
        store: NoonmarkStore
    ) async throws {
        let surfaceIdentifier =
            "day-list.subtask.\(subtaskID.description).title"
        let inputIdentifier = "\(surfaceIdentifier).input"
        var surface: NSView?
        var editor: NSTextView?

        try await waitUntil("Day Todo 主列表展开后没有形成子任务编辑器") {
            surface = AppViewTreeE2E.view(identifier: surfaceIdentifier)
            editor = AppViewTreeE2E.view(
                identifier: inputIdentifier
            ) as? NSTextView
            return surface != nil && editor != nil
        }
        guard let surface, let editor, let window = surface.window else {
            throw Failure.failed("Day Todo 主列表子任务编辑器在点击前消失")
        }
        let input = try WindowServerInputDriver()
        guard AppViewTreeE2E.activateMainWindow() else {
            throw Failure.failed("Day Todo 主列表子任务编辑时主窗口无法激活")
        }
        let resolveTarget = { () throws -> WindowServerInputDriver.PointerCoordinate in
            guard surface.window === window,
                  surface.isHiddenOrHasHiddenAncestor == false
            else {
                throw Failure.failed("Day Todo 主列表子任务点击目标发生变化")
            }
            let point = surface.convert(
                NSPoint(x: surface.bounds.midX, y: surface.bounds.midY),
                to: nil
            )
            return try input.pointerCoordinate(windowPoint: point, in: window)
        }
        try await input.postClick(
            at: try resolveTarget(),
            modifiers: [],
            resolveTarget: resolveTarget
        )
        try await waitUntil(
            "Day Todo 主列表子任务点击后没有获得输入焦点；"
                + "firstResponder=\(String(describing: window.firstResponder))"
        ) {
            window.firstResponder === editor
        }
        try input.postKey(keyCode: 0, modifiers: .command)
        try input.typeUnicode(Self.editedTitle)
        do {
            try await waitUntil("Day Todo 主列表子任务接收键入后没有更新领域模型") {
                guard let listEditor = AppViewTreeE2E.view(
                    identifier: inputIdentifier
                ) as? NSTextView,
                    let detailEditor = AppViewTreeE2E.view(
                        identifier:
                        "day.subtask.\(subtaskID.description).title.input"
                    ) as? NSTextView
                else {
                    return false
                }
                return listEditor.string == Self.editedTitle
                    && detailEditor.string == Self.editedTitle
                    && store.engine.subtasks[subtaskID]?.title
                    == Self.editedTitle
            }
        } catch {
            let listEditorState = (
                AppViewTreeE2E.view(
                    identifier: inputIdentifier
                ) as? NSTextView
            )?.string ?? "nil"
            let detailEditorState = (
                AppViewTreeE2E.view(
                    identifier:
                    "day.subtask.\(subtaskID.description).title.input"
                ) as? NSTextView
            )?.string ?? "nil"
            throw Failure.failed(
                "Day Todo 主列表子任务连续输入失败：target=\(editor.string)，"
                    + "list=\(listEditorState)，detail=\(detailEditorState)，model="
                    + "\(store.engine.subtasks[subtaskID]?.title ?? "nil")，"
                    + "focused=\(window.firstResponder === editor)"
            )
        }
    }

    private func verifyLayout(
        namespace: String,
        itemIDs: [String],
        newEditorIdentifier: String
    ) async throws {
        guard itemIDs.count == 3 else {
            throw Failure.failed("\(namespace) 子任务数量错误：\(itemIDs.count)")
        }
        try await waitUntil("\(namespace) 子任务详情没有出现") {
            itemIDs.allSatisfy { id in
                AppViewTreeE2E.view(
                    identifier: "\(namespace).subtask.\(id).row"
                ) != nil
                    && AppViewTreeE2E.view(
                        identifier: "\(namespace).subtask.\(id).title.input"
                    ) != nil
            }
                && AppViewTreeE2E.view(
                    identifier: newEditorIdentifier
                ) != nil
        }

        var rowFrames: [NSRect] = []
        for id in itemIDs {
            let prefix = "\(namespace).subtask.\(id)"
            guard let row = AppViewTreeE2E.view(
                identifier: "\(prefix).row"
            ), let textView = AppViewTreeE2E.view(
                identifier: "\(prefix).title.input"
            ) as? NSTextView,
                let textContainer = textView.textContainer,
                let layoutManager = textView.layoutManager,
                let scrollView = textView.enclosingScrollView
            else {
                throw Failure.failed("\(prefix) 缺少真实文本布局容器")
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedTextHeight = ceil(
                layoutManager.usedRect(for: textContainer).height
                    + textView.textContainerInset.height * 2
            )
            let rowFrame = AppViewTreeE2E.frameInWindow(for: row)
            let editorFrame = AppViewTreeE2E.frameInWindow(for: scrollView)
            guard usedTextHeight > 28 else {
                throw Failure.failed(
                    "\(prefix) fixture 没有形成多行：used=\(usedTextHeight)"
                )
            }
            guard editorFrame.height + 1 >= usedTextHeight else {
                throw Failure.failed(
                    "\(prefix) 编辑器高度不足："
                        + "editor=\(editorFrame.height), used=\(usedTextHeight)"
                )
            }
            guard rowFrame.height + 1 >= editorFrame.height else {
                throw Failure.failed(
                    "\(prefix) 行高没有承接编辑器："
                        + "row=\(rowFrame.height), editor=\(editorFrame.height)"
                )
            }
            rowFrames.append(rowFrame)
        }

        guard let newEditor = AppViewTreeE2E.view(
            identifier: newEditorIdentifier
        ) else {
            throw Failure.failed("\(namespace) 缺少新增子任务输入框")
        }
        let newEditorFrame = AppViewTreeE2E.frameInWindow(for: newEditor)
        let allFrames = rowFrames + [newEditorFrame]
        for leftIndex in allFrames.indices {
            for rightIndex in allFrames.indices where rightIndex > leftIndex {
                let intersection = allFrames[leftIndex]
                    .intersection(allFrames[rightIndex])
                guard intersection.isNull || intersection.height <= 0.5 else {
                    throw Failure.failed(
                        "\(namespace) 子任务控件相交："
                            + "\(allFrames[leftIndex]) 与 \(allFrames[rightIndex])"
                    )
                }
            }
        }
    }

    private func waitUntil(
        _ failureMessage: String,
        attempts: Int = 160,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw Failure.failed(failureMessage)
    }

    private func captureMainWindow(to url: URL) throws {
        guard let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }),
              let view = window.contentView
        else {
            throw Failure.failed("无法取得真实 App 主窗口截图内容")
        }
        do {
            try AppE2EScreenshot.capture(view, to: url)
        } catch {
            throw Failure.failed(
                "无法捕获真实 App 主窗口截图：\(error.localizedDescription)"
            )
        }
    }

    private func writeResult(_ value: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try value.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}
