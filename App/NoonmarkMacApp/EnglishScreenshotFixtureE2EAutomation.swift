import AppKit
import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkMacUIContract
import NoonmarkStorage
import NoonmarkSync

struct EnglishScreenshotFixtureE2EAutomation: LaunchAutomationRunnable {
    static let longTitle = "Coordinate the launch readiness review with accessibility owners"
    static let categoryName = "Product Design"
    static let primaryLabelName = "Accessibility"
    static let secondaryLabelName = "Launch Readiness"

    private let databaseURL: URL?
    private let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> EnglishScreenshotFixtureE2EAutomation? {
        guard AppLaunchArguments.contains(
            "--e2e-bootstrap-english-screenshot-fixture"
        ) else {
            return nil
        }
        return EnglishScreenshotFixtureE2EAutomation(
            databaseURL: AppLaunchArguments.value(after: "--data-url")
                .map { URL(fileURLWithPath: $0) },
            resultURL: AppLaunchArguments.value(
                after: "--e2e-english-fixture-result-url"
            )
            .map { URL(fileURLWithPath: $0) }
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            try validateLaunchBoundary()
            let startingSnapshot = store.engine.snapshot()
            guard startingSnapshot.chains.isEmpty,
                  startingSnapshot.definitions.isEmpty,
                  startingSnapshot.traces.isEmpty,
                  startingSnapshot.subtasks.isEmpty,
                  startingSnapshot.classifications.categories.isEmpty,
                  startingSnapshot.classifications.labels.isEmpty,
                  startingSnapshot.classifications.currentByChainID.isEmpty
            else {
                throw Failure.failed(
                    "English screenshot fixture requires an empty isolated domain database"
                )
            }

            let identities = try Self.populate(store)
            store.onLanguageChange?()

            guard let repository = store.repository else {
                throw Failure.failed(
                    "English screenshot fixture did not use the SQLite repository"
                )
            }
            let persisted = try repository.load()
            guard let databaseURL else {
                throw Failure.failed(
                    "English screenshot fixture lost its database URL"
                )
            }
            let journalEntries = try SQLiteSyncRepository(
                databaseURL: databaseURL
            ).journalEntries()
            let manifest = try Self.fixtureManifest(
                engine: persisted,
                today: store.today,
                identities: identities,
                journalEntries: journalEntries
            )
            try writeResult(manifest)
        } catch {
            NSLog(
                "Noonmark English screenshot fixture failed: %@",
                String(reflecting: error)
            )
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func validateLaunchBoundary() throws {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              AppLaunchArguments.permitsInternalArguments,
              databaseURL != nil,
              resultURL != nil,
              AppLaunchArguments.value(after: "--e2e-fixed-instant")
              == "2026-07-05T16:00:00Z",
              AppLaunchArguments.value(after: "--e2e-fixed-time-zone")
              == "America/New_York",
              AppLaunchArguments.value(after: "--e2e-fixed-locale")
              == "en_SG"
        else {
            throw Failure.failed(
                "English screenshot fixture requires the E2E bundle, explicit data/result URLs, and the fixed en_SG Natural Day"
            )
        }
    }

    @MainActor
    private static func populate(
        _ store: NoonmarkStore
    ) throws -> FixtureIdentities {
        let today = store.today
        guard today == LocalDate("2026-07-05") else {
            throw Failure.failed(
                "English screenshot fixture Natural Day does not match 2026-07-05"
            )
        }
        let previousDay = LocalDate("2026-07-04")
        let nextDay = LocalDate("2026-07-06")

        let unfinishedChainID = try makeTask(
            on: store,
            title: "Review the unresolved keyboard navigation findings",
            description: "Confirm owners and record the remaining keyboard paths before the next review.",
            note: "Keep the unresolved items visible until every owner confirms a fix."
        )
        let unfinishedTraceID = try commit(on: store) { candidate, moment in
            try candidate.scheduleFromPool(
                chainID: unfinishedChainID,
                date: previousDay,
                today: previousDay,
                now: moment.instant
            )
        }

        let historicalCompletedChainID = try makeTask(
            on: store,
            title: "Publish the accessibility review agenda",
            description: "Share the final agenda and the testing responsibilities with every reviewer.",
            note: "The agenda includes keyboard, VoiceOver, contrast, and localisation checks."
        )
        let historicalCompletedTraceID = try commit(on: store) { candidate, moment in
            try candidate.scheduleFromPool(
                chainID: historicalCompletedChainID,
                date: previousDay,
                today: previousDay,
                now: moment.instant
            )
        }
        try commit(on: store) { candidate, moment in
            try candidate.markCompleted(
                traceID: historicalCompletedTraceID,
                today: previousDay,
                now: moment.instant
            )
        }
        try commit(on: store) { candidate, moment in
            try candidate.settleDays(
                upTo: today,
                now: moment.instant
            )
        }

        let dayChainID = try makeTask(
            on: store,
            title: longTitle,
            description: "Review keyboard access, VoiceOver labels, contrast, and English localisation before approving the release.",
            note: "Bring the latest audit evidence and leave each owner with one explicit next action."
        )
        let dayTraceID = try commit(on: store) { candidate, moment in
            try candidate.scheduleFromPool(
                chainID: dayChainID,
                date: today,
                today: today,
                now: moment.instant
            )
        }
        try commit(on: store) { candidate, moment in
            _ = try candidate.addSubtask(
                traceID: dayTraceID,
                title: "Confirm the VoiceOver reading order",
                difficulty: .medium,
                now: moment.instant
            )
        }
        try commit(on: store) { candidate, moment in
            _ = try candidate.addSubtask(
                traceID: dayTraceID,
                title: "Verify the English layout at minimum window size",
                difficulty: .hard,
                now: moment.instant
            )
        }

        let completedChainID = try makeTask(
            on: store,
            title: "Approve the final English navigation copy",
            description: "Check every navigation label and approve the release wording.",
            note: "The approved copy uses concise native Mac terminology."
        )
        let completedTraceID = try commit(on: store) { candidate, moment in
            try candidate.scheduleFromPool(
                chainID: completedChainID,
                date: today,
                today: today,
                now: moment.instant
            )
        }
        try commit(on: store) { candidate, moment in
            try candidate.markCompleted(
                traceID: completedTraceID,
                today: today,
                now: moment.instant
            )
        }

        let poolChainID = try makeTask(
            on: store,
            title: "Draft the post-launch accessibility follow-up",
            description: "Prepare a focused follow-up task without assigning a day yet.",
            note: "Schedule this after the first week of production feedback."
        )
        try commit(on: store) { candidate, moment in
            _ = try candidate.addPlannedSubtask(
                chainID: poolChainID,
                title: "Collect feedback from keyboard users",
                difficulty: .medium,
                now: moment.instant
            )
        }

        let futureChainID = try makeTask(
            on: store,
            title: "Run the release candidate VoiceOver walkthrough",
            description: "Walk through the release candidate with VoiceOver and record any blocking regression.",
            note: "Use the signed release candidate and the final English copy."
        )
        let futureTraceID = try commit(on: store) { candidate, moment in
            try candidate.scheduleFromPool(
                chainID: futureChainID,
                date: nextDay,
                today: today,
                now: moment.instant
            )
        }

        let writerID = store.syncDeviceIdentity?.deviceID.rawValue
            ?? AppPreferences.defaultLocalThemeLanguageWriterID
        try commit(on: store) { candidate, moment in
            candidate.updateSettingsPoemDisplayPolicy(
                SettingsPoemDisplayPolicy(
                    enabled: true,
                    text: "Mark the hours by what was completed, and leave the next step clear."
                )
            )
            try candidate.updateLanguage(
                .english,
                writerID: writerID,
                now: moment.instant
            )
        }

        return FixtureIdentities(
            dayTraceID: dayTraceID,
            poolChainID: poolChainID,
            futureTraceID: futureTraceID,
            unfinishedChainID: unfinishedChainID,
            unfinishedTraceID: unfinishedTraceID,
            completedTraceID: completedTraceID
        )
    }

    @MainActor
    private static func makeTask(
        on store: NoonmarkStore,
        title: String,
        description: String,
        note: String
    ) throws -> TaskChainID {
        let chainID = try commit(on: store) { candidate, moment in
            try candidate.createPoolTask(
                title: title,
                descriptionText: description,
                initialNoteBody: note,
                now: moment.instant
            )
        }
        try commit(on: store) { candidate, moment in
            let interactionID = UUID()
            let plan = try candidate.prepareClassification(
                .setCurrent(
                    TaskClassificationDraft(
                        chainID: chainID,
                        category: .new(
                            name: categoryName,
                            colorHex: "#2A6FDB"
                        ),
                        labels: [
                            .new(
                                name: primaryLabelName,
                                colorHex: "#0E9488"
                            ),
                            .new(
                                name: secondaryLabelName,
                                colorHex: "#E0851B"
                            )
                        ]
                    )
                ),
                source: .userDirect,
                interactionID: interactionID,
                now: moment.instant
            )
            _ = try candidate.commitClassification(
                plan,
                confirmation: .confirmedByUser(
                    confirming: plan,
                    decisionID: interactionID
                ),
                now: moment.instant
            )
        }
        return chainID
    }

    @MainActor
    private static func commit<Result>(
        on store: NoonmarkStore,
        _ mutation: (NoonmarkEngine, StoreMutationMoment) throws -> Result
    ) throws -> Result {
        try store.commitEngineMutation(
            undoPolicy: .invalidate,
            mutation
        )
    }

    private static func fixtureManifest(
        engine: NoonmarkEngine,
        today: LocalDate,
        identities: FixtureIdentities,
        journalEntries: [SyncJournalEntry]
    ) throws -> String {
        let day = engine.getDayTodo(date: today).traces
        let pool = engine.taskPool()
        let future = engine.futurePlans(today: today)
        let unfinished = engine.unfinishedPool()
        let completed = engine.completedPool()
        let calendarCount = engine.calendarSummary(for: today).total

        guard engine.preferences.language == .english,
              day.first?.id == identities.dayTraceID,
              pool.first?.chain.id == identities.poolChainID,
              future.first?.trace.id == identities.futureTraceID,
              unfinished.first?.chain.id == identities.unfinishedChainID,
              unfinished.first?.latestUnfinishedTrace?.id
              == identities.unfinishedTraceID,
              completed.first?.trace.id == identities.completedTraceID,
              calendarCount == day.count,
              day.count >= 2,
              pool.isEmpty == false,
              future.isEmpty == false,
              unfinished.isEmpty == false,
              completed.isEmpty == false
        else {
            throw Failure.failed(
                "persisted English fixture projections or selected identities do not match"
            )
        }

        guard case let .task(classification) = try engine.classification(
            .task(identities.dayTraceID.flatMapChain(in: engine))
        ),
        classification.category?.name == categoryName,
        Set(classification.labels.map(\.name))
            == [primaryLabelName, secondaryLabelName]
        else {
            throw Failure.failed(
                "persisted English fixture classification does not match"
            )
        }

        let snapshot = engine.snapshot()
        let definitionText = snapshot.definitions.flatMap { definition in
            [definition.title, definition.descriptionText ?? ""]
                + definition.plannedSubtasks.map(\.title)
        }
        let chainNoteText = snapshot.chains.flatMap {
            $0.noteEntries.map(\.body)
        }
        let traceNoteText = snapshot.traces.flatMap {
            $0.noteEntries.map(\.body)
        }
        let classificationText = snapshot.classifications.categories.values
            .map(\.name) + snapshot.classifications.labels.values.map(\.name)
        let fixtureText = definitionText
            + chainNoteText
            + traceNoteText
            + snapshot.subtasks.map(\.title)
            + classificationText
            + [snapshot.preferences.settingsPoemDisplayPolicy.text]
        guard fixtureText.allSatisfy({ containsHan($0) == false }) else {
            throw Failure.failed(
                "persisted English fixture contains Han text"
            )
        }

        return ([
            "ok",
            "language=english",
            "day_count=\(day.count)",
            "day_selected_id=\(identities.dayTraceID.description)",
            "day_selected_title=\(longTitle)",
            "pool_count=\(pool.count)",
            "pool_selected_id=\(identities.poolChainID.description)",
            "future_count=\(future.count)",
            "future_selected_id=\(identities.futureTraceID.description)",
            "unfinished_count=\(unfinished.count)",
            "unfinished_selected_id=\(identities.unfinishedChainID.description)",
            "completed_count=\(completed.count)",
            "completed_selected_id=\(identities.completedTraceID.description)",
            "calendar_count=\(calendarCount)",
            "calendar_selected_id=\(today.description)",
            "classification_category=\(categoryName)",
            "classification_labels=\(primaryLabelName),\(secondaryLabelName)"
        ] + (try journalEvidence(
            snapshot: snapshot,
            journalEntries: journalEntries
        ))).joined(separator: "\n")
    }

    private static func journalEvidence(
        snapshot: NoonmarkSnapshot,
        journalEntries: [SyncJournalEntry]
    ) throws -> [String] {
        let classificationRecords = Dictionary(
            uniqueKeysWithValues: snapshot.classifications.changeRecords.map {
                ($0.id.uuidString, $0)
            }
        )
        let classificationEntries = journalEntries.filter {
            $0.entityType == .classificationCommit
        }
        guard classificationEntries.count == classificationRecords.count,
              classificationEntries.count == 6,
              classificationEntries.allSatisfy({ entry in
                  guard let record = classificationRecords[entry.entityID] else {
                      return false
                  }
                  return exactBits(entry.changedAt)
                      == exactBits(record.committedAt)
              }),
              Set(classificationEntries.map { exactBits($0.changedAt) }).count
              == classificationEntries.count
        else {
            throw Failure.failed(
                "classification Store transaction clocks do not match their exact journal clocks"
            )
        }

        let preferenceEntries = journalEntries.filter {
            $0.entityType == .appPreferences
        }
        guard preferenceEntries.count == 1,
              preferenceEntries.first.map({ exactBits($0.changedAt) })
              == exactBits(snapshot.preferences.themeLanguageUpdatedAt)
        else {
            throw Failure.failed(
                "English preference Store transaction clock does not match its exact journal clock"
            )
        }

        let domainEntries = journalEntries.filter {
            [.day, .taskChain, .taskDefinition, .dayTrace, .subtask]
                .contains($0.entityType)
        }
        guard domainEntries.isEmpty == false,
              domainEntries.allSatisfy({
                  domainJournalClockMatches(
                      $0,
                      snapshot: snapshot
                  )
              })
        else {
            throw Failure.failed(
                "English fixture domain facts do not carry their Store transaction clocks"
            )
        }

        let transactionClockCount = Set(
            journalEntries.map { exactBits($0.changedAt) }
        ).count
        guard transactionClockCount >= 24 else {
            throw Failure.failed(
                "English fixture did not preserve its independent Store transaction frontiers"
            )
        }
        return [
            "journal_entry_count=\(journalEntries.count)",
            "journal_transaction_count=\(transactionClockCount)",
            "classification_journal_count=\(classificationEntries.count)",
            "classification_journal_exact=true",
            "preferences_journal_exact=true",
            "domain_journal_clock_exact=true"
        ]
    }

    private static func domainJournalClockMatches(
        _ entry: SyncJournalEntry,
        snapshot: NoonmarkSnapshot
    ) -> Bool {
        guard let dates = domainJournalDates(entry, snapshot: snapshot) else {
            return false
        }
        return dates.contains {
            exactBits($0) == exactBits(entry.changedAt)
        }
    }

    private static func domainJournalDates(
        _ entry: SyncJournalEntry,
        snapshot: NoonmarkSnapshot
    ) -> [Date]? {
        switch entry.entityType {
        case .day:
            snapshot.days.first(where: {
                $0.date.description == entry.entityID
            }).map { day in
                [day.createdAt, day.updatedAt]
                    + [day.lockedAt].compactMap { $0 }
            }
        case .taskCycleSeries:
            snapshot.taskCycleSeries.first(where: {
                $0.id.description == entry.entityID
            }).map { series in
                [series.createdAt, series.updatedAt]
                    + series.cancellationFacts.map(\.recordedAt)
            }
        case .taskChain:
            snapshot.chains.first(where: {
                $0.id.description == entry.entityID
            }).map { chain in
                [chain.createdAt, chain.updatedAt]
                    + noteDates(chain.noteEntries)
            }
        case .taskDefinition:
            snapshot.definitions.first(where: {
                $0.id.description == entry.entityID
            }).map { definition in
                [definition.createdAt, definition.contentUpdatedAt]
                    + [definition.supersededAt].compactMap { $0 }
                    + definition.plannedSubtasks.map(\.createdAt)
            }
        case .dayTrace:
            snapshot.traces.first(where: {
                $0.id.description == entry.entityID
            }).map { trace in
                [trace.createdAt, trace.contentUpdatedAt]
                    + [trace.completedAt, trace.settledAt].compactMap { $0 }
                    + noteDates(trace.noteEntries)
            }
        case .subtask:
            snapshot.subtasks.first(where: {
                $0.id.description == entry.entityID
            }).map { subtask in
                [subtask.createdAt, subtask.updatedAt]
                    + [subtask.completedAt, subtask.settledAt].compactMap { $0 }
            }
        case .ideaEntry:
            snapshot.ideas.first(where: {
                $0.id.description == entry.entityID
            }).map { idea in
                [idea.createdAt, idea.updatedAt]
                    + [idea.deletedAt].compactMap { $0 }
            }
        case .appPreferences, .classificationBaseline,
             .classificationCommit,
             .traceClassificationEvent:
            nil
        }
    }

    private static func noteDates(_ notes: [TaskNoteEntry]) -> [Date] {
        notes.flatMap { note in
            [note.createdAt, note.updatedAt]
                + [note.deletedAt].compactMap { $0 }
        }
    }

    private static func exactBits(_ date: Date) -> UInt64 {
        date.timeIntervalSinceReferenceDate.bitPattern
    }

    private static func containsHan(_ text: String) -> Bool {
        text.range(of: "\\p{Han}", options: .regularExpression) != nil
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else {
            throw Failure.failed(
                "English screenshot fixture requires a result URL"
            )
        }
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

struct EnglishScreenshotUIE2EAutomation: LaunchAutomationRunnable {
    private let resultURL: URL?
    private let historyHeaderDate: LocalDate?

    @MainActor
    static func fromCommandLine() -> EnglishScreenshotUIE2EAutomation? {
        guard AppLaunchArguments.contains(
            "--e2e-verify-english-populated-screenshot"
        ) else {
            return nil
        }
        return EnglishScreenshotUIE2EAutomation(
            resultURL: AppLaunchArguments.value(
                after: "--e2e-english-ui-result-url"
            )
            .map { URL(fileURLWithPath: $0) },
            historyHeaderDate: AppLaunchArguments.contains(
                "--e2e-english-history-header"
            )
                ? LocalDate("2025-09-30")
                : nil
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              AppLaunchArguments.value(after: "--data-url") != nil,
              AppLaunchArguments.value(after: "--e2e-fixed-locale")
              == "en_SG",
              let resultURL
        else {
            try? writeResult(
                "failed: English populated screenshot verification crossed its E2E boundary"
            )
            return
        }
        if let historyHeaderDate {
            store.page = .day
            store.selectedDate = historyHeaderDate
            store.clearSelection()
        }
        EnglishScreenshotUIVerifier.start(
            store: store,
            resultURL: resultURL,
            historyHeaderDate: historyHeaderDate
        )
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
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

@MainActor
private enum EnglishScreenshotUIVerifier {
    static func start(
        store: NoonmarkStore,
        resultURL: URL,
        historyHeaderDate: LocalDate?
    ) {
        attempt(
            store: store,
            resultURL: resultURL,
            historyHeaderDate: historyHeaderDate,
            remainingAttempts: 50,
            lastFailure: "view tree was not ready"
        )
    }

    private static func attempt(
        store: NoonmarkStore,
        resultURL: URL,
        historyHeaderDate: LocalDate?,
        remainingAttempts: Int,
        lastFailure: String
    ) {
        do {
            let manifest = try manifest(
                store: store,
                historyHeaderDate: historyHeaderDate
            )
            try write(manifest, to: resultURL)
        } catch {
            guard remainingAttempts > 1 else {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? write(
                    "failed: \(error.localizedDescription); previous=\(lastFailure)",
                    to: resultURL
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                attempt(
                    store: store,
                    resultURL: resultURL,
                    historyHeaderDate: historyHeaderDate,
                    remainingAttempts: remainingAttempts - 1,
                    lastFailure: error.localizedDescription
                )
            }
        }
    }

    private static func manifest(
        store: NoonmarkStore,
        historyHeaderDate: LocalDate?
    ) throws -> String {
        guard store.engine.preferences.language == .english else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "screenshot store is not English"
            )
        }
        guard let rail = AppViewTreeE2E.view(identifier: "shell.detail-rail") else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "detail rail is not visible"
            )
        }
        let railWidth = AppViewTreeE2E.frameInWindow(for: rail).width
        let expectedRailWidth = store.page == .calendar
            ? MacUIShellLayout.calendarRailWidth
            : MacUIShellLayout.detailRailWidth
        guard abs(Double(railWidth) - expectedRailWidth) <= 2 else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "detail rail width is \(railWidth), expected \(expectedRailWidth)"
            )
        }
        let pageEvidence = if let historyHeaderDate {
            try historyHeaderEvidence(
                store: store,
                expectedDate: historyHeaderDate
            )
        } else {
            try pageEvidence(store: store, rail: rail)
        }
        let lines = [
            "ok",
            "page=\(store.page.rawValue)",
            "detail_width=\(String(format: "%.1f", railWidth))"
        ] + pageEvidence
        return lines.joined(separator: "\n")
    }

    private static func pageEvidence(
        store: NoonmarkStore,
        rail: NSView
    ) throws -> [String] {
        switch store.page {
        case .day:
            try dayEvidence(store: store, rail: rail)
        case .pool:
            try poolEvidence(store: store)
        case .future:
            try futureEvidence(store: store)
        case .unfinished:
            try unfinishedEvidence(store: store)
        case .completed:
            try completedEvidence(store: store)
        case .calendar:
            try calendarEvidence(store: store)
        case .recurring, .settings, .zhulong, .stickyNotes, .ideas:
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "populated screenshot verifier does not apply to this page"
            )
        }
    }

    private static func dayEvidence(
        store: NoonmarkStore,
        rail: NSView
    ) throws -> [String] {
        let items = store.engine.getDayTodo(date: store.selectedDate).traces
        guard let windowWidth = rail.window?.frame.width,
              let selected = items.first,
              store.selectedTraceID == selected.id,
              store.definition(for: selected)?.title
              == EnglishScreenshotFixtureE2EAutomation.longTitle
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "Day screenshot did not select the first populated identity"
            )
        }
        try verifyClassification(
            store: store,
            chainID: selected.chainID,
            surface: "day-row",
            instanceID: selected.id.description,
            expectedOverflowText: windowWidth
                <= CGFloat(MacUIWindowLayout.minimumWidth) + 1
                ? "+1"
                : nil
        )
        return classificationEvidenceLines + selectionLines(
            count: items.count,
            kind: "dayTrace",
            id: selected.id.description,
            title: EnglishScreenshotFixtureE2EAutomation.longTitle
        ) + (try dayHeaderEvidence(store: store))
            + (try verifyLongTitle(in: rail))
            + (try editorLabelControlExpectations(
                store: store,
                chainID: selected.chainID
            ))
    }

    private static func dayHeaderEvidence(
        store: NoonmarkStore
    ) throws -> [String] {
        let expectedFullDate = "5 July 2026"
        guard store.selectedDate == store.today,
              store.displayFullDate(store.selectedDate) == expectedFullDate,
              let date = AppViewTreeE2E.view(identifier: "day.header.date"),
              AppViewTreeE2E.verificationText(for: date) == expectedFullDate,
              let state = AppViewTreeE2E.view(identifier: "day.header.state"),
              AppViewTreeE2E.verificationText(for: state)
              == store.copy.dayBadgeToday,
              AppViewTreeE2E.hasNoVisibleView(
                  identifier: "day.header.today-action"
              )
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "today header did not expose one complete date/state surface"
            )
        }

        let dateFrame = AppViewTreeE2E.frameInWindow(for: date)
        let requiredDateWidth = ceil(
            (expectedFullDate as NSString).size(
                withAttributes: [
                    .font:
                    NoonmarkVisualMetrics
                        .dayHeaderDateMeasurementFont
                ]
            ).width
        )
        let actionIdentifiers = [
            "day.header.previous-action",
            "day.header.next-action",
            "day.header.choose-date-action"
        ]
        let actions = actionIdentifiers.compactMap(AppViewTreeE2E.view)
        let minimumTarget = CGFloat(
            MacUIAccessibilityLayout.minimumInteractiveTargetSize
        )
        guard dateFrame.width + 1 >= requiredDateWidth,
              actions.count == actionIdentifiers.count,
              actions.allSatisfy({ action in
                  let frame = AppViewTreeE2E.frameInWindow(for: action)
                  return frame.width + 0.5 >= minimumTarget
                      && frame.height + 0.5 >= minimumTarget
                      && dateFrame.intersects(frame) == false
              })
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "today header date was clipped, overlapped, or exposed a target below 28 points"
            )
        }

        let requiredDateWidthText = String(
            format: "%.1f",
            requiredDateWidth
        )
        let minimumTargetText = String(format: "%.1f", minimumTarget)
        return [
            "header_full_date=\(expectedFullDate)",
            "header_date_frame=\(NSStringFromRect(dateFrame))",
            "header_date_required_width=\(requiredDateWidthText)",
            "header_today_state_visible=true",
            "header_today_action_visible=false",
            "header_today_surface_count=1",
            "header_navigation_target_count=\(actions.count)",
            "header_navigation_minimum_target=\(minimumTargetText)",
            "header_date_width_sufficient=true",
            "header_navigation_targets_sufficient=true",
            "header_date_action_overlap=false"
        ]
    }

    private static func historyHeaderEvidence(
        store: NoonmarkStore,
        expectedDate: LocalDate
    ) throws -> [String] {
        let expectedFullDate = "30 September 2025"
        guard store.page == .day,
              expectedDate == LocalDate("2025-09-30"),
              store.selectedDate == expectedDate,
              store.isHistory,
              store.displayFullDate(store.selectedDate) == expectedFullDate,
              let date = AppViewTreeE2E.view(identifier: "day.header.date"),
              AppViewTreeE2E.verificationText(for: date) == expectedFullDate,
              let state = AppViewTreeE2E.view(identifier: "day.header.state"),
              AppViewTreeE2E.verificationText(for: state)
              == store.copy.dayBadgeLocked,
              let todayAction = AppViewTreeE2E.view(
                  identifier: "day.header.today-action"
              ),
              AppViewTreeE2E.verificationText(for: todayAction)
              == store.copy.today
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "history header did not expose its complete date, state, and Today action"
            )
        }

        let dateFrame = AppViewTreeE2E.frameInWindow(for: date)
        let requiredDateWidth = ceil(
            (expectedFullDate as NSString).size(
                withAttributes: [
                    .font:
                    NoonmarkVisualMetrics
                        .dayHeaderDateMeasurementFont
                ]
            ).width
        )
        let actionIdentifiers = [
            "day.header.previous-action",
            "day.header.today-action",
            "day.header.next-action",
            "day.header.choose-date-action"
        ]
        let actions = actionIdentifiers.compactMap(AppViewTreeE2E.view)
        let actionFrames = actions.map(AppViewTreeE2E.frameInWindow)
        let minimumTarget = CGFloat(
            MacUIAccessibilityLayout.minimumInteractiveTargetSize
        )
        guard dateFrame.width + 1 >= requiredDateWidth,
              actions.count == actionIdentifiers.count,
              actionFrames.allSatisfy({ frame in
                  frame.width + 0.5 >= minimumTarget
                      && frame.height + 0.5 >= minimumTarget
                      && dateFrame.intersects(frame) == false
              }),
              let actionsMaxY = actionFrames.map(\.maxY).max(),
              dateFrame.minY >= actionsMaxY + 4
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "history header did not select its complete two-row 28-point layout"
            )
        }

        return [
            "header_full_date=\(expectedFullDate)",
            "header_date_frame=\(NSStringFromRect(dateFrame))",
            "header_date_required_width=\(String(format: "%.1f", requiredDateWidth))",
            "header_state=\(store.copy.dayBadgeLocked)",
            "header_today_state_visible=false",
            "header_today_action_visible=true",
            "header_today_surface_count=1",
            "header_navigation_target_count=\(actions.count)",
            "header_navigation_minimum_target=\(String(format: "%.1f", minimumTarget))",
            "header_compact_row_count=2",
            "header_date_width_sufficient=true",
            "header_navigation_targets_sufficient=true",
            "header_date_action_overlap=false"
        ]
    }

    private static func poolEvidence(store: NoonmarkStore) throws -> [String] {
        let items = store.engine.taskPool()
        guard let selected = items.first,
              store.selectedPoolChainID == selected.chain.id
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "Task Pool screenshot did not select the first populated identity"
            )
        }
        try verifyClassification(
            store: store,
            chainID: selected.chain.id,
            surface: "pool-row",
            instanceID: selected.chain.id.description,
            categoryIdentifier: "classification.editor.category.\(selected.chain.id.description)"
        )
        return classificationEvidenceLines + selectionLines(
            count: items.count,
            kind: "taskChain",
            id: selected.chain.id.description,
            title: selected.definition.title
        )
    }

    private static func futureEvidence(store: NoonmarkStore) throws -> [String] {
        let items = store.engine.futurePlans(today: store.today)
        guard let selected = items.first,
              store.selectedTraceID == selected.trace.id
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "Upcoming screenshot did not select the first populated identity"
            )
        }
        try verifyClassification(
            store: store,
            chainID: selected.trace.chainID,
            surface: "future-row",
            instanceID: selected.trace.id.description
        )
        return classificationEvidenceLines + selectionLines(
            count: items.count,
            kind: "dayTrace",
            id: selected.trace.id.description,
            title: selected.definition.title
        )
    }

    private static func unfinishedEvidence(
        store: NoonmarkStore
    ) throws -> [String] {
        let items = store.engine.unfinishedPool()
        guard let selected = items.first,
              let trace = selected.latestUnfinishedTrace,
              store.selectedUnfinishedChainID == selected.chain.id
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "Unfinished screenshot did not select the first populated identity"
            )
        }
        try verifyClassification(
            store: store,
            chainID: selected.chain.id,
            surface: "unfinished-row",
            instanceID: trace.id.description
        )
        return classificationEvidenceLines + selectionLines(
            count: items.count,
            kind: "taskChain",
            id: selected.chain.id.description,
            title: selected.definition.title
        )
    }

    private static func completedEvidence(
        store: NoonmarkStore
    ) throws -> [String] {
        let items = store.engine.completedPool()
        guard let selected = items.first,
              store.selectedCompletedTraceID == selected.trace.id
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "Completed screenshot did not select the first populated identity"
            )
        }
        try verifyClassification(
            store: store,
            chainID: selected.trace.chainID,
            surface: "completed-row",
            instanceID: selected.trace.id.description
        )
        return classificationEvidenceLines + selectionLines(
            count: items.count,
            kind: "dayTrace",
            id: selected.trace.id.description,
            title: selected.definition.title
        )
    }

    private static func calendarEvidence(
        store: NoonmarkStore
    ) throws -> [String] {
        let traces = store.engine.getDayTodo(
            date: store.selectedCalendarDate
        ).traces
        guard store.selectedCalendarDate == store.today,
              traces.isEmpty == false,
              AppViewTreeE2E.view(
                  identifier: "calendar.date-cell.\(store.today.description).heat"
              ) != nil
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "Calendar screenshot did not expose the populated selected day"
            )
        }
        let labelFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let labels = [
            ("continuation", store.copy.continuation),
            ("change", store.copy.change),
            ("risk", store.copy.risk)
        ]
        let labelFrames = try labels.map { identifier, label in
            guard let anchor = AppViewTreeE2E.view(
                identifier: "calendar.insight.\(identifier).label"
            ) else {
                throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                    "Calendar screenshot did not expose the \(identifier) insight label"
                )
            }
            let frame = AppViewTreeE2E.frameInWindow(for: anchor)
            let requiredWidth = (label as NSString).size(
                withAttributes: [.font: labelFont]
            ).width
            guard frame.width + 1 >= requiredWidth,
                  frame.height <= labelFont.boundingRectForFont.height + 2
            else {
                throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                    "Calendar insight label wrapped or clipped: \(identifier) frame=\(frame) requiredWidth=\(requiredWidth)"
                )
            }
            return "\(identifier)=\(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))"
        }
        return selectionLines(
            count: traces.count,
            kind: "calendarDate",
            id: store.selectedCalendarDate.description,
            title: store.displayFullDate(store.selectedCalendarDate)
        ) + ["calendarInsightLabels=\(labelFrames.joined(separator: ","))"]
    }

    private static func verifyClassification(
        store: NoonmarkStore,
        chainID: TaskChainID,
        surface: String,
        instanceID: String,
        categoryIdentifier explicitCategoryIdentifier: String? = nil,
        expectedOverflowText: String? = nil
    ) throws {
        guard case let .task(classification) = try store.engine.classification(
            .task(chainID)
        ),
        classification.category?.name
            == EnglishScreenshotFixtureE2EAutomation.categoryName,
        Set(classification.labels.map(\.name)) == [
            EnglishScreenshotFixtureE2EAutomation.primaryLabelName,
            EnglishScreenshotFixtureE2EAutomation.secondaryLabelName
        ]
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "selected task classification is missing"
            )
        }
        let categoryIdentifier = explicitCategoryIdentifier
            ?? "classification.\(surface).\(instanceID).category"
        guard let categoryView = AppViewTreeE2E.view(
            identifier: categoryIdentifier
        ),
        AppViewTreeE2E.verificationText(for: categoryView)
            == EnglishScreenshotFixtureE2EAutomation.categoryName
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "classification group is not visible on its real surface"
            )
        }
        if let expectedOverflowText {
            try verifyClassificationOverflow(
                expectedOverflowText,
                surface: surface,
                instanceID: instanceID
            )
        } else {
            try verifyRowLabels(
                classification.labels,
                surface: surface,
                instanceID: instanceID
            )
        }
    }

    private static func verifyClassificationOverflow(
        _ expectedText: String,
        surface: String,
        instanceID: String
    ) throws {
        let identifier = "classification.\(surface).\(instanceID).overflow"
        let actualText = AppViewTreeE2E.view(identifier: identifier).flatMap {
            AppViewTreeE2E.verificationText(for: $0)
        }
        guard actualText == expectedText else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "classification overflow does not match the minimum-width surface contract: expected=\(expectedText) actual=\(actualText ?? "missing") identifier=\(identifier)"
            )
        }
    }

    private static func verifyRowLabels(
        _ labels: [ClassificationItemProjection],
        surface: String,
        instanceID: String
    ) throws {
        let allLabelsAreVisible = labels.allSatisfy { label in
            let identifier = "classification.\(surface).\(instanceID).label.\(label.id)"
            guard let view = AppViewTreeE2E.view(identifier: identifier) else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: view) == label.name
        }
        guard allLabelsAreVisible else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "classification tags are not visible on their real row surface"
            )
        }
    }

    private static func editorLabelControlExpectations(
        store: NoonmarkStore,
        chainID: TaskChainID
    ) throws -> [String] {
        guard case let .task(classification) = try store.engine.classification(
            .task(chainID)
        ), classification.labels.count == 2 else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "selected detail editor does not have exactly two tag controls"
            )
        }
        let expectations = classification.labels.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.map { label in
            let identifier = "classification.editor.remove-label.\(chainID.description).\(label.id)"
            let expectedLabel = "Remove the tag “\(label.name)” from “\(EnglishScreenshotFixtureE2EAutomation.longTitle)”"
            return "classification_remove_button=\(identifier)\t\(expectedLabel)"
        }
        return ["classification_remove_button_count=2"] + expectations
    }

    private static func verifyLongTitle(in rail: NSView) throws -> [String] {
        guard let textView = AppViewTreeE2E.view(
            identifier: "detail.title.input"
        ) as? NSTextView,
        AppViewTreeE2E.verificationText(for: textView)
            == EnglishScreenshotFixtureE2EAutomation.longTitle,
        textView.accessibilityValue()
            == EnglishScreenshotFixtureE2EAutomation.longTitle,
        let layoutManager = textView.layoutManager,
        let textContainer = textView.textContainer
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "long title is incomplete in the real view tree or AX value"
            )
        }
        layoutManager.ensureLayout(for: textContainer)
        var lineCount = 0
        layoutManager.enumerateLineFragments(
            forGlyphRange: layoutManager.glyphRange(for: textContainer)
        ) { _, _, _, _, _ in
            lineCount += 1
        }
        let titleFrame = AppViewTreeE2E.frameInWindow(for: textView)
        let railFrame = AppViewTreeE2E.frameInWindow(for: rail)
        guard lineCount == 2,
              titleFrame.minX >= railFrame.minX - 1,
              titleFrame.maxX <= railFrame.maxX + 1,
              titleFrame.minY >= railFrame.minY - 1,
              titleFrame.maxY <= railFrame.maxY + 1
        else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "long title did not render as two contained lines"
            )
        }
        return [
            "long_title_view_tree=complete",
            "long_title_ax=complete",
            "long_title_line_count=\(lineCount)",
            "long_title_frame=\(NSStringFromRect(titleFrame))"
        ]
    }

    private static func selectionLines(
        count: Int,
        kind: String,
        id: String,
        title: String
    ) -> [String] {
        [
            "count=\(count)",
            "selected_kind=\(kind)",
            "selected_id=\(id)",
            "selected_title=\(title)"
        ]
    }

    private static var classificationEvidenceLines: [String] {
        [
            "classification_category_visible=\(EnglishScreenshotFixtureE2EAutomation.categoryName)",
            "classification_label_visible=\(EnglishScreenshotFixtureE2EAutomation.primaryLabelName)",
            "classification_secondary_label_visible=\(EnglishScreenshotFixtureE2EAutomation.secondaryLabelName)"
        ]
    }

    private static func write(_ result: String, to resultURL: URL) throws {
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

private struct FixtureIdentities {
    let dayTraceID: DayTraceID
    let poolChainID: TaskChainID
    let futureTraceID: DayTraceID
    let unfinishedChainID: TaskChainID
    let unfinishedTraceID: DayTraceID
    let completedTraceID: DayTraceID
}

private extension DayTraceID {
    func flatMapChain(in engine: NoonmarkEngine) throws -> TaskChainID {
        guard let chainID = engine.traces[self]?.chainID else {
            throw EnglishScreenshotFixtureE2EAutomation.Failure.failed(
                "English fixture selected Day trace is missing"
            )
        }
        return chainID
    }
}

extension EnglishScreenshotFixtureE2EAutomation {
    enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }
}
