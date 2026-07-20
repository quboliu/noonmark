import AppKit
import Foundation
import NoonmarkAI
import NoonmarkCore
import NoonmarkStorage

struct AutomaticTaskClassificationE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains(
            "--e2e-automatic-classification-enqueue"
        ) else { return nil }
        return Self(
            resultURL: AppLaunchArguments.value(
                after: "--e2e-automatic-classification-result-url"
            ).map(URL.init(fileURLWithPath:))
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            store.quickText = "E2E 自动归类 Day 任务 #用户标签"
            store.addQuickTask()
            store.poolText = "E2E 自动归类任务池任务"
            store.addPoolTask()

            let matchingChains = store.engine.definitions.values
                .filter {
                    $0.title == "E2E 自动归类 Day 任务"
                        || $0.title == "E2E 自动归类任务池任务"
                }
                .map(\.chainID)
            guard matchingChains.count == 2 else {
                throw AutomaticTaskClassificationE2EError.failed(
                    "new task entry points did not create both chains"
                )
            }
            guard matchingChains.allSatisfy({
                store.automaticClassificationStatus(for: $0)
                    == .waitingForConfiguration
            }) else {
                throw AutomaticTaskClassificationE2EError.failed(
                    "new task and waiting job were not published together"
                )
            }
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func writeResult(_ value: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try value.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

struct AutomaticTaskClassificationLiveE2EAutomation: LaunchAutomationRunnable {
    private static let title = "E2E DeepSeek 自动归类真实任务"

    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains(
            "--e2e-automatic-classification-live"
        ) else { return nil }
        return Self(
            resultURL: AppLaunchArguments.value(
                after: "--e2e-automatic-classification-result-url"
            ).map(URL.init(fileURLWithPath:))
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            var result = await exercise(on: store)
            do {
                let transition = try ZhulongProviderSettingsStore.clear()
                store.zhulongProviderDraft = transition.draft
                store.automaticClassificationProviderConfigurationDidChange(
                    transition
                )
                guard store.zhulongProviderDraft.hasStoredAPIKey == false,
                      store.zhulongProviderDraft.enabled == false,
                      try ZhulongProviderKeychain.hasAnyAPIKey() == false
                else {
                    result = "failed: isolated Provider cleanup was incomplete"
                    try? writeResult(result)
                    NSApp.terminate(nil)
                    return
                }
            } catch {
                result = "failed: isolated Provider cleanup failed"
            }
            try? writeResult(result)
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private func exercise(on store: NoonmarkStore) async -> String {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              store.databaseURL != nil,
              let configuration = environmentConfiguration()
        else { return "failed: isolated DeepSeek configuration unavailable" }

        var draft = store.zhulongProviderDraft
        draft.displayName = "DeepSeek E2E"
        draft.kind = .openAICompatible
        draft.baseURL = configuration.baseURL.absoluteString
        draft.model = configuration.model
        draft.apiKeyInput = configuration.apiKey
        draft.enabled = true
        store.zhulongProviderDraft = draft
        store.saveZhulongProvider()
        guard store.zhulongProviderDraft.isConfigured,
              store.zhulongProviderDraft.hasStoredAPIKey
        else { return "failed: isolated Provider setup rejected" }

        store.quickText = Self.title
        store.addQuickTask()
        guard let chainID = store.engine.definitions.values.first(where: {
            $0.title == Self.title
        })?.chainID else {
            return "failed: live quick task was not created"
        }

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if store.automaticClassificationStatus(for: chainID) == .failed {
                return "failed: live automatic classification reached failed state"
            }
            if store.automaticClassificationStatus(for: chainID) == nil {
                return persistedAutomaticClassificationExists(
                    chainID: chainID,
                    store: store
                )
                    ? "ok"
                    : "failed: completed state lacked persisted automatic relations"
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return "failed: live automation cancelled"
            }
        }
        return "failed: live automatic classification timed out"
    }

    @MainActor
    private func persistedAutomaticClassificationExists(
        chainID: TaskChainID,
        store: NoonmarkStore
    ) -> Bool {
        guard let repository = store.repository,
              let persisted = try? repository.load().snapshot(),
              let current = persisted.classifications.currentByChainID[chainID],
              case .automaticAI = current.category?.source,
              current.labels.contains(where: {
                  if case .automaticAI = $0.source { return true }
                  return false
              })
        else { return false }
        return true
    }

    private func environmentConfiguration() -> (
        baseURL: URL,
        model: String,
        apiKey: String
    )? {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURLString = environment["NOONMARK_AI_BASE_URL"],
              let baseURL = URL(string: baseURLString),
              baseURL.scheme?.lowercased() == "https",
              baseURL.host?.lowercased() == "api.deepseek.com",
              let model = environment["NOONMARK_AI_MODEL"]?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              model.hasPrefix("deepseek-"),
              let apiKey = environment["NOONMARK_AI_API_KEY"],
              apiKey.isEmpty == false
        else { return nil }
        return (baseURL, model, apiKey)
    }

    private func writeResult(_ value: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try value.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

struct AutomaticTaskClassificationLifecycleE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains(
            "--e2e-automatic-classification-lifecycle"
        ) else { return nil }
        return Self(
            resultURL: AppLaunchArguments.value(
                after: "--e2e-automatic-classification-result-url"
            ).map(URL.init(fileURLWithPath:))
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            try verifyManualClassificationWins(on: store)
            try verifyUndoRedoRequeuesOnlyCancelledWork(on: store)
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(safeMessage(error))")
        }
    }

    @MainActor
    private func verifyManualClassificationWins(
        on store: NoonmarkStore
    ) throws {
        let title = "E2E 用户抢先归类"
        store.quickText = title
        store.addQuickTask()
        let chainID = try chainID(for: title, in: store)
        _ = try store.replaceTaskClassification(
            chainID: chainID,
            category: .new(name: "人工分组", colorHex: "#2A6FDB"),
            labels: [.new(name: "人工标签", colorHex: "#0E9488")]
        )
        guard let job = try jobs(in: store).first(where: {
            $0.chainID == chainID
        }),
            job.state == .superseded,
            job.errorCode == .manualClassificationWon,
            let current = store.engine.snapshot()
            .classifications.currentByChainID[chainID],
            current.category?.source == .userDirect,
            current.labels.allSatisfy({ $0.source == .userDirect })
        else {
            throw AutomaticTaskClassificationE2EError.failed(
                "manual classification did not atomically supersede automatic work"
            )
        }
    }

    @MainActor
    private func verifyUndoRedoRequeuesOnlyCancelledWork(
        on store: NoonmarkStore
    ) throws {
        let title = "E2E 自动归类撤销重做"
        store.quickText = "\(title) #保留标签"
        store.addQuickTask()
        let chainID = try chainID(for: title, in: store)
        let first = try required(
            jobs(in: store).first(where: {
                $0.chainID == chainID && $0.state == .waitingForConfiguration
            }),
            "new work was not waiting before undo"
        )
        guard first.generation == 1 else {
            throw AutomaticTaskClassificationE2EError.failed(
                "new work did not begin at generation one"
            )
        }

        store.undo()
        let cancelled = try required(
            jobs(in: store).first(where: { $0.id == first.id }),
            "undo removed the durable job"
        )
        guard cancelled.state == .cancelled,
              cancelled.cancelledByUndo,
              cancelled.errorCode == .cancelledByUndo
        else {
            throw AutomaticTaskClassificationE2EError.failed(
                "undo did not cancel exactly its automatic work"
            )
        }

        store.redo()
        let chainJobs = try jobs(in: store).filter { $0.chainID == chainID }
        let replacement = try required(
            chainJobs.first(where: {
                $0.id != first.id && $0.state == .waitingForConfiguration
            }),
            "redo did not enqueue replacement work"
        )
        let liveCount = chainJobs.count { $0.state.isTerminal == false }
        guard replacement.generation == 2,
              liveCount == 1,
              let current = store.engine.snapshot()
              .classifications.currentByChainID[chainID],
              current.labels.contains(where: { $0.source == .userDirect })
        else {
            throw AutomaticTaskClassificationE2EError.failed(
                "redo generation or explicit user label was not preserved"
            )
        }
    }

    @MainActor
    private func chainID(
        for title: String,
        in store: NoonmarkStore
    ) throws -> TaskChainID {
        try required(
            store.engine.definitions.values.first(where: {
                $0.title == title
            })?.chainID,
            "created task identity is missing"
        )
    }

    @MainActor
    private func jobs(
        in store: NoonmarkStore
    ) throws -> [AutomaticClassificationJob] {
        guard let repository = store.automaticClassificationJobRepository else {
            throw AutomaticTaskClassificationE2EError.failed(
                "durable job repository is unavailable"
            )
        }
        return try repository.jobs()
    }

    private func required<Value>(
        _ value: Value?,
        _ message: String
    ) throws -> Value {
        guard let value else {
            throw AutomaticTaskClassificationE2EError.failed(message)
        }
        return value
    }

    private func safeMessage(_ error: Error) -> String {
        guard let error = error as? AutomaticTaskClassificationE2EError else {
            return "unexpected lifecycle failure"
        }
        return error.localizedDescription
    }

    private func writeResult(_ value: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try value.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum AutomaticTaskClassificationE2EError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message): message
        }
    }
}
