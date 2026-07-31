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

struct ReviewRail: View {
    @EnvironmentObject private var store: NoonmarkStore

    var day: Day? { store.engine.days[store.selectedDate] }
    var stats: DailyReviewStats { store.engine.dailyReviewStats(date: store.selectedDate) }
    var noReview: Bool { store.isFuture }

    private var completionRate: Int {
        stats.total == 0
            ? 0
            : Int((Double(stats.completed) / Double(stats.total) * 100).rounded())
    }

    private var pendingCount: Int {
        max(
            0,
            stats.total
                - stats.completed
                - stats.unfinished
                - stats.deferred
                - stats.abandoned
        )
    }

    private var trendPoints: [RailTrendPoint] {
        (0 ..< 7).reversed().map { daysBack in
            let date = NoonmarkStore.offset(store.selectedDate, by: -daysBack)
            let dayStats = store.engine.dailyReviewStats(date: date)
            return RailTrendPoint(
                axisLabel: store.weekdayNarrow(date),
                ratio: dayStats.total == 0
                    ? nil
                    : Double(dayStats.completed) / Double(dayStats.total),
                isHighlighted: daysBack == 0
            )
        }
    }

    private var signals: [RailSignal] {
        var items: [RailSignal] = []
        if stats.unfinished > 0 {
            items.append(
                RailSignal(
                    text: store.copy.reviewUnfinishedCarrySignal(stats.unfinished),
                    actionTitle: store.copy.reviewOpenUnfinishedAction,
                    action: { store.selectPage(.unfinished) }
                )
            )
        }
        if store.selectedDate == store.today {
            let tomorrow = NoonmarkStore.offset(store.today, by: 1)
            let tomorrowCount = store.engine.getDayTodo(date: tomorrow).traces.count
            if tomorrowCount > 0 {
                items.append(
                    RailSignal(
                        text: store.copy.reviewTomorrowLoadSignal(tomorrowCount),
                        actionTitle: store.copy.reviewOpenTomorrowAction,
                        action: {
                            store.selectedDate = tomorrow
                            store.selectPage(.day)
                        }
                    )
                )
            }
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(store.copy.dailyReviewTitle)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                ReviewSavedStatusView(status: store.reviewAutosaveStatus)
                Spacer()
                Text("\(store.displayDate(store.selectedDate)) \(store.weekday(store.selectedDate))")
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            if store.isHistory {
                Text(store.copy.historicalReviewHint)
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.accent)
            }
            if store.selectedDate == store.today {
                ZhulongReviewEntryButton()
            }
            if noReview {
                Text(store.copy.futureReviewHint)
                    .font(.noonmarkSystem(size: 12))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            } else {
                RailHeroStat(
                    label: store.copy.completionHeroLabel,
                    value: "\(completionRate)%",
                    tone: completionRate == 100 && stats.total > 0
                        ? Theme.ok
                        : Theme.accent
                )

                DetailSection(store.copy.railTrendTitle) {
                    RailTrendStrip(points: trendPoints)
                }

                RailDivider()

                DetailSection(store.copy.totalTasksTitle) {
                    VStack(alignment: .leading, spacing: 6) {
                        RailStatRow(
                            label: store.copy.traceStatusLabel(.pending),
                            value: "\(pendingCount)",
                            valueColor: pendingCount == 0 ? Theme.text3 : Theme.accent
                        )
                        RailStatRow(
                            label: store.copy.traceStatusLabel(.completed),
                            value: "\(stats.completed)",
                            valueColor: stats.completed == 0 ? Theme.text3 : Theme.ok
                        )
                        RailStatRow(
                            label: store.copy.traceStatusLabel(.unfinished),
                            value: "\(stats.unfinished)",
                            valueColor: stats.unfinished == 0 ? Theme.text3 : Theme.warn
                        )
                        RailStatRow(
                            label: store.copy.traceStatusLabel(.deferred),
                            value: "\(stats.deferred)"
                        )
                        RailStatRow(
                            label: store.copy.traceStatusLabel(.abandoned),
                            value: "\(stats.abandoned)"
                        )
                    }
                }

                if signals.isEmpty == false {
                    RailDivider()

                    DetailSection(store.copy.reviewSignalsTitle) {
                        RailSignalList(signals: signals)
                    }
                }

                RailDivider()

                ReviewEditor(
                    title: store.copy.todaySummaryTitle,
                    placeholder: store.copy.todaySummaryPlaceholder,
                    accessibilityIdentifier: "review.summary",
                    ownerID:
                    "review:\(store.selectedDate.description):summary",
                    text: day?.reviewSummary ?? "",
                    onPersist: {
                        await store.autosaveReview(
                            summary: $0
                        )
                    }
                )
                ReviewEditor(
                    title: store.copy.unfinishedReasonTitle,
                    placeholder: store.copy.unfinishedReasonPlaceholder,
                    accessibilityIdentifier: "review.unfinished-reason",
                    ownerID:
                    "review:\(store.selectedDate.description):unfinished-reason",
                    text: day?.reviewUnfinishedReason ?? "",
                    onPersist: {
                        await store.autosaveReview(
                            reason: $0
                        )
                    }
                )
                ReviewEditor(
                    title: store.copy.tomorrowNotesTitle,
                    placeholder: store.copy.tomorrowNotesPlaceholder,
                    accessibilityIdentifier: "review.tomorrow-note",
                    ownerID:
                    "review:\(store.selectedDate.description):tomorrow-note",
                    text: day?.reviewTomorrowNote ?? "",
                    onPersist: {
                        await store.autosaveReview(
                            tomorrow: $0
                        )
                    }
                )
            }
        }
    }
}

struct ReviewSavedIndicator: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.noonmarkSystem(size: 8.5, weight: .bold))
            Text(text)
        }
        .font(.noonmarkSystem(size: 10))
        .foregroundStyle(Theme.ok.opacity(0.9))
    }
}

private struct ReviewSavedStatusView: View {
    @ObservedObject var status: ReviewAutosaveStatus

    var body: some View {
        if let message = status.message {
            ReviewSavedIndicator(text: message)
        }
    }
}

struct ZhulongReviewEntryButton: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        RailEntryRow(
            systemImage: "sparkles",
            title: store.copy.analyzeTodayWithZhulong
        ) {
            store.requestZhulongDailyReviewFromReviewRail()
        }
    }
}

struct ReviewEditor: View {
    let title: String
    let placeholder: String
    let accessibilityIdentifier: String
    let ownerID: String
    let text: String
    let onPersist: @MainActor (String) async -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.6)
            AutosavingMarkdownEditor(
                ownerID: ownerID,
                persistedText: text,
                placeholder: placeholder,
                style: .body,
                showsSurface: true,
                height: 92,
                onPersist: onPersist,
                nativeAccessibilityIdentifier:
                accessibilityIdentifier
            )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .background {
                    AppE2EViewAnchor(
                        identifier: "\(accessibilityIdentifier).surface",
                        verificationText: placeholder
                    )
                }
        }
    }
}
