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

struct CompletedRecordDetail: View {
    @EnvironmentObject private var store: NoonmarkStore
    let item: CompletedPoolItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader(store.copy.taskDetailsTitle, onClose: { store.clearSelection() }, trailing: {
                IconMenuButton(menuContent: {
                    CompletedTaskContextMenu(item: item)
                })
            })
            DetailPrimaryText {
                DetailTitleRow(store.copy.displayTaskTitle(item.definition.title))
            } description: {
                DetailDescriptionBlock(
                    text: Binding(
                        get: { item.trace.descriptionText ?? "" },
                        set: { store.updateTraceText(traceID: item.trace.id, descriptionText: $0) }
                    ),
                    placeholder: store.copy.taskDescriptionPlaceholder,
                    editable: false
                )
            }

            HStack(spacing: 8) {
                StatusChip(status: .completed)
                Text("\(store.displayDate(item.trace.date)) \(store.weekday(item.trace.date))")
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
            }

            DetailProgressSection(
                traceID: item.trace.id,
                progress: store.engine.traceProgress(for: item.trace.id),
                editable: false
            )

            TaskClassificationDetailSection(
                trace: item.trace,
                taskTitle: item.definition.title
            )

            TraceTimelineSection(trace: item.trace)

            DetailNotesSection(
                traceID: item.trace.id,
                entries: item.trace.activeNoteEntries,
                editable: false,
                placeholder: store.copy.noteComposerPlaceholder
            )
        }
    }
}

struct TraceTimelineSection: View {
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace

    var body: some View {
        CollapsibleTaskTrailSection(trace: trace) {
            MarkdownText(summaryText)
                .font(.noonmarkSystem(size: 11))
                .foregroundStyle(Theme.text2)
                .monospacedDigit()
                .lineLimit(1)
            TraceEndBadge(text: endLabel, color: endColor)
        }
    }

    var summaryText: String {
        if continuationCount > 0 {
            return store.copy.durationWithContinuations(days: durationDays, count: continuationCount)
        }
        return store.copy.duration(durationDays)
    }

    var durationDays: Int {
        guard let first = chainTraces.first else { return 1 }
        guard let last = chainTraces.last else { return 1 }
        return NoonmarkStore.dayDistance(from: first.date, to: last.date) + 1
    }

    var continuationCount: Int {
        chainTraces.map(\.continuationSeq).max() ?? 0
    }

    var endLabel: String {
        store.copy.traceEndLabel(endStatus)
    }

    var endColor: Color {
        switch endStatus {
        case .completed:
            return Theme.ok
        case .abandoned, .returnedToPool:
            return Theme.text3
        case .cancelledDraft:
            preconditionFailure("Internal trace status cannot appear in completed details")
        default:
            return Theme.accent
        }
    }

    var endStatus: TraceStatus {
        chainTraces.last?.status ?? trace.status
    }

    var chainTraces: [DayTrace] {
        store.engine.traces.values
            .filter {
                $0.chainID == trace.chainID && $0.formsDayHistory
            }
            .sorted { $0.date < $1.date }
    }
}

struct TraceEndBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.noonmarkSystem(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(Theme.chip))
    }
}

struct CompletedSubtaskDetail: View {
    @EnvironmentObject private var store: NoonmarkStore
    let record: CompletedSubtaskRecord

    var completedAt: String { store.displayTime(record.subtask.completedAt) ?? store.copy.notRecorded }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader(store.copy.completedSubtaskRecordTitle, onClose: { store.clearSelection() }, trailing: {
                IconMenuButton(menuContent: {
                    CompletedSubtaskContextMenu(record: record)
                })
            })
            DetailTitleRow(record.subtask.title)

            HStack(spacing: 8) {
                CompletionKindPill(text: store.copy.subtask, color: Theme.accent)
                Text("\(store.displayDate(record.date)) \(store.weekday(record.date))")
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
            }

            CompletionSummaryCard(items: [
                CompletionSummaryItem(
                    label: store.copy.parentTaskTitle,
                    value: store.copy.displayTaskTitle(record.parentDefinition.title),
                    color: Theme.text2
                ),
                CompletionSummaryItem(
                    label: store.copy.difficultyTitle,
                    value: store.copy.subtaskDifficulty(record.subtask.difficulty),
                    color: record.subtask.difficulty == .hard ? Theme.warn : Theme.text2
                ),
                CompletionSummaryItem(label: store.copy.completedTitle, value: store.displayDate(record.date), color: Theme.ok),
                CompletionSummaryItem(label: store.copy.timeTitle, value: completedAt, color: Theme.text2)
            ])

            Notice(text: store.copy.subtaskCompletionNotice, tone: .locked)

            TaskClassificationDetailSection(
                trace: record.parentTrace,
                taskTitle: record.parentDefinition.title
            )

            DetailSection(store.copy.parentTaskTitle) {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownInlineText(
                        store.copy.displayTaskTitle(record.parentDefinition.title)
                    )
                        .font(.noonmarkSystem(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(2)
                    MarkdownText(
                        record.parentDefinition.descriptionText ?? "",
                        fallback: store.copy.missingTaskDescription
                    )
                        .font(.noonmarkSystem(size: 11.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(3)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            DetailSection(store.copy.completionNodeTitle) {
                CompletedTrajectoryPanel(nodes: [CompletedTrajectoryNode(subtask: record.subtask, date: record.date)])
            }
        }
    }
}

struct CompletionSummaryItem {
    let label: String
    let value: String
    let color: Color
}

struct CompletionSummaryCard: View {
    let items: [CompletionSummaryItem]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(items, id: \.label) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.label)
                        .font(.noonmarkSystem(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .tracking(0.6)
                        .frame(width: 38, alignment: .leading)
                    Text(item.value)
                        .font(.noonmarkSystem(size: 11.5, weight: .medium))
                        .foregroundStyle(item.color)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CompletedTrajectoryPanel: View {
    let nodes: [CompletedTrajectoryNode]

    var body: some View {
        CompletedTrajectoryNodes(nodes: nodes)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
