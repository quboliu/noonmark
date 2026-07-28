import AppKit
import CryptoKit
import Foundation
import NoonmarkAI
import NoonmarkCore
import NoonmarkDemoSupport
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkStorage
import NoonmarkZhulong

struct InteractiveDemoFixtureAutomation: LaunchAutomationRunnable {
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains("--interactive-demo-fixture"),
              let resultPath = AppLaunchArguments.value(
                  after: "--interactive-demo-result-url"
              )
        else {
            return nil
        }
        return Self(
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            let fixture = try NoonmarkDemoFixture.make(
                anchorDate: store.today
            )
            var candidate = try NoonmarkEngine(
                snapshot: fixture.engine.snapshot()
            )
            let providerIdentity = try store.zhulongProviderIdentity()
            let sessions = try makeZhulongSessions(
                engine: &candidate,
                today: store.today,
                providerIdentity: providerIdentity
            )
            try install(
                engine: candidate,
                sessions: sessions,
                fixture: fixture,
                on: store
            )
            verifyScopeAuthorizationPresentation(
                fixture: fixture,
                engine: candidate,
                sessions: sessions,
                store: store,
                remainingAttempts: 100
            )
        } catch {
            writeFailure(error)
            store.showOperationFailure(
                .persistence,
                error: error
            )
        }
    }

    @MainActor
    private func verifyScopeAuthorizationPresentation(
        fixture: NoonmarkDemoFixture,
        engine: NoonmarkEngine,
        sessions: [ZhulongSession],
        store: NoonmarkStore,
        remainingAttempts: Int
    ) {
        guard let insightSession = sessions.first(where: {
            $0.purpose == .habitInsight
        }) else {
            finishWithFailure(
                InteractiveDemoFixtureError.incompleteZhulongCoverage,
                on: store
            )
            return
        }
        store.zhulongWorkspace.selectSession(insightSession.id)
        store.page = .zhulong

        guard remainingAttempts > 0 else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError
                    .scopeAuthorizationPresentationFailed,
                on: store
            )
            return
        }
        guard AppViewTreeE2E.activateMainWindow(),
              AppViewTreeE2E.view(
                  identifier: "zhulong-session-stream"
              ) != nil
        else {
            retryScopeAuthorizationPresentation(
                fixture: fixture,
                engine: engine,
                sessions: sessions,
                store: store,
                remainingAttempts: remainingAttempts - 1
            )
            return
        }
        guard AppViewTreeE2E.hasNoVisibleView(
            identifier: "zhulong-authorize-scope"
        ) else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError
                    .scopeAuthorizationPresentationFailed,
                on: store
            )
            return
        }
        verifyZhulongHeaderPresentation(
            fixture: fixture,
            engine: engine,
            sessions: sessions,
            store: store,
            remainingAttempts: 100
        )
    }

    @MainActor
    private func retryScopeAuthorizationPresentation(
        fixture: NoonmarkDemoFixture,
        engine: NoonmarkEngine,
        sessions: [ZhulongSession],
        store: NoonmarkStore,
        remainingAttempts: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            verifyScopeAuthorizationPresentation(
                fixture: fixture,
                engine: engine,
                sessions: sessions,
                store: store,
                remainingAttempts: remainingAttempts
            )
        }
    }

    @MainActor
    private func verifyZhulongHeaderPresentation(
        fixture: NoonmarkDemoFixture,
        engine: NoonmarkEngine,
        sessions: [ZhulongSession],
        store: NoonmarkStore,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError
                    .presentationContractFailed,
                on: store
            )
            return
        }
        guard AppViewTreeE2E.view(
            identifier: "zhulong.session.title"
        ) != nil,
        AppViewTreeE2E.view(
            identifier: "zhulong-session-show-home"
        ) != nil,
        AppViewTreeE2E.view(
            identifier: "zhulong-stream-variant-menu"
        ) != nil,
        AppViewTreeE2E.view(
            identifier: "zhulong-session-composer"
        ) != nil,
        AppViewTreeE2E.view(
            identifier: "zhulong-session-send"
        ) != nil,
        AppViewTreeE2E.hasNoVisibleView(
            identifier: "zhulong-session-stop"
        ),
        AppViewTreeE2E.hasNoVisibleView(
            identifier: "zhulong-session-pause"
        )
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                verifyZhulongHeaderPresentation(
                    fixture: fixture,
                    engine: engine,
                    sessions: sessions,
                    store: store,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }

        store.page = .pool
        store.clearSelection()
        store.isDetailRailExpanded = true
        verifyTaskPoolPresentation(
            fixture: fixture,
            engine: engine,
            sessions: sessions,
            store: store,
            remainingAttempts: 100
        )
    }

    @MainActor
    private func verifyTaskPoolPresentation(
        fixture: NoonmarkDemoFixture,
        engine: NoonmarkEngine,
        sessions: [ZhulongSession],
        store: NoonmarkStore,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError
                    .presentationContractFailed,
                on: store
            )
            return
        }
        let prefix = "detail.summary.pool"
        let analysisVisible = AppViewTreeE2E.view(
            identifier: "\(prefix).analysis"
        ) != nil
        let reportVisible = AppViewTreeE2E.view(
            identifier: "\(prefix).analysis.report"
        ) != nil
        let analysisReportContractVerified =
            taskPoolAnalysisReportContractIsValid(
                sessions: sessions,
                store: store
            )
        guard AppViewTreeE2E.activateMainWindow(),
              AppViewTreeE2E.view(identifier: prefix) != nil,
              AppViewTreeE2E.view(
                  identifier: "\(prefix).statistics"
              ) != nil,
              AppViewTreeE2E.hasNoVisibleView(
                  identifier: "\(prefix).signals"
              ),
              AppViewTreeE2E.hasNoVisibleView(
                  identifier: "\(prefix).recommendations"
              ),
              AppViewTreeE2E.hasNoVisibleView(
                  identifier: "\(prefix).zhulong-hint"
              ),
              analysisVisible == store.isZhulongProviderReady,
              reportVisible == store.isZhulongProviderReady,
              analysisReportContractVerified
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                verifyTaskPoolPresentation(
                    fixture: fixture,
                    engine: engine,
                    sessions: sessions,
                    store: store,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }

        let presentationVerification =
            InteractiveDemoPresentationVerification(
                scopeAuthorizationUIVerified: true,
                taskPoolStatisticsPresentationVerified: true,
                taskPoolProviderBoundaryVerified: true,
                taskPoolProviderReportPresentationVerified:
                analysisReportContractVerified,
                taskCollectionCategoryVisibilityVerified: false,
                calendarRecurringBoundaryVerified: false,
                taskCyclePresentationVerified: false,
                zhulongHeaderComposerHierarchyVerified: true
            )
        let collectionCheckContext = DemoCollectionCheckContext(
            fixture: fixture,
            engine: engine,
            sessions: sessions,
            store: store,
            presentationVerification: presentationVerification,
            cases: categoryVerificationCases
        )
        verifyTaskCollectionCategoryVisibility(
            context: collectionCheckContext,
            index: 0,
            remainingAttempts: 100
        )
    }

    @MainActor
    private func verifyTaskCollectionCategoryVisibility(
        context: DemoCollectionCheckContext,
        index: Int,
        remainingAttempts: Int
    ) {
        guard context.cases.indices.contains(index),
              remainingAttempts > 0
        else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError
                    .presentationContractFailed,
                on: context.store
            )
            return
        }
        let verificationCase = context.cases[index]
        guard context.store.page == verificationCase.page else {
            retryTaskCollectionCategoryVisibility(
                context: context,
                index: index,
                remainingAttempts: remainingAttempts - 1
            )
            return
        }

        let sectionIdentifiers = AppViewTreeE2E.identifiers(
            withPrefix: "task-collection.section.category."
        )
        let rowIdentifiers = taskCollectionRowIdentifiers(
            prefixes: verificationCase.rowPrefixes
        )
        let categoryIdentifiers = rowIdentifiers?.filter {
            $0.hasSuffix(".category")
        }
        let expectedGroupedRowCategoryIdentifiers =
            groupedRowCategoryIdentifiers(
                context: context,
                verificationCase: verificationCase
            )
        let labelIdentifiers = rowIdentifiers?.filter {
            $0.contains(".label.")
        }
        let categoryPlacementIsValid =
            switch verificationCase.organization {
            case .flat:
                sectionIdentifiers?.isEmpty == true
                    && categoryIdentifiers?.isEmpty == false
            case .grouped:
                sectionIdentifiers?.isEmpty == false
                    && categoryIdentifiers
                    == expectedGroupedRowCategoryIdentifiers
            }
        let completedHierarchyIsValid =
            completedHierarchyPresentationIsValid(
                context: context,
                verificationCase: verificationCase
            )
        let recurringProjectionIsValid =
            taskCollectionRecurringProjectionIsValid(
                context: context,
                verificationCase: verificationCase
            )
        guard AppViewTreeE2E.activateMainWindow(),
              labelIdentifiers?.isEmpty == false,
              categoryPlacementIsValid,
              completedHierarchyIsValid,
              recurringProjectionIsValid
        else {
            retryTaskCollectionCategoryVisibility(
                context: context,
                index: index,
                remainingAttempts: remainingAttempts - 1
            )
            return
        }
        do {
            try captureTaskCollectionScreenshot(page: verificationCase.page)
        } catch {
            finishWithFailure(error, on: context.store)
            return
        }

        let nextIndex = index + 1
        guard context.cases.indices.contains(nextIndex) else {
            guard AppViewTreeE2E.click(
                identifier: "sidebar.nav.calendar"
            )
            else {
                AppViewTreeE2E.writeDump(beside: resultURL)
                finishWithFailure(
                    InteractiveDemoFixtureError
                        .presentationContractFailed,
                    on: context.store
                )
                return
            }
            retryCalendarRecurringBoundary(
                context: context,
                remainingAttempts: 100
            )
            return
        }
        guard AppViewTreeE2E.click(
            identifier: context.cases[nextIndex]
                .sidebarNavigationIdentifier
        ) else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError
                    .presentationContractFailed,
                on: context.store
            )
            return
        }
        retryTaskCollectionCategoryVisibility(
            context: context,
            index: nextIndex,
            remainingAttempts: 100
        )
    }

    @MainActor
    private func taskCollectionRecurringProjectionIsValid(
        context: DemoCollectionCheckContext,
        verificationCase: DemoCollectionCheckCase
    ) -> Bool {
        switch verificationCase.page {
        case .future:
            futureRecurringProjectionIsValid(context: context)
        case .day:
            dayRecurringProjectionIsValid(context: context)
        case .pool, .unfinished, .completed:
            AppViewTreeE2E.identifiers(
                withPrefix: "task-cycle-track."
            )?.isEmpty == true
        case .recurring, .calendar, .zhulong, .settings:
            true
        }
    }

    @MainActor
    private func futureRecurringProjectionIsValid(
        context: DemoCollectionCheckContext
    ) -> Bool {
        let recurringItems =
            context.store.visibleFuturePlanItems().filter {
                context.engine.isRecurringTaskChain(
                    $0.trace.chainID
                )
            }
        let firstRecurringCategoryIdentifier =
            recurringItems.first.map {
                TaskClassificationAccessibilityNamespace(
                    surface: "future-row",
                    instanceID: $0.trace.id.description
                ).categoryIdentifier
            }
        return AppViewTreeE2E.view(
            identifier: "future.recurring-visibility"
        ).flatMap(AppViewTreeE2E.verificationText) == "15"
            && recurringItems.count == 16
            && firstRecurringCategoryIdentifier.flatMap {
                AppViewTreeE2E.view(identifier: $0)
            } != nil
            && AppViewTreeE2E.identifiers(
                withPrefix: "task-cycle-track."
            )?.isEmpty == true
    }

    @MainActor
    private func dayRecurringProjectionIsValid(
        context: DemoCollectionCheckContext
    ) -> Bool {
        let recurringTraceIDs = context.engine.getDayTodo(
            date: context.fixture.anchorDate
        ).traces.filter {
            context.engine.isRecurringTaskChain($0.chainID)
        }.map(\.id)
        return recurringTraceIDs.isEmpty == false
            && recurringTraceIDs.allSatisfy {
                AppViewTreeE2E.view(
                    identifier:
                    "day-row.task-cycle.\($0.description)"
                ) != nil
            }
    }

    @MainActor
    private func retryCalendarRecurringBoundary(
        context: DemoCollectionCheckContext,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.presentationContractFailed,
                on: context.store
            )
            return
        }
        let ordinaryTrace = context.engine.calendarTraces(
            for: context.fixture.anchorDate
        ).first
        let recurringTraceIDs = context.engine.traces.values.filter {
            context.engine.isRecurringTaskChain($0.chainID)
        }.map(\.id)
        let recurringRowsAreHidden = recurringTraceIDs.allSatisfy {
            AppViewTreeE2E.view(
                identifier: "calendar.trace.\($0.description).status-dot"
            ) == nil
        }
        guard context.store.page == .calendar,
              context.store.selectedCalendarDate
              == context.fixture.anchorDate,
              let ordinaryTrace,
              AppViewTreeE2E.activateMainWindow(),
              AppViewTreeE2E.view(
                  identifier:
                  "calendar.trace.\(ordinaryTrace.id.description).status-dot"
              ) != nil,
              recurringRowsAreHidden
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                retryCalendarRecurringBoundary(
                    context: context,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        do {
            try captureTaskCollectionScreenshot(page: .calendar)
        } catch {
            finishWithFailure(error, on: context.store)
            return
        }

        let cycleContext = DemoCycleCheckContext(
            fixture: context.fixture,
            engine: context.engine,
            sessions: context.sessions,
            store: context.store,
            presentationVerification:
            context.presentationVerification
                .verifyingTaskCollectionCategoryVisibility()
                .verifyingCalendarRecurringBoundary(),
            detailVerificationStage: .ended
        )
        guard AppViewTreeE2E.click(
            identifier: "sidebar.nav.recurring"
        )
        else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.presentationContractFailed,
                on: context.store
            )
            return
        }
        retryTaskCyclePresentation(
            context: cycleContext,
            remainingAttempts: 100
        )
    }

    @MainActor
    private func retryTaskCollectionCategoryVisibility(
        context: DemoCollectionCheckContext,
        index: Int,
        remainingAttempts: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            verifyTaskCollectionCategoryVisibility(
                context: context,
                index: index,
                remainingAttempts: remainingAttempts
            )
        }
    }

    @MainActor
    private func verifyTaskCyclePresentation(
        context: DemoCycleCheckContext,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.presentationContractFailed,
                on: context.store
            )
            return
        }
        let tracks = context.engine.taskCycleTracks(
            today: context.fixture.anchorDate
        )
        let presentationExpectations =
            taskCyclePresentationExpectations(context: context)
        guard context.store.page == .recurring,
              tracks.map(\.title)
              == presentationExpectations.map(\.title),
              let track = tracks.first(where: {
                  $0.title
                      == DemoCycleDetailVerificationStage.active
                      .trackTitle
              }),
              let detailTrack = tracks.first(where: {
                  $0.title
                      == context.detailVerificationStage.trackTitle
              }),
              let detailExpectation =
              presentationExpectations.first(where: {
                  $0.title == detailTrack.title
              })
        else {
            retryTaskCyclePresentation(
                context: context,
                remainingAttempts: remainingAttempts - 1
            )
            return
        }
        let expectedTrackIdentifier =
            "task-cycle-track.recurring.\(track.id.description)"
        let expectedTrackIdentifiers: Set<String> = [
            expectedTrackIdentifier,
            "\(expectedTrackIdentifier).detail",
            "\(expectedTrackIdentifier).disclosure",
            "\(expectedTrackIdentifier).lifecycle",
            "\(expectedTrackIdentifier).lifecycle-icon"
        ]
        let expectedDayIdentifiers = Set(track.days.map {
            "task-cycle-day.recurring.\(track.id.description).\($0.date.description).\($0.state.rawValue)"
        })
        let trackIdentifiers = AppViewTreeE2E.identifiers(
            withPrefix: "task-cycle-track.recurring."
        )
        let expectedTrackRootIdentifiers = Set(tracks.map {
            "task-cycle-track.recurring.\($0.id.description)"
        })
        let lifecyclePresentationsAreCorrect = zip(
            tracks,
            presentationExpectations
        ).allSatisfy { track, expectation in
            let identifier =
                "task-cycle-track.recurring."
                + "\(track.id.description).lifecycle"
            let iconIdentifier =
                "task-cycle-track.recurring."
                + "\(track.id.description).lifecycle-icon"
            guard let view = AppViewTreeE2E.view(
                identifier: identifier
            ), let iconView = AppViewTreeE2E.view(
                identifier: iconIdentifier
            ) else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: view)
                == expectation.lifecycleSummary
                && AppViewTreeE2E.verificationText(for: iconView)
                == expectation.lifecycleIconVerification
        }
        let expectedListVerificationText =
            presentationExpectations.map {
                "\($0.title)|\($0.lifecycleSummary)"
            }.joined(separator: "\n")
        let actualTrackRootIdentifiers =
            (trackIdentifiers ?? []).intersection(
                expectedTrackRootIdentifiers
            )
        let dayIdentifiers = AppViewTreeE2E.identifiers(
            withPrefix:
            "task-cycle-day.recurring.\(track.id.description)."
        )
        guard AppViewTreeE2E.activateMainWindow(),
              AppViewTreeE2E.view(
                  identifier: "recurring-plans.list"
              ).flatMap(AppViewTreeE2E.verificationText)
              == expectedListVerificationText,
              expectedTrackIdentifiers.isSubset(
                  of: trackIdentifiers ?? []
              ),
              actualTrackRootIdentifiers == expectedTrackRootIdentifiers,
              lifecyclePresentationsAreCorrect,
              AppViewTreeE2E.view(
                  identifier: "task-cycle-create.open"
              ) == nil
        else {
            retryTaskCyclePresentation(
                context: context,
                remainingAttempts: remainingAttempts - 1
            )
            return
        }
        switch prepareRecurringPlanDetail(
            context: context,
            track: detailTrack,
            expectsPlanEditing:
            detailExpectation.expectsPlanEditing,
            expectsStop:
            detailExpectation.expectsStop
        ) {
        case .ready:
            if let nextStage =
                context.detailVerificationStage.next
            {
                retryTaskCyclePresentation(
                    context: context.advancing(to: nextStage),
                    remainingAttempts: 100
                )
                return
            }
        case .retry:
            retryTaskCyclePresentation(
                context: context,
                remainingAttempts: 100
            )
            return
        case .failed:
            return
        }
        if dayIdentifiers?.isEmpty == true {
            guard AppViewTreeE2E.click(
                identifier: "\(expectedTrackIdentifier).disclosure"
            ) else {
                AppViewTreeE2E.writeDump(beside: resultURL)
                finishWithFailure(
                    InteractiveDemoFixtureError.presentationContractFailed,
                    on: context.store
                )
                return
            }
            retryTaskCyclePresentation(
                context: context,
                remainingAttempts: 100
            )
            return
        }
        guard dayIdentifiers == expectedDayIdentifiers else {
            retryTaskCyclePresentation(
                context: context,
                remainingAttempts: remainingAttempts - 1
            )
            return
        }
        do {
            try captureTaskCollectionScreenshot(page: .recurring)
        } catch {
            finishWithFailure(error, on: context.store)
            return
        }

        navigateToAnchorTaskCycleDay(
            context: context,
            track: track
        )
    }

    @MainActor
    private func navigateToAnchorTaskCycleDay(
        context: DemoCycleCheckContext,
        track: TaskCycleTrack
    ) {
        guard let anchorDay = track.days.first(where: {
            $0.date == context.fixture.anchorDate
                && $0.navigationTarget != nil
        }), let navigationTarget = anchorDay.navigationTarget,
        AppViewTreeE2E.click(
            identifier: cycleDayIdentifier(
                day: anchorDay,
                track: track
            )
        ) else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.presentationContractFailed,
                on: context.store
            )
            return
        }
        retryTaskCycleNavigation(
            context: context,
            expectedTraceID: navigationTarget.traceID,
            expectedDate: navigationTarget.date,
            remainingAttempts: 100
        )
    }

    @MainActor
    private func prepareRecurringPlanDetail(
        context: DemoCycleCheckContext,
        track: TaskCycleTrack,
        expectsPlanEditing: Bool,
        expectsStop: Bool
    ) -> RecurringPlanDetailPreparation {
        guard context.store.selectedTaskCycleSeriesID == track.id else {
            guard AppViewTreeE2E.click(
                identifier:
                "task-cycle-track.recurring."
                    + "\(track.id.description).detail"
            ) else {
                AppViewTreeE2E.writeDump(beside: resultURL)
                finishWithFailure(
                    InteractiveDemoFixtureError.presentationContractFailed,
                    on: context.store
                )
                return .failed
            }
            return .retry
        }
        let hasPlanEditing = AppViewTreeE2E.view(
            identifier: "task-cycle-detail.edit-plan"
        ) != nil
        let hasStop = AppViewTreeE2E.view(
            identifier: "task-cycle-detail.stop"
        ) != nil
        guard AppViewTreeE2E.view(
            identifier: "task-cycle-detail.\(track.id.description)"
        ) != nil,
        AppViewTreeE2E.view(
            identifier:
            "classification.editor.cycle-\(track.id.description)"
        ) != nil,
        hasPlanEditing == expectsPlanEditing,
        hasStop == expectsStop
        else {
            return .retry
        }
        return .ready
    }

    @MainActor
    private func taskCyclePresentationExpectations(
        context: DemoCycleCheckContext
    ) -> [DemoCyclePresentationExpectation] {
        let today = context.store.displayDate(
            context.fixture.anchorDate
        )
        let upcomingDate = context.store.displayDate(
            DemoFixtureClock.offset(
                context.fixture.anchorDate,
                by: 2
            )
        )
        return switch context.store.copy.language {
        case .chinese:
            [
                DemoCyclePresentationExpectation(
                    title: "每日产品复盘",
                    lifecycleSummary: "进行中 · 下次 \(today)",
                    lifecycleIconVerification:
                    MacUIRecurringLifecycleStyles.active.verificationText,
                    expectsPlanEditing: true,
                    expectsStop: true
                ),
                DemoCyclePresentationExpectation(
                    title: "准备下周工作回顾",
                    lifecycleSummary:
                    "即将开始 · \(upcomingDate)开始",
                    lifecycleIconVerification:
                    MacUIRecurringLifecycleStyles.upcoming.verificationText,
                    expectsPlanEditing: true,
                    expectsStop: true
                ),
                DemoCyclePresentationExpectation(
                    title: "完成首次晨间回顾",
                    lifecycleSummary: "已结束 · 完成 1/1 次",
                    lifecycleIconVerification:
                    MacUIRecurringLifecycleStyles.ended.verificationText,
                    expectsPlanEditing: false,
                    expectsStop: false
                ),
                DemoCyclePresentationExpectation(
                    title: "暂停周报打磨",
                    lifecycleSummary: "已停止 · 停止于 \(today)",
                    lifecycleIconVerification:
                    MacUIRecurringLifecycleStyles.stopped.verificationText,
                    expectsPlanEditing: false,
                    expectsStop: false
                )
            ]
        case .english:
            [
                DemoCyclePresentationExpectation(
                    title: "每日产品复盘",
                    lifecycleSummary: "Active · Next \(today)",
                    lifecycleIconVerification:
                    MacUIRecurringLifecycleStyles.active.verificationText,
                    expectsPlanEditing: true,
                    expectsStop: true
                ),
                DemoCyclePresentationExpectation(
                    title: "准备下周工作回顾",
                    lifecycleSummary:
                    "Upcoming · Starts \(upcomingDate)",
                    lifecycleIconVerification:
                    MacUIRecurringLifecycleStyles.upcoming.verificationText,
                    expectsPlanEditing: true,
                    expectsStop: true
                ),
                DemoCyclePresentationExpectation(
                    title: "完成首次晨间回顾",
                    lifecycleSummary: "Ended · 1/1 completed",
                    lifecycleIconVerification:
                    MacUIRecurringLifecycleStyles.ended.verificationText,
                    expectsPlanEditing: false,
                    expectsStop: false
                ),
                DemoCyclePresentationExpectation(
                    title: "暂停周报打磨",
                    lifecycleSummary: "Stopped · Stopped \(today)",
                    lifecycleIconVerification:
                    MacUIRecurringLifecycleStyles.stopped.verificationText,
                    expectsPlanEditing: false,
                    expectsStop: false
                )
            ]
        }
    }

    private func cycleDayIdentifier(
        day: TaskCycleTrackDay,
        track: TaskCycleTrack
    ) -> String {
        "task-cycle-day.recurring.\(track.id.description)."
            + "\(day.date.description).\(day.state.rawValue)"
    }

    @MainActor
    private func retryTaskCyclePresentation(
        context: DemoCycleCheckContext,
        remainingAttempts: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            verifyTaskCyclePresentation(
                context: context,
                remainingAttempts: remainingAttempts
            )
        }
    }

    @MainActor
    private func retryTaskCycleNavigation(
        context: DemoCycleCheckContext,
        expectedTraceID: DayTraceID,
        expectedDate: LocalDate,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.presentationContractFailed,
                on: context.store
            )
            return
        }
        guard context.store.page == .day,
              context.store.selectedDate == expectedDate,
              context.store.selectedTraceID == expectedTraceID,
              taskCycleClassificationEditorMatchesStore(
                  store: context.store,
                  traceID: expectedTraceID
              ),
              taskLifecycleSummaryIsPlain(
                  traceID: expectedTraceID
              )
        else {
            if remainingAttempts == 1 {
                AppViewTreeE2E.writeDump(beside: resultURL)
                finishWithFailure(
                    InteractiveDemoFixtureError
                        .taskCycleDetailPresentationFailed(
                            taskCycleDetailPresentationDiagnostic(
                                store: context.store,
                                traceID: expectedTraceID
                            )
                        ),
                    on: context.store
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                retryTaskCycleNavigation(
                    context: context,
                    expectedTraceID: expectedTraceID,
                    expectedDate: expectedDate,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        do {
            let result = try manifest(
                fixture: context.fixture,
                engine: context.engine,
                sessions: context.sessions,
                store: context.store,
                presentationVerification:
                context.presentationVerification
                    .verifyingTaskCyclePresentation()
            )
            try write(result)
        } catch {
            finishWithFailure(error, on: context.store)
        }
    }

    @MainActor
    private func taskCycleClassificationEditorMatchesStore(
        store: NoonmarkStore,
        traceID: DayTraceID
    ) -> Bool {
        guard let trace = store.engine.traces[traceID],
              let classification = store.currentClassification(
                  for: trace.chainID
              ),
              let category = classification.category,
              let categoryView = AppViewTreeE2E.view(
                  identifier:
                  "classification.editor.category.\(trace.chainID.description)"
              ),
              AppViewTreeE2E.verificationText(for: categoryView)
              == category.name
        else {
            return false
        }
        return classification.labels.allSatisfy { label in
            let identifier =
                "classification.editor.label-chip."
                + "\(trace.chainID.description).\(label.id)"
            guard let view = AppViewTreeE2E.view(
                identifier: identifier
            ) else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: view)
                == label.name
        }
    }

    @MainActor
    private func taskLifecycleSummaryIsPlain(
        traceID: DayTraceID
    ) -> Bool {
        guard let view = AppViewTreeE2E.view(
            identifier:
            "detail.lifecycle-summary.\(traceID.description)"
        ) else {
            return false
        }
        return AppViewTreeE2E.verificationText(for: view)
            == "plain"
    }

    @MainActor
    private func taskCycleDetailPresentationDiagnostic(
        store: NoonmarkStore,
        traceID: DayTraceID
    ) -> String {
        guard let trace = store.engine.traces[traceID] else {
            return "trace=missing id=\(traceID.description)"
        }
        let classification = store.currentClassification(
            for: trace.chainID
        )
        let categoryIdentifier =
            "classification.editor.category."
            + trace.chainID.description
        let categoryText = AppViewTreeE2E.view(
            identifier: categoryIdentifier
        ).flatMap(AppViewTreeE2E.verificationText)
        let expectedLabels = classification?.labels.map {
            "\($0.id):\($0.name)"
        }.sorted() ?? []
        let visibleLabelIdentifiers = AppViewTreeE2E.identifiers(
            withPrefix:
            "classification.editor.label-chip."
            + trace.chainID.description
        )?.sorted() ?? []
        let lifecycleIdentifier =
            "detail.lifecycle-summary."
            + traceID.description
        let lifecyclePresentation = AppViewTreeE2E.view(
            identifier: lifecycleIdentifier
        ).flatMap(AppViewTreeE2E.verificationText)
        return [
            "trace=\(traceID.description)",
            "chain=\(trace.chainID.description)",
            "expectedCategory=\(classification?.category?.name ?? "nil")",
            "actualCategory=\(categoryText ?? "missing")",
            "expectedLabels=\(expectedLabels)",
            "actualLabelIdentifiers=\(visibleLabelIdentifiers)",
            "lifecyclePresentation=\(lifecyclePresentation ?? "missing")"
        ].joined(separator: " ")
    }

    @MainActor
    private func taskCollectionRowIdentifiers(
        prefixes: [String]
    ) -> Set<String>? {
        var result = Set<String>()
        for prefix in prefixes {
            guard let identifiers = AppViewTreeE2E.identifiers(
                withPrefix: prefix
            ) else {
                return nil
            }
            result.formUnion(identifiers)
        }
        return result
    }

    @MainActor
    private func groupedRowCategoryIdentifiers(
        context: DemoCollectionCheckContext,
        verificationCase: DemoCollectionCheckCase
    ) -> Set<String> {
        guard verificationCase.organization == .grouped else {
            return []
        }
        var result: Set<String> = []
        if verificationCase.page == .day {
            result.formUnion(
                context.store.engine.getDayTodo(
                    date: context.fixture.anchorDate
                ).traces.compactMap { trace in
                    guard trace.status == .pending,
                          trace.pinOrder != nil,
                          context.store.displayableClassification(
                              for: trace
                          )?.category != nil
                    else {
                        return nil
                    }
                    return TaskClassificationAccessibilityNamespace(
                        surface: "day-row",
                        instanceID: trace.id.description
                    ).categoryIdentifier
                }
            )
        }
        return result
    }

    @MainActor
    private func completedHierarchyPresentationIsValid(
        context: DemoCollectionCheckContext,
        verificationCase: DemoCollectionCheckCase
    ) -> Bool {
        guard verificationCase.page == .completed else {
            return true
        }
        let ordinaryHierarchies =
            context.engine.completedTaskHierarchies().filter {
                $0.chain.cycleMembership == nil
            }
        guard let open = ordinaryHierarchies.first(where: {
            $0.parentCompletion == nil
                && $0.completedChildren.isEmpty == false
        }), let completed = ordinaryHierarchies.first(where: {
            $0.parentCompletion != nil
                && $0.completedChildren.isEmpty == false
        }), let openParent = AppViewTreeE2E.view(
            identifier:
            "completed.hierarchy.parent.\(open.chain.id.description)"
        ), let completedParent = AppViewTreeE2E.view(
            identifier:
            "completed.hierarchy.parent.\(completed.chain.id.description)"
        ), AppViewTreeE2E.verificationText(for: openParent) == "open",
            AppViewTreeE2E.verificationText(for: completedParent)
            == "completed"
        else {
            return false
        }
        let openChildrenAreChecked =
            open.completedChildren.allSatisfy { record in
                guard let view = AppViewTreeE2E.view(
                    identifier:
                    "completed.hierarchy.child.\(record.subtask.id.description)"
                ) else {
                    return false
                }
                return AppViewTreeE2E.verificationText(for: view)
                    == "checked"
            }
        let completedChildrenAreQuiet =
            completed.completedChildren.allSatisfy { record in
                guard let view = AppViewTreeE2E.view(
                    identifier:
                    "completed.hierarchy.child.\(record.subtask.id.description)"
                ) else {
                    return false
                }
                return AppViewTreeE2E.verificationText(for: view)
                    == "quiet"
            }
        let openTraceIDs = Set(
            context.engine.traces.values
                .filter { $0.chainID == open.chain.id }
                .map(\.id)
        )
        let hiddenChildrenStayHidden =
            context.engine.subtasks.values
                .filter {
                    openTraceIDs.contains($0.traceID)
                        && $0.isUserPresentable
                        && $0.status != .completed
                }
                .allSatisfy {
                    AppViewTreeE2E.hasNoVisibleView(
                        identifier:
                        "completed.hierarchy.child.\($0.id.description)"
                    )
                }
        return openChildrenAreChecked
            && completedChildrenAreQuiet
            && hiddenChildrenStayHidden
    }

    @MainActor
    private func captureTaskCollectionScreenshot(page: NoonmarkStore.Page) throws {
        guard let window = NSApp.windows.first(where: {
            $0 is NoonmarkWindow
                && $0.isVisible
                && $0.isMiniaturized == false
        })
        else {
            throw InteractiveDemoFixtureError
                .presentationContractFailed
        }
        do {
            try AppE2EScreenshot.captureContent(
                of: window,
                to: resultURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        "task-collection-\(page.rawValue).png"
                    )
            )
        } catch {
            throw InteractiveDemoFixtureError
                .presentationContractFailed
        }
    }

    private var categoryVerificationCases: [DemoCollectionCheckCase] {
        [
            DemoCollectionCheckCase(
                page: .pool,
                rowPrefixes: ["classification.pool-row."],
                organization: .grouped
            ),
            DemoCollectionCheckCase(
                page: .day,
                rowPrefixes: ["classification.day-row."],
                organization: .grouped
            ),
            DemoCollectionCheckCase(
                page: .future,
                rowPrefixes: ["classification.future-row."],
                organization: .flat
            ),
            DemoCollectionCheckCase(
                page: .recurring,
                rowPrefixes: [
                    "classification.task-cycle-row."
                ],
                organization: .flat
            ),
            DemoCollectionCheckCase(
                page: .unfinished,
                rowPrefixes: ["classification.unfinished-row."],
                organization: .flat
            ),
            DemoCollectionCheckCase(
                page: .completed,
                rowPrefixes: ["classification.completed-row."],
                organization: .grouped
            )
        ]
    }

    @MainActor
    private func taskPoolAnalysisReportContractIsValid(
        sessions: [ZhulongSession],
        store: NoonmarkStore
    ) -> Bool {
        guard let session = sessions.first(where: {
            $0.purpose == .taskPoolAnalysis
        }),
        let send = session.providerSends.last,
        send.status == .succeeded,
        send.payload.contextVersion
            == store.currentTaskPoolAnalysisContextVersion(),
        let response = send.response,
        (try? send.payload.responseContract.validate(response))
            != nil,
        case let .some(.taskPoolAnalysis(report)) =
            response.artifacts.first,
        report.findings.count
            <= MacUITaskPoolHomeRailLayout.maximumAnalysisFindingCount
        else {
            return false
        }
        return true
    }

    @MainActor
    private func finishWithFailure(
        _ error: Error,
        on store: NoonmarkStore
    ) {
        writeFailure(error)
        store.showOperationFailure(
            .persistence,
            error: error
        )
    }

    @MainActor
    private func install(
        engine: NoonmarkEngine,
        sessions: [ZhulongSession],
        fixture: NoonmarkDemoFixture,
        on store: NoonmarkStore
    ) throws {
        guard let databaseURL = store.databaseURL,
              AppLaunchArguments.value(after: "--data-url")
              == databaseURL.path,
              AppLaunchArguments.contains(
                  "--e2e-zhulong-sidecar-key"
              )
        else {
            throw InteractiveDemoFixtureError
                .unsafeLaunchConfiguration
        }

        guard let engineRepository = store.repository else {
            throw InteractiveDemoFixtureError
                .unsafeLaunchConfiguration
        }
        try engineRepository.save(engine)
        let sessionRepository =
            EncryptedFileZhulongSessionRepository(
                directoryURL: store.zhulongSidecarDirectoryURL,
                keySource: store.zhulongSidecarKeySource
            )
        for session in sessions {
            try sessionRepository.save(session)
        }

        store.engine = engine
        store.setZhulongPageEnabled(true)
        seedCollectionPresentationPreferences()
        store.zhulongWorkspace.reload()
        store.page = .day
        store.selectedDate = fixture.anchorDate
        store.selectedCalendarDate = fixture.anchorDate

        let persisted = try SQLiteEngineRepository(
            databaseURL: databaseURL
        ).load()
        guard persisted.snapshot() == engine.snapshot(),
              store.zhulongWorkspace.sessions.count
              == sessions.count,
              try sessions.allSatisfy({
                  try sessionRepository.load($0.id) == $0
              })
        else {
            throw InteractiveDemoFixtureError
                .persistenceVerificationFailed
        }
    }

    @MainActor
    private func seedCollectionPresentationPreferences() {
        let repository =
            TaskCollectionPresentationPreferenceRepository()
        repository.save(
            TaskCollectionPresentationPreference(
                organization: .grouped,
                sortKey: .time,
                direction: .ascending
            ),
            for: .dayTodo
        )
        repository.save(
            TaskCollectionPresentationPreference(
                organization: .grouped,
                sortKey: .time,
                direction: .ascending
            ),
            for: .taskPool
        )
        repository.save(
            TaskCollectionPresentationPreference(
                organization: .flat,
                sortKey: .time,
                direction: .descending
            ),
            for: .unfinished
        )
        repository.save(
            TaskCollectionPresentationPreference(
                organization: .grouped,
                sortKey: .time,
                direction: .descending
            ),
            for: .completed
        )
    }

    private func makeZhulongSessions(
        engine: inout NoonmarkEngine,
        today: LocalDate,
        providerIdentity: ZhulongProviderConfigurationIdentity
    ) throws -> [ZhulongSession] {
        let submitted = try makeSubmittedPlanningSession(
            engine: &engine,
            today: today,
            providerIdentity: providerIdentity
        )
        let insight = try makeInsightSession(
            today: today,
            providerIdentity: providerIdentity
        )
        let review = try makeDailyReviewSession(
            engine: &engine,
            today: today,
            providerIdentity: providerIdentity
        )
        let activeDraft = try makeActivePlanningSession(
            engine: engine,
            today: today,
            providerIdentity: providerIdentity
        )
        let poolAnalysis = try makeTaskPoolAnalysisSession(
            engine: engine,
            today: today,
            providerIdentity: providerIdentity
        )
        return [review, activeDraft, submitted, poolAnalysis, insight]
    }

    private func makeTaskPoolAnalysisSession(
        engine: NoonmarkEngine,
        today: LocalDate,
        providerIdentity: ZhulongProviderConfigurationIdentity
    ) throws -> ZhulongSession {
        let start = DemoFixtureClock.timestamp(
            today,
            hour: 16,
            minute: 30
        )
        let scope = AIScopeSnapshot.pools(
            from: engine,
            includeTaskPool: true,
            includeUnfinishedPool: false,
            includeCompletedPool: false,
            requestedAt: start
        )
        let requestContent = AIPromptBuilder().buildRequest(
            task: .taskPoolAnalysis,
            scope: scope,
            report: LocalInsightAnalyzer().analyze(scope)
        ).userPrompt
        guard let evidenceTask = scope.taskPool.first else {
            throw InteractiveDemoFixtureError.invalidZhulongFixture
        }
        let guardrail = PromptInjectionGuard()
        let evidenceTitle = guardrail.taskPoolEvidenceTitle(
            evidenceTask.definition.title
        )
        let evidenceReference = evidenceTitle ?? "该任务"
        let finding = try ZhulongTaskPoolAnalysisFinding(
            kind: .clarity,
            conclusion:
            "「\(evidenceReference)」的完成边界仍可更具体。",
            evidence: [
                try ZhulongTaskPoolAnalysisEvidence(
                    taskID: evidenceTask.chain.id.description,
                    title: evidenceTitle
                )
            ],
            confidence: .medium,
            uncertainty: "当前判断只依据任务池里已有的标题、说明、附言与计划子任务。",
            recommendation: "补充可观察的交付物或完成标准，再决定是否安排日期。"
        )
        let report = try ZhulongTaskPoolAnalysisReport(
            findings: [finding]
        )
        let authorisedEvidence = try scope.taskPool.map {
            try ZhulongTaskPoolAnalysisEvidence(
                taskID: $0.chain.id.description,
                title: guardrail.taskPoolEvidenceTitle(
                    $0.definition.title
                )
            )
        }
        var session = try ZhulongSession(
            primaryIntent: "分析当前任务池，找出需要澄清或安排的任务。",
            purpose: .taskPoolAnalysis,
            proposedScopes: [.taskPool],
            now: start
        )
        try session.authorizeScope(
            [.taskPool],
            providerIdentity: providerIdentity,
            now: start.addingTimeInterval(1)
        )
        let digest = SHA256.hash(data: Data(requestContent.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let providerRun = try session.beginProviderRun(
            payload: try ZhulongProviderPayload(
                systemPrompt: "这是晷迹交互式演示中的任务池分析。",
                userPrompt: session.primaryIntent,
                contextVersion: "sha256:\(digest)",
                scopeContent: [.taskPool: requestContent],
                responseContract: .taskPoolAnalysis(
                    evidence: authorisedEvidence
                )
            ),
            providerIdentity: providerIdentity,
            now: start.addingTimeInterval(2)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(
                content: "我找到一项值得先明确完成边界的任务。",
                artifacts: [.taskPoolAnalysis(report)]
            ),
            runID: providerRun.runID,
            now: start.addingTimeInterval(3)
        )
        return session
    }

    private func makeSubmittedPlanningSession(
        engine: inout NoonmarkEngine,
        today: LocalDate,
        providerIdentity: ZhulongProviderConfigurationIdentity
    ) throws -> ZhulongSession {
        let start = DemoFixtureClock.timestamp(
            today,
            hour: 13,
            minute: 0
        )
        let scopes: Set<ZhulongDataScope> = [
            .currentDayTodo,
            .taskPool
        ]
        var session = try ZhulongSession(
            primaryIntent: "帮我规划发布演示，并把结果安排进今天、任务池和未来计划。",
            purpose: .taskShaping,
            proposedScopes: scopes,
            now: start
        )
        try session.authorizeScope(
            scopes,
            providerIdentity: providerIdentity,
            now: start.addingTimeInterval(1)
        )
        let plan = try ZhulongConversationTaskPlan(
            tasks: [
                try ZhulongConversationTaskDraft(
                    title: "准备发布演示",
                    descriptionText: "按真实用户路径完成一次发布前演示。",
                    initialNoteBody: "先验证任务状态，再演示烛龙。",
                    destination: .today,
                    subtasks: [
                        try ZhulongPlannedSubtaskDraft(
                            title: "检查 Day Todo 状态",
                            difficulty: .simple
                        ),
                        try ZhulongPlannedSubtaskDraft(
                            title: "检查未来计划与回池",
                            difficulty: .medium
                        ),
                        try ZhulongPlannedSubtaskDraft(
                            title: "记录演示反馈",
                            difficulty: .hard
                        )
                    ]
                ),
                try ZhulongConversationTaskDraft(
                    title: "整理演示反馈问题",
                    descriptionText: "收集体验过程中发现的细节问题。",
                    initialNoteBody: nil,
                    destination: .taskPool,
                    subtasks: []
                ),
                try ZhulongConversationTaskDraft(
                    title: "安排发布后复盘会议",
                    descriptionText: "在演示完成两天后集中复盘。",
                    initialNoteBody: nil,
                    destination: .date(
                        DemoFixtureClock.offset(today, by: 2)
                    ),
                    subtasks: []
                )
            ]
        )
        let request = try session.beginProviderRun(
            payload: try providerPayload(
                scopes: scopes,
                prompt: "形成可编辑的发布演示任务计划。"
            ),
            providerIdentity: providerIdentity,
            now: start.addingTimeInterval(2)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(
                content: "我先整理成三个去向明确的任务，你可以继续编辑。",
                draftVersion: 1,
                artifacts: [.taskPlan(plan)]
            ),
            runID: request.runID,
            now: start.addingTimeInterval(3)
        )
        let original = try ZhulongTodoDiffDraft(
            sessionID: session.id,
            conversationRunID: request.runID,
            planningDate: today,
            sourceSnapshot: engine.snapshot(),
            createdAt: start.addingTimeInterval(4),
            items: plan.todoDiffItems(planningDate: today)
        )
        try session.publishConversationTodoDiff(
            original,
            now: start.addingTimeInterval(4)
        )
        var revisedItems = original.items
        guard case let .createTask(
            title,
            descriptionText,
            initialNoteBody,
            subtasks,
            targetDate
        ) = revisedItems[0].operation
        else {
            throw InteractiveDemoFixtureError
                .invalidZhulongFixture
        }
        revisedItems[0] = ZhulongTodoDiffItem(
            id: revisedItems[0].id,
            operation: .createTask(
                title: "\(title)（已确认范围）",
                descriptionText: descriptionText,
                initialNoteBody: initialNoteBody,
                plannedSubtasks: subtasks,
                targetDate: targetDate
            )
        )
        let revision = try ZhulongTodoDiffDraft(
            revising: original,
            createdAt: start.addingTimeInterval(5),
            items: revisedItems
        )
        try session.reviseTodoDiff(
            revision,
            now: start.addingTimeInterval(5)
        )
        _ = try session.authorizeTodoWrite(
            against: engine,
            today: today,
            now: start.addingTimeInterval(6)
        )
        _ = try session.applyAuthorizedTodoDiff(
            to: &engine,
            today: today,
            now: start.addingTimeInterval(7)
        )
        return session
    }

    private func makeActivePlanningSession(
        engine: NoonmarkEngine,
        today: LocalDate,
        providerIdentity: ZhulongProviderConfigurationIdentity
    ) throws -> ZhulongSession {
        let start = DemoFixtureClock.timestamp(
            today,
            hour: 17,
            minute: 0
        )
        let scopes: Set<ZhulongDataScope> = [
            .currentDayTodo,
            .taskPool
        ]
        var session = try ZhulongSession(
            primaryIntent: "我想深入学习 PostgreSQL 的索引，我们一起规划一下。",
            purpose: .taskShaping,
            proposedScopes: scopes,
            now: start
        )
        try session.authorizeScope(
            scopes,
            providerIdentity: providerIdentity,
            now: start.addingTimeInterval(1)
        )
        let plan = try ZhulongConversationTaskPlan(
            tasks: [
                try ZhulongConversationTaskDraft(
                    title: "理解 PostgreSQL 索引策略",
                    descriptionText: "从最左前缀、覆盖索引到 EXPLAIN/ANALYZE。",
                    initialNoteBody: "完成后用一个真实查询验证。",
                    destination: .taskPool,
                    subtasks: [
                        try ZhulongPlannedSubtaskDraft(
                            title: "理解复合索引的最左前缀原则",
                            difficulty: .medium
                        ),
                        try ZhulongPlannedSubtaskDraft(
                            title: "练习覆盖索引与 INCLUDE 列",
                            difficulty: .medium
                        ),
                        try ZhulongPlannedSubtaskDraft(
                            title: "验证 ORDER BY 与 NULLS 排序",
                            difficulty: .medium
                        ),
                        try ZhulongPlannedSubtaskDraft(
                            title: "检查联合查询与子查询的索引使用",
                            difficulty: .hard
                        ),
                        try ZhulongPlannedSubtaskDraft(
                            title: "用 EXPLAIN / ANALYZE 判断索引失效",
                            difficulty: .hard
                        )
                    ]
                )
            ]
        )
        let request = try session.beginProviderRun(
            payload: try providerPayload(
                scopes: scopes,
                prompt: "把 PostgreSQL 索引学习目标拆成可编辑任务。"
            ),
            providerIdentity: providerIdentity,
            now: start.addingTimeInterval(2)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(
                content: "我拆成一个主任务和五个循序渐进的子任务，提交前都可以修改。",
                draftVersion: 1,
                artifacts: [.taskPlan(plan)]
            ),
            runID: request.runID,
            now: start.addingTimeInterval(3)
        )
        let original = try ZhulongTodoDiffDraft(
            sessionID: session.id,
            conversationRunID: request.runID,
            planningDate: today,
            sourceSnapshot: engine.snapshot(),
            createdAt: start.addingTimeInterval(4),
            items: plan.todoDiffItems(planningDate: today)
        )
        try session.publishConversationTodoDiff(
            original,
            now: start.addingTimeInterval(4)
        )
        return session
    }

    private func makeInsightSession(
        today: LocalDate,
        providerIdentity: ZhulongProviderConfigurationIdentity
    ) throws -> ZhulongSession {
        let start = DemoFixtureClock.timestamp(
            DemoFixtureClock.offset(today, by: -2),
            hour: 18,
            minute: 0
        )
        let scopes: Set<ZhulongDataScope> = [
            .currentDayTodo,
            .unfinishedPool
        ]
        var session = try ZhulongSession(
            primaryIntent: "复盘一下最近任务经常延期的模式。",
            purpose: .habitInsight,
            proposedScopes: scopes,
            now: start
        )
        try session.authorizeScope(
            scopes,
            providerIdentity: providerIdentity,
            now: start.addingTimeInterval(1)
        )
        let request = try session.beginProviderRun(
            payload: try providerPayload(
                scopes: scopes,
                prompt: "根据轨迹总结延期模式，不创建任务。"
            ),
            providerIdentity: providerIdentity,
            now: start.addingTimeInterval(2)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(
                content: "最近的延期主要发生在依赖未确认和任务范围过大的场景。建议把等待依赖与可独立推进的部分分开。",
                draftVersion: 1
            ),
            runID: request.runID,
            now: start.addingTimeInterval(3)
        )
        return session
    }

    private func makeDailyReviewSession(
        engine: inout NoonmarkEngine,
        today: LocalDate,
        providerIdentity: ZhulongProviderConfigurationIdentity
    ) throws -> ZhulongSession {
        let start = DemoFixtureClock.timestamp(
            today,
            hour: 16,
            minute: 0
        )
        var session = try ZhulongSession(
            primaryIntent: "根据今天的真实任务轨迹做一次日终复盘。",
            purpose: .dailyClose,
            proposedScopes: [.currentDayTodo],
            now: start
        )
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: providerIdentity,
            now: start.addingTimeInterval(0.25)
        )
        _ = try session.appendEntry(
            author: .zhulong,
            kind: .statement,
            content: "今天已经完成演示准备；置顶任务、主动延期和进行中任务仍保留，明天先确认法务依赖。",
            now: start.addingTimeInterval(0.5)
        )
        let snapshot = try session.captureDailyClose(
            date: today,
            from: engine,
            now: start.addingTimeInterval(1)
        )
        let draft = try session.publishDailyReviewDraft(
            dailyCloseID: snapshot.id,
            summary: "今天完成了演示准备，并保留置顶、延期和进行中任务供继续体验。",
            tomorrowNote: "明天先确认法务依赖，再处理发布后的复盘安排。",
            causeResolutionIDs: [],
            now: start.addingTimeInterval(2)
        )
        _ = try session.authorizeDailyReview(
            draft.id,
            against: engine,
            now: start.addingTimeInterval(3)
        )
        _ = try session.applyAuthorizedDailyReview(
            draft.id,
            to: &engine,
            now: start.addingTimeInterval(4)
        )
        return session
    }

    private func providerPayload(
        scopes: Set<ZhulongDataScope>,
        prompt: String
    ) throws -> ZhulongProviderPayload {
        try ZhulongProviderPayload(
            systemPrompt: "这是晷迹交互式演示中的历史烛龙会话。",
            userPrompt: prompt,
            contextVersion: "interactive-demo-v1",
            scopeContent: Dictionary(
                uniqueKeysWithValues: scopes.map {
                    ($0, "演示范围 \($0.rawValue) 已授权")
                }
            )
        )
    }

    @MainActor
    private func manifest(
        fixture: NoonmarkDemoFixture,
        engine: NoonmarkEngine,
        sessions: [ZhulongSession],
        store: NoonmarkStore,
        presentationVerification:
        InteractiveDemoPresentationVerification
    ) throws -> InteractiveDemoManifest {
        let currentProviderIdentity = try store.zhulongProviderIdentity()
        let visibleScopeReauthorizationCardCount = sessions.filter {
            $0.requiresScopeAuthorization(
                for: currentProviderIdentity
            )
        }.count
        let submittedArtifacts = sessions.flatMap(
            \.conversationTodoArtifacts
        ).filter { $0.receipt != nil }.count
        let editableArtifacts = sessions.flatMap(
            \.conversationTodoArtifacts
        ).filter { $0.receipt == nil }.count
        let reviewReceipts = sessions.flatMap(
            \.dailyReviewReceipts
        ).count
        let groupedDayTodoSections = store.dayTodoPresentationSections(
            date: fixture.anchorDate,
            preference: TaskCollectionPresentationPreference(
                organization: .grouped,
                sortKey: .time,
                direction: .ascending
            )
        ).filter { $0.title != nil }
        let currentTracesByID = Dictionary(
            uniqueKeysWithValues: engine.getDayTodo(
                date: fixture.anchorDate
            ).traces.map { ($0.id.description, $0) }
        )
        let groupedTitles = groupedDayTodoSections.compactMap(\.title)
        let mixedStatusSectionCount = groupedDayTodoSections.count { section in
            let statuses = section.items.compactMap {
                currentTracesByID[$0.id]?.status
            }
            return statuses.contains(.pending)
                && statuses.contains { $0 != .pending }
        }
        let statusSinkingVerified = groupedDayTodoSections.allSatisfy { section in
            var encounteredSettledItem = false
            return section.items.allSatisfy { item in
                guard let status = currentTracesByID[item.id]?.status else {
                    return false
                }
                if status == .pending {
                    return encounteredSettledItem == false
                }
                encounteredSettledItem = true
                return true
            }
        }
        let dayTodoGroupingPresentationVerified =
            Set(groupedTitles).count == groupedTitles.count
                && mixedStatusSectionCount > 0
                && statusSinkingVerified
        let completedItems = engine.completedPool()
        let singleDayCompletedTaskCount = completedItems.count {
            $0.trajectory.traces.count == 1
        }
        let ordinarySingleDayCompletedTaskCount =
            singleDayCompletedTaskCount
        let cycleSingleDayCompletedTaskCount = completedItems.count {
            engine.chains[$0.trace.chainID]?.cycleMembership != nil
                && $0.trajectory.traces.count == 1
        }
        let multiDayCompletedTaskCount = completedItems.count {
            $0.trajectory.traces.count
                >= MacUICompletedPoolRowLayout.minimumVisibleTrajectoryNodeCount
        }
        let ordinaryCompletedHierarchies =
            engine.completedTaskHierarchies().filter {
                $0.chain.cycleMembership == nil
            }
        let hasOpenParentWithCompletedChildren =
            ordinaryCompletedHierarchies.contains {
                $0.parentCompletion == nil
                    && $0.completedChildren.isEmpty == false
            }
        let hasCompletedParentWithCompletedChildren =
            ordinaryCompletedHierarchies.contains {
                $0.parentCompletion != nil
                    && $0.completedChildren.isEmpty == false
            }
        let completedPoolRowHierarchyVerified =
            singleDayCompletedTaskCount > 0
                && completedItems.allSatisfy {
                    engine.chains[$0.trace.chainID]?
                        .cycleMembership == nil
                }
                && multiDayCompletedTaskCount > 0
                && hasOpenParentWithCompletedChildren
                && hasCompletedParentWithCompletedChildren
                && MacUICompletedPoolRowLayout
                .strongStatusRepresentationCount == 1
                && MacUICompletedPoolRowLayout
                .trajectoryUsesStrongStatusGlyphs == false
                && MacUICompletedPoolRowLayout
                .completionMomentIncludesDate
        guard var editableSession = sessions.first(where: {
            $0.currentTodoDiff != nil
                && $0.todoApplyReceipts.isEmpty
        }) else {
            throw InteractiveDemoFixtureError
                .incompleteZhulongCoverage
        }
        _ = try editableSession.authorizeTodoWrite(
            against: engine,
            today: fixture.anchorDate,
            now: DemoFixtureClock.timestamp(
                fixture.anchorDate,
                hour: 17,
                minute: 30
            )
        )
        guard visibleScopeReauthorizationCardCount == 0 else {
            throw InteractiveDemoFixtureError
                .unexpectedScopeReauthorization(
                    count: visibleScopeReauthorizationCardCount
                )
        }
        guard submittedArtifacts > 0,
              editableArtifacts > 0,
              reviewReceipts > 0,
              store.zhulongWorkspace.sessions.count == sessions.count,
              dayTodoGroupingPresentationVerified,
              completedPoolRowHierarchyVerified,
              presentationVerification
              .taskPoolStatisticsPresentationVerified,
              presentationVerification
              .taskPoolProviderBoundaryVerified,
              presentationVerification
              .taskPoolProviderReportPresentationVerified,
              presentationVerification
              .taskCollectionCategoryVisibilityVerified,
              presentationVerification
              .calendarRecurringBoundaryVerified,
              presentationVerification
              .taskCyclePresentationVerified,
              presentationVerification
              .zhulongHeaderComposerHierarchyVerified,
              engine.getDayTodo(date: fixture.anchorDate).traces
              .isEmpty == false
        else {
            throw InteractiveDemoFixtureError
                .incompleteZhulongCoverage
        }
        return InteractiveDemoManifest(
            status: "ready",
            anchorDate: fixture.anchorDate.description,
            generatedAt: DemoFixtureClock.timestamp(
                fixture.anchorDate,
                hour: 17,
                minute: 0
            ),
            core: fixture.report,
            zhulongSessionCount: sessions.count,
            submittedTodoArtifactCount: submittedArtifacts,
            editableTodoArtifactCount: editableArtifacts,
            dailyReviewReceiptCount: reviewReceipts,
            dayTodoMixedStatusSectionCount: mixedStatusSectionCount,
            dayTodoGroupingPresentationVerified:
            dayTodoGroupingPresentationVerified,
            singleDayCompletedTaskCount: singleDayCompletedTaskCount,
            ordinarySingleDayCompletedTaskCount:
            ordinarySingleDayCompletedTaskCount,
            cycleSingleDayCompletedTaskCount:
            cycleSingleDayCompletedTaskCount,
            multiDayCompletedTaskCount: multiDayCompletedTaskCount,
            completedPoolRowHierarchyVerified:
            completedPoolRowHierarchyVerified,
            visibleScopeReauthorizationCardCount:
            visibleScopeReauthorizationCardCount,
            scopeAuthorizationUIVerified:
            presentationVerification.scopeAuthorizationUIVerified,
            taskPoolStatisticsPresentationVerified:
            presentationVerification
                .taskPoolStatisticsPresentationVerified,
            taskPoolProviderBoundaryVerified:
            presentationVerification
                .taskPoolProviderBoundaryVerified,
            taskPoolProviderReportPresentationVerified:
            presentationVerification
                .taskPoolProviderReportPresentationVerified,
            taskCollectionCategoryVisibilityVerified:
            presentationVerification
                .taskCollectionCategoryVisibilityVerified,
            calendarRecurringBoundaryVerified:
            presentationVerification
                .calendarRecurringBoundaryVerified,
            taskCyclePresentationVerified:
            presentationVerification
                .taskCyclePresentationVerified,
            zhulongHeaderComposerHierarchyVerified:
            presentationVerification
                .zhulongHeaderComposerHierarchyVerified,
            persistedDatabasePath: store.databaseURL?.path ?? ""
        )
    }

    private func write(_ manifest: InteractiveDemoManifest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        let data = try encoder.encode(manifest)
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: resultURL, options: .atomic)
    }

    private func writeFailure(_ error: Error) {
        let failure = InteractiveDemoFailureManifest(
            status: "failed",
            error: String(describing: error)
        )
        guard let data = try? JSONEncoder().encode(failure) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: resultURL, options: .atomic)
    }
}

private struct InteractiveDemoPresentationVerification {
    let scopeAuthorizationUIVerified: Bool
    let taskPoolStatisticsPresentationVerified: Bool
    let taskPoolProviderBoundaryVerified: Bool
    let taskPoolProviderReportPresentationVerified: Bool
    let taskCollectionCategoryVisibilityVerified: Bool
    let calendarRecurringBoundaryVerified: Bool
    let taskCyclePresentationVerified: Bool
    let zhulongHeaderComposerHierarchyVerified: Bool

    func verifyingTaskCollectionCategoryVisibility() -> Self {
        Self(
            scopeAuthorizationUIVerified:
            scopeAuthorizationUIVerified,
            taskPoolStatisticsPresentationVerified:
            taskPoolStatisticsPresentationVerified,
            taskPoolProviderBoundaryVerified:
            taskPoolProviderBoundaryVerified,
            taskPoolProviderReportPresentationVerified:
            taskPoolProviderReportPresentationVerified,
            taskCollectionCategoryVisibilityVerified: true,
            calendarRecurringBoundaryVerified:
            calendarRecurringBoundaryVerified,
            taskCyclePresentationVerified:
            taskCyclePresentationVerified,
            zhulongHeaderComposerHierarchyVerified:
            zhulongHeaderComposerHierarchyVerified
        )
    }

    func verifyingCalendarRecurringBoundary() -> Self {
        Self(
            scopeAuthorizationUIVerified:
            scopeAuthorizationUIVerified,
            taskPoolStatisticsPresentationVerified:
            taskPoolStatisticsPresentationVerified,
            taskPoolProviderBoundaryVerified:
            taskPoolProviderBoundaryVerified,
            taskPoolProviderReportPresentationVerified:
            taskPoolProviderReportPresentationVerified,
            taskCollectionCategoryVisibilityVerified:
            taskCollectionCategoryVisibilityVerified,
            calendarRecurringBoundaryVerified: true,
            taskCyclePresentationVerified:
            taskCyclePresentationVerified,
            zhulongHeaderComposerHierarchyVerified:
            zhulongHeaderComposerHierarchyVerified
        )
    }

    func verifyingTaskCyclePresentation() -> Self {
        Self(
            scopeAuthorizationUIVerified:
            scopeAuthorizationUIVerified,
            taskPoolStatisticsPresentationVerified:
            taskPoolStatisticsPresentationVerified,
            taskPoolProviderBoundaryVerified:
            taskPoolProviderBoundaryVerified,
            taskPoolProviderReportPresentationVerified:
            taskPoolProviderReportPresentationVerified,
            taskCollectionCategoryVisibilityVerified:
            taskCollectionCategoryVisibilityVerified,
            calendarRecurringBoundaryVerified:
            calendarRecurringBoundaryVerified,
            taskCyclePresentationVerified: true,
            zhulongHeaderComposerHierarchyVerified:
            zhulongHeaderComposerHierarchyVerified
        )
    }
}

private struct DemoCollectionCheckContext {
    let fixture: NoonmarkDemoFixture
    let engine: NoonmarkEngine
    let sessions: [ZhulongSession]
    let store: NoonmarkStore
    let presentationVerification:
        InteractiveDemoPresentationVerification
    let cases: [DemoCollectionCheckCase]
}

private struct DemoCollectionCheckCase {
    let page: NoonmarkStore.Page
    let rowPrefixes: [String]
    let organization: TaskCollectionOrganization

    var sidebarNavigationIdentifier: String {
        "sidebar.nav.\(page.rawValue)"
    }
}

private struct DemoCycleCheckContext {
    let fixture: NoonmarkDemoFixture
    let engine: NoonmarkEngine
    let sessions: [ZhulongSession]
    let store: NoonmarkStore
    let presentationVerification:
        InteractiveDemoPresentationVerification
    let detailVerificationStage:
        DemoCycleDetailVerificationStage

    func advancing(
        to stage: DemoCycleDetailVerificationStage
    ) -> DemoCycleCheckContext {
        DemoCycleCheckContext(
            fixture: fixture,
            engine: engine,
            sessions: sessions,
            store: store,
            presentationVerification: presentationVerification,
            detailVerificationStage: stage
        )
    }
}

private struct DemoCyclePresentationExpectation {
    let title: String
    let lifecycleSummary: String
    let lifecycleIconVerification: String
    let expectsPlanEditing: Bool
    let expectsStop: Bool
}

private enum DemoCycleDetailVerificationStage {
    case ended
    case stopped
    case upcoming
    case active

    var trackTitle: String {
        switch self {
        case .ended:
            "完成首次晨间回顾"
        case .stopped:
            "暂停周报打磨"
        case .upcoming:
            "准备下周工作回顾"
        case .active:
            "每日产品复盘"
        }
    }

    var next: DemoCycleDetailVerificationStage? {
        switch self {
        case .ended:
            .stopped
        case .stopped:
            .upcoming
        case .upcoming:
            .active
        case .active:
            nil
        }
    }
}

private enum RecurringPlanDetailPreparation {
    case ready
    case retry
    case failed
}

private struct InteractiveDemoManifest: Codable {
    let status: String
    let anchorDate: String
    let generatedAt: Date
    let core: NoonmarkDemoCoverageReport
    let zhulongSessionCount: Int
    let submittedTodoArtifactCount: Int
    let editableTodoArtifactCount: Int
    let dailyReviewReceiptCount: Int
    let dayTodoMixedStatusSectionCount: Int
    let dayTodoGroupingPresentationVerified: Bool
    let singleDayCompletedTaskCount: Int
    let ordinarySingleDayCompletedTaskCount: Int
    let cycleSingleDayCompletedTaskCount: Int
    let multiDayCompletedTaskCount: Int
    let completedPoolRowHierarchyVerified: Bool
    let visibleScopeReauthorizationCardCount: Int
    let scopeAuthorizationUIVerified: Bool
    let taskPoolStatisticsPresentationVerified: Bool
    let taskPoolProviderBoundaryVerified: Bool
    let taskPoolProviderReportPresentationVerified: Bool
    let taskCollectionCategoryVisibilityVerified: Bool
    let calendarRecurringBoundaryVerified: Bool
    let taskCyclePresentationVerified: Bool
    let zhulongHeaderComposerHierarchyVerified: Bool
    let persistedDatabasePath: String
}

private struct InteractiveDemoFailureManifest: Codable {
    let status: String
    let error: String
}

private enum InteractiveDemoFixtureError: LocalizedError {
    case unsafeLaunchConfiguration
    case persistenceVerificationFailed
    case invalidZhulongFixture
    case incompleteZhulongCoverage
    case unexpectedScopeReauthorization(count: Int)
    case scopeAuthorizationPresentationFailed
    case presentationContractFailed
    case taskCycleDetailPresentationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsafeLaunchConfiguration:
            "演示 fixture 只能写入显式隔离数据根。"
        case .persistenceVerificationFailed:
            "演示 fixture 的 SQLite 或烛龙 sidecar 持久化对账失败。"
        case .invalidZhulongFixture:
            "演示 fixture 的烛龙任务产物不符合预期结构。"
        case .incompleteZhulongCoverage:
            "演示 fixture 未覆盖烛龙草稿、提交回执和日终复盘。"
        case let .unexpectedScopeReauthorization(count):
            "演示 fixture 出现 \(count) 张非预期的烛龙阅读范围确认卡。"
        case .scopeAuthorizationPresentationFailed:
            "演示 App 的烛龙历史会话仍然显示阅读范围确认卡。"
        case .presentationContractFailed:
            "演示 App 未满足任务池统计边界或烛龙头部／输入框层级契约。"
        case let .taskCycleDetailPresentationFailed(diagnostic):
            "重复任务实例详情未满足分类与生命周期摘要契约：\(diagnostic)"
        }
    }
}

private enum DemoFixtureClock {
    static func offset(
        _ date: LocalDate,
        by days: Int
    ) -> LocalDate {
        let start = timestamp(
            date,
            hour: 12,
            minute: 0
        )
        let calendar = calendar
        guard let shifted = calendar.date(
            byAdding: .day,
            value: days,
            to: start
        ) else {
            preconditionFailure("演示日期偏移必须有效")
        }
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: shifted
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            preconditionFailure("演示日期偏移必须有效")
        }
        return LocalDate(
            year: year,
            month: month,
            day: day
        )
    }

    static func timestamp(
        _ date: LocalDate,
        hour: Int,
        minute: Int
    ) -> Date {
        let calendar = calendar
        guard let timestamp = calendar.date(
            from: DateComponents(
                year: date.year,
                month: date.month,
                day: date.day,
                hour: hour,
                minute: minute
            )
        ) else {
            preconditionFailure("演示时间必须有效")
        }
        return timestamp
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(
            secondsFromGMT: -4 * 60 * 60
        ) ?? .current
        return calendar
    }
}
