import AppKit
import Carbon.HIToolbox
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

    private struct IMEEditingContext {
        let input: WindowServerInputDriver
        let editor: NSTextView
        let inputIdentifier: String
        let subtaskID: SubtaskID
        let initialTitle: String
        let store: NoonmarkStore
    }

    private struct ASCIILatencySample {
        let key: Character
        let totalMilliseconds: Double
        let postMilliseconds: Double
        let echoWaitMilliseconds: Double
        let eventDeliveryMilliseconds: Double
        let eventToKeyDownMilliseconds: Double
        let keyDownMilliseconds: Double
        let superKeyDownMilliseconds: Double
        let nativeSnapshotCallbackMilliseconds: Double
        let eventToObservationMilliseconds: Double
    }

    private static let unicodeEditedTitle = "测试主列表展开子任务可编辑"
    private static let imeEditedTitle = "你好，你好。"

    private let resultURL: URL
    private let mode: Mode
    private let imeInputModeID: String?
    private let asciiLatencyReportURL: URL?

    private var editedTitle: String {
        imeInputModeID == nil
            ? Self.unicodeEditedTitle
            : Self.imeEditedTitle
    }

    static func fromCommandLine() -> Self? {
        guard let resultPath = AppLaunchArguments.value(
            after: "--e2e-subtask-layout-result-url"
        ) else {
            return nil
        }
        let imeInputModeID = AppLaunchArguments.value(
            after: "--e2e-subtask-ime-input-mode"
        )
        let asciiLatencyReportURL = AppLaunchArguments.value(
            after: "--e2e-subtask-ascii-latency-report-url"
        ).map(URL.init(fileURLWithPath:))
        if AppLaunchArguments.contains(
            "--e2e-subtask-layout-restart-verify"
        ) {
            return Self(
                resultURL: URL(fileURLWithPath: resultPath),
                mode: .verifyRestart,
                imeInputModeID: imeInputModeID,
                asciiLatencyReportURL: asciiLatencyReportURL
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
            ),
            imeInputModeID: imeInputModeID,
            asciiLatencyReportURL: asciiLatencyReportURL
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
            newEditorIdentifier: SubtaskRowSurface.dayDetail
                .newEditorIdentifier(for: traceID)
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
            $0.title == editedTitle
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

        let listInputIdentifier = SubtaskRowSurface.dayList
            .titleInputIdentifier(for: subtask.id)
        let detailInputIdentifier = SubtaskRowSurface.dayDetail
            .titleInputIdentifier(for: subtask.id)
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
            return listEditor.string == editedTitle
                && detailEditor.string == editedTitle
                && store.engine.subtasks[subtask.id]?.title == editedTitle
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
        let surfaceIdentifier = SubtaskRowSurface.dayList
            .titleIdentifier(for: subtaskID)
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
        if imeInputModeID == nil {
            try await verifyMarkedTextSurvivesSwiftUIReconciliation(
                editor: editor,
                inputIdentifier: inputIdentifier,
                subtaskID: subtaskID,
                initialTitle: store.engine.subtasks[subtaskID]?.title ?? "",
                store: store
            )
        }
        if let imeInputModeID {
            try await typeWithPhysicalPinyinIME(
                inputModeID: imeInputModeID,
                context: IMEEditingContext(
                    input: input,
                    editor: editor,
                    inputIdentifier: inputIdentifier,
                    subtaskID: subtaskID,
                    initialTitle: store.engine.subtasks[subtaskID]?.title ?? "",
                    store: store
                )
            )
        } else {
            try await verifyResponsiveASCIIEditing(
                context: IMEEditingContext(
                    input: input,
                    editor: editor,
                    inputIdentifier: inputIdentifier,
                    subtaskID: subtaskID,
                    initialTitle: store.engine.subtasks[subtaskID]?.title ?? "",
                    store: store
                )
            )
            try input.postKey(keyCode: 0, modifiers: .command)
            try input.typeUnicode(editedTitle)
            try input.postKey(keyCode: 36)
        }
        do {
            try await waitUntil("Day Todo 主列表子任务接收键入后没有更新领域模型") {
                guard let listEditor = AppViewTreeE2E.view(
                    identifier: inputIdentifier
                ) as? NSTextView,
                    let detailEditor = AppViewTreeE2E.view(
                        identifier:
                        SubtaskRowSurface.dayDetail
                            .titleInputIdentifier(for: subtaskID)
                    ) as? NSTextView
                else {
                    return false
                }
                return listEditor.string == editedTitle
                    && detailEditor.string == editedTitle
                    && store.engine.subtasks[subtaskID]?.title
                    == editedTitle
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
                    SubtaskRowSurface.dayDetail
                        .titleInputIdentifier(for: subtaskID)
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

    private func verifyResponsiveASCIIEditing(
        context: IMEEditingContext
    ) async throws {
        let input = context.input
        let editor = context.editor
        let inputIdentifier = context.inputIdentifier
        let subtaskID = context.subtaskID
        let initialTitle = context.initialTitle
        let store = context.store
        let originalInputSource = TISCopyCurrentKeyboardInputSource()
            .takeRetainedValue()
        let asciiInputSource =
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()
                .takeRetainedValue()
        guard TISSelectInputSource(asciiInputSource) == noErr else {
            throw Failure.failed("无法选择 ASCII 键盘布局进行响应性测试")
        }
        defer {
            _ = TISSelectInputSource(originalInputSource)
        }
        guard let asciiInputSourceID = inputSourceID(asciiInputSource) else {
            throw Failure.failed("ASCII 键盘布局缺少输入源标识")
        }
        do {
            try await waitUntil("ASCII 键盘布局没有准备完成") {
                currentInputSourceID() == asciiInputSourceID
                    && editor.window?.firstResponder === editor
            }
        } catch {
            throw Failure.failed(
                "ASCII 输入现场未就绪：expected_source=\(asciiInputSourceID)，"
                    + "actual_source=\(currentInputSourceID() ?? "nil")，"
                    + "focused=\(editor.window?.firstResponder === editor)"
            )
        }
        try await selectAllText(
            in: editor,
            expectedText: initialTitle,
            using: input,
            context: "ASCII"
        )

        let strokes: [(CGKeyCode, Character)] = [
            (0, "a"),
            (11, "b"),
            (8, "c"),
            (2, "d"),
            (14, "e"),
            (3, "f"),
            (5, "g"),
            (4, "h"),
            (34, "i"),
            (38, "j")
        ]
        var expected = ""
        var samples: [ASCIILatencySample] = []
        var keyDownSequence = 0
        var latestKeyDownAt: TimeInterval?
        var timingSequence = 0
        var latestTiming: MarkdownEditorKeyDownTiming?
        var latestTimingFinishedAt: TimeInterval?
        let keyDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            keyDownSequence &+= 1
            latestKeyDownAt =
                ProcessInfo.processInfo.systemUptime
            return event
        }
        let previousTimingObserver =
            MarkdownEditorKeyDownTimingProbe.observer
        MarkdownEditorKeyDownTimingProbe.observer = { timing in
            timingSequence &+= 1
            latestTiming = timing
            latestTimingFinishedAt =
                ProcessInfo.processInfo.systemUptime
        }
        defer {
            MarkdownEditorKeyDownTimingProbe.observer =
                previousTimingObserver
            if let keyDownMonitor {
                NSEvent.removeMonitor(keyDownMonitor)
            }
        }
        for (keyCode, character) in strokes {
            let previousKeyDownSequence = keyDownSequence
            let previousTimingSequence = timingSequence
            let startedAt =
                ProcessInfo.processInfo.systemUptime
            try input.postKey(keyCode: keyCode)
            let postedAt =
                ProcessInfo.processInfo.systemUptime
            expected.append(character)
            for _ in 0 ..< 30 {
                if editor.string == expected {
                    break
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard editor.string == expected else {
                throw Failure.failed(
                    "英文连续输入未及时进入编辑器：expected=\(expected)，"
                        + "actual=\(editor.string)"
                )
            }
            let observedAt =
                ProcessInfo.processInfo.systemUptime
            guard keyDownSequence > previousKeyDownSequence,
                  let eventArrivedAt = latestKeyDownAt,
                  timingSequence > previousTimingSequence,
                  let timing = latestTiming,
                  let timingFinishedAt = latestTimingFinishedAt
            else {
                throw Failure.failed(
                    "英文按键缺少 WindowServer／编辑器分段计时：\(character)"
                )
            }
            samples.append(
                ASCIILatencySample(
                    key: character,
                    totalMilliseconds:
                    (observedAt - startedAt) * 1000,
                    postMilliseconds:
                    (postedAt - startedAt) * 1000,
                    echoWaitMilliseconds:
                    (observedAt - postedAt) * 1000,
                    eventDeliveryMilliseconds:
                    max(0, (eventArrivedAt - postedAt) * 1000),
                    eventToKeyDownMilliseconds:
                    max(0, (timing.enteredAt - eventArrivedAt) * 1000),
                    keyDownMilliseconds:
                    max(0, (timingFinishedAt - timing.enteredAt) * 1000),
                    superKeyDownMilliseconds:
                    timing.superKeyDownMilliseconds,
                    nativeSnapshotCallbackMilliseconds:
                    timing.nativeSnapshotCallbackMilliseconds,
                    eventToObservationMilliseconds:
                    max(0, (observedAt - eventArrivedAt) * 1000)
                )
            )
            guard store.engine.subtasks[subtaskID]?.title == initialTitle else {
                throw Failure.failed(
                    "英文连续输入期间逐键触发了领域持久化："
                        + "\(store.engine.subtasks[subtaskID]?.title ?? "nil")"
                )
            }
        }
        try writeASCIILatencyReport(samples)
        guard let slowest = samples.max(by: {
            $0.totalMilliseconds < $1.totalMilliseconds
        }) else {
            throw Failure.failed("英文连续输入没有形成延迟样本")
        }
        guard slowest.totalMilliseconds < 120 else {
            throw Failure.failed(
                "英文单键到编辑器的最大延迟过高："
                    + "key=\(slowest.key) "
                    + "total=\(format(slowest.totalMilliseconds))ms "
                    + "post=\(format(slowest.postMilliseconds))ms "
                    + "echo_wait=\(format(slowest.echoWaitMilliseconds))ms "
                    + "event_delivery="
                    + "\(format(slowest.eventDeliveryMilliseconds))ms "
                    + "event_to_key_down="
                    + "\(format(slowest.eventToKeyDownMilliseconds))ms "
                    + "key_down=\(format(slowest.keyDownMilliseconds))ms "
                    + "super_key_down="
                    + "\(format(slowest.superKeyDownMilliseconds))ms "
                    + "native_snapshot_callback="
                    + "\(format(slowest.nativeSnapshotCallbackMilliseconds))ms "
                    + "event_to_observation="
                    + "\(format(slowest.eventToObservationMilliseconds))ms"
            )
        }
        NSLog(
            "Noonmark E2E subtask ASCII input maximum latency: %@",
            "\(format(slowest.totalMilliseconds))ms"
        )
        try await waitUntil("英文输入停止后没有自动保存最终标题") {
            guard let activeEditor = AppViewTreeE2E.view(
                identifier: inputIdentifier
            ) as? NSTextView
            else {
                return false
            }
            return activeEditor.string == expected
                && store.engine.subtasks[subtaskID]?.title == expected
        }
    }

    private func verifyMarkedTextSurvivesSwiftUIReconciliation(
        editor: NSTextView,
        inputIdentifier: String,
        subtaskID: SubtaskID,
        initialTitle: String,
        store: NoonmarkStore
    ) async throws {
        let markedFixture = "nihao"
        editor.selectAll(nil)
        editor.setMarkedText(
            markedFixture,
            selectedRange: NSRange(
                location: markedFixture.utf16.count,
                length: 0
            ),
            replacementRange: editor.selectedRange()
        )
        guard editor.hasMarkedText(), editor.string == markedFixture else {
            throw Failure.failed("无法建立子任务 IME marked-text 回归现场")
        }

        store.objectWillChange.send()
        try await Task.sleep(for: .milliseconds(160))
        guard let activeEditor = AppViewTreeE2E.view(
            identifier: inputIdentifier
        ) as? NSTextView,
            activeEditor === editor,
            activeEditor.hasMarkedText(),
            activeEditor.string == markedFixture
        else {
            throw Failure.failed(
                "SwiftUI 刷新覆盖了子任务 IME marked-text 组合态"
            )
        }
        guard store.engine.subtasks[subtaskID]?.title == initialTitle else {
            throw Failure.failed("IME 组合态错误写入了子任务领域模型")
        }

        editor.unmarkText()
        editor.inputContext?.discardMarkedText()
        editor.string = initialTitle
        editor.setSelectedRange(
            NSRange(location: initialTitle.utf16.count, length: 0)
        )
        editor.didChangeText()
        editor.inputContext?.invalidateCharacterCoordinates()
        if #available(macOS 15.4, *) {
            editor.inputContext?.textInputClientDidUpdateSelection()
        }
        guard editor.hasMarkedText() == false,
              editor.string == initialTitle,
              store.engine.subtasks[subtaskID]?.title == initialTitle
        else {
            throw Failure.failed("IME 回归探针没有静默恢复子任务编辑现场")
        }
    }

    private func typeWithPhysicalPinyinIME(
        inputModeID: String,
        context: IMEEditingContext
    ) async throws {
        let input = context.input
        let editor = context.editor
        let inputIdentifier = context.inputIdentifier
        let subtaskID = context.subtaskID
        let initialTitle = context.initialTitle
        let store = context.store
        let originalInputSource = TISCopyCurrentKeyboardInputSource()
            .takeRetainedValue()
        let selectedInputSource = try inputSource(modeID: inputModeID)
        guard TISSelectInputSource(selectedInputSource) == noErr else {
            throw Failure.failed("无法选择真实拼音输入源：\(inputModeID)")
        }
        defer {
            _ = TISSelectInputSource(originalInputSource)
        }
        try await waitUntil("真实拼音输入源没有切换成功：\(inputModeID)") {
            currentInputModeID() == inputModeID
        }
        try await selectAllText(
            in: editor,
            expectedText: initialTitle,
            using: input,
            context: "真实拼音"
        )

        try await typePhysicalKeys(
            [45, 34, 4, 0, 31],
            using: input
        )
        try await waitUntil("物理键入 nihao 后没有形成完整 IME marked-text") {
            guard let activeEditor = AppViewTreeE2E.view(
                identifier: inputIdentifier
            ) as? NSTextView
            else {
                return false
            }
            return activeEditor.hasMarkedText()
                && activeEditor.markedRange().length >= 6
        }
        try await Task.sleep(for: .milliseconds(160))
        guard store.engine.subtasks[subtaskID]?.title == initialTitle else {
            throw Failure.failed(
                "IME 候选确认前错误写入领域模型："
                    + "\(store.engine.subtasks[subtaskID]?.title ?? "nil")"
            )
        }
        try input.postKey(keyCode: 49)
        try await waitForIMECommit(
            "你好",
            inputIdentifier: inputIdentifier
        )

        try input.postKey(keyCode: 43)
        try await waitForIMECommit(
            "你好，",
            inputIdentifier: inputIdentifier
        )

        try await typePhysicalKeys(
            [45, 34, 4, 0, 31],
            using: input
        )
        try await waitUntil("再次物理键入 nihao 后没有形成完整 IME marked-text") {
            guard let activeEditor = AppViewTreeE2E.view(
                identifier: inputIdentifier
            ) as? NSTextView
            else {
                return false
            }
            return activeEditor.hasMarkedText()
                && activeEditor.markedRange().length >= 6
        }
        try await Task.sleep(for: .milliseconds(160))
        try input.postKey(keyCode: 49)
        try await waitForIMECommit(
            "你好，你好",
            inputIdentifier: inputIdentifier
        )

        try input.postKey(keyCode: 47)
        try await waitForIMECommit(
            Self.imeEditedTitle,
            inputIdentifier: inputIdentifier
        )
        try input.postKey(keyCode: 36)
        try await waitUntil("IME 最终标题没有在回车后写入领域模型") {
            store.engine.subtasks[subtaskID]?.title == Self.imeEditedTitle
        }
        guard editor.window?.firstResponder is NSTextView else {
            throw Failure.failed("IME 输入过程中子任务编辑器丢失焦点")
        }
    }

    private func typePhysicalKeys(
        _ keyCodes: [CGKeyCode],
        using input: WindowServerInputDriver
    ) async throws {
        for keyCode in keyCodes {
            try input.postKey(keyCode: keyCode)
            try await Task.sleep(for: .milliseconds(45))
        }
    }

    private func selectAllText(
        in editor: NSTextView,
        expectedText: String,
        using input: WindowServerInputDriver,
        context: String
    ) async throws {
        try input.postKey(keyCode: 0, modifiers: .command)
        do {
            try await waitUntil("\(context) 全选输入现场没有准备完成") {
                guard editor.window?.firstResponder === editor,
                      editor.string == expectedText
                else {
                    return false
                }
                let selection = editor.selectedRange()
                return selection.location == 0
                    && selection.length == expectedText.utf16.count
            }
        } catch {
            throw Failure.failed(
                "\(context) 全选输入现场未就绪："
                    + "selection=\(editor.selectedRange())，"
                    + "expected_length=\(expectedText.utf16.count)，"
                    + "actual_text=\(editor.string)，"
                    + "focused=\(editor.window?.firstResponder === editor)"
            )
        }
    }

    private func waitForIMECommit(
        _ expected: String,
        inputIdentifier: String
    ) async throws {
        try await waitUntil("IME 没有提交预期文本：\(expected)") {
            guard let activeEditor = AppViewTreeE2E.view(
                identifier: inputIdentifier
            ) as? NSTextView
            else {
                return false
            }
            return activeEditor.hasMarkedText() == false
                && activeEditor.string == expected
        }
    }

    private func inputSource(modeID: String) throws -> TISInputSource {
        let filter = [
            kTISPropertyInputModeID: modeID as CFString
        ] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false)
            .takeRetainedValue()
        guard CFArrayGetCount(sources) == 1,
              let rawSource = CFArrayGetValueAtIndex(sources, 0)
        else {
            throw Failure.failed("找不到唯一且已启用的拼音输入源：\(modeID)")
        }
        return Unmanaged<TISInputSource>
            .fromOpaque(rawSource)
            .takeUnretainedValue()
    }

    private func currentInputModeID() -> String? {
        let source = TISCopyCurrentKeyboardInputSource()
            .takeRetainedValue()
        guard let property = TISGetInputSourceProperty(
            source,
            kTISPropertyInputModeID
        ) else {
            return nil
        }
        return Unmanaged<CFString>
            .fromOpaque(property)
            .takeUnretainedValue() as String
    }

    private func currentInputSourceID() -> String? {
        let source = TISCopyCurrentKeyboardInputSource()
            .takeRetainedValue()
        return inputSourceID(source)
    }

    private func inputSourceID(
        _ source: TISInputSource
    ) -> String? {
        guard let property = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceID
        ) else {
            return nil
        }
        return Unmanaged<CFString>
            .fromOpaque(property)
            .takeUnretainedValue() as String
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

    private func writeASCIILatencyReport(
        _ samples: [ASCIILatencySample]
    ) throws {
        guard let asciiLatencyReportURL else {
            return
        }
        let header = [
            "key",
            "total_ms",
            "post_ms",
            "echo_wait_ms",
            "event_delivery_ms",
            "event_to_key_down_ms",
            "key_down_ms",
            "super_key_down_ms",
            "native_snapshot_callback_ms",
            "event_to_observation_ms"
        ].joined(separator: "\t")
        let rows = samples.map { sample in
            [
                String(sample.key),
                format(sample.totalMilliseconds),
                format(sample.postMilliseconds),
                format(sample.echoWaitMilliseconds),
                format(sample.eventDeliveryMilliseconds),
                format(sample.eventToKeyDownMilliseconds),
                format(sample.keyDownMilliseconds),
                format(sample.superKeyDownMilliseconds),
                format(sample.nativeSnapshotCallbackMilliseconds),
                format(sample.eventToObservationMilliseconds)
            ].joined(separator: "\t")
        }
        try FileManager.default.createDirectory(
            at: asciiLatencyReportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ([header] + rows).joined(separator: "\n").write(
            to: asciiLatencyReportURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private func format(_ milliseconds: Double) -> String {
        String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            milliseconds
        )
    }

    private func writeResult(_ value: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try value.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}
