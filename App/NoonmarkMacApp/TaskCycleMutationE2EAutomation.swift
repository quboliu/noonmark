import AppKit
import Foundation
import NoonmarkCore
import NoonmarkStorage
import NoonmarkSync

struct DefaultStateE2ESeedAutomation: LaunchAutomationRunnable {
    @MainActor
    static func fromCommandLine() -> Self? {
        AppLaunchArguments.contains("--e2e-seed-default-state")
            ? Self()
            : nil
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        guard store.engine.snapshot().chains.isEmpty else { return }
        do {
            try store.seed()
            guard let repository = store.repository else {
                throw DefaultStateE2ESeedError.missingRepository
            }
            try repository.save(store.engine)
        } catch {
            NSLog(
                "Noonmark default E2E seed failed: %@",
                String(describing: error)
            )
        }
    }
}

private enum DefaultStateE2ESeedError: Error {
    case missingRepository
}

struct ClassificationDeletionRestartE2EAutomation:
    LaunchAutomationRunnable
{
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard let path = AppLaunchArguments.value(
            after: "--e2e-classification-deletion-restart-result-url"
        ) else {
            return nil
        }
        return Self(resultURL: URL(fileURLWithPath: path))
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        guard let target = store.classificationCatalog()?
            .categories.first(where: {
                $0.lifecycle == .archived
                    && $0.currentUsageCount == 0
                    && $0.historicalUsageCount > 0
            })
        else {
            finish(
                "failed: 重启后没有找到已删除且保留历史引用的分组"
            )
            return
        }
        let state = store.engine.snapshot().classifications
        guard state.currentByChainID.values.allSatisfy({
            $0.categoryID?.description != target.id
        }), state.snapshotEventsByTraceID.values
            .flatMap({ $0 })
            .contains(where: {
                $0.category?.id.description == target.id
            })
        else {
            finish("failed: 重启后分组删除的当前关系或历史事实不正确")
            return
        }
        finish("ok")
    }

    @MainActor
    private func finish(_ result: String) {
        do {
            try FileManager.default.createDirectory(
                at: resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try result.write(
                to: resultURL,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            NSLog(
                "Noonmark classification deletion restart result failed: %@",
                String(describing: error)
            )
        }
        E2EApplicationTermination.schedule()
    }
}

struct TaskCycleMutationE2EAutomation: LaunchAutomationRunnable {
    static let createdTitle = "E2E UI 新建重复"
    static let rowConvertedTitle = "E2E UI 右键转重复"
    static let detailConvertedTitle = "E2E UI 详情转重复"
    static let emptyConvertedTitle = "E2E UI 空标题转重复"
    static let skippedTitle = "E2E UI 跳过重复"
    static let stoppedTitle = "E2E UI 停止重复"
    static let returnedTitle = "E2E UI 回池重复"

    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard let path = AppLaunchArguments.value(
            after: "--e2e-task-cycle-mutation-result-url"
        ) else {
            return nil
        }
        return Self(resultURL: URL(fileURLWithPath: path))
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Session(store: store, resultURL: resultURL).start()
    }

    @MainActor
    private final class Session {
        private final class MenuTrackingProbe: @unchecked Sendable {
            private(set) var didBeginTracking = false
            private var observer: NSObjectProtocol?

            init(downArrowCount: Int) {
                observer = NotificationCenter.default.addObserver(
                    forName: NSMenu.didBeginTrackingNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.didBeginTracking = true
                        Self.postSelection(
                            downArrowCount: downArrowCount
                        )
                    }
                }
            }

            @MainActor
            private static func postSelection(
                downArrowCount: Int
            ) {
                guard downArrowCount > 0,
                      let window = NSApp.keyWindow ?? NSApp.mainWindow
                else {
                    return
                }
                let timestamp = ProcessInfo.processInfo.systemUptime
                let keyCodes = Array(
                    repeating: UInt16(125),
                    count: downArrowCount
                ) + [UInt16(36)]
                for (index, keyCode) in keyCodes.enumerated() {
                    let characters = keyCode == 125
                        ? String(
                            UnicodeScalar(
                                NSDownArrowFunctionKey
                            )!
                        )
                        : "\r"
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: [],
                        timestamp:
                        timestamp + (Double(index) * 0.01),
                        windowNumber: window.windowNumber,
                        context: nil,
                        characters: characters,
                        charactersIgnoringModifiers: characters,
                        isARepeat: false,
                        keyCode: keyCode
                    ) else {
                        return
                    }
                    NSApp.postEvent(event, atStart: false)
                }
            }

            func stop() {
                guard let observer else { return }
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
        }

        private let store: NoonmarkStore
        private let resultURL: URL
        private var rowConversionChainID: TaskChainID?
        private var detailConversionChainID: TaskChainID?
        private var emptyConversionChainID: TaskChainID?
        private var menuTrackingProbe: MenuTrackingProbe?

        init(store: NoonmarkStore, resultURL: URL) {
            self.store = store
            self.resultURL = resultURL
        }

        func start() {
            guard store.engine.taskCycleSeries.isEmpty else {
                finish("failed: 重复任务 UI mutation fixture 不是空库")
                return
            }
            store.poolText =
                TaskCycleMutationE2EAutomation.rowConvertedTitle
                + " @E2E转换分组 #E2E转换标签"
            store.addPoolTask()
            rowConversionChainID = store.selectedPoolChainID
            store.poolText =
                TaskCycleMutationE2EAutomation.detailConvertedTitle
                + " @E2E转换分组 #E2E转换标签"
            store.addPoolTask()
            detailConversionChainID = store.selectedPoolChainID
            store.poolText = "E2E UI 空标题占位"
            store.addPoolTask()
            emptyConversionChainID = store.selectedPoolChainID
            if let emptyConversionChainID {
                store.renamePoolTask(
                    chainID: emptyConversionChainID,
                    title: "",
                    immediately: true
                )
            }
            guard archiveConversionClassifications() else {
                finish("failed: 无法归档转换源任务的分类")
                return
            }
            let tomorrow = NoonmarkStore.offset(store.today, by: 1)
            let followingDay = NoonmarkStore.offset(store.today, by: 2)
            guard rowConversionChainID != nil,
                  detailConversionChainID != nil,
                  emptyConversionChainID != nil,
                  store.createTaskCycleSeries(
                      title: TaskCycleMutationE2EAutomation.skippedTitle,
                      startDate: tomorrow,
                      endDate: followingDay,
                      schedule: .daily
                  ), store.createTaskCycleSeries(
                      title: TaskCycleMutationE2EAutomation.stoppedTitle,
                      startDate: tomorrow,
                      endDate: followingDay,
                      schedule: .daily
                  ), store.createTaskCycleSeries(
                      title: TaskCycleMutationE2EAutomation.returnedTitle,
                      startDate: tomorrow,
                      endDate: tomorrow,
                      schedule: .daily
                  ), let returnedSeries = series(
                      titled: TaskCycleMutationE2EAutomation.returnedTitle
                  ), let returnedTrace = occurrenceTrace(
                      seriesID: returnedSeries.id,
                      occurrenceDate: tomorrow
                  )
            else {
                finish("failed: 无法建立重复任务 UI mutation fixture")
                return
            }
            store.returnToPool(returnedTrace.id)
            store.page = .pool
            waitFor("任务池 slash command 输入框") {
                guard AppViewTreeE2E.activateMainWindow(),
                      AppViewTreeE2E.view(
                          identifier: "task-cycle-create.open"
                      ) == nil,
                      let input = AppViewTreeE2E.view(
                          identifier: "quick-add.pool.input"
                      )
                else {
                    return false
                }
                return AppViewTreeE2E.click(input)
            } onSuccess: { [self] in
                submitRecurringSlashCommand()
            }
        }

        private func archiveConversionClassifications() -> Bool {
            guard let catalog = store.classificationCatalog(),
                  let category = catalog.categories.first(where: {
                      $0.name == "E2E转换分组"
                  }),
                  let label = catalog.labels.first(where: {
                      $0.name == "E2E转换标签"
                  }),
                  let categoryUUID = UUID(uuidString: category.id),
                  let labelUUID = UUID(uuidString: label.id)
            else {
                return false
            }
            do {
                _ = try store.applyClassificationIntent(
                    .archiveCategory(TaskCategoryID(categoryUUID))
                )
                _ = try store.applyClassificationIntent(
                    .archiveLabel(TaskLabelID(labelUUID))
                )
                return true
            } catch {
                return false
            }
        }

        private func submitRecurringSlashCommand() {
            let input =
                "/repeat \(TaskCycleMutationE2EAutomation.createdTitle)"
                + " @E2E重复分组 #E2E重复标签"
            waitFor("slash command 输入框获得焦点") {
                guard let inputView = AppViewTreeE2E.view(
                    identifier: "quick-add.pool.input"
                ), inputView.window?.firstResponder is NSTextView
                else {
                    return false
                }
                return AppViewTreeE2E.typeUnicode(input)
            } onSuccess: { [self] in
                waitFor("slash command 已解析") {
                    self.store.parsedTaskDraft(
                        self.store.poolText
                    ).command == .recurring
                        && AppViewTreeE2E.sendReturnKey()
                } onSuccess: { [self] in
                    waitFor("slash command 新建重复任务配置") {
                        AppViewTreeE2E.activateWindow(
                            containing: "task-cycle-create.sheet"
                        )
                            && self.taskCycleTitleField()?.stringValue
                            == TaskCycleMutationE2EAutomation.createdTitle
                    } onSuccess: { [self] in
                        confirmCreatedSeries()
                    }
                }
            }
        }

        private func confirmCreatedSeries() {
            waitFor("新建重复任务确认") {
                guard self.taskCycleTitleField()?.stringValue
                    == TaskCycleMutationE2EAutomation.createdTitle
                else {
                    return false
                }
                return AppViewTreeE2E.click(
                    identifier: "task-cycle-create.confirm"
                )
            } onSuccess: { [self] in
                waitFor("新建重复任务落盘") {
                    self.series(
                        titled:
                        TaskCycleMutationE2EAutomation.createdTitle
                    ) != nil
                        && AppViewTreeE2E.hasNoAttachedSheets()
                } onSuccess: { [self] in
                    convertPoolTaskFromRow()
                }
            }
        }

        private func convertPoolTaskFromRow() {
            guard let chainID = rowConversionChainID else {
                finish("failed: 缺少右键转换源任务")
                return
            }
            let titleIdentifier = PoolTaskRowE2ENamespace(
                taskIdentifier: chainID.description
            ).titleIdentifier
            waitFor("既有任务右键转换入口") {
                guard let titleView = AppViewTreeE2E.view(
                    identifier: titleIdentifier
                ) else {
                    return false
                }
                return AppViewTreeE2E.selectContextMenuItem(
                    of: titleView,
                    downArrowCount: 4
                )
            } onSuccess: { [self] in
                waitFor("右键转换重复任务配置") {
                    self.conversionRequestTargets(chainID)
                        && self.taskCycleTitleField()?.stringValue
                        == TaskCycleMutationE2EAutomation
                            .rowConvertedTitle
                        && self.taskCycleTitleField()?.isEnabled == false
                } onSuccess: { [self] in
                    rejectConversionPersistenceThenRetry(
                        title:
                        TaskCycleMutationE2EAutomation.rowConvertedTitle,
                        chainID: chainID
                    ) {
                        self.openDetailConversion()
                    }
                }
            }
        }

        private func rejectConversionPersistenceThenRetry(
            title: String,
            chainID: TaskChainID,
            onSuccess: @escaping @MainActor () -> Void
        ) {
            guard let repository = store.repository,
                  let databaseURL = store.databaseURL,
                  let persistedBaseline = try? repository.load()
                      .snapshot(),
                  let journalBaseline = try? SQLiteSyncRepository(
                      databaseURL: databaseURL
                  ).journalEntries()
            else {
                finish("failed: 无法读取转换失败注入基线")
                return
            }
            let engineBaseline = store.engine.snapshot()
            guard persistedBaseline == engineBaseline else {
                finish("failed: 转换失败注入前 Engine 与 SQLite 不一致")
                return
            }
            do {
                try store.armPersistenceFailureForE2E()
            } catch {
                finish(
                    "failed: 无法启用转换持久化失败注入："
                        + error.localizedDescription
                )
                return
            }
            waitFor("转换重复任务失败注入确认") {
                AppViewTreeE2E.click(
                    identifier: "task-cycle-create.confirm"
                )
            } onSuccess: { [self] in
                waitFor("转换重复任务失败后完整回滚") {
                    guard self.store.operationFailure != nil,
                          self.store.engine.snapshot()
                          == engineBaseline,
                          (try? repository.load().snapshot())
                          == persistedBaseline,
                          (try? SQLiteSyncRepository(
                              databaseURL: databaseURL
                          ).journalEntries()) == journalBaseline,
                          self.series(titled: title) == nil,
                          self.store.engine.chains[
                              chainID
                          ]?.cycleMembership == nil,
                          self.conversionRequestTargets(chainID),
                          self.taskCycleTitleField() != nil
                    else {
                        return false
                    }
                    return true
                } onSuccess: { [self] in
                    self.store.disarmPersistenceFailureForE2E()
                    self.store.dismissOperationFailure()
                    self.confirmConvertedSeries(
                        title: title,
                        chainID: chainID,
                        onSuccess: onSuccess
                    )
                }
            }
        }

        private func openDetailConversion() {
            guard let chainID = detailConversionChainID else {
                finish("failed: 缺少详情转换源任务")
                return
            }
            let titleIdentifier = PoolTaskRowE2ENamespace(
                taskIdentifier: chainID.description
            ).titleIdentifier
            waitFor("既有任务详情入口") {
                guard let titleView = AppViewTreeE2E.view(
                    identifier: titleIdentifier
                ) else {
                    return false
                }
                return AppViewTreeE2E.click(titleView)
            } onSuccess: { [self] in
                waitFor("既有任务详情展开") {
                    self.store.selectedPoolChainID == chainID
                        && self.store.isDetailRailExpanded
                        && AppViewTreeE2E.view(
                            identifier:
                            "pool.detail-overflow.\(chainID.description)"
                        ) != nil
                } onSuccess: { [self] in
                    selectDetailConversion(chainID: chainID)
                }
            }
        }

        private func selectDetailConversion(
            chainID: TaskChainID
        ) {
            let probe = MenuTrackingProbe(downArrowCount: 4)
            menuTrackingProbe = probe
            waitFor("详情省略号转换入口") {
                AppViewTreeE2E.click(
                    identifier:
                    "pool.detail-overflow.\(chainID.description)"
                )
            } onSuccess: { [self] in
                waitFor("详情省略号转换动作") {
                    probe.didBeginTracking
                        && self.conversionRequestTargets(chainID)
                } onSuccess: { [self] in
                    probe.stop()
                    menuTrackingProbe = nil
                    confirmConvertedSeries(
                        title:
                        TaskCycleMutationE2EAutomation
                            .detailConvertedTitle,
                        chainID: chainID
                    ) {
                        self.convertEmptyTitleTask()
                    }
                }
            }
        }

        private func convertEmptyTitleTask() {
            guard let chainID = emptyConversionChainID else {
                finish("failed: 缺少空标题转换源任务")
                return
            }
            let titleIdentifier = PoolTaskRowE2ENamespace(
                taskIdentifier: chainID.description
            ).titleIdentifier
            waitFor("空标题既有任务右键转换入口") {
                guard let titleView = AppViewTreeE2E.view(
                    identifier: titleIdentifier
                ) else {
                    return false
                }
                return AppViewTreeE2E.selectContextMenuItem(
                    of: titleView,
                    downArrowCount: 4
                )
            } onSuccess: { [self] in
                waitFor("空标题转换允许输入系列标题") {
                    self.conversionRequestTargets(chainID)
                        && self.taskCycleTitleField()?.stringValue.isEmpty
                        == true
                        && self.taskCycleTitleField()?.isEnabled == true
                } onSuccess: { [self] in
                    typeEmptyConversionTitle(chainID: chainID)
                }
            }
        }

        private func typeEmptyConversionTitle(
            chainID: TaskChainID
        ) {
            waitFor("空标题转换标题框获得焦点") {
                guard let field = self.taskCycleTitleField()
                else {
                    return false
                }
                return AppViewTreeE2E.click(field)
                    && AppViewTreeE2E.typeUnicode(
                        TaskCycleMutationE2EAutomation
                            .emptyConvertedTitle
                    )
            } onSuccess: { [self] in
                waitFor("空标题转换标题输入完成") {
                    self.taskCycleTitleField()?.stringValue
                        == TaskCycleMutationE2EAutomation
                            .emptyConvertedTitle
                } onSuccess: { [self] in
                    confirmConvertedSeries(
                        title:
                        TaskCycleMutationE2EAutomation
                            .emptyConvertedTitle,
                        chainID: chainID
                    ) {
                        guard self.currentDefinitionTitle(
                            chainID: chainID
                        ) == TaskCycleMutationE2EAutomation
                            .emptyConvertedTitle
                        else {
                            self.finish(
                                "failed: 空标题转换没有原子写入当前标题"
                            )
                            return
                        }
                        self.openReturnedOccurrence()
                    }
                }
            }
        }

        private func confirmConvertedSeries(
            title: String,
            chainID: TaskChainID,
            onSuccess: @escaping @MainActor () -> Void
        ) {
            waitFor("转换重复任务确认") {
                guard self.taskCycleTitleField()?.stringValue == title
                else {
                    return false
                }
                return AppViewTreeE2E.click(
                    identifier: "task-cycle-create.confirm"
                )
            } onSuccess: { [self] in
                waitFor("转换重复任务落盘") {
                    self.series(titled: title) != nil
                        && self.store.engine.chains[
                            chainID
                        ]?.cycleMembership != nil
                        && AppViewTreeE2E.hasNoAttachedSheets()
                } onSuccess: {
                    onSuccess()
                }
            }
        }

        private func conversionRequestTargets(
            _ chainID: TaskChainID
        ) -> Bool {
            guard let request = store.taskCycleCreationRequest
            else {
                return false
            }
            if case let .existingTask(
                sourceChainID,
                adoptsSourceChain
            ) = request.origin {
                return sourceChainID == chainID
                    && adoptsSourceChain
            }
            return false
        }

        private func currentDefinitionTitle(
            chainID: TaskChainID
        ) -> String? {
            store.engine.definitions.values
                .filter {
                    $0.chainID == chainID
                        && $0.supersededAt == nil
                }
                .max { $0.sequence < $1.sequence }?
                .title
        }

        private func openReturnedOccurrence() {
            guard let target = cycleDayTarget(
                title: TaskCycleMutationE2EAutomation.returnedTitle,
                state: .returnedToPool
            ) else {
                finish("failed: 缺少回池 occurrence")
                return
            }
            expandTrackIfNeeded(target)
            waitFor("回池 occurrence 轨迹") {
                AppViewTreeE2E.view(identifier: target.dayIdentifier)
                    != nil
            } onSuccess: { [self] in
                waitFor("回池 occurrence 详情入口") {
                    AppViewTreeE2E.click(
                        identifier: target.dayIdentifier
                    )
                } onSuccess: { [self] in
                    waitFor("回池 occurrence 任务详情") {
                        self.store.selectedPoolChainID == target.chainID
                            && self.store.isDetailRailExpanded
                    } onSuccess: { [self] in
                        scheduleReturnedOccurrence(target)
                    }
                }
            }
        }

        private func scheduleReturnedOccurrence(
            _ target: CycleDayTarget
        ) {
            waitFor("回池 occurrence 今日排期菜单") {
                guard let dayView = AppViewTreeE2E.view(
                    identifier: target.dayIdentifier
                ) else {
                    return false
                }
                return AppViewTreeE2E.selectFirstContextMenuItem(
                    of: dayView
                )
            } onSuccess: { [self] in
                waitFor("回池 occurrence 今日排期结果") {
                    self.store.engine.traces.values.contains {
                        $0.chainID == target.chainID
                            && $0.date == self.store.today
                            && $0.status == .pending
                    }
                } onSuccess: { [self] in
                    waitFor("返回任务池重复任务分组") {
                        AppViewTreeE2E.click(
                            identifier: "sidebar.nav.pool"
                        )
                    } onSuccess: { [self] in
                        skipOccurrence()
                    }
                }
            }
        }

        private func skipOccurrence() {
            guard let target = cycleDayTarget(
                title: TaskCycleMutationE2EAutomation.skippedTitle,
                state: .planned
            ) else {
                finish("failed: 缺少可跳过的未来 occurrence")
                return
            }
            expandTrackIfNeeded(target)
            waitFor("跳过 occurrence 菜单") {
                guard let dayView = AppViewTreeE2E.view(
                    identifier: target.dayIdentifier
                ) else {
                    return false
                }
                return AppViewTreeE2E.selectFirstContextMenuItem(
                    of: dayView
                )
            } onSuccess: { [self] in
                waitFor("跳过 occurrence 结果") {
                    self.series(
                        titled:
                        TaskCycleMutationE2EAutomation.skippedTitle
                    )?.isOccurrenceSkipped(target.occurrenceDate)
                        == true
                } onSuccess: { [self] in
                    stopSeries()
                }
            }
        }

        private func stopSeries() {
            guard let target = cycleDayTarget(
                title: TaskCycleMutationE2EAutomation.stoppedTitle,
                state: .planned
            ) else {
                finish("failed: 缺少可停止的重复任务")
                return
            }
            waitFor("停止重复任务菜单") {
                guard let trackView = AppViewTreeE2E.view(
                    identifier: target.trackIdentifier
                ) else {
                    return false
                }
                return AppViewTreeE2E.selectFirstContextMenuItem(
                    of: trackView
                )
            } onSuccess: { [self] in
                waitFor("停止重复任务确认") {
                    guard let confirm = AppViewTreeE2E.button(
                        label: self.store.copy.stopRecurringTask
                    ) else {
                        return false
                    }
                    return AppViewTreeE2E.click(confirm)
                } onSuccess: { [self] in
                    waitFor("停止重复任务结果") {
                        self.series(
                            titled:
                            TaskCycleMutationE2EAutomation.stoppedTitle
                        )?.stoppedAfterDate == self.store.today
                    } onSuccess: { [self] in
                        finish("ok")
                    }
                }
            }
        }

        private func taskCycleTitleField() -> NSTextField? {
            guard let view = AppViewTreeE2E.view(
                identifier: "task-cycle-create.title"
            ) else {
                return nil
            }
            return (view as? NSTextField)
                ?? AppViewTreeE2E.textField(overlapping: view)
        }

        private func series(titled title: String) -> TaskCycleSeries? {
            store.engine.taskCycleSeries.values.first {
                $0.title == title
            }
        }

        private func occurrenceTrace(
            seriesID: TaskCycleSeriesID,
            occurrenceDate: LocalDate
        ) -> DayTrace? {
            guard let chainID = store.engine.chains.values.first(where: {
                $0.cycleMembership?.seriesID == seriesID
                    && $0.cycleMembership?.occurrenceDate
                    == occurrenceDate
            })?.id else {
                return nil
            }
            return store.engine.traces.values.first {
                $0.chainID == chainID
                    && $0.date == occurrenceDate
            }
        }

        private func cycleDayTarget(
            title: String,
            state: TaskCycleTrackDayState
        ) -> CycleDayTarget? {
            guard let series = series(titled: title),
                  let track = store.engine.taskCycleTracks(
                      today: store.today,
                      collection: .pool
                  ).first(where: { $0.id == series.id }),
                  let day = track.days.first(where: {
                      $0.presentationState(in: .pool) == state
                          && $0.chainID != nil
                  }),
                  let chainID = day.chainID
            else {
                return nil
            }
            return CycleDayTarget(
                seriesID: series.id,
                chainID: chainID,
                occurrenceDate: day.date,
                trackIdentifier:
                "task-cycle-track.pool.\(series.id.description)",
                dayIdentifier:
                "task-cycle-day.pool.\(series.id.description).\(day.date.description).\(state.rawValue)"
            )
        }

        private func expandTrackIfNeeded(_ target: CycleDayTarget) {
            guard AppViewTreeE2E.view(
                identifier: target.dayIdentifier
            ) == nil else {
                return
            }
            _ = AppViewTreeE2E.click(
                identifier: target.trackIdentifier
            )
        }

        private func waitFor(
            _ label: String,
            attemptsRemaining: Int = 120,
            condition: @escaping @MainActor () -> Bool,
            onSuccess: @escaping @MainActor () -> Void
        ) {
            guard attemptsRemaining > 0 else {
                finish("failed: \(label)")
                return
            }
            guard condition() else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.waitFor(
                        label,
                        attemptsRemaining: attemptsRemaining - 1,
                        condition: condition,
                        onSuccess: onSuccess
                    )
                }
                return
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.05,
                execute: onSuccess
            )
        }

        private func finish(_ result: String) {
            if result != "ok" {
                AppViewTreeE2E.writeDump(beside: resultURL)
            }
            do {
                try FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try result.write(
                    to: resultURL,
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                NSLog(
                    "Noonmark task cycle mutation result failed: %@",
                    String(describing: error)
                )
            }
            E2EApplicationTermination.schedule()
        }
    }

    private struct CycleDayTarget {
        let seriesID: TaskCycleSeriesID
        let chainID: TaskChainID
        let occurrenceDate: LocalDate
        let trackIdentifier: String
        let dayIdentifier: String
    }
}

struct TaskCycleMutationRestartE2EAutomation:
    LaunchAutomationRunnable
{
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard let path = AppLaunchArguments.value(
            after: "--e2e-task-cycle-mutation-restart-result-url"
        ) else {
            return nil
        }
        return Self(resultURL: URL(fileURLWithPath: path))
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        let seriesByTitle = Dictionary(
            uniqueKeysWithValues: store.engine.taskCycleSeries.values.map {
                ($0.title, $0)
            }
        )
        guard let created = seriesByTitle[
            TaskCycleMutationE2EAutomation.createdTitle
        ],
        let rowConverted = seriesByTitle[
            TaskCycleMutationE2EAutomation.rowConvertedTitle
        ],
        let detailConverted = seriesByTitle[
            TaskCycleMutationE2EAutomation.detailConvertedTitle
        ],
        let emptyConverted = seriesByTitle[
            TaskCycleMutationE2EAutomation.emptyConvertedTitle
        ],
        emptyConverted.title
            == TaskCycleMutationE2EAutomation.emptyConvertedTitle,
        seriesHasClassification(
            created,
            categoryName: "E2E重复分组",
            labelName: "E2E重复标签",
            store: store
        ),
        seriesHasClassification(
            rowConverted,
            categoryName: "E2E转换分组",
            labelName: "E2E转换标签",
            store: store
        ),
        seriesHasClassification(
            detailConverted,
            categoryName: "E2E转换分组",
            labelName: "E2E转换标签",
            store: store
        ),
        conversionClassificationsAreArchived(store: store),
        let skipped = seriesByTitle[
            TaskCycleMutationE2EAutomation.skippedTitle
        ],
        skipped.cancellationFacts.contains(where: {
            if case .occurrence = $0.scope { return true }
            return false
        }),
        seriesByTitle[
            TaskCycleMutationE2EAutomation.stoppedTitle
        ]?.stoppedAfterDate == store.today,
        let returned = seriesByTitle[
            TaskCycleMutationE2EAutomation.returnedTitle
        ],
        let returnedChainID = store.engine.chains.values.first(where: {
            $0.cycleMembership?.seriesID == returned.id
        })?.id,
        store.engine.traces.values.contains(where: {
            $0.chainID == returnedChainID
                && $0.date == store.today
                && $0.status == .pending
        }),
        store.engine.taskPool().contains(where: {
            $0.chain.id == returnedChainID
        }) == false
        else {
            finish("failed: 重启后重复任务 UI mutation 未完整保留")
            return
        }
        finish("ok")
    }

    @MainActor
    private func conversionClassificationsAreArchived(
        store: NoonmarkStore
    ) -> Bool {
        guard let catalog = store.classificationCatalog()
        else {
            return false
        }
        return catalog.categories.first {
            $0.name == "E2E转换分组"
        }?.lifecycle == .archived
            && catalog.labels.first {
                $0.name == "E2E转换标签"
            }?.lifecycle == .archived
    }

    @MainActor
    private func seriesHasClassification(
        _ series: TaskCycleSeries,
        categoryName: String,
        labelName: String,
        store: NoonmarkStore
    ) -> Bool {
        let chainIDs = store.engine.chains.values.compactMap {
            $0.cycleMembership?.seriesID == series.id
                ? $0.id
                : nil
        }
        return chainIDs.isEmpty == false
            && chainIDs.allSatisfy { chainID in
                guard let classification =
                    store.currentClassification(for: chainID)
                else {
                    return false
                }
                return classification.category?.name == categoryName
                    && classification.labels.contains {
                        $0.name == labelName
                    }
            }
    }

    @MainActor
    private func finish(_ result: String) {
        do {
            try FileManager.default.createDirectory(
                at: resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try result.write(
                to: resultURL,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            NSLog(
                "Noonmark task cycle restart result failed: %@",
                String(describing: error)
            )
        }
        E2EApplicationTermination.schedule()
    }
}
