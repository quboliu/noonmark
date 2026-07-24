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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(store.copy.dailyReviewTitle)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                if let message = store.reviewAutosaveMessage {
                    ReviewSavedIndicator(text: message)
                }
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
                ReviewStatsCard(stats: stats)
                ReviewEditor(
                    title: store.copy.todaySummaryTitle,
                    placeholder: store.copy.todaySummaryPlaceholder,
                    accessibilityIdentifier: "review.summary",
                    text: Binding(
                        get: { day?.reviewSummary ?? "" },
                        set: { store.updateReview(summary: $0) }
                    )
                )
                ReviewEditor(
                    title: store.copy.unfinishedReasonTitle,
                    placeholder: store.copy.unfinishedReasonPlaceholder,
                    accessibilityIdentifier: "review.unfinished-reason",
                    text: Binding(
                        get: { day?.reviewUnfinishedReason ?? "" },
                        set: { store.updateReview(reason: $0) }
                    )
                )
                ReviewEditor(
                    title: store.copy.tomorrowNotesTitle,
                    placeholder: store.copy.tomorrowNotesPlaceholder,
                    accessibilityIdentifier: "review.tomorrow-note",
                    text: Binding(
                        get: { day?.reviewTomorrowNote ?? "" },
                        set: { store.updateReview(tomorrow: $0) }
                    )
                )
            }
        }
    }
}

struct ReviewSavedIndicator: View {
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark")
                .font(.noonmarkSystem(size: 8.5, weight: .bold))
            Text(text)
        }
        .font(.noonmarkSystem(size: 10))
        .foregroundStyle(Theme.ok.opacity(0.9))
    }
}

struct ZhulongReviewEntryButton: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        Button {
            store.requestZhulongDailyReviewFromReviewRail()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                Text(store.copy.analyzeTodayWithZhulong)
                    .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.noonmarkSystem(size: 10, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .hoverSurface(
                cornerRadius: 8,
                idleFill: Theme.accentSoft,
                hoverFill: Theme.accentSoft.opacity(0.72),
                idleStroke: Theme.accent.opacity(0.18),
                hoverStroke: Theme.accent.opacity(0.32)
            )
        }
        .buttonStyle(.plain)
    }
}

struct ReviewStatsCard: View {
    @EnvironmentObject private var store: NoonmarkStore
    let stats: DailyReviewStats

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(store.copy.totalTasksTitle)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Text("\(stats.total)")
                    .font(.noonmarkSystem(size: 22, weight: .semibold))
            }
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    segment(stats.completed, total: stats.total, color: Theme.ok, width: proxy.size.width)
                    segment(pendingCount, total: stats.total, color: Theme.accent, width: proxy.size.width)
                    segment(stats.unfinished, total: stats.total, color: Theme.warn, width: proxy.size.width)
                }
            }
            .frame(height: 7)
            .clipShape(Capsule())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                legend(store.copy.traceStatusLabel(.pending), pendingCount, Theme.accent)
                legend(store.copy.traceStatusLabel(.completed), stats.completed, Theme.ok)
                legend(store.copy.traceStatusLabel(.unfinished), stats.unfinished, Theme.warn)
                legend(store.copy.traceStatusLabel(.deferred), stats.deferred, Theme.text2)
                legend(store.copy.traceStatusLabel(.abandoned), stats.abandoned, Theme.text2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }

    func segment(_ value: Int, total: Int, color: Color, width: CGFloat) -> some View {
        Rectangle()
            .fill(value == 0 ? Color.clear : color)
            .frame(width: total == 0 ? 0 : max(2, width * CGFloat(value) / CGFloat(total)))
    }

    var pendingCount: Int {
        max(
            0,
            stats.total
                - stats.completed
                - stats.unfinished
                - stats.deferred
                - stats.abandoned
        )
    }

    func legend(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack {
            Circle().fill(value == 0 ? Theme.line2 : color).frame(width: 6, height: 6)
            Text(label)
            Spacer()
            Text("\(value)")
        }
        .font(.noonmarkSystem(size: 11))
        .foregroundStyle(value == 0 ? Theme.text3 : Theme.text2)
    }
}

struct ReviewEditor: View {
    let title: String
    let placeholder: String
    let accessibilityIdentifier: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
            MarkdownEditor(
                text: $text,
                placeholder: placeholder,
                style: .body,
                height: 92,
                nativeAccessibilityIdentifier: accessibilityIdentifier
            )
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .background {
                    AppE2EViewAnchor(
                        identifier: "\(accessibilityIdentifier).surface",
                        verificationText: placeholder
                    )
                }
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        }
    }
}
