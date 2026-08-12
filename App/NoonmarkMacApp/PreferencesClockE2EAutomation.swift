import AppKit
import ApplicationServices
import Foundation
import NoonmarkCore
import NoonmarkStorage

/// Drives the native Settings controls and the V2 replication lifecycle in a
/// signed, isolated App. V1 status metadata and transports are intentionally
/// absent: durable state is read only through `LocalFirstReplication`.
@MainActor
struct PreferencesClockE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case setup
        case exercise
        case verifyRestart
    }

    private struct ProbeState: Codable {
        let formatVersion: Int
        let initialClockBits: UInt64
        var themeClockBits: UInt64?
        var languageClockBits: UInt64?
        var failureIncidentCleared: Bool
        var disabledWorkerPersisted: Bool
    }

    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): message
            }
        }
    }

    private static let e2eBundleIdentifier = "app.noonmark.mac.e2e"
    private static let formatVersion = 3
    private static let initialTheme = AppTheme.warmPaper
    private static let initialLanguage = AppLanguage.english
    private static let finalTheme = AppTheme.coolGray
    private static let finalLanguage = AppLanguage.chinese
    private static let localPoemText =
        "E2E local-only preference sentinel 6049"
    private static let themeIdentifier = "settings.preferences.theme"
    private static let languageIdentifier = "settings.preferences.language"
    private static let poemIdentifier = "settings.preferences.poem.enabled"
    private static let syncEnabledIdentifier = "settings.sync.enabled"

    private let mode: Mode
    private let stateURL: URL
    private let resultURL: URL
    private let databaseURL: URL
    private let syncFolderURL: URL

    static func fromCommandLine() -> Self? {
        guard Bundle.main.bundleIdentifier == e2eBundleIdentifier else {
            return nil
        }
        let mode: Mode
        if AppLaunchArguments.contains("--e2e-preferences-clock-setup") {
            mode = .setup
        } else if AppLaunchArguments.contains(
            "--e2e-preferences-clock-exercise"
        ) {
            mode = .exercise
        } else if AppLaunchArguments.contains(
            "--e2e-preferences-clock-verify"
        ) {
            mode = .verifyRestart
        } else {
            return nil
        }
        guard let statePath = AppLaunchArguments.value(
            after: "--e2e-preferences-clock-state-url"
        ), let resultPath = AppLaunchArguments.value(
            after: "--e2e-preferences-clock-result-url"
        ), let databasePath = AppLaunchArguments.value(after: "--data-url"),
            let syncFolderPath = AppLaunchArguments.value(
                after: "--sync-folder-url"
            )
        else {
            return nil
        }
        return Self(
            mode: mode,
            stateURL: URL(fileURLWithPath: statePath),
            resultURL: URL(fileURLWithPath: resultPath),
            databaseURL: URL(fileURLWithPath: databasePath),
            syncFolderURL: URL(
                fileURLWithPath: syncFolderPath,
                isDirectory: true
            )
        )
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                switch mode {
                case .setup:
                    try await setup(on: store)
                case .exercise:
                    try await exercise(on: store)
                case .verifyRestart:
                    try await verifyRestart(on: store)
                }
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? appendTrace(
                    "failure mode=\(mode) type=\(String(describing: type(of: error)))"
                )
                try? writeResult("failed: \(error.localizedDescription)")
            }
            E2EApplicationTermination.schedule()
        }
    }

    private func setup(on store: NoonmarkStore) async throws {
        try validateIsolation()
        try? FileManager.default.removeItem(at: traceURL)
        guard store.engine.preferences.theme == Self.finalTheme,
              store.engine.preferences.language == Self.finalLanguage,
              store.operationFailureNotice == nil
        else {
            throw Failure.failed(
                "preference V2 setup did not start from an isolated database"
            )
        }

        store.setSettingsPoemText(Self.localPoemText)
        store.setSettingsPoemEnabled(true)
        store.setTheme(Self.initialTheme)
        store.setLanguage(Self.initialLanguage)
        store.setLocalFirstSyncEndpoint(.localFolder)
        store.setLocalFirstSyncMode(.manual)
        store.setLocalFirstSyncEnabled(true)
        let initialClock = store.engine.preferences.themeLanguageUpdatedAt
        try assertPreferences(
            in: store,
            theme: Self.initialTheme,
            language: Self.initialLanguage,
            clock: initialClock,
            poemEnabled: true
        )
        try await requireConfiguredRuntime(on: store)
        let baseline = try await runSync(on: store)
        guard baseline.convergence == .converged,
              baseline.incident == nil,
              baseline.pendingLocalPublicationCount == 0,
              baseline.lastSyncedAt != nil,
              baseline.lastEffectiveSyncedAt != nil
        else {
            throw Failure.failed(
                "preference V2 setup baseline did not converge"
            )
        }
        try writeState(
            ProbeState(
                formatVersion: Self.formatVersion,
                initialClockBits: exactBits(initialClock),
                themeClockBits: nil,
                languageClockBits: nil,
                failureIncidentCleared: false,
                disabledWorkerPersisted: false
            )
        )
        try appendTrace(
            "setup v2 baseline=converged initial=\(exactBits(initialClock))"
        )
    }

    private func exercise(on store: NoonmarkStore) async throws {
        try validateIsolation()
        var state = try readState()
        guard state.formatVersion == Self.formatVersion,
              state.themeClockBits == nil,
              state.languageClockBits == nil,
              state.failureIncidentCleared == false,
              state.disabledWorkerPersisted == false
        else {
            throw Failure.failed("preference V2 setup state is stale")
        }
        let initialClock = date(from: state.initialClockBits)
        try assertPreferences(
            in: store,
            theme: Self.initialTheme,
            language: Self.initialLanguage,
            clock: initialClock,
            poemEnabled: true
        )
        try await requireConfiguredRuntime(on: store)
        guard let lifecycleEndpoint =
            store.localFirstReplicationLifecycleE2EEndpoint
        else {
            throw Failure.failed("V2 lifecycle E2E endpoint is unavailable")
        }

        let settingsWindow = try await visibleSettingsWindow()
        try await activate(settingsWindow)
        let input = try WindowServerInputDriver()
        let themeClock = nextRepresentableDate(after: initialClock)
        try await clickLeftSegment(
            identifier: Self.themeIdentifier,
            expectedWindow: settingsWindow,
            input: input,
            beforeClock: initialClock
        )
        try await waitUntil("theme click did not advance the exact clock") {
            store.engine.preferences.theme == Self.finalTheme
                && store.engine.preferences.language == Self.initialLanguage
                && hasSameBits(
                    store.engine.preferences.themeLanguageUpdatedAt,
                    themeClock
                )
        }

        let languageClock = nextRepresentableDate(after: themeClock)
        try await clickLeftSegment(
            identifier: Self.languageIdentifier,
            expectedWindow: settingsWindow,
            input: input,
            beforeClock: themeClock
        )
        try await waitUntil("language click did not advance the exact clock") {
            store.engine.preferences.theme == Self.finalTheme
                && store.engine.preferences.language == Self.finalLanguage
                && hasSameBits(
                    store.engine.preferences.themeLanguageUpdatedAt,
                    languageClock
                )
        }
        try await clickCheckbox(
            identifier: Self.poemIdentifier,
            expectedWindow: settingsWindow,
            input: input,
            beforeClock: languageClock
        )
        try await waitUntil("local-only poem checkbox did not turn off") {
            store.engine.preferences.settingsPoemDisplayPolicy.enabled == false
        }
        try assertPreferences(
            in: store,
            theme: Self.finalTheme,
            language: Self.finalLanguage,
            clock: languageClock,
            poemEnabled: false
        )

        let authority = try requireAuthority()
        let pendingBeforeSync = try SQLiteReplicationLedger(
            databaseURL: databaseURL
        ).outboxSnapshot(generationID: authority.generationID)
        guard pendingBeforeSync.pendingCount == 2 else {
            throw Failure.failed(
                "shared preference input did not create exactly two V2 outbox facts"
            )
        }
        let converged = try await runSync(on: store)
        guard converged.convergence == .converged,
              converged.incident == nil,
              converged.pendingLocalPublicationCount == 0,
              converged.lastSyncedAt != nil,
              converged.lastEffectiveSyncedAt != nil
        else {
            throw Failure.failed("shared preferences did not converge through V2")
        }
        try await showSyncStatus(
            in: settingsWindow,
            input: input,
            beforeClock: languageClock,
            state: converged
        )

        guard await lifecycleEndpoint.armReadFailure() else {
            throw Failure.failed("V2 read failure seam could not be armed")
        }
        store.syncLocalFolderNow()
        guard let failedCommand = store.localFirstReplicationCommandTask else {
            throw Failure.failed("V2 failure reconcile did not start")
        }
        _ = await failedCommand.result
        try await waitUntil("V2 failure did not reach the Store") {
            guard let persisted = try LocalFirstReplication.persistedState(
                databaseURL: databaseURL
            ) else { return false }
            return persisted.worker == .idle
                && persisted.convergence == .blocked
                && persisted.incident == .runtimeFailure
                && store.operationFailureNotice?.context == .sync
        }
        try appendTrace(
            "sync v2 failure incident=runtimeFailure warning=visible"
        )

        guard await lifecycleEndpoint.armBlockingRead() else {
            throw Failure.failed("V2 blocking read seam could not be armed")
        }
        store.syncLocalFolderNow()
        guard let blockedCommand = store.localFirstReplicationCommandTask else {
            throw Failure.failed("V2 blocked reconcile did not start")
        }
        try await waitUntil("V2 reconcile did not enter blocked read") {
            await lifecycleEndpoint.isReadBlocked()
        }
        let poolCountBefore = store.engine.taskPoolCount()
        store.poolText = "Replication V2 lifecycle E2E mutation"
        store.addPoolTask()
        guard store.poolText.isEmpty,
              store.engine.taskPoolCount() == poolCountBefore + 1
        else {
            throw Failure.failed(
                "ordinary mutation was rejected while V2 waited on endpoint I/O"
            )
        }

        try await clickCheckbox(
            identifier: Self.syncEnabledIdentifier,
            expectedWindow: settingsWindow,
            input: input,
            beforeClock: languageClock
        )
        try await waitUntil("V2 disable did not enter cancel and join") {
            await lifecycleEndpoint.hasCancelStarted()
                && store.engine.preferences.localFirstSyncPolicy.enabled == false
                && store.isLocalFirstSyncStopping
        }
        try appendTrace(
            "sync v2 task-mutation=allowed checkbox-disable=stopping join=held"
        )
        await lifecycleEndpoint.releaseJoin()
        _ = await blockedCommand.result
        await settleConfiguration(on: store)
        try await waitUntil("V2 disable did not finish durably") {
            guard let persisted = try LocalFirstReplication.persistedState(
                databaseURL: databaseURL
            ) else { return false }
            return persisted.worker == .disabled
                && persisted.incident == nil
                && store.engine.preferences.localFirstSyncPolicy.enabled == false
                && store.isLocalFirstSyncing == false
                && store.isLocalFirstSyncStopping == false
                && store.operationFailureNotice == nil
        }

        state.themeClockBits = exactBits(themeClock)
        state.languageClockBits = exactBits(languageClock)
        state.failureIncidentCleared = true
        state.disabledWorkerPersisted = true
        try writeState(state)
        try appendTrace(
            "sync v2 disabled worker=disabled incident=cleared warning=suppressed"
        )
    }

    private func verifyRestart(on store: NoonmarkStore) async throws {
        try validateIsolation()
        let state = try readState()
        guard state.formatVersion == Self.formatVersion,
              let themeClockBits = state.themeClockBits,
              let languageClockBits = state.languageClockBits,
              state.failureIncidentCleared,
              state.disabledWorkerPersisted,
              themeClockBits > state.initialClockBits,
              languageClockBits > themeClockBits
        else {
            throw Failure.failed("preference V2 exercise state is incomplete")
        }
        let languageClock = date(from: languageClockBits)
        try assertPreferences(
            in: store,
            theme: Self.finalTheme,
            language: Self.finalLanguage,
            clock: languageClock,
            poemEnabled: false
        )
        guard let restored = try LocalFirstReplication.persistedState(
            databaseURL: databaseURL
        ), restored.worker == .disabled,
        restored.incident == nil,
        store.engine.preferences.localFirstSyncPolicy.enabled == false,
        store.operationFailureNotice == nil,
        AppViewTreeE2E.view(identifier: "settings.operation-failure") == nil
        else {
            throw Failure.failed(
                "disabled V2 restart replayed an historical failure warning"
            )
        }

        let settingsWindow = try await visibleSettingsWindow()
        try await activate(settingsWindow)
        let input = try WindowServerInputDriver()
        try await clickElement(
            identifier: "settings.sidebar.sync",
            expectedWindow: settingsWindow,
            input: input,
            beforeClock: languageClock
        )
        try await clickCheckbox(
            identifier: Self.syncEnabledIdentifier,
            expectedWindow: settingsWindow,
            input: input,
            beforeClock: languageClock
        )
        try await requireConfiguredRuntime(on: store)
        guard store.engine.preferences.localFirstSyncPolicy.enabled else {
            throw Failure.failed("V2 sync could not be re-enabled after restart")
        }
        let retried = try await runSync(on: store)
        guard retried.worker == .idle,
              retried.convergence == .converged,
              retried.incident == nil,
              retried.pendingLocalPublicationCount == 0,
              store.operationFailureNotice == nil
        else {
            throw Failure.failed(
                "re-enabled V2 sync did not clear the historical incident"
            )
        }
        try appendTrace(
            "sync v2 restart worker=disabled warning=suppressed "
                + "policy=disabled reenabled=true retry=converged"
        )
        try AppE2EScreenshot.captureContent(
            of: settingsWindow,
            to: resultURL.deletingLastPathComponent()
                .appendingPathComponent("sync-v2-lifecycle.png")
        )
    }

    private func requireConfiguredRuntime(on store: NoonmarkStore) async throws {
        await settleConfiguration(on: store)
        guard store.localFirstReplicationRuntime != nil else {
            throw Failure.failed("V2 replication runtime did not settle")
        }
    }

    private func settleConfiguration(on store: NoonmarkStore) async {
        for _ in 0 ..< 8 {
            guard let task = store.localFirstReplicationConfigurationTask else {
                await Task.yield()
                continue
            }
            _ = await task.result
            await Task.yield()
        }
    }

    private func runSync(
        on store: NoonmarkStore
    ) async throws -> LocalFirstReplicationState {
        store.syncLocalFolderNow()
        guard let command = store.localFirstReplicationCommandTask else {
            throw Failure.failed("V2 manual reconcile did not start")
        }
        _ = await command.result
        guard let state = try LocalFirstReplication.persistedState(
            databaseURL: databaseURL
        ), store.isLocalFirstSyncing == false
        else {
            throw Failure.failed("V2 manual reconcile did not persist state")
        }
        guard store.operationFailureNotice == nil else {
            throw Failure.failed(
                "V2 manual reconcile surfaced failure kind="
                    + (store.localFirstReplicationLastErrorKind ?? "unknown")
            )
        }
        return state
    }

    private func requireAuthority() throws
        -> SQLiteReplicationCleanCutAuthority
    {
        guard let authority = try SQLiteReplicationLedger(
            databaseURL: databaseURL
        ).cleanCutAuthority() else {
            throw Failure.failed("V2 clean-cut authority is missing")
        }
        return authority
    }

    private func showSyncStatus(
        in settingsWindow: NSWindow,
        input: WindowServerInputDriver,
        beforeClock: Date,
        state: LocalFirstReplicationState
    ) async throws {
        try await clickElement(
            identifier: "settings.sidebar.sync",
            expectedWindow: settingsWindow,
            input: input,
            beforeClock: beforeClock
        )
        try await waitUntil("V2 sync timestamps were not rendered") {
            guard state.lastSyncedAt != nil,
                  state.lastEffectiveSyncedAt != nil,
                  AppViewTreeE2E.view(
                      identifier: "settings.sync.latest-timestamp",
                      in: settingsWindow
                  ) != nil,
                  AppViewTreeE2E.view(
                      identifier: "settings.sync.latest-effective-timestamp",
                      in: settingsWindow
                  ) != nil
            else { return false }
            return true
        }
        try AppE2EScreenshot.captureContent(
            of: settingsWindow,
            to: resultURL.deletingLastPathComponent()
                .appendingPathComponent("sync-v2-status.png")
        )
        try appendTrace(
            "sync v2 pending=0 converged=true timestamps=true"
        )
    }

    private func assertPreferences(
        in store: NoonmarkStore,
        theme: AppTheme,
        language: AppLanguage,
        clock: Date,
        poemEnabled: Bool
    ) throws {
        let preferences = store.engine.preferences
        guard preferences.theme == theme,
              preferences.language == language,
              hasSameBits(preferences.themeLanguageUpdatedAt, clock),
              preferences.settingsPoemDisplayPolicy.enabled == poemEnabled,
              preferences.settingsPoemDisplayPolicy.text == Self.localPoemText,
              preferences.localFirstSyncPolicy.endpoint == .localFolder,
              preferences.localFirstSyncPolicy.mode == .manual
        else {
            throw Failure.failed("preference V2 state diverged")
        }
    }

    private func visibleSettingsWindow() async throws -> NSWindow {
        var settingsWindow: NSWindow?
        try await waitUntil("native Settings window was not visible") {
            settingsWindow = NSApp.windows.first {
                $0.identifier
                    == NoonmarkSettingsWindowController.windowIdentifier
                    && $0.isVisible
                    && $0.isMiniaturized == false
                    && $0 is NSPanel == false
                    && $0.parent == nil
            }
            guard let settingsWindow else { return false }
            return AppViewTreeE2E.view(identifier: "settings.window") != nil
                && settingsWindow.attachedSheet == nil
                && NSApp.modalWindow == nil
        }
        guard let settingsWindow else {
            throw Failure.failed("native Settings window disappeared")
        }
        return settingsWindow
    }

    private func activate(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil(
            "native Settings window did not become the expected key window"
        ) {
            NSApp.isActive
                && window.isKeyWindow
                && NSApp.keyWindow === window
                && window.isVisible
                && window.isMiniaturized == false
                && window.attachedSheet == nil
                && NSApp.modalWindow == nil
        }
    }

    private func clickLeftSegment(
        identifier: String,
        expectedWindow: NSWindow,
        input: WindowServerInputDriver,
        beforeClock: Date
    ) async throws {
        let target = try await accessibilityTarget(identifier: identifier)
        guard let frame = target.frame, frame.width >= 40 else {
            throw Failure.failed(
                "segmented control has no stable frame: \(identifier)"
            )
        }
        let point = CGPoint(
            x: frame.minX + frame.width * 0.25,
            y: frame.midY
        )
        try appendTrace(
            "click identifier=\(identifier) frame=\(frame) point=\(point) "
                + "before=\(exactBits(beforeClock))"
        )
        let resolveTarget = { () throws -> WindowServerInputDriver.PointerCoordinate in
            guard NSApp.keyWindow === expectedWindow,
                  let currentFrame = ReadOnlyAccessibilityTarget.uniqueElement(
                      identifier: identifier,
                      enabled: true
                  )?.frame
            else {
                throw Failure.failed(
                    "segmented target changed before mouseDown: \(identifier)"
                )
            }
            return try input.pointerCoordinate(
                quartzPoint: CGPoint(
                    x: currentFrame.minX + currentFrame.width * 0.25,
                    y: currentFrame.midY
                ),
                in: expectedWindow
            )
        }
        try await input.postClick(
            at: try input.pointerCoordinate(
                quartzPoint: point,
                in: expectedWindow
            ),
            modifiers: [],
            resolveTarget: resolveTarget
        )
    }

    private func clickCheckbox(
        identifier: String,
        expectedWindow: NSWindow,
        input: WindowServerInputDriver,
        beforeClock: Date
    ) async throws {
        _ = try await accessibilityTarget(identifier: identifier)
        try await revealCheckbox(identifier: identifier, in: expectedWindow)
        let resolveTarget = { () throws -> WindowServerInputDriver.PointerCoordinate in
            guard NSApp.keyWindow === expectedWindow,
                  let anchor = AppViewTreeE2E.view(
                      identifier: identifier,
                      in: expectedWindow
                  ),
                  let target = AppViewTreeE2E.checkboxInteractionTarget(
                      overlapping: anchor
                  ), target.window === expectedWindow
            else {
                throw Failure.failed(
                    "checkbox interaction target changed: \(identifier)"
                )
            }
            return try input.pointerCoordinate(
                windowPoint: target.windowPoint,
                in: expectedWindow
            )
        }
        let coordinate = try resolveTarget()
        try appendTrace(
            "click identifier=\(identifier) checkbox=true "
                + "point=\(coordinate.appKitScreenPoint) "
                + "before=\(exactBits(beforeClock))"
        )
        try await input.postClick(
            at: coordinate,
            modifiers: [],
            resolveTarget: resolveTarget
        )
    }

    private func revealCheckbox(
        identifier: String,
        in expectedWindow: NSWindow
    ) async throws {
        guard let anchor = AppViewTreeE2E.attachedView(identifier: identifier),
              anchor.window === expectedWindow
        else {
            throw Failure.failed(
                "checkbox anchor was not attached: \(identifier)"
            )
        }
        anchor.scrollToVisible(anchor.bounds.insetBy(dx: 0, dy: -24))
        expectedWindow.contentView?.layoutSubtreeIfNeeded()
        expectedWindow.displayIfNeeded()
        try await waitUntil("checkbox hit target was not visible: \(identifier)") {
            guard let visibleAnchor = AppViewTreeE2E.view(
                identifier: identifier,
                in: expectedWindow
            ) else { return false }
            return AppViewTreeE2E.checkboxInteractionTarget(
                overlapping: visibleAnchor
            ) != nil
        }
    }

    private func clickElement(
        identifier: String,
        expectedWindow: NSWindow,
        input: WindowServerInputDriver,
        beforeClock: Date
    ) async throws {
        let target = try await accessibilityTarget(identifier: identifier)
        guard let frame = target.frame else {
            throw Failure.failed("AX target has no frame: \(identifier)")
        }
        let resolveTarget = { () throws -> WindowServerInputDriver.PointerCoordinate in
            guard NSApp.keyWindow === expectedWindow,
                  let currentFrame = ReadOnlyAccessibilityTarget.uniqueElement(
                      identifier: identifier,
                      enabled: true
                  )?.frame
            else {
                throw Failure.failed("AX target changed: \(identifier)")
            }
            return try input.pointerCoordinate(
                quartzPoint: CGPoint(
                    x: currentFrame.midX,
                    y: currentFrame.midY
                ),
                in: expectedWindow
            )
        }
        try appendTrace(
            "click identifier=\(identifier) before=\(exactBits(beforeClock))"
        )
        try await input.postClick(
            at: try input.pointerCoordinate(
                quartzPoint: CGPoint(x: frame.midX, y: frame.midY),
                in: expectedWindow
            ),
            modifiers: [],
            resolveTarget: resolveTarget
        )
    }

    private func accessibilityTarget(
        identifier: String
    ) async throws -> ReadOnlyAccessibilityTarget.Match {
        guard AXIsProcessTrusted() else {
            throw Failure.failed("Accessibility is unavailable")
        }
        var match: ReadOnlyAccessibilityTarget.Match?
        try await waitUntil("missing AX target \(identifier)") {
            guard NSApp.isActive,
                  NSApp.keyWindow?.identifier
                  == NoonmarkSettingsWindowController.windowIdentifier,
                  let candidate = ReadOnlyAccessibilityTarget.uniqueElement(
                      identifier: identifier,
                      enabled: true
                  )
            else { return false }
            match = candidate
            return true
        }
        guard let match else {
            throw Failure.failed("AX target disappeared: \(identifier)")
        }
        return match
    }

    private func validateIsolation() throws {
        let path = syncFolderURL.path
        let guardedPrefix = "/private/tmp/noonmark-e2e-preferences-clock-sync-"
        let suffix = path.dropFirst(guardedPrefix.count)
        guard Bundle.main.bundleIdentifier == Self.e2eBundleIdentifier,
              databaseURL.path.isEmpty == false,
              path.hasPrefix(guardedPrefix),
              suffix.isEmpty == false,
              suffix.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let shellProcessID = Int32(suffix), shellProcessID > 0
        else {
            throw Failure.failed(
                "preference V2 automation escaped its isolated profile"
            )
        }
        if FileManager.default.fileExists(atPath: path) {
            let values = try syncFolderURL.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw Failure.failed("preference V2 repository is a symlink")
            }
        }
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 240,
        condition: @MainActor () async throws -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if try await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.failed(failure)
    }

    private func nextRepresentableDate(after date: Date) -> Date {
        Date(
            timeIntervalSinceReferenceDate: date
                .timeIntervalSinceReferenceDate.nextUp
        )
    }

    private func exactBits(_ date: Date) -> UInt64 {
        date.timeIntervalSinceReferenceDate.bitPattern
    }

    private func date(from bits: UInt64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
    }

    private func hasSameBits(_ lhs: Date, _ rhs: Date) -> Bool {
        exactBits(lhs) == exactBits(rhs)
    }

    private var traceURL: URL {
        resultURL.deletingLastPathComponent()
            .appendingPathComponent("input-trace.txt")
    }

    private func appendTrace(_ line: String) throws {
        try FileManager.default.createDirectory(
            at: traceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: traceURL.path) {
            let handle = try FileHandle(forWritingTo: traceURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: traceURL, options: .atomic)
        }
    }

    private func writeState(_ state: ProbeState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private func readState() throws -> ProbeState {
        try JSONDecoder().decode(
            ProbeState.self,
            from: Data(contentsOf: stateURL)
        )
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(
            to: resultURL,
            atomically: true,
            encoding: .utf8
        )
    }
}
