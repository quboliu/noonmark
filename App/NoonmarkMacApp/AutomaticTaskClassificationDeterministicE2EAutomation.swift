import AppKit
import Foundation
import NoonmarkAI
import NoonmarkCore
import NoonmarkMacRuntime
import NoonmarkStorage

private enum AutomaticClassificationDeterministicProviderE2E {
    static let model = "noonmark-e2e-automatic-classification"
    static let apiKey = "noonmark-e2e-local-provider-key"

    @MainActor
    static func configure(_ store: NoonmarkStore) throws {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              store.databaseURL != nil,
              let baseURL = localBaseURL()
        else {
            throw AutomaticClassificationDeterministicE2EError.failed(
                "isolated local provider configuration is unavailable"
            )
        }
        var draft = store.zhulongProviderDraft
        draft.displayName = "Noonmark deterministic E2E"
        draft.kind = .openAICompatible
        draft.baseURL = baseURL.absoluteString
        draft.model = model
        draft.apiKeyInput = apiKey
        draft.enabled = true
        store.zhulongProviderDraft = draft
        store.saveZhulongProvider()
        guard store.zhulongProviderDraft.isConfigured,
              store.zhulongProviderDraft.hasStoredAPIKey
        else {
            throw AutomaticClassificationDeterministicE2EError.failed(
                "isolated local provider setup was rejected"
            )
        }
    }

    @MainActor
    static func clear(_ store: NoonmarkStore) throws {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e" else {
            throw AutomaticClassificationDeterministicE2EError.failed(
                "provider cleanup escaped the E2E bundle"
            )
        }
        let transition = try ZhulongProviderSettingsStore.clear()
        store.zhulongProviderDraft = transition.draft
        store.automaticClassificationProviderConfigurationDidChange(transition)
        guard store.zhulongProviderDraft.hasStoredAPIKey == false,
              store.zhulongProviderDraft.enabled == false,
              ZhulongProviderKeychain.hasAPIKey() == false
        else {
            throw AutomaticClassificationDeterministicE2EError.failed(
                "isolated provider credentials were not cleared"
            )
        }
    }

    private static func localBaseURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NOONMARK_E2E_AI_MODEL"] == model,
              environment["NOONMARK_E2E_AI_API_KEY"] == apiKey,
              let value = environment["NOONMARK_E2E_AI_BASE_URL"],
              let url = URL(string: value),
              url.scheme?.lowercased() == "http",
              ["127.0.0.1", "localhost", "::1"].contains(
                  url.host?.lowercased() ?? ""
              ),
              url.port != nil
        else { return nil }
        return url
    }
}

struct AutomaticClassificationOperationalClockE2EAutomation:
    LaunchAutomationRunnable
{
    private static let seedTitle = "E2E 未来领域时钟前沿"
    private static let taskTitle = "E2E 未来前沿自动归类"

    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains(
            "--e2e-automatic-classification-operational-clock"
        ), let path = AppLaunchArguments.value(
            after: "--e2e-automatic-classification-result-url"
        ), path.isEmpty == false
        else { return nil }
        return Self(resultURL: URL(fileURLWithPath: path))
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            let result = await exercise(on: store)
            try? writeResult(result)
            E2EApplicationTermination.schedule()
        }
    }

    @MainActor
    private func exercise(on store: NoonmarkStore) async -> String {
        do {
            try AutomaticClassificationDeterministicProviderE2E.configure(store)
            guard let repository = store.automaticClassificationJobRepository else {
                throw AutomaticClassificationDeterministicE2EError.failed(
                    "durable job repository is unavailable"
                )
            }

            let operationalBefore = store.automaticClassificationOperationalClock
                .now()
            let futureDomainInstant = operationalBefore.addingTimeInterval(
                10 * 366 * 24 * 60 * 60
            )
            let futureEngine = try NoonmarkEngine(
                snapshot: store.engine.snapshot()
            )
            let seedChainID = try futureEngine.createPoolTask(
                title: Self.seedTitle,
                now: futureDomainInstant
            )
            try store.save(
                futureEngine,
                mutationAt: futureDomainInstant
            )
            store.engine = futureEngine
            guard let seedDefinition = futureEngine.definitions.values.first(
                where: { $0.chainID == seedChainID }
            ), seedDefinition.createdAt == futureDomainInstant
            else {
                throw AutomaticClassificationDeterministicE2EError.failed(
                    "future domain frontier was not established"
                )
            }

            store.quickText = Self.taskTitle
            store.addQuickTask()
            guard let definition = store.engine.definitions.values.first(
                where: { $0.title == Self.taskTitle }
            ), definition.createdAt > futureDomainInstant,
               let initialJob = try repository.jobs().first(
                   where: { $0.chainID == definition.chainID }
               ),
               initialJob.createdAt < futureDomainInstant,
               initialJob.availableAt < futureDomainInstant,
               initialJob.createdAt >= operationalBefore.addingTimeInterval(-1)
            else {
                throw AutomaticClassificationDeterministicE2EError.failed(
                    "new work still coupled queue time to the future domain frontier"
                )
            }

            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if let job = try repository.job(id: initialJob.id),
                   job.state == .completed,
                   let terminalAt = job.terminalAt,
                   terminalAt < futureDomainInstant,
                   job.updatedAt < futureDomainInstant,
                   persistedAutomaticClassificationExists(
                       chainID: definition.chainID,
                       store: store
                   )
                {
                    return "ok"
                }
                if try repository.job(id: initialJob.id)?.state == .failed {
                    return "failed: future-frontier automatic classification failed"
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            return "failed: future-frontier automatic classification timed out"
        } catch is CancellationError {
            return "failed: future-frontier automation was cancelled"
        } catch let error as AutomaticClassificationDeterministicE2EError {
            return "failed: \(error.message)"
        } catch {
            return "failed: unexpected future-frontier automation failure"
        }
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

    private func writeResult(_ value: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try value.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

struct AutomaticClassificationCheckpointSetupE2EAutomation:
    LaunchAutomationRunnable
{
    private static let title = "E2E checkpoint 重启复用"

    struct State: Codable {
        let formatVersion: Int
        let chainID: String
        let jobID: String
    }

    let stateURL: URL
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains(
            "--e2e-automatic-classification-checkpoint-setup"
        ), let statePath = AppLaunchArguments.value(
            after: "--e2e-automatic-classification-state-url"
        ), statePath.isEmpty == false,
        let resultPath = AppLaunchArguments.value(
            after: "--e2e-automatic-classification-result-url"
        ), resultPath.isEmpty == false
        else { return nil }
        return Self(
            stateURL: URL(fileURLWithPath: statePath),
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            try AutomaticClassificationDeterministicProviderE2E.configure(store)
            store.quickText = Self.title
            store.addQuickTask()
            guard let chainID = store.engine.definitions.values.first(
                where: { $0.title == Self.title }
            )?.chainID,
            let job = try store.automaticClassificationJobRepository?
                .jobs().first(where: { $0.chainID == chainID })
            else {
                throw AutomaticClassificationDeterministicE2EError.failed(
                    "checkpoint task and durable job were not created"
                )
            }
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(
                State(
                    formatVersion: 1,
                    chainID: chainID.description,
                    jobID: job.id.uuidString.lowercased()
                )
            ).write(to: stateURL, options: .atomic)
        } catch {
            try? AutomaticClassificationDeterministicProviderE2E.clear(store)
            try? "failed: checkpoint setup failed".write(
                to: resultURL,
                atomically: true,
                encoding: .utf8
            )
            E2EApplicationTermination.schedule()
        }
    }
}

struct AutomaticClassificationCheckpointVerifyE2EAutomation:
    LaunchAutomationRunnable
{
    let stateURL: URL
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains(
            "--e2e-automatic-classification-checkpoint-verify"
        ), let statePath = AppLaunchArguments.value(
            after: "--e2e-automatic-classification-state-url"
        ), statePath.isEmpty == false,
        let resultPath = AppLaunchArguments.value(
            after: "--e2e-automatic-classification-result-url"
        ), resultPath.isEmpty == false
        else { return nil }
        return Self(
            stateURL: URL(fileURLWithPath: statePath),
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            let result = await verify(on: store)
            try? result.write(to: resultURL, atomically: true, encoding: .utf8)
            E2EApplicationTermination.schedule()
        }
    }

    @MainActor
    private func verify(on store: NoonmarkStore) async -> String {
        do {
            let state = try JSONDecoder().decode(
                AutomaticClassificationCheckpointSetupE2EAutomation.State.self,
                from: Data(contentsOf: stateURL)
            )
            guard state.formatVersion == 1,
                  let jobID = UUID(uuidString: state.jobID),
                  let chainUUID = UUID(uuidString: state.chainID),
                  let repository = store.automaticClassificationJobRepository
            else {
                throw AutomaticClassificationDeterministicE2EError.failed(
                    "checkpoint restart state was invalid"
                )
            }
            let chainID = TaskChainID(chainUUID)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                guard let job = try repository.job(id: jobID) else {
                    throw AutomaticClassificationDeterministicE2EError.failed(
                        "checkpoint job disappeared after restart"
                    )
                }
                if job.state == .completed,
                   persistedAutomaticClassificationExists(
                       chainID: chainID,
                       store: store
                   )
                {
                    return "ok"
                }
                if job.state == .failed {
                    return "failed: checkpoint restart reached failed state"
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            return "failed: checkpoint restart timed out"
        } catch is CancellationError {
            return "failed: checkpoint restart was cancelled"
        } catch let error as AutomaticClassificationDeterministicE2EError {
            return "failed: \(error.message)"
        } catch {
            return "failed: unexpected checkpoint restart failure"
        }
    }

    @MainActor
    private func persistedAutomaticClassificationExists(
        chainID: TaskChainID,
        store: NoonmarkStore
    ) -> Bool {
        guard let repository = store.repository,
              let persisted = try? repository.load().snapshot(),
              let current = persisted.classifications.currentByChainID[chainID],
              case .automaticAI = current.category?.source
        else { return false }
        return current.labels.contains(where: {
            if case .automaticAI = $0.source { return true }
            return false
        })
    }
}

struct AutomaticClassificationContentionSetupE2EAutomation:
    LaunchAutomationRunnable
{
    static let title = "E2E Provider 启用锁竞争"

    struct State: Codable {
        let formatVersion: Int
        let chainID: String
        let jobID: String
    }

    let stateURL: URL
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains(
            "--e2e-automatic-classification-contention-setup"
        ), let statePath = AppLaunchArguments.value(
            after: "--e2e-automatic-classification-state-url"
        ), statePath.isEmpty == false,
        let resultPath = AppLaunchArguments.value(
            after: "--e2e-automatic-classification-result-url"
        ), resultPath.isEmpty == false
        else { return nil }
        return Self(
            stateURL: URL(fileURLWithPath: statePath),
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard store.zhulongProviderDraft.enabled == false,
                  store.zhulongProviderDraft.hasStoredAPIKey == false,
                  let repository = store.automaticClassificationJobRepository
            else {
                throw AutomaticClassificationDeterministicE2EError.failed(
                    "contention setup did not begin without a Provider"
                )
            }
            store.quickText = Self.title
            store.addQuickTask()
            guard let chainID = store.engine.definitions.values.first(
                where: { $0.title == Self.title }
            )?.chainID,
            let job = try repository.jobs().first(
                where: { $0.chainID == chainID }
            ), job.state == .waitingForConfiguration,
            job.generation == 1,
            job.attempt == 0
            else {
                throw AutomaticClassificationDeterministicE2EError.failed(
                    "contention setup did not persist one waiting job"
                )
            }
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(
                State(
                    formatVersion: 1,
                    chainID: chainID.description,
                    jobID: job.id.uuidString.lowercased()
                )
            ).write(to: stateURL, options: .atomic)
            try write("ok", to: resultURL)
        } catch let error as AutomaticClassificationDeterministicE2EError {
            try? write("failed: \(error.message)", to: resultURL)
        } catch {
            try? write("failed: unexpected contention setup failure", to: resultURL)
        }
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try value.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct AutomaticClassificationContentionVerifyE2EAutomation:
    LaunchAutomationRunnable
{
    let stateURL: URL
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains(
            "--e2e-automatic-classification-contention-verify"
        ), let statePath = AppLaunchArguments.value(
            after: "--e2e-automatic-classification-state-url"
        ), statePath.isEmpty == false,
        let resultPath = AppLaunchArguments.value(
            after: "--e2e-automatic-classification-result-url"
        ), resultPath.isEmpty == false
        else { return nil }
        return Self(
            stateURL: URL(fileURLWithPath: statePath),
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            let result = await verify(on: store)
            try? result.write(to: resultURL, atomically: true, encoding: .utf8)
            E2EApplicationTermination.schedule()
        }
    }

    @MainActor
    private func verify(on store: NoonmarkStore) async -> String {
        do {
            let state = try JSONDecoder().decode(
                AutomaticClassificationContentionSetupE2EAutomation.State.self,
                from: Data(contentsOf: stateURL)
            )
            guard state.formatVersion == 1,
                  let jobID = UUID(uuidString: state.jobID),
                  let chainUUID = UUID(uuidString: state.chainID),
                  let repository = store.automaticClassificationJobRepository,
                  try repository.job(id: jobID)?.state
                  == .waitingForConfiguration
            else {
                throw AutomaticClassificationDeterministicE2EError.failed(
                    "contention verification state was invalid"
                )
            }
            try AutomaticClassificationDeterministicProviderE2E.configure(store)
            let chainID = TaskChainID(chainUUID)
            let authorizationDeadline = Date().addingTimeInterval(5)
            while Date() < authorizationDeadline,
                  store.automaticClassificationBacklogPrompt?.count != 1
            {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard store.automaticClassificationBacklogPrompt?.count == 1,
                  let pending = try repository.job(id: jobID),
                  pending.state == .waitingForConfiguration,
                  pending.dispatchAuthorization == .pendingUserDecision,
                  pending.attempt == 0
            else {
                throw AutomaticClassificationDeterministicE2EError.failed(
                    "configured backlog dispatched before explicit authorization"
                )
            }
            store.resolveAutomaticClassificationBacklog(.startExisting)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                guard let job = try repository.job(id: jobID) else {
                    throw AutomaticClassificationDeterministicE2EError.failed(
                        "contention job disappeared"
                    )
                }
                if job.state == .completed,
                   job.generation == 1,
                   job.attempt == 1,
                   persistedAutomaticClassificationExists(
                       chainID: chainID,
                       store: store
                   )
                {
                    return "ok"
                }
                if job.state == .failed {
                    return "failed: contention job reached failed state"
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return "failed: contention job timed out"
        } catch is CancellationError {
            return "failed: contention verification was cancelled"
        } catch let error as AutomaticClassificationDeterministicE2EError {
            return "failed: \(error.message)"
        } catch {
            return "failed: unexpected contention verification failure"
        }
    }

    @MainActor
    private func persistedAutomaticClassificationExists(
        chainID: TaskChainID,
        store: NoonmarkStore
    ) -> Bool {
        guard let repository = store.repository,
              let persisted = try? repository.load().snapshot(),
              let current = persisted.classifications.currentByChainID[chainID],
              case .automaticAI = current.category?.source
        else { return false }
        return current.labels.contains(where: {
            if case .automaticAI = $0.source { return true }
            return false
        })
    }
}

struct AutomaticClassificationProviderRaceE2EAutomation:
    LaunchAutomationRunnable
{
    private static let title = "E2E Provider 保存与 checkpoint 竞争"

    let saveTriggerURL: URL
    let saveCompletedURL: URL
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains(
            "--e2e-automatic-classification-provider-race"
        ), let triggerPath = AppLaunchArguments.value(
            after: "--e2e-automatic-classification-provider-save-trigger-url"
        ), triggerPath.isEmpty == false,
        let completedPath = AppLaunchArguments.value(
            after: "--e2e-automatic-classification-provider-save-completed-url"
        ), completedPath.isEmpty == false,
        let resultPath = AppLaunchArguments.value(
            after: "--e2e-automatic-classification-result-url"
        ), resultPath.isEmpty == false
        else { return nil }
        return Self(
            saveTriggerURL: URL(fileURLWithPath: triggerPath),
            saveCompletedURL: URL(fileURLWithPath: completedPath),
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            let result = await exercise(on: store)
            try? result.write(to: resultURL, atomically: true, encoding: .utf8)
            E2EApplicationTermination.schedule()
        }
    }

    @MainActor
    private func exercise(on store: NoonmarkStore) async -> String {
        do {
            try AutomaticClassificationDeterministicProviderE2E.configure(store)
            guard let repository = store.automaticClassificationJobRepository else {
                throw AutomaticClassificationDeterministicE2EError.failed(
                    "durable job repository is unavailable"
                )
            }
            store.quickText = Self.title
            store.addQuickTask()
            guard let chainID = store.engine.definitions.values.first(
                where: { $0.title == Self.title }
            )?.chainID,
            let jobID = try repository.jobs().first(
                where: { $0.chainID == chainID }
            )?.id
            else {
                throw AutomaticClassificationDeterministicE2EError.failed(
                    "provider race task was not created"
                )
            }

            try await waitForFile(saveTriggerURL, label: "same-save trigger")
            guard let before = try repository.job(id: jobID),
                  before.state == .running,
                  before.attempt == 1,
                  before.proposalCheckpoint == nil,
                  let circuitBefore = try repository.providerCircuit()
            else {
                throw AutomaticClassificationDeterministicE2EError.failed(
                    "provider request was not in flight before same-config save"
                )
            }
            let fenceBefore = before.fence
            let reconciliationBefore =
                store.pendingAutomaticClassificationProviderReconciliation
            let operationFailureBefore = store.operationFailureNotice
            store.toast = nil
            store.saveZhulongProvider()
            let expectedSuccess = AppPresentation(
                language: store.engine.preferences.language
            ).zhulong.providerActionNotice(.configurationSaved)
            guard let after = try repository.job(id: jobID),
                  after == before,
                  after.fence == fenceBefore,
                  try repository.providerCircuit() == circuitBefore,
                  store.pendingAutomaticClassificationProviderReconciliation
                  == reconciliationBefore,
                  store.operationFailureNotice == operationFailureBefore,
                  store.toast == expectedSuccess
            else {
                throw AutomaticClassificationDeterministicE2EError.failed(
                    "same-config save changed work or missed success feedback"
                )
            }
            try write("ok", to: saveCompletedURL)

            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                guard let job = try repository.job(id: jobID) else {
                    throw AutomaticClassificationDeterministicE2EError.failed(
                        "provider race job disappeared"
                    )
                }
                if job.state == .completed,
                   job.attempt == 1,
                   persistedAutomaticClassificationExists(
                       chainID: chainID,
                       store: store
                   )
                {
                    return "ok"
                }
                if job.state == .failed {
                    return "failed: provider race job reached failed state"
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return "failed: provider race job timed out"
        } catch is CancellationError {
            return "failed: provider race automation was cancelled"
        } catch let error as AutomaticClassificationDeterministicE2EError {
            return "failed: \(error.message)"
        } catch {
            return "failed: unexpected provider race failure"
        }
    }

    private func waitForFile(_ url: URL, label: String) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw AutomaticClassificationDeterministicE2EError.failed(
            "\(label) timed out"
        )
    }

    @MainActor
    private func persistedAutomaticClassificationExists(
        chainID: TaskChainID,
        store: NoonmarkStore
    ) -> Bool {
        guard let repository = store.repository,
              let persisted = try? repository.load().snapshot(),
              let current = persisted.classifications.currentByChainID[chainID],
              case .automaticAI = current.category?.source
        else { return false }
        return current.labels.contains(where: {
            if case .automaticAI = $0.source { return true }
            return false
        })
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try value.write(to: url, atomically: true, encoding: .utf8)
    }
}

@MainActor
enum ClassificationRetryE2EOverride {
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let productionDelays: [TimeInterval] = [30, 120, 600]
        guard let delays = explicitDelays else {
            return productionDelays[boundedIndex(forAttempt: attempt)]
        }
        return delays[boundedIndex(forAttempt: attempt)]
    }

    static var hasValidExplicitSchedule: Bool {
        explicitDelays != nil
    }

    private static var explicitDelays: [TimeInterval]? {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              AppLaunchArguments.contains(
                  "--e2e-automatic-classification-provider-transient-circuit"
              ),
              let value = AppLaunchArguments.value(
                  after: "--e2e-automatic-classification-retry-delays-ms"
              )
        else { return nil }
        let tokens = value.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard tokens.count == 3 else { return nil }
        var milliseconds: [Int] = []
        milliseconds.reserveCapacity(tokens.count)
        for token in tokens {
            let trimmed = token.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard trimmed.isEmpty == false,
                  let parsed = Int(trimmed),
                  1 ... 1000 ~= parsed
            else { return nil }
            milliseconds.append(parsed)
        }
        return milliseconds.map { TimeInterval($0) / 1000 }
    }

    private static func boundedIndex(forAttempt attempt: Int) -> Int {
        min(max(attempt - 1, 0), 2)
    }
}

struct ClassificationQueueE2EAutomation: LaunchAutomationRunnable {
    private enum Scenario {
        case backlogStart(requestReceivedURL: URL, responseReleaseURL: URL)
        case backlogLater
        case futureOnly
        case providerBlockRetry
        case providerTransientCircuit(gateDirectory: URL)
    }

    private enum Title {
        static let backlogA = "E2E 待归类积压 A"
        static let backlogB = "E2E 待归类积压 B"
        static let automaticC = "E2E 配置后自动归类 C"
        static let blockedPrefix = "E2E Provider 拒绝"
        static let transientPrefix = "E2E Provider 瞬时故障"
        static let manualCategory = "E2E 人工分组"
        static let manualLabel = "E2E 人工标签"
    }

    private let scenario: Scenario
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard let resultPath = AppLaunchArguments.value(
            after: "--e2e-automatic-classification-result-url"
        ), resultPath.isEmpty == false
        else { return nil }
        let resultURL = URL(fileURLWithPath: resultPath)

        if AppLaunchArguments.contains(
            "--e2e-automatic-classification-backlog-start"
        ) {
            guard let receivedPath = AppLaunchArguments.value(
                after: "--e2e-provider-request-received-url"
            ), receivedPath.isEmpty == false,
            let releasePath = AppLaunchArguments.value(
                after: "--e2e-provider-response-release-url"
            ), releasePath.isEmpty == false
            else { return nil }
            return Self(
                scenario: .backlogStart(
                    requestReceivedURL: URL(fileURLWithPath: receivedPath),
                    responseReleaseURL: URL(fileURLWithPath: releasePath)
                ),
                resultURL: resultURL
            )
        }
        if AppLaunchArguments.contains(
            "--e2e-automatic-classification-future-only"
        ) {
            return Self(scenario: .futureOnly, resultURL: resultURL)
        }
        if AppLaunchArguments.contains(
            "--e2e-automatic-classification-backlog-later"
        ) {
            return Self(scenario: .backlogLater, resultURL: resultURL)
        }
        if AppLaunchArguments.contains(
            "--e2e-automatic-classification-provider-block-retry"
        ) {
            return Self(scenario: .providerBlockRetry, resultURL: resultURL)
        }
        if AppLaunchArguments.contains(
            "--e2e-automatic-classification-provider-transient-circuit"
        ) {
            guard let directoryPath = AppLaunchArguments.value(
                after: "--e2e-provider-gate-directory"
            ), directoryPath.isEmpty == false
            else { return nil }
            return Self(
                scenario: .providerTransientCircuit(
                    gateDirectory: URL(fileURLWithPath: directoryPath)
                ),
                resultURL: resultURL
            )
        }
        return nil
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            let result = await exercise(on: store)
            try? writeResult(result)
            E2EApplicationTermination.schedule()
        }
    }

    @MainActor
    private func exercise(on store: NoonmarkStore) async -> String {
        do {
            switch scenario {
            case let .backlogStart(requestReceivedURL, responseReleaseURL):
                try await exerciseBacklogStart(
                    on: store,
                    requestReceivedURL: requestReceivedURL,
                    responseReleaseURL: responseReleaseURL
                )
            case .backlogLater:
                try await exerciseBacklogLater(on: store)
            case .futureOnly:
                try await exerciseFutureOnly(on: store)
            case .providerBlockRetry:
                try await exerciseProviderBlockRetry(on: store)
            case let .providerTransientCircuit(gateDirectory):
                try await exerciseProviderTransientCircuit(
                    on: store,
                    gateDirectory: gateDirectory
                )
            }
            return "ok"
        } catch is CancellationError {
            return "failed: automatic classification automation was cancelled"
        } catch let error as AutomaticClassificationDeterministicE2EError {
            return "failed: \(error.message)"
        } catch {
            return "failed: unexpected automatic classification automation failure"
        }
    }

    @MainActor
    private func exerciseBacklogStart(
        on store: NoonmarkStore,
        requestReceivedURL: URL,
        responseReleaseURL: URL
    ) async throws {
        let repository = try await prepareUnconfiguredStore(store)
        let chainA = try addTask(Title.backlogA, to: store)
        let chainB = try addTask(Title.backlogB, to: store)
        let backlogChainIDs = Set([chainA, chainB])
        try assertPendingBacklog(
            chainIDs: backlogChainIDs,
            repository: repository
        )

        try AutomaticClassificationDeterministicProviderE2E.configure(store)
        try await waitUntil("configured backlog prompt") {
            guard store.automaticClassificationBacklogPrompt?.count == 2 else {
                return false
            }
            return try isClosedCircuit(repository)
        }
        try assertPendingBacklog(
            chainIDs: backlogChainIDs,
            repository: repository
        )

        let chainC = try addTask(Title.automaticC, to: store)
        try await waitForFile(
            requestReceivedURL,
            label: "automatic task Provider request"
        )
        guard let automaticJob = try job(for: chainC, repository: repository),
              automaticJob.state == .running,
              automaticJob.attempt == 1,
              automaticJob.dispatchAuthorization == .automatic,
              automaticJob.authorizationID == nil,
              automaticJob.authorizedAt == nil
        else {
            throw failure("new automatic work did not own the gated request")
        }
        try assertPendingBacklog(
            chainIDs: backlogChainIDs,
            repository: repository
        )

        try await clickZhulongSettingsButton(
            identifier: "settings.zhulong.automatic-classification-backlog.start",
            label: store.copy
                .startAutomaticClassificationBacklogAccessibilityLabel(2),
            store: store
        )
        try await waitUntil("exact backlog authorization") {
            let jobs = try jobs(
                for: backlogChainIDs,
                repository: repository
            )
            return jobs.count == 2
                && jobs.allSatisfy {
                    $0.dispatchAuthorization == .explicit
                        && $0.authorizationID != nil
                        && $0.authorizedAt != nil
                }
        }
        let authorized = try jobs(
            for: backlogChainIDs,
            repository: repository
        )
        guard let authorizationID = authorized.first?.authorizationID,
              let authorizedAt = authorized.first?.authorizedAt,
              Set(authorized.compactMap(\.authorizationID)) == [authorizationID],
              Set(authorized.compactMap(\.authorizedAt)) == [authorizedAt]
        else {
            throw failure("one backlog decision did not share one authorization")
        }

        try writeMarker(responseReleaseURL)
        let allChainIDs = backlogChainIDs.union([chainC])
        try await waitUntil("authorized backlog completion", timeout: 30) {
            let current = try jobs(for: allChainIDs, repository: repository)
            guard current.count == 5,
                  let automatic = current.first(where: { $0.chainID == chainC }),
                  isCompletedAutomaticJob(automatic, attempt: 1)
            else { return false }
            return backlogChainIDs.allSatisfy { chainID in
                isCompletedCatalogReplacement(
                    current.filter { $0.chainID == chainID },
                    dispatchAuthorization: .explicit,
                    authorizationID: authorizationID,
                    authorizedAt: authorizedAt
                )
            }
        }
        let completed = try jobs(for: allChainIDs, repository: repository)
        let completedAutomatic = completed.first { $0.chainID == chainC }
        guard completed.count == 5,
              completedAutomatic.map({ isCompletedAutomaticJob($0, attempt: 1) })
              == true,
              backlogChainIDs.allSatisfy({ chainID in
                  isCompletedCatalogReplacement(
                      completed.filter { $0.chainID == chainID },
                      dispatchAuthorization: .explicit,
                      authorizationID: authorizationID,
                      authorizedAt: authorizedAt
                  )
              }),
              try allHaveAutomaticClassification(
                  allChainIDs,
                  store: store
              ),
              try isHealthyClosedCircuit(repository)
        else {
            throw failure("authorized backlog did not complete under its exact authority")
        }
    }

    @MainActor
    private func exerciseBacklogLater(on store: NoonmarkStore) async throws {
        let repository = try await prepareUnconfiguredStore(store)
        let chainA = try addTask(Title.backlogA, to: store)
        let chainB = try addTask(Title.backlogB, to: store)
        let backlogChainIDs = Set([chainA, chainB])
        try assertPendingBacklog(
            chainIDs: backlogChainIDs,
            repository: repository
        )

        try AutomaticClassificationDeterministicProviderE2E.configure(store)
        try await waitUntil("later backlog prompt") {
            guard store.automaticClassificationBacklogPrompt?.count == 2 else {
                return false
            }
            return try isClosedCircuit(repository)
        }
        try assertPendingBacklog(
            chainIDs: backlogChainIDs,
            repository: repository
        )

        try await clickZhulongSettingsButton(
            identifier: "settings.zhulong.automatic-classification-backlog.later",
            label: store.copy
                .decideAutomaticClassificationBacklogLaterAccessibilityLabel(2),
            store: store
        )
        try await waitUntil("later backlog prompt dismissal") {
            store.automaticClassificationBacklogPrompt == nil
        }
        try assertPendingBacklog(
            chainIDs: backlogChainIDs,
            repository: repository
        )

        let chainC = try addTask(Title.automaticC, to: store)
        try await waitUntil("later automatic completion", timeout: 30) {
            guard let automatic = try job(for: chainC, repository: repository)
            else { return false }
            return automatic.state == .completed && automatic.attempt == 1
        }
        try assertPendingBacklog(
            chainIDs: backlogChainIDs,
            repository: repository
        )
        guard store.automaticClassificationBacklogPrompt == nil,
              let automatic = try job(for: chainC, repository: repository),
              automatic.state == .completed,
              automatic.dispatchAuthorization == .automatic,
              automatic.authorizationID == nil,
              automatic.authorizedAt == nil,
              try hasAutomaticClassification(chainC, store: store),
              try isHealthyClosedCircuit(repository)
        else {
            throw failure("later decision did not remain session-local")
        }
    }

    @MainActor
    private func exerciseFutureOnly(on store: NoonmarkStore) async throws {
        let repository = try await prepareUnconfiguredStore(store)
        let chainA = try addTask(Title.backlogA, to: store)
        let chainB = try addTask(Title.backlogB, to: store)
        _ = try store.replaceTaskClassification(
            chainID: chainA,
            category: .new(name: Title.manualCategory, colorHex: "#2A6FDB"),
            labels: [.new(name: Title.manualLabel, colorHex: "#0E9488")]
        )
        guard let manualJob = try job(for: chainA, repository: repository),
              manualJob.state == .superseded,
              manualJob.errorCode == .manualClassificationWon,
              manualJob.attempt == 0,
              try hasUserDirectClassification(chainA, store: store)
        else {
            throw failure("manual classification did not supersede pending work")
        }

        try AutomaticClassificationDeterministicProviderE2E.configure(store)
        try await waitUntil("future-only backlog prompt") {
            guard store.automaticClassificationBacklogPrompt?.count == 1 else {
                return false
            }
            return try isClosedCircuit(repository)
        }
        guard let pending = try job(for: chainB, repository: repository),
              pending.state == .waitingForConfiguration,
              pending.dispatchAuthorization == .pendingUserDecision,
              pending.attempt == 0
        else {
            throw failure("remaining backlog dispatched before the user decision")
        }

        try await clickZhulongSettingsButton(
            identifier: "settings.zhulong.automatic-classification-backlog.future-only",
            label: store.copy
                .classifyOnlyFutureTasksAccessibilityLabel(1),
            store: store
        )
        try await waitUntil("future-only backlog cancellation") {
            guard let skipped = try job(for: chainB, repository: repository)
            else { return false }
            return skipped.state == .cancelled
                && skipped.errorCode == .backlogSkippedByUser
                && skipped.attempt == 0
        }
        let chainC = try addTask(Title.automaticC, to: store)
        try await waitUntil("future-only automatic completion", timeout: 30) {
            guard let automatic = try job(for: chainC, repository: repository)
            else { return false }
            return automatic.state == .completed && automatic.attempt == 1
        }

        guard let finalA = try job(for: chainA, repository: repository),
              let finalB = try job(for: chainB, repository: repository),
              let finalC = try job(for: chainC, repository: repository),
              finalA.state == .superseded,
              finalB.state == .cancelled,
              finalC.state == .completed,
              finalC.dispatchAuthorization == .automatic,
              finalC.authorizationID == nil,
              finalC.authorizedAt == nil,
              try hasUserDirectClassification(chainA, store: store),
              try hasAutomaticClassification(chainC, store: store),
              try isHealthyClosedCircuit(repository)
        else {
            throw failure("future-only decision did not preserve manual authority")
        }
    }

    @MainActor
    private func exerciseProviderBlockRetry(
        on store: NoonmarkStore
    ) async throws {
        let repository = try await prepareConfiguredStore(store)
        let chainIDs = try Set((1 ... 3).map {
            try addTask("\(Title.blockedPrefix) \($0)", to: store)
        })
        try await waitUntil("Provider rejection circuit", timeout: 15) {
            guard let circuit = try repository.providerCircuit() else {
                return false
            }
            return circuit.state == .blocked
                && circuit.failureCode == .providerRejected
                && circuit.consecutiveFailures == 1
        }
        let blockedJobs = try jobs(for: chainIDs, repository: repository)
        let attempted = blockedJobs.filter { $0.attempt == 1 }
        let untouched = blockedJobs.filter { $0.attempt == 0 }
        guard blockedJobs.count == 3,
              attempted.count == 1,
              attempted[0].state == .waitingForConfiguration,
              attempted[0].errorCode == .providerRejected,
              untouched.count == 2,
              untouched.allSatisfy({
                  $0.state == .ready && $0.errorCode == nil
              })
        else {
            throw failure("Provider rejection was not a one-request global gate")
        }
        let attemptedJobID = attempted[0].id
        let attemptedChainID = attempted[0].chainID

        let blockedCircuit = try repository.providerCircuit()
        store.saveZhulongProvider()
        try await Task.sleep(nanoseconds: 300_000_000)
        guard try repository.providerCircuit() == blockedCircuit,
              try jobs(for: chainIDs, repository: repository) == blockedJobs
        else {
            throw failure("same Provider configuration reset the blocked circuit")
        }

        try await clickZhulongSettingsButton(
            identifier: "settings.zhulong.automatic-classification-circuit.retry",
            label: store.copy.retryAutomaticClassificationProvider,
            store: store
        )
        try await waitUntil("Provider retry completion", timeout: 30) {
            let current = try jobs(for: chainIDs, repository: repository)
            guard current.count == 5,
                  let retried = current.first(where: { $0.id == attemptedJobID }),
                  isCompletedAutomaticJob(retried, attempt: 2)
            else { return false }
            let replacementChainIDs = chainIDs.subtracting([attemptedChainID])
            guard replacementChainIDs.allSatisfy({ chainID in
                isCompletedCatalogReplacement(
                    current.filter { $0.chainID == chainID },
                    dispatchAuthorization: .automatic,
                    authorizationID: nil,
                    authorizedAt: nil
                )
            }) else { return false }
            return try isHealthyClosedCircuit(repository)
        }
        let completed = try jobs(for: chainIDs, repository: repository)
        let replacementChainIDs = chainIDs.subtracting([attemptedChainID])
        guard completed.map(\.attempt).sorted() == [1, 1, 1, 1, 2],
              replacementChainIDs.allSatisfy({ chainID in
                  isCompletedCatalogReplacement(
                      completed.filter { $0.chainID == chainID },
                      dispatchAuthorization: .automatic,
                      authorizationID: nil,
                      authorizedAt: nil
                  )
              }),
              try allHaveAutomaticClassification(chainIDs, store: store)
        else {
            throw failure("healthy retry did not drain the blocked queue once")
        }
    }

    @MainActor
    private func exerciseProviderTransientCircuit(
        on store: NoonmarkStore,
        gateDirectory: URL
    ) async throws {
        guard ClassificationRetryE2EOverride
            .hasValidExplicitSchedule
        else {
            throw failure("transient retry schedule was missing or invalid")
        }
        let repository = try await prepareConfiguredStore(store)
        let chainIDs = try Set((1 ... 4).map {
            try addTask("\(Title.transientPrefix) \($0)", to: store)
        })

        try await waitForGateRequest(1, in: gateDirectory)
        let firstJobs = try jobs(for: chainIDs, repository: repository)
        guard let canaryID = firstJobs.first(where: { $0.attempt == 1 })?.id,
              firstJobs.filter({ $0.attempt == 1 }).count == 1,
              firstJobs.filter({ $0.attempt == 0 }).count == 3
        else {
            throw failure("first transient request did not isolate one canary")
        }
        try releaseGateResponse(1, in: gateDirectory)

        try await assertHalfOpenCanary(
            request: 2,
            canaryID: canaryID,
            allChainIDs: chainIDs,
            repository: repository,
            gateDirectory: gateDirectory
        )
        try releaseGateResponse(2, in: gateDirectory)
        try await assertHalfOpenCanary(
            request: 3,
            canaryID: canaryID,
            allChainIDs: chainIDs,
            repository: repository,
            gateDirectory: gateDirectory
        )
        try releaseGateResponse(3, in: gateDirectory)

        try await waitUntil("third transient failure gate", timeout: 15) {
            guard let circuit = try repository.providerCircuit() else {
                return false
            }
            return circuit.state == .blocked
                && circuit.failureCode == .providerUnavailable
                && circuit.consecutiveFailures == 3
                && circuit.probeFence == nil
        }
        let finalJobs = try jobs(for: chainIDs, repository: repository)
        guard let canary = finalJobs.first(where: { $0.id == canaryID }),
              canary.state == .ready,
              canary.attempt == 3,
              canary.errorCode == .providerUnavailable,
              finalJobs.filter({ $0.id != canaryID }).allSatisfy({
                  $0.state == .ready
                      && $0.attempt == 0
                      && $0.errorCode == nil
              })
        else {
            throw failure("transient circuit fanned retries across queued work")
        }
    }

    @MainActor
    private func clickZhulongSettingsButton(
        identifier: String,
        label: String,
        store: NoonmarkStore
    ) async throws {
        let settingsWindow = try await visibleSettingsWindow()
        try await activate(settingsWindow)
        try await clickSettingsSidebar(
            in: settingsWindow,
            label: store.copy.providerTitle
        )
        try await assertVisibleSettingsButton(
            identifier: identifier,
            label: label,
            in: settingsWindow
        )
        try await clickSettingsButton(
            identifier: identifier,
            label: label,
            in: settingsWindow
        )

        guard store.automaticClassificationJobRepository != nil else {
            throw failure("UI action lost its durable classification repository")
        }
    }

    @MainActor
    private func visibleSettingsWindow() async throws -> NSWindow {
        var resolved: NSWindow?
        try await waitUntil("native Settings window") {
            let matches = NSApp.windows.filter {
                $0.identifier
                    == NoonmarkSettingsWindowController.windowIdentifier
                    && $0.isVisible
                    && $0.isMiniaturized == false
                    && $0 is NSPanel == false
                    && $0.parent == nil
                    && $0.attachedSheet == nil
            }
            guard matches.count == 1, NSApp.modalWindow == nil else {
                return false
            }
            resolved = matches[0]
            return true
        }
        guard let resolved else {
            throw failure("native Settings window disappeared")
        }
        return resolved
    }

    @MainActor
    private func activate(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil("native Settings window activation") {
            NSApp.isActive
                && NSApp.keyWindow === window
                && window.isKeyWindow
                && window.isVisible
                && window.isMiniaturized == false
                && window.attachedSheet == nil
                && NSApp.modalWindow == nil
        }
    }

    @MainActor
    private func clickSettingsSidebar(
        in settingsWindow: NSWindow,
        label: String
    ) async throws {
        let identifier = "settings.sidebar.zhulong"
        try await waitUntil("visible Zhulong Settings sidebar target") {
            settingsInteractionTarget(
                identifier: identifier,
                in: settingsWindow,
                verificationText: label
            ) != nil
        }
        guard let target = settingsInteractionTarget(
            identifier: identifier,
            in: settingsWindow,
            verificationText: label
        ) else {
            throw failure("Zhulong Settings sidebar target disappeared")
        }
        guard AppViewTreeE2E.click(target) else {
            throw failure(
                "AppKit sidebar click failed for \(identifier)"
            )
        }
        NSLog("Noonmark E2E AppKit click identifier=%@", identifier)
    }

    @MainActor
    private func settingsInteractionTarget(
        identifier: String,
        in settingsWindow: NSWindow,
        verificationText: String
    ) -> NSView? {
        guard NSApp.isActive,
              NSApp.keyWindow === settingsWindow,
              settingsWindow.isKeyWindow,
              settingsWindow.isVisible,
              settingsWindow.isMiniaturized == false,
              settingsWindow.attachedSheet == nil,
              NSApp.modalWindow == nil,
              let target = AppViewTreeE2E.view(
                  identifier: identifier,
                  in: settingsWindow
              ),
              target.window === settingsWindow,
              target.isHiddenOrHasHiddenAncestor == false,
              target.alphaValue > 0,
              AppViewTreeE2E.verificationText(for: target)
              == verificationText
        else {
            return nil
        }
        let frame = target.convert(target.bounds, to: nil)
        guard frame.isNull == false,
              frame.isInfinite == false,
              frame.width >= 2,
              frame.height >= 2
        else {
            return nil
        }
        return target
    }

    @MainActor
    private func assertVisibleSettingsButton(
        identifier: String,
        label: String,
        in settingsWindow: NSWindow
    ) async throws {
        do {
            try await waitUntil("visible Settings button \(identifier)") {
                settingsInteractionTarget(
                    identifier: identifier,
                    in: settingsWindow,
                    verificationText: label
                ) != nil
            }
        } catch {
            throw failure(
                "Settings button geometry was not rendered: \(identifier)"
            )
        }
    }

    @MainActor
    private func clickSettingsButton(
        identifier: String,
        label: String,
        in settingsWindow: NSWindow
    ) async throws {
        guard let target = settingsInteractionTarget(
            identifier: identifier,
            in: settingsWindow,
            verificationText: label
        ) else {
            throw failure("Settings button frame disappeared: \(identifier)")
        }
        guard AppViewTreeE2E.click(target) else {
            throw failure(
                "AppKit button click failed for \(identifier)"
            )
        }
        NSLog("Noonmark E2E AppKit click identifier=%@", identifier)
    }

    @MainActor
    private func prepareUnconfiguredStore(
        _ store: NoonmarkStore
    ) async throws -> SQLiteAutomaticClassificationJobRepository {
        guard let repository = store.automaticClassificationJobRepository else {
            throw failure("durable job repository is unavailable")
        }
        try AutomaticClassificationDeterministicProviderE2E.clear(store)
        try await waitUntil("unconfigured Provider reconciliation") {
            try repository.providerCircuit()?.state == .unconfigured
        }
        guard store.zhulongProviderDraft.enabled == false,
              store.zhulongProviderDraft.hasStoredAPIKey == false
        else {
            throw failure("scenario did not begin without a Provider")
        }
        return repository
    }

    @MainActor
    private func prepareConfiguredStore(
        _ store: NoonmarkStore
    ) async throws -> SQLiteAutomaticClassificationJobRepository {
        let repository = try await prepareUnconfiguredStore(store)
        try AutomaticClassificationDeterministicProviderE2E.configure(store)
        try await waitUntil("configured Provider reconciliation") {
            try isClosedCircuit(repository)
        }
        return repository
    }

    @MainActor
    private func addTask(
        _ title: String,
        to store: NoonmarkStore
    ) throws -> TaskChainID {
        store.quickText = title
        store.addQuickTask()
        guard let chainID = store.engine.definitions.values.first(
            where: { $0.title == title }
        )?.chainID else {
            throw failure("scenario task was not created")
        }
        return chainID
    }

    private func assertPendingBacklog(
        chainIDs: Set<TaskChainID>,
        repository: SQLiteAutomaticClassificationJobRepository
    ) throws {
        let current = try jobs(for: chainIDs, repository: repository)
        guard current.count == chainIDs.count,
              current.allSatisfy({
                  $0.state == .waitingForConfiguration
                      && $0.dispatchAuthorization == .pendingUserDecision
                      && $0.attempt == 0
                      && $0.authorizationID == nil
                      && $0.authorizedAt == nil
              })
        else {
            throw failure("backlog was dispatched without explicit authorization")
        }
    }

    @MainActor
    private func assertHalfOpenCanary(
        request: Int,
        canaryID: UUID,
        allChainIDs: Set<TaskChainID>,
        repository: SQLiteAutomaticClassificationJobRepository,
        gateDirectory: URL
    ) async throws {
        try await waitForGateRequest(request, in: gateDirectory)
        let expectedFailureCode: AutomaticClassificationJobErrorCode
        switch request {
        case 2:
            expectedFailureCode = .providerRateLimited
        case 3:
            expectedFailureCode = .providerUnavailable
        default:
            throw failure("unexpected half-open request number")
        }
        guard let circuit = try repository.providerCircuit(),
              circuit.state == .halfOpen,
              circuit.failureCode == expectedFailureCode,
              circuit.consecutiveFailures == request - 1,
              let probe = circuit.probeFence,
              probe.jobID == canaryID,
              probe.attempt == request
        else {
            throw failure("half-open circuit did not fence its single canary")
        }
        let current = try jobs(for: allChainIDs, repository: repository)
        guard let canary = current.first(where: { $0.id == canaryID }),
              canary.state == .running,
              canary.attempt == request,
              canary.errorCode == expectedFailureCode,
              canary.fence == probe,
              current.filter({ $0.id != canaryID }).allSatisfy({
                  $0.state == .ready && $0.attempt == 0
              })
        else {
            throw failure("half-open retry escaped the original canary")
        }
    }

    private func jobs(
        for chainIDs: Set<TaskChainID>,
        repository: SQLiteAutomaticClassificationJobRepository
    ) throws -> [AutomaticClassificationJob] {
        try repository.jobs().filter { chainIDs.contains($0.chainID) }
    }

    private func isCompletedAutomaticJob(
        _ job: AutomaticClassificationJob,
        attempt: Int
    ) -> Bool {
        job.generation == 1
            && job.state == .completed
            && job.dispatchAuthorization == .automatic
            && job.authorizationID == nil
            && job.authorizedAt == nil
            && job.attempt == attempt
            && job.errorCode == nil
            && job.terminalAt != nil
    }

    private func isCompletedCatalogReplacement(
        _ jobs: [AutomaticClassificationJob],
        dispatchAuthorization: AutomaticClassificationDispatchAuthorization,
        authorizationID: UUID?,
        authorizedAt: Date?
    ) -> Bool {
        guard jobs.count == 2,
              let original = jobs.first(where: { $0.generation == 1 }),
              let replacement = jobs.first(where: { $0.generation == 2 })
        else { return false }
        return original.state == .superseded
            && original.dispatchAuthorization == dispatchAuthorization
            && original.authorizationID == authorizationID
            && original.authorizedAt == authorizedAt
            && original.attempt == 1
            && original.errorCode == .contentOrCatalogChanged
            && original.terminalAt != nil
            && replacement.state == .completed
            && replacement.dispatchAuthorization == dispatchAuthorization
            && replacement.authorizationID == authorizationID
            && replacement.authorizedAt == authorizedAt
            && replacement.attempt == 1
            && replacement.errorCode == nil
            && replacement.terminalAt != nil
    }

    private func job(
        for chainID: TaskChainID,
        repository: SQLiteAutomaticClassificationJobRepository
    ) throws -> AutomaticClassificationJob? {
        try repository.jobs().first { $0.chainID == chainID }
    }

    @MainActor
    private func hasAutomaticClassification(
        _ chainID: TaskChainID,
        store: NoonmarkStore
    ) throws -> Bool {
        guard let repository = store.repository,
              let current = try repository.load().snapshot()
              .classifications.currentByChainID[chainID],
              case .automaticAI = current.category?.source
        else { return false }
        return current.labels.contains {
            if case .automaticAI = $0.source { return true }
            return false
        }
    }

    @MainActor
    private func allHaveAutomaticClassification(
        _ chainIDs: Set<TaskChainID>,
        store: NoonmarkStore
    ) throws -> Bool {
        try chainIDs.allSatisfy {
            try hasAutomaticClassification($0, store: store)
        }
    }

    @MainActor
    private func hasUserDirectClassification(
        _ chainID: TaskChainID,
        store: NoonmarkStore
    ) throws -> Bool {
        guard let repository = store.repository,
              let current = try repository.load().snapshot()
              .classifications.currentByChainID[chainID],
              current.category?.source == .userDirect,
              current.labels.isEmpty == false,
              current.labels.allSatisfy({ $0.source == .userDirect }),
              let projection = store.currentClassification(for: chainID),
              projection.category?.name == Title.manualCategory,
              projection.labels.map(\.name) == [Title.manualLabel]
        else { return false }
        return true
    }

    private func isClosedCircuit(
        _ repository: SQLiteAutomaticClassificationJobRepository
    ) throws -> Bool {
        guard let circuit = try repository.providerCircuit() else {
            return false
        }
        return circuit.state == .closed
            && circuit.providerExecutionRevision != nil
    }

    private func isHealthyClosedCircuit(
        _ repository: SQLiteAutomaticClassificationJobRepository
    ) throws -> Bool {
        guard let circuit = try repository.providerCircuit() else {
            return false
        }
        return circuit.state == .closed
            && circuit.providerExecutionRevision != nil
            && circuit.failureCode == nil
            && circuit.consecutiveFailures == 0
            && circuit.retryAt == nil
            && circuit.probeFence == nil
    }

    @MainActor
    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 10,
        condition: @MainActor () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw failure("\(label) timed out")
    }

    @MainActor
    private func waitForFile(
        _ url: URL,
        label: String,
        timeout: TimeInterval = 15
    ) async throws {
        try await waitUntil(label, timeout: timeout) {
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    @MainActor
    private func waitForGateRequest(
        _ request: Int,
        in directory: URL
    ) async throws {
        try await waitForFile(
            directory.appendingPathComponent("request-\(request).received"),
            label: "Provider request \(request)",
            timeout: 15
        )
    }

    private func releaseGateResponse(
        _ response: Int,
        in directory: URL
    ) throws {
        try writeMarker(
            directory.appendingPathComponent("response-\(response).release")
        )
    }

    private func writeMarker(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "ok".write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeResult(_ value: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try value.write(to: resultURL, atomically: true, encoding: .utf8)
    }

    private func failure(
        _ message: String
    ) -> AutomaticClassificationDeterministicE2EError {
        .failed(message)
    }
}

@MainActor
enum AutomaticClassificationCheckpointE2EInterruption {
    static func interruptIfRequested(jobID: UUID) -> Bool {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              AppLaunchArguments.contains(
                  "--e2e-automatic-classification-checkpoint-setup"
              ),
              let resultPath = AppLaunchArguments.value(
                  after: "--e2e-automatic-classification-result-url"
              ), resultPath.isEmpty == false
        else { return false }
        let resultURL = URL(fileURLWithPath: resultPath)
        do {
            try FileManager.default.createDirectory(
                at: resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "ok".write(
                to: resultURL,
                atomically: true,
                encoding: .utf8
            )
            NSLog(
                "Noonmark E2E checkpoint interruption job=%@",
                jobID.uuidString
            )
        } catch {
            return false
        }
        E2EApplicationTermination.schedule(after: 0.05)
        return true
    }
}

private enum AutomaticClassificationDeterministicE2EError: Error {
    case failed(String)

    var message: String {
        switch self {
        case let .failed(message): message
        }
    }
}
