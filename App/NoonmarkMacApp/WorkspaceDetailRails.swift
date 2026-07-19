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
    let signals: [String]
    let recommendations: [String]
    let zhulongNote: String
    let zhulongIntent: String
    let zhulongScopes: Set<ZhulongDataScope>

    @MainActor
    static func make(for page: NoonmarkStore.Page, store: NoonmarkStore) -> SidebarAnalysisModel? {
        switch page {
        case .pool:
            let tasks = store.engine.taskPool()
                .sorted { $0.definition.createdAt < $1.definition.createdAt }
            let contextCount = tasks.filter {
                ($0.definition.descriptionText ?? "").isEmpty == false
                    || $0.chain.activeNoteEntries.isEmpty == false
            }.count
            let plannedCount = tasks.filter {
                $0.definition.plannedSubtasks.isEmpty == false
            }.count
            let needsDetailCount = tasks.filter {
                ($0.definition.descriptionText ?? "").isEmpty
                    && $0.chain.activeNoteEntries.isEmpty
                    && $0.definition.plannedSubtasks.isEmpty
            }.count
            let unclassifiedCount = tasks.filter {
                store.isUnclassified($0.chain.id)
            }.count
            return SidebarAnalysisModel(
                page: page,
                title: store.copy.poolSchedulingTitle,
                subtitle: store.copy.poolSchedulingSubtitle,
                metrics: [
                    SidebarAnalysisMetric(
                        label: store.copy.unscheduled,
                        value: "\(tasks.count)",
                        tone: .accent
                    ),
                    SidebarAnalysisMetric(
                        label: store.copy.hasDescription,
                        value: "\(contextCount)",
                        tone: contextCount == tasks.count ? .ok : .neutral
                    ),
                    SidebarAnalysisMetric(
                        label: store.copy.plannedSubtasksMetric,
                        value: "\(plannedCount)",
                        tone: .neutral
                    ),
                    SidebarAnalysisMetric(
                        label: store.copy.ungrouped,
                        value: "\(unclassifiedCount)",
                        tone: unclassifiedCount == 0 ? .ok : .warn
                    )
                ],
                signals: [
                    store.copy.poolOldestSignal(
                        tasks.first.map {
                            store.copy.poolCreatedAtLabel($0.definition.createdAt)
                        }
                    ),
                    store.copy.poolOrganizationSignal(
                        unclassifiedCount: unclassifiedCount
                    )
                ],
                recommendations: [
                    store.copy.poolDetailsRecommendation(
                        needsDetailCount: needsDetailCount
                    ),
                    store.copy.poolPlanningRecommendation(
                        plannedCount: plannedCount,
                        totalCount: tasks.count
                    )
                ],
                zhulongNote: store.copy.poolZhulongNote,
                zhulongIntent: store.copy.poolSchedulingIntent,
                zhulongScopes: [.taskPool, .unfinishedPool]
            )
        case .future:
            let plans = store.engine.futurePlans(today: store.today)
            let dates = Set(plans.map(\.trace.date))
            let continuationCount = plans.filter { $0.trace.continuationSeq > 0 }.count
            let maxDayLoad = Dictionary(grouping: plans, by: { $0.trace.date }).values.map(\.count).max() ?? 0
            return SidebarAnalysisModel(
                page: page,
                title: store.copy.futureAnalysisTitle,
                subtitle: store.copy.futureAnalysisSubtitle,
                metrics: [
                    SidebarAnalysisMetric(label: store.copy.plannedTasks, value: "\(plans.count)", tone: .accent),
                    SidebarAnalysisMetric(label: store.copy.coveredDates, value: "\(dates.count)", tone: .neutral),
                    SidebarAnalysisMetric(label: store.copy.continuedTasks, value: "\(continuationCount)", tone: continuationCount > 0 ? .warn : .ok)
                ],
                signals: [
                    store.copy.recentPlanSignal(
                        date: plans.first.map { store.displayDate($0.trace.date) },
                        title: plans.first?.definition.title
                    ),
                    store.copy.futureDensitySignal(isDense: maxDayLoad >= 4)
                ],
                recommendations: [
                    store.copy.futurePrimaryRecommendation(isEmpty: plans.isEmpty),
                    store.copy.futureContinuationRecommendation(hasContinuations: continuationCount > 0)
                ],
                zhulongNote: store.copy.futureZhulongNote,
                zhulongIntent: store.copy.futureReschedulingIntent,
                zhulongScopes: [.taskPool, .unfinishedPool]
            )
        case .unfinished:
            let items = store.engine.unfinishedPool()
            let missed = items.reduce(0) { $0 + $1.unfinishedTraces.count }
            let active = items.filter { $0.activeTrace != nil }.count
            let repeated = items.filter { $0.unfinishedTraces.count >= 2 }.count
            return SidebarAnalysisModel(
                page: page,
                title: store.copy.unfinishedRiskTitle,
                subtitle: store.copy.unfinishedRiskSubtitle,
                metrics: [
                    SidebarAnalysisMetric(label: store.copy.taskChains, value: "\(items.count)", tone: items.isEmpty ? .ok : .warn),
                    SidebarAnalysisMetric(label: store.copy.missedOccurrences, value: "\(missed)", tone: missed == 0 ? .ok : .warn),
                    SidebarAnalysisMetric(label: store.copy.continuedTasks, value: "\(active)", tone: .accent)
                ],
                signals: [
                    store.copy.repeatedUnfinishedSignal(repeated),
                    store.copy.activeContinuationSignal(active)
                ],
                recommendations: [
                    store.copy.unfinishedPrimaryRecommendation(isEmpty: items.isEmpty),
                    store.copy.repeatedUnfinishedRecommendation(hasRepeated: repeated > 0)
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
                    store.copy.recentCompletionSignal(
                        date: completed.first.map { store.displayDate($0.trace.date) },
                        title: completed.first?.definition.title
                    ),
                    store.copy.continuedCompletionSignal(continuedCompletions)
                ],
                recommendations: [
                    store.copy.completionPrimaryRecommendation(
                        isEmpty: completed.isEmpty && subtaskRecords.isEmpty
                    ),
                    store.copy.completedSubtaskRecommendation(hasSubtasks: subtaskRecords.isEmpty == false)
                ],
                zhulongNote: store.copy.completionZhulongNote,
                zhulongIntent: store.copy.completionReviewIntent,
                zhulongScopes: [.completedPool]
            )
        case .day, .calendar, .zhulong, .settings:
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
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.title)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Text(model.subtitle)
                    .font(.noonmarkSystem(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(model.metrics) { metric in
                    SidebarMetricTile(metric: metric)
                }
            }
            .background {
                AppE2EViewAnchor(
                    identifier: "\(identifierPrefix).metrics",
                    verificationText: "\(model.metrics.count)"
                )
            }

            SidebarTextBlock(
                title: store.copy.localSignals,
                rows: model.signals,
                identifier: "\(identifierPrefix).signals"
            )
            SidebarTextBlock(
                title: store.copy.algorithmSuggestions,
                rows: model.recommendations,
                identifier: "\(identifierPrefix).recommendations"
            )
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

struct SidebarMetricTile: View {
    let metric: SidebarAnalysisMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(metric.label)
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
            Text(metric.value)
                .font(.noonmarkSystem(size: 18, weight: .semibold))
                .foregroundStyle(metric.tone.color)
                .monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(metric.tone.background.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

struct SidebarTextBlock: View {
    let title: String
    let rows: [String]
    let identifier: String

    var body: some View {
        DetailSection(title) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 7) {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        Text(row)
                            .font(.noonmarkSystem(size: 11.5))
                            .foregroundStyle(Theme.text2)
                            .lineSpacing(3)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        }
        .background {
            AppE2EViewAnchor(
                identifier: identifier,
                verificationText: "\(rows.count)"
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
                .frame(width: 18, height: 18)
            Text(text)
                .font(.noonmarkSystem(size: 11.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.16)))
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

    private var recentSession: ZhulongSession? {
        store.recentZhulongSession(matching: scopes)
    }

    private var title: String {
        recentSession == nil
            ? store.copy.handToZhulong
            : store.copy.continueRecentSession
    }

    private var subtitle: String {
        if let recentSession {
            return "\(recentSession.primaryIntent) · \(store.zhulongWorkspaceStatus(recentSession))"
        }
        return store.copy.zhulongContextEntrySubtitle
    }

    var body: some View {
        Button(action: openZhulongDestination) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Text(subtitle)
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text3)
                        .lineSpacing(3)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.noonmarkSystem(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .padding(.top, 4)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.16)))
            .background {
                AppE2EViewAnchor(
                    identifier: "detail.summary.\(page.rawValue).zhulong-action",
                    verificationText: title
                )
            }
        }
        .buttonStyle(.plain)
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

    var body: some View {
        switch store.detailRailRoute {
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
            if let model = SidebarAnalysisModel.make(for: page, store: store) {
                SidebarAnalysisRail(model: model)
            } else {
                RailHint(text: hint)
                    .padding(.top, 40)
            }
        }
    }

    @ViewBuilder
    private var selectionDetail: some View {
        if let record = completedSubtaskDetailRecord {
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
