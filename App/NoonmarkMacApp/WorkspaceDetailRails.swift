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

struct ZhulongContextModel {
    struct Stat: Identifiable {
        let id = UUID()
        let title: String
        let value: String
    }

    let title: String
    let subtitle: String
    let stats: [Stat]
    let intent: String
    let recentSession: ZhulongSession?

    @MainActor
    static func make(for page: NoonmarkStore.Page, store: NoonmarkStore) -> ZhulongContextModel? {
        switch page {
        case .pool:
            let tasks = store.engine.taskPool()
            let contextCount = tasks.filter {
                ($0.definition.descriptionText ?? "").isEmpty == false || $0.chain.activeNoteEntries.isEmpty == false
            }.count
            let unclassifiedCount = tasks.filter { store.isUnclassified($0.chain.id) }.count
            return ZhulongContextModel(
                title: store.copy.poolSchedulingTitle,
                subtitle: store.copy.poolSchedulingSubtitle,
                stats: [
                    Stat(title: store.copy.unscheduled, value: store.copy.itemCount(tasks.count)),
                    Stat(title: store.copy.hasDescription, value: store.copy.itemCount(contextCount)),
                    Stat(title: store.copy.ungrouped, value: store.copy.itemCount(unclassifiedCount))
                ],
                intent: store.copy.poolSchedulingIntent,
                recentSession: store.recentZhulongSession(matching: [.taskPool, .unfinishedPool])
            )
        case .future:
            let plans = store.engine.futurePlans(today: store.today)
            let coveredDates = Set(plans.map(\.trace.date)).count
            let continued = plans.filter { $0.trace.continuationSeq > 0 }.count
            return ZhulongContextModel(
                title: store.copy.futureReschedulingTitle,
                subtitle: store.copy.futureReschedulingSubtitle,
                stats: [
                    Stat(title: store.copy.plannedTasks, value: store.copy.itemCount(plans.count)),
                    Stat(title: store.copy.coveredDates, value: store.copy.dayCount(coveredDates)),
                    Stat(title: store.copy.continuedTasks, value: store.copy.itemCount(continued))
                ],
                intent: store.copy.futureReschedulingIntent,
                recentSession: store.recentZhulongSession(matching: [.taskPool, .unfinishedPool])
            )
        case .unfinished:
            let items = store.engine.unfinishedPool()
            let missed = items.reduce(0) { $0 + $1.unfinishedTraces.count }
            let active = items.filter { $0.activeTrace != nil }.count
            return ZhulongContextModel(
                title: store.copy.unfinishedHandlingTitle,
                subtitle: store.copy.unfinishedHandlingSubtitle,
                stats: [
                    Stat(title: store.copy.taskChains, value: store.copy.chainCount(items.count)),
                    Stat(title: store.copy.missedOccurrences, value: store.copy.occurrenceCount(missed)),
                    Stat(title: store.copy.continuedTasks, value: store.copy.chainCount(active))
                ],
                intent: store.copy.unfinishedHandlingIntent,
                recentSession: store.recentZhulongSession(matching: [.unfinishedPool])
            )
        case .completed:
            let completed = store.engine.completedPool()
            let subtaskRecords = store.engine.completedSubtaskRecords()
            let coveredDates = Set(completed.map(\.trace.date) + subtaskRecords.map(\.date)).count
            return ZhulongContextModel(
                title: store.copy.completionReviewTitle,
                subtitle: store.copy.completionReviewSubtitle,
                stats: [
                    Stat(title: store.copy.completedTasks, value: store.copy.itemCount(completed.count)),
                    Stat(title: store.copy.subtask, value: store.copy.recordCount(subtaskRecords.count)),
                    Stat(title: store.copy.coveredDates, value: store.copy.dayCount(coveredDates))
                ],
                intent: store.copy.completionReviewIntent,
                recentSession: store.recentZhulongSession(matching: [.completedPool])
            )
        case .day, .calendar, .zhulong, .settings:
            return nil
        }
    }
}

struct ZhulongContextRail: View {
    @EnvironmentObject private var store: NoonmarkStore
    let model: ZhulongContextModel

    var statusText: String {
        store.zhulongProviderDraft.isConfigured ? store.copy.providerEnabled : store.copy.localMode
    }

    var entryTitle: String {
        model.recentSession == nil ? store.copy.handToZhulong : store.copy.continueRecentSession
    }

    var entrySubtitle: String {
        if let recentSession = model.recentSession {
            return "\(recentSession.primaryIntent) · \(store.zhulongWorkspaceStatus(recentSession))"
        }
        return store.copy.zhulongContextEntrySubtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(store.copy.navZhulong)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Spacer()
                StatusPill(text: statusText, color: store.zhulongProviderDraft.isConfigured ? Theme.accent : Theme.ok)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(model.title)
                    .font(.noonmarkSystem(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text(model.subtitle)
                    .font(.noonmarkSystem(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(model.stats) { stat in
                    ZhulongScopeChip(title: stat.title, value: stat.value)
                }
            }

            Button(action: openZhulongDestination) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.noonmarkSystem(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entryTitle)
                            .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        Text(entrySubtitle)
                            .font(.noonmarkSystem(size: 11))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(3)
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.noonmarkSystem(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }
            .buttonStyle(.plain)
        }
    }

    private func openZhulongDestination() {
        store.page = .zhulong
        if let recentSession = model.recentSession {
            store.zhulongWorkspace.selectSession(recentSession.id)
        } else {
            store.startZhulongWorkspaceSession(intent: model.intent)
        }
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
    let title: String
    let subtitle: String
    let metrics: [SidebarAnalysisMetric]
    let signals: [String]
    let recommendations: [String]
    let zhulongNote: String

    @MainActor
    static func make(for page: NoonmarkStore.Page, store: NoonmarkStore) -> SidebarAnalysisModel? {
        switch page {
        case .future:
            let plans = store.engine.futurePlans(today: store.today)
            let dates = Set(plans.map(\.trace.date))
            let continuationCount = plans.filter { $0.trace.continuationSeq > 0 }.count
            let maxDayLoad = Dictionary(grouping: plans, by: { $0.trace.date }).values.map(\.count).max() ?? 0
            return SidebarAnalysisModel(
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
                zhulongNote: store.copy.futureZhulongNote
            )
        case .unfinished:
            let items = store.engine.unfinishedPool()
            let missed = items.reduce(0) { $0 + $1.unfinishedTraces.count }
            let active = items.filter { $0.activeTrace != nil }.count
            let repeated = items.filter { $0.unfinishedTraces.count >= 2 }.count
            return SidebarAnalysisModel(
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
                zhulongNote: store.copy.unfinishedZhulongNote
            )
        case .completed:
            let completed = store.engine.completedPool()
            let subtaskRecords = store.engine.completedSubtaskRecords()
            let dates = Set(completed.map(\.trace.date) + subtaskRecords.map(\.date))
            let continuedCompletions = completed.filter { $0.trace.continuationSeq > 0 }.count
            return SidebarAnalysisModel(
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
                zhulongNote: store.copy.completionZhulongNote
            )
        case .pool, .day, .calendar, .zhulong, .settings:
            return nil
        }
    }
}

struct PoolSummaryModel {
    struct Group: Identifiable {
        let id: String
        let title: String
        let color: Color
        var count: Int
        let leadTitle: String
    }

    let orderedTasks: [PoolTask]
    let contextCount: Int
    let plannedCount: Int
    let needsDetailCount: Int
    let unclassifiedCount: Int
    let groups: [Group]

    var totalCount: Int { orderedTasks.count }
    var oldestCreatedAt: Date? { orderedTasks.first?.definition.createdAt }

    @MainActor
    static func make(store: NoonmarkStore) -> PoolSummaryModel {
        let orderedTasks = store.engine.taskPool()
            .sorted { $0.definition.createdAt < $1.definition.createdAt }
        let contextCount = orderedTasks.filter {
            ($0.definition.descriptionText ?? "").isEmpty == false || $0.chain.activeNoteEntries.isEmpty == false
        }.count
        let plannedCount = orderedTasks.filter { $0.definition.plannedSubtasks.isEmpty == false }.count
        let needsDetailCount = orderedTasks.filter {
            ($0.definition.descriptionText ?? "").isEmpty &&
                $0.chain.activeNoteEntries.isEmpty &&
                $0.definition.plannedSubtasks.isEmpty
        }.count
        let unclassifiedCount = orderedTasks.filter { store.isUnclassified($0.chain.id) }.count

        var groups: [Group] = []
        var groupIndexes: [String: Int] = [:]
        for task in orderedTasks {
            let category = store.currentClassification(for: task.chain.id)?.category
            let id = category?.id ?? "no-primary-category"
            if let index = groupIndexes[id] {
                groups[index].count += 1
            } else {
                groupIndexes[id] = groups.count
                groups.append(
                    Group(
                        id: id,
                        title: category?.name ?? store.copy.ungrouped,
                        color: category?.color ?? Theme.text3,
                        count: 1,
                        leadTitle: task.definition.title
                    )
                )
            }
        }

        return PoolSummaryModel(
            orderedTasks: orderedTasks,
            contextCount: contextCount,
            plannedCount: plannedCount,
            needsDetailCount: needsDetailCount,
            unclassifiedCount: unclassifiedCount,
            groups: groups
        )
    }
}

struct PoolSummaryRail: View {
    @EnvironmentObject private var store: NoonmarkStore

    var model: PoolSummaryModel {
        PoolSummaryModel.make(store: store)
    }

    var focusTasks: [PoolTask] {
        Array(model.orderedTasks.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PoolSummaryOverviewCard(model: model)

            if model.totalCount > 0 {
                DetailSection(store.copy.groupsSection) {
                    PoolSummaryGroupsPanel(groups: model.groups, totalCount: model.totalCount)
                }

                DetailSection(store.copy.leadingRecordsSection(focusTasks.count)) {
                    PoolSummaryQueuePanel(tasks: focusTasks)
                }
            }
        }
    }
}

struct PoolSummaryOverviewCard: View {
    @EnvironmentObject private var store: NoonmarkStore
    let model: PoolSummaryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.copy.navPool)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.8)

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(model.totalCount)")
                    .font(.noonmarkSystem(size: 32, weight: .semibold))
                    .foregroundStyle(Theme.navPool)
                    .monospacedDigit()
                Text(store.copy.unscheduled)
                    .font(.noonmarkSystem(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text2)
            }

            Text(
                model.oldestCreatedAt.map {
                    store.copy.oldestPoolEntry(store.copy.poolCreatedAtLabel($0))
                } ?? store.copy.poolEmptyNow
            )
                .font(.noonmarkSystem(size: 11.5))
                .foregroundStyle(Theme.text2)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                PoolSummaryMetric(label: store.copy.hasDescription, value: model.contextCount, color: Theme.navPool)
                PoolSummaryMetric(label: store.copy.plannedSubtasksMetric, value: model.plannedCount, color: Theme.accent)
                PoolSummaryMetric(label: store.copy.needsDetailsMetric, value: model.needsDetailCount, color: Theme.warn)
                PoolSummaryMetric(label: store.copy.ungrouped, value: model.unclassifiedCount, color: Theme.text3)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.navPool.opacity(0.16)))
    }
}

struct PoolSummaryMetric: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
            Text("\(value)")
                .font(.noonmarkSystem(size: 18, weight: .semibold))
                .foregroundStyle(value == 0 ? Theme.text3 : color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PoolSummaryGroupsPanel: View {
    let groups: [PoolSummaryModel.Group]
    let totalCount: Int

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                PoolSummaryGroupRow(group: group, totalCount: totalCount)
                if index < groups.count - 1 {
                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}

struct PoolSummaryGroupRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let group: PoolSummaryModel.Group
    let totalCount: Int

    var ratio: CGFloat {
        guard totalCount > 0 else { return 0 }
        return CGFloat(group.count) / CGFloat(totalCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(group.color)
                    .frame(width: 7, height: 7)
                Text(group.title)
                    .font(.noonmarkSystem(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                Spacer()
                Text(store.copy.itemCount(group.count))
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.panel)
                    Capsule()
                        .fill(group.color.opacity(0.82))
                        .frame(width: max(8, proxy.size.width * ratio))
                }
            }
            .frame(height: 5)

            Text(group.leadTitle)
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

struct PoolSummaryQueuePanel: View {
    let tasks: [PoolTask]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tasks.enumerated()), id: \.element.chain.id) { index, task in
                PoolSummaryQueueRow(task: task)
                if index < tasks.count - 1 {
                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}

struct PoolSummaryQueueRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let task: PoolTask

    var meta: String {
        let hasDescription = (task.definition.descriptionText ?? "").isEmpty == false
        let hasNote = task.chain.activeNoteEntries.isEmpty == false
        let plannedSubtaskCount = task.definition.plannedSubtasks.count
        var parts = [store.copy.enteredPool(store.copy.poolCreatedAtLabel(task.definition.createdAt))]
        if store.isUnclassified(task.chain.id) {
            parts.append(store.copy.ungrouped)
        }
        if hasDescription == false && hasNote == false {
            parts.append(store.copy.missingDescription)
        }
        if plannedSubtaskCount > 0 {
            parts.append(store.copy.subtaskCount(plannedSubtaskCount))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button { store.selectPool(task.chain.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                MarkdownInlineText(task.definition.title)
                    .font(.noonmarkSystem(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let classification = store.displayableClassification(for: task.chain.id) {
                    TaskClassificationBadges(
                        display: classification,
                        taskTitle: task.definition.title,
                        accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                            surface: "pool-summary-row",
                            instanceID: task.chain.id.description
                        )
                    )
                    .padding(.top, 4)
                }

                Text(meta)
                    .font(.noonmarkSystem(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(4)
        .hoverSurface(
            cornerRadius: 8,
            idleFill: .clear,
            hoverFill: Theme.panel,
            idleStroke: .clear,
            hoverStroke: Theme.line
        )
        .contextMenu {
            PoolTaskContextMenu(task: task, surface: "summary-row")
        }
    }
}

struct SidebarAnalysisRail: View {
    @EnvironmentObject private var store: NoonmarkStore
    let model: SidebarAnalysisModel

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

            SidebarTextBlock(title: store.copy.localSignals, rows: model.signals)
            SidebarTextBlock(title: store.copy.algorithmSuggestions, rows: model.recommendations)
            ZhulongAnalysisHint(text: model.zhulongNote)
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
    }
}

struct ZhulongAnalysisHint: View {
    let text: String

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
    }
}

struct DetailRail: View {
    @EnvironmentObject private var store: NoonmarkStore

    var zhulongContextModel: ZhulongContextModel? {
        guard store.usesZhulongContextRail else { return nil }
        return ZhulongContextModel.make(for: store.page, store: store)
    }

    var body: some View {
        if store.page == .calendar {
            CalendarDetailPanel()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let trace = store.selectedTrace, let definition = store.selectedDefinition {
                        if store.page == .completed, let record = store.selectedCompletedSubtaskRecord {
                            CompletedSubtaskDetail(record: record)
                        } else if store.page == .completed, let item = store.selectedCompletedItem {
                            CompletedRecordDetail(item: item)
                        } else if store.page == .future {
                            FuturePlanDetail(trace: trace, definition: definition)
                        } else {
                            TaskDetail(trace: trace, definition: definition)
                        }
                    } else if let task = store.selectedPoolTask {
                        PoolDetail(task: task)
                    } else if let item = store.selectedUnfinishedItem {
                        UnfinishedDetail(item: item)
                    } else if store.page == .zhulong {
                        ZhulongRail()
                    } else if store.page == .day {
                        ReviewRail()
                    } else if let model = zhulongContextModel {
                        ZhulongContextRail(model: model)
                    } else {
                        RailHint(text: hint)
                            .padding(.top, 40)
                    }
                }
                .padding(NoonmarkVisualMetrics.detailPadding)
            }
            .background(Theme.panel)
        }
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
