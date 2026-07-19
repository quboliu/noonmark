import AppKit
import Foundation
import NoonmarkStorage
import NoonmarkZhulong

struct DataRootProcessLeaseE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case holder(releaseURL: URL)
        case probe
        case processExit
    }

    private let mode: Mode
    private let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        let holds = AppLaunchArguments.contains(
            "--e2e-hold-data-root-process-lease"
        )
        let probes = AppLaunchArguments.contains(
            "--e2e-probe-data-root-process-lease"
        )
        let exits = AppLaunchArguments.contains(
            "--e2e-_exit-data-root-process-lease"
        )
        guard [holds, probes, exits].filter(\.self).count == 1,
              let resultPath = AppLaunchArguments.value(
                  after: "--e2e-data-root-process-lease-result-url"
              ),
              resultPath.isEmpty == false
        else { return nil }
        let mode: Mode
        if holds {
            guard let releasePath = AppLaunchArguments.value(
                after: "--e2e-data-root-process-lease-release-url"
            ), releasePath.isEmpty == false else { return nil }
            mode = .holder(
                releaseURL: URL(fileURLWithPath: releasePath)
            )
        } else if exits {
            mode = .processExit
        } else {
            mode = .probe
        }
        return Self(
            mode: mode,
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                try assertHealthy(store)
                switch mode {
                case let .holder(releaseURL):
                    try writeResult("ready")
                    try await waitForRelease(at: releaseURL)
                    try assertHealthy(store)
                case .probe:
                    break
                case .processExit:
                    try writeResult("ready")
                    _exit(EX_OK)
                }
                try writeResult("ok")
            } catch {
                try? writeResult("failed: \(error.localizedDescription)")
            }
            E2EApplicationTermination.schedule()
        }
    }

    @MainActor
    private func assertHealthy(_ store: NoonmarkStore) throws {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e" else {
            throw Failure.unhealthyStore
        }
        if AppLaunchArguments.contains("--ephemeral") {
            guard store.dataRootProcessLease == nil,
                  store.repository == nil,
                  store.databaseURL == nil
            else {
                throw Failure.unhealthyStore
            }
            return
        }
        guard store.dataRootProcessLease != nil,
              let repository = store.repository,
              try repository.load().snapshot() == store.engine.snapshot()
        else {
            throw Failure.unhealthyStore
        }
        guard AppLaunchArguments.contains("--e2e-zhulong-sidecar-key") else {
            return
        }
        let journal = EncryptedFileZhulongApplicationJournal(
            directoryURL: store.zhulongSidecarDirectoryURL,
            keySource: ZhulongE2ESidecarKeySource()
        )
        guard let pending = try journal.load() else { return }
        let sessions = EncryptedFileZhulongSessionRepository(
            directoryURL: store.zhulongSidecarDirectoryURL,
            keySource: ZhulongE2ESidecarKeySource()
        )
        guard try sessions.load(pending.sessionID) == pending.beforeSession,
              store.zhulongWorkspace.sessions.contains(pending.beforeSession)
        else {
            throw Failure.unhealthyStore
        }
    }

    private func waitForRelease(at url: URL) async throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.releaseTimedOut
    }

    private func writeResult(_ value: String) throws {
        try value.write(
            to: resultURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private enum Failure: LocalizedError {
        case unhealthyStore
        case releaseTimedOut

        var errorDescription: String? {
            switch self {
            case .unhealthyStore:
                "data-root lease holder could not read its exact Store snapshot"
            case .releaseTimedOut:
                "data-root lease holder did not receive its release signal"
            }
        }
    }
}

enum DataRootLeaseConflictE2EObserver {
    static func record(_ error: Error) -> Int32? {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              let path = AppLaunchArguments.value(
                  after: "--e2e-data-root-process-lease-conflict-result-url"
              ),
              path.isEmpty == false
        else { return nil }
        let result: String
        let status: Int32
        if isExpectedConflict(error) {
            result = "ok: data-root process lease already held"
            status = EX_TEMPFAIL
        } else {
            result = "unexpected startup failure: \(String(reflecting: error))"
            status = EX_SOFTWARE
        }
        try? result.write(
            to: URL(fileURLWithPath: path),
            atomically: true,
            encoding: .utf8
        )
        return status
    }

    private static func isExpectedConflict(_ error: Error) -> Bool {
        guard let leaseError = error as? NoonmarkDataRootProcessLeaseError,
              case .alreadyHeld = leaseError
        else { return false }
        return true
    }
}
