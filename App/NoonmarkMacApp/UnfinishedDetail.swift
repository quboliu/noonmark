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

struct UnfinishedDetail: View {
    @EnvironmentObject private var store: NoonmarkStore
    let item: UnfinishedPoolItem

    var latestUnfinished: DayTrace? { item.latestUnfinishedTrace }
    var detailTrace: DayTrace? { latestUnfinished ?? item.activeTrace }

    var body: some View {
        if let trace = detailTrace {
            VStack(alignment: .leading, spacing: 14) {
                DetailHeader(store.copy.taskDetailsTitle, onClose: { store.clearSelection() }, trailing: {
                    if item.actionPlan.isEmpty == false {
                        IconMenuButton(menuContent: {
                            UnfinishedTaskContextMenu(item: item)
                        })
                        .accessibilityIdentifier("unfinished.detail.actions.ax")
                        .background {
                            AppE2EViewAnchor(
                                identifier: "unfinished.detail.actions",
                                verificationText: "\(item.actionPlan.count)"
                            )
                        }
                    }
                })
                DetailPrimaryText {
                    DetailTitleRow(store.copy.displayTaskTitle(item.definition.title))
                } description: {
                    DetailDescriptionBlock(
                        text: .constant(trace.descriptionText ?? item.definition.descriptionText ?? ""),
                        placeholder: "",
                        editable: false
                    )
                }

                HStack(spacing: 8) {
                    StatusChip(status: item.isAbandoned ? .abandoned : .unfinished)
                    Text("\(store.displayDate(trace.date)) \(store.weekday(trace.date))")
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text3)
                }

                UnfinishedTraceContextCard(item: item, trace: trace)
                Notice(
                    text: item.isAbandoned
                        ? store.copy.abandonedChainHistoryNotice
                        : store.copy.historicalFactsReadOnlyNotice,
                    tone: .locked
                )

                DetailProgressSection(
                    traceID: trace.id,
                    progress: store.engine.traceProgress(for: trace.id),
                    editable: false
                )

                TaskClassificationDetailSection(
                    trace: trace,
                    taskTitle: item.definition.title,
                    editable: false
                )

                DetailSection(store.copy.taskTrailTitle) {
                    Timeline(trace: trace)
                }

                DetailNotesSection(
                    traceID: trace.id,
                    entries: trace.activeNoteEntries,
                    editable: false,
                    placeholder: store.copy.noteComposerPlaceholder
                )
            }
        } else {
            RailHint(text: store.copy.noUnfinishedDetail)
        }
    }
}

struct UnfinishedTraceContextCard: View {
    @EnvironmentObject private var store: NoonmarkStore
    let item: UnfinishedPoolItem
    let trace: DayTrace

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(store.copy.continuationOrdinal(trace.continuationSeq))
            Text("·")
                .foregroundStyle(Theme.text3)
            Text(store.copy.duration(durationDays))
            if let active = item.activeTrace {
                Text("·")
                    .foregroundStyle(Theme.text3)
                Button(store.copy.continuedToLink(store.displayDate(active.date))) {
                    store.selectedDate = active.date
                    store.page = .day
                    store.selectTrace(active.id)
                }
                .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
        }
        .font(.noonmarkSystem(size: 11))
        .foregroundStyle(Theme.text2)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.warnSoft))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }

    var durationDays: Int {
        let traces = (item.unfinishedTraces + [item.activeTrace].compactMap { $0 }).sorted { $0.date < $1.date }
        guard let first = traces.first else { return 1 }
        return max(
            1,
            NoonmarkStore.dayDistance(from: first.date, to: trace.date) + 1
        )
    }
}
