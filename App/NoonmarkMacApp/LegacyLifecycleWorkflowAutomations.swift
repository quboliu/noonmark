import AppKit
import Combine
import CryptoKit
import Darwin
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import NoonmarkZhulongAI
import SwiftUI
import UniformTypeIdentifiers

private func isWithinLogicalMutationEnvelope(
    _ date: Date,
    reference: Date
) -> Bool {
    date >= reference && date < reference.addingTimeInterval(1)
}

struct LifecycleE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> LifecycleE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-lifecycle-workflow") else { return nil }
        let resultURL = AppLaunchArguments.value(after: "--e2e-lifecycle-result-url")
            .map { URL(fileURLWithPath: $0) }
        return LifecycleE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            try runChangeFlow(on: store)
            try runReturnToPoolFlow(on: store)
            try runAbandonFlow(on: store)
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func runChangeFlow(on store: NoonmarkStore) throws {
        let oldTitle = "E2E 变更旧任务"
        let newTitle = "E2E 变更新任务"
        let (_, traceID) = try createScheduledTask(
            title: oldTitle,
            descriptionText: "E2E 变更路径。",
            on: store
        )
        store.selectTrace(traceID)
        store.changeText = newTitle
        store.changeSelectedTrace()
        guard let oldTrace = store.engine.traces[traceID] else {
            throw LifecycleE2EAutomationError.failed("changed source trace missing")
        }
        guard let target = store.changedTarget(for: oldTrace),
              target.definition.title == newTitle
        else {
            throw LifecycleE2EAutomationError.failed("changed target did not resolve to new task title")
        }
        store.openChangedTarget(from: oldTrace)
        guard store.selectedTraceID == target.trace.id,
              store.selectedDate == target.trace.date
        else {
            throw LifecycleE2EAutomationError.failed("changed target jump did not select new trace")
        }
    }

    @MainActor
    private func runReturnToPoolFlow(on store: NoonmarkStore) throws {
        let (_, traceID) = try createScheduledTask(
            title: "E2E 回池任务",
            descriptionText: "E2E 回池路径。",
            on: store
        )
        store.returnToPool(traceID)
    }

    @MainActor
    private func runAbandonFlow(on store: NoonmarkStore) throws {
        let (chainID, traceID) = try createScheduledTask(
            title: "E2E 废弃任务",
            descriptionText: "E2E 废弃路径。",
            on: store
        )
        let traceCount = store.engine.traces.count
        store.abandon(traceID)
        guard let item = store.engine.unfinishedPool().first(where: { $0.chain.id == chainID }),
              item.chain.state == .abandoned,
              item.unfinishedTraces.contains(where: { $0.id == traceID && $0.status == .abandoned })
        else {
            throw LifecycleE2EAutomationError.failed("abandoned chain did not remain visible in unfinished pool")
        }
        store.reactivateAbandonedChain(from: traceID)
        let interactionMoment = try store.dayContext.moment()
        guard let chain = store.engine.chains[chainID],
              let trace = store.engine.traces[traceID],
              chain.state == .active,
              trace.status == .pending,
              chain.updatedAt == trace.contentUpdatedAt,
              isWithinLogicalMutationEnvelope(
                  chain.updatedAt,
                  reference: interactionMoment.instant
              ),
              store.engine.traces.count == traceCount
        else {
            throw LifecycleE2EAutomationError.failed(
                "abandoned chain reactivation did not preserve the injected clock"
            )
        }
    }

    @MainActor
    private func createScheduledTask(
        title: String,
        descriptionText: String,
        on store: NoonmarkStore
    ) throws -> (TaskChainID, DayTraceID) {
        var timeline = try E2EFixtureTimeline(
            store: store,
            eventCount: 2
        )
        let today = timeline.today
        let chainID = try store.engine.createPoolTask(
            title: title,
            descriptionText: descriptionText,
            now: timeline.nextInstant()
        )
        let traceID = try store.engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: timeline.nextInstant()
        )
        _ = try timeline.finish()
        return (chainID, traceID)
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum LifecycleE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

struct LifecycleRestartE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains("--e2e-lifecycle-restart-verify") else {
            return nil
        }
        let resultURL = AppLaunchArguments.value(
            after: "--e2e-lifecycle-result-url"
        ).map { URL(fileURLWithPath: $0) }
        return Self(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            let definition = try required(
                store.engine.definitions.values.first {
                    $0.title == "E2E 废弃任务"
                },
                "reactivated definition was not loaded after restart"
            )
            let trace = try required(
                store.engine.traces.values.first {
                    $0.definitionID == definition.id
                },
                "reactivated trace was not loaded after restart"
            )
            let chain = try required(
                store.engine.chains[trace.chainID],
                "reactivated chain was not loaded after restart"
            )
            let interactionMoment = try store.dayContext.moment()
            guard chain.state == .active,
                  trace.status == .pending,
                  trace.settledAt == nil,
                  trace.contentUpdatedAt == chain.updatedAt,
                  isWithinLogicalMutationEnvelope(
                      chain.updatedAt,
                      reference: interactionMoment.instant
                  )
            else {
                throw LifecycleE2EAutomationError.failed(
                    "reactivated lifecycle facts or mutation clock changed after restart"
                )
            }
            let followUpDescription = "E2E 固定时钟重启修改。"
            store.updateTraceText(
                traceID: trace.id,
                descriptionText: followUpDescription
            )
            guard let updatedTrace = store.engine.traces[trace.id],
                  updatedTrace.descriptionText == followUpDescription,
                  updatedTrace.contentUpdatedAt > trace.contentUpdatedAt,
                  isWithinLogicalMutationEnvelope(
                      updatedTrace.contentUpdatedAt,
                      reference: interactionMoment.instant
                  ),
                  store.operationFailureNotice == nil,
                  try persistedSnapshot() == store.engine.snapshot()
            else {
                throw LifecycleE2EAutomationError.failed(
                    "reactivated trace rejected a later fixed-clock mutation"
                )
            }
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func required<Value>(
        _ value: Value?,
        _ message: String
    ) throws -> Value {
        guard let value else {
            throw LifecycleE2EAutomationError.failed(message)
        }
        return value
    }

    @MainActor
    private func persistedSnapshot() throws -> NoonmarkSnapshot {
        guard let databasePath = AppLaunchArguments.value(after: "--data-url") else {
            throw LifecycleE2EAutomationError.failed(
                "lifecycle restart E2E requires an explicit data URL"
            )
        }
        return try SQLiteEngineRepository(
            databaseURL: URL(fileURLWithPath: databasePath)
        ).load().snapshot()
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private struct ReactivationAtomicityE2EState: Codable {
    let baseline: NoonmarkSnapshot
    let chainID: TaskChainID
    let traceID: DayTraceID
}

struct ReactivationAtomicityE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case exerciseFailure
        case verifyRestart
    }

    private let mode: Mode?
    let stateURL: URL?
    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> Self? {
        let exercisesFailure = AppLaunchArguments.contains(
            "--e2e-reactivation-atomicity-exercise"
        )
        let verifiesRestart = AppLaunchArguments.contains(
            "--e2e-reactivation-atomicity-verify"
        )
        guard exercisesFailure || verifiesRestart else { return nil }
        let mode: Mode? = switch (exercisesFailure, verifiesRestart) {
        case (true, false): .exerciseFailure
        case (false, true): .verifyRestart
        default: nil
        }
        return Self(
            mode: mode,
            stateURL: AppLaunchArguments.value(
                after: "--e2e-reactivation-atomicity-state-url"
            ).map { URL(fileURLWithPath: $0) },
            resultURL: AppLaunchArguments.value(
                after: "--e2e-reactivation-atomicity-result-url"
            ).map { URL(fileURLWithPath: $0) }
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let mode, let stateURL, let resultURL else {
                throw LifecycleE2EAutomationError.failed(
                    "missing or conflicting reactivation atomicity arguments"
                )
            }
            switch mode {
            case .exerciseFailure:
                try exerciseFailure(on: store, stateURL: stateURL)
            case .verifyRestart:
                try verifyRestart(on: store, stateURL: stateURL)
            }
            try writeResult("ok", to: resultURL)
        } catch {
            if let resultURL {
                try? writeResult("failed: \(error.localizedDescription)", to: resultURL)
            }
        }
    }

    @MainActor
    private func exerciseFailure(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws {
        guard store.engine.chains.isEmpty,
              store.engine.definitions.isEmpty,
              store.engine.traces.isEmpty
        else {
            throw LifecycleE2EAutomationError.failed(
                "isolated reactivation atomicity database was not empty"
            )
        }

        var timeline = try E2EFixtureTimeline(
            store: store,
            eventCount: 3
        )
        let today = timeline.today
        let chainID = try store.engine.createPoolTask(
            title: "E2E 重新启用保存失败",
            now: timeline.nextInstant()
        )
        let traceID = try store.engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: timeline.nextInstant()
        )
        try store.engine.abandonChain(
            from: traceID,
            now: timeline.nextInstant()
        )
        _ = try timeline.finish()
        store.persist()
        let baseline = store.engine.snapshot()
        try baseline.validateIntegrity()
        try writeState(
            ReactivationAtomicityE2EState(
                baseline: baseline,
                chainID: chainID,
                traceID: traceID
            ),
            to: stateURL
        )

        store.clearUndoHistory()
        try store.armPersistenceFailureForE2E()
        let committed = store.reactivateAbandonedChain(from: traceID)
        store.disarmPersistenceFailureForE2E()
        guard committed == false,
              store.engine.snapshot() == baseline,
              store.toast == nil,
              store.operationFailure == AppPresentation(
                  language: store.engine.preferences.language
              ).failureMessage(for: .taskMutation),
              store.operationFailureNotice?.context == .taskMutation
        else {
            throw LifecycleE2EAutomationError.failed(
                "failed reactivation published state or success feedback"
            )
        }

        try store.armPersistenceFailureForE2E()
        store.undo()
        store.disarmPersistenceFailureForE2E()
        guard store.toast == "没有可撤销的操作" else {
            throw LifecycleE2EAutomationError.failed(
                "failed reactivation changed the undo stack"
            )
        }
        try verifyPersistedBaseline(baseline)
    }

    @MainActor
    private func verifyRestart(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws {
        let state = try readState(from: stateURL)
        guard store.engine.snapshot() == state.baseline,
              store.engine.chains[state.chainID]?.state == .abandoned,
              store.engine.traces[state.traceID]?.status == .abandoned
        else {
            throw LifecycleE2EAutomationError.failed(
                "failed reactivation changed restarted lifecycle state"
            )
        }
    }

    @MainActor
    private func verifyPersistedBaseline(_ baseline: NoonmarkSnapshot) throws {
        guard let databasePath = AppLaunchArguments.value(after: "--data-url") else {
            throw LifecycleE2EAutomationError.failed(
                "reactivation atomicity E2E requires an explicit data URL"
            )
        }
        let persisted = try SQLiteEngineRepository(
            databaseURL: URL(fileURLWithPath: databasePath)
        ).load().snapshot()
        guard persisted == baseline else {
            throw LifecycleE2EAutomationError.failed(
                "failed reactivation changed isolated SQLite state"
            )
        }
    }

    private func writeState(
        _ state: ReactivationAtomicityE2EState,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func readState(from url: URL) throws -> ReactivationAtomicityE2EState {
        try JSONDecoder().decode(
            ReactivationAtomicityE2EState.self,
            from: Data(contentsOf: url)
        )
    }

    private func writeResult(_ result: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct WorkflowE2EAutomation: LaunchAutomationRunnable {
    var title: String
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> WorkflowE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-domain-workflow") else { return nil }
        let title = AppLaunchArguments.value(after: "--e2e-workflow-title") ?? "E2E 排期延续复盘"
        let resultURL = AppLaunchArguments.value(after: "--e2e-workflow-result-url")
            .map { URL(fileURLWithPath: $0) }
        return WorkflowE2EAutomation(title: title, resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            let tomorrow = NoonmarkStore.offset(store.today, by: 1)

            store.page = .pool
            store.poolText = title
            store.addPoolTask()
            guard let chainID = store.selectedPoolChainID else {
                throw WorkflowE2EAutomationError.missing("pool chain")
            }

            store.schedulePoolTask(chainID, date: store.today)
            guard let todayTraceID = store.selectedTraceID else {
                throw WorkflowE2EAutomationError.missing("scheduled trace")
            }

            store.continueTrace(todayTraceID, to: tomorrow)
            guard store.selectedTraceID != todayTraceID else {
                throw WorkflowE2EAutomationError.missing("continued trace")
            }

            store.selectedDate = store.today
            store.updateReview(
                summary: "E2E 已完成排期、延续和复盘写入。",
                reason: "验证真实 App workflow 自动化。",
                tomorrow: "明天检查延续任务。"
            )

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum WorkflowE2EAutomationError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case let .missing(value):
            return "Workflow E2E missing: \(value)"
        }
    }
}

struct ProviderE2EAutomation: LaunchAutomationRunnable {
    var expectedName: String
    var expectedBaseURL: String
    var expectedModel: String
    var expectedAPIKey: String
    var shouldConfigure: Bool
    var shouldVerify: Bool
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> ProviderE2EAutomation? {
        let shouldConfigure = AppLaunchArguments.contains("--e2e-configure-provider")
        let shouldVerify = AppLaunchArguments.contains("--e2e-verify-provider")
        guard shouldConfigure || shouldVerify else { return nil }

        let expectedName = AppLaunchArguments.value(after: "--e2e-provider-name") ?? ""
        let expectedBaseURL = AppLaunchArguments.value(after: "--e2e-provider-base-url") ?? ""
        let expectedModel = AppLaunchArguments.value(after: "--e2e-provider-model") ?? ""
        let expectedAPIKey = AppLaunchArguments.value(after: "--e2e-provider-api-key") ?? ""
        let resultURL = AppLaunchArguments.value(after: "--e2e-provider-result-url")
            .map { URL(fileURLWithPath: $0) }

        return ProviderE2EAutomation(
            expectedName: expectedName,
            expectedBaseURL: expectedBaseURL,
            expectedModel: expectedModel,
            expectedAPIKey: expectedAPIKey,
            shouldConfigure: shouldConfigure,
            shouldVerify: shouldVerify,
            resultURL: resultURL
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            if shouldConfigure {
                try configureProvider(on: store)
            }
            if shouldVerify {
                try verifyProvider(on: store)
                store.zhulongProviderDraft = try ZhulongProviderSettingsStore.clear()
            }
            try writeResult("ok")
        } catch {
            if shouldVerify {
                store.zhulongProviderDraft = (try? ZhulongProviderSettingsStore.clear()) ?? ZhulongProviderDraft()
            }
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func configureProvider(on store: NoonmarkStore) throws {
        store.zhulongProviderDraft = try ZhulongProviderSettingsStore.clear()
        store.zhulongProviderDraft.displayName = expectedName
        store.zhulongProviderDraft.kind = .openAICompatible
        store.zhulongProviderDraft.baseURL = expectedBaseURL
        store.zhulongProviderDraft.model = expectedModel
        store.zhulongProviderDraft.apiKeyInput = expectedAPIKey
        store.zhulongProviderDraft.enabled = true
        store.zhulongProviderDraft = try ZhulongProviderSettingsStore.save(store.zhulongProviderDraft)
    }

    @MainActor
    private func verifyProvider(on store: NoonmarkStore) throws {
        let draft = store.zhulongProviderDraft
        guard draft.displayName == expectedName else {
            throw ProviderE2EAutomationError.mismatch("displayName")
        }
        guard draft.normalizedBaseURL?.absoluteString == URL(string: expectedBaseURL)?.absoluteString else {
            throw ProviderE2EAutomationError.mismatch("baseURL")
        }
        guard draft.model == expectedModel else {
            throw ProviderE2EAutomationError.mismatch("model")
        }
        guard draft.enabled else {
            throw ProviderE2EAutomationError.mismatch("enabled")
        }
        guard draft.hasStoredAPIKey else {
            throw ProviderE2EAutomationError.mismatch("hasStoredAPIKey")
        }
        guard try ZhulongProviderKeychain.readAPIKey() == expectedAPIKey else {
            throw ProviderE2EAutomationError.mismatch("apiKey")
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum ProviderE2EAutomationError: LocalizedError {
    case mismatch(String)

    var errorDescription: String? {
        switch self {
        case let .mismatch(field):
            return "Provider E2E mismatch: \(field)"
        }
    }
}
