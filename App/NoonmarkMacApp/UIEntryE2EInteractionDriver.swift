import AppKit
import Darwin
import Foundation
import NoonmarkCore

struct UIEntryE2EStartGate {
    enum Configuration {
        case disabled
        case enabled(UIEntryE2EStartGate)
        case invalid(String)
    }

    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    private static let gateURLArgument = "--e2e-ui-entry-start-gate-url"
    private static let gateTokenArgument = "--e2e-ui-entry-start-gate-token"
    private static let maximumRecordSize = 512
    private static let maximumTokenSize = 128

    private let gateURL: URL
    private let token: String
    private let resultURL: URL
    private let processID: pid_t

    @MainActor
    static func fromCommandLine(resultURL: URL) -> Configuration {
        let gateURLArgumentCount = AppLaunchArguments.values.filter {
            $0 == gateURLArgument
        }.count
        let gateTokenArgumentCount = AppLaunchArguments.values.filter {
            $0 == gateTokenArgument
        }.count
        guard gateURLArgumentCount > 0 || gateTokenArgumentCount > 0 else {
            return .disabled
        }
        guard gateURLArgumentCount == 1, gateTokenArgumentCount == 1,
              let gatePath = AppLaunchArguments.value(after: gateURLArgument),
              let token = AppLaunchArguments.value(after: gateTokenArgument),
              gatePath.isEmpty == false,
              gatePath.hasPrefix("--") == false,
              token.hasPrefix("--") == false
        else {
            return .invalid("gate URL 与 token 必须成对提供且各自带有值")
        }
        guard token.isEmpty == false,
              token.utf8.count <= maximumTokenSize,
              token.contains("|") == false,
              token.unicodeScalars.allSatisfy({
                  CharacterSet.controlCharacters.contains($0) == false
              })
        else {
            return .invalid("gate token 必须是有界且不含分隔符或控制字符的单行值")
        }
        return .enabled(
            UIEntryE2EStartGate(
                gateURL: URL(fileURLWithPath: gatePath),
                token: token,
                resultURL: resultURL,
                processID: ProcessInfo.processInfo.processIdentifier
            )
        )
    }

    func publishWaiting() throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "waiting|\(token)|\(processID)".write(
            to: resultURL,
            atomically: true,
            encoding: .utf8
        )
    }

    func waitForArm() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try readArmRecord())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    func activateMainWindow(expectedWindowNumber: Int) throws {
        guard AppViewTreeE2E.activateMainWindow(
            expectedWindowNumber: expectedWindowNumber
        ) else {
            throw Failure.failed(
                "无法激活外部观察器确认的主窗口 #\(expectedWindowNumber)"
            )
        }
    }

    private func readArmRecord() throws -> Int {
        let pathStatusBeforeOpen = try fifoStatus(operation: "lstat FIFO")
        try validateFIFO(pathStatusBeforeOpen, operation: "lstat FIFO")

        let descriptor = try openFIFO()
        defer { _ = Darwin.close(descriptor) }

        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else {
            throw posixFailure(operation: "fstat FIFO", code: errno)
        }
        try validateFIFO(descriptorStatus, operation: "fstat FIFO")
        guard sameFile(pathStatusBeforeOpen, descriptorStatus) else {
            throw Failure.failed("FIFO 在 lstat 与 open 之间被替换")
        }

        let pathStatusAfterOpen = try fifoStatus(operation: "再次 lstat FIFO")
        try validateFIFO(pathStatusAfterOpen, operation: "再次 lstat FIFO")
        guard sameFile(descriptorStatus, pathStatusAfterOpen) else {
            throw Failure.failed("FIFO 在 open 后被替换")
        }

        let data = try readBoundedRecord(from: descriptor)
        return try parseArmRecord(data)
    }

    private func fifoStatus(operation: String) throws -> stat {
        var status = stat()
        let result = gateURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32.min }
            return Darwin.lstat(path, &status)
        }
        guard result != Int32.min else {
            throw Failure.failed("FIFO 路径无法表示")
        }
        guard result == 0 else {
            throw posixFailure(operation: operation, code: errno)
        }
        return status
    }

    private func openFIFO() throws -> Int32 {
        let result: (descriptor: Int32, errorCode: Int32) = gateURL
            .withUnsafeFileSystemRepresentation { path in
                guard let path else { return (-1, EINVAL) }
                let descriptor = Darwin.open(
                    path,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW
                )
                return (descriptor, descriptor >= 0 ? 0 : errno)
            }
        guard result.descriptor >= 0 else {
            throw posixFailure(
                operation: "open FIFO",
                code: result.errorCode
            )
        }
        return result.descriptor
    }

    private func validateFIFO(_ status: stat, operation: String) throws {
        let fileType = status.st_mode & mode_t(S_IFMT)
        let permissions = status.st_mode & mode_t(0o7777)
        guard fileType == mode_t(S_IFIFO),
              status.st_uid == geteuid(),
              permissions == mode_t(0o600)
        else {
            throw Failure.failed(
                "\(operation) 未得到当前用户拥有且权限为 0600 的 FIFO"
            )
        }
    }

    private func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private func readBoundedRecord(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](
            repeating: 0,
            count: Self.maximumRecordSize + 1
        )
        while data.count <= Self.maximumRecordSize {
            let remaining = Self.maximumRecordSize + 1 - data.count
            let requestedCount = min(buffer.count, remaining)
            let readResult: (count: Int, errorCode: Int32) = buffer
                .withUnsafeMutableBytes { bytes in
                    let count = Darwin.read(
                        descriptor,
                        bytes.baseAddress,
                        requestedCount
                    )
                    return (count, count >= 0 ? 0 : errno)
                }
            if readResult.count > 0 {
                let chunk = buffer.prefix(readResult.count)
                if let newlineIndex = chunk.firstIndex(of: 0x0A) {
                    guard newlineIndex == chunk.index(before: chunk.endIndex) else {
                        throw Failure.failed(
                            "FIFO arm record 的结束换行后存在尾随字节或第二条记录"
                        )
                    }
                    data.append(contentsOf: chunk)
                    guard data.count <= Self.maximumRecordSize else {
                        throw Failure.failed("FIFO arm record 超过长度上限")
                    }
                    return data
                }
                data.append(contentsOf: chunk)
                continue
            }
            if readResult.count == 0 {
                throw Failure.failed("FIFO arm record 在结束换行前关闭")
            }
            if readResult.errorCode == EINTR { continue }
            throw posixFailure(
                operation: "read FIFO",
                code: readResult.errorCode
            )
        }
        throw Failure.failed("FIFO arm record 超过长度上限")
    }

    private func parseArmRecord(_ data: Data) throws -> Int {
        guard var record = String(data: data, encoding: .utf8) else {
            throw Failure.failed("FIFO arm record 不是有效 UTF-8")
        }
        guard record.hasSuffix("\n") else {
            throw Failure.failed("FIFO arm record 缺少结束换行")
        }
        record.removeLast()
        guard record.isEmpty == false,
              record.contains("\n") == false,
              record.contains("\r") == false
        else {
            throw Failure.failed("FIFO 必须只包含一条 arm record")
        }
        let fields = record.split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        // Wire contract: arm|<token>|<pid>|<main-window-number>
        guard fields.count == 4,
              fields[0] == "arm",
              fields[1] == Substring(token),
              fields[2] == Substring(String(processID)),
              let windowNumber = Int(fields[3]),
              windowNumber > 0,
              fields[3] == Substring(String(windowNumber))
        else {
            throw Failure.failed(
                "FIFO arm record 与本次 App launch 或主窗口身份不匹配"
            )
        }
        return windowNumber
    }

    private func posixFailure(operation: String, code: Int32) -> Failure {
        Failure.failed(
            "\(operation) 失败：\(String(cString: strerror(code)))"
        )
    }
}

@MainActor
enum ClassificationLabelMenuUIE2EDriver {
    static func start(
        chainIdentifier: String,
        availableLabelIdentifier: String,
        resultURL: URL,
        keepsAppOpen: Bool
    ) {
        Session(
            chainIdentifier: chainIdentifier,
            availableLabelIdentifier: availableLabelIdentifier,
            resultURL: resultURL,
            keepsAppOpen: keepsAppOpen
        ).start()
    }

    @MainActor
    private final class Session {
        private let chainIdentifier: String
        private let availableLabelIdentifier: String
        private let resultURL: URL
        private let keepsAppOpen: Bool

        init(
            chainIdentifier: String,
            availableLabelIdentifier: String,
            resultURL: URL,
            keepsAppOpen: Bool
        ) {
            self.chainIdentifier = chainIdentifier
            self.availableLabelIdentifier = availableLabelIdentifier
            self.resultURL = resultURL
            self.keepsAppOpen = keepsAppOpen
        }

        func start() {
            let addIdentifier = "classification.editor.add-label.\(chainIdentifier)"
            waitFor("添加标签菜单入口") {
                AppViewTreeE2E.click(identifier: addIdentifier)
            } onSuccess: { [self] in
                let itemIdentifier =
                    "classification.editor.available-label.\(chainIdentifier).\(availableLabelIdentifier)"
                waitFor("未选标签候选项") {
                    AppViewTreeE2E.view(identifier: itemIdentifier) != nil
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
            do {
                try FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try result.write(to: resultURL, atomically: true, encoding: .utf8)
            } catch {
                NSLog(
                    "Noonmark classification label menu UI E2E result write failed: %@",
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
        expectsExpandedDetailRail: Bool,
        resultURL: URL
    ) {
        Session(
            expectations: expectations,
            expectedWindowSize: expectedWindowSize,
            expectsExpandedDetailRail: expectsExpandedDetailRail,
            resultURL: resultURL
        ).start()
    }

    @MainActor
    private final class Session {
        private let expectations: [PoolListLayoutUIE2EExpectation]
        private let expectedWindowSize: NSSize
        private let expectsExpandedDetailRail: Bool
        private let resultURL: URL

        init(
            expectations: [PoolListLayoutUIE2EExpectation],
            expectedWindowSize: NSSize,
            expectsExpandedDetailRail: Bool,
            resultURL: URL
        ) {
            self.expectations = expectations
            self.expectedWindowSize = expectedWindowSize
            self.expectsExpandedDetailRail = expectsExpandedDetailRail
            self.resultURL = resultURL
        }

        func start(attemptsRemaining: Int = 80) {
            let titleViews = expectations.compactMap {
                AppViewTreeE2E.view(
                    identifier: "pool.task.\($0.taskIdentifier).title"
                )
            }
            guard titleViews.count == expectations.count,
                  hasSettledShellLayout()
            else {
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

        private func hasSettledShellLayout() -> Bool {
            guard let sidebar = AppViewTreeE2E.view(identifier: "shell.sidebar"),
                  let middle = AppViewTreeE2E.view(identifier: "shell.middle-pane")
            else {
                return false
            }
            let sidebarWidth = AppViewTreeE2E.frameInWindow(for: sidebar).width
            let middleWidth = AppViewTreeE2E.frameInWindow(for: middle).width
            guard (180...320).contains(sidebarWidth), middleWidth >= 440 else {
                return false
            }
            if expectsExpandedDetailRail {
                guard let rail = AppViewTreeE2E.view(identifier: "shell.detail-rail") else {
                    return false
                }
                let railWidth = AppViewTreeE2E.frameInWindow(for: rail).width
                return (240...420).contains(railWidth)
            }
            return AppViewTreeE2E.hasNoVisibleView(identifier: "shell.detail-rail")
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
                AppViewTreeE2E.view(
                    identifier: "classification.manager.open"
                ) != nil
            } onSuccess: { [self] in
                openManager()
            }
        }

        private func openManager() {
            waitFor("分组与标签管理入口点击") {
                AppViewTreeE2E.click(identifier: "classification.manager.open")
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
                completeInteraction()
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
                    completeInteraction()
                }
            }
        }

        private func completeInteraction() {
            guard keepsAppOpen == false else {
                finish(with: "ok")
                return
            }
            waitFor("关闭分组与标签管理浮窗") {
                AppViewTreeE2E.click(identifier: "classification.manager.close")
            } onSuccess: { [self] in
                waitFor("分组与标签管理浮窗关闭完成") {
                    AppViewTreeE2E.hasNoVisibleView(
                        identifier: "classification.manager.dialog"
                    )
                        && AppViewTreeE2E.hasNoAttachedSheets()
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
        keepsAppOpen: Bool,
        invalidatesFirstCaptureReadiness: Bool
    ) {
        Session(
            chainIdentifier: chainIdentifier,
            labels: labels,
            resultURL: resultURL,
            keepsAppOpen: keepsAppOpen,
            invalidatesFirstCaptureReadiness: invalidatesFirstCaptureReadiness
        ).start()
    }

    @MainActor
    private final class Session {
        private let chainIdentifier: String
        private let labels: [ClassificationItemProjection]
        private let resultURL: URL
        private let keepsAppOpen: Bool
        private let invalidatesFirstCaptureReadiness: Bool
        private var didInvalidateFirstCaptureReadiness = false
        private var captureRecoveryCount = 0

        init(
            chainIdentifier: String,
            labels: [ClassificationItemProjection],
            resultURL: URL,
            keepsAppOpen: Bool,
            invalidatesFirstCaptureReadiness: Bool
        ) {
            self.chainIdentifier = chainIdentifier
            self.labels = labels
            self.resultURL = resultURL
            self.keepsAppOpen = keepsAppOpen
            self.invalidatesFirstCaptureReadiness = invalidatesFirstCaptureReadiness
        }

        func start() {
            let namespace = TaskClassificationAccessibilityNamespace(
                surface: "pool-row",
                instanceID: chainIdentifier
            )
            waitFor("主窗口进入前台") {
                AppViewTreeE2E.activateMainWindow()
            } onSuccess: { [self] in
                openPopover(in: namespace)
            }
        }

        private func openPopover(
            in namespace: TaskClassificationAccessibilityNamespace
        ) {
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
                        waitFor("全部标签浮窗映射到 WindowServer") {
                            AppViewTreeE2E.mappedPresentationWindow(
                                identifier: namespace.popoverIdentifier
                            ) != nil
                        } onSuccess: { [self] in
                            guard let identity = AppViewTreeE2E.mappedPresentationWindow(
                                identifier: namespace.popoverIdentifier
                            ) else {
                                restartAfterInvalidPresentation()
                                return
                            }
                            completeInteraction(
                                in: namespace,
                                identity: identity
                            )
                        }
                    }
                }
            }
        }

        private func completeInteraction(
            in namespace: TaskClassificationAccessibilityNamespace,
            identity: AppViewTreeE2E.PresentationWindowIdentity
        ) {
            guard keepsAppOpen == false else {
                beginCaptureHandshake(
                    in: namespace,
                    identity: identity
                )
                return
            }
            waitFor("关闭全部标签浮窗") {
                AppViewTreeE2E.sendEscapeKey()
            } onSuccess: { [self] in
                waitFor("全部标签浮窗关闭完成") {
                    AppViewTreeE2E.hasNoVisibleView(
                        identifier: namespace.popoverIdentifier
                    )
                        && AppViewTreeE2E.hasNoAttachedPresentationWindows()
                } onSuccess: { [self] in
                    finish(with: "ok")
                }
            }
        }

        private func beginCaptureHandshake(
            in namespace: TaskClassificationAccessibilityNamespace,
            identity: AppViewTreeE2E.PresentationWindowIdentity
        ) {
            let generation = UUID().uuidString
            let processID = ProcessInfo.processInfo.processIdentifier
            write(
                "ready|\(generation)|\(processID)|" +
                    "\(identity.mainWindowNumber)|\(identity.presentationWindowNumber)|" +
                    "\(captureRecoveryCount)"
            )
            let shouldInvalidateFirstReadiness = invalidatesFirstCaptureReadiness
                && didInvalidateFirstCaptureReadiness == false
            if shouldInvalidateFirstReadiness {
                didInvalidateFirstCaptureReadiness = true
                invalidateCaptureReadiness(
                    generation: generation,
                    namespace: namespace
                )
                return
            }
            waitForCaptureAcknowledgement(
                generation: generation,
                namespace: namespace,
                identity: identity
            )
        }

        private func waitForCaptureAcknowledgement(
            generation: String,
            namespace: TaskClassificationAccessibilityNamespace,
            identity: AppViewTreeE2E.PresentationWindowIdentity,
            attemptsRemaining: Int = 160
        ) {
            if captureAcknowledgement == generation {
                guard AppViewTreeE2E.mappedPresentationWindow(
                    identifier: namespace.popoverIdentifier
                ) == identity else {
                    restartAfterInvalidPresentation(generation: generation)
                    return
                }
                write("ok|\(generation)|\(captureRecoveryCount)")
                return
            }

            guard AppViewTreeE2E.mappedPresentationWindow(
                identifier: namespace.popoverIdentifier
            ) == identity else {
                restartAfterInvalidPresentation(generation: generation)
                return
            }
            guard attemptsRemaining > 1 else {
                AppViewTreeE2E.writeDump(beside: resultURL)
                finish(with: "failed: 等待截图确认超时")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                waitForCaptureAcknowledgement(
                    generation: generation,
                    namespace: namespace,
                    identity: identity,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
        }

        private func invalidateCaptureReadiness(
            generation: String,
            namespace: TaskClassificationAccessibilityNamespace
        ) {
            waitFor("使首轮截图就绪失效") {
                AppViewTreeE2E.sendEscapeKey()
            } onSuccess: { [self] in
                waitFor("首轮截图就绪窗口关闭完成") {
                    AppViewTreeE2E.hasNoVisibleView(
                        identifier: namespace.popoverIdentifier
                    )
                        && AppViewTreeE2E.hasNoAttachedPresentationWindows()
                } onSuccess: { [self] in
                    restartAfterInvalidPresentation(generation: generation)
                }
            }
        }

        private func restartAfterInvalidPresentation(generation: String? = nil) {
            if let generation {
                captureRecoveryCount += 1
                write("stale|\(generation)|\(captureRecoveryCount)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                start()
            }
        }

        private var captureAcknowledgement: String? {
            try? String(contentsOf: captureAcknowledgementURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var captureAcknowledgementURL: URL {
            resultURL.appendingPathExtension("ack")
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
                    "Noonmark classification overflow UI E2E result write failed: %@",
                    String(describing: error)
                )
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
