import AppKit
import Foundation
import NoonmarkAI
import NoonmarkCore
import NoonmarkZhulong

enum ZhulongChatE2EFixture {
    static let intent = "E2E 持续对话"
    static let firstLine = "E2E 第一行"
    static let secondLine = "E2E 第二行"
    static let submittedEntry = "\(firstLine)  \n\(secondLine)"
    static let initialReply = "我在。你可以从目标、限制或眼前的困难开始说。"
    static let initialReplyStreamingFragment = String(initialReply.prefix(5))
    static let continuedReply = "我看到了两行内容。我们继续沿着这个问题一起梳理。"
    static let reauthorizationEntry = "E2E 重新授权后的消息"
    static let reauthorizationReply = "身份变更已经确认。我们可以继续沿着这个问题推进。"
    static let artifactIntent = "E2E 规划一个带三个子任务的今天任务"
    static let artifactReply = "我整理成三项可编辑任务，你可以调整后直接提交。"
    static let artifactTaskTitle = "重做烛龙对话"
    static let artifactPoolTaskTitle = "整理烛龙后续想法"
    static let artifactFutureTaskTitle = "复查烛龙交互"
    static let artifactFutureDate = LocalDate("2099-12-31")
    static let artifactSubtaskTitles = [
        "定义对话产物",
        "实现内联编辑",
        "验证一次提交"
    ]
}

struct ZhulongE2EConversationProvider: ZhulongProvider, ZhulongStreamingProvider {
    let configurationIdentity: ZhulongProviderConfigurationIdentity

    func complete(_ request: ZhulongProviderRequest) async -> ZhulongProviderResult {
        .success(response(for: request))
    }

    func stream(_ request: ZhulongProviderRequest) -> AsyncStream<ZhulongProviderStreamEvent> {
        let response = response(for: request)
        let content = request.payload.userPrompt.contains(
            ZhulongChatE2EFixture.artifactIntent
        )
            ? artifactRawContent()
            : response.content
        let firstFragment = String(content.prefix(5))
        let remaining = String(content.dropFirst(firstFragment.count))
        let fragmentWindowNanoseconds: UInt64 = content == ZhulongChatE2EFixture.initialReply
            ? 1_500_000_000
            : 50_000_000
        return AsyncStream { continuation in
            let task = Task {
                defer { continuation.finish() }
                continuation.yield(.delta(firstFragment))
                try? await Task.sleep(nanoseconds: fragmentWindowNanoseconds)
                guard Task.isCancelled == false else { return }
                if remaining.isEmpty == false {
                    continuation.yield(.delta(remaining))
                }
                continuation.yield(.finished(.success(response)))
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func responseContent(for request: ZhulongProviderRequest) -> String {
        if request.payload.userPrompt.contains(ZhulongChatE2EFixture.reauthorizationEntry) {
            ZhulongChatE2EFixture.reauthorizationReply
        } else if request.payload.userPrompt.contains(ZhulongChatE2EFixture.firstLine) {
            ZhulongChatE2EFixture.continuedReply
        } else {
            ZhulongChatE2EFixture.initialReply
        }
    }

    private func response(
        for request: ZhulongProviderRequest
    ) -> ZhulongProviderResponse {
        guard request.payload.userPrompt.contains(
            ZhulongChatE2EFixture.artifactIntent
        ) else {
            return ZhulongProviderResponse(
                content: responseContent(for: request),
                draftVersion: 1
            )
        }
        guard let turn = try? ZhulongConversationTurnParser().parse(
            artifactRawContent()
        ) else {
            preconditionFailure("Invalid deterministic Zhulong E2E artifact")
        }
        return ZhulongProviderResponse(
            content: turn.message,
            draftVersion: 1,
            artifacts: turn.artifacts
        )
    }

    private func artifactRawContent() -> String {
        """
        \(ZhulongChatE2EFixture.artifactReply)
        <noonmark-artifacts>
        {
          "artifacts": [
            {
              "kind": "taskPlan",
              "tasks": [
                {
                  "title": "\(ZhulongChatE2EFixture.artifactTaskTitle)",
                  "description": "用自然对话形成可执行任务",
                  "note": null,
                  "destination": { "kind": "today" },
                  "subtasks": [
                    { "title": "\(ZhulongChatE2EFixture.artifactSubtaskTitles[0])", "difficulty": "medium" },
                    { "title": "\(ZhulongChatE2EFixture.artifactSubtaskTitles[1])", "difficulty": "hard" },
                    { "title": "\(ZhulongChatE2EFixture.artifactSubtaskTitles[2])", "difficulty": "medium" }
                  ]
                },
                {
                  "title": "\(ZhulongChatE2EFixture.artifactPoolTaskTitle)",
                  "description": null,
                  "note": null,
                  "destination": { "kind": "pool" },
                  "subtasks": []
                },
                {
                  "title": "\(ZhulongChatE2EFixture.artifactFutureTaskTitle)",
                  "description": null,
                  "note": null,
                  "destination": {
                    "kind": "date",
                    "date": "\(ZhulongChatE2EFixture.artifactFutureDate)"
                  },
                  "subtasks": []
                }
              ]
            }
          ]
        }
        </noonmark-artifacts>
        """
    }
}

struct ZhulongChatE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case interaction
        case restartVerification
    }

    private let mode: Mode
    private let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        let mode: Mode? = if AppLaunchArguments.contains("--e2e-zhulong-chat-ui") {
            .interaction
        } else if AppLaunchArguments.contains("--e2e-zhulong-chat-restart") {
            .restartVerification
        } else {
            nil
        }
        guard let mode,
              let resultPath = AppLaunchArguments.value(after: "--e2e-zhulong-chat-result-url")
        else { return nil }
        return Self(mode: mode, resultURL: URL(fileURLWithPath: resultPath))
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        configureDeterministicProvider(on: store)
        switch mode {
        case .interaction:
            startInteraction(on: store)
        case .restartVerification:
            verifyRestart(on: store)
        }
    }

    @MainActor
    private func configureDeterministicProvider(on store: NoonmarkStore) {
        // This scenario owns the complete conversation entry condition. Earlier
        // E2E scenarios can deliberately disable the optional Zhulong page in
        // shared preferences; a configured conversation Provider alone must
        // not leave this real UI interaction on Day Todo.
        store.setZhulongPageEnabled(true)
        var draft = ZhulongProviderDraft()
        draft.displayName = "E2E conversation provider"
        draft.kind = .openAICompatible
        draft.baseURL = mode == .restartVerification
            ? "https://e2e.provider.example/v2"
            : "https://e2e.provider.example/v1"
        draft.model = mode == .restartVerification
            ? "e2e-conversation-v2"
            : "e2e-conversation-v1"
        draft.enabled = true
        draft.status = .savedWithCredential
        store.zhulongProviderDraft = draft
    }

    @MainActor
    private func startInteraction(on store: NoonmarkStore) {
        store.page = .zhulong
        Task { @MainActor in
            do {
                try await submitHomeIntentThroughWindowServer(
                    on: store
                )
                beginInteractionMonitoring(on: store)
            } catch {
                write("failed: \(error.localizedDescription)")
                E2EApplicationTermination.schedule()
            }
        }
    }

    @MainActor
    private func submitHomeIntentThroughWindowServer(
        on store: NoonmarkStore
    ) async throws {
        var textView: NSTextView?
        try await waitForHome("首页没有在发送前披露范围与接收方") {
            guard let disclosure = AppViewTreeE2E.view(
                identifier: "zhulong-home-data-disclosure"
            ), let text = AppViewTreeE2E.verificationText(
                for: disclosure
            )
            else { return false }
            textView = AppViewTreeE2E.view(
                identifier: "zhulong-home-intent.input"
            ) as? NSTextView
            return textView != nil
                && text.contains("Day Todo")
                && text.contains("https://e2e.provider.example/v1")
                && text.contains("e2e-conversation-v1")
        }
        guard let textView, let window = textView.window else {
            throw ZhulongChatE2EError.missing("真实烛龙首页输入框窗口")
        }
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitForHome("烛龙首页窗口没有成为 key") {
            NSApp.isActive && window.isKeyWindow
        }

        let input = try WindowServerInputDriver()
        let inputTarget: @MainActor () throws
            -> WindowServerInputDriver.PointerCoordinate = {
            guard let current = AppViewTreeE2E.view(
                identifier: "zhulong-home-intent.input"
            ) as? NSTextView,
                current.window === window,
                window.isKeyWindow
            else {
                throw ZhulongChatE2EError.missing(
                    "烛龙首页输入框在点击前变化"
                )
            }
            let frame = AppViewTreeE2E.frameInWindow(for: current)
            return try input.pointerCoordinate(
                windowPoint: NSPoint(x: frame.midX, y: frame.midY),
                in: window
            )
        }
        try await input.postClick(
            at: try inputTarget(),
            modifiers: [],
            resolveTarget: inputTarget
        )
        try await waitForHome("烛龙首页输入框没有获得真实焦点") {
            window.firstResponder === textView
        }
        try input.typeUnicode(ZhulongChatE2EFixture.intent)
        try await waitForHome("烛龙首页意图没有通过键盘输入") {
            guard let current = AppViewTreeE2E.view(
                identifier: "zhulong-home-intent.input"
            ) as? NSTextView
            else { return false }
            return current.string == ZhulongChatE2EFixture.intent
        }
        try await waitForHome("烛龙首页发送按钮没有进入可点击状态") {
            guard let submit = AppViewTreeE2E.view(
                identifier: "zhulong-home-submit-target"
            ) else { return false }
            return (submit as? NSControl)?.isEnabled != false
        }

        let submitTarget: @MainActor () throws
            -> WindowServerInputDriver.PointerCoordinate = {
            guard let submit = AppViewTreeE2E.view(
                identifier: "zhulong-home-submit-target"
            ), submit.window === window
            else {
                throw ZhulongChatE2EError.missing(
                    "烛龙首页发送按钮在点击前变化"
                )
            }
            let frame = AppViewTreeE2E.frameInWindow(for: submit)
            return try input.pointerCoordinate(
                windowPoint: NSPoint(x: frame.midX, y: frame.midY),
                in: window
            )
        }
        try await input.postClick(
            at: try submitTarget(),
            modifiers: [],
            resolveTarget: submitTarget
        )
        try await waitForHome("点击首页发送按钮后没有建立会话") {
            store.zhulongWorkspace.selectedSession?.primaryIntent
                == ZhulongChatE2EFixture.intent
        }
    }

    @MainActor
    private func waitForHome(
        _ step: String,
        attempts: Int = 180,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ZhulongChatE2EError.missing(step)
    }

    @MainActor
    private func beginInteractionMonitoring(on store: NoonmarkStore) {
        guard store.zhulongWorkspace.selectedSession != nil else {
            write("failed: missing Zhulong session")
            return
        }
        ZhulongChatE2EUIInteractionDriver.start(
            .init(
                hasInitialLiveDelta: {
                    let session = store.zhulongWorkspace.selectedSession
                    let fullReplyAlreadyPersisted = session?.entries.contains(where: {
                        $0.author == .zhulong
                            && $0.content == ZhulongChatE2EFixture.initialReply
                    }) == true
                    return store.zhulongWorkspace.selectedLiveResponse?.content
                            == ZhulongChatE2EFixture.initialReplyStreamingFragment
                        && fullReplyAlreadyPersisted == false
                        && AppViewTreeE2E.hasNoVisibleView(
                            identifier: "zhulong-authorize-scope"
                        )
                        && AppViewTreeE2E.view(
                            identifier: "zhulong-live-assistant-message"
                        ) != nil
                },
                hasInitialReply: {
                store.zhulongWorkspace.selectedSession?.purpose == .freeform
                    && store.zhulongWorkspace.selectedSession?.entries.contains(where: {
                        $0.author == .zhulong && $0.content == ZhulongChatE2EFixture.initialReply
                    }) == true
                    && store.zhulongWorkspace.selectedSession?.phase == .draftReview
                    && AppViewTreeE2E.hasNoVisibleView(
                        identifier: "zhulong-stream-conversation-current-action"
                    )
                },
                hasPersistedConversation: {
                    let entries = store.zhulongWorkspace.selectedSession?.entries ?? []
                    return store.zhulongWorkspace.selectedSession?.purpose == .freeform
                        && entries.contains(where: {
                            $0.author == .user && $0.content == ZhulongChatE2EFixture.submittedEntry
                        }) && entries.contains(where: {
                            $0.author == .zhulong && $0.content == ZhulongChatE2EFixture.continuedReply
                        }) && store.zhulongWorkspace.selectedSession?.phase == .draftReview
                        && AppViewTreeE2E.hasNoVisibleView(
                            identifier: "zhulong-stream-conversation-current-action"
                        )
                },
                beginReauthorization: {
                    store.zhulongProviderDraft.baseURL =
                        "https://e2e.provider.example/v2"
                },
                hasReauthorizationRequired: {
                    let session = store.zhulongWorkspace.selectedSession
                    let recipientDisclosure = AppViewTreeE2E.view(
                        identifier: "zhulong-authorization-recipient"
                    ).flatMap {
                        AppViewTreeE2E.verificationText(for: $0)
                    }
                    return store.currentZhulongSessionNeedsScopeAuthorization
                        && session?.authorizations.count == 1
                        && session?.phase == .draftReview
                        && recipientDisclosure?.contains(
                            "https://e2e.provider.example/v2"
                        ) == true
                        && recipientDisclosure?.contains(
                            "e2e-conversation-v1"
                        ) == true
                        && AppViewTreeE2E.view(identifier: "zhulong-authorize-scope") != nil
                        && AppViewTreeE2E.view(identifier: "zhulong-decline-scope") != nil
                },
                hasReauthorizedSessionReady: {
                    let session = store.zhulongWorkspace.selectedSession
                    return store.currentZhulongSessionNeedsScopeAuthorization == false
                        && session?.authorizations.count == 2
                        && session?.phase == .readyForProvider
                },
                hasReauthorizedConversation: {
                    let entries = store.zhulongWorkspace.selectedSession?.entries ?? []
                    return entries.contains(where: {
                        $0.author == .user
                            && $0.content == ZhulongChatE2EFixture.reauthorizationEntry
                    }) && entries.contains(where: {
                        $0.author == .zhulong
                            && $0.content == ZhulongChatE2EFixture.reauthorizationReply
                    }) && store.zhulongWorkspace.selectedSession?.authorizations.count == 2
                        && store.zhulongWorkspace.selectedSession?.phase == .draftReview
                },
                resultURL: resultURL
            )
        )
    }

    @MainActor
    private func verifyRestart(on store: NoonmarkStore) {
        guard let session = store.zhulongWorkspace.sessions.first(where: {
            $0.primaryIntent == ZhulongChatE2EFixture.intent
        }) else {
            write("failed: missing persisted Zhulong session")
            return
        }
        store.page = .zhulong
        store.zhulongWorkspace.selectSession(session.id)
        let entries = store.zhulongWorkspace.selectedSession?.entries ?? []
        let persisted = entries.contains(where: {
            $0.author == .user && $0.content == ZhulongChatE2EFixture.submittedEntry
        }) && entries.contains(where: {
            $0.author == .zhulong && $0.content == ZhulongChatE2EFixture.continuedReply
        }) && entries.contains(where: {
            $0.author == .user && $0.content == ZhulongChatE2EFixture.reauthorizationEntry
        }) && entries.contains(where: {
            $0.author == .zhulong && $0.content == ZhulongChatE2EFixture.reauthorizationReply
        }) && session.authorizations.count == 2
            && session.purpose == .freeform
            && store.currentZhulongSessionNeedsScopeAuthorization == false
            && AppViewTreeE2E.hasNoVisibleView(
                identifier: "zhulong-authorize-scope"
            )
        write(persisted ? "ok" : "failed: conversation did not survive restart")
    }

    private func write(_ result: String) {
        do {
            try FileManager.default.createDirectory(
                at: resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try result.write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Noonmark Zhulong chat E2E result write failed: %@", String(describing: error))
        }
    }
}

@MainActor
enum ZhulongChatE2EUIInteractionDriver {
    struct Interaction {
        let hasInitialLiveDelta: @MainActor () -> Bool
        let hasInitialReply: @MainActor () -> Bool
        let hasPersistedConversation: @MainActor () -> Bool
        let beginReauthorization: @MainActor () -> Void
        let hasReauthorizationRequired: @MainActor () -> Bool
        let hasReauthorizedSessionReady: @MainActor () -> Bool
        let hasReauthorizedConversation: @MainActor () -> Bool
        let resultURL: URL
    }

    static func start(_ interaction: Interaction) {
        Session(interaction: interaction).start()
    }

    @MainActor
    private final class Session {
        private let interaction: Interaction

        init(interaction: Interaction) {
            self.interaction = interaction
        }

        func start() {
            Task { @MainActor [self] in
                do {
                    try await exerciseComposer()
                    finish("ok")
                } catch {
                    fail(error.localizedDescription)
                }
            }
        }

        private func exerciseComposer() async throws {
            var textView: NSTextView?
            try await waitUntil("烛龙首条回复没有逐段落屏") {
                self.interaction.hasInitialLiveDelta()
            }
            try await waitUntil("烛龙对话输入框与初始回复") {
                textView = AppViewTreeE2E.view(
                    identifier: "zhulong-session-entry.input"
                ) as? NSTextView
                return textView != nil && self.interaction.hasInitialReply()
            }
            guard let textView, let window = textView.window else {
                throw ZhulongChatE2EError.missing("真实烛龙输入框窗口")
            }
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            try await waitUntil("烛龙对话窗口成为 key") {
                NSApp.isActive && window.isKeyWindow
            }

            let input = try WindowServerInputDriver()
            let target: @MainActor () throws -> WindowServerInputDriver.PointerCoordinate = {
                guard let current = AppViewTreeE2E.view(
                    identifier: "zhulong-session-entry.input"
                ) as? NSTextView,
                    current.window === window,
                    window.isKeyWindow
                else {
                    throw ZhulongChatE2EError.missing("烛龙输入框在点击前变化")
                }
                let frame = AppViewTreeE2E.frameInWindow(for: current)
                return try input.pointerCoordinate(
                    windowPoint: NSPoint(x: frame.midX, y: frame.midY),
                    in: window
                )
            }
            try await input.postClick(
                at: try target(),
                modifiers: [],
                resolveTarget: target
            )
            try await waitUntil("烛龙输入框获得真实焦点") {
                window.firstResponder === textView
            }

            try input.typeUnicode(ZhulongChatE2EFixture.firstLine)
            try input.postKey(keyCode: 36, modifiers: .shift)
            try input.typeUnicode(ZhulongChatE2EFixture.secondLine)
            try await waitUntil("Shift+Enter 没有插入换行") {
                textView.string == ZhulongChatE2EFixture.submittedEntry
            }

            try input.postKey(keyCode: 36)
            try await waitUntil("Enter 没有发送并收到烛龙回复") {
                textView.string.isEmpty && self.interaction.hasPersistedConversation()
            }

            interaction.beginReauthorization()
            try await waitUntil("Provider 身份变更后没有要求重新授权") {
                self.interaction.hasReauthorizationRequired()
            }

            try input.typeUnicode(ZhulongChatE2EFixture.reauthorizationEntry)
            try input.postKey(keyCode: 36)
            try await waitUntil("重新授权前的输入被错误保存或清空") {
                textView.string == ZhulongChatE2EFixture.reauthorizationEntry
                    && self.interaction.hasReauthorizationRequired()
            }

            try await authorizeScope(input: input, in: window)
            try await waitUntil("重新授权后会话没有恢复到可继续对话状态") {
                self.interaction.hasReauthorizedSessionReady()
            }

            try await focusComposer(input: input, in: window)
            try input.postKey(keyCode: 36)
            try await waitUntil("重新授权后 Enter 没有继续对话") {
                textView.string.isEmpty && self.interaction.hasReauthorizedConversation()
            }
        }

        private func authorizeScope(
            input: WindowServerInputDriver,
            in window: NSWindow
        ) async throws {
            try await waitUntil("重新授权按钮") {
                guard let action = AppViewTreeE2E.view(
                    identifier: "zhulong-authorize-scope"
                ) else { return false }
                return action.window === window && action.isHidden == false
            }
            let target: @MainActor () throws -> WindowServerInputDriver.PointerCoordinate = {
                guard let action = AppViewTreeE2E.view(
                    identifier: "zhulong-authorize-scope"
                ), action.window === window, action.isHidden == false
                else {
                    throw ZhulongChatE2EError.missing("重新授权按钮在点击前变化")
                }
                let frame = AppViewTreeE2E.frameInWindow(for: action)
                return try input.pointerCoordinate(
                    windowPoint: NSPoint(x: frame.midX, y: frame.midY),
                    in: window
                )
            }
            try await input.postClick(
                at: try target(),
                modifiers: [],
                resolveTarget: target
            )
        }

        private func focusComposer(
            input: WindowServerInputDriver,
            in window: NSWindow
        ) async throws {
            let target: @MainActor () throws -> WindowServerInputDriver.PointerCoordinate = {
                guard let textView = AppViewTreeE2E.view(
                    identifier: "zhulong-session-entry.input"
                ) as? NSTextView,
                    textView.window === window
                else {
                    throw ZhulongChatE2EError.missing("重新授权后的烛龙输入框")
                }
                let frame = AppViewTreeE2E.frameInWindow(for: textView)
                return try input.pointerCoordinate(
                    windowPoint: NSPoint(x: frame.midX, y: frame.midY),
                    in: window
                )
            }
            try await input.postClick(
                at: try target(),
                modifiers: [],
                resolveTarget: target
            )
            try await waitUntil("重新授权后的输入框没有获得焦点") {
                guard let textView = AppViewTreeE2E.view(
                    identifier: "zhulong-session-entry.input"
                ) as? NSTextView
                else { return false }
                return window.firstResponder === textView
            }
        }

        private func waitUntil(
            _ step: String,
            attempts: Int = 180,
            condition: @MainActor () -> Bool
        ) async throws {
            for _ in 0 ..< attempts {
                if condition() { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw ZhulongChatE2EError.missing("等待真实 UI 超时：\(step)")
        }

        private func fail(_ message: String) {
            AppViewTreeE2E.writeDump(beside: interaction.resultURL)
            finish("failed: \(message)")
        }

        private func finish(_ result: String) {
            do {
                try FileManager.default.createDirectory(
                    at: interaction.resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            try result.write(to: interaction.resultURL, atomically: true, encoding: .utf8)
            } catch {
                NSLog("Noonmark Zhulong chat UI E2E result write failed: %@", String(describing: error))
            }
            E2EApplicationTermination.schedule()
        }
    }
}

private enum ZhulongChatE2EError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case let .missing(message): message
        }
    }
}
