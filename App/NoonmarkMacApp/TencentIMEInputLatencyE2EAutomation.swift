import AppKit
import Carbon
import Foundation
import NoonmarkCore

@MainActor
struct TencentIMEInputLatencyE2EAutomation: LaunchAutomationRunnable {
    private static let expectedInputSourceID =
        "com.tencent.inputmethod.wetype.pinyin"
    private static let fixtureTitle = "E2E 腾讯输入法回显"
    private static let initialDescription = "输入法性能："
    private static let p95LimitMilliseconds = 100.0
    private static let maximumLimitMilliseconds = 250.0

    private let resultURL: URL

    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains(
            "--e2e-tencent-ime-input-latency"
        ), let resultPath = AppLaunchArguments.value(
            after: "--e2e-tencent-ime-input-latency-result-url"
        ) else {
            return nil
        }
        return Self(resultURL: URL(fileURLWithPath: resultPath))
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                let task = try prepareFixture(on: store)
                let evidence = try await exercise(
                    taskIdentifier: task.chain.id.description,
                    titleReadback: {
                        store.currentDefinition(
                            for: task.chain.id
                        )?.title ?? ""
                    },
                    descriptionReadback: {
                        store.currentDefinition(
                            for: task.chain.id
                        )?.descriptionText ?? ""
                    }
                )
                store.persist()
                try writeResult(
                    [
                        "status=PASS",
                        "input_source=\(evidence.inputSourceID)",
                        "title_sample_count=\(evidence.title.latencies.count)",
                        "title_p95_ms=\(format(evidence.title.p95Milliseconds))",
                        "title_max_ms=\(format(evidence.title.maximumMilliseconds))",
                        "description_sample_count=\(evidence.description.latencies.count)",
                        "description_p95_ms=\(format(evidence.description.p95Milliseconds))",
                        "description_max_ms=\(format(evidence.description.maximumMilliseconds))",
                        "title_final_utf16_count=\(evidence.title.finalText.utf16.count)",
                        "description_final_utf16_count="
                            + "\(evidence.description.finalText.utf16.count)"
                    ]
                )
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeResult([
                    "status=FAIL",
                    "reason=\(singleLine(error.localizedDescription))"
                ])
            }
            E2EApplicationTermination.schedule()
        }
    }

    private func prepareFixture(
        on store: NoonmarkStore
    ) throws -> PoolTask {
        store.page = .pool
        if store.engine.taskPool().contains(
            where: { $0.definition.title == Self.fixtureTitle }
        ) == false {
            store.poolText = Self.fixtureTitle
            store.addPoolTask()
        }
        guard let task = store.engine.taskPool().first(
            where: { $0.definition.title == Self.fixtureTitle }
        ) else {
            throw Failure.failed("无法创建输入法性能任务")
        }
        store.selectPool(task.chain.id)
        store.updatePoolTaskText(
            chainID: task.chain.id,
            descriptionText: Self.initialDescription
        )
        return task
    }

    private func exercise(
        taskIdentifier: String,
        titleReadback: @escaping @MainActor () -> String,
        descriptionReadback: @escaping @MainActor () -> String
    ) async throws -> Evidence {
        let inputSourceID = try currentInputSourceID()
        guard inputSourceID == Self.expectedInputSourceID else {
            throw Failure.failed(
                "当前输入源不是腾讯拼音：\(inputSourceID)"
            )
        }

        let input = try WindowServerInputDriver()
        let titleEditor = try await waitForEditor(
            identifier: "detail.title.input",
            expectedText: Self.fixtureTitle,
            fieldName: "标题"
        )
        let title = try await measure(
            fieldName: "标题",
            editor: titleEditor,
            phrases: ["renwumiaoshu"],
            readback: titleReadback,
            input: input
        )
        let descriptionEditor = try await waitForEditor(
            identifier: "detail.description.input",
            expectedText: Self.initialDescription,
            fieldName: "描述"
        )
        let description = try await measure(
            fieldName: "描述",
            editor: descriptionEditor,
            phrases: ["nihaoshijie", "ceshishuru", "renwumiaoshu"],
            readback: descriptionReadback,
            input: input
        )
        guard AppViewTreeE2E.view(
            identifier: "classification.editor.category.\(taskIdentifier)"
        ) != nil else {
            throw Failure.failed("输入期间任务详情被意外替换")
        }

        let failedMeasurements = [
            ("标题", title),
            ("描述", description)
        ].filter { _, measurement in
            measurement.p95Milliseconds > Self.p95LimitMilliseconds
                || measurement.maximumMilliseconds
                > Self.maximumLimitMilliseconds
        }
        guard failedMeasurements.isEmpty else {
            let summaries = failedMeasurements.map { field, measurement in
                "\(field){\(summary(measurement))}"
            }.joined(separator: " ")
            throw Failure.failed(
                "腾讯拼音回显超时：\(summaries) "
                    + "limits=\(format(Self.p95LimitMilliseconds))/"
                    + "\(format(Self.maximumLimitMilliseconds))"
            )
        }
        return Evidence(
            inputSourceID: inputSourceID,
            title: title,
            description: description
        )
    }

    private func measure(
        fieldName: String,
        editor: NSTextView,
        phrases: [String],
        readback: @escaping @MainActor () -> String,
        input: WindowServerInputDriver
    ) async throws -> Measurement {
        try await focus(editor, fieldName: fieldName)
        let persistedBeforeClear = readback()
        try input.postKey(keyCode: 0, modifiers: .command)
        try input.postKey(keyCode: 51)
        try await waitUntil("\(fieldName)编辑器未完成清空") {
            editor.string.isEmpty
        }
        guard readback() == persistedBeforeClear else {
            throw Failure.failed(
                "\(fieldName)清空本地草稿时发生了同步领域写入"
            )
        }

        var latencies: [Double] = []
        for phrase in phrases {
            for character in phrase {
                let previousText = editor.string
                let startedAt = ProcessInfo.processInfo.systemUptime
                try input.postKey(keyCode: try keyCode(for: character))
                try await waitUntil(
                    "按键 \(character) 未在\(fieldName)编辑器回显"
                ) {
                    editor.string != previousText
                }
                latencies.append(
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
                )
            }
            try input.postKey(keyCode: 49)
            try await waitUntil("\(fieldName)腾讯拼音组合文字未提交") {
                editor.hasMarkedText() == false
            }
        }

        let finalText = editor.string
        guard finalText.isEmpty == false else {
            throw Failure.failed("腾讯拼音提交后\(fieldName)为空")
        }
        try await waitUntil("\(fieldName)绑定未追上输入法提交结果") {
            readback() == finalText
        }
        let sorted = latencies.sorted()
        guard let maximum = sorted.last, sorted.isEmpty == false else {
            throw Failure.failed("\(fieldName)没有取得逐键回显样本")
        }
        let percentileIndex = max(
            0,
            Int(ceil(Double(sorted.count) * 0.95)) - 1
        )
        return Measurement(
            latencies: latencies,
            p95Milliseconds: sorted[percentileIndex],
            maximumMilliseconds: maximum,
            finalText: finalText
        )
    }

    private func waitForEditor(
        identifier: String,
        expectedText: String,
        fieldName: String
    ) async throws -> NSTextView {
        for _ in 0 ..< 100 {
            if let editor = AppViewTreeE2E.view(
                identifier: identifier
            ) as? NSTextView,
                editor.string == expectedText
            {
                return editor
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure.failed("真实任务\(fieldName) NSTextView 未出现")
    }

    private func focus(
        _ editor: NSTextView,
        fieldName: String
    ) async throws {
        guard let window = editor.window else {
            throw Failure.failed("任务\(fieldName)编辑器没有所属窗口")
        }
        for _ in 0 ..< 100 {
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            if window.makeFirstResponder(editor),
               window.firstResponder === editor,
               window.isKeyWindow,
               NSApp.isActive
            {
                editor.setSelectedRange(
                    NSRange(location: editor.string.utf16.count, length: 0)
                )
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure.failed("真实任务\(fieldName)编辑器无法取得输入焦点")
    }

    private func waitUntil(
        _ failure: String,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< 400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Failure.failed(failure)
    }

    private func currentInputSourceID() throws -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceID
        ) else {
            throw Failure.failed("无法读取当前输入源身份")
        }
        return Unmanaged<CFString>
            .fromOpaque(pointer)
            .takeUnretainedValue() as String
    }

    private func keyCode(for character: Character) throws -> CGKeyCode {
        let codes: [Character: CGKeyCode] = [
            "a": 0,
            "c": 8,
            "e": 14,
            "f": 3,
            "h": 4,
            "i": 34,
            "j": 38,
            "m": 46,
            "n": 45,
            "o": 31,
            "r": 15,
            "s": 1,
            "u": 32,
            "w": 13
        ]
        guard let code = codes[character] else {
            throw Failure.failed("缺少按键映射：\(character)")
        }
        return code
    }

    private func writeResult(_ lines: [String]) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(
            to: resultURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func summary(_ measurement: Measurement) -> String {
        "samples=\(measurement.latencies.count),"
            + "p95_ms=\(format(measurement.p95Milliseconds)),"
            + "max_ms=\(format(measurement.maximumMilliseconds))"
    }

    private func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
    }

    private struct Evidence {
        let inputSourceID: String
        let title: Measurement
        let description: Measurement
    }

    private struct Measurement {
        let latencies: [Double]
        let p95Milliseconds: Double
        let maximumMilliseconds: Double
        let finalText: String
    }

    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }
}
