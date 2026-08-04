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

        do {
            try captureTaskCollectionScreenshot(page: .zhulong)
        } catch {
            finishWithFailure(error, on: store)
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
                ideasPresentationVerified: false,
                flylightEditingInteractionVerified: false,
                flylightGlobalSuggestionVerified: false,
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
                    && categoryIdentifiers.map {
                        $0.isSubset(
                            of: expectedGroupedRowCategoryIdentifiers
                        )
                    } == true
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
            if remainingAttempts == 1 {
                let diagnostic = [
                    "page=\(verificationCase.page.rawValue)",
                    "sections=\(sectionIdentifiers ?? [])",
                    "categories=\(categoryIdentifiers ?? [])",
                    "expectedCategories=\(expectedGroupedRowCategoryIdentifiers)",
                    "labels=\(labelIdentifiers ?? [])",
                    "categoryPlacement=\(categoryPlacementIsValid)",
                    "completedHierarchy=\(completedHierarchyIsValid)",
                    "recurringProjection=\(recurringProjectionIsValid)"
                ].joined(separator: " ")
                AppViewTreeE2E.writeDump(beside: resultURL)
                finishWithFailure(
                    InteractiveDemoFixtureError
                        .taskCollectionPresentationFailed(
                            diagnostic
                        ),
                    on: context.store
                )
                return
            }
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
                identifier: "sidebar.nav.ideas"
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
            verifyIdeasPresentation(
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
        case .recurring, .calendar, .zhulong, .settings, .stickyNotes, .ideas:
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
        }.map {
            $0.id.description
        }.sorted()
        let visibleRecurringRowIDs =
            AppViewTreeE2E.identifiers(
                withPrefix: "day-row.task-cycle."
            )?.map {
                String($0.dropFirst("day-row.task-cycle.".count))
            } ?? []
        return recurringTraceIDs.isEmpty == false
            && AppViewTreeE2E.view(
                identifier: "day.recurring-projection"
            ).flatMap(AppViewTreeE2E.verificationText)
                == recurringTraceIDs.joined(separator: "\n")
            && Set(visibleRecurringRowIDs).isSubset(
                of: Set(recurringTraceIDs)
            )
    }

    @MainActor
    private func verifyIdeasPresentation(
        context: DemoCollectionCheckContext,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                    "飞光最近集合骨架未稳定"
                ),
                on: context.store
            )
            return
        }
        if context.store.isDetailRailExpanded == false {
            guard AppViewTreeE2E.click(
                identifier: "shell.detail-rail.toggle"
            ) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    verifyIdeasPresentation(
                        context: context,
                        remainingAttempts: remainingAttempts - 1
                    )
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                verifyIdeasPresentation(
                    context: context,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        let timelineGroups = context.store.ideaTimelineGroups
        let projectedIdeas = context.engine.ideaCollection(
            .recent,
            today: context.store.today
        ).ideas
        let stickyNotes = context.engine.pinnedIdeas()
        let expectedCardIdentifiers = Set(projectedIdeas.map {
            "ideas.card.\($0.id)"
        })
        let timelineGroupIdeaIDs = Set(timelineGroups.flatMap { group in
            group.ideas.map(\.id)
        })
        let tombstonedIdeaIDs = context.engine.ideas.values
            .filter { $0.isDeleted }
            .map(\.id)
        let topGroupIsFullyVisible = timelineGroups.first.map { group in
            AppViewTreeE2E.view(identifier: "ideas.day.\(group.date)")
                != nil
                && group.ideas.allSatisfy { idea in
                    AppViewTreeE2E.view(
                        identifier: "ideas.card.\(idea.id)"
                    )
                    .flatMap(AppViewTreeE2E.verificationText) == idea.body
                }
        } ?? false
        // Card sub-anchors (overflow menu, inline edit field, classification
        // filter buttons and actions) extend the card identifier with a
        // dotted suffix; the projection check only concerns the cards
        // themselves.
        let visibleCardIdentifiers = AppViewTreeE2E.identifiers(
            withPrefix: "ideas.card."
        ).map { identifiers in
            Set(identifiers.filter { identifier in
                identifier.dropFirst("ideas.card.".count)
                    .contains(".") == false
            })
        } ?? []
        let visibleCardsMatchProjection = visibleCardIdentifiers
            .isEmpty == false
            && visibleCardIdentifiers.isSubset(
                of: expectedCardIdentifiers
            )
            && visibleCardIdentifiers.allSatisfy { identifier in
                guard let idea = projectedIdeas.first(where: {
                    identifier == "ideas.card.\($0.id)"
                }) else {
                    return false
                }
                return AppViewTreeE2E.view(identifier: identifier)
                    .flatMap(AppViewTreeE2E.verificationText) == idea.body
            }
        let stickySourcesStayInFlylight = stickyNotes.count >= 3
            && AppViewTreeE2E.view(identifier: "ideas.pinned") == nil
            && stickyNotes.allSatisfy { idea in
                timelineGroupIdeaIDs.contains(idea.id)
                    && AppViewTreeE2E.view(
                        identifier: "ideas.card.\(idea.id)"
                    )
                    .flatMap(AppViewTreeE2E.verificationText) == idea.body
            }
        let tombstonesStayHidden = tombstonedIdeaIDs.allSatisfy {
            AppViewTreeE2E.hasNoVisibleView(
                identifier: "ideas.card.\($0)"
            )
        }
        let inspectorMatchesSelection = context.store.selectedIdea.map(
            { idea in
                AppViewTreeE2E.view(
                    identifier: "ideas.inspector.idea.\(idea.id)"
                ).flatMap(AppViewTreeE2E.verificationText) == idea.body
            }
        ) == true
        guard context.store.page == .ideas,
              timelineGroups.isEmpty == false,
              tombstonedIdeaIDs.isEmpty == false,
              AppViewTreeE2E.activateMainWindow(),
              AppViewTreeE2E.view(identifier: "ideas.page")
              .flatMap(AppViewTreeE2E.verificationText)
              == context.store.copy.navIdeas,
              AppViewTreeE2E.view(identifier: "ideas.composer") != nil,
              AppViewTreeE2E.view(
                  identifier: "ideas.composer.primary"
              ) != nil,
              AppViewTreeE2E.view(
                  identifier: "ideas.composer.secondary"
              ) != nil,
              AppViewTreeE2E.view(
                  identifier: "ideas.composer.tool.label"
              ) != nil,
              AppViewTreeE2E.view(
                  identifier: "ideas.composer.tool.category"
              ) != nil,
              AppViewTreeE2E.view(
                  identifier: "ideas.composer.tool.format"
              ) != nil,
              context.store.detailRailRoute == .flylight,
              AppViewTreeE2E.view(identifier: "shell.detail-rail") != nil,
              inspectorMatchesSelection,
              AppViewTreeE2E.view(identifier: "ideas.filter") == nil,
              AppViewTreeE2E.view(identifier: "ideas.timeline")
              .flatMap(AppViewTreeE2E.verificationText)
              == "\(projectedIdeas.count)",
              topGroupIsFullyVisible,
              visibleCardsMatchProjection,
              stickySourcesStayInFlylight,
              tombstonesStayHidden
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                verifyIdeasPresentation(
                    context: context,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        Task { @MainActor in
            do {
                try await verifyFlylightEditingAndSuggestions(
                    idea: timelineGroups[0].ideas[0],
                    context: context
                )
                let verifiedContext = DemoCollectionCheckContext(
                    fixture: context.fixture,
                    engine: context.engine,
                    sessions: context.sessions,
                    store: context.store,
                    presentationVerification:
                    context.presentationVerification
                        .verifyingFlylightInteractions(),
                    cases: context.cases
                )
                guard AppViewTreeE2E.click(
                    identifier: "ideas.search.toggle"
                ) else {
                    throw InteractiveDemoFixtureError
                        .taskCollectionPresentationFailed(
                            "飞光搜索动作无法点击"
                        )
                }
                verifyIdeasSearchPresentation(
                    context: verifiedContext,
                    expectedRecentCount: projectedIdeas.count,
                    remainingAttempts: 100
                )
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                finishWithFailure(error, on: context.store)
            }
        }
    }

    @MainActor
    private func verifyFlylightEditingAndSuggestions(
        idea: IdeaEntry,
        context: DemoCollectionCheckContext
    ) async throws {
        guard let mainWindow = NSApp.windows.first(where: {
            $0 is NoonmarkWindow && $0.isVisible && $0.isMiniaturized == false
        }) else {
            throw InteractiveDemoFixtureError.presentationContractFailed
        }
        let input = try WindowServerInputDriver(
            requestEventAccessIfNeeded: true
        )
        let original = idea

        guard let composerEditor = AppViewTreeE2E.view(
            identifier: "ideas.composer.input",
            in: mainWindow
        ) as? NSTextView else {
            throw InteractiveDemoFixtureError.presentationContractFailed
        }
        let collapsedDraft = "演示中暂时收起、稍后继续的飞光草稿 @工"
        try await demoClick(
            "ideas.composer.input",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光草稿收起验收没有取得焦点") {
            mainWindow.firstResponder === composerEditor
        }
        try input.typeUnicode(collapsedDraft)
        try await waitForFlylightDemo("飞光草稿收起验收文本没有进入编辑器") {
            composerEditor.string == collapsedDraft
                && context.store.ideaText == collapsedDraft
                && AppViewTreeE2E.view(
                    identifier: "ideas.composer.suggestions",
                    in: mainWindow
                ) != nil
        }
        try await demoClick(
            "ideas.composer.secondary",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光脏草稿没有在保留正文时收起") {
            mainWindow.contentView?.layoutSubtreeIfNeeded()
            guard let surface = AppViewTreeE2E.view(
                identifier: "ideas.composer.surface",
                in: mainWindow
            ) else { return false }
            return mainWindow.firstResponder !== composerEditor
                && (62 ... 72).contains(
                    AppViewTreeE2E.frameInWindow(for: surface).height
                )
                && composerEditor.string == collapsedDraft
                && context.store.ideaText == collapsedDraft
                && composerEditor.accessibilityLabel()
                == context.store.copy.ideaBodyAccessibilityLabel
                && composerEditor.accessibilityValue() == collapsedDraft
                && AppViewTreeE2E.view(
                    identifier: "ideas.composer.suggestions",
                    in: mainWindow
                ) == nil
        }
        try await demoClick(
            "ideas.composer.secondary",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光脏草稿收起后无法重新展开") {
            mainWindow.firstResponder === composerEditor
                && composerEditor.string == collapsedDraft
                && AppViewTreeE2E.view(
                    identifier: "ideas.composer.suggestions",
                    in: mainWindow
                ) != nil
        }
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.postKey(keyCode: 51)
        try await waitForFlylightDemo("飞光草稿收起验收文本没有清理") {
            composerEditor.string.isEmpty && context.store.ideaText.isEmpty
        }

        try await demoDoubleClick(
            "ideas.card.body.\(idea.id)",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光双击没有进入原位编辑") {
            context.store.editingIdeaID == idea.id
                && mainWindow.firstResponder is NSTextView
        }
        let originalEditableText = context.store.ideaEditText
        try captureTaskCollectionScreenshot(named: "ideas-inline-edit")
        try await demoClick(
            "ideas.card.edit.cancel.\(idea.id)",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光取消没有保留原事实") {
            context.store.editingIdeaID == nil
                && context.store.engine.ideas[idea.id]?.body == original.body
                && context.store.engine.ideas[idea.id]?.updatedAt
                == original.updatedAt
        }

        try await demoDoubleClick(
            "ideas.card.body.\(idea.id)",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光保存验收没有重新进入编辑") {
            context.store.editingIdeaID == idea.id
                && mainWindow.firstResponder is NSTextView
        }
        let editedBody = "演示验收\n\(originalEditableText)"
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.typeUnicode(editedBody)
        try await waitForFlylightDemo("飞光保存验收文本没有进入编辑器") {
            context.store.ideaEditText == editedBody
        }
        try await demoClick(
            "ideas.card.edit.save.\(idea.id)",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光保存中状态不可观察") {
            context.store.ideaInlineEditorSession.saveState == .saving
                && context.store.editingIdeaID == idea.id
        }
        try captureTaskCollectionScreenshot(named: "ideas-inline-saving")
        try await waitForFlylightDemo("飞光保存动作没有写入正文") {
            context.store.editingIdeaID == nil
                && context.store.engine.ideas[idea.id]?.body
                == "演示验收\n\(original.body)"
        }
        try await waitForFlylightCardBody(
            ideaID: idea.id,
            body: "演示验收\n\(original.body)",
            in: mainWindow
        )

        try await demoDoubleClick(
            "ideas.card.body.\(idea.id)",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光验收正文无法恢复") {
            context.store.editingIdeaID == idea.id
                && mainWindow.firstResponder is NSTextView
        }
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.typeUnicode(originalEditableText)
        try await demoClick(
            "ideas.card.edit.save.\(idea.id)",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光验收后没有恢复 fixture 正文") {
            guard context.store.editingIdeaID == nil,
                  let restored = context.store.engine.ideas[idea.id]
            else { return false }
            return restored.body == original.body
                && restored.categoryID == original.categoryID
                && restored.labelIDs == original.labelIDs
                && restored.pinnedAt == original.pinnedAt
        }
        try await waitForFlylightCardBody(
            ideaID: idea.id,
            body: original.body,
            in: mainWindow
        )

        let ideaCount = context.store.engine.ideaTimeline().count
        try input.postKey(keyCode: 34, modifiers: [.control, .shift])
        var panel: NSWindow?
        try await waitForFlylightDemo("全局飞光速记没有打开") {
            panel = NSApp.windows.first {
                $0.identifier
                    == NoonmarkIdeaCaptureWindowController.windowIdentifier
                    && $0.isVisible
            }
            return panel?.firstResponder is NSTextView
        }
        guard let panel, let panelEditor = panel.firstResponder as? NSTextView
        else {
            throw InteractiveDemoFixtureError.presentationContractFailed
        }
        try input.typeUnicode("@工")
        try await waitForFlylightDemo("全局飞光速记没有显示工程分组候选") {
            panelEditor.string == "@工"
                && AppViewTreeE2E.view(
                    identifier: "idea-capture.field.suggestions",
                    in: panel
                ).flatMap(AppViewTreeE2E.verificationText)?.contains("工程")
                == true
        }
        try captureDemoScreenshot(
            named: "idea-capture-suggestions",
            of: panel
        )
        try await demoClick(
            "idea-capture.field.suggestions",
            in: panel,
            input: input
        )
        try await waitForFlylightDemo("全局飞光分组候选没有完成 token") {
            panelEditor.string == "@工程 "
                && context.store.ideaText == "@工程 "
        }
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.postKey(keyCode: 51)
        try await waitForFlylightDemo("全局飞光候选验收草稿没有清空") {
            panelEditor.string.isEmpty && context.store.ideaText.isEmpty
        }
        try input.postKey(keyCode: 53)
        try await waitForFlylightDemo("全局飞光候选验收面板没有关闭") {
            panel.isVisible == false
                && context.store.engine.ideaTimeline().count == ideaCount
        }
        try await activateDemoWindow(mainWindow)

        guard let sourceIdea = context.store.stickyNoteIdeas.first else {
            throw InteractiveDemoFixtureError.presentationContractFailed
        }
        let sourceFilter = sourceIdea.body.components(
            separatedBy: .newlines
        ).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard sourceFilter.isEmpty == false else {
            throw InteractiveDemoFixtureError.presentationContractFailed
        }
        let sourceSelection = context.store.selectedIdeaID
        try await demoClick(
            "ideas.search.toggle",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光来源浏览验收没有展开搜索") {
            AppViewTreeE2E.view(
                identifier: "ideas.filter",
                in: mainWindow
            ) != nil
        }
        try await demoClick(
            "ideas.filter",
            in: mainWindow,
            input: input
        )
        try input.typeUnicode(sourceFilter)
        try await waitForFlylightDemo("飞光来源浏览验收没有建立稳定集合") {
            context.store.ideaFilterText == sourceFilter
                && context.store.displayedIdeaCollection.ideas.map(\.id)
                == [sourceIdea.id]
        }
        try await demoClick(
            "sidebar.nav.stickyNotes",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光来源浏览验收无法打开 Sticky Note") {
            context.store.page == .stickyNotes
                && AppViewTreeE2E.view(
                    identifier: "sticky-notes.item.\(sourceIdea.id)",
                    in: mainWindow
                ) != nil
        }
        try await demoDoubleClick(
            "sticky-notes.item.\(sourceIdea.id)",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("Sticky Note 来源没有定位到飞光") {
            context.store.page == .ideas
                && context.store.selectedIdeaID == sourceIdea.id
                && context.store.ideaFilterText.isEmpty
                && context.store.canRestoreIdeaBrowseLocation
                && AppViewTreeE2E.view(
                    identifier: "ideas.browse.restore",
                    in: mainWindow
                ) != nil
        }
        try await demoClick(
            "ideas.browse.restore",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("Sticky Note 来源没有恢复此前浏览位置") {
            context.store.ideaFilterText == sourceFilter
                && context.store.selectedIdeaID == sourceSelection
                && context.store.canRestoreIdeaBrowseLocation == false
                && AppViewTreeE2E.view(
                    identifier: "ideas.filter",
                    in: mainWindow
                ) != nil
        }
        try await demoClick(
            "ideas.search.toggle",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光来源浏览验收没有恢复最近集合") {
            context.store.ideaFilterText.isEmpty
                && AppViewTreeE2E.view(
                    identifier: "ideas.filter",
                    in: mainWindow
                ) == nil
        }
        try await demoClick(
            "ideas.review.toggle",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光来源浏览验收没有进入回看") {
            context.store.ideaBrowseMode == .review
        }
        let priorReviewSeed = context.store.ideaReviewSeed
        try await demoClick(
            "ideas.review.refresh",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("飞光来源浏览验收没有刷新回看") {
            context.store.ideaReviewSeed == priorReviewSeed &+ 1
        }
        let sourceReviewSeed = context.store.ideaReviewSeed
        try await demoClick(
            "sidebar.nav.stickyNotes",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("回看来源验收无法打开 Sticky Note") {
            context.store.page == .stickyNotes
                && AppViewTreeE2E.view(
                    identifier: "sticky-notes.item.\(sourceIdea.id)",
                    in: mainWindow
                ) != nil
        }
        try await demoDoubleClick(
            "sticky-notes.item.\(sourceIdea.id)",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("回看来源没有定位到飞光") {
            context.store.page == .ideas
                && context.store.ideaBrowseMode == .recent
                && context.store.canRestoreIdeaBrowseLocation
        }
        try await demoClick(
            "ideas.browse.restore",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("回看来源没有恢复模式与随机种子") {
            context.store.ideaBrowseMode == .review
                && context.store.ideaReviewSeed == sourceReviewSeed
                && context.store.canRestoreIdeaBrowseLocation == false
        }
        try await demoClick(
            "ideas.review.toggle",
            in: mainWindow,
            input: input
        )
        try await waitForFlylightDemo("回看来源验收没有返回最近集合") {
            context.store.ideaBrowseMode == .recent
        }
    }

    @MainActor
    private func captureDemoScreenshot(
        named name: String,
        of window: NSWindow
    ) throws {
        try AppE2EScreenshot.captureContent(
            of: window,
            to: resultURL.deletingLastPathComponent()
                .appendingPathComponent("\(name).png")
        )
    }

    @MainActor
    private func waitForFlylightDemo(
        _ failure: String,
        condition: () -> Bool
    ) async throws {
        for _ in 0 ..< 120 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw InteractiveDemoFixtureError
            .taskCollectionPresentationFailed(failure)
    }

    @MainActor
    private func waitForFlylightCardBody(
        ideaID: IdeaID,
        body: String,
        in window: NSWindow
    ) async throws {
        try await waitForFlylightDemo("飞光保存后正文没有重新挂载") {
            guard let cardBody = AppViewTreeE2E.view(
                identifier: "ideas.card.body.\(ideaID)",
                in: window
            ) else {
                return false
            }
            return cardBody.isHiddenOrHasHiddenAncestor == false
                && cardBody.visibleRect.isEmpty == false
                && AppViewTreeE2E.verificationText(for: cardBody) == body
        }
    }

    @MainActor
    private func activateDemoWindow(_ window: NSWindow) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await waitForFlylightDemo("飞光验收窗口无法成为输入目标") {
            NSApp.isActive && window.isKeyWindow
        }
    }

    @MainActor
    private func demoClick(
        _ identifier: String,
        in window: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let resolveTarget = try demoTargetResolver(
            identifier: identifier,
            in: window,
            input: input
        )
        try await activateDemoWindow(window)
        try await input.postClick(
            at: try resolveTarget(),
            modifiers: [],
            resolveTarget: resolveTarget
        )
    }

    @MainActor
    private func demoDoubleClick(
        _ identifier: String,
        in window: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let resolveTarget = try demoTargetResolver(
            identifier: identifier,
            in: window,
            input: input
        )
        try await activateDemoWindow(window)
        try await input.postDoubleClick(
            at: try resolveTarget(),
            modifiers: [],
            resolveTarget: resolveTarget
        )
    }

    @MainActor
    private func demoTargetResolver(
        identifier: String,
        in window: NSWindow,
        input: WindowServerInputDriver
    ) throws -> @MainActor @Sendable () throws
        -> WindowServerInputDriver.PointerCoordinate
    {
        {
            guard let anchor = AppViewTreeE2E.view(
                identifier: identifier,
                in: window
            ) else {
                throw InteractiveDemoFixtureError
                    .taskCollectionPresentationFailed(
                        "飞光验收目标不存在：\(identifier)"
                    )
            }
            if let buttonTarget = AppViewTreeE2E.buttonInteractionTarget(
                overlapping: anchor
            ) {
                return try input.pointerCoordinate(
                    windowPoint: buttonTarget.windowPoint,
                    in: window
                )
            }
            let frame = AppViewTreeE2E.frameInWindow(for: anchor)
            let visibleFrame = anchor.convert(anchor.visibleRect, to: nil)
            let clickableFrame = frame.intersection(visibleFrame)
            guard clickableFrame.isNull == false,
                  clickableFrame.isEmpty == false
            else {
                throw InteractiveDemoFixtureError
                    .taskCollectionPresentationFailed(
                        "飞光验收目标不可见：\(identifier)"
                    )
            }
            return try input.pointerCoordinate(
                windowPoint: NSPoint(
                    x: clickableFrame.midX,
                    y: clickableFrame.midY
                ),
                in: window
            )
        }
    }

    @MainActor
    private func verifyIdeasSearchPresentation(
        context: DemoCollectionCheckContext,
        expectedRecentCount: Int,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                    "飞光搜索输入面未展开"
                ),
                on: context.store
            )
            return
        }
        guard AppViewTreeE2E.view(identifier: "ideas.filter")
            .flatMap(AppViewTreeE2E.verificationText) == "",
            AppViewTreeE2E.view(identifier: "ideas.collection")
            .flatMap(AppViewTreeE2E.verificationText) == "recent"
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                verifyIdeasSearchPresentation(
                    context: context,
                    expectedRecentCount: expectedRecentCount,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        guard AppViewTreeE2E.click(identifier: "ideas.search.toggle") else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                    "飞光搜索收起动作无法点击"
                ),
                on: context.store
            )
            return
        }
        verifyIdeasSearchDismissed(
            context: context,
            expectedRecentCount: expectedRecentCount,
            remainingAttempts: 100
        )
    }

    @MainActor
    private func verifyIdeasSearchDismissed(
        context: DemoCollectionCheckContext,
        expectedRecentCount: Int,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                    "飞光搜索输入面未收起"
                ),
                on: context.store
            )
            return
        }
        guard AppViewTreeE2E.view(identifier: "ideas.filter") == nil,
              context.store.ideaBrowseMode == .recent
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                verifyIdeasSearchDismissed(
                    context: context,
                    expectedRecentCount: expectedRecentCount,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        guard AppViewTreeE2E.click(identifier: "ideas.review.toggle") else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                    "飞光回看动作无法点击"
                ),
                on: context.store
            )
            return
        }
        verifyIdeasReviewPresentation(
            context: context,
            expectedRecentCount: expectedRecentCount,
            remainingAttempts: 100
        )
    }

    @MainActor
    private func verifyIdeasReviewPresentation(
        context: DemoCollectionCheckContext,
        expectedRecentCount: Int,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                    "飞光回看集合未与领域投影对齐"
                ),
                on: context.store
            )
            return
        }
        let reviewIdeas = context.engine.ideaCollection(
            .review(
                seed: context.store.ideaReviewSeed,
                count: 5,
                excludingRecentDays: 7
            ),
            today: context.store.today
        ).ideas
        let reviewCardsAreVisible = reviewIdeas.allSatisfy { idea in
            AppViewTreeE2E.view(identifier: "ideas.card.\(idea.id)")
                .flatMap(AppViewTreeE2E.verificationText) == idea.body
        }
        let inspectorMatchesSelection = context.store.selectedIdea.map(
            { idea in
                AppViewTreeE2E.view(
                    identifier: "ideas.inspector.idea.\(idea.id)"
                ).flatMap(AppViewTreeE2E.verificationText) == idea.body
            }
        ) == true
        guard reviewIdeas.isEmpty == false,
              context.store.ideaBrowseMode == .review,
              AppViewTreeE2E.view(identifier: "ideas.collection")
              .flatMap(AppViewTreeE2E.verificationText) == "review",
              AppViewTreeE2E.view(identifier: "ideas.timeline")
              .flatMap(AppViewTreeE2E.verificationText)
              == "\(reviewIdeas.count)",
              reviewCardsAreVisible,
              inspectorMatchesSelection
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                verifyIdeasReviewPresentation(
                    context: context,
                    expectedRecentCount: expectedRecentCount,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        guard AppViewTreeE2E.click(identifier: "ideas.review.toggle") else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                    "飞光无法从回看返回最近集合"
                ),
                on: context.store
            )
            return
        }
        verifyIdeasRecentRestored(
            context: context,
            expectedRecentCount: expectedRecentCount,
            remainingAttempts: 100
        )
    }

    @MainActor
    private func verifyIdeasRecentRestored(
        context: DemoCollectionCheckContext,
        expectedRecentCount: Int,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                    "飞光最近集合没有在回看后恢复"
                ),
                on: context.store
            )
            return
        }
        guard context.store.ideaBrowseMode == .recent,
              AppViewTreeE2E.view(identifier: "ideas.collection")
              .flatMap(AppViewTreeE2E.verificationText) == "recent",
              AppViewTreeE2E.view(identifier: "ideas.timeline")
              .flatMap(AppViewTreeE2E.verificationText)
              == "\(expectedRecentCount)",
              AppViewTreeE2E.view(identifier: "ideas.filter") == nil
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                verifyIdeasRecentRestored(
                    context: context,
                    expectedRecentCount: expectedRecentCount,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        do {
            try captureTaskCollectionScreenshot(page: .ideas)
        } catch {
            finishWithFailure(error, on: context.store)
            return
        }
        let tombstones = context.engine.ideaTrash()
        guard tombstones.isEmpty == false,
              AppViewTreeE2E.view(identifier: "sidebar.nav.memoTrash") == nil,
              AppViewTreeE2E.view(identifier: "ideas.trash") == nil,
              (AppViewTreeE2E.identifiers(
                  withPrefix: "ideas.trash.item."
              ) ?? []).isEmpty
        else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                    "飞光墓碑不应暴露回收站或恢复 UI"
                ),
                on: context.store
            )
            return
        }
        let stickyNotesContext = DemoCollectionCheckContext(
            fixture: context.fixture,
            engine: context.engine,
            sessions: context.sessions,
            store: context.store,
            presentationVerification:
            context.presentationVerification
                .verifyingIdeasPresentation(),
            cases: context.cases
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard AppViewTreeE2E.click(
                identifier: "sidebar.nav.stickyNotes"
            )
            else {
                AppViewTreeE2E.writeDump(beside: resultURL)
                finishWithFailure(
                    InteractiveDemoFixtureError
                        .taskCollectionPresentationFailed(
                            "飞光验收后无法切换到 Sticky Note"
                        ),
                    on: context.store
                )
                return
            }
            verifyStickyNotesStreamPresentation(
                context: stickyNotesContext,
                remainingAttempts: 100
            )
        }
    }

    @MainActor
    private func verifyStickyNotesStreamPresentation(
        context: DemoCollectionCheckContext,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                    "Sticky Note 清单流未与飞光投影对齐"
                ),
                on: context.store
            )
            return
        }
        let stickyNotes = context.engine.pinnedIdeas()
        guard context.store.page == .stickyNotes,
              AppViewTreeE2E.view(identifier: "sticky-notes.page")
              .flatMap(AppViewTreeE2E.verificationText)
              == "\(stickyNotes.count)"
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                verifyStickyNotesStreamPresentation(
                    context: context,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        if AppViewTreeE2E.view(identifier: "sticky-notes.presentation")
            .flatMap(AppViewTreeE2E.verificationText) != "stream"
        {
            guard AppViewTreeE2E.selectMenuItem(
                identifier: "sticky-notes.mode",
                downArrowCount: 1
            ) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    verifyStickyNotesStreamPresentation(
                        context: context,
                        remainingAttempts: remainingAttempts - 1
                    )
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                verifyStickyNotesStreamPresentation(
                    context: context,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        guard stickyNotes.count >= 3,
              stickyNotes.allSatisfy({ idea in
                  AppViewTreeE2E.view(
                      identifier: "sticky-notes.item.\(idea.id)"
                  ).flatMap(AppViewTreeE2E.verificationText) == idea.body
              }),
              AppViewTreeE2E.view(identifier: "sticky-notes.empty") == nil
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                verifyStickyNotesStreamPresentation(
                    context: context,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        do {
            try captureTaskCollectionScreenshot(named: "stickyNotes-stream")
        } catch {
            finishWithFailure(error, on: context.store)
            return
        }
        guard AppViewTreeE2E.selectMenuItem(
            identifier: "sticky-notes.mode",
            downArrowCount: 2
        ) else {
            finishWithFailure(
                InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                    "Sticky Note 清单流验收后无法切换到便签墙"
                ),
                on: context.store
            )
            return
        }
        verifyStickyNotesWallPresentation(
            context: context,
            remainingAttempts: 100
        )
    }

    @MainActor
    private func verifyStickyNotesWallPresentation(
        context: DemoCollectionCheckContext,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                    "Sticky Note 便签墙未与飞光投影对齐"
                ),
                on: context.store
            )
            return
        }
        let stickyNotes = context.engine.pinnedIdeas()
        guard context.store.page == .stickyNotes,
              AppViewTreeE2E.view(identifier: "sticky-notes.presentation")
              .flatMap(AppViewTreeE2E.verificationText) == "wall",
              stickyNotes.allSatisfy({ idea in
                  AppViewTreeE2E.view(
                      identifier: "sticky-notes.item.\(idea.id)"
                  ).flatMap(AppViewTreeE2E.verificationText) == idea.body
              })
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                verifyStickyNotesWallPresentation(
                    context: context,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        do {
            try captureTaskCollectionScreenshot(named: "stickyNotes-wall")
            try captureTaskCollectionScreenshot(page: .stickyNotes)
        } catch {
            finishWithFailure(error, on: context.store)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard AppViewTreeE2E.click(identifier: "sidebar.nav.calendar") else {
                AppViewTreeE2E.writeDump(beside: resultURL)
                finishWithFailure(
                    InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                        "Sticky Note 验收后无法切换到日历"
                    ),
                    on: context.store
                )
                return
            }
            retryCalendarRecurringBoundary(
                context: context,
                remainingAttempts: 100
            )
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
                InteractiveDemoFixtureError.taskCollectionPresentationFailed(
                    "Sticky Note 验收后日历页面没有呈现"
                ),
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
        ).filter { track, _ in
            expectedTrackRootIdentifiers.contains(
                "task-cycle-track.recurring.\(track.id.description)"
            ) && (trackIdentifiers ?? []).contains(
                "task-cycle-track.recurring.\(track.id.description)"
            )
        }.allSatisfy { track, expectation in
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
              actualTrackRootIdentifiers.isEmpty == false,
              actualTrackRootIdentifiers.isSubset(
                  of: expectedTrackRootIdentifiers
              ),
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
            context.store.userSelectTaskCycleSeries(track.id)
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
        context.engine.taskCycleTracks(
            today: context.fixture.anchorDate
        ).map { track in
            let iconVerification: String
            let isEditable: Bool
            switch track.lifecycle {
            case .active:
                iconVerification =
                    MacUIRecurringLifecycleStyles.active.verificationText
                isEditable = true
            case .upcoming:
                iconVerification =
                    MacUIRecurringLifecycleStyles.upcoming.verificationText
                isEditable = true
            case .ended:
                iconVerification =
                    MacUIRecurringLifecycleStyles.ended.verificationText
                isEditable = false
            case .stopped:
                iconVerification =
                    MacUIRecurringLifecycleStyles.stopped.verificationText
                isEditable = false
            }
            return DemoCyclePresentationExpectation(
                title: track.title,
                lifecycleSummary:
                context.store.copy.taskCycleLifecycleSummary(
                    track,
                    displayDate: context.store.displayDate
                ),
                lifecycleIconVerification: iconVerification,
                expectsPlanEditing: isEditable,
                expectsStop: isEditable
            )
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
        startDocumentationSurfaceCapture(context: context)
    }

    @MainActor
    private func startDocumentationSurfaceCapture(
        context: DemoCycleCheckContext
    ) {
        guard AppViewTreeE2E.activateMainWindow(),
              NSApp.sendAction(
                  NoonmarkMenuAction.showQuickEntry,
                  to: nil,
                  from: nil
              )
        else {
            finishWithFailure(
                InteractiveDemoFixtureError.documentationCaptureFailed(
                    "无法打开快速记录窗口"
                ),
                on: context.store
            )
            return
        }
        verifyQuickEntryForDocumentation(
            context: context,
            deadline: Date().addingTimeInterval(30)
        )
    }

    @MainActor
    private func verifyQuickEntryForDocumentation(
        context: DemoCycleCheckContext,
        deadline: Date
    ) {
        guard Date() < deadline else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.documentationCaptureFailed(
                    "快速记录窗口没有进入可截图状态"
                ),
                on: context.store
            )
            return
        }
        guard let panel = NSApp.windows.first(where: {
            $0.identifier
                == NoonmarkQuickEntryWindowController.windowIdentifier
                && $0.isVisible
                && $0.isMiniaturized == false
        }),
        panel.isKeyWindow,
        AppViewTreeE2E.view(
            identifier: "quick-entry.window",
            in: panel
        ) != nil,
        AppViewTreeE2E.view(
            identifier: "quick-entry.field",
            in: panel
        ) != nil
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                verifyQuickEntryForDocumentation(
                    context: context,
                    deadline: deadline
                )
            }
            return
        }
        do {
            try captureDocumentationScreenshot(
                of: panel,
                named: "quick-entry.png"
            )
        } catch {
            finishWithFailure(error, on: context.store)
            return
        }
        panel.performClose(nil)
        waitForQuickEntryToClose(
            context: context,
            deadline: deadline
        )
    }

    @MainActor
    private func waitForQuickEntryToClose(
        context: DemoCycleCheckContext,
        deadline: Date
    ) {
        guard Date() < deadline else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.documentationCaptureFailed(
                    "快速记录窗口无法关闭"
                ),
                on: context.store
            )
            return
        }
        let quickEntryIsVisible = NSApp.windows.contains {
            $0.identifier
                == NoonmarkQuickEntryWindowController.windowIdentifier
                && $0.isVisible
        }
        guard quickEntryIsVisible == false else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                waitForQuickEntryToClose(
                    context: context,
                    deadline: deadline
                )
            }
            return
        }
        guard AppViewTreeE2E.activateMainWindow(),
              NSApp.sendAction(
                  NoonmarkMenuAction.showSettings,
                  to: nil,
                  from: nil
              )
        else {
            finishWithFailure(
                InteractiveDemoFixtureError.documentationCaptureFailed(
                    "无法打开设置窗口"
                ),
                on: context.store
            )
            return
        }
        captureSettingsPaneForDocumentation(
            context: context,
            paneIndex: 0,
            deadline: deadline
        )
    }

    @MainActor
    private func captureSettingsPaneForDocumentation(
        context: DemoCycleCheckContext,
        paneIndex: Int,
        deadline: Date
    ) {
        let panes: [SettingsPane] = [
            .general,
            .groups,
            .data,
            .privacy,
        ]
        guard panes.indices.contains(paneIndex) else {
            finishWithFailure(
                InteractiveDemoFixtureError.documentationCaptureFailed(
                    "设置面板索引无效"
                ),
                on: context.store
            )
            return
        }
        let pane = panes[paneIndex]
        guard Date() < deadline else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.documentationCaptureFailed(
                    "设置面板 \(pane.rawValue) 没有进入可截图状态"
                ),
                on: context.store
            )
            return
        }
        guard let settingsWindow = NSApp.windows.first(where: {
            $0.identifier
                == NoonmarkSettingsWindowController.windowIdentifier
                && $0.isVisible
                && $0.isMiniaturized == false
        }),
        settingsWindow.isKeyWindow,
        let contentAnchor = AppViewTreeE2E.view(
            identifier: "settings.content.\(pane.rawValue)",
            in: settingsWindow
        ),
        AppViewTreeE2E.verificationText(for: contentAnchor)
            == pane.title(copy: context.store.copy)
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                captureSettingsPaneForDocumentation(
                    context: context,
                    paneIndex: paneIndex,
                    deadline: deadline
                )
            }
            return
        }
        do {
            try captureDocumentationScreenshot(
                of: settingsWindow,
                named: "settings-\(pane.rawValue).png"
            )
        } catch {
            finishWithFailure(error, on: context.store)
            return
        }

        let nextIndex = paneIndex + 1
        guard panes.indices.contains(nextIndex) else {
            settingsWindow.performClose(nil)
            finalizeDocumentationSurfaceCapture(
                context: context,
                deadline: deadline
            )
            return
        }
        let nextPane = panes[nextIndex]
        guard let nextPaneAnchor = AppViewTreeE2E.view(
            identifier: "settings.sidebar.\(nextPane.rawValue)",
            in: settingsWindow
        ), AppViewTreeE2E.click(nextPaneAnchor)
        else {
            finishWithFailure(
                InteractiveDemoFixtureError.documentationCaptureFailed(
                    "无法切换到设置面板 \(nextPane.rawValue)"
                ),
                on: context.store
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            captureSettingsPaneForDocumentation(
                context: context,
                paneIndex: nextIndex,
                deadline: deadline
            )
        }
    }

    @MainActor
    private func finalizeDocumentationSurfaceCapture(
        context: DemoCycleCheckContext,
        deadline: Date
    ) {
        guard Date() < deadline else {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finishWithFailure(
                InteractiveDemoFixtureError.documentationCaptureFailed(
                    "设置窗口关闭后主窗口没有恢复"
                ),
                on: context.store
            )
            return
        }
        let settingsIsVisible = NSApp.windows.contains {
            $0.identifier
                == NoonmarkSettingsWindowController.windowIdentifier
                && $0.isVisible
        }
        guard settingsIsVisible == false,
              AppViewTreeE2E.activateMainWindow(),
              context.store.page == .day
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                finalizeDocumentationSurfaceCapture(
                    context: context,
                    deadline: deadline
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
        let openHierarchies = ordinaryHierarchies.filter {
            $0.parentCompletion == nil
                && $0.completedChildren.isEmpty == false
        }
        let completedHierarchies = ordinaryHierarchies.filter {
            $0.parentCompletion != nil
                && $0.completedChildren.isEmpty == false
        }
        let expectedProjection = ordinaryHierarchies.map { hierarchy in
            let parentState =
                hierarchy.parentCompletion == nil
                    ? "open"
                    : "completed"
            let childState =
                hierarchy.parentCompletion == nil
                    ? "checked"
                    : "quiet"
            let children = hierarchy.completedChildren.map {
                "\($0.subtask.id.description):\(childState)"
            }.sorted().joined(separator: ",")
            return [
                hierarchy.chain.id.description,
                parentState,
                "expanded",
                children
            ].joined(separator: "|")
        }.sorted().joined(separator: "\n")
        guard openHierarchies.isEmpty == false,
              completedHierarchies.isEmpty == false,
              AppViewTreeE2E.view(
                  identifier: "completed.hierarchy-projection"
              ).flatMap(AppViewTreeE2E.verificationText)
              == expectedProjection,
              let hierarchyIdentifiers = AppViewTreeE2E.identifiers(
                  withPrefix: "completed.hierarchy."
              )
        else {
            return false
        }
        let hierarchyByID = Dictionary(
            uniqueKeysWithValues: ordinaryHierarchies.map {
                ($0.chain.id.description, $0)
            }
        )
        let visibleRootIDs = hierarchyIdentifiers.compactMap {
            identifier -> String? in
            let prefix = "completed.hierarchy."
            let suffix = String(identifier.dropFirst(prefix.count))
            return UUID(uuidString: suffix) == nil ? nil : suffix
        }
        guard visibleRootIDs.isEmpty == false,
              visibleRootIDs.allSatisfy({ chainID in
                  guard let hierarchy = hierarchyByID[chainID],
                        let view = AppViewTreeE2E.view(
                            identifier: "completed.hierarchy.\(chainID)"
                        )
                  else {
                      return false
                  }
                  let parentState =
                      hierarchy.parentCompletion == nil
                          ? "open"
                          : "completed"
                  return AppViewTreeE2E.verificationText(for: view)
                      == [
                          parentState,
                          "\(hierarchy.completedChildren.count)",
                          "expanded"
                      ].joined(separator: ",")
              })
        else {
            return false
        }
        let completedChildStates = ordinaryHierarchies.reduce(
            into: [String: String]()
        ) { result, hierarchy in
            let state =
                hierarchy.parentCompletion == nil
                    ? "checked"
                    : "quiet"
            for record in hierarchy.completedChildren {
                result[record.subtask.id.description] = state
            }
        }
        let visibleChildIDs = hierarchyIdentifiers.compactMap {
            identifier -> String? in
            let prefix = "completed.hierarchy.child."
            guard identifier.hasPrefix(prefix) else { return nil }
            return String(identifier.dropFirst(prefix.count))
        }
        let visibleChildrenAreStyledByParentState =
            visibleChildIDs.allSatisfy { childID in
                guard let expectedState = completedChildStates[childID],
                      let view = AppViewTreeE2E.view(
                          identifier:
                          "completed.hierarchy.child.\(childID)"
                      )
                else {
                    return false
                }
                return AppViewTreeE2E.verificationText(for: view)
                    == expectedState
            }
        let completedChildIDs = Set(completedChildStates.keys)
        let ordinaryChainIDs = Set(ordinaryHierarchies.map(\.chain.id))
        let hiddenChildrenStayHidden =
            context.engine.subtasks.values
                .filter {
                    guard let trace =
                        context.engine.traces[$0.traceID]
                    else {
                        return false
                    }
                    return ordinaryChainIDs.contains(trace.chainID)
                        && $0.isUserPresentable
                        && $0.status != .completed
                }
                .allSatisfy {
                    completedChildIDs.contains($0.id.description)
                        == false
                        && hierarchyIdentifiers.contains(
                            "completed.hierarchy.child."
                                + $0.id.description
                        ) == false
                }
        return visibleChildrenAreStyledByParentState
            && hiddenChildrenStayHidden
    }

    @MainActor
    private func captureTaskCollectionScreenshot(page: NoonmarkStore.Page) throws {
        try captureTaskCollectionScreenshot(named: page.rawValue)
    }

    @MainActor
    private func captureTaskCollectionScreenshot(named name: String) throws {
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
                        "task-collection-\(name).png"
                    )
            )
        } catch {
            throw InteractiveDemoFixtureError
                .presentationContractFailed
        }
    }

    @MainActor
    private func captureDocumentationScreenshot(
        of window: NSWindow,
        named fileName: String
    ) throws {
        do {
            try AppE2EScreenshot.captureContent(
                of: window,
                to: resultURL.deletingLastPathComponent()
                    .appendingPathComponent(fileName)
            )
        } catch {
            throw InteractiveDemoFixtureError
                .documentationCaptureFailed(fileName)
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
        guard let session = sessions.last(where: {
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
        var sessions: [ZhulongSession] = []
        for offset in [-270, -180, -90, 0] {
            let sessionDate = DemoFixtureClock.offset(today, by: offset)
            let submitted = try makeSubmittedPlanningSession(
                engine: &engine,
                today: today,
                sessionDate: sessionDate,
                providerIdentity: providerIdentity
            )
            let insight = try makeInsightSession(
                sessionDate: sessionDate,
                providerIdentity: providerIdentity
            )
            let review = try makeDailyReviewSession(
                engine: &engine,
                today: today,
                sessionDate: sessionDate,
                providerIdentity: providerIdentity
            )
            let activeDraft = try makeActivePlanningSession(
                engine: engine,
                today: today,
                sessionDate: sessionDate,
                providerIdentity: providerIdentity
            )
            let poolAnalysis = try makeTaskPoolAnalysisSession(
                engine: engine,
                sessionDate: sessionDate,
                providerIdentity: providerIdentity
            )
            sessions.append(
                contentsOf: [
                    review,
                    activeDraft,
                    submitted,
                    poolAnalysis,
                    insight
                ]
            )
        }
        return sessions
    }

    private func makeTaskPoolAnalysisSession(
        engine: NoonmarkEngine,
        sessionDate: LocalDate,
        providerIdentity: ZhulongProviderConfigurationIdentity
    ) throws -> ZhulongSession {
        let start = DemoFixtureClock.timestamp(
            sessionDate,
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
        sessionDate: LocalDate,
        providerIdentity: ZhulongProviderConfigurationIdentity
    ) throws -> ZhulongSession {
        let start = DemoFixtureClock.timestamp(
            sessionDate,
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
        sessionDate: LocalDate,
        providerIdentity: ZhulongProviderConfigurationIdentity
    ) throws -> ZhulongSession {
        let start = DemoFixtureClock.timestamp(
            sessionDate,
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
        sessionDate: LocalDate,
        providerIdentity: ZhulongProviderConfigurationIdentity
    ) throws -> ZhulongSession {
        let start = DemoFixtureClock.timestamp(
            DemoFixtureClock.offset(sessionDate, by: -2),
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
        sessionDate: LocalDate,
        providerIdentity: ZhulongProviderConfigurationIdentity
    ) throws -> ZhulongSession {
        let start = DemoFixtureClock.timestamp(
            sessionDate,
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
        let insightSessionCount = sessions.count {
            $0.purpose == .habitInsight
        }
        let taskPoolAnalysisSessionCount = sessions.count {
            $0.purpose == .taskPoolAnalysis
        }
        var quarterCalendar = Calendar(identifier: .gregorian)
        quarterCalendar.timeZone = TimeZone(
            identifier: "America/New_York"
        ) ?? .current
        let zhulongCoveredQuarterCount = Set(
            sessions.compactMap {
                $0.events.first?.occurredAt
            }.map {
                let year = quarterCalendar.component(.year, from: $0)
                let month = quarterCalendar.component(.month, from: $0)
                return "\(year)-Q\(((month - 1) / 3) + 1)"
            }
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
        guard var editableSession = sessions.last(where: {
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
        guard sessions.count == 20,
              submittedArtifacts == 4,
              editableArtifacts == 4,
              reviewReceipts == 4,
              insightSessionCount == 4,
              taskPoolAnalysisSessionCount == 4,
              zhulongCoveredQuarterCount == 4,
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
              .ideasPresentationVerified,
              presentationVerification
              .flylightEditingInteractionVerified,
              presentationVerification
              .flylightGlobalSuggestionVerified,
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
            habitInsightSessionCount: insightSessionCount,
            taskPoolAnalysisSessionCount:
            taskPoolAnalysisSessionCount,
            zhulongCoveredQuarterCount: zhulongCoveredQuarterCount,
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
            ideasPresentationVerified:
            presentationVerification
                .ideasPresentationVerified,
            flylightEditingInteractionVerified:
            presentationVerification
                .flylightEditingInteractionVerified,
            flylightGlobalSuggestionVerified:
            presentationVerification
                .flylightGlobalSuggestionVerified,
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
    let ideasPresentationVerified: Bool
    let flylightEditingInteractionVerified: Bool
    let flylightGlobalSuggestionVerified: Bool
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
            ideasPresentationVerified:
            ideasPresentationVerified,
            flylightEditingInteractionVerified:
            flylightEditingInteractionVerified,
            flylightGlobalSuggestionVerified:
            flylightGlobalSuggestionVerified,
            calendarRecurringBoundaryVerified:
            calendarRecurringBoundaryVerified,
            taskCyclePresentationVerified:
            taskCyclePresentationVerified,
            zhulongHeaderComposerHierarchyVerified:
            zhulongHeaderComposerHierarchyVerified
        )
    }

    func verifyingIdeasPresentation() -> Self {
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
            ideasPresentationVerified: true,
            flylightEditingInteractionVerified:
            flylightEditingInteractionVerified,
            flylightGlobalSuggestionVerified:
            flylightGlobalSuggestionVerified,
            calendarRecurringBoundaryVerified:
            calendarRecurringBoundaryVerified,
            taskCyclePresentationVerified:
            taskCyclePresentationVerified,
            zhulongHeaderComposerHierarchyVerified:
            zhulongHeaderComposerHierarchyVerified
        )
    }

    func verifyingFlylightInteractions() -> Self {
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
            ideasPresentationVerified:
            ideasPresentationVerified,
            flylightEditingInteractionVerified: true,
            flylightGlobalSuggestionVerified: true,
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
            ideasPresentationVerified:
            ideasPresentationVerified,
            flylightEditingInteractionVerified:
            flylightEditingInteractionVerified,
            flylightGlobalSuggestionVerified:
            flylightGlobalSuggestionVerified,
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
            ideasPresentationVerified:
            ideasPresentationVerified,
            flylightEditingInteractionVerified:
            flylightEditingInteractionVerified,
            flylightGlobalSuggestionVerified:
            flylightGlobalSuggestionVerified,
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
    let habitInsightSessionCount: Int
    let taskPoolAnalysisSessionCount: Int
    let zhulongCoveredQuarterCount: Int
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
    let ideasPresentationVerified: Bool
    let flylightEditingInteractionVerified: Bool
    let flylightGlobalSuggestionVerified: Bool
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
    case taskCollectionPresentationFailed(String)
    case taskCycleDetailPresentationFailed(String)
    case documentationCaptureFailed(String)

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
        case let .taskCollectionPresentationFailed(diagnostic):
            "任务集合展示契约失败：\(diagnostic)"
        case let .taskCycleDetailPresentationFailed(diagnostic):
            "重复任务实例详情未满足分类与生命周期摘要契约：\(diagnostic)"
        case let .documentationCaptureFailed(diagnostic):
            "演示 App 文档截图失败：\(diagnostic)"
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
            identifier: "America/New_York"
        ) ?? .current
        return calendar
    }
}
