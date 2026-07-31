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

struct ZhulongRail: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        ZhulongWorkspaceRail(workspace: store.zhulongWorkspace)
    }
}

struct TaskPoolHomeRailModel {
    let statistics: TaskPoolStatisticsSnapshot
    let analysisState: TaskPoolAnalysisState?
    let analysisSessionID: ZhulongSessionID?

    @MainActor
    static func make(store: NoonmarkStore) -> TaskPoolHomeRailModel {
        let pool = store.engine.taskPool()
        let items = pool.map { task in
            let classification = store.currentClassification(
                for: task.chain.id
            )
            let hasReturnedToPool = (
                try? store.engine.taskTrail(chainID: task.chain.id)
            )?.contains { $0.kind == .returnedToPool } ?? false
            return TaskPoolStatisticsItem(
                categoryID: classification?.category?.id,
                labelIDs: Set(
                    classification?.labels.map(\.id) ?? []
                ),
                hasContext:
                (task.definition.descriptionText ?? "").isEmpty == false
                    || task.chain.activeNoteEntries.isEmpty == false,
                hasPlannedSubtasks:
                task.definition.plannedSubtasks.isEmpty == false,
                hasReturnedToPool: hasReturnedToPool
            )
        }
        let availability = TaskPoolAnalysisAvailability(
            providerConfigurationIsReady:
            store.isZhulongProviderReady
        )
        let session = store.recentZhulongSession(
            purpose: .taskPoolAnalysis
        )
        let run = analysisRunSnapshot(
            session: session
        )
        return TaskPoolHomeRailModel(
            statistics: TaskPoolStatisticsSnapshot(items: items),
            analysisState: TaskPoolAnalysisProjection.state(
                availability: availability,
                run: run,
                currentContextVersion:
                store.currentTaskPoolAnalysisContextVersion()
            ),
            analysisSessionID: session?.id
        )
    }

    private static func analysisRunSnapshot(
        session: ZhulongSession?
    ) -> TaskPoolAnalysisRunSnapshot? {
        guard let session else { return nil }
        if session.phase == .providerRunning {
            return .running
        }
        guard let send = session.providerSends.last else {
            return nil
        }
        switch send.result {
        case .running:
            return .running
        case .stopped:
            return .stopped
        case .failed:
            return .failed
        case let .succeeded(completedAt, response):
            guard case .taskPoolAnalysis =
                send.payload.responseContract,
                (try? send.payload.responseContract.validate(
                    response
                )) != nil,
                case let .some(.taskPoolAnalysis(report)) =
                response.artifacts.first
            else {
                return .failed
            }
            return .succeeded(
                contextVersion: send.payload.contextVersion,
                report: TaskPoolAnalysisReportPresentation(
                    generatedAt: completedAt,
                    findings: report.findings.map {
                        TaskPoolAnalysisFindingPresentation(
                            conclusion: $0.conclusion,
                            evidenceTitles: $0.evidence.map(\.title),
                            confidence:
                            TaskPoolAnalysisConfidence(
                                rawValue: $0.confidence.rawValue
                            ) ?? .low,
                            uncertainty: $0.uncertainty,
                            recommendation: $0.recommendation
                        )
                    }
                )
            )
        }
    }
}

struct TaskPoolHomeRail: View {
    private struct Statistic: Identifiable {
        let id: String
        let label: String
        let value: Int
    }

    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var workspace: ZhulongWorkspaceStore

    private var model: TaskPoolHomeRailModel {
        TaskPoolHomeRailModel.make(store: store)
    }

    private var secondaryStatistics: [Statistic] {
        [
            Statistic(
                id: "categories",
                label: store.copy.poolCategoryTotalMetric,
                value: model.statistics.categoryCount
            ),
            Statistic(
                id: "labels",
                label: store.copy.poolLabelTotalMetric,
                value: model.statistics.labelCount
            ),
            Statistic(
                id: "ungrouped",
                label: store.copy.ungrouped,
                value: model.statistics.ungroupedTaskCount
            ),
            Statistic(
                id: "context",
                label: store.copy.poolContextualTaskMetric,
                value: model.statistics.contextualTaskCount
            ),
            Statistic(
                id: "planned",
                label: store.copy.plannedSubtasksMetric,
                value: model.statistics.plannedTaskCount
            ),
            Statistic(
                id: "returned",
                label: store.copy.poolReturnedTaskMetric,
                value: model.statistics.returnedTaskCount
            )
        ]
    }

    private var oldestPoolTask: (title: String, chainID: TaskChainID, days: Int)? {
        guard let oldest = store.engine.taskPool().min(by: {
            $0.chain.createdAt < $1.chain.createdAt
        }) else {
            return nil
        }
        let days = max(
            0,
            Calendar.current.dateComponents(
                [.day],
                from: oldest.chain.createdAt,
                to: Date()
            ).day ?? 0
        )
        return (oldest.definition.title, oldest.chain.id, days)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statisticsSection

            if let analysisState = model.analysisState {
                RailDivider()
                analysisSection(analysisState)
            }
        }
        .background {
            AppE2EViewAnchor(
                identifier: "detail.summary.pool",
                verificationText: store.copy.poolStatisticsTitle
            )
        }
    }

    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.copy.poolStatisticsTitle)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Text(store.copy.poolStatisticsSubtitle)
                    .font(.noonmarkSystem(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
            }

            VStack(alignment: .leading, spacing: 10) {
                RailHeroStat(
                    label: store.copy.poolTaskTotalMetric,
                    value: "\(model.statistics.taskCount)",
                    tone: Theme.accent
                )

                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), alignment: .leading),
                        count: MacUITaskPoolHomeRailLayout.statisticsColumnCount
                    ),
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(secondaryStatistics) { statistic in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(statistic.value)")
                                .font(.noonmarkSystem(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.text1)
                                .monospacedDigit()
                            Text(statistic.label)
                                .font(.noonmarkSystem(size: 10.5))
                                .foregroundStyle(Theme.text3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let oldest = oldestPoolTask {
                    Button {
                        store.selectPool(oldest.chainID)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(store.copy.poolOldestTaskLabel)
                                .font(.noonmarkSystem(size: 11.5))
                                .foregroundStyle(Theme.text3)
                            Text(store.copy.displayTaskTitle(oldest.title))
                                .font(.noonmarkSystem(size: 11.5))
                                .foregroundStyle(Theme.text2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(-1)
                            Spacer(minLength: 0)
                            Text(store.copy.poolOldestTaskDays(oldest.days))
                                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.text1)
                                .monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background {
                AppE2EViewAnchor(
                    identifier: "detail.summary.pool.statistics",
                    verificationText:
                    "\(model.statistics.taskCount),\(secondaryStatistics.count)"
                )
            }
        }
    }

    private func analysisSection(
        _ state: TaskPoolAnalysisState
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.copy.poolAnalysisTitle)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Text(store.copy.poolAnalysisSubtitle)
                    .font(.noonmarkSystem(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
            }
            analysisContent(state)
        }
        .background {
            AppE2EViewAnchor(
                identifier: "detail.summary.pool.analysis",
                verificationText: store.copy.poolAnalysisTitle
            )
        }
    }

    @ViewBuilder
    private func analysisContent(
        _ state: TaskPoolAnalysisState
    ) -> some View {
        switch state {
        case .notGenerated:
            analysisActionButton(
                title: store.copy.analyzeTaskPool,
                systemImage: "sparkles",
                action: store.requestTaskPoolAnalysis
            )
        case .generating:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(store.copy.poolAnalysisGenerating)
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text2)
                Spacer(minLength: 0)
                analysisSessionButton
            }
        case let .report(report, freshness):
            VStack(alignment: .leading, spacing: 0) {
                Text(
                    AppPresentation(
                        language: store.engine.preferences.language
                    ).zhulong.eventTimestamp(report.generatedAt)
                )
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
                .padding(.bottom, 8)
                if freshness == .outdated {
                    Text(store.copy.poolAnalysisOutdated)
                        .font(.noonmarkSystem(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.warn)
                        .padding(.bottom, 8)
                }
                if report.findings.isEmpty {
                    Text(store.copy.poolAnalysisNoFindings)
                        .font(.noonmarkSystem(size: 11.5))
                        .foregroundStyle(Theme.text2)
                }
                ForEach(
                    Array(report.findings.enumerated()),
                    id: \.offset
                ) { index, finding in
                    if index > 0 {
                        RailDivider()
                    }
                    analysisFinding(finding)
                }
                HStack(spacing: 12) {
                    TextActionButton(store.copy.refreshTaskPoolAnalysis) {
                        store.requestTaskPoolAnalysis()
                    }
                    analysisSessionButton
                }
                .padding(.top, 12)
            }
            .background {
                AppE2EViewAnchor(
                    identifier:
                    "detail.summary.pool.analysis.report",
                    verificationText:
                    "\(report.findings.count),\(freshness)"
                )
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text(store.copy.poolAnalysisFailed)
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.warn)
                analysisActionButton(
                    title: store.copy.retryTaskPoolAnalysis,
                    systemImage: "arrow.clockwise",
                    action: store.requestTaskPoolAnalysis
                )
            }
        }
    }

    private func analysisFinding(
        _ finding: TaskPoolAnalysisFindingPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(finding.conclusion)
                .font(.noonmarkSystem(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text1)
            Text(
                store.copy.poolAnalysisEvidence(
                    finding.evidenceTitles
                )
            )
            .font(.noonmarkSystem(size: 11))
            .foregroundStyle(Theme.text2)
            Text(
                store.copy.poolAnalysisConfidence(
                    finding.confidence,
                    uncertainty: finding.uncertainty
                )
            )
            .font(.noonmarkSystem(size: 10.5))
            .foregroundStyle(Theme.text3)
            Text(finding.recommendation)
                .font(.noonmarkSystem(size: 11))
                .foregroundStyle(Theme.accent)
        }
    }

    private var analysisSessionButton: some View {
        Button(store.copy.viewTaskPoolAnalysisSession) {
            guard let sessionID = model.analysisSessionID else {
                return
            }
            store.page = .zhulong
            workspace.selectSession(sessionID)
        }
        .buttonStyle(.plain)
        .font(.noonmarkSystem(size: 10.5, weight: .medium))
        .foregroundStyle(Theme.text3)
    }

    private func analysisActionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            "detail.summary.pool.zhulong-action"
        )
    }
}

struct SidebarAnalysisMetric: Identifiable {
    enum Tone {
        case accent
        case ok
        case warn
        case neutral

        var color: Color {
            switch self {
            case .accent:
                return Theme.accent
            case .ok:
                return Theme.ok
            case .warn:
                return Theme.warn
            case .neutral:
                return Theme.text2
            }
        }

        var background: Color {
            switch self {
            case .accent:
                return Theme.accentSoft
            case .ok:
                return Theme.okSoft
            case .warn:
                return Theme.warnSoft
            case .neutral:
                return Theme.chip
            }
        }
    }

    let id = UUID()
    let label: String
    let value: String
    let tone: Tone
}

struct SidebarAnalysisModel {
    let page: NoonmarkStore.Page
    let title: String
    let subtitle: String
    let metrics: [SidebarAnalysisMetric]
    let signals: [RailSignal]
    let recommendations: [RailSignal]
    let zhulongNote: String
    let zhulongIntent: String
    let zhulongScopes: Set<ZhulongDataScope>

    @MainActor
    static func make(for page: NoonmarkStore.Page, store: NoonmarkStore) -> SidebarAnalysisModel? {
        switch page {
        case .pool:
            return nil
        case .future:
            let plans = store.visibleFuturePlanItems()
            let dates = Set(plans.map(\.trace.date))
            let continuationCount = plans.filter { $0.trace.continuationSeq > 0 }.count
            let plansByDate = Dictionary(grouping: plans, by: { $0.trace.date })
            let maxDayLoad = plansByDate.values.map(\.count).max() ?? 0
            let densestDate = plansByDate
                .filter { $0.value.count == maxDayLoad }
                .keys
                .sorted()
                .first
            var signals = [
                RailSignal(
                    text: store.copy.recentPlanSignal(
                        date: plans.first.map { store.displayDate($0.trace.date) },
                        title: plans.first.map {
                            store.copy.displayTaskTitle($0.definition.title)
                        }
                    )
                )
            ]
            if maxDayLoad >= 3, let densestDate {
                signals.append(
                    RailSignal(
                        text: store.copy.densestDaySignal(
                            date: store.displayDate(densestDate),
                            count: maxDayLoad
                        ),
                        actionTitle: store.copy.openDayAction,
                        action: {
                            store.selectedDate = densestDate
                            store.selectPage(.day)
                        }
                    )
                )
            } else {
                signals.append(
                    RailSignal(
                        text: store.copy.futureDensitySignal(isDense: false)
                    )
                )
            }
            return SidebarAnalysisModel(
                page: page,
                title: store.copy.futureAnalysisTitle,
                subtitle: store.copy.futureAnalysisSubtitle,
                metrics: [
                    SidebarAnalysisMetric(label: store.copy.plannedTasks, value: "\(plans.count)", tone: .accent),
                    SidebarAnalysisMetric(label: store.copy.coveredDates, value: "\(dates.count)", tone: .neutral),
                    SidebarAnalysisMetric(label: store.copy.continuedTasks, value: "\(continuationCount)", tone: continuationCount > 0 ? .warn : .ok)
                ],
                signals: signals,
                recommendations: [
                    RailSignal(
                        text: store.copy.futurePrimaryRecommendation(isEmpty: plans.isEmpty)
                    ),
                    RailSignal(
                        text: store.copy.futureContinuationRecommendation(hasContinuations: continuationCount > 0)
                    )
                ],
                zhulongNote: store.copy.futureZhulongNote,
                zhulongIntent: store.copy.futureReschedulingIntent,
                zhulongScopes: [.taskPool, .unfinishedPool]
            )
        case .unfinished:
            let items = store.engine.unfinishedPool()
            let missed = items.reduce(0) { $0 + $1.unfinishedTraces.count }
            let active = items.filter { $0.activeTrace != nil }.count
            let repeatedItems = items.filter { $0.unfinishedTraces.count >= 2 }
            let repeated = repeatedItems.count
            var signals = [
                RailSignal(text: store.copy.repeatedUnfinishedSignal(repeated)),
                RailSignal(text: store.copy.activeContinuationSignal(active))
            ]
            if let top = repeatedItems.max(by: {
                $0.unfinishedTraces.count < $1.unfinishedTraces.count
            }) {
                let chainID = top.chain.id
                signals.append(
                    RailSignal(
                        text: store.copy.repeatedUnfinishedTitleSignal(
                            title: store.copy.displayTaskTitle(top.definition.title),
                            count: top.unfinishedTraces.count
                        ),
                        actionTitle: store.copy.locateTaskAction,
                        action: { store.selectUnfinished(chainID) }
                    )
                )
            }
            return SidebarAnalysisModel(
                page: page,
                title: store.copy.unfinishedRiskTitle,
                subtitle: store.copy.unfinishedRiskSubtitle,
                metrics: [
                    SidebarAnalysisMetric(label: store.copy.taskChains, value: "\(items.count)", tone: items.isEmpty ? .ok : .warn),
                    SidebarAnalysisMetric(label: store.copy.missedOccurrences, value: "\(missed)", tone: missed == 0 ? .ok : .warn),
                    SidebarAnalysisMetric(label: store.copy.continuedTasks, value: "\(active)", tone: .accent)
                ],
                signals: signals,
                recommendations: [
                    RailSignal(
                        text: store.copy.unfinishedPrimaryRecommendation(isEmpty: items.isEmpty)
                    ),
                    RailSignal(
                        text: store.copy.repeatedUnfinishedRecommendation(hasRepeated: repeated > 0)
                    )
                ],
                zhulongNote: store.copy.unfinishedZhulongNote,
                zhulongIntent: store.copy.unfinishedHandlingIntent,
                zhulongScopes: [.unfinishedPool]
            )
        case .completed:
            let completed = store.engine.completedPool()
            let subtaskRecords = store.engine.completedSubtaskRecords()
            let dates = Set(completed.map(\.trace.date) + subtaskRecords.map(\.date))
            let continuedCompletions = completed.filter { $0.trace.continuationSeq > 0 }.count
            return SidebarAnalysisModel(
                page: page,
                title: store.copy.completionTrailTitle,
                subtitle: store.copy.completionTrailSubtitle,
                metrics: [
                    SidebarAnalysisMetric(label: store.copy.completedTasks, value: "\(completed.count)", tone: .ok),
                    SidebarAnalysisMetric(label: store.copy.subtask, value: "\(subtaskRecords.count)", tone: .accent),
                    SidebarAnalysisMetric(label: store.copy.coveredDates, value: "\(dates.count)", tone: .neutral)
                ],
                signals: [
                    RailSignal(
                        text: store.copy.recentCompletionSignal(
                            date: completed.first.map { store.displayDate($0.trace.date) },
                            title: completed.first.map {
                                store.copy.displayTaskTitle($0.definition.title)
                            }
                        )
                    ),
                    RailSignal(
                        text: store.copy.continuedCompletionSignal(continuedCompletions)
                    )
                ],
                recommendations: [
                    RailSignal(
                        text: store.copy.completionPrimaryRecommendation(
                            isEmpty: completed.isEmpty && subtaskRecords.isEmpty
                        )
                    ),
                    RailSignal(
                        text: store.copy.completedSubtaskRecommendation(hasSubtasks: subtaskRecords.isEmpty == false)
                    )
                ],
                zhulongNote: store.copy.completionZhulongNote,
                zhulongIntent: store.copy.completionReviewIntent,
                zhulongScopes: [.completedPool]
            )
        case .day, .recurring, .calendar, .zhulong, .settings:
            return nil
        }
    }
}

struct SidebarAnalysisRail: View {
    @EnvironmentObject private var store: NoonmarkStore
    let model: SidebarAnalysisModel

    private var identifierPrefix: String {
        "detail.summary.\(model.page.rawValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Text(model.subtitle)
                    .font(.noonmarkSystem(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.metrics) { metric in
                    RailStatRow(
                        label: metric.label,
                        value: metric.value,
                        valueColor: metric.tone.color
                    )
                }
            }
            .background {
                AppE2EViewAnchor(
                    identifier: "\(identifierPrefix).metrics",
                    verificationText: "\(model.metrics.count)"
                )
            }

            RailDivider()

            DetailSection(store.copy.localSignals) {
                RailSignalList(signals: model.signals)
            }
            .background {
                AppE2EViewAnchor(
                    identifier: "\(identifierPrefix).signals",
                    verificationText: "\(model.signals.count)"
                )
            }

            DetailSection(store.copy.algorithmSuggestions) {
                RailSignalList(signals: model.recommendations)
            }
            .background {
                AppE2EViewAnchor(
                    identifier: "\(identifierPrefix).recommendations",
                    verificationText: "\(model.recommendations.count)"
                )
            }

            RailDivider()

            if store.isZhulongEnabled {
                ZhulongAnalysisEntry(
                    page: model.page,
                    intent: model.zhulongIntent,
                    scopes: model.zhulongScopes
                )
            } else {
                ZhulongAnalysisHint(
                    text: model.zhulongNote,
                    identifier: "\(identifierPrefix).zhulong-hint"
                )
            }
        }
        .background {
            AppE2EViewAnchor(
                identifier: identifierPrefix,
                verificationText: model.title
            )
        }
    }
}

struct ZhulongAnalysisHint: View {
    let text: String
    let identifier: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
                .padding(.top, 1)
            Text(text)
                .font(.noonmarkSystem(size: 11.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            AppE2EViewAnchor(
                identifier: identifier,
                verificationText: text
            )
        }
    }
}

struct ZhulongAnalysisEntry: View {
    @EnvironmentObject private var store: NoonmarkStore
    let page: NoonmarkStore.Page
    let intent: String
    let scopes: Set<ZhulongDataScope>
    let newSessionTitle: String?
    let recentSessionTitle: String?
    let newSessionSubtitle: String?

    init(
        page: NoonmarkStore.Page,
        intent: String,
        scopes: Set<ZhulongDataScope>,
        newSessionTitle: String? = nil,
        recentSessionTitle: String? = nil,
        newSessionSubtitle: String? = nil
    ) {
        self.page = page
        self.intent = intent
        self.scopes = scopes
        self.newSessionTitle = newSessionTitle
        self.recentSessionTitle = recentSessionTitle
        self.newSessionSubtitle = newSessionSubtitle
    }

    private var recentSession: ZhulongSession? {
        store.recentZhulongSession(matching: scopes)
    }

    private var title: String {
        recentSession == nil
            ? (newSessionTitle ?? store.copy.handToZhulong)
            : (recentSessionTitle ?? store.copy.continueRecentSession)
    }

    private var subtitle: String {
        if let recentSession {
            return "\(recentSession.primaryIntent) · \(store.zhulongWorkspaceStatus(recentSession))"
        }
        return newSessionSubtitle
            ?? store.copy.zhulongContextEntrySubtitle
    }

    var body: some View {
        RailEntryRow(
            systemImage: "sparkles",
            title: title,
            subtitle: subtitle,
            action: openZhulongDestination
        )
        .background {
            AppE2EViewAnchor(
                identifier: "detail.summary.\(page.rawValue).zhulong-action",
                verificationText: title
            )
        }
    }

    private func openZhulongDestination() {
        store.page = .zhulong
        if let recentSession {
            store.zhulongWorkspace.selectSession(recentSession.id)
        } else {
            store.startZhulongWorkspaceSession(intent: intent)
        }
    }
}

struct DetailRail: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var zhulongWorkspace: ZhulongWorkspaceStore
    @State private var railSearchQuery = ""
    @State private var railSearchIndex:
        WorkspaceSearchIndex?

    private var trimmedRailSearchQuery: String {
        railSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var railSearchResults: [WorkspaceSearchResult] {
        guard trimmedRailSearchQuery.isEmpty == false else { return [] }
        return railSearchIndex?
            .search(trimmedRailSearchQuery, limit: 6) ?? []
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    PaneBoundaryToggle(
                        direction: .right,
                        accessibilityLabel: store.copy.collapseDetailRail,
                        identifier: "shell.detail-rail.toggle"
                    ) {
                        store.toggleDetailRail()
                    }
                    RailSearchField(
                        query: $railSearchQuery,
                        onSubmit: {
                            if let first = railSearchResults.first {
                                revealRailSearchResult(first)
                            }
                        },
                        onDismiss: {
                            railSearchQuery = ""
                        }
                    )
                }
                .padding(.horizontal, 8)
                .frame(height: 36)
                .background(Theme.panel)

                detailContent
            }

            if trimmedRailSearchQuery.isEmpty == false {
                VStack(spacing: 0) {
                    RailSearchResultsPanel(
                        results: railSearchResults,
                        onSelect: revealRailSearchResult
                    )
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    RailDivider()
                }
                .background(Theme.panel)
                .shadow(color: Theme.shadowRaised, radius: 6, y: 3)
                .padding(.top, 40)
            }
        }
        .task(id: store.engineRevision) {
            railSearchIndex = WorkspaceSearchIndex(
                engine: store.engine
            )
        }
    }

    private func revealRailSearchResult(_ result: WorkspaceSearchResult) {
        store.revealSearchResult(result)
        railSearchQuery = ""
    }

    @ViewBuilder
    private var detailContent: some View {
        switch detailRailRoute {
        case .some(.calendar):
            CalendarDetailPanel()
        case let .some(route):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    routeContent(route)
                }
                .padding(NoonmarkVisualMetrics.detailPadding)
            }
            .background(Theme.panel)
        case .none:
            EmptyView()
        }
    }

    private var detailRailRoute: NoonmarkStore.DetailRailRoute? {
        guard store.page == .zhulong else {
            return store.detailRailRoute
        }
        return zhulongWorkspace.selectedSession == nil
            ? nil
            : .zhulong
    }

    @ViewBuilder
    private func routeContent(_ route: NoonmarkStore.DetailRailRoute) -> some View {
        switch route {
        case .calendar:
            EmptyView()
        case .selection:
            selectionDetail
        case .zhulong:
            ZhulongRail()
        case .dayReview:
            ReviewRail()
        case let .pageSummary(page):
            if page == .pool {
                TaskPoolHomeRail(
                    workspace: store.zhulongWorkspace
                )
            } else if let model = SidebarAnalysisModel.make(for: page, store: store) {
                SidebarAnalysisRail(model: model)
            } else {
                RailHint(text: hint)
                    .padding(.top, 40)
            }
        }
    }

    @ViewBuilder
    private var selectionDetail: some View {
        if let series = store.selectedTaskCycleSeries {
            TaskCycleDetail(series: series)
        } else if let record = completedSubtaskDetailRecord {
            CompletedSubtaskDetail(record: record)
        } else if let item = completedTaskDetailItem {
            CompletedRecordDetail(item: item)
        } else if let detail = selectedTraceDetail {
            if detail.isFuture {
                FuturePlanDetail(
                    trace: detail.trace,
                    definition: detail.definition
                )
            } else {
                TaskDetail(
                    trace: detail.trace,
                    definition: detail.definition
                )
            }
        } else if let task = store.selectedPoolTask {
            PoolDetail(task: task)
        } else if let item = store.selectedUnfinishedItem {
            UnfinishedDetail(item: item)
        } else {
            RailHint(text: hint)
                .padding(.top, 40)
        }
    }

    private var completedSubtaskDetailRecord: CompletedSubtaskRecord? {
        store.page == .completed
            ? store.selectedCompletedSubtaskRecord
            : nil
    }

    private var completedTaskDetailItem: CompletedPoolItem? {
        store.page == .completed
            ? store.selectedCompletedItem
            : nil
    }

    private var selectedTraceDetail: (
        trace: DayTrace,
        definition: TaskDefinition,
        isFuture: Bool
    )? {
        guard let trace = store.selectedTrace,
              let definition = store.selectedDefinition
        else {
            return nil
        }
        return (
            trace,
            definition,
            store.page == .future
        )
    }

    var hint: String {
        store.copy.detailRailHint(for: store.page)
    }
}

struct RailHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.noonmarkSystem(size: 12))
            .foregroundStyle(Theme.text3)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .padding(.horizontal, 4)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
    }
}
