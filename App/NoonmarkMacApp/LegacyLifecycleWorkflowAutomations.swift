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

private enum ProviderCredentialRecoveryE2EPhase {
    case interruptedSaveSetup
    case recoverOldAndPublishNew
    case recoverNewAndInterruptClear
    case recoverInterruptedClear

    static func fromCommandLine() -> Self? {
        if AppLaunchArguments.contains("--e2e-provider-credential-setup") {
            return .interruptedSaveSetup
        }
        if AppLaunchArguments.contains("--e2e-provider-credential-recover-old") {
            return .recoverOldAndPublishNew
        }
        if AppLaunchArguments.contains("--e2e-provider-credential-recover-new") {
            return .recoverNewAndInterruptClear
        }
        if AppLaunchArguments.contains("--e2e-provider-credential-recover-clear") {
            return .recoverInterruptedClear
        }
        return nil
    }
}

private struct ProviderCredentialRecoveryE2EState: Codable {
    let formatVersion: Int
    let initialExecutionRevision: UUID
    let interruptedExecutionRevision: UUID
    var replacementExecutionRevision: UUID?
}

struct ProviderE2EAutomation: LaunchAutomationRunnable {
    private static let replacementBaseURL =
        "https://replacement.provider.example/v1"
    private static let replacementAPIKey = "replacement-e2e-key"

    var expectedName: String
    var expectedBaseURL: String
    var expectedModel: String
    var expectedAPIKey: String
    var shouldConfigure: Bool
    var shouldVerify: Bool
    private var credentialRecoveryPhase: ProviderCredentialRecoveryE2EPhase?
    var credentialStateURL: URL?
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> ProviderE2EAutomation? {
        let shouldConfigure = AppLaunchArguments.contains("--e2e-configure-provider")
        let shouldVerify = AppLaunchArguments.contains("--e2e-verify-provider")
        let credentialRecoveryPhase = ProviderCredentialRecoveryE2EPhase
            .fromCommandLine()
        guard shouldConfigure || shouldVerify || credentialRecoveryPhase != nil else {
            return nil
        }

        let expectedName = AppLaunchArguments.value(after: "--e2e-provider-name") ?? ""
        let expectedBaseURL = AppLaunchArguments.value(after: "--e2e-provider-base-url") ?? ""
        let expectedModel = AppLaunchArguments.value(after: "--e2e-provider-model") ?? ""
        let expectedAPIKey = AppLaunchArguments.value(after: "--e2e-provider-api-key") ?? ""
        let credentialStateURL = AppLaunchArguments.value(
            after: "--e2e-provider-credential-state-url"
        ).map { URL(fileURLWithPath: $0) }
        let resultURL = AppLaunchArguments.value(after: "--e2e-provider-result-url")
            .map { URL(fileURLWithPath: $0) }

        return ProviderE2EAutomation(
            expectedName: expectedName,
            expectedBaseURL: expectedBaseURL,
            expectedModel: expectedModel,
            expectedAPIKey: expectedAPIKey,
            shouldConfigure: shouldConfigure,
            shouldVerify: shouldVerify,
            credentialRecoveryPhase: credentialRecoveryPhase,
            credentialStateURL: credentialStateURL,
            resultURL: resultURL
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            if let credentialRecoveryPhase {
                try runCredentialRecoveryPhase(
                    credentialRecoveryPhase,
                    on: store
                )
            }
            if shouldConfigure {
                try configureProvider(on: store)
            }
            if shouldVerify {
                try verifyProvider(on: store)
                store.zhulongProviderDraft = try ZhulongProviderSettingsStore
                    .clear().draft
            }
            try writeResult("ok")
        } catch {
            if shouldConfigure || shouldVerify || credentialRecoveryPhase != nil {
                store.zhulongProviderDraft = (try? ZhulongProviderSettingsStore
                    .clear().draft) ?? ZhulongProviderDraft()
            }
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func runCredentialRecoveryPhase(
        _ phase: ProviderCredentialRecoveryE2EPhase,
        on store: NoonmarkStore
    ) throws {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              credentialStateURL != nil
        else {
            throw ProviderE2EAutomationError.mismatch(
                "credentialRecoveryIsolation"
            )
        }
        switch phase {
        case .interruptedSaveSetup:
            try prepareInterruptedCredentialSave(on: store)
        case .recoverOldAndPublishNew:
            try recoverOldCredentialAndPublishNew(on: store)
        case .recoverNewAndInterruptClear:
            try recoverNewCredentialAndInterruptClear(on: store)
        case .recoverInterruptedClear:
            try recoverInterruptedClear(on: store)
        }
    }

    @MainActor
    private func prepareInterruptedCredentialSave(on store: NoonmarkStore) throws {
        store.zhulongProviderDraft = try ZhulongProviderSettingsStore.clear().draft
        var insecureRemote = store.zhulongProviderDraft
        insecureRemote.baseURL = "http://provider.example/v1"
        insecureRemote.model = expectedModel
        insecureRemote.enabled = true
        guard insecureRemote.normalizedBaseURL == nil else {
            throw ProviderE2EAutomationError.mismatch("remoteHTTPWasAccepted")
        }
        do {
            _ = try ZhulongProviderSettingsStore.save(insecureRemote)
            throw ProviderE2EAutomationError.mismatch("remoteHTTPWasPersisted")
        } catch ZhulongProviderSettingsError.invalidBaseURL {
            // Remote credentials must only travel over TLS.
        }
        for loopbackURL in [
            "http://localhost:8080/v1",
            "http://127.0.0.1:8080/v1",
            "http://[::1]:8080/v1"
        ] {
            var loopback = insecureRemote
            loopback.baseURL = loopbackURL
            guard loopback.normalizedBaseURL != nil else {
                throw ProviderE2EAutomationError.mismatch(
                    "loopbackHTTPWasRejected"
                )
            }
        }
        var initial = store.zhulongProviderDraft
        initial.displayName = expectedName
        initial.kind = .openAICompatible
        initial.baseURL = expectedBaseURL
        initial.model = expectedModel
        initial.apiKeyInput = expectedAPIKey
        initial.enabled = true
        let initialTransition = try ZhulongProviderSettingsStore.save(initial)

        var replacement = initialTransition.draft
        replacement.baseURL = Self.replacementBaseURL
        replacement.apiKeyInput = Self.replacementAPIKey
        var interruptedExecutionRevision: UUID?
        do {
            _ = try ZhulongProviderSettingsStore.save(
                replacement,
                afterCredentialWriteBeforeConfigPointer: { executionRevision in
                    interruptedExecutionRevision = executionRevision
                    throw ProviderE2EAutomationError.injectedInterruption
                }
            )
            throw ProviderE2EAutomationError.mismatch("interruptionNotInjected")
        } catch ProviderE2EAutomationError.injectedInterruption {
            // The injected interruption models process death after the new
            // credential is durable but before the config pointer is switched.
        }

        guard let initialExecutionRevision = initialTransition.currentExecutionRevision,
              let persisted = try ZhulongProviderSettingsStore.makePersistedConfig(),
              let persistedBaseURL = persisted.baseURL,
              persistedBaseURL.absoluteString == URL(string: expectedBaseURL)?.absoluteString,
              let keyRef = persisted.apiKeyRef,
              keyRef == ZhulongProviderKeychain.keyRef(
                  for: initialExecutionRevision
              ),
              try ZhulongProviderKeychain.resolveAPIKey(
                  keyRef,
                  expectedExecutionRevision: initialExecutionRevision
              ) == expectedAPIKey,
              let interruptedExecutionRevision,
              try ZhulongProviderKeychain.readAPIKey(
                  for: interruptedExecutionRevision
              ) == Self.replacementAPIKey,
              try ZhulongProviderSettingsStore.makePersistedConfig(
                  expectedExecutionRevision: interruptedExecutionRevision
              ) == nil,
              try ZhulongProviderKeychain.resolveAPIKey(
                  keyRef,
                  expectedExecutionRevision: interruptedExecutionRevision
              ) == nil,
              try ZhulongProviderKeychain.resolveAPIKey(
                  ZhulongProviderKeychain.keyRef(
                      for: interruptedExecutionRevision
                  ),
                  expectedExecutionRevision: initialExecutionRevision
              ) == nil
        else {
            throw ProviderE2EAutomationError.mismatch(
                "interruptedCredentialWasPairedWithOldEndpoint"
            )
        }
        try writeCredentialRecoveryState(
            ProviderCredentialRecoveryE2EState(
                formatVersion: 1,
                initialExecutionRevision: initialExecutionRevision,
                interruptedExecutionRevision: interruptedExecutionRevision,
                replacementExecutionRevision: nil
            )
        )
    }

    @MainActor
    private func recoverOldCredentialAndPublishNew(
        on store: NoonmarkStore
    ) throws {
        var state = try readCredentialRecoveryState()
        guard state.formatVersion == 1,
              store.zhulongProviderDraft.normalizedBaseURL?.absoluteString
              == URL(string: expectedBaseURL)?.absoluteString,
              store.zhulongProviderDraft.hasStoredAPIKey,
              try ZhulongProviderKeychain.readAPIKey(
                  for: state.initialExecutionRevision
              ) == expectedAPIKey,
            try ZhulongProviderKeychain.readAPIKey(
                for: state.interruptedExecutionRevision
            ) == nil,
              let persisted = try ZhulongProviderSettingsStore.makePersistedConfig(
                  expectedExecutionRevision: state.initialExecutionRevision
              ),
              persisted.apiKeyRef == ZhulongProviderKeychain.keyRef(
                  for: state.initialExecutionRevision
              )
        else {
            throw ProviderE2EAutomationError.mismatch(
                "freshLaunchDidNotRecoverOldCredential"
            )
        }

        var replacement = store.zhulongProviderDraft
        replacement.baseURL = Self.replacementBaseURL
        replacement.apiKeyInput = Self.replacementAPIKey
        var replacementExecutionRevision: UUID?
        do {
            _ = try ZhulongProviderSettingsStore.save(
                replacement,
                afterConfigPointerPublication: { executionRevision in
                    replacementExecutionRevision = executionRevision
                    throw ProviderE2EAutomationError.injectedInterruption
                }
            )
            throw ProviderE2EAutomationError.mismatch(
                "pointerPublicationInterruptionNotInjected"
            )
        } catch ProviderE2EAutomationError.injectedInterruption {
            // This process exits with a published new pointer and both revisions
            // still present. A fresh launch is solely responsible for cleanup.
        }
        guard let replacementExecutionRevision,
              replacementExecutionRevision != state.initialExecutionRevision,
              replacementExecutionRevision != state.interruptedExecutionRevision,
              ZhulongProviderSettingsStore.persistedConfiguredExecutionRevision()
              == replacementExecutionRevision,
              try ZhulongProviderKeychain.readAPIKey(
                  for: state.initialExecutionRevision
              ) == expectedAPIKey,
              try ZhulongProviderKeychain.readAPIKey(
                  for: replacementExecutionRevision
              ) == Self.replacementAPIKey
        else {
            throw ProviderE2EAutomationError.mismatch(
                "newCredentialWasNotPublishedBeforeDeferredCleanup"
            )
        }
        state.replacementExecutionRevision = replacementExecutionRevision
        try writeCredentialRecoveryState(state)
    }

    @MainActor
    private func recoverNewCredentialAndInterruptClear(
        on store: NoonmarkStore
    ) throws {
        let state = try readCredentialRecoveryState()
        guard let replacementExecutionRevision = state.replacementExecutionRevision,
              store.zhulongProviderDraft.normalizedBaseURL?.absoluteString
              == URL(string: Self.replacementBaseURL)?.absoluteString,
              store.zhulongProviderDraft.hasStoredAPIKey,
              try ZhulongProviderKeychain.readAPIKey(
                  for: state.initialExecutionRevision
              ) == nil,
              try ZhulongProviderKeychain.readAPIKey(
                  for: state.interruptedExecutionRevision
              ) == nil,
              try ZhulongProviderKeychain.readAPIKey(
                  for: replacementExecutionRevision
              ) == Self.replacementAPIKey,
              try ZhulongProviderSettingsStore.makePersistedConfig(
                  expectedExecutionRevision: replacementExecutionRevision
              )?.apiKeyRef == ZhulongProviderKeychain.keyRef(
                  for: replacementExecutionRevision
              )
        else {
            throw ProviderE2EAutomationError.mismatch(
                "freshLaunchDidNotRecoverNewCredential"
            )
        }

        var interruptionReached = false
        do {
            _ = try ZhulongProviderSettingsStore.clear(
                afterCredentialRemovalBeforeConfigPointer: {
                    interruptionReached = true
                    throw ProviderE2EAutomationError.injectedInterruption
                }
            )
            throw ProviderE2EAutomationError.mismatch(
                "clearInterruptionNotInjected"
            )
        } catch ProviderE2EAutomationError.injectedInterruption {
            // A failed clear keeps the non-sensitive pointer for retry, but the
            // credential has already been removed and cannot be dispatched.
        }
        let recoveredDraft = ZhulongProviderSettingsStore.load()
        guard interruptionReached,
              try ZhulongProviderKeychain.hasAnyAPIKey() == false,
              recoveredDraft.enabled,
              recoveredDraft.hasStoredAPIKey == false,
              ZhulongProviderSettingsStore.persistedConfiguredExecutionRevision()
              == replacementExecutionRevision,
              try ZhulongProviderSettingsStore.makePersistedConfig() == nil
        else {
            throw ProviderE2EAutomationError.mismatch(
                "interruptedClearWasNotFailClosed"
            )
        }
    }

    @MainActor
    private func recoverInterruptedClear(on store: NoonmarkStore) throws {
        let state = try readCredentialRecoveryState()
        guard let replacementExecutionRevision = state.replacementExecutionRevision,
              store.zhulongProviderDraft.enabled,
              store.zhulongProviderDraft.hasStoredAPIKey == false,
              try ZhulongProviderKeychain.hasAnyAPIKey() == false,
              ZhulongProviderSettingsStore.persistedConfiguredExecutionRevision()
              == replacementExecutionRevision,
              try ZhulongProviderSettingsStore.makePersistedConfig() == nil
        else {
            throw ProviderE2EAutomationError.mismatch(
                "freshLaunchDidNotRecoverInterruptedClear"
            )
        }

        store.zhulongProviderDraft = try ZhulongProviderSettingsStore.clear().draft
        guard try ZhulongProviderKeychain.hasAnyAPIKey() == false,
              ZhulongProviderSettingsStore.persistedConfiguredExecutionRevision() == nil
        else {
            throw ProviderE2EAutomationError.mismatch(
                "explicitClearLeftProviderState"
            )
        }

        let retainedExecutionRevision = UUID()
        try ZhulongProviderKeychain.saveAPIKey(
            "retained-e2e-key",
            for: retainedExecutionRevision
        )
        _ = ZhulongProviderSettingsStore.load()
        guard try ZhulongProviderKeychain.readAPIKey(
            for: retainedExecutionRevision
        ) == "retained-e2e-key"
        else {
            throw ProviderE2EAutomationError.mismatch(
                "cleanCutCredentialWasDeletedWithoutConfig"
            )
        }
        store.zhulongProviderDraft = try ZhulongProviderSettingsStore.clear().draft
        guard try ZhulongProviderKeychain.hasAnyAPIKey() == false else {
            throw ProviderE2EAutomationError.mismatch(
                "explicitClearLeftRetainedCredential"
            )
        }
    }

    private func readCredentialRecoveryState() throws
        -> ProviderCredentialRecoveryE2EState
    {
        guard let credentialStateURL else {
            throw ProviderE2EAutomationError.mismatch(
                "credentialRecoveryStateURL"
            )
        }
        return try JSONDecoder().decode(
            ProviderCredentialRecoveryE2EState.self,
            from: Data(contentsOf: credentialStateURL)
        )
    }

    private func writeCredentialRecoveryState(
        _ state: ProviderCredentialRecoveryE2EState
    ) throws {
        guard let credentialStateURL else {
            throw ProviderE2EAutomationError.mismatch(
                "credentialRecoveryStateURL"
            )
        }
        try FileManager.default.createDirectory(
            at: credentialStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: credentialStateURL, options: .atomic)
    }

    @MainActor
    private func configureProvider(on store: NoonmarkStore) throws {
        store.zhulongProviderDraft = try ZhulongProviderSettingsStore.clear().draft
        store.zhulongProviderDraft.displayName = expectedName
        store.zhulongProviderDraft.kind = .openAICompatible
        store.zhulongProviderDraft.baseURL = expectedBaseURL
        store.zhulongProviderDraft.model = expectedModel
        store.zhulongProviderDraft.apiKeyInput = expectedAPIKey
        store.zhulongProviderDraft.enabled = true
        let firstSave = try ZhulongProviderSettingsStore.save(
            store.zhulongProviderDraft
        )
        guard firstSave.revisionChanged,
              firstSave.readinessChanged,
              firstSave.currentReadiness
        else {
            throw ProviderE2EAutomationError.mismatch("initialTransition")
        }
        store.zhulongProviderDraft = firstSave.draft

        var sameKeyDraft = store.zhulongProviderDraft
        sameKeyDraft.apiKeyInput = expectedAPIKey
        let sameSave = try ZhulongProviderSettingsStore.save(sameKeyDraft)
        guard sameSave.revisionChanged == false,
              sameSave.readinessChanged == false,
              sameSave.previousExecutionRevision
              == firstSave.currentExecutionRevision,
              sameSave.currentExecutionRevision
              == firstSave.currentExecutionRevision
        else {
            throw ProviderE2EAutomationError.mismatch("sameConfigTransition")
        }

        var renamedDraft = sameSave.draft
        renamedDraft.displayName += " E2E renamed"
        let renamed = try ZhulongProviderSettingsStore.save(renamedDraft)
        guard renamed.revisionChanged == false,
              renamed.readinessChanged == false
        else {
            throw ProviderE2EAutomationError.mismatch("displayNameTransition")
        }
        var restoredNameDraft = renamed.draft
        restoredNameDraft.displayName = expectedName
        let restoredName = try ZhulongProviderSettingsStore.save(
            restoredNameDraft
        )
        guard restoredName.revisionChanged == false else {
            throw ProviderE2EAutomationError.mismatch("restoredNameTransition")
        }

        var movedEndpointDraft = restoredName.draft
        movedEndpointDraft.baseURL = "https://moved.provider.example/v1"
        let movedEndpoint = try ZhulongProviderSettingsStore.save(
            movedEndpointDraft
        )
        guard movedEndpoint.revisionChanged,
              movedEndpoint.readinessChanged == false,
              let firstExecutionRevision = firstSave.currentExecutionRevision,
              let movedEndpointRevision = movedEndpoint.currentExecutionRevision,
              try ZhulongProviderKeychain.readAPIKey(
                  for: firstExecutionRevision
              ) == expectedAPIKey,
              try ZhulongProviderKeychain.readAPIKey(
                  for: movedEndpointRevision
              ) == expectedAPIKey
        else {
            throw ProviderE2EAutomationError.mismatch("movedEndpointTransition")
        }
        var restoredEndpointDraft = movedEndpoint.draft
        restoredEndpointDraft.baseURL = expectedBaseURL
        let restoredEndpoint = try ZhulongProviderSettingsStore.save(
            restoredEndpointDraft
        )
        guard restoredEndpoint.revisionChanged,
              restoredEndpoint.readinessChanged == false,
              try ZhulongProviderKeychain.readAPIKey(
                  for: movedEndpointRevision
              ) == expectedAPIKey
        else {
            throw ProviderE2EAutomationError.mismatch("restoredEndpointTransition")
        }

        var replacementKeyDraft = restoredEndpoint.draft
        replacementKeyDraft.apiKeyInput = "\(expectedAPIKey)-replacement"
        let replacementKey = try ZhulongProviderSettingsStore.save(
            replacementKeyDraft
        )
        guard replacementKey.revisionChanged,
              replacementKey.readinessChanged == false,
              let replacementExecutionRevision = replacementKey.currentExecutionRevision,
              try ZhulongProviderKeychain.readAPIKey(
                  for: firstExecutionRevision
              ) == expectedAPIKey,
              try ZhulongProviderKeychain.readAPIKey(
                  for: replacementExecutionRevision
              ) == "\(expectedAPIKey)-replacement"
        else {
            throw ProviderE2EAutomationError.mismatch("replacementKeyTransition")
        }
        var restoredKeyDraft = replacementKey.draft
        restoredKeyDraft.apiKeyInput = expectedAPIKey
        let restoredKey = try ZhulongProviderSettingsStore.save(
            restoredKeyDraft
        )
        guard restoredKey.revisionChanged,
              restoredKey.readinessChanged == false,
              let restoredExecutionRevision = restoredKey.currentExecutionRevision,
              try ZhulongProviderKeychain.readAPIKey(
                  for: replacementExecutionRevision
              ) == "\(expectedAPIKey)-replacement",
              try ZhulongProviderKeychain.readAPIKey(
                  for: restoredExecutionRevision
              ) == expectedAPIKey
        else {
            throw ProviderE2EAutomationError.mismatch("restoredKeyTransition")
        }

        var disabledDraft = restoredKey.draft
        disabledDraft.enabled = false
        let disabled = try ZhulongProviderSettingsStore.save(disabledDraft)
        guard disabled.revisionChanged == false,
              disabled.previousReadiness,
              disabled.currentReadiness == false
        else {
            throw ProviderE2EAutomationError.mismatch("disabledTransition")
        }

        var enabledDraft = disabled.draft
        enabledDraft.enabled = true
        let enabled = try ZhulongProviderSettingsStore.save(enabledDraft)
        guard enabled.revisionChanged == false,
              enabled.previousReadiness == false,
              enabled.currentReadiness,
              enabled.currentExecutionRevision
              == restoredKey.currentExecutionRevision
        else {
            throw ProviderE2EAutomationError.mismatch("enabledTransition")
        }
        store.zhulongProviderDraft = enabled.draft

        guard let persisted = UserDefaults.standard.data(
            forKey: "noonmark.zhulong.provider.config"
        ), let object = try JSONSerialization.jsonObject(with: persisted)
            as? [String: Any],
            Set(object.keys) == [
                "baseURL", "displayName", "enabled", "executionRevision",
                "kind", "model"
            ],
            persisted.range(of: Data(expectedAPIKey.utf8)) == nil
        else {
            throw ProviderE2EAutomationError.mismatch("nonSensitivePersistence")
        }
    }

    @MainActor
    private func verifyProvider(on store: NoonmarkStore) throws {
        guard ZhulongProviderKeychain.serviceIdentifier
            == "app.noonmark.zhulong.provider.e2e"
        else {
            throw ProviderE2EAutomationError.mismatch("isolatedKeychainService")
        }
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
        guard let persisted = try ZhulongProviderSettingsStore.makePersistedConfig(),
              persisted.capabilities.supportsStreaming,
              let keyRef = persisted.apiKeyRef,
              try ZhulongProviderKeychain.resolveAPIKey(keyRef) == expectedAPIKey
        else {
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
    case injectedInterruption

    var errorDescription: String? {
        switch self {
        case let .mismatch(field):
            return "Provider E2E mismatch: \(field)"
        case .injectedInterruption:
            return "Provider E2E injected interruption"
        }
    }
}
