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

struct LaunchAutomation {
    var actions: [@MainActor (NoonmarkStore, FixedNaturalDayEnvironment?) -> Void]
    var quitsAfterAutomation: Bool

    @MainActor
    static func fromCommandLine() -> LaunchAutomation? {
        guard AppLaunchArguments.permitsInternalArguments else { return nil }
        var actions: [@MainActor (NoonmarkStore, FixedNaturalDayEnvironment?) -> Void] = []

        if let naturalDayAutomation = NaturalDayRolloverE2EAutomation.fromCommandLine() {
            actions.append { store, environment in
                naturalDayAutomation.run(
                    on: store,
                    environment: environment
                )
            }
        }
        if let mutationClockAutomation = MutationClockE2EAutomation.fromCommandLine() {
            actions.append { store, environment in
                mutationClockAutomation.run(
                    on: store,
                    environment: environment
                )
            }
        }

        append(ProviderE2EAutomation.fromCommandLine(), to: &actions)
        append(DataRootProcessLeaseE2EAutomation.fromCommandLine(), to: &actions)
        append(ZhulongStreamE2EAutomation.fromCommandLine(), to: &actions)
        append(ZhulongChatE2EAutomation.fromCommandLine(), to: &actions)
        append(
            ZhulongInlineArtifactE2EAutomation.fromCommandLine(),
            to: &actions
        )
        append(ZhulongProviderSettingsE2EAutomation.fromCommandLine(), to: &actions)
        append(ZhulongTodoDiffE2EAutomation.fromCommandLine(), to: &actions)
        append(ZhulongPersistenceE2EAutomation.fromCommandLine(), to: &actions)
        append(ZhulongExactRecoveryE2EAutomation.fromCommandLine(), to: &actions)
        append(ZhulongPendingGateE2EAutomation.fromCommandLine(), to: &actions)
        append(ClassificationE2EAutomation.fromCommandLine(), to: &actions)
        append(
            AutomaticTaskClassificationE2EAutomation.fromCommandLine(),
            to: &actions
        )
        append(
            AutomaticTaskClassificationLiveE2EAutomation.fromCommandLine(),
            to: &actions
        )
        append(
            AutomaticTaskClassificationLifecycleE2EAutomation.fromCommandLine(),
            to: &actions
        )
        append(
            AutomaticClassificationOperationalClockE2EAutomation
                .fromCommandLine(),
            to: &actions
        )
        append(
            AutomaticClassificationCheckpointSetupE2EAutomation
                .fromCommandLine(),
            to: &actions
        )
        append(
            AutomaticClassificationCheckpointVerifyE2EAutomation
                .fromCommandLine(),
            to: &actions
        )
        append(
            ClassificationQueueE2EAutomation
                .fromCommandLine(),
            to: &actions
        )
        append(
            AutomaticClassificationContentionSetupE2EAutomation
                .fromCommandLine(),
            to: &actions
        )
        append(
            AutomaticClassificationContentionVerifyE2EAutomation
                .fromCommandLine(),
            to: &actions
        )
        append(
            AutomaticClassificationProviderRaceE2EAutomation
                .fromCommandLine(),
            to: &actions
        )
        append(WorkflowE2EAutomation.fromCommandLine(), to: &actions)
        append(LifecycleE2EAutomation.fromCommandLine(), to: &actions)
        append(LifecycleRestartE2EAutomation.fromCommandLine(), to: &actions)
        append(ReactivationAtomicityE2EAutomation.fromCommandLine(), to: &actions)
        append(DataPackageE2EAutomation.fromCommandLine(), to: &actions)
        append(ICloudSyncE2EAutomation.fromCommandLine(), to: &actions)
        append(CloudKitSyncE2EAutomation.fromCommandLine(), to: &actions)
        append(TaskNoteE2EAutomation.fromCommandLine(), to: &actions)
        append(TaskPoolNoteE2EAutomation.fromCommandLine(), to: &actions)
        append(TaskNoteMutationAtomicityE2EAutomation.fromCommandLine(), to: &actions)
        append(TaskNoteMutationAtomicityUIE2EAutomation.fromCommandLine(), to: &actions)
        append(TaskTitleDeleteE2EAutomation.fromCommandLine(), to: &actions)
        append(QuickAddUIE2EAutomation.fromCommandLine(), to: &actions)
        append(ReportedBugsE2EAutomation.fromCommandLine(), to: &actions)
        append(ReviewE2EAutomation.fromCommandLine(), to: &actions)
        append(ReviewEditorLayoutE2EAutomation.fromCommandLine(), to: &actions)
        append(ReviewZhulongEntryE2EAutomation.fromCommandLine(), to: &actions)
        append(ContextMenuActionsE2EAutomation.fromCommandLine(), to: &actions)
        append(UndoE2EAutomation.fromCommandLine(), to: &actions)
        append(CopyUndoPersistenceE2EAutomation.fromCommandLine(), to: &actions)
        append(DateStripE2EAutomation.fromCommandLine(), to: &actions)
        append(KeyboardDateNavigationE2EAutomation.fromCommandLine(), to: &actions)
        append(
            HorizontalPageNavigationE2EAutomation.fromCommandLine(),
            to: &actions
        )
        append(DetailRailLayoutE2EAutomation.fromCommandLine(), to: &actions)
        append(ZhulongNavigationE2EAutomation.fromCommandLine(), to: &actions)
        append(SubtaskMutationE2EAutomation.fromCommandLine(), to: &actions)
        append(SubtaskLayoutE2EAutomation.fromCommandLine(), to: &actions)
        append(SummarySidebarE2EAutomation.fromCommandLine(), to: &actions)
        append(UnfinishedActionE2EAutomation.fromCommandLine(), to: &actions)
        append(ImmediateTaskMutationE2EAutomation.fromCommandLine(), to: &actions)
        append(PoolListLayoutE2EAutomation.fromCommandLine(), to: &actions)
        append(PoolContextMenuActionE2EAutomation.fromCommandLine(), to: &actions)
        append(PoolContextMenuPresentationE2EAutomation.fromCommandLine(), to: &actions)
        append(WindowResizeE2EAutomation.fromCommandLine(), to: &actions)
        append(WindowCloseBehaviorE2EAutomation.fromCommandLine(), to: &actions)
        append(MainWindowChromeE2EAutomation.fromCommandLine(), to: &actions)
        append(HeaderNavigationHitTargetE2EAutomation.fromCommandLine(), to: &actions)
        append(CalendarGridTopologyE2EAutomation.fromCommandLine(), to: &actions)
        append(DatePickerSheetE2EAutomation.fromCommandLine(), to: &actions)
        append(ZhulongTitleGeometryE2EAutomation.fromCommandLine(), to: &actions)
        append(WorkspaceRestorationE2EAutomation.fromCommandLine(), to: &actions)
        append(NativeCommandSurfaceE2EAutomation.fromCommandLine(), to: &actions)
        append(CompletionControlE2EAutomation.fromCommandLine(), to: &actions)
        append(WorkspaceProductivityE2EAutomation.fromCommandLine(), to: &actions)
        append(SelectionFocusVisualE2EAutomation.fromCommandLine(), to: &actions)
        append(DataImportUIE2EAutomation.fromCommandLine(), to: &actions)
        append(PreferencesClockE2EAutomation.fromCommandLine(), to: &actions)
        append(EnglishScreenshotFixtureE2EAutomation.fromCommandLine(), to: &actions)
        append(LaunchSelectionE2EAutomation.fromCommandLine(), to: &actions)
        append(EnglishScreenshotUIE2EAutomation.fromCommandLine(), to: &actions)
        append(UIEntryE2EAutomation.fromCommandLine(), to: &actions)

        if let seedClockResultPath = AppLaunchArguments.value(
            after: "--e2e-seed-clock-result-url"
        ) {
            actions.append { store, _ in
                SeedClockE2EVerifier.run(
                    on: store,
                    resultURL: URL(fileURLWithPath: seedClockResultPath)
                )
            }
        }

        if AppLaunchArguments.contains("--e2e-expand-first-subtask-trace") {
            actions.append { store, _ in
                store.page = .day
                store.selectedDate = store.today
                if let trace = store.engine.getDayTodo(date: store.today).traces.first(where: { store.subtasks(for: $0.id).isEmpty == false }) {
                    store.selectTrace(trace.id)
                    store.expandedTraceIDs.insert(trace.id)
                }
            }
        }

        guard actions.isEmpty == false else { return nil }
        return LaunchAutomation(
            actions: actions,
            quitsAfterAutomation: AppLaunchArguments.contains("--e2e-quit-after-automation")
        )
    }

    @MainActor
    func run(
        on store: NoonmarkStore,
        fixedNaturalDayEnvironment: FixedNaturalDayEnvironment?
    ) {
        actions.forEach { $0(store, fixedNaturalDayEnvironment) }

        if quitsAfterAutomation {
            store.persist()
            E2EApplicationTermination.schedule()
        }
    }

    @MainActor
    private static func append(
        _ automation: (some LaunchAutomationRunnable)?,
        to actions: inout [@MainActor (NoonmarkStore, FixedNaturalDayEnvironment?) -> Void]
    ) {
        guard let automation else { return }
        actions.append { store, _ in
            automation.run(on: store)
        }
    }
}

protocol LaunchAutomationRunnable {
    @MainActor
    func run(on store: NoonmarkStore)
}

@MainActor
enum E2EApplicationTermination {
    static func schedule(after delay: TimeInterval = 0.2) {
        NSLog("Noonmark E2E termination scheduled after %.3f seconds", delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSLog("Noonmark E2E termination request started")
            NSApp.terminate(nil)
            NSLog("Noonmark E2E termination request returned")
        }
    }
}
