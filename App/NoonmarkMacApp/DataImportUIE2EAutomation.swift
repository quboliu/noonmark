import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import NoonmarkCore
import NoonmarkMacE2ESupport
import NoonmarkMacRuntime
import NoonmarkStorage
import NoonmarkSync

/// Exercises the destructive import through Noonmark's real File menu,
/// `NSOpenPanel`, SwiftUI confirmation sheet, and pointer events.
///
/// Direct Store import APIs are deliberately absent from this driver. Store
/// access is limited to fixture setup and post-interaction assertions.
@MainActor
struct DataImportUIE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case setup
        case exercise
        case verifyRestart
        case integritySetup
        case integrityExercise
        case integrityVerifyRestart
    }

    private enum IntegrityCase: String, CaseIterable {
        case duplicateSubtaskIdentity = "duplicate-subtask-identity"
        case danglingSubtaskParent = "dangling-subtask-parent"
        case invalidSubtaskTerminalFacts = "invalid-subtask-terminal-facts"
        case invalidPlannedSubtaskPosition = "invalid-planned-subtask-position"

        var fileName: String {
            "\(rawValue).json"
        }
    }

    private struct ProbeState: Codable {
        let baselineTitle: String
        let scheduledImportTitle: String
        let poolImportTitle: String
        let returnedImportTitle: String
        let scheduledDate: String
        let cancellationConfirmationWasVisible: Bool
        let destructiveConfirmationWasVisible: Bool
        let scheduledImportDefinitionCount: Int
        let poolImportDefinitionCount: Int
        let returnedImportDefinitionCount: Int
        let retiredImportDefinitionCount: Int
    }

    private struct IntegrityProbeState: Codable {
        let formatVersion: Int
        let baselineTitle: String
        let malformedPayloadTitle: String
        let scenarioIDs: [String]
        let completedScenarioIDs: [String]
        let fixtureSHA256ByScenarioID: [String: String]
        let recoverableFailureMessage: String
        let baselineSnapshotSHA256: String
        let baselineJournalSHA256: String
        let baselineJournalCount: Int
    }

    private struct IntegrityBaselineEvidence {
        let snapshot: NoonmarkSnapshot
        let snapshotSHA256: String
        let journalEntries: [SyncJournalEntry]
        let journalSHA256: String
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

    private struct ConfirmationClickTarget {
        let window: NSWindow
        let frame: CGRect
        let point: CGPoint
    }

    private static let e2eBundleIdentifier = "app.noonmark.mac.e2e"
    private static let baselineTitle = "E2E UI import baseline 7319"
    private static let scheduledImportTitle = "E2E UI import scheduled 7319"
    private static let poolImportTitle = "E2E UI import pool 7319"
    private static let returnedImportTitle = "E2E UI import returned 7319"
    private static let retiredImportTitle = "E2E UI import retired 7319"
    private static let decoyImportTitle = "E2E UI import decoy 7319"
    private static let integrityBaselineTitle = "E2E import integrity baseline 9340"
    private static let malformedPayloadTitle = "E2E malformed import payload 9340"
    private static var currentDataPackageFormatVersion: Int {
        NoonmarkDataPackage.currentFormatVersion
    }

    private let mode: Mode
    private let fixtureURL: URL
    private let stateURL: URL
    private let resultURL: URL
    private let databaseURL: URL
    private let openPanelProtocolDirectory: URL?

    static func fromCommandLine() -> Self? {
        guard Bundle.main.bundleIdentifier == e2eBundleIdentifier else {
            return nil
        }

        let mode: Mode
        if AppLaunchArguments.contains("--e2e-data-import-ui-setup") {
            mode = .setup
        } else if AppLaunchArguments.contains("--e2e-data-import-ui-exercise") {
            mode = .exercise
        } else if AppLaunchArguments.contains("--e2e-data-import-ui-verify") {
            mode = .verifyRestart
        } else if AppLaunchArguments.contains("--e2e-data-import-integrity-setup") {
            mode = .integritySetup
        } else if AppLaunchArguments.contains("--e2e-data-import-integrity-exercise") {
            mode = .integrityExercise
        } else if AppLaunchArguments.contains("--e2e-data-import-integrity-verify") {
            mode = .integrityVerifyRestart
        } else {
            return nil
        }

        guard let fixturePath = AppLaunchArguments.value(
            after: "--e2e-data-import-ui-fixture-url"
        ), let statePath = AppLaunchArguments.value(
            after: "--e2e-data-import-ui-state-url"
        ), let resultPath = AppLaunchArguments.value(
            after: "--e2e-data-import-ui-result-url"
        ), let databasePath = AppLaunchArguments.value(after: "--data-url")
        else {
            return nil
        }

        let openPanelProtocolDirectory = AppLaunchArguments.value(
            after: "--e2e-data-import-open-panel-protocol-directory"
        ).map { URL(fileURLWithPath: $0) }
        if [.exercise, .integrityExercise].contains(mode),
           openPanelProtocolDirectory == nil
        {
            return nil
        }

        return Self(
            mode: mode,
            fixtureURL: URL(fileURLWithPath: fixturePath),
            stateURL: URL(fileURLWithPath: statePath),
            resultURL: URL(fileURLWithPath: resultPath),
            databaseURL: URL(fileURLWithPath: databasePath),
            openPanelProtocolDirectory: openPanelProtocolDirectory
        )
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                switch mode {
                case .setup:
                    try setup(on: store)
                case .exercise:
                    try await exercise(on: store)
                case .verifyRestart:
                    try verifyRestart(on: store)
                case .integritySetup:
                    try setupIntegrityFixtures(on: store)
                case .integrityExercise:
                    try await exerciseIntegrityFailures(on: store)
                case .integrityVerifyRestart:
                    try verifyIntegrityRestart(on: store)
                }
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeWindowDump()
                try? writeResult("failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }

    private func setup(on store: NoonmarkStore) throws {
        var timeline = try E2EFixtureTimeline(
            store: store,
            eventCount: 13
        )
        let today = timeline.today

        let baselineEngine = NoonmarkEngine()
        _ = try baselineEngine.createPoolTask(
            title: Self.baselineTitle,
            descriptionText: "Cancel must retain this persisted task.",
            now: try timeline.nextInstant()
        )

        let importEngine = NoonmarkEngine()
        let scheduledChainID = try importEngine.createPoolTask(
            title: Self.scheduledImportTitle,
            descriptionText: "Selected through the real NSOpenPanel.",
            now: try timeline.nextInstant()
        )
        _ = try importEngine.scheduleFromPool(
            chainID: scheduledChainID,
            date: today,
            today: today,
            now: try timeline.nextInstant()
        )
        _ = try importEngine.createPoolTask(
            title: Self.poolImportTitle,
            descriptionText: "Confirms the complete package replaced current data.",
            now: try timeline.nextInstant()
        )
        let returnedChainID = try importEngine.createPoolTask(
            title: Self.returnedImportTitle,
            descriptionText: "Internal cancellation facts must stay out of import metrics.",
            now: try timeline.nextInstant()
        )
        let futureDate = NoonmarkStore.offset(today, by: 1)
        let returnedTraceID = try importEngine.scheduleFromPool(
            chainID: returnedChainID,
            date: futureDate,
            today: today,
            now: try timeline.nextInstant()
        )
        _ = try importEngine.addSubtask(
            traceID: returnedTraceID,
            title: "Hidden import subtask",
            now: try timeline.nextInstant()
        )
        try importEngine.returnToPool(
            traceID: returnedTraceID,
            today: today,
            now: try timeline.nextInstant()
        )
        let retiredChainID = try importEngine.createPoolTask(
            title: Self.retiredImportTitle,
            descriptionText: "A fully hidden internal chain must not inflate import metrics.",
            now: try timeline.nextInstant()
        )
        let retiredTraceID = try importEngine.scheduleFromPool(
            chainID: retiredChainID,
            date: futureDate,
            today: today,
            now: try timeline.nextInstant()
        )
        try importEngine.returnToPool(
            traceID: retiredTraceID,
            today: today,
            now: try timeline.nextInstant()
        )
        _ = try importEngine.removeTaskFromPool(
            chainID: retiredChainID,
            now: try timeline.nextInstant()
        )

        let decoyEngine = NoonmarkEngine()
        _ = try decoyEngine.createPoolTask(
            title: Self.decoyImportTitle,
            descriptionText: "The open panel must select fixture.json, not the first JSON file.",
            now: try timeline.nextInstant()
        )
        _ = try timeline.finish()

        store.engine = baselineEngine
        store.persist()

        let persistedBaseline = try persistedEngine()
        guard persistedBaseline.definitions.values.filter({
            $0.title == Self.baselineTitle
        }).count == 1,
            persistedBaseline.definitions.count == 1,
            persistedBaseline.traces.isEmpty
        else {
            throw Failure.failed("baseline fixture was not committed to SQLite")
        }

        try writePreviousReleaseDataPackage(
            importEngine.snapshot(),
            to: fixtureURL
        )
        try NoonmarkDataPackage.write(decoyEngine.snapshot(), to: decoyURL)

        guard FileManager.default.fileExists(atPath: fixtureURL.path),
              FileManager.default.fileExists(atPath: decoyURL.path)
        else {
            throw Failure.failed("import fixture and decoy JSON files were not created")
        }
    }

    private func writePreviousReleaseDataPackage(
        _ snapshot: NoonmarkSnapshot,
        to url: URL
    ) throws {
        let currentData = try NoonmarkDataPackage.encode(snapshot)
        guard var envelope = try JSONSerialization.jsonObject(
            with: currentData
        ) as? [String: Any],
            var legacySnapshot = envelope["snapshot"] as? [String: Any]
        else {
            throw Failure.failed(
                "could not build the previous-release import fixture"
            )
        }
        envelope["formatVersion"] = NoonmarkDataPackage.legacyFormatVersion
        legacySnapshot.removeValue(forKey: "ideas")
        envelope["snapshot"] = legacySnapshot
        let legacyData = try canonicalJSON(envelope)
        try legacyData.write(to: url, options: .atomic)
        guard try NoonmarkDataPackage.read(from: url) == snapshot else {
            throw Failure.failed(
                "previous-release import fixture did not round-trip"
            )
        }
    }

    private func exercise(on store: NoonmarkStore) async throws {
        guard fixtureURL.path.hasPrefix("/tmp/"),
              FileManager.default.fileExists(atPath: fixtureURL.path),
              FileManager.default.fileExists(atPath: decoyURL.path)
        else {
            throw Failure.failed(
                "UI import fixture and decoy must be existing isolated /tmp JSON files"
            )
        }
        let mainWindow = try await visibleMainWindow()
        try await activate(mainWindow)
        let panelTraceURL = resultURL
            .deletingLastPathComponent()
            .appendingPathComponent("panel-events.txt")
        try? FileManager.default.removeItem(at: panelTraceURL)

        let baseline = store.engine.snapshot()
        let persistedBaseline = try persistedSnapshot()
        guard definitionCount(titled: Self.baselineTitle, in: store) == 1,
              definitionCount(titled: Self.scheduledImportTitle, in: store) == 0
        else {
            throw Failure.failed("exercise did not start from its persisted baseline")
        }

        try await chooseFixtureThroughFileMenu(
            mainWindow: mainWindow,
            panelTraceURL: panelTraceURL,
            interactionLabel: "cancel"
        )
        try await waitForConfirmation(
            store: store,
            failure: "first import selection did not present data-import.confirmation"
        )
        try validatePreparedImportSummary(store)
        let cancellationConfirmationWasVisible = true
        try await clickConfirmationButton(
            identifier: "data-import.cancel",
            title: store.copy.cancel
        )
        try await waitUntil("Cancel did not dismiss the import confirmation") {
            store.preparedDataImport == nil
                && AppViewTreeE2E.hasNoVisibleView(
                    identifier: "data-import.confirmation"
                )
                && AppViewTreeE2E.hasNoAttachedSheets()
        }
        guard store.engine.snapshot() == baseline,
              try persistedSnapshot() == persistedBaseline,
              definitionCount(titled: Self.baselineTitle, in: store) == 1,
              definitionCount(titled: Self.scheduledImportTitle, in: store) == 0
        else {
            throw Failure.failed("Cancel changed memory or SQLite before confirmation")
        }

        try await activate(mainWindow)
        try await chooseFixtureThroughFileMenu(
            mainWindow: mainWindow,
            panelTraceURL: panelTraceURL,
            interactionLabel: "confirm"
        )
        try await waitForConfirmation(
            store: store,
            failure: "second import selection did not present data-import.confirmation"
        )
        try validatePreparedImportSummary(store)
        guard let preparedSnapshot = store.preparedDataImport?.snapshot else {
            throw Failure.failed("selected import package disappeared before confirmation")
        }
        let scheduledImportDefinitionCount = definitionCount(
            titled: Self.scheduledImportTitle,
            in: preparedSnapshot
        )
        let poolImportDefinitionCount = definitionCount(
            titled: Self.poolImportTitle,
            in: preparedSnapshot
        )
        let returnedImportDefinitionCount = definitionCount(
            titled: Self.returnedImportTitle,
            in: preparedSnapshot
        )
        let retiredImportDefinitionCount = definitionCount(
            titled: Self.retiredImportTitle,
            in: preparedSnapshot
        )
        guard scheduledImportDefinitionCount > 0,
              poolImportDefinitionCount > 0,
              returnedImportDefinitionCount > 0,
              retiredImportDefinitionCount > 0
        else {
            throw Failure.failed("selected import package lost expected definition history")
        }
        let destructiveConfirmationWasVisible = true
        try await clickConfirmationButton(
            identifier: "data-import.confirm",
            title: store.copy.confirmImport
        )
        try await waitUntil("destructive confirmation did not commit the selected package") {
            store.preparedDataImport == nil
                && AppViewTreeE2E.hasNoVisibleView(
                    identifier: "data-import.confirmation"
                )
                && AppViewTreeE2E.hasNoAttachedSheets()
                && self.definitionCount(
                    titled: Self.scheduledImportTitle,
                    in: store
                ) == scheduledImportDefinitionCount
                && self.definitionCount(
                    titled: Self.poolImportTitle,
                    in: store
                ) == poolImportDefinitionCount
                && self.definitionCount(
                    titled: Self.returnedImportTitle,
                    in: store
                ) == returnedImportDefinitionCount
        }

        let persistedAfterImport = try persistedEngine()
        guard definitionCount(titled: Self.baselineTitle, in: store) == 0,
              definitionCount(
                  titled: Self.baselineTitle,
                  in: persistedAfterImport
              ) == 0,
              definitionCount(
                  titled: Self.scheduledImportTitle,
                  in: persistedAfterImport
              ) == scheduledImportDefinitionCount,
              definitionCount(
                  titled: Self.poolImportTitle,
                  in: persistedAfterImport
              ) == poolImportDefinitionCount,
              definitionCount(
                  titled: Self.returnedImportTitle,
                  in: persistedAfterImport
              ) == returnedImportDefinitionCount,
              persistedAfterImport.traces.values.contains(where: {
                  $0.status == .cancelledDraft
                      && persistedAfterImport.definitions[$0.definitionID]?
                      .title == Self.returnedImportTitle
              }),
              definitionCount(
                  titled: Self.retiredImportTitle,
                  in: persistedAfterImport
              ) == retiredImportDefinitionCount,
              definitionCount(
                  titled: Self.decoyImportTitle,
                  in: persistedAfterImport
              ) == 0,
              persistedAfterImport.taskPool().contains(where: {
                  $0.definition.title == Self.retiredImportTitle
              }) == false
        else {
            throw Failure.failed("confirmed UI import did not atomically replace SQLite")
        }
        guard persistedAfterImport.futurePlans(today: store.today).allSatisfy({
            $0.definition.title != Self.retiredImportTitle
        }), persistedAfterImport.unfinishedPool().allSatisfy({
            $0.definition.title != Self.retiredImportTitle
        }), persistedAfterImport.completedPool().allSatisfy({
            $0.definition.title != Self.retiredImportTitle
        })
        else {
            throw Failure.failed("import exposed a fully retired internal task chain")
        }

        try writeState(
            ProbeState(
                baselineTitle: Self.baselineTitle,
                scheduledImportTitle: Self.scheduledImportTitle,
                poolImportTitle: Self.poolImportTitle,
                returnedImportTitle: Self.returnedImportTitle,
                scheduledDate: store.today.description,
                cancellationConfirmationWasVisible: cancellationConfirmationWasVisible,
                destructiveConfirmationWasVisible: destructiveConfirmationWasVisible,
                scheduledImportDefinitionCount: scheduledImportDefinitionCount,
                poolImportDefinitionCount: poolImportDefinitionCount,
                returnedImportDefinitionCount: returnedImportDefinitionCount,
                retiredImportDefinitionCount: retiredImportDefinitionCount
            )
        )
    }

    private func verifyRestart(on store: NoonmarkStore) throws {
        let state = try JSONDecoder().decode(
            ProbeState.self,
            from: Data(contentsOf: stateURL)
        )
        guard state.cancellationConfirmationWasVisible,
              state.destructiveConfirmationWasVisible,
              state.baselineTitle == Self.baselineTitle,
              state.scheduledImportTitle == Self.scheduledImportTitle,
              state.poolImportTitle == Self.poolImportTitle,
              state.returnedImportTitle == Self.returnedImportTitle,
              definitionCount(titled: state.baselineTitle, in: store) == 0,
              definitionCount(
                  titled: state.scheduledImportTitle,
                  in: store
              ) == state.scheduledImportDefinitionCount,
              definitionCount(
                  titled: state.poolImportTitle,
                  in: store
              ) == state.poolImportDefinitionCount,
              definitionCount(
                  titled: state.returnedImportTitle,
                  in: store
              ) == state.returnedImportDefinitionCount,
              store.engine.taskPool().contains(where: {
                  $0.definition.title == state.returnedImportTitle
              }),
              store.engine.traces.values.contains(where: {
                  $0.status == .cancelledDraft
                      && store.engine.definitions[$0.definitionID]?.title
                      == state.returnedImportTitle
              }),
              store.engine.taskPool().allSatisfy({
                  $0.definition.title != Self.retiredImportTitle
              }),
              store.engine.traces.values.contains(where: { trace in
                  trace.date.description == state.scheduledDate
                      && store.engine.definitions[trace.definitionID]?.title
                      == state.scheduledImportTitle
              }),
              store.preparedDataImport == nil
        else {
            throw Failure.failed("UI-imported package did not survive a clean restart")
        }
        let persisted = try persistedEngine()
        guard definitionCount(titled: state.baselineTitle, in: persisted) == 0,
              definitionCount(
                  titled: state.scheduledImportTitle,
                  in: persisted
              ) == state.scheduledImportDefinitionCount,
              definitionCount(
                  titled: state.poolImportTitle,
                  in: persisted
              ) == state.poolImportDefinitionCount,
              definitionCount(
                  titled: state.returnedImportTitle,
                  in: persisted
              ) == state.returnedImportDefinitionCount,
              definitionCount(
                  titled: Self.retiredImportTitle,
                  in: persisted
              ) == state.retiredImportDefinitionCount,
              definitionCount(titled: Self.decoyImportTitle, in: persisted) == 0,
              persisted.taskPool().allSatisfy({
                  $0.definition.title != Self.retiredImportTitle
              })
        else {
            throw Failure.failed("restarted UI import did not match SQLite")
        }
    }

    private func setupIntegrityFixtures(on store: NoonmarkStore) throws {
        var timeline = try E2EFixtureTimeline(
            store: store,
            eventCount: 5
        )
        let baselineEngine = NoonmarkEngine()
        let baselineAt = try timeline.nextInstant()
        _ = try baselineEngine.createPoolTask(
            title: Self.integrityBaselineTitle,
            descriptionText: "Malformed imports must never replace this baseline.",
            now: baselineAt
        )

        let malformedEngine = NoonmarkEngine()
        let malformedChainID = try malformedEngine.createPoolTask(
            title: Self.malformedPayloadTitle,
            descriptionText: "This task exists only inside malformed v2 fixtures.",
            now: try timeline.nextInstant()
        )
        _ = try malformedEngine.addPlannedSubtask(
            chainID: malformedChainID,
            title: "Malformed planned-subtask fixture",
            now: try timeline.nextInstant()
        )
        let malformedTraceID = try malformedEngine.scheduleFromPool(
            chainID: malformedChainID,
            date: timeline.today,
            today: timeline.today,
            now: try timeline.nextInstant()
        )
        _ = try malformedEngine.addSubtask(
            traceID: malformedTraceID,
            title: "Malformed Subtask fixture",
            now: try timeline.nextInstant()
        )
        _ = try timeline.finish()

        try store.save(baselineEngine, mutationAt: baselineAt)
        store.engine = baselineEngine

        let baseline = try integrityBaselineEvidence(on: store)
        guard definitionCount(
            titled: Self.integrityBaselineTitle,
            in: store
        ) == 1,
            definitionCount(
                titled: Self.malformedPayloadTitle,
                in: store
            ) == 0,
            baseline.snapshot.definitions.count == 1,
            baseline.snapshot.traces.isEmpty,
            baseline.snapshot.subtasks.isEmpty
        else {
            throw Failure.failed(
                "integrity setup did not commit the isolated baseline"
            )
        }

        let canonical = try NoonmarkDataPackage.encode(
            malformedEngine.snapshot()
        )
        let envelope = try dataPackageEnvelope(from: canonical)
        var fixtureSHA256ByScenarioID: [String: String] = [:]
        for scenario in IntegrityCase.allCases {
            let fixture = try malformedIntegrityFixture(
                envelope: envelope,
                scenario: scenario
            )
            let url = integrityFixtureURL(for: scenario)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fixture.write(to: url, options: .atomic)
            let persistedFixture = try Data(contentsOf: url)
            guard persistedFixture == fixture,
                  try canonicalJSON(
                      JSONSerialization.jsonObject(with: persistedFixture)
                  ) == persistedFixture
            else {
                throw Failure.failed(
                    "integrity fixture was not persisted as canonical JSON: "
                        + scenario.rawValue
                )
            }
            fixtureSHA256ByScenarioID[scenario.rawValue] = sha256(
                persistedFixture
            )
        }

        let failureMessage = AppPresentation(
            language: store.engine.preferences.language
        ).failureMessage(for: .dataTransfer)
        try writeIntegrityState(
            IntegrityProbeState(
                formatVersion: Self.currentDataPackageFormatVersion,
                baselineTitle: Self.integrityBaselineTitle,
                malformedPayloadTitle: Self.malformedPayloadTitle,
                scenarioIDs: IntegrityCase.allCases.map(\.rawValue),
                completedScenarioIDs: [],
                fixtureSHA256ByScenarioID: fixtureSHA256ByScenarioID,
                recoverableFailureMessage: failureMessage,
                baselineSnapshotSHA256: baseline.snapshotSHA256,
                baselineJournalSHA256: baseline.journalSHA256,
                baselineJournalCount: baseline.journalEntries.count
            )
        )
    }

    private func exerciseIntegrityFailures(
        on store: NoonmarkStore
    ) async throws {
        let state = try readIntegrityState()
        try validateIntegrityState(state, expectsCompletedScenarios: false)
        let baseline = try integrityBaselineEvidence(on: store)
        try validateIntegrityBaseline(
            baseline,
            state: state,
            failure: "integrity exercise did not start from setup baseline"
        )

        let mainWindow = try await visibleMainWindow()
        try await activate(mainWindow)
        let panelTraceURL = resultURL
            .deletingLastPathComponent()
            .appendingPathComponent("panel-events.txt")
        try? FileManager.default.removeItem(at: panelTraceURL)

        var completedScenarioIDs: [String] = []
        for scenario in IntegrityCase.allCases {
            let scenarioURL = integrityFixtureURL(for: scenario)
            guard scenarioURL.path.hasPrefix("/tmp/"),
                  FileManager.default.fileExists(atPath: scenarioURL.path),
                  state.fixtureSHA256ByScenarioID[scenario.rawValue]
                  == sha256(try Data(contentsOf: scenarioURL))
            else {
                throw Failure.failed(
                    "integrity fixture is missing or changed: "
                        + scenario.rawValue
                )
            }

            let previousFailureID = store.operationFailureNotice?.id
            try await activate(mainWindow)
            try await chooseFixtureThroughFileMenu(
                fixtureURL: scenarioURL,
                mainWindow: mainWindow,
                panelTraceURL: panelTraceURL,
                interactionLabel: scenario.rawValue
            )
            try await waitForIntegrityFailure(
                store: store,
                previousFailureID: previousFailureID,
                expectedMessage: state.recoverableFailureMessage,
                scenario: scenario
            )

            let afterFailure = try integrityBaselineEvidence(on: store)
            try validateIntegrityBaseline(
                afterFailure,
                state: state,
                failure: "malformed import changed baseline: \(scenario.rawValue)"
            )
            guard afterFailure.snapshot == baseline.snapshot,
                  afterFailure.journalEntries == baseline.journalEntries,
                  store.preparedDataImport == nil,
                  definitionCount(
                      titled: Self.malformedPayloadTitle,
                      in: store
                  ) == 0
            else {
                throw Failure.failed(
                    "malformed import escaped its fail-closed boundary: "
                        + scenario.rawValue
                )
            }

            completedScenarioIDs.append(scenario.rawValue)
            store.dismissOperationFailure()
            try await waitUntil(
                "recoverable import error did not dismiss: \(scenario.rawValue)"
            ) {
                store.operationFailureNotice == nil
                    && AppViewTreeE2E.hasNoVisibleView(
                        identifier: "app.operation-failure"
                    )
            }
        }

        try writeIntegrityState(
            IntegrityProbeState(
                formatVersion: state.formatVersion,
                baselineTitle: state.baselineTitle,
                malformedPayloadTitle: state.malformedPayloadTitle,
                scenarioIDs: state.scenarioIDs,
                completedScenarioIDs: completedScenarioIDs,
                fixtureSHA256ByScenarioID: state
                    .fixtureSHA256ByScenarioID,
                recoverableFailureMessage: state
                    .recoverableFailureMessage,
                baselineSnapshotSHA256: state.baselineSnapshotSHA256,
                baselineJournalSHA256: state.baselineJournalSHA256,
                baselineJournalCount: state.baselineJournalCount
            )
        )
    }

    private func verifyIntegrityRestart(on store: NoonmarkStore) throws {
        let state = try readIntegrityState()
        try validateIntegrityState(state, expectsCompletedScenarios: true)
        let restarted = try integrityBaselineEvidence(on: store)
        try validateIntegrityBaseline(
            restarted,
            state: state,
            failure: "malformed-import baseline changed after restart"
        )
        guard definitionCount(titled: state.baselineTitle, in: store) == 1,
              definitionCount(
                  titled: state.malformedPayloadTitle,
                  in: store
              ) == 0,
              store.preparedDataImport == nil,
              store.operationFailureNotice == nil,
              AppViewTreeE2E.hasNoVisibleView(
                  identifier: "data-import.confirmation"
              ),
              AppViewTreeE2E.hasNoAttachedSheets()
        else {
            throw Failure.failed(
                "malformed import left UI or task state after restart"
            )
        }
    }

    private func waitForIntegrityFailure(
        store: NoonmarkStore,
        previousFailureID: UUID?,
        expectedMessage: String,
        scenario: IntegrityCase
    ) async throws {
        try await waitUntil(
            "malformed import did not present a recoverable error: "
                + scenario.rawValue
        ) {
            guard let notice = store.operationFailureNotice,
                  previousFailureID.map({ notice.id != $0 }) ?? true,
                  notice.context == .dataTransfer,
                  notice.message == expectedMessage,
                  let failureView = AppViewTreeE2E.view(
                      identifier: "app.operation-failure"
                  )
            else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: failureView)
                == expectedMessage
                && store.preparedDataImport == nil
                && AppViewTreeE2E.hasNoVisibleView(
                    identifier: "data-import.confirmation"
                )
                && AppViewTreeE2E.hasNoAttachedSheets()
        }
    }

    private func dataPackageEnvelope(
        from canonicalData: Data
    ) throws -> [String: Any] {
        guard let envelope = try JSONSerialization.jsonObject(
            with: canonicalData
        ) as? [String: Any],
            envelope["formatVersion"] as? Int
            == Self.currentDataPackageFormatVersion,
            envelope["snapshot"] is [String: Any],
            try canonicalJSON(envelope) == canonicalData
        else {
            throw Failure.failed(
                "integrity fixture source was not a canonical current DataPackage envelope"
            )
        }
        return envelope
    }

    private func malformedIntegrityFixture(
        envelope: [String: Any],
        scenario: IntegrityCase
    ) throws -> Data {
        var envelope = envelope
        guard var snapshot = envelope["snapshot"] as? [String: Any] else {
            throw Failure.failed("integrity fixture source is missing snapshot")
        }

        switch scenario {
        case .duplicateSubtaskIdentity:
            guard var subtasks = snapshot["subtasks"] as? [[String: Any]],
                  let first = subtasks.first
            else {
                throw Failure.failed(
                    "duplicate-identity fixture has no Subtask source"
                )
            }
            subtasks.append(first)
            snapshot["subtasks"] = subtasks

        case .danglingSubtaskParent:
            guard var subtasks = snapshot["subtasks"] as? [[String: Any]],
                  subtasks.isEmpty == false
            else {
                throw Failure.failed(
                    "dangling-parent fixture has no Subtask source"
                )
            }
            subtasks[0]["traceID"] = "93400000-0000-0000-0000-000000000001"
            snapshot["subtasks"] = subtasks

        case .invalidSubtaskTerminalFacts:
            guard var subtasks = snapshot["subtasks"] as? [[String: Any]],
                  subtasks.isEmpty == false
            else {
                throw Failure.failed(
                    "terminal-facts fixture has no Subtask source"
                )
            }
            subtasks[0]["status"] = SubtaskStatus.completed.rawValue
            subtasks[0].removeValue(forKey: "completedAt")
            subtasks[0].removeValue(forKey: "settledAt")
            snapshot["subtasks"] = subtasks

        case .invalidPlannedSubtaskPosition:
            guard var definitions = snapshot["definitions"]
                as? [[String: Any]],
                definitions.isEmpty == false,
                var plannedSubtasks = definitions[0]["plannedSubtasks"]
                as? [[String: Any]],
                plannedSubtasks.isEmpty == false
            else {
                throw Failure.failed(
                    "planned-position fixture has no planned Subtask source"
                )
            }
            plannedSubtasks[0]["position"] = 2
            definitions[0]["plannedSubtasks"] = plannedSubtasks
            snapshot["definitions"] = definitions
        }

        envelope["snapshot"] = snapshot
        guard envelope["formatVersion"] as? Int
            == Self.currentDataPackageFormatVersion
        else {
            throw Failure.failed(
                "integrity fixture mutation changed the current DataPackage version"
            )
        }
        return try canonicalJSON(envelope)
    }

    private func integrityBaselineEvidence(
        on store: NoonmarkStore
    ) throws -> IntegrityBaselineEvidence {
        let snapshot = store.engine.snapshot()
        let persisted = try persistedSnapshot()
        guard snapshot == persisted else {
            throw Failure.failed(
                "Store and SQLite snapshots diverged during integrity probe"
            )
        }
        let journalEntries = try SQLiteSyncRepository(
            databaseURL: databaseURL
        ).journalEntries()
        return IntegrityBaselineEvidence(
            snapshot: snapshot,
            snapshotSHA256: sha256(
                try NoonmarkDataPackage.encode(snapshot)
            ),
            journalEntries: journalEntries,
            journalSHA256: try journalSHA256(journalEntries)
        )
    }

    private func validateIntegrityBaseline(
        _ evidence: IntegrityBaselineEvidence,
        state: IntegrityProbeState,
        failure: String
    ) throws {
        let baselineCount = evidence.snapshot.definitions.filter {
            $0.title == state.baselineTitle
        }.count
        let malformedCount = evidence.snapshot.definitions.filter {
            $0.title == state.malformedPayloadTitle
        }.count
        guard evidence.snapshotSHA256 == state.baselineSnapshotSHA256,
              evidence.journalSHA256 == state.baselineJournalSHA256,
              evidence.journalEntries.count == state.baselineJournalCount,
              baselineCount == 1,
              malformedCount == 0,
              evidence.snapshot.definitions.count == 1,
              evidence.snapshot.traces.isEmpty,
              evidence.snapshot.subtasks.isEmpty
        else {
            throw Failure.failed(failure)
        }
    }

    private func validateIntegrityState(
        _ state: IntegrityProbeState,
        expectsCompletedScenarios: Bool
    ) throws {
        let expectedScenarioIDs = IntegrityCase.allCases.map(\.rawValue)
        guard state.formatVersion == Self.currentDataPackageFormatVersion,
              state.baselineTitle == Self.integrityBaselineTitle,
              state.malformedPayloadTitle == Self.malformedPayloadTitle,
              state.scenarioIDs == expectedScenarioIDs,
              Set(state.fixtureSHA256ByScenarioID.keys)
              == Set(expectedScenarioIDs),
              state.fixtureSHA256ByScenarioID.values.allSatisfy({
                  $0.count == 64
              }),
              state.recoverableFailureMessage.isEmpty == false,
              state.baselineSnapshotSHA256.count == 64,
              state.baselineJournalSHA256.count == 64,
              state.baselineJournalCount > 0,
              state.completedScenarioIDs
              == (expectsCompletedScenarios ? expectedScenarioIDs : [])
        else {
            throw Failure.failed(
                "integrity probe state is missing or inconsistent"
            )
        }
    }

    private func readIntegrityState() throws -> IntegrityProbeState {
        try JSONDecoder().decode(
            IntegrityProbeState.self,
            from: Data(contentsOf: stateURL)
        )
    }

    private func writeIntegrityState(
        _ state: IntegrityProbeState
    ) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private func journalSHA256(
        _ entries: [SyncJournalEntry]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let seconds = date.timeIntervalSinceReferenceDate
            guard seconds.isFinite else {
                throw Failure.failed(
                    "sync journal contains a nonfinite timestamp"
                )
            }
            var container = encoder.singleValueContainer()
            try container.encode(seconds.bitPattern)
        }
        encoder.outputFormatting = [.sortedKeys]
        return sha256(try encoder.encode(entries))
    }

    private func canonicalJSON(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw Failure.failed(
                "integrity fixture contains an invalid JSON object"
            )
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func integrityFixtureURL(
        for scenario: IntegrityCase
    ) -> URL {
        fixtureURL
            .deletingLastPathComponent()
            .appendingPathComponent(scenario.fileName)
    }

    private func validatePreparedImportSummary(_ store: NoonmarkStore) throws {
        guard let summary = store.preparedDataImport?.summary,
              summary.dayCount == 1,
              summary.taskCount == 3,
              summary.traceCount == 1,
              summary.subtaskCount == 0,
              summary.completedTraceCount == 0,
              summary.unfinishedTraceCount == 0
        else {
            throw Failure.failed(
                "import preview exposed internal cancellation facts or inflated task identities"
            )
        }
    }

    private func chooseFixtureThroughFileMenu(
        fixtureURL selectedFixtureURL: URL? = nil,
        mainWindow: NSWindow,
        panelTraceURL: URL,
        interactionLabel: String
    ) async throws {
        guard let openPanelProtocolDirectory else {
            throw Failure.failed(
                "data-import exercise lacked its external Open-panel protocol directory"
            )
        }
        let interaction = OpenPanelKeyboardSelection(
            fixtureURL: selectedFixtureURL ?? fixtureURL,
            traceURL: panelTraceURL,
            interactionLabel: interactionLabel,
            protocolDirectory: openPanelProtocolDirectory
        )
        interaction.start()
        defer { interaction.stop() }

        let item = try menuItem(action: NoonmarkMenuAction.importData)
        let expectedModifiers: NSEvent.ModifierFlags = [.command, .shift]
        guard item.keyEquivalent == "i",
              normalizedModifiers(item.keyEquivalentModifierMask)
              == normalizedModifiers(expectedModifiers),
              validate(item),
              let event = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: expectedModifiers,
                  timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: mainWindow.windowNumber,
                  context: nil,
                  characters: "I",
                  charactersIgnoringModifiers: "i",
                  isARepeat: false,
                  keyCode: 34
              ),
              NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        else {
            throw Failure.failed("File > Import keyboard command was unavailable")
        }
        interaction.recordMenuActionReturned()
        if let failure = interaction.failure {
            throw Failure.failed(failure)
        }
        guard interaction.didTypeExactFixturePathUsingInput,
              interaction.readyPublicationCount == 1,
              interaction.exactURLValidationCount == 1
        else {
            throw Failure.failed(
                "NSOpenPanel closed without one exact external Open action"
            )
        }
        try await interaction.waitForHelperCompletion()
        try await waitForOpenPanelSettlement(mainWindow: mainWindow)
        interaction.recordPostModalSettlement(mainWindow: mainWindow)
    }

    private func waitForOpenPanelSettlement(
        mainWindow: NSWindow
    ) async throws {
        try await waitUntil(
            "NSOpenPanel modal transition did not settle"
        ) {
            guard NSApp.modalWindow == nil,
                  NSApp.isActive,
                  mainWindow.isVisible,
                  let keyWindow = NSApp.keyWindow,
                  keyWindow === mainWindow || keyWindow.sheetParent === mainWindow
            else {
                return false
            }
            let visibleOpenPanel = NSApp.windows.contains { window in
                window is NSOpenPanel && window.isVisible
            }
            return visibleOpenPanel == false
        }
    }

    private func waitForConfirmation(
        store: NoonmarkStore,
        failure: String
    ) async throws {
        try await waitUntil(failure) {
            store.preparedDataImport?.sourceURL.standardizedFileURL
                == fixtureURL.standardizedFileURL
                && AppViewTreeE2E.view(
                    identifier: "data-import.confirmation"
                ) != nil
        }
    }

    private func clickConfirmationButton(
        identifier: String,
        title: String
    ) async throws {
        for _ in 0 ..< 100 {
            if let target = confirmationClickTarget(
                identifier: identifier,
                title: title
            ) {
                let input = try WindowServerInputDriver()
                let resolveTarget = { () throws -> WindowServerInputDriver.PointerCoordinate in
                    guard let currentTarget = confirmationClickTarget(
                        identifier: identifier,
                        title: title
                    ), currentTarget.window === target.window
                    else {
                        throw Failure.failed(
                            "confirmation target changed before mouseDown: \(identifier)"
                        )
                    }
                    return try input.pointerCoordinate(
                        quartzPoint: currentTarget.point,
                        in: currentTarget.window
                    )
                }
                let coordinate = try input.pointerCoordinate(
                    quartzPoint: target.point,
                    in: target.window
                )
                try await input.postClick(
                    at: coordinate,
                    modifiers: [],
                    resolveTarget: resolveTarget
                )
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.failed(
            "confirmation button was not AX-visible and enabled: \(identifier)"
        )
    }

    private func confirmationClickTarget(
        identifier: String,
        title: String
    ) -> ConfirmationClickTarget? {
        guard NSApp.isActive,
              let window = NSApp.keyWindow,
              window.sheetParent != nil,
              let button = ReadOnlyAccessibilityTarget.uniqueButton(
                  identifier: identifier,
                  label: title,
                  enabled: true,
                  in: window
              ),
            let frame = button.frame,
            frame.isNull == false,
            frame.isInfinite == false,
            frame.width >= 2,
            frame.height >= 2
        else {
            return nil
        }
        return ConfirmationClickTarget(
            window: window,
            frame: frame,
            point: CGPoint(x: frame.midX, y: frame.midY)
        )
    }

    private func menuItem(action: Selector) throws -> NSMenuItem {
        let matches = NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .filter { $0.action == action } ?? []
        guard matches.count == 1, let item = matches.first else {
            throw Failure.failed("File menu import action was missing or duplicated")
        }
        return item
    }

    private func validate(_ item: NSMenuItem) -> Bool {
        guard let validator = item.target as? NSMenuItemValidation else {
            return item.isEnabled
        }
        let enabled = validator.validateMenuItem(item)
        item.isEnabled = enabled
        return enabled
    }

    private func definitionCount(titled title: String, in store: NoonmarkStore) -> Int {
        store.engine.definitions.values.filter { $0.title == title }.count
    }

    private func definitionCount(titled title: String, in engine: NoonmarkEngine) -> Int {
        engine.definitions.values.filter { $0.title == title }.count
    }

    private func definitionCount(titled title: String, in snapshot: NoonmarkSnapshot) -> Int {
        snapshot.definitions.filter { $0.title == title }.count
    }

    private var decoyURL: URL {
        fixtureURL
            .deletingLastPathComponent()
            .appendingPathComponent("0-decoy.json")
    }

    private func persistedSnapshot() throws -> NoonmarkSnapshot {
        try persistedEngine().snapshot()
    }

    private func persistedEngine() throws -> NoonmarkEngine {
        try SQLiteEngineRepository(databaseURL: databaseURL).load()
    }

    private func visibleMainWindow() async throws -> NSWindow {
        var resolved: NSWindow?
        try await waitUntil("main window did not become visible") {
            resolved = NSApp.windows.first {
                $0 is NoonmarkWindow && $0.isVisible && $0.isMiniaturized == false
            }
            return resolved != nil
        }
        guard let resolved else {
            throw Failure.failed("main window disappeared")
        }
        return resolved
    }

    private func activate(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil("main window did not remain visible for menu input") {
            window.isVisible && window.isMiniaturized == false
        }
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

    private func normalizedModifiers(
        _ modifiers: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        modifiers.intersection(.deviceIndependentFlagsMask)
    }

    private func writeState(_ state: ProbeState) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }

    private func writeWindowDump() throws {
        let lines = NSApp.windows.map { window in
            "window=\(window.windowNumber) type=\(String(describing: type(of: window))) "
                + "visible=\(window.isVisible) key=\(window.isKeyWindow) "
                + "title=\(window.title) frame=\(NSStringFromRect(window.frame))"
        }
        try lines.joined(separator: "\n").write(
            to: resultURL.deletingPathExtension().appendingPathExtension("windows.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

@MainActor
private final class OpenPanelKeyboardSelection: NSObject, NSOpenSavePanelDelegate {
    private enum Stage {
        case waitingForPanel
        case waitingForPathEditor
        case waitingForClearedPathEditor
        case waitingForEnteredPath
        case waitingForPathResolution
        case waitingForPanelClose
        case finished
    }

    private let fixtureURL: URL
    private let traceURL: URL
    private let interactionLabel: String
    private let protocolDirectory: URL
    private var timer: Timer?
    private weak var panel: NSOpenPanel?
    private var inputDriver: WindowServerInputDriver?
    private var pathEditor: AXUIElement?
    private var ready: OpenPanelPhysicalInputReady?
    private var stage = Stage.waitingForPanel
    private var tickCount = 0

    private(set) var failure: String?
    private(set) var didTypeExactFixturePathUsingInput = false
    private(set) var readyPublicationCount = 0
    private(set) var exactURLValidationCount = 0

    init(
        fixtureURL: URL,
        traceURL: URL,
        interactionLabel: String,
        protocolDirectory: URL
    ) {
        self.fixtureURL = fixtureURL
        self.traceURL = traceURL
        self.interactionLabel = interactionLabel
        self.protocolDirectory = protocolDirectory
    }

    func start() {
        let timer = Timer(
            timeInterval: 0.05,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        trace("timer-started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if panel?.delegate === self {
            panel?.delegate = nil
        }
    }

    func recordPostModalSettlement(mainWindow: NSWindow) {
        let keyWindowNumber = NSApp.keyWindow?.windowNumber.description ?? "nil"
        let visibleOpenPanelCount = NSApp.windows.filter {
            $0 is NSOpenPanel && $0.isVisible
        }.count
        trace(
            "post-modal-settled main-window=\(mainWindow.windowNumber) "
                + "key-window=\(keyWindowNumber) "
                + "visible-open-panels=\(visibleOpenPanelCount)"
        )
    }

    func waitForHelperCompletion() async throws {
        guard let ready else {
            throw DataImportPanelInputError.missingOpenPanelReady
        }
        let completionURL = protocolDirectory.appendingPathComponent(
            "\(interactionLabel).completion.json"
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: completionURL.path) {
                let completion = try OpenPanelPhysicalInputProtocolFile
                    .readCompletion(from: completionURL)
                guard completion.launchToken == ready.launchToken,
                      completion.targetPID == ready.targetPID,
                      completion.panelWindowNumber == ready.panelWindowNumber,
                      completion.selectedPath == ready.selectedPath,
                      completion.interactionLabel == ready.interactionLabel,
                      completion.helperPID != ready.targetPID,
                      completion.source == "cghidEventTap",
                      completion.leftButtonUp
                else {
                    throw DataImportPanelInputError.helperCompletionMismatch
                }
                trace(
                    "external-helper-completed-physical-open "
                        + "helper-pid=\(completion.helperPID) "
                        + "window=\(completion.panelWindowNumber) "
                        + "button=\(completion.buttonTitle) left-button-up=true"
                )
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw DataImportPanelInputError.helperCompletionTimedOut
    }

    @objc private func tick() {
        tickCount += 1
        if tickCount > 240 {
            fail("timed out while driving the real NSOpenPanel")
            return
        }

        do {
            try advanceInteraction()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func advanceInteraction() throws {
        switch stage {
        case .waitingForPanel:
            try waitForPanel()
        case .waitingForPathEditor:
            try waitForPathEditor()
        case .waitingForClearedPathEditor:
            try waitForClearedPathEditor()
        case .waitingForEnteredPath:
            try waitForEnteredPath()
        case .waitingForPathResolution:
            try waitForPathResolution()
        case .waitingForPanelClose:
            waitForPanelClose()
        case .finished:
            stop()
        }
    }

    private func waitForPanel() throws {
        guard let panel = (NSApp.modalWindow as? NSOpenPanel)
            ?? NSApp.windows.compactMap({ $0 as? NSOpenPanel }).first(where: \.isVisible)
        else {
            return
        }
        guard panel.delegate == nil else {
            throw DataImportPanelInputError.unexpectedOpenPanelDelegate
        }
        self.panel = panel
        panel.delegate = self
        trace(
            "panel-visible title=\(panel.title ?? "") "
                + "key=\(panel.isKeyWindow) responder="
                + responderDescription(panel.firstResponder)
        )
        guard panel.isKeyWindow, NSApp.isActive else { return }
        try postHIDKey(
            keyCode: 5,
            modifiers: [.command, .shift]
        )
        stage = .waitingForPathEditor
        trace("sent-shift-command-g")
    }

    private func waitForPathEditor() throws {
        guard let inputWindow = expectedInputWindow else { return }
        guard let editor = ReadOnlyAccessibilityTarget.focusedTextEntry(
            in: inputWindow
        ) else {
            if tickCount.isMultiple(of: 20), let panel {
                traceWindowState(panel: panel)
                trace("waiting-focused-path-editor")
            }
            return
        }
        pathEditor = editor
        try postHIDKey(keyCode: 0, modifiers: .command)
        try postHIDKey(keyCode: 51)
        stage = .waitingForClearedPathEditor
        trace(
            "focused-path-editor role="
                + "\(ReadOnlyAccessibilityTarget.string(editor, kAXRoleAttribute) ?? "nil") "
                + "and-cleared-current-value"
        )
    }

    private func waitForClearedPathEditor() throws {
        guard let inputWindow = expectedInputWindow,
              let pathEditor
        else {
            return
        }
        guard ReadOnlyAccessibilityTarget.focusedElementMatches(
            pathEditor,
            in: inputWindow
        ) else {
            if tickCount.isMultiple(of: 20) {
                trace("waiting-path-editor-refocus")
            }
            return
        }
        guard ReadOnlyAccessibilityTarget.string(
            pathEditor,
            kAXValueAttribute
        )?.isEmpty == true else {
            if tickCount.isMultiple(of: 20) {
                trace(
                    "waiting-cleared-path-editor value="
                        + (
                            ReadOnlyAccessibilityTarget.string(
                                pathEditor,
                                kAXValueAttribute
                            ) ?? "nil"
                        )
                )
            }
            return
        }
        try input().typeUnicode(fixtureURL.path)
        stage = .waitingForEnteredPath
        trace("typed-fixture-path \(fixtureURL.path)")
    }

    private func waitForEnteredPath() throws {
        guard let inputWindow = expectedInputWindow,
              let pathEditor
        else {
            return
        }
        guard ReadOnlyAccessibilityTarget.focusedElementMatches(
            pathEditor,
            in: inputWindow
        ),
              ReadOnlyAccessibilityTarget.string(
                  pathEditor,
                  kAXValueAttribute
              ) == fixtureURL.path
        else {
            if tickCount.isMultiple(of: 20) {
                trace(
                    "waiting-entered-path value="
                        + (
                            ReadOnlyAccessibilityTarget.string(
                                pathEditor,
                                kAXValueAttribute
                            ) ?? "nil"
                        )
                )
            }
            return
        }
        didTypeExactFixturePathUsingInput = true
        try postHIDKey(keyCode: 36)
        stage = .waitingForPathResolution
        trace("verified-entered-path-and-sent-go-return")
    }

    private func waitForPathResolution() throws {
        guard let panel else {
            stage = .finished
            trace("panel-released-after-path-return")
            return
        }
        guard panel.isVisible else {
            stage = .finished
            trace("panel-closed-after-path-return")
            return
        }
        guard panel.isKeyWindow, NSApp.isActive else { return }
        let pathEditorRemainsFocused =
            pathEditorIsFocusedInExpectedWindow()
        if pathEditorRemainsFocused {
            if tickCount.isMultiple(of: 20) {
                let currentValue = pathEditor.flatMap {
                    ReadOnlyAccessibilityTarget.string(
                        $0,
                        kAXValueAttribute
                    )
                } ?? "nil"
                trace(
                    "waiting-path-resolution value="
                        + currentValue
                )
            }
            return
        }
        let selectedURLs = Set(panel.urls.map(canonicalFileURL))
        guard selectedURLs == Set([canonicalFileURL(fixtureURL)]) else {
            if tickCount.isMultiple(of: 20) {
                trace(
                    "waiting-exact-file-selection urls="
                        + String(describing: panel.urls.map(\.path))
                )
            }
            return
        }
        guard readyPublicationCount == 0,
              exactURLValidationCount == 0,
              NSApp.modalWindow === panel,
              panel.isVisible,
              panel.isKeyWindow
        else {
            throw DataImportPanelInputError.publicOpenActionStateInvalid
        }
        let ready = try OpenPanelPhysicalInputReady(
            launchToken: UUID().uuidString,
            targetPID: Int(ProcessInfo.processInfo.processIdentifier),
            appPath: Bundle.main.bundleURL.standardizedFileURL
                .resolvingSymlinksInPath().path,
            panelWindowNumber: panel.windowNumber,
            panelLayer: Int(panel.level.rawValue),
            panelTitle: panel.title,
            selectedPath: canonicalFileURL(fixtureURL).path,
            interactionLabel: interactionLabel
        )
        let readyURL = protocolDirectory.appendingPathComponent(
            "\(interactionLabel).ready.json"
        )
        try OpenPanelPhysicalInputProtocolFile.publish(ready, to: readyURL)
        self.ready = ready
        readyPublicationCount = 1
        stage = .waitingForPanelClose
        trace(
            "exact-file-selected-and-published-external-open-ready "
                + "window=\(panel.windowNumber) "
                + "token=\(ready.launchToken) "
                + "urls=\(String(describing: panel.urls.map(\.path)))"
        )
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard let validatingPanel = sender as? NSOpenPanel,
              panel === validatingPanel,
              stage == .waitingForPanelClose,
              readyPublicationCount == 1,
              exactURLValidationCount == 0,
              NSApp.modalWindow === validatingPanel,
              validatingPanel.isVisible,
              canonicalFileURL(url) == canonicalFileURL(fixtureURL),
              Set(validatingPanel.urls.map(canonicalFileURL))
              == Set([canonicalFileURL(fixtureURL)])
        else {
            throw DataImportPanelInputError.publicOpenActionValidationFailed
        }
        exactURLValidationCount = 1
        trace(
            "external-physical-open-validated-exact-url "
                + "window=\(validatingPanel.windowNumber) "
                + "url=\(canonicalFileURL(url).path)"
        )
    }

    func recordMenuActionReturned() {
        guard let panel,
              readyPublicationCount == 1,
              exactURLValidationCount == 1,
              panel.isVisible == false,
              NSApp.modalWindow !== panel,
              Set(panel.urls.map(canonicalFileURL))
              == Set([canonicalFileURL(fixtureURL)])
        else {
            failure = "NSOpenPanel external Open action lacked its modal return acknowledgement"
            return
        }
        trace(
            "external-physical-open-returned-from-modal "
                + "window=\(panel.windowNumber) validation-count=1"
        )
    }

    private func canonicalFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func waitForPanelClose() {
        guard let panel else {
            stage = .finished
            trace("panel-released")
            return
        }
        guard panel.isVisible else {
            stage = .finished
            trace("panel-closed")
            return
        }
    }

    private var expectedInputWindow: NSWindow? {
        guard let panel else { return nil }
        let keyWindow = NSApp.keyWindow
        guard panel.isVisible,
              NSApp.isActive,
              let keyWindow,
              keyWindow === panel || keyWindow.sheetParent === panel
        else {
            return nil
        }
        return keyWindow
    }

    private func pathEditorIsFocusedInExpectedWindow() -> Bool {
        guard let pathEditor, let inputWindow = expectedInputWindow else {
            return false
        }
        return ReadOnlyAccessibilityTarget.focusedElementMatches(
            pathEditor,
            in: inputWindow
        )
    }

    private func postHIDKey(
        keyCode: CGKeyCode,
        modifiers: NSEvent.ModifierFlags = []
    ) throws {
        guard let panel,
              panel.isVisible,
              panel.isKeyWindow || NSApp.keyWindow?.sheetParent === panel,
              NSApp.isActive
        else {
            throw DataImportPanelInputError.inputTargetUnavailable
        }
        let driver: WindowServerInputDriver
        if let inputDriver {
            driver = inputDriver
        } else {
            driver = try WindowServerInputDriver()
            inputDriver = driver
        }
        try driver.postKey(keyCode: keyCode, modifiers: modifiers)
    }

    private func input() throws -> WindowServerInputDriver {
        if let inputDriver {
            return inputDriver
        }
        let driver = try WindowServerInputDriver()
        inputDriver = driver
        return driver
    }

    private func fail(_ message: String) {
        if let panel {
            traceWindowState(panel: panel)
        }
        trace("failed \(message)")
        failure = message
        stage = .finished
        if let panel, panel.isVisible {
            panel.cancel(nil)
        }
        stop()
    }

    private func traceWindowState(panel: NSOpenPanel) {
        var windows: [NSWindow] = [panel]
        windows.append(contentsOf: panel.childWindows ?? [])
        if let attachedSheet = panel.attachedSheet {
            windows.append(attachedSheet)
        }
        if let keyWindow = NSApp.keyWindow {
            windows.append(keyWindow)
        }
        let descriptions = windows.map { window in
            "\(String(describing: type(of: window)))"
                + "[title=\(window.title),visible=\(window.isVisible),"
                + "key=\(window.isKeyWindow),"
                + "sheetParent=\(window.sheetParent === panel),"
                + "responder=\(responderDescription(window.firstResponder))]"
        }
        trace(
            "waiting-path-window modal=\(NSApp.modalWindow === panel) "
                + "urls=\(String(describing: panel.urls.map(\.path))) "
                + descriptions.joined(separator: " | ")
        )
    }

    private func responderDescription(_ responder: NSResponder?) -> String {
        responder.map { String(describing: type(of: $0)) } ?? "nil"
    }

    private func trace(_ message: String) {
        let line = "\(interactionLabel) \(tickCount) \(message)\n"
        try? FileManager.default.createDirectory(
            at: traceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: traceURL.path) == false {
            try? Data().write(to: traceURL, options: .atomic)
        }
        guard let handle = try? FileHandle(forWritingTo: traceURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            return
        }
    }
}

private enum DataImportPanelInputError: LocalizedError {
    case inputTargetUnavailable
    case unexpectedOpenPanelDelegate
    case publicOpenActionStateInvalid
    case publicOpenActionValidationFailed
    case missingOpenPanelReady
    case helperCompletionMismatch
    case helperCompletionTimedOut

    var errorDescription: String? {
        switch self {
        case .inputTargetUnavailable:
            "NSOpenPanel was not the active key window for real keyboard input"
        case .unexpectedOpenPanelDelegate:
            "NSOpenPanel had an unexpected delegate before E2E input"
        case .publicOpenActionStateInvalid:
            "NSOpenPanel public Open action was not requested exactly once"
        case .publicOpenActionValidationFailed:
            "NSOpenPanel public Open action did not validate the exact fixture URL"
        case .missingOpenPanelReady:
            "NSOpenPanel did not publish its exact external-input ready state"
        case .helperCompletionMismatch:
            "external Open-panel Helper completion did not match the exact ready state"
        case .helperCompletionTimedOut:
            "external Open-panel Helper did not publish completion"
        }
    }
}
