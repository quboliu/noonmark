import AppKit
import Foundation
import NoonmarkCore

@MainActor
struct SubtaskLayoutE2EAutomation: LaunchAutomationRunnable {
    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): message
            }
        }
    }

    private let resultURL: URL
    private let screenshotURL: URL

    static func fromCommandLine() -> Self? {
        guard let resultPath = AppLaunchArguments.value(
            after: "--e2e-subtask-layout-result-url"
        ), let screenshotPath = AppLaunchArguments.value(
            after: "--e2e-subtask-layout-screenshot-url"
        ) else {
            return nil
        }
        return Self(
            resultURL: URL(fileURLWithPath: resultPath),
            screenshotURL: URL(fileURLWithPath: screenshotPath)
        )
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
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
                try captureMainWindow(to: screenshotURL)

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

                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? captureMainWindow(to: screenshotURL)
                try? writeResult("failed: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
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
              let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            throw Failure.failed("无法取得真实 App 主窗口截图缓冲区")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.failed("无法编码真实 App 主窗口截图")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func writeResult(_ value: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try value.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}
