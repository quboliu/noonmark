import AppKit
import Carbon
import Foundation
import NoonmarkAI
import NoonmarkCore
import NoonmarkDemoSupport
import NoonmarkStorage
import NoonmarkZhulong

@MainActor
struct TencentIMEInputSurfaceMatrixE2EAutomation:
    LaunchAutomationRunnable
{
    private static let expectedInputSourceID =
        "com.tencent.inputmethod.wetype.pinyin"
    private static let phrases = [
        "nihaoshijie",
        "ceshishuru",
        "renwumiaoshu"
    ]
    private static let burstPhrase = "renwumiaoshu"
    private static let persistenceOverlapPhrases = phrases
    private static let p95LimitMilliseconds = 100.0
    private static let maximumLimitMilliseconds = 250.0
    private static let burstLimitMilliseconds = 1000.0
    private static let durableLimitMilliseconds = 1500.0
    private static let mainActorBlockingLimitMilliseconds =
        25.0

    private let resultURL: URL
    private let surface: Surface
    private let lifecyclePhase: LifecyclePhase?
    private let lifecycleStateURL: URL?

    static func fromCommandLine() -> Self? {
        guard let rawSurface = AppLaunchArguments.value(
            after: "--e2e-tencent-ime-input-surface"
        ), let surface = Surface(rawValue: rawSurface),
        let resultPath = AppLaunchArguments.value(
            after: "--e2e-tencent-ime-input-surface-result-url"
        )
        else {
            return nil
        }
        let lifecyclePhase = AppLaunchArguments.value(
            after:
            "--e2e-tencent-ime-termination-phase"
        ).flatMap(LifecyclePhase.init(rawValue:))
        let lifecycleStateURL = AppLaunchArguments.value(
            after:
            "--e2e-tencent-ime-termination-state-url"
        ).map(URL.init(fileURLWithPath:))
        guard lifecyclePhase == nil
            || lifecycleStateURL != nil
        else {
            return nil
        }
        return Self(
            resultURL: URL(fileURLWithPath: resultPath),
            surface: surface,
            lifecyclePhase: lifecyclePhase,
            lifecycleStateURL: lifecycleStateURL
        )
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                if let lifecyclePhase {
                    NSLog(
                        "Noonmark Tencent IME lifecycle phase=%@ surface=%@ started",
                        lifecyclePhase.rawValue,
                        surface.rawValue
                    )
                }
                if lifecyclePhase == .verify {
                    try await verifyLifecycleTermination(
                        on: store
                    )
                    E2EApplicationTermination.schedule()
                    return
                }
                try installRealisticWorkloadIfRequested(on: store)
                let inputSourceID = try currentInputSourceID()
                guard inputSourceID == Self.expectedInputSourceID else {
                    throw Failure.failed(
                        "当前输入源不是腾讯拼音：\(inputSourceID)"
                    )
                }
                let input = try WindowServerInputDriver()
                let target = try await prepare(
                    surface,
                    store: store,
                    input: input
                )
                if lifecyclePhase == .exercise {
                    try await exerciseLifecycleTermination(
                        target,
                        inputSourceID: inputSourceID,
                        input: input,
                        store: store
                    )
                    return
                }
                // Fixture construction can perform synchronous mutations.
                // Only samples produced after the real editor is ready belong
                // to this input-surface measurement.
                store.e2eLastEngineMutationPerformanceSample = nil
                store.zhulongWorkspace
                    .e2eLastDraftPersistencePerformanceSample = nil
                let measurement = try await measure(
                    target,
                    input: input
                )
                let mutation =
                    store.e2eLastEngineMutationPerformanceSample
                let zhulongDraftPersistence =
                    store.zhulongWorkspace
                    .e2eLastDraftPersistencePerformanceSample
                if let mainActorBlockingMilliseconds =
                    mutation?.mainActorBlockingMilliseconds,
                    mainActorBlockingMilliseconds
                    > Self
                    .mainActorBlockingLimitMilliseconds
                {
                    throw Failure.failed(
                        "\(surface.label)自动保存占用主线程 "
                            + "\(format(mainActorBlockingMilliseconds))ms"
                    )
                }
                if let mainActorPublishMilliseconds =
                    zhulongDraftPersistence?
                    .mainActorPublishMilliseconds,
                    mainActorPublishMilliseconds
                    > Self
                    .mainActorBlockingLimitMilliseconds
                {
                    throw Failure.failed(
                        "\(surface.label)烛龙草稿发布占用主线程 "
                            + "\(format(mainActorPublishMilliseconds))ms"
                    )
                }
                try writeResult([
                    "status=PASS",
                    "surface=\(surface.rawValue)",
                    "label=\(surface.label)",
                    "control=\(target.identifier)",
                    "save_policy=\(surface.savePolicy)",
                    "workload=\(workloadLabel)",
                    "input_source=\(inputSourceID)",
                    "sample_count=\(measurement.latencies.count)",
                    "paced_p50_ms=\(format(measurement.p50Milliseconds))",
                    "paced_p95_ms=\(format(measurement.p95Milliseconds))",
                    "paced_max_ms=\(format(measurement.maximumMilliseconds))",
                    "event_delivery_p95_ms="
                        + formatOptional(
                            measurement
                                .eventDeliveryP95Milliseconds
                        ),
                    "event_to_key_down_p95_ms="
                        + formatOptional(
                            measurement
                                .eventToKeyDownP95Milliseconds
                        ),
                    "key_down_marked_text_query_p95_ms="
                        + formatOptional(
                            measurement
                                .keyDownMarkedTextQueryP95Milliseconds
                        ),
                    "key_down_pre_super_p95_ms="
                        + formatOptional(
                            measurement
                                .keyDownPreSuperP95Milliseconds
                        ),
                    "key_down_super_p95_ms="
                        + formatOptional(
                            measurement
                                .keyDownSuperP95Milliseconds
                        ),
                    "key_down_set_marked_text_p95_ms="
                        + formatOptional(
                            measurement
                                .keyDownSetMarkedTextP95Milliseconds
                        ),
                    "key_down_insert_text_p95_ms="
                        + formatOptional(
                            measurement
                                .keyDownInsertTextP95Milliseconds
                        ),
                    "key_down_did_change_text_p95_ms="
                        + formatOptional(
                            measurement
                                .keyDownDidChangeTextP95Milliseconds
                        ),
                    "key_down_composition_callback_p95_ms="
                        + formatOptional(
                            measurement
                                .keyDownCompositionCallbackP95Milliseconds
                        ),
                    "key_down_native_snapshot_callback_p95_ms="
                        + formatOptional(
                            measurement
                                .keyDownNativeSnapshotCallbackP95Milliseconds
                        ),
                    "event_to_echo_p95_ms="
                        + formatOptional(
                            measurement
                                .eventToEchoP95Milliseconds
                        ),
                    "burst_total_ms=\(format(measurement.burstTotalMilliseconds))",
                    "persistence_overlap_p95_ms="
                        + formatOptional(
                            measurement
                                .persistenceOverlapP95Milliseconds
                        ),
                    "persistence_overlap_max_ms="
                        + formatOptional(
                            measurement
                                .persistenceOverlapMaximumMilliseconds
                        ),
                    "marked_text=\(measurement.observedMarkedText)",
                    "composition_expected="
                        + "\(surface.expectsMarkedText)",
                    "premature_persist_count="
                        + "\(measurement.prematurePersistCount)",
                    "durable_ms="
                        + formatOptional(
                            measurement.durableMilliseconds
                        ),
                    "durable_readback_probe_ms="
                        + formatOptional(
                            measurement
                                .durableReadbackProbeMilliseconds
                        ),
                    "live_readback_match="
                        + "\(measurement.liveReadbackMatched)",
                    "durable_readback_match="
                        + "\(measurement.durableReadbackMatched)",
                    "mutation_prepare_ms="
                        + formatOptional(
                            mutation?.prepareMilliseconds
                        ),
                    "mutation_snapshot_ms="
                        + formatOptional(
                            mutation?.snapshotMilliseconds
                        ),
                    "mutation_clone_ms="
                        + formatOptional(
                            mutation?.cloneMilliseconds
                        ),
                    "mutation_domain_ms="
                        + formatOptional(
                            mutation?.mutationMilliseconds
                        ),
                    "mutation_classification_ms="
                        + formatOptional(
                            mutation?
                                .automaticClassificationMilliseconds
                        ),
                    "mutation_persistence_ms="
                        + formatOptional(
                            mutation?.persistenceMilliseconds
                        ),
                    "mutation_publish_ms="
                        + formatOptional(
                            mutation?.publishMilliseconds
                        ),
                    "mutation_total_ms="
                        + formatOptional(
                            mutation?.totalMilliseconds
                        ),
                    "mutation_main_actor_blocking_ms="
                        + formatOptional(
                            mutation?
                                .mainActorBlockingMilliseconds
                        ),
                    "zhulong_draft_persistence_total_ms="
                        + formatOptional(
                            zhulongDraftPersistence?
                                .totalMilliseconds
                        ),
                    "zhulong_draft_main_actor_publish_ms="
                        + formatOptional(
                            zhulongDraftPersistence?
                                .mainActorPublishMilliseconds
                        )
                ])
            } catch {
                NSLog(
                    "Noonmark Tencent IME automation failed surface=%@ error=%@ result=%@",
                    surface.rawValue,
                    error.localizedDescription,
                    resultURL.path
                )
                AppViewTreeE2E.writeDump(beside: resultURL)
                let mutation =
                    store.e2eLastEngineMutationPerformanceSample
                let zhulongDraftPersistence =
                    store.zhulongWorkspace
                    .e2eLastDraftPersistencePerformanceSample
                do {
                    try writeResult([
                        "status=FAIL",
                        "surface=\(surface.rawValue)",
                        "label=\(surface.label)",
                        "save_policy=\(surface.savePolicy)",
                        "workload=\(workloadLabel)",
                        "composition_expected="
                            + "\(surface.expectsMarkedText)",
                        "mutation_snapshot_ms="
                            + formatOptional(
                                mutation?.snapshotMilliseconds
                            ),
                        "mutation_domain_ms="
                            + formatOptional(
                                mutation?.mutationMilliseconds
                            ),
                        "mutation_persistence_ms="
                            + formatOptional(
                                mutation?.persistenceMilliseconds
                            ),
                        "mutation_total_ms="
                            + formatOptional(
                                mutation?.totalMilliseconds
                            ),
                        "mutation_main_actor_blocking_ms="
                            + formatOptional(
                                mutation?
                                    .mainActorBlockingMilliseconds
                            ),
                        "zhulong_draft_persistence_total_ms="
                            + formatOptional(
                                zhulongDraftPersistence?
                                    .totalMilliseconds
                            ),
                        "zhulong_draft_main_actor_publish_ms="
                            + formatOptional(
                                zhulongDraftPersistence?
                                    .mainActorPublishMilliseconds
                            ),
                        "reason=\(singleLine(error.localizedDescription))"
                    ])
                } catch {
                    NSLog(
                        "Noonmark Tencent IME result write failed: %@",
                        error.localizedDescription
                    )
                }
            }
            E2EApplicationTermination.schedule()
        }
    }

    private var workloadLabel: String {
        AppLaunchArguments.contains(
            "--e2e-tencent-ime-input-realistic-workload"
        )
            ? "一年完整演示状态（annual-v1）"
            : "空库"
    }

    private func installRealisticWorkloadIfRequested(
        on store: NoonmarkStore
    ) throws {
        guard AppLaunchArguments.contains(
            "--e2e-tencent-ime-input-realistic-workload"
        ) else {
            return
        }
        guard let repository = store.repository else {
            throw Failure.failed("真实数据规模夹具没有 SQLite repository")
        }
        let fixture = try NoonmarkDemoFixture.make(
            anchorDate: store.today
        )
        let engine = try NoonmarkEngine(
            snapshot: fixture.engine.snapshot()
        )
        try repository.save(engine)
        store.engine = engine
        store.page = .day
        store.selectedDate = fixture.anchorDate
        store.selectedCalendarDate = fixture.anchorDate
        store.clearSelection()
    }

    private func prepare(
        _ surface: Surface,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws -> Target {
        switch surface {
        case .dayQuickAdd:
            store.page = .day
            store.selectedDate = store.today
            store.selectedCalendarDate = store.today
            store.clearSelection()
            return Target(identifier: "quick-add.day.input")

        case .futureQuickAdd:
            let date = NoonmarkStore.offset(store.today, by: 2)
            store.page = .day
            store.selectedDate = date
            store.selectedCalendarDate = date
            store.clearSelection()
            return Target(identifier: "quick-add.day.input")

        case .poolQuickAdd:
            store.page = .pool
            store.clearSelection()
            return Target(identifier: "quick-add.pool.input")

        case .railSearch:
            store.page = .day
            store.selectedDate = store.today
            store.clearSelection()
            store.isDetailRailExpanded = true
            return Target(identifier: "rail.search.field")

        case .quickEntry:
            try showQuickEntry()
            return Target(
                identifier: "quick-entry.field",
                preFocusedWindowIdentifier:
                NoonmarkQuickEntryWindowController.windowIdentifier
            )

        case .globalSearch:
            try showSearch()
            return Target(identifier: "search.field")

        default:
            return try await preparePoolSurface(
                surface,
                store: store,
                input: input
            )
        }
    }

    private func preparePoolSurface(
        _ surface: Surface,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws -> Target {
        switch surface {
        case .poolTitle:
            let chainID = try preparePoolTask(store)
            return Target(
                identifier: "detail.title.input",
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.currentDefinition(
                            for: chainID
                        )?.title
                    },
                    durableReadback: {
                        currentDefinition(
                            in: $0,
                            chainID: chainID
                        )?.title
                    }
                )
            )

        case .poolDescription:
            let chainID = try preparePoolTask(store)
            return Target(
                identifier: "detail.description.input",
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.currentDefinition(
                            for: chainID
                        )?.descriptionText ?? ""
                    },
                    durableReadback: {
                        currentDefinition(
                            in: $0,
                            chainID: chainID
                        )?.descriptionText ?? ""
                    }
                )
            )

        case .poolNewSubtask:
            let chainID = try preparePoolTask(store)
            return Target(
                identifier:
                "pool.subtask.\(chainID.description).new.input",
                scrollsIntoView: true
            )

        case .poolExistingSubtask:
            let chainID = try preparePoolTask(store)
            store.detailSubtaskText = "初始池子任务"
            store.addPoolPlannedSubtask(chainID: chainID)
            guard let plannedID = store.currentDefinition(
                for: chainID
            )?.plannedSubtasks.first?.id else {
                throw Failure.failed("无法建立任务池已有子任务")
            }
            return Target(
                identifier:
                "pool.subtask.\(plannedID.description).title.input",
                scrollsIntoView: true,
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.currentDefinition(
                            for: chainID
                        )?.plannedSubtasks.first(
                            where: { $0.id == plannedID }
                        )?.title
                    },
                    durableReadback: {
                        currentDefinition(
                            in: $0,
                            chainID: chainID
                        )?.plannedSubtasks.first(
                            where: { $0.id == plannedID }
                        )?.title
                    }
                )
            )

        case .poolNewNote:
            _ = try preparePoolTask(store)
            return Target(
                identifier: "detail.note.composer.input",
                scrollsIntoView: true
            )

        case .poolExistingNote:
            let chainID = try preparePoolTask(store)
            store.detailNoteText = "初始池附言"
            guard store.appendPoolNote(chainID: chainID),
                  let noteID = store.currentDefinition(
                      for: chainID
                  ).flatMap({ _ in
                      store.engine.chains[chainID]?
                          .activeNoteEntries.first?.id
                  })
            else {
                throw Failure.failed("无法建立任务池已有附言")
            }
            return try await openNoteEditor(
                noteID: noteID,
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.engine.chains[chainID]?
                            .activeNoteEntries.first(
                                where: { $0.id == noteID }
                            )?.body
                    },
                    durableReadback: {
                        $0.chains[chainID]?
                            .activeNoteEntries.first(
                                where: { $0.id == noteID }
                            )?.body
                    }
                ),
                input: input
            )

        default:
            return try await prepareDaySurface(
                surface,
                store: store,
                input: input
            )
        }
    }

    private func prepareDaySurface(
        _ surface: Surface,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws -> Target {
        switch surface {
        case .dayTitle:
            let traceID = try prepareDayTask(store, future: false)
            guard let chainID = store.engine.traces[
                traceID
            ]?.chainID else {
                throw Failure.failed("Day 标题缺少任务链")
            }
            return Target(
                identifier: "detail.title.input",
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.currentDefinition(
                            for: chainID
                        )?.title
                    },
                    durableReadback: {
                        currentDefinition(
                            in: $0,
                            chainID: chainID
                        )?.title
                    }
                )
            )

        case .dayDescription:
            let traceID = try prepareDayTask(store, future: false)
            return Target(
                identifier: "detail.description.input",
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.engine.traces[
                            traceID
                        ]?.descriptionText
                    },
                    durableReadback: {
                        $0.traces[traceID]?.descriptionText
                    }
                )
            )

        case .dayNewSubtask:
            let traceID = try prepareDayTask(store, future: false)
            return Target(
                identifier: SubtaskRowSurface.dayDetail
                    .newEditorInputIdentifier(for: traceID),
                scrollsIntoView: true
            )

        case .dayExistingSubtask:
            let traceID = try prepareDayTask(store, future: false)
            store.detailSubtaskText = "初始当日子任务"
            store.addDetailSubtask(traceID: traceID)
            guard let subtaskID = store.subtasks(
                for: traceID
            ).first?.id else {
                throw Failure.failed("无法建立 Day 已有子任务")
            }
            return Target(
                identifier: SubtaskRowSurface.dayDetail
                    .titleInputIdentifier(for: subtaskID),
                scrollsIntoView: true,
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.engine.subtasks[
                            subtaskID
                        ]?.title
                    },
                    durableReadback: {
                        $0.subtasks[subtaskID]?.title
                    }
                )
            )

        case .dayNewNote:
            _ = try prepareDayTask(store, future: false)
            return Target(
                identifier: "detail.note.composer.input",
                scrollsIntoView: true
            )

        case .dayExistingNote:
            let traceID = try prepareDayTask(store, future: false)
            store.detailNoteText = "初始当日附言"
            guard store.appendTraceNote(traceID: traceID),
                  let noteID = store.engine.traces[
                      traceID
                  ]?.activeNoteEntries.first?.id
            else {
                throw Failure.failed("无法建立 Day 已有附言")
            }
            return try await openNoteEditor(
                noteID: noteID,
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.engine.traces[
                            traceID
                        ]?.activeNoteEntries.first(
                            where: { $0.id == noteID }
                        )?.body
                    },
                    durableReadback: {
                        $0.traces[traceID]?
                            .activeNoteEntries.first(
                                where: { $0.id == noteID }
                            )?.body
                    }
                ),
                input: input
            )

        default:
            return try await prepareFutureSurface(
                surface,
                store: store,
                input: input
            )
        }
    }

    private func prepareFutureSurface(
        _ surface: Surface,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws -> Target {
        switch surface {
        case .futureTitle:
            let traceID = try prepareDayTask(store, future: true)
            guard let chainID = store.engine.traces[
                traceID
            ]?.chainID else {
                throw Failure.failed("未来计划标题缺少任务链")
            }
            return Target(
                identifier: "detail.title.input",
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.currentDefinition(
                            for: chainID
                        )?.title
                    },
                    durableReadback: {
                        currentDefinition(
                            in: $0,
                            chainID: chainID
                        )?.title
                    }
                )
            )

        case .futureDescription:
            let traceID = try prepareDayTask(store, future: true)
            return Target(
                identifier: "detail.description.input",
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.engine.traces[
                            traceID
                        ]?.descriptionText
                    },
                    durableReadback: {
                        $0.traces[traceID]?.descriptionText
                    }
                )
            )

        case .futureNewNote:
            _ = try prepareDayTask(store, future: true)
            return Target(
                identifier: "detail.note.composer.input",
                scrollsIntoView: true
            )

        case .futureExistingNote:
            let traceID = try prepareDayTask(store, future: true)
            store.detailNoteText = "初始未来计划附言"
            guard store.appendTraceNote(traceID: traceID),
                  let noteID = store.engine.traces[
                      traceID
                  ]?.activeNoteEntries.first?.id
            else {
                throw Failure.failed("无法建立未来计划已有附言")
            }
            return try await openNoteEditor(
                noteID: noteID,
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.engine.traces[
                            traceID
                        ]?.activeNoteEntries.first(
                            where: { $0.id == noteID }
                        )?.body
                    },
                    durableReadback: {
                        $0.traces[traceID]?
                            .activeNoteEntries.first(
                                where: { $0.id == noteID }
                            )?.body
                    }
                ),
                input: input
            )

        default:
            return try await prepareTaskCycleSurface(
                surface,
                store: store,
                input: input
            )
        }
    }

    private func prepareTaskCycleSurface(
        _ surface: Surface,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws -> Target {
        switch surface {
        case .taskCycleCreateTitle:
            store.page = .recurring
            store.clearSelection()
            store.beginTaskCycleCreation()
            return Target(identifier: "task-cycle-create.title")

        case .taskCycleTitle:
            let seriesID = try prepareTaskCycle(store)
            return Target(
                identifier: "detail.title.input",
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.engine.taskCycleSeries[
                            seriesID
                        ]?.title
                    },
                    durableReadback: {
                        $0.taskCycleSeries[seriesID]?.title
                    }
                )
            )

        case .taskCycleDescription:
            let seriesID = try prepareTaskCycle(store)
            return Target(
                identifier: "detail.description.input",
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.engine.taskCycleSeries[
                            seriesID
                        ]?.descriptionText ?? ""
                    },
                    durableReadback: {
                        $0.taskCycleSeries[
                            seriesID
                        ]?.descriptionText ?? ""
                    }
                )
            )

        case .taskCycleNewSubtask:
            let seriesID = try prepareTaskCycle(store)
            return Target(
                identifier:
                "task-cycle-subtask.\(seriesID.description).new.input",
                scrollsIntoView: true
            )

        case .taskCycleExistingSubtask:
            let seriesID = try prepareTaskCycle(store)
            store.addTaskCyclePlannedSubtask(
                seriesID: seriesID,
                title: "初始重复子任务"
            )
            guard let plannedID = store.engine.taskCycleSeries[
                seriesID
            ]?.plannedSubtasks.first?.id else {
                throw Failure.failed("无法建立重复任务已有子任务")
            }
            return Target(
                identifier:
                "task-cycle-subtask."
                    + "\(plannedID.description).title.input",
                scrollsIntoView: true,
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.engine.taskCycleSeries[
                            seriesID
                        ]?.plannedSubtasks.first(
                            where: { $0.id == plannedID }
                        )?.title
                    },
                    durableReadback: {
                        $0.taskCycleSeries[
                            seriesID
                        ]?.plannedSubtasks.first(
                            where: { $0.id == plannedID }
                        )?.title
                    }
                )
            )

        default:
            return try await prepareReviewSurface(
                surface,
                store: store,
                input: input
            )
        }
    }

    private func prepareReviewSurface(
        _ surface: Surface,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws -> Target {
        switch surface {
        case .reviewSummary:
            prepareReview(store)
            let date = store.selectedDate
            return Target(
                identifier: "review.summary.input",
                scrollsIntoView: true,
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.engine.days[
                            date
                        ]?.reviewSummary ?? ""
                    },
                    durableReadback: {
                        $0.days[date]?.reviewSummary ?? ""
                    }
                )
            )

        case .reviewUnfinishedReason:
            prepareReview(store)
            let date = store.selectedDate
            return Target(
                identifier: "review.unfinished-reason.input",
                scrollsIntoView: true,
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.engine.days[
                            date
                        ]?.reviewUnfinishedReason ?? ""
                    },
                    durableReadback: {
                        $0.days[
                            date
                        ]?.reviewUnfinishedReason ?? ""
                    }
                )
            )

        case .reviewTomorrowNote:
            prepareReview(store)
            let date = store.selectedDate
            return Target(
                identifier: "review.tomorrow-note.input",
                scrollsIntoView: true,
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.engine.days[
                            date
                        ]?.reviewTomorrowNote ?? ""
                    },
                    durableReadback: {
                        $0.days[
                            date
                        ]?.reviewTomorrowNote ?? ""
                    }
                )
            )

        case .changeTaskTitle:
            _ = try prepareDayTask(store, future: false)
            store.changeText = ""
            store.showingChangeDialog = true
            return Target(identifier: "change-task.title.input")

        default:
            return try await prepareClassificationSurface(
                surface,
                store: store,
                input: input
            )
        }
    }

    private func prepareClassificationSurface(
        _ surface: Surface,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws -> Target {
        switch surface {
        case .classificationLabel:
            let chainID = try preparePoolTask(store)
            return Target(
                identifier:
                "classification.editor.label-input."
                    + chainID.description,
                scrollsIntoView: true
            )

        case .classificationCategoryCreate:
            let chainID = try preparePoolTask(store)
            let categoryMenu =
                "classification.editor.category.\(chainID.description)"
            try await scrollIntoView(categoryMenu)
            try await click(
                identifier: categoryMenu,
                input: input
            )
            try await Task.sleep(for: .milliseconds(80))
            // The annual fixture intentionally contains multiple categories.
            // End selects the stable final "new group" menu action without
            // depending on catalog cardinality.
            try input.postKey(keyCode: 119)
            try input.postKey(keyCode: 36)
            return Target(
                identifier:
                "classification.editor.category-create."
                    + chainID.description,
                scrollsIntoView: true
            )

        case .classificationManagerSearch:
            store.showingClassificationManager = true
            return Target(
                identifier: "classification.manager.search.field"
            )

        case .classificationManagerCreate:
            store.showingClassificationManager = true
            try await click(
                identifier: "classification.manager.create.toggle",
                input: input
            )
            return Target(
                identifier: "classification.manager.create.name"
            )

        case .classificationManagerRename:
            let item = try prepareClassificationItem(store)
            store.showingClassificationManager = true
            let actions =
                "classification.manager.actions.\(item.id)"
            try await click(identifier: actions, input: input)
            try await Task.sleep(for: .milliseconds(80))
            try input.postKey(keyCode: 125)
            try input.postKey(keyCode: 36)
            return Target(
                identifier:
                "classification.manager.rename.\(item.id)"
            )

        default:
            return try await prepareSettingsSurface(
                surface,
                store: store,
                input: input
            )
        }
    }

    private func prepareSettingsSurface(
        _ surface: Surface,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws -> Target {
        switch surface {
        case .settingsPoem:
            try showSettings()
            return Target(
                identifier: "settings.preferences.poem.text.input",
                scrollsIntoView: true,
                persistence: try persistenceProbe(
                    on: store,
                    liveReadback: {
                        store.engine.preferences
                            .settingsPoemDisplayPolicy.text
                    },
                    durableReadback: {
                        $0.preferences
                            .settingsPoemDisplayPolicy.text
                    }
                )
            )

        case .providerName:
            try showSettings()
            return Target(identifier: "settings.zhulong.provider.name")

        case .providerBaseURL:
            try showSettings()
            return Target(
                identifier: "settings.zhulong.provider.base-url"
            )

        case .providerModel:
            try showSettings()
            return Target(identifier: "settings.zhulong.provider.model")

        case .providerAPIKey:
            try showSettings()
            return Target(identifier: "settings.zhulong.provider.api-key")

        default:
            return try await prepareZhulongSessionSurface(
                surface,
                store: store,
                input: input
            )
        }
    }

    private func prepareZhulongSessionSurface(
        _ surface: Surface,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws -> Target {
        switch surface {
        case .zhulongHomeIntent:
            store.setZhulongPageEnabled(true)
            store.page = .zhulong
            store.clearSelection()
            return Target(identifier: "zhulong-home-intent.input")

        case .zhulongSessionEntry:
            store.setZhulongPageEnabled(true)
            store.page = .zhulong
            store.startZhulongWorkspaceSession(
                intent: "E2E 输入法会话"
            )
            return Target(identifier: "zhulong-session-entry.input")

        case .zhulongDecisionSupplement:
            try await prepareZhulongDecisionGate(on: store)
            return Target(
                identifier: "zhulong-decision-supplement.input",
                scrollsIntoView: true
            )

        case .zhulongDailyReviewSummary:
            let sessionID =
                try prepareZhulongDailyReview(on: store)
            return Target(
                identifier: "zhulong-daily-review.summary.input",
                scrollsIntoView: true,
                persistence: zhulongPersistenceProbe(
                    on: store,
                    sessionID: sessionID
                ) {
                    $0.dailyReviewDrafts.last?.summary ?? ""
                }
            )

        case .zhulongDailyReviewTomorrow:
            let sessionID =
                try prepareZhulongDailyReview(on: store)
            return Target(
                identifier: "zhulong-daily-review.tomorrow.input",
                scrollsIntoView: true,
                persistence: zhulongPersistenceProbe(
                    on: store,
                    sessionID: sessionID
                ) {
                    $0.dailyReviewDrafts.last?
                        .tomorrowNote ?? ""
                }
            )

        default:
            return try await prepareZhulongInlineSurface(
                surface,
                store: store,
                input: input
            )
        }
    }

    private func prepareZhulongInlineSurface(
        _ surface: Surface,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws -> Target {
        switch surface {
        case .zhulongInlineTaskTitle:
            let draft = try await prepareZhulongInlineTaskDraft(
                on: store
            )
            let itemID = draft.items[0].id
            return Target(
                identifier:
                "zhulong-inline-task."
                    + inlineTaskIdentifierSuffix(
                        itemID
                    )
                    + ".title",
                scrollsIntoView: true,
                persistence: zhulongPersistenceProbe(
                    on: store,
                    sessionID: draft.sessionID
                ) {
                    zhulongTodoValue(
                        in: $0,
                        itemID: itemID,
                        field: .title
                    )
                }
            )

        case .zhulongInlineTaskDescription:
            let draft = try await prepareZhulongInlineTaskDraft(
                on: store
            )
            let itemID = draft.items[0].id
            return Target(
                identifier:
                "zhulong-inline-task."
                    + inlineTaskIdentifierSuffix(
                        itemID
                    )
                    + ".description",
                scrollsIntoView: true,
                persistence: zhulongPersistenceProbe(
                    on: store,
                    sessionID: draft.sessionID
                ) {
                    zhulongTodoValue(
                        in: $0,
                        itemID: itemID,
                        field: .description
                    )
                }
            )

        case .zhulongInlineTaskNote:
            let draft = try await prepareZhulongInlineTaskDraft(
                on: store
            )
            let itemID = draft.items[0].id
            return Target(
                identifier:
                "zhulong-inline-task."
                    + inlineTaskIdentifierSuffix(
                        itemID
                    )
                    + ".note",
                scrollsIntoView: true,
                persistence: zhulongPersistenceProbe(
                    on: store,
                    sessionID: draft.sessionID
                ) {
                    zhulongTodoValue(
                        in: $0,
                        itemID: itemID,
                        field: .note
                    )
                }
            )

        case .zhulongInlineTaskTargetDate:
            let draft = try await prepareZhulongInlineTaskDraft(
                on: store
            )
            guard draft.items.count >= 3 else {
                throw Failure.failed(
                    "烛龙内联任务缺少未来日期输入 fixture"
                )
            }
            return Target(
                identifier:
                "zhulong-inline-task."
                    + inlineTaskIdentifierSuffix(
                        draft.items[2].id
                    )
                    + ".target-date",
                scrollsIntoView: true
            )

        case .zhulongInlineSubtaskTitle:
            let draft = try await prepareZhulongInlineTaskDraft(
                on: store
            )
            let itemID = draft.items[0].id
            return Target(
                identifier:
                "zhulong-inline-subtask."
                    + inlineTaskIdentifierSuffix(
                        itemID
                    )
                    + ".0.title",
                scrollsIntoView: true,
                persistence: zhulongPersistenceProbe(
                    on: store,
                    sessionID: draft.sessionID
                ) {
                    zhulongTodoValue(
                        in: $0,
                        itemID: itemID,
                        field: .subtask(0)
                    )
                }
            )

        default:
            return try await prepareZhulongTodoDiffSurface(
                surface,
                store: store,
                input: input
            )
        }
    }

    private func prepareZhulongTodoDiffSurface(
        _ surface: Surface,
        store: NoonmarkStore,
        input _: WindowServerInputDriver
    ) async throws -> Target {
        switch surface {
        case .zhulongTodoDiffTitle:
            let draft = try await prepareZhulongInlineTaskDraft(
                on: store
            )
            return Target(
                identifier:
                "zhulong-todo-diff-title-"
                    + draft.items[0].id.rawValue.uuidString
                    .lowercased()
                    + ".input",
                scrollsIntoView: true
            )

        case .zhulongTodoDiffTargetDate:
            let draft = try await prepareZhulongInlineTaskDraft(
                on: store
            )
            guard draft.items.count >= 3 else {
                throw Failure.failed(
                    "烛龙 Todo 变更缺少日期输入 fixture"
                )
            }
            return Target(
                identifier:
                "zhulong-todo-diff-target-date-"
                    + draft.items[2].id.rawValue.uuidString
                    .lowercased(),
                scrollsIntoView: true
            )

        default:
            throw Failure.failed(
                "未实现输入面准备流程：\(surface.rawValue)"
            )
        }
    }

    private func preparePoolTask(
        _ store: NoonmarkStore
    ) throws -> TaskChainID {
        store.page = .pool
        store.clearSelection()
        store.isDetailRailExpanded = true
        store.poolText = "E2E 输入面任务"
        store.addPoolTask()
        guard let chainID = store.selectedPoolChainID else {
            throw Failure.failed("无法建立任务池输入 fixture")
        }
        return chainID
    }

    private func prepareDayTask(
        _ store: NoonmarkStore,
        future: Bool
    ) throws -> DayTraceID {
        let chainID = try preparePoolTask(store)
        let date = future
            ? NoonmarkStore.offset(store.today, by: 2)
            : store.today
        store.schedulePoolTask(chainID, date: date)
        guard let traceID = store.selectedTraceID else {
            throw Failure.failed("无法建立 Day 输入 fixture")
        }
        store.page = future ? .future : .day
        store.selectedDate = date
        store.selectedCalendarDate = date
        store.selectTrace(traceID)
        return traceID
    }

    private func prepareTaskCycle(
        _ store: NoonmarkStore
    ) throws -> TaskCycleSeriesID {
        let title = "E2E 输入面重复任务"
        let startDate = NoonmarkStore.offset(store.today, by: 1)
        guard store.createTaskCycleSeries(
            title: title,
            startDate: startDate,
            schedule: .daily,
            endCondition: .durationDays(5)
        ), let series = store.engine.taskCycleSeries.values.first(
            where: { $0.title == title }
        ) else {
            throw Failure.failed("无法建立重复任务输入 fixture")
        }
        store.page = .recurring
        store.selectTaskCycleSeries(series.id)
        return series.id
    }

    private func prepareReview(_ store: NoonmarkStore) {
        store.page = .day
        store.selectedDate = store.today
        store.selectedCalendarDate = store.today
        store.clearSelection()
        store.isDetailRailExpanded = true
    }

    private func prepareZhulongDailyReview(
        on store: NoonmarkStore
    ) throws -> ZhulongSessionID {
        let identity = try configureDeterministicZhulong(
            on: store
        )
        let now = Date().addingTimeInterval(-10)
        store.page = .zhulong
        guard let sessionID =
            store.zhulongWorkspace.createSession(
                intent: "E2E 腾讯输入法每日复盘",
                purpose: .dailyClose,
                scopes: [.currentDayTodo],
                now: now
            ),
            store.zhulongWorkspace.authorizeCurrentSession(
                providerIdentity: identity,
                now: now.addingTimeInterval(1)
            )
        else {
            throw Failure.failed("无法建立烛龙每日复盘会话")
        }
        store.zhulongWorkspace.captureDailyClose(
            date: store.today,
            from: store.engine,
            now: now.addingTimeInterval(2)
        )
        store.zhulongWorkspace.publishDailyReviewDraft(
            summary: "初始烛龙复盘",
            tomorrowNote: "初始烛龙明日事项",
            now: now.addingTimeInterval(3)
        )
        guard store.zhulongWorkspace.selectedSession?
            .dailyReviewDrafts.last != nil
        else {
            throw Failure.failed("烛龙每日复盘草稿没有建立")
        }
        return sessionID
    }

    private func prepareZhulongDecisionGate(
        on store: NoonmarkStore
    ) async throws {
        let identity = try configureDeterministicZhulong(
            on: store
        )
        let now = Date().addingTimeInterval(-10)
        store.page = .zhulong
        guard store.zhulongWorkspace.createSession(
            intent: "E2E 腾讯输入法决策补充",
            purpose: .taskShaping,
            scopes: [.currentDayTodo],
            now: now
        ) != nil,
            store.zhulongWorkspace.authorizeCurrentSession(
                providerIdentity: identity,
                now: now.addingTimeInterval(1)
            ),
            let sourceEntryID = store.zhulongWorkspace
            .selectedSession?.entries.first?.id
        else {
            throw Failure.failed("无法建立烛龙决策会话")
        }
        let brief = try ZhulongPlanningBriefDraft(
            goal: "根治腾讯输入法输入延迟",
            successCriteria: ["所有自由文本输入面通过真实 App 门禁"],
            hardConstraints: ["不得绕过真实输入法组合态"],
            userDecisions: ["使用一年完整数据量复现"],
            delegatedActivities: [
                .taskDecomposition,
                .sequencing,
                .riskReview
            ],
            assumptions: [],
            openQuestions: [],
            dataScopes: [.currentDayTodo],
            sourceEntryIDs: [sourceEntryID]
        )
        store.zhulongWorkspace.publishPlanningBrief(
            brief,
            now: now.addingTimeInterval(2)
        )
        store.zhulongWorkspace.reviewCurrentPlanningBrief(
            now: now.addingTimeInterval(3)
        )
        store.zhulongWorkspace.delegateCurrentPlanningBrief(
            now: now.addingTimeInterval(4)
        )
        guard store.zhulongWorkspace.selectedSession?
            .activePlanningDelegation != nil
        else {
            throw Failure.failed("烛龙规划没有进入委托态")
        }
        let payload = try ZhulongProviderPayload(
            systemPrompt: "只输出当前规划协议允许的结构化结果。",
            userPrompt: "判断是否还需要更多输入延迟证据。",
            contextVersion: "tencent-ime-matrix-v1",
            scopeContent: [
                .currentDayTodo: "一年完整数据规模下的真实 App 输入证据"
            ]
        )
        await store.zhulongWorkspace.runCurrentPlanningSession(
            payload: payload,
            provider: TencentIMEDecisionGateProvider(
                configurationIdentity: identity
            )
        )
        guard store.zhulongWorkspace.selectedSession?
            .currentDecisionGate != nil
        else {
            throw Failure.failed(
                "烛龙决策补充输入面没有建立："
                    + zhulongDiagnostic(store)
            )
        }
    }

    private func prepareZhulongInlineTaskDraft(
        on store: NoonmarkStore
    ) async throws -> ZhulongTodoDiffDraft {
        let identity = try configureDeterministicZhulong(
            on: store
        )
        let now = Date().addingTimeInterval(-10)
        store.page = .zhulong
        guard store.zhulongWorkspace.createSession(
            intent: ZhulongChatE2EFixture.artifactIntent,
            purpose: .taskShaping,
            scopes: [.currentDayTodo],
            now: now
        ) != nil,
            store.zhulongWorkspace.authorizeCurrentSession(
                providerIdentity: identity,
                now: now.addingTimeInterval(1)
            )
        else {
            throw Failure.failed("无法建立烛龙内联任务会话")
        }
        let payload = try ZhulongProviderPayload(
            systemPrompt: "返回带可编辑任务草稿的会话结果。",
            userPrompt: ZhulongChatE2EFixture.artifactIntent,
            contextVersion: "tencent-ime-inline-v1",
            scopeContent: [
                .currentDayTodo: "一年完整数据规模下的今日任务"
            ]
        )
        await store.zhulongWorkspace.runCurrentSession(
            payload: payload,
            provider: ZhulongE2EConversationProvider(
                configurationIdentity: identity
            ),
            sourceSnapshot: store.engine.snapshot(),
            planningDate: store.today
        )
        guard let draft = store.zhulongWorkspace
            .selectedSession?.currentTodoDiff,
            draft.items.count == 3
        else {
            throw Failure.failed(
                "烛龙内联任务草稿没有建立："
                    + zhulongDiagnostic(store)
            )
        }
        return draft
    }

    private func configureDeterministicZhulong(
        on store: NoonmarkStore
    ) throws -> ZhulongProviderConfigurationIdentity {
        store.setZhulongPageEnabled(true)
        var draft = ZhulongProviderDraft()
        draft.displayName = "E2E 腾讯输入法 Provider"
        draft.kind = .openAICompatible
        draft.baseURL = "https://e2e.provider.example/v1"
        draft.model = "e2e-tencent-ime-v1"
        draft.enabled = true
        draft.status = .savedWithCredential
        store.zhulongProviderDraft = draft
        return try store.zhulongProviderIdentity()
    }

    private func zhulongPersistenceProbe(
        on store: NoonmarkStore,
        sessionID: ZhulongSessionID,
        readback:
        @escaping @MainActor (ZhulongSession) -> String?
    ) -> PersistenceProbe {
        let liveReadback: @MainActor () -> String? = {
            guard let session =
                store.zhulongWorkspace.sessions.first(
                    where: { $0.id == sessionID }
                )
            else {
                return nil
            }
            return readback(session)
        }
        return PersistenceProbe(
            baseline: liveReadback() ?? "",
            liveReadback: liveReadback,
            durableReadback: {
                let session = try await store
                    .zhulongWorkspace.persistedSession(
                        sessionID
                    )
                return readback(session)
            }
        )
    }

    private func zhulongTodoValue(
        in session: ZhulongSession,
        itemID: ZhulongTodoDiffItemID,
        field: ZhulongTodoField
    ) -> String? {
        guard let item = session.currentTodoDiff?
            .items.first(where: { $0.id == itemID }),
            case let .createTask(
                title,
                description,
                note,
                subtasks,
                targetDate
            ) = item.operation
        else {
            return nil
        }
        return switch field {
        case .title:
            title
        case .description:
            description ?? ""
        case .note:
            note ?? ""
        case let .subtask(index):
            subtasks.indices.contains(index)
                ? subtasks[index].title
                : nil
        case .targetDate:
            targetDate?.description ?? ""
        }
    }

    private func inlineTaskIdentifierSuffix(
        _ id: ZhulongTodoDiffItemID
    ) -> String {
        id.rawValue.uuidString.lowercased()
    }

    private func zhulongDiagnostic(
        _ store: NoonmarkStore
    ) -> String {
        guard let session =
            store.zhulongWorkspace.selectedSession
        else {
            return "session=none status="
                + String(
                    describing: store.zhulongWorkspace.status
                )
        }
        let send = session.providerSends.last
        return [
            "phase=\(session.phase.rawValue)",
            "briefs=\(session.planningBriefs.count)",
            "delegations=\(session.planningDelegations.count)",
            "sends=\(session.providerSends.count)",
            "failure=\(send?.failure?.code ?? "none")",
            "status="
                + String(
                    describing: store.zhulongWorkspace.status
                )
        ].joined(separator: " ")
    }

    private func prepareClassificationItem(
        _ store: NoonmarkStore
    ) throws -> ClassificationCatalogItemProjection {
        _ = try store.applyClassificationIntent(
            .createCategory(
                name: "E2E 待重命名分组",
                colorHex: "#D87831"
            )
        )
        guard let item = store.classificationCatalog()?
            .categories.first(where: {
                $0.name == "E2E 待重命名分组"
            })
        else {
            throw Failure.failed("无法建立待重命名分类")
        }
        return item
    }

    private func openNoteEditor(
        noteID: TaskNoteEntryID,
        persistence: PersistenceProbe,
        input: WindowServerInputDriver
    ) async throws -> Target {
        let bodyIdentifier =
            "detail.note.body.\(noteID.description)"
        try await scrollIntoView(bodyIdentifier)
        guard let body = resolvedView(
            identifier: bodyIdentifier
        ), let window = body.window else {
            throw Failure.failed("附言正文没有进入真实可见区域")
        }
        try await activate(window)
        let resolveTarget = {
            () throws -> WindowServerInputDriver.PointerCoordinate in
            guard let current = resolvedView(
                identifier: bodyIdentifier
            ), current === body else {
                throw Failure.failed("附言双击目标发生变化")
            }
            let frame = AppViewTreeE2E.frameInWindow(for: current)
            return try input.pointerCoordinate(
                windowPoint: NSPoint(
                    x: frame.midX,
                    y: frame.midY
                ),
                in: window
            )
        }
        try await postActivatedDoubleClick(
            in: window,
            input: input,
            resolveTarget: resolveTarget
        )
        return Target(
            identifier:
            "detail.note.editor.\(noteID.description).input",
            scrollsIntoView: true,
            persistence: persistence
        )
    }

    private func persistenceProbe(
        on store: NoonmarkStore,
        liveReadback: @escaping @MainActor () -> String?,
        durableReadback:
        @escaping @MainActor (NoonmarkEngine) -> String?
    ) throws -> PersistenceProbe {
        guard let databaseURL = store.databaseURL else {
            throw Failure.failed("持久化输入面没有 SQLite 数据路径")
        }
        return PersistenceProbe(
            baseline: liveReadback() ?? "",
            liveReadback: liveReadback,
            durableReadback: {
                let transferredEngine =
                    try await Task.detached {
                        ReadOnlyEngineTransfer(
                            engine:
                            try SQLiteEngineRepository(
                                databaseURL: databaseURL
                            ).load()
                        )
                    }.value
                return durableReadback(
                    transferredEngine.engine
                )
            }
        )
    }

    private func currentDefinition(
        in engine: NoonmarkEngine,
        chainID: TaskChainID
    ) -> TaskDefinition? {
        engine.definitions.values
            .filter {
                $0.chainID == chainID
                    && $0.supersededAt == nil
            }
            .max { $0.sequence < $1.sequence }
    }

    private func showSettings() throws {
        guard let app = NSApp.delegate as? NoonmarkMacApp else {
            throw Failure.failed("无法取得 App delegate 打开设置")
        }
        app.showSettingsAction(nil)
    }

    private func showQuickEntry() throws {
        guard let app = NSApp.delegate as? NoonmarkMacApp else {
            throw Failure.failed("无法取得 App delegate 打开快速输入")
        }
        app.showQuickEntryAction(nil)
    }

    private func showSearch() throws {
        guard let app = NSApp.delegate as? NoonmarkMacApp else {
            throw Failure.failed("无法取得 App delegate 打开搜索")
        }
        app.showSearchAction(nil)
    }

    private func exerciseLifecycleTermination(
        _ target: Target,
        inputSourceID: String,
        input: WindowServerInputDriver,
        store: NoonmarkStore
    ) async throws {
        guard surface.supportsLifecycleTermination,
              let persistence = target.persistence,
              let lifecycleStateURL
        else {
            throw Failure.failed(
                "\(surface.label)不是自动保存退出门禁面"
            )
        }
        let editor = try await focusedEditor(
            target,
            input: input
        )
        try await clear(editor, input: input)
        let injectsFailure = AppLaunchArguments.contains(
            "--e2e-tencent-ime-termination-inject-once"
        )
        if injectsFailure {
            guard surface.usesZhulongSidecar == false else {
                throw Failure.failed(
                    "SQLite 保存失败注入不能用于烛龙 sidecar"
                )
            }
            try store.armPersistenceFailureForE2E()
        }

        var observedMarkedText = false
        for phrase in Self.phrases {
            let previousText = editor.string
            for character in phrase {
                try input.postKey(
                    keyCode: try keyCode(for: character)
                )
            }
            try await waitUntil(
                "\(surface.label)退出门禁输入没有回显"
            ) {
                editor.string != previousText
            }
            observedMarkedText =
                observedMarkedText || editor.hasMarkedText()
            try input.postKey(keyCode: 49)
            try await waitUntil(
                "\(surface.label)退出门禁候选未提交"
            ) {
                editor.hasMarkedText() == false
                    && editor.string != previousText
            }
        }
        guard observedMarkedText else {
            throw Failure.failed(
                "\(surface.label)退出门禁没有观察到 marked text"
            )
        }
        let expected = editor.string
        guard expected.isEmpty == false else {
            throw Failure.failed(
                "\(surface.label)退出门禁最终文本为空"
            )
        }
        guard persistence.liveReadback() != expected else {
            throw Failure.failed(
                "\(surface.label)退出前已经越过 debounce，不是即时退出"
            )
        }
        let finalEchoAt =
            ProcessInfo.processInfo.systemUptime
        try writeLifecycleState(
            expected: expected,
            to: lifecycleStateURL
        )
        let quitRequestMilliseconds =
            (
                ProcessInfo.processInfo.systemUptime
                    - finalEchoAt
            ) * 1000
        guard quitRequestMilliseconds < 250 else {
            throw Failure.failed(
                "\(surface.label)退出请求没有落在 debounce 窗口内："
                    + "\(format(quitRequestMilliseconds))ms"
            )
        }
        try writeResult([
            "status=ARMED",
            "surface=\(surface.rawValue)",
            "label=\(surface.label)",
            "input_source=\(inputSourceID)",
            "marked_text=\(observedMarkedText)",
            "pending_before_quit=true",
            "quit_request_after_final_echo_ms="
                + format(quitRequestMilliseconds),
            "failure_retry=\(injectsFailure)"
        ])
        if injectsFailure {
            E2EApplicationTermination.schedule(after: 2)
        }
        NSLog(
            "Noonmark Tencent IME immediate termination requested for %@",
            surface.rawValue
        )
        E2EApplicationTermination.schedule(after: 0)
    }

    private func verifyLifecycleTermination(
        on store: NoonmarkStore
    ) async throws {
        guard surface.supportsLifecycleTermination,
              let lifecycleStateURL
        else {
            throw Failure.failed(
                "\(surface.label)缺少退出门禁状态"
            )
        }
        let expected = try readLifecycleState(
            from: lifecycleStateURL
        )
        let liveMatched: Bool
        let durableMatched: Bool
        if surface.usesZhulongSidecar {
            let liveSessions = store.zhulongWorkspace.sessions
                .filter {
                    lifecycleValueExists(
                        in: $0,
                        expected: expected
                    )
                }
            liveMatched = liveSessions.isEmpty == false
            var persistedMatched = false
            for session in liveSessions {
                let persisted = try await store
                    .zhulongWorkspace.persistedSession(
                        session.id
                    )
                if lifecycleValueExists(
                    in: persisted,
                    expected: expected
                ) {
                    persistedMatched = true
                    break
                }
            }
            durableMatched = persistedMatched
        } else {
            liveMatched = lifecycleValueExists(
                in: store.engine,
                expected: expected
            )
            guard let databaseURL = store.databaseURL else {
                throw Failure.failed(
                    "退出门禁没有 SQLite 数据路径"
                )
            }
            let transferredEngine =
                try await Task.detached {
                    ReadOnlyEngineTransfer(
                        engine:
                        try SQLiteEngineRepository(
                            databaseURL: databaseURL
                        ).load()
                    )
                }.value
            durableMatched = lifecycleValueExists(
                in: transferredEngine.engine,
                expected: expected
            )
        }
        guard liveMatched, durableMatched else {
            throw Failure.failed(
                "\(surface.label)重启后 App/持久层回读不一致："
                    + "live=\(liveMatched) "
                    + "durable=\(durableMatched)"
            )
        }
        try writeResult([
            "status=PASS",
            "surface=\(surface.rawValue)",
            "label=\(surface.label)",
            "phase=restart-readback",
            "live_readback_match=\(liveMatched)",
            "durable_readback_match=\(durableMatched)"
        ])
    }

    private func writeLifecycleState(
        expected: String,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoded = Data(expected.utf8)
            .base64EncodedString()
        try [
            "surface=\(surface.rawValue)",
            "expected_base64=\(encoded)"
        ].joined(separator: "\n")
            .appending("\n")
            .write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
    }

    private func readLifecycleState(
        from url: URL
    ) throws -> String {
        let values = try String(contentsOf: url)
            .split(separator: "\n")
            .reduce(into: [String: String]()) {
                result,
                line in
                let components = line.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard components.count == 2 else {
                    return
                }
                result[String(components[0])] =
                    String(components[1])
            }
        guard values["surface"] == surface.rawValue,
              let encoded = values["expected_base64"],
              let data = Data(base64Encoded: encoded),
              let expected = String(
                  data: data,
                  encoding: .utf8
              ),
              expected.isEmpty == false
        else {
            throw Failure.failed("退出门禁状态不可验证")
        }
        return expected
    }

    private func lifecycleValueExists(
        in engine: NoonmarkEngine,
        expected: String
    ) -> Bool {
        switch surface {
        case .poolTitle, .dayTitle, .futureTitle:
            return engine.definitions.values.contains {
                $0.supersededAt == nil
                    && $0.title == expected
            }
        case .poolDescription:
            return engine.definitions.values.contains {
                $0.supersededAt == nil
                    && $0.descriptionText == expected
            }
        case .dayDescription, .futureDescription:
            return engine.traces.values.contains {
                $0.descriptionText == expected
            }
        case .poolExistingSubtask:
            return engine.definitions.values.contains {
                $0.supersededAt == nil
                    && $0.plannedSubtasks.contains {
                        $0.title == expected
                    }
            }
        case .dayExistingSubtask:
            return engine.subtasks.values.contains {
                $0.title == expected
            }
        case .poolExistingNote:
            return engine.chains.values.contains {
                $0.activeNoteEntries.contains {
                    $0.body == expected
                }
            }
        case .dayExistingNote, .futureExistingNote:
            return engine.traces.values.contains {
                $0.activeNoteEntries.contains {
                    $0.body == expected
                }
            }
        case .taskCycleTitle:
            return engine.taskCycleSeries.values.contains {
                $0.title == expected
            }
        case .taskCycleDescription:
            return engine.taskCycleSeries.values.contains {
                $0.descriptionText == expected
            }
        case .taskCycleExistingSubtask:
            return engine.taskCycleSeries.values.contains {
                $0.plannedSubtasks.contains {
                    $0.title == expected
                }
            }
        case .reviewSummary:
            return engine.days.values.contains {
                $0.reviewSummary == expected
            }
        case .reviewUnfinishedReason:
            return engine.days.values.contains {
                $0.reviewUnfinishedReason == expected
            }
        case .reviewTomorrowNote:
            return engine.days.values.contains {
                $0.reviewTomorrowNote == expected
            }
        case .settingsPoem:
            return engine.preferences
                .settingsPoemDisplayPolicy.text == expected
        default:
            return false
        }
    }

    private func lifecycleValueExists(
        in session: ZhulongSession,
        expected: String
    ) -> Bool {
        switch surface {
        case .zhulongDailyReviewSummary:
            return session.dailyReviewDrafts.last?
                .summary == expected
        case .zhulongDailyReviewTomorrow:
            return session.dailyReviewDrafts.last?
                .tomorrowNote == expected
        case .zhulongInlineTaskTitle,
             .zhulongInlineTaskDescription,
             .zhulongInlineTaskNote,
             .zhulongInlineSubtaskTitle:
            guard let items =
                session.currentTodoDiff?.items
            else {
                return false
            }
            return items.contains { item in
                guard case let .createTask(
                    title,
                    description,
                    note,
                    subtasks,
                    _
                ) = item.operation
                else {
                    return false
                }
                switch surface {
                case .zhulongInlineTaskTitle:
                    return title == expected
                case .zhulongInlineTaskDescription:
                    return description == expected
                case .zhulongInlineTaskNote:
                    return note == expected
                case .zhulongInlineSubtaskTitle:
                    return subtasks.contains {
                        $0.title == expected
                    }
                default:
                    return false
                }
            }
        default:
            return false
        }
    }

    private func measure(
        _ target: Target,
        input: WindowServerInputDriver
    ) async throws -> Measurement {
        if target.scrollsIntoView {
            try await scrollIntoView(target.identifier)
        }
        let editor = try await focusedEditor(
            target,
            input: input
        )
        try await clear(editor, input: input)

        var latencies: [Double] = []
        var keyPostLatencies: [Double] = []
        var echoWaitLatencies: [Double] = []
        var eventDeliveryLatencies: [Double] = []
        var eventToEchoLatencies: [Double] = []
        var eventToKeyDownLatencies: [Double] = []
        var keyDownMarkedTextQueryLatencies:
            [Double] = []
        var keyDownPreSuperLatencies: [Double] = []
        var keyDownSuperLatencies: [Double] = []
        var keyDownSetMarkedTextLatencies:
            [Double] = []
        var keyDownInsertTextLatencies: [Double] = []
        var keyDownDidChangeTextLatencies:
            [Double] = []
        var keyDownCompositionCallbackLatencies:
            [Double] = []
        var keyDownNativeSnapshotCallbackLatencies:
            [Double] = []
        var latencyLabels: [String] = []
        var observedMarkedText = false
        var prematurePersistCount = 0
        var keyDownSequence = 0
        var latestKeyDownAt: TimeInterval?
        var markdownKeyDownSequence = 0
        var latestMarkdownKeyDownTiming:
            MarkdownEditorKeyDownTiming?
        let keyDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            keyDownSequence &+= 1
            latestKeyDownAt =
                ProcessInfo.processInfo.systemUptime
            return event
        }
        let previousMarkdownKeyDownObserver =
            MarkdownEditorKeyDownTimingProbe.observer
        MarkdownEditorKeyDownTimingProbe.observer = {
            timing in
            markdownKeyDownSequence &+= 1
            latestMarkdownKeyDownTiming = timing
        }
        defer {
            MarkdownEditorKeyDownTimingProbe.observer =
                previousMarkdownKeyDownObserver
            if let keyDownMonitor {
                NSEvent.removeMonitor(keyDownMonitor)
            }
        }
        for (phraseIndex, phrase) in Self.phrases.enumerated() {
            for (characterIndex, character) in phrase
                .enumerated()
            {
                let previousText = editor.string
                let previousKeyDownSequence =
                    keyDownSequence
                let previousMarkdownKeyDownSequence =
                    markdownKeyDownSequence
                let startedAt = ProcessInfo.processInfo.systemUptime
                try input.postKey(keyCode: try keyCode(for: character))
                let postedAt = ProcessInfo.processInfo.systemUptime
                try await waitUntil(
                    "\(surface.label)按键 \(character) 没有回显"
                ) {
                    editor.string != previousText
                }
                let echoedAt = ProcessInfo.processInfo.systemUptime
                editor.window?.displayIfNeeded()
                let latency =
                    (
                        echoedAt - startedAt
                    ) * 1000
                latencies.append(latency)
                keyPostLatencies.append(
                    (postedAt - startedAt) * 1000
                )
                echoWaitLatencies.append(
                    (echoedAt - postedAt) * 1000
                )
                let arrivedAt =
                    keyDownSequence > previousKeyDownSequence
                        ? latestKeyDownAt
                        : nil
                let markdownTiming =
                    markdownKeyDownSequence
                        > previousMarkdownKeyDownSequence
                        ? latestMarkdownKeyDownTiming
                        : nil
                eventDeliveryLatencies.append(
                    arrivedAt.map {
                        max(0, ($0 - postedAt) * 1000)
                    } ?? .nan
                )
                eventToEchoLatencies.append(
                    arrivedAt.map {
                        max(0, (echoedAt - $0) * 1000)
                    } ?? .nan
                )
                eventToKeyDownLatencies.append(
                    arrivedAt.flatMap { eventArrivedAt in
                        markdownTiming.map {
                            max(
                                0,
                                (
                                    $0.enteredAt
                                        - eventArrivedAt
                                ) * 1000
                            )
                        }
                    } ?? .nan
                )
                keyDownMarkedTextQueryLatencies.append(
                    markdownTiming?
                        .markedTextQueryMilliseconds
                        ?? .nan
                )
                keyDownPreSuperLatencies.append(
                    markdownTiming?
                        .preSuperMilliseconds
                        ?? .nan
                )
                keyDownSuperLatencies.append(
                    markdownTiming?
                        .superKeyDownMilliseconds
                        ?? .nan
                )
                keyDownSetMarkedTextLatencies.append(
                    markdownTiming?
                        .setMarkedTextMilliseconds
                        ?? .nan
                )
                keyDownInsertTextLatencies.append(
                    markdownTiming?
                        .insertTextMilliseconds
                        ?? .nan
                )
                keyDownDidChangeTextLatencies.append(
                    markdownTiming?
                        .didChangeTextMilliseconds
                        ?? .nan
                )
                keyDownCompositionCallbackLatencies
                    .append(
                        markdownTiming?
                            .compositionCallbackMilliseconds
                            ?? .nan
                    )
                keyDownNativeSnapshotCallbackLatencies
                    .append(
                        markdownTiming?
                            .nativeSnapshotCallbackMilliseconds
                            ?? .nan
                    )
                latencyLabels.append(
                    "\(phraseIndex + 1):"
                        + "\(characterIndex + 1):"
                        + String(character)
                )
                observedMarkedText =
                    observedMarkedText || editor.hasMarkedText()
                prematurePersistCount +=
                    prematurePersistenceCount(
                        editor: editor,
                        persistence: target.persistence
                    )
            }
            try input.postKey(keyCode: 49)
            try await waitUntil("\(surface.label)候选未提交") {
                editor.hasMarkedText() == false
            }
        }

        try await clear(editor, input: input)
        let burstBaseline = editor.string
        let burstStartedAt =
            ProcessInfo.processInfo.systemUptime
        for character in Self.burstPhrase {
            try input.postKey(keyCode: try keyCode(for: character))
        }
        try await waitUntil(
            surface.expectsMarkedText
                ? "\(surface.label)连续输入未进入组合态"
                : "\(surface.label)安全输入没有回显完整按键"
        ) {
            if surface.expectsMarkedText {
                return editor.hasMarkedText()
                    && editor.string.isEmpty == false
            }
            return editor.string.utf16.count
                >= burstBaseline.utf16.count
                    + Self.burstPhrase.utf16.count
        }
        try input.postKey(keyCode: 49)
        try await waitUntil("\(surface.label)连续输入未提交") {
            editor.hasMarkedText() == false
                && editor.string.isEmpty == false
        }
        editor.window?.displayIfNeeded()
        let burstTotalMilliseconds =
            (
                ProcessInfo.processInfo.systemUptime
                    - burstStartedAt
            ) * 1000
        var persistenceOverlapLatencies: [Double] = []
        var persistenceOverlapKeyPostLatencies: [Double] = []
        var persistenceOverlapEchoWaitLatencies: [Double] = []
        if target.persistence != nil {
            try await Task.sleep(for: .milliseconds(740))
            for phrase in Self.persistenceOverlapPhrases {
                for character in phrase {
                    let previousText = editor.string
                    let startedAt =
                        ProcessInfo.processInfo.systemUptime
                    try input.postKey(
                        keyCode: try keyCode(
                            for: character
                        )
                    )
                    let postedAt =
                        ProcessInfo.processInfo.systemUptime
                    try await waitUntil(
                        "\(surface.label)后台保存重叠按键 "
                            + "\(character) 没有回显"
                    ) {
                        editor.string != previousText
                    }
                    let echoedAt =
                        ProcessInfo.processInfo.systemUptime
                    editor.window?.displayIfNeeded()
                    persistenceOverlapLatencies.append(
                        (echoedAt - startedAt) * 1000
                    )
                    persistenceOverlapKeyPostLatencies.append(
                        (postedAt - startedAt) * 1000
                    )
                    persistenceOverlapEchoWaitLatencies.append(
                        (echoedAt - postedAt) * 1000
                    )
                    observedMarkedText =
                        observedMarkedText
                            || editor.hasMarkedText()
                    prematurePersistCount +=
                        prematurePersistenceCount(
                            editor: editor,
                            persistence:
                            target.persistence
                        )
                }
                try input.postKey(keyCode: 49)
                try await waitUntil(
                    "\(surface.label)后台保存重叠候选未提交"
                ) {
                    editor.hasMarkedText() == false
                }
            }
        }
        let finalText = editor.string

        let sorted = latencies.sorted()
        guard sorted.isEmpty == false else {
            throw Failure.failed("\(surface.label)没有回显样本")
        }
        let p50Milliseconds = percentile(0.50, in: sorted)
        let p95Milliseconds = percentile(0.95, in: sorted)
        let maximumMilliseconds = sorted[sorted.count - 1]
        let eventDeliveryP95Milliseconds =
            finitePercentile(
                0.95,
                in: eventDeliveryLatencies
            )
        let eventToKeyDownP95Milliseconds =
            finitePercentile(
                0.95,
                in: eventToKeyDownLatencies
            )
        let keyDownMarkedTextQueryP95Milliseconds =
            finitePercentile(
                0.95,
                in: keyDownMarkedTextQueryLatencies
            )
        let keyDownPreSuperP95Milliseconds =
            finitePercentile(
                0.95,
                in: keyDownPreSuperLatencies
            )
        let keyDownSuperP95Milliseconds =
            finitePercentile(
                0.95,
                in: keyDownSuperLatencies
            )
        let keyDownSetMarkedTextP95Milliseconds =
            finitePercentile(
                0.95,
                in: keyDownSetMarkedTextLatencies
            )
        let keyDownInsertTextP95Milliseconds =
            finitePercentile(
                0.95,
                in: keyDownInsertTextLatencies
            )
        let keyDownDidChangeTextP95Milliseconds =
            finitePercentile(
                0.95,
                in: keyDownDidChangeTextLatencies
            )
        let keyDownCompositionCallbackP95Milliseconds =
            finitePercentile(
                0.95,
                in: keyDownCompositionCallbackLatencies
            )
        let keyDownNativeSnapshotCallbackP95Milliseconds =
            finitePercentile(
                0.95,
                in:
                keyDownNativeSnapshotCallbackLatencies
            )
        let eventToEchoP95Milliseconds =
            finitePercentile(
                0.95,
                in: eventToEchoLatencies
            )
        let persistenceOverlapSorted =
            persistenceOverlapLatencies.sorted()
        let persistenceOverlapP95Milliseconds =
            persistenceOverlapSorted.isEmpty
                ? nil
                : percentile(
                    0.95,
                    in: persistenceOverlapSorted
                )
        let persistenceOverlapMaximumMilliseconds =
            persistenceOverlapSorted.last
        let persistenceOverlapKeyPostP95Milliseconds =
            persistenceOverlapKeyPostLatencies.isEmpty
                ? .nan
                : percentile(
                    0.95,
                    in: persistenceOverlapKeyPostLatencies
                        .sorted()
                )
        let persistenceOverlapEchoWaitP95Milliseconds =
            persistenceOverlapEchoWaitLatencies.isEmpty
                ? .nan
                : percentile(
                    0.95,
                    in: persistenceOverlapEchoWaitLatencies
                        .sorted()
                )
        guard surface.expectsMarkedText == false
            || observedMarkedText
        else {
            throw Failure.failed(
                "\(surface.label)没有观察到腾讯拼音 marked text"
            )
        }
        guard p95Milliseconds
            <= Self.p95LimitMilliseconds,
            maximumMilliseconds
            <= Self.maximumLimitMilliseconds,
            burstTotalMilliseconds
            <= Self.burstLimitMilliseconds
        else {
            let slowestIndex = latencies.indices.max {
                latencies[$0] < latencies[$1]
            }
            let slowestLabel = slowestIndex.map {
                latencyLabels[$0]
            } ?? "n/a"
            let slowestPost = slowestIndex.map {
                keyPostLatencies[$0]
            } ?? .nan
            let slowestEchoWait = slowestIndex.map {
                echoWaitLatencies[$0]
            } ?? .nan
            let slowestEventDelivery = slowestIndex.map {
                eventDeliveryLatencies[$0]
            } ?? .nan
            let slowestEventToEcho = slowestIndex.map {
                eventToEchoLatencies[$0]
            } ?? .nan
            let slowestEventToKeyDown = slowestIndex.map {
                eventToKeyDownLatencies[$0]
            } ?? .nan
            let slowestMarkedTextQuery = slowestIndex.map {
                keyDownMarkedTextQueryLatencies[$0]
            } ?? .nan
            let slowestPreSuper = slowestIndex.map {
                keyDownPreSuperLatencies[$0]
            } ?? .nan
            let slowestSuper = slowestIndex.map {
                keyDownSuperLatencies[$0]
            } ?? .nan
            let slowestSetMarkedText = slowestIndex.map {
                keyDownSetMarkedTextLatencies[$0]
            } ?? .nan
            let slowestInsertText = slowestIndex.map {
                keyDownInsertTextLatencies[$0]
            } ?? .nan
            let slowestDidChangeText = slowestIndex.map {
                keyDownDidChangeTextLatencies[$0]
            } ?? .nan
            let slowestCompositionCallback =
                slowestIndex.map {
                    keyDownCompositionCallbackLatencies[
                        $0
                    ]
                } ?? .nan
            let slowestNativeSnapshotCallback =
                slowestIndex.map {
                    keyDownNativeSnapshotCallbackLatencies[
                        $0
                    ]
                } ?? .nan
            throw Failure.failed(
                "\(surface.label)回显超过硬阈值："
                    + "p95=\(format(p95Milliseconds))ms "
                    + "max=\(format(maximumMilliseconds))ms "
                    + "burst=\(format(burstTotalMilliseconds))ms "
                    + "slowest_key=\(slowestLabel) "
                    + "post=\(format(slowestPost))ms "
                    + "echo_wait=\(format(slowestEchoWait))ms "
                    + "event_delivery="
                    + "\(format(slowestEventDelivery))ms "
                    + "event_to_key_down="
                    + "\(format(slowestEventToKeyDown))ms "
                    + "marked_query="
                    + "\(format(slowestMarkedTextQuery))ms "
                    + "pre_super="
                    + "\(format(slowestPreSuper))ms "
                    + "super_key_down="
                    + "\(format(slowestSuper))ms "
                    + "set_marked_text="
                    + "\(format(slowestSetMarkedText))ms "
                    + "insert_text="
                    + "\(format(slowestInsertText))ms "
                    + "did_change_text="
                    + "\(format(slowestDidChangeText))ms "
                    + "composition_callback="
                    + "\(format(slowestCompositionCallback))ms "
                    + "native_snapshot_callback="
                    + "\(format(slowestNativeSnapshotCallback))ms "
                    + "event_to_echo="
                    + "\(format(slowestEventToEcho))ms"
            )
        }
        if let persistenceOverlapP95Milliseconds,
           let persistenceOverlapMaximumMilliseconds,

               persistenceOverlapP95Milliseconds
                   > Self.p95LimitMilliseconds
                   || persistenceOverlapMaximumMilliseconds
                   > Self.maximumLimitMilliseconds

        {
            throw Failure.failed(
                "\(surface.label)后台自动保存期间回显超过硬阈值："
                    + "p95="
                    + "\(format(persistenceOverlapP95Milliseconds))ms "
                    + "max="
                    + "\(format(persistenceOverlapMaximumMilliseconds))ms "
                    + "post_p95="
                    + "\(format(persistenceOverlapKeyPostP95Milliseconds))ms "
                    + "echo_wait_p95="
                    + "\(format(persistenceOverlapEchoWaitP95Milliseconds))ms"
            )
        }

        var durableMilliseconds: Double?
        var durableReadbackProbeMilliseconds: Double?
        var liveReadbackMatched = true
        var durableReadbackMatched = true
        if let persistence = target.persistence {
            guard prematurePersistCount == 0 else {
                throw Failure.failed(
                    "\(surface.label)把 marked text 提前写进领域模型"
                )
            }
            let durableStartedAt =
                ProcessInfo.processInfo.systemUptime
            guard let window = editor.window,
                  window.makeFirstResponder(nil)
            else {
                throw Failure.failed(
                    "\(surface.label)无法通过真实失焦路径提交"
                )
            }
            try await waitUntil(
                "\(surface.label)领域模型没有追上最终文本"
            ) {
                persistence.liveReadback() == finalText
            }
            let durableElapsed =
                (
                    ProcessInfo.processInfo.systemUptime
                        - durableStartedAt
                ) * 1000
            liveReadbackMatched =
                persistence.liveReadback() == finalText
            let readbackStartedAt =
                ProcessInfo.processInfo.systemUptime
            let durableValue =
                try await persistence.durableReadback()
            durableReadbackProbeMilliseconds =
                (
                    ProcessInfo.processInfo.systemUptime
                        - readbackStartedAt
                ) * 1000
            durableReadbackMatched =
                durableValue == finalText
            guard durableReadbackMatched else {
                throw Failure.failed(
                    "\(surface.label) SQLite 回读不等于最终文本"
                )
            }
            durableMilliseconds = durableElapsed
            guard durableElapsed
                <= Self.durableLimitMilliseconds
            else {
                throw Failure.failed(
                    "\(surface.label)持久化超过硬阈值："
                        + "\(format(durableElapsed))ms"
                )
            }
        }
        return Measurement(
            latencies: latencies,
            p50Milliseconds: p50Milliseconds,
            p95Milliseconds: p95Milliseconds,
            maximumMilliseconds: maximumMilliseconds,
            eventDeliveryP95Milliseconds:
            eventDeliveryP95Milliseconds,
            eventToKeyDownP95Milliseconds:
            eventToKeyDownP95Milliseconds,
            keyDownMarkedTextQueryP95Milliseconds:
            keyDownMarkedTextQueryP95Milliseconds,
            keyDownPreSuperP95Milliseconds:
            keyDownPreSuperP95Milliseconds,
            keyDownSuperP95Milliseconds:
            keyDownSuperP95Milliseconds,
            keyDownSetMarkedTextP95Milliseconds:
            keyDownSetMarkedTextP95Milliseconds,
            keyDownInsertTextP95Milliseconds:
            keyDownInsertTextP95Milliseconds,
            keyDownDidChangeTextP95Milliseconds:
            keyDownDidChangeTextP95Milliseconds,
            keyDownCompositionCallbackP95Milliseconds:
            keyDownCompositionCallbackP95Milliseconds,
            keyDownNativeSnapshotCallbackP95Milliseconds:
            keyDownNativeSnapshotCallbackP95Milliseconds,
            eventToEchoP95Milliseconds:
            eventToEchoP95Milliseconds,
            burstTotalMilliseconds: burstTotalMilliseconds,
            persistenceOverlapP95Milliseconds:
            persistenceOverlapP95Milliseconds,
            persistenceOverlapMaximumMilliseconds:
            persistenceOverlapMaximumMilliseconds,
            observedMarkedText: observedMarkedText,
            prematurePersistCount: prematurePersistCount,
            durableMilliseconds: durableMilliseconds,
            durableReadbackProbeMilliseconds:
            durableReadbackProbeMilliseconds,
            liveReadbackMatched: liveReadbackMatched,
            durableReadbackMatched:
            durableReadbackMatched
        )
    }

    private func prematurePersistenceCount(
        editor: NSTextView,
        persistence: PersistenceProbe?
    ) -> Int {
        guard editor.hasMarkedText(),
              let persistence,
              editor.string != persistence.baseline,
              persistence.liveReadback() == editor.string
        else {
            return 0
        }
        return 1
    }

    private func focusedEditor(
        _ target: Target,
        input: WindowServerInputDriver
    ) async throws -> NSTextView {
        let identifier = target.identifier
        if let windowIdentifier =
            target.preFocusedWindowIdentifier
        {
            var focusedWindow: NSWindow?
            try await waitUntil(
                "预聚焦输入窗口没有出现：\(identifier)"
            ) {
                let windows = NSApp.windows.filter {
                    $0.identifier == windowIdentifier
                        && $0.isVisible
                        && $0.isMiniaturized == false
                }
                guard windows.count == 1 else { return false }
                focusedWindow = windows[0]
                return true
            }
            guard let focusedWindow else {
                throw Failure.failed(
                    "预聚焦输入窗口消失：\(identifier)"
                )
            }
            try await activate(focusedWindow)
            var consecutiveReadySamples = 0
            for _ in 0 ..< 150 {
                let isFrontmost =
                    NSWorkspace.shared.frontmostApplication?
                        .processIdentifier
                        == ProcessInfo.processInfo
                        .processIdentifier
                if NSApp.isActive,
                   focusedWindow.isKeyWindow,
                   isFrontmost,
                   let editor =
                   focusedWindow.firstResponder
                   as? NSTextView
                {
                    consecutiveReadySamples += 1
                    if consecutiveReadySamples >= 3 {
                        return editor
                    }
                } else {
                    consecutiveReadySamples = 0
                }
                try await Task.sleep(
                    for: .milliseconds(20)
                )
            }
            throw Failure.failed(
                "预聚焦输入控件没有连续稳定成为 first responder："
                    + identifier
            )
        }
        var identifiedView: NSView?
        try await waitUntil(
            "找不到真实输入控件：\(identifier)"
        ) {
            identifiedView = resolvedView(
                identifier: identifier
            )
            return identifiedView != nil
        }
        guard let identifiedView,
              let window = identifiedView.window
        else {
            throw Failure.failed("输入控件在聚焦前消失：\(identifier)")
        }
        try await activate(window)
        let resolveTarget = {
            () throws -> WindowServerInputDriver.PointerCoordinate in
            guard let current = resolvedView(
                identifier: identifier
            ), current.window === window else {
                throw Failure.failed(
                    "输入控件点击目标发生变化：\(identifier)"
                )
            }
            let clickTarget = clickableView(for: current)
            guard clickTarget.window === window,
                  clickTarget.isHiddenOrHasHiddenAncestor == false
            else {
                throw Failure.failed(
                    "输入控件点击目标发生变化：\(identifier)"
                )
            }
            let frame = AppViewTreeE2E.frameInWindow(
                for: clickTarget
            )
            let visibleFrame = clickTarget.convert(
                clickTarget.visibleRect,
                to: nil
            )
            let clickableFrame = frame.intersection(
                visibleFrame
            )
            guard clickableFrame.isNull == false,
                  clickableFrame.isEmpty == false
            else {
                throw Failure.failed(
                    "输入控件没有可点击的可见区域："
                        + identifier
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
        try await postActivatedClick(
            in: window,
            input: input,
            resolveTarget: resolveTarget
        )
        try await Task.sleep(for: .milliseconds(20))
        if window.firstResponder as? NSTextView == nil,
           let textView = identifiedView as? NSTextView
        {
            _ = window.makeFirstResponder(textView)
        }
        var editor: NSTextView?
        try await waitUntil(
            "输入控件没有成为 first responder：\(identifier)"
        ) {
            editor = window.firstResponder as? NSTextView
            return editor != nil
        }
        guard let editor else {
            throw Failure.failed("系统 field editor 消失：\(identifier)")
        }
        return editor
    }

    private func clickableView(
        for identifiedView: NSView
    ) -> NSView {
        if identifiedView is NSTextView
            || identifiedView is NSTextField
        {
            return identifiedView
        }
        return AppViewTreeE2E.textField(
            overlapping: identifiedView
        ) ?? identifiedView
    }

    private func click(
        identifier: String,
        input: WindowServerInputDriver
    ) async throws {
        try await scrollIntoView(identifier)
        guard let view = resolvedView(identifier: identifier),
              let window = view.window
        else {
            throw Failure.failed("找不到点击目标：\(identifier)")
        }
        try await activate(window)
        let resolveTarget = {
            () throws -> WindowServerInputDriver.PointerCoordinate in
            guard let current = resolvedView(
                identifier: identifier
            ), current.window === window else {
                throw Failure.failed(
                    "点击目标发生变化：\(identifier)"
                )
            }
            let frame = AppViewTreeE2E.frameInWindow(for: current)
            return try input.pointerCoordinate(
                windowPoint: NSPoint(
                    x: frame.midX,
                    y: frame.midY
                ),
                in: window
            )
        }
        try await postActivatedClick(
            in: window,
            input: input,
            resolveTarget: resolveTarget
        )
    }

    private func activate(_ window: NSWindow) async throws {
        var consecutiveReadySamples = 0
        for _ in 0 ..< 150 {
            window.makeKeyAndOrderFront(nil)
            if window.canBecomeMain {
                window.makeMain()
            }
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(
                options: [.activateAllWindows]
            )
            let isFrontmost =
                NSWorkspace.shared.frontmostApplication?
                .processIdentifier
                == ProcessInfo.processInfo.processIdentifier
            if NSApp.isActive,
               window.isKeyWindow,
               isFrontmost
            {
                consecutiveReadySamples += 1
                if consecutiveReadySamples >= 3 {
                    return
                }
            } else {
                consecutiveReadySamples = 0
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.failed("输入控件所属窗口无法激活")
    }

    private func postActivatedClick(
        in window: NSWindow,
        input: WindowServerInputDriver,
        resolveTarget:
        () throws -> WindowServerInputDriver.PointerCoordinate
    ) async throws {
        for attempt in 0 ..< 3 {
            try await activate(window)
            do {
                try await input.postClick(
                    at: try resolveTarget(),
                    modifiers: [],
                    resolveTarget: resolveTarget
                )
                return
            } catch {
                guard attempt < 2,
                      isActivationInterruption(error)
                else {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func postActivatedDoubleClick(
        in window: NSWindow,
        input: WindowServerInputDriver,
        resolveTarget:
        () throws -> WindowServerInputDriver.PointerCoordinate
    ) async throws {
        for attempt in 0 ..< 3 {
            try await activate(window)
            do {
                try await input.postDoubleClick(
                    at: try resolveTarget(),
                    modifiers: [],
                    resolveTarget: resolveTarget
                )
                return
            } catch {
                guard attempt < 2,
                      isActivationInterruption(error)
                else {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func isActivationInterruption(
        _ error: Error
    ) -> Bool {
        guard let failure =
            error as? WindowServerInputDriver.Failure
        else {
            return false
        }
        guard case let .inputContextUnavailable(report) =
            failure
        else {
            return false
        }
        return report.expectedWindowVisible
            && report.expectedWindowMiniaturized == false
            && (
                report.appActive == false
                    || report.expectedWindowIsKey == false
            )
    }

    private func scrollIntoView(
        _ identifier: String
    ) async throws {
        for _ in 0 ..< 100 {
            let target = resolvedView(
                identifier: identifier
            ) ?? AppViewTreeE2E.attachedView(
                identifier: identifier
            )
            if let target {
                target.scrollToVisible(target.bounds)
                target.window?.contentView?
                    .layoutSubtreeIfNeeded()
                let frame = AppViewTreeE2E.frameInWindow(
                    for: target
                )
                if target.isHiddenOrHasHiddenAncestor == false,
                   target.visibleRect.intersects(
                       target.bounds
                   ),
                   let contentBounds =
                   target.window?.contentView?.bounds,
                   frame.intersects(contentBounds)
                {
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.failed("控件没有进入可见区域：\(identifier)")
    }

    private func resolvedView(identifier: String) -> NSView? {
        let matches = NSApp.windows.compactMap { window in
            AppViewTreeE2E.view(
                identifier: identifier,
                in: window
            )
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func clear(
        _ editor: NSTextView,
        input: WindowServerInputDriver
    ) async throws {
        if editor.string.isEmpty, editor.hasMarkedText() == false {
            return
        }
        guard let window = editor.window else {
            throw Failure.failed("编辑器没有所属窗口")
        }
        try await activate(window)
        guard window.firstResponder === editor else {
            throw Failure.failed("清空前编辑器失去焦点")
        }
        try input.postKey(keyCode: 0, modifiers: .command)
        try input.postKey(keyCode: 51)
        try await waitUntil("编辑器没有完成清空") {
            editor.string.isEmpty
                && editor.hasMarkedText() == false
        }
    }

    private func waitUntil(
        _ failure: String,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< 600 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure.failed(failure)
    }

    private func currentInputSourceID() throws -> String {
        let source = TISCopyCurrentKeyboardInputSource()
            .takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceID
        ) else {
            throw Failure.failed("无法读取当前输入源身份")
        }
        return Unmanaged<CFString>
            .fromOpaque(pointer)
            .takeUnretainedValue() as String
    }

    private func keyCode(
        for character: Character
    ) throws -> CGKeyCode {
        let codes: [Character: CGKeyCode] = [
            "a": 0,
            "c": 8,
            "e": 14,
            "f": 3,
            "h": 4,
            "i": 34,
            "j": 38,
            "m": 46,
            "n": 45,
            "o": 31,
            "r": 15,
            "s": 1,
            "u": 32,
            "w": 13
        ]
        guard let code = codes[character] else {
            throw Failure.failed("缺少按键映射：\(character)")
        }
        return code
    }

    private func percentile(
        _ percentile: Double,
        in sorted: [Double]
    ) -> Double {
        let index = max(
            0,
            Int(ceil(Double(sorted.count) * percentile)) - 1
        )
        return sorted[index]
    }

    private func finitePercentile(
        _ percentile: Double,
        in values: [Double]
    ) -> Double? {
        let sorted = values
            .filter(\.isFinite)
            .sorted()
        guard sorted.isEmpty == false else {
            return nil
        }
        return self.percentile(
            percentile,
            in: sorted
        )
    }

    private func writeResult(_ lines: [String]) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(
            to: resultURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func formatOptional(
        _ value: Double?
    ) -> String {
        value.map(format) ?? "n/a"
    }

    private func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
    }

    private struct Target {
        let identifier: String
        var scrollsIntoView = false
        var preFocusedWindowIdentifier:
            NSUserInterfaceItemIdentifier?
        var persistence: PersistenceProbe?
    }

    private struct PersistenceProbe {
        let baseline: String
        let liveReadback:
            @MainActor () -> String?
        let durableReadback:
            @MainActor () async throws -> String?
    }

    private struct ReadOnlyEngineTransfer: @unchecked Sendable {
        let engine: NoonmarkEngine
    }

    private enum ZhulongTodoField {
        case title
        case description
        case note
        case targetDate
        case subtask(Int)
    }

    private struct Measurement {
        let latencies: [Double]
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let maximumMilliseconds: Double
        let eventDeliveryP95Milliseconds: Double?
        let eventToKeyDownP95Milliseconds: Double?
        let keyDownMarkedTextQueryP95Milliseconds:
            Double?
        let keyDownPreSuperP95Milliseconds: Double?
        let keyDownSuperP95Milliseconds: Double?
        let keyDownSetMarkedTextP95Milliseconds:
            Double?
        let keyDownInsertTextP95Milliseconds: Double?
        let keyDownDidChangeTextP95Milliseconds:
            Double?
        let keyDownCompositionCallbackP95Milliseconds:
            Double?
        let keyDownNativeSnapshotCallbackP95Milliseconds:
            Double?
        let eventToEchoP95Milliseconds: Double?
        let burstTotalMilliseconds: Double
        let persistenceOverlapP95Milliseconds: Double?
        let persistenceOverlapMaximumMilliseconds: Double?
        let observedMarkedText: Bool
        let prematurePersistCount: Int
        let durableMilliseconds: Double?
        let durableReadbackProbeMilliseconds: Double?
        let liveReadbackMatched: Bool
        let durableReadbackMatched: Bool
    }

    private enum LifecyclePhase: String {
        case exercise
        case verify
    }

    private enum Surface: String {
        case dayQuickAdd = "day-quick-add"
        case futureQuickAdd = "future-quick-add"
        case poolQuickAdd = "pool-quick-add"
        case railSearch = "rail-search"
        case quickEntry = "quick-entry"
        case globalSearch = "global-search"
        case poolTitle = "pool-title"
        case poolDescription = "pool-description"
        case poolNewSubtask = "pool-new-subtask"
        case poolExistingSubtask = "pool-existing-subtask"
        case poolNewNote = "pool-new-note"
        case poolExistingNote = "pool-existing-note"
        case dayTitle = "day-title"
        case dayDescription = "day-description"
        case dayNewSubtask = "day-new-subtask"
        case dayExistingSubtask = "day-existing-subtask"
        case dayNewNote = "day-new-note"
        case dayExistingNote = "day-existing-note"
        case futureTitle = "future-title"
        case futureDescription = "future-description"
        case futureNewNote = "future-new-note"
        case futureExistingNote = "future-existing-note"
        case taskCycleCreateTitle = "task-cycle-create-title"
        case taskCycleTitle = "task-cycle-title"
        case taskCycleDescription = "task-cycle-description"
        case taskCycleNewSubtask = "task-cycle-new-subtask"
        case taskCycleExistingSubtask =
            "task-cycle-existing-subtask"
        case reviewSummary = "review-summary"
        case reviewUnfinishedReason = "review-unfinished-reason"
        case reviewTomorrowNote = "review-tomorrow-note"
        case changeTaskTitle = "change-task-title"
        case classificationLabel = "classification-label"
        case classificationCategoryCreate =
            "classification-category-create"
        case classificationManagerSearch =
            "classification-manager-search"
        case classificationManagerCreate =
            "classification-manager-create"
        case classificationManagerRename =
            "classification-manager-rename"
        case settingsPoem = "settings-poem"
        case providerName = "provider-name"
        case providerBaseURL = "provider-base-url"
        case providerModel = "provider-model"
        case providerAPIKey = "provider-api-key"
        case zhulongHomeIntent = "zhulong-home-intent"
        case zhulongSessionEntry = "zhulong-session-entry"
        case zhulongDecisionSupplement =
            "zhulong-decision-supplement"
        case zhulongDailyReviewSummary =
            "zhulong-daily-review-summary"
        case zhulongDailyReviewTomorrow =
            "zhulong-daily-review-tomorrow"
        case zhulongInlineTaskTitle =
            "zhulong-inline-task-title"
        case zhulongInlineTaskDescription =
            "zhulong-inline-task-description"
        case zhulongInlineTaskNote =
            "zhulong-inline-task-note"
        case zhulongInlineTaskTargetDate =
            "zhulong-inline-task-target-date"
        case zhulongInlineSubtaskTitle =
            "zhulong-inline-subtask-title"
        case zhulongTodoDiffTitle =
            "zhulong-todo-diff-title"
        case zhulongTodoDiffTargetDate =
            "zhulong-todo-diff-target-date"

        var label: String {
            switch self {
            case .dayQuickAdd: "Day Todo 快速新增"
            case .futureQuickAdd: "未来日期快速新增"
            case .poolQuickAdd: "任务池快速新增"
            case .railSearch: "详情栏快速搜索"
            case .quickEntry: "全局快速输入"
            case .globalSearch: "全局搜索"
            case .poolTitle: "任务池标题"
            case .poolDescription: "任务池描述"
            case .poolNewSubtask: "任务池新增计划子任务"
            case .poolExistingSubtask: "任务池已有计划子任务"
            case .poolNewNote: "任务池新增附言"
            case .poolExistingNote: "任务池编辑附言"
            case .dayTitle: "当日任务标题"
            case .dayDescription: "当日任务描述"
            case .dayNewSubtask: "当日新增子任务"
            case .dayExistingSubtask: "当日已有子任务"
            case .dayNewNote: "当日新增附言"
            case .dayExistingNote: "当日编辑附言"
            case .futureTitle: "未来计划标题"
            case .futureDescription: "未来计划描述"
            case .futureNewNote: "未来计划新增附言"
            case .futureExistingNote: "未来计划编辑附言"
            case .taskCycleCreateTitle: "新建重复任务标题"
            case .taskCycleTitle: "重复任务模板标题"
            case .taskCycleDescription: "重复任务模板描述"
            case .taskCycleNewSubtask: "重复任务新增模板子任务"
            case .taskCycleExistingSubtask:
                "重复任务已有模板子任务"
            case .reviewSummary: "复盘今日总结"
            case .reviewUnfinishedReason: "复盘未完成原因"
            case .reviewTomorrowNote: "复盘明日注意事项"
            case .changeTaskTitle: "变更为新任务标题"
            case .classificationLabel: "任务标签输入"
            case .classificationCategoryCreate: "详情新建分组"
            case .classificationManagerSearch: "分类管理搜索"
            case .classificationManagerCreate: "分类管理新建名称"
            case .classificationManagerRename: "分类管理重命名"
            case .settingsPoem: "设置诗文"
            case .providerName: "Provider 显示名称"
            case .providerBaseURL: "Provider Base URL"
            case .providerModel: "Provider Model"
            case .providerAPIKey: "Provider API Key"
            case .zhulongHomeIntent: "烛龙首页意图"
            case .zhulongSessionEntry: "烛龙会话输入"
            case .zhulongDecisionSupplement: "烛龙决策补充"
            case .zhulongDailyReviewSummary: "烛龙每日复盘总结"
            case .zhulongDailyReviewTomorrow: "烛龙每日复盘明日事项"
            case .zhulongInlineTaskTitle: "烛龙内联任务标题"
            case .zhulongInlineTaskDescription: "烛龙内联任务描述"
            case .zhulongInlineTaskNote: "烛龙内联任务附言"
            case .zhulongInlineTaskTargetDate: "烛龙内联任务目标日期"
            case .zhulongInlineSubtaskTitle: "烛龙内联子任务标题"
            case .zhulongTodoDiffTitle: "烛龙 Todo 变更标题"
            case .zhulongTodoDiffTargetDate: "烛龙 Todo 变更目标日期"
            }
        }

        var savePolicy: String {
            switch self {
            case .poolTitle, .poolDescription, .dayTitle,
                 .dayDescription, .futureTitle,
                 .futureDescription, .taskCycleTitle,
                 .taskCycleDescription, .poolExistingNote,
                 .dayExistingNote, .futureExistingNote,
                 .reviewSummary,
                 .reviewUnfinishedReason, .reviewTomorrowNote,
                 .settingsPoem, .poolExistingSubtask,
                 .dayExistingSubtask,
                 .taskCycleExistingSubtask:
                "组合态本地草稿／700ms有序后台保存／失焦发布"
            case .globalSearch, .railSearch:
                "不持久化"
            case .providerName, .providerBaseURL,
                 .providerModel, .providerAPIKey:
                "逐字内存草稿，保存按钮后持久化"
            case .zhulongHomeIntent, .zhulongSessionEntry,
                 .zhulongDecisionSupplement,
                 .zhulongTodoDiffTitle,
                 .zhulongTodoDiffTargetDate,
                 .dayQuickAdd, .futureQuickAdd,
                 .poolQuickAdd, .quickEntry,
                 .poolNewSubtask, .dayNewSubtask,
                 .taskCycleNewSubtask, .poolNewNote,
                 .dayNewNote, .futureNewNote,
                 .taskCycleCreateTitle,
                 .changeTaskTitle,
                 .classificationCategoryCreate,
                 .classificationManagerCreate,
                 .classificationManagerRename:
                "提交／确认时持久化"
            case .zhulongDailyReviewSummary,
                 .zhulongDailyReviewTomorrow,
                 .zhulongInlineTaskTitle,
                 .zhulongInlineTaskDescription,
                 .zhulongInlineTaskNote,
                 .zhulongInlineTaskTargetDate,
                 .zhulongInlineSubtaskTitle:
                "组合态本地草稿／350ms有序后台 sidecar 保存／提交确认"
            case .classificationLabel:
                "选择／提交标签时持久化"
            case .classificationManagerSearch:
                "不持久化"
            }
        }

        var expectsMarkedText: Bool {
            self != .providerAPIKey
        }

        var supportsLifecycleTermination: Bool {
            switch self {
            case .poolTitle, .poolDescription,
                 .poolExistingSubtask, .poolExistingNote,
                 .dayTitle, .dayDescription,
                 .dayExistingSubtask, .dayExistingNote,
                 .futureTitle, .futureDescription,
                 .futureExistingNote, .taskCycleTitle,
                 .taskCycleDescription,
                 .taskCycleExistingSubtask,
                 .reviewSummary,
                 .reviewUnfinishedReason,
                 .reviewTomorrowNote, .settingsPoem,
                 .zhulongDailyReviewSummary,
                 .zhulongDailyReviewTomorrow,
                 .zhulongInlineTaskTitle,
                 .zhulongInlineTaskDescription,
                 .zhulongInlineTaskNote,
                 .zhulongInlineSubtaskTitle:
                true
            default:
                false
            }
        }

        var usesZhulongSidecar: Bool {
            switch self {
            case .zhulongDailyReviewSummary,
                 .zhulongDailyReviewTomorrow,
                 .zhulongInlineTaskTitle,
                 .zhulongInlineTaskDescription,
                 .zhulongInlineTaskNote,
                 .zhulongInlineSubtaskTitle:
                true
            default:
                false
            }
        }
    }

    private struct TencentIMEDecisionGateProvider:
        ZhulongProvider
    {
        let configurationIdentity:
            ZhulongProviderConfigurationIdentity

        func complete(
            _ request: ZhulongProviderRequest
        ) async -> ZhulongProviderResult {
            .success(
                ZhulongProviderResponse(
                    content:
                    """
                    {
                      "kind":"decisionGate",
                      "summary":"证据仍需覆盖条件输入面。",
                      "prompt":"这次验证应该怎样继续？",
                      "reason":"需要确认所有真实中文自由文本控件。",
                      "evidenceGaps":["条件页面尚未逐项测量"],
                      "options":[
                        {
                          "id":"complete-matrix",
                          "title":"补齐矩阵",
                          "impact":"逐项验证真实输入和持久化"
                        },
                        {
                          "id":"stop",
                          "title":"保留未决",
                          "impact":"停止本轮验证"
                        }
                      ]
                    }
                    """
                )
            )
        }
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
}
