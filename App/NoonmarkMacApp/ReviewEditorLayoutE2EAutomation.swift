import AppKit
import Foundation
import NoonmarkCore

@MainActor
struct ReviewEditorLayoutE2EAutomation: LaunchAutomationRunnable {
    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): message
            }
        }
    }

    private let resultURL: URL

    static func fromCommandLine() -> Self? {
        guard let resultPath = AppLaunchArguments.value(
            after: "--e2e-review-editor-layout-result-url"
        ) else {
            return nil
        }
        return Self(resultURL: URL(fileURLWithPath: resultPath))
    }

    func run(on store: NoonmarkStore) {
        store.page = .day
        store.selectedDate = store.today
        store.selectedCalendarDate = store.today
        store.clearSelection()
        store.isDetailRailExpanded = true

        Task { @MainActor in
            do {
                let evidence = try await verifyReviewEditors()
                let readOnlyNoteID = try prepareReadOnlyNoteFixture(on: store)
                try await verifyReadOnlyNoteRejectsDoubleClick(noteID: readOnlyNoteID)
                NSLog("Noonmark review first-line E2E: %@", evidence)
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeResult("failed: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }

    private func verifyReviewEditors() async throws -> String {
        let fields = [
            (identifier: "review.summary", sentinel: "SUMMARY7263"),
            (identifier: "review.unfinished-reason", sentinel: "REASON4815"),
            (identifier: "review.tomorrow-note", sentinel: "TOMORROW3097")
        ]
        var evidence: [String] = []
        let input = try WindowServerInputDriver()
        for field in fields {
            let fieldEvidence = try await verifyReviewEditor(
                identifier: field.identifier,
                sentinel: field.sentinel,
                input: input
            )
            evidence.append(fieldEvidence)
        }
        return evidence.joined(separator: ";")
    }

    private func verifyReviewEditor(
        identifier: String,
        sentinel: String,
        input: WindowServerInputDriver
    ) async throws -> String {
        var textView: NSTextView?
        try await waitUntil("每日复盘编辑器没有出现：\(identifier)") {
            textView = AppViewTreeE2E.view(identifier: "\(identifier).input") as? NSTextView
            return textView != nil
        }
        guard let textView, let scrollView = textView.enclosingScrollView,
              let surface = AppViewTreeE2E.view(identifier: "\(identifier).surface"),
              let window = textView.window
        else {
            throw Failure.failed("每日复盘编辑器缺少原生文本容器：\(identifier)")
        }
        guard textView.string.isEmpty,
              AppViewTreeE2E.view(identifier: "\(identifier).placeholder") != nil
        else {
            throw Failure.failed("每日复盘空字段没有显示 placeholder：\(identifier)")
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil("每日复盘窗口没有成为 key window") {
            NSApp.isActive && window.isKeyWindow
        }

        let resolveTarget: @MainActor () throws -> WindowServerInputDriver.PointerCoordinate = {
            guard let currentTextView = AppViewTreeE2E.view(
                identifier: "\(identifier).input"
            ) as? NSTextView,
                currentTextView === textView,
                let currentScrollView = currentTextView.enclosingScrollView,
                currentScrollView === scrollView,
                currentTextView.window === window,
                window.isKeyWindow
            else {
                throw Failure.failed("每日复盘首行点击目标在 mouseDown 前变化：\(identifier)")
            }
            let frame = AppViewTreeE2E.frameInWindow(for: currentScrollView)
            let point = NSPoint(
                x: frame.minX + currentTextView.textContainerInset.width + 12,
                y: frame.maxY - currentTextView.textContainerInset.height - 6
            )
            return try input.pointerCoordinate(windowPoint: point, in: window)
        }
        let initialTarget = try resolveTarget()
        try await input.postClick(
            at: initialTarget,
            modifiers: [],
            resolveTarget: resolveTarget
        )
        try await waitUntil("placeholder 首行点击没有聚焦原生编辑器") {
            window.firstResponder === textView
        }

        try input.typeUnicode(sentinel)
        try await waitUntil("每日复盘 WindowServer 输入没有进入编辑器：\(identifier)") {
            textView.string == sentinel
                && AppViewTreeE2E.hasNoVisibleView(
                    identifier: "\(identifier).placeholder"
                )
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        var actualRange = NSRange()
        let characterRect = textView.firstRect(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualRange: &actualRange
        )
        let scrollFrame = window.convertToScreen(
            AppViewTreeE2E.frameInWindow(for: scrollView)
        )
        let surfaceFrame = window.convertToScreen(
            AppViewTreeE2E.frameInWindow(for: surface)
        )
        let topGap = surfaceFrame.maxY - characterRect.maxY
        let allowedTopGap = textView.textContainerInset.height + 8
        guard actualRange.location == 0,
              actualRange.length > 0,
              topGap >= 0,
              topGap <= allowedTopGap
        else {
            throw Failure.failed(
                "首行被推低：topGap=\(topGap), allowed=\(allowedTopGap), "
                    + "surface=\(surfaceFrame), scroll=\(scrollFrame), text=\(textView.frame), "
                    + "visible=\(textView.visibleRect), character=\(characterRect), "
                    + "inset=\(textView.textContainerInset)"
            )
        }
        try input.postKey(keyCode: 0, modifiers: .command)
        try input.postKey(keyCode: 51)
        try await waitUntil("每日复盘清空后没有恢复 placeholder：\(identifier)") {
            textView.string.isEmpty
                && AppViewTreeE2E.view(
                    identifier: "\(identifier).placeholder"
                ) != nil
        }
        return "\(identifier):topGap=\(topGap),allowed=\(allowedTopGap)"
    }

    private func prepareReadOnlyNoteFixture(
        on store: NoonmarkStore
    ) throws -> TaskNoteEntryID {
        store.page = .pool
        store.poolText = "E2E 已完成只读附言"
        store.addPoolTask()
        guard let chainID = store.selectedPoolChainID,
              let noteID = store.engine.chains[chainID]?.activeNoteEntries.first?.id
        else {
            throw Failure.failed("无法建立只读附言 fixture")
        }
        store.schedulePoolTask(chainID, date: store.today)
        guard let traceID = store.selectedTraceID else {
            throw Failure.failed("只读附言 fixture 没有进入 Day Todo")
        }
        store.toggleComplete(traceID)
        guard store.engine.traces[traceID]?.status == .completed else {
            throw Failure.failed("只读附言 fixture 没有成为已完成事实")
        }
        store.page = .day
        store.selectedDate = store.today
        store.selectedCalendarDate = store.today
        store.selectTrace(traceID)
        store.isDetailRailExpanded = true
        return noteID
    }

    private func verifyReadOnlyNoteRejectsDoubleClick(
        noteID: TaskNoteEntryID
    ) async throws {
        let bodyIdentifier = "detail.note.body.\(noteID.description)"
        let editorIdentifier = "detail.note.editor.state.\(noteID.description)"
        var body: NSView?
        try await waitUntil("只读附言正文没有出现") {
            body = AppViewTreeE2E.view(identifier: bodyIdentifier)
            return body != nil
        }
        guard let body, let window = body.window else {
            throw Failure.failed("只读附言没有可用的 WindowServer 双击目标")
        }
        let input = try WindowServerInputDriver()
        let resolveTarget: @MainActor () throws -> WindowServerInputDriver.PointerCoordinate = {
            guard let currentBody = AppViewTreeE2E.view(identifier: bodyIdentifier),
                  currentBody === body,
                  currentBody.window === window,
                  window.isKeyWindow
            else {
                throw Failure.failed("只读附言双击目标在 mouseDown 前变化")
            }
            return try input.pointerCoordinate(
                windowPoint: NSPoint(
                    x: AppViewTreeE2E.frameInWindow(for: currentBody).midX,
                    y: AppViewTreeE2E.frameInWindow(for: currentBody).midY
                ),
                in: window
            )
        }
        let initialTarget = try resolveTarget()
        try await input.postDoubleClick(
            at: initialTarget,
            modifiers: [],
            resolveTarget: resolveTarget
        )
        try await Task.sleep(nanoseconds: 400_000_000)
        guard AppViewTreeE2E.hasNoVisibleView(identifier: editorIdentifier) else {
            throw Failure.failed("只读附言被双击打开了编辑器")
        }
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 120,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.failed(failure)
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}
