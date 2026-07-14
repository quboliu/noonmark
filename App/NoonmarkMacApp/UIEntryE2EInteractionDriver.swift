import AppKit
import Foundation
import NoonmarkCore

struct PoolTaskRowE2ENamespace {
    let rawValue: String

    init(taskIdentifier: String) {
        precondition(taskIdentifier.isEmpty == false)
        rawValue = "pool.task.\(taskIdentifier)"
    }

    var titleIdentifier: String { "\(rawValue).title" }
}

struct PoolListLayoutUIE2EExpectation {
    let taskIdentifier: String
    let title: String
    let labelNamesByIdentifier: [String: String]
    let expectedVisibleLabelCount: Int
    let forbiddenInlineActionTitles: [String]
}

@MainActor
enum PoolListLayoutUIE2EDriver {
    static func start(
        expectations: [PoolListLayoutUIE2EExpectation],
        expectedWindowSize: NSSize,
        resultURL: URL
    ) {
        Session(
            expectations: expectations,
            expectedWindowSize: expectedWindowSize,
            resultURL: resultURL
        ).start()
    }

    @MainActor
    private final class Session {
        private let expectations: [PoolListLayoutUIE2EExpectation]
        private let expectedWindowSize: NSSize
        private let resultURL: URL

        init(
            expectations: [PoolListLayoutUIE2EExpectation],
            expectedWindowSize: NSSize,
            resultURL: URL
        ) {
            self.expectations = expectations
            self.expectedWindowSize = expectedWindowSize
            self.resultURL = resultURL
        }

        func start(attemptsRemaining: Int = 80) {
            let titleViews = expectations.compactMap {
                AppViewTreeE2E.view(
                    identifier: "pool.task.\($0.taskIdentifier).title"
                )
            }
            guard titleViews.count == expectations.count else {
                guard attemptsRemaining > 1 else {
                    finish(with: "failed: 任务池列表标题几何锚点未完整出现")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                    start(attemptsRemaining: attemptsRemaining - 1)
                }
                return
            }

            finish(with: evaluate())
        }

        private func evaluate() -> String {
            if let failure = windowFailure() {
                return failure
            }
            for expectation in expectations {
                if let failure = classificationFailure(for: expectation) {
                    return failure
                }
                if let failure = inlineActionFailure(for: expectation) {
                    return failure
                }
                if let failure = titleFailure(for: expectation) {
                    return failure
                }
            }
            return "ok"
        }

        private func windowFailure() -> String? {
            guard let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }) else {
                return "failed: 缺少任务池主窗口"
            }
            guard abs(window.frame.width - expectedWindowSize.width) <= 1,
                  abs(window.frame.height - expectedWindowSize.height) <= 1
            else {
                return "failed: 任务池窗口尺寸错误 actual=\(rounded(window.frame.width))×\(rounded(window.frame.height)) expected=\(rounded(expectedWindowSize.width))×\(rounded(expectedWindowSize.height))"
            }
            return nil
        }

        private func classificationFailure(
            for expectation: PoolListLayoutUIE2EExpectation
        ) -> String? {
            var visibleLabelCount = 0
            for (identifier, labelName) in expectation.labelNamesByIdentifier {
                guard let labelView = AppViewTreeE2E.view(identifier: identifier) else {
                    continue
                }
                visibleLabelCount += 1
                let requiredWidth = measuredWidth(
                    "#",
                    font: .noonmarkSystemFont(ofSize: 9, weight: .black)
                ) + 3 + measuredWidth(
                    labelName,
                    font: .noonmarkSystemFont(ofSize: 10.5, weight: .semibold)
                ) + 12
                let actualWidth = AppViewTreeE2E.frameInWindow(for: labelView).width
                guard actualWidth + 1 >= requiredWidth, isFullyVisible(labelView) else {
                    return "failed: 任务标签被挤成空色块：\(expectation.title) / \(labelName) actual=\(rounded(actualWidth)) required=\(rounded(requiredWidth))"
                }
            }
            let expectedVisibleLabelCount = expectation.expectedVisibleLabelCount
            guard visibleLabelCount == expectedVisibleLabelCount else {
                return "failed: 当前窗口未展示预期标签：\(expectation.title) actual=\(visibleLabelCount) expected=\(expectedVisibleLabelCount)"
            }

            let overflowCount = expectation.labelNamesByIdentifier.count - expectedVisibleLabelCount
            guard overflowCount > 0 else { return nil }
            return overflowFailure(count: overflowCount, for: expectation)
        }

        private func overflowFailure(
            count: Int,
            for expectation: PoolListLayoutUIE2EExpectation
        ) -> String? {
            let namespace = TaskClassificationAccessibilityNamespace(
                surface: "pool-row",
                instanceID: expectation.taskIdentifier
            )
            guard let overflowView = AppViewTreeE2E.view(
                identifier: namespace.overflowIdentifier
            ) else {
                return "failed: 隐藏标签没有 +N 入口：\(expectation.title)"
            }
            let overflowText = "+\(count)"
            let requiredOverflowWidth = measuredWidth(
                overflowText,
                font: .noonmarkSystemFont(ofSize: 10.5, weight: .semibold)
            ) + 14
            let actualOverflowWidth = AppViewTreeE2E.frameInWindow(
                for: overflowView
            ).width
            guard AppViewTreeE2E.verificationText(for: overflowView) == overflowText,
                  actualOverflowWidth + 1 >= requiredOverflowWidth,
                  isFullyVisible(overflowView)
            else {
                return "failed: +N 入口被挤压或计数错误：\(expectation.title)"
            }
            return nil
        }

        private func inlineActionFailure(
            for expectation: PoolListLayoutUIE2EExpectation
        ) -> String? {
            let visibleButtonLabels = AppViewTreeE2E.visibleButtonLabels()
            guard let title = expectation.forbiddenInlineActionTitles.first(where: {
                visibleButtonLabels.contains($0)
            }) else { return nil }
            return "failed: 任务池低频操作仍常驻列表行：\(expectation.title) / \(title)"
        }

        private func titleFailure(
            for expectation: PoolListLayoutUIE2EExpectation
        ) -> String? {
            let titleIdentifier = "pool.task.\(expectation.taskIdentifier).title"
            guard let titleView = AppViewTreeE2E.view(identifier: titleIdentifier) else {
                return "failed: 缺少任务标题几何锚点：\(expectation.title)"
            }
            let titleWidth = AppViewTreeE2E.frameInWindow(for: titleView).width
            let requiredTitleWidth = measuredWidth(
                expectation.title,
                font: .noonmarkSystemFont(ofSize: 13, weight: .semibold)
            )
            guard titleWidth + 1 >= requiredTitleWidth, isFullyVisible(titleView) else {
                return "failed: 任务标题被挤压：\(expectation.title) actual=\(rounded(titleWidth)) required=\(rounded(requiredTitleWidth))"
            }
            return nil
        }

        private func isFullyVisible(_ view: NSView) -> Bool {
            view.visibleRect.width + 1 >= view.bounds.width &&
                view.visibleRect.height + 1 >= view.bounds.height
        }

        private func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }

        private func rounded(_ value: CGFloat) -> String {
            String(format: "%.1f", value)
        }

        private func finish(with result: String) {
            if result != "ok" {
                AppViewTreeE2E.writeDump(beside: resultURL)
            }
            do {
                try FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try result.write(to: resultURL, atomically: true, encoding: .utf8)
            } catch {
                NSLog(
                    "Noonmark pool list layout UI E2E result write failed: %@",
                    String(describing: error)
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.terminate(nil)
            }
        }
    }
}

@MainActor
enum ClassificationManagerUIE2EDriver {
    static func start(resultURL: URL, keepsAppOpen: Bool, selectsLabels: Bool) {
        Session(
            resultURL: resultURL,
            keepsAppOpen: keepsAppOpen,
            selectsLabels: selectsLabels
        ).start()
    }

    @MainActor
    private final class Session {
        private let resultURL: URL
        private let keepsAppOpen: Bool
        private let selectsLabels: Bool

        init(resultURL: URL, keepsAppOpen: Bool, selectsLabels: Bool) {
            self.resultURL = resultURL
            self.keepsAppOpen = keepsAppOpen
            self.selectsLabels = selectsLabels
        }

        func start() {
            waitFor("分组与标签管理入口") {
                guard let anchor = AppViewTreeE2E.view(
                    identifier: "classification.manager.open"
                ) else {
                    return false
                }
                return AppViewTreeE2E.click(anchor)
            } onSuccess: { [self] in
                waitFor("分组与标签管理浮窗") {
                    AppViewTreeE2E.view(
                        identifier: "classification.manager.dialog"
                    ) != nil
                } onSuccess: { [self] in
                    selectLabelsIfNeeded()
                }
            }
        }

        private func selectLabelsIfNeeded() {
            guard selectsLabels else {
                finish(with: "ok")
                return
            }
            waitFor("标签分段入口") {
                AppViewTreeE2E.click(identifier: "classification.manager.kind.label")
            } onSuccess: { [self] in
                waitFor("标签分段选中状态") {
                    AppViewTreeE2E.view(
                        identifier: "classification.manager.kind.selected.label"
                    ) != nil
                } onSuccess: { [self] in
                    finish(with: "ok")
                }
            }
        }

        private func waitFor(
            _ step: String,
            attemptsRemaining: Int = 80,
            action: @escaping @MainActor () -> Bool,
            onSuccess: @escaping @MainActor () -> Void
        ) {
            if action() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: onSuccess)
                return
            }
            guard attemptsRemaining > 1 else {
                AppViewTreeE2E.writeDump(beside: resultURL)
                finish(with: "failed: 等待真实 UI 超时：\(step)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                waitFor(
                    step,
                    attemptsRemaining: attemptsRemaining - 1,
                    action: action,
                    onSuccess: onSuccess
                )
            }
        }

        private func finish(with result: String) {
            write(result)
            guard keepsAppOpen == false else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.terminate(nil)
            }
        }

        private func write(_ result: String) {
            do {
                try FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try result.write(to: resultURL, atomically: true, encoding: .utf8)
            } catch {
                NSLog(
                    "Noonmark classification manager UI E2E result write failed: %@",
                    String(describing: error)
                )
            }
        }
    }
}

@MainActor
enum ClassificationOverflowUIE2EDriver {
    static func start(
        chainIdentifier: String,
        labels: [ClassificationItemProjection],
        resultURL: URL,
        keepsAppOpen: Bool
    ) {
        Session(
            chainIdentifier: chainIdentifier,
            labels: labels,
            resultURL: resultURL,
            keepsAppOpen: keepsAppOpen
        ).start()
    }

    @MainActor
    private final class Session {
        private let chainIdentifier: String
        private let labels: [ClassificationItemProjection]
        private let resultURL: URL
        private let keepsAppOpen: Bool

        init(
            chainIdentifier: String,
            labels: [ClassificationItemProjection],
            resultURL: URL,
            keepsAppOpen: Bool
        ) {
            self.chainIdentifier = chainIdentifier
            self.labels = labels
            self.resultURL = resultURL
            self.keepsAppOpen = keepsAppOpen
        }

        func start() {
            let namespace = TaskClassificationAccessibilityNamespace(
                surface: "pool-row",
                instanceID: chainIdentifier
            )
            waitFor("标签溢出入口") {
                AppViewTreeE2E.click(
                    identifier: namespace.overflowIdentifier
                )
            } onSuccess: { [self] in
                waitFor("全部标签浮窗") {
                    AppViewTreeE2E.view(
                        identifier: namespace.popoverIdentifier
                    ) != nil
                } onSuccess: { [self] in
                    waitFor("全部标签浮窗内容") {
                        self.validatesAllLabels(in: namespace)
                    } onSuccess: { [self] in
                        finish(with: "ok")
                    }
                }
            }
        }

        private func validatesAllLabels(
            in namespace: TaskClassificationAccessibilityNamespace
        ) -> Bool {
            let expected = Dictionary(
                uniqueKeysWithValues: labels.map {
                    (namespace.popoverLabelIdentifier($0.id), $0.name)
                }
            )
            guard AppViewTreeE2E.identifiers(
                withPrefix: "\(namespace.popoverIdentifier).label."
            ) == Set(expected.keys) else {
                return false
            }
            return expected.allSatisfy { identifier, name in
                guard let view = AppViewTreeE2E.view(identifier: identifier) else {
                    return false
                }
                return AppViewTreeE2E.verificationText(for: view) == name
            }
        }

        private func waitFor(
            _ step: String,
            attemptsRemaining: Int = 80,
            action: @escaping @MainActor () -> Bool,
            onSuccess: @escaping @MainActor () -> Void
        ) {
            if action() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: onSuccess)
                return
            }
            guard attemptsRemaining > 1 else {
                AppViewTreeE2E.writeDump(beside: resultURL)
                finish(with: "failed: 等待真实 UI 超时：\(step)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                waitFor(
                    step,
                    attemptsRemaining: attemptsRemaining - 1,
                    action: action,
                    onSuccess: onSuccess
                )
            }
        }

        private func finish(with result: String) {
            do {
                try FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try result.write(to: resultURL, atomically: true, encoding: .utf8)
            } catch {
                NSLog(
                    "Noonmark classification overflow UI E2E result write failed: %@",
                    String(describing: error)
                )
            }
            guard keepsAppOpen == false else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.terminate(nil)
            }
        }
    }
}

@MainActor
enum ZhulongWorkflowE2EUIInteractionDriver {
    private struct WorkflowExpectation {
        let buttonID: String
        let purpose: String
        let scopes: Set<String>
    }

    static func start(resultURL: URL) {
        Session(resultURL: resultURL).start()
    }

    @MainActor
    private final class Session {
        private let resultURL: URL
        private let workflows = [
            WorkflowExpectation(
                buttonID: "zhulong-home-workflow-task-shaping",
                purpose: "taskShaping",
                scopes: ["currentDayTodo"]
            ),
            WorkflowExpectation(
                buttonID: "zhulong-home-workflow-daily-close",
                purpose: "dailyClose",
                scopes: ["currentDayTodo"]
            ),
            WorkflowExpectation(
                buttonID: "zhulong-home-workflow-scheduling",
                purpose: "schedulingAssistance",
                scopes: ["currentDayTodo", "taskPool", "unfinishedPool"]
            ),
            WorkflowExpectation(
                buttonID: "zhulong-home-workflow-classification",
                purpose: "classificationAssistance",
                scopes: [
                    "currentDayTodo",
                    "taskPool",
                    "unfinishedPool",
                    "completedPool",
                    "taskClassifications"
                ]
            )
        ]
        private var workflowIndex = 0

        init(resultURL: URL) {
            self.resultURL = resultURL
        }

        func start() {
            runCurrentWorkflow()
        }

        private func runCurrentWorkflow() {
            guard workflows.indices.contains(workflowIndex) else {
                finish(with: "ok")
                return
            }
            let workflow = workflows[workflowIndex]
            waitFor("固定 workflow 入口 \(workflow.buttonID)") {
                guard let anchor = AppViewTreeE2E.view(
                    identifier: workflow.buttonID
                ) else {
                    return false
                }
                return AppViewTreeE2E.click(anchor)
            } onSuccess: { [self] in
                verifySession(for: workflow)
            }
        }

        private func verifySession(for workflow: WorkflowExpectation) {
            waitFor("固定 workflow 会话 \(workflow.buttonID)") {
                guard AppViewTreeE2E.view(
                    identifier: "zhulong-session-purpose-\(workflow.purpose)"
                ) != nil,
                    AppViewTreeE2E.view(
                        identifier: "zhulong-session-stream"
                    ) != nil,
                    let scopeIdentifiers = AppViewTreeE2E.identifiers(
                        withPrefix: "zhulong-session-scope-"
                    )
                else {
                    return false
                }
                let prefix = "zhulong-session-scope-"
                let observedScopes = Set(
                    scopeIdentifiers.map {
                        String($0.dropFirst(prefix.count))
                    }
                )
                return observedScopes == workflow.scopes
            } onSuccess: { [self] in
                returnHome()
            }
        }

        private func returnHome() {
            waitFor("全部会话入口") {
                guard let anchor = AppViewTreeE2E.view(
                    identifier: "zhulong-session-show-home"
                ) else {
                    return false
                }
                return AppViewTreeE2E.click(anchor)
            } onSuccess: { [self] in
                waitFor("烛龙首页") {
                    AppViewTreeE2E.view(
                        identifier: "zhulong-converged-home"
                    ) != nil
                } onSuccess: { [self] in
                    workflowIndex += 1
                    runCurrentWorkflow()
                }
            }
        }

        private func waitFor(
            _ step: String,
            attemptsRemaining: Int = 80,
            action: @escaping @MainActor () -> Bool,
            onSuccess: @escaping @MainActor () -> Void
        ) {
            if action() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: onSuccess)
                return
            }
            guard attemptsRemaining > 1 else {
                AppViewTreeE2E.writeDump(beside: resultURL)
                finish(with: "failed: 等待真实 UI 超时：\(step)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                waitFor(
                    step,
                    attemptsRemaining: attemptsRemaining - 1,
                    action: action,
                    onSuccess: onSuccess
                )
            }
        }

        private func finish(with result: String) {
            do {
                try FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try result.write(to: resultURL, atomically: true, encoding: .utf8)
            } catch {
                NSLog(
                    "Noonmark Zhulong workflow UI E2E result write failed: %@",
                    String(describing: error)
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.terminate(nil)
            }
        }
    }
}
