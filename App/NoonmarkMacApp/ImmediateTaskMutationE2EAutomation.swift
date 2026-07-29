import AppKit
import Foundation
import NoonmarkCore
import NoonmarkStorage

/// Exercises the exact interaction that used to lose a task title: type into
/// the native title editor and immediately click another workspace row.
@MainActor
struct ImmediateTaskMutationE2EAutomation: LaunchAutomationRunnable {
    private enum Mode: Equatable {
        case immediateEdits
        case returnLifecycle
    }

    private static let dayInitialTitle = "E2E Day original title"
    private static let dayInitialDescription = "快速记录自 Day Todo。"
    private static let daySavedTitle = "E2E Day saved immediately"
    private static let daySavedDescription = "E2E Day description saved immediately"
    private static let daySiblingTitle = "E2E Day click-away target"
    private static let poolInitialTitle = "E2E Pool original title"
    private static let poolSavedTitle = "E2E Pool saved immediately"
    private static let poolSavedDescription = "E2E Pool description saved immediately"
    private static let poolSiblingTitle = "E2E Pool click-away target"
    private static let deletedTitle = "E2E Day delete immediately"
    private static let returnedTitle = "E2E Day return and reschedule"
    private static let returnedInitialDescription = "E2E returned source description"
    private static let returnedSavedDescription = "E2E returned pool description saved"
    private static let returnedSubtaskInitialTitle = "E2E returned subtask original"
    private static let returnedSubtaskSavedTitle = "E2E returned subtask saved immediately"
    private static let deletedDaySubtaskTitle = "E2E delete subtask in Day Todo"
    private static let deletedPoolSubtaskTitle = "E2E delete subtask in Task Pool"
    private static let addedPoolSubtaskTitle = "E2E add subtask after return"

    let resultURL: URL
    let screenshotURL: URL
    private let mode: Mode

    static func fromCommandLine() -> Self? {
        guard let resultPath = AppLaunchArguments.value(
            after: "--e2e-immediate-task-mutation-result-url"
        ), let screenshotPath = AppLaunchArguments.value(
            after: "--e2e-immediate-task-mutation-screenshot-url"
        ) else {
            return nil
        }
        return Self(
            resultURL: URL(fileURLWithPath: resultPath),
            screenshotURL: URL(fileURLWithPath: screenshotPath),
            mode: AppLaunchArguments.contains(
                "--e2e-immediate-task-return-lifecycle"
            ) ? .returnLifecycle : .immediateEdits
        )
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                try await exercise(on: store)
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeResult("failed: \(error.localizedDescription)")
            }
            E2EApplicationTermination.schedule()
        }
    }

    private func exercise(on store: NoonmarkStore) async throws {
        let fixture = try installFixture(on: store)
        let interactionMoment = try store.dayContext.moment()
        guard fixture.latestMutationAt <= interactionMoment.instant else {
            throw Failure.failed(
                "immediate task mutation fixture clock exceeded its UI interaction clock"
            )
        }
        let input = try WindowServerInputDriver()
        guard AppViewTreeE2E.activateMainWindow() else {
            throw Failure.failed("main window could not become active")
        }

        if mode == .immediateEdits {
            try await editTitle(
                TitleEdit(
                    initialTitle: Self.dayInitialTitle,
                    savedTitle: Self.daySavedTitle,
                    clickAwayIdentifier: dayIdentifier(fixture.daySiblingTraceID),
                    selectedAfterClick: {
                        store.selectedTraceID == fixture.daySiblingTraceID
                    },
                    readback: {
                        guard let trace = store.engine.traces[fixture.dayTraceID] else {
                            return nil
                        }
                        return store.engine.definitions[trace.definitionID]?.title
                    }
                ),
                input: input
            )
            store.selectTrace(fixture.dayTraceID)
            try await clearTitleAndRestore(
                restoredTitle: Self.daySavedTitle,
                readback: {
                    guard let trace = store.engine.traces[fixture.dayTraceID] else {
                        return nil
                    }
                    return store.engine.definitions[trace.definitionID]?.title
                },
                placeholder: store.copy.taskTitlePlaceholder,
                input: input
            )

            store.selectTrace(fixture.dayTraceID)
            try await clearDescriptionAndKeepEmpty(
                initialText: Self.dayInitialDescription,
                readback: {
                    store.engine.traces[fixture.dayTraceID]?.descriptionText
                },
                input: input
            )
            try await editDescription(
                TextEdit(
                    initialText: "",
                    savedText: Self.daySavedDescription,
                    clickAwayIdentifier: dayIdentifier(fixture.daySiblingTraceID),
                    selectedAfterClick: {
                        store.selectedTraceID == fixture.daySiblingTraceID
                    },
                    readback: {
                        store.engine.traces[fixture.dayTraceID]?.descriptionText
                    },
                    failureContext: {
                        store.operationFailureNotice?.message ?? "none"
                    }
                ),
                input: input
            )

            store.page = .pool
            store.clearSelection()
            store.selectPool(fixture.poolChainID)
            try await editTitle(
                TitleEdit(
                    initialTitle: Self.poolInitialTitle,
                    savedTitle: Self.poolSavedTitle,
                    clickAwayIdentifier: poolIdentifier(fixture.poolSiblingChainID),
                    selectedAfterClick: {
                        store.selectedPoolChainID == fixture.poolSiblingChainID
                    },
                    readback: {
                        store.currentDefinition(for: fixture.poolChainID)?.title
                    }
                ),
                input: input
            )

            store.selectPool(fixture.poolChainID)
            try await editDescription(
                TextEdit(
                    initialText: "",
                    savedText: Self.poolSavedDescription,
                    clickAwayIdentifier: poolIdentifier(fixture.poolSiblingChainID),
                    selectedAfterClick: {
                        store.selectedPoolChainID == fixture.poolSiblingChainID
                    },
                    readback: {
                        store.currentDefinition(for: fixture.poolChainID)?.descriptionText
                    },
                    failureContext: {
                        store.operationFailureNotice?.message ?? "none"
                    }
                ),
                input: input
            )

            store.page = .day
            store.selectedDate = fixture.today
            store.selectedCalendarDate = fixture.today
            store.clearSelection()
            try await chooseMenuAction(
                .deleteNewCurrentDayTask,
                for: fixture.deletedTraceID,
                from: dayIdentifier(fixture.deletedTraceID),
                store: store,
                input: input
            )
            try await waitUntil("today's newly added task was not deleted through its menu") {
                store.engine.traces[fixture.deletedTraceID]?.status == .cancelledDraft
                    && store.engine.chains[fixture.deletedChainID]?.state == .abandoned
                    && store.engine.getDayTodo(date: fixture.today).traces.contains(where: {
                        $0.id == fixture.deletedTraceID
                    }) == false
                    && store.engine.taskPool().contains(where: {
                        $0.chain.id == fixture.deletedChainID
                    }) == false
            }
            try assertImmediateEditsPersisted(fixture, store: store)
            try captureMainWindow()
            return
        }

        store.page = .day
        store.selectedDate = fixture.today
        store.selectedCalendarDate = fixture.today
        store.selectTrace(fixture.returnedTraceID)
        try await editInlineSubtaskTitle(
            subtaskID: fixture.returnedSubtaskID,
            initialTitle: Self.returnedSubtaskInitialTitle,
            savedTitle: Self.returnedSubtaskSavedTitle,
            clickAwayIdentifier: dayIdentifier(fixture.daySiblingTraceID),
            selectedAfterClick: {
                store.selectedTraceID == fixture.daySiblingTraceID
            },
            readback: {
                store.engine.subtasks[fixture.returnedSubtaskID]?.title
            },
            input: input
        )
        store.selectTrace(fixture.returnedTraceID)
        try await click(
            identifier: SubtaskRowSurface.dayDetail.deleteIdentifier(
                for: fixture.deletedDaySubtaskID
            ),
            modifiers: [],
            input: input
        )
        try await waitUntil("Day Todo subtask delete did not commit") {
            store.engine.subtasks[fixture.deletedDaySubtaskID]?.status
                == .cancelledDraft
                && store.subtasks(for: fixture.returnedTraceID).allSatisfy {
                    $0.id != fixture.deletedDaySubtaskID
                }
        }
        try await exerciseReturnAndReschedule(fixture, store: store, input: input)
        try assertReturnLifecyclePersisted(fixture, store: store)
    }

    private func installFixture(on store: NoonmarkStore) throws -> Fixture {
        store.engine = NoonmarkEngine()
        store.setLanguage(.english)
        var timeline = try E2EFixtureTimeline(store: store, eventCount: 13)
        let today = timeline.today

        let dayChainID = try store.engine.createPoolTask(
            title: Self.dayInitialTitle,
            descriptionText: Self.dayInitialDescription,
            now: try timeline.nextInstant()
        )
        let dayTraceID = try store.engine.scheduleFromPool(
            chainID: dayChainID,
            date: today,
            today: today,
            now: try timeline.nextInstant()
        )
        let daySiblingChainID = try store.engine.createPoolTask(
            title: Self.daySiblingTitle,
            now: try timeline.nextInstant()
        )
        let daySiblingTraceID = try store.engine.scheduleFromPool(
            chainID: daySiblingChainID,
            date: today,
            today: today,
            now: try timeline.nextInstant()
        )
        let poolChainID = try store.engine.createPoolTask(
            title: Self.poolInitialTitle,
            now: try timeline.nextInstant()
        )
        let poolSiblingChainID = try store.engine.createPoolTask(
            title: Self.poolSiblingTitle,
            now: try timeline.nextInstant()
        )
        let deletedChainID = try store.engine.createPoolTask(
            title: Self.deletedTitle,
            now: try timeline.nextInstant()
        )
        let deletedTraceID = try store.engine.scheduleFromPool(
            chainID: deletedChainID,
            date: today,
            today: today,
            now: try timeline.nextInstant()
        )
        let returnedChainID = try store.engine.createPoolTask(
            title: Self.returnedTitle,
            descriptionText: Self.returnedInitialDescription,
            now: try timeline.nextInstant()
        )
        let returnedTraceID = try store.engine.scheduleFromPool(
            chainID: returnedChainID,
            date: today,
            today: today,
            now: try timeline.nextInstant()
        )
        let returnedSubtaskID = try store.engine.addSubtask(
            traceID: returnedTraceID,
            title: Self.returnedSubtaskInitialTitle,
            difficulty: .hard,
            now: try timeline.nextInstant()
        )
        let deletedDaySubtaskID = try store.engine.addSubtask(
            traceID: returnedTraceID,
            title: Self.deletedDaySubtaskTitle,
            now: try timeline.nextInstant()
        )
        let deletedPoolSubtaskID = try store.engine.addSubtask(
            traceID: returnedTraceID,
            title: Self.deletedPoolSubtaskTitle,
            now: try timeline.nextInstant()
        )
        let latestMutationAt = try timeline.finish()

        guard store.engine.canDeleteNewCurrentDayTask(
            traceID: deletedTraceID,
            today: today
        ), store.contextMenuActions(
            for: try requiredTrace(deletedTraceID, in: store)
        ).last == .deleteNewCurrentDayTask
        else {
            throw Failure.failed(
                "current-day deletion fixture did not expose the delete menu action"
            )
        }

        store.page = .day
        store.selectedDate = today
        store.selectedCalendarDate = today
        store.selectTrace(dayTraceID)
        store.persist()
        return Fixture(
            today: today,
            dayChainID: dayChainID,
            dayTraceID: dayTraceID,
            daySiblingTraceID: daySiblingTraceID,
            poolChainID: poolChainID,
            poolSiblingChainID: poolSiblingChainID,
            deletedChainID: deletedChainID,
            deletedTraceID: deletedTraceID,
            returnedChainID: returnedChainID,
            returnedTraceID: returnedTraceID,
            returnedSubtaskID: returnedSubtaskID,
            deletedDaySubtaskID: deletedDaySubtaskID,
            deletedPoolSubtaskID: deletedPoolSubtaskID,
            latestMutationAt: latestMutationAt
        )
    }

    private func exerciseReturnAndReschedule(
        _ fixture: Fixture,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws {
        store.page = .day
        store.selectedDate = fixture.today
        store.selectedCalendarDate = fixture.today
        try await chooseMenuAction(
            .deferTo,
            for: fixture.returnedTraceID,
            from: dayIdentifier(fixture.returnedTraceID),
            store: store,
            input: input
        )
        try await waitUntil("defer date picker did not appear") {
            store.showingPicker?.id
                == NoonmarkStore.DatePickerPurpose.deferTrace(
                    fixture.returnedTraceID
                ).id
                && AppViewTreeE2E.view(
                    identifier: "date-picker.confirm"
                ) != nil
        }
        try await click(
            identifier: "date-picker.confirm",
            modifiers: [],
            input: input
        )
        let tomorrow = NoonmarkStore.offset(fixture.today, by: 1)
        var deferredTargetTraceID: DayTraceID?
        try await waitUntil("task was not deferred to tomorrow") {
            deferredTargetTraceID = store.engine.traces.values.first {
                $0.chainID == fixture.returnedChainID
                    && $0.id != fixture.returnedTraceID
                    && $0.status == .pending
                    && $0.date == tomorrow
            }?.id
            return store.showingPicker == nil
                && store.engine.traces[
                    fixture.returnedTraceID
                ]?.status == .deferred
                && deferredTargetTraceID != nil
        }
        guard let deferredTargetTraceID else {
            throw Failure.failed("deferred target identity was unavailable")
        }

        try await click(
            identifier: "sidebar.nav.future",
            modifiers: [],
            input: input
        )
        try await waitUntil("Future Plans navigation did not complete") {
            store.page == .future
                && AppViewTreeE2E.view(
                    identifier: self.futureIdentifier(
                        deferredTargetTraceID
                    )
                ) != nil
        }
        try await chooseFutureMenuAction(
            .returnToPool,
            for: deferredTargetTraceID,
            from: futureIdentifier(deferredTargetTraceID),
            store: store,
            input: input
        )
        try await waitUntil("deferred target did not return to the pool") {
            store.page == .future
                && store.engine.traces[
                    fixture.returnedTraceID
                ]?.status == .deferred
                && store.engine.traces[
                    deferredTargetTraceID
                ]?.status == .cancelledDraft
                && store.engine.taskPool().contains {
                    $0.chain.id == fixture.returnedChainID
                }
        }

        try await click(
            identifier: "sidebar.nav.pool",
            modifiers: [],
            input: input
        )
        try await waitUntil("Task Pool navigation did not complete after return") {
            store.page == .pool
        }
        try await click(
            identifier: poolIdentifier(fixture.returnedChainID),
            modifiers: [],
            input: input
        )
        try await waitUntil("returned task pool detail did not open") {
            store.selectedPoolChainID == fixture.returnedChainID
        }
        try await assertTrail(
            chainID: fixture.returnedChainID,
            expectedKinds: [
                .createdInPool,
                .scheduled,
                .scheduled,
                .deferred,
                .returnedToPool
            ],
            store: store
        )

        guard store.currentDefinition(for: fixture.returnedChainID)?
            .plannedSubtasks.map(\.title) == [
                Self.returnedSubtaskSavedTitle,
                Self.deletedPoolSubtaskTitle
            ]
        else {
            throw Failure.failed(
                "return-to-pool did not materialize the current open subtasks"
            )
        }
        try await editDescription(
            TextEdit(
                initialText: Self.returnedInitialDescription,
                savedText: Self.returnedSavedDescription,
                clickAwayIdentifier: poolIdentifier(fixture.poolSiblingChainID),
                selectedAfterClick: {
                    store.selectedPoolChainID == fixture.poolSiblingChainID
                },
                readback: {
                    store.currentDefinition(for: fixture.returnedChainID)?
                        .descriptionText
                },
                failureContext: {
                    store.operationFailureNotice?.message ?? "none"
                }
            ),
            input: input
        )
        try await click(
            identifier: poolIdentifier(fixture.returnedChainID),
            modifiers: [],
            input: input
        )
        let plannedDeleteID = try requiredPlannedSubtaskID(
            lineageID: try requiredSubtask(
                fixture.deletedPoolSubtaskID,
                in: store
            ).lineageID,
            chainID: fixture.returnedChainID,
            store: store
        )
        try await click(
            identifier: "pool.subtask.\(plannedDeleteID.description).delete",
            modifiers: [],
            input: input
        )
        try await waitUntil("Task Pool subtask delete did not commit") {
            store.currentDefinition(for: fixture.returnedChainID)?
                .plannedSubtasks.contains(where: {
                    $0.id == plannedDeleteID
                }) == false
        }
        try await addPoolSubtask(
            chainID: fixture.returnedChainID,
            title: Self.addedPoolSubtaskTitle,
            store: store,
            input: input
        )

        try await chooseMenuItem(
            from: poolIdentifier(fixture.returnedChainID),
            downArrowCount: 1,
            input: input
        )
        var replacementTraceID: DayTraceID?
        try await waitUntil("returned task was not rescheduled to today") {
            replacementTraceID = store.engine.traces.values.first {
                $0.chainID == fixture.returnedChainID
                    && $0.id != fixture.returnedTraceID
                    && $0.id != deferredTargetTraceID
                    && $0.status == .pending
                    && $0.date == fixture.today
            }?.id
            return store.page == .day
                && store.selectedTraceID == replacementTraceID
        }
        guard let replacementTraceID else {
            throw Failure.failed("rescheduled trace identity was unavailable")
        }
        guard store.engine.traces[replacementTraceID]?.descriptionText
            == Self.returnedSavedDescription,
            store.subtasks(for: replacementTraceID).map(\.title) == [
                Self.returnedSubtaskSavedTitle,
                Self.addedPoolSubtaskTitle
            ]
        else {
            throw Failure.failed(
                "rescheduled task did not keep the edited pool draft"
            )
        }

        try await waitUntil("Day Todo still rendered the returned source row") {
            let visible = store.engine.getDayTodo(date: fixture.today).traces.filter {
                $0.chainID == fixture.returnedChainID
            }
            return visible.map(\.id) == [replacementTraceID]
                && AppViewTreeE2E.view(
                    identifier: self.dayIdentifier(fixture.returnedTraceID)
                ) == nil
                && AppViewTreeE2E.view(
                    identifier: self.dayIdentifier(replacementTraceID)
                ) != nil
        }
        try await assertTrail(
            chainID: fixture.returnedChainID,
            expectedKinds: [
                .createdInPool,
                .scheduled,
                .scheduled,
                .deferred,
                .returnedToPool,
                .scheduled
            ],
            store: store
        )
        try await assertTrailCanCollapse(
            traceID: replacementTraceID,
            chainID: fixture.returnedChainID,
            store: store,
            input: input
        )

        let replacementSubtasks = store.subtasks(for: replacementTraceID)
        for subtask in replacementSubtasks {
            try await clickCompletionButton(
                identifier: SubtaskRowSurface.dayDetail.completionIdentifier(
                    for: subtask.id
                ),
                label: store.copy.markComplete,
                input: input
            )
            try await waitUntil(
                "rescheduled task subtask status could not be changed"
            ) {
                store.engine.subtasks[subtask.id]?.status == .completed
            }
        }
        try await clickCompletionButton(
            identifier:
                "day.trace.\(replacementTraceID.description).completion",
            label: store.copy.markComplete,
            input: input
        )
        try await waitUntil(
            "rescheduled task status could not be changed after returning"
        ) {
            store.engine.traces[replacementTraceID]?.status == .completed
                && store.engine.getDayTodo(
                    date: fixture.today
                ).traces.filter {
                    $0.chainID == fixture.returnedChainID
                }.map(\.id) == [replacementTraceID]
                && AppViewTreeE2E.view(
                    identifier: self.dayIdentifier(
                        fixture.returnedTraceID
                    )
                ) == nil
                && AppViewTreeE2E.view(
                    identifier: self.dayIdentifier(replacementTraceID)
                ) != nil
        }
        try await assertTrail(
            chainID: fixture.returnedChainID,
            expectedKinds: [
                .createdInPool,
                .scheduled,
                .scheduled,
                .deferred,
                .returnedToPool,
                .scheduled,
                .completed
            ],
            store: store
        )
        try captureMainWindow()
    }

    private func assertTrail(
        chainID: TaskChainID,
        expectedKinds: [TaskTrailEntryKind],
        store: NoonmarkStore
    ) async throws {
        let trail = try store.engine.taskTrail(chainID: chainID)
        guard trail.map(\.kind) == expectedKinds else {
            throw Failure.failed("task trail lifecycle projection was incomplete")
        }
        for entry in trail {
            let identifier = "timeline.event.\(entry.id)"
            let timestamp = store.displayExactDateTime(entry.occurredAt)
            try await waitUntil("task trail omitted exact timestamp: \(entry.id)") {
                guard let anchor = AppViewTreeE2E.view(identifier: identifier),
                      let verification = AppViewTreeE2E.verificationText(for: anchor)
                else { return false }
                return verification.contains(timestamp)
                    && timestamp.range(
                        of: #"\d{2}:\d{2}:\d{2}$"#,
                        options: .regularExpression
                    ) != nil
            }
        }
    }

    private func assertTrailCanCollapse(
        traceID: DayTraceID,
        chainID: TaskChainID,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws {
        let prefix = "task-trail.trace.\(traceID.description)"
        guard let firstEntry = try store.engine.taskTrail(
            chainID: chainID
        ).first else {
            throw Failure.failed("task trail collapse fixture was empty")
        }
        let firstEventIdentifier = "timeline.event.\(firstEntry.id)"

        try await waitUntil("task trail did not start expanded") {
            AppViewTreeE2E.view(
                identifier: "\(prefix).toggle"
            ).flatMap(AppViewTreeE2E.verificationText) == "expanded"
                && AppViewTreeE2E.view(
                    identifier: "\(prefix).content"
                ) != nil
        }
        try await click(
            identifier: "\(prefix).toggle",
            modifiers: [],
            input: input
        )
        try await waitUntil("task trail could not collapse") {
            AppViewTreeE2E.view(
                identifier: "\(prefix).toggle"
            ).flatMap(AppViewTreeE2E.verificationText) == "collapsed"
                && AppViewTreeE2E.view(
                    identifier: "\(prefix).content"
                ) == nil
                && AppViewTreeE2E.view(
                    identifier: firstEventIdentifier
                ) == nil
        }
        try await click(
            identifier: "\(prefix).toggle",
            modifiers: [],
            input: input
        )
        try await waitUntil("task trail could not expand again") {
            AppViewTreeE2E.view(
                identifier: "\(prefix).toggle"
            ).flatMap(AppViewTreeE2E.verificationText) == "expanded"
                && AppViewTreeE2E.view(
                    identifier: "\(prefix).content"
                ) != nil
                && AppViewTreeE2E.view(
                    identifier: firstEventIdentifier
                ) != nil
        }
    }

    private func captureMainWindow() throws {
        guard let window = NSApp.keyWindow else {
            throw Failure.failed("Day Todo screenshot window was unavailable")
        }
        do {
            try AppE2EScreenshot.captureContent(
                of: window,
                to: screenshotURL
            )
        } catch {
            throw Failure.failed(
                "Day Todo screenshot failed: \(error.localizedDescription)"
            )
        }
    }

    private func editTitle(
        _ edit: TitleEdit,
        input: WindowServerInputDriver
    ) async throws {
        var titleEditor: NSTextView?
        try await waitUntil("native title editor was not ready: \(edit.initialTitle)") {
            titleEditor = AppViewTreeE2E.view(identifier: "detail.title.input")
                as? NSTextView
            return titleEditor?.string == edit.initialTitle
        }
        guard let titleEditor else {
            throw Failure.failed("native title editor disappeared before editing")
        }

        try await click(identifier: "detail.title.input", modifiers: [], input: input)
        try await waitUntil("native title editor did not become first responder") {
            titleEditor.window?.firstResponder === titleEditor
        }
        try input.postKey(keyCode: 0, modifiers: .command)
        try input.typeUnicode(edit.savedTitle)
        try await waitUntil("typed title was not saved before focus changed") {
            titleEditor.string == edit.savedTitle && edit.readback() == edit.savedTitle
        }

        try await click(identifier: edit.clickAwayIdentifier, modifiers: [], input: input)
        try await waitUntil("clicking away did not keep the saved title") {
            edit.selectedAfterClick() && edit.readback() == edit.savedTitle
        }
    }

    private func clearTitleAndRestore(
        restoredTitle: String,
        readback: @escaping @MainActor () -> String?,
        placeholder: String,
        input: WindowServerInputDriver
    ) async throws {
        var titleEditor: NSTextView?
        try await waitUntil("native title editor was not ready for clear") {
            titleEditor = AppViewTreeE2E.view(identifier: "detail.title.input")
                as? NSTextView
            return titleEditor?.string == restoredTitle
        }
        guard let titleEditor else {
            throw Failure.failed("native title editor disappeared before clear")
        }

        try await click(identifier: "detail.title.input", modifiers: [], input: input)
        try await waitUntil("native title editor did not focus before clear") {
            titleEditor.window?.firstResponder === titleEditor
        }
        try input.postKey(keyCode: 0, modifiers: .command)
        try input.postKey(keyCode: 51)
        try await waitUntil("Cmd+A Delete could not clear the task title") {
            titleEditor.string.isEmpty
                && readback() == ""
                && AppViewTreeE2E.view(
                    identifier: "detail.title.placeholder"
                ).flatMap(AppViewTreeE2E.verificationText) == placeholder
        }

        try input.typeUnicode(restoredTitle)
        try await waitUntil("cleared task title could not be restored") {
            titleEditor.string == restoredTitle && readback() == restoredTitle
        }
    }

    private func editInlineSubtaskTitle(
        subtaskID: SubtaskID,
        initialTitle: String,
        savedTitle: String,
        clickAwayIdentifier: String,
        selectedAfterClick: @escaping @MainActor () -> Bool,
        readback: @escaping @MainActor () -> String?,
        input: WindowServerInputDriver
    ) async throws {
        let identifier = SubtaskRowSurface.dayDetail
            .titleInputIdentifier(for: subtaskID)
        var editor: NSTextView?
        try await waitUntil("native subtask title editor was not ready") {
            editor = AppViewTreeE2E.view(identifier: identifier) as? NSTextView
            return editor?.string == initialTitle
        }
        guard let editor else {
            throw Failure.failed("native subtask title editor disappeared")
        }

        // The NSTextView document can be taller than its clipped compact row.
        // Click the visible NSScrollView surface so the event cannot land on
        // the neighbouring subtask editor through an offscreen midpoint.
        try await click(
            identifier: String(identifier.dropLast(".input".count)),
            modifiers: [],
            input: input
        )
        try await waitUntil("native subtask title editor did not focus") {
            editor.window?.firstResponder === editor
        }
        try input.postKey(keyCode: 0, modifiers: .command)
        try input.typeUnicode(savedTitle)
        try await waitUntil("typed subtask title was not saved immediately") {
            editor.string == savedTitle && readback() == savedTitle
        }
        try await click(
            identifier: clickAwayIdentifier,
            modifiers: [],
            input: input
        )
        try await waitUntil("clicking away lost the subtask title") {
            selectedAfterClick() && readback() == savedTitle
        }
    }

    private func addPoolSubtask(
        chainID: TaskChainID,
        title: String,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws {
        let identifier = "pool.subtask.\(chainID.description).new.input"
        try await click(identifier: identifier, modifiers: [], input: input)
        try input.typeUnicode(title)
        try input.postKey(keyCode: 36)
        try await waitUntil("Task Pool subtask add did not commit") {
            store.currentDefinition(for: chainID)?.plannedSubtasks.contains {
                $0.title == title
            } == true
        }
    }

    private func chooseMenuAction(
        _ action: NoonmarkStore.TraceContextAction,
        for traceID: DayTraceID,
        from identifier: String,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws {
        let trace = try requiredTrace(traceID, in: store)
        guard let actionIndex = store.contextMenuActions(for: trace)
            .firstIndex(of: action)
        else {
            throw Failure.failed("task context menu did not expose \(action)")
        }
        try await chooseMenuItem(
            from: identifier,
            downArrowCount: actionIndex + 1,
            input: input
        )
    }

    private func chooseFutureMenuAction(
        _ action: NoonmarkStore.TraceContextAction,
        for traceID: DayTraceID,
        from identifier: String,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws {
        let trace = try requiredTrace(traceID, in: store)
        guard let actionIndex = store.contextMenuActions(for: trace)
            .firstIndex(of: action)
        else {
            throw Failure.failed(
                "future context menu did not expose \(action)"
            )
        }
        // FuturePlanRow prepends “View details” before shared trace actions.
        try await chooseMenuItem(
            from: identifier,
            downArrowCount: actionIndex + 2,
            input: input
        )
    }

    private func chooseMenuItem(
        from identifier: String,
        downArrowCount: Int,
        input: WindowServerInputDriver
    ) async throws {
        let probe = MenuTrackingProbe()
        defer { probe.stop() }
        try await click(identifier: identifier, modifiers: [.control], input: input)
        try await waitUntil("task context menu did not begin tracking") {
            probe.didBeginTracking
        }
        for _ in 0 ..< downArrowCount {
            try input.postKey(keyCode: 125)
        }
        try input.postKey(keyCode: 36)
    }

    private func editDescription(
        _ edit: TextEdit,
        input: WindowServerInputDriver
    ) async throws {
        var editor: NSTextView?
        try await waitUntil("native description editor was not ready") {
            editor = AppViewTreeE2E.view(identifier: "detail.description.input")
                as? NSTextView
            return editor?.string == edit.initialText
        }
        guard let editor else {
            throw Failure.failed("native description editor disappeared before editing")
        }

        try await click(identifier: "detail.description.input", modifiers: [], input: input)
        try await waitUntil("native description editor did not become first responder") {
            editor.window?.firstResponder === editor
        }
        try input.postKey(keyCode: 0, modifiers: .command)
        try input.typeUnicode(edit.savedText)
        var lastEditorText = editor.string
        var lastReadback = edit.readback()
        do {
            try await waitUntil("typed description was not saved before focus changed") {
                lastEditorText = editor.string
                lastReadback = edit.readback()
                return lastEditorText == edit.savedText && lastReadback == edit.savedText
            }
        } catch {
            throw Failure.failed(
                "typed description was not saved before focus changed "
                    + "editor=\(String(reflecting: lastEditorText)) "
                    + "readback=\(String(reflecting: lastReadback)) "
                    + "operationFailure=\(edit.failureContext())"
            )
        }

        try await click(identifier: edit.clickAwayIdentifier, modifiers: [], input: input)
        try await waitUntil("clicking away did not keep the saved description") {
            edit.selectedAfterClick() && edit.readback() == edit.savedText
        }
    }

    private func clearDescriptionAndKeepEmpty(
        initialText: String,
        readback: @escaping () -> String?,
        input: WindowServerInputDriver
    ) async throws {
        var editor: NSTextView?
        try await waitUntil("native description editor was not ready for clearing") {
            editor = AppViewTreeE2E.view(identifier: "detail.description.input")
                as? NSTextView
            return editor?.string == initialText
        }
        guard let editor else {
            throw Failure.failed("native description editor disappeared before clearing")
        }

        try await click(identifier: "detail.description.input", modifiers: [], input: input)
        try await waitUntil("description editor did not focus before Control-A") {
            editor.window?.firstResponder === editor
        }
        try input.postKey(keyCode: 0, modifiers: .control)
        let fullRange = NSRange(location: 0, length: initialText.utf16.count)
        try await waitUntil("Control-A did not select the full description") {
            editor.selectedRange() == fullRange
        }
        try input.postKey(keyCode: 51)

        for _ in 0 ..< 5 {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let currentEditor = AppViewTreeE2E.view(
                identifier: "detail.description.input"
            ) as? NSTextView,
                currentEditor.string.isEmpty,
                readback() == nil
            else {
                throw Failure.failed(
                    "Control-A and Delete did not keep the task description empty"
                )
            }
        }
    }

    private func click(
        identifier: String,
        modifiers: NSEvent.ModifierFlags,
        input: WindowServerInputDriver
    ) async throws {
        try await waitUntil("visible click target was missing: \(identifier)") {
            AppViewTreeE2E.view(identifier: identifier) != nil
        }
        guard let view = AppViewTreeE2E.view(identifier: identifier),
              let window = view.window,
              window.isKeyWindow,
              NSApp.isActive
        else {
            throw Failure.failed(
                "WindowServer click target was not in the active key window"
            )
        }
        let resolveTarget = { () throws -> WindowServerInputDriver.PointerCoordinate in
            guard let currentView = AppViewTreeE2E.view(identifier: identifier),
                  let currentWindow = currentView.window,
                  currentWindow === window,
                  currentWindow.isKeyWindow,
                  currentView.isHiddenOrHasHiddenAncestor == false,
                  currentView.bounds.width > 0,
                  currentView.bounds.height > 0
            else {
                throw Failure.failed(
                    "WindowServer click target changed before mouseDown: \(identifier)"
                )
            }
            let point = currentView.convert(
                NSPoint(
                    x: currentView.bounds.midX,
                    y: currentView.bounds.midY
                ),
                to: nil
            )
            return try input.pointerCoordinate(windowPoint: point, in: currentWindow)
        }
        let coordinate = try resolveTarget()
        try await input.postClick(
            at: coordinate,
            modifiers: modifiers,
            resolveTarget: resolveTarget
        )
    }

    private func clickCompletionButton(
        identifier: String,
        label: String,
        input: WindowServerInputDriver
    ) async throws {
        guard let window = NSApp.keyWindow else {
            throw Failure.failed(
                "completion control window was unavailable: \(identifier)"
            )
        }
        let resolveTarget = {
            guard NSApp.keyWindow === window,
                  let frame = ReadOnlyAccessibilityTarget.uniqueButton(
                      identifier: identifier,
                      label: label,
                      enabled: true,
                      in: window
                  )?.frame
            else {
                throw Failure.failed(
                    "completion control changed before mouseDown: \(identifier)"
                )
            }
            return try input.pointerCoordinate(
                quartzPoint: CGPoint(x: frame.midX, y: frame.midY),
                in: window
            )
        }
        var coordinate: WindowServerInputDriver.PointerCoordinate?
        try await waitUntil(
            "visible completion control was missing: \(identifier)"
        ) {
            coordinate = try? resolveTarget()
            return coordinate != nil
        }
        guard let coordinate else {
            throw Failure.failed(
                "completion control frame was unavailable: \(identifier)"
            )
        }
        try await input.postClick(
            at: coordinate,
            modifiers: [],
            resolveTarget: resolveTarget
        )
    }

    private func assertImmediateEditsPersisted(
        _ fixture: Fixture,
        store: NoonmarkStore
    ) throws {
        guard let databaseURL = store.databaseURL else {
            throw Failure.failed(
                "immediate task mutation persistence probe requires --data-url"
            )
        }
        let restored = try SQLiteEngineRepository(databaseURL: databaseURL).load()
        guard let dayTrace = restored.traces[fixture.dayTraceID],
              restored.definitions[dayTrace.definitionID]?.title == Self.daySavedTitle,
              dayTrace.descriptionText == Self.daySavedDescription,
              restored.definitions.values.contains(where: {
                  $0.chainID == fixture.poolChainID
                      && $0.supersededAt == nil
                      && $0.title == Self.poolSavedTitle
                      && $0.descriptionText == Self.poolSavedDescription
              }),
              let deletedTrace = restored.traces[fixture.deletedTraceID],
              deletedTrace.status == .cancelledDraft,
              deletedTrace.draftCancellationID != nil,
              deletedTrace.draftCancelledOn == fixture.today,
              restored.chains[fixture.deletedChainID]?.state == .abandoned,
              restored.getDayTodo(date: fixture.today).traces.contains(where: {
                  $0.id == fixture.deletedTraceID
              }) == false,
              restored.taskPool().contains(where: {
                  $0.chain.id == fixture.deletedChainID
              }) == false
        else {
            throw Failure.failed(
                "immediate title, description, or deletion mutations did not persist exactly"
            )
        }
    }

    private func assertReturnLifecyclePersisted(
        _ fixture: Fixture,
        store: NoonmarkStore
    ) throws {
        guard let databaseURL = store.databaseURL else {
            throw Failure.failed(
                "immediate task mutation persistence probe requires --data-url"
            )
        }
        let restored = try SQLiteEngineRepository(databaseURL: databaseURL).load()
        guard let replacementTrace = restored.getDayTodo(date: fixture.today)
            .traces.first(where: {
                $0.chainID == fixture.returnedChainID
            })
        else {
            throw Failure.failed("rescheduled trace did not persist")
        }
        let replacementSubtaskTitles = restored.subtasks.values
            .filter {
                $0.traceID == replacementTrace.id && $0.isUserPresentable
            }
            .sorted { $0.position < $1.position }
            .map(\.title)
        let returnedTrailKinds = try restored.taskTrail(
            chainID: fixture.returnedChainID
        ).map(\.kind)
        guard restored.traces[fixture.returnedTraceID]?.status == .deferred,
              restored.traces.values.contains(where: {
                  $0.chainID == fixture.returnedChainID
                      && $0.date == NoonmarkStore.offset(
                          fixture.today,
                          by: 1
                      )
                      && $0.status == .cancelledDraft
              }),
              restored.subtasks[fixture.deletedDaySubtaskID]?.status
                  == .cancelledDraft,
              restored.getDayTodo(date: fixture.today).traces.filter({
                  $0.chainID == fixture.returnedChainID
              }).count == 1,
              replacementTrace.status == .completed,
              replacementTrace.descriptionText == Self.returnedSavedDescription,
              replacementSubtaskTitles == [
                  Self.returnedSubtaskSavedTitle,
                  Self.addedPoolSubtaskTitle
              ],
              restored.subtasks.values.filter({
                  $0.traceID == replacementTrace.id
                      && $0.isUserPresentable
              }).allSatisfy({
                  $0.status == .completed
              }),
              returnedTrailKinds
                  == [
                      .createdInPool,
                      .scheduled,
                      .scheduled,
                      .deferred,
                      .returnedToPool,
                      .scheduled,
                      .completed
                  ]
        else {
            throw Failure.failed(
                "return/reschedule projection did not persist exactly"
            )
        }
    }

    private func requiredTrace(
        _ traceID: DayTraceID,
        in store: NoonmarkStore
    ) throws -> DayTrace {
        guard let trace = store.engine.traces[traceID] else {
            throw Failure.failed("fixture trace was missing")
        }
        return trace
    }

    private func requiredSubtask(
        _ subtaskID: SubtaskID,
        in store: NoonmarkStore
    ) throws -> Subtask {
        guard let subtask = store.engine.subtasks[subtaskID] else {
            throw Failure.failed("fixture subtask was missing")
        }
        return subtask
    }

    private func requiredPlannedSubtaskID(
        lineageID: SubtaskLineageID,
        chainID: TaskChainID,
        store: NoonmarkStore
    ) throws -> PlannedSubtaskID {
        guard let plannedSubtaskID = store.currentDefinition(for: chainID)?
            .plannedSubtasks.first(where: {
                $0.lineageID == lineageID
            })?.id
        else {
            throw Failure.failed("returned planned subtask lineage was missing")
        }
        return plannedSubtaskID
    }

    private func dayIdentifier(_ traceID: DayTraceID) -> String {
        "workspace.item.day.\(traceID.description)"
    }

    private func poolIdentifier(_ chainID: TaskChainID) -> String {
        "workspace.item.pool.\(chainID.description)"
    }

    private func futureIdentifier(_ traceID: DayTraceID) -> String {
        "workspace.item.future.\(traceID.description)"
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 80,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failure.failed(failure)
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }

    private struct Fixture {
        let today: LocalDate
        let dayChainID: TaskChainID
        let dayTraceID: DayTraceID
        let daySiblingTraceID: DayTraceID
        let poolChainID: TaskChainID
        let poolSiblingChainID: TaskChainID
        let deletedChainID: TaskChainID
        let deletedTraceID: DayTraceID
        let returnedChainID: TaskChainID
        let returnedTraceID: DayTraceID
        let returnedSubtaskID: SubtaskID
        let deletedDaySubtaskID: SubtaskID
        let deletedPoolSubtaskID: SubtaskID
        let latestMutationAt: Date
    }

    private struct TitleEdit {
        let initialTitle: String
        let savedTitle: String
        let clickAwayIdentifier: String
        let selectedAfterClick: @MainActor () -> Bool
        let readback: @MainActor () -> String?
    }

    private struct TextEdit {
        let initialText: String
        let savedText: String
        let clickAwayIdentifier: String
        let selectedAfterClick: @MainActor () -> Bool
        let readback: @MainActor () -> String?
        let failureContext: @MainActor () -> String
    }

    private final class MenuTrackingProbe: @unchecked Sendable {
        private(set) var didBeginTracking = false
        private var observer: NSObjectProtocol?

        init() {
            observer = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.didBeginTracking = true
                }
            }
        }

        func stop() {
            guard let observer else { return }
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): message
            }
        }
    }
}
