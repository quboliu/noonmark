import Foundation
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
            identifier: "zhulong-session-pause"
        ) != nil
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
              analysisVisible == store.isZhulongProviderReady
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

        do {
            let result = try manifest(
                fixture: fixture,
                engine: engine,
                sessions: sessions,
                store: store,
                scopeAuthorizationUIVerified: true,
                taskPoolStatisticsPresentationVerified: true,
                taskPoolProviderBoundaryVerified: true,
                zhulongHeaderComposerHierarchyVerified: true
            )
            store.page = .day
            store.selectedDate = fixture.anchorDate
            try write(result)
        } catch {
            finishWithFailure(error, on: store)
        }
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
        return [review, activeDraft, submitted, insight]
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
        scopeAuthorizationUIVerified: Bool,
        taskPoolStatisticsPresentationVerified: Bool,
        taskPoolProviderBoundaryVerified: Bool,
        zhulongHeaderComposerHierarchyVerified: Bool
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
        let multiDayCompletedTaskCount = completedItems.count {
            $0.trajectory.traces.count
                >= MacUICompletedPoolRowLayout.minimumVisibleTrajectoryNodeCount
        }
        let completedPoolRowHierarchyVerified =
            singleDayCompletedTaskCount > 0
                && multiDayCompletedTaskCount > 0
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
              taskPoolStatisticsPresentationVerified,
              taskPoolProviderBoundaryVerified,
              zhulongHeaderComposerHierarchyVerified,
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
            multiDayCompletedTaskCount: multiDayCompletedTaskCount,
            completedPoolRowHierarchyVerified:
            completedPoolRowHierarchyVerified,
            visibleScopeReauthorizationCardCount:
            visibleScopeReauthorizationCardCount,
            scopeAuthorizationUIVerified:
            scopeAuthorizationUIVerified,
            taskPoolStatisticsPresentationVerified:
            taskPoolStatisticsPresentationVerified,
            taskPoolProviderBoundaryVerified:
            taskPoolProviderBoundaryVerified,
            zhulongHeaderComposerHierarchyVerified:
            zhulongHeaderComposerHierarchyVerified,
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
    let multiDayCompletedTaskCount: Int
    let completedPoolRowHierarchyVerified: Bool
    let visibleScopeReauthorizationCardCount: Int
    let scopeAuthorizationUIVerified: Bool
    let taskPoolStatisticsPresentationVerified: Bool
    let taskPoolProviderBoundaryVerified: Bool
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
