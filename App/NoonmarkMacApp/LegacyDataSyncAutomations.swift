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

struct DataPackageE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case roundTrip
        case importPersistenceFailure
    }

    private let mode: Mode
    var exportURL: URL
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> DataPackageE2EAutomation? {
        let mode: Mode? = if AppLaunchArguments.contains("--e2e-data-package-workflow") {
            .roundTrip
        } else if AppLaunchArguments.contains("--e2e-data-package-import-failure") {
            .importPersistenceFailure
        } else {
            nil
        }
        guard let mode,
              let exportPath = AppLaunchArguments.value(after: "--e2e-data-package-url")
        else {
            return nil
        }
        let resultURL = AppLaunchArguments.value(after: "--e2e-data-package-result-url")
            .map { URL(fileURLWithPath: $0) }
        return DataPackageE2EAutomation(
            mode: mode,
            exportURL: URL(fileURLWithPath: exportPath),
            resultURL: resultURL
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                switch mode {
                case .roundTrip:
                    try await runRoundTrip(on: store)
                case .importPersistenceFailure:
                    try await runImportPersistenceFailure(on: store)
                }
                try writeResult("ok")
            } catch {
                store.disarmPersistenceFailureForE2E()
                try? writeResult("failed: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private func runRoundTrip(on store: NoonmarkStore) async throws {
        let title = "E2E 数据包任务"
        let chainID = try store.engine.createPoolTask(
            title: title,
            descriptionText: "E2E 数据包导出导入路径。"
        )
        _ = try store.engine.scheduleFromPool(
            chainID: chainID,
            date: store.today,
            today: store.today
        )
        store.updateReview(
            summary: "E2E 数据包导出前复盘。",
            reason: "验证 App 导入导出。",
            tomorrow: "导入后继续检查。"
        )
        var exportPolicy = store.engine.preferences.localFirstSyncPolicy
        exportPolicy.enabled = true
        exportPolicy.mode = .automatic
        store.engine.updateLocalFirstSyncPolicy(exportPolicy)
        var expected = store.engine.snapshot()
        expected.preferences.localFirstSyncPolicy.enabled = false

        try store.exportDataPackage(to: exportURL)
        let exportedSnapshot = try NoonmarkDataPackage.read(from: exportURL)
        guard exportedSnapshot.preferences.localFirstSyncPolicy.enabled == false else {
            throw DataPackageE2EAutomationError.failed(
                "导出的数据包携带了同步启用状态"
            )
        }

        let replacedTitle = "E2E 导入前替换任务"
        store.engine = NoonmarkEngine()
        store.poolText = replacedTitle
        store.addPoolTask()
        guard store.engine.definitions.values.contains(where: { $0.title == replacedTitle }) else {
            throw DataPackageE2EAutomationError.failed(
                "未能建立导入前的持久化替换状态"
            )
        }
        let preview = try await store.prepareDataImport(from: exportURL)
        do {
            try await store.commitDataImport(
                preview,
                confirmation: .confirmed(previewID: UUID())
            )
            throw DataPackageE2EAutomationError.failed(
                "导入在确认 token 不匹配时仍然执行"
            )
        } catch DataImportTransactionError.confirmationMismatch {
            guard store.engine.definitions.values.contains(where: {
                $0.title == replacedTitle
            }) else {
                throw DataPackageE2EAutomationError.failed(
                    "错误确认 token 改变了当前数据"
                )
            }
        }
        let beforeConcurrentCommit = store.engine.snapshot()
        try store.armDataImportCommitPauseForE2E()
        let concurrentCommit = Task { @MainActor in
            try await store.commitDataImport(
                preview,
                confirmation: .confirmed(previewID: preview.id)
            )
        }
        for _ in 0 ..< 1000 where store.isDataImportCommitPausedForE2E == false {
            await Task.yield()
        }
        guard store.isDataImportCommitPausedForE2E else {
            concurrentCommit.cancel()
            store.resumeDataImportCommitForE2E()
            _ = try? await concurrentCommit.value
            throw DataPackageE2EAutomationError.failed(
                "导入没有在独占写入门禁内进入确定性等待点"
            )
        }

        let blockedTitle = "E2E 导入等待期间不得写入"
        store.poolText = blockedTitle
        store.addPoolTask()
        guard store.engine.snapshot() == beforeConcurrentCommit,
              store.poolText == blockedTitle,
              store.engine.definitions.values.contains(where: {
                  $0.title == blockedTitle
              }) == false
        else {
            store.resumeDataImportCommitForE2E()
            _ = try? await concurrentCommit.value
            throw DataPackageE2EAutomationError.failed(
                "导入等待期间的普通 Store 写入绕过了独占门禁"
            )
        }

        store.engine = try NoonmarkEngine(snapshot: beforeConcurrentCommit)
        store.resumeDataImportCommitForE2E()
        do {
            try await concurrentCommit.value
            throw DataPackageE2EAutomationError.failed(
                "导入等待期间 engine revision 改变后仍覆盖了当前数据"
            )
        } catch DataImportTransactionError.engineChangedWhilePreparingCommit {
            guard store.engine.snapshot() == beforeConcurrentCommit else {
                throw DataPackageE2EAutomationError.failed(
                    "导入 revision 冲突改变了当前 engine"
                )
            }
        }

        let refreshedPreview = try await store.prepareDataImport(from: exportURL)
        try await store.commitDataImport(
            refreshedPreview,
            confirmation: .confirmed(previewID: refreshedPreview.id)
        )
        guard store.engine.snapshot() == expected else {
            throw DataPackageE2EAutomationError.failed(
                "导入后的完整 snapshot 与安全归一化后的导出 snapshot 不一致"
            )
        }
    }

    @MainActor
    private func runImportPersistenceFailure(on store: NoonmarkStore) async throws {
        let baselineTitle = "E2E 导入失败保留任务"
        _ = try store.engine.createPoolTask(
            title: baselineTitle,
            descriptionText: "导入写库失败后必须保留。"
        )
        store.persist()
        let baseline = store.engine.snapshot()

        let rejectedMutationTitle = "E2E 普通写入失败不得进入内存"
        store.poolText = rejectedMutationTitle
        try store.armPersistenceFailureForE2E()
        store.addPoolTask()
        store.disarmPersistenceFailureForE2E()
        guard store.engine.snapshot() == baseline,
              store.poolText == rejectedMutationTitle,
              store.engine.definitions.values.contains(where: {
                  $0.title == rejectedMutationTitle
              }) == false
        else {
            throw DataPackageE2EAutomationError.failed(
                "普通 Store 写入失败后仍改变了内存、输入或领域数据"
            )
        }
        guard let databasePath = AppLaunchArguments.value(after: "--data-url") else {
            throw DataPackageE2EAutomationError.failed(
                "原子写入失败验证缺少隔离数据库路径"
            )
        }
        let persistedAfterRejectedMutation = try SQLiteEngineRepository(
            databaseURL: URL(fileURLWithPath: databasePath)
        ).load().snapshot()
        guard persistedAfterRejectedMutation == baseline else {
            throw DataPackageE2EAutomationError.failed(
                "普通 Store 写入失败后 SQLite 与提交前基线分叉"
            )
        }

        let imported = NoonmarkEngine()
        _ = try imported.createPoolTask(
            title: "E2E 不应落盘的导入任务",
            descriptionText: "这个 snapshot 必须被整体拒绝。"
        )
        try NoonmarkDataPackage.write(imported.snapshot(), to: exportURL)

        try store.armPersistenceFailureForE2E()
        do {
            let preview = try await store.prepareDataImport(from: exportURL)
            try await store.commitDataImport(
                preview,
                confirmation: .confirmed(previewID: preview.id)
            )
            throw DataPackageE2EAutomationError.failed(
                "导入写库失败却返回成功"
            )
        } catch is PersistenceFailureE2EError {
            store.disarmPersistenceFailureForE2E()
        }

        guard store.engine.snapshot() == baseline else {
            throw DataPackageE2EAutomationError.failed(
                "导入写库失败后内存 snapshot 被替换"
            )
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

private enum DataPackageE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        }
    }
}

struct ICloudSyncE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> ICloudSyncE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-icloud-sync-live"),
              let resultPath = AppLaunchArguments.value(
                  after: "--e2e-icloud-sync-result-url"
              )
        else { return nil }
        return ICloudSyncE2EAutomation(
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard store.isICloudDriveAvailable else {
                throw ICloudSyncE2EAutomationError.failed(
                    "iCloud Drive runtime endpoint is unavailable"
                )
            }
            _ = try store.engine.createPoolTask(
                title: "E2E 真实 iCloud App 同步",
                descriptionText: "由真实 App 写入并等待系统上传。"
            )
            store.persist()
            store.setLocalFirstSyncEndpoint(.iCloud)
            store.setLocalFirstSyncMode(.manual)
            store.setLocalFirstSyncEnabled(true)
            guard store.engine.preferences.localFirstSyncPolicy.enabled else {
                throw ICloudSyncE2EAutomationError.failed(
                    "iCloud sync did not become enabled"
                )
            }
            store.syncLocalFolderNow()
            waitForCompletion(on: store)
        } catch {
            finish("failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func waitForCompletion(on store: NoonmarkStore) {
        Task { @MainActor in
            for _ in 0 ..< 300 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let syncCompleted = store.isLocalFirstSyncing == false
                    && store.localFirstSyncMessage?.hasPrefix("同步完成") == true
                if syncCompleted {
                    finish("ok")
                    return
                }
            }
            finish(
                "failed: \(store.localFirstSyncMessage ?? "iCloud sync timed out without a status")"
            )
        }
    }

    @MainActor
    private func finish(_ result: String) {
        do {
            try FileManager.default.createDirectory(
                at: resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try result.write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Noonmark iCloud E2E result write failed: %@", String(describing: error))
        }
        NSApp.terminate(nil)
    }
}

private enum ICloudSyncE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        }
    }
}

struct CloudKitSyncE2EAutomation: LaunchAutomationRunnable {
    enum Action: String {
        case upload
        case download
        case cleanup
    }

    let action: Action
    let expectedTitle: String?
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> CloudKitSyncE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-cloudkit-sync-live"),
              let actionValue = AppLaunchArguments.value(
                  after: "--e2e-cloudkit-sync-action"
              ),
              let action = Action(rawValue: actionValue),
              let resultPath = AppLaunchArguments.value(
                  after: "--e2e-cloudkit-sync-result-url"
              )
        else { return nil }
        let expectedTitle = AppLaunchArguments.value(
            after: "--e2e-cloudkit-sync-title"
        )
        guard action == .cleanup || expectedTitle?.isEmpty == false else {
            return nil
        }
        return CloudKitSyncE2EAutomation(
            action: action,
            expectedTitle: expectedTitle,
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        guard store.isCloudKitSyncConfigured else {
            finish("failed: CloudKit transport is not explicitly configured")
            return
        }
        Task { @MainActor in
            if action == .cleanup {
                do {
                    try await store.deleteCloudKitLiveValidationZone()
                    finish("ok")
                } catch {
                    finish("failed: \(error.localizedDescription)")
                }
                return
            }

            do {
                if action == .upload, let expectedTitle {
                    _ = try store.engine.createPoolTask(
                        title: expectedTitle,
                        descriptionText: "由真实签名 App 写入 CloudKit development zone。"
                    )
                    store.persist()
                }
                store.setLocalFirstSyncEndpoint(.iCloud)
                store.setLocalFirstSyncMode(.manual)
                try await store.enableCloudKitSyncAfterAccountCheck()
                guard store.engine.preferences.localFirstSyncPolicy.enabled else {
                    throw CloudKitSyncE2EAutomationError.failed(
                        "CloudKit sync did not become enabled"
                    )
                }
                store.syncLocalFolderNow()
                waitForCompletion(on: store)
            } catch {
                finish("failed: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func waitForCompletion(on store: NoonmarkStore) {
        Task { @MainActor in
            for _ in 0 ..< 600 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let syncCompleted = store.isLocalFirstSyncing == false
                    && store.localFirstSyncMessage?.hasPrefix("同步完成") == true
                guard syncCompleted else { continue }
                let downloadedRecordIsMissing = action == .download
                    && containsExpectedTitle(in: store) == false
                if downloadedRecordIsMissing {
                    finish("failed: downloaded CloudKit record was not materialized")
                    return
                }
                finish("ok")
                return
            }
            finish(
                "failed: \(store.localFirstSyncMessage ?? "CloudKit sync timed out without a status")"
            )
        }
    }

    @MainActor
    private func containsExpectedTitle(in store: NoonmarkStore) -> Bool {
        guard let expectedTitle else { return false }
        return store.engine.taskPool().contains {
            $0.definition.title == expectedTitle
        }
    }

    @MainActor
    private func finish(_ result: String) {
        do {
            try FileManager.default.createDirectory(
                at: resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try result.write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog(
                "Noonmark CloudKit E2E result write failed: %@",
                String(describing: error)
            )
        }
        NSApp.terminate(nil)
    }
}

private enum CloudKitSyncE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        }
    }
}
