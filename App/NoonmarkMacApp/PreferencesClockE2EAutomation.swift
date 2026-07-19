import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import NoonmarkCore
import NoonmarkStorage
import NoonmarkSync

/// Verifies that native Settings input advances the theme/language logical
/// clock beyond a future remote record without synchronizing local-only
/// preferences.
///
/// Fixture and assertion access may use the Store directly. During the
/// exercise, theme, language, and the local-only poem toggle are changed only
/// through WindowServer input.
@MainActor
struct PreferencesClockE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case setup
        case exercise
        case verifyRestart
    }

    private struct ProbeState: Codable {
        let formatVersion: Int
        let remoteClockBits: UInt64
        let remoteRecordSHA256: String
        let localPoemText: String
        var themeClockBits: UInt64?
        var languageClockBits: UInt64?
        var themeJournalID: UUID?
        var languageJournalID: UUID?
        var themePayloadSHA256: String?
        var languagePayloadSHA256: String?
        var finalRecordSHA256: String?
        var finalSnapshotID: String?
        var finalSnapshotPayloadDigest: String?
        var finalSnapshotSHA256: String?
        var finalHeaderClockBits: UInt64?
        var finalPayloadClockBits: UInt64?
        var appPreferencesAuditCountAfterExercise: Int?
    }

    private struct StoredPreferenceRecord {
        let record: SyncRecord
        let data: Data

        var sha256: String {
            SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    private struct StoredRepositorySnapshot {
        let snapshot: SyncRepositorySnapshot
        let data: Data

        var sha256: String {
            SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    private struct ExpectedPreferenceState {
        let theme: AppTheme
        let language: AppLanguage
        let clock: Date
        let writerID: String
        let poemEnabled: Bool
    }

    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }

    private static let e2eBundleIdentifier = "app.noonmark.mac.e2e"
    private static let formatVersion = 2
    private static let remoteDeviceID = SyncDeviceID(
        "preferences-clock-remote-device"
    )
    private static let remoteTheme = AppTheme.warmPaper
    private static let remoteLanguage = AppLanguage.english
    private static let localTheme = AppTheme.coolGray
    private static let localLanguage = AppLanguage.chinese
    private static let localPoemText =
        "E2E local-only preference sentinel 6049"
    private static let themeIdentifier = "settings.preferences.theme"
    private static let languageIdentifier = "settings.preferences.language"
    private static let poemIdentifier =
        "settings.preferences.poem.enabled"

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
                    "failure mode=\(mode) error=\(error.localizedDescription)"
                )
                try? writeResult("failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }

    private func setup(on store: NoonmarkStore) async throws {
        try validateIsolation()
        try? FileManager.default.removeItem(at: traceURL)

        guard store.engine.preferences.theme == .coolGray,
              store.engine.preferences.language == .chinese,
              try preferenceJournalEntries().isEmpty,
              store.operationFailureNotice == nil
        else {
            throw Failure.failed(
                "preference-clock setup did not start from an isolated database"
            )
        }

        store.setSettingsPoemText(Self.localPoemText)
        store.setSettingsPoemEnabled(true)
        store.setLocalFirstSyncEndpoint(.localFolder)
        store.setLocalFirstSyncMode(.manual)
        store.setLocalFirstSyncEnabled(true)
        try assertLocalOnlyPreferences(
            in: store.engine.preferences,
            poemEnabled: true
        )
        guard try preferenceJournalEntries().isEmpty,
              store.operationFailureNotice == nil
        else {
            throw Failure.failed(
                "local-only setup created an appPreferences journal entry"
            )
        }

        let remoteClock = try instant("2035-07-05T16:00:00Z")
        let remoteRecord = try preferenceRecord(
            theme: Self.remoteTheme,
            language: Self.remoteLanguage,
            clock: remoteClock,
            deviceID: Self.remoteDeviceID
        )
        let transport = LocalFolderSyncTransport(rootURL: syncFolderURL)
        try await transport.push([remoteRecord])
        let storedRemote = try await storedPreferenceRecord(
            transport: transport,
            artifactName: "remote-future-preferences.json"
        )
        try assertPreferenceRecord(
            storedRemote.record,
            theme: Self.remoteTheme,
            language: Self.remoteLanguage,
            clock: remoteClock,
            deviceID: Self.remoteDeviceID
        )

        let syncResult = try await synchronize(store)
        guard syncResult.upload.pendingCount == 0,
              syncResult.upload.uploadedCount == 0,
              syncResult.upload.failedCount == 0,
              syncResult.download.fetchedCount == 1,
              syncResult.download.appliedCount == 1,
              syncResult.download.waitingCount == 0,
              syncResult.download.conflictCount == 0
        else {
            throw Failure.failed(
                "future remote preference setup did not merge through the "
                    + "real local-first coordinator"
            )
        }
        try assertPreferenceState(
            in: store,
            expected: ExpectedPreferenceState(
                theme: Self.remoteTheme,
                language: Self.remoteLanguage,
                clock: remoteClock,
                writerID: Self.remoteDeviceID.rawValue,
                poemEnabled: true
            )
        )
        guard try preferenceJournalEntries().isEmpty else {
            throw Failure.failed(
                "remote preference download created a local upload journal"
            )
        }

        try writeState(
            ProbeState(
                formatVersion: Self.formatVersion,
                remoteClockBits: exactBits(remoteClock),
                remoteRecordSHA256: storedRemote.sha256,
                localPoemText: Self.localPoemText,
                themeClockBits: nil,
                languageClockBits: nil,
                themeJournalID: nil,
                languageJournalID: nil,
                themePayloadSHA256: nil,
                languagePayloadSHA256: nil,
                finalRecordSHA256: nil,
                finalSnapshotID: nil,
                finalSnapshotPayloadDigest: nil,
                finalSnapshotSHA256: nil,
                finalHeaderClockBits: nil,
                finalPayloadClockBits: nil,
                appPreferencesAuditCountAfterExercise: nil
            )
        )
        try appendTrace(
            "setup remote=\(exactBits(remoteClock)) "
                + "recordSHA256=\(storedRemote.sha256)"
        )
    }

    private func exercise(on store: NoonmarkStore) async throws {
        try validateIsolation()
        var state = try readState()
        try validateSetupState(state)
        let localWriterID = try localPreferenceWriterID(in: store)

        let remoteClock = date(from: state.remoteClockBits)
        try assertPreferenceState(
            in: store,
            expected: ExpectedPreferenceState(
                theme: Self.remoteTheme,
                language: Self.remoteLanguage,
                clock: remoteClock,
                writerID: Self.remoteDeviceID.rawValue,
                poemEnabled: true
            )
        )
        guard try preferenceJournalEntries().isEmpty else {
            throw Failure.failed(
                "preference-clock exercise reopened with unexpected journal rows"
            )
        }
        let initialTransport = LocalFolderSyncTransport(
            rootURL: syncFolderURL
        )
        let initialRemote = try await storedPreferenceRecord(
            transport: initialTransport,
            artifactName: "remote-before-local-settings.json"
        )
        guard initialRemote.sha256 == state.remoteRecordSHA256 else {
            throw Failure.failed(
                "future remote preference record changed before Settings input"
            )
        }
        try assertPreferenceRecord(
            initialRemote.record,
            theme: Self.remoteTheme,
            language: Self.remoteLanguage,
            clock: remoteClock,
            deviceID: Self.remoteDeviceID
        )

        let settingsWindow = try await visibleSettingsWindow()
        try await activate(settingsWindow)
        let input = try WindowServerInputDriver()

        let themeClock = nextRepresentableDate(after: remoteClock)
        try await clickLeftSegment(
            identifier: Self.themeIdentifier,
            expectedWindow: settingsWindow,
            input: input,
            beforeClock: remoteClock
        )
        try await waitUntil(
            "theme click did not commit coolGray with the next exact clock"
        ) {
            let preferences = store.engine.preferences
            return preferences.theme == Self.localTheme
                && preferences.language == Self.remoteLanguage
                && self.hasSameBits(
                    preferences.themeLanguageUpdatedAt,
                    themeClock
                )
        }
        try assertPreferenceState(
            in: store,
            expected: ExpectedPreferenceState(
                theme: Self.localTheme,
                language: Self.remoteLanguage,
                clock: themeClock,
                writerID: localWriterID,
                poemEnabled: true
            )
        )
        var entries = try preferenceJournalEntries()
        guard entries.count == 1, let themeEntry = entries.first else {
            throw Failure.failed(
                "theme click did not create exactly one appPreferences journal"
            )
        }
        let themeEnvelope = try assertPreferenceJournalEntry(
            themeEntry,
            theme: Self.localTheme,
            language: Self.remoteLanguage,
            clock: themeClock,
            state: .pendingUpload
        )
        try appendTrace(
            "theme target=\(Self.themeIdentifier) "
                + "after=\(exactBits(themeEnvelope.updatedAt))"
        )

        let languageClock = nextRepresentableDate(after: themeClock)
        try await clickLeftSegment(
            identifier: Self.languageIdentifier,
            expectedWindow: settingsWindow,
            input: input,
            beforeClock: themeClock
        )
        try await waitUntil(
            "language click did not commit Chinese with the next exact clock"
        ) {
            let preferences = store.engine.preferences
            return preferences.theme == Self.localTheme
                && preferences.language == Self.localLanguage
                && self.hasSameBits(
                    preferences.themeLanguageUpdatedAt,
                    languageClock
                )
        }
        try assertPreferenceState(
            in: store,
            expected: ExpectedPreferenceState(
                theme: Self.localTheme,
                language: Self.localLanguage,
                clock: languageClock,
                writerID: localWriterID,
                poemEnabled: true
            )
        )
        entries = try preferenceJournalEntries()
        guard entries.count == 2 else {
            throw Failure.failed(
                "language click did not retain both preference journal rows"
            )
        }
        let languageEntry = try uniqueJournalEntry(
            in: entries,
            clock: languageClock
        )
        let languageEnvelope = try assertPreferenceJournalEntry(
            languageEntry,
            theme: Self.localTheme,
            language: Self.localLanguage,
            clock: languageClock,
            state: .pendingUpload
        )
        try appendTrace(
            "language target=\(Self.languageIdentifier) "
                + "after=\(exactBits(languageEnvelope.updatedAt))"
        )

        try await clickElement(
            identifier: Self.poemIdentifier,
            expectedWindow: settingsWindow,
            input: input,
            beforeClock: languageClock
        )
        try await waitUntil(
            "local-only poem checkbox did not turn off through WindowServer input"
        ) {
            store.engine.preferences.settingsPoemDisplayPolicy.enabled == false
        }
        try assertPreferenceState(
            in: store,
            expected: ExpectedPreferenceState(
                theme: Self.localTheme,
                language: Self.localLanguage,
                clock: languageClock,
                writerID: localWriterID,
                poemEnabled: false
            )
        )

        entries = try preferenceJournalEntries()
        guard entries.count == 2 else {
            throw Failure.failed(
                "local-only poem mutation advanced the preference clock "
                    + "or changed its journal"
            )
        }
        let poemThemeEntry = try uniqueJournalEntry(
            in: entries,
            clock: themeClock
        )
        let poemLanguageEntry = try uniqueJournalEntry(
            in: entries,
            clock: languageClock
        )
        guard poemThemeEntry.id == themeEntry.id,
              poemLanguageEntry.id == languageEntry.id
        else {
            throw Failure.failed(
                "local-only poem mutation replaced a preference journal row"
            )
        }
        _ = try assertPreferenceJournalEntry(
            poemThemeEntry,
            theme: Self.localTheme,
            language: Self.remoteLanguage,
            clock: themeClock,
            state: .pendingUpload
        )
        _ = try assertPreferenceJournalEntry(
            poemLanguageEntry,
            theme: Self.localTheme,
            language: Self.localLanguage,
            clock: languageClock,
            state: .pendingUpload
        )
        try appendTrace(
            "poem target=\(Self.poemIdentifier) "
                + "clock-retained=\(exactBits(languageClock))"
        )

        let syncResult = try await synchronize(store)
        guard syncResult.upload.pendingCount == 2,
              syncResult.upload.uploadedCount == 2,
              syncResult.upload.failedCount == 0,
              syncResult.download.fetchedCount == 1,
              syncResult.download.appliedCount == 0,
              syncResult.download.waitingCount == 0,
              syncResult.download.conflictCount == 0
        else {
            throw Failure.failed(
                "one production sync did not consume both preference journals"
            )
        }

        entries = try preferenceJournalEntries()
        guard entries.count == 2,
              entries.allSatisfy({
                  $0.state == .uploaded
                      && $0.retryCount == 0
                      && $0.lastError == nil
              }),
              try preferenceJournalEntries(state: .pendingUpload).isEmpty,
              try preferenceJournalEntries(state: .failed).isEmpty
        else {
            throw Failure.failed(
                "preference journals remained pending or failed after one sync"
            )
        }
        let uploadedThemeEntry = try uniqueJournalEntry(
            in: entries,
            clock: themeClock
        )
        let uploadedLanguageEntry = try uniqueJournalEntry(
            in: entries,
            clock: languageClock
        )
        _ = try assertPreferenceJournalEntry(
            uploadedThemeEntry,
            theme: Self.localTheme,
            language: Self.remoteLanguage,
            clock: themeClock,
            state: .uploaded
        )
        _ = try assertPreferenceJournalEntry(
            uploadedLanguageEntry,
            theme: Self.localTheme,
            language: Self.localLanguage,
            clock: languageClock,
            state: .uploaded
        )

        let transport = LocalFolderSyncTransport(rootURL: syncFolderURL)
        let finalStoredRecord = try await storedPreferenceRecord(
            transport: transport,
            artifactName: "final-local-winner-preferences.json"
        )
        let finalEnvelope = try assertPreferenceRecord(
            finalStoredRecord.record,
            theme: Self.localTheme,
            language: Self.localLanguage,
            clock: languageClock,
            deviceID: uploadedLanguageEntry.deviceID
        )
        let finalStoredSnapshot = try await storedLatestSnapshot(
            transport: transport,
            artifactName: "final-local-winner-snapshot.json"
        )
        let reconstructedSnapshot = try SyncRepositorySnapshotBuilder()
            .snapshot(
                records: [finalStoredRecord.record],
                memo: finalStoredSnapshot.snapshot.memo,
                createdAt: finalStoredSnapshot.snapshot.createdAt,
                deviceID: finalStoredSnapshot.snapshot.deviceID
            )
        guard finalStoredSnapshot.snapshot.recordIDs
                == [finalStoredRecord.record.id],
              finalStoredSnapshot.snapshot.recordCount == 1,
              finalStoredSnapshot.snapshot.payloadDigest
              == reconstructedSnapshot.payloadDigest,
              finalStoredSnapshot.snapshot.id == reconstructedSnapshot.id
        else {
            throw Failure.failed(
                "preference batch snapshot did not contain one reconstructible winner"
            )
        }
        try assertPreferenceState(
            in: store,
            expected: ExpectedPreferenceState(
                theme: Self.localTheme,
                language: Self.localLanguage,
                clock: languageClock,
                writerID: localWriterID,
                poemEnabled: false
            )
        )

        let preferenceAudit = try appPreferencesAuditEntries()
        let uploadAudit = preferenceAudit.filter {
            $0.direction == .upload && $0.action == "uploaded"
        }
        guard preferenceAudit.count == 4,
              uploadAudit.count == 2,
              preferenceAudit.filter({
                  $0.direction == .download && $0.action == "merged"
              }).count == 1,
              preferenceAudit.filter({
                  $0.direction == .download && $0.action == "ignored"
              }).count == 1
        else {
            throw Failure.failed(
                "preference sync audit did not record one merge, one replay ignore, "
                    + "and two uploads"
            )
        }

        state.themeClockBits = exactBits(themeClock)
        state.languageClockBits = exactBits(languageClock)
        state.themeJournalID = uploadedThemeEntry.id
        state.languageJournalID = uploadedLanguageEntry.id
        state.themePayloadSHA256 = sha256(
            try requiredPayload(uploadedThemeEntry)
        )
        state.languagePayloadSHA256 = sha256(
            try requiredPayload(uploadedLanguageEntry)
        )
        state.finalRecordSHA256 = finalStoredRecord.sha256
        state.finalSnapshotID = finalStoredSnapshot.snapshot.id
        state.finalSnapshotPayloadDigest =
            finalStoredSnapshot.snapshot.payloadDigest
        state.finalSnapshotSHA256 = finalStoredSnapshot.sha256
        state.finalHeaderClockBits = exactBits(finalStoredRecord.record.modifiedAt)
        state.finalPayloadClockBits = exactBits(finalEnvelope.updatedAt)
        state.appPreferencesAuditCountAfterExercise = preferenceAudit.count
        try writeState(state)

        try await replaceTransportWithStaleRemote(
            expectedSHA256: state.remoteRecordSHA256
        )
        try appendTrace(
            "sync uploaded=2 pending=0 failed=0 "
                + "final=\(exactBits(languageClock)) "
                + "recordSHA256=\(finalStoredRecord.sha256)"
        )
    }

    private func verifyRestart(on store: NoonmarkStore) async throws {
        try validateIsolation()
        let state = try readState()
        let final = try validateExerciseState(state)
        let languageClock = date(from: final.languageClockBits)
        let localWriterID = try localPreferenceWriterID(in: store)

        try assertPreferenceState(
            in: store,
            expected: ExpectedPreferenceState(
                theme: Self.localTheme,
                language: Self.localLanguage,
                clock: languageClock,
                writerID: localWriterID,
                poemEnabled: false
            )
        )
        var entries = try preferenceJournalEntries()
        try assertFinalJournal(entries, state: state)
        guard try appPreferencesAuditEntries().count
                == final.auditCountAfterExercise
        else {
            throw Failure.failed(
                "preference audit changed before the restart sync probe"
            )
        }

        let transport = LocalFolderSyncTransport(rootURL: syncFolderURL)
        let staleRecord = try await storedPreferenceRecord(
            transport: transport,
            artifactName: "stale-remote-before-restart-sync.json"
        )
        guard staleRecord.sha256 == state.remoteRecordSHA256 else {
            throw Failure.failed(
                "restart did not receive the exact stale remote preference record"
            )
        }
        try assertPreferenceRecord(
            staleRecord.record,
            theme: Self.remoteTheme,
            language: Self.remoteLanguage,
            clock: date(from: state.remoteClockBits),
            deviceID: Self.remoteDeviceID
        )

        let syncResult = try await synchronize(store)
        guard syncResult.upload.pendingCount == 0,
              syncResult.upload.uploadedCount == 0,
              syncResult.upload.failedCount == 0,
              syncResult.download.fetchedCount == 1,
              syncResult.download.appliedCount == 0,
              syncResult.download.waitingCount == 0,
              syncResult.download.conflictCount == 0
        else {
            throw Failure.failed(
                "restart stale-remote sync did not take the ignored path"
            )
        }
        try assertPreferenceState(
            in: store,
            expected: ExpectedPreferenceState(
                theme: Self.localTheme,
                language: Self.localLanguage,
                clock: languageClock,
                writerID: localWriterID,
                poemEnabled: false
            )
        )
        entries = try preferenceJournalEntries()
        try assertFinalJournal(entries, state: state)

        let preferenceAudit = try appPreferencesAuditEntries()
        guard preferenceAudit.count == final.auditCountAfterExercise + 1,
              preferenceAudit.filter({
                  $0.direction == .download && $0.action == "ignored"
              }).count == 2,
              preferenceAudit.filter({
                  $0.direction == .download && $0.action == "merged"
              }).count == 1,
              preferenceAudit.filter({
                  $0.direction == .upload
              }).count == 2
        else {
            throw Failure.failed(
                "restart stale remote was not recorded as one ignored download"
            )
        }
        try appendTrace(
            "restart stale=\(state.remoteClockBits) "
                + "winner=\(final.languageClockBits) "
                + "journal=uploaded,uploaded local-only=retained"
        )
    }

    private func synchronize(
        _ store: NoonmarkStore
    ) async throws -> SQLiteLocalFirstSyncResult {
        guard store.isLocalFirstSyncing == false,
              store.operationFailureNotice == nil
        else {
            throw Failure.failed(
                "preference-clock sync started from a failed or busy Store"
            )
        }
        store.syncLocalFolderNow()
        guard store.isLocalFirstSyncing else {
            throw Failure.failed(
                "Store did not start its production local-folder sync"
            )
        }
        try await waitUntil("production local-folder sync did not finish") {
            store.isLocalFirstSyncing == false
        }
        guard store.operationFailureNotice == nil else {
            throw Failure.failed(
                "production local-folder sync surfaced an operation failure"
            )
        }
        return try lastSyncResult()
    }

    private func lastSyncResult() throws -> SQLiteLocalFirstSyncResult {
        let repository = SQLiteSyncRepository(databaseURL: databaseURL)
        guard let metadata = try repository.metadata(
            for: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey
        ) else {
            throw Failure.failed("local-first sync status metadata is missing")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(
            SQLiteLocalFirstSyncStatus.self,
            from: metadata.value
        )
        guard case let .succeeded(result) = status else {
            throw Failure.failed(
                "local-first sync status did not finish as succeeded"
            )
        }
        return result
    }

    private func assertPreferenceState(
        in store: NoonmarkStore,
        expected: ExpectedPreferenceState
    ) throws {
        let current = store.engine.preferences
        try assertPreferences(
            current,
            expected: expected
        )
        let persisted = try SQLiteEngineRepository(
            databaseURL: databaseURL
        ).load().preferences
        try assertPreferences(
            persisted,
            expected: expected
        )
    }

    private func assertPreferences(
        _ preferences: AppPreferences,
        expected: ExpectedPreferenceState
    ) throws {
        guard preferences.theme == expected.theme,
              preferences.language == expected.language,
              hasSameBits(
                  preferences.themeLanguageUpdatedAt,
                  expected.clock
              ),
              preferences.themeLanguageWriterID == expected.writerID,
              preferences.dataMode == .localFirst,
              preferences.localFirstSyncPolicy.enabled,
              preferences.localFirstSyncPolicy.endpoint == .localFolder,
              preferences.localFirstSyncPolicy.mode == .manual,
              preferences.settingsPoemDisplayPolicy.enabled
              == expected.poemEnabled,
              preferences.settingsPoemDisplayPolicy.text
              == Self.localPoemText
        else {
            throw Failure.failed(
                "memory or SQLite preference state diverged from the probe vector"
            )
        }
    }

    private func assertLocalOnlyPreferences(
        in preferences: AppPreferences,
        poemEnabled: Bool
    ) throws {
        guard preferences.dataMode == .localFirst,
              preferences.localFirstSyncPolicy.enabled,
              preferences.localFirstSyncPolicy.endpoint == .localFolder,
              preferences.localFirstSyncPolicy.mode == .manual,
              preferences.settingsPoemDisplayPolicy.enabled == poemEnabled,
              preferences.settingsPoemDisplayPolicy.text
              == Self.localPoemText
        else {
            throw Failure.failed(
                "local-only preference fixture was not configured"
            )
        }
    }

    @discardableResult
    private func assertPreferenceJournalEntry(
        _ entry: SyncJournalEntry,
        theme: AppTheme,
        language: AppLanguage,
        clock: Date,
        state: SyncChangeState
    ) throws -> AppPreferencesEnvelope {
        guard entry.entityType == .appPreferences,
              entry.entityID == "default",
              entry.operation == .upsert,
              entry.state == state,
              entry.retryCount == 0,
              entry.lastError == nil,
              hasSameBits(entry.changedAt, clock)
        else {
            throw Failure.failed(
                "appPreferences journal header did not match its exact clock"
            )
        }
        let payload = try requiredPayload(entry)
        let record = SyncRecord(
            id: SyncRecordID("preferences:default"),
            entityType: .appPreferences,
            entityID: "default",
            modifiedAt: entry.changedAt,
            modifiedByDeviceID: entry.deviceID,
            payload: payload
        )
        let envelope = try SyncRecordMapper().decodeAppPreferences(record)
        guard envelope.theme == theme,
              envelope.language == language,
              envelope.writerDeviceID == entry.deviceID,
              hasSameBits(envelope.updatedAt, clock),
              hasSameBits(envelope.updatedAt, entry.changedAt)
        else {
            throw Failure.failed(
                "appPreferences journal payload did not match its header"
            )
        }
        return envelope
    }

    @discardableResult
    private func assertPreferenceRecord(
        _ record: SyncRecord,
        theme: AppTheme,
        language: AppLanguage,
        clock: Date,
        deviceID: SyncDeviceID
    ) throws -> AppPreferencesEnvelope {
        guard record.id == SyncRecordID("preferences:default"),
              record.entityType == .appPreferences,
              record.entityID == "default",
              record.operation == .upsert,
              record.modifiedByDeviceID == deviceID,
              hasSameBits(record.modifiedAt, clock)
        else {
            throw Failure.failed(
                "preference transport record header diverged from the probe vector"
            )
        }
        let envelope = try SyncRecordMapper().decodeAppPreferences(record)
        guard envelope.theme == theme,
              envelope.language == language,
              envelope.writerDeviceID == deviceID,
              hasSameBits(envelope.updatedAt, clock),
              hasSameBits(envelope.updatedAt, record.modifiedAt)
        else {
            throw Failure.failed(
                "preference transport payload did not match its exact header clock"
            )
        }
        return envelope
    }

    private func assertFinalJournal(
        _ entries: [SyncJournalEntry],
        state: ProbeState
    ) throws {
        let final = try validateExerciseState(state)
        guard entries.count == 2,
              try preferenceJournalEntries(state: .pendingUpload).isEmpty,
              try preferenceJournalEntries(state: .failed).isEmpty
        else {
            throw Failure.failed(
                "final preference journal did not contain two uploaded rows"
            )
        }
        let themeEntry = try uniqueJournalEntry(
            in: entries,
            clock: date(from: final.themeClockBits)
        )
        let languageEntry = try uniqueJournalEntry(
            in: entries,
            clock: date(from: final.languageClockBits)
        )
        guard themeEntry.id == final.themeJournalID,
              languageEntry.id == final.languageJournalID,
              sha256(try requiredPayload(themeEntry))
              == final.themePayloadSHA256,
              sha256(try requiredPayload(languageEntry))
              == final.languagePayloadSHA256
        else {
            throw Failure.failed(
                "preference journal identity or frozen payload changed on restart"
            )
        }
        _ = try assertPreferenceJournalEntry(
            themeEntry,
            theme: Self.localTheme,
            language: Self.remoteLanguage,
            clock: date(from: final.themeClockBits),
            state: .uploaded
        )
        _ = try assertPreferenceJournalEntry(
            languageEntry,
            theme: Self.localTheme,
            language: Self.localLanguage,
            clock: date(from: final.languageClockBits),
            state: .uploaded
        )
    }

    private func uniqueJournalEntry(
        in entries: [SyncJournalEntry],
        clock: Date
    ) throws -> SyncJournalEntry {
        let matches = entries.filter {
            hasSameBits($0.changedAt, clock)
        }
        guard matches.count == 1, let match = matches.first else {
            throw Failure.failed(
                "preference journal did not contain one row for "
                    + "\(exactBits(clock))"
            )
        }
        return match
    }

    private func preferenceRecord(
        theme: AppTheme,
        language: AppLanguage,
        clock: Date,
        deviceID: SyncDeviceID
    ) throws -> SyncRecord {
        try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: theme,
                language: language,
                updatedAt: clock,
                writerDeviceID: deviceID
            ),
            modifiedBy: deviceID
        )
    }

    private func localPreferenceWriterID(
        in store: NoonmarkStore
    ) throws -> String {
        guard let writerID = store.syncDeviceIdentity?.deviceID.rawValue,
              writerID.isEmpty == false
        else {
            throw Failure.failed(
                "local sync device identity is missing for preference provenance"
            )
        }
        return writerID
    }

    private func storedPreferenceRecord(
        transport: LocalFolderSyncTransport,
        artifactName: String
    ) async throws -> StoredPreferenceRecord {
        let fetchedRecords = try await transport.fetchAll()
        let fetched = fetchedRecords.filter {
            $0.entityType == .appPreferences
                && $0.id == SyncRecordID("preferences:default")
        }
        guard fetched.count == 1, let fetchedRecord = fetched.first else {
            throw Failure.failed(
                "local-folder transport does not contain one preference record"
            )
        }

        let recordsURL = syncFolderURL.appendingPathComponent(
            "records",
            isDirectory: true
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: recordsURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        let matches = try files.compactMap { url -> StoredPreferenceRecord? in
            let data = try Data(contentsOf: url)
            let record = try decoder.decode(SyncRecord.self, from: data)
            guard record.id == SyncRecordID("preferences:default") else {
                return nil
            }
            return StoredPreferenceRecord(record: record, data: data)
        }
        guard matches.count == 1, let stored = matches.first,
              stored.record == fetchedRecord,
              hasSameBits(
                  stored.record.modifiedAt,
                  fetchedRecord.modifiedAt
              )
        else {
            throw Failure.failed(
                "real local-folder record bytes diverged from fetchAll"
            )
        }

        let artifactURL = resultURL.deletingLastPathComponent()
            .appendingPathComponent(artifactName)
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try stored.data.write(to: artifactURL, options: .atomic)
        return stored
    }

    private func storedLatestSnapshot(
        transport: LocalFolderSyncTransport,
        artifactName: String
    ) async throws -> StoredRepositorySnapshot {
        let fetchedSnapshots = try await transport.fetchSnapshots()
        let latestRefURL = syncFolderURL
            .appendingPathComponent("refs", isDirectory: true)
            .appendingPathComponent("latest")
        let latestID = try String(
            contentsOf: latestRefURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let fetched = fetchedSnapshots.filter { $0.id == latestID }
        guard fetched.count == 1, let fetchedSnapshot = fetched.first else {
            throw Failure.failed(
                "local-folder latest ref did not resolve to one snapshot"
            )
        }

        let indexesURL = syncFolderURL.appendingPathComponent(
            "indexes",
            isDirectory: true
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: indexesURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let matches = try files.compactMap { url -> StoredRepositorySnapshot? in
            let data = try Data(contentsOf: url)
            let snapshot = try decoder.decode(
                SyncRepositorySnapshot.self,
                from: data
            )
            guard snapshot.id == latestID else { return nil }
            return StoredRepositorySnapshot(
                snapshot: snapshot,
                data: data
            )
        }
        guard matches.count == 1, let stored = matches.first,
              stored.snapshot == fetchedSnapshot
        else {
            throw Failure.failed(
                "real local-folder latest snapshot bytes diverged from fetchSnapshots"
            )
        }

        let artifactURL = resultURL.deletingLastPathComponent()
            .appendingPathComponent(artifactName)
        try stored.data.write(to: artifactURL, options: .atomic)
        return stored
    }

    private func replaceTransportWithStaleRemote(
        expectedSHA256: String
    ) async throws {
        try validateSyncFolderForReplacement()
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: syncFolderURL.path) {
            try fileManager.removeItem(at: syncFolderURL)
        }
        let remoteRecord = try preferenceRecord(
            theme: Self.remoteTheme,
            language: Self.remoteLanguage,
            clock: try instant("2035-07-05T16:00:00Z"),
            deviceID: Self.remoteDeviceID
        )
        let transport = LocalFolderSyncTransport(rootURL: syncFolderURL)
        try await transport.push([remoteRecord])
        let stored = try await storedPreferenceRecord(
            transport: transport,
            artifactName: "stale-remote-reintroduced.json"
        )
        guard stored.sha256 == expectedSHA256 else {
            throw Failure.failed(
                "reintroduced stale preference record was not byte-identical"
            )
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
                + "before=\(exactBits(beforeClock)) "
                + "window=\(expectedWindow.identifier?.rawValue ?? "nil")"
        )
        do {
            let resolveTarget = { () throws -> WindowServerInputDriver.PointerCoordinate in
                guard NSApp.keyWindow === expectedWindow,
                      let currentFrame = ReadOnlyAccessibilityTarget
                      .uniqueElement(
                          identifier: identifier,
                          enabled: true
                      )?.frame
                else {
                    throw Failure.failed(
                        "segmented target changed before mouseDown: \(identifier)"
                    )
                }
                let currentPoint = CGPoint(
                    x: currentFrame.minX + currentFrame.width * 0.25,
                    y: currentFrame.midY
                )
                return try input.pointerCoordinate(
                    quartzPoint: currentPoint,
                    in: expectedWindow
                )
            }
            let coordinate = try input.pointerCoordinate(
                quartzPoint: point,
                in: expectedWindow
            )
            try await input.postClick(
                at: coordinate,
                modifiers: [],
                resolveTarget: resolveTarget
            )
        } catch {
            throw Failure.failed(
                "WindowServer segmented click failed for \(identifier): "
                    + error.localizedDescription
            )
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
            throw Failure.failed(
                "accessibility click target has no frame: \(identifier)"
            )
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        try appendTrace(
            "click identifier=\(identifier) frame=\(frame) point=\(point) "
                + "before=\(exactBits(beforeClock)) "
                + "window=\(expectedWindow.identifier?.rawValue ?? "nil")"
        )
        do {
            let resolveTarget = { () throws -> WindowServerInputDriver.PointerCoordinate in
                guard NSApp.keyWindow === expectedWindow,
                      let currentFrame = ReadOnlyAccessibilityTarget
                      .uniqueElement(
                          identifier: identifier,
                          enabled: true
                      )?.frame
                else {
                    throw Failure.failed(
                        "accessibility target changed before mouseDown: \(identifier)"
                    )
                }
                let currentPoint = CGPoint(
                    x: currentFrame.midX,
                    y: currentFrame.midY
                )
                return try input.pointerCoordinate(
                    quartzPoint: currentPoint,
                    in: expectedWindow
                )
            }
            let coordinate = try input.pointerCoordinate(
                quartzPoint: point,
                in: expectedWindow
            )
            try await input.postClick(
                at: coordinate,
                modifiers: [],
                resolveTarget: resolveTarget
            )
        } catch {
            throw Failure.failed(
                "WindowServer click failed for \(identifier): "
                    + error.localizedDescription
            )
        }
    }

    private func accessibilityTarget(
        identifier: String
    ) async throws -> ReadOnlyAccessibilityTarget.Match {
        guard AXIsProcessTrusted() else {
            throw Failure.failed(
                "Accessibility access is unavailable for \(identifier)"
            )
        }
        var match: ReadOnlyAccessibilityTarget.Match?
        do {
            try await waitUntil("missing AX target \(identifier)") {
                guard NSApp.isActive,
                      NSApp.keyWindow?.identifier
                      == NoonmarkSettingsWindowController.windowIdentifier,
                      let candidate = ReadOnlyAccessibilityTarget.uniqueElement(
                          identifier: identifier,
                          enabled: true
                      )
                else {
                    return false
                }
                match = candidate
                return true
            }
        } catch {
            throw Failure.failed(
                "missing AX target \(identifier): "
                    + ReadOnlyAccessibilityTarget.elementDiagnostics(
                        identifier: identifier
                    )
            )
        }
        guard let match else {
            throw Failure.failed("AX target disappeared: \(identifier)")
        }
        return match
    }

    private func preferenceJournalEntries(
        state: SyncChangeState? = nil
    ) throws -> [SyncJournalEntry] {
        try SQLiteSyncRepository(databaseURL: databaseURL)
            .journalEntries(state: state)
            .filter { $0.entityType == .appPreferences }
    }

    private func appPreferencesAuditEntries() throws -> [SyncAuditLogEntry] {
        try SQLiteSyncRepository(databaseURL: databaseURL)
            .auditLog(limit: 100)
            .filter { $0.entityType == .appPreferences }
    }

    private func requiredPayload(
        _ entry: SyncJournalEntry
    ) throws -> Data {
        guard let payload = entry.recordPayload, payload.isEmpty == false else {
            throw Failure.failed(
                "appPreferences journal is missing its canonical payload"
            )
        }
        return payload
    }

    private func validateIsolation() throws {
        guard Bundle.main.bundleIdentifier == Self.e2eBundleIdentifier,
              databaseURL.path.isEmpty == false
        else {
            throw Failure.failed(
                "preference-clock automation requires the E2E bundle and database"
            )
        }
        try validateSyncFolderForReplacement()
    }

    private func validateSyncFolderForReplacement() throws {
        let path = syncFolderURL.standardizedFileURL.path
        guard path.hasPrefix(
            "/tmp/noonmark-e2e-preferences-clock-sync-"
        ), path.count > "/tmp/noonmark-e2e-preferences-clock-sync-".count
        else {
            throw Failure.failed(
                "preference-clock sync folder is outside its guarded /tmp scope"
            )
        }
        if FileManager.default.fileExists(atPath: path) {
            let values = try syncFolderURL.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw Failure.failed(
                    "preference-clock sync folder must not be a symbolic link"
                )
            }
        }
    }

    private func validateSetupState(_ state: ProbeState) throws {
        guard state.formatVersion == Self.formatVersion,
              state.localPoemText == Self.localPoemText,
              state.remoteClockBits
              == exactBits(try instant("2035-07-05T16:00:00Z")),
              state.remoteRecordSHA256.count == 64,
              state.themeClockBits == nil,
              state.languageClockBits == nil,
              state.themeJournalID == nil,
              state.languageJournalID == nil,
              state.themePayloadSHA256 == nil,
              state.languagePayloadSHA256 == nil,
              state.finalRecordSHA256 == nil,
              state.finalSnapshotID == nil,
              state.finalSnapshotPayloadDigest == nil,
              state.finalSnapshotSHA256 == nil,
              state.finalHeaderClockBits == nil,
              state.finalPayloadClockBits == nil,
              state.appPreferencesAuditCountAfterExercise == nil
        else {
            throw Failure.failed(
                "preference-clock setup state is incomplete or stale"
            )
        }
    }

    private func validateExerciseState(
        _ state: ProbeState
    ) throws -> (
        themeClockBits: UInt64,
        languageClockBits: UInt64,
        themeJournalID: UUID,
        languageJournalID: UUID,
        themePayloadSHA256: String,
        languagePayloadSHA256: String,
        auditCountAfterExercise: Int
    ) {
        guard state.formatVersion == Self.formatVersion,
              state.localPoemText == Self.localPoemText,
              let themeClockBits = state.themeClockBits,
              let languageClockBits = state.languageClockBits,
              let themeJournalID = state.themeJournalID,
              let languageJournalID = state.languageJournalID,
              let themePayloadSHA256 = state.themePayloadSHA256,
              let languagePayloadSHA256 = state.languagePayloadSHA256,
              let finalRecordSHA256 = state.finalRecordSHA256,
              let finalSnapshotID = state.finalSnapshotID,
              let finalSnapshotPayloadDigest =
              state.finalSnapshotPayloadDigest,
              let finalSnapshotSHA256 = state.finalSnapshotSHA256,
              let finalHeaderClockBits = state.finalHeaderClockBits,
              let finalPayloadClockBits = state.finalPayloadClockBits,
              let auditCount = state
              .appPreferencesAuditCountAfterExercise,
              themeClockBits
              == exactBits(
                  nextRepresentableDate(
                      after: date(from: state.remoteClockBits)
                  )
              ),
              languageClockBits
              == exactBits(
                  nextRepresentableDate(
                      after: date(from: themeClockBits)
                  )
              ),
              finalHeaderClockBits == languageClockBits,
              finalPayloadClockBits == languageClockBits,
              themePayloadSHA256.count == 64,
              languagePayloadSHA256.count == 64,
              finalRecordSHA256.count == 64,
              finalSnapshotID.count == 64,
              finalSnapshotPayloadDigest.count == 64,
              finalSnapshotSHA256.count == 64,
              auditCount == 4
        else {
            throw Failure.failed(
                "preference-clock exercise state is incomplete or inconsistent"
            )
        }
        return (
            themeClockBits,
            languageClockBits,
            themeJournalID,
            languageJournalID,
            themePayloadSHA256,
            languagePayloadSHA256,
            auditCount
        )
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 200,
        condition: @MainActor () throws -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
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
        Date(
            timeIntervalSinceReferenceDate: Double(bitPattern: bits)
        )
    }

    private func hasSameBits(_ lhs: Date, _ rhs: Date) -> Bool {
        exactBits(lhs) == exactBits(rhs)
    }

    private func instant(_ text: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: text) else {
            throw Failure.failed(
                "invalid preference-clock instant: \(text)"
            )
        }
        return date
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
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
